// M13 (issue #143) — the one shared surface, driven by `DesktopErrorState`.
//
// "Same shape whatever failed: what, why, what still works, what to do"
// (Author Flows, Flow 8 §02). `DesktopErrorSurface` renders that shape for
// any of M13's twelve typed states, choosing its container from the state's
// entry in `desktopErrorTreatments` — full-screen block, banner over the
// still-usable app, inline card, inline notice, or (export only) a dialog.
//
// The bespoke branded widgets in `error_states.dart` (`ConflictBanner` with
// its relaxation cards, `CapabilityWarmingNotice`, `ProviderUnreachableBanner`,
// `NoDataBanner`) remain the richer per-state treatments where a screen needs
// them; this surface is the shared stub every state can be shown through, and
// the single place the enum is turned into a presentation. A failure in an
// optional enrichment is rendered here but never blocks — `blocksApp` is
// wired from the treatment, and the domain layer asserts it is false for
// every optional-enrichment state.
library;

import 'package:flutter/material.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../domain/desktop_error_state.dart';

/// The variable content for one showing of [DesktopErrorSurface]. Everything
/// here is text the app already holds or a callback — no sentence is
/// composed at the call site (FR145): [why] is a resolved reason phrase from
/// the bounded table, [whatStillWorks] are resolved lines.
class DesktopErrorContent {
  const DesktopErrorContent({
    required this.headline,
    required this.why,
    this.whatStillWorks = const [],
    this.onRetry,
    this.retryLabel = 'Retry',
    this.actions = const [],
  });

  /// The "what" — a short label for the state (e.g. "The routing engine
  /// won't start", "Layer extraction failed").
  final String headline;

  /// The "why" — one already-resolved line from `reason_phrase.dart`'s
  /// bounded table.
  final String why;

  /// The "what still works" — zero or more already-resolved lines. Empty is
  /// fine for the pre-sidecar states, where nothing is up yet.
  final List<String> whatStillWorks;

  /// The "what to do" — a direct retry. Rendered only when the state's
  /// treatment is [DesktopErrorTreatment.retryable]; ignored otherwise.
  final VoidCallback? onRetry;
  final String retryLabel;

  /// Any further affordances (relaxation offers, "Choose another area",
  /// "Remove this layer"). Rendered after the retry.
  final List<Widget> actions;
}

/// Renders [state] in the container its treatment specifies. For
/// [ErrorSurfacePresentation.bannerOverApp] this is the banner only — the
/// caller keeps rendering the app beneath it (the trip stays on screen).
/// For [ErrorSurfacePresentation.dialog] use [showAsDialog] instead of
/// placing this in the tree. For [ErrorSurfacePresentation.elsewhere]
/// (no-clusters-found) this renders nothing: that state belongs in the
/// proposals view.
class DesktopErrorSurface extends StatelessWidget {
  const DesktopErrorSurface({
    super.key,
    required this.state,
    required this.content,
  });

  final DesktopErrorState state;
  final DesktopErrorContent content;

  DesktopErrorTreatment get treatment => desktopErrorTreatments[state]!;

  /// The export-failed treatment: a modal with a retry, over the unchanged
  /// trip.
  static Future<void> showAsDialog(
    BuildContext context, {
    required DesktopErrorContent content,
  }) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(content.headline),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(content.why),
            for (final line in content.whatStillWorks) ...[
              const SizedBox(height: PlotSpacing.s2),
              Text(line),
            ],
          ],
        ),
        actions: [
          if (content.onRetry != null)
            PlotButton(
              label: content.retryLabel,
              variant: PlotButtonVariant.secondary,
              onPressed: () {
                Navigator.pop(ctx);
                content.onRetry!();
              },
            ),
          PlotButton(label: 'OK', onPressed: () => Navigator.pop(ctx)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    switch (treatment.presentation) {
      case ErrorSurfacePresentation.fullScreenBlock:
        return _fullScreen(context);
      case ErrorSurfacePresentation.bannerOverApp:
        return _banner(context);
      case ErrorSurfacePresentation.inlineCard:
        return _card(context);
      case ErrorSurfacePresentation.inlineNotice:
        return _notice(context);
      case ErrorSurfacePresentation.dialog:
        // A dialog is shown imperatively; if placed in the tree, fall back
        // to the card shape rather than an empty box.
        return _card(context);
      case ErrorSurfacePresentation.elsewhere:
        return const SizedBox.shrink();
    }
  }

  Widget _retryAndActions(BuildContext context) {
    final children = <Widget>[
      if (treatment.retryable && content.onRetry != null)
        PlotButton(
          label: content.retryLabel,
          variant: PlotButtonVariant.secondary,
          onPressed: content.onRetry,
        ),
      ...content.actions,
    ];
    if (children.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: PlotSpacing.s3),
      child: Wrap(spacing: PlotSpacing.s2, runSpacing: PlotSpacing.s2, children: children),
    );
  }

  Widget _whatStillWorks(BuildContext context) {
    if (content.whatStillWorks.isEmpty) return const SizedBox.shrink();
    final c = PlotColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: PlotSpacing.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('WHAT STILL WORKS',
              style: PlotTypography.data(c.textMuted).copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: PlotSpacing.s1),
          for (final line in content.whatStillWorks)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.check, size: 14, color: c.textMuted),
                  const SizedBox(width: PlotSpacing.s2),
                  Expanded(child: Text(line, style: PlotTypography.small(c.textSecondary))),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _fullScreen(BuildContext context) {
    final c = PlotColors.of(context);
    final blocking = treatment.blocksApp;
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(PlotSpacing.s6),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(treatment.retryable ? Icons.error_outline : Icons.hourglass_top,
                    size: 40, color: treatment.retryable ? c.danger : c.textMuted),
                const SizedBox(height: PlotSpacing.s4),
                Text(content.headline,
                    textAlign: TextAlign.center, style: PlotTypography.title(c.textPrimary)),
                const SizedBox(height: PlotSpacing.s2),
                Text(content.why,
                    textAlign: TextAlign.center, style: PlotTypography.body(c.textSecondary)),
                if (!blocking) _whatStillWorks(context),
                _retryAndActions(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _banner(BuildContext context) {
    final c = PlotColors.of(context);
    return Container(
      width: double.infinity,
      color: c.warning.withValues(alpha: 0.16),
      padding: const EdgeInsets.symmetric(
          horizontal: PlotSpacing.s4, vertical: PlotSpacing.s2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 18, color: c.warning),
          const SizedBox(width: PlotSpacing.s2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(content.headline,
                    style: PlotTypography.small(c.textPrimary)
                        .copyWith(fontWeight: FontWeight.w700)),
                Text(content.why, style: PlotTypography.small(c.textPrimary)),
                for (final line in content.whatStillWorks)
                  Text(line, style: PlotTypography.small(c.textSecondary)),
              ],
            ),
          ),
          if (treatment.retryable && content.onRetry != null)
            PlotButton(
              label: content.retryLabel,
              variant: PlotButtonVariant.ghost,
              onPressed: content.onRetry,
            ),
        ],
      ),
    );
  }

  Widget _card(BuildContext context) {
    final c = PlotColors.of(context);
    return PlotCard(
      padding: const EdgeInsets.all(PlotSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline, size: 18, color: c.danger),
              const SizedBox(width: PlotSpacing.s2),
              Expanded(
                child: Text(content.headline,
                    style: PlotTypography.title(c.textPrimary).copyWith(fontSize: 15)),
              ),
            ],
          ),
          const SizedBox(height: PlotSpacing.s2),
          Text(content.why, style: PlotTypography.body(c.textSecondary)),
          _whatStillWorks(context),
          _retryAndActions(context),
        ],
      ),
    );
  }

  Widget _notice(BuildContext context) {
    final c = PlotColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: PlotSpacing.s3, vertical: PlotSpacing.s2),
      decoration: BoxDecoration(
        color: c.surfaceSunk,
        borderRadius: const BorderRadius.all(PlotRadii.md),
        border: Border.all(color: c.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.info_outline, size: 15, color: c.textMuted),
          const SizedBox(width: PlotSpacing.s2),
          Flexible(child: Text(content.why, style: PlotTypography.small(c.textSecondary))),
        ],
      ),
    );
  }
}
