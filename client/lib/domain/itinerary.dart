/// F2 (FR48, FR133) — the master group itinerary and tailored individual
/// itineraries. `dayTimeline` (`day_timeline.dart`) already gives every
/// Character-facing surface the same ordered "passages and the junctions
/// between them" reading; this builds on it rather than re-deriving day
/// order from `Day.segments` a second time, the way the pre-F2 Export tab
/// cue preview once did (`day_timeline.dart`'s own doc comment names this
/// file, "H3's timeline and print," as one of the surfaces meant to land
/// here).
///
/// FR133 — "the Frodo principle" — is why [ItineraryDayEntry.paragraphs] is
/// prose, not a table: transportation, places, hazards and rest/lodging
/// detail are woven into a day's account together. A build that renders
/// logistics as a disjoint panel fails the AC even if every fact in it is
/// correct.
///
/// **Scope note:** promoted [Anchor]s (`anchor.dart`) carry no day/segment
/// linkage anywhere in the current object model — promotion is trip-scoped
/// (`Trip.anchors`), not day-scoped, and nothing records which day an anchor
/// sits on. "Places" here is therefore built from [Day.nodes] /
/// [Segment.nodes], the same day-scoped source the Export tab's existing
/// cue-sheet fallback (`export_tab.dart`'s `_entriesFromAuthoredContent`)
/// already reads for exactly this purpose, and — matching that same existing
/// surface — is not run through `RevealResolver`: nothing in the codebase
/// reveal-gates `Node` content today (only `Role` content is reveal-gated,
/// per O5/P11), and anchors have no day association to resolve against in
/// the first place. Wiring the anchor/role narrative layer into a day's
/// account is real future work, gated on that linkage existing.
library;

import 'day.dart';
import 'day_timeline.dart';
import 'travel_mode.dart';
import 'trip.dart';

/// One day's narrative-register account.
class ItineraryDayEntry {
  ItineraryDayEntry({
    required this.day,
    required this.heading,
    required this.paragraphs,
  });

  final Day day;
  final String heading;

  /// Prose paragraphs, in reading order. Kept as a list rather than one
  /// joined string so a UI or writer picks its own paragraph separator
  /// instead of parsing one back out.
  final List<String> paragraphs;
}

/// FR48 — a master itinerary (every day) or an individual one (only the
/// attended days), built by the same [buildItinerary] so the two can never
/// render a day's account differently — the AC's only stated difference
/// between them is which days are included.
class Itinerary {
  Itinerary({
    required this.title,
    required this.isIndividual,
    required this.days,
  });

  final String title;
  final bool isIndividual;
  final List<ItineraryDayEntry> days;
}

/// [attendedDayIds] `null` builds the master itinerary. A non-null set
/// builds an individual itinerary scoped to a partial-attendance Character —
/// "reflects only that Character's days/passages/transit" — by filtering
/// [Trip.days] down to the attended days before building each day's account.
/// Attendance is per-day, not per-passage: every passage/transition/node on
/// an included day rides along with it, matching FR48's own wording
/// ("days/passages/transit," not "passages within a day").
Itinerary buildItinerary(
  Trip trip, {
  Set<String>? attendedDayIds,
  String? characterLabel,
}) {
  final days = attendedDayIds == null
      ? trip.days
      : trip.days.where((d) => attendedDayIds.contains(d.id)).toList();
  return Itinerary(
    title: characterLabel == null ? trip.title : '${trip.title} — $characterLabel',
    isIndividual: attendedDayIds != null,
    days: [for (final day in days) _buildDayEntry(day)],
  );
}

ItineraryDayEntry _buildDayEntry(Day day) {
  final heading = 'Day ${day.index}${day.title != null ? ' — ${day.title}' : ''}';
  return ItineraryDayEntry(
    day: day,
    heading: heading,
    paragraphs: day.isRest ? [_restDayAccount(day)] : _routeDayAccount(day),
  );
}

String _restDayAccount(Day day) {
  final sentences = <String>[if (day.note != null) day.note! else 'A rest day, no route.'];
  final agenda = day.nodes.where((n) => n.title != null).map((n) => n.title!).toList();
  if (agenda.isNotEmpty) {
    sentences.add('On the agenda: ${agenda.join(', ')}.');
  }
  return sentences.join(' ');
}

List<String> _routeDayAccount(Day day) {
  final paragraphs = <String>[];

  final legs = <String>[];
  for (final entry in dayTimeline(day)) {
    switch (entry) {
      case PassageEntry():
        final distanceM = entry.passage.metrics?.distanceM;
        final distanceText =
            distanceM == null ? '' : ' (${(distanceM / 1000).toStringAsFixed(1)} km)';
        legs.add('${travelModeLabel(entry.mode)}$distanceText');
      case ModeChangeEntry(:final isModeChange, :final toMode) when isModeChange:
        legs.add('switch to ${travelModeLabel(toMode!)}');
      case ModeChangeEntry():
        break;
    }
  }
  if (legs.isNotEmpty) {
    paragraphs.add('${_capitalize(legs.join(', then '))}.');
  }

  final places = <String>[
    for (final segment in day.segments)
      for (final node in segment.nodes)
        if (node.title != null) node.title!,
    for (final node in day.nodes)
      if (node.title != null) node.title!,
  ];
  if (places.isNotEmpty) {
    paragraphs.add('Along the way: ${places.join(', ')}.');
  }

  // FR27 / C11 — day-level and passage-level hazards both surface here; a
  // hazard is never reveal-gated (FR115), so it is woven into the account
  // unconditionally.
  final hazards = [
    ...day.hazards,
    for (final segment in day.segments) ...segment.hazards,
  ];
  if (hazards.isNotEmpty) {
    paragraphs.add('Watch for ${hazards.map((h) => h.title ?? h.severity).join(', ')}.');
  }

  final portages = [
    for (final segment in day.segments) ...segment.portages,
  ];
  if (portages.isNotEmpty) {
    paragraphs.add(
        '${portages.length} portage${portages.length == 1 ? '' : 's'} along the route.');
  }

  return paragraphs;
}

String _capitalize(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
