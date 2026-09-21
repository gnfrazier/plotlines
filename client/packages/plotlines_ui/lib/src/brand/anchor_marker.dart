import 'package:flutter/material.dart';
import 'dart:math' as math;
import '../theme/colors.dart';

/// The internal mark an [AnchorMarker] carries: the anchor's role set, read
/// as a shape. A single role keeps the mark its candidate had
/// ([CandidateRoleAffinity]'s circle / square / triangle), so promotion
/// changes the silhouette and not the kind — an Author who read "provision"
/// off the square before promoting still reads it after. More than one role
/// draws the narrative star: the place is a story point with several jobs,
/// and no one of the three shapes would be honest.
enum AnchorMarkerMark { narrative, provision, station, multiRole }

/// FR106 / FR110 (O1), issue #410 — a promoted anchor on the map. Distinct
/// from [CandidateMarker] (a salience-scaled ring: cache, not yet in the
/// trip) and from [NodeMarker]'s eight route marks (points on a day's line):
/// an anchor is trip canon, so it draws at one fixed size, fully opaque, on
/// a diamond silhouette no other mark uses — the brand guardrail is shape +
/// internal mark, never colour alone, and circles, squares and triangles are
/// all taken. Blaze ring, paper fill, ink mark.
class AnchorMarker extends StatelessWidget {
  const AnchorMarker({
    super.key,
    this.mark = AnchorMarkerMark.narrative,
    this.size = 28,
    this.color,
  });

  final AnchorMarkerMark mark;
  final double size;

  /// Override the ring colour. Defaults to the brand primary (Blaze):
  /// promotion is the editorial moment, and the primary is what marks it.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return CustomPaint(
      size: Size.square(size),
      painter: _AnchorMarkerPainter(
        mark: mark,
        color: color ?? c.primary,
        ink: c.textPrimary,
        paper: c.surfaceCard,
      ),
    );
  }
}

class _AnchorMarkerPainter extends CustomPainter {
  _AnchorMarkerPainter({
    required this.mark,
    required this.color,
    required this.ink,
    required this.paper,
  });

  final AnchorMarkerMark mark;
  final Color color;
  final Color ink;
  final Color paper;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final u = s / 24; // the same 24-unit grid as NodeMarker
    final c = Offset(12 * u, 12 * u);
    final ring = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.3 * u
      ..strokeJoin = StrokeJoin.round;
    final paperFill = Paint()..color = paper..style = PaintingStyle.fill;
    final inkFill = Paint()..color = ink..style = PaintingStyle.fill;

    final diamond = Path()
      ..moveTo(12 * u, 2.5 * u)
      ..lineTo(21.5 * u, 12 * u)
      ..lineTo(12 * u, 21.5 * u)
      ..lineTo(2.5 * u, 12 * u)
      ..close();
    canvas.drawPath(diamond, paperFill);
    canvas.drawPath(diamond, ring);

    switch (mark) {
      case AnchorMarkerMark.narrative:
        canvas.drawCircle(c, 2.8 * u, inkFill);
        break;
      case AnchorMarkerMark.provision:
        canvas.drawRect(Rect.fromCenter(center: c, width: 5 * u, height: 5 * u), inkFill);
        break;
      case AnchorMarkerMark.station:
        final tri = Path()
          ..moveTo(c.dx, c.dy - 3.2 * u)
          ..lineTo(c.dx + 3.2 * u, c.dy + 2.4 * u)
          ..lineTo(c.dx - 3.2 * u, c.dy + 2.4 * u)
          ..close();
        canvas.drawPath(tri, inkFill);
        break;
      case AnchorMarkerMark.multiRole:
        _drawStar(canvas, c, 4 * u, inkFill);
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
  bool shouldRepaint(_AnchorMarkerPainter old) =>
      old.mark != mark || old.color != color || old.ink != ink || old.paper != paper;
}
