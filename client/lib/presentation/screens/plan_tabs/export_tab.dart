// Wireframe screen "04 Cue Sheet + Export" — the Trip Shell's Export tab:
// cue-sheet preview (left, F1) + export panel (right, F3/E5), replacing the
// standalone `cue_sheet_screen.dart` (deleted; its cue-derivation logic
// moved here unchanged). New this pass: real content toggles and per-day
// splitting — `export_options.dart`'s `ExportOptions` reached the writers,
// including wiring `/segments/cues` into them for the cue-sheet toggle,
// which the old screen only ever showed on-screen, never exported.
//
// F2 (FR48, FR133) adds `_ItinerarySection`, above the per-day cue sheets:
// the master (every day) or an individual (attended-days-only) itinerary,
// previewed in the same narrative register it prints/exports in. See
// `domain/itinerary.dart` for why the day account's own prose stays
// reveal-agnostic — it reads `Node`s directly (never gated) plus an
// already-resolved anchor-title map this file builds and hands it.
//
// Issue #393 gives both this section and the per-day cue sheet below their
// first rendering of a promoted `Anchor`'s narrative role, now that
// `Role.dayId`/`Role.segmentId` (issue #384) says which day/segment it
// belongs to. `DayCueSection` is shared with the Character-facing read
// screen (H13, issue #87), so its anchor entries *are* reveal-gated
// (`RevealResolver`, via the section's `hasArrived` parameter) even though
// the Day-node entries beside them never were — this file's Export tab use
// passes the Author "preview-as-self" mode, seeing everything.
library;

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../../data/character_journey.dart';
import '../../../data/export/export_options.dart';
import '../../../data/export/fit_writer.dart';
import '../../../data/export/geojson_writer.dart';
import '../../../data/export/gpx_writer.dart';
import '../../../data/export/itinerary_writer.dart';
import '../../../data/export/tcx_writer.dart';
import '../../../data/reveal_resolver.dart';
import '../../../domain/domain.dart';
import '../../../state/providers.dart';
import '../../../state/settings_provider.dart';
import '../../../state/trip_bbox_provider.dart';
import '../../widgets/error_states.dart';
import '../../widgets/print_preview.dart';
import '../../widgets/stale_list_dialog.dart';

class ExportTab extends ConsumerWidget {
  const ExportTab({super.key, required this.trip});
  final Trip trip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    return Row(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(PlotSpacing.s5),
            children: [
              _ItinerarySection(trip: trip),
              for (final day in trip.days)
                DayCueSection(day: day, trip: trip, hasArrived: (_) => true),
              if (trip.days.every((d) => d.segments.isEmpty))
                Padding(
                  padding: const EdgeInsets.all(PlotSpacing.s5),
                  child: Text(
                    'No routed days yet.',
                    style: PlotTypography.body(c.textMuted),
                  ),
                ),
            ],
          ),
        ),
        Container(
          width: 400,
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: c.border)),
          ),
          child: _ExportPanel(trip: trip),
        ),
      ],
    );
  }
}

/// F2 (FR48, FR133) — master/individual itinerary preview, print preview,
/// and Markdown export. Attendance is modelled as a plain set of day ids
/// (`buildItinerary`'s `attendedDayIds`), not a persisted roster — there is
/// no roster/Character object anywhere in the trip payload yet (that is its
/// own future story), and FR48's "tailored individual itineraries for
/// partial-attendance Characters" is satisfiable today as an ad hoc
/// day-attendance selection the Author makes at export time.
class _ItinerarySection extends ConsumerStatefulWidget {
  const _ItinerarySection({required this.trip});
  final Trip trip;

  @override
  ConsumerState<_ItinerarySection> createState() => _ItinerarySectionState();
}

class _ItinerarySectionState extends ConsumerState<_ItinerarySection> {
  bool _individual = false;
  final Set<String> _attendedDayIds = {};
  final _labelController = TextEditingController();
  bool _exporting = false;

  @override
  void dispose() {
    _labelController.dispose();
    super.dispose();
  }

  Itinerary get _itinerary => buildItinerary(
        widget.trip,
        attendedDayIds: _individual ? _attendedDayIds : null,
        characterLabel: _individual && _labelController.text.trim().isNotEmpty
            ? _labelController.text.trim()
            : null,
        format: ref.read(displayFormatProvider),
        // The Author's own itinerary preview, not a Character's — `hasArrived:
        // (_) => true` is `RevealResolver`'s documented "preview-as-self" mode
        // (`data/reveal_resolver.dart`), matching this section's own existing
        // non-reveal-gated treatment of `Day.nodes`.
        anchorTitlesByDayId: revealedAnchorTitlesByDay(widget.trip, hasArrived: (_) => true),
      );

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final itinerary = _itinerary;
    return Padding(
      padding: const EdgeInsets.only(bottom: PlotSpacing.s5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('ITINERARY',
              style: PlotTypography.data(c.textMuted).copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: PlotSpacing.s2),
          Row(
            children: [
              Expanded(
                child: ChoiceChip(
                  label: const Text('MASTER'),
                  selected: !_individual,
                  onSelected: (_) => setState(() => _individual = false),
                ),
              ),
              const SizedBox(width: PlotSpacing.s2),
              Expanded(
                child: ChoiceChip(
                  label: const Text('INDIVIDUAL'),
                  selected: _individual,
                  onSelected: (_) => setState(() => _individual = true),
                ),
              ),
            ],
          ),
          if (_individual) ...[
            const SizedBox(height: PlotSpacing.s3),
            TextField(
              controller: _labelController,
              decoration: const InputDecoration(
                labelText: 'Character (optional)',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: PlotSpacing.s3),
            Text('ATTENDS', style: PlotTypography.data(c.textMuted)),
            const SizedBox(height: PlotSpacing.s2),
            Wrap(
              spacing: PlotSpacing.s2,
              runSpacing: PlotSpacing.s2,
              children: [
                for (final day in widget.trip.days)
                  FilterChip(
                    label: Text('DAY ${day.index}'),
                    selected: _attendedDayIds.contains(day.id),
                    onSelected: (selected) => setState(() {
                      if (selected) {
                        _attendedDayIds.add(day.id);
                      } else {
                        _attendedDayIds.remove(day.id);
                      }
                    }),
                  ),
              ],
            ),
          ],
          const SizedBox(height: PlotSpacing.s4),
          PlotCard(
            padding: const EdgeInsets.all(PlotSpacing.s4),
            child: itinerary.days.isEmpty
                ? Text(
                    _individual ? 'No days selected yet.' : 'No days on this trip yet.',
                    style: PlotTypography.body(c.textMuted),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final entry in itinerary.days) ...[
                        Text(entry.heading, style: PlotTypography.title(c.textPrimary)),
                        const SizedBox(height: PlotSpacing.s1),
                        for (final paragraph in entry.paragraphs)
                          Padding(
                            padding: const EdgeInsets.only(bottom: PlotSpacing.s2),
                            child: Text(paragraph, style: PlotTypography.body(c.textSecondary)),
                          ),
                        const SizedBox(height: PlotSpacing.s2),
                      ],
                    ],
                  ),
          ),
          const SizedBox(height: PlotSpacing.s3),
          Row(
            children: [
              Expanded(
                child: PlotButton(
                  label: 'Print preview',
                  variant: PlotButtonVariant.secondary,
                  onPressed: itinerary.days.isEmpty ? null : () => _showPrintPreview(itinerary),
                ),
              ),
              const SizedBox(width: PlotSpacing.s2),
              Expanded(
                child: PlotButton(
                  label: _exporting ? 'Exporting…' : 'Export itinerary (MD)',
                  onPressed:
                      (_exporting || itinerary.days.isEmpty) ? null : () => _export(itinerary),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _export(Itinerary itinerary) async {
    setState(() => _exporting = true);
    try {
      final content = itineraryToMarkdown(itinerary);
      final safeName = itinerary.title.replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '').trim();
      final location = await getSaveLocation(
        suggestedName: '${safeName.isEmpty ? 'itinerary' : safeName}.md',
      );
      if (location == null) return; // Author cancelled — not a failure.
      await File(location.path).writeAsString(content);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Exported ${location.path}')));
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// Issue #326 — the shared previewer (`presentation/widgets/print_preview.dart`)
  /// rather than a Markdown-echoing dialog of its own: [itinerary]'s own
  /// heading/paragraphs render as formatted prose, on a real paginated page
  /// with attribution and a print action, blocked outright (FR140/Flow 9) if
  /// any of its days carry stale derived work.
  Future<void> _showPrintPreview(Itinerary itinerary) async {
    final dayIds = itinerary.days.map((e) => e.day.id).toSet();
    final staleItems =
        tripStaleItems(widget.trip).where((i) => dayIds.contains(i.dayId)).toList();
    final attribution = await fetchPrintAttribution(ref.read(routingClientProvider));
    if (!mounted) return;
    await showPrintPreview(
      context,
      document: ItineraryPrintDocument(
        title: itinerary.title,
        sections: [
          for (final entry in itinerary.days)
            ProseSection(heading: entry.heading, paragraphs: entry.paragraphs),
        ],
      ),
      staleItems: staleItems,
      attribution: attribution,
    );
  }
}

class _CueEntry {
  _CueEntry({
    required this.distanceAlongM,
    required this.label,
    required this.glyph,
    this.tag,
  });
  final double distanceAlongM;
  final String label;
  final String glyph;
  final String? tag;
}

const _turnGlyph = {
  'left': 'L',
  'right': 'R',
  'slight_left': 'BL',
  'slight_right': 'BR',
  'sharp_left': 'SL',
  'sharp_right': 'SR',
  'uturn': 'U',
};

/// FR12 / B3 — a mode change, as a Character reads it in the sheet.
///
/// This is where B3's "appears on Character timeline at the mode change"
/// actually lands today. A `Transition` belongs to the day rather than to
/// either passage (`domain/transition.dart`), so concatenating per-passage cue
/// sheets — which is what this preview and all three export writers do — went
/// straight over every junction between them: a Character reading the sheet
/// was never told to get off the bike. `dayTimeline` is the ordered reading
/// that puts them back, at the distance the preceding passage ends.
_CueEntry _modeChangeEntry(ModeChangeEntry change, {required double distanceAlongM}) {
  final from = change.fromMode;
  final to = change.toMode;
  final title = change.transition.node?.title;
  final lead = change.isModeChange && from != null && to != null
      ? '${travelModeLabel(from)} → ${travelModeLabel(to)}'
      : 'Transition';
  final label = [
    title == null ? lead : '$lead: $title',
    if (change.instructions != null) change.instructions!.split('\n').first,
  ].join(' — ');
  return _CueEntry(
    // Passed in rather than read off the entry: this preview and its
    // authored-content fallback measure in different frames (day-cumulative
    // vs. per-passage), and a mode change has to land in whichever frame the
    // rows around it are using.
    distanceAlongM: distanceAlongM,
    label: label,
    glyph: '⇄',
    // The gap is safety-adjacent information at exactly the moment a Character
    // is looking for the next leg, so it rides along rather than living only
    // in the Author's timeline.
    tag: change.gapWarning
        ? 'GAP ${change.gapM == null ? '' : '${change.gapM!.round()} M'}'.trim()
        : null,
  );
}

List<_CueEntry> _entriesFromCueSheets(
  Day day,
  List<CueSheet> sheets,
  Trip trip, {
  bool Function(String anchorId)? hasArrived,
}) {
  final entries = <_CueEntry>[];
  final modeChanges = {
    for (final change in dayModeChanges(day)) change.transition.toSegmentId: change,
  };
  var offset = 0.0;
  for (var i = 0; i < day.segments.length; i++) {
    final segment = day.segments[i];
    final change = modeChanges[segment.id];
    if (change != null) entries.add(_modeChangeEntry(change, distanceAlongM: offset));
    // FR128 / A11 — the dismount/gate/ford edges this passage rolls over. The
    // engine reports them in path order without a distance-along, so they land
    // at the passage's start (this list is built in reading order, not sorted).
    for (final sc in segment.surfacedConstraints) {
      entries.add(
        _CueEntry(
          distanceAlongM: offset,
          label: _surfacedConstraintLabel(sc.flags),
          glyph: '⚑',
          tag: 'ON ROUTE',
        ),
      );
    }
    final sheet = sheets[i];
    for (final cue in sheet.cues) {
      final glyph = switch (cue.kind) {
        'turn' => _turnGlyph[cue.modifier] ?? '•',
        'start' => 'S',
        'finish' => 'F',
        'hazard' => '⚠',
        'portage' => '▲',
        'surface' => '~',
        // FR133 — C5's amenities, woven into `cue.instruction` server-side
        // (`cues.node_cues`); this glyph is the only thing that marks the
        // line as a provision rather than a plain waypoint.
        'provision' => 'P',
        'event' => '◷',
        _ => '●',
      };
      entries.add(
        _CueEntry(
          distanceAlongM: offset + cue.distanceAlongM,
          label: cue.instruction ?? cue.kind,
          glyph: glyph,
          tag: cue.retrace == true ? 'RETRACE' : (cue.kind == 'provision' ? 'PROVISION' : null),
        ),
      );
    }
    offset += segment.metrics?.distanceM ?? 0;
    // Issue #393 — a narrative anchor role attached to this segment
    // (`Role.segmentId`, issue #384) lands right after the cues that
    // segment itself produced; nothing here projects its coordinate onto
    // the route the way `cues.node_cues` does server-side (core, not this
    // client, holds the routing graph), so "end of the segment it's pinned
    // to" is the position, not a distance measured along it.
    entries.addAll(_anchorEntriesForSegment(trip, segment.id,
        distanceAlongM: offset, hasArrived: hasArrived));
  }
  // FR133 — day-scoped nodes (a rest day's POIs, and lodging/campground
  // choices placed at the day level — Story C7, issue #43) have no route
  // position of their own; place them after the day's last derived cue,
  // in their own list order (see `_dayNodeEntries`'s doc comment for why
  // `_entriesFromAuthoredContent` needs the same treatment).
  for (var i = 0; i < day.nodes.length; i++) {
    entries.add(_cueEntryForNode(day.nodes[i], distanceAlongM: offset + i + 1));
  }
  entries.addAll(_anchorEntriesForDayOnly(trip, day,
      startOffset: offset + day.nodes.length + 1, hasArrived: hasArrived));
  return entries;
}

/// Issue #393 (FR108/FR126's "timeline, cue sheet" AC; issue #384's
/// `Role.dayId`/`Role.segmentId`) — the first cue-sheet rendering of a
/// promoted anchor's narrative role. Reveal-resolved here rather than
/// server-side: a `CueSheet` is a *derived* document with no reveal concept
/// of its own (`core/plotlines_core/trips/cues.py` only ever sees `Node`s,
/// which are never reveal-gated), and baking a role's title into it directly
/// would leak withheld content into every consumer of that sheet — export,
/// print, a Character who has not arrived — bypassing the one boundary P11
/// requires (`RevealResolver`). Scoped to `RoleKind.narrative` only, matching
/// `buildPlotPoints`'s own scope (`data/character_journey.dart`) — a
/// provision/station role's content already has its own surfaces
/// (C5 amenities on `Node`, O4's station dashboard).
List<_CueEntry> _anchorEntriesForSegment(
  Trip trip,
  String segmentId, {
  required double distanceAlongM,
  required bool Function(String anchorId)? hasArrived,
}) {
  final entries = <_CueEntry>[];
  for (final anchor in trip.anchors) {
    for (final role in anchor.roles) {
      if (role.kind != RoleKind.narrative || role.segmentId != segmentId) continue;
      entries.add(_cueEntryForAnchorRole(anchor, role,
          distanceAlongM: distanceAlongM, hasArrived: hasArrived));
    }
  }
  return entries;
}

/// The day-only half of [_anchorEntriesForSegment]'s scope: a role that
/// names [day] but no segment within it has no route position at all — the
/// same shortfall [_dayNodeEntries] documents for `Day.nodes` — so these are
/// placed after everything else, in encounter order.
List<_CueEntry> _anchorEntriesForDayOnly(
  Trip trip,
  Day day, {
  required double startOffset,
  required bool Function(String anchorId)? hasArrived,
}) {
  final entries = <_CueEntry>[];
  var index = 0;
  for (final anchor in trip.anchors) {
    for (final role in anchor.roles) {
      if (role.kind != RoleKind.narrative || role.dayId != day.id || role.segmentId != null) {
        continue;
      }
      entries.add(_cueEntryForAnchorRole(anchor, role,
          distanceAlongM: startOffset + index, hasArrived: hasArrived));
      index++;
    }
  }
  return entries;
}

/// A day with no segments and no `Day.nodes` used to render an empty
/// section, so `DayCueSection.build` short-circuited to nothing rather than
/// mount one — a rest day composed *entirely* of area/point anchors (FR108's
/// own "rest days can be composed primarily of area anchors") would now
/// silently drop its only content without this check (issue #393).
bool _dayHasAttachedNarrativeAnchors(Trip trip, String dayId) => trip.anchors.any(
      (anchor) => anchor.roles.any((role) => role.kind == RoleKind.narrative && role.dayId == dayId),
    );

/// One [_CueEntry] for a narrative anchor role, resolved through
/// [RevealResolver] — the only sanctioned reader of `Role.title`/`.note`
/// (gate 1, `tools/ci/reveal_gate_lint.sh`). A withheld role reads "Held for
/// arrival," matching `character_read_screen.dart`'s `_PlotPointRow`; the
/// arc stage and the hazard flag are role *metadata* (never gated, per that
/// same gate's own carve-out) and always show via [_CueEntry.tag].
_CueEntry _cueEntryForAnchorRole(
  Anchor anchor,
  Role role, {
  required double distanceAlongM,
  required bool Function(String anchorId)? hasArrived,
}) {
  const resolver = RevealResolver();
  final revealed = resolver.resolve(role,
      hasArrived: hasArrived?.call(anchor.id) ?? false, anchorCoord: anchor.coord);
  final label =
      revealed.visible ? (revealed.title ?? anchor.title ?? 'Plot point') : 'Held for arrival';
  return _CueEntry(
    distanceAlongM: distanceAlongM,
    label: label,
    glyph: role.hazard ? '⚠' : '★',
    tag: role.hazard ? 'HAZARD' : role.arc?.wireValue.toUpperCase(),
  );
}

/// FR128 / A11 — the raw OSM-shaped `key=value` flags as a Character reads
/// them in the sheet: `bicycle=dismount` → `bicycle dismount`. The value is
/// shown as sent, not mapped through a lookup that could silently drop one.
String _surfacedConstraintLabel(List<String> flags) =>
    flags.map((f) => f.replaceFirst('=', ' ')).join(', ');

/// The pre-F1 proxy: authored stops only, no derived turns. Used when the
/// real cue derivation call fails.
List<_CueEntry> _entriesFromAuthoredContent(
  Day day,
  Trip trip, {
  bool Function(String anchorId)? hasArrived,
}) {
  final entries = <_CueEntry>[];
  // Placed at the preceding passage's own finish distance, which is the frame
  // this fallback measures in (each passage restarts at zero here).
  for (final change in dayModeChanges(day)) {
    final before = day.segments
        .where((s) => s.id == change.transition.fromSegmentId)
        .firstOrNull;
    entries.add(_modeChangeEntry(change,
        distanceAlongM: before?.metrics?.distanceM ?? 0));
  }
  for (final segment in day.segments) {
    if (segment.start != null) {
      entries.add(_CueEntry(distanceAlongM: 0, label: 'Start', glyph: 'S'));
    }
    for (final node in segment.nodes) {
      // FR133 — the same narrative-register weaving `cues.node_cues` does
      // server-side, kept here too since this fallback runs whenever the
      // sidecar/region graph is unavailable (`_load`'s other branch).
      entries.add(_cueEntryForNode(node, distanceAlongM: node.distanceAlongM ?? 0));
    }
    for (final hazard in segment.hazards) {
      entries.add(
        _CueEntry(
          distanceAlongM: hazard.distanceAlongM ?? 0,
          label: hazard.title ?? 'Hazard',
          glyph: '⚠',
          tag: hazard.severity.toUpperCase(),
        ),
      );
    }
    for (final portage in segment.portages) {
      entries.add(
        _CueEntry(
          distanceAlongM: portage.distanceM ?? 0,
          label: 'Portage',
          glyph: '▲',
          tag: portage.mandatory == true ? 'MANDATORY' : null,
        ),
      );
    }
    for (final sc in segment.surfacedConstraints) {
      entries.add(
        _CueEntry(
          distanceAlongM: 0,
          label: _surfacedConstraintLabel(sc.flags),
          glyph: '⚑',
          tag: 'ON ROUTE',
        ),
      );
    }
    if (segment.metrics?.distanceM != null) {
      entries.add(
        _CueEntry(
          distanceAlongM: segment.metrics!.distanceM!,
          label: 'Finish',
          glyph: 'F',
        ),
      );
    }
    // Issue #393 — same segment attachment as `_entriesFromCueSheets`, at
    // this fallback's own "Finish" distance since it has no route to
    // project a finer position onto either.
    entries.addAll(_anchorEntriesForSegment(trip, segment.id,
        distanceAlongM: segment.metrics?.distanceM ?? 0, hasArrived: hasArrived));
  }
  entries.addAll(_dayNodeEntries(day, after: entries));
  entries.addAll(_anchorEntriesForDayOnly(trip, day,
      startOffset: entries.isEmpty
          ? 0
          : entries.map((e) => e.distanceAlongM).reduce((a, b) => a > b ? a : b),
      hasArrived: hasArrived));
  entries.sort((a, b) => a.distanceAlongM.compareTo(b.distanceAlongM));
  return entries;
}

/// FR133 (the Frodo principle) — "transportation, places, hazards and
/// rest/lodging detail are woven into a day's account together"
/// (`itinerary.dart`'s own citation of the same requirement). `Day.nodes`
/// carries exactly that: a rest day's POIs, and — since Story C7 (issue
/// #43) — lodging/campground choices placed on a route day at the day
/// level rather than tied to one segment's own position. Neither
/// [_entriesFromAuthoredContent] nor [_entriesFromCueSheets] read it before
/// this, despite this file's own header doc comment already claiming "the
/// cue-sheet preview below... reads the same day-scoped nodes" —
/// `day.nodes` reached the itinerary (`itinerary.dart`) and the Logistics
/// tab, but never here.
///
/// A day-scoped node has no route position to sort by (that is the whole
/// reason it lives on the day rather than a segment), so these are placed
/// after every entry already built from the day's segments — [after] — in
/// their own list order, using each entry's own index past that point to
/// keep that order stable through the final sort.
List<_CueEntry> _dayNodeEntries(Day day, {required List<_CueEntry> after}) {
  if (day.nodes.isEmpty) return const [];
  final dayEndM =
      after.isEmpty ? 0.0 : after.map((e) => e.distanceAlongM).reduce((a, b) => a > b ? a : b);
  return [
    for (var i = 0; i < day.nodes.length; i++)
      _cueEntryForNode(day.nodes[i], distanceAlongM: dayEndM + i + 1),
  ];
}

/// One [_CueEntry] for an authored [node] — the same amenity-weaving and
/// `poiType` tagging [_entriesFromAuthoredContent]'s segment-node loop
/// applies, factored out so [_dayNodeEntries] and that loop can never drift
/// apart on how a node becomes a line.
_CueEntry _cueEntryForNode(Node node, {required double distanceAlongM}) {
  final label = node.amenities.isEmpty
      ? (node.title ?? node.kind.wireValue)
      : '${node.title ?? node.kind.wireValue} — ${node.amenities.join(', ')}';
  return _CueEntry(
    distanceAlongM: distanceAlongM,
    label: label,
    glyph: node.amenities.isNotEmpty
        ? 'P'
        : node.kind == NodeKind.regroup
            ? '◆'
            : node.kind == NodeKind.event
                ? '◷'
                : '●',
    tag: node.amenities.isNotEmpty ? 'PROVISION' : node.poiType?.toUpperCase(),
  );
}

/// Public (H13, issue #87) — `character_read_screen.dart` reuses this
/// unchanged rather than re-deriving cues a second time; the Character
/// reading surface needs the exact same per-day sheet the Export tab already
/// shows the Author, not a parallel implementation that could drift from it.
class DayCueSection extends ConsumerStatefulWidget {
  const DayCueSection({super.key, required this.day, required this.trip, this.hasArrived});
  final Day day;
  final Trip trip;

  /// Issue #393 — how a narrative anchor role attached to this day resolves
  /// through `RevealResolver`. `null` (the default; `character_read_screen.dart`'s
  /// use) resolves every role as not-yet-arrived, the same placeholder
  /// policy `data/character_journey.dart`'s `buildPlotPoints` applies until a
  /// real arrival signal exists (issue #101). The Export tab passes
  /// `(_) => true` — `RevealResolver`'s documented "Author preview-as-self."
  final bool Function(String anchorId)? hasArrived;

  @override
  ConsumerState<DayCueSection> createState() => DayCueSectionState();
}

class DayCueSectionState extends ConsumerState<DayCueSection> {
  late Future<List<_CueEntry>> _future = _load();

  Future<List<_CueEntry>> _load() async {
    if (widget.day.segments.every((s) => s.start == null)) {
      return _entriesFromAuthoredContent(widget.day, widget.trip, hasArrived: widget.hasArrived);
    }
    final client = ref.read(routingClientProvider);
    // FR120/D41, issue #154 — cues re-solve against the region-scoped graph;
    // issue #208 — that graph is per travel mode, so a day mixing a ride and
    // a drive to the trailhead ensures one region per distinct `network_type`
    // and each segment's cues come off its own mode's graph.
    final bbox = ref.read(tripBboxProvider);
    if (bbox == null) {
      return _entriesFromAuthoredContent(widget.day, widget.trip, hasArrived: widget.hasArrived);
    }
    final regionByNetworkType = <String, String>{};
    for (final networkType
        in widget.day.segments.map((s) => networkTypeForMode(s.mode)).toSet()) {
      regionByNetworkType[networkType] =
          await client.ensureRegion(bbox.bboxWsen, networkType: networkType);
    }
    final sheets = await Future.wait(
      widget.day.segments.map((s) => client.cuesFor(s,
          region: regionByNetworkType[networkTypeForMode(s.mode)]!)),
    );
    return _entriesFromCueSheets(widget.day, sheets, widget.trip, hasArrived: widget.hasArrived);
  }

  @override
  void didUpdateWidget(covariant DayCueSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.day != widget.day || oldWidget.trip != widget.trip) {
      setState(() => _future = _load());
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final df = ref.watch(displayFormatProvider);
    if (widget.day.segments.isEmpty &&
        widget.day.nodes.isEmpty &&
        !_dayHasAttachedNarrativeAnchors(widget.trip, widget.day.id)) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: PlotSpacing.s5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'DAY ${widget.day.index}${widget.day.title != null ? ' — ${widget.day.title}' : ''}',
            style: PlotTypography.data(
              c.textMuted,
            ).copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: PlotSpacing.s2),
          FutureBuilder<List<_CueEntry>>(
            future: _future,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.all(PlotSpacing.s4),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final entries = snapshot.data ??
                  _entriesFromAuthoredContent(widget.day, widget.trip,
                      hasArrived: widget.hasArrived);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (snapshot.hasError)
                    Padding(
                      padding: const EdgeInsets.only(bottom: PlotSpacing.s2),
                      child: ProviderUnreachableBanner(
                        provider: 'Turn-by-turn cue derivation',
                      ),
                    ),
                  PlotCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: PlotSpacing.s4,
                    ),
                    child: Column(
                      children: [
                        for (var i = 0; i < entries.length; i++)
                          CueSheetRow(
                            mile: df.formatDistance(entries[i].distanceAlongM),
                            turn: entries[i].glyph,
                            instruction: entries[i].label,
                            tag: entries[i].tag,
                            divider: i < entries.length - 1,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: PlotSpacing.s2),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: PlotButton(
                      label: 'Print preview',
                      variant: PlotButtonVariant.ghost,
                      onPressed: entries.isEmpty ? null : () => _showPrintPreview(entries),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  /// FR46 — "viewable in-app and printable," through the shared previewer
  /// (issue #326) rather than a dialog of its own. FR116's "print inherits
  /// reveal policy" is satisfied by construction here — this reads the same
  /// [entries] the on-screen `CueSheetRow` list does, so there is no second,
  /// unguarded path for content to leak through. FR140/Flow 9's "print
  /// blocks with no override" gates on this day's own stale items, not the
  /// whole trip's — a cue sheet only ever covers one day.
  Future<void> _showPrintPreview(List<_CueEntry> entries) async {
    final day = widget.day;
    final df = ref.read(displayFormatProvider);
    final attribution = await fetchPrintAttribution(ref.read(routingClientProvider));
    if (!mounted) return;
    await showPrintPreview(
      context,
      document: CueSheetPrintDocument(
        title: 'Day ${day.index}${day.title != null ? ' — ${day.title}' : ''}',
        lines: [
          for (final e in entries)
            CueLine(
              distance: df.formatDistance(e.distanceAlongM),
              glyph: e.glyph,
              label: e.label,
              tag: e.tag,
            ),
        ],
      ),
      staleItems: dayStaleItems(day),
      attribution: attribution,
    );
  }
}

enum _ExportFormat { gpx, tcx, geojson, fit }

class _ExportPanel extends ConsumerStatefulWidget {
  const _ExportPanel({required this.trip});
  final Trip trip;

  @override
  ConsumerState<_ExportPanel> createState() => _ExportPanelState();
}

class _ExportPanelState extends ConsumerState<_ExportPanel> {
  _ExportFormat _format = _ExportFormat.gpx;
  bool _includeWaypoints = true;
  bool _includeCueSheet = false;
  bool _includeAlternates = false;
  bool _perDay = false;
  bool _exporting = false;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final dayCount = widget.trip.days
        .where((d) => d.segments.isNotEmpty)
        .length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            PlotSpacing.s5,
            PlotSpacing.s5,
            PlotSpacing.s5,
            PlotSpacing.s3,
          ),
          child: Text(
            'EXPORT',
            style: PlotTypography.data(
              c.textMuted,
            ).copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: PlotSpacing.s5),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('FORMAT', style: PlotTypography.data(c.textMuted)),
                const SizedBox(height: PlotSpacing.s2),
                Wrap(
                  spacing: PlotSpacing.s2,
                  children: [
                    for (final f in _ExportFormat.values)
                      ChoiceChip(
                        label: Text(f.name.toUpperCase()),
                        selected: _format == f,
                        onSelected: (_) => setState(() => _format = f),
                      ),
                  ],
                ),
                if (_format == _ExportFormat.fit) ...[
                  const SizedBox(height: PlotSpacing.s2),
                  Text(
                    'FIT course file for Garmin head units. Plot-point notes '
                    'ride in the cue name, trimmed to the device cue-list window.',
                    style: PlotTypography.small(c.textMuted),
                  ),
                ],
                const SizedBox(height: PlotSpacing.s4),
                Text(
                  'CONTENTS',
                  style: PlotTypography.data(
                    c.textMuted,
                  ).copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: PlotSpacing.s2),
                _ToggleRow(
                  label: 'Track + elevation',
                  value: true,
                  onChanged: null,
                ),
                _ToggleRow(
                  label: 'Waypoints & rest stops',
                  value: _includeWaypoints,
                  onChanged: (v) => setState(() => _includeWaypoints = v),
                ),
                _ToggleRow(
                  label: 'Cue sheet (turn points)',
                  value: _includeCueSheet,
                  onChanged: (v) => setState(() => _includeCueSheet = v),
                ),
                _ToggleRow(
                  label: 'Alternates & variants',
                  value: _includeAlternates,
                  onChanged: (v) => setState(() => _includeAlternates = v),
                ),
                const SizedBox(height: PlotSpacing.s4),
                Text(
                  'FILE SPLITTING',
                  style: PlotTypography.data(
                    c.textMuted,
                  ).copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: PlotSpacing.s2),
                Row(
                  children: [
                    Expanded(
                      child: ChoiceChip(
                        label: const Text('SINGLE FILE'),
                        selected: !_perDay,
                        onSelected: (_) => setState(() => _perDay = false),
                      ),
                    ),
                    const SizedBox(width: PlotSpacing.s2),
                    Expanded(
                      child: ChoiceChip(
                        label: const Text('PER DAY'),
                        selected: _perDay,
                        onSelected: (_) => setState(() => _perDay = true),
                      ),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(
                    top: PlotSpacing.s2,
                    bottom: PlotSpacing.s4,
                  ),
                  child: Text(
                    _perDay
                        ? '$dayCount files · one per routed day'
                        : '1 file · every day, one course/track each',
                    style: PlotTypography.small(c.textMuted),
                  ),
                ),
              ],
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: c.border)),
          ),
          padding: const EdgeInsets.all(PlotSpacing.s5),
          child: PlotButton(
            label: _exporting
                ? 'Exporting…'
                : 'Export ${_perDay ? '$dayCount ${_format.name.toUpperCase()} files' : '${_format.name.toUpperCase()} file'}',
            expand: true,
            onPressed: (_exporting || dayCount == 0) ? null : _export,
          ),
        ),
      ],
    );
  }

  Future<void> _export() async {
    // FR140/Q3 — "a stale route stays viewable but is not exportable":
    // the attempt opens the stale list rather than erroring, and export
    // proceeds once it's cleared (by resolving or dropping every item).
    final ready = await ensureNoStaleWork(context, widget.trip);
    if (!mounted || !ready) return;
    setState(() => _exporting = true);
    try {
      Map<String, CueSheet> cueSheets = const {};
      if (_includeCueSheet) {
        cueSheets = await _fetchCueSheets(widget.trip);
      }
      final options = ExportOptions(
        includeWaypoints: _includeWaypoints,
        includeAlternates: _includeAlternates,
        includeCueSheet: _includeCueSheet,
        cueSheetsBySegmentId: cueSheets,
      );
      if (_perDay) {
        await _exportPerDay(options);
      } else {
        await _exportSingle(options);
      }
    } catch (e) {
      if (mounted) await showExportFailedDialog(context, reason: '$e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<Map<String, CueSheet>> _fetchCueSheets(Trip trip) async {
    final client = ref.read(routingClientProvider);
    final result = <String, CueSheet>{};
    // FR120/D41, issue #154 — cues re-solve against the graph, which is
    // region-scoped. A reopened trip that hasn't redrawn its bbox yet
    // (`TripPersistence.open`'s doc comment) has no region to ensure; the
    // same honest-degrade rule below already covers a per-segment cue
    // failure, so this just skips cue derivation entirely rather than
    // failing the whole export.
    final bbox = ref.read(tripBboxProvider);
    if (bbox == null) return result;
    // Issue #208 — one region per distinct travel-mode `network_type` across
    // the trip, so a driving passage's cues come off the `drive` graph rather
    // than the `bike` default (SPIKE-E, #171).
    final regionByNetworkType = <String, String>{};
    for (final networkType in {
      for (final day in trip.days)
        for (final segment in day.segments) networkTypeForMode(segment.mode),
    }) {
      regionByNetworkType[networkType] =
          await client.ensureRegion(bbox.bboxWsen, networkType: networkType);
    }
    for (final day in trip.days) {
      for (final segment in day.segments) {
        if (segment.start == null) continue;
        try {
          result[segment.id] = await client.cuesFor(segment,
              region: regionByNetworkType[networkTypeForMode(segment.mode)]!);
        } catch (_) {
          // Honest degrade (MVP doc §4): a segment whose cues fail to derive
          // just exports without cue points rather than failing the whole export.
        }
      }
    }
    return result;
  }

  /// FIT is the one binary format — it writes bytes, not a string. The three
  /// text writers still go through [_write]; [_exportSingle] / [_exportPerDay]
  /// pick the path off this flag.
  bool get _isBinary => _format == _ExportFormat.fit;

  String _write(Trip trip, ExportOptions options) => switch (_format) {
    _ExportFormat.gpx => tripToGpx(trip, options: options),
    _ExportFormat.tcx => tripToTcx(trip, options: options),
    _ExportFormat.geojson => tripToGeoJson(trip, options: options),
    _ExportFormat.fit => throw StateError('FIT writes bytes — use _writeBytes'),
  };

  List<int> _writeBytes(Trip trip, ExportOptions options) => switch (_format) {
    _ExportFormat.fit => tripToFit(trip, options: options),
    _ => throw StateError('${_format.name} writes a string — use _write'),
  };

  String get _extension => switch (_format) {
    _ExportFormat.gpx => 'gpx',
    _ExportFormat.tcx => 'tcx',
    _ExportFormat.geojson => 'geojson',
    _ExportFormat.fit => 'fit',
  };

  String _safeName(String s) =>
      s.replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '').trim();

  Future<void> _exportSingle(ExportOptions options) async {
    final safeName = _safeName(widget.trip.title);
    final location = await getSaveLocation(
      suggestedName: '${safeName.isEmpty ? 'plotline' : safeName}.$_extension',
    );
    if (location == null) return; // Author cancelled — not a failure.
    if (_isBinary) {
      await File(location.path).writeAsBytes(_writeBytes(widget.trip, options));
    } else {
      await File(location.path).writeAsString(_write(widget.trip, options));
    }
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Exported ${location.path}')));
    }
  }

  Future<void> _exportPerDay(ExportOptions options) async {
    final dirPath = await getDirectoryPath();
    if (dirPath == null) return; // Author cancelled — not a failure.
    final safeName = _safeName(widget.trip.title);
    var count = 0;
    for (final day in widget.trip.days) {
      if (day.segments.isEmpty) continue;
      final dayTrip = widget.trip.copyWith(days: [day]);
      final base = safeName.isEmpty ? 'plotline' : safeName;
      final file = File('$dirPath/${base}_day${day.index}.$_extension');
      if (_isBinary) {
        await file.writeAsBytes(_writeBytes(dayTrip, options));
      } else {
        await file.writeAsString(_write(dayTrip, options));
      }
      count++;
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Exported $count files to $dirPath')),
      );
    }
  }
}

class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });
  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: PlotTypography.body(PlotColors.of(context).textPrimary),
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}
