// Wireframe screen "04 Cue Sheet + Export".
//
// Two honest gaps, both open questions in the MVP doc rather than silently
// faked here:
//  - F1/FR46's turn-by-turn cues are `core/plotlines_core/trips/cues.py`'s
//    job (SPIKE-21, ARCH D31) but nothing exposes them over the sidecar API
//    yet, so there is no derived turn list to show. What's shown instead is
//    every curated node/hazard/portage ordered by `distance_along_m` — a
//    real, useful stop list, just not SPIKE-21's derived turns.
//  - `core/plotlines_core/export/` has no writers and no
//    `/trips/{id}/export` endpoint exists. GeoJSON and GPX are written
//    entirely client-side here (see data/export/) because both are cheap
//    enough not to need core at all; TCX and FIT stay disabled pending
//    SPIKE-16 (which also decides whether FIT runs in the core or on-device
//    via the Garmin FIT SDK).
library;

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../data/export/geojson_writer.dart';
import '../../data/export/gpx_writer.dart';
import '../../domain/domain.dart';
import '../../state/current_trip_provider.dart';
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

class _DayCueSection extends StatelessWidget {
  const _DayCueSection({required this.day});
  final Day day;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    if (day.segments.isEmpty && day.nodes.isEmpty) return const SizedBox.shrink();

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
        entries.add(_CueEntry(
          distanceAlongM: segment.metrics!.distanceM!,
          label: 'Finish',
          glyph: 'F',
        ));
      }
    }
    entries.sort((a, b) => a.distanceAlongM.compareTo(b.distanceAlongM));

    return Padding(
      padding: const EdgeInsets.only(bottom: PlotSpacing.s5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('DAY ${day.index}${day.title != null ? ' — ${day.title}' : ''}',
              style: PlotTypography.data(c.textMuted).copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: PlotSpacing.s2),
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
            onPressed: () => _export(context, 'geojson', tripToGeoJson(trip), 'geojson'),
          ),
          const SizedBox(height: PlotSpacing.s2),
          PlotButton(
            label: 'GPX (.gpx)',
            expand: true,
            variant: PlotButtonVariant.secondary,
            onPressed: () => _export(context, 'gpx', tripToGpx(trip), 'gpx'),
          ),
          const SizedBox(height: PlotSpacing.s2),
          PlotButton(label: 'TCX — not available yet', expand: true, variant: PlotButtonVariant.ghost, onPressed: null),
          const SizedBox(height: PlotSpacing.s1),
          PlotButton(label: 'FIT — not available yet', expand: true, variant: PlotButtonVariant.ghost, onPressed: null),
          const SizedBox(height: PlotSpacing.s3),
          Text(
            'TCX/FIT wait on SPIKE-16 (also decides whether FIT runs in the '
            'core or on-device via the Garmin FIT SDK).',
            style: PlotTypography.small(c.textMuted),
          ),
        ],
      ),
    );
  }

  Future<void> _export(BuildContext context, String kind, String content, String extension) async {
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
