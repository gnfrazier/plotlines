// FR99 — candidates render on the planning map and a tap promotes.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:drift/native.dart';

import 'package:plotlines_client/data/app_database.dart';
import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/domain/candidate.dart';
import 'package:plotlines_client/presentation/map/candidate_map.dart';
import 'package:plotlines_client/presentation/map/tap_to_pick_map.dart' show MapTileAssets;
import 'package:plotlines_client/state/providers.dart';
import 'package:plotlines_client/state/settings_provider.dart';

// Issue #154 — CandidateMap now reads `sidecarManagerProvider.baseUrl` to
// build its (sidecar-backed) tile provider, so it needs a `ProviderScope`
// like every other consumer of it; no network call actually happens in
// these tests (`_settle`'s short pumps never wait for a tile fetch).
class _FakeSidecarManager extends SidecarManager {
  @override
  Future<void> start() async {}

  @override
  SidecarStatus get status => const SidecarStatus(SidecarState.ready);
}

Future<void> _settle(WidgetTester tester) async {
  // Same pattern widget_test.dart uses: vector_map_tiles' internal ticker
  // needs several short pumps to settle rather than one `pumpAndSettle`.
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Widget _wrap(Widget child) => ProviderScope(
      overrides: [sidecarManagerProvider.overrideWith((ref) => _FakeSidecarManager())],
      child: MaterialApp(home: Scaffold(body: child)),
    );

/// Issue #465 — an in-memory settings DB pre-seeded with a basemap-style
/// choice (settings_provider_test.dart's own pattern), plus a chosen
/// [Brightness], for the basemap-style-selection tests below.
Future<Widget> _wrapWithBasemapPref(
  Widget child, {
  required BasemapStylePref basemapStyle,
  required Brightness brightness,
}) async {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  await db.setSetting('basemap_style', basemapStyle.name);
  return ProviderScope(
    overrides: [
      sidecarManagerProvider.overrideWith((ref) => _FakeSidecarManager()),
      appDatabaseProvider.overrideWithValue(db),
    ],
    child: MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  final candidate = const Candidate(
    id: 'c1',
    coord: [-105.27, 40.02],
    layer: 'historic',
    salience: 0.8,
    roleAffinity: RoleAffinity.narrative,
    title: 'Old Fort',
  );

  testWidgets('renders a marker per candidate', (tester) async {
    await tester.pumpWidget(_wrap(CandidateMap(candidates: [candidate])));
    await _settle(tester);
    expect(find.byTooltip('Old Fort'), findsOneWidget);
  });

  testWidgets('tapping a candidate marker reports that candidate', (tester) async {
    Candidate? tapped;
    await tester.pumpWidget(_wrap(
      CandidateMap(candidates: [candidate], onCandidateTap: (c) => tapped = c),
    ));
    await _settle(tester);

    await tester.tap(find.byTooltip('Old Fort'));
    await tester.pump();
    expect(tapped?.id, 'c1');
  });

  testWidgets('renders with an empty candidate list without throwing', (tester) async {
    await tester.pumpWidget(_wrap(const CandidateMap(candidates: [])));
    await _settle(tester);
    expect(find.byType(CandidateMap), findsOneWidget);
  });

  group('basemap style preference (issue #465)', () {
    testWidgets('an explicit preference reaches MapTileAssets.theme', (tester) async {
      await tester.pumpWidget(await _wrapWithBasemapPref(
        const CandidateMap(candidates: []),
        basemapStyle: BasemapStylePref.grayscale,
        brightness: Brightness.light,
      ));
      await _settle(tester);

      expect(
        MapTileAssets.requestedKeysForTesting.any((k) => k.startsWith('grayscale@')),
        isTrue,
      );
    });

    testWidgets('matchAppearance still tracks the device brightness (regression guard)',
        (tester) async {
      await tester.pumpWidget(await _wrapWithBasemapPref(
        const CandidateMap(candidates: []),
        basemapStyle: BasemapStylePref.matchAppearance,
        brightness: Brightness.dark,
      ));
      await _settle(tester);

      expect(
        MapTileAssets.requestedKeysForTesting.any((k) => k.startsWith('dark@')),
        isTrue,
      );
    });
  });
}
