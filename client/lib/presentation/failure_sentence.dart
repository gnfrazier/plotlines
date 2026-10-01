// M13 / FR145 — the one conversion from a caught error to text on a
// surface. Its own file rather than part of `widgets/error_states.dart`,
// because the stale list (FR140a) uses it too and deliberately sits outside
// that shared error surface.
library;

import '../data/routing_client.dart' show RoutingException;
import '../domain/reason_phrase.dart' show looksLikeRawDiagnostic;

/// A sidecar's own reason ([RoutingException.reason]) passes through when
/// it reads as a sentence; anything else — a raw body, a traceback, or any
/// other exception's `toString()` (a class name, a path, an errno) — becomes
/// [fallback], and the caller logs the detail.
String failureSentence(Object error, {required String fallback}) {
  final reason = error is RoutingException ? error.reason : null;
  if (reason != null && !looksLikeRawDiagnostic(reason)) return reason;
  return fallback;
}

/// Issue #574 — a solve refused because a point the Author placed (start,
/// end, via) is farther from the trip area's routing data than the
/// sidecar's wrong-region guard allows (`OutsideGraphExtent`, a 422 naming
/// "outside this graph's region"). The one failure that really is "this area
/// doesn't have routable data" — not a timeout, a not-ready region, or a
/// solve that found no route.
bool isOutsideRoutingArea(Object error) =>
    error is RoutingException &&
    error.statusCode == 422 &&
    (error.reason?.contains("outside this graph's region") ?? false);
