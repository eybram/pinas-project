# pinas-project

Proyecto para proteger las piñas: monitoreo local del suelo con ESP32.

Sistema de monitoreo **sin Internet** para un punto de suelo próximo a una planta de piña
(Panamá Oeste). El ESP32 crea su propia red Wi-Fi y sirve un panel web local; los datos se
guardan en la memoria flash del microcontrolador. No requiere microSD, RTC ni servicios en la nube.

## Qué incluye

- **Firmware ESP32** (`build/ProyectoSueloESP32/`): red AP `Pina-Suelo-ESP32`, servidor web,
  calibración en NVS y registro CSV en LittleFS.
- **Panel web** (`dashboard.html` / `dashboard.h`): humedad (YL-69), pH (E201 + acondicionador)
  y ficha de observación. No inventa lecturas: sin calibración muestra `No evaluable`.
- **Simulador local** (`build/tools/mock-server.ps1`): replica la API del firmware para probar
  el panel sin hardware.
- **Documentación** (`instrucciones/`): plan de ejecución, instalación y cableado.

## Estructura

```
.
├─ build/
│  ├─ ProyectoSueloESP32/     Proyecto Arduino IDE (abrir esta carpeta)
│  │  ├─ ProyectoSueloESP32.ino
│  │  ├─ dashboard.h          Panel embebido (generado)
│  │  └─ dashboard.html       Fuente editable del panel
│  ├─ tools/
│  │  ├─ make_dashboard_h.ps1 Regenera dashboard.h desde el HTML
│  │  ├─ mock-server.ps1      Simulador local del ESP32
│  │  └─ mock-control.html    Control del simulador
│  └─ README.md               Detalle del build
└─ instrucciones/
   ├─ PLAN_DE_EJECUCION.md
   ├─ README_INSTALACION.md
   └─ dashboard.html          Plantilla original
```

## Inicio rápido (hardware)

1. Instala el núcleo `esp32` de Espressif en Arduino IDE.
2. Abre `build/ProyectoSueloESP32/ProyectoSueloESP32.ino`.
3. Cambia `WIFI_PASS` por una contraseña propia (8+ caracteres).
4. Sube por USB y luego alimenta con 5 V regulados.
5. Conéctate a `Pina-Suelo-ESP32` y abre **http://192.168.4.1**.

## Probar sin hardware (simulador)

```
powershell -ExecutionPolicy Bypass -File build\tools\mock-server.ps1
```

- Panel → `http://localhost:8080/`
- Control del simulador → `http://localhost:8080/mock`

Sirve para recorrer los cinco casos de validación del plan (humedad sin calibrar, pH no
evaluable, ambas variables válidas, coincidencia/persistencia y persistencia tras reinicio).

## Documentación

- [Plan de ejecución](instrucciones/PLAN_DE_EJECUCION.md)
- [Instalación rápida](instrucciones/README_INSTALACION.md)
- [Detalle del build y API](build/README.md)

## Alcance y límites

- Funciona solo en la red local del ESP32; no hay acceso remoto ni almacenamiento en nube.
- No hay sensor de temperatura del suelo ni RTC: la hora la aporta el teléfono.
- Los umbrales de alerta son **provisionales/demostrativos** y no constituyen un diagnóstico
  de degradación ni representan toda la finca.
- Exporta una copia del CSV después de cada visita: la flash no es un respaldo infalible.
