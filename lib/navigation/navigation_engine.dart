import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../models/nav_route.dart';
import '../models/place.dart';
import '../services/app_exception.dart';
import '../services/routing_service.dart';
import '../util/constants.dart';
import '../util/geo.dart';
import 'speaker.dart';
import '../services/ble_services.dart';

/// Supplies the live position stream; injectable for tests.
typedef PositionStreamFactory = Stream<Position> Function();

/// Supplies a one-shot fix; injectable for tests.
typedef PositionFetcher = Future<Position> Function();

/// Live turn-by-turn navigation: consumes the GPS stream, snaps the user to
/// the route, tracks the upcoming maneuver, speaks voice guidance, and
/// reroutes automatically when the user leaves the route.
class NavigationEngine extends ChangeNotifier {
  NavRoute route;
  final Place destination;
  final RoutingService _routing;
  final Speaker _speaker;
  final _bleService = BleNavigationService();
  final PositionStreamFactory _positionStream;
  final PositionFetcher _currentPosition;

  StreamSubscription<Position>? _positionSub;
  bool _disposed = false;

  LatLng? rawPosition;
  LatLng? snappedPosition;

  /// Horizontal accuracy of the last fix in metres, for the accuracy ring.
  double accuracyMeters = 0;

  /// Direction of travel in degrees. Falls back to route bearing at low speed.
  double heading = 0;
  double speedMps = 0;

  /// Index of the maneuver whose instruction is coming up next.
  int nextManeuverIndex = 1;
  double distanceToNextManeuver = 0;
  double remainingDistanceMeters = 0;
  double remainingTimeSeconds = 0;

  /// True while the last fix was beyond the off-route threshold (before a
  /// reroute has been triggered), so the UI can say so.
  bool offRoute = false;
  bool rerouting = false;
  bool arrived = false;
  String? error;

  bool _muted;

  int _segmentHint = 0;
  int _offRouteFixes = 0;
  final Set<String> _spokenCues = {};

  // Smart wrong-turn detection state.
  int _wrongHeadingFixes = 0;
  double _divergenceRawMeters = 0;
  double _divergenceProgressMeters = 0;
  double _lastAlongMeters = 0;
  DateTime? _lastRerouteAt;

  static const _offRouteThresholdMeters = 35.0;
  static const _offRouteFixesBeforeReroute = 2;
  static const _offRouteInstantMeters = 70.0;
  static const _arrivalRadiusMeters = 30.0;
  static const _rerouteCooldown = Duration(seconds: 8);

  /// Location settings used while navigating. On Android a foreground
  /// service keeps fixes coming when the screen locks or the app is in the
  /// background; on iOS the background-location mode does the same.
  static LocationSettings navigationSettings() {
    if (kIsWeb) {
      return const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 3,
      );
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 3,
        intervalDuration: const Duration(seconds: 1),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'ZamosaRide is navigating',
          notificationText: 'Turn-by-turn guidance is running',
          notificationChannelName: 'Navigation',
          enableWakeLock: true,
          setOngoing: true,
        ),
      );
    }
    if (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS) {
      return AppleSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 3,
        activityType: ActivityType.automotiveNavigation,
        showBackgroundLocationIndicator: true,
      );
    }
    return const LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 3,
    );
  }

  NavigationEngine({
    required this.route,
    required this.destination,
    required RoutingService routing,
    Speaker? speaker,
    PositionStreamFactory? positionStream,
    PositionFetcher? currentPosition,
    bool muted = false,
  }) : _routing = routing,
       _speaker = speaker ?? TtsSpeaker.shared,
       _positionStream =
           positionStream ??
           (() => Geolocator.getPositionStream(
             locationSettings: navigationSettings(),
           )),
       _currentPosition =
           currentPosition ??
           (() => Geolocator.getCurrentPosition(
             locationSettings: const LocationSettings(
               accuracy: LocationAccuracy.bestForNavigation,
               timeLimit: Duration(seconds: 8),
             ),
           )),
       _muted = muted {
    remainingDistanceMeters = route.distanceMeters;
    remainingTimeSeconds = route.timeSeconds;
    if (route.maneuvers.length > 1) {
      distanceToNextManeuver = route.distanceAtShapeIndex(
        route.maneuvers[1].beginShapeIndex,
      );
    }
  }

  bool get muted => _muted;

  RouteManeuver? get nextManeuver => nextManeuverIndex < route.maneuvers.length
      ? route.maneuvers[nextManeuverIndex]
      : null;

  /// The maneuver after [nextManeuver] — for the "then …" preview chip.
  RouteManeuver? get followingManeuver =>
      nextManeuverIndex + 1 < route.maneuvers.length
      ? route.maneuvers[nextManeuverIndex + 1]
      : null;

  /// Index of the route shape segment the user is currently on.
  int get segmentIndex => _segmentHint;

  double get speedKmh => speedMps * 3.6;

  Future<void> start() async {
    _speak('Starting navigation. ${route.maneuvers.first.instruction}');
    _bleService.connectToDashboard();

    _positionSub = _positionStream().listen(
      _onPosition,
      onError: (Object e) {
        if (_disposed) return;
        error = 'Location unavailable';
        logError('nav position stream', e);
        notifyListeners();
      },
    );

    // The stream only emits after the device moves; seed an immediate fix so
    // the camera and arrow snap into place the moment navigation starts.
    try {
      final position = await _currentPosition();
      if (_disposed) return;
      _onPosition(position);
    } on Exception catch (e) {
      logError('nav initial fix', e);
    }
  }

  void toggleMute() => setMuted(muted: !_muted);

  void setMuted({required bool muted}) {
    if (_muted == muted) return;
    _muted = muted;
    if (_muted) unawaited(_speaker.stop());
    notifyListeners();
  }

  bool get _rerouteAllowed =>
      !rerouting &&
      (_lastRerouteAt == null ||
          DateTime.now().difference(_lastRerouteAt!) > _rerouteCooldown);

  /// Feed a fix into the engine (public so tests can replay a GPS trace).
  @visibleForTesting
  void onPosition(Position position) => _onPosition(position);

  void _onPosition(Position position) {
    print("📍 GPS MOVIDO: Lat: ${position.latitude}, Lng: ${position.longitude}");
    if (arrived || _disposed) return;
    final previousRaw = rawPosition;
    rawPosition = LatLng(position.latitude, position.longitude);
    accuracyMeters = position.accuracy;
    speedMps = position.speed >= 0 ? position.speed : 0;

    final projection = projectOntoRoute(
      rawPosition!,
      route.shape,
      route.cumulative,
      hintIndex: _segmentHint,
    );

    if (projection.offRouteMeters > _offRouteThresholdMeters) {
      // Follow the raw GPS position while we're off the known route.
      snappedPosition = null;
      offRoute = true;
      if (position.heading >= 0 && speedMps > kMovingSpeedMps) {
        heading = position.heading;
      }
      _offRouteFixes++;
      final clearlyGone = projection.offRouteMeters > _offRouteInstantMeters;
      if ((clearlyGone || _offRouteFixes >= _offRouteFixesBeforeReroute) &&
          _rerouteAllowed) {
        unawaited(_reroute(position));
      }
      notifyListeners();
      return;
    }
    _offRouteFixes = 0;
    offRoute = false;
    _segmentHint = projection.segmentIndex;
    snappedPosition = projection.snapped;

    // GPS course is noise at walking-pace speeds; use the route's own bearing.
    if (speedMps > kMovingSpeedMps && position.heading >= 0) {
      heading = position.heading;
    } else {
      final i = projection.segmentIndex;
      heading = bearingDegrees(route.shape[i], route.shape[i + 1]);
    }

    if (_detectWrongTurn(position, projection, previousRaw)) {
      unawaited(_reroute(position));
      notifyListeners();
      return;
    }

    _updateProgress(projection.alongRouteMeters);
    notifyListeners();


    int maniobraNumero = 3; // 3 = Seguir recto por defecto
    
    if (nextManeuver != null) {
      // Pasamos el texto a mayúsculas para evitar errores (ej: TURN_SLIGHT_LEFT)
      String tipoGoogle = nextManeuver!.type.toString().toUpperCase(); 
      
      if (tipoGoogle.contains('DESTINATION')) {
        maniobraNumero = 4; // Llegada
      } else if (tipoGoogle.contains('LEFT')) {
        maniobraNumero = 1; // Cubre TURN_LEFT, SLIGHT_LEFT, SHARP_LEFT, RAMP_LEFT
      } else if (tipoGoogle.contains('RIGHT')) {
        maniobraNumero = 2; // Cubre TURN_RIGHT, SLIGHT_RIGHT, SHARP_RIGHT, RAMP_RIGHT
      } else if (tipoGoogle.contains('UTURN')) {
        maniobraNumero = 5; // Opcional: si le programás una flecha de "Retorno en U" al visor
      }
    }

    _bleService.sendNavigationUpdate(
      maniobraNumero,
      distanceToNextManeuver.round(),
      remainingDistanceMeters.round(),
      speedKmh.round(),
      120,          // 120 km/h como límite de velocidad por defecto (puede ser dinámico si se implementa)
      ((1 - remainingDistanceMeters / route.distanceMeters) * 100).round(),
    );
  }

  /// Detects a wrong turn while still geometrically near the route:
  /// either the travel direction opposes the route's direction, or the user
  /// keeps moving without making progress along the route (parallel road,
  /// shortcut, closed-road detour).
  bool _detectWrongTurn(
    Position position,
    RouteProjection projection,
    LatLng? previousRaw,
  ) {
    final moving = speedMps > kMovingSpeedMps;

    // 1) Heading opposes the route (e.g. turned left instead of right,
    //    or U-turned). Suppressed near the maneuver point itself, where
    //    the bearing legitimately swings while turning.
    if (moving &&
        position.heading >= 0 &&
        distanceToNextManeuver > 40 &&
        speedMps > kWrongTurnSpeedMps) {
      final i = projection.segmentIndex;
      final segBearing = bearingDegrees(route.shape[i], route.shape[i + 1]);
      if (bearingDiff(position.heading, segBearing) > 100) {
        _wrongHeadingFixes++;
      } else {
        _wrongHeadingFixes = 0;
      }
      if (_wrongHeadingFixes >= 2 && _rerouteAllowed) {
        _wrongHeadingFixes = 0;
        return true;
      }
    } else {
      _wrongHeadingFixes = 0;
    }

    // 2) Moving without progressing along the route.
    if (moving && previousRaw != null) {
      _divergenceRawMeters += distanceMeters(previousRaw, rawPosition!);
      _divergenceProgressMeters +=
          (projection.alongRouteMeters - _lastAlongMeters).clamp(
            0,
            double.infinity,
          );
      if (_divergenceRawMeters > 45) {
        final diverging =
            _divergenceProgressMeters < _divergenceRawMeters * 0.4;
        _divergenceRawMeters = 0;
        _divergenceProgressMeters = 0;
        if (diverging && _rerouteAllowed) return true;
      }
    }
    _lastAlongMeters = projection.alongRouteMeters;
    return false;
  }

  void _updateProgress(double alongMeters) {
    final maneuvers = route.maneuvers;
    // Advance to the maneuver whose span contains our position.
    var current = 0;
    for (var i = 0; i < maneuvers.length; i++) {
      if (route.distanceAtShapeIndex(maneuvers[i].beginShapeIndex) <=
          alongMeters + 1) {
        current = i;
      } else {
        break;
      }
    }
    nextManeuverIndex = (current + 1).clamp(0, maneuvers.length - 1);

    final next = maneuvers[nextManeuverIndex];
    distanceToNextManeuver =
        (route.distanceAtShapeIndex(next.beginShapeIndex) - alongMeters).clamp(
          0,
          double.infinity,
        );
    remainingDistanceMeters = (route.distanceMeters - alongMeters).clamp(
      0,
      double.infinity,
    );

    // Scale remaining time: full time of untraveled maneuvers plus the
    // untraveled fraction of the one we're inside.
    var remaining = 0.0;
    for (var i = nextManeuverIndex; i < maneuvers.length; i++) {
      remaining += maneuvers[i].timeSeconds;
    }
    final inside = maneuvers[current];
    if (inside.lengthMeters > 0) {
      final maneuverStart = route.distanceAtShapeIndex(inside.beginShapeIndex);
      final fractionLeft =
          1 -
          ((alongMeters - maneuverStart) / inside.lengthMeters).clamp(0.0, 1.0);
      remaining += inside.timeSeconds * fractionLeft;
    }
    remainingTimeSeconds = remaining;

    if (nextManeuverIndex > current) _maybeAnnounce(next);

    if (remainingDistanceMeters < _arrivalRadiusMeters &&
        nextManeuverIndex >= maneuvers.length - 1) {
      arrived = true;
      _speak('You have arrived at your destination.');
      unawaited(_positionSub?.cancel());
    }
  }

  void _maybeAnnounce(RouteManeuver next) {
    final motorized = route.mode.motorized;
    final farMeters = motorized ? 500.0 : 120.0;
    final nowMeters = motorized ? 45.0 : 20.0;

    // The destination's "now" cue is the arrival announcement itself.
    final isFinal = nextManeuverIndex >= route.maneuvers.length - 1;

    if (distanceToNextManeuver <= nowMeters) {
      if (!isFinal) {
        _speakOnce(
          '$nextManeuverIndex:now',
          next.verbalPre ?? next.instruction,
        );
      }
    } else if (distanceToNextManeuver <= farMeters) {
      final alert = next.verbalAlert;
      if (alert != null) {
        _speakOnce('$nextManeuverIndex:far', alert);
      } else {
        _speakOnce(
          '$nextManeuverIndex:far',
          'In ${_spokenDistance(distanceToNextManeuver)}, ${next.instruction}',
        );
      }
    }
  }

  static String _spokenDistance(double meters) {
    final rounded = meters < 300
        ? (meters / 50).round() * 50
        : (meters / 100).round() * 100;
    return '$rounded meters';
  }

  int _rerouteId = 0;

  Future<void> _reroute(Position position) async {
    final id = ++_rerouteId;
    rerouting = true;
    _lastRerouteAt = DateTime.now();
    error = null;
    notifyListeners();
    _speak('Rerouting.');
    try {
      final routes = await _routing.getRoutes(
        from: LatLng(position.latitude, position.longitude),
        to: destination.point,
        mode: route.mode,
        alternates: 0,
        headingDegrees: position.heading >= 0 ? position.heading : null,
      );
      // Navigation ended, or a newer reroute superseded this one.
      if (_disposed || id != _rerouteId) return;
      route = routes.first;
      _segmentHint = 0;
      _offRouteFixes = 0;
      _wrongHeadingFixes = 0;
      _divergenceRawMeters = 0;
      _divergenceProgressMeters = 0;
      _lastAlongMeters = 0;
      nextManeuverIndex = 1;
      offRoute = false;
      _spokenCues.clear();
      remainingDistanceMeters = route.distanceMeters;
      remainingTimeSeconds = route.timeSeconds;
      // Announce the first instruction of the corrected route right away.
      final next = nextManeuver;
      if (next != null) {
        _speak(next.verbalAlert ?? next.instruction);
      }
    } on Exception catch (e) {
      if (_disposed || id != _rerouteId) return;
      logError('reroute', e);
      error = e is NoRouteException
          ? 'No route from here — keep driving'
          : 'Reroute failed — retrying as you move';
      _offRouteFixes = 0; // allow another attempt on subsequent fixes
    } finally {
      if (!_disposed && id == _rerouteId) {
        rerouting = false;
        notifyListeners();
      }
    }
  }

  void _speakOnce(String key, String text) {
    if (_spokenCues.add(key)) _speak(text);
  }

  void _speak(String text) {
    if (!_muted && !_disposed) unawaited(_speaker.speak(text));
  }

  @override
  void dispose() {
    _disposed = true;
    _rerouteId++; // abandon any in-flight reroute
    unawaited(_positionSub?.cancel());
    unawaited(_speaker.stop());
    super.dispose();
  }
}
