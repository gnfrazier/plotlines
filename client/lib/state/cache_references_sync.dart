// Epic #641 (ARCH D73, story #647) — tells the sidecar which held map areas
// live trips still need.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/routing_client.dart';
import '../data/sidecar_manager.dart';
import 'providers.dart';

/// Sends the sidecar the full set of live trips' stored bboxes (D70) —
/// bboxes only, never a trip id or title — whenever that set changes (a trip
/// created, cloned, deleted, or its bbox edited) and whenever the sidecar is
/// ready on a new port (start, restart). A full set rather than add/remove
/// events, so a send the sidecar missed is corrected by the next one; until
/// the first arrives the sidecar keeps every area, so a lost send never
/// deletes anything.
///
/// A failed send is not retried on a timer: the next change, or the next
/// time the sidecar manager notifies, tries again.
class CacheReferencesSync {
  CacheReferencesSync({
    required Stream<List<List<double>>> bboxes,
    required this.manager,
    required this.send,
  }) {
    _sub = bboxes.listen((b) {
      _current = b;
      _maybeSend();
    });
    manager.addListener(_maybeSend);
  }

  final Future<void> Function(String baseUrl, List<List<double>> bboxes) send;
  final SidecarManager manager;
  StreamSubscription<List<List<double>>>? _sub;
  List<List<double>>? _current;
  String? _sentKey;
  bool _inFlight = false;
  bool _disposed = false;

  void _maybeSend() {
    final bboxes = _current;
    if (_disposed || bboxes == null || _inFlight) return;
    if (manager.status.state != SidecarState.ready) return;
    final baseUrl = manager.baseUrl;
    final key = '$baseUrl|${jsonEncode(bboxes)}';
    if (key == _sentKey) return;
    _inFlight = true;
    send(baseUrl, bboxes).then((_) {
      _sentKey = key;
    }, onError: (Object _) {}).whenComplete(() {
      _inFlight = false;
      // The set may have moved on while this send was in flight.
      if (_sentKey == key) _maybeSend();
    });
  }

  void dispose() {
    _disposed = true;
    manager.removeListener(_maybeSend);
    _sub?.cancel();
  }
}

/// Created once the app starts its sidecar (`main.dart`); lives for the
/// app's lifetime.
final cacheReferencesSyncProvider = Provider<CacheReferencesSync>((ref) {
  final sync = CacheReferencesSync(
    bboxes: ref.read(appDatabaseProvider).watchTripBboxes(),
    manager: ref.read(sidecarManagerProvider),
    send: (baseUrl, bboxes) => RoutingClient(baseUrl).putCacheReferences(bboxes),
  );
  ref.onDispose(sync.dispose);
  return sync;
});
