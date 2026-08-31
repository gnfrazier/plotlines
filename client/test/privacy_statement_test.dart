// K11 / FR138 (issue #117) — the privacy statement covers every clause the
// FR names, reads as prose rather than boilerplate, and is reachable with no
// sidecar (the bundled constant is the fallback for the lightest surfaces).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_client/domain/privacy_statement.dart';
import 'package:plotlines_client/presentation/screens/privacy_screen.dart';

void main() {
  group('privacyStatement constant', () {
    test('covers every clause FR138 names', () {
      final ids = privacyStatement.map((p) => p.id).toSet();
      expect(ids, {
        'on_device',
        'to_server',
        'reveal',
        'arrival_sharing',
        'author_notes',
        'guest_sessions',
      });
    });

    PrivacyPoint point(String id) =>
        privacyStatement.firstWhere((p) => p.id == id);

    test('says reveal is a product guarantee, not a security boundary', () {
      expect(point('reveal').body, contains('not a security boundary'));
    });

    test('says arrival sharing defaults to nothing shared', () {
      final body = point('arrival_sharing').body;
      expect(body, contains('defaults to nothing shared'));
      expect(body.toLowerCase(), anyOf(contains('not your live'), contains('not your route')));
    });

    test('describes Author notes: visibility, persistence, deletion', () {
      final body = point('author_notes').body;
      expect(body, contains('visible only to the Author'));
      expect(body, contains('persist across trips'));
      expect(body, contains('deleted'));
    });

    test('says guest sessions leave no server-side trace', () {
      final body = point('guest_sessions').body.toLowerCase();
      expect(body, contains('nothing'));
      expect(body, contains('server'));
    });

    test('reads as prose, not legal boilerplate', () {
      for (final p in privacyStatement) {
        expect(p.body.trim().endsWith('.'), isTrue, reason: p.id);
        expect(p.body.toLowerCase(), isNot(contains('hereby')));
        expect(p.body.toLowerCase(), isNot(contains('pursuant to')));
      }
    });
  });

  group('privacyPointsFrom', () {
    test('parses the privacy list from an /about payload', () {
      final points = privacyPointsFrom([
        {'id': 'x', 'title': 'X', 'body': 'Body.'},
      ]);
      expect(points.single.id, 'x');
    });

    test('falls back to the bundled statement when the payload is absent', () {
      expect(privacyPointsFrom(null), same(privacyStatement));
    });

    test('falls back when the payload is malformed', () {
      expect(privacyPointsFrom([1, 2, 3]), same(privacyStatement));
    });
  });

  testWidgets('PrivacyStatementView renders every point with no providers',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: PrivacyStatementView(points: privacyStatement)),
    ));

    for (final p in privacyStatement) {
      expect(find.text(p.title), findsOneWidget);
    }
  });
}
