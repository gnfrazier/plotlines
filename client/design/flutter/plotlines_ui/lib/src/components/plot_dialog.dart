import 'package:flutter/material.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../theme/tokens.dart';
import 'plot_button.dart';

/// Brand dialogs & sheets. Paper surface, hairline border, subtle corners.
/// Static helpers wrap the Material routes so callers get brand chrome for free.
class PlotDialog {
  PlotDialog._();

  static Future<bool?> confirm(
    BuildContext context, {
    required String title,
    required String message,
    String confirmLabel = 'Confirm',
    String cancelLabel = 'Cancel',
    bool destructive = false,
  }) {
    final c = PlotColors.of(context);
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title, style: PlotTypography.title(c.textPrimary)),
        content: Text(message, style: PlotTypography.body(c.textSecondary)),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        actions: [
          PlotButton(
            label: cancelLabel,
            variant: PlotButtonVariant.ghost,
            onPressed: () => Navigator.pop(ctx, false),
          ),
          PlotButton(
            label: confirmLabel,
            variant: destructive
                ? PlotButtonVariant.danger
                : PlotButtonVariant.primary,
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
  }

  /// A brand bottom sheet with a grab handle. Good for mode pickers and
  /// per-node actions in the field app.
  static Future<T?> sheet<T>(
    BuildContext context, {
    required WidgetBuilder builder,
  }) {
    final c = PlotColors.of(context);
    return showModalBottomSheet<T>(
      context: context,
      backgroundColor: c.surfaceCard,
      showDragHandle: false,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(
            PlotSpacing.s5, PlotSpacing.s3, PlotSpacing.s5, PlotSpacing.s6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: PlotSpacing.s4),
                decoration: BoxDecoration(
                  color: c.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            builder(ctx),
          ],
        ),
      ),
    );
  }
}
