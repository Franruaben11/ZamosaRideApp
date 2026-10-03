# ZamosaRide

<div align="center">

<img src="assets/branding/zamosaRide.png" width="112" alt="ZamosaRide">

# ZamosaRide

<em>Navigation and turn-by-turn routing for motorbikes</em>

<p>
  <a href="https://github.com/Franruaben11/ZamosaRideApp-valhalla1-openstreetmap/blob/main/LICENSE">
    <img src="https://img.shields.io/badge/Flutter-stable-02569B?logo=flutter&logoColor=white" alt="Flutter stable">
  </a>
  <a href="https://github.com/Franruaben11/ZamosaRideApp-valhalla1-openstreetmap/blob/main/LICENSE">
    <img src="https://img.shields.io/badge/licence-MIT-green" alt="MIT">
  </a>
</p>

</div>

## Description

ZamosaRide es una aplicación móvil desarrollada en Flutter diseñada para navegación GPS paso a paso en motos. El app calcula rutas optimizadas usando la **Google Routes API** y las muestra con **Google Maps SDK**, ofreciendo instrucciones de maniobra, seguimiento de posición y recálculo automático cuando el usuario se desvía del camino.

Está pensada para funcionar en conjunto con un ESP32-S3 (firmware `ZamosaRideFirmware`) que actúa como pantalla externa en la moto, mientras el teléfono procesa todo el cálculo de rutas, GPS y navegación.

## Características principales

- **Cálculo de rutas** con Google Routes API para distintos modos de viaje: `drive`, `two_wheeler`, `bike`, `walk`.
- **Modos de viaje con preferencias de tráfico**: `TRAFFIC_AWARE` para conducción motorizada.
- **Evitar peajes, highways y ferries** mediante `routeModifiers`.
- **Visualización de mapas** con Google Maps SDK y tiles vectoriales `vector_map_tiles`.
- **Pines y ubicaciones** con `google_maps_flutter` markers.
- **Navegación turn-by-turn** con motor `NavigationEngine` que lleva el seguimiento de la cámara, detección de desvíos y anuncios de maniobras.
- **Habla de instrucciones** mediante `flutter_tts`.
- **Recálculo automático** cuando el GPS indica que el usuario se fue de la ruta.
- **Compatible con Impeller**: operaciones pesadas (decodificación de geometrías) se realizan en isolates para no congelar el hilo principal.

## Stack tecnológico

- **Flutter** ^3.11
- **Dart** ^3.11
- **Google Maps SDK** (`google_maps_flutter`) para renderizado de mapas
- **Google Routes API** (`routing_service.dart`) para cálculo de rutas optimizadas
- **Paquetes clave**:
  - `google_maps_flutter`
  - `flutter_map` / `vector_map_tiles` / `vector_tile_renderer` (tiles vectoriales)
  - `geolocator` / `latlong2` (GPS y coordenadas)
  - `http` (cliente HTTP)
  - `flutter_polyline_points` (decodificación de polylines)
  - `flutter_compass` (dirección heading)
  - `share_plus`, `shared_preferences`, `url_launcher`, `wakelock_plus`

## Requisitos previos

- **Flutter SDK** ^3.11 instalado.
- **Cuenta de Google Cloud** con las APIs habilitadas:
  - Google Maps SDK for Android
  - Google Maps SDK for iOS
  - Google Routes API
- **Clave de API** de Google Maps (String alfanumérico).

## Instalación y ejecución local

Instala las dependencias:

```bash
flutter pub get
```

Ejecuta la inyectando la API Key desde la terminal (obligatorio):

```bash
flutter run --dart-define=GOOGLE_MAPS_API_KEY=tu_clave_aqui
```

> El valor `GOOGLE_MAPS_API_KEY` se inyecta como define de Dart y es leído por `main.dart` y `routing_service.dart` al instante. Esto evita tener la clave hardcodeada en el código fuente.

## Configuración nativa

### AndroidManifest.xml

El archivo `android/app/src/main/AndroidManifest.xml` ya incluye la inyección de la clave mediante variable de entorno:

```xml
<meta-data
    android:name="com.google.android.geo.API_KEY"
    android:value="${GOOGLE_MAPS_API_KEY}" />
```

> **Importante**: la misma variable `GOOGLE_MAPS_API_KEY` debe estar disponible en el entorno de compilación de Android. Cuando usas `flutter run --dart-define=GOOGLE_MAPS_API_KEY=...`, el complemento de Flutter la transfiere al proceso de compilación de Android automáticamente.

### build.gradle.kts

El proyecto usa:

```kotlin
plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.11.1" apply false
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
}
```

Asegurate de tener el **Google Services Gradle Plugin** configurado en `android/app/build.gradle` (generalmente agregado automáticamente por `flutter pub get` cuando se añaden dependencias de `google_maps_flutter`).

### iOS

En `ios/Runner.xcconfig` o `Podfile`, la clave también debe estar disponible. El valor inyectado con `--dart-define` se propaga automáticamente al generar el `GoogleMaps` bundle ID.

## Licencia

MIT. Ver `LICENSE.md` para detalles.
