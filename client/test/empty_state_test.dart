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

  test('the enumeration covers the contexts named in K12 AC, plus what has been added since', () {
    // The five K12 named — none may quietly disappear.
    expect(
      EmptyStateContext.values.toSet(),
      containsAll({
        EmptyStateContext.tripNoDays,
        EmptyStateContext.dayNoPassages,
        EmptyStateContext.bboxNoPromotedAnchors,
        EmptyStateContext.rosterNoCharacters,
        EmptyStateContext.layerSetNoCandidates,
      }),
    );
    // And the whole enumeration, so a new context is a deliberate addition
    // with its own registry copy. Added since K12: the three alternate
    // surfaces (issue #324), where the copy they replaced explained the model
    // instead of naming the next action.
    expect(
      EmptyStateContext.values.toSet(),
      {
        EmptyStateContext.tripNoDays,
        EmptyStateContext.dayNoPassages,
        EmptyStateContext.bboxNoPromotedAnchors,
        EmptyStateContext.rosterNoCharacters,
        EmptyStateContext.layerSetNoCandidates,
        EmptyStateContext.passageNoAlternates,
        EmptyStateContext.branchNoAnchors,
        EmptyStateContext.branchNoNarration,
      },
    );
  });
}
