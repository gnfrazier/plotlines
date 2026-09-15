// Issue #399 — K5's `DisplayFormat` had `platformDateFormatter` /
// `platformUses24Hour` hooks from the start and no caller ever supplied
// them, so `inherit` (FR79's default) read as ISO 8601 / 24-hour on every
// device. `displayFormatOf` is the one place a date- or clock-rendering
// widget resolves `inherit` against what the `BuildContext` knows. These
// pin what it takes from the context, what it leaves to the stored
// preference, and that a pinned `displayFormatProvider` still pins.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/presentation/display_format_of.dart';
import 'package:plotlines_client/presentation/widgets/metrics_rail.dart' show formatEta;
import 'package:plotlines_client/state/settings_provider.dart';

final _stamp = DateTime(2026, 9, 12, 15, 7);

Future<DisplayFormat> _resolve(
  WidgetTester tester, {
  List<Override> overrides = const [],
  bool alwaysUse24HourFormat = false,
}) async {
  late DisplayFormat resolved;
  await tester.pumpWidget(ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(alwaysUse24HourFormat: alwaysUse24HourFormat),
        child: Consumer(builder: (context, ref, _) {
          resolved = displayFormatOf(context, ref);
          return const SizedBox.shrink();
        }),
      ),
    ),
  ));
  return resolved;
}

void main() {
  testWidgets('inherit takes the locale date pattern and the platform clock flag',
      (tester) async {
    // flutter_test's MaterialApp localises to en_US, and the view's
    // 24-hour flag is what MediaQuery reports.
    final f = await _resolve(
      tester,
      overrides: [displayFormatProvider.overrideWithValue(const DisplayFormat())],
    );
    expect(f.dateIsInherited, isTrue);
    expect(f.formatDate(_stamp), 'Sep 12, 2026');
    expect(f.formatTime(_stamp), '3:07 PM');

    final f24 = await _resolve(
      tester,
      overrides: [displayFormatProvider.overrideWithValue(const DisplayFormat())],
      alwaysUse24HourFormat: true,
    );
    expect(f24.formatTime(_stamp), '15:07');
  });

  testWidgets('an explicit preference wins over the platform on both axes', (tester) async {
    final f = await _resolve(
      tester,
      overrides: [
        displayFormatProvider.overrideWithValue(const DisplayFormat(
          datePref: DateFormatPref.europeanDot,
          clockPref: ClockPref.hour24,
        )),
      ],
    );
    expect(f.dateIsInherited, isFalse);
    expect(f.formatDate(_stamp), '12.09.2026');
    expect(f.formatTime(_stamp), '15:07');
  });

  testWidgets('a pinned provider keeps its units — only the inherit answers come from context',
      (tester) async {
    final f = await _resolve(
      tester,
      overrides: [
        displayFormatProvider.overrideWithValue(const DisplayFormat(
          useMiles: true,
          temperatureUnit: TemperatureUnit.fahrenheit,
        )),
      ],
    );
    expect(f.useMiles, isTrue);
    expect(f.temperatureUnit, TemperatureUnit.fahrenheit);
    expect(f.formatDate(_stamp), 'Sep 12, 2026');
  });

  group('the Route tab EST. ARRIVAL stamp follows the clock preference', () {
    const eta = '2026-09-01T14:30:00Z';

    test('24-hour', () {
      expect(formatEta(eta, const DisplayFormat(clockPref: ClockPref.hour24)), '14:30');
    });

    test('12-hour', () {
      expect(formatEta(eta, const DisplayFormat(clockPref: ClockPref.hour12)), '2:30 PM');
    });

    test('inherit defers to the platform flag', () {
      expect(formatEta(eta, const DisplayFormat(platformUses24Hour: false)), '2:30 PM');
      expect(formatEta(eta, const DisplayFormat(platformUses24Hour: true)), '14:30');
    });

    test('a stamp that is not a timestamp is shown as-is rather than fudged', () {
      expect(formatEta('soon', const DisplayFormat()), 'soon');
    });
  });
}
