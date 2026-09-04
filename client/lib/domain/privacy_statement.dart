// K11 / FR138 (issue #117) — the plain-language privacy statement, reachable
// from the About surface on every platform including the lightest (Web guest,
// the share-token reading view). It is *not* legal boilerplate: it says what
// is true, briefly, in the app's own voice.
//
// This is the Dart mirror of `plotlines_core.web.about.PRIVACY_STATEMENT`. The
// service also carries it in `GET /about`, but a surface with no sidecar
// reachable (a fresh Web guest, a reading view) must still be able to show it,
// so the canonical text lives here too — the same pattern the message catalog
// uses for server strings. `privacy_statement_test.dart` pins that every
// clause FR138 names is present; `test_web_about.py` pins the same on the
// Python side.
library;

/// One titled paragraph of the privacy statement.
class PrivacyPoint {
  const PrivacyPoint({required this.id, required this.title, required this.body});

  /// Stable handle, shared with the Python statement and the `/about` payload.
  final String id;
  final String title;
  final String body;

  factory PrivacyPoint.fromJson(Map<String, dynamic> json) => PrivacyPoint(
        id: json['id'] as String,
        title: json['title'] as String,
        body: json['body'] as String,
      );
}

/// The statement, in reading order. Each point maps to a clause FR138 names.
const List<PrivacyPoint> privacyStatement = [
  PrivacyPoint(
    id: 'on_device',
    title: 'What stays on this device',
    body: 'Your trips, routes, notes, and the maps and elevation you have '
        'downloaded all live on this device. Planning works with nothing '
        'signed in.',
  ),
  PrivacyPoint(
    id: 'to_server',
    title: 'What reaches the server',
    body: 'Only things that need other people: signing in, syncing your own '
        'trips between your devices, and sharing a trip or an arrival with '
        'someone you have chosen. Drawing an area or looking up a place is '
        'different — see the next point.',
  ),
  // Phase 0.12 / addendum P1 (issue #252): today this names Overpass and
  // Nominatim because that is what actually runs. Phase 1 (#264) moves map
  // data to a Plotlines-operated mirror — revisit this wording, and its
  // recipient, when that migration lands.
  PrivacyPoint(
    id: 'planning_requests',
    title: 'What planning sends, even signed out',
    body: "Drawing an area to plan in sends that area to Overpass, a "
        "volunteer-run map-data lookup — today hosted in Germany or "
        "Lithuania — so we can show you what is nearby. Typing a place to "
        "search for it sends that text to Nominatim, the OpenStreetMap "
        "Foundation's place-name lookup. Neither request carries your "
        "account, your name, or any other identity.",
  ),
  PrivacyPoint(
    id: 'reveal',
    title: 'Reveal keeps surprises intact — it is not a lock',
    body: 'Hiding a plot point stops it from spoiling the story before you '
        'reach it. It is a guarantee against accidental spoiling, not a '
        'security boundary: do not use it to keep a determined reader out of '
        'data they already hold.',
  ),
  PrivacyPoint(
    id: 'arrival_sharing',
    title: 'Arrival sharing is off until you turn it on',
    body: 'Sharing an arrival lets a specific person see that you reached a '
        'specific plot point. It shares nothing else — not your live '
        'location, not your route — and it defaults to nothing shared. You '
        'choose each field and each person, and you can stop at any time.',
  ),
  PrivacyPoint(
    id: 'author_notes',
    title: "An Author's private notes about a Character",
    body: 'An Author can keep private notes about the people on a trip. Those '
        'notes are visible only to the Author who wrote them, they persist '
        'across trips, and the person they are about can ask to have them '
        'deleted. They are the first thing Plotlines holds about a person '
        'recorded by someone else, which is why this statement spells it out.',
  ),
  PrivacyPoint(
    id: 'guest_sessions',
    title: 'Guest sessions leave no trace',
    body: 'Using Plotlines on the web without an account leaves nothing behind '
        'on the server once the session ends.',
  ),
];

/// Parse the `privacy` list from a `GET /about` payload, falling back to the
/// bundled [privacyStatement] when the payload is absent or malformed — the
/// lightest surfaces must always have something true to show.
List<PrivacyPoint> privacyPointsFrom(Object? aboutPrivacy) {
  if (aboutPrivacy is List && aboutPrivacy.isNotEmpty) {
    try {
      return aboutPrivacy
          .map((e) => PrivacyPoint.fromJson(e as Map<String, dynamic>))
          .toList(growable: false);
    } catch (_) {
      // Malformed — fall through to the bundled copy.
    }
  }
  return privacyStatement;
}
