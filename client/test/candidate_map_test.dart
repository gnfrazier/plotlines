// FR99 — candidates render on the planning map and a tap promotes.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/domain/candidate.dart';
import 'package:plotlines_client/presentation/map/candidate_map.dart';
import 'package:plotlines_client/state/providers.dart';

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
}
