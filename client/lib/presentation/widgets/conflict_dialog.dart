// Wireframe screen "02 Constraint Conflict" — A6's named-conflict +
// relaxation flow as its own centered modal over the dimmed Route tab,
// rather than an inline card buried in a bottom sheet. Reuses
// `error_states.dart`'s `RelaxationOffer` type so both this dialog and any
// other future conflict surface agree on what a relaxation is; only the
// container differs from `ConflictBanner`.
library;

import 'package:flutter/material.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import 'error_states.dart';

/// Shows the conflict as a real modal (FR9/A6): named constraints as chips,
/// each relaxation with its trade-off and an APPLY action. Returns nothing —
/// callers act via [onApplyRelaxation]/[onDropVia] and pop themselves.
Future<void> showConflictDialog(
  BuildContext context, {
  required String explanation,
  List<RelaxationOffer> relaxations = const [],
  bool viaImplicated = false,
  VoidCallback? onDropVia,
  required void Function(RelaxationOffer) onApplyRelaxation,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.42),
    builder: (context) => Dialog(
      backgroundColor: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: _ConflictDialogContent(
          explanation: explanation,
          relaxations: relaxations,
          viaImplicated: viaImplicated,
          onDropVia: onDropVia,
          onApplyRelaxation: onApplyRelaxation,
        ),
      ),
    ),
  );
}

class _ConflictDialogContent extends StatelessWidget {
  const _ConflictDialogContent({
    required this.explanation,
    required this.relaxations,
    required this.viaImplicated,
    required this.onDropVia,
    required this.onApplyRelaxation,
  });
  final String explanation;
  final List<RelaxationOffer> relaxations;
  final bool viaImplicated;
  final VoidCallback? onDropVia;
  final void Function(RelaxationOffer) onApplyRelaxation;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return Material(
      color: c.surfaceCard,
      borderRadius: const BorderRadius.all(PlotRadii.lg),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(PlotSpacing.s5, PlotSpacing.s5, PlotSpacing.s5, PlotSpacing.s4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_rounded, color: c.danger, size: 28),
                const SizedBox(width: PlotSpacing.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('No route fits every constraint',
                          style: PlotTypography.h2(c.textPrimary).copyWith(fontSize: 22)),
                      const SizedBox(height: PlotSpacing.s2),
                      Text(explanation, style: PlotTypography.body(c.textSecondary)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: PlotSpacing.s5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (viaImplicated && onDropVia != null) ...[
                    PlotButton(
                      label: 'Drop via-node(s) and route',
                      variant: PlotButtonVariant.secondary,
                      onPressed: () {
                        Navigator.pop(context);
                        onDropVia!();
                      },
                    ),
                    const SizedBox(height: PlotSpacing.s4),
                  ],
                  if (relaxations.isNotEmpty) ...[
                    Text('SUGGESTED RELAXATIONS',
                        style: PlotTypography.data(c.textMuted).copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: PlotSpacing.s3),
                    for (final r in relaxations)
                      Padding(
                        padding: const EdgeInsets.only(bottom: PlotSpacing.s3),
                        child: _RelaxationRow(
                          offer: r,
                          onApply: () {
                            Navigator.pop(context);
                            onApplyRelaxation(r);
                          },
                        ),
                      ),
                  ] else
                    Padding(
                      padding: const EdgeInsets.only(bottom: PlotSpacing.s4),
                      child: Text('No automatic relaxation was found — adjust manually.',
                          style: PlotTypography.body(c.textMuted)),
                    ),
                ],
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: c.surfaceSunk,
              border: Border(top: BorderSide(color: c.border)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: PlotSpacing.s5, vertical: PlotSpacing.s3),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Adjust manually'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Dismiss'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RelaxationRow extends StatelessWidget {
  const _RelaxationRow({required this.offer, required this.onApply});
  final RelaxationOffer offer;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return PlotCard(
      sunk: true,
      padding: const EdgeInsets.all(PlotSpacing.s4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${offer.from}  →  ${offer.to}',
                    style: PlotTypography.body(c.textPrimary).copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(offer.tradeOff, style: PlotTypography.small(c.textSecondary)),
              ],
            ),
          ),
          const SizedBox(width: PlotSpacing.s3),
          PlotButton(label: 'Apply', variant: PlotButtonVariant.secondary, onPressed: onApply),
        ],
      ),
    );
  }
}
