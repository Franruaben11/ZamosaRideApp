import 'package:latlong2/latlong.dart';

import '../util/geo.dart';

enum TravelMode { drive, twoWheeler, bike, walk }

extension TravelModeInfo on TravelMode {
  String get valhallaCosting => switch (this) {
    TravelMode.drive => 'auto',
    TravelMode.twoWheeler => 'motor_scooter',
    TravelMode.bike => 'bicycle',
    TravelMode.walk => 'pedestrian',
  };

  String get label => switch (this) {
    TravelMode.drive => 'Drive',
    TravelMode.twoWheeler => '2-wheeler',
    TravelMode.bike => 'Bike',
    TravelMode.walk => 'Walk',
  };

  /// Motorized modes get voice prompts earlier and support road-avoidance
  /// preferences.
  bool get motorized =>
      this == TravelMode.drive || this == TravelMode.twoWheeler;
}

/// User routing preferences (Google Maps' "Route options").
class RouteOptions {
  final bool avoidTolls;
  final bool avoidHighways;
  final bool avoidFerries;

  const RouteOptions({
    this.avoidTolls = false,
    this.avoidHighways = false,
    this.avoidFerries = false,
  });

  RouteOptions copyWith({
    bool? avoidTolls,
    bool? avoidHighways,
    bool? avoidFerries,
  }) => RouteOptions(
    avoidTolls: avoidTolls ?? this.avoidTolls,
    avoidHighways: avoidHighways ?? this.avoidHighways,
    avoidFerries: avoidFerries ?? this.avoidFerries,
  );

  bool get any => avoidTolls || avoidHighways || avoidFerries;

  Map<String, dynamic> toJson() => {
    'avoidTolls': avoidTolls,
    'avoidHighways': avoidHighways,
    'avoidFerries': avoidFerries,
  };

  factory RouteOptions.fromJson(Map<String, dynamic> json) => RouteOptions(
    avoidTolls: json['avoidTolls'] == true,
    avoidHighways: json['avoidHighways'] == true,
    avoidFerries: json['avoidFerries'] == true,
  );

  @override
  bool operator ==(Object other) =>
      other is RouteOptions &&
      other.avoidTolls == avoidTolls &&
      other.avoidHighways == avoidHighways &&
      other.avoidFerries == avoidFerries;

  @override
  int get hashCode => Object.hash(avoidTolls, avoidHighways, avoidFerries);
}

/// One instruction step of a route (a Valhalla maneuver).
class RouteManeuver {
  final int type;
  final String instruction;
  final String? verbalAlert;
  final String? verbalPre;
  final String? verbalPost;
  final double lengthMeters;
  final double timeSeconds;
  final int beginShapeIndex;
  final int endShapeIndex;

  const RouteManeuver({
    required this.type,
    required this.instruction,
    required this.lengthMeters,
    required this.timeSeconds,
    required this.beginShapeIndex,
    required this.endShapeIndex,
    this.verbalAlert,
    this.verbalPre,
    this.verbalPost,
  });
}

/// A complete routable path returned by the router.
class NavRoute {
  final List<LatLng> shape;
  final List<RouteManeuver> maneuvers;
  final double distanceMeters;
  final double timeSeconds;
  final TravelMode mode;

  /// Valhalla summary flags, for labelling alternatives.
  final bool hasToll;
  final bool hasHighway;
  final bool hasFerry;

  /// Cumulative distance along [shape] at each vertex, in meters.
  /// Computed at parse time (possibly in a background isolate), never on the
  /// first GPS fix.
  final List<double> cumulative;

  NavRoute({
    required this.shape,
    required this.maneuvers,
    required this.distanceMeters,
    required this.timeSeconds,
    required this.mode,
    this.hasToll = false,
    this.hasHighway = false,
    this.hasFerry = false,
    List<double>? cumulative,
  }) : assert(shape.length >= 2, 'A route needs at least two points'),
       assert(maneuvers.isNotEmpty, 'A route needs at least one maneuver'),
       cumulative = cumulative ?? cumulativeDistances(shape);

  /// Distance in meters from route start to the vertex at [shapeIndex].
  double distanceAtShapeIndex(int shapeIndex) =>
      cumulative[shapeIndex.clamp(0, cumulative.length - 1)];

  /// Short qualifiers for the alternatives list, e.g. "Tolls · Highway".
  List<String> get badges => [
    if (hasToll) 'Tolls',
    if (hasHighway) 'Highway',
    if (hasFerry) 'Ferry',
  ];
}
