// Story A7 (issue #24) — route shape is selectable independently of
// weights, loop is the default, and only point_to_point requires a
// destination. Covers `planner_ui_state.dart`'s `defaultSegmentShape` and
// `canGenerateShape`, which `new_route_screen.dart`'s `_shape` field and
// `_canGenerate` getter now read rather than duplicating the rule inline.
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/state/planner_ui_state.dart';

void main() {
  test('defaultSegmentShape is loop', () {
    expect(defaultSegmentShape, 'loop');
  });

  group('canGenerateShape', () {
    test('no start never generates, regardless of shape', () {
      expect(
        canGenerateShape(shape: 'loop', hasStart: false, hasEnd: false, hasTargetM: true),
        isFalse,
      );
      expect(
        canGenerateShape(shape: 'out_and_back', hasStart: false, hasEnd: true, hasTargetM: true),
        isFalse,
      );
      expect(
        canGenerateShape(shape: 'point_to_point', hasStart: false, hasEnd: true, hasTargetM: false),
        isFalse,
      );
    });

    group('loop', () {
      test('start + target distance is enough — no destination needed', () {
        expect(
          canGenerateShape(shape: 'loop', hasStart: true, hasEnd: false, hasTargetM: true),
          isTrue,
        );
      });

      test('a destination alone is not enough — loop always needs a target distance', () {
        expect(
          canGenerateShape(shape: 'loop', hasStart: true, hasEnd: true, hasTargetM: false),
          isFalse,
        );
      });
    });

    group('out_and_back', () {
      test('start + target distance is enough — no picked turnaround needed', () {
        expect(
          canGenerateShape(shape: 'out_and_back', hasStart: true, hasEnd: false, hasTargetM: true),
          isTrue,
        );
      });

      test('start + a picked turnaround is enough — no target distance needed', () {
        expect(
          canGenerateShape(shape: 'out_and_back', hasStart: true, hasEnd: true, hasTargetM: false),
          isTrue,
        );
      });

      test('start alone, with neither, is not enough', () {
        expect(
          canGenerateShape(shape: 'out_and_back', hasStart: true, hasEnd: false, hasTargetM: false),
          isFalse,
        );
      });
    });

    group('point_to_point', () {
      test('requires a destination — a target distance alone does not substitute', () {
        expect(
          canGenerateShape(shape: 'point_to_point', hasStart: true, hasEnd: false, hasTargetM: true),
          isFalse,
        );
      });

      test('start + destination is enough', () {
        expect(
          canGenerateShape(shape: 'point_to_point', hasStart: true, hasEnd: true, hasTargetM: false),
          isTrue,
        );
      });
    });
  });
}
