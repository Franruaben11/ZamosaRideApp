import 'package:flutter/material.dart';

import '../models/nav_route.dart';
import '../services/overpass_service.dart';

/// UI-only icon mappings, kept out of the models/services layer so those
/// don't depend on Flutter's material library.
extension TravelModeIcon on TravelMode {
  IconData get icon => switch (this) {
    TravelMode.drive => Icons.directions_car,
    TravelMode.twoWheeler => Icons.two_wheeler,
    TravelMode.bike => Icons.directions_bike,
    TravelMode.walk => Icons.directions_walk,
  };
}

extension RouteManeuverIcon on RouteManeuver {
  IconData get icon => switch (type) {
    1 || 2 || 3 => Icons.trip_origin,
    4 || 5 || 6 => Icons.flag,
    7 || 8 || 17 || 22 => Icons.straight,
    9 || 23 => Icons.turn_slight_right,
    10 || 18 || 20 => Icons.turn_right,
    11 => Icons.turn_sharp_right,
    12 => Icons.u_turn_right,
    13 => Icons.u_turn_left,
    14 => Icons.turn_sharp_left,
    15 || 19 || 21 => Icons.turn_left,
    16 || 24 => Icons.turn_slight_left,
    25 || 37 || 38 => Icons.merge,
    26 || 27 => Icons.roundabout_right,
    28 || 29 => Icons.directions_boat,
    _ => Icons.navigation,
  };
}

extension PoiCategoryIcon on PoiCategory {
  IconData get icon => switch (value) {
    'restaurant' => Icons.restaurant,
    'cafe' => Icons.local_cafe,
    'fuel' => Icons.local_gas_station,
    'hotel' => Icons.hotel,
    'atm' => Icons.local_atm,
    'pharmacy' => Icons.local_pharmacy,
    'hospital' => Icons.local_hospital,
    'supermarket' => Icons.shopping_cart,
    'parking' => Icons.local_parking,
    'charging_station' => Icons.ev_station,
    _ => Icons.place,
  };
}

/// Icon for a place by its OSM category value (search results, recents).
IconData iconForCategory(String? category) => switch (category) {
  'restaurant' || 'fast_food' => Icons.restaurant,
  'cafe' => Icons.local_cafe,
  'fuel' => Icons.local_gas_station,
  'hotel' || 'guest_house' => Icons.hotel,
  'hospital' || 'clinic' => Icons.local_hospital,
  'pharmacy' => Icons.local_pharmacy,
  'supermarket' || 'convenience' || 'mall' => Icons.shopping_cart,
  'school' || 'university' || 'college' => Icons.school,
  'bank' || 'atm' => Icons.account_balance,
  'city' || 'town' || 'village' || 'hamlet' => Icons.location_city,
  'airport' || 'aerodrome' => Icons.flight,
  'station' || 'halt' || 'bus_stop' => Icons.directions_transit,
  'park' || 'garden' => Icons.park,
  'parking' => Icons.local_parking,
  'charging_station' => Icons.ev_station,
  _ => Icons.place,
};
