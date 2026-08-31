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

  group('Alternate.copyWith / intent conversion (FR20 [AMENDED v2.0], Flow 11 §06)', () {
    LineString line() => LineString(coordinates: const [
          [-105.27, 40.02],
          [-105.24, 40.03],
        ]);

    Alternate branch() => Alternate(
          id: 'b1',
          kind: 'extension',
          intent: 'branch',
          label: 'Past the Sugarloaf mine',
          note: 'Three miles of old tramway grade.',
          anchorIds: const ['anc-portal', 'anc-cut'],
          narration: Narration(triggerDistanceM: 100.0, text: 'The portal.'),
          reveal: 'on_arrival',
          geometry: line(),
        );

    test('hasBranchContent is true only while the branch is holding something', () {
      expect(branch().hasBranchContent, isTrue);
      expect(
        Alternate(id: 'b2', kind: 'bypass', intent: 'branch', geometry: line()).hasBranchContent,
        isFalse,
      );
    });

    test('copyWith replaces kind/label without disturbing the branch content', () {
      final edited = branch().copyWith(kind: 'bypass', label: 'The direct way');
      expect(edited.kind, 'bypass');
      expect(edited.label, 'The direct way');
      expect(edited.note, 'Three miles of old tramway grade.');
      expect(edited.anchorIds, ['anc-portal', 'anc-cut']);
    });

    test('copyWith clears the branch fields one at a time via clearX', () {
      expect(branch().copyWith(clearNote: true).note, isNull);
      expect(branch().copyWith(clearReveal: true).reveal, isNull);
      expect(branch().copyWith(clearNarration: true).narration, isNull);
      expect(branch().copyWith(anchorIds: const []).anchorIds, isEmpty);
    });

    test('asAccommodation drops every branch-only field and flips the intent', () {
      final accom = branch().asAccommodation();
      expect(accom.isBranch, isFalse);
      expect(accom.intent, 'accommodation');
      expect(accom.note, isNull);
      expect(accom.anchorIds, isEmpty);
      expect(accom.narration, isNull);
      expect(accom.reveal, isNull);
      // Shape is kept.
      expect(accom.kind, 'extension');
      expect(accom.label, 'Past the Sugarloaf mine');
      // The result is a legal accommodation alternate (no assertion thrown).
      expect(accom.toJson()['intent'], 'accommodation');
    });

    test('asBranch keeps the shape and starts the branch content empty', () {
      final accom = Alternate(id: 'x', kind: 'bypass', label: 'Toe River road', geometry: line());
      final asB = accom.asBranch();
      expect(asB.isBranch, isTrue);
      expect(asB.kind, 'bypass');
      expect(asB.label, 'Toe River road');
      expect(asB.hasBranchContent, isFalse);
    });

    test('the conversions are a no-op when already in the target intent', () {
      final b = branch();
      expect(identical(b.asBranch(), b), isTrue);
      final a = Alternate(id: 'y', kind: 'bypass', geometry: line());
      expect(identical(a.asAccommodation(), a), isTrue);
    });
  });

  group('Segment.surfacedConstraints (FR128 / A11, issue #209)', () {
    test('defaults to empty', () {
      final segment = Segment(id: 's1', mode: 'cycling', shape: 'loop');
      expect(segment.surfacedConstraints, isEmpty);
    });

    test('is session-only — toJson never emits it, so a save stays schema-clean', () {
      final segment = Segment(
        id: 's1',
        mode: 'cycling',
        shape: 'loop',
        surfacedConstraints: [
          SurfacedConstraint(from: 1, to: 2, flags: const ['bicycle=dismount']),
        ],
      );
      // No schema home yet (`$defs/segment` is `additionalProperties: false`),
      // so `toJson` must not emit it — the domain layer's strict `done()` would
      // reject the key on the next read.
      expect(segment.toJson().containsKey('surfaced_constraints'), isFalse);
      // A round trip through the payload drops it, as documented.
      expect(Segment.fromJson(segment.toJson()).surfacedConstraints, isEmpty);
    });

    test('copyWith preserves it by default and replaces it when given', () {
      final segment = Segment(
        id: 's1',
        mode: 'cycling',
        shape: 'loop',
        surfacedConstraints: [SurfacedConstraint(from: 1, to: 2, flags: const ['ford=yes'])],
      );
      expect(segment.copyWith(title: 'x').surfacedConstraints.single.flags, ['ford=yes']);
      final replaced = segment.copyWith(surfacedConstraints: const []);
      expect(replaced.surfacedConstraints, isEmpty);
    });

    test('SurfacedConstraint.fromJson reads from/to/flags', () {
      final sc = SurfacedConstraint.fromJson({
        'from': 101,
        'to': 102,
        'flags': ['barrier=gate', 'ford=yes'],
      });
      expect(sc.from, 101);
      expect(sc.to, 102);
      expect(sc.flags, ['barrier=gate', 'ford=yes']);
    });
  });
}
