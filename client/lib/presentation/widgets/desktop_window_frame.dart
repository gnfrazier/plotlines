// X1 (issue #180) — wraps the whole app in its client-side window frame: the
// custom titlebar on top (`AppTitleBar`) and, on Linux, manual edge-resize
// handles. Mounted once in `main.dart`'s `MaterialApp.router` builder, above
// `SidecarGate`, so the controls are present even on the sidecar-starting
// screen.
//
// Linux runs fully undecorated (`my_application.cc`
// `gtk_window_set_decorated(window, FALSE)`), which is the reliable way to get
// no native chrome on WSLg / minimal window managers — but it also removes the
// native resize border, so `DragToResizeArea` puts it back. Windows and macOS
// keep their native resize border and OS snap under `TitleBarStyle.hidden`, so
// they get the bar alone.
library;

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app_title_bar.dart';

/// True on the three desktop platforms that render a host window we manage.
bool get isDesktopWindowingPlatform =>
    Platform.isLinux || Platform.isWindows || Platform.isMacOS;

class DesktopWindowFrame extends StatelessWidget {
  const DesktopWindowFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!isDesktopWindowingPlatform) return child;

    final Widget framed = Column(
      children: [
        // Material ancestor: this bar sits above the router's Navigator, so
        // it inherits no Scaffold/Material of its own.
        const Material(type: MaterialType.transparency, child: AppTitleBar()),
        Expanded(child: child),
      ],
    );

    if (Platform.isLinux) {
      return DragToResizeArea(resizeEdgeSize: 6, child: framed);
    }
    return framed;
  }
}
