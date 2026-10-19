# MEMORY.md — ZamosaRide

> Estado vivo del proyecto. Leer al empezar y actualizar al terminar cada tarea. Máximo ~50 líneas: resumir o borrar lo que ya no aporte. Las reglas permanentes van en `AGENTS.md`. Nunca guardar claves, tokens ni datos personales.

## Estado actual
- App Flutter con mapas del **Google Maps SDK** oficial y ruteo avanzado mediante **Google Routes API** (`computeRoutes`).
- Cámara (`CameraAnimator` / `GoogleMapFacade`) y renderizado de polilíneas/marcadores optimizados para delegar la interpolación al motor nativo de Google Maps (1 llamada por movimiento en lugar de 60–120 FPS por Platform Channel) y reutilizar geometrías en memoria.
- Integración con el ESP32-S3 (`ZamosaRideFirmware`) en etapa de diseño: el protocolo BLE + JSON está definido a nivel de principios, sin implementar.
- `AGENTS.md` condensado a ~100 líneas (reglas consolidadas, sin duplicados).

## Decisiones tomadas (con su porqué)
- **Thin client:** el teléfono procesa GPS, la lógica de navegación y las peticiones a la **Google Routes API**; el ESP32 solo dibuja la interfaz física. Así el firmware queda simple y toda la lógica centralizada vive en un solo lugar.
- **Animación de cámara nativa:** `CameraAnimator` delega la transición a `GoogleMapController.animateCamera(..., duration: ...)` con un contador de movimientos en vuelo (`_programmaticMovesInFlight`) y corte inmediato al tocar la pantalla (`Listener.onPointerDown`), evitando saturar el Platform Channel.
- **BLE + JSON:** tramas chicas con solo los campos necesarios.
- **Maniobras como strings** (`"left"`, `"right"`, `"u_turn"`), nunca IDs numéricos: facilita la depuración.
- **ESP32 -> App:** solo eventos de botones del manubrio; el firmware no interpreta qué hacen.
- **Frecuencia de envío: sin definir a propósito.** Se mide en la moto (fluidez vs. batería). Debe ser un único parámetro configurable. La fluidez visual se resuelve con animaciones en el ESP32 (LVGL), no subiendo la frecuencia.

## Pendiente
- Definir la ruta del esquema de mensajes y los UUID en el firmware y ponerla en `AGENTS.md` (reemplazar `<ruta>`).
- Definir heartbeat y timeout de conexión (sin valores asumidos todavía).
- Crear un `AGENTS.md` propio en `ZamosaRideFirmware` (LVGL, pantalla circular, build y flasheo).

## Errores a evitar
- Nunca invocar `GoogleMapController.animateCamera` desde un `AnimationController` por frame (60–120 Hz): cancela la animación nativa continuamente, satura el `MethodChannel` y rompe el seguimiento `heading-up`.
- No usar `print()` síncronos ni doble `notifyListeners()` en el ciclo de lectura GPS (`NavigationEngine._onPosition`).
