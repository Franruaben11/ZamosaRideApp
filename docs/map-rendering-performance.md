# Map rendering performance: research, measurements and plan

**Date:** 2026-08-28
**Device under test:** OnePlus CPH2491 (Snapdragon 695, 8 GB RAM, 1240×2772 @ dpr 3), profile builds driven over adb.
**Subject:** why zooming in ZamosaRide felt laggy and why tiles took seconds to sharpen, how the fast open-source map engines avoid both, and what we can realistically adopt.

---

## 1. The problem, as reported

Three distinct complaints, which turned out to have three different causes:

1. **"Zoom in and out while navigating lags, then crashes."** — two bugs: a NaN camera from flutter_map's fling, and live vector rendering during a camera that moves every frame.
2. **"Tiles take way too long to load."** — a PNG encode on the critical path, plus re-parsing the same source tile once per overzoomed fragment.
3. **"It's a mess for a few seconds."** — labels baked into rotated bitmaps, and no retention of the previous zoom level while the new one renders.

---

## 2. What we measured on device

Frame timings come from a dev-only `SchedulerBinding.addTimingsCallback` logger
(`--dart-define=OM_FRAMESTATS=true`, see `lib/main.dart`). Tile timings come from
`--dart-define=OM_TILESTATS=true` (see `packages/vector_map_tiles/lib/src/raster/tile_loader.dart`
and `.../cache/vector_tile_loading_cache.dart`).

### 2.1 Frame times during a scripted pinch

Pinches were injected as real two-finger gestures with `adb shell monkey -f` scripts
(`sendevent` is SELinux-denied to the shell user, so monkey's `PinchZoom` is the only
way to script true multi-touch).

| Scenario | UI thread | Raster thread | Frames over budget |
|---|---|---|---|
| Browse, live vector (`quality`) | 1–3 ms | avg 9–13 ms, p90 14–16 ms | 10–22 % |
| Browse, pre-rendered (`smooth`) | 1 ms | avg 2 ms, p90 2–5 ms | 0–3 % |
| Navigation + pinch, live vector | 5–6 ms | **avg 26–29 ms, p90 38–45 ms** | **75–95 %** |
| Navigation + pinch, pre-rendered | 1 ms | 2–3 ms | **0 %** |

The UI thread was never the problem. The cost is entirely on the raster thread.

### 2.2 Tile latency, per phase

| Phase | Before | After |
|---|---|---|
| Vector data fetch + parse | 72 ms median | — |
| Vector tile **parse** alone | 154 ms median, p90 512 ms | **34 ms** median, p90 263 ms |
| Render to canvas | 2 ms | 1 ms |
| `Picture.toImage` | 11 ms | 15–23 ms |
| **PNG encode + disk write** | **347 ms median, p90 545 ms** | **removed** |
| **Total per tile** | **464 ms median, p90 924 ms, max 4956 ms** | **116 ms median** |

The PNG write was on the critical path — the tile was withheld until it completed,
capping throughput at roughly 10 tiles/second. That is the "10–15 seconds to go from
smooth zoomed-out to clean sharp street".

### 2.3 Memory during sustained pinching in navigation

| | Before | After |
|---|---|---|
| PSS after 1 round | 1.0 GB | 297 MB |
| PSS after 2 rounds | 1.8 GB | 297 MB |
| PSS after 3 rounds | dead (ANR, ~4.4 GB) | 300 MB |
| 8 rounds (96 pinches) | never reached | 284–300 MB, 0 ANRs |

---

## 3. Root cause: immediate mode vs retained mode

Our renderer (`vector_tile_renderer`) **does** cache `ui.Path` objects per tile —
`TileFeature._paths` is built lazily and reused across frames, and the UI preprocessor
can pre-warm it (`initializeGeometry: true`). So path *construction* is not the issue.

The issue is what Flutter does with those paths. From the Flutter engine issue tracker:

> Impeller tessellates every path synchronously on the CPU, and then hauls all of the
> decompressed geometry to the GPU via vertex buffers.

Every frame. On the raster thread. That is the 9–30 ms.

Worse, **Impeller disables the layer/picture raster cache entirely** — verified in engine source:

```cpp
// shell/gpu/gpu_surface_metal_impeller.mm, gpu_surface_vulkan_impeller.cc,
// gpu_surface_gl_impeller.cc — all three:
bool GPUSurface*Impeller::EnableRasterCache() const { return false; }
```

Impeller is the only renderer on iOS and the default on Android API 29+. So
`RepaintBoundary` buys us paint-phase isolation but **no cached texture**. Any advice of
the form "wrap the tile in a RepaintBoundary" is dead on modern Flutter.

The sanctioned escape hatch is `Picture.toImageSync`, which per the dart:ui docs creates an
image that is *"GPU resident and not copied back to the host"*. That is exactly what our
pre-rendered ("smooth") mode does, and why its raster time is 2–3 ms.

---

## 4. How the fast engines actually work

### 4.1 MapLibre / Mapbox GL — amortize per tile, pay a matrix per frame

**Once per tile, on a worker thread** (`WorkerTile.parse()`): geometry is tessellated into
typed-array vertex/index buffers ("buckets"), glyphs are packed into an atlas, symbol layout
runs. Then it is uploaded to the GPU **once**, guarded by an `uploaded` flag. Vertices are
`Int16` in tile-local coordinates with `EXTENT = 8192` — deliberately zoom-independent.

**Per frame:** bind a program, call `drawElements`. All zoom dependence lives in one matrix
and a handful of scalars. The tile matrix is `translate(tileOrigin·s) · scale(s/EXTENT)`
where `s = 512·2^zoom / 2^z` with *fractional* zoom. Line widths stay in screen pixels via a
single float uniform (`u_ratio`); text size via `u_size` / `u_size_t`.

A z14 tile displays unchanged from zoom 14.0 through 14.999 — up to 2× magnification, free.
The render loop only runs when dirty; a stationary map renders zero frames.

Neat detail: for data-driven *and* zoom-dependent paint properties, the worker bakes
`evaluate(zoom)` **and** `evaluate(zoom+1)` into two vertex attributes, and the shader
`mix()`es between them per frame. No buffer re-upload during a zoom at all.

**Labels.** Glyph quad corners are stored as offsets from the anchor **in screen space**
(1/32-px fixed point), and the shader adds them *after* projection:

```glsl
finalPos = u_coord_matrix * vec4(projected_pos.xy / projected_pos.w
         + rotation_matrix * (a_offset / 32.0 * fontScale + a_pxoffset), z, 1.0);
```

So labels are screen-axis-aligned **by construction** — rotating the map costs zero CPU for
point labels.

**Placement does not run per frame.** It restarts at most once per `fadeDuration` (300 ms
default), and when it runs it is spread across frames with a **2 ms/frame budget**
("we can keep rendering with a partial placement, we'll resume on the next frame").
Fading is a single uniform (`u_fade_change`); only the opacity attribute buffer is rewritten,
never geometry. A `CrossTileSymbolIndex` gives each conceptual label a stable ID across zoom
levels so labels don't re-fade when the pyramid switches.

**Never blank.** For a tile without data: retain loaded children up to 3 levels down, else
walk *up* to 10 levels for the first loaded ancestor. Different-zoom tiles are composited
with an 8-bit stencil buffer.

Two corrections to widely-repeated folklore, verified in source:
- `prefetch-zoom-delta` (default 4) exists **only in MapLibre Native**, not in the JS engines.
- **Vector tiles do not fade in.** Fading applies only to raster layers and to symbols;
  fills and lines pop in instantly.

Selected constants (read from `main`, 2026-08-28):

| Quantity | MapLibre GL JS | MapLibre Native |
|---|---|---|
| `EXTENT` / tile size | 8192 / 512 | 8192 / 512 |
| Symbol fade duration | 300 ms (0 until first `idle`) | 300 ms |
| Placement budget | 2 ms/frame | pauseable |
| Placement restart throttle | ≥ `fadeDuration` since commit | same |
| Parent search depth | 10 levels | to `zoomRange.min` |
| Child search depth | 3 levels | 1 generation |
| Prefetch zoom delta | not implemented | **4** |
| Collision padding / grid cell | 100 px / 25 px | same |
| Glyph SDF border / atlas padding | 3 px / 1 px | 3 / 1 |
| Default workers | 1 (Chromium/FF) | 3 |

### 4.2 Organic Maps (Drape) — move the work to build time

Organic Maps is fast on cheap hardware because **the expensive work happens when the map
file is built, not on the phone.**

The `.mwm` format ships geometry **pre-simplified at 4 LODs and pre-triangulated**. The
generator runs a near-optimal Douglas-Peucker (`SimplifyNearOptimal`) per level and
`TesselateInterior`, writing triangles into `trg0..trg3`. At runtime `ForEachTriangle` only
decodes and pushes vertices — **there is no tessellation on the device at all.**

Contrast with Mapbox Vector Tiles, which ship polygon *rings* and require every client to
tessellate them, every time.

LOD layout (country files): `{10, 12, 14, 17}` — so z15–17 all read `geom3`/`trg3`. Each LOD
is also quantized more coarsely (24/25/26/27 coordinate bits), and a coarser LOD is dropped
entirely unless it is meaningfully smaller. The z17 level uses a **0.4 px** simplification
tolerance versus 1.3 px elsewhere, specifically so it survives overzoom to z20. The tile grid
stops subdividing at z17 (`ClipTileZoomByMaxDataZoom`) while style rules keep resolving to z20.

Storage is a flat tagged-section archive per country, indexed by a Morton/Z-order interval
index, with features physically sorted by `(min-visible-zoom, morton)`. Files are **not**
mmap'd — reads go through a 1 KiB × 4096 page LRU (4 MiB per file).

**Per frame during a pinch, Drape touches nothing but the model-view matrix.** Vertices live
in GPU buffers in tile-local coordinates (scaled by 1000 for float32 precision); the
projection is pixel-space orthographic. Line half-widths are applied *after* the model-view
in the shader, so road widths stay constant in pixels through a fractional zoom.

**How they never show a mess** — the mechanism worth copying:

- On a zoom flip, old-zoom render groups are marked `DeleteLater()` but **keep drawing at
  full opacity**.
- They are dropped only when `canBeDeleted = !HasIntersection(tileRect, notFinishedTileRects)`
  — a group overlapping *any* still-loading tile cannot be removed.
- Per-bucket gating: `visible = !canBeDeleted && bucket->GetMinZoom() <= currentZoom`, so on
  zoom-out over-detailed features vanish immediately while everything else survives.
- **No cross-fade at all** — `UpdateAnimation()` hard-sets opacity to 1.0. Old geometry is
  swapped for new instantly, once new is ready.
- The requested rect is inflated by 75 px × visual scale for pan slack.
- Anything genuinely uncovered is painted the style's background colour for that zoom.

Labels are SDF glyphs from a single ≤1024² atlas rasterised at one base size (22 px,
FreeType `FT_RENDER_MODE_SDF`), with the quad offset added after the model-view — constant
pixel size, never scaled. Placement is a 4-tree over pixel rects, re-run adaptively **every
5–15 frames** depending on label count. Visibility is applied by mutating the index buffer,
so labels pop rather than fade.

Threads: exactly two named renderer threads (render/frontend and resource-upload) plus a
reading pool of 2–3 (`CpuCores() >= 6 ? 3 : 2`), all communicating by message passing.

### 4.3 OsmAnd — the before-and-after, in one codebase

**v1 (Java + native Skia rasterizer) is what our "smooth" mode currently does.**

A full-screen ARGB_8888 bitmap is rasterised on a background thread, 33 % wider and 25 %
taller than the viewport for slack, then blitted with `setFilterBitmap(true)`. Crucially:

```java
// MapVectorLayer.onPrepareBufferImage
if (!view.isZooming()) { ... }        // isZooming() is true for the whole gesture
```

**No re-render is even attempted mid-pinch.** The old bitmap is bilinear-stretched, labels
blur with it, and the map snaps to an integer zoom at the end with a visible pop
(`isSteplessZoomSupported() { return hasMapRenderer(); }` — v1 pins the fractional part to 0).

That is a precise description of the behaviour we were complaining about, in a shipping app,
from the same architecture.

**v2 (OsmAnd Core, OpenGL) did not become a vector renderer.** Its base map is *still*
Skia-rasterized tiles uploaded as GPU textures — `MapRasterLayerProvider_Software_P::rasterize`
draws into an `SkBitmap` and `uploadTiledDataToGPU` does `glTexImage2D`. The rasterizer only
handles polygons and polylines; no points, icons or text.

What v2 actually changed:

1. Fractional zoom became a **camera dolly** (`distanceFromCameraToTarget` computed from
   `visualZoom`) over a fixed-size tile mesh, instead of stretching a bitmap.
2. **Labels were lifted out of the bitmap** into per-frame screen-space quads drawn at exact
   native pixel size (`vertexOnScreen = in_vs_vertexPosition * vec2(param_vs_symbolSize)`),
   with their own quadtree collision re-run every frame.
3. A real substitution ladder: **5 levels up (overscaled), 2 levels down (underscaled)**, with
   stub textures, and the cache deliberately protects overscaled tiles from eviction —
   `"If it's less than zero (overscaled tile), keep it"`.

### 4.4 What all three agree on

| | MapLibre | Organic Maps | OsmAnd v2 |
|---|---|---|---|
| Per-frame geometry work | matrix + uniforms | matrix only | matrix + camera dolly |
| Tessellation | once per tile, on a worker | **at map-build time** | in the Skia raster step |
| Base map on GPU as | vertex buffers | vertex buffers | **textures** |
| Labels | screen-space SDF quads | screen-space SDF quads | screen-space textured quads |
| Label size under zoom | constant pixels | constant pixels | constant pixels |
| Placement cadence | ≤ once / 300 ms, 2 ms budget | every 5–15 frames | every frame |
| Old data while loading | 10 up / 3 down | keep previous level until ready | 5 up / 2 down + stubs |

**Nobody re-tessellates geometry every frame.** And **nobody bakes labels into a bitmap that
then rotates.** Those are the two things we were doing.

---

## 5. The Flutter constraint

We cannot reach the Organic Maps ceiling, and it is worth being explicit about why:

- `Canvas` calls can only be issued on the UI isolate (flutter#75755).
- Impeller re-tessellates every path every frame on the raster thread.
- Impeller's raster cache is disabled, so there is no engine-level texture reuse.
- There is no supported path to back a `Texture` widget with our own GPU rendering
  (flutter#74318 — would need embedder WebGPU support plus external texture support; neither
  exists).

vector_map_tiles' own author is candid about the ceiling:

> We've done a lot of work to address performance issues, but it's still not as good as
> raster or native maps. […] you may find that raster tiles are needed to get the performance
> that you want.

And flutter_map's documentation: *"Using vector tiles may significantly cut FPS and introduce
jank."*

**Our realistic ceiling is the OsmAnd-v2 architecture**, which is exactly where we now are:
rasterize geometry to GPU-resident images, draw labels live in screen space.

---

## 6. Flutter ecosystem options

| Option | What it is | Verdict |
|---|---|---|
| **Current** — flutter_map + vendored vector_map_tiles | Rasterize per tile to `ui.Image`, live vector labels | Right architecture; missing retention + budget + overzoom culling |
| [`flutter_map_vector_tiles`](https://pub.dev/packages/flutter_map_vector_tiles) | Clean-room rewrite for flutter_map ≥8.2 on **stable** Flutter. Rasterize once to GPU image; retained ancestors (no white flash); screen-space labels with global collision | Does everything on our list already. **Risk:** published days ago, 2 likes, single maintainer, unverified uploader |
| [`flutter_map_maplibre`](https://pub.dev/packages/flutter_map_maplibre) | MapLibre Native as a layer *inside* flutter_map — flutter_map keeps camera/gestures | Best native option; contains platform-view blast radius |
| `maplibre_gl` / `maplibre` | Full native map as a platform view | Widgets can only go *over* the map, not between layers. Android hybrid-composition jank is open with no reliable workaround (flutter#167547) |
| `vector_map_tiles` 10.x (flutter_gpu) | GPU backend with hand-written GLSL | Requires `flutter channel main`; author says use 9.0.0-beta.8 in production; no pub release in ~10 months; silently fails to render on some Android devices |
| `maplibre_flutter_gpu` | MapLibre C++ core via FFI, rendered through Flutter GPU | Three weeks old, 25 likes. Right long-term direction; watch it |

Note on `drawVertices`: it performs **no anti-aliasing at all**, even with
`Paint.isAntiAlias` (flutter#77485), which disqualifies it for map lines and text. Both
serious GPU efforts went to `flutter_gpu` with custom shaders instead.

---

## 7. Where we stand — gap analysis

Our current hybrid **is** the OsmAnd v2 architecture. The remaining gap is three things:

| They do | We do | Symptom of the gap |
|---|---|---|
| Retain the old zoom level until every replacement is ready | Drop and re-render | The "mess for a few seconds" |
| Protect overscaled tiles from eviction; 5 up / 2 down | `maximumTileSubstitutionDifference: 3`; no bitmap cache since we removed the PNG cache | Re-render on every zoom crossing |
| Throttle label placement (5–15 frames, or once per 300 ms) | Re-layout driven by tile state changes | Label churn |

Two supporting numbers:

- **One zoom level of tile bitmaps is ~48 MB on this phone** (5.1 tiles/screen × 9.4 MB at
  512 px × 3× scale, RGBA). A comparable Flutter implementation sizes its cache at 2.5
  screenfuls (64–256 MiB) after finding a 64 MiB budget held "0.81 of a level" and caused
  constant re-rasterization at every zoom crossing.
- **Overzoom is our biggest untapped win.** Liberty's data stops at z14 and we view at z18–20,
  so every display tile is a clipped fragment of one z14 tile. A comparable implementation
  measured **~85 ms → ~1 ms per tile** by rejecting features against the visible window
  *before* running filter or paint expressions. Our `TileClip` runs per fragment over the full
  feature set.
- Style size is **not** a big lever for us: liberty is 111 layers (104 active at z18). The
  widely-cited 10× report (5 → 50 FPS) went from "a few hundred layers to just over a dozen".

---

## 8. Recommendations, prioritized

1. **Retain the previous zoom level until every replacement tile is ready.**
   Organic Maps' `notFinishedTileRects` gate. Single fix for the visual mess, cheap to do.
2. **Give tile bitmaps a real budget, and keep overscaled ones.**
   Target ~2.5 screenfuls; explicitly protect overscaled tiles from eviction the way OsmAnd does.
3. **Cull overzoomed geometry against the visible window before evaluating style expressions.**
   The ~85 ms → ~1 ms item; directly applicable because we overzoom 4–6 levels.
4. **Throttle label placement** to a fixed cadence rather than reacting to every tile state change.
5. **Evaluate `flutter_map_vector_tiles`** as a possible replacement for our vendored fork — it
   already implements 1–4. Prototype and measure; do not adopt on reputation.
6. **Longer term:** the only way past the Flutter ceiling is a native core
   (`flutter_map_maplibre`) or a GPU backend (`maplibre_flutter_gpu`). Both are worth watching;
   neither is safe to ship today.

---

## 9. Changes already made (2026-08-28)

App:
- `lib/screens/map_screen.dart` — reject non-finite cameras from flutter_map's fling and snap
  back to the last finite one (fixes an ANR/OOM: a symmetric pinch produced a 0/0 fling
  direction → NaN centre → `MarkerLayer`'s world-wrapping loop never terminated, since
  `Rect.overlaps` is true for NaN; ~6 M `Positioned` widgets, 4 GB, dead in 3 pinch rounds).
- `lib/screens/map_screen.dart` — cancel follow/compass animations on user gesture.
- `lib/screens/map_screen.dart` — Smooth mode draws geometry as pre-rendered bitmaps and
  labels as a live vector layer, so labels stay upright when the map rotates.
- `lib/services/render_quality.dart` — `auto` now resolves to `smooth`.
- `lib/main.dart` — dev-only frame-timing logger (`--dart-define=OM_FRAMESTATS=true`).

Vendored `packages/vector_map_tiles` (see its `PATCHES.md` for the full list):
- 4. `rasterScale` option so bitmaps match the device pixel ratio; 220 ms tile cross-fade.
- 5. Rendered bitmaps are no longer PNG-encoded to disk; land/water background painted under
  raster tiles.
- 6. Parsed source tiles cached per isolate (4 entries) — the overzoom re-parse fix.
- 7. Labels survive pan/rotate; refreshed within 1.2 s of continuous movement.
- 8. Rendered tile bitmaps kept in memory under a byte budget
  (`rasterImageCacheMaxSizeInBytes`; the app sizes it to three levels of visible
  tiles via `VectorBasemap.rasterCacheBytes`, 192 MB on the test phone), so a zoom
  level that was recently on screen comes back without a render. Only tiles on
  screen when they finish rendering are cached — flutter_map's off-screen ring is
  about half of a level here and a return only needs the visible tiles at once.
  This is recommendation 2. A screen recording showed flutter_map already retains
  the previous level (recommendation 1, 5 up / 2 down, ready-gated); the gap was
  that its bitmaps were disposed on every crossing and re-rendered on return, with
  the `data` phase queueing 250–1500 ms per tile behind the ring.

App (same day, later):
- `lib/widgets/vector_basemap.dart` — the Overture overlay is symbols-only and is
  now always a live vector layer. In Smooth mode it was pre-rendered, which baked
  its labels into bitmaps that rotated with the map and stretched to several times
  their size during a zoom, and doubled the bitmaps per level: a scripted 16-step
  zoom sequence rendered 661 tiles before, 425 after (369 with the bitmap cache).
- Dev flag `OM_RASTER_CACHE=0` disables the bitmap cache for A/B runs.

Vendored, found while measuring the cache (see `PATCHES.md` 9):
- 9. Render jobs for tiles the map has left wait off-queue until wanted again. This
  was the cause of a second ANR (16:54, RSS peak 2.97 GB): after a zoom burst the
  queue kept rendering stale levels for a minute, graphics memory passed 1 GB,
  Vulkan reported a lost device and the raster thread blocked in
  `vkAcquireNextImageKHR`, which the platform thread waits on. With all of today's
  fixes, the same 16-step run (phone untouched), cache off vs on: 391 vs 386 tile
  renders (55 cache hits — every visible tile on the three returns to a level);
  40 s after the last tap zero renders in both, no Impeller errors, Graphics
  348 MB vs 476 MB. So the bitmap cache costs its ~128 MB budget in GPU memory
  and buys instant visible tiles on a return; the runaway was the stale queue.
  Lower `VectorBasemap.rasterCacheBytes` if that budget is too much for target
  devices; `didHaveMemoryPressure` now halves and clears it under pressure.

Navigation crash (reported twice more, reproduced with a scripted flow: search →
Directions → Start → 40 drags along the route, memory sampled every 3 s):
- Process peak (`VmHWM`) 3.2–3.3 GB, graphics memory swinging 0.5–1.4 GB every few
  seconds, raster thread 100–340 ms per frame, then `ErrorDeviceLost`. The spike
  began at Start (before any drag) and did not happen in browse mode.
- Cause: `vector_tile_renderer` builds every text halo as **four blurred
  `Shadow`s** (blur radius = halo width). Impeller has no raster cache, so live
  symbol layers redraw every label every frame, and each blurred shadow is a
  Gaussian blur pass with its own offscreen texture — per label, per frame.
  Making the Overture overlay live (earlier today) multiplied that by thousands
  of POI labels; the basemap's own labels alone already produced the 3 GB peaks.
- Fixes: `vector_tile_renderer` is now vendored (`packages/vector_tile_renderer`,
  `PATCHES.md`) with halos as eight *unblurred* offset copies (glyph-atlas draws);
  the Overture overlay is pre-rendered again in Smooth mode; symbol tiles no
  longer fade (`Visibility` instead of `AnimatedOpacity`, PATCHES.md 10).
- Same flow after: peak 1.32 GB, raster 2–6 ms/frame during the drags, 0 Impeller
  errors, graphics memory 0.5–0.9 GB with no spikes (two raster layers with
  caches; the overlay's cache is a quarter of the basemap's).
- `picture.dispose()` after `toImage` (native heap 300 → 165 MB after the run) and
  the memory-pressure observer is now actually registered.

App (2026-08-29) — "scrolling is a little laggy" in browse and navigation:
- Scripted pans in both modes measured *clean* — UI 2–3 ms, raster 3–4 ms, 0–2 %
  of frames over budget — yet FRAMESTATS windows held ~120 frames per 2 s: the
  app was rendering at 60 fps on a 120 Hz panel (`peak_refresh_rate=120`,
  active mode 60). Android runs content that doesn't declare a frame rate at
  the "normal" category (60 Hz), so the map scrolled at half the rate of every
  other app on the phone — perceived as lag despite perfect frame times.
- `MainActivity.kt` now votes for the fastest display mode at the current
  resolution (`preferredDisplayModeId`). The system still arbitrates: the
  user's screen setting, battery saver and thermals can clamp it, and LTPO
  panels still idle low. After: ~240 frames per 2 s window during pans
  (browse *and* navigation), UI 2 ms / raster 3–4 ms, 0–6 % of frames over
  the stricter 8.3 ms budget; 16-tap zoom burst 3 %, zero re-renders (bitmap
  cache), PSS and graphics memory flat at idle.
- `lib/main.dart` — FRAMESTATS now derives its per-thread jank budget from the
  display's actual refresh rate instead of assuming 16.7 ms, and prints it.

Dev flags: `OM_FRAMESTATS`, `OM_TILESTATS`, `OM_RASTER_CACHE`, plus the pre-existing
`OM_CENTER`, `OM_ZOOM`, `OM_QUALITY`. (In zsh pass several `--dart-define`s as an array —
an unquoted `$D` string is passed as one mangled define and silently disables them all.)

---

## 10. Sources

MapLibre / Mapbox
- <https://github.com/maplibre/maplibre-gl-js/blob/main/ARCHITECTURE.md>
- <https://github.com/maplibre/maplibre-gl-js/blob/main/developer-guides/life-of-a-tile.md>
- <https://github.com/maplibre/maplibre-gl-js/blob/main/src/source/worker_tile.ts>
- <https://github.com/maplibre/maplibre-gl-js/blob/main/src/shaders/glsl/symbol_sdf.vertex.glsl>
- <https://github.com/maplibre/maplibre-gl-js/blob/main/src/symbol/placement.ts>
- <https://github.com/maplibre/maplibre-gl-js/blob/main/src/symbol/collision_index.ts>
- <https://github.com/maplibre/maplibre-gl-js/blob/main/src/tile/tile_manager.ts>
- <https://github.com/maplibre/maplibre-native/blob/main/src/mln/renderer/tile_pyramid.cpp>
- <https://github.com/maplibre/maplibre-native/blob/main/src/mln/algorithm/update_renderables.hpp>
- <https://deepwiki.com/maplibre/maplibre-native/3.3-symbol-placement-and-collision-detection>

Organic Maps
- <https://github.com/organicmaps/organicmaps> — `libs/drape_frontend/frontend_renderer.cpp`,
  `libs/drape/batcher.hpp`, `libs/indexer/feature_impl.hpp`, `libs/indexer/scales.cpp`,
  `generator/geometry_holder.hpp`, `libs/drape/glyph_manager.cpp`, `libs/drape/overlay_tree.cpp`

OsmAnd
- <https://github.com/osmandapp/OsmAnd> — `OsmandMapTileView.java`, `MapVectorLayer.java`,
  `MapRenderRepositories.java`
- <https://github.com/osmandapp/OsmAnd-core> — `AtlasMapRenderer_OpenGL.cpp`,
  `MapRasterLayerProvider_Software_P.cpp`, `AtlasMapRendererSymbolsStage_OpenGL.cpp`,
  `MapRendererResourcesManager.cpp`
- <https://osmand.net/docs/user/map/interact-with-map/>

Flutter
- <https://github.com/flutter/flutter/issues/108499> — Impeller path tessellation
- <https://github.com/flutter/flutter/issues/75755> — Canvas is UI-thread-only
- <https://github.com/flutter/flutter/issues/77485> — `drawVertices` has no anti-aliasing
- <https://github.com/flutter/flutter/issues/167547> — Android hybrid composition jank
- <https://github.com/flutter/flutter/issues/74318> — no custom-GPU `Texture` path
- <https://api.flutter.dev/flutter/dart-ui/Picture/toImageSync.html>
- <https://docs.fleaflet.dev/why-and-how/how-does-it-work/raster-vs-vector-tiles>
- <https://github.com/greensopinion/flutter-vector-map-tiles/issues/120>
- <https://github.com/JonasGrunau/flutter-map-vector-tiles/blob/main/doc/ARCHITECTURE.md>
