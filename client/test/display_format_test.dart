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

  test('formatDateTime composes the chosen date and time forms', () {
    final f = DisplayFormat(
      datePref: DateFormatPref.monDayYear,
      clockPref: ClockPref.hour12,
    );
    expect(f.formatDateTime(sample), 'Aug 20, 2026 3:07 PM');
  });
}
