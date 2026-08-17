// Core app-wide providers (ARCH §9.1's State layer). Kept to wiring only —
// no business logic lives here, just how the Data-layer singletons are
// constructed and how their lifecycles are exposed to Riverpod.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/app_database.dart';
import '../data/routing_client.dart';
import '../data/sidecar_manager.dart';

/// One [SidecarManager] for the app's lifetime — it owns a real OS process.
/// `ref.onDispose` stops it if the provider is ever torn down (tests,
/// hot-restart of the provider tree), though in production this scope never
/// closes before the app does.
final sidecarManagerProvider = ChangeNotifierProvider<SidecarManager>((ref) {
  final manager = SidecarManager();
  ref.onDispose(manager.stop);
  return manager;
});

/// Rebuilds whenever [SidecarManager] notifies — i.e. on every state
/// transition, not just once the port is known. Downstream code should read
/// `.port` off the manager itself rather than caching this URL, since it is
/// `http://127.0.0.1:0` (unusable) until the sidecar has actually bound a
/// port (ARCH §9.1: RoutingClient holds the base URL; this is where it gets it).
final routingClientProvider = Provider<RoutingClient>((ref) {
  final manager = ref.watch(sidecarManagerProvider);
  return RoutingClient(manager.baseUrl);
});

/// One drift connection for the app's lifetime (ARCH §9.2 — desktop storage).
final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});
