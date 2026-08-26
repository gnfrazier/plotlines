// FR145 / M14 — the migrated surface. The role chips on an anchor card were
// the client's clearest instance of the thing FR145 forbids: a tooltip
// assembled at the call site out of a `switch` over reveal state, a
// `toStringAsFixed` coordinate, and two appended clauses. They are now four
// independent templates joined by the locale's own facet separator.
//
// What these tests are actually for is the property that makes the migration
// worth doing: swap the catalog and the whole surface changes language,
// without a widget being touched. A composed sentence cannot do that, which
// is why "localization works" and "no sentence becomes a path around the
// reveal gate" are the same requirement (FR145).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/widgets/anchor_promotion_panel.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/messages_provider.dart';

Trip _tripWithAnchor() => Trip(
      id: 't1',
      title: 'Test trip',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      anchors: [
        Anchor(
          id: 'a1',
          coord: [-105.266, 40.024],
          title: 'Sunset Overlook',
          roles: [
            Role(
              id: 'r1',
              kind: RoleKind.narrative,
              reveal: RevealPolicy.onArrival,
              coord: [-105.267, 40.025],
              arc: ArcStage.crux,
              title: 'The mill stone',
              note: 'The stone marks where the mill burned in 1897.',
            ),
            Role(id: 'r2', kind: RoleKind.provision, title: 'Spring box'),
          ],
        ),
      ],
    );

class _Harness extends ConsumerWidget {
  const _Harness();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trip = ref.watch(currentTripProvider);
    return MaterialApp(home: Scaffold(body: AnchorPromotionPanel(trip: trip)));
  }
}

/// A catalog that renames the two templates a role chip leads with, so a
/// changed rendering can only come from the catalog and not from the widget.
class _AltCatalog extends MessageCatalog {
  const _AltCatalog();

  @override
  String get locale => 'en';

  @override
  ListPatterns get listPatterns => const ListPatterns(
        two: '{0} and {1}',
        start: '{0}, {1}',
        middle: '{0}, {1}',
        end: '{0}, and {1}',
        facetSeparator: ' / ',
      );

  @override
  String? pattern(MessageId id) => switch (id) {
        MessageId.roleRefNamed => 'ROLE<{type}> AT <{place}>',
        MessageId.termRevealOnArrival => 'ON-ARRIVAL',
        _ => null,
      };
}

Future<void> _pump(WidgetTester tester, {List<Override> overrides = const []}) => tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentTripProvider.overrideWith((ref) => CurrentTripNotifier(ref)..open(_tripWithAnchor())),
          ...overrides,
        ],
        child: const _Harness(),
      ),
    );

String _tooltip(WidgetTester tester, {required String containing}) => tester
    .widgetList<Tooltip>(find.byType(Tooltip))
    .map((t) => t.message ?? '')
    .firstWhere((m) => m.contains(containing), orElse: () => '');

void main() {
  testWidgets('a role chip states the place, the role type, and its reveal — from templates', (tester) async {
    await _pump(tester);
    expect(
      _tooltip(tester, containing: 'narrative'),
      'the narrative role at Sunset Overlook: on arrival · offset 40.02500, -105.26700 · arc: crux',
    );
  });

  testWidgets('a provision role left unset reads as the engine default, not as a fourth state', (tester) async {
    await _pump(tester);
    expect(_tooltip(tester, containing: 'provision'), 'the provision role at Sunset Overlook: always visible (default)');
  });

  testWidgets('the offset line under the card renders through the locale number format', (tester) async {
    await _pump(tester);
    expect(find.text('narrative offset: 40.02500, -105.26700'), findsOneWidget);
  });

  testWidgets('swapping the catalog changes the surface with no widget change (FR83 / M8)', (tester) async {
    await _pump(tester, overrides: [messageCatalogProvider.overrideWithValue(const _AltCatalog())]);
    expect(
      _tooltip(tester, containing: 'ROLE'),
      'ROLE<narrative> AT <Sunset Overlook>: ON-ARRIVAL / offset 40.02500, -105.26700 / arc: crux',
    );
  });

  testWidgets('no chip tooltip carries the role\'s authored content (FR145, ARCH A30)', (tester) async {
    await _pump(tester);
    final tooltips = tester.widgetList<Tooltip>(find.byType(Tooltip)).map((t) => t.message ?? '').join('\n');
    expect(tooltips, isNot(contains('The mill stone')));
    expect(tooltips, isNot(contains('the mill burned')));
    expect(tooltips, isNot(contains('Spring box')));
  });
}
