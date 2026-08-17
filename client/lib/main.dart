import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import 'presentation/screens/new_route_screen.dart';
import 'presentation/screens/settings_screen.dart';
import 'presentation/screens/trip_library_screen.dart';
import 'presentation/screens/trip_shell_screen.dart';
import 'presentation/widgets/sidecar_gate.dart';
import 'state/providers.dart';
import 'state/settings_provider.dart';

void main() {
  runApp(const ProviderScope(child: PlotlinesApp()));
}

final _router = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(path: '/', builder: (context, state) => const TripLibraryScreen()),
    GoRoute(path: '/new', builder: (context, state) => const NewRouteScreen()),
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
  @override
  void initState() {
    super.initState();
    // Fire-and-forget: SidecarGate renders the starting/failed states off
    // sidecarManagerProvider's own notifications, not this future.
    Future.microtask(() => ref.read(sidecarManagerProvider).start());
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
      builder: (context, child) => SidecarGate(child: child ?? const SizedBox.shrink()),
    );
  }
}
