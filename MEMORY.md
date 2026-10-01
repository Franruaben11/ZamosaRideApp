# MEMORY.md — ZamosaRide

> Estado vivo del proyecto. Leer al empezar y actualizar al terminar cada tarea. Máximo ~50 líneas: resumir o borrar lo que ya no aporte. Las reglas permanentes van en `AGENTS.md`. Nunca guardar claves, tokens ni datos personales.

## Estado actual
- App Flutter con mapa vectorial OSM, ruteo con Valhalla, lugares con Overture Maps y autocompletado con Photon.
- Integración con el ESP32-S3 (`ZamosaRideFirmware`) en etapa de diseño: el protocolo BLE + JSON está definido a nivel de principios, sin implementar.
- `AGENTS.md` condensado a ~100 líneas (reglas consolidadas, sin duplicados).

## Decisiones tomadas (con su porqué)
- **Thin client:** el teléfono procesa GPS, Valhalla y toda la lógica; el ESP32 solo dibuja. Así el firmware queda simple y la lógica vive en un solo lugar.
- **BLE + JSON:** tramas chicas con solo los campos necesarios.
- **Maniobras como strings** (`"left"`, `"right"`, `"u_turn"`), nunca IDs numéricos: facilita la depuración.
- **ESP32 -> App:** solo eventos de botones del manubrio; el firmware no interpreta qué hacen.
- **Frecuencia de envío: sin definir a propósito.** Se mide en la moto (fluidez vs. batería). Debe ser un único parámetro configurable. La fluidez visual se resuelve con animaciones en el ESP32 (LVGL), no subiendo la frecuencia.

## Pendiente
- Definir la ruta del esquema de mensajes y los UUID en el firmware y ponerla en `AGENTS.md` (reemplazar `<ruta>`).
- Definir heartbeat y timeout de conexión (sin valores asumidos todavía).
- Aclarar si Valhalla y Photon corren local o remoto y cómo levantarlos.
- Crear un `AGENTS.md` propio en `ZamosaRideFirmware` (LVGL, pantalla circular, build y flasheo).

## Errores a evitar
- (vacío por ahora)
