import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import 'google_map_facade.dart';

/// Smoothly moves a [GoogleMapFacade]'s camera by delegating interpolation to
/// the native Google Maps engine (1 platform-channel call per camera target
/// update instead of 60–120 calls per second).
class CameraAnimator {
  final GoogleMapFacade map;

  bool ready = false;

  CameraAnimator({required TickerProvider vsync, required this.map});

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

    map.moveAndRotate(
      center,
      zoom ?? camera.zoom,
      beginRot + delta,
      duration: duration,
    );
  }

  /// Resets the programmatic move state before a manual gesture or fit.
  void stop() => map.stop();

  /// Fits the camera to [coordinates].
  void fit(List<LatLng> coordinates, {EdgeInsets padding = EdgeInsets.zero}) {
    if (!ready) return;
    stop();
    map.fitCamera(coordinates, padding: padding);
  }

  void dispose() {}
}
