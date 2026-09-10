// #324 — the two marks an alternate's divergence puts on the map: where it
// leaves the passage's line, and where it comes back.
//
// These are not [NodeMarker]s. A fork is not a node on the day — nothing is
// authored there, nothing is arrived at, and it belongs to the alternate
// rather than to the passage — so it gets its own shape rather than borrowing
// a node's. The brand rule holds either way: shape plus an internal mark
// carries the meaning, and colour only reinforces it. Both are diamonds (a
// shape the node set does not use) with an internal splitting or converging
// pair of strokes, so the two read apart in monochrome, at print size, and in
// outdoor high-contrast.
library;

import 'package:flutter/material.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

/// Which end of the divergence a mark is.
enum AlternateEndpoint {
  /// The alternate leaves the passage's line here.
  fork,

  /// The alternate returns to it here.
  rejoin,
}

/// The map mark for one end of an alternate's divergence.
class AlternateEndpointMarker extends StatelessWidget {
  const AlternateEndpointMarker(this.endpoint, {super.key, this.size = 26, this.color});

  final AlternateEndpoint endpoint;
  final double size;

  /// Override the mark colour. Defaults to the brand's caution gold, which is
  /// a fill-and-marker colour (never text) and reads apart from the blaze the
  /// route itself is drawn in.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return CustomPaint(
      size: Size.square(size),
      painter: _EndpointPainter(
        endpoint: endpoint,
        stroke: color ?? c.warning,
        fill: c.surfaceCard,
      ),
    );
  }
}

class _EndpointPainter extends CustomPainter {
  _EndpointPainter({required this.endpoint, required this.stroke, required this.fill});

  final AlternateEndpoint endpoint;
  final Color stroke;
  final Color fill;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final cx = size.width / 2, cy = size.height / 2;
    final r = s / 2 - 1;

    final diamond = Path()
      ..moveTo(cx, cy - r)
      ..lineTo(cx + r, cy)
      ..lineTo(cx, cy + r)
      ..lineTo(cx - r, cy)
      ..close();
    canvas.drawPath(diamond, Paint()..color = fill);
    canvas.drawPath(
      diamond,
      Paint()
        ..color = stroke
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * 0.09,
    );

    // The internal mark: a stem that splits into two (fork) or two strands
    // that come back to one (rejoin). Drawn left-to-right in both cases, so
    // the difference is the direction of the split, not the direction of
    // travel.
    final p = Paint()
      ..color = stroke
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.09
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final a = r * 0.52; // arm reach
    final split = Path();
    if (endpoint == AlternateEndpoint.fork) {
      split
        ..moveTo(cx - a, cy)
        ..lineTo(cx, cy)
        ..moveTo(cx, cy)
        ..lineTo(cx + a, cy - a * 0.85)
        ..moveTo(cx, cy)
        ..lineTo(cx + a, cy + a * 0.85);
    } else {
      split
        ..moveTo(cx - a, cy - a * 0.85)
        ..lineTo(cx, cy)
        ..moveTo(cx - a, cy + a * 0.85)
        ..lineTo(cx, cy)
        ..moveTo(cx, cy)
        ..lineTo(cx + a, cy);
    }
    canvas.drawPath(split, p);
  }

  @override
  bool shouldRepaint(_EndpointPainter old) =>
      old.endpoint != endpoint || old.stroke != stroke || old.fill != fill;
}
