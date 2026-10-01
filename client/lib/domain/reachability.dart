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

/// Every object kind K12's AC enumerates as needing a reachable home, plus
/// what has been added since.
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

  /// A Character on the trip's roster (D4b). Added by K12's wiring: the
  /// Roster tab used to list the session's response grid, which starts empty
  /// on every open, so a reopened trip's Characters were on no surface.
  character,

  /// Character detail view (D5).
  characterNote,

  /// Roster (D7).
  groupAssignment,

  /// Stale list (Q3).
  staleItem,

  /// An alternate on a passage (C4). Drawn on the Route tab's map (#324) and
  /// found back on the Logistics tab, under the passage it diverges from —
  /// the one object an Author makes on one surface and inspects on another,
  /// which is exactly the case FR142(b) exists for.
  alternate,
}

/// Where one [ReachableObject] is found back, and a short label for the
/// affordance that gets an Author there.
class ReachabilityTarget {
  const ReachabilityTarget({
    required this.surface,
    required this.description,
    this.pendingStory,
  });

  /// Stable identifier for the surface, not display copy. A surface id is
  /// checked by `reachability_surfaces_test.dart`, which builds that surface
  /// with one such object in it and finds the object there.
  final String surface;

  /// Human-readable description of the path, for diagnostics and tests.
  final String description;

  /// Set when the object kind cannot be made by an Author yet, naming the
  /// story whose surface both makes it and finds it back. Such a kind is not
  /// a reachability hole — nothing makes it — but its path is still named
  /// here, so the story that adds the maker cannot ship without the finder.
  final String? pendingStory;

  bool get shipped => pendingStory == null;
}

/// The reachability enumeration itself. Every [ReachableObject] must have an
/// entry here — see `reachability_test.dart`'s completeness check, and
/// `reachability_surfaces_test.dart`, which verifies each shipped path on the
/// real widget.
const Map<ReachableObject, ReachabilityTarget> reachabilityRegistry = {
  ReachableObject.anchorAttached: ReachabilityTarget(
    surface: 'anchors_view',
    description: "Layers tab → Anchors view, filter 'Attached' — and on its day",
  ),
  ReachableObject.anchorUnattached: ReachabilityTarget(
    surface: 'anchors_view',
    description: "Layers tab → Anchors view, filter 'Unattached'",
  ),
  ReachableObject.passage: ReachabilityTarget(
    surface: 'day_view',
    description: "Logistics tab, under its day — and the Route tab's day strip",
  ),
  ReachableObject.day: ReachabilityTarget(
    surface: 'trip_view',
    description: "Route tab's day chips — and the Logistics tab's day list",
  ),
  ReachableObject.trip: ReachabilityTarget(
    surface: 'library',
    description: 'Library (G2a)',
  ),
  ReachableObject.character: ReachabilityTarget(
    surface: 'roster_tab',
    description: 'Roster tab — the roster list',
  ),
  ReachableObject.characterNote: ReachabilityTarget(
    surface: 'character_detail_view',
    description: "Roster → the person's detail view (D5)",
    pendingStory: '#58',
  ),
  ReachableObject.groupAssignment: ReachabilityTarget(
    surface: 'roster_board',
    description: 'Roster entry, with per-day and per-passage overrides (D7)',
    pendingStory: '#61',
  ),
  ReachableObject.staleItem: ReachabilityTarget(
    surface: 'stale_list',
    description: "The stale count in the trip's app bar or on Logistics → the stale list (Q3)",
  ),
  ReachableObject.alternate: ReachabilityTarget(
    surface: 'logistics_tab_passage_alternates',
    description: "Logistics tab — the passage's ALTERNATES list (C4)",
  ),
};

/// Every [ReachableObject] the registry is missing an entry for — empty when
/// reachability is fully covered. FR142(b): a non-empty result means an
/// object type shipped without its path named.
List<ReachableObject> unreachableObjectTypes() => [
      for (final kind in ReachableObject.values)
        if (!reachabilityRegistry.containsKey(kind)) kind,
    ];
