import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../models/weather.dart';
import 'api_client.dart';
import 'app_exception.dart';

export '../models/weather.dart';

/// Current weather via Open-Meteo: free, open-source-friendly, no API key.
class WeatherService {
  final http.Client _client;

  WeatherService({http.Client? client}) : _client = client ?? ApiClient.shared;

  Future<Weather> current(LatLng point) => guarded('Open-Meteo', () async {
    final uri = Uri.https('api.open-meteo.com', '/v1/forecast', {
      'latitude': point.latitude.toStringAsFixed(4),
      'longitude': point.longitude.toStringAsFixed(4),
      'current': 'temperature_2m,weather_code',
    });
    final response = await _client.get(uri).timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      throw ServerException(response.statusCode);
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final current = json['current'] as Map<String, dynamic>?;
    final temp = current?['temperature_2m'];
    if (temp is! num) throw const BadResponseException();
    return Weather(
      temperatureC: temp.toDouble(),
      code: (current?['weather_code'] as num?)?.toInt() ?? -1,
    );
  });
}
