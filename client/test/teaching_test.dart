// FR142(e) (Story K12a) — teaching moments: one per non-inferable
// behaviour, dismissible per trip, always reachable from an inline help
// affordance.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';

/// #347 — the registry can be complete and well-formed while a moment is
/// never mounted anywhere (`staleRouteIsDeliberate` shipped that way: entry,
/// copy and help affordance all present, no widget in
/// `presentation/` ever referenced it). This scans the actual Presentation
/// source rather than trusting another enumeration, so a moment added
/// without its `TeachingBlock`/`TeachingHelpIcon` pair fails here the same
/// way the old one would have.
///
/// `flutter test` runs with the client package as its working directory
/// (see `reveal_gate_lint_test.dart`), so `lib/presentation` is relative.
bool _mountsBlockAndHelpIcon(String momentName) {
  final dir = Directory('lib/presentation');
  final blockPattern = RegExp('TeachingBlock\\([\\s\\S]{0,300}?TeachingMoment\\.$momentName\\b');
  final iconPattern = RegExp('TeachingHelpIcon\\([\\s\\S]{0,300}?TeachingMoment\\.$momentName\\b');
  var hasBlock = false;
  var hasIcon = false;
  for (final entity in dir.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final content = entity.readAsStringSync();
    hasBlock = hasBlock || blockPattern.hasMatch(content);
    hasIcon = hasIcon || iconPattern.hasMatch(content);
  }
  return hasBlock && hasIcon;
}

/// Unmounted today for reasons unrelated to #347 — filed as their own defect
/// (#353) rather than fixed here, since #347's scope is `staleRouteIsDeliberate`
/// only. This carve-out is what makes the debt visible instead of silently
/// masking it: shrink it only by actually mounting the moment removed from
/// it, never by widening the check.
const _mountedElsewhereTodo = {
  TeachingMoment.promotionNotIntoDay,
  TeachingMoment.revealIsRoleProperty,
  TeachingMoment.composeDistanceIsOutcome,
};

void main() {
  test('every TeachingMoment naming a surface is actually mounted there', () {
    for (final moment in TeachingMoment.values) {
      if (_mountedElsewhereTodo.contains(moment)) continue;
      expect(
        _mountsBlockAndHelpIcon(moment.name),
        isTrue,
        reason: '$moment has a registry entry but no TeachingBlock/TeachingHelpIcon pair found in '
            'presentation/ referencing it — a complete, well-formed entry can still be dead on '
            'its surface (#347).',
      );
    }
  });

  test('the known-unmounted carve-out names only moments actually still unmounted (#353)', () {
    // Guards the carve-out itself from going stale: once a listed moment is
    // mounted, it must come out of `_mountedElsewhereTodo` in the same change.
    for (final moment in _mountedElsewhereTodo) {
      expect(
        _mountsBlockAndHelpIcon(moment.name),
        isFalse,
        reason: '$moment is mounted now — remove it from _mountedElsewhereTodo (and close #353 '
            'if that was the last one).',
      );
    }
  });


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
