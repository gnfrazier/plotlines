// Wireframe screen "04 Cue Sheet + Export".
//
// F1's real turn-by-turn cues (SPIKE-21's `derive_cue_sheet`) are live as of
// this session via `POST /segments/cues` — each day's segments are re-solved
// server-side (same pattern as `/segments/envelope`/`/segments/diagnose`:
// nothing about geometry is trusted from the client) and the real cue sheet
// is fetched and stitched together with cumulative distance across
// segments. If that call fails (sidecar unreachable, a segment with no
// start point yet), the day falls back to the authored-stops proxy list —
// an honest degrade (MVP doc §4's "external provider unreachable" family),
// not a silent gap anymore.
//
// `core/plotlines_core/export/` still has no writers and no
// `/trips/{id}/export` endpoint exists. GeoJSON, GPX, and (new this
// session) TCX are all written entirely client-side (see data/export/) —
// none of the three needed core. FIT stays disabled: it is explicitly
// gated on SPIKE-16 (unresolved — also decides whether FIT runs in the
// core or on-device via the Garmin FIT SDK), the one export format this
// session did not fabricate an answer for.
library;

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../data/export/geojson_writer.dart';
import '../../data/export/gpx_writer.dart';
import '../../data/export/tcx_writer.dart';
import '../../domain/domain.dart';
import '../../state/current_trip_provider.dart';
import '../../state/providers.dart';
import '../widgets/error_states.dart';

class CueSheetScreen extends ConsumerWidget {
  const CueSheetScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    final trip = ref.watch(currentTripProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Cue sheet + export')),
      body: Row(
        children: [
          Expanded(
            flex: 2,
            child: ListView(
              padding: const EdgeInsets.all(PlotSpacing.s5),
              children: [
                for (final day in trip.days) _DayCueSection(day: day),
                if (trip.days.every((d) => d.segments.isEmpty))
                  Padding(
                    padding: const EdgeInsets.all(PlotSpacing.s5),
                    child: Text('No routed days yet.', style: PlotTypography.body(c.textMuted)),
                  ),
              ],
            ),
          ),
          VerticalDivider(width: 1, color: c.border),
          SizedBox(
            width: 320,
            child: _ExportPanel(trip: trip),
          ),
        ],
      ),
    );
  }
}

class _CueEntry {
  _CueEntry({required this.distanceAlongM, required this.label, required this.glyph, this.tag});
  final double distanceAlongM;
  final String label;
  final String glyph;
  final String? tag;
}

const _turnGlyph = {
  'left': 'L', 'right': 'R', 'slight_left': 'BL', 'slight_right': 'BR',
  'sharp_left': 'SL', 'sharp_right': 'SR', 'uturn': 'U',
};

List<_CueEntry> _entriesFromCueSheets(Day day, List<CueSheet> sheets) {
  final entries = <_CueEntry>[];
  var offset = 0.0;
  for (var i = 0; i < day.segments.length; i++) {
    final sheet = sheets[i];
    for (final cue in sheet.cues) {
      final glyph = switch (cue.kind) {
        'turn' => _turnGlyph[cue.modifier] ?? '•',
        'start' => 'S',
        'finish' => 'F',
        'hazard' => '⚠',
        'portage' => '▲',
        'surface' => '~',
        _ => '●',
      };
      entries.add(_CueEntry(
        distanceAlongM: offset + cue.distanceAlongM,
        label: cue.instruction ?? cue.kind,
        glyph: glyph,
        tag: cue.retrace == true ? 'RETRACE' : null,
      ));
    }
    offset += day.segments[i].metrics?.distanceM ?? 0;
  }
  return entries;
}

/// The pre-F1 proxy: authored stops only, no derived turns. Used when the
/// real cue derivation call fails.
List<_CueEntry> _entriesFromAuthoredContent(Day day) {
  final entries = <_CueEntry>[];
  for (final segment in day.segments) {
    if (segment.start != null) {
      entries.add(_CueEntry(distanceAlongM: 0, label: 'Start', glyph: 'S'));
    }
    for (final node in segment.nodes) {
      entries.add(_CueEntry(
        distanceAlongM: node.distanceAlongM ?? 0,
        label: node.title ?? node.kind.wireValue,
        glyph: node.kind == NodeKind.regroup ? '◆' : '●',
        tag: node.poiType?.toUpperCase(),
      ));
    }
    for (final hazard in segment.hazards) {
      entries.add(_CueEntry(
        distanceAlongM: hazard.distanceAlongM ?? 0,
        label: hazard.title ?? 'Hazard',
        glyph: '⚠',
        tag: hazard.severity.toUpperCase(),
      ));
    }
    for (final portage in segment.portages) {
      entries.add(_CueEntry(
        distanceAlongM: portage.distanceM ?? 0,
        label: 'Portage',
        glyph: '▲',
        tag: portage.mandatory == true ? 'MANDATORY' : null,
      ));
    }
    if (segment.metrics?.distanceM != null) {
      entries.add(_CueEntry(distanceAlongM: segment.metrics!.distanceM!, label: 'Finish', glyph: 'F'));
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
    final sheets = await Future.wait(widget.day.segments.map(client.cuesFor));
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
    if (widget.day.segments.isEmpty && widget.day.nodes.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: PlotSpacing.s5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('DAY ${widget.day.index}${widget.day.title != null ? ' — ${widget.day.title}' : ''}',
              style: PlotTypography.data(c.textMuted).copyWith(fontWeight: FontWeight.w700)),
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
              final entries = snapshot.data ?? _entriesFromAuthoredContent(widget.day);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (snapshot.hasError)
                    Padding(
                      padding: const EdgeInsets.only(bottom: PlotSpacing.s2),
                      child: ProviderUnreachableBanner(provider: 'Turn-by-turn cue derivation'),
                    ),
                  PlotCard(
                    padding: const EdgeInsets.symmetric(horizontal: PlotSpacing.s4),
                    child: Column(
                      children: [
                        for (var i = 0; i < entries.length; i++)
                          CueSheetRow(
                            mile: '${(entries[i].distanceAlongM / 1000).toStringAsFixed(1)} km',
                            turn: entries[i].glyph,
                            instruction: entries[i].label,
                            tag: entries[i].tag,
                            divider: i < entries.length - 1,
                          ),
                      ],
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
}

class _ExportPanel extends ConsumerWidget {
  const _ExportPanel({required this.trip});
  final Trip trip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    return Padding(
      padding: const EdgeInsets.all(PlotSpacing.s5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('EXPORT', style: PlotTypography.data(c.textMuted).copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: PlotSpacing.s3),
          PlotButton(
            label: 'GeoJSON (.geojson)',
            expand: true,
            onPressed: () => _export(context, tripToGeoJson(trip), 'geojson'),
          ),
          const SizedBox(height: PlotSpacing.s2),
          PlotButton(
            label: 'GPX (.gpx)',
            expand: true,
            variant: PlotButtonVariant.secondary,
            onPressed: () => _export(context, tripToGpx(trip), 'gpx'),
          ),
          const SizedBox(height: PlotSpacing.s2),
          PlotButton(
            label: 'TCX (.tcx)',
            expand: true,
            variant: PlotButtonVariant.secondary,
            onPressed: () => _export(context, tripToTcx(trip), 'tcx'),
          ),
          const SizedBox(height: PlotSpacing.s2),
          PlotButton(label: 'FIT — not available yet', expand: true, variant: PlotButtonVariant.ghost, onPressed: null),
          const SizedBox(height: PlotSpacing.s3),
          Text(
            'FIT waits on SPIKE-16 (unresolved — also decides whether FIT runs '
            'in the core or on-device via the Garmin FIT SDK).',
            style: PlotTypography.small(c.textMuted),
          ),
        ],
      ),
    );
  }

  Future<void> _export(BuildContext context, String content, String extension) async {
    final safeName = trip.title.replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '').trim();
    final location = await getSaveLocation(
      suggestedName: '${safeName.isEmpty ? 'plotline' : safeName}.$extension',
    );
    if (location == null) return; // Author cancelled — not a failure.
    try {
      await File(location.path).writeAsString(content);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Exported ${location.path}')));
      }
    } catch (e) {
      if (context.mounted) {
        await showExportFailedDialog(context, reason: '$e');
      }
    }
  }
}
