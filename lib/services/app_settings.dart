import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/nav_route.dart';
import '../util/units.dart';
import 'app_exception.dart';

/// Last camera position, restored on the next launch.
class SavedCamera {
  final LatLng center;
  final double zoom;
  const SavedCamera(this.center, this.zoom);
}

/// User preferences and small bits of session state that should survive a
/// restart. Every value is a [ValueNotifier] so widgets can listen to just
/// the one they care about; [load] must complete before the first frame.
class AppSettings {
  AppSettings._();

  static const _unitsKey = 'units';
  static const _themeKey = 'theme_mode';
  static const _voiceKey = 'voice_guidance';
  static const _modeKey = 'travel_mode';
  static const _optionsKey = 'route_options';
  static const _layerKey = 'map_layer';
  static const _cameraKey = 'last_camera';

  static final units = ValueNotifier<Units>(Units.metric);
  static final themeMode = ValueNotifier<ThemeMode>(ThemeMode.system);
  static final voiceGuidance = ValueNotifier<bool>(true);
  static final travelMode = ValueNotifier<TravelMode>(TravelMode.drive);
  static final routeOptions = ValueNotifier<RouteOptions>(const RouteOptions());

  /// Name of the selected `MapLayerStyle`, or null for the default.
  static final layerName = ValueNotifier<String?>(null);

  static SavedCamera? lastCamera;

  static SharedPreferences? _prefs;

  static Future<void> load() async {
    try {
      final prefs = _prefs ??= await SharedPreferences.getInstance();

      final unitsName = prefs.getString(_unitsKey);
      units.value =
          Units.values.asNameMap()[unitsName] ??
          Units.forCountry(PlatformDispatcher.instance.locale.countryCode);
      Units.current = units.value;

      themeMode.value =
          ThemeMode.values.asNameMap()[prefs.getString(_themeKey)] ??
          ThemeMode.system;
      voiceGuidance.value = prefs.getBool(_voiceKey) ?? true;
      travelMode.value =
          TravelMode.values.asNameMap()[prefs.getString(_modeKey)] ??
          TravelMode.drive;
      final optionsRaw = prefs.getString(_optionsKey);
      if (optionsRaw != null) {
        routeOptions.value = RouteOptions.fromJson(
          jsonDecode(optionsRaw) as Map<String, dynamic>,
        );
      }
      layerName.value = prefs.getString(_layerKey);
      final cam = prefs.getStringList(_cameraKey);
      if (cam != null && cam.length == 3) {
        final lat = double.tryParse(cam[0]);
        final lng = double.tryParse(cam[1]);
        final zoom = double.tryParse(cam[2]);
        if (lat != null && lng != null && zoom != null) {
          lastCamera = SavedCamera(LatLng(lat, lng), zoom);
        }
      }
      // Corrupt prefs must never block startup; defaults are fine.
      // ignore: avoid_catches_without_on_clauses
    } catch (e, s) {
      logError('settings load', e, s);
    }

    units.addListener(() {
      Units.current = units.value;
      _save((p) => p.setString(_unitsKey, units.value.name));
    });
    themeMode.addListener(
      () => _save((p) => p.setString(_themeKey, themeMode.value.name)),
    );
    voiceGuidance.addListener(
      () => _save((p) => p.setBool(_voiceKey, voiceGuidance.value)),
    );
    travelMode.addListener(
      () => _save((p) => p.setString(_modeKey, travelMode.value.name)),
    );
    routeOptions.addListener(
      () => _save(
        (p) =>
            p.setString(_optionsKey, jsonEncode(routeOptions.value.toJson())),
      ),
    );
    layerName.addListener(
      () => _save((p) {
        final name = layerName.value;
        return name == null
            ? p.remove(_layerKey)
            : p.setString(_layerKey, name);
      }),
    );
  }

  /// Remembers the camera; call from a debounced `onPositionChanged`.
  static void saveCamera(LatLng center, double zoom) {
    lastCamera = SavedCamera(center, zoom);
    unawaited(
      _put(
        (p) => p.setStringList(_cameraKey, [
          center.latitude.toStringAsFixed(6),
          center.longitude.toStringAsFixed(6),
          zoom.toStringAsFixed(2),
        ]),
      ),
    );
  }

  /// Fire-and-forget persistence for listener callbacks.
  static void _save(Future<bool> Function(SharedPreferences prefs) write) =>
      unawaited(_put(write));

  static Future<void> _put(
    Future<bool> Function(SharedPreferences prefs) write,
  ) async {
    try {
      final prefs = _prefs ??= await SharedPreferences.getInstance();
      await write(prefs);
    } on Exception catch (e, s) {
      logError('settings save', e, s);
    }
  }

  /// Test hook: drop the cached instance so `setMockInitialValues` applies.
  @visibleForTesting
  static void resetForTest() => _prefs = null;
}
