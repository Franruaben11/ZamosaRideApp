import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_exception.dart';

/// How hard the basemap works per frame.
enum RenderQuality {
  /// [smooth]: pre-rendered tiles scale on the GPU during gestures, which
  /// is what makes zooming feel continuous (live vector redraw dropped
  /// 10-20% of frames while pinching even on a mid-range phone, and most
  /// frames while navigating). The other modes stay available in Settings.
  auto,

  /// True vector rendering: every fractional zoom is redrawn, crispest.
  quality,

  /// Tiles pre-rendered to bitmaps off the UI thread and scaled between
  /// zoom levels — the frame rate of a raster map. For low-end devices.
  smooth,

  /// Foveated: [smooth] bitmaps across the screen, [quality] vector
  /// rendering only in the centre where the eye is. The balance.
  foveated;

  String get label => switch (this) {
    RenderQuality.auto => 'Auto',
    RenderQuality.quality => 'Sharp',
    RenderQuality.foveated => 'Focus',
    RenderQuality.smooth => 'Smooth',
  };

  String get description => switch (this) {
    RenderQuality.smooth =>
      'Tiles pre-rendered at screen resolution; zooming and rotating stay at full frame rate.',
    RenderQuality.foveated =>
      'Sharp vector rendering in the centre of the screen, pre-rendered tiles around it.',
    RenderQuality.quality =>
      'Live vector rendering, crispest at fractional zooms; heavier while moving.',
    RenderQuality.auto => 'Pre-rendered tiles (Smooth).',
  };
}

class RenderQualitySettings {
  RenderQualitySettings._();

  static const _key = 'render_quality';

  /// The user's choice; [RenderQuality.auto] unless overridden.
  static final ValueNotifier<RenderQuality> choice = ValueNotifier(
    RenderQuality.auto,
  );

  /// What the map actually uses ([auto] resolves to [smooth]).
  static RenderQuality get effective => switch (choice.value) {
    RenderQuality.auto => RenderQuality.smooth,
    final q => q,
  };

  /// Dev override, e.g. `--dart-define=OM_QUALITY=foveated`.
  static const _devQuality = String.fromEnvironment('OM_QUALITY');

  static Future<void> load() async {
    for (final q in RenderQuality.values) {
      if (q.name == _devQuality) {
        choice.value = q;
        return;
      }
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final i = prefs.getInt(_key);
      if (i != null && i >= 0 && i < RenderQuality.values.length) {
        choice.value = RenderQuality.values[i];
      }
    } on Exception catch (e, s) {
      logError('render quality load', e, s);
    }
  }

  static Future<void> set(RenderQuality q) async {
    choice.value = q;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_key, q.index);
    } on Exception catch (e, s) {
      logError('render quality save', e, s);
    }
  }

  /// Few cores or little RAM: isolate-rendered vectors can't keep up.
  static final bool isLowEndDevice = _detectLowEnd();

  static bool _detectLowEnd() {
    if (kIsWeb) return false;
    try {
      if (Platform.numberOfProcessors <= 4) return true;
      if (Platform.isAndroid || Platform.isLinux) {
        final mem = File('/proc/meminfo').readAsLinesSync().firstWhere(
          (l) => l.startsWith('MemTotal:'),
          orElse: () => '',
        );
        final kb = int.tryParse(RegExp(r'\d+').firstMatch(mem)?.group(0) ?? '');
        if (kb != null && kb < 4 * 1024 * 1024) return true; // < 4 GB
      }
    } on FileSystemException {
      // /proc unavailable on some builds; assume a capable device.
    }
    return false;
  }
}
