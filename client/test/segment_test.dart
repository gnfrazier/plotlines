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
}
