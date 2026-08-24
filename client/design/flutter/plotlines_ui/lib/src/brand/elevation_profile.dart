import 'package:flutter/material.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';

/// A quiet elevation profile: filled area under a spruce ridgeline, hairline
/// axes, mono end labels. Pass normalized samples in 0..1 (fraction of max
/// elevation), left to right.
class ElevationProfile extends StatelessWidget {
  const ElevationProfile({
    super.key,
    required this.samples,
    this.height = 120,
    this.startLabel,
    this.endLabel,
    this.lineColor,
  });

  final List<double> samples;
  final double height;
  final String? startLabel;
  final String? endLabel;
  final Color? lineColor;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final line = lineColor ?? c.success;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: height,
          child: CustomPaint(
            painter: _ElevationPainter(
              samples: samples,
              line: line,
              axis: c.textSecondary,
            ),
          ),
        ),
        if (startLabel != null || endLabel != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(startLabel ?? '', style: PlotTypography.data(c.textMuted)),
                Text(endLabel ?? '', style: PlotTypography.data(c.textMuted)),
              ],
            ),
          ),
      ],
    );
  }
}

class _ElevationPainter extends CustomPainter {
  _ElevationPainter({
    required this.samples,
    required this.line,
    required this.axis,
  });

  final List<double> samples;
  final Color line;
  final Color axis;

  @override
  void paint(Canvas canvas, Size size) {
    final axisPaint = Paint()
      ..color = axis
      ..strokeWidth = 1;
    // L-shaped axes
    canvas.drawLine(Offset(0, 0), Offset(0, size.height), axisPaint);
    canvas.drawLine(
        Offset(0, size.height), Offset(size.width, size.height), axisPaint);

    if (samples.length < 2) return;
    final path = Path();
    Offset at(int i) {
      final x = size.width * i / (samples.length - 1);
      final y = size.height * (1 - samples[i].clamp(0.0, 1.0)) * 0.92;
      return Offset(x, y);
    }

    path.moveTo(0, size.height);
    path.lineTo(at(0).dx, at(0).dy);
    for (int i = 1; i < samples.length; i++) {
      path.lineTo(at(i).dx, at(i).dy);
    }
    path.lineTo(size.width, size.height);
    path.close();

    canvas.drawPath(
      path,
      Paint()..color = line.withValues(alpha: 0.16)..style = PaintingStyle.fill,
    );

    final ridge = Path()..moveTo(at(0).dx, at(0).dy);
    for (int i = 1; i < samples.length; i++) {
      ridge.lineTo(at(i).dx, at(i).dy);
    }
    canvas.drawPath(
      ridge,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_ElevationPainter old) =>
      old.samples != samples || old.line != line || old.axis != axis;
}
