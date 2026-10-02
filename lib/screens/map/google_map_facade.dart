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
  bool _programmaticMove = false;

  bool get ready => _controller != null;
  bool get programmaticMove => _programmaticMove;

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

  void move(LatLng center, double zoom) {
    final controller = _controller;
    if (controller == null) return;
    camera = camera.copyWith(center: center, zoom: zoom);
    _programmaticMove = true;
    unawaited(
      controller
          .animateCamera(
            gm.CameraUpdate.newCameraPosition(
              gm.CameraPosition(
                target: gm.LatLng(center.latitude, center.longitude),
                zoom: zoom,
                bearing: camera.rotation,
              ),
            ),
          )
          .whenComplete(() => _programmaticMove = false),
    );
  }

  void moveAndRotate(LatLng center, double zoom, double rotation) {
    final controller = _controller;
    if (controller == null) return;
    camera = camera.copyWith(center: center, zoom: zoom, rotation: rotation);
    _programmaticMove = true;
    unawaited(
      controller.animateCamera(
        gm.CameraUpdate.newCameraPosition(
          gm.CameraPosition(
            target: gm.LatLng(center.latitude, center.longitude),
            zoom: zoom,
            bearing: rotation,
          ),
        ),
      ).whenComplete(() => _programmaticMove = false),
    );
  }

  void rotate(double rotation) {
    final controller = _controller;
    if (controller == null) return;
    camera = camera.copyWith(rotation: rotation);
    _programmaticMove = true;
    unawaited(
      controller
          .animateCamera(
            gm.CameraUpdate.newCameraPosition(
              gm.CameraPosition(
                target: gm.LatLng(camera.center.latitude, camera.center.longitude),
                zoom: camera.zoom,
                bearing: rotation,
              ),
            ),
          )
          .whenComplete(() => _programmaticMove = false),
    );
  }

  void fitCamera(List<LatLng> coordinates, {EdgeInsets padding = EdgeInsets.zero}) {
    final controller = _controller;
    if (controller == null || coordinates.isEmpty) return;
    final bounds = _boundsFor(coordinates);
    if (bounds == null) return;
    final paddingPx = math.max(
      math.max(padding.left, padding.right),
      math.max(padding.top, padding.bottom),
    ).round();
    _programmaticMove = true;
    final center = _centerOfBounds(bounds);
    camera = camera.copyWith(center: center);
    unawaited(
      controller
          .animateCamera(
            gm.CameraUpdate.newLatLngBounds(bounds, paddingPx.toDouble()),
          )
          .whenComplete(() => _programmaticMove = false),
    );
  }

  void stop() {
    _programmaticMove = false;
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
