/// FR142(b) (Story K12) — reachability: every object an Author creates is
/// findable from a surface without reconstructing how it was made. "Verified
/// against an enumeration, not asserted" (K12's AC) means the enumeration
/// below is exhaustive over [ReachableObject], and [reachabilityRegistry] is
/// checked (see `reachability_test.dart`) to cover every value in it — a new
/// [ReachableObject] with no registry entry fails that check, matching
/// FR142(b)'s "a new object type ships with its path named, or it does not
/// ship."
///
/// Not part of the trip payload schema — this maps object kinds to the
/// authoring surface that lists them back, it is not trip content itself.
library;

/// Every object kind K12's AC enumerates as needing a reachable home.
enum ReachableObject {
  /// N4a anchors view — an anchor attached to a day.
  anchorAttached,

  /// N4a anchors view — an anchor promoted but not placed on any day (O1:
  /// ordinary working state, not an error).
  anchorUnattached,

  /// Day view.
  passage,

  /// Trip view.
  day,

  /// Library (G2a).
  trip,

  /// Character detail view (D5).
  characterNote,

  /// Roster (D7).
  groupAssignment,

  /// Stale list (Q3).
  staleItem,
}

/// Where one [ReachableObject] is found back, and a short label for the
/// affordance that gets an Author there.
class ReachabilityTarget {
  const ReachabilityTarget({required this.surface, required this.description});

  /// Stable identifier for the surface (route name / screen id), not display
  /// copy.
  final String surface;

  /// Human-readable description of the surface, for diagnostics and tests.
  final String description;
}

/// The reachability enumeration itself. Every [ReachableObject] must have an
/// entry here — see `reachability_test.dart`'s completeness check.
const Map<ReachableObject, ReachabilityTarget> reachabilityRegistry = {
  ReachableObject.anchorAttached: ReachabilityTarget(
    surface: 'anchors_view',
    description: "N4a anchors view — attached anchors",
  ),
  ReachableObject.anchorUnattached: ReachabilityTarget(
    surface: 'anchors_view',
    description: "N4a anchors view — unattached anchors",
  ),
  ReachableObject.passage: ReachabilityTarget(
    surface: 'day_view',
    description: 'Day view',
  ),
  ReachableObject.day: ReachabilityTarget(
    surface: 'trip_view',
    description: 'Trip view',
  ),
  ReachableObject.trip: ReachabilityTarget(
    surface: 'library',
    description: 'Library (G2a)',
  ),
  ReachableObject.characterNote: ReachabilityTarget(
    surface: 'character_detail_view',
    description: 'Character detail view (D5)',
  ),
  ReachableObject.groupAssignment: ReachabilityTarget(
    surface: 'roster_board',
    description: 'Roster (D7)',
  ),
  ReachableObject.staleItem: ReachabilityTarget(
    surface: 'stale_list',
    description: 'Stale list (Q3)',
  ),
};

/// Every [ReachableObject] the registry is missing an entry for — empty when
/// reachability is fully covered. FR142(b): a non-empty result means an
/// object type shipped without its path named.
List<ReachableObject> unreachableObjectTypes() => [
      for (final kind in ReachableObject.values)
        if (!reachabilityRegistry.containsKey(kind)) kind,
    ];
