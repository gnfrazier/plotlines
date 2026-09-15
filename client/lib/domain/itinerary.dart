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
/// **Anchors, since issue #393.** A promoted [Anchor]'s narrative role can now
/// name its day (`Role.dayId`/`Role.segmentId`, issue #384), so "places" here
/// is [Day.nodes]/[Segment.nodes] (never reveal-gated — only `Role` content
/// is, per O5/P11) *plus* whichever of that day's anchor titles are
/// reveal-visible. This function stays reveal-agnostic on purpose — Domain
/// may not import `RevealResolver` (ARCH §10.1's layering: Data depends on
/// Domain, not the reverse) — so [buildItinerary] takes the already-resolved
/// [anchorTitlesByDayId] map rather than resolving anything itself; callers
/// build it with `data/character_journey.dart`'s `revealedAnchorTitlesByDay`.
library;

import 'day.dart';
import 'day_timeline.dart';
import 'display_format.dart';
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
  DisplayFormat format = const DisplayFormat(),
  Map<String, List<String>> anchorTitlesByDayId = const {},
}) {
  final days = attendedDayIds == null
      ? trip.days
      : trip.days.where((d) => attendedDayIds.contains(d.id)).toList();
  return Itinerary(
    title: characterLabel == null ? trip.title : '${trip.title} — $characterLabel',
    isIndividual: attendedDayIds != null,
    days: [
      for (final day in days)
        _buildDayEntry(day, format, anchorTitlesByDayId[day.id] ?? const []),
    ],
  );
}

ItineraryDayEntry _buildDayEntry(Day day, DisplayFormat format, List<String> anchorTitles) {
  final heading = 'Day ${day.index}${day.title != null ? ' — ${day.title}' : ''}';
  return ItineraryDayEntry(
    day: day,
    heading: heading,
    paragraphs: day.isRest
        ? [_restDayAccount(day, anchorTitles)]
        : _routeDayAccount(day, format, anchorTitles),
  );
}

String _restDayAccount(Day day, List<String> anchorTitles) {
  final sentences = <String>[if (day.note != null) day.note! else 'A rest day, no route.'];
  final agenda = [
    ...day.nodes.where((n) => n.title != null).map((n) => n.title!),
    ...anchorTitles,
  ];
  if (agenda.isNotEmpty) {
    sentences.add('On the agenda: ${agenda.join(', ')}.');
  }
  return sentences.join(' ');
}

List<String> _routeDayAccount(Day day, DisplayFormat format, List<String> anchorTitles) {
  final paragraphs = <String>[];

  final legs = <String>[];
  for (final entry in dayTimeline(day)) {
    switch (entry) {
      case PassageEntry():
        final distanceM = entry.passage.metrics?.distanceM;
        final distanceText =
            distanceM == null ? '' : ' (${format.formatDistance(distanceM)})';
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
    ...anchorTitles,
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
