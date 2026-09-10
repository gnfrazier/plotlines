// FR142(e) (Story K12a) — teaching moments: one per non-inferable
// behaviour, dismissible per trip, always reachable from an inline help
// affordance.
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';

void main() {
  test('every TeachingMoment has a registry entry with a help affordance', () {
    expect(teachingMomentsMissingHelpAffordance(), isEmpty);
    for (final moment in TeachingMoment.values) {
      final copy = teachingRegistry[moment];
      expect(copy, isNotNull, reason: '$moment has no teaching copy');
      expect(copy!.helpAffordance.trim(), isNotEmpty);
      expect(copy.surface.trim(), isNotEmpty);
      expect(copy.message.trim(), isNotEmpty);
    }
  });

  test('the enumeration covers the moments named in K12a AC, plus what has been added since', () {
    // The four K12a named. None may quietly disappear: each is a behaviour
    // the interface cannot make inferable on its own.
    expect(
      TeachingMoment.values.toSet(),
      containsAll({
        TeachingMoment.promotionNotIntoDay,
        TeachingMoment.revealIsRoleProperty,
        TeachingMoment.staleRouteIsDeliberate,
        TeachingMoment.composeDistanceIsOutcome,
      }),
    );
    // And the whole enumeration, so a fifth moment is a deliberate addition
    // with its own registry entry rather than a drive-by. Added since K12a:
    // `branchAnchorsByReference` (issue #324), which was standing body copy
    // on the alternate branch card.
    expect(
      TeachingMoment.values.toSet(),
      {
        TeachingMoment.promotionNotIntoDay,
        TeachingMoment.revealIsRoleProperty,
        TeachingMoment.staleRouteIsDeliberate,
        TeachingMoment.composeDistanceIsOutcome,
        TeachingMoment.branchAnchorsByReference,
      },
    );
  });

  test('a tip is not dismissed anywhere before it is dismissed', () {
    final dismissals = TeachingDismissals();
    expect(dismissals.isDismissed('trip-1', TeachingMoment.promotionNotIntoDay), isFalse);
    expect(dismissals.shouldShow('trip-1', TeachingMoment.promotionNotIntoDay), isTrue);
  });

  test('dismissing a tip on one trip hides it only on that trip', () {
    final dismissals = TeachingDismissals();
    dismissals.dismiss('trip-1', TeachingMoment.staleRouteIsDeliberate);

    expect(dismissals.isDismissed('trip-1', TeachingMoment.staleRouteIsDeliberate), isTrue);
    expect(dismissals.shouldShow('trip-1', TeachingMoment.staleRouteIsDeliberate), isFalse);

    // A different trip — including a brand new one — shows it again.
    expect(dismissals.isDismissed('trip-2', TeachingMoment.staleRouteIsDeliberate), isFalse);
    expect(dismissals.shouldShow('trip-2', TeachingMoment.staleRouteIsDeliberate), isTrue);
  });

  test('dismissing one moment does not dismiss another on the same trip', () {
    final dismissals = TeachingDismissals();
    dismissals.dismiss('trip-1', TeachingMoment.composeDistanceIsOutcome);

    expect(dismissals.isDismissed('trip-1', TeachingMoment.composeDistanceIsOutcome), isTrue);
    expect(dismissals.isDismissed('trip-1', TeachingMoment.revealIsRoleProperty), isFalse);
  });
}
