// M13 — the error/empty-state taxonomy's sidecar-lifecycle rows (MVP doc §4),
// stubbed as one shared surface rather than an ad-hoc dialog per call site:
//   "Sidecar starting"       -> full-screen honest wait, escalating detail
//   "Sidecar won't start"    -> full-screen honest message + retry
//   "Sidecar died mid-session" -> banner over the still-usable app:
//       cached trips viewable, generation unavailable — never a full block,
//       because P5 (work is never silently destroyed) means a transient
//       crash must not take the Author's open trip off screen.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../data/sidecar_manager.dart';
import '../../state/providers.dart';

/// Wraps the whole routed app. Blocks on starting/failed; overlays a banner
/// on degraded; renders [child] untouched once ready.
class SidecarGate extends ConsumerWidget {
  const SidecarGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manager = ref.watch(sidecarManagerProvider);
    final status = manager.status;

    switch (status.state) {
      case SidecarState.starting:
        return _FullScreenWait(detail: status.detail);
      case SidecarState.failed:
        return _FullScreenFailure(
          detail: status.detail,
          onRetry: () => ref.read(sidecarManagerProvider).start(),
        );
      case SidecarState.restarting:
        return _FullScreenWait(detail: status.detail);
      case SidecarState.degraded:
        return Column(
          children: [
            _DegradedBanner(detail: status.detail),
            Expanded(child: child),
          ],
        );
      case SidecarState.ready:
      case SidecarState.stopped:
        return child;
    }
  }
}

class _FullScreenWait extends StatelessWidget {
  const _FullScreenWait({required this.detail});
  final String detail;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(PlotSpacing.s6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // The cycling-themed wait (PRD Story C27 lineage) — a route-line
              // sweep rather than a bare spinner, so a cold start still reads
              // as "working", not "hung".
              const _RouteSweep(),
              const SizedBox(height: PlotSpacing.s5),
              Text('Plotting the route graph', style: PlotTypography.title(c.textPrimary)),
              const SizedBox(height: PlotSpacing.s2),
              Text(detail,
                  textAlign: TextAlign.center,
                  style: PlotTypography.body(c.textSecondary)),
            ],
          ),
        ),
      ),
    );
  }
}

class _RouteSweep extends StatefulWidget {
  const _RouteSweep();
  @override
  State<_RouteSweep> createState() => _RouteSweepState();
}

class _RouteSweepState extends State<_RouteSweep> with SingleTickerProviderStateMixin {
  late final _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return SizedBox(
      width: 96,
      height: 40,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) => CustomPaint(
          painter: _SweepPainter(progress: _ctrl.value, color: c.primary, track: c.border),
        ),
      ),
    );
  }
}

class _SweepPainter extends CustomPainter {
  _SweepPainter({required this.progress, required this.color, required this.track});
  final double progress;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height * 0.6;
    final trackPaint = Paint()
      ..color = track
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(0, y), Offset(size.width, y), trackPaint);

    final sweepPaint = Paint()
      ..color = color
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    final headX = size.width * progress;
    final tailX = (headX - size.width * 0.35).clamp(0.0, size.width);
    canvas.drawLine(Offset(tailX, y), Offset(headX, y), sweepPaint);
    canvas.drawCircle(Offset(headX, y), 4, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_SweepPainter old) => old.progress != progress;
}

class _FullScreenFailure extends StatelessWidget {
  const _FullScreenFailure({required this.detail, required this.onRetry});
  final String detail;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(PlotSpacing.s6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 40, color: c.danger),
              const SizedBox(height: PlotSpacing.s4),
              Text('The routing engine won\'t start',
                  style: PlotTypography.title(c.textPrimary)),
              const SizedBox(height: PlotSpacing.s2),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Text(detail,
                    textAlign: TextAlign.center,
                    style: PlotTypography.body(c.textSecondary)),
              ),
              const SizedBox(height: PlotSpacing.s5),
              PlotButton(label: 'Retry', onPressed: onRetry),
            ],
          ),
        ),
      ),
    );
  }
}

class _DegradedBanner extends StatelessWidget {
  const _DegradedBanner({required this.detail});
  final String detail;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return Container(
      width: double.infinity,
      color: c.warning.withValues(alpha: 0.16),
      padding: const EdgeInsets.symmetric(horizontal: PlotSpacing.s4, vertical: PlotSpacing.s2),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 18, color: c.warning),
          const SizedBox(width: PlotSpacing.s2),
          Expanded(
            child: Text(detail, style: PlotTypography.small(c.textPrimary)),
          ),
        ],
      ),
    );
  }
}
