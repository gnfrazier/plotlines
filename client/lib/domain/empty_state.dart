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
    nextAction: 'Add a day to start building the itinerary.',
  ),
  EmptyStateContext.dayNoPassages: EmptyStateCopy(
    message: 'This day has no passages yet.',
    nextAction: 'Promote a candidate or draw a route to add the first passage.',
  ),
  EmptyStateContext.bboxNoPromotedAnchors: EmptyStateCopy(
    message: 'Nothing in this area has been promoted yet.',
    nextAction: 'Select a candidate on the map and promote it to an anchor.',
  ),
  EmptyStateContext.rosterNoCharacters: EmptyStateCopy(
    message: 'This roster has no Characters yet.',
    nextAction: 'Add a Character to start assigning them to the trip.',
  ),
  EmptyStateContext.layerSetNoCandidates: EmptyStateCopy(
    message: 'This layer selection returned no candidates.',
    nextAction: 'Widen the layer selection or adjust the bbox to bring in more of the map.',
  ),
};

/// Every [EmptyStateContext] missing a registry entry, or present but with a
/// blank [EmptyStateCopy.nextAction] — empty when FR142(c) is fully covered.
List<EmptyStateContext> emptyStatesMissingNextAction() => [
      for (final context in EmptyStateContext.values)
        if (emptyStateRegistry[context]?.nextAction.trim().isEmpty ?? true) context,
    ];
