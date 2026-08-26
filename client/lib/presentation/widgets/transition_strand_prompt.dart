// FR139 / FR12 (Stories Q2, B2, B3) — reordering a day's passages can pull
// apart a junction an Author has written instructions for. `compose_day`
// rejects a transition between non-adjacent passages outright, so it cannot be
// carried along; the Author has to be told what the move will drop, by what it
// says, before it happens.
//
// Same shape as `passage_removal_prompt.dart` and `day_removal_prompt.dart`:
// FR139's one rule rather than a bespoke prompt per object type. It appears
// only when authored content is actually at risk — a bare junction with no
// instructions is rebuilt silently, because there is nothing to lose and a
// confirmation for nothing is friction the Author learns to click through.
library;

import 'package:flutter/material.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../domain/domain.dart';

/// Shows the prompt for the instructed [stranded] transitions a reorder would
/// separate. Returns true if the Author confirmed the move, false/null
/// otherwise (treated as "leave the order alone" by the caller).
Future<bool?> showTransitionStrandPrompt(
  BuildContext context, {
  required List<Transition> stranded,
}) {
  return showDialog<bool>(
    context: context,
    builder: (context) => _TransitionStrandDialog(stranded: stranded),
  );
}

class _TransitionStrandDialog extends StatelessWidget {
  const _TransitionStrandDialog({required this.stranded});
  final List<Transition> stranded;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final one = stranded.length == 1;
    return AlertDialog(
      title: Text(one ? 'Move this passage?' : 'Move this passage?',
          style: PlotTypography.title(c.textPrimary)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              one
                  ? 'This order puts two other passages together, so one '
                      'transition no longer sits between two neighbours. Its '
                      'instructions are removed with it.'
                  : 'This order puts other passages together, so '
                      '${stranded.length} transitions no longer sit between two '
                      'neighbours. Their instructions are removed with them.',
              style: PlotTypography.body(c.textSecondary),
            ),
            const SizedBox(height: PlotSpacing.s3),
            Text('TRANSITION INSTRUCTIONS THAT WOULD BE LOST',
                style: PlotTypography.data(c.textMuted).copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: PlotSpacing.s2),
            for (final t in stranded)
              Padding(
                padding: const EdgeInsets.only(bottom: PlotSpacing.s1),
                child: Text('• ${t.instructions}', style: PlotTypography.data(c.textPrimary)),
              ),
          ],
        ),
      ),
      actions: [
        PlotButton(
          label: 'Leave the order',
          variant: PlotButtonVariant.ghost,
          onPressed: () => Navigator.pop(context, false),
        ),
        PlotButton(
          label: 'Move anyway',
          variant: PlotButtonVariant.danger,
          onPressed: () => Navigator.pop(context, true),
        ),
      ],
    );
  }
}
