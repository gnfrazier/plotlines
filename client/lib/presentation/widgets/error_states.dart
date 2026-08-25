// M13's remaining error/empty-state rows (MVP doc §4) that aren't sidecar
// lifecycle (see sidecar_gate.dart for those). One shared surface per row so
// no screen invents its own dialog:
//   "No route possible"            -> ConflictBanner
//   "No data for area"             -> NoDataBanner
//   "External provider unreachable"-> ProviderUnreachableBanner
//   "Capability warming"           -> CapabilityWarmingNotice
//   "Export failed"                -> showExportFailedDialog
//
// The rule tying all four together (§4): a failure in an optional
// enrichment never destroys the primary work. None of these widgets ever
// clear or block the Author's already-drawn route — they sit alongside it.
library;

import 'package:flutter/material.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../data/sidecar_manager.dart' show CapabilityStatus;

/// FR9 / A6 — named conflict + nearest relaxations, each stating its
/// trade-off, applyable in one action. Never a raw "no route found".
class ConflictBanner extends StatelessWidget {
  const ConflictBanner({
    super.key,
    required this.explanation,
    this.relaxations = const [],
    this.onApplyRelaxation,
    this.viaImplicated = false,
    this.onDropVia,
  });

  final String explanation;
  final List<RelaxationOffer> relaxations;
  final void Function(RelaxationOffer)? onApplyRelaxation;
  final bool viaImplicated;
  final VoidCallback? onDropVia;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return PlotCard(
      padding: const EdgeInsets.all(PlotSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.route_outlined, size: 18, color: c.danger),
              const SizedBox(width: PlotSpacing.s2),
              Expanded(
                child: Text('No route satisfies every band',
                    style: PlotTypography.title(c.textPrimary).copyWith(fontSize: 15)),
              ),
            ],
          ),
          const SizedBox(height: PlotSpacing.s2),
          Text(explanation, style: PlotTypography.body(c.textSecondary)),
          if (viaImplicated && onDropVia != null) ...[
            const SizedBox(height: PlotSpacing.s3),
            PlotButton(
              label: 'Drop via-node(s) and route',
              variant: PlotButtonVariant.secondary,
              onPressed: onDropVia,
            ),
          ],
          if (relaxations.isNotEmpty) ...[
            const SizedBox(height: PlotSpacing.s3),
            Text('NEAREST RELAXATIONS',
                style: PlotTypography.data(c.textMuted).copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: PlotSpacing.s2),
            for (final r in relaxations)
              Padding(
                padding: const EdgeInsets.only(bottom: PlotSpacing.s2),
                child: PlotCard(
                  sunk: true,
                  padding: const EdgeInsets.all(PlotSpacing.s3),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${r.from}  →  ${r.to}',
                          style: PlotTypography.body(c.textPrimary)
                              .copyWith(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Text(r.tradeOff, style: PlotTypography.small(c.textSecondary)),
                      const SizedBox(height: PlotSpacing.s2),
                      Align(
                        alignment: Alignment.centerRight,
                        child: PlotButton(
                          label: 'Apply',
                          variant: PlotButtonVariant.ghost,
                          onPressed: onApplyRelaxation == null ? null : () => onApplyRelaxation!(r),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// Transport-agnostic view of a relaxation offer, so this widget doesn't
/// depend on which domain type (RoutingClient's `Relaxation` /
/// `data/routing_client.dart`) produced it.
class RelaxationOffer {
  const RelaxationOffer({
    required this.from,
    required this.to,
    required this.tradeOff,
    this.metric,
  });
  final String from;
  final String to;
  final String tradeOff;
  final String? metric;
}

/// Region has no/thin OSM coverage. Distinct from a band conflict — this
/// means there is no graph to route on at all, not that the bands disagree.
class NoDataBanner extends StatelessWidget {
  const NoDataBanner({super.key, this.onChooseAnotherArea});
  final VoidCallback? onChooseAnotherArea;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return PlotCard(
      padding: const EdgeInsets.all(PlotSpacing.s4),
      child: Row(
        children: [
          Icon(Icons.map_outlined, size: 20, color: c.textMuted),
          const SizedBox(width: PlotSpacing.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('This area doesn\'t have routable data',
                    style: PlotTypography.body(c.textPrimary)
                        .copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text('Try a starting point closer to a downloaded region.',
                    style: PlotTypography.small(c.textSecondary)),
              ],
            ),
          ),
          if (onChooseAnotherArea != null)
            PlotButton(
              label: 'Choose area',
              variant: PlotButtonVariant.ghost,
              onPressed: onChooseAnotherArea,
            ),
        ],
      ),
    );
  }
}

/// Elevation/weather API down or rate-limited. The route itself already
/// generated (elevation void rule) — this only ever narrates the enrichment
/// gap, never blocks.
class ProviderUnreachableBanner extends StatelessWidget {
  const ProviderUnreachableBanner({super.key, required this.provider, this.lastCachedAge});
  final String provider;
  final String? lastCachedAge;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final detail = lastCachedAge == null
        ? '$provider is unavailable right now.'
        : '$provider is unavailable — showing data from $lastCachedAge ago.';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: PlotSpacing.s3, vertical: PlotSpacing.s2),
      decoration: BoxDecoration(
        color: c.surfaceSunk,
        borderRadius: const BorderRadius.all(PlotRadii.md),
        border: Border.all(color: c.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off, size: 15, color: c.textMuted),
          const SizedBox(width: PlotSpacing.s2),
          Flexible(child: Text(detail, style: PlotTypography.small(c.textSecondary))),
        ],
      ),
    );
  }
}

/// "Capability warming" (M13, FR121) — the reason a control is disabled
/// while its capability (usually routing, waiting on elevation) is still
/// loading. Never a bare spinner or a silent no-op on click: names what's
/// loading and, once the sidecar has an estimate, how long. A [status] that
/// has settled failed (no `eta_s`, a `failed:` reason) reads as an honest
/// failure rather than a wait.
class CapabilityWarmingNotice extends StatelessWidget {
  const CapabilityWarmingNotice({super.key, required this.capabilityLabel, required this.status});

  final String capabilityLabel;
  final CapabilityStatus status;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final failed = status.failed;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(failed ? Icons.error_outline : Icons.hourglass_top,
            size: 15, color: failed ? c.danger : c.textMuted),
        const SizedBox(width: PlotSpacing.s2),
        Flexible(
          child: Text(status.describe(capabilityLabel), style: PlotTypography.small(c.textSecondary)),
        ),
      ],
    );
  }
}

/// F3 — export write failed (bad path, unsupported content combo, disk
/// full). The generated route/trip is never lost because an export failed —
/// this is purely informational with a retry, not a state-destroying error.
Future<void> showExportFailedDialog(BuildContext context, {required String reason}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Export didn\'t finish'),
      content: Text('$reason\n\nYour trip is unchanged and still open.'),
      actions: [
        PlotButton(label: 'OK', onPressed: () => Navigator.pop(ctx)),
      ],
    ),
  );
}
