// K10 (PRD FR86, FR95; ARCH §11.2, §12.4) — attribution is a build
// requirement, not a polish item: a missing credit here is a build failure.
// Also the natural home for M12's version-mismatch debugging surface, since
// it's where app + sidecar version already have to be shown (ARCH §12.4).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../data/sidecar_manager.dart';
import '../../state/providers.dart';

class AboutScreen extends ConsumerWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    final client = ref.watch(routingClientProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('About Plotlines')),
      body: ListView(
        padding: const EdgeInsets.all(PlotSpacing.s5),
        children: [
          Text('Plotlines', style: PlotTypography.display(c.textPrimary).copyWith(fontSize: 40)),
          const SizedBox(height: PlotSpacing.s2),
          Text('App version $kClientVersion', style: PlotTypography.data(c.textSecondary)),
          const SizedBox(height: PlotSpacing.s1),
          FutureBuilder<Map<String, dynamic>>(
            future: client.health(),
            builder: (context, snapshot) {
              final version = snapshot.data?['version'] as String?;
              return Text(
                version == null ? 'Sidecar version: checking…' : 'Sidecar version $version',
                style: PlotTypography.data(c.textSecondary),
              );
            },
          ),
          const SizedBox(height: PlotSpacing.s6),
          Text('ATTRIBUTION', style: PlotTypography.data(c.textMuted).copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: PlotSpacing.s2),
          const _AttributionCard(
            source: 'Elevation — GEDTM30',
            credit: 'GEDTM30 via OpenTopography, CC BY 4.0',
            detail: 'Global Elevation Digital Terrain Model, 30 m resolution.',
          ),
          const SizedBox(height: PlotSpacing.s3),
          const _AttributionCard(
            source: 'Basemap — Protomaps Basemap',
            credit: '© OpenStreetMap contributors, ODbL',
            detail: 'Vector tiles built from OpenStreetMap data.',
          ),
          const SizedBox(height: PlotSpacing.s6),
          Text(
            'Plotlines runs entirely on your device. No accounts, no telemetry, '
            'no hosted service for the desktop app.',
            style: PlotTypography.small(c.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _AttributionCard extends StatelessWidget {
  const _AttributionCard({required this.source, required this.credit, required this.detail});
  final String source;
  final String credit;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return PlotCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(source, style: PlotTypography.body(c.textPrimary).copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(credit, style: PlotTypography.small(c.textSecondary)),
          const SizedBox(height: 2),
          Text(detail, style: PlotTypography.small(c.textMuted)),
        ],
      ),
    );
  }
}
