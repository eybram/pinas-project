/* ============================================================================
 *  ProyectoSueloESP32.ino
 *  Monitoreo local del suelo de piña (ESP32 DevKit V1, 30 pines)
 *  - Wi-Fi en modo Access Point (sin Internet) + Dashboard web embebido
 *  - Lectura de humedad (YL-69 + LM393 -> GPIO34) y pH (E201 + acondicionador -> GPIO35)
 *  - Calibración guardada en NVS (Preferences) y registro en LittleFS (datos.csv)
 *  - Hora aportada por el teléfono (no hay RTC)
 *
 *  IMPORTANTE: cambia WIFI_PASS por una contraseña propia de 8+ caracteres.
 *  La interfaz web vive en dashboard.h (generado desde dashboard.html).
 * ==========================================================================*/

#include <WiFi.h>
#include <WebServer.h>
#include <LittleFS.h>
#include <Preferences.h>
#include <math.h>
#include "dashboard.h"

// ----------------------------- Configuración --------------------------------
const char* AP_SSID   = "Pina-Suelo-ESP32";   // red Wi-Fi local
const char* WIFI_PASS = "12345678";      // >= 8 caracteres (¡CAMBIAR!)

static const int PIN_HUM        = 34;   // AO del LM393 (YL-69)   -> ADC1
static const int PIN_PH         = 35;   // salida del acondicionador pH -> ADC1
static const int PIN_LED_GREEN  = 14;   // sin señales entre las dos variables
static const int PIN_LED_YELLOW = 27;   // lectura incompleta / señal individual
static const int PIN_LED_RED    = 26;   // coincidencia provisional persistente

static const char* CSV_PATH   = "/datos.csv";
static const char* CSV_HEADER =
    "fecha_utc,epoch_s,hum_mv,hum_ind,ph_mv,ph,ph_present,lluvia,riego,agua,cobertura,notas,coincide,persistente";

// Umbrales PROVISIONALES/demostrativos (deben revisarse en el protocolo).
static const float    HUM_ALERT_DELTA = 20.0f;   // puntos de índice de humedad
static const float    PH_ALERT_DELTA  = 1.0f;    // unidades de pH
static const uint32_t PERSIST_MIN_S   = 18UL * 3600UL;  // 18 h
static const uint32_t PERSIST_MAX_S   = 30UL * 3600UL;  // 30 h

// Columnas del CSV (para no depender del orden al leer)
enum { C_FECHA = 0, C_EPOCH, C_HUM_MV, C_HUM_IND, C_PH_MV, C_PH,
       C_PH_PRESENT, C_LLUVIA, C_RIEGO, C_AGUA, C_COBERTURA, C_NOTAS,
       C_COINCIDE, C_PERSIST };

// -------------------------------- Estado ------------------------------------
WebServer  server(80);
Preferences prefs;

long hum_dry = -1;   // mV de referencia seca   (-1 = sin calibrar)
long hum_wet = -1;   // mV de referencia húmeda
long ph7     = -1;   // mV en tampón pH 7.00
long ph4     = -1;   // mV en tampón pH 4.00
bool fsReady = false;

// Sesión anterior (para umbrales de variación y persistencia)
struct PrevData {
  bool  hasHum    = false;
  float hum       = 0;
  bool  hasPh     = false;
  float ph        = 0;
  bool  coincide  = false;
  long  epoch     = 0;
};

// ------------------------------ Utilidades ----------------------------------
// Lee el ADC promediando varias muestras y devuelve mV calibrados.
long readMV(int pin) {
  const int N = 16;
  uint32_t acc = 0;
  for (int i = 0; i < N; i++) {
    acc += analogReadMilliVolts(pin);
    delay(2);
  }
  return (long)(acc / N);
}

bool humCalibrated() { return hum_dry >= 0 && hum_wet >= 0 && hum_dry != hum_wet; }
bool phCalibrated()  { return ph7 >= 0 && ph4 >= 0 && ph7 != ph4; }

// Índice local 0..100 (NO es humedad volumétrica).
float humIndex(long mv) {
  float v = (float)(hum_dry - mv) * 100.0f / (float)(hum_dry - hum_wet);
  if (v < 0) v = 0;
  if (v > 100) v = 100;
  return v;
}

// pH por calibración de dos puntos (7.00 y 4.00).
float phValue(long mv) {
  return 7.0f + (float)(ph7 - mv) * 3.0f / (float)(ph4 - ph7);
}

void loadCalibration() {
  hum_dry = prefs.getLong("hum_dry", -1);
  hum_wet = prefs.getLong("hum_wet", -1);
  ph7     = prefs.getLong("ph7", -1);
  ph4     = prefs.getLong("ph4", -1);
}

void saveCalibration() {
  prefs.putLong("hum_dry", hum_dry);
  prefs.putLong("hum_wet", hum_wet);
  prefs.putLong("ph7", ph7);
  prefs.putLong("ph4", ph4);
}

// Limpia un campo de texto para que no rompa el CSV (comas, saltos, comillas).
String csvClean(String s, int maxLen) {
  s.replace("\r", " ");
  s.replace("\n", " ");
  s.replace(",", ";");
  s.replace("\"", "'");
  s.trim();
  if ((int)s.length() > maxLen) s = s.substring(0, maxLen);
  return s;
}

String fieldAt(const String& line, int idx) {
  int start = 0;
  for (int i = 0; i < idx; i++) {
    int c = line.indexOf(',', start);
    if (c < 0) return String("");
    start = c + 1;
  }
  int end = line.indexOf(',', start);
  if (end < 0) end = line.length();
  return line.substring(start, end);
}

String jsonLongOrNull(const char* key, long v) {
  String s = "\"";
  s += key;
  s += "\":";
  s += (v < 0) ? String("null") : String(v);
  return s;
}

void ensureCsv() {
  if (!fsReady) return;
  if (!LittleFS.exists(CSV_PATH)) {
    File f = LittleFS.open(CSV_PATH, FILE_WRITE);
    if (f) { f.println(CSV_HEADER); f.close(); }
    return;
  }
  File f = LittleFS.open(CSV_PATH, FILE_READ);
  bool empty = (f && f.size() == 0);
  if (f) f.close();
  if (empty) {
    File w = LittleFS.open(CSV_PATH, FILE_WRITE);
    if (w) { w.println(CSV_HEADER); w.close(); }
  }
}

bool readLastDataLine(String& out) {
  if (!fsReady || !LittleFS.exists(CSV_PATH)) return false;
  File f = LittleFS.open(CSV_PATH, FILE_READ);
  if (!f) return false;
  String last;
  while (f.available()) {
    String l = f.readStringUntil('\n');
    l.trim();
    if (l.length() > 0 && !l.startsWith("fecha_utc")) last = l;
  }
  f.close();
  out = last;
  return last.length() > 0;
}

PrevData loadPrev() {
  PrevData p;
  String line;
  if (!readLastDataLine(line)) return p;
  String humS = fieldAt(line, C_HUM_IND);
  if (humS.length()) { p.hum = humS.toFloat(); p.hasHum = true; }
  String phS = fieldAt(line, C_PH);
  if (phS.length()) { p.ph = phS.toFloat(); p.hasPh = true; }
  p.coincide = (fieldAt(line, C_COINCIDE) == "1");
  p.epoch    = fieldAt(line, C_EPOCH).toInt();
  return p;
}

void applyLEDs(bool humValid, bool phValid, bool coincide, bool persistente) {
  digitalWrite(PIN_LED_GREEN,  LOW);
  digitalWrite(PIN_LED_YELLOW, LOW);
  digitalWrite(PIN_LED_RED,    LOW);
  if (!humValid || !phValid)          digitalWrite(PIN_LED_YELLOW, HIGH);
  else if (coincide && persistente)   digitalWrite(PIN_LED_RED,    HIGH);
  else                                digitalWrite(PIN_LED_GREEN,  HIGH);
}

// ------------------------------- Handlers -----------------------------------
void handleRoot() {
  server.send_P(200, "text/html; charset=utf-8", DASHBOARD_HTML);
}

void handleNotFound() {
  server.send(404, "text/plain; charset=utf-8", "Recurso no encontrado");
}

void handleStatus() {
  long h = readMV(PIN_HUM);
  long p = readMV(PIN_PH);

  String j = "{";
  j += "\"storage\":"; j += fsReady ? "true" : "false";
  j += ",\"hum_mv\":"; j += String(h);
  j += ",\"ph_mv\":";  j += String(p);
  j += ",\"hum_index\":";
  j += humCalibrated() ? String(humIndex(h), 1) : String("null");
  j += ","; j += jsonLongOrNull("hum_dry", hum_dry);
  j += ","; j += jsonLongOrNull("hum_wet", hum_wet);
  j += ","; j += jsonLongOrNull("ph7", ph7);
  j += ","; j += jsonLongOrNull("ph4", ph4);
  j += "}";
  server.send(200, "application/json", j);
}

void handlePreview() {
  bool phPresent = (server.arg("ph_present") == "1");
  long h = readMV(PIN_HUM);
  long p = readMV(PIN_PH);

  bool  humValid = humCalibrated();
  bool  phValid  = phPresent && phCalibrated();
  float humv     = humValid ? humIndex(h) : 0.0f;
  float phv      = phValid  ? phValue(p)  : 0.0f;

  String st;
  if (!humValid && !phValid)      st = "Sin variables evaluables";
  else if (humValid && !phValid)  st = "Solo humedad evaluable; pH no evaluable";
  else if (!humValid && phValid)  st = "Solo pH evaluable; humedad sin calibrar";
  else {
    PrevData prev = loadPrev();
    bool humAlert = prev.hasHum && fabs(humv - prev.hum) >= HUM_ALERT_DELTA;
    bool phAlert  = prev.hasPh  && fabs(phv  - prev.ph)  >= PH_ALERT_DELTA;
    st = (humAlert && phAlert)
         ? "Dos variables evaluables; coincidencia provisional"
         : "Dos variables evaluables; sin coincidencia";
  }

  String j = "{";
  j += "\"hum_mv\":"; j += String(h);
  j += ",\"ph_mv\":";  j += String(p);
  j += ",\"hum_index\":";
  j += humValid ? String(humv, 1) : String("null");
  j += ",\"ph\":";
  j += phValid ? String(phv, 2) : String("null");
  j += ",\"status\":\""; j += st; j += "\"";
  j += "}";
  server.send(200, "application/json", j);
}

void handleSave() {
  if (!fsReady) {
    server.send(500, "application/json",
                "{\"error\":\"Almacenamiento no disponible; no se guardó la sesión.\"}");
    return;
  }

  bool   phPresent = (server.arg("ph_present") == "1");
  String timestamp = csvClean(server.arg("timestamp"), 40);
  long   epoch     = server.arg("epoch_s").toInt();
  String lluvia    = csvClean(server.arg("lluvia"), 20);
  String riego     = csvClean(server.arg("riego"), 20);
  String agua      = csvClean(server.arg("agua"), 20);
  String cobertura = csvClean(server.arg("cobertura"), 20);
  String notas     = csvClean(server.arg("notas"), 100);

  long  hum_mv  = readMV(PIN_HUM);
  long  ph_mv   = readMV(PIN_PH);
  bool  humValid = humCalibrated();
  bool  phValid  = phPresent && phCalibrated();
  float humv     = humValid ? humIndex(hum_mv) : 0.0f;
  float phv      = phValid  ? phValue(ph_mv)   : 0.0f;

  PrevData prev = loadPrev();
  bool humAlert = humValid && prev.hasHum && fabs(humv - prev.hum) >= HUM_ALERT_DELTA;
  bool phAlert  = phValid  && prev.hasPh  && fabs(phv  - prev.ph)  >= PH_ALERT_DELTA;
  bool coincide = humAlert && phAlert;

  long dt = epoch - prev.epoch;
  bool persistente = coincide && prev.coincide &&
                     dt >= (long)PERSIST_MIN_S && dt <= (long)PERSIST_MAX_S;

  String row;
  row += timestamp;                       row += ",";
  row += String(epoch);                   row += ",";
  row += String(hum_mv);                  row += ",";
  row += humValid ? String(humv, 1) : String(""); row += ",";
  row += String(ph_mv);                   row += ",";
  row += phValid ? String(phv, 2) : String("");  row += ",";
  row += phPresent ? "1" : "0";           row += ",";
  row += lluvia;                          row += ",";
  row += riego;                           row += ",";
  row += agua;                            row += ",";
  row += cobertura;                       row += ",";
  row += notas;                           row += ",";
  row += coincide ? "1" : "0";            row += ",";
  row += persistente ? "1" : "0";

  File f = LittleFS.open(CSV_PATH, FILE_APPEND);
  if (!f) {
    server.send(500, "application/json",
                "{\"error\":\"No se pudo abrir datos.csv para escritura.\"}");
    return;
  }
  size_t written = f.println(row);
  f.close();
  if (written == 0) {
    server.send(500, "application/json",
                "{\"error\":\"Falla al escribir en la memoria flash.\"}");
    return;
  }

  applyLEDs(humValid, phValid, coincide, persistente);

  String st = "Humedad: ";
  st += humValid ? (String(humv, 1) + " indice") : String("sin calibrar");
  st += " - pH: ";
  st += phValid ? String(phv, 2) : String("no evaluable");
  if (coincide) {
    st += " - Coincidencia provisional";
    if (persistente) st += " persistente";
  }

  server.send(200, "application/json", "{\"status\":\"" + st + "\"}");
}

void handleCalibrar() {
  String tipo = server.arg("tipo");
  long mv;
  String msg;

  if (tipo == "seco" || tipo == "humedo") {
    mv = readMV(PIN_HUM);
    if (tipo == "seco") {
      hum_dry = mv;
      msg = "Referencia seca guardada: " + String(mv) + " mV";
      if (hum_wet >= 0 && hum_dry <= hum_wet)
        msg += " (aviso: el valor seco no supera al humedo; revisa la sonda)";
    } else {
      hum_wet = mv;
      msg = "Referencia humeda guardada: " + String(mv) + " mV";
      if (hum_dry >= 0 && hum_dry <= hum_wet)
        msg += " (aviso: el valor humedo no es menor que el seco; revisa la sonda)";
    }
  } else if (tipo == "ph7" || tipo == "ph4") {
    mv = readMV(PIN_PH);
    if (tipo == "ph7") {
      ph7 = mv;
      msg = "Tampon pH 7.00 guardado: " + String(mv) + " mV";
    } else {
      ph4 = mv;
      msg = "Tampon pH 4.00 guardado: " + String(mv) + " mV";
    }
    if (ph7 >= 0 && ph4 >= 0 && ph7 == ph4)
      msg += " (aviso: ambos tampones dieron el mismo mV; revisa el modulo)";
  } else {
    server.send(400, "application/json",
                "{\"error\":\"Tipo de calibracion desconocido\"}");
    return;
  }

  saveCalibration();
  server.send(200, "application/json", "{\"message\":\"" + msg + "\"}");
}

void handleCsv() {
  if (!fsReady) {
    server.send(500, "text/plain; charset=utf-8", "Almacenamiento no disponible");
    return;
  }
  bool inline_view = server.hasArg("view");
  if (!LittleFS.exists(CSV_PATH)) {
    server.send(200, "text/csv; charset=utf-8", CSV_HEADER);
    return;
  }
  File f = LittleFS.open(CSV_PATH, FILE_READ);
  if (!f) {
    server.send(500, "text/plain; charset=utf-8", "No se pudo leer datos.csv");
    return;
  }
  if (!inline_view)
    server.sendHeader("Content-Disposition", "attachment; filename=suelo_pina.csv");
  server.streamFile(f, "text/csv; charset=utf-8");
  f.close();
}

// --------------------------------- Setup ------------------------------------
void setup() {
  Serial.begin(115200);
  delay(200);

  pinMode(PIN_LED_GREEN,  OUTPUT);
  pinMode(PIN_LED_YELLOW, OUTPUT);
  pinMode(PIN_LED_RED,    OUTPUT);
  digitalWrite(PIN_LED_GREEN,  LOW);
  digitalWrite(PIN_LED_YELLOW, LOW);
  digitalWrite(PIN_LED_RED,    LOW);

  // ADC1 (GPIO34/35) con atenuación por defecto (rango hasta ~3.1 V).
  analogReadResolution(12);

  prefs.begin("suelo", false);
  loadCalibration();

  // LittleFS: se formatea SOLO la primera vez (marcado en NVS).
  // Si ya existía y falla, no se vuelve a formatear para no borrar datos.
  if (!prefs.getBool("fs_ready", false)) {
    fsReady = LittleFS.begin(true);
    if (fsReady) prefs.putBool("fs_ready", true);
  } else {
    fsReady = LittleFS.begin(false);
  }
  Serial.print("LittleFS: "); Serial.println(fsReady ? "listo" : "NO disponible");
  if (fsReady) ensureCsv();

  WiFi.mode(WIFI_AP);
  bool ap = WiFi.softAP(AP_SSID, WIFI_PASS);
  Serial.print("AP "); Serial.print(AP_SSID);
  Serial.print(ap ? " activo en http://" : " FALLO. IP ");
  Serial.println(WiFi.softAPIP());

  server.on("/",              handleRoot);
  server.on("/api/status",    handleStatus);
  server.on("/api/preview",   handlePreview);
  server.on("/api/save",      HTTP_POST, handleSave);
  server.on("/api/calibrar",  HTTP_POST, handleCalibrar);
  server.on("/api/csv",       handleCsv);
  server.onNotFound(handleNotFound);
  server.begin();
  Serial.println("Servidor web iniciado.");
}

void loop() {
  server.handleClient();
}
