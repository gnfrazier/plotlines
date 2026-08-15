import 'package:flutter/material.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../theme/tokens.dart';

/// One turn on a printable cue sheet. All-mono, high-contrast, reads on paper
/// and in glare: mileage, a bold turn glyph, the instruction, and a surface tag.
class CueSheetRow extends StatelessWidget {
  const CueSheetRow({
    super.key,
    required this.mile,
    required this.turn,
    required this.instruction,
    this.tag,
    this.turnColor,
    this.tagColor,
    this.divider = true,
  });

  /// e.g. "MI 4.2"
  final String mile;

  /// Short turn glyph/letter — "L", "R", "◆", "↑".
  final String turn;
  final String instruction;

  /// Trailing surface/state tag — "GRAVEL", "REST".
  final String? tag;
  final Color? turnColor;
  final Color? tagColor;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: PlotSpacing.s3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 60,
                child: Text(mile, style: PlotTypography.data(c.textMuted)),
              ),
              SizedBox(
                width: 28,
                child: Text(
                  turn,
                  style: PlotTypography.data(turnColor ?? c.primary)
                      .copyWith(fontWeight: FontWeight.w700, letterSpacing: 0),
                ),
              ),
              Expanded(
                child: Text(instruction,
                    style: PlotTypography.data(c.textPrimary)
                        .copyWith(letterSpacing: 0)),
              ),
              if (tag != null)
                Text(
                  tag!,
                  style: PlotTypography.data(tagColor ?? c.success)
                      .copyWith(letterSpacing: 0.04 * 12),
                ),
            ],
          ),
        ),
        if (divider) Divider(height: 1, thickness: 1, color: c.border),
      ],
    );
  }
}
