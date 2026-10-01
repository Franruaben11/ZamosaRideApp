import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:open_maps/models/place.dart';
import 'package:open_maps/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const a = Place(name: 'Charminar', point: LatLng(17.3616, 78.4747));
  const b = Place(name: 'Golconda', point: LatLng(17.3833, 78.4011));
  const c = Place(name: 'Hussain Sagar', point: LatLng(17.4239, 78.4738));

  late StorageService storage;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    storage = StorageService();
  });

  test('recents round-trip, dedupe and cap at 15', () async {
    await storage.addRecent(a);
    await storage.addRecent(b);
    await storage.addRecent(a);
    expect(await storage.getRecents(), [a, b]);

    for (var i = 0; i < 20; i++) {
      await storage.addRecent(Place(name: 'p$i', point: LatLng(i / 100, 0)));
    }
    expect((await storage.getRecents()).length, 15);
  });

  test('saved places toggle and report state', () async {
    expect(await storage.isSaved(a), isFalse);
    expect(await storage.toggleSaved(a), isTrue);
    expect(await storage.isSaved(a), isTrue);
    expect(await storage.toggleSaved(a), isFalse);
    expect(await storage.getSaved(), isEmpty);
  });

  test('remove / restore / clear', () async {
    await storage.addRecent(a);
    await storage.addRecent(b);
    await storage.addRecent(c);
    await storage.removeRecent(b);
    expect(await storage.getRecents(), [c, a]);
    await storage.restoreRecent(b, index: 1);
    expect(await storage.getRecents(), [c, b, a]);
    await storage.clearRecents();
    expect(await storage.getRecents(), isEmpty);

    await storage.toggleSaved(a);
    await storage.toggleSaved(b);
    await storage.removeSaved(a);
    expect(await storage.getSaved(), [b]);
    await storage.restoreSaved(a, index: 5);
    expect(await storage.getSaved(), [b, a]);
  });

  test('home and work', () async {
    expect(await storage.getHome(), isNull);
    await storage.setHome(a);
    await storage.setWork(b);
    expect(await storage.getHome(), a);
    expect(await storage.getWork(), b);
    await storage.setHome(null);
    expect(await storage.getHome(), isNull);
  });

  test(
    'one corrupt entry is skipped and the rest survive the next write',
    () async {
      SharedPreferences.setMockInitialValues({
        'saved_places': jsonEncode([
          a.toJson(),
          {'name': 'no coordinates'},
          {'lat': 'NaN', 'lon': 1},
          b.toJson(),
          'garbage',
        ]),
      });
      storage = StorageService();
      expect(await storage.getSaved(), [a, b]);

      await storage.toggleSaved(c);
      expect(await storage.getSaved(), [c, a, b]);
    },
  );

  test('entirely corrupt blob reads as empty', () async {
    SharedPreferences.setMockInitialValues({'recent_places': '{not json'});
    storage = StorageService();
    expect(await storage.getRecents(), isEmpty);
  });

  test('overlapping unawaited writes are serialised', () async {
    await Future.wait([
      storage.addRecent(a),
      storage.addRecent(b),
      storage.toggleSaved(c),
      storage.addRecent(c),
    ]);
    expect(await storage.getRecents(), [c, b, a]);
    expect(await storage.getSaved(), [c]);
  });
}
