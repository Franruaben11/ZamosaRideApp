import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Identifies the app to the open services it relies on. Wikimedia,
/// Nominatim, Overpass and FOSSGIS all ask for a descriptive User-Agent and
/// throttle or block the default `Dart/x.y`.
///
/// Put a contact URL or address here before shipping — most operators'
/// usage policies require one.
const kUserAgent = 'ZamosaRide/0.1.0 (Franco; fran.ruaben23@gmail.com)';

/// Shared HTTP client: one keep-alive connection pool for the whole app and
/// a proper User-Agent on every request. Inject it into services so tests
/// can swap in a `MockClient`.
class ApiClient extends http.BaseClient {
  final http.Client _inner;

  ApiClient([http.Client? inner]) : _inner = inner ?? http.Client();

  static final ApiClient shared = ApiClient();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    // Browsers forbid setting User-Agent from script.
    if (!kIsWeb) request.headers.putIfAbsent('User-Agent', () => kUserAgent);
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
