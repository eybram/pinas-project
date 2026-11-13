# Servidor local — Monitoreo de suelo de piña (ESP32)

Aquí vive el **proyecto Arduino IDE** que implementa el servidor web local descrito en
`../instrucciones/PLAN_DE_EJECUCION.md` y `../instrucciones/README_INSTALACION.md`.
No hay Internet ni servidor externo: el propio ESP32 crea la red Wi-Fi y sirve el panel.

## Contenido de `build/`

```
build/
├─ ProyectoSueloESP32/          <- abrir ESTA carpeta en Arduino IDE
│  ├─ ProyectoSueloESP32.ino    <- firmware (Wi-Fi AP + WebServer + LittleFS + NVS)
│  ├─ dashboard.h               <- panel web embebido (GENERADO, no editar a mano)
│  └─ dashboard.html            <- fuente editable del panel
├─ tools/
│  ├─ make_dashboard_h.ps1      <- regenera dashboard.h desde dashboard.html
│  ├─ mock-server.ps1           <- simulador local del ESP32 (probar sin placa)
│  ├─ mock-control.html         <- panel de control del simulador
│  └─ mock-data/                <- datos simulados (se crea al ejecutar el simulador)
└─ README.md
```

## Puesta en marcha

1. Instala el núcleo **esp32** de Espressif en Arduino IDE.
2. Abre `ProyectoSueloESP32/ProyectoSueloESP32.ino` (conserva `dashboard.h` junto al `.ino`).
3. En `ProyectoSueloESP32.ino` cambia `WIFI_PASS` por una contraseña propia (8+ caracteres).
4. Herramientas → placa **ESP32 Dev Module** y una partición de flash con sistema de archivos
   (LittleFS/SPIFFS). No hacen falta bibliotecas externas.
5. Sube por USB del computador (sin fuente externa conectada) y luego alimenta con 5 V regulados.
6. En el teléfono: Wi-Fi → `Pina-Suelo-ESP32` → contraseña → navegador → **http://192.168.4.1**.

> Si editas `dashboard.html`, ejecuta `powershell -ExecutionPolicy Bypass -File tools\make_dashboard_h.ps1`
> para regenerar `dashboard.h` antes de compilar. **No** edites `dashboard.h` a mano.

## Pines

| Función | GPIO | Notas |
| --- | --- | --- |
| Humedad YL-69 (AO del LM393) | 34 | ADC1; divisor 10k+10k si AO supera ~3.1 V |
| pH (salida del acondicionador) | 35 | ADC1; solo salida 0–3 V, nunca el electrodo directo |
| LED verde | 14 | sin señales entre las dos variables |
| LED amarillo | 27 | lectura incompleta / una sola señal |
| LED rojo | 26 | coincidencia provisional persistente (18–30 h) |

## API del servidor (usada por el panel)

| Método | Ruta | Descripción |
| --- | --- | --- |
| GET | `/` | Panel web embebido |
| GET | `/api/status` | `storage`, `hum_mv`, `ph_mv`, `hum_index`, `hum_dry`, `hum_wet`, `ph7`, `ph4` |
| GET | `/api/preview?ph_present=0\|1` | Vista previa sin guardar (`hum_index`, `ph`, `status`) |
| POST | `/api/save` | Guarda una fila en `datos.csv` (form-urlencoded) |
| POST | `/api/calibrar` | `tipo=seco\|humedo\|ph7\|ph4` → guarda la referencia actual en NVS |
| GET | `/api/csv` | Descarga `datos.csv` (adjunto) |
| GET | `/api/csv?view=1` | Devuelve el CSV en línea para las gráficas |

## Persistencia

- Calibración (`seco`, `humedo`, `ph7`, `ph4`) en **NVS/Preferences** (namespace `suelo`).
- Registro en **LittleFS** → `/datos.csv`. Cabecera:

  `fecha_utc,epoch_s,hum_mv,hum_ind,ph_mv,ph,ph_present,lluvia,riego,agua,cobertura,notas,coincide,persistente`

- LittleFS se formatea **solo la primera vez** (marcado en NVS). Si luego falla, el firmware
  **no** lo formatea automáticamente, para no borrar datos. Exporta el CSV tras cada visita.

## Criterios provisionales (editables en el `.ino`)

- `HUM_ALERT_DELTA = 20.0` puntos de índice (demostrativo).
- `PH_ALERT_DELTA  = 1.0` unidad de pH (provisional; el plan no fija un umbral de pH).
- `persistente` = coincidencia en la sesión anterior con 18–30 h de separación.

Estos umbrales **no** son un diagnóstico de degradación y deben revisarse en el protocolo.

## Simulador local (probar el panel sin placa)

`tools/mock-server.ps1` es un servidor en PowerShell (sin dependencias externas)
que replica la misma API del firmware, sirve el mismo `dashboard.html` y permite
validar la lógica del panel en el navegador:

```
powershell -ExecutionPolicy Bypass -File tools\mock-server.ps1 [-Port 8080]
```

- **Panel** → `http://localhost:8080/`
- **Control del simulador** → `http://localhost:8080/mock` (fija los mV que
  "leen" GPIO34/35, genera 12 sesiones de ejemplo o borra todo).

Aplica exactamente los mismos cálculos que el `.ino` (índice de humedad, pH por
dos puntos, umbrales provisionales, coincidencia y persistencia 18–30 h), por lo
que sirve para recorrer los cinco casos de la sección «Validación del Dashboard»
del plan. Los datos se guardan en `tools/mock-data/` y sobreviven al reinicio del
simulador (equivalente a LittleFS). **No sustituye** las pruebas con la placa ni
la calibración física.

## Validación esperada (sin inventar datos)

- Humedad sin calibrar → el panel muestra mV, sin índice válido.
- pH sin calibrar o sonda ausente → `No evaluable`.
- Ambas calibradas y presentes → fila con datos evaluables y hora del teléfono.
- Apagar/encender → el CSV persiste; si falla el almacenamiento se informa error, no se simula guardado.
