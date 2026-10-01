/// Measurement system for distances, speeds and temperatures.
enum Units {
  metric,
  imperial;

  /// Process-wide current setting. Set by `AppSettings` so formatting
  /// helpers can stay plain functions.
  static Units current = Units.metric;

  /// Default for a locale: the US, Liberia and Myanmar use imperial units.
  static Units forCountry(String? countryCode) => switch (countryCode) {
    'US' || 'LR' || 'MM' => Units.imperial,
    _ => Units.metric,
  };

  String get label => this == Units.metric ? 'Kilometres' : 'Miles';
}
