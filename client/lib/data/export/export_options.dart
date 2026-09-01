// Wireframe screen "04 Cue Sheet + Export"'s CONTENTS toggles. Track +
// elevation is always on (it's the geometry the export exists to carry —
// there's no meaningful "off" for it); the other three are real booleans
// the writers gate on, not decoration.
//
// Splitting (single file vs. per day) needs no writer support at all: a
// caller wanting per-day files just calls a writer once per
// `trip.copyWith(days: [day])` — see `presentation/screens/plan_tabs/export_tab.dart`.
library;

import '../../domain/domain.dart';

/// The four file formats FR44 names. Public because it is also the currency
/// of the **output** plugin seam (ARCH §14.3): an `OutputIntegration` declares
/// which formats it accepts and asks a `TripPayloadWriter` for the bytes — it
/// never encodes its own (D58 keeps all four writers on one code path).
///
/// `presentation/screens/plan_tabs/export_tab.dart` still carries a private
/// `_ExportFormat` that predates this one; the two collapse together when F3's
/// writers move to the core `export_trip` path.
enum ExportFormat {
  gpx,
  tcx,
  geojson,
  fit;

  /// The file extension, which is also the wire name in the core's
  /// `POST /trips/{id}/export`.
  String get extension => name;

  bool get isBinary => this == ExportFormat.fit;
}

class ExportOptions {
  const ExportOptions({
    this.includeWaypoints = true,
    this.includeAlternates = false,
    this.includeCueSheet = false,
    this.cueSheetsBySegmentId = const {},
  });

  final bool includeWaypoints;
  final bool includeAlternates;

  /// Real cue-sheet embedding needs the derived sheets handed in — the
  /// writers have no sidecar access of their own (ARCH §9.1: only the Data
  /// layer's `RoutingClient` talks to the sidecar). The Export tab fetches
  /// these the same way the Cue Sheet tab already does, via `client.cuesFor`.
  final bool includeCueSheet;
  final Map<String, CueSheet> cueSheetsBySegmentId;
}
