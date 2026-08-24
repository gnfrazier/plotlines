import 'package:flutter/material.dart';
import '../theme/colors.dart';

/// A curation candidate's primary role affinity (ARCH D47) — narrative,
/// provision, or station. Distinct from [NodeMarkerType]'s promoted-node
/// shapes: a candidate is not yet in the trip.
enum CandidateRoleAffinity { narrative, provision, station }

/// FR99 — a candidate on the planning map, salience rendered as size, ring
/// weight, and fill opacity (never color alone: candidate_marker.dart §brand
/// guardrail — "every map marker must carry a distinct shape + internal
/// mark, not color alone"). The inner mark's shape carries
/// [roleAffinity] — circle/square/triangle, mirroring [NodeMarkerType]'s
/// existing point/stop/warning vocabulary — so an Author can read what kind
/// of place this is before ever checking color.
class CandidateMarker extends StatelessWidget {
  const CandidateMarker({
    super.key,
    required this.salience,
    this.roleAffinity = CandidateRoleAffinity.narrative,
    this.color,
    this.baseSize = 22,
  }) : assert(salience >= 0.0 && salience <= 1.0);

  /// 0.0-1.0 — FR98's salience score.
  final double salience;
  final CandidateRoleAffinity roleAffinity;
  final Color? color;

  /// The marker's diameter at salience 1.0; a low-salience candidate draws
  /// smaller, never larger, so a dense bbox doesn't drown its best places.
  final double baseSize;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    // Never below 55% of baseSize — even a low-salience candidate must stay
    // tappable — and never fully transparent, so it's still findable.
    final size = baseSize * (0.55 + 0.45 * salience);
    return CustomPaint(
      size: Size.square(size),
      painter: _CandidateMarkerPainter(
        salience: salience,
        roleAffinity: roleAffinity,
        color: color ?? c.primary,
        paper: c.surfaceCard,
      ),
    );
  }
}

class _CandidateMarkerPainter extends CustomPainter {
  _CandidateMarkerPainter({
    required this.salience,
    required this.roleAffinity,
    required this.color,
    required this.paper,
  });

  final double salience;
  final CandidateRoleAffinity roleAffinity;
  final Color color;
  final Color paper;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final u = s / 24;
    final center = Offset(12 * u, 12 * u);
    // Weight: a notable candidate draws with a bolder ring.
    final strokeWidth = (1.4 + 1.6 * salience) * u;
    // Opacity: a marginal candidate reads as a hint, a notable one as solid.
    final fillOpacity = 0.25 + 0.55 * salience;

    final ring = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    final fill = Paint()
      ..color = color.withValues(alpha: fillOpacity)
      ..style = PaintingStyle.fill;
    final paperFill = Paint()..color = paper..style = PaintingStyle.fill;
    final mark = Paint()..color = color..style = PaintingStyle.fill;

    canvas.drawCircle(center, 9 * u, paperFill);
    canvas.drawCircle(center, 9 * u, fill);
    canvas.drawCircle(center, 9 * u, ring);

    switch (roleAffinity) {
      case CandidateRoleAffinity.narrative:
        canvas.drawCircle(center, 3 * u, mark);
        break;
      case CandidateRoleAffinity.provision:
        canvas.drawRect(Rect.fromCenter(center: center, width: 5 * u, height: 5 * u), mark);
        break;
      case CandidateRoleAffinity.station:
        final tri = Path()
          ..moveTo(center.dx, center.dy - 3.4 * u)
          ..lineTo(center.dx + 3.4 * u, center.dy + 2.6 * u)
          ..lineTo(center.dx - 3.4 * u, center.dy + 2.6 * u)
          ..close();
        canvas.drawPath(tri, mark);
        break;
    }
  }

  @override
  bool shouldRepaint(_CandidateMarkerPainter old) =>
      old.salience != salience ||
      old.roleAffinity != roleAffinity ||
      old.color != color ||
      old.paper != paper;
}
