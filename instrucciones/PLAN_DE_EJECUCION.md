# PLAN DE EJECUCIÓN — Monitoreo de suelo de piña con ESP32 y Dashboard local

## 0. Alcance y estado real

**Objetivo:** monitoreo cuantitativo y descriptivo de un punto del suelo próximo a una planta de piña de Panamá Oeste. Variables originales: humedad, pH y temperatura del suelo. Se mantiene la observación estructurada para registrar lluvia, riego, cobertura y agua visible.

**Inventario confirmado por el equipo:** ESP32 DevKit V1 (30 pines), YL-69 + comparador LM393, electrodo pH E201 con conector BNC, MB102, una 18650 y su portabatería, tres resistencias de 220 Ω, una resistencia de 4.7 kΩ, protoboard y cables. **No se da por confirmada una sonda de temperatura del suelo.** El DHT22, aunque se comentó en una etapa previa, solo mide el ambiente y no reemplaza una sonda de suelo.

**Faltantes antes de operar de forma real:** acondicionador de señal pH con entrada BNC (compatible con E201, salida al ESP32 de máximo 3.3 V; ejemplo de especificación comprobable SEN0161-V2: suministro 3.3–5.5 V, salida 0–3 V), soluciones tampón pH 7 y pH 4 y solución de almacenamiento KCl; sonda DS18B20 impermeable para temperatura del suelo; circuito adecuado de carga/protección y elevación para la 18650; dos resistencias de 10 kΩ para divisor de YL-69 si su AO alcanza 3.3 V y por tanto satura el ADC del ESP32. Un microSD **no** es requerido.

**Advertencia de alimentación:** NO alimentar la entrada DC del MB102 directamente con la 18650 (3.0–4.2 V). La variante común del MB102 requiere 6.5–12 V por conector barril. Tampoco suponer que su conector USB-A es una entrada: en modelos habituales es una salida. Durante pruebas se puede usar MB102 con su propia fuente compatible, pero sin alimentaciones simultáneas incompatibles. Para la configuración portátil, es preferible: 18650 protegida → cargador 1S compatible (TP4056 con protección) → elevador 5.0 V → conector USB del ESP32. **No cargar la batería y utilizar la carga simultáneamente** con un TP4056 básico sin circuito power-path. Apagar el sistema durante la carga.

## 1. Arquitectura de datos: sin microSD y sin Internet

1. La placa ESP32 genera una Wi-Fi local llamada `Pina-Suelo-ESP32` (editar contraseña dentro de `.ino`).
2. El investigador conecta el teléfono o computadora a esa Wi-Fi y visita **http://192.168.4.1** con el navegador. No se requiere Internet.
3. El ESP32 lee el ADC de humedad (GPIO34) y de la interfaz pH (GPIO35) en el momento de la sesión. Los valores se calibran, validan y presentan en un Dashboard web totalmente local (HTML/CSS/JS embebido).
4. El investigador completa en el Dashboard la **ficha de observación estructurada** y confirma si el electrodo está en una muestra preparada y estabilizada.
5. El ESP32 guarda una nueva fila del registro `datos.csv` en su **memoria flash interna mediante LittleFS**. El teléfono suministra la fecha UTC, porque todavía no hay reloj RTC.
6. El Dashboard puede leer el historial, dibujar dos gráficas (humedad/pH) y exportar el CSV al teléfono.

**Elección tecnológica:** el enfoque local es más económico, consume menos datos y funciona sin infraestructura de Internet o cobertura móvil. No proporciona acceso desde otra ciudad ni datos en tiempo real cuando el ESP32 está apagado. Guardar a flash una vez por sesión es razonable para 28 días; aun así, exportar una copia del CSV después de cada visita es esencial. La flash no es un respaldo infalible ni reemplaza un sistema de archivos profesional.

## 2. Cableado — tabla componente | conexión (sin números de columna de protoboard)

| Componente | Conexión |
| --- | --- |
| Batería 18650 protegida | `+` y `-` → entrada B+ y B− del circuito cargador 1S conforme a su especificación. **NO** al MB102 por la entrada DC. |
| TP4056 protegido | Salida protegida `OUT+`/`OUT−` → convertidor elevador a 5.0 V regulados, mediante interruptor. No utilizar el circuito durante la carga con TP4056 básico. |
| Convertidor elevador 5 V | Salida de 5.0 V y GND → **conector USB adecuado** para alimentar el ESP32. Medir tensión antes de conectarlo. |
| MB102 | **En reserva para laboratorio**; si se usa, únicamente con la entrada DC compatible y sin conectarlo a la cadena portátil de batería. |
| ESP32 DevKit V1 | Alimentación por su USB de 5.0 V; pin `3V3` → riel positivo (3.3 V) protoboard, y `GND` → riel negativo. |
| YL-69 (sonda de humedad) | Dos terminales de la sonda → bornes del LM393. En el LM393: VCC → 3.3 V; GND → GND; AO → entrada analógica GPIO34. DO sin utilizar. |
| Divisor opcional de YL-69 (recomendado) | Si AO puede alcanzar 3.3 V, AO → resistencia 10 kΩ → GPIO34; otra resistencia 10 kΩ entre GPIO34 y GND. Así se evita sobrepasar el rango útil del ADC1. El software registra mV **ya divididos** y calibra el índice con esos mismos mV. |
| Electrodo E201-BNC | Conector BNC → entrada BNC del acondicionador de pH **compatible**. Nunca a un GPIO del ESP32. |
| Módulo de pH BNC compatible, tipo SEN0161-V2 | VCC → 3.3 V; GND → GND; salida `A` (0–3.0 V para ese modelo) → GPIO35 (ADC1). Si utilizan otro módulo, comprobar sus límites antes de conectar. |
| LED verde (si disponible) | GPIO14 → resistencia de 220 Ω → ánodo; cátodo → GND. Indica sesión sin señales entre las dos variables disponibles. |
| LED amarillo (si disponible) | GPIO27 → resistencia de 220 Ω → ánodo; cátodo → GND. Señala lectura incompleta o señal individual. |
| LED rojo (si disponible) | GPIO26 → resistencia de 220 Ω → ánodo; cátodo → GND. Coincidencia provisional repetida en dos sesiones separadas unas 24 horas. |
| Resistencia de 4.7 kΩ disponible | Se reserva para la línea de datos de un DS18B20 cuando se adquiera; **no** va entre el electrodo pH y el ESP32. |

Los GPIO34 y GPIO35 pertenecen a ADC1, que permite lecturas analógicas mientras se utiliza el Wi-Fi del ESP32. No se utilizarán señales de 5 V en los GPIO. El YL-69 resiste menos a la corrosión que un sensor capacitivo: apagar la placa después de la visita y evaluar un interruptor electrónico para su alimentación son mejoras recomendadas. **El hardware se debe montar y probar primero por secciones, no conectarlo todo a la vez.**

## 3. Nueva metodología de medición de pH con E201-BNC

### Por qué cambia

El electrodo E201-BNC que normalmente se emplea en soluciones acuosas requiere (a) circuito de acondicionamiento de alta impedancia; (b) calibración con soluciones tampón; y (c) contacto con un líquido apropiado. No se colocará de forma continua en el suelo ni se convertirá su voltaje directamente a pH mediante una escala arbitraria. El procedimiento es una **medición de pH en suspensión suelo-agua**, no una lectura continua de pH in situ.

### Protocolo de muestreo propuesto (alternativa de suelo fresco 1:2)

1. Delimitar la planta y el entorno radicular observado, con código `P01`. Mantener fija la ubicación y profundidad de la sonda de humedad. Para el pH, obtener pequeñas submuestras de la misma zona delimitada sin dañar raíces; registrar lugar, profundidad, fecha y tratamiento. No afirmar que representan toda la finca.
2. Utilizar un método de pH de **suelo fresco 1:2 (masa:volumen)**, consistente con protocolos de Michigan State University: pesar 15 g de suelo fresco tamizado y añadir 30 mL de agua desionizada en un recipiente limpio, agitar y dejar equilibrar al menos 30 minutos. Mantener el método constante en todas las sesiones. **Esta propuesta modifica la relación de extracción frente a antecedentes que usan 1:2.5 o 1:5: sus valores no deben compararse directamente sin considerar el procedimiento.**
3. Verificar el módulo pH y el E201 con soluciones tampón 7.00 y 4.00 (y su temperatura), haciendo calibración de dos puntos desde el Dashboard. Repetir la comprobación diariamente cuando haya sesión pH, especialmente después de transporte o almacenamiento del electrodo.
4. Enjuagar cuidadosamente el electrodo con agua desionizada, escurrir sin frotar la membrana de vidrio, introducirlo suavemente en la suspensión y esperar que la respuesta sea estable. Evitar golpes contra partículas gruesas y las paredes del recipiente.
5. Marcar la casilla “sonda en muestra preparada y estabilizada” en el Dashboard, pulsar “Vista previa” y comprobar el valor; luego guardar la sesión junto a humedad y las observaciones contextuales del día.
6. Enjuagar y guardar el electrodo en la solución de conservación recomendada por su fabricante, habitualmente KCl; **no almacenar la punta permanentemente en agua destilada ni en seco**. Mantener BNC y placa acondicionadora secos.

**Nota académica:** pH no equivale a degradación. Un valor ácido puede ser adecuado para la piña. El índice de humedad del YL-69 no expresa por sí mismo humedad volumétrica ni límites agronómicos y puede depender de la conductividad del suelo. Los criterios configurados son preliminares.

### Frecuencia de muestreo propuesta para 28 días

- Día 1: caracterizar el punto, calibrar YL-69 y E201; registrar humedad de referencia. En esa visita se puede registrar pH de línea base si se tiene muestra preparada, pero no se espera una alerta de humedad respecto al propio día inicial.
- Días 2–28: una sesión diaria de humedad y lista de cotejo, preferentemente a la misma hora.
- pH, con **visitas emparejadas en días consecutivos**: días **2–3, 9–10, 16–17, 23–24 y 27–28**. Este esquema propuesto limita la cantidad de pequeñas extracciones (10 sesiones) y permite estudiar si las dos variables disponibles coinciden en visitas separadas aproximadamente 24 horas.
- Una ausencia de pH en días intermedios se registra como **dato no evaluable**, nunca copiando el valor de una sesión anterior. Se consideran señales de las dos variables disponibles solamente en días con pH válido y humedad calibrada.
- La aplicación marca `coincidencia` cuando hay alerta de humedad y pH simultáneas; marca `persistente` si también la hubo en la sesión anterior y ambas sesiones están separadas entre 18 y 30 horas. Si se necesita estudiar tres variables, **antes** deberá añadirse y calibrarse una sonda de temperatura del suelo (p. ej. DS18B20 impermeable) y ampliar el software.
- La coincidencia de dos variables disponibles **no es validación integral de la hipótesis original de tres variables** ni prueba de degradación. El umbral de variación de 20 puntos en el índice de humedad es solo demostrativo: debe sustituirse por uno fundamentado antes del análisis formal.

## 4. Pasos de montaje y puesta en marcha

**Fase 1 — Seguridad eléctrica y alimentación**

1. Comprobar que la batería 18650 es una celda adecuada y protegida y que la polaridad del portabatería coincide. No soldar sobre una celda suelta ni crear paquetes multicelda improvisados.
2. Comprar y ensamblar cargador 1S protegido y elevador 5 V, aislados de humedad y alimentados a través de un interruptor. Ajustar el elevador a **5.0 V con multímetro** antes de conectar ESP32.
3. Alimentar el ESP32 por USB desde el elevador. De su `3V3` alimentar sensores de bajo consumo compatibles; utilizar GND común. No usar simultáneamente USB de PC y 5V del elevador. El MB102 queda reservado para pruebas con fuente independiente apropiada.

**Fase 2 — Medición eléctrica**

4. Conectar el YL-69 al LM393 y su AO al GPIO34, preferiblemente con divisor 10k+10k si la salida puede alcanzar 3.3 V. Verificar señales analógicas y el sentido de la escala con dos referencias locales (seco y húmedo).
5. Conectar el E201-BNC a su acondicionador, y la salida 0–3 V del acondicionador compatible al GPIO35. Medir primero en tampón pH 7, luego pH 4, y calibrar el sistema desde el panel. Si la lectura no se estabiliza, no registrar pH como válido.
6. Los LED son opcionales. Sin sensor de temperatura del suelo disponible, mostrar `No disponible` en el Dashboard.

**Fase 3 — Cargar el programa y abrir Dashboard**

7. En Arduino IDE instalar el paquete de tarjetas `esp32` de Espressif, elegir ESP32 Dev Module (o la variante exacta de la placa) y la partición de flash con LittleFS/SPIFFS. Abrir `ProyectoSueloESP32.ino` dentro de su carpeta, junto con `dashboard.h`.
8. Cambiar `WIFI_PASS` por una contraseña propia. Cargar el programa por USB del computador, sin la fuente externa conectada. La primera ejecución prepara LittleFS si todavía no existía; no activar `Erase All Flash` al actualizar el sketch en visitas posteriores.
9. Desconectar el USB del computador y usar la batería/convertidor. En el celular, abrir Wi-Fi → `Pina-Suelo-ESP32` → ingresar contraseña → abrir el navegador **http://192.168.4.1** (HTTP, no HTTPS). Si el teléfono advierte “sin Internet”, mantener esa red para acceder a la web local.

**Fase 4 — Captura y respaldo**

10. Antes de la primera sesión, guardar referencias de humedad seca/húmeda y pH 7/4 desde la pantalla `Calibración`.
11. Cada visita: preparar muestra pH cuando corresponda, marcar la casilla de pH solo si la sonda está realmente en suspensión, completar observación contextual y pulsar `Guardar sesión`.
12. Consultar historial y exportar CSV al teléfono para respaldo. Apagar la placa después de guardar; al volver a encender, los registros permanecen en LittleFS mientras no se borre el sistema de archivos.

## 5. Validación del Dashboard (sin inventar datos)

- **Caso 1**: humedad sin calibrar → el panel muestra mV, pero no índice válido ni señal de humedad.
- **Caso 2**: pH no calibrado o sonda no presente → el panel muestra `No evaluable`, no inventa pH.
- **Caso 3**: ambas variables calibradas y presentes → se genera una fila con datos evaluables, contexto y hora UTC del teléfono.
- **Caso 4**: dos señales simultáneas en una sesión → coincidencia preliminar. Si se repite dentro de 18–30 h según fecha aportada por el teléfono → episodio preliminar repetido. La lógica no convierte esto en diagnóstico de degradación.
- **Caso 5**: apagar y encender → el CSV persiste; abrir Dashboard y exportar. Si ocurre falla de almacenamiento, la aplicación informa error en lugar de simular un guardado.

## 6. Límites y mejoras

- La app funciona **localmente**. No se accede desde fuera de cobertura Wi-Fi ni hay almacenamiento en nube. La red AP requiere al ESP32 encendido, por lo que la autonomía continua con una 18650 es limitada; este diseño propone **encender solo durante las visitas**.
- No se dispone de microSD ni RTC. El teléfono aporta la hora; su reloj debe estar correcto, y las visitas deben registrarse de forma cronológica. El sistema no registra automáticamente cuando está apagado.
- No borrar la flash para actualizar código sin haber exportado los CSV. El desgaste de flash existe, aunque una escritura diaria sea de bajo volumen.
- El E201-BNC necesita acondicionador y soluciones de referencia; un conector BNC compatible no garantiza por sí solo que todos los módulos tengan el mismo comportamiento eléctrico. Evitar interfaz PH-4502C alimentada a 5 V con AO no verificada; la señal no debe superar 3.3 V en GPIO35.
- El YL-69 es resistivo: se corroe, y su lectura depende de sales/temperatura. Para seguimiento prolongado, reemplazar por una sonda capacitiva calibrable y usar alimentación conmutada.
- Los modelos actuales de ESP32 DevKit consumen considerablemente más que el chip solo; si se desea dejar encendido y alcanzar semanas, será necesario un esquema de Deep Sleep y sensor de temperatura con registro autónomo/RTC, alimentación eficiente y medición real de corriente.
- Los datos por sí solos no demuestran erosión o degradación y no representan toda la finca. La lista de cotejo es contexto, no causa demostrada.

## Fuentes técnicas públicas relevantes

- DFRobot: https://wiki.dfrobot.com/sen0161-v2 — acondicionador pH 3.3–5.5 V, salida 0–3 V, BNC.
- ESP32 ADC: https://docs.espressif.com/projects/arduino-esp32/en/latest/api/adc.html
- ESP32 Wi-Fi AP: https://docs.espressif.com/projects/arduino-esp32/en/latest/api/wifi.html
- Arduino ESP32 WebServer / LittleFS: https://github.com/espressif/arduino-esp32/blob/master/libraries/WebServer/examples/WebServer/README.md
- MSU Soil pH (1:2 suelo fresco): https://lter.kbs.msu.edu/protocols/163
- SunFounder MB102: https://www.sunfounder.com/products/mb102-breadboard-power-module
