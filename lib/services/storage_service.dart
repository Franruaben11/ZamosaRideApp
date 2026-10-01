import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/place.dart';
import 'app_exception.dart';

/// Persists recent searches and saved (favorite) places locally.
///
/// Writes are serialised through a single queue so two overlapping
/// read-modify-write cycles (e.g. `addRecent` fired unawaited from the
/// search page while the map toggles a favourite) can't lose an update.
class StorageService {
  static const _recentsKey = 'recent_places';
  static const _savedKey = 'saved_places';
  static const _homeKey = 'home_place';
  static const _workKey = 'work_place';
  static const _maxRecents = 15;

  final Future<SharedPreferences> Function() _prefs;
  Future<void> _queue = Future.value();

  StorageService({Future<SharedPreferences> Function()? prefs})
    : _prefs = prefs ?? SharedPreferences.getInstance;

  Future<Place?> getHome() => _readOne(_homeKey);

  Future<Place?> getWork() => _readOne(_workKey);

  Future<void> setHome(Place? place) => _writeOne(_homeKey, place);

  Future<void> setWork(Place? place) => _writeOne(_workKey, place);

  Future<List<Place>> getRecents() => _read(_recentsKey);

  Future<List<Place>> getSaved() => _read(_savedKey);

  Future<void> addRecent(Place place) => _mutate(_recentsKey, (recents) {
    recents.removeWhere((p) => p == place);
    recents.insert(0, place);
    return recents.take(_maxRecents).toList();
  });

  Future<void> removeRecent(Place place) => _mutate(
    _recentsKey,
    (recents) => recents..removeWhere((p) => p == place),
  );

  Future<void> clearRecents() => _mutate(_recentsKey, (_) => []);

  Future<bool> isSaved(Place place) async => (await getSaved()).contains(place);

  Future<void> removeSaved(Place place) =>
      _mutate(_savedKey, (saved) => saved..removeWhere((p) => p == place));

  /// Returns true if the place is saved after the call.
  Future<bool> toggleSaved(Place place) async {
    var nowSaved = false;
    await _mutate(_savedKey, (saved) {
      final wasSaved = saved.contains(place);
      if (wasSaved) {
        saved.removeWhere((p) => p == place);
      } else {
        saved.insert(0, place);
      }
      nowSaved = !wasSaved;
      return saved;
    });
    return nowSaved;
  }

  /// Re-inserts a place at [index] (for Undo after a removal).
  Future<void> restoreSaved(Place place, {int index = 0}) =>
      _mutate(_savedKey, (saved) {
        saved.removeWhere((p) => p == place);
        saved.insert(index.clamp(0, saved.length), place);
        return saved;
      });

  Future<void> restoreRecent(Place place, {int index = 0}) =>
      _mutate(_recentsKey, (recents) {
        recents.removeWhere((p) => p == place);
        recents.insert(index.clamp(0, recents.length), place);
        return recents.take(_maxRecents).toList();
      });

  // ───────────────────────────────────────── internals

  Future<void> _mutate(
    String key,
    List<Place> Function(List<Place> current) update,
  ) {
    final task = _queue.then((_) async {
      final current = await _read(key);
      await _write(key, update(current));
    });
    // Keep the chain alive even if this task fails.
    _queue = task.catchError((Object e, StackTrace s) {
      logError('storage mutate $key', e, s);
    });
    return task;
  }

  Future<Place?> _readOne(String key) async {
    final prefs = await _prefs();
    final raw = prefs.getString(key);
    if (raw == null) return null;
    try {
      return Place.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on FormatException catch (e, s) {
      logError('storage read $key', e, s);
      return null;
    } on TypeError catch (e, s) {
      logError('storage read $key', e, s);
      return null;
    }
  }

  Future<void> _writeOne(String key, Place? place) {
    final task = _queue.then((_) async {
      final prefs = await _prefs();
      if (place == null) {
        await prefs.remove(key);
      } else {
        await prefs.setString(key, jsonEncode(place.toJson()));
      }
    });
    _queue = task.catchError((Object e, StackTrace s) {
      logError('storage write $key', e, s);
    });
    return task;
  }

  /// Decodes entry by entry: one corrupt record is skipped, never allowed
  /// to wipe the whole list on the next write.
  Future<List<Place>> _read(String key) async {
    final prefs = await _prefs();
    final raw = prefs.getString(key);
    if (raw == null) return [];
    return decodePlaces(raw, key: key);
  }

  static List<Place> decodePlaces(String raw, {String key = ''}) {
    final List<dynamic> list;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      list = decoded;
    } on FormatException catch (e) {
      logError('storage decode $key', e);
      return [];
    }
    final places = <Place>[];
    for (final j in list) {
      if (j is! Map<String, dynamic>) continue;
      try {
        places.add(Place.fromJson(j));
      } on FormatException catch (e) {
        logError('storage skip entry in $key', e);
      }
    }
    return places;
  }

  Future<void> _write(String key, List<Place> places) async {
    final prefs = await _prefs();
    await prefs.setString(
      key,
      jsonEncode(places.map((p) => p.toJson()).toList()),
    );
  }
}
