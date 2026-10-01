// FR142(c) (Story K12), Flow 10 §04 — an empty view says what to do next:
// the registry's message (what is true), its next action (what to do), and
// the controls that do it, right there. Every empty surface the AC names
// renders through this rather than writing its own line, so the copy lives
// in one enumeration (`domain/empty_state.dart`) and a test can find each
// one by its context.
//
// Distinct in presentation from a result (N4a's "no clusters found", which
// stays with the analysis) and from a failure (M13's shared error surface):
// no warning icon, no error colour, no Try again — nothing is wrong.
library;

import 'package:flutter/material.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../domain/empty_state.dart';

/// One control that carries out an empty state's next action.
class EmptyStateAction {
  const EmptyStateAction(this.label, this.onPressed);
  final String label;
  final VoidCallback onPressed;
}

class EmptyStateNotice extends StatelessWidget {
  const EmptyStateNotice(
    this.emptyContext, {
    super.key,
    this.actions = const [],
    this.compact = false,
    this.detail,
  });

  final EmptyStateContext emptyContext;

  /// The controls that do the next action. The first is the primary one.
  final List<EmptyStateAction> actions;

  /// One line of small text, for a strip or a list row, rather than a
  /// centred block.
  final bool compact;

  /// Optional extra sentence from the surface (a count it knows), placed
  /// after the next action.
  final String? detail;

  /// The key every rendering carries, so a test finds an empty state by what
  /// it means rather than by its copy.
  static ValueKey<String> keyFor(EmptyStateContext context) =>
      ValueKey('empty-state-${context.name}');

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final copy = emptyStateRegistry[emptyContext]!;
    final buttons = [
      for (var i = 0; i < actions.length; i++)
        i == 0
            ? PlotButton(
                label: actions[i].label,
                variant: PlotButtonVariant.secondary,
                onPressed: actions[i].onPressed,
              )
            : TextButton(onPressed: actions[i].onPressed, child: Text(actions[i].label)),
    ];

    if (compact) {
      return Wrap(
        key: keyFor(emptyContext),
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: PlotSpacing.s2,
        runSpacing: PlotSpacing.s1,
        children: [
          Text('${copy.message} ${copy.nextAction}${detail == null ? '' : ' $detail'}',
              style: PlotTypography.small(c.textMuted)),
          for (final a in actions)
            TextButton(onPressed: a.onPressed, child: Text(a.label)),
        ],
      );
    }

    return Padding(
      key: keyFor(emptyContext),
      padding: const EdgeInsets.all(PlotSpacing.s4),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(copy.message,
                style: PlotTypography.title(c.textPrimary), textAlign: TextAlign.center),
            const SizedBox(height: PlotSpacing.s1),
            Text(
              detail == null ? copy.nextAction : '${copy.nextAction} $detail',
              style: PlotTypography.body(c.textSecondary),
              textAlign: TextAlign.center,
            ),
            if (buttons.isNotEmpty) ...[
              const SizedBox(height: PlotSpacing.s3),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: PlotSpacing.s2,
                runSpacing: PlotSpacing.s2,
                children: buttons,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
