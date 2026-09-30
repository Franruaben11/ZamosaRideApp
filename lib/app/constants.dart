import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';

class AppConstants {
  // For the flutter community
  // This is a sample app to demonstrate the usage of Mapbox Maps in Flutter.
  // The app is not intended for production use and is only for educational purposes.
  // You can use this app as a reference to build your own app using Mapbox Maps in Flutter.
  static const String appName = 'Flutter Mapbox Example';
  static const String appVersion = '1.0.0';
  static const String appUrl = 'https://afgrogrammer.com';

  static String get mapboxToken {
    const fromDefine = String.fromEnvironment('ACCESS_TOKEN', defaultValue: '');
    if (fromDefine.isNotEmpty) return fromDefine;

    const fromMapboxDefine = String.fromEnvironment('MAPBOX_TOKEN', defaultValue: '');
    if (fromMapboxDefine.isNotEmpty) return fromMapboxDefine;

    return dotenv.env['ACCESS_TOKEN'] ?? dotenv.env['MAPBOX_TOKEN'] ?? '';
  }

  static const String mapboxStyleID = MapboxStyles.MAPBOX_STREETS;
}
