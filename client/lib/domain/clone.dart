// FR74 / FR74b (Stories G2, G2b) and ARCH §11.8 — "clone semantics: an
// enumerated copy, not a deep copy."
//
// The load-bearing rule: **enumerate what is copied rather than excluding
// what isn't.** A table or payload field added later is *not* carried by a
// clone unless someone adds it to the allowlist here. The one clause that
// must never regress is the **profile-grant exclusion** — FR78 makes sharing
// per-trip and revisable by design, so carrying grants forward would make
// cloning a consent-laundering path (last year's medical disclosure silently
// re-shared on this year's different trip). There is **no scope in which
// consent is inherited**.
//
// What this module operates on:
//   * `Trip` — the canonical payload (`trip.dart`). A whole-trip / authored
//     clone copies it in full via `toJson()`/`fromJson`, swapping only id,
//     title, and timestamps.
//   * `TripRoster` — membership, group assignments, shared gear, meal
//     responsibilities, Author notes (`roster.dart`).
//   * `declaredModes` — carried with the authored trip; re-declared at trip
//     initiation when the authored trip is not in scope (FR144).
//
// What it deliberately does **not** model, because nothing on the
// Character-layer allowlist has a home in this client yet: `profile_grant`,
// granted permissions / arrival visibility, `reveal_state`, `arrival`,
// `story_choice`, `field_note`, `amendment`, `feedback`, journals. The
// exclusion is therefore structural here — but [describeClone] still names
// every one of them in its not-carried list so the Author sees the guarantee
// before the clone runs (FR74b: the scope "names what it will and will not
// bring before the clone is created").
library;

import 'roster.dart';
import 'trip.dart';

/// FR74b's four offered scopes.
enum CloneScope {
  /// Everything on the §11.8 allowlist: the authored trip in full plus the
  /// roster.
  wholeTrip,

  /// Membership and group assignments only — no days, passages, anchors, or
  /// content. Runs trip initiation (it has nothing to inherit a bbox or
  /// modes from).
  rosterOnly,

  /// The full authored structure with an empty roster; everything assigned
  /// to a (now absent) person is dropped, not left dangling.
  authoredTripOnly,

  /// Author picks the parts — see [CloneParts].
  perPart,
}

/// The Author's selection for [CloneScope.perPart].
class CloneParts {
  const CloneParts({this.roster = false, this.authoredTrip = false});
  final bool roster;
  final bool authoredTrip;
}

bool _carriesRoster(CloneScope scope, CloneParts parts) => switch (scope) {
      CloneScope.wholeTrip => true,
      CloneScope.rosterOnly => true,
      CloneScope.authoredTripOnly => false,
      CloneScope.perPart => parts.roster,
    };

bool _carriesAuthoredTrip(CloneScope scope, CloneParts parts) => switch (scope) {
      CloneScope.wholeTrip => true,
      CloneScope.rosterOnly => false,
      CloneScope.authoredTripOnly => true,
      CloneScope.perPart => parts.authoredTrip,
    };

/// The carried / not-carried statement shown to the Author *before* the clone
/// is created (FR74b). [runsTripInitiation] is true whenever the authored
/// trip is not in scope: there is no bbox, mode set, or itinerary to inherit,
/// so the new trip starts at the location prompt (FR96, FR120, FR144).
class CloneManifest {
  const CloneManifest({
    required this.scope,
    required this.carried,
    required this.notCarried,
    required this.runsTripInitiation,
  });

  final CloneScope scope;
  final List<String> carried;
  final List<String> notCarried;
  final bool runsTripInitiation;

  /// Invariant used by the dialog and asserted in tests: consent is never on
  /// the carried list, in any scope.
  bool get carriesConsent => false;
}

const List<String> _consentAndLayerExclusions = [
  'Profile grants — every Character re-grants for this trip',
  'Arrival-visibility permission',
  'Reveals, arrivals, and in-story choices',
  'Field notes, feedback, amendments, and journals',
];

/// Builds the [CloneManifest] for a scope without touching any trip data —
/// this is what the scope picker renders as the Author changes the selection.
CloneManifest describeClone(CloneScope scope, {CloneParts parts = const CloneParts()}) {
  final carriesRoster = _carriesRoster(scope, parts);
  final carriesAuthored = _carriesAuthoredTrip(scope, parts);

  final carried = <String>[
    if (carriesAuthored) ...[
      'The authored trip — bbox, layers, anchors, roles, reveal settings, '
          'passages, days, and arc',
      'Declared travel modes',
    ],
    if (carriesRoster) ...[
      'Roster membership',
      'Group and sub-group assignments',
      'Shared gear and meal responsibilities',
      'Author notes (they follow the person, not the trip)',
    ],
  ];

  final notCarried = <String>[
    ..._consentAndLayerExclusions,
    if (!carriesAuthored)
      'Days, passages, anchors, and content — you set the location, area, and '
          'modes fresh',
    if (!carriesRoster)
      'The roster — this clone starts with nobody on it; anything assigned to '
          'a person (groups, shared gear, meals) is dropped, not left dangling',
  ];

  return CloneManifest(
    scope: scope,
    carried: carried,
    notCarried: notCarried,
    runsTripInitiation: !carriesAuthored,
  );
}

/// The product of a clone: a fresh [Trip], its [TripRoster], the declared
/// modes it starts with, and whether the caller must now run trip
/// initiation.
class CloneOutcome {
  const CloneOutcome({
    required this.trip,
    required this.roster,
    required this.declaredModes,
    required this.runsTripInitiation,
  });

  final Trip trip;
  final TripRoster roster;
  final Set<String> declaredModes;
  final bool runsTripInitiation;
}

/// Produces a clone of [source] at [scope]. Pure: no persistence, no clocks,
/// no id generation — [newId] and [nowIso] are supplied so the result is
/// deterministic and testable.
///
/// The enumerated copy (ARCH §11.8):
///   * authored trip in scope → the payload is copied **in full** via
///     `source.toJson()`, with only `id`, `title`, `created_at`, and
///     `updated_at` replaced;
///   * authored trip out of scope → a blank [Trip] (no days, anchors,
///     duration, or weights), and [CloneOutcome.runsTripInitiation] is true;
///   * roster in scope → membership, groups, gear, meals, and Author notes
///     are carried (Author-note `updated_at` verbatim); if the authored trip
///     is *not* also in scope, per-day / per-passage group overrides are
///     cleared (nothing to point at);
///   * roster out of scope → [TripRoster.empty]; everything that was assigned
///     to a person is gone with them, not dangling.
///
/// Nothing on the consent / Character-layer allowlist is ever carried — see
/// the library doc comment.
CloneOutcome cloneTrip({
  required Trip source,
  required TripRoster sourceRoster,
  required Set<String> sourceDeclaredModes,
  required CloneScope scope,
  required String newId,
  required String nowIso,
  CloneParts parts = const CloneParts(),
  String? title,
}) {
  final carriesRoster = _carriesRoster(scope, parts);
  final carriesAuthored = _carriesAuthoredTrip(scope, parts);
  final newTitle = title ?? _defaultTitle(source.title, carriesAuthored, carriesRoster);

  final Trip clonedTrip;
  if (carriesAuthored) {
    final json = source.toJson()
      ..['id'] = newId
      ..['title'] = newTitle
      ..['created_at'] = nowIso
      ..['updated_at'] = nowIso;
    clonedTrip = Trip.fromJson(json);
  } else {
    clonedTrip = Trip(
      id: newId,
      title: newTitle,
      createdAt: nowIso,
      updatedAt: nowIso,
    );
  }

  final TripRoster clonedRoster;
  if (carriesRoster) {
    // Round-trip for a clean deep copy, then drop position overrides when
    // there is no itinerary to key them to.
    var r = TripRoster.fromJson(sourceRoster.toJson());
    if (!carriesAuthored) r = r.withoutPositionOverrides();
    clonedRoster = r;
  } else {
    // "Where a scope drops people, everything assigned to them drops with
    // them" — dropping the whole roster is the empty case of that rule.
    clonedRoster = sourceRoster.retainingPeople(const {});
  }

  return CloneOutcome(
    trip: clonedTrip,
    roster: clonedRoster,
    declaredModes: carriesAuthored ? {...sourceDeclaredModes} : const {},
    runsTripInitiation: !carriesAuthored,
  );
}

String _defaultTitle(String source, bool carriesAuthored, bool carriesRoster) {
  if (!carriesAuthored && carriesRoster) return '$source — roster';
  if (carriesAuthored && !carriesRoster) return '$source — route';
  return 'Copy of $source';
}
