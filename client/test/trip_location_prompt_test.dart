// A10 (PRD FR96) — the trip-creation location prompt: prefilled with the
// last-used value and freely editable, resolves via an injected geocode
// callback, and its only job is to hand back a map center. Choosing the
// shipped home region must never call geocode at all (no eager lookup for
// an extent nothing has justified), and an empty/failed geocode must keep
// the dialog open with an inline error rather than silently discarding what
// the Author typed.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/routing_client.dart';
import 'package:plotlines_client/domain/home_region.dart';
import 'package:plotlines_client/presentation/widgets/trip_location_prompt.dart';

Widget _harness({
  required String prefill,
  required Future<List<GeocodeResult>> Function(String) geocode,
  required void Function(TripLocationChoice?) onResult,
}) {
  return MaterialApp(
    home: Builder(builder: (context) {
      return ElevatedButton(
        onPressed: () async {
          final choice =
              await showTripLocationPrompt(context, prefill: prefill, geocode: geocode);
          onResult(choice);
        },
        child: const Text('open'),
      );
    }),
  );
}

void main() {
  testWidgets('prefills the field with the last-used value, freely editable', (tester) async {
    await tester.pumpWidget(_harness(
      prefill: 'Asheville, NC',
      geocode: (_) async => const [],
      onResult: (_) {},
    ));
    await tester.tap(find.text('open'));
    await tester.pump();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'Asheville, NC');

    await tester.enterText(find.byType(TextField), 'Boulder, CO');
    expect(field.controller!.text, 'Boulder, CO');
  });

  testWidgets('choosing the home region resolves with a null center and never geocodes',
      (tester) async {
    var geocodeCalls = 0;
    TripLocationChoice? result;
    var resultSet = false;
    await tester.pumpWidget(_harness(
      prefill: '',
      geocode: (_) async {
        geocodeCalls++;
        return const [];
      },
      onResult: (choice) {
        result = choice;
        resultSet = true;
      },
    ));
    await tester.tap(find.text('open'));
    await tester.pump();

    await tester.tap(find.text('Use ${HomeRegion.label}'));
    await tester.pumpAndSettle();

    expect(resultSet, isTrue);
    expect(result!.label, HomeRegion.label);
    expect(result!.center, isNull);
    expect(geocodeCalls, 0);
  });

  testWidgets('continuing with a resolvable location centers on the first geocode result',
      (tester) async {
    TripLocationChoice? result;
    await tester.pumpWidget(_harness(
      prefill: '',
      geocode: (query) async {
        expect(query, 'Boulder, CO');
        return const [GeocodeResult(label: 'Boulder, CO', coord: [-105.27, 40.02])];
      },
      onResult: (choice) => result = choice,
    ));
    await tester.tap(find.text('open'));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'Boulder, CO');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.label, 'Boulder, CO');
    expect(result!.center, [-105.27, 40.02]);
  });

  testWidgets('submitting a blank field is treated as choosing the home region', (tester) async {
    var geocodeCalls = 0;
    TripLocationChoice? result;
    await tester.pumpWidget(_harness(
      prefill: '',
      geocode: (_) async {
        geocodeCalls++;
        return const [];
      },
      onResult: (choice) => result = choice,
    ));
    await tester.tap(find.text('open'));
    await tester.pump();

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(result!.label, HomeRegion.label);
    expect(result!.center, isNull);
    expect(geocodeCalls, 0);
  });

  testWidgets('an empty geocode result shows an inline error and keeps the dialog open',
      (tester) async {
    var resultSet = false;
    await tester.pumpWidget(_harness(
      prefill: '',
      geocode: (_) async => const [],
      onResult: (_) => resultSet = true,
    ));
    await tester.tap(find.text('open'));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'Nowhereville');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(resultSet, isFalse);
    expect(find.textContaining('returned nothing'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('a geocode failure shows an inline error and keeps the dialog open',
      (tester) async {
    var resultSet = false;
    await tester.pumpWidget(_harness(
      prefill: '',
      geocode: (_) async => throw Exception('network down'),
      onResult: (_) => resultSet = true,
    ));
    await tester.tap(find.text('open'));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'Boulder, CO');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(resultSet, isFalse);
    expect(find.textContaining("Couldn't resolve"), findsOneWidget);
  });

  testWidgets('cancel returns null without resolving anything', (tester) async {
    TripLocationChoice? result;
    var resultSet = false;
    var geocodeCalls = 0;
    await tester.pumpWidget(_harness(
      prefill: 'Asheville, NC',
      geocode: (_) async {
        geocodeCalls++;
        return const [];
      },
      onResult: (choice) {
        result = choice;
        resultSet = true;
      },
    ));
    await tester.tap(find.text('open'));
    await tester.pump();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(resultSet, isTrue);
    expect(result, isNull);
    expect(geocodeCalls, 0);
  });
}
