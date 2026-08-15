import 'package:flutter/material.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../theme/tokens.dart';
import '../components/plot_badge.dart';

/// The signature object in Plotlines: a saved trip. A route thumbnail band with
/// an offline-ready status badge, the trip title, and mono stats
/// (distance · elevation · modes).
class TripCard extends StatelessWidget {
  const TripCard({
    super.key,
    required this.title,
    required this.stats,
    this.thumbnail,
    this.offlineReady = false,
    this.modeTag,
    this.onTap,
  });

  final String title;

  /// Mono stat chips, e.g. ["178 MI", "↑ 9,400 FT"].
  final List<String> stats;

  /// Optional custom thumbnail; defaults to a hatched placeholder band.
  final Widget? thumbnail;
  final bool offlineReady;

  /// Trailing mode tag on the stat line, e.g. "GRAVEL+PADDLE".
  final String? modeTag;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: const BorderRadius.all(PlotRadii.lg),
        child: Container(
          decoration: BoxDecoration(
            color: c.surfaceCard,
            borderRadius: const BorderRadius.all(PlotRadii.lg),
            border: Border.all(color: c.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 84,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: thumbnail ??
                          CustomPaint(
                            painter: _HatchPainter(
                              c.surfaceSunk,
                              c.surfaceApp,
                            ),
                          ),
                    ),
                    if (offlineReady)
                      Positioned(
                        top: 10,
                        right: 10,
                        child: PlotBadge('Offline ready',
                            tone: PlotBadgeTone.spruce, solid: true),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(PlotSpacing.s4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: PlotTypography.title(c.textPrimary)
                            .copyWith(fontSize: 17)),
                    const SizedBox(height: PlotSpacing.s2),
                    Wrap(
                      spacing: PlotSpacing.s2,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        for (int i = 0; i < stats.length; i++) ...[
                          Text(stats[i],
                              style: PlotTypography.data(c.textSecondary)),
                          if (i < stats.length - 1)
                            Text('·', style: PlotTypography.data(c.textMuted)),
                        ],
                        if (modeTag != null) ...[
                          Text('·', style: PlotTypography.data(c.textMuted)),
                          Text(modeTag!,
                              style: PlotTypography.data(c.success)),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HatchPainter extends CustomPainter {
  _HatchPainter(this.a, this.b);
  final Color a;
  final Color b;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = b);
    final p = Paint()
      ..color = a
      ..strokeWidth = 9;
    const gap = 18.0;
    for (double x = -size.height; x < size.width; x += gap) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), p);
    }
  }

  @override
  bool shouldRepaint(_HatchPainter old) => old.a != a || old.b != b;
}
