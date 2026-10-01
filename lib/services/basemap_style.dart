import 'package:flutter/painting.dart' show Color, HSLColor;

/// Pure JSON transformations of the OpenFreeMap `liberty` MapLibre style:
/// denser labels/POIs, Overture Maps place layers, and a night re-grade.
/// No Flutter widgets here — these run in a background isolate via
/// `compute` and are unit-tested directly.

/// Decodes a style and applies the day-time transforms. Top-level so it can
/// run through `compute`.
Map<String, dynamic> prepareStyleJson(Map<String, dynamic> style) =>
    addOvertureLayers(englishLabelsStyleJson(densifyStyleJson(style)));

// ---------------------------------------------------------------------------
// Label language: liberty shows "latin + native script" for every named
// feature; the app shows English (falling back to a romanised name, then
// the local name) so countries, cities and roads read the same everywhere.
// ---------------------------------------------------------------------------

/// The `text-field` expression used for every named feature.
const englishNameExpression = <dynamic>[
  'coalesce',
  ['get', 'name:en'],
  ['get', 'name_en'],
  ['get', 'name:latin'],
  ['get', 'name'],
];

/// Rewrites every layer whose `text-field` reads a `name*` property to
/// [englishNameExpression]; refs, house numbers etc. are left alone.
Map<String, dynamic> englishLabelsStyleJson(Map<String, dynamic> style) {
  final layers = <Map<String, dynamic>>[];
  for (final l in style['layers'] as List) {
    final layer = Map<String, dynamic>.from(l as Map);
    final layout = layer['layout'];
    final field = layout is Map ? layout['text-field'] : null;
    if (field != null && _readsName(field)) {
      layer['layout'] = {...layout as Map, 'text-field': englishNameExpression};
    }
    layers.add(layer);
  }
  return {...style, 'layers': layers};
}

bool _readsName(dynamic expression) {
  if (expression is String) {
    return expression.contains('{name'); // legacy "{name:latin}" tokens
  }
  if (expression is List) {
    if (expression.length == 2 &&
        expression[0] == 'get' &&
        expression[1] is String &&
        (expression[1] as String).startsWith('name')) {
      return true;
    }
    return expression.any(_readsName);
  }
  return false;
}

// ---------------------------------------------------------------------------
// Data density: bring labels/POIs in earlier, Google-style, and add layers
// liberty omits (POI dots at mid zoom, house numbers at high zoom).
// ---------------------------------------------------------------------------

const _minZoomOverrides = <String, double>{
  'poi_r1': 13.5, // top-ranked POIs (stations, hospitals, malls)
  'poi_r7': 14.5,
  'poi_r20': 15.5,
  'highway-name-minor': 14,
  'highway-name-path': 15,
  'building': 13,
  'label_other': 8, // neighbourhoods / suburbs
};

Map<String, dynamic> densifyStyleJson(Map<String, dynamic> style) {
  final out = Map<String, dynamic>.from(style);
  final layers = <Map<String, dynamic>>[];
  for (final l in style['layers'] as List) {
    final layer = Map<String, dynamic>.from(l as Map);
    final id = layer['id'] as String;
    final mz = _minZoomOverrides[id];
    if (mz != null) layer['minzoom'] = mz;

    // Insert POI dots just before the first real POI label layer so labels
    // draw on top of them.
    if (id == 'poi_r20') layers.add(_poiDotsLayer());
    layers.add(layer);
    if (id == 'building') layers.add(_housenumberLayer());
  }
  out['layers'] = layers;
  return out;
}

/// Unlabelled dots for POIs whose label zoom hasn't been reached yet — the
/// "there's stuff here" texture Google shows at z13–16.
Map<String, dynamic> _poiDotsLayer() => {
  'id': 'poi_dots',
  'type': 'symbol',
  'source': 'openmaptiles',
  'source-layer': 'poi',
  'minzoom': 13,
  'maxzoom': 17,
  'filter': [
    'all',
    [
      'match',
      ['geometry-type'],
      ['Point', 'MultiPoint'],
      true,
      false,
    ],
    [
      '>=',
      ['get', 'rank'],
      7,
    ],
    [
      'match',
      ['get', 'class'],
      ['airport', 'bus', 'rail'],
      false,
      true,
    ],
  ],
  'layout': {
    'icon-image': 'dot_9',
    'icon-size': [
      'interpolate',
      ['linear'],
      ['zoom'],
      13,
      0.5,
      16,
      0.8,
    ],
    'icon-allow-overlap': false,
  },
  'paint': {'icon-opacity': 0.85},
};

Map<String, dynamic> _housenumberLayer() => {
  'id': 'housenumber',
  'type': 'symbol',
  'source': 'openmaptiles',
  'source-layer': 'housenumber',
  'minzoom': 17.5,
  'layout': {
    'text-field': ['get', 'housenumber'],
    'text-font': ['Noto Sans Regular'],
    'text-size': 10,
    'text-max-width': 6,
  },
  'paint': {
    'text-color': 'rgba(120,120,120,1)',
    'text-halo-color': 'rgba(255,255,255,0.8)',
    'text-halo-width': 1,
  },
};

// ---------------------------------------------------------------------------
// Overture Maps: places (POIs) and building footprints as extra sources.
// ---------------------------------------------------------------------------

/// Overture category -> sprite icon. Covers both `basic_category` values and
/// the finer `categories.primary` vocabulary; anything else gets a dot.
const _iconByCategory = <String, List<String>>{
  'hospital': [
    'hospital',
    'medical_center',
    'health_and_medical',
    'diagnostic_services',
    'diagnostic_imaging',
    'clinic',
    'emergency_room',
    'medical_supply',
  ],
  'doctors': ['doctor', 'doctors', 'naturopathic_holistic', 'physician'],
  'dentist': ['dentist', 'general_dentistry'],
  'pharmacy': ['pharmacy', 'drugstore'],
  'school': [
    'school',
    'high_school',
    'preschool',
    'elementary_school',
    'middle_school',
    'education',
    'educational_services',
    'tutoring_center',
    'computer_coaching',
    'vocational_and_technical_school',
  ],
  'college': ['college_university', 'college', 'university'],
  'place_of_worship': [
    'hindu_temple',
    'hindu_place_of_worship',
    'place_of_worship',
    'religious_organization',
    'buddhist_temple',
    'sikh_temple',
    'gurudwara',
    'jain_temple',
    'temple',
  ],
  'religious_muslim': ['mosque'],
  'religious_christian': [
    'church_cathedral',
    'church',
    'christian_place_of_worship',
  ],
  'bank': [
    'bank_credit_union',
    'bank_or_credit_union',
    'banks',
    'credit_union',
    'financial_service',
    'atms',
    'atm',
    'stock_and_bond_brokers',
  ],
  'restaurant': [
    'restaurant',
    'indian_restaurant',
    'pizza_restaurant',
    'chinese_restaurant',
    'biryani_restaurant',
    'vegetarian_restaurant',
    'food_and_beverage',
    'dhaba',
  ],
  'fast_food': [
    'fast_food_restaurant',
    'fast_food',
    'burger_restaurant',
    'sandwich_shop',
    'snack_bar',
  ],
  'cafe': ['cafe', 'coffee_shop', 'tea_room', 'tea_stall'],
  'bakery': ['bakery', 'cake_shop', 'dessert_shop'],
  'ice_cream': ['ice_cream_shop', 'ice_cream'],
  'bar': ['bar', 'pub', 'wine_bar', 'liquor_store'],
  'lodging': [
    'hotel',
    'resort',
    'hostel',
    'accommodation',
    'guest_house',
    'lodging',
    'serviced_apartments',
  ],
  'fuel': ['gas_station', 'fuel_station', 'petrol_pump'],
  'car': [
    'car_dealer',
    'automotive_repair',
    'automotive_services_and_repair',
    'auto_parts_and_supply_store',
    'automotive',
    'motorcycle_dealer',
    'car_wash',
  ],
  'parking': ['parking', 'parking_lot'],
  'bus': ['bus_station', 'bus_stop', 'transportation', 'public_transportation'],
  'railway': [
    'train_station',
    'railway_station',
    'metro_station',
    'light_rail_station',
  ],
  'airport': ['airport'],
  'grocery': [
    'grocery_store',
    'supermarket',
    'convenience_store',
    'kirana_store',
    'general_store',
    'market',
  ],
  'clothing_store': [
    'clothing_store',
    'womens_clothing_store',
    'mens_clothing_store',
    'boutique',
    'saree_store',
    'fashion',
    'fashion_accessories_store',
  ],
  'shop': [
    'shopping',
    'shopping_center',
    'mall',
    'department_store',
    'retail',
    'electronics',
    'electronics_store',
    'mobile_phone_store',
    'furniture_store',
    'hardware_store',
    'hardware_home_and_garden_store',
    'jewelry_store',
    'shoe_store',
    'flowers_and_gifts_shop',
    'gift_shop',
    'home_decor_store',
    'toy_store',
    'bookstore',
    'sporting_goods_store',
  ],
  'hairdresser': [
    'beauty_salon',
    'hair_salon',
    'barber',
    'spas',
    'spa',
    'nail_salon',
  ],
  'cinema': ['movie_theater', 'cinema'],
  'theatre': ['performing_arts', 'theatre', 'auditorium'],
  'museum': ['museum', 'art_gallery'],
  'monument': [
    'landmark_and_historical_building',
    'historic_site',
    'monument',
    'memorial',
  ],
  'park': ['park', 'playground', 'garden', 'public_park'],
  'stadium': ['stadium', 'sports_complex', 'cricket_ground'],
  'pitch': [
    'gym',
    'fitness_center',
    'sports_and_recreation',
    'yoga_studio',
    'swimming_pool',
    'sports_club',
  ],
  'police': ['police_station', 'police'],
  'fire_station': ['fire_station'],
  'post': ['post_office', 'courier_service', 'shipping_center'],
  'town_hall': [
    'central_government_office',
    'government_office',
    'city_hall',
    'local_government_office',
    'public_service_government',
  ],
  'library': ['library'],
  'community_centre': ['community_center', 'community_services_non_profits'],
  'veterinary': ['veterinarian', 'veterinary', 'pet_store'],
  'laundry': ['laundry_service', 'dry_cleaning', 'laundromat'],
  'information': ['travel_services', 'travel_agency', 'tourist_information'],
  'cemetery': ['cemetery', 'funeral_service', 'crematorium'],
  'industry': [
    'industrial_equipment',
    'business_manufacturing_and_supply',
    'commercial_industrial',
    'factory',
    'manufacturer',
  ],
};

/// Categories that matter from neighbourhood zoom (like Google at z14-15).
const _tierACategories = [
  'hospital',
  'medical_center',
  'school',
  'high_school',
  'college_university',
  'college',
  'university',
  'hindu_temple',
  'hindu_place_of_worship',
  'place_of_worship',
  'mosque',
  'church_cathedral',
  'church',
  'shopping_center',
  'mall',
  'hotel',
  'resort',
  'gas_station',
  'park',
  'stadium',
  'sports_complex',
  'bus_station',
  'train_station',
  'railway_station',
  'metro_station',
  'airport',
  'police_station',
  'fire_station',
  'central_government_office',
  'government_office',
  'landmark_and_historical_building',
  'movie_theater',
  'cinema',
  'museum',
  'library',
  'post_office',
  'bank_credit_union',
  'bank_or_credit_union',
  'banks',
];

/// Everyday places from street zoom (z15.5+).
const _tierBCategories = [
  'restaurant',
  'indian_restaurant',
  'pizza_restaurant',
  'fast_food_restaurant',
  'cafe',
  'coffee_shop',
  'bakery',
  'ice_cream_shop',
  'bar',
  'pub',
  'pharmacy',
  'grocery_store',
  'supermarket',
  'convenience_store',
  'clothing_store',
  'jewelry_store',
  'electronics_store',
  'mobile_phone_store',
  'furniture_store',
  'hardware_store',
  'hardware_home_and_garden_store',
  'hostel',
  'dentist',
  'doctors',
  'doctor',
  'gym',
  'beauty_salon',
  'hair_salon',
  'car_dealer',
  'automotive_repair',
  'parking',
  'preschool',
  'community_center',
  'atms',
  'credit_union',
  'financial_service',
  'shopping',
  'electronics',
];

List<dynamic> _iconExpression() {
  final match = <dynamic>[
    'match',
    [
      'coalesce',
      ['get', 'basic_category'],
      '',
    ],
  ];
  _iconByCategory.forEach((icon, cats) {
    match
      ..add(cats)
      ..add(icon);
  });
  match.add('dot_11');
  return match;
}

List<dynamic> _isPoint() => [
  'match',
  ['geometry-type'],
  ['Point', 'MultiPoint'],
  true,
  false,
];

List<dynamic> _hasName() => ['has', '@name'];

List<dynamic> _minConfidence(double c) => [
  '>=',
  [
    'coalesce',
    ['get', 'confidence'],
    0,
  ],
  c,
];

Map<String, dynamic> _overturePoiLayer({
  required String id,
  required double minzoom,
  required List<dynamic> filter,
  double textSize = 12,
}) => {
  'id': id,
  'type': 'symbol',
  'source': 'overture_places',
  'source-layer': 'place',
  'minzoom': minzoom,
  'filter': filter,
  'layout': {
    'icon-image': _iconExpression(),
    'icon-size': 0.9,
    'text-field': ['get', '@name'],
    'text-font': ['Noto Sans Italic'],
    'text-size': textSize,
    'text-max-width': 8,
    'text-anchor': 'top',
    'text-offset': [0, 0.7],
    'text-optional': true,
  },
  'paint': {
    'text-color': '#5c4a2e',
    'text-halo-color': 'rgba(255,255,255,0.9)',
    'text-halo-width': 1.2,
    'text-halo-blur': 0.5,
  },
};

Map<String, dynamic> addOvertureLayers(Map<String, dynamic> style) {
  final out = Map<String, dynamic>.from(style);
  final sources = Map<String, dynamic>.from(style['sources'] as Map);
  sources['overture_places'] = {
    'type': 'vector',
    'tiles': <String>[],
    'minzoom': 14,
    'maxzoom': 14,
  };
  out['sources'] = sources;

  final layers = <Map<String, dynamic>>[];
  for (final l in style['layers'] as List) {
    final layer = Map<String, dynamic>.from(l as Map);
    final id = layer['id'] as String;
    // Overture footprints were dropped: as a separate layer they painted over
    // roads and labels, and their multi-MB tiles dominated load time.
    if (id == 'building-3d') continue; // extrusions are heavy and add little
    layers.add(layer);
  }

  // POIs go on top of everything so they take part in label collision last
  // (OSM labels, drawn earlier, win ties — avoids duplicate names).
  layers.addAll([
    {
      'id': 'overture_poi_dots',
      'type': 'symbol',
      'source': 'overture_places',
      'source-layer': 'place',
      // Icons aren't collision-culled by the renderer (only text is), so keep
      // dots sparse: confident, unlabelled-tier places only, from z15.5.
      'minzoom': 15.5,
      'maxzoom': 17,
      'filter': [
        'all',
        _isPoint(),
        _hasName(),
        _minConfidence(0.6),
        [
          'match',
          [
            'coalesce',
            ['get', 'basic_category'],
            '',
          ],
          <String>[..._tierACategories, ..._tierBCategories],
          false,
          true,
        ],
      ],
      'layout': {
        'icon-image': 'dot_9',
        'icon-size': [
          'interpolate',
          ['linear'],
          ['zoom'],
          15.5,
          0.4,
          17,
          0.6,
        ],
      },
      'paint': {'icon-opacity': 0.7},
    },
    _overturePoiLayer(
      id: 'overture_poi_a',
      minzoom: 14,
      filter: [
        'all',
        _isPoint(),
        _hasName(),
        _minConfidence(0.6),
        [
          'match',
          [
            'coalesce',
            ['get', 'basic_category'],
            '',
          ],
          _tierACategories,
          true,
          false,
        ],
      ],
    ),
    _overturePoiLayer(
      id: 'overture_poi_b',
      minzoom: 15.5,
      filter: [
        'all',
        _isPoint(),
        _hasName(),
        _minConfidence(0.55),
        [
          'match',
          [
            'coalesce',
            ['get', 'basic_category'],
            '',
          ],
          _tierBCategories,
          true,
          false,
        ],
      ],
    ),
    _overturePoiLayer(
      id: 'overture_poi_c',
      minzoom: 17,
      textSize: 11,
      filter: [
        'all',
        _isPoint(),
        _hasName(),
        _minConfidence(0.45),
        [
          'match',
          [
            'coalesce',
            ['get', 'basic_category'],
            '',
          ],
          [..._tierACategories, ..._tierBCategories],
          false,
          true,
        ],
      ],
    ),
  ]);
  out['layers'] = layers;
  return out;
}

// ---------------------------------------------------------------------------
// Night re-grading of a MapLibre style JSON.
// ---------------------------------------------------------------------------

/// Re-grades every colour in a MapLibre style into a night palette.
Map<String, dynamic> nightifyStyleJson(Map<String, dynamic> style) {
  final out = Map<String, dynamic>.from(style);
  final layers = (style['layers'] as List).map((l) {
    final layer = Map<String, dynamic>.from(l as Map);
    final type = layer['type'] as String;
    if (layer['paint'] is Map) {
      layer['paint'] = _walkProps(layer['paint'] as Map, type);
    }
    if (layer['layout'] is Map) {
      layer['layout'] = _walkProps(layer['layout'] as Map, type);
    }
    return layer;
  }).toList();
  out['layers'] = layers;
  return out;
}

Map<String, dynamic> _walkProps(Map<dynamic, dynamic> props, String layerType) {
  final out = <String, dynamic>{};
  props.forEach((k, v) {
    final key = k as String;
    out[key] = key.endsWith('color')
        ? _walkValue(v, (c) => _recolor(c, key, layerType))
        : v;
  });
  return out;
}

dynamic _walkValue(dynamic v, HSLColor Function(HSLColor) f) {
  if (v is String) {
    final c = _parseColor(v);
    return c == null ? v : _fmt(f(HSLColor.fromColor(c)));
  }
  if (v is List) return v.map((e) => _walkValue(e, f)).toList();
  if (v is Map) return v.map((k, e) => MapEntry(k, _walkValue(e, f)));
  return v;
}

/// Maps a daytime colour to its night counterpart depending on what it
/// paints. Targets (lightness): ground ≈ 0.11, water ≈ 0.14, roads 0.22–0.34,
/// text ≈ 0.80, halos ≈ 0.10. Hue is preserved so parks stay green, water
/// blue and motorways orange; neutral ground gets a cool navy cast.
HSLColor _recolor(HSLColor c, String prop, String layerType) {
  final l = c.lightness;
  double h = c.hue, s = c.saturation, nl;

  if (prop == 'text-halo-color' || prop == 'icon-halo-color') {
    return HSLColor.fromAHSL(c.alpha, 220, 0.25, 0.10);
  }
  if (prop == 'text-color' || prop == 'icon-color') {
    // Dark text -> light text; coloured text keeps hue, brighter.
    nl = 0.92 - 0.45 * l;
    if (s > 0.2) s = (s * 0.9).clamp(0, 1);
    return HSLColor.fromAHSL(c.alpha, h, s, nl.clamp(0.55, 0.95));
  }
  switch (layerType) {
    case 'background':
      return HSLColor.fromAHSL(c.alpha, 220, 0.28, 0.11);
    case 'fill':
    case 'fill-extrusion':
      // Land / parks / water / buildings: deep, hue-preserving.
      nl = 0.09 + 0.14 * (1 - l);
      if (s < 0.15) {
        h = 220;
        s = 0.22;
      } else {
        s = (s * 0.75).clamp(0, 1);
      }
      // Keep water and greens slightly distinct from bare ground.
      if (_isBlue(h) && s > 0.2) nl = 0.16;
      if (_isGreen(h) && s > 0.2) nl = 0.13;
      return HSLColor.fromAHSL(c.alpha, h, s, nl.clamp(0.06, 0.22));
    case 'line':
      // Roads/paths/rails must sit *above* the ground tone.
      nl = 0.20 + 0.22 * (1 - l);
      if (s < 0.15) {
        h = 220;
        s = 0.14;
      } else {
        s = (s * 0.85).clamp(0, 1);
        nl += 0.08; // keep motorway orange etc. readable
      }
      return HSLColor.fromAHSL(c.alpha, h, s, nl.clamp(0.18, 0.5));
    default:
      nl = 0.9 - 0.6 * l;
      return HSLColor.fromAHSL(c.alpha, h, s, nl.clamp(0.1, 0.9));
  }
}

bool _isBlue(double h) => h >= 180 && h <= 250;
bool _isGreen(double h) => h >= 70 && h <= 170;

final _hex = RegExp(r'^#([0-9a-fA-F]{3,8})$');
final _fn = RegExp(r'^(rgba?|hsla?)\(([^)]*)\)$', caseSensitive: false);

Color? _parseColor(String s) {
  final t = s.trim();
  final hm = _hex.firstMatch(t);
  if (hm != null) {
    var h = hm.group(1)!;
    if (h.length == 3 || h.length == 4) {
      h = h.split('').map((c) => '$c$c').join();
    }
    if (h.length == 6) {
      h = 'ff$h';
    } else if (h.length == 8) {
      // #rrggbbaa -> aarrggbb
      h = h.substring(6) + h.substring(0, 6);
    }
    if (h.length != 8) return null;
    return Color(int.parse(h, radix: 16));
  }
  final fm = _fn.firstMatch(t);
  if (fm != null) {
    final fn = fm.group(1)!.toLowerCase();
    final parts = fm
        .group(2)!
        .split(RegExp(r'[,\s/]+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.length < 3) return null;
    double num(String p) =>
        double.parse(p.endsWith('%') ? p.substring(0, p.length - 1) : p);
    final a = parts.length > 3 ? num(parts[3]).clamp(0, 1).toDouble() : 1.0;
    if (fn.startsWith('rgb')) {
      int ch(String p) => p.endsWith('%')
          ? (num(p) * 2.55).round().clamp(0, 255)
          : num(p).round().clamp(0, 255);
      return Color.fromARGB(
        (a * 255).round(),
        ch(parts[0]),
        ch(parts[1]),
        ch(parts[2]),
      );
    }
    return HSLColor.fromAHSL(
      a,
      num(parts[0]) % 360,
      num(parts[1]) / 100,
      num(parts[2]) / 100,
    ).toColor();
  }
  final named = _named[t.toLowerCase()];
  return named;
}

const _named = <String, Color>{
  'white': Color(0xFFFFFFFF),
  'black': Color(0xFF000000),
  'transparent': Color(0x00000000),
};

String _fmt(HSLColor c) {
  final col = c.toColor();
  final r = (col.r * 255).round(),
      g = (col.g * 255).round(),
      b = (col.b * 255).round();
  return 'rgba($r,$g,$b,${col.a.toStringAsFixed(3)})';
}
