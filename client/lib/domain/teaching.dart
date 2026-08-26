/// FR142(e) (Story K12a) — teaching is first-run and dismissible: where a
/// behaviour is not inferable from the interface, Plotlines explains it in
/// place, at the moment it applies, in a dismissible block. [TeachingMoment]
/// is the enumeration K12a's AC requires ("one per non-inferable behaviour,
/// each naming the surface it appears on"); [teachingRegistry] pairs each
/// with its surface, its copy, and the inline help affordance that keeps a
/// dismissed tip reachable — the same reachability discipline as K12's
/// [ReachableObject] registry (`reachability.dart`), verified for
/// completeness the same way (see `teaching_test.dart`).
///
/// [TeachingDismissals] tracks dismissal scoped to a trip: "a tip dismissed
/// on one trip does not reappear there and does appear on the next" (K12a
/// AC). It holds no [Trip] payload data and never disables anything by
/// itself — a teaching block is presentation-layer chrome shown or hidden by
/// consulting [TeachingDismissals.isDismissed], so "no teaching block is
/// load-bearing" holds structurally: nothing here can make a control
/// inoperable, only a block of copy invisible.
///
/// Deliberately excluded from [TeachingMoment]: live status text (e.g.
/// "routing available in about 3 minutes", N2) is part of the control it
/// annotates and is never dismissible, so it has no entry and no dismissal
/// path. Empty states (FR142(c), `empty_state.dart`) and failures (M13) are
/// likewise out of this enumeration by design.
///
/// Not part of the trip payload schema — this is authoring-surface teaching
/// copy and per-trip dismissal state, not trip content.
library;

/// One non-inferable behaviour K12a's AC names as needing first-run teaching.
enum TeachingMoment {
  /// Promoting a candidate does not place it into a day.
  promotionNotIntoDay,

  /// Reveal is a property of a role, not of a place.
  revealIsRoleProperty,

  /// A stale route is deliberate (Q3), not broken.
  staleRouteIsDeliberate,

  /// In Compose mode, distance is a reported outcome, not an enforced input.
  composeDistanceIsOutcome,
}

/// The copy, surface, and reachability affordance for one [TeachingMoment].
class TeachingCopy {
  const TeachingCopy({
    required this.surface,
    required this.message,
    required this.helpAffordance,
  });

  /// Stable identifier for the surface this teaching moment appears on.
  final String surface;

  /// The dismissible explanation itself.
  final String message;

  /// Identifier for the inline help affordance on [surface] that keeps this
  /// tip reachable after it's dismissed — K12a's AC: "every dismissed tip is
  /// reachable from an inline help affordance on its own surface."
  final String helpAffordance;
}

/// The teaching enumeration. Every [TeachingMoment] must have an entry here
/// — see `teaching_test.dart`'s completeness check.
const Map<TeachingMoment, TeachingCopy> teachingRegistry = {
  TeachingMoment.promotionNotIntoDay: TeachingCopy(
    surface: 'anchors_view',
    message: 'Promoting adds this place to your trip as an anchor — it still needs to be placed into a day.',
    helpAffordance: 'anchors_view_help',
  ),
  TeachingMoment.revealIsRoleProperty: TeachingCopy(
    surface: 'anchor_role_editor',
    message: "Reveal belongs to a role on this anchor, not to the place itself — the same anchor can hold content for arrival and content that's always visible.",
    helpAffordance: 'anchor_role_editor_help',
  ),
  TeachingMoment.staleRouteIsDeliberate: TeachingCopy(
    surface: 'stale_list',
    message: 'A stale route means an edit invalidated it, not that something is broken — it stays viewable until you resolve it.',
    helpAffordance: 'stale_list_help',
  ),
  TeachingMoment.composeDistanceIsOutcome: TeachingCopy(
    surface: 'day_view_compose_mode',
    message: 'In Compose mode you pick the places; the engine connects them, and the resulting distance is reported, not enforced.',
    helpAffordance: 'day_view_compose_mode_help',
  ),
};

/// Every [TeachingMoment] the registry is missing an entry for, or whose
/// entry has no help affordance — empty when FR142(e)'s reachability
/// requirement is fully covered.
List<TeachingMoment> teachingMomentsMissingHelpAffordance() => [
      for (final moment in TeachingMoment.values)
        if ((teachingRegistry[moment]?.helpAffordance.trim().isEmpty) ?? true) moment,
    ];

/// Per-trip dismissal state for [TeachingMoment]s. Session-lived, scoped by
/// trip id — construct one per open trip (or key an instance's calls by
/// trip id, as here) so a dismissal on one trip never suppresses the same
/// moment on another.
class TeachingDismissals {
  final Map<String, Set<TeachingMoment>> _dismissedByTrip = {};

  /// Whether [moment] was dismissed on [tripId].
  bool isDismissed(String tripId, TeachingMoment moment) => _dismissedByTrip[tripId]?.contains(moment) ?? false;

  /// Dismisses [moment] for [tripId] only.
  void dismiss(String tripId, TeachingMoment moment) {
    _dismissedByTrip.putIfAbsent(tripId, () => <TeachingMoment>{}).add(moment);
  }

  /// Whether [moment] should currently be shown on [tripId] — the inverse of
  /// [isDismissed], named for call sites that gate rendering on it.
  bool shouldShow(String tripId, TeachingMoment moment) => !isDismissed(tripId, moment);
}
