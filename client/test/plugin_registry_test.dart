// FR84's output half — ARCH §14.1, §14.3, §14.4. Issue #147.
//
// The claim under test is the same one the input half had to prove at Leg 2.5:
// **a plugin may not require a change to core code.** `_FakeHeadUnit` below is
// written the way a third-party destination would be — it imports the seam and
// nothing else, registers itself with no core edit, and is driven entirely
// through `RevealView`.
//
// The assertions that matter are the P11 ones, and they are made on what the
// destination actually received, not on the code path that got it there — the
// same discipline as the export byte assertions (punch list §6A.2) and
// `speech_test.dart`. A push to a head unit is a content-crossing boundary
// nobody thinks to test with unrevealed content present (ARCH §14.3).

import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_client/data/export/export_options.dart';
import 'package:plotlines_client/data/plugins/output_integration.dart';
import 'package:plotlines_client/data/plugins/plugin_registry.dart';
import 'package:plotlines_client/data/reveal_view.dart';
import 'package:plotlines_client/domain/anchor.dart';
import 'package:plotlines_client/domain/reason_phrase.dart';
import 'package:plotlines_client/domain/trip.dart';

const _secret = 'The stone marks where the mill burned in 1897.';
const _hazard = 'Fifty metres of moving rock above a drop.';

Trip _trip() => Trip(
      id: 't1',
      title: 'Mill Creek',
      createdAt: '2026-09-01T00:00:00Z',
      updatedAt: '2026-09-01T00:00:00Z',
      anchors: [
        Anchor(
          id: 'a1',
          coord: [-105.266, 40.024],
          title: 'Sunset Overlook',
          roles: [
            Role(
              id: 'r-narrative',
              kind: RoleKind.narrative,
              reveal: RevealPolicy.onArrival,
              title: 'The mill stone',
              note: _secret,
            ),
            Role(
              id: 'r-provision',
              kind: RoleKind.provision,
              title: 'Spring box',
              note: 'Water, year-round.',
            ),
            Role(
              id: 'r-hazard',
              kind: RoleKind.station,
              hazard: true,
              // No `reveal:` — the model itself refuses `on_arrival` on a
              // hazard role (FR115 is enforced in `anchor.dart`, not here).
              title: 'Loose scree traverse',
              note: _hazard,
            ),
          ],
        ),
      ],
      provenance: Provenance(
        producedBy: 'plotlines',
        attribution: [
          Attribution(
            source: 'nps_units',
            licence: 'public-domain',
            credit: 'National Park Service',
            url: 'https://www.nps.gov/',
          ),
        ],
      ),
    );

// ─────────────────────────────────────────────────────── the fakes ──

/// The core's writers, stood in for. Records every call so "the integration
/// never encodes its own bytes" (D58) is checkable.
class _FakeWriter implements TripPayloadWriter {
  _FakeWriter(this.formats);

  @override
  final Set<ExportFormat> formats;
  final List<ExportFormat> calls = [];

  @override
  Future<List<int>> bytes(ExportFormat format) async {
    calls.add(format);
    return [0x0e, 0x10, format.index];
  }
}

class _FakeStore implements SecureStore {
  final Map<String, String> values = {};
  final List<String> deleted = [];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> delete(String key) async {
    values.remove(key);
    deleted.add(key);
  }
}

/// A third-party destination. Everything it can see about the trip's content
/// is recorded in [seen] — which is what the reveal assertions read.
class _FakeHeadUnit implements OutputIntegration {
  _FakeHeadUnit({
    this.id = 'fake-head-unit',
    this.accepts = const {ExportFormat.fit, ExportFormat.gpx},
    this.refuse = false,
  });

  @override
  final String id;
  @override
  String get displayName => 'Fake Head Unit';
  @override
  final Set<ExportFormat> accepts;

  final bool refuse;

  /// Every string and byte the destination got hold of.
  final List<String> seen = [];
  final List<List<int>> payloads = [];
  int pushes = 0;

  @override
  Future<void> authenticate(SecureStore store) =>
      store.write(id, 'oauth-token-abc123');

  @override
  Future<bool> isAuthenticated(SecureStore store) async =>
      (await store.read(id)) != null;

  @override
  Future<PushOutcome> pushTrip(Trip trip, RevealView reveal) async {
    pushes++;
    for (final anchor in trip.anchors) {
      for (final role in reveal.rolesFor(anchor)) {
        seen.addAll([role.title, role.note].whereType<String>());
      }
    }
    seen.addAll(reveal.attribution.map((a) => a.attribution));

    final format = negotiateFormat(this, reveal);
    if (format != null) payloads.add(await reveal.payload(format));

    if (refuse) {
      return const PushOutcome.failed(ReasonCode.externalProviderUnreachable);
    }
    return const PushOutcome.pushed(remoteId: 'course-9001');
  }
}

PluginRegistry _registry(_FakeStore store, {OutputIntegration? integration}) {
  final registry = PluginRegistry(secureStore: store);
  registry.register(integration ?? _FakeHeadUnit());
  return registry;
}

void main() {
  group('a destination registers with no core change (ARCH §14.4)', () {
    test('registration, lookup, and a stable picker order', () {
      final registry = PluginRegistry(secureStore: _FakeStore())
        ..register(_FakeHeadUnit(id: 'zwift'))
        ..register(_FakeHeadUnit(id: 'coros'));

      expect(registry.integrations.map((i) => i.id), ['coros', 'zwift']);
      expect(registry.byId('coros'), isNotNull);
      expect(registry.byId('garmin'), isNull);
    });

    test('a duplicate id is refused — ids key the credential store', () {
      final registry = _registry(_FakeStore());
      expect(() => registry.register(_FakeHeadUnit()), throwsStateError);
    });

    test('an id-less integration is refused', () {
      final registry = PluginRegistry(secureStore: _FakeStore());
      expect(() => registry.register(_FakeHeadUnit(id: '  ')), throwsArgumentError);
    });

    test('pushing to an unregistered id is a programming error, not an outcome', () {
      final registry = PluginRegistry(secureStore: _FakeStore());
      expect(
        () => registry.push('garmin', _trip(), RevealView.asCharacter(_trip())),
        throwsStateError,
      );
    });
  });

  group('P11 — a push is a content-crossing boundary', () {
    test('an unarrived Character never receives the withheld narrative', () async {
      final store = _FakeStore();
      final integration = _FakeHeadUnit();
      final registry = _registry(store, integration: integration);
      await registry.authenticate(integration.id);

      final trip = _trip();
      final outcome = await registry.push(
        integration.id,
        trip,
        RevealView.asCharacter(trip, payloadWriter: _FakeWriter({ExportFormat.fit})),
      );

      expect(outcome.ok, isTrue);
      expect(outcome.remoteId, 'course-9001');
      final crossed = integration.seen.join('\n');
      expect(crossed, isNot(contains(_secret)));
      expect(crossed, isNot(contains('The mill stone')));
    });

    test('a hazard crosses even when nothing else does (FR115)', () async {
      final store = _FakeStore();
      final integration = _FakeHeadUnit();
      final registry = _registry(store, integration: integration);
      await registry.authenticate(integration.id);

      final trip = _trip();
      await registry.push(integration.id, trip,
          RevealView.asCharacter(trip, payloadWriter: _FakeWriter({ExportFormat.fit})));

      expect(integration.seen.join('\n'), contains(_hazard));
    });

    test('a provision role crosses by its engine default (FR114)', () async {
      final store = _FakeStore();
      final integration = _FakeHeadUnit();
      final registry = _registry(store, integration: integration);
      await registry.authenticate(integration.id);

      final trip = _trip();
      await registry.push(integration.id, trip,
          RevealView.asCharacter(trip, payloadWriter: _FakeWriter({ExportFormat.gpx})));

      expect(integration.seen.join('\n'), contains('Water, year-round.'));
    });

    test('the Author pushing their own trip sees their own content', () async {
      final store = _FakeStore();
      final integration = _FakeHeadUnit();
      final registry = _registry(store, integration: integration);
      await registry.authenticate(integration.id);

      final trip = _trip();
      await registry.push(integration.id, trip,
          RevealView.asAuthor(trip, payloadWriter: _FakeWriter({ExportFormat.fit})));

      expect(integration.seen.join('\n'), contains(_secret));
    });

    test('arrival at the anchor releases it, and only then', () {
      final trip = _trip();
      final before = RevealView.asCharacter(trip);
      final after = RevealView.asCharacter(trip, arrivedAnchorIds: {'a1'});

      expect(before.releasedRoles.map((r) => r.roleId),
          isNot(contains('r-narrative')));
      expect(after.releasedRoles.map((r) => r.roleId), contains('r-narrative'));
      expect(before.resolvedRoles, hasLength(3));
    });
  });

  group('attribution travels with the data (FR86, FR95, FR101)', () {
    test('a trip always owes elevation and basemap, plus its own layers', () {
      final lines = attributionForTrip(_trip());
      expect(lines.map((l) => l.layer), containsAll(['elevation', 'basemap', 'nps_units']));
      expect(lines.firstWhere((l) => l.layer == 'nps_units').attribution,
          'National Park Service');
    });

    test('the destination receives the credit lines', () async {
      final store = _FakeStore();
      final integration = _FakeHeadUnit();
      final registry = _registry(store, integration: integration);
      await registry.authenticate(integration.id);

      final trip = _trip();
      await registry.push(integration.id, trip,
          RevealView.asCharacter(trip, payloadWriter: _FakeWriter({ExportFormat.fit})));

      expect(integration.seen.join('\n'), contains('© OpenStreetMap contributors'));
      expect(integration.seen.join('\n'), contains('National Park Service'));
    });

    test('a view carrying no credits is refused before anything leaves', () async {
      final store = _FakeStore();
      final integration = _FakeHeadUnit();
      final registry = _registry(store, integration: integration);
      await registry.authenticate(integration.id);

      final trip = _trip();
      final bare = RevealView.asCharacter(trip, attribution: const []);

      expect(bare.carriesAttribution, isFalse);
      await expectLater(
        registry.push(integration.id, trip, bare),
        throwsA(isA<MissingAttributionError>()),
      );
      expect(integration.pushes, 0);
    });
  });

  group('bytes come from the core writer, never from the integration (D58)', () {
    test('the destination reads its payload through the supplied writer', () async {
      final store = _FakeStore();
      final integration = _FakeHeadUnit();
      final registry = _registry(store, integration: integration);
      await registry.authenticate(integration.id);

      final writer = _FakeWriter({ExportFormat.fit, ExportFormat.gpx});
      final trip = _trip();
      await registry.push(
          integration.id, trip, RevealView.asCharacter(trip, payloadWriter: writer));

      expect(writer.calls, [ExportFormat.fit]); // destination's preference wins
      expect(integration.payloads, hasLength(1));
    });

    test('a format the writer cannot produce is refused before the push', () async {
      final store = _FakeStore();
      final integration = _FakeHeadUnit(accepts: const {ExportFormat.fit});
      final registry = _registry(store, integration: integration);
      await registry.authenticate(integration.id);

      final writer = _FakeWriter({ExportFormat.gpx});
      final trip = _trip();
      final outcome = await registry.push(
          integration.id, trip, RevealView.asCharacter(trip, payloadWriter: writer));

      expect(outcome.status, PushStatus.formatUnsupported);
      expect(integration.pushes, 0);
      expect(writer.calls, isEmpty);
    });

    test('asking a view for bytes it has no writer for throws rather than improvising',
        () {
      final trip = _trip();
      final view = RevealView.asCharacter(trip);
      expect(view.payloadFormats, isEmpty);
      expect(() => view.payload(ExportFormat.fit), throwsStateError);
    });
  });

  group('credentials live in the SecureStore (§14.3)', () {
    test('authenticate writes the token to the registry store, not the integration',
        () async {
      final store = _FakeStore();
      final integration = _FakeHeadUnit();
      final registry = _registry(store, integration: integration);

      expect(await registry.isAuthenticated(integration.id), isFalse);
      await registry.authenticate(integration.id);

      expect(store.values[integration.id], 'oauth-token-abc123');
      expect(await registry.isAuthenticated(integration.id), isTrue);
    });

    test('a push with no credential asks for one instead of failing', () async {
      final store = _FakeStore();
      final integration = _FakeHeadUnit();
      final registry = _registry(store, integration: integration);

      final trip = _trip();
      final outcome = await registry.push(integration.id, trip,
          RevealView.asCharacter(trip, payloadWriter: _FakeWriter({ExportFormat.fit})));

      expect(outcome.status, PushStatus.notAuthenticated);
      expect(outcome.reason, isNull); // "connect" is an action, not a cause
      expect(integration.pushes, 0);
    });

    test('disconnecting deletes the token rather than leaving it', () async {
      final store = _FakeStore();
      final integration = _FakeHeadUnit();
      final registry = _registry(store, integration: integration);
      await registry.authenticate(integration.id);

      await registry.disconnect(integration.id);

      expect(store.values, isEmpty);
      expect(store.deleted, [integration.id]);
      expect(registry.byId(integration.id), isNull);
    });
  });

  group('a failure states a bounded cause (FR145, ARCH D57)', () {
    test('a refusing destination reports a ReasonCode from the phrase table', () async {
      final store = _FakeStore();
      final integration = _FakeHeadUnit(refuse: true);
      final registry = _registry(store, integration: integration);
      await registry.authenticate(integration.id);

      final trip = _trip();
      final outcome = await registry.push(integration.id, trip,
          RevealView.asCharacter(trip, payloadWriter: _FakeWriter({ExportFormat.fit})));

      expect(outcome.ok, isFalse);
      expect(outcome.status, PushStatus.failed);
      expect(outcome.reason, ReasonCode.externalProviderUnreachable);
      expect(reasonPhrases.containsKey(outcome.reason), isTrue);
    });
  });
}
