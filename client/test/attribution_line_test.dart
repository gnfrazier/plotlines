// K10 / FR86, FR95, FR101, issue #269, and issue #296 — `aboutStaticAttribution`
// is the offline/lightest-surface fallback for `GET /about`'s dynamic
// attribution list. It must carry exactly the four always-owed obligations
// (elevation CC BY, basemap ODbL, routing graph ODbL, Nominatim's own
// display-attribution credit) with the exact strings the Python side's
// `test_web_about.py` pins, so neither side drifts from the other without
// both failing.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_client/domain/attribution_line.dart';

void main() {
  group('aboutStaticAttribution', () {
    test('carries exactly the four always-owed obligations', () {
      final layers = aboutStaticAttribution.map((a) => a.layer).toList();
      expect(layers, ['elevation', 'basemap', 'graph', 'geocode']);
    });

    test('the graph credit is a separate ODbL obligation from the basemap\'s',
        () {
      final basemap =
          aboutStaticAttribution.firstWhere((a) => a.layer == 'basemap');
      final graph =
          aboutStaticAttribution.firstWhere((a) => a.layer == 'graph');

      // Same licence, both ODbL — but distinct credit text (issue #269's
      // presentation decision): a screen must not repeat the identical
      // "© OpenStreetMap contributors" string for two different obligations.
      expect(graph.licence, 'ODbL-1.0');
      expect(graph.licence, basemap.licence);
      expect(graph.attribution, isNot(basemap.attribution));
      expect(graph.attribution, contains('OpenStreetMap'));
      expect(graph.builtin, isTrue);
      expect(graph.termsUrl, 'https://www.openstreetmap.org/copyright');
    });

    test('removing the graph credit is a test failure, not a silent drop',
        () {
      // Pins issue #269's "done when": the constant must keep a 'graph'
      // entry — this fails the moment someone edits the list back down to
      // two.
      expect(aboutStaticAttribution.any((a) => a.layer == 'graph'), isTrue);
    });

    test('the geocode credit names Nominatim and shares no text with the '
        'graph credit', () {
      // Issue #296: Nominatim's display-attribution obligation was unmet —
      // this pins the fix so it cannot silently regress.
      final graph =
          aboutStaticAttribution.firstWhere((a) => a.layer == 'graph');
      final geocode =
          aboutStaticAttribution.firstWhere((a) => a.layer == 'geocode');

      expect(geocode.attribution, contains('Nominatim'));
      expect(geocode.attribution, nominatimSearchAttribution);
      expect(geocode.attribution, isNot(graph.attribution));
      expect(geocode.builtin, isTrue);
    });

    test('removing the geocode credit is a test failure, not a silent drop',
        () {
      expect(aboutStaticAttribution.any((a) => a.layer == 'geocode'), isTrue);
    });
  });

  group('attributionLinesFrom', () {
    test('falls back to aboutStaticAttribution — graph included — when the '
        'payload is absent', () {
      expect(attributionLinesFrom(null), aboutStaticAttribution);
    });

    test('falls back when the payload is malformed', () {
      expect(attributionLinesFrom([1, 2, 3]), aboutStaticAttribution);
    });

    test('parses a real /about payload, graph line included', () {
      final lines = attributionLinesFrom([
        {
          'layer': 'graph',
          'licence': 'ODbL-1.0',
          'attribution': 'Routing data: © OpenStreetMap contributors',
          'terms_url': 'https://www.openstreetmap.org/copyright',
          'builtin': true,
        },
      ]);
      expect(lines.single.layer, 'graph');
      expect(lines.single.attribution,
          'Routing data: © OpenStreetMap contributors');
    });
  });
}
