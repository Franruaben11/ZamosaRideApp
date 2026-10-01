import 'package:latlong2/latlong.dart';

class Place {
  final String name;
  final String? address;
  final LatLng point;

  /// OSM tag value, e.g. "restaurant", "fuel", "city".
  final String? category;

  final String? phone;
  final String? website;
  final String? openingHours;

  /// Wikidata id (e.g. "Q83063") — used to fetch a photo from Commons.
  final String? wikidata;

  /// Direct image URL from the OSM `image` tag, when present.
  final String? imageUrl;

  const Place({
    required this.name,
    required this.point,
    this.address,
    this.category,
    this.phone,
    this.website,
    this.openingHours,
    this.wikidata,
    this.imageUrl,
  });

  /// A bare coordinate pin (long-press, pasted coordinates, deep link).
  factory Place.pin(LatLng point, {String name = 'Dropped pin'}) =>
      Place(name: name, point: point);

  /// Fills in missing detail fields from [other] (same location, richer data).
  Place mergedWith(Place other) => Place(
    name: name,
    point: point,
    address: address ?? other.address,
    category: category ?? other.category,
    phone: phone ?? other.phone,
    website: website ?? other.website,
    openingHours: openingHours ?? other.openingHours,
    wikidata: wikidata ?? other.wikidata,
    imageUrl: imageUrl ?? other.imageUrl,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'address': address,
    'lat': point.latitude,
    'lon': point.longitude,
    'category': category,
    'phone': phone,
    'website': website,
    'openingHours': openingHours,
    'wikidata': wikidata,
    'imageUrl': imageUrl,
  };

  /// Tolerant decoder: optional fields of the wrong type are dropped rather
  /// than failing the whole entry. Throws [FormatException] only when the
  /// coordinates are missing or invalid.
  factory Place.fromJson(Map<String, dynamic> json) {
    final lat = json['lat'], lon = json['lon'];
    if (lat is! num || lon is! num) {
      throw const FormatException('Place without coordinates');
    }
    if (lat.abs() > 90 || lon.abs() > 180 || lat.isNaN || lon.isNaN) {
      throw const FormatException('Place with invalid coordinates');
    }
    String? str(String key) {
      final v = json[key];
      return v is String && v.isNotEmpty ? v : null;
    }

    final point = LatLng(lat.toDouble(), lon.toDouble());
    return Place(
      name:
          str('name') ??
          '${point.latitude.toStringAsFixed(5)}, ${point.longitude.toStringAsFixed(5)}',
      address: str('address'),
      point: point,
      category: str('category'),
      phone: str('phone'),
      website: str('website'),
      openingHours: str('openingHours'),
      wikidata: str('wikidata'),
      imageUrl: str('imageUrl'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Place &&
      other.name == name &&
      other.point.latitude == point.latitude &&
      other.point.longitude == point.longitude;

  @override
  int get hashCode => Object.hash(name, point.latitude, point.longitude);

  @override
  String toString() => 'Place($name @ $point)';
}
