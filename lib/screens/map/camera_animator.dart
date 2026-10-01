import 'dart:async';

import 'package:flutter/animation.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// Smoothly moves a [MapController]'s camera. One [AnimationController] is
/// reused for every move (navigation issues one per GPS fix), and nothing
/// happens until [ready] is set from `onMapReady`.
class CameraAnimator {
  final MapController map;
  late final AnimationController _controller;

  bool ready = false;

  // Tweens for the move in progress.
  Tween<double> _lat = Tween(begin: 0, end: 0);
  Tween<double> _lng = Tween(begin: 0, end: 0);
  Tween<double> _zoom = Tween(begin: 0, end: 0);
  Tween<double> _rot = Tween(begin: 0, end: 0);
  Animation<double> _curve = const AlwaysStoppedAnimation(0);

  CameraAnimator({required TickerProvider vsync, required this.map}) {
    _controller = AnimationController(vsync: vsync)..addListener(_tick);
  }

  void _tick() {
    map.moveAndRotate(
      LatLng(_lat.evaluate(_curve), _lng.evaluate(_curve)),
      _zoom.evaluate(_curve),
      _rot.evaluate(_curve),
    );
  }

  /// Animates to [center] (and optionally [zoom] / [rotation], in degrees),
  /// taking the shortest way round for rotation.
  void animateTo({
    required LatLng center,
    double? zoom,
    double? rotation,
    Duration duration = const Duration(milliseconds: 600),
    Curve curve = Curves.easeInOut,
  }) {
    if (!ready) return;
    final camera = map.camera;
    final beginRot = camera.rotation;
    var delta = (rotation ?? beginRot) - beginRot;
    while (delta > 180) {
      delta -= 360;
    }
    while (delta < -180) {
      delta += 360;
    }

    _controller.stop();
    _lat = Tween(begin: camera.center.latitude, end: center.latitude);
    _lng = Tween(begin: camera.center.longitude, end: center.longitude);
    _zoom = Tween(begin: camera.zoom, end: zoom ?? camera.zoom);
    _rot = Tween(begin: beginRot, end: beginRot + delta);
    _controller.duration = duration;
    _curve = CurvedAnimation(parent: _controller, curve: curve);
    unawaited(_controller.forward(from: 0));
  }

  /// Stops any running animation (before a manual `move`/`fitCamera`).
  void stop() => _controller.stop();

  /// Fits the camera instantly, cancelling any animation.
  void fit(CameraFit fit) {
    if (!ready) return;
    stop();
    map.fitCamera(fit);
  }

  void dispose() => _controller.dispose();
}
