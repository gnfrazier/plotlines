/// FR84's **output** half — ARCH §14.1, §14.3. The seam a third-party
/// destination (Garmin, Coros, Wahoo, RideWithGPS) implements to receive a
/// finished trip.
///
/// **Deliberately open, and that is the requirement rather than an omission.**
/// FR84 v2.0 closed the data-input half (FR100, Leg 2.5, `LayerProvider`) and
/// left the output half's contract shape open at Leg 7 — no destination is
/// named in code, no vendor SDK is depended on, and `SPIKE-17`'s questions
/// about packaging and registration for a third-party contributor are not
/// answered here. What this file fixes is the *shape of a push*, so the four
/// obligations below are structural rather than remembered.
///
/// **It runs on the device, in Dart, not in the service.** The integration
/// holds the user's OAuth token and must reach the vendor's API from where
/// that token lives; routing a push through the server would make the service
/// a credential custodian for every user (§14.1).
///
/// The four things the shape enforces:
///
/// 1.  **`pushTrip` takes a [RevealView].** A push is a content-crossing
///     boundary exactly like an export, and it is the one nobody thinks to
///     test with unrevealed content present (§14.3, P11).
/// 2.  **Bytes come from the core writer.** An integration declares which
///     formats it [accepts] and asks the view for them; it does not carry a
///     FIT encoder of its own (D58 — one writer, one code path, so a sidecar
///     and a hosted deployment cannot produce different FIT files).
/// 3.  **Tokens go to a [SecureStore].** Never to drift, never to the server.
///     The store is handed in at [authenticate] rather than held by the
///     integration, so an integration never owns credential storage.
/// 4.  **A failure states a bounded cause.** [PushOutcome] carries a
///     [ReasonCode] from the phrase table, never a vendor error string:
///     every user-visible message resolves a template against typed slots
///     (FR145, ARCH D57), and an interpolated remote error is exactly the
///     unbounded slot that rule forbids.
///
/// A destination that needs core to change in order to be added has found a
/// missing or wrong extension point — fix the extension point, do not
/// special-case the destination (§14.4).
library;

import '../../domain/reason_phrase.dart' show ReasonCode;
import '../../domain/trip.dart';
import '../export/export_options.dart';
import '../reveal_view.dart';

/// Where an integration's credentials live: the platform keychain on the
/// device. Deliberately has no network of its own — a token that reaches this
/// interface has nowhere else to go.
///
/// Leg 7 supplies the platform-backed implementation; nothing in the app
/// ships one yet, which is why `PluginRegistry` requires one to be passed in
/// rather than defaulting to something in memory.
abstract class SecureStore {
  Future<void> write(String key, String value);
  Future<String?> read(String key);
  Future<void> delete(String key);
}

/// What happened to a push. `pushed` is the only success.
enum PushStatus {
  pushed,

  /// No usable credential — the surface offers "connect", which is an action
  /// to take rather than a cause to state.
  notAuthenticated,

  /// The destination accepts no format this trip's writer can produce.
  formatUnsupported,

  /// Reached the destination and it refused, or never reached it.
  failed,
}

/// A push's result. [reason] is present only where a surface must state a
/// cause, and it is always a member of the bounded table
/// (`domain/reason_phrase.dart`) — `externalProviderUnreachable` when the
/// destination could not be reached or refused, `exportFailed` when the
/// payload could not be produced.
class PushOutcome {
  const PushOutcome({required this.status, this.reason, this.remoteId});

  const PushOutcome.pushed({this.remoteId})
      : status = PushStatus.pushed,
        reason = null;

  const PushOutcome.failed(ReasonCode this.reason)
      : status = PushStatus.failed,
        remoteId = null;

  const PushOutcome.notAuthenticated()
      : status = PushStatus.notAuthenticated,
        reason = null,
        remoteId = null;

  const PushOutcome.formatUnsupported()
      : status = PushStatus.formatUnsupported,
        reason = null,
        remoteId = null;

  final PushStatus status;
  final ReasonCode? reason;

  /// The destination's own id for what it just received, where it returns
  /// one — an identifier, never prose.
  final String? remoteId;

  bool get ok => status == PushStatus.pushed;
}

/// One output destination.
abstract class OutputIntegration {
  /// Stable, machine-readable, unique across the registry — also the key
  /// prefix this integration's credentials are stored under.
  String get id;

  /// The destination's own name, as it appears in a picker. Not a message:
  /// a proper noun the app does not translate.
  String get displayName;

  /// The formats this destination can receive, in preference order of the
  /// destination's own choosing. Empty is a valid answer for a destination
  /// that takes a trip some other way, and it will never be handed bytes.
  Set<ExportFormat> get accepts;

  /// Obtain and store a credential. The token goes into [store] and nowhere
  /// else — not into a field on this object, not to the service.
  Future<void> authenticate(SecureStore store);

  /// Whether a usable credential exists, asked before every push so a
  /// revoked token surfaces as "connect again" rather than as a failure.
  Future<bool> isAuthenticated(SecureStore store);

  /// Push [trip] to the destination. Every piece of content that crosses
  /// comes from [reveal]: `reveal.rolesFor(anchor)` for role content,
  /// `reveal.payload(format)` for encoded bytes, `reveal.attribution` for the
  /// credits the destination must carry with the data.
  Future<PushOutcome> pushTrip(Trip trip, RevealView reveal);
}
