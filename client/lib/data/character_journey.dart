/// H13 (FR132, FR116) — the Character-facing reading surface's "plot points"
/// list: every [Anchor]'s narrative role (`RoleKind.narrative` — PRD §4.3,
/// *"Plot points are the point in Plotlines"*), resolved through
/// [RevealResolver] rather than read off [Role] directly, so the in-app
/// reading screen and its print output share one reveal-safe source (gate 1
/// of `tools/ci/reveal_gate_lint.sh`).
///
/// **Why `hasArrived` defaults to "never."** [RevealResolver]'s own doc
/// comment already names the gap: "[hasArrived] stands in for the Character
/// reveal-state layer... until that layer exists." That layer is the Field
/// Runtime's trigger engine (ARCH §6.2) — GPS-triggered arrival detection —
/// and it is not built. Rather than invent a fake arrival signal for this
/// story, [buildPlotPoints] applies the same policy SPIKE-F chose for the
/// *other* reader with no live arrival signal, the anonymous web share (ARCH
/// §10.3, D59): a permanently empty revealed set. A held plot point renders
/// as a placeholder that keeps its [arcStage] but no content — "the paper
/// copy cannot spoil the trip" holds by construction, never by discipline.
/// [hasArrived] is a parameter (not a hardcoded `false`) purely so a future
/// caller wired to a real reveal-state layer can supply one without this
/// module changing.
///
/// **Scope, matching `itinerary.dart`'s own precedent.** Anchors are
/// trip-scoped (`Trip.anchors`); nothing in the object model associates one
/// with a specific day (`itinerary.dart`'s doc comment records the same
/// gap for "places"). Plot points therefore read as one trip-wide list, in
/// [Trip.anchors] order, not threaded into a per-day account — a real
/// improvement gated on that linkage existing, not something this module can
/// close on its own.
library;

import '../domain/domain.dart';
import 'reveal_resolver.dart';

/// One narrative role, reveal-resolved for a Character-facing reading
/// surface. [visible] is `false` for [title]/[note] withheld; [arcStage] is
/// never withheld — FR116's "the arc's shape" survives a held plot point.
class PlotPointEntry {
  const PlotPointEntry({
    required this.anchorId,
    required this.roleId,
    required this.visible,
    this.title,
    this.note,
    this.arcStage,
    this.hazard = false,
  });

  final String anchorId;
  final String roleId;
  final bool visible;
  final String? title;
  final String? note;
  final ArcStage? arcStage;

  /// FR115 — a hazard/technical-crux role. Always [visible] (the resolver
  /// enforces this), carried through so a reading surface can badge it
  /// distinctly from an ordinary always-visible narrative role.
  final bool hazard;
}

/// Every narrative role across [trip], reveal-resolved. [hasArrived] answers
/// "has this Character reached this anchor" — see the file doc comment for
/// why it defaults to "never reached."
List<PlotPointEntry> buildPlotPoints(
  Trip trip, {
  bool Function(String anchorId)? hasArrived,
}) {
  const resolver = RevealResolver();
  final entries = <PlotPointEntry>[];
  for (final anchor in trip.anchors) {
    final arrived = hasArrived?.call(anchor.id) ?? false;
    for (final role in anchor.roles) {
      if (role.kind != RoleKind.narrative) continue;
      final revealed = resolver.resolve(role, hasArrived: arrived, anchorCoord: anchor.coord);
      entries.add(PlotPointEntry(
        anchorId: anchor.id,
        roleId: role.id,
        visible: revealed.visible,
        title: revealed.title,
        note: revealed.note,
        arcStage: role.arc,
        hazard: role.hazard,
      ));
    }
  }
  return entries;
}

/// Issue #393 — the day-scoped counterpart to [buildPlotPoints], now that a
/// role can actually name its day (`Role.dayId`, issue #384). Returns plain,
/// already-reveal-resolved title strings grouped by `dayId` rather than a
/// richer type, deliberately: `domain/itinerary.dart`'s [buildItinerary]
/// weaves this into a day's prose account (FR133), and Domain may not import
/// [RevealResolver] (ARCH §10.1's Presentation → State → Domain → Data
/// layering — Data depends on Domain, never the reverse). A withheld role
/// contributes nothing here rather than a placeholder string: FR116
/// withholds a plot point's *content*, not the fact that other, revealed
/// content exists on the same day, and the arc-preserving placeholder
/// ("Held for arrival") already has a home in [buildPlotPoints]'s own list.
///
/// Segment-scoped roles (`Role.segmentId`) are folded in here too — day
/// prose has no finer position to place them at than "this day" — while the
/// per-segment cue sheet (`export_tab.dart`) reads `segmentId` itself for a
/// tighter placement.
Map<String, List<String>> revealedAnchorTitlesByDay(
  Trip trip, {
  bool Function(String anchorId)? hasArrived,
}) {
  const resolver = RevealResolver();
  final byDay = <String, List<String>>{};
  for (final anchor in trip.anchors) {
    final arrived = hasArrived?.call(anchor.id) ?? false;
    for (final role in anchor.roles) {
      if (role.kind != RoleKind.narrative || role.dayId == null) continue;
      final revealed = resolver.resolve(role, hasArrived: arrived, anchorCoord: anchor.coord);
      if (!revealed.visible) continue;
      final title = revealed.title ?? anchor.title;
      if (title == null) continue;
      (byDay[role.dayId!] ??= <String>[]).add(title);
    }
  }
  return byDay;
}
