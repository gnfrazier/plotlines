/// The object that crosses a content boundary — ARCH §6.1 (`export_trip`),
/// §14.3 (`OutputIntegration.pushTrip`), P11.
///
/// [RevealResolver] answers "may this one role's content render, for this one
/// Character, right now." [RevealView] is that answer applied to a whole trip
/// and handed to something on the *other* side of a boundary: an export
/// writer, a print layout, an offline package, a push to Garmin. Both
/// signatures the architecture fixes take one — `export_trip(trip, fmt,
/// contents, reveal: RevealView)` and `pushTrip(Trip trip, RevealView reveal)`
/// — because those are the paths nobody thinks to test with unrevealed
/// content present, and a spoiled trip cannot be un-spoiled (ARCH A22).
///
/// **Why the licence lines and the payload writer live here too.** Three
/// obligations attach to exactly the same event — content leaving the app —
/// and each has its own way of being forgotten:
///
/// 1.  **Reveal** (P11). [rolesFor] is the only way to reach a role's title,
///     note, or media through this object; a withheld role comes back with
///     nulls, a hazard role always comes back released (FR115).
/// 2.  **Attribution** (FR86, FR95, FR101; ARCH §12.2). Every layer whose
///     data is in the artifact is owed its credit, and elevation's CC BY and
///     the basemap's ODbL are owed always because both ship with the home
///     region. A view is constructed with them or it is not a valid view —
///     `PluginRegistry` refuses to push one with an empty [attribution], the
///     same shape as the core's `assert_attribution_complete`.
/// 3.  **Encoding** (D58). Bytes come from a [TripPayloadWriter] the caller
///     supplies — the core's writers — so an integration that needs FIT calls
///     the one FIT writer rather than carrying a second one that drifts.
///
/// **Author notes (FR135) are absent by construction, not by filtering.** They
/// are not in the trip payload at all — they live in their own `author_note`
/// table (ARCH D50, D55) — so there is no path from a [RevealView] to one.
/// That is deliberate: notes are the *never-release* class, and "withheld"
/// would be the wrong state for them because it implies a later release.
library;

import '../domain/anchor.dart';
import '../domain/attribution_line.dart';
import '../domain/trip.dart';
import 'export/export_options.dart';
import 'reveal_resolver.dart';

/// Supplies the encoded bytes for one format. Implemented over the core's
/// `export_trip` path (D58) — never by an integration itself.
abstract class TripPayloadWriter {
  /// The formats this writer can produce. An empty set means "no bytes are
  /// available", which is a real state: a trip whose route is stale is
  /// viewable but not exportable (FR140 / D52).
  Set<ExportFormat> get formats;

  /// The bytes for [format], already reveal-gated at the byte boundary
  /// (punch-list §6A.2 asserts on these bytes, not on the code path).
  Future<List<int>> bytes(ExportFormat format);
}

class RevealView {
  // Positional because the private fields cannot be named parameters; the two
  // factories below are the only call sites.
  const RevealView._(
    this.trip,
    this._resolver,
    this._arrivedAnchorIds,
    this._authorSelf,
    this.attribution,
    this._payloadWriter,
  );

  /// The Author looking at their own trip: everything they wrote is theirs to
  /// see. Never the right view for anything a Character receives.
  factory RevealView.asAuthor(
    Trip trip, {
    RevealResolver resolver = const RevealResolver(),
    List<AttributionLine>? attribution,
    TripPayloadWriter? payloadWriter,
  }) =>
      RevealView._(trip, resolver, const {}, true,
          attribution ?? attributionForTrip(trip), payloadWriter);

  /// A Character's view, and the Author's "preview as a Character would see
  /// it" (O5's AC) when [arrivedAnchorIds] is empty — which is also the right
  /// view for anything handed to a device before departure.
  factory RevealView.asCharacter(
    Trip trip, {
    Set<String> arrivedAnchorIds = const {},
    RevealResolver resolver = const RevealResolver(),
    List<AttributionLine>? attribution,
    TripPayloadWriter? payloadWriter,
  }) =>
      RevealView._(trip, resolver, arrivedAnchorIds, false,
          attribution ?? attributionForTrip(trip), payloadWriter);

  final Trip trip;
  final RevealResolver _resolver;
  final Set<String> _arrivedAnchorIds;
  final bool _authorSelf;
  final TripPayloadWriter? _payloadWriter;

  /// Every credit owed by the data in this artifact. Never hardcoded at a
  /// surface: derived from the trip's own provenance plus the two credits
  /// that ship with the home region (ARCH §12.2).
  final List<AttributionLine> attribution;

  /// The formats bytes can be had in — empty when no writer was supplied.
  Set<ExportFormat> get payloadFormats => _payloadWriter?.formats ?? const {};

  /// Whether this artifact may leave the app at all. A view with no credit
  /// lines has lost track of an obligation somewhere upstream; it is a build
  /// failure, not a warning to render (FR101).
  bool get carriesAttribution => attribution.isNotEmpty;

  /// [anchor]'s roles, resolved. The only way to reach role content through
  /// this object.
  List<RevealedRole> rolesFor(Anchor anchor) =>
      _resolver.resolveAnchor(anchor, hasArrived: hasArrived(anchor));

  /// Every role of every anchor on the trip, resolved in anchor order.
  List<RevealedRole> get resolvedRoles =>
      [for (final anchor in trip.anchors) ...rolesFor(anchor)];

  /// The roles whose content is actually released into this artifact.
  List<RevealedRole> get releasedRoles =>
      [for (final role in resolvedRoles) if (role.visible) role];

  bool hasArrived(Anchor anchor) =>
      _authorSelf || _arrivedAnchorIds.contains(anchor.id);

  /// The encoded trip. Throws when no writer was supplied or the writer does
  /// not produce [format] — a caller checks [payloadFormats] first, and an
  /// integration declares what it accepts so the registry can check for it.
  Future<List<int>> payload(ExportFormat format) {
    final writer = _payloadWriter;
    if (writer == null || !writer.formats.contains(format)) {
      throw StateError(
        'no core writer for ${format.name} on this RevealView — an integration '
        'never encodes its own payload (ARCH §14.3, D58)',
      );
    }
    return writer.bytes(format);
  }
}

/// The credit lines a trip owes: whatever its provenance recorded, plus
/// elevation's CC BY and the basemap's ODbL, which are owed on every artifact
/// because both ship with the home region (FR86, FR95). Deduplicated by
/// layer — a trip that already records the basemap does not credit it twice.
List<AttributionLine> attributionForTrip(Trip trip) {
  final lines = <String, AttributionLine>{};
  for (final line in aboutStaticAttribution) {
    lines[line.layer] = line;
  }
  for (final a in trip.provenance?.attribution ?? const <Attribution>[]) {
    lines[a.source] = AttributionLine(
      layer: a.source,
      licence: a.licence,
      attribution: a.credit,
      termsUrl: a.url ?? '',
    );
  }
  final out = lines.values.toList()
    ..sort((a, b) {
      if (a.builtin != b.builtin) return a.builtin ? -1 : 1;
      return a.layer.compareTo(b.layer);
    });
  return List.unmodifiable(out);
}
