import 'package:flutter/material.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../theme/tokens.dart';

/// A list row with a hairline divider, a leading slot (often a NodeMarker),
/// mono trailing metadata, and optional tap. Density suits both touch and
/// pointer.
class PlotListTile extends StatelessWidget {
  const PlotListTile({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.trailingMono,
    this.onTap,
    this.divider = true,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final String? trailingMono;
  final VoidCallback? onTap;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    Widget? trail = trailing;
    trail ??= trailingMono == null
        ? null
        : Text(trailingMono!, style: PlotTypography.data(c.textMuted));

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: PlotSpacing.s1, vertical: PlotSpacing.s3),
            child: Row(
              children: [
                if (leading != null) ...[
                  leading!,
                  const SizedBox(width: PlotSpacing.s3),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: PlotTypography.body(c.textPrimary).copyWith(
                              fontWeight: FontWeight.w600, height: 1.2)),
                      if (subtitle != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(subtitle!,
                              style: PlotTypography.small(c.textSecondary)),
                        ),
                    ],
                  ),
                ),
                if (trail != null) ...[
                  const SizedBox(width: PlotSpacing.s3),
                  trail,
                ],
              ],
            ),
          ),
        ),
        if (divider) Divider(height: 1, thickness: 1, color: c.border),
      ],
    );
  }
}
