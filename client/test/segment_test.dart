// FR10 / B1 — Segment wire parsing, scoped to FR38/O6's `arc_stage` addition
// (the "passage" arc, distinct from any arc stage on a Node along it). No
// prior dedicated test file covered Segment; broader pre-existing behaviour
// is out of this story's scope.
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';

void main() {
  group('Segment.arcStage (FR38 / O6)', () {
    test('defaults to null and is absent from JSON', () {
      final segment = Segment(id: 's1', mode: 'hiking', shape: 'point_to_point');
      expect(segment.arcStage, isNull);
      expect(segment.toJson().containsKey('arc_stage'), isFalse);
    });

    test('round-trips through JSON', () {
      final segment = Segment(id: 's1', mode: 'hiking', shape: 'point_to_point', arcStage: 'rising');
      final decoded = Segment.fromJson(segment.toJson());
      expect(decoded.arcStage, 'rising');
    });

    test('an unset arc_stage on read stays null', () {
      final decoded = Segment.fromJson({'id': 's1', 'mode': 'hiking', 'shape': 'loop'});
      expect(decoded.arcStage, isNull);
    });

    test('copyWith preserves arcStage by default and clears it via clearArcStage', () {
      final segment = Segment(id: 's1', mode: 'hiking', shape: 'loop', arcStage: 'crux');
      expect(segment.copyWith(title: 'x').arcStage, 'crux');
      expect(segment.copyWith(clearArcStage: true).arcStage, isNull);
    });

    test('a new arcStage value replaces the old one via copyWith', () {
      final segment = Segment(id: 's1', mode: 'hiking', shape: 'loop', arcStage: 'crux');
      expect(segment.copyWith(arcStage: 'climax').arcStage, 'climax');
    });
  });

  group('Segment.note / Segment.media (FR37 / E1)', () {
    test('default to null/empty and are absent from JSON', () {
      final segment = Segment(id: 's1', mode: 'hiking', shape: 'loop');
      expect(segment.note, isNull);
      expect(segment.media, isEmpty);
      final json = segment.toJson();
      expect(json.containsKey('note'), isFalse);
      expect(json.containsKey('media'), isFalse);
    });

    test('round-trip through JSON, distinct from arc_stage or any role', () {
      final segment = Segment(
        id: 's1',
        mode: 'hiking',
        shape: 'loop',
        note: 'The grind between the two overlooks.',
        media: [MediaRef(id: 'm1', kind: 'image', path: 'grind.jpg', caption: 'The climb')],
      );
      final decoded = Segment.fromJson(segment.toJson());
      expect(decoded.note, 'The grind between the two overlooks.');
      expect(decoded.media.single.path, 'grind.jpg');
      expect(decoded.media.single.caption, 'The climb');
    });

    test('copyWith replaces note/media without disturbing other fields, and clearNote clears it', () {
      final segment = Segment(id: 's1', mode: 'hiking', shape: 'loop', arcStage: 'crux', note: 'old');
      final updated = segment.copyWith(note: 'new', media: [MediaRef(id: 'm1', kind: 'image', path: 'p.jpg')]);
      expect(updated.note, 'new');
      expect(updated.media.single.path, 'p.jpg');
      expect(updated.arcStage, 'crux'); // untouched

      expect(segment.copyWith(clearNote: true).note, isNull);
    });
  });

  group('Alternate.intent (FR20 / C4 [AMENDED v2.0])', () {
    LineString line() => LineString(coordinates: const [
          [-105.27, 40.02],
          [-105.24, 40.03],
        ]);

    test('defaults to accommodation and reads back that way from a payload with no intent', () {
      final a = Alternate(id: 'a1', kind: 'bypass', geometry: line());
      expect(a.intent, 'accommodation');
      expect(a.isBranch, isFalse);
      expect(a.toJson()['intent'], 'accommodation');

      final decoded = Alternate.fromJson({
        'id': 'a1',
        'kind': 'bypass',
        'geometry': {
          'type': 'LineString',
          'coordinates': const [
            [-105.27, 40.02],
            [-105.24, 40.03],
          ],
          'source': 'authored',
        },
      });
      expect(decoded.intent, 'accommodation');
    });

    test('a branch alternate round-trips its own content', () {
      final a = Alternate(
        id: 'a2',
        kind: 'extension',
        intent: 'branch',
        label: 'The long way past the abandoned mine',
        note: 'Adds 4 km and a 200 m climb.',
        anchorIds: const ['anc-mine', 'anc-cemetery'],
        narration: Narration(triggerDistanceM: 150.0, text: 'The mine.'),
        reveal: 'on_arrival',
        geometry: line(),
      );
      final decoded = Alternate.fromJson(a.toJson());
      expect(decoded.intent, 'branch');
      expect(decoded.isBranch, isTrue);
      expect(decoded.note, 'Adds 4 km and a 200 m climb.');
      expect(decoded.anchorIds, ['anc-mine', 'anc-cemetery']);
      expect(decoded.narration!.triggerDistanceM, 150.0);
      expect(decoded.reveal, 'on_arrival');
    });

    test('an accommodation alternate omits the branch content keys from JSON', () {
      final json = Alternate(id: 'a3', kind: 'bypass', geometry: line()).toJson();
      expect(json.containsKey('note'), isFalse);
      expect(json.containsKey('anchor_ids'), isFalse);
      expect(json.containsKey('narration'), isFalse);
      expect(json.containsKey('reveal'), isFalse);
    });

    test('an unknown intent is rejected', () {
      expect(
        () => Alternate(id: 'a4', kind: 'bypass', intent: 'ladder', geometry: line()),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
