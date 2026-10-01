/// Current weather at a location (WMO weather code + temperature).
class Weather {
  final double temperatureC;
  final int code;

  const Weather({required this.temperatureC, required this.code});

  String get emoji => switch (code) {
    0 => '☀️',
    1 || 2 => '🌤️',
    3 => '☁️',
    45 || 48 => '🌫️',
    51 || 53 || 55 || 56 || 57 => '🌦️',
    61 || 63 || 65 || 66 || 67 || 80 || 81 || 82 => '🌧️',
    71 || 73 || 75 || 77 || 85 || 86 => '🌨️',
    95 || 96 || 99 => '⛈️',
    _ => '🌡️',
  };

  String get label => switch (code) {
    0 => 'Clear',
    1 || 2 => 'Partly cloudy',
    3 => 'Overcast',
    45 || 48 => 'Fog',
    51 || 53 || 55 || 56 || 57 => 'Drizzle',
    61 || 63 || 65 || 66 || 67 => 'Rain',
    71 || 73 || 75 || 77 => 'Snow',
    80 || 81 || 82 => 'Showers',
    85 || 86 => 'Snow showers',
    95 || 96 || 99 => 'Thunderstorm',
    _ => '',
  };
}
