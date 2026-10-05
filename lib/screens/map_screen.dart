import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gm;
//import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart' show Style;
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/nav_route.dart';
import '../models/place.dart';
import '../navigation/navigation_engine.dart';
import '../services/app_exception.dart';
import '../services/app_settings.dart';
import '../services/geocoding_service.dart';
import '../services/overpass_service.dart';
import '../services/photo_service.dart';
import '../services/render_quality.dart';
import '../services/routing_service.dart';
import '../services/storage_service.dart';
import '../services/weather_service.dart';
import '../util/constants.dart';
import '../util/geo.dart';
import 'map/google_map_facade.dart';
import '../widgets/foveated_layer.dart';
import '../widgets/map_controls.dart';
import '../widgets/map_layers.dart';
import '../widgets/map_top_bar.dart';
import '../widgets/nav_overlay.dart';
import '../widgets/place_sheet.dart';
import '../widgets/route_panel.dart';
import '../widgets/vector_basemap.dart';
import 'map/camera_animator.dart';
import 'map/location_controller.dart';
import 'search_page.dart';
import 'settings_page.dart';

enum _ViewMode { browse, place, route, navigate }

/// Dev-only start view, e.g.
/// `--dart-define=OM_CENTER=17.3616,78.4747 --dart-define=OM_ZOOM=15.3`.
const _devCenterRaw = String.fromEnvironment('OM_CENTER');

/// Dev-only A/B switch: `--dart-define=OM_RASTER_CACHE=0` disables the
/// in-memory cache of rendered tile bitmaps.
const _devRasterCacheOff = String.fromEnvironment('OM_RASTER_CACHE') == '0';
final LatLng? _devCenter = () {
  final p = _devCenterRaw.split(',');
  if (p.length != 2) return null;
  final lat = double.tryParse(p[0]), lng = double.tryParse(p[1]);
  return lat == null || lng == null ? null : LatLng(lat, lng);
}();
final _devZoom =
    double.tryParse(const String.fromEnvironment('OM_ZOOM')) ?? 15.0;

/// World view shown when nothing better is known (first launch, no GPS).
const _fallbackCenter = LatLng(22.0, 79.0);
const _fallbackZoom = 4.5;

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final _geocoding = GeocodingService();
  final _routing = RoutingService();
  final _overpass = OverpassService();
  final _storage = StorageService();
  final _weather = WeatherService();
  final _photos = PhotoService();

  late final GoogleMapFacade _mapController = GoogleMapFacade(
    initialCamera: const MapViewCamera(
      center: _fallbackCenter,
      zoom: _fallbackZoom,
      rotation: 0,
      nonRotatedSize: Size.zero,
    ),
  );
  late final CameraAnimator _camera = CameraAnimator(
    vsync: this,
    map: _mapController,
  );
  final _location = LocationController();

  _ViewMode _view = _ViewMode.browse;

  // High-frequency state lives in ValueNotifiers so that only the small
  // widgets displaying it rebuild — never the whole screen or the map.
  final _rotationN = ValueNotifier<double>(0);
  final _followNavN = ValueNotifier<bool>(true);
  final _poiStaleN = ValueNotifier<bool>(false);

  /// Phone-facing direction from the gyro/magnetometer fusion sensor.
  final _compassN = ValueNotifier<double?>(null);
  StreamSubscription<CompassEvent>? _compassSub;
  // DateTime _lastCompassCameraAt = DateTime.fromMillisecondsSinceEpoch(0);

  LatLng? get _myLocation => _location.current;

  Place? _selectedPlace;
  bool _selectedSaved = false;
  bool _placeSheetVisible = true;
  bool _resolvingPin = false;
  Weather? _placeWeather;
  String? _placePhotoUrl;
  final _sheetController = DraggableScrollableController();

  List<NavRoute> _routes = [];
  int _selectedRoute = 0;
  int _routeRequestId = 0;
  TravelMode get _mode => AppSettings.travelMode.value;
  RouteOptions get _routeOptions => AppSettings.routeOptions.value;
  bool _routesLoading = false;
  AppException? _routeError;

  NavigationEngine? _nav;
  bool _arrivedShown = false;
  int _travelSplitIndex = 0;

  // Cached render objects — rebuilt only when the underlying data changes,
  // not on every widget build.
  List<gm.Polyline> _routePolylines = const [];
  List<gm.Marker> _staticMarkers = const [];
  NavRoute? _cachedNavRoute;

  // Camera-follow throttling.
  LatLng? _lastCamTarget;
  double _lastCamHeading = 0;
  Timer? _autoRecenterTimer;
  Timer? _cameraSaveTimer;

  /// Browse-mode heading-up follow (second tap on the my-location button),
  /// like Google's compass mode.
  bool _browseHeadingMode = false;
  bool _blueDotEnabled = false;

  MapLayerStyle get _layer => MapLayerStyle.byName(AppSettings.layerName.value);
  Widget? _tileWidget;
  MapLayerStyle? _tileStyle;
  bool? _tileDark;
  RenderQuality? _tileQuality;
  bool _vectorErrorShown = false;

  PoiCategory? _activePoi;
  List<Place> _pois = [];
  LatLng? _poiCenter;
  bool _poisLoading = false;
  int _poiRequestId = 0;

  // ─────────────────────────────────────── lifecycle

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    RenderQualitySettings.choice.addListener(_rebuild);
    AppSettings.layerName.addListener(_rebuild);
    AppSettings.units.addListener(_onUnitsChanged);
    AppSettings.voiceGuidance.addListener(_onVoiceChanged);
    // No permission prompt on a cold start: only start the GPS if the user
    // already granted it. The first tap on the location button asks.
    unawaited(_location.startIfPermitted());
    _location.position.addListener(_onBrowsePosition);
    _initCompass();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        // Navigation keeps its own foreground stream; everything else stops.
        // Sensor streams are cancelled, not paused: pausing a broadcast
        // subscription leaves the sensor running.
        _location.pause();
        _stopCompass();
      case AppLifecycleState.resumed:
        if (_view != _ViewMode.navigate) _location.resume();
        _initCompass();
      case AppLifecycleState.inactive:
        break;
    }
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _onUnitsChanged() => _refresh(() {});

  void _onVoiceChanged() =>
      _nav?.setMuted(muted: !AppSettings.voiceGuidance.value);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    RenderQualitySettings.choice.removeListener(_rebuild);
    AppSettings.layerName.removeListener(_rebuild);
    AppSettings.units.removeListener(_onUnitsChanged);
    AppSettings.voiceGuidance.removeListener(_onVoiceChanged);
    _autoRecenterTimer?.cancel();
    _cameraSaveTimer?.cancel();
    unawaited(_compassSub?.cancel());
    _compassN.dispose();
    _location.position.removeListener(_onBrowsePosition);
    _location.dispose();
    _camera.dispose();
    _nav?.removeListener(_onNavUpdate);
    _nav?.dispose();
    _mapController.dispose();
    _sheetController.dispose();
    _rotationN.dispose();
    _followNavN.dispose();
    _poiStaleN.dispose();
    unawaited(WakelockPlus.disable());
    super.dispose();
  }

  // ─────────────────────────────────────── sensors

  /// Compass fusion, Google-style: the sensor heading drives the arrow/beam
  /// whenever GPS course is unreliable (slow or stationary), and rotates the
  /// map itself while paused during navigation.
  void _stopCompass() {
    unawaited(_compassSub?.cancel());
    _compassSub = null;
  }

  void _initCompass() {
    if (_compassSub != null) return;
    final events = FlutterCompass.events;
    if (events == null) return;
    _compassSub = events.listen((event) {
      final raw = event.heading;
      if (raw == null) return;
      final heading = raw < 0 ? raw + 360 : raw;
      final previous = _compassN.value;
      if (previous == null || bearingDiff(heading, previous) > 1.5) {
        _compassN.value = heading;
      }

      if (!_camera.ready) return;
      
      // final now = DateTime.now();
      final engine = _nav;




    }, onError: (Object e) => logError('compass', e));
  }

  /// Browse-mode GPS tick: keep the camera glued to the user in compass
  /// mode, and centre once on the very first fix of a fresh launch.
  bool _centeredOnFirstFix = false;
  void _onBrowsePosition() {
    final here = _myLocation;
    if (here == null || !_camera.ready) return;

    if (!_blueDotEnabled) {
      setState(() {
        _blueDotEnabled = true;
      });
    }

    if (_browseHeadingMode && _view == _ViewMode.browse) {
      _camera.animateTo(
        center: here,
        duration: const Duration(milliseconds: 500),
      );
    } else if (!_centeredOnFirstFix &&
        _devCenter == null &&
        AppSettings.lastCamera == null &&
        _view == _ViewMode.browse) {
      _centeredOnFirstFix = true;
      _camera.animateTo(center: here, zoom: 15);
    }
  }

  /// Google-style dynamic follow camera: speed-dependent zoom (close and
  /// detailed at low speed, pulled back at highway speed), a decisive zoom-in
  /// approaching each maneuver, and look-ahead framing that keeps the arrow
  /// in the lower third of the screen so the road ahead fills the view.
  ({LatLng center, double zoom}) _navCameraTarget(
    NavigationEngine engine,
    LatLng position,
    double heading,
  ) {
    final speedKmh = engine.speedKmh;
    double targetZoom;
    if (engine.distanceToNextManeuver < 160) {
      targetZoom = 18.0; // approaching a turn: maximum detail
    } else if (speedKmh < 15) {
      targetZoom = 17.8;
    } else if (speedKmh < 40) {
      targetZoom = 17.2;
    } else if (speedKmh < 75) {
      targetZoom = 16.4;
    } else {
      targetZoom = 15.8; // highway: see far ahead
    }
    // Glide toward the target instead of jumping between bands.
    final currentZoom = _mapController.camera.zoom;
    final zoom = currentZoom + (targetZoom - currentZoom) * 0.4;

    final viewportHeight = _mapController.camera.nonRotatedSize.height;
    final lookAheadMeters =
        viewportHeight * 0.18 * metersPerPixel(zoom, position.latitude);
    return (center: offsetBy(position, lookAheadMeters, heading), zoom: zoom);
  }

  // ─────────────────────────────────────── location

  /// Starts the GPS (prompting if needed) and explains refusals with a way
  /// out. Returns true when fixes are (or will be) flowing.
  Future<bool> _requireLocation() async {
    final status = await _location.ensureStarted();
    if (!mounted) return false;
    switch (status) {
      case LocationStatus.ready:
      case LocationStatus.locating:
        return true;
      case LocationStatus.servicesOff:
        _toast(
          'Location services are turned off',
          action: SnackBarAction(
            label: 'Turn on',
            onPressed: Geolocator.openLocationSettings,
          ),
        );
      case LocationStatus.deniedForever:
        _toast(
          'Location permission is blocked for ZamosaRide',
          action: SnackBarAction(
            label: 'Settings',
            onPressed: Geolocator.openAppSettings,
          ),
        );
      case LocationStatus.denied:
        _toast('Location permission is needed for GPS and directions');
      case LocationStatus.error:
        _toast('Could not access location right now');
      case LocationStatus.idle:
        break;
    }
    return false;
  }

  /// First tap: center on the user. Second tap while centered: enter
  /// compass mode (map turns with the phone). Tap again: back to north-up.
  Future<void> _goToMyLocation() async {
    if (_myLocation == null) {
      if (!await _requireLocation()) return;
      try {
        await _location.waitForFix(timeout: const Duration(seconds: 12));
      } on TimeoutException {
        _toast('Still looking for a GPS fix — try again outside');
        return;
      }
      if (!mounted || _myLocation == null) return;
    }
    if (_browseHeadingMode) {
      setState(() => _browseHeadingMode = false);
      _camera.animateTo(center: _myLocation!, rotation: 0);
      return;
    }
    final alreadyCentered =
        _camera.ready &&
        distanceMeters(_mapController.camera.center, _myLocation!) < 40 &&
        _mapController.camera.zoom > 13;
    if (alreadyCentered && _view == _ViewMode.browse) {
      setState(() => _browseHeadingMode = true);
      unawaited(HapticFeedback.selectionClick());
      _camera.animateTo(
        center: _myLocation!,
        zoom: math.max(_mapController.camera.zoom, 16.5),
        rotation: -(_compassN.value ?? _location.heading.value),
      );
    } else {
      _camera.animateTo(center: _myLocation!, zoom: 16);
    }
  }

  // ─────────────────────────────────────── camera helpers

    static gm.LatLng _toGoogleLatLng(LatLng point) =>
      gm.LatLng(point.latitude, point.longitude);

  void _fitRoute(NavRoute route) => _camera.fit(
    route.shape,
    padding: const EdgeInsets.fromLTRB(48, 140, 48, 380),
  );

  void _scheduleCameraSave(MapViewCamera camera) {
    _cameraSaveTimer?.cancel();
    _cameraSaveTimer = Timer(const Duration(seconds: 1), () {
      if (_view != _ViewMode.navigate) {
        AppSettings.saveCamera(camera.center, camera.zoom);
      }
    });
  }

  // ─────────────────────────────────────── render caches

  void _rebuildRoutePolylines() {
    if (_routes.isEmpty && _cachedNavRoute == null) {
      _routePolylines = const [];
      return;
    }
    final dark = Theme.of(context).brightness == Brightness.dark;
    // Google-style route colors: strong blue with white casing by day,
    // bright blue with deep casing on the dark basemap.
    final activeFill = dark ? const Color(0xFF5AA7FF) : kBrandBlue;
    final polylines = <gm.Polyline>[];
    if (_view == _ViewMode.route) {
      for (var i = 0; i < _routes.length; i++) {
        if (i == _selectedRoute) continue;
        polylines.add(
          gm.Polyline(
            polylineId: gm.PolylineId('route_alt_$i'),
            points: _routes[i].shape.map(_toGoogleLatLng).toList(),
            width: 6,
            color: dark
                ? const Color(0xFF8DA3B8).withValues(alpha: 0.7)
                : Colors.blueGrey.withValues(alpha: 0.55),
          ),
        );
      }
    }
    final active = _view == _ViewMode.navigate && _cachedNavRoute != null
        ? _cachedNavRoute!
        : (_routes.isEmpty
              ? null
              : _routes[_selectedRoute.clamp(0, _routes.length - 1)]);
    if (active != null) {
      // While navigating, gray out the part of the route already traveled.
      final split = _view == _ViewMode.navigate
          ? _travelSplitIndex.clamp(0, active.shape.length - 2)
          : 0;
      if (split > 0) {
        polylines.add(
          gm.Polyline(
            polylineId: const gm.PolylineId('route_traveled'),
            points: active.shape.sublist(0, split + 1).map(_toGoogleLatLng).toList(),
            width: 7,
            color: dark ? const Color(0xFF5F6B78) : const Color(0xFF9AA0A6),
          ),
        );
      }
      polylines.add(
        gm.Polyline(
          polylineId: const gm.PolylineId('route_active'),
          points: (split > 0 ? active.shape.sublist(split) : active.shape)
              .map(_toGoogleLatLng)
              .toList(),
          width: 9,
          color: activeFill,
        ),
      );
    }
    _routePolylines = polylines;
  }

  void _rebuildStaticMarkers() {
    final markers = <gm.Marker>[];
    for (final poi in _pois) {
      markers.add(
        gm.Marker(
          markerId: gm.MarkerId('poi_${poi.name}_${poi.point.latitude}_${poi.point.longitude}'),
          position: gm.LatLng(poi.point.latitude, poi.point.longitude),
          onTap: () => _selectPlace(poi, moveCamera: false),
          icon: gm.BitmapDescriptor.defaultMarkerWithHue(gm.BitmapDescriptor.hueAzure),
        ),
      );
    }
    if (_selectedPlace != null) {
      markers.add(
        gm.Marker(
          markerId: const gm.MarkerId('selected_place'),
          position: gm.LatLng(
            _selectedPlace!.point.latitude,
            _selectedPlace!.point.longitude,
          ),
          onTap: () {
            if (_view != _ViewMode.place) return;
            if (!_placeSheetVisible) {
              setState(() => _placeSheetVisible = true);
            } else if (_sheetController.isAttached) {
              final expanded = _sheetController.size > 0.5;
              unawaited(
                _sheetController.animateTo(
                  expanded ? kSheetPeekSize : kSheetMaxSize,
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOut,
                ),
              );
            }
          },
          icon: gm.BitmapDescriptor.defaultMarkerWithHue(gm.BitmapDescriptor.hueRed),
        ),
      );
    }
    _staticMarkers = markers;
  }

  /// Rebuilds cached map geometry, then triggers one widget rebuild.
  void _refresh(VoidCallback updates) {
    if (!mounted) return;
    setState(() {
      updates();
      _rebuildRoutePolylines();
      _rebuildStaticMarkers();
    });
  }

  // ─────────────────────────────────────── search & places

  Future<void> _openSearch() async {
    final place = await Navigator.of(context).push<Place>(
      MaterialPageRoute(
        builder: (_) => SearchPage(
          geocoding: _geocoding,
          storage: _storage,
          near:
              _myLocation ??
              (_camera.ready ? _mapController.camera.center : null),
        ),
      ),
    );
    if (place != null && mounted) await _selectPlace(place);
  }

  void _openSettings() {
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => SettingsPage(storage: _storage)),
      ),
    );
  }

  Future<void> _selectPlace(
    Place place, {
    bool moveCamera = true,
    bool resolvePin = false,
  }) async {
    final saved = await _storage.isSaved(place);
    if (!mounted) return;
    _refresh(() {
      _selectedPlace = place;
      _selectedSaved = saved;
      _placeWeather = null;
      _placePhotoUrl = null;
      _placeSheetVisible = true;
      _resolvingPin = resolvePin;
      _view = _ViewMode.place;
      _routes = [];
      _routeError = null;
    });
    if (moveCamera) {
      _camera.animateTo(center: place.point, zoom: 16);
    }
    // A new place starts at the peek height, like a freshly opened sheet.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _sheetController.isAttached && _selectedPlace == place) {
        _sheetController.jumpTo(kSheetPeekSize);
      }
    });
    unawaited(_loadPlaceExtras(place, replaceIdentity: resolvePin));
  }

  /// The single enrichment path: weather, OSM detail tags via reverse
  /// geocoding (a dropped pin takes the resolved name and address; a search
  /// result only fills in gaps), and an open-licensed photo.
  Future<void> _loadPlaceExtras(
    Place place, {
    bool replaceIdentity = false,
  }) async {
    unawaited(
      _weather
          .current(place.point)
          .then<void>((weather) {
            if (mounted && _selectedPlace == place) {
              setState(() => _placeWeather = weather);
            }
          })
          .catchError((Object e) {
            logError('weather', e);
          }),
    );

    var enriched = place;
    if (replaceIdentity || place.wikidata == null || place.phone == null) {
      try {
        final detail = await _geocoding.reverse(place.point);
        if (!mounted || _selectedPlace != place) return;
        if (replaceIdentity) {
          // Keep the pin exactly where it was dropped.
          enriched = Place(
            name: detail.name,
            address: detail.address,
            point: place.point,
            category: detail.category,
            phone: detail.phone,
            website: detail.website,
            openingHours: detail.openingHours,
            wikidata: detail.wikidata,
            imageUrl: detail.imageUrl,
          );
          final saved = await _storage.isSaved(enriched);
          if (!mounted || _selectedPlace != place) return;
          _refresh(() {
            _selectedPlace = enriched;
            _selectedSaved = saved;
            _resolvingPin = false;
          });
        } else if (distanceMeters(detail.point, place.point) < 120) {
          // Only merge when Nominatim resolved the same spot (within ~120 m).
          enriched = place.mergedWith(detail);
          setState(() => _selectedPlace = enriched);
        }
      } on Exception catch (e) {
        logError('reverse geocode', e);
        if (mounted && replaceIdentity && _selectedPlace == place) {
          setState(() => _resolvingPin = false);
        }
      }
    }

    try {
      final url = await _photos.photoUrl(enriched);
      if (url != null && mounted && _selectedPlace == enriched) {
        setState(() => _placePhotoUrl = url);
      }
    } on Exception catch (e) {
      logError('photo', e);
    }
  }

  void _onLongPress(LatLng point) {
    if (_view == _ViewMode.navigate) return;
    unawaited(HapticFeedback.selectionClick());
    // Show the pin immediately; the enrichment path swaps in the address.
    unawaited(
      _selectPlace(Place.pin(point), moveCamera: false, resolvePin: true),
    );
  }

  void _closePlace() {
    _refresh(() {
      _selectedPlace = null;
      _view = _ViewMode.browse;
      _routes = [];
    });
  }

  Future<void> _toggleSaved() async {
    final place = _selectedPlace;
    if (place == null) return;
    final nowSaved = await _storage.toggleSaved(place);
    if (!mounted) return;
    if (_selectedPlace == place) setState(() => _selectedSaved = nowSaved);
    _toast(nowSaved ? 'Saved to your places' : 'Removed from saved places');
  }

  void _showSaveMenu() {
    final place = _selectedPlace;
    if (place == null) return;
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(
                  _selectedSaved ? Icons.star : Icons.star_border,
                  color: _selectedSaved ? Colors.amber : null,
                ),
                title: Text(
                  _selectedSaved
                      ? 'Remove from favorites'
                      : 'Save to favorites',
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(_toggleSaved());
                },
              ),
              ListTile(
                leading: const Icon(Icons.home),
                title: const Text('Set as Home'),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  await _storage.setHome(place);
                  _toast('Home set to ${place.name}');
                },
              ),
              ListTile(
                leading: const Icon(Icons.work),
                title: const Text('Set as Work'),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  await _storage.setWork(place);
                  _toast('Work set to ${place.name}');
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─────────────────────────────────────── POIs

  Future<void> _togglePoiCategory(PoiCategory category) async {
    if (_activePoi == category) {
      _poiRequestId++;
      _refresh(() {
        _activePoi = null;
        _pois = [];
        _poisLoading = false;
      });
      _poiStaleN.value = false;
      return;
    }
    await _searchPois(category);
  }

  Future<void> _searchPois(PoiCategory category) async {
    final id = ++_poiRequestId; // cancels any previous search's result
    final center = _camera.ready
        ? _mapController.camera.center
        : (_myLocation ?? _fallbackCenter);
    _refresh(() {
      _activePoi = category;
      _poisLoading = true;
      _pois = [];
    });
    _poiCenter = center;
    _poiStaleN.value = false;
    try {
      final pois = await _overpass.findNearby(category, center);
      if (!mounted || id != _poiRequestId) return;
      _refresh(() {
        _pois = pois;
        _poisLoading = false;
      });
      _toast(
        pois.isEmpty
            ? 'No ${category.label.toLowerCase()} found nearby'
            : '${pois.length} ${category.label.toLowerCase()} nearby',
      );
    } on Exception catch (e) {
      if (!mounted || id != _poiRequestId) return;
      final error = toAppException(e);
      setState(() => _poisLoading = false);
      _toast(
        'Nearby search failed: ${error.message}',
        action: error.retryable
            ? SnackBarAction(
                label: 'Retry',
                onPressed: () => _searchPois(category),
              )
            : null,
      );
    }
  }

  void _updatePoiStale(MapViewCamera camera) {
    final origin = _poiCenter;
    if (_activePoi == null || origin == null) return;
    final stale = distanceMeters(origin, camera.center) > 1200;
    if (_poiStaleN.value != stale) _poiStaleN.value = stale;
  }

  // ─────────────────────────────────────── directions

  Future<void> _openDirections() async {
    if (_selectedPlace == null) return;
    if (_myLocation == null) {
      if (!await _requireLocation()) return;
      try {
        await _location.waitForFix(timeout: const Duration(seconds: 12));
      } on TimeoutException {
        _toast('Could not get your location yet — try again in a moment');
        return;
      }
      if (!mounted) return;
    }
    setState(() => _view = _ViewMode.route);
    await _fetchRoutes();
  }

  Future<void> _fetchRoutes() async {
    final destination = _selectedPlace;
    final origin = _myLocation;
    if (destination == null || origin == null) return;
    // Request token: a slow Drive response must not overwrite a later
    // Walk selection.
    final id = ++_routeRequestId;
    _refresh(() {
      _routesLoading = true;
      _routeError = null;
      _routes = [];
    });
    try {
      final routes = await _routing.getRoutes(
        from: origin,
        to: destination.point,
        mode: _mode,
        options: _routeOptions,
      );
      if (!mounted || id != _routeRequestId || _view != _ViewMode.route) {
        return;
      }
      _refresh(() {
        _routes = routes;
        _selectedRoute = 0;
        _routesLoading = false;
      });
      _fitRoute(routes.first);
    } on Exception catch (e) {
      if (!mounted || id != _routeRequestId) return;
      setState(() {
        _routesLoading = false;
        _routeError = toAppException(e);
      });
    }
  }

  void _onModeChanged(TravelMode mode) {
    AppSettings.travelMode.value = mode;
    unawaited(_fetchRoutes());
  }

  void _previewStep(RouteManeuver step) {
    if (_routes.isEmpty) return;
    final route = _routes[_selectedRoute.clamp(0, _routes.length - 1)];
    final at = step.beginShapeIndex.clamp(0, route.shape.length - 1);
    _camera.animateTo(center: route.shape[at], zoom: 17);
  }

  // ─────────────────────────────────────── navigation

  Future<void> _startNavigation() async {
    if (_routes.isEmpty || _selectedPlace == null) return;
    final engine = NavigationEngine(
      route: _routes[_selectedRoute],
      destination: _selectedPlace!,
      routing: _routing,
      muted: !AppSettings.voiceGuidance.value,
    );
    unawaited(HapticFeedback.mediumImpact());
    engine.addListener(_onNavUpdate);
    _followNavN.value = true;
    _lastCamTarget = null;
    _travelSplitIndex = 0;
    _refresh(() {
      _nav = engine;
      _cachedNavRoute = engine.route;
      _view = _ViewMode.navigate;
      _arrivedShown = false;
    });
    // The engine runs its own high-rate stream; don't double up.
    _location.pause();
    unawaited(WakelockPlus.enable());
    // Zoom straight into driving view; the engine refines it on the next fix.
    if (_myLocation != null) {
      _camera.animateTo(
        center: _myLocation!,
        zoom: 17.5,
        rotation: -_location.heading.value,
        duration: const Duration(milliseconds: 800),
      );
    }
    await engine.start();
  }

  void _onNavUpdate() {
    final engine = _nav;
    if (engine == null || !mounted) return;

    // A reroute swapped the route object — refresh the cached polyline.
    if (!identical(engine.route, _cachedNavRoute)) {
      _refresh(() {
        _cachedNavRoute = engine.route;
        _travelSplitIndex = 0;
      });
    } else if (engine.segmentIndex - _travelSplitIndex >= 8) {
      // Periodically gray out the traveled part of the route (cheap: at most
      // once per ~8 segments, never per frame).
      _refresh(() => _travelSplitIndex = engine.segmentIndex);
    }

    // Follow the user, but skip redundant camera animations when the
    // position/heading has barely changed.
    final center = engine.snappedPosition ?? engine.rawPosition;
    if (_followNavN.value && center != null) {
      final moved =
          _lastCamTarget == null ||
          distanceMeters(_lastCamTarget!, center) > 1.5;
      final headingDelta = bearingDiff(engine.heading, _lastCamHeading);
      if (moved || headingDelta > 2) {
        _lastCamTarget = center;
        _lastCamHeading = engine.heading;
        final target = _navCameraTarget(engine, center, engine.heading);
        _camera.animateTo(
          center: target.center,
          zoom: target.zoom,
          rotation: -engine.heading,
          duration: const Duration(milliseconds: 900),
          curve: Curves.linear,
        );
      }
    }

    if (engine.arrived && !_arrivedShown) {
      _arrivedShown = true;
      unawaited(HapticFeedback.heavyImpact());
      unawaited(
        showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            icon: const Icon(Icons.flag, size: 40),
            title: const Text('You have arrived'),
            content: Text(_selectedPlace?.name ?? 'Destination'),
            actions: [
              FilledButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  _exitNavigation(toBrowse: true);
                },
                child: const Text('Done'),
              ),
            ],
          ),
        ),
      );
    }
  }

  Future<void> _confirmExitNavigation() async {
    final engine = _nav;
    if (engine == null) return;
    if (engine.arrived) {
      _exitNavigation(toBrowse: true);
      return;
    }
    final end = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('End navigation?'),
        content: Text(
          '${formatDistance(engine.remainingDistanceMeters)} left to ${engine.destination.name}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep going'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('End'),
          ),
        ],
      ),
    );
    if (end == true && mounted && _nav == engine) _exitNavigation();
  }

  void _exitNavigation({bool toBrowse = false}) {
    _autoRecenterTimer?.cancel();
    _nav?.removeListener(_onNavUpdate);
    _nav?.dispose();
    _nav = null;
    unawaited(WakelockPlus.disable());
    _location.resume();
    _refresh(() {
      _cachedNavRoute = null;
      _view = toBrowse ? _ViewMode.browse : _ViewMode.route;
      if (toBrowse) {
        _selectedPlace = null;
        _routes = [];
      }
    });
    if (!toBrowse && _routes.isNotEmpty) {
      // fitCamera keeps the current rotation, so level the map first.
      _camera.stop();
      _mapController.rotate(0);
      _fitRoute(_routes[_selectedRoute]);
    } else {
      _camera.animateTo(
        center: _myLocation ?? _mapController.camera.center,
        zoom: 15,
        rotation: 0,
      );
    }
  }

  // ─────────────────────────────────────── back button

  bool get _canPop => _view == _ViewMode.browse && _activePoi == null;

  /// Android back steps one mode back instead of leaving the app.
  void _onPopInvoked(bool didPop, Object? result) {
    if (didPop) return;
    switch (_view) {
      case _ViewMode.navigate:
        unawaited(_confirmExitNavigation());
      case _ViewMode.route:
        _refresh(() {
          _routeRequestId++;
          _view = _ViewMode.place;
          _routes = [];
          _routeError = null;
        });
      case _ViewMode.place:
        _closePlace();
      case _ViewMode.browse:
        if (_activePoi != null) unawaited(_togglePoiCategory(_activePoi!));
    }
  }

  // ─────────────────────────────────────── build

  void _toast(String message, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          duration: action == null
              ? kToastDuration
              : const Duration(seconds: 6),
          action: action,
        ),
      );
  }

  /// Basemap (and Overture overlay for the vector style), memoised per
  /// style/theme/quality so FlutterMap keeps the same layer widgets across
  /// rebuilds.
  Widget _basemap(bool dark) {
    final quality = RenderQualitySettings.effective;
    final layer = _layer;
    if (_tileWidget == null ||
        _tileStyle != layer ||
        _tileDark != dark ||
        _tileQuality != quality) {
      final raster = layer.buildTileLayer(
        darkMode: dark,
        retina: MediaQuery.devicePixelRatioOf(context) > 1.8,
      );
      _tileWidget = layer.vector
          ? FutureBuilder<Style>(
              key: ValueKey('vector-$dark-$quality'),
              future: dark ? VectorBasemap.dark() : VectorBasemap.light(),
              builder: (context, snap) {
                final style = snap.data;
                if (snap.hasError) {
                  _notifyVectorError(snap.error!);
                  return raster;
                }
                if (style == null) {
                  // Plain background first; the raster fallback only
                  // kicks in if the style is slow, so it doesn't compete
                  // with the style/sprite/tile requests at launch.
                  return _DelayedChild(
                    delay: const Duration(seconds: 2),
                    child: raster,
                  );
                }
                final lite = quality == RenderQuality.smooth;
                // Pre-rendered tiles at the screen's pixel ratio (capped:
                // a 3x tile is 2.3 MB of GPU memory).
                final rasterScale = MediaQuery.devicePixelRatioOf(
                  context,
                ).clamp(2.0, 3.0);
                // Rendered tiles of neighbouring zoom levels stay in memory
                // so zooming out and back in doesn't re-render them.
                final rasterCacheBytes = _devRasterCacheOff
                    ? 0
                    : VectorBasemap.rasterCacheBytes(context);
                // The overlay's bitmaps cost as much GPU memory as the
                // basemap's but a return to a zoom level only needs its
                // POI icons eventually, so it gets a quarter of the budget.
                final overture = VectorBasemap.overlayLayer(
                  style,
                  lite: lite,
                  rasterScale: rasterScale,
                  rasterCacheBytes: rasterCacheBytes ~/ 4,
                );
                if (lite) {
                  // Smooth: geometry pre-rendered (scales on the GPU while
                  // moving), labels drawn live so they stay upright when the
                  // map rotates and never look scaled.
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      VectorBasemap.layer(
                        style,
                        lite: true,
                        part: BasemapPart.geometry,
                        rasterScale: rasterScale,
                        rasterCacheBytes: rasterCacheBytes,
                      ),
                      VectorBasemap.layer(style, part: BasemapPart.symbols),
                      ?overture,
                    ],
                  );
                }
                if (quality != RenderQuality.foveated) {
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      VectorBasemap.layer(style, rasterScale: rasterScale),
                      ?overture,
                    ],
                  );
                }
                // Foveate geometry only (pre-rendered outside, live vector
                // in the centre window). Labels are one full-screen vector
                // layer on top: they're cheap (painted once movement
                // settles) and this way they're never clipped or duplicated
                // at the window edge.
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    FoveatedLayer(
                      fraction: 0.7,
                      periphery: [
                        VectorBasemap.layer(
                          style,
                          lite: true,
                          part: BasemapPart.geometry,
                          foveated: true,
                          rasterScale: rasterScale,
                          rasterCacheBytes: rasterCacheBytes,
                        ),
                      ],
                      fovea: [
                        VectorBasemap.layer(
                          style,
                          part: BasemapPart.geometry,
                          foveated: true,
                        ),
                      ],
                    ),
                    VectorBasemap.layer(
                      style,
                      part: BasemapPart.symbols,
                      foveated: true,
                    ),
                    ?overture,
                  ],
                );
              },
            )
          : raster;
      _tileStyle = layer;
      _tileDark = dark;
      _tileQuality = quality;
    }
    return _tileWidget!;
  }

  void _notifyVectorError(Object error) {
    if (_vectorErrorShown) return;
    _vectorErrorShown = true;
    logError('vector style', error);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _toast(
        'Couldn\'t load the detailed map (${toAppException(error).message}) — showing the basic map',
        action: SnackBarAction(
          label: 'Retry',
          onPressed: () => setState(() {
            _vectorErrorShown = false;
            _tileWidget = null; // re-creates the FutureBuilder
          }),
        ),
      );
    });
  }

  

  @override
  Widget build(BuildContext context) {
    final navigating = _view == _ViewMode.navigate;
    final engine = _nav;
    final saved = AppSettings.lastCamera;
    final initialCenter = _devCenter ?? saved?.center ?? _fallbackCenter;
    final initialZoom = _devCenter != null
        ? _devZoom
        : (saved?.zoom ?? _fallbackZoom);

    return PopScope(
      canPop: _canPop,
      onPopInvokedWithResult: _onPopInvoked,
      child: Scaffold(
        body: Stack(
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final viewport = constraints.biggest;
                if (viewport.isFinite) {
                  _mapController.updateViewportSize(viewport);
                }
                if (!_mapController.ready) {
                  _mapController.camera = MapViewCamera(
                    center: initialCenter,
                    zoom: initialZoom,
                    rotation: 0,
                    nonRotatedSize: viewport,
                  );
                }
                return gm.GoogleMap(
                  initialCameraPosition: gm.CameraPosition(
                    target: gm.LatLng(
                      initialCenter.latitude,
                      initialCenter.longitude,
                    ),
                    zoom: initialZoom,
                    bearing: 0,
                  ),
                  onMapCreated: (controller) {
                    _mapController.attach(controller);
                    _camera.ready = true;
                    if (_myLocation != null &&
                        _devCenter == null &&
                        saved == null) {
                      _centeredOnFirstFix = true;
                      _mapController.move(_myLocation!, 15);
                    }
                  },
                  onCameraMoveStarted: () {
                    if (_mapController.programmaticMove) return;
                    _camera.stop();
                    if (_view == _ViewMode.navigate) {
                      if (_followNavN.value) _followNavN.value = false;
                      _autoRecenterTimer?.cancel();
                      _autoRecenterTimer = Timer(const Duration(seconds: 10), () {
                        if (mounted &&
                            _view == _ViewMode.navigate &&
                            _nav != null &&
                            !_followNavN.value) {
                          _followNavN.value = true;
                          _lastCamTarget = null;
                          _onNavUpdate();
                        }
                      });
                    }
                    if (_browseHeadingMode) {
                      setState(() => _browseHeadingMode = false);
                    }
                  },
                  onCameraMove: (position) {
                    _mapController.updateFromCameraPosition(position);
                    final camera = _mapController.camera;
                    _rotationN.value = camera.rotation;
                    _updatePoiStale(camera);
                    _scheduleCameraSave(camera);
                  },
                  onTap: (point) {
                    if (_view != _ViewMode.place) return;
                    if (_placeSheetVisible) {
                      setState(() => _placeSheetVisible = false);
                    } else {
                      _closePlace();
                    }
                  },
                  onLongPress: (point) => _onLongPress(
                    LatLng(point.latitude, point.longitude),
                  ),
                  myLocationEnabled: _blueDotEnabled,
                  myLocationButtonEnabled: false,
                  zoomControlsEnabled: false,
                  compassEnabled: false,
                  mapToolbarEnabled: false,
                  rotateGesturesEnabled: true,
                  tiltGesturesEnabled: true,
                  scrollGesturesEnabled: true,
                  zoomGesturesEnabled: true,
                  polylines: Set<gm.Polyline>.from(_routePolylines),
                  markers: Set<gm.Marker>.from(_staticMarkers),
                );
              },
            ),

            // Top UI: search bar + POI chips (hidden while navigating).
            if (!navigating)
              MapTopBar(
                title: _selectedPlace?.name,
                busy: _poisLoading,
                showChips:
                    _view != _ViewMode.route &&
                    (_view == _ViewMode.browse ||
                        !_placeSheetVisible ||
                        _activePoi != null),
                activeCategory: _activePoi,
                searchAreaStale: _poiStaleN,
                onSearch: _openSearch,
                onSettings: _openSettings,
                onCategory: _togglePoiCategory,
                onSearchThisArea: () {
                  final c = _activePoi;
                  if (c != null) unawaited(_searchPois(c));
                },
              ),

            // Navigation banner — listens to the engine directly.
            if (navigating && engine != null)
              Align(
                alignment: Alignment.topCenter,
                child: SafeArea(
                  child: ListenableBuilder(
                    listenable: engine,
                    builder: (context, _) => NavBanner(engine: engine),
                  ),
                ),
              ),

            // Right-side controls, kept just above whatever panel is open.
            if (!navigating)
              AnimatedBuilder(
                animation: _sheetController,
                builder: (context, child) {
                  final height = MediaQuery.sizeOf(context).height;
                  double bottom = 96;
                  if (_view == _ViewMode.place && _placeSheetVisible) {
                    // Ride the sheet up to its peek height; when expanded
                    // further the sheet simply covers the controls rather
                    // than pushing them into the search bar.
                    final size = _sheetController.isAttached
                        ? _sheetController.size
                        : kSheetPeekSize;
                    bottom = math.min(size, kSheetPeekSize) * height + 12;
                  }
                  return Positioned(right: 12, bottom: bottom, child: child!);
                },
                child: MapControls(
                  rotation: _rotationN,
                  locationStatus: _location.status,
                  headingMode: _browseHeadingMode,
                  onResetRotation: () => _camera.animateTo(
                    center: _mapController.camera.center,
                    rotation: 0,
                  ),
                  onLayers: () async {
                    final style = await showLayerPicker(context, _layer);
                    if (style != null) AppSettings.layerName.value = style.name;
                  },
                  onZoomIn: () => _camera.animateTo(
                    center: _mapController.camera.center,
                    zoom: _mapController.camera.zoom + 1,
                    duration: const Duration(milliseconds: 250),
                  ),
                  onZoomOut: () => _camera.animateTo(
                    center: _mapController.camera.center,
                    zoom: _mapController.camera.zoom - 1,
                    duration: const Duration(milliseconds: 250),
                  ),
                  onMyLocation: _goToMyLocation,
                ),
              ),

            // Bottom panels per mode.
            if (_view == _ViewMode.place &&
                _selectedPlace != null &&
                _placeSheetVisible)
              Positioned.fill(
                // Deliberately not keyed by place: a key change would
                // inflate a second sheet before the first is disposed and
                // the shared DraggableScrollableController asserts. The
                // size is reset in _selectPlace instead.
                child: PlaceSheet(
                  place: _selectedPlace!,
                  myLocation: _myLocation,
                  isSaved: _selectedSaved,
                  weather: _placeWeather,
                  photoUrl: _placePhotoUrl,
                  resolving: _resolvingPin,
                  controller: _sheetController,
                  onDirections: _openDirections,
                  onSavePressed: _showSaveMenu,
                  // X tucks the card away; the pin stays and re-opens it.
                  onClose: () => setState(() => _placeSheetVisible = false),
                ),
              ),
            if (_view == _ViewMode.route && _selectedPlace != null)
              Align(
                alignment: Alignment.bottomCenter,
                child: SafeArea(
                  child: RoutePanel(
                    destination: _selectedPlace!,
                    routes: _routes,
                    selectedIndex: _selectedRoute,
                    mode: _mode,
                    options: _routeOptions,
                    loading: _routesLoading,
                    error: _routeError,
                    onModeChanged: _onModeChanged,
                    onOptionsChanged: (options) {
                      AppSettings.routeOptions.value = options;
                      unawaited(_fetchRoutes());
                    },
                    onRouteSelected: (i) {
                      _refresh(() => _selectedRoute = i);
                      _fitRoute(_routes[i]);
                    },
                    onStepTapped: _previewStep,
                    onRetry: _fetchRoutes,
                    onStart: _startNavigation,
                    onClose: () => _refresh(() {
                      _routeRequestId++;
                      _view = _ViewMode.place;
                      _routes = [];
                      _routeError = null;
                    }),
                  ),
                ),
              ),
            if (navigating && engine != null) ...[
              // Floating secondary controls above the status bar.
              Positioned(
                right: 12,
                bottom: 110,
                child: SafeArea(
                  child: ListenableBuilder(
                    listenable: Listenable.merge([engine, _followNavN]),
                    builder: (context, _) => Column(
                      children: [
                        FloatingActionButton.small(
                          heroTag: 'nav_mute',
                          onPressed: () =>
                              AppSettings.voiceGuidance.value = engine.muted,
                          tooltip: engine.muted
                              ? 'Unmute voice guidance'
                              : 'Mute voice guidance',
                          child: Icon(
                            engine.muted ? Icons.volume_off : Icons.volume_up,
                          ),
                        ),
                        const SizedBox(height: 10),
                        FloatingActionButton.small(
                          heroTag: 'nav_view',
                          onPressed: _followNavN.value
                              ? () {
                                  // Route overview: whole remaining route.
                                  _followNavN.value = false;
                                  _camera.fit(
                                    engine.route.shape,
                                    padding: const EdgeInsets.fromLTRB(
                                      48,
                                      200,
                                      48,
                                      200,
                                    ),
                                  );
                                  _mapController.rotate(0);
                                }
                              : () {
                                  // Re-center into driving view.
                                  _autoRecenterTimer?.cancel();
                                  _followNavN.value = true;
                                  final center =
                                      engine.snappedPosition ??
                                      engine.rawPosition ??
                                      _myLocation;
                                  if (center != null) {
                                    final heading = engine.rawPosition != null
                                        ? engine.heading
                                        : (_compassN.value ??
                                              _location.heading.value);
                                    final target = _navCameraTarget(
                                      engine,
                                      center,
                                      heading,
                                    );
                                    _camera.animateTo(
                                      center: target.center,
                                      zoom: target.zoom,
                                      rotation: -heading,
                                    );
                                  }
                                },
                          tooltip: _followNavN.value
                              ? 'Route overview'
                              : 'Re-center',
                          child: Icon(
                            _followNavN.value
                                ? Icons.zoom_out_map
                                : Icons.navigation,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: SafeArea(
                  child: ListenableBuilder(
                    listenable: engine,
                    builder: (context, _) => NavBottomBar(
                      engine: engine,
                      onExit: _confirmExitNavigation,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Shows nothing until [delay] has passed, then [child].
class _DelayedChild extends StatefulWidget {
  final Duration delay;
  final Widget child;

  const _DelayedChild({required this.delay, required this.child});

  @override
  State<_DelayedChild> createState() => _DelayedChildState();
}

class _DelayedChildState extends State<_DelayedChild> {
  Timer? _timer;
  bool _show = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.delay, () {
      if (mounted) setState(() => _show = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _show ? widget.child : const SizedBox.shrink();
}
