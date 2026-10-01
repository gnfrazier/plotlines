/// FR142(c) (Story K12) — empty states carry a next action rather than
/// stating an absence: a trip with no days, a day with no passages, a bbox
/// with no promoted anchors, a roster with no Characters, a layer set
/// yielding no candidates. Distinct from N4a's "no clusters found" (a
/// *result* belonging with the analysis) and from M13's failure states —
/// neither is an [EmptyStateContext] here.
///
/// Not part of the trip payload schema — this is authoring-surface copy, not
/// trip content.
library;

/// One surface's empty condition, named in K12's AC.
enum EmptyStateContext {
  /// A trip with no days yet.
  tripNoDays,

  /// A day with no passages yet.
  dayNoPassages,

  /// A bbox with no promoted anchors yet.
  bboxNoPromotedAnchors,

  /// A roster with no Characters yet.
  rosterNoCharacters,

  /// A layer set that yielded no candidates.
  layerSetNoCandidates,

  /// A passage with no alternates on it yet (issue #324) — the Logistics
  /// list's own empty condition, whose next action is the map gesture that
  /// makes one.
  passageNoAlternates,

  /// A branch alternate with no anchors attached, on a trip that has none to
  /// attach (issue #324).
  branchNoAnchors,

  /// A branch alternate with no narration on it yet (issue #324).
  branchNoNarration,
}

/// The copy for one [EmptyStateContext]: what's true, and what to do about
/// it. [nextAction] is the required half — FR142(c) fails if it is empty.
class EmptyStateCopy {
  const EmptyStateCopy({required this.message, required this.nextAction});

  /// States the absence plainly; never the whole story on its own.
  final String message;

  /// The action available from this surface right now, stated as an
  /// instruction (e.g. "Add a day to get started") rather than restated
  /// absence.
  final String nextAction;
}

/// The empty-state enumeration. Every [EmptyStateContext] must have an entry
/// here with a non-empty [EmptyStateCopy.nextAction] — see
/// `empty_state_test.dart`.
const Map<EmptyStateContext, EmptyStateCopy> emptyStateRegistry = {
  EmptyStateContext.tripNoDays: EmptyStateCopy(
    message: 'This trip has no days yet.',
    nextAction: 'Add a day, then give it a passage or make it a rest day.',
  ),
  EmptyStateContext.dayNoPassages: EmptyStateCopy(
    message: 'This day has nowhere to go yet.',
    nextAction:
        'Add a passage, or make it a rest day — a rest day holds anchors and detail without a route.',
  ),
  EmptyStateContext.bboxNoPromotedAnchors: EmptyStateCopy(
    message: 'Nothing has been promoted into this trip yet.',
    nextAction:
        'Tap a candidate on the map to promote it, or let Proposals find the good spots.',
  ),
  EmptyStateContext.rosterNoCharacters: EmptyStateCopy(
    message: 'Nobody is on this trip yet.',
    nextAction:
        "Add a Character by name above, or clone a past trip's roster from the Library.",
  ),
  EmptyStateContext.layerSetNoCandidates: EmptyStateCopy(
    message: 'These layers found nothing in this area.',
    nextAction: 'Turn on more layers, or widen the trip area.',
  ),
  EmptyStateContext.passageNoAlternates: EmptyStateCopy(
    message: 'No alternates on this passage.',
    nextAction: 'Draw one on the Route tab: mark where it leaves the route and where it rejoins.',
  ),
  EmptyStateContext.branchNoAnchors: EmptyStateCopy(
    message: 'No anchors in this trip yet.',
    nextAction: 'Promote a place on the Layers tab, then attach it here.',
  ),
  EmptyStateContext.branchNoNarration: EmptyStateCopy(
    message: 'No narration on this branch.',
    nextAction: 'Attach it from the narrative editor.',
  ),
};

/// Every [EmptyStateContext] missing a registry entry, or present but with a
/// blank [EmptyStateCopy.nextAction] — empty when FR142(c) is fully covered.
List<EmptyStateContext> emptyStatesMissingNextAction() => [
      for (final context in EmptyStateContext.values)
        if (emptyStateRegistry[context]?.nextAction.trim().isEmpty ?? true) context,
    ];
