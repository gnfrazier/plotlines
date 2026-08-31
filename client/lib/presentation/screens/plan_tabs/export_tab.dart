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
// `domain/itinerary.dart` for why "places" reads from `Node`s rather than
// the promoted `Anchor`/`Role` layer, and why reveal policy isn't applied
// here (neither is it on the cue-sheet preview below, which reads the same
// day-scoped nodes).
library;

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../../data/export/export_options.dart';
import '../../../data/export/geojson_writer.dart';
import '../../../data/export/gpx_writer.dart';
import '../../../data/export/itinerary_writer.dart';
import '../../../data/export/tcx_writer.dart';
import '../../../domain/domain.dart';
import '../../../state/providers.dart';
import '../../../state/trip_bbox_provider.dart';
import '../../widgets/error_states.dart';
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
              for (final day in trip.days) _DayCueSection(day: day),
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
class _ItinerarySection extends StatefulWidget {
  const _ItinerarySection({required this.trip});
  final Trip trip;

  @override
  State<_ItinerarySection> createState() => _ItinerarySectionState();
}

class _ItinerarySectionState extends State<_ItinerarySection> {
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

  /// "Printable" (FR48) with no PDF/printing dependency in this app yet
  /// (`pubspec.yaml` carries none): a chrome-free, letter-proportioned view
  /// of the exact document `_export` writes, which the desktop OS's own
  /// print command can act on. A real "Print" button that talks to a
  /// printer driver needs a printing package added as its own decision —
  /// flagging that rather than reaching for a new dependency here.
  Future<void> _showPrintPreview(Itinerary itinerary) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        child: SizedBox(
          width: 640,
          height: 800,
          child: Padding(
            padding: const EdgeInsets.all(PlotSpacing.s5),
            child: SingleChildScrollView(
              child: SelectableText(itineraryToMarkdown(itinerary)),
            ),
          ),
        ),
      ),
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

List<_CueEntry> _entriesFromCueSheets(Day day, List<CueSheet> sheets) {
  final entries = <_CueEntry>[];
  final modeChanges = {
    for (final change in dayModeChanges(day)) change.transition.toSegmentId: change,
  };
  var offset = 0.0;
  for (var i = 0; i < day.segments.length; i++) {
    final change = modeChanges[day.segments[i].id];
    if (change != null) entries.add(_modeChangeEntry(change, distanceAlongM: offset));
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
    offset += day.segments[i].metrics?.distanceM ?? 0;
  }
  return entries;
}

/// The pre-F1 proxy: authored stops only, no derived turns. Used when the
/// real cue derivation call fails.
List<_CueEntry> _entriesFromAuthoredContent(Day day) {
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
      final label = node.amenities.isEmpty
          ? (node.title ?? node.kind.wireValue)
          : '${node.title ?? node.kind.wireValue} — ${node.amenities.join(', ')}';
      entries.add(
        _CueEntry(
          distanceAlongM: node.distanceAlongM ?? 0,
          label: label,
          glyph: node.amenities.isNotEmpty
              ? 'P'
              : node.kind == NodeKind.regroup
                  ? '◆'
                  : node.kind == NodeKind.event
                      ? '◷'
                      : '●',
          tag: node.amenities.isNotEmpty ? 'PROVISION' : node.poiType?.toUpperCase(),
        ),
      );
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
    if (segment.metrics?.distanceM != null) {
      entries.add(
        _CueEntry(
          distanceAlongM: segment.metrics!.distanceM!,
          label: 'Finish',
          glyph: 'F',
        ),
      );
    }
  }
  entries.sort((a, b) => a.distanceAlongM.compareTo(b.distanceAlongM));
  return entries;
}

class _DayCueSection extends ConsumerStatefulWidget {
  const _DayCueSection({required this.day});
  final Day day;

  @override
  ConsumerState<_DayCueSection> createState() => _DayCueSectionState();
}

class _DayCueSectionState extends ConsumerState<_DayCueSection> {
  late Future<List<_CueEntry>> _future = _load();

  Future<List<_CueEntry>> _load() async {
    if (widget.day.segments.every((s) => s.start == null)) {
      return _entriesFromAuthoredContent(widget.day);
    }
    final client = ref.read(routingClientProvider);
    // FR120/D41, issue #154 — cues re-solve against the region-scoped graph;
    // issue #208 — that graph is per travel mode, so a day mixing a ride and
    // a drive to the trailhead ensures one region per distinct `network_type`
    // and each segment's cues come off its own mode's graph.
    final bbox = ref.read(tripBboxProvider);
    if (bbox == null) return _entriesFromAuthoredContent(widget.day);
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
    return _entriesFromCueSheets(widget.day, sheets);
  }

  @override
  void didUpdateWidget(covariant _DayCueSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.day != widget.day) {
      setState(() => _future = _load());
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    if (widget.day.segments.isEmpty && widget.day.nodes.isEmpty) {
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
              final entries =
                  snapshot.data ?? _entriesFromAuthoredContent(widget.day);
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
                            mile:
                                '${(entries[i].distanceAlongM / 1000).toStringAsFixed(1)} km',
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

  /// FR46 — "viewable in-app and printable." Same no-PDF-dependency
  /// reasoning as the itinerary's own print preview
  /// (`_ItinerarySectionState._showPrintPreview`): a chrome-free view of
  /// exactly what's on screen, for the desktop OS's own print command to
  /// act on. FR116's "print inherits reveal policy" is satisfied by
  /// construction here — this reads the same [entries] the on-screen list
  /// does, so there is no second, unguarded path for content to leak
  /// through.
  Future<void> _showPrintPreview(List<_CueEntry> entries) {
    final day = widget.day;
    final lines = [
      'Day ${day.index}${day.title != null ? ' — ${day.title}' : ''}',
      '',
      for (final e in entries)
        '${(e.distanceAlongM / 1000).toStringAsFixed(1)} km  ${e.glyph}  ${e.label}'
            '${e.tag != null ? '  [${e.tag}]' : ''}',
    ];
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        child: SizedBox(
          width: 640,
          height: 800,
          child: Padding(
            padding: const EdgeInsets.all(PlotSpacing.s5),
            child: SingleChildScrollView(child: SelectableText(lines.join('\n'))),
          ),
        ),
      ),
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
                        onSelected: f == _ExportFormat.fit
                            ? null
                            : (_) => setState(() => _format = f),
                      ),
                  ],
                ),
                if (_format == _ExportFormat.fit) ...[
                  const SizedBox(height: PlotSpacing.s2),
                  Text(
                    'FIT waits on SPIKE-16 (unresolved — also decides whether FIT runs '
                    'in the core or on-device via the Garmin FIT SDK).',
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
            onPressed:
                (_exporting || _format == _ExportFormat.fit || dayCount == 0)
                ? null
                : _export,
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

  String _write(Trip trip, ExportOptions options) => switch (_format) {
    _ExportFormat.gpx => tripToGpx(trip, options: options),
    _ExportFormat.tcx => tripToTcx(trip, options: options),
    _ExportFormat.geojson => tripToGeoJson(trip, options: options),
    _ExportFormat.fit => throw StateError('FIT is disabled'),
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
    final content = _write(widget.trip, options);
    final safeName = _safeName(widget.trip.title);
    final location = await getSaveLocation(
      suggestedName: '${safeName.isEmpty ? 'plotline' : safeName}.$_extension',
    );
    if (location == null) return; // Author cancelled — not a failure.
    await File(location.path).writeAsString(content);
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
      final content = _write(dayTrip, options);
      final base = safeName.isEmpty ? 'plotline' : safeName;
      final file = File('$dirPath/${base}_day${day.index}.$_extension');
      await file.writeAsString(content);
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
