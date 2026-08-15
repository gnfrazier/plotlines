import 'package:flutter/material.dart';
import 'dart:math' as math;
import '../theme/colors.dart';

/// The six canonical map markers. Following topographic convention, each has a
/// distinct silhouette *plus* an internal mark, so the shape carries the
/// meaning and color only reinforces it — every marker reads in one ink, in
/// glare, or for color-blind users.
///
/// Circles = points on the route · squares = stops & transitions · triangle =
/// warning.
enum NodeMarkerType {
  waypoint, // ring + dot        · spruce
  regroup, // double ring (rally) · blaze
  rest, // shelter             · riverslate
  hazard, // warning triangle    · ember
  portage, // square + arrow      · gold
  plot, // filled disc + star  · ink (narrative)
}

class NodeMarker extends StatelessWidget {
  const NodeMarker(this.type, {super.key, this.size = 26, this.color});

  final NodeMarkerType type;
  final double size;

  /// Override the role color. Defaults to the marker's canonical brand color,
  /// resolved against the active theme.
  final Color? color;

  Color _defaultColor(PlotColors c) {
    switch (type) {
      case NodeMarkerType.waypoint:
        return c.success; // spruce
      case NodeMarkerType.regroup:
        return c.primary; // blaze
      case NodeMarkerType.rest:
        return c.info; // riverslate
      case NodeMarkerType.hazard:
        return c.danger; // ember
      case NodeMarkerType.portage:
        return c.warning; // gold
      case NodeMarkerType.plot:
        return c.textPrimary; // ink
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return CustomPaint(
      size: Size.square(size),
      painter: _NodeMarkerPainter(
        type: type,
        color: color ?? _defaultColor(c),
        paper: c.surfaceCard,
      ),
    );
  }
}

class _NodeMarkerPainter extends CustomPainter {
  _NodeMarkerPainter({
    required this.type,
    required this.color,
    required this.paper,
  });

  final NodeMarkerType type;
  final Color color;
  final Color paper;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final u = s / 24; // draw on a 24-unit grid
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.3 * u
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()..color = color..style = PaintingStyle.fill;
    final paperFill = Paint()..color = paper..style = PaintingStyle.fill;
    final c = Offset(12 * u, 12 * u);

    switch (type) {
      case NodeMarkerType.waypoint: // ring + dot
        canvas.drawCircle(c, 8.5 * u, paperFill);
        canvas.drawCircle(c, 8.5 * u, stroke..strokeWidth = 2.5 * u);
        canvas.drawCircle(c, 2.6 * u, fill);
        break;
      case NodeMarkerType.regroup: // double ring (rally target)
        canvas.drawCircle(c, 8.5 * u, paperFill);
        canvas.drawCircle(c, 8.5 * u, stroke..strokeWidth = 2.5 * u);
        canvas.drawCircle(c, 4 * u, stroke);
        break;
      case NodeMarkerType.rest: // shelter
        final roof = Path()
          ..moveTo(3.5 * u, 12 * u)
          ..lineTo(12 * u, 5.5 * u)
          ..lineTo(20.5 * u, 12 * u);
        final walls = Path()
          ..moveTo(5 * u, 11 * u)
          ..lineTo(5 * u, 20 * u)
          ..lineTo(19 * u, 20 * u)
          ..lineTo(19 * u, 11 * u);
        canvas.drawPath(walls, stroke);
        canvas.drawPath(roof, stroke);
        canvas.drawLine(Offset(4 * u, 20 * u), Offset(20 * u, 20 * u), stroke);
        break;
      case NodeMarkerType.hazard: // warning triangle + !
        final tri = Path()
          ..moveTo(12 * u, 4 * u)
          ..lineTo(20.5 * u, 19 * u)
          ..lineTo(3.5 * u, 19 * u)
          ..close();
        canvas.drawPath(tri, paperFill);
        canvas.drawPath(tri, stroke);
        canvas.drawLine(Offset(12 * u, 10 * u), Offset(12 * u, 14.5 * u), stroke);
        canvas.drawCircle(Offset(12 * u, 17 * u), 1.2 * u, fill);
        break;
      case NodeMarkerType.portage: // square + arrow
        final r = RRect.fromRectAndRadius(
          Rect.fromLTWH(4 * u, 4 * u, 16 * u, 16 * u),
          Radius.circular(2.5 * u),
        );
        canvas.drawRRect(r, paperFill);
        canvas.drawRRect(r, stroke);
        canvas.drawLine(Offset(8 * u, 12 * u), Offset(15 * u, 12 * u), stroke);
        final arrow = Path()
          ..moveTo(12.5 * u, 9 * u)
          ..lineTo(15.5 * u, 12 * u)
          ..lineTo(12.5 * u, 15 * u);
        canvas.drawPath(arrow, stroke);
        break;
      case NodeMarkerType.plot: // filled disc + star (narrative)
        canvas.drawCircle(c, 8 * u, fill);
        _drawStar(canvas, c, 4.2 * u, paperFill);
        break;
    }
  }

  void _drawStar(Canvas canvas, Offset center, double r, Paint paint) {
    final path = Path();
    for (int i = 0; i < 5; i++) {
      final outer = i * 2 * math.pi / 5 - math.pi / 2;
      final inner = outer + math.pi / 5;
      final po = Offset(
          center.dx + r * math.cos(outer), center.dy + r * math.sin(outer));
      final pi = Offset(center.dx + r * 0.42 * math.cos(inner),
          center.dy + r * 0.42 * math.sin(inner));
      if (i == 0) {
        path.moveTo(po.dx, po.dy);
      } else {
        path.lineTo(po.dx, po.dy);
      }
      path.lineTo(pi.dx, pi.dy);
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_NodeMarkerPainter old) =>
      old.type != type || old.color != color || old.paper != paper;
}
