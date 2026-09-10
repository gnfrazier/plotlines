// Issue #338 — `disciplineIcon` gives every discipline its own glyph. The
// walkthrough guardrail (`travel_mode_icons.dart` doc) is that the three cycle
// disciplines must not all read as one bike; more generally, no two
// disciplines that share a category — the only ones a picker row shows at
// once — may share a glyph.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/discipline.dart';
import 'package:plotlines_client/domain/travel_mode.dart';
import 'package:plotlines_client/presentation/widgets/travel_mode_icons.dart';

void main() {
  test('every discipline key resolves to a glyph', () {
    for (final k in kDisciplineKeys) {
      expect(disciplineIcon(k), isA<IconData>(), reason: k);
    }
  });

  test('road / gravel / mountain are three different glyphs', () {
    final icons = {
      disciplineIcon('road'),
      disciplineIcon('gravel'),
      disciplineIcon('mountain'),
    };
    expect(icons, hasLength(3));
  });

  test('within every category, no two disciplines share a glyph', () {
    for (final category in kTravelCategories) {
      final keys = disciplinesForCategory(category);
      final icons = keys.map(disciplineIcon).toSet();
      expect(icons, hasLength(keys.length), reason: category);
    }
  });

  test('an unknown discipline falls through to a neutral mark, never a bike', () {
    expect(disciplineIcon('wingfoiling'), isNot(Icons.directions_bike));
    expect(disciplineIcon('wingfoiling'), isA<IconData>());
  });
}
