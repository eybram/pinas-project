# Instalación rápida: ESP32 + Dashboard local

Este paquete contiene un **proyecto Arduino IDE** en `ProyectoSueloESP32/` con firmware, `dashboard.h` (interfaz web embebida) y `dashboard.html` (fuente editable del panel), más el plan técnico detallado.

## Requisitos para usar las mediciones

- ESP32 DevKit V1 de 30 pines.
- YL-69 + LM393 alimentado a 3.3 V, AO al GPIO34 (divisor 10k+10k si AO alcanza >3.1 V).
- E201-BNC **más acondicionador para electrodo pH con entrada BNC** y salida compatible 0-3 V, AO al GPIO35. El E201 por sí solo NO se puede conectar al ESP32.
- Dos soluciones tampón 7 y 4, agua desionizada y solución apropiada para almacenar la sonda.
- 18650 protegida + cargador 1S + elevador 5V + cable USB, o USB de la computadora para comenzar. El MB102 no funciona directamente con una sola 18650 sin conversión.
- No se dispone aún de temperatura del suelo: el tablero indica `No disponible`.

## Arduino IDE

1. Instala el núcleo `esp32` de Espressif en Arduino IDE.
2. Abre la carpeta `ProyectoSueloESP32` y el archivo homónimo `.ino`. **Conserva `dashboard.h` junto al `.ino`**.
3. Herramientas: selecciona `ESP32 Dev Module`, puerto serial correcto y una partición de flash que incluya sistema de archivos (LittleFS/SPIFFS). No hay bibliotecas externas obligatorias: WiFi, WebServer, Preferences y LittleFS vienen con Arduino-ESP32.
4. Cambia `WIFI_PASS` del código por una contraseña propia (8 caracteres o más), guarda y sube a la placa mediante USB de la computadora.
5. Tras cargar, desconecta el USB de la computadora y alimenta con una fuente USB de 5 V bien regulados. No utilices dos fuentes simultáneamente.
6. En el celular, conecta a la red `Pina-Suelo-ESP32` y visita `http://192.168.4.1`.
7. Haz calibración, una vista previa y una sesión de prueba; verifica el historial y descarga el CSV.

## Importante sobre LittleFS

La primera ejecución prepara el sistema de archivos si nunca se usó, marcándolo en NVS. Si LittleFS falla posteriormente, el firmware **no lo formatea de nuevo automáticamente**, para evitar borrar datos. No selecciones `Erase All Flash` después de iniciar el estudio y descarga una copia CSV tras cada sesión.

## Qué ofrece la aplicación

- Dashboard responsive desde el navegador del teléfono o laptop, **sin Internet**.
- pH condicionado por la casilla “electrodo en muestra” y calibración en 7.00 / 4.00.
- Humedad con salida en mV e índice local de 0-100 después de calibración (no equivale a humedad volumétrica real).
- Ficha de lluvia, riego, agua acumulada, cobertura y notas.
- Registro en LittleFS CSV, gráficas y exportación al teléfono.
- Detección de coincidencias de pH + humedad y repetición entre sesiones separadas 18–30 h, solo como indicador **experimental/provisional**.

## Funciones expresamente no implementadas

- No hay sensor de temperatura del suelo, porque no está en el inventario confirmado.
- No hay publicación remota en Internet ni sincronización con servicios externos.
- No hay adquisición automática cuando el equipo está apagado, ni fecha autónoma (no hay RTC).
- No hay calibración agronómica validada del YL-69 ni prueba de degradación.
- No hay funcionamiento con una 18650 conectada directamente al MB102.

Consulta `PLAN_DE_EJECUCION.md` para metodología, seguridad, cableado y cronograma.
