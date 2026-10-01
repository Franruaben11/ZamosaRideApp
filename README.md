<p align="center">
  <img src="assets/branding/icon.svg" width="112" alt="ZamosaRide">
</p>
<h1 align="center">ZamosaRide</h1>
<p align="center"><em>Open maps, open data, no API keys.</em></p>
<p align="center">
  <a href="https://github.com/vivekmishra5699/ZamosaRide/actions/workflows/ci.yml"><img src="https://github.com/vivekmishra5699/ZamosaRide/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/Flutter-stable-02569B?logo=flutter&logoColor=white" alt="Flutter stable">
  <img src="https://img.shields.io/badge/licence-MIT-green" alt="MIT">
</p>

ZamosaRide is a maps and turn-by-turn navigation app built with Flutter on nothing
but open data and free public services. There is no account, no API key and no
telemetry: the basemap is rendered on the device from OpenStreetMap vector
tiles, places come from Overture Maps, routes from Valhalla, and everything
else from the OSM ecosystem.

## Features

- **Basemap rendered on device** from OpenFreeMap's `liberty` vector style, with
  denser labels and POIs than the stock style and a night re-grade for dark
  mode. Raster alternatives (Streets, OSM Classic, Satellite, Terrain, Cycling,
  Humanitarian) are a tap away.
- **Places** from Overture Maps, read straight out of the hosted PMTiles archive
  with HTTP range requests — no tile server in between.
- **Search and nearby**: Photon autocomplete, Nominatim reverse geocoding,
  category search ("Restaurants", "Cafés", "Fuel", …) through Overpass, hedged
  across three mirrors so one slow server doesn't stall the app.
- **Directions** for driving, two-wheelers, cycling and walking, with up to two
  alternatives and avoid-tolls / avoid-highways / avoid-ferries options.
- **Voice turn-by-turn navigation**: heading-up camera with speed-dependent
  zoom, spoken manoeuvres, the travelled part of the route greyed out, and
  automatic rerouting when you leave the route.
- **Place details** with weather (Open-Meteo) and a photo (Wikidata / Wikipedia
  via Wikimedia Commons), plus save and share.
- **Settings** for units, theme, voice guidance and the map render mode.

## Data and services

| | Source | Licence / terms |
| --- | --- | --- |
| Basemap tiles + style | [OpenFreeMap](https://openfreemap.org) (`liberty`, OpenMapTiles schema) | ODbL (OSM data), OpenMapTiles BSD/CC-BY |
| Places | [Overture Maps](https://overturemaps.org) `places` PMTiles | CDLA-Permissive-2.0 |
| Raster basemaps | CARTO, OSM, Esri, OpenTopoMap, CyclOSM, HOT | Free with attribution |
| Search | [Photon](https://photon.komoot.io) (autocomplete), [Nominatim](https://nominatim.org) (reverse) | OSM usage policies |
| Nearby | [Overpass API](https://overpass-api.de) (+ Kumi Systems, mail.ru mirrors) | OSM usage policies |
| Routing | [Valhalla](https://valhalla1.openstreetmap.de) hosted by FOSSGIS | Fair use |
| Weather | [Open-Meteo](https://open-meteo.com) | CC-BY 4.0 |
| Photos | Wikidata P18 / Wikipedia GeoSearch via Wikimedia Commons | Per-file licences |

All of these are shared public services. Before publishing a build, put a real
contact URL or e-mail in the `User-Agent` in `lib/services/api_client.dart` —
Wikimedia, Nominatim and Overpass require one — and read each service's usage
policy. `LICENSE` lists the data and service licences alongside the MIT licence
for the app code.

## Getting started

Requirements: Flutter stable (Dart SDK `^3.11`) and, for a device build, the
Android SDK. Android is the primary and tested target; the iOS, macOS and web
project folders are present but not exercised.

```sh
git clone git@github.com:vivekmishra5699/ZamosaRide.git
cd ZamosaRide
flutter pub get
flutter run                      # debug build on a connected device
flutter build apk --release      # release APK (signed with the debug key until you add a signingConfig)
```

Developer flags, all optional and passed with `--dart-define`:

| Flag | Effect | Example |
| --- | --- | --- |
| `OM_CENTER` | Start the camera here instead of the last saved view | `OM_CENTER=17.3616,78.4747` |
| `OM_ZOOM` | Start zoom (with `OM_CENTER`) | `OM_ZOOM=15.3` |
| `OM_QUALITY` | Force a render mode: `quality`, `smooth`, `foveated` | `OM_QUALITY=foveated` |
| `OM_FRAMESTATS` | Log UI/raster frame times every 2 s | `OM_FRAMESTATS=true` |
| `OM_TILESTATS` | Log per-tile fetch/parse/render times and bitmap-cache hits | `OM_TILESTATS=true` |
| `OM_RASTER_CACHE` | `0` disables the in-memory tile bitmap cache (A/B runs) | `OM_RASTER_CACHE=0` |

In zsh, pass several defines as an array (`D=(--dart-define=A=1 --dart-define=B=2); flutter run "${D[@]}"`);
an unquoted `$D` string is passed as one mangled define.

## How the map is drawn

Vector tiles on Flutter are hard to keep smooth: Impeller re-tessellates every
path on every frame and has no raster cache, so a live vector basemap costs
9–30 ms of GPU time per frame on a mid-range phone. ZamosaRide's default
**Smooth** mode follows the OsmAnd/OpenGL architecture instead:

- Tile geometry is parsed in isolates and painted **once** to a GPU-resident
  bitmap at the device's pixel ratio; the GPU scales those bitmaps during
  gestures, so pinching and rotating stay at full frame rate.
- Labels are drawn **live** as a separate symbols-only layer, so they stay
  upright when the map rotates and are never scaled or blurred.
- Rendered bitmaps are kept in a byte-budgeted cache so zooming out and back in
  shows the map immediately, and render jobs for levels the map has left are
  parked instead of drawn.
- Two upstream packages are vendored with small, documented patches:
  [`packages/vector_map_tiles`](packages/vector_map_tiles/PATCHES.md) (the tile
  pipeline) and [`packages/vector_tile_renderer`](packages/vector_tile_renderer/PATCHES.md)
  (text halos, which must not be blurred under Impeller).

**Sharp** (live vector, crispest at fractional zooms) and **Focus** (live vector
in the centre of the screen, bitmaps around it) are available in Settings.
The measurements behind these choices, and how MapLibre, Organic Maps and
OsmAnd solve the same problems, are in
[docs/map-rendering-performance.md](docs/map-rendering-performance.md).

## International boundaries

ZamosaRide is distributed in India, where maps must show the country's external
boundaries as the Government of India depicts them: the whole of Jammu &
Kashmir, Ladakh (with Aksai Chin and the Trans-Karakoram tract) and Arunachal
Pradesh inside India, and no Line of Control, Line of Actual Control or rival
claim lines drawn as boundaries.

OpenStreetMap maps the de-facto lines and tags them (`disputed`, `claimed_by`,
`disputed_name`), but it does not contain India's claimed outline as a line,
and the Natural Earth data OpenMapTiles uses below zoom 5 has no claim tags at
all. So [`lib/services/boundary_policy.dart`](lib/services/boundary_policy.dart)
works geometrically. India's outline through the two affected sectors — from
the Punjab border round Kashmir, Aksai Chin and down the Tibet border to
Nepal, and the McMahon line — is embedded from Natural Earth's public-domain
*India point of view* dataset
([`lib/services/india_boundary_data.dart`](lib/services/india_boundary_data.dart),
generated by [`tool/india_boundary_data.dart`](tool/india_boundary_data.dart)).
As each tile is decoded, disputed and de-facto lines inside or along that
outline are dropped, India's own claim lines become ordinary boundaries, and
the outline is drawn as an international boundary wherever OpenStreetMap does
not already have one running along it (its more precise geometry is kept where
it exists, and the drawn stretches are joined to it). The `state` labels of
Pakistan's units in the area are not drawn. Boundaries elsewhere in the world
are left exactly as OpenStreetMap maps them.

The rule runs on the tile data in the decoding isolates, so it holds in every
render mode and costs a few milliseconds per tile; the raster alternatives
(OSM Classic, CARTO, …) are third-party images and show their own boundaries.
`test/boundary_policy_test.dart` covers the rules, and
`test/boundary_policy_realdata_test.dart` checks them against real tiles over
Kashmir, Aksai Chin and Arunachal Pradesh; `test/boundary_render_tool_test.dart`
renders any directory of tiles before and after the rule for a visual check.

## Project layout

```
lib/
  main.dart                    app shell, theme, dev-only frame logger
  models/                      Place, NavRoute, Weather (no Flutter imports)
  services/                    HTTP clients (routing, geocoding, Overpass, weather,
                               photos, PMTiles), settings, storage, style transforms
  navigation/                  NavigationEngine (GPS → guidance, rerouting) and Speaker (TTS)
  screens/                     MapScreen, SearchPage, SettingsPage
  screens/map/                 CameraAnimator, LocationController
  widgets/                     map layers, basemap wiring, panels, overlays, controls
  ui/                          icon mappings (the only place models meet Icons)
  util/                        geo maths, formatting, units, constants
packages/vector_map_tiles/     vendored tile pipeline (see PATCHES.md)
packages/vector_tile_renderer/ vendored renderer (see PATCHES.md)
docs/                          performance research
test/                          unit tests and fixtures (Valhalla response, liberty style,
                               boundary tiles)
```

## Development

```sh
dart format --set-exit-if-changed lib test
flutter analyze --fatal-infos
flutter test
```

The same three commands run in CI (`.github/workflows/ci.yml`) on every push
and pull request. Device performance work — scripted pinch and zoom runs,
frame and tile timing logs, memory sampling — is described in the
performance doc above.

## Licence

MIT for the app code — see [`LICENSE`](LICENSE), which also lists the data
and service licences the app depends on. Map data © OpenStreetMap
contributors (ODbL); places © Overture Maps Foundation.
