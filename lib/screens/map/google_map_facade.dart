import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gm;
import 'package:latlong2/latlong.dart';

class MapViewCamera {
  final LatLng center;
  final double zoom;
  final double rotation;
  final Size nonRotatedSize;

  const MapViewCamera({
    required this.center,
    required this.zoom,
    required this.rotation,
    required this.nonRotatedSize,
  });

  MapViewCamera copyWith({
    LatLng? center,
    double? zoom,
    double? rotation,
    Size? nonRotatedSize,
  }) {
    return MapViewCamera(
      center: center ?? this.center,
      zoom: zoom ?? this.zoom,
      rotation: rotation ?? this.rotation,
      nonRotatedSize: nonRotatedSize ?? this.nonRotatedSize,
    );
  }
}

class GoogleMapFacade {
  GoogleMapFacade({required MapViewCamera initialCamera})
    : camera = initialCamera;

  gm.GoogleMapController? _controller;
  MapViewCamera camera;
  int _programmaticMovesInFlight = 0;

  bool get ready => _controller != null;
  bool get programmaticMove => _programmaticMovesInFlight > 0;

  void attach(gm.GoogleMapController controller) {
    _controller = controller;
  }

  void updateViewportSize(Size size) {
    camera = camera.copyWith(nonRotatedSize: size);
  }

  void updateFromCameraPosition(gm.CameraPosition position) {
    camera = camera.copyWith(
      center: LatLng(position.target.latitude, position.target.longitude),
      zoom: position.zoom,
      rotation: position.bearing,
    );
  }

  void _runProgrammatic(
    Future<void> Function(gm.GoogleMapController controller) action,
  ) {
    final controller = _controller;
    if (controller == null) return;
    _programmaticMovesInFlight++;
    unawaited(
      action(controller).whenComplete(() {
        if (_programmaticMovesInFlight > 0) {
          _programmaticMovesInFlight--;
        }
      }),
    );
  }

  void move(LatLng center, double zoom, {Duration? duration}) {
    camera = camera.copyWith(center: center, zoom: zoom);
    _runProgrammatic(
      (controller) => controller.animateCamera(
        gm.CameraUpdate.newCameraPosition(
          gm.CameraPosition(
            target: gm.LatLng(center.latitude, center.longitude),
            zoom: zoom,
            bearing: camera.rotation,
          ),
        ),
        duration: duration,
      ),
    );
  }

  void moveAndRotate(
    LatLng center,
    double zoom,
    double rotation, {
    Duration? duration,
  }) {
    final normalizedBearing = (rotation % 360 + 360) % 360;
    camera = camera.copyWith(
      center: center,
      zoom: zoom,
      rotation: normalizedBearing,
    );
    _runProgrammatic(
      (controller) => controller.animateCamera(
        gm.CameraUpdate.newCameraPosition(
          gm.CameraPosition(
            target: gm.LatLng(center.latitude, center.longitude),
            zoom: zoom,
            bearing: normalizedBearing,
          ),
        ),
        duration: duration,
      ),
    );
  }

  void rotate(double rotation, {Duration? duration}) {
    final normalizedBearing = (rotation % 360 + 360) % 360;
    camera = camera.copyWith(rotation: normalizedBearing);
    _runProgrammatic(
      (controller) => controller.animateCamera(
        gm.CameraUpdate.newCameraPosition(
          gm.CameraPosition(
            target: gm.LatLng(
              camera.center.latitude,
              camera.center.longitude,
            ),
            zoom: camera.zoom,
            bearing: normalizedBearing,
          ),
        ),
        duration: duration,
      ),
    );
  }

  void fitCamera(
    List<LatLng> coordinates, {
    EdgeInsets padding = EdgeInsets.zero,
  }) {
    if (_controller == null || coordinates.isEmpty) return;
    final bounds = _boundsFor(coordinates);
    if (bounds == null) return;
    final paddingPx = math.max(
      math.max(padding.left, padding.right),
      math.max(padding.top, padding.bottom),
    ).round();
    final center = _centerOfBounds(bounds);
    camera = camera.copyWith(center: center);
    _runProgrammatic(
      (controller) => controller.animateCamera(
        gm.CameraUpdate.newLatLngBounds(bounds, paddingPx.toDouble()),
      ),
    );
  }

  void stop() {
    _programmaticMovesInFlight = 0;
  }

  void dispose() {}

  gm.LatLngBounds? _boundsFor(List<LatLng> coordinates) {
    var minLat = coordinates.first.latitude;
    var maxLat = coordinates.first.latitude;
    var minLng = coordinates.first.longitude;
    var maxLng = coordinates.first.longitude;
    for (final point in coordinates.skip(1)) {
      if (point.latitude < minLat) minLat = point.latitude;
      if (point.latitude > maxLat) maxLat = point.latitude;
      if (point.longitude < minLng) minLng = point.longitude;
      if (point.longitude > maxLng) maxLng = point.longitude;
    }
    if (minLat == maxLat && minLng == maxLng) return null;
    return gm.LatLngBounds(
      southwest: gm.LatLng(minLat, minLng),
      northeast: gm.LatLng(maxLat, maxLng),
    );
  }

  LatLng _centerOfBounds(gm.LatLngBounds bounds) {
    return LatLng(
      (bounds.northeast.latitude + bounds.southwest.latitude) / 2,
      (bounds.northeast.longitude + bounds.southwest.longitude) / 2,
    );
  }
}
