// FR142(c) (Story K12) — empty states state a next action rather than an
// absence.
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';

void main() {
  test('every EmptyStateContext has a registry entry with a non-empty next action', () {
    expect(emptyStatesMissingNextAction(), isEmpty);
    for (final context in EmptyStateContext.values) {
      final copy = emptyStateRegistry[context];
      expect(copy, isNotNull, reason: '$context has no empty-state copy');
      expect(copy!.nextAction.trim(), isNotEmpty);
      expect(copy.message.trim(), isNotEmpty);
    }
  });

  test('the next action is distinct copy from the absence message, not a restatement', () {
    for (final copy in emptyStateRegistry.values) {
      expect(copy.nextAction, isNot(equals(copy.message)));
    }
  });

  test('the enumeration covers exactly the contexts named in K12 AC', () {
    expect(
      EmptyStateContext.values.toSet(),
      {
        EmptyStateContext.tripNoDays,
        EmptyStateContext.dayNoPassages,
        EmptyStateContext.bboxNoPromotedAnchors,
        EmptyStateContext.rosterNoCharacters,
        EmptyStateContext.layerSetNoCandidates,
      },
    );
  });
}
