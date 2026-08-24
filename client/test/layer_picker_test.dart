// FR97 — the layer-toggle picker used for both trip and per-day selection.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/presentation/widgets/layer_picker.dart';

void main() {
  testWidgets('renders a chip per layer, selected state reflects live set', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LayerPicker(
          layers: const ['sight', 'amenity', 'natural'],
          live: const {'sight', 'natural'},
          onToggle: (_) {},
        ),
      ),
    ));

    expect(find.byType(FilterChip), findsNWidgets(3));
    final sightChip = tester.widget<FilterChip>(find.widgetWithText(FilterChip, 'Sightseeing'));
    expect(sightChip.selected, isTrue);
    final amenityChip = tester.widget<FilterChip>(find.widgetWithText(FilterChip, 'Amenities'));
    expect(amenityChip.selected, isFalse);
  });

  testWidgets('tapping a chip reports which layer was toggled', (tester) async {
    String? toggled;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LayerPicker(
          layers: const ['sight', 'amenity'],
          live: const {'sight'},
          onToggle: (layer) => toggled = layer,
        ),
      ),
    ));

    await tester.tap(find.widgetWithText(FilterChip, 'Amenities'));
    await tester.pump();
    expect(toggled, 'amenity');
  });

  testWidgets('an unlabeled layer id falls back to the raw id', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LayerPicker(layers: const ['some_plugin_layer'], live: const {}, onToggle: (_) {}),
      ),
    ));
    expect(find.text('some_plugin_layer'), findsOneWidget);
  });
}
