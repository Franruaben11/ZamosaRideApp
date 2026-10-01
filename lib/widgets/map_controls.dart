import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../screens/map/location_controller.dart';

/// The floating button column on the right of the map: compass (only while
/// rotated), layers, zoom and my-location.
class MapControls extends StatelessWidget {
  final ValueListenable<double> rotation;
  final ValueListenable<LocationStatus> locationStatus;
  final bool headingMode;
  final VoidCallback onResetRotation;
  final VoidCallback onLayers;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onMyLocation;

  const MapControls({
    super.key,
    required this.rotation,
    required this.locationStatus,
    required this.headingMode,
    required this.onResetRotation,
    required this.onLayers,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onMyLocation,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Compass appears only while the map is rotated.
        ValueListenableBuilder<double>(
          valueListenable: rotation,
          builder: (context, rotation, _) => rotation.abs() <= 1
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: FloatingActionButton.small(
                    heroTag: 'compass',
                    tooltip: 'Reset to north',
                    onPressed: onResetRotation,
                    child: Transform.rotate(
                      angle: rotation * math.pi / 180,
                      child: const Icon(Icons.explore),
                    ),
                  ),
                ),
        ),
        FloatingActionButton.small(
          heroTag: 'layers',
          tooltip: 'Map type',
          onPressed: onLayers,
          child: const Icon(Icons.layers),
        ),
        const SizedBox(height: 8),
        FloatingActionButton.small(
          heroTag: 'zoom_in',
          tooltip: 'Zoom in',
          onPressed: onZoomIn,
          child: const Icon(Icons.add),
        ),
        const SizedBox(height: 8),
        FloatingActionButton.small(
          heroTag: 'zoom_out',
          tooltip: 'Zoom out',
          onPressed: onZoomOut,
          child: const Icon(Icons.remove),
        ),
        const SizedBox(height: 8),
        ValueListenableBuilder<LocationStatus>(
          valueListenable: locationStatus,
          builder: (context, status, _) {
            final locating = status == LocationStatus.locating;
            final blocked =
                status == LocationStatus.deniedForever ||
                status == LocationStatus.servicesOff;
            return FloatingActionButton.small(
              heroTag: 'my_location',
              onPressed: onMyLocation,
              tooltip: headingMode
                  ? 'Exit compass mode'
                  : locating
                  ? 'Locating…'
                  : blocked
                  ? 'Location unavailable — tap for help'
                  : 'My location',
              child: locating
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      headingMode
                          ? Icons.explore
                          : blocked
                          ? Icons.location_disabled
                          : Icons.my_location,
                    ),
            );
          },
        ),
      ],
    );
  }
}
