/// `PluginRegistry` — ARCH §9.1, §14.3. What the app holds output
/// integrations in, and the one place a push is gated.
///
/// The input-side registry (`plotlines_core.curation.registry.LayerRegistry`)
/// refuses a layer whose licence metadata is absent or unsatisfiable — at
/// registration, not at render (D45). This is the output-side mirror, with
/// the gates the direction actually needs:
///
/// - **A destination registers once, by unique id.** A second integration
///   claiming a live id is a programming error and throws; ids are also the
///   key prefix credentials are stored under, so a silent overwrite would
///   hand one destination another's token.
/// - **A push carries its credits or does not happen.** A [RevealView] with
///   no attribution has lost an obligation upstream (FR86, FR95, FR101), and
///   like the core's `assert_attribution_complete` that is a build failure —
///   it throws [MissingAttributionError] rather than returning an outcome for
///   a surface to render.
/// - **Format is negotiated before the integration is called.** A destination
///   that accepts only FIT and a trip whose writer produces only GPX is a
///   `formatUnsupported` outcome, decided here, so a destination is never
///   handed a view it cannot read bytes from.
/// - **Credentials are checked, and they come from the registry's store.**
///   An integration never holds the [SecureStore]; it is passed the one the
///   registry owns, for the duration of the call.
///
/// What this registry deliberately does *not* do is discover integrations.
/// Discovery — packaging, entry points, key handling for a third-party
/// contributor — is `SPIKE-17`'s unrun question and Leg 7's to answer; the
/// input half's answer (an installable package behind an entry point, never a
/// URL the app downloads at runtime — `curation/plugins.py`) is the obvious
/// starting point, not a settled one. Until then registration is explicit and
/// in-app.
library;

import '../../domain/trip.dart';
import '../export/export_options.dart';
import '../reveal_view.dart';
import 'output_integration.dart';

/// A push was attempted for an artifact carrying no attribution. Mirrors the
/// core's `MissingAttributionError`: a build failure, not a message.
class MissingAttributionError extends Error {
  MissingAttributionError(this.integrationId);

  final String integrationId;

  @override
  String toString() =>
      'MissingAttributionError: refused to push to "$integrationId" — the '
      'RevealView carries no attribution lines. Every layer whose data is in '
      'the artifact is owed its credit, and elevation (CC BY) and the basemap '
      '(ODbL) are owed always (FR86, FR95, FR101; ARCH §12.2).';
}

class PluginRegistry {
  PluginRegistry({required SecureStore secureStore}) : _store = secureStore;

  final SecureStore _store;
  final Map<String, OutputIntegration> _integrations = {};

  /// Every registered destination, ordered by id so a picker is stable.
  List<OutputIntegration> get integrations {
    final out = _integrations.values.toList()..sort((a, b) => a.id.compareTo(b.id));
    return List.unmodifiable(out);
  }

  OutputIntegration? byId(String id) => _integrations[id];

  void register(OutputIntegration integration) {
    if (integration.id.trim().isEmpty) {
      throw ArgumentError.value(integration.id, 'id', 'an integration needs a stable id');
    }
    if (_integrations.containsKey(integration.id)) {
      throw StateError(
        'output integration "${integration.id}" is already registered — ids are '
        'unique, and are the key prefix credentials are stored under',
      );
    }
    _integrations[integration.id] = integration;
  }

  /// Removes a destination and forgets its credential. Disconnecting is the
  /// only path that deletes a token, and it deletes it rather than leaving it
  /// for a re-connect to find.
  Future<void> disconnect(String id) async {
    final integration = _integrations.remove(id);
    if (integration == null) return;
    await _store.delete(id);
  }

  /// Runs [OutputIntegration.authenticate] against the registry's store.
  Future<void> authenticate(String id) => _require(id).authenticate(_store);

  Future<bool> isAuthenticated(String id) => _require(id).isAuthenticated(_store);

  /// The gated push. Ordered so the cheapest refusals happen before anything
  /// leaves the device, and so an integration is never invoked with a view it
  /// cannot use.
  Future<PushOutcome> push(String id, Trip trip, RevealView reveal) async {
    final integration = _require(id);

    if (!reveal.carriesAttribution) {
      throw MissingAttributionError(id);
    }
    if (!await integration.isAuthenticated(_store)) {
      return const PushOutcome.notAuthenticated();
    }
    if (integration.accepts.isNotEmpty && negotiateFormat(integration, reveal) == null) {
      return const PushOutcome.formatUnsupported();
    }
    return integration.pushTrip(trip, reveal);
  }

  OutputIntegration _require(String id) {
    final integration = _integrations[id];
    if (integration == null) {
      throw StateError('no output integration registered as "$id"');
    }
    return integration;
  }
}

/// The format a push would use: the destination's first accepted format the
/// trip's writer can actually produce. `null` when there is no overlap.
///
/// The destination's preference order wins, not the writer's — a head unit
/// that reads both FIT and GPX renders course points from one and a bare
/// track from the other, and only the destination knows which it prefers.
ExportFormat? negotiateFormat(OutputIntegration integration, RevealView reveal) {
  for (final format in integration.accepts) {
    if (reveal.payloadFormats.contains(format)) return format;
  }
  return null;
}
