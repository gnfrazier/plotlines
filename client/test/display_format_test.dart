// K5 / FR79 — the render-time transform. These assert the two things the
// story hangs on: the seven date patterns (plus a 12/24-hour clock) render
// exactly as offered, and `inherit` resolves against the *device's* answer
// supplied at call time rather than being frozen to one of the seven.

import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_client/domain/display_format.dart';

void main() {
  // 2026-08-20T15:07:00 — a date whose day and month are unambiguous only
  // once the pattern is applied, and an afternoon time for AM/PM coverage.
  final sample = DateTime(2026, 8, 20, 15, 7);
  final morning = DateTime(2026, 1, 5, 9, 3);

  group('the seven date patterns render verbatim (FR79 override menu)', () {
    const cases = {
      DateFormatPref.iso8601: '2026-08-20',
      DateFormatPref.us: '08/20/2026',
      DateFormatPref.uk: '20/08/2026',
      DateFormatPref.europeanDot: '20.08.2026',
      DateFormatPref.eastAsia: '2026/08/20',
      DateFormatPref.dayMonYear: '20 Aug 2026',
      DateFormatPref.monDayYear: 'Aug 20, 2026',
    };
    cases.forEach((pref, expected) {
      test(pref.name, () {
        expect(DisplayFormat(datePref: pref).formatDate(sample), expected);
      });
    });

    test('single-digit day/month keep zero padding except in the prose forms', () {
      expect(DisplayFormat(datePref: DateFormatPref.us).formatDate(morning),
          '01/05/2026');
      expect(DisplayFormat(datePref: DateFormatPref.europeanDot).formatDate(morning),
          '05.01.2026');
      expect(DisplayFormat(datePref: DateFormatPref.dayMonYear).formatDate(morning),
          '5 Jan 2026');
      expect(DisplayFormat(datePref: DateFormatPref.monDayYear).formatDate(morning),
          'Jan 5, 2026');
    });
  });

  group('inherit resolves at render time, not at install', () {
    test('date defers to the platform formatter the caller supplies', () {
      final fmt = DisplayFormat(
        datePref: DateFormatPref.inherit,
        platformDateFormatter: (d) => 'PLATFORM-${d.year}',
      );
      expect(fmt.formatDate(sample), 'PLATFORM-2026');
      expect(fmt.dateIsInherited, isTrue);
    });

    test('date falls back to ISO 8601 when no platform pattern is available', () {
      final fmt = DisplayFormat(datePref: DateFormatPref.inherit);
      expect(fmt.formatDate(sample), '2026-08-20');
      expect(fmt.dateIsInherited, isFalse);
    });

    test('inherit is not one of the seven — a different platform gives a different answer', () {
      String render(String Function(DateTime) platform) => DisplayFormat(
            datePref: DateFormatPref.inherit,
            platformDateFormatter: platform,
          ).formatDate(sample);
      expect(render((d) => '20th of August'), isNot('2026-08-20'));
      expect(render((d) => '20th of August'),
          isNot(render((d) => '2026年8月20日')));
    });

    test('clock defers to the platform 24-hour flag', () {
      expect(
        DisplayFormat(clockPref: ClockPref.inherit, platformUses24Hour: true)
            .formatTime(sample),
        '15:07',
      );
      expect(
        DisplayFormat(clockPref: ClockPref.inherit, platformUses24Hour: false)
            .formatTime(sample),
        '3:07 PM',
      );
    });
  });

  group('12/24-hour clock override', () {
    test('24-hour is zero-padded', () {
      expect(DisplayFormat(clockPref: ClockPref.hour24).formatTime(sample),
          '15:07');
      expect(DisplayFormat(clockPref: ClockPref.hour24).formatTime(morning),
          '09:03');
    });

    test('12-hour drops the leading hour zero, keeps the minute zero, marks the period', () {
      expect(DisplayFormat(clockPref: ClockPref.hour12).formatTime(sample),
          '3:07 PM');
      expect(DisplayFormat(clockPref: ClockPref.hour12).formatTime(morning),
          '9:03 AM');
      expect(
        DisplayFormat(clockPref: ClockPref.hour12)
            .formatTime(DateTime(2026, 1, 1, 0, 30)),
        '12:30 AM',
      );
      expect(
        DisplayFormat(clockPref: ClockPref.hour12)
            .formatTime(DateTime(2026, 1, 1, 12, 0)),
        '12:00 PM',
      );
    });
  });

  group('temperature is a render-time transform on canonical Celsius', () {
    test('celsius passes through', () {
      final f = DisplayFormat(temperatureUnit: TemperatureUnit.celsius);
      expect(f.temperatureValue(21), 21);
      expect(f.formatTemperature(21.4), '21°C');
    });

    test('fahrenheit converts and rounds for display only', () {
      final f = DisplayFormat(temperatureUnit: TemperatureUnit.fahrenheit);
      expect(f.temperatureValue(0), 32);
      expect(f.temperatureValue(100), 212);
      expect(f.formatTemperature(21), '70°F'); // 69.8 -> 70
    });
  });

  group('distance & length are render-time transforms on canonical metres (#312)', () {
    const metric = DisplayFormat();
    const imperial = DisplayFormat(useMiles: true);

    test('route/day distance: km passes through, miles convert, one decimal', () {
      expect(metric.formatDistance(17800), '17.8 km');
      expect(imperial.formatDistance(17800), '11.1 mi'); // 11.06 -> 11.1
      expect(metric.distanceUnitLabel, 'km');
      expect(imperial.distanceUnitLabel, 'mi');
      expect(metric.formatDistance(42000, fractionDigits: 0), '42 km');
    });

    test('short lengths: feet under imperial, metres under metric, whole units', () {
      expect(metric.formatSmallLength(120), '120 m');
      expect(imperial.formatSmallLength(120), '394 ft'); // 393.7 -> 394
      expect(metric.smallLengthUnitLabel, 'm');
      expect(imperial.smallLengthUnitLabel, 'ft');
    });

    test('altitude: feet under imperial, never metres-under-imperial', () {
      expect(metric.formatElevation(366), '366 m');
      expect(imperial.formatElevation(366), '1201 ft'); // 1200.8 -> 1201
    });

    test('parseDistanceToMetres inverts the active route unit', () {
      expect(metric.parseDistanceToMetres('40'), 40000);
      expect(imperial.parseDistanceToMetres('40'), closeTo(64373.76, 1e-6));
      expect(metric.parseDistanceToMetres('not a number'), isNull);
    });

    test('parseSmallLengthToMetres inverts the active short-length unit', () {
      expect(metric.parseSmallLengthToMetres('150'), 150);
      expect(imperial.parseSmallLengthToMetres('150'), closeTo(45.72, 1e-3));
    });

    test('a value typed in one unit round-trips through parse+format', () {
      final metres = imperial.parseDistanceToMetres('26.2')!; // a marathon
      expect(imperial.distanceInputValue(metres), '26.2');
    });
  });

  test('formatDateTime composes the chosen date and time forms', () {
    final f = DisplayFormat(
      datePref: DateFormatPref.monDayYear,
      clockPref: ClockPref.hour12,
    );
    expect(f.formatDateTime(sample), 'Aug 20, 2026 3:07 PM');
  });

  group('formatDateRange decides compaction once (#399)', () {
    final sep12 = DateTime(2026, 9, 12);
    final sep15 = DateTime(2026, 9, 15);
    final oct2 = DateTime(2026, 10, 2);
    final jan3 = DateTime(2027, 1, 3);

    test('a missing or same-day end is a single date', () {
      final f = DisplayFormat(datePref: DateFormatPref.us);
      expect(f.formatDateRange(sep12, null), '09/12/2026');
      expect(f.formatDateRange(sep12, DateTime(2026, 9, 12, 18)), '09/12/2026');
    });

    test('the prose patterns collapse a shared month and a shared year', () {
      final mdy = DisplayFormat(datePref: DateFormatPref.monDayYear);
      expect(mdy.formatDateRange(sep12, sep15), 'Sep 12–15, 2026');
      expect(mdy.formatDateRange(sep12, oct2), 'Sep 12 – Oct 2, 2026');
      expect(mdy.formatDateRange(sep12, jan3), 'Sep 12, 2026 – Jan 3, 2027');

      final dmy = DisplayFormat(datePref: DateFormatPref.dayMonYear);
      expect(dmy.formatDateRange(sep12, sep15), '12–15 Sep 2026');
      expect(dmy.formatDateRange(sep12, oct2), '12 Sep – 2 Oct 2026');
      expect(dmy.formatDateRange(sep12, jan3), '12 Sep 2026 – 3 Jan 2027');
    });

    test('the numeric patterns never compact — both ends in full', () {
      const numeric = {
        DateFormatPref.iso8601: '2026-09-12 – 2026-09-15',
        DateFormatPref.us: '09/12/2026 – 09/15/2026',
        DateFormatPref.uk: '12/09/2026 – 15/09/2026',
        DateFormatPref.europeanDot: '12.09.2026 – 15.09.2026',
        DateFormatPref.eastAsia: '2026/09/12 – 2026/09/15',
      };
      numeric.forEach((pref, expected) {
        expect(DisplayFormat(datePref: pref).formatDateRange(sep12, sep15), expected,
            reason: pref.name);
      });
    });

    test('an inherited platform pattern is opaque, so both ends go through it', () {
      final f = DisplayFormat(platformDateFormatter: (d) => 'P${d.day}');
      expect(f.formatDateRange(sep12, sep15), 'P12 – P15');
      // and with no platform answer, ISO on both ends
      expect(const DisplayFormat().formatDateRange(sep12, sep15),
          '2026-09-12 – 2026-09-15');
    });
  });

  group('withPlatform attaches the device answers and nothing else (#399)', () {
    test('an inherit pair picks up the closures; explicit prefs ignore them', () {
      const stored = DisplayFormat(
        temperatureUnit: TemperatureUnit.fahrenheit,
        useMiles: true,
      );
      final resolved = stored.withPlatform(
        dateFormatter: (d) => 'DEVICE-${d.day}',
        uses24Hour: false,
      );
      expect(resolved.formatDate(sample), 'DEVICE-20');
      expect(resolved.formatTime(sample), '3:07 PM');
      expect(resolved.dateIsInherited, isTrue);
      // preferences carried through untouched
      expect(resolved.useMiles, isTrue);
      expect(resolved.temperatureUnit, TemperatureUnit.fahrenheit);

      final explicit = DisplayFormat(
        datePref: DateFormatPref.iso8601,
        clockPref: ClockPref.hour24,
      ).withPlatform(dateFormatter: (d) => 'DEVICE', uses24Hour: false);
      expect(explicit.formatDate(sample), '2026-08-20');
      expect(explicit.formatTime(sample), '15:07');
    });
  });
}
