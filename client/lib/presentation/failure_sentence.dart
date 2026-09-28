// M13 / FR145 — the one conversion from a caught error to text on a
// surface. Its own file rather than part of `widgets/error_states.dart`,
// because the stale list (FR140a) uses it too and deliberately sits outside
// that shared error surface.
library;

import '../data/routing_client.dart' show RoutingException;
import '../domain/reason_phrase.dart' show looksLikeRawDiagnostic;

/// A sidecar's own reason ([RoutingException.message]) passes through when
/// it reads as a sentence; anything else — a raw body, a traceback, or any
/// other exception's `toString()` (a class name, a path, an errno) — becomes
/// [fallback], and the caller logs the detail.
String failureSentence(Object error, {required String fallback}) {
  if (error is RoutingException && !looksLikeRawDiagnostic(error.message)) {
    return error.message;
  }
  return fallback;
}
