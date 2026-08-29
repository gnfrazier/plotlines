import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:plotlines_ui/plotlines_ui.dart';
import 'package:window_manager/window_manager.dart';

import 'presentation/screens/new_route_screen.dart';
import 'presentation/screens/settings_screen.dart';
import 'presentation/screens/trip_area_screen.dart';
import 'presentation/screens/trip_library_screen.dart';
import 'presentation/screens/trip_shell_screen.dart';
import 'presentation/widgets/desktop_window_frame.dart';
import 'presentation/widgets/sidecar_gate.dart';
import 'presentation/widgets/trip_location_prompt.dart';
import 'state/providers.dart';
import 'state/settings_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _initDesktopWindow();
  runApp(const ProviderScope(child: PlotlinesApp()));
}

/// X1 (issue #180) — strip the native window frame and hand sizing to the
/// app before the first frame, so there is no flash of an unstyled or
/// oversized window and the custom titlebar (`AppTitleBar`) is the only
/// chrome the user ever sees. No-op off desktop.
Future<void> _initDesktopWindow() async {
  if (!isDesktopWindowingPlatform) return;
  await windowManager.ensureInitialized();
  const options = WindowOptions(
    size: Size(1280, 720),
    minimumSize: Size(800, 600),
    center: true,
    title: 'Plotlines',
    titleBarStyle: TitleBarStyle.hidden,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  });
}

final _router = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(path: '/', builder: (context, state) => const TripLibraryScreen()),
    // N1 (FR120) — step 2 of trip initiation: draw the trip bbox before
    // New Route's setup form.
    GoRoute(
      path: '/new-trip-area',
      builder: (context, state) {
        final choice = state.extra as TripLocationChoice?;
        return TripAreaScreen(
          isCreation: true,
          initialCenter: choice?.center,
          initialFramingBbox: choice?.bbox,
        );
      },
    ),
    // N1 (FR120) — the reachable path for revising an existing trip's
    // extent (trip_shell_screen.dart's app bar action), distinct from the
    // route above: it frames on the current bbox, not a fresh location.
    GoRoute(
      path: '/trip-area',
      builder: (context, state) => const TripAreaScreen(isCreation: false),
    ),
    GoRoute(
      path: '/new',
      builder: (context, state) =>
          NewRouteScreen(initialCenter: state.extra as List<double>?),
    ),
    // Wireframe screens 01/02/03/04 — one persistent tabbed shell per trip,
    // not four separate routes (see trip_shell_screen.dart).
    GoRoute(path: '/plan', builder: (context, state) => const TripShellScreen()),
    // Wireframe screen 06 — Preferences & About merged into one screen.
    GoRoute(path: '/settings', builder: (context, state) => const SettingsScreen()),
  ],
);

/// Starts the sidecar once, at app launch, so [SidecarGate] has something to
/// watch by the time the first frame needs it (ARCH §7.3, M12).
class PlotlinesApp extends ConsumerStatefulWidget {
  const PlotlinesApp({super.key});

  @override
  ConsumerState<PlotlinesApp> createState() => _PlotlinesAppState();
}

class _PlotlinesAppState extends ConsumerState<PlotlinesApp> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // Fire-and-forget: SidecarGate renders the starting/failed states off
    // sidecarManagerProvider's own notifications, not this future. The
    // orphan sweep (ARCH §8.4) runs first, so a sidecar the previous session
    // crashed without stopping is cleared before this one binds its port.
    Future.microtask(() async {
      final manager = ref.read(sidecarManagerProvider);
      await manager.sweepOrphans();
      await manager.start();
    });
    // A desktop window close routes through here first. Stop the sidecar
    // gracefully before the process exits, so the Windows CTRL_BREAK stop
    // path (ARCH §7.3) actually runs in production — `ref.onDispose` never
    // fires before app exit, and a severed in-flight write is exactly what
    // that path exists to prevent.
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        await ref.read(sidecarManagerProvider).stop();
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final theme = switch (settings.contrast) {
      ContrastMode.highContrast => PlotTheme.highContrast(),
      _ => PlotTheme.light(),
    };
    return MaterialApp.router(
      title: 'Plotlines',
      debugShowCheckedModeBanner: false,
      theme: theme,
      darkTheme: settings.contrast == ContrastMode.highContrast
          ? PlotTheme.highContrast()
          : PlotTheme.dark(),
      themeMode: settings.themeMode,
      routerConfig: _router,
      builder: (context, child) => DesktopWindowFrame(
        child: SidecarGate(child: child ?? const SizedBox.shrink()),
      ),
    );
  }
}
