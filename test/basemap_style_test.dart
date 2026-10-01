import 'package:flutter_test/flutter_test.dart';
import 'package:open_maps/services/basemap_style.dart';

void main() {
  test('englishLabelsStyleJson rewrites name labels only', () {
    final style = <String, dynamic>{
      'layers': <Map<String, dynamic>>[
        {
          'id': 'place',
          'layout': {
            'text-field': [
              'case',
              ['has', 'name:nonlatin'],
              [
                'concat',
                ['get', 'name:latin'],
                '\n',
                ['get', 'name:nonlatin'],
              ],
              [
                'coalesce',
                ['get', 'name_en'],
                ['get', 'name'],
              ],
            ],
            'text-size': 12,
          },
        },
        {
          'id': 'legacy',
          'layout': {'text-field': '{name:latin}'},
        },
        {
          'id': 'ref',
          'layout': {
            'text-field': [
              'to-string',
              ['get', 'ref'],
            ],
          },
        },
        {'id': 'fill', 'paint': <String, dynamic>{}},
      ],
    };
    final out = englishLabelsStyleJson(style);
    final layers = (out['layers'] as List).cast<Map<String, dynamic>>();
    Map<String, dynamic> layout(int i) =>
        (layers[i]['layout'] as Map).cast<String, dynamic>();
    expect(layout(0)['text-field'], englishNameExpression);
    expect(layout(0)['text-size'], 12);
    expect(layout(1)['text-field'], englishNameExpression);
    expect(layout(2)['text-field'], [
      'to-string',
      ['get', 'ref'],
    ]);
    expect(layers[3].containsKey('layout'), isFalse);
    // Input is not mutated.
    final original = (style['layers'] as List<Map<String, dynamic>>)[0];
    final originalField =
        (original['layout'] as Map<String, dynamic>)['text-field'] as List;
    expect(originalField[0], 'case');
  });
}
