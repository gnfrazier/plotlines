import 'package:flutter/material.dart';
import '../theme/colors.dart';
import '../theme/tokens.dart';

enum PlotButtonVariant { primary, secondary, ghost, danger }

/// The brand button. Primary is Blaze with a bold ≥16 label so paper text
/// clears WCAG contrast; ghost uses an Ink label (never Blaze text) so small
/// controls stay legible on canvas.
class PlotButton extends StatelessWidget {
  const PlotButton({
    super.key,
    required this.label,
    this.onPressed,
    this.variant = PlotButtonVariant.primary,
    this.icon,
    this.expand = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final PlotButtonVariant variant;
  final IconData? icon;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final child = icon == null
        ? Text(label)
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18),
              const SizedBox(width: PlotSpacing.s2),
              Text(label),
            ],
          );

    Widget button;
    switch (variant) {
      case PlotButtonVariant.primary:
        button = ElevatedButton(onPressed: onPressed, child: child);
        break;
      case PlotButtonVariant.danger:
        button = ElevatedButton(
          onPressed: onPressed,
          style: ElevatedButton.styleFrom(
            backgroundColor: c.danger,
            foregroundColor: Colors.white,
            minimumSize: const Size(0, 48),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            shape: const RoundedRectangleBorder(borderRadius: PlotRadii.controlShape),
            textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          child: child,
        );
        break;
      case PlotButtonVariant.secondary:
        button = OutlinedButton(onPressed: onPressed, child: child);
        break;
      case PlotButtonVariant.ghost:
        button = TextButton(onPressed: onPressed, child: child);
        break;
    }
    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}
