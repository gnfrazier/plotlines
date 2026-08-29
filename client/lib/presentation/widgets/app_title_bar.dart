// X1 (issue #180) — the app's own client-side titlebar. UAT on WSL showed the
// application running with no window chrome at all: WSLg / minimal window
// managers give the native GTK frame nothing to draw, so there was no way to
// move, minimise, maximise, or close the window. This widget replaces that
// native chrome with a brand-themed bar the app draws itself, on every desktop
// platform, so the controls behave identically regardless of the host window
// manager.
//
// The native frame is stripped in `linux/runner/my_application.cc`
// (`gtk_window_set_decorated(window, FALSE)`) and via `window_manager`'s
// `TitleBarStyle.hidden` on Windows/macOS; `DesktopWindowFrame`
// (`desktop_window_frame.dart`) mounts this bar at the top of the app and, on
// Linux, restores edge-resize with `DragToResizeArea`.
library;

import 'package:flutter/material.dart';
import 'package:plotlines_ui/plotlines_ui.dart';
import 'package:window_manager/window_manager.dart';

/// Height of the custom titlebar. Slightly under the 44px field touch target
/// (`PlotSpacing.touchMin`) — a pointer-only desktop affordance, kept compact
/// so it costs little vertical space, with the control buttons widened to 46px
/// to stay comfortably clickable.
const double kAppTitleBarHeight = 40;

class AppTitleBar extends StatefulWidget {
  const AppTitleBar({super.key});

  @override
  State<AppTitleBar> createState() => _AppTitleBarState();
}

class _AppTitleBarState extends State<AppTitleBar> with WindowListener {
  bool _isMaximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _syncMaximized();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _syncMaximized() async {
    final maximized = await windowManager.isMaximized();
    if (mounted && maximized != _isMaximized) {
      setState(() => _isMaximized = maximized);
    }
  }

  @override
  void onWindowMaximize() => setState(() => _isMaximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _isMaximized = false);

  Future<void> _toggleMaximize() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
    // Re-sync rather than trust the maximize/unmaximize event to arrive: on a
    // dropped WindowListener callback the button would otherwise show the
    // wrong icon until the next state change.
    await _syncMaximized();
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return SizedBox(
      height: kAppTitleBarHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: c.surfaceApp,
          border: Border(bottom: BorderSide(color: c.border)),
        ),
        child: Row(
          children: [
            // Drag region: title + branding, plus every pixel of empty space
            // up to the control buttons. Double-clicking it toggles
            // maximise/restore (handled by DragToMoveArea).
            Expanded(
              child: DragToMoveArea(
                child: SizedBox(
                  height: double.infinity,
                  child: Row(
                    children: [
                      const SizedBox(width: PlotSpacing.s3),
                      _BrandMark(color: c.textSecondary, dotColor: c.primary),
                      const SizedBox(width: PlotSpacing.s2),
                      Text(
                        'Plotlines',
                        style: PlotTypography.small(c.textSecondary)
                            .copyWith(fontWeight: FontWeight.w600, letterSpacing: 0.2),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            _WindowButton(
              key: const Key('window-button-minimize'),
              label: 'Minimise',
              icon: _WindowIcon.minimize,
              onPressed: windowManager.minimize,
            ),
            _WindowButton(
              key: const Key('window-button-maximize'),
              label: _isMaximized ? 'Restore' : 'Maximise',
              icon: _isMaximized ? _WindowIcon.restore : _WindowIcon.maximize,
              onPressed: _toggleMaximize,
            ),
            _WindowButton(
              key: const Key('window-button-close'),
              label: 'Close',
              icon: _WindowIcon.close,
              isClose: true,
              onPressed: windowManager.close,
            ),
          ],
        ),
      ),
    );
  }
}

/// A compact geometric mark — a rotated square outline with a Blaze centre dot
/// — echoing the brand's shape-plus-internal-mark iconography without pulling
/// in a bitmap asset. Blaze is used as a fill here (permitted); it is never set
/// as text.
class _BrandMark extends StatelessWidget {
  const _BrandMark({required this.color, required this.dotColor});

  final Color color;
  final Color dotColor;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 16,
      child: CustomPaint(painter: _BrandMarkPainter(color, dotColor)),
    );
  }
}

class _BrandMarkPainter extends CustomPainter {
  _BrandMarkPainter(this.color, this.dotColor);

  final Color color;
  final Color dotColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final r = size.width / 2;
    final diamond = Path()
      ..moveTo(center.dx, center.dy - r)
      ..lineTo(center.dx + r, center.dy)
      ..lineTo(center.dx, center.dy + r)
      ..lineTo(center.dx - r, center.dy)
      ..close();
    canvas.drawPath(
      diamond,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = PlotRadii.strokeMarker
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
    canvas.drawCircle(center, r * 0.28, Paint()..color = dotColor);
  }

  @override
  bool shouldRepaint(_BrandMarkPainter old) =>
      old.color != color || old.dotColor != dotColor;
}

enum _WindowIcon { minimize, maximize, restore, close }

class _WindowButton extends StatefulWidget {
  const _WindowButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.isClose = false,
  });

  /// Accessibility label. Not shown as a hover tooltip — a `Tooltip` needs an
  /// `Overlay`, and this bar renders above the router's `Navigator` where
  /// there is none. The hover fill is the pointer affordance instead.
  final String label;
  final _WindowIcon icon;
  final Future<void> Function() onPressed;
  final bool isClose;

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final Color? hoverBg = !_hovered
        ? null
        : widget.isClose
            ? c.danger
            : c.surfaceSunk;
    final Color fg = _hovered && widget.isClose
        ? c.onPrimary
        : _hovered
            ? c.textPrimary
            : c.textSecondary;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed,
        child: Semantics(
          button: true,
          label: widget.label,
          child: Container(
            width: 46,
            height: double.infinity,
            color: hoverBg,
            child: Center(
              child: CustomPaint(
                size: const Size.square(10),
                painter: _WindowIconPainter(widget.icon, fg),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WindowIconPainter extends CustomPainter {
  _WindowIconPainter(this.icon, this.color);

  final _WindowIcon icon;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // 2px stroke spec from the brand iconography grid, held crisp at this size.
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = color;
    final w = size.width;
    final h = size.height;

    switch (icon) {
      case _WindowIcon.minimize:
        canvas.drawLine(Offset(0, h / 2), Offset(w, h / 2), stroke);
      case _WindowIcon.maximize:
        canvas.drawRect(Rect.fromLTWH(0, 0, w, h), stroke);
      case _WindowIcon.restore:
        final d = w * 0.28;
        canvas.drawRect(Rect.fromLTWH(d, 0, w - d, h - d), stroke);
        final back = Path()
          ..moveTo(0, h - d)
          ..lineTo(0, d)
          ..lineTo(w - d, d);
        canvas.drawPath(back, stroke);
      case _WindowIcon.close:
        canvas.drawLine(Offset.zero, Offset(w, h), stroke);
        canvas.drawLine(Offset(w, 0), Offset(0, h), stroke);
    }
  }

  @override
  bool shouldRepaint(_WindowIconPainter old) =>
      old.icon != icon || old.color != color;
}
