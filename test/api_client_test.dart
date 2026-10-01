import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:open_maps/services/api_client.dart';
import 'package:open_maps/services/app_exception.dart';

void main() {
  test(
    'ApiClient adds the User-Agent without clobbering an explicit one',
    () async {
      final seen = <String?>[];
      final client = ApiClient(
        MockClient((request) async {
          seen.add(request.headers['User-Agent']);
          return http.Response('ok', 200);
        }),
      );
      await client.get(Uri.parse('https://example.com/a'));
      await client.get(
        Uri.parse('https://example.com/b'),
        headers: {'User-Agent': 'custom/1'},
      );
      expect(seen, [kUserAgent, 'custom/1']);
    },
  );

  test('toAppException maps transport errors to friendly messages', () {
    expect(
      toAppException(http.ClientException('Failed host lookup: x')),
      isA<OfflineException>(),
    );
    expect(
      toAppException(const FormatException('bad')),
      isA<BadResponseException>(),
    );
    expect(toAppException(StateError('x')).message, 'Something went wrong');
    final server = ServerException(429);
    expect(toAppException(server), same(server));
    expect(server.retryable, isTrue);
    expect(ServerException(404).retryable, isFalse);
    expect(ServerException(500).message, contains('busy'));
  });
}
