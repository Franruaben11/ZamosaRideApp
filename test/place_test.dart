import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:open_maps/models/place.dart';

void main() {
  test('toJson / fromJson round-trip keeps every field', () {
    const place = Place(
      name: 'Café',
      address: '1 Road, City',
      point: LatLng(12.345678, 98.765432),
      category: 'cafe',
      phone: '+91 40 1234',
      website: 'example.com',
      openingHours: 'Mo-Su 08:00-22:00',
      wikidata: 'Q1',
      imageUrl: 'https://example.com/a.jpg',
    );
    final copy = Place.fromJson(place.toJson());
    expect(copy, place);
    expect(copy.address, place.address);
    expect(copy.category, place.category);
    expect(copy.phone, place.phone);
    expect(copy.website, place.website);
    expect(copy.openingHours, place.openingHours);
    expect(copy.wikidata, place.wikidata);
    expect(copy.imageUrl, place.imageUrl);
  });

  test('fromJson tolerates a missing name and wrong-typed optionals', () {
    final place = Place.fromJson({
      'lat': 1.5,
      'lon': 2.5,
      'phone': 12345,
      'address': '',
    });
    expect(place.name, '1.50000, 2.50000');
    expect(place.phone, isNull);
    expect(place.address, isNull);
    expect(place.point, const LatLng(1.5, 2.5));
  });

  test('fromJson rejects missing or out-of-range coordinates', () {
    expect(() => Place.fromJson({'name': 'x'}), throwsFormatException);
    expect(
      () => Place.fromJson({'name': 'x', 'lat': 95, 'lon': 0}),
      throwsFormatException,
    );
    expect(
      () => Place.fromJson({'name': 'x', 'lat': '1', 'lon': 0}),
      throwsFormatException,
    );
  });

  test('mergedWith fills gaps only', () {
    const thin = Place(name: 'A', point: LatLng(0, 0), phone: '1');
    const rich = Place(
      name: 'B',
      point: LatLng(0, 0),
      phone: '2',
      website: 'w',
      wikidata: 'Q2',
    );
    final merged = thin.mergedWith(rich);
    expect(merged.name, 'A');
    expect(merged.phone, '1');
    expect(merged.website, 'w');
    expect(merged.wikidata, 'Q2');
  });
}
