import 'package:flutter/material.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';

/// A quiet elevation profile: filled area under a spruce ridgeline, hairline
/// axes, mono end labels. Pass normalized samples in 0..1 (fraction of max
/// elevation), left to right. [markers] are positions along the profile, as
/// fractions 0..1 of its length, drawn as ember ticks (a hazard or crux).
class ElevationProfile extends StatelessWidget {
  const ElevationProfile({
    super.key,
    required this.samples,
    this.height = 120,
    this.startLabel,
    this.endLabel,
    this.lineColor,
    this.markers = const [],
  });

  final List<double> samples;
  final double height;
  final String? startLabel;
  final String? endLabel;
  final Color? lineColor;
  final List<double> markers;

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
              markers: markers,
              marker: c.danger,
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
    this.markers = const [],
    this.marker = PlotColors.ember,
  });

  final List<double> samples;
  final Color line;
  final Color axis;
  final List<double> markers;
  final Color marker;

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

    final tick = Paint()
      ..color = marker
      ..strokeWidth = 2;
    for (final m in markers) {
      final x = size.width * m.clamp(0.0, 1.0);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), tick);
      canvas.drawPath(
        Path()
          ..moveTo(x - 5, 0)
          ..lineTo(x + 5, 0)
          ..lineTo(x, 7)
          ..close(),
        Paint()..color = marker,
      );
    }
  }

  @override
  bool shouldRepaint(_ElevationPainter old) =>
      old.samples != samples ||
      old.line != line ||
      old.axis != axis ||
      old.markers != markers;
}
