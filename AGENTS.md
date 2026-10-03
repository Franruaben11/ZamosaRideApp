# AGENTS.md — ZamosaRide

## Propósito

ZamosaRide es una app móvil de navegación GPS paso a paso para motos, basada en tecnologías open-source y pensada para funcionar con mapas vectoriales locales/offline. Está previsto que se comunique con un ESP32-S3 (firmware `ZamosaRideFirmware`) que actúa como pantalla externa en la moto.

Desarrollar y mantener el proyecto de forma incremental, respetando la arquitectura existente.

## Stack

- Flutter, Dart SDK `^3.11`.
- Mapas y Ruteo: Google Maps SDK oficial para renderizado de mapas y Google Routes API (`computeRoutes`) para el cálculo de trayectos optimizados y navegación en tiempo real.
- Hardware: ESP32-S3 Waveshare 1,75" (466 × 466 px, QSPI).
- El firmware está en la carpeta hermana `../ZamosaRideFirmware`; se puede leer para verificar el protocolo.

No introducir wrappers comerciales (Mapbox, etc.) ni reemplazar el stack sin autorización.

## Estructura

- `lib/services/`: Conexiones a APIs externas (como el cliente de la API de Google Routes).
- `lib/navigation/`: Motor de navegación (`NavigationEngine`) y lógica de recálculo de rutas.
- `assets/`: recursos, incluidos los JSON de estilos del mapa.
- `packages/`: librerías internas parcheadas.

Antes de crear carpetas, clases o capas nuevas, seguir las convenciones existentes.

## Comandos

```bash
flutter pub get              # instalar dependencias
flutter run                  # ejecutar
flutter analyze              # análisis estático
flutter test                 # pruebas
flutter build apk --release  # APK de release
```

## Convenciones

- Código (clases, variables, métodos, archivos) en inglés, siguiendo las convenciones de Dart.
- Comentarios, documentación, explicaciones y mensajes de commit en español.
- UI minimalista y legible durante la conducción. En la vista de navegación, no mostrar puntos de interés que no ayuden a conducir.
- Sin lógica de negocio dentro de los widgets cuando pueda vivir en servicios o componentes.
- Mantener separadas la interfaz, la lógica de navegación, el acceso a datos y la conectividad.

## Reglas de dominio

**Mapas y Arquitectura**
- Mantener las operaciones pesadas (como el procesamiento y decodificación de geometrías de rutas) en isolates para no congelar el hilo principal y garantizar fluidez gráfica (compatible con Impeller).
- Distinguir datos locales de los que requieren internet; no afirmar que algo funciona offline si depende de servicios remotos como la Google Routes API.
- Ante errores de red, timeouts o respuestas inválidas de la API, fallar de forma controlada y dejar la app en un estado coherente.

**Navegación y GPS**
- Preservar el seguimiento de cámara, incluido el modo heading-up.
- Tratar la señal GPS ausente o imprecisa como un estado posible: sin bloqueos, saltos injustificados ni recálculos repetitivos.
- No inventar maniobras, distancias ni rutas que el servicio de Google no haya devuelto.

## Comunicación App <-> ESP32 (BLE + JSON)

- El teléfono procesa todo (GPS, Routes API, recálculos). El ESP32 solo dibuja y reporta botones.
- App -> ESP32: estados listos para mostrar (distancia, velocidad, próxima maniobra). Tramas JSON chicas, solo con los campos necesarios.
- Maniobras siempre como string legible (`"left"`, `"right"`, `"u_turn"`), nunca IDs numéricos.
- ESP32 -> App: solo eventos de botones del manubrio (ej. `{"button":"ok"}`). El firmware no interpreta su efecto.
- El esquema de campos y los UUID están en `../ZamosaRideFirmware/<ruta>`, que es la fuente de verdad. Revisarlo antes de tocar el protocolo y no asumir nombres de campos, UUID ni comportamiento no definidos.
- La comunicación debe estar desacoplada de la UI y no bloquear el hilo principal.
- Frecuencia de envío: **por definir** (se ajustará midiendo fluidez vs. batería en la moto). No fijar valores definitivos.
  - El intervalo debe ser un único parámetro configurable, no valores dispersos por el código.
  - El firmware no debe asumir un ritmo fijo de llegada; la fluidez visual se resuelve con animaciones en el ESP32, no subiendo la frecuencia.


## Forma de trabajo

**Plan primero.** Antes de cambios que afecten arquitectura, motor de navegación, renderizado, cámara GPS, dependencias o comunicación con el hardware:
1. Inspeccionar los archivos y el flujo actual.
2. Explicar el problema y la causa probable, distinguiendo hechos de hipótesis.
3. Proponer un plan paso a paso, con los archivos a modificar y los riesgos previstos.
4. Describir cómo se verificará el resultado.
5. Esperar confirmación antes de ejecutar.

Las correcciones pequeñas y localizadas con alcance claro se pueden hacer directamente.

**Implementación.** Cambios pequeños y enfocados. No reemplazar implementaciones existentes sin entender por qué están así. Si falta información que pueda afectar la arquitectura, preguntar antes de asumir. Al terminar, explicar en español qué se cambió, por qué y qué debería observar el usuario.

## Requiere autorización explícita

- Agregar, quitar o actualizar dependencias en `pubspec.yaml` (incluidas las de BLE).
- Modificar `packages/` o eliminar parches de compatibilidad con Impeller.
- Reescribir la cámara GPS o cambiar `heading-up`.
- Cambiar los identificadores o la estructura de capas de los JSON de estilo.
- Modificar de forma amplia el motor de navegación o el recálculo de rutas.
- Cambiar proveedores, servicios o formatos de datos cartográficos.
- Implementar o alterar la comunicación BLE con el ESP32-S3.
- Refactorizaciones amplias, cambios en varios módulos o cambios destructivos.

## Verificación

Antes de dar una tarea por terminada, ejecutar `flutter analyze` y `flutter test` cuando correspondan, y comprobar que la app compile en Android si el entorno lo permite. Según el alcance:
- Mapas o ruteo: que no se rompa el seguimiento fluido de la cámara ni `heading-up`.
- GPS: comportamiento con señal ausente, imprecisa o intermitente.
- Servicios remotos: errores, timeouts y respuestas inválidas.
- Hardware: que las esperas no bloqueen la UI.

No afirmar que algo se probó o funciona si no se verificó; indicar qué quedó pendiente.
Actualiza `MEMORY.md` al terminar cada tarea
