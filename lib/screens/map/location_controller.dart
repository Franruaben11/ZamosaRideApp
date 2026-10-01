import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../services/app_exception.dart';

enum LocationStatus {
  /// Not started — permission has never been asked for.
  idle,

  /// Permission granted, waiting for the first fix.
  locating,

  /// Delivering fixes.
  ready,

  /// Permission refused this time (can ask again).
  denied,

  /// Permission refused permanently; only the OS settings can change it.
  deniedForever,

  /// Location services are switched off device-wide.
  servicesOff,

  /// Stream failed for another reason.
  error,
}

/// Owns the browse-mode GPS subscription and the permission flow.
///
/// * Never prompts on its own: [startIfPermitted] (cold start) only subscribes
///   when permission was already granted; [ensureStarted] (user tapped the
///   location button) is the one that shows the system prompt.
/// * Subscribes to the stream first, then seeds with the last known fix and
///   a bounded one-shot, so a slow GPS never blocks the blue dot.
/// * [pause] / [resume] let the screen stop the stream while backgrounded or
///   while the navigation engine runs its own, more precise one.
class LocationController {
  final position = ValueNotifier<LatLng?>(null);

  /// GPS course in degrees (only updated while it is valid).
  final heading = ValueNotifier<double>(0);

  /// Horizontal accuracy of the last fix, metres.
  final accuracy = ValueNotifier<double>(0);
  final status = ValueNotifier<LocationStatus>(LocationStatus.idle);

  static const _browseSettings = LocationSettings(
    accuracy: LocationAccuracy.high,
    distanceFilter: 8,
  );

  StreamSubscription<Position>? _sub;
  bool _paused = false;
  bool _subscribed = false;
  bool _disposed = false;
  Completer<LatLng>? _firstFix;

  LatLng? get current => position.value;
  bool get isPaused => _paused;

  /// Cold-start path: start only when no prompt would be shown.
  Future<bool> startIfPermitted() async {
    try {
      final permission = await Geolocator.checkPermission();
      if (permission != LocationPermission.whileInUse &&
          permission != LocationPermission.always) {
        return false;
      }
      if (!await Geolocator.isLocationServiceEnabled()) {
        return false;
      }
      _subscribe();
      return true;
    } on Exception catch (e, s) {
      logError('location check', e, s);
      return false;
    }
  }

  /// User-initiated path: prompt if needed, then start. Returns the
  /// resulting status so the caller can explain a refusal.
  Future<LocationStatus> ensureStarted() async {
    if (_subscribed && !_paused) return status.value;
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return status.value = LocationStatus.servicesOff;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      switch (permission) {
        case LocationPermission.deniedForever:
          return status.value = LocationStatus.deniedForever;
        case LocationPermission.denied:
        case LocationPermission.unableToDetermine:
          return status.value = LocationStatus.denied;
        case LocationPermission.whileInUse:
        case LocationPermission.always:
          if (_paused) {
            resume();
          } else {
            _subscribe();
          }
          return status.value;
      }
    } on Exception catch (e, s) {
      logError('location permission', e, s);
      return status.value = LocationStatus.error;
    }
  }

  /// Completes with the first fix (or the current one), or throws
  /// [TimeoutException].
  Future<LatLng> waitForFix({Duration timeout = const Duration(seconds: 10)}) {
    final now = position.value;
    if (now != null) return Future.value(now);
    final c = _firstFix ??= Completer<LatLng>();
    return c.future.timeout(timeout);
  }

  void _subscribe() {
    if (_disposed || _subscribed) return;
    _subscribed = true;
    if (position.value == null) status.value = LocationStatus.locating;

    _sub = Geolocator.getPositionStream(
      locationSettings: _browseSettings,
    ).listen(_onPosition, onError: _onError);

    // Instant first paint from the OS cache, then a bounded fresh fix.
    unawaited(_seed());
  }

  Future<void> _seed() async {
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null && position.value == null) _onPosition(last);
    } on Exception catch (e) {
      logError('last known position', e);
    }
    try {
      final fresh = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 8),
        ),
      );
      _onPosition(fresh);
    } on Exception catch (e) {
      // The stream will deliver one when the GPS warms up.
      logError('one-shot position', e);
    }
  }

  void _onPosition(Position p) {
    if (_disposed) return;
    position.value = LatLng(p.latitude, p.longitude);
    accuracy.value = p.accuracy;
    if (p.heading >= 0) heading.value = p.heading;
    status.value = LocationStatus.ready;
    final c = _firstFix;
    if (c != null && !c.isCompleted) c.complete(position.value);
    _firstFix = null;
  }

  void _onError(Object e) {
    if (_disposed) return;
    logError('position stream', e);
    if (e is LocationServiceDisabledException) {
      status.value = LocationStatus.servicesOff;
    } else if (e is PermissionDeniedException) {
      status.value = LocationStatus.denied;
    } else {
      status.value = LocationStatus.error;
    }
    // Restart cleanly next time instead of holding a dead subscription.
    unawaited(_sub?.cancel());
    _sub = null;
    _subscribed = false;
  }

  /// Stops fixes (battery) without forgetting the last position.
  ///
  /// This *cancels* the subscription rather than pausing it: geolocator
  /// shares one platform stream between all listeners, so a paused
  /// subscription keeps the GPS running, and the stream's settings are fixed
  /// by whoever subscribed first. Cancelling lets the navigation engine
  /// open the stream with its own (foreground-service) settings.
  void pause() {
    if (_paused || !_subscribed) return;
    _paused = true;
    unawaited(_sub?.cancel());
    _sub = null;
    _subscribed = false;
  }

  void resume() {
    if (!_paused) return;
    _paused = false;
    _subscribe();
  }

  void dispose() {
    _disposed = true;
    unawaited(_sub?.cancel());
    position.dispose();
    heading.dispose();
    accuracy.dispose();
    status.dispose();
  }
}
