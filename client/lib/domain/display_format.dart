/// K5 / FR79 — the **render-time** half of display & measurement preferences.
///
/// Every value here is a transform applied when a [DateTime], a temperature,
/// or a distance is about to be *shown*. Nothing in this file is ever stored,
/// exported, put in a filename, or fed to a content digest: ISO 8601 (and SI
/// metres / canonical °C) remain the sole persisted form (ARCH D49). A
/// [DisplayFormat] is cheap to build and is expected to be reconstructed on
/// each render so that `inherit` picks up the device's *current* platform
/// answer rather than one frozen at install.
library;

/// The seven date patterns FR79 offers in the override menu, plus `inherit`.
///
/// `inherit` is **not** "pick one of these for me" — it defers to the
/// platform's own locale pattern, which may not be any of the seven, and is
/// resolved by [DisplayFormat] at render time from the closures the caller
/// supplies. The stored value is always either `inherit` or one of the seven.
enum DateFormatPref {
  /// Resolve from the device's locale at render time (default).
  inherit,

  /// `2026-08-20` — ISO 8601. Also the stored/exported/filename form.
  iso8601,

  /// `08/20/2026` — United States.
  us,

  /// `20/08/2026` — UK, Europe, India, Australia, Latin America.
  uk,

  /// `20.08.2026` — Germany, Central/Eastern Europe, the Nordics.
  europeanDot,

  /// `2026/08/20` — East Asia.
  eastAsia,

  /// `20 Aug 2026`.
  dayMonYear,

  /// `Aug 20, 2026`.
  monDayYear,
}

/// 12- vs 24-hour clock, plus `inherit` (defer to the platform clock).
enum ClockPref { inherit, hour12, hour24 }

/// Whose temperature scale the reader sees. A render-time transform — the
/// stored/telemetry form is always canonical Celsius.
enum TemperatureUnit { fahrenheit, celsius }

const List<String> _monthAbbr = <String>[
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _pad2(int n) => n.toString().padLeft(2, '0');
String _pad4(int n) => n.toString().padLeft(4, '0');

/// A resolved bundle of display transforms. Build one per render from the
/// user's stored preferences ([DateFormatPref] / [ClockPref] / units) and the
/// platform's *current* answers for anything left on `inherit`.
class DisplayFormat {
  const DisplayFormat({
    this.datePref = DateFormatPref.inherit,
    this.clockPref = ClockPref.inherit,
    this.temperatureUnit = TemperatureUnit.celsius,
    this.useMiles = false,
    this.platformDateFormatter,
    this.platformUses24Hour,
  });

  /// Stored date preference (`inherit` or one of the seven).
  final DateFormatPref datePref;

  /// Stored clock preference (`inherit`, `hour12`, or `hour24`).
  final ClockPref clockPref;

  final TemperatureUnit temperatureUnit;

  /// Distance/length: miles & feet when true, kilometres & metres when false.
  final bool useMiles;

  /// The device's own locale date pattern, as a formatter, consulted only
  /// when [datePref] is `inherit`. Supplied by the caller at render time
  /// (e.g. backed by `MaterialLocalizations`/`intl`). When null, `inherit`
  /// falls back to ISO 8601 — unambiguous and safe.
  final String Function(DateTime)? platformDateFormatter;

  /// The device's own 12/24-hour clock preference, consulted only when
  /// [clockPref] is `inherit`. When null, `inherit` falls back to 24-hour.
  final bool? platformUses24Hour;

  /// True when the date shown is the platform's own pattern rather than one
  /// of the seven — i.e. `inherit` with a platform formatter available.
  bool get dateIsInherited =>
      datePref == DateFormatPref.inherit && platformDateFormatter != null;

  /// Renders [d] (its calendar date) per [datePref]. Never mutates or stores.
  String formatDate(DateTime d) {
    final y = _pad4(d.year);
    final m = _pad2(d.month);
    final day = _pad2(d.day);
    final mon = _monthAbbr[d.month - 1];
    switch (datePref) {
      case DateFormatPref.inherit:
        final fmt = platformDateFormatter;
        return fmt != null ? fmt(d) : '$y-$m-$day';
      case DateFormatPref.iso8601:
        return '$y-$m-$day';
      case DateFormatPref.us:
        return '$m/$day/$y';
      case DateFormatPref.uk:
        return '$day/$m/$y';
      case DateFormatPref.europeanDot:
        return '$day.$m.$y';
      case DateFormatPref.eastAsia:
        return '$y/$m/$day';
      case DateFormatPref.dayMonYear:
        return '${d.day} $mon $y';
      case DateFormatPref.monDayYear:
        return '$mon ${d.day}, $y';
    }
  }

  /// Renders the wall-clock time of [d] per [clockPref].
  String formatTime(DateTime d) {
    final use24 = switch (clockPref) {
      ClockPref.hour24 => true,
      ClockPref.hour12 => false,
      ClockPref.inherit => platformUses24Hour ?? true,
    };
    if (use24) return '${_pad2(d.hour)}:${_pad2(d.minute)}';
    final period = d.hour < 12 ? 'AM' : 'PM';
    var h = d.hour % 12;
    if (h == 0) h = 12;
    return '$h:${_pad2(d.minute)} $period';
  }

  /// `<date> <time>` in the reader's chosen forms.
  String formatDateTime(DateTime d) => '${formatDate(d)} ${formatTime(d)}';

  /// Canonical Celsius → the reader's scale, as a number (no rounding).
  double temperatureValue(double celsius) =>
      temperatureUnit == TemperatureUnit.fahrenheit
          ? celsius * 9 / 5 + 32
          : celsius;

  /// Canonical Celsius → a rounded, degree-marked string in the reader's
  /// scale, e.g. `21°C` / `70°F`.
  String formatTemperature(double celsius) {
    final suffix = temperatureUnit == TemperatureUnit.fahrenheit ? '°F' : '°C';
    return '${temperatureValue(celsius).round()}$suffix';
  }

  // --- Distance & length (K5 / FR79 / issue #312) ------------------------
  //
  // Three sub-units, decided here once rather than at each call site:
  //
  //  * route / day distance   → miles or kilometres, one decimal
  //  * short lengths          → feet or metres, whole units
  //    (a narration trigger radius, a between-passages gap, a snap tolerance)
  //  * altitude / climb       → feet or metres, whole units — never yards,
  //    and never metres-under-imperial
  //
  // Every method is canonical SI metres in, a display string (or a bare
  // display number) out. Nothing here is ever stored, exported, or digested
  // — SI metres remain the sole persisted form (ARCH D49). Parsing back from
  // an Author-typed field is [parseDistanceToMetres], so a value typed in
  // miles round-trips to metres before it reaches the payload.

  static const double _metresPerMile = 1609.344;
  static const double _feetPerMetre = 3.28084;

  /// `mi` under imperial, `km` under metric — for a unit-aware field label
  /// or suffix (`Target distance (km)` → `Target distance (mi)`).
  String get distanceUnitLabel => useMiles ? 'mi' : 'km';

  /// `ft` under imperial, `m` under metric — for short lengths and altitude.
  String get smallLengthUnitLabel => useMiles ? 'ft' : 'm';

  /// Canonical metres → the reader's route/day-distance unit, as a number
  /// (no rounding, no label).
  double distanceValue(double metres) =>
      useMiles ? metres / _metresPerMile : metres / 1000;

  /// Canonical metres → a route/day distance in the reader's unit, e.g.
  /// `17.8 km` / `11.1 mi`. One decimal by default.
  String formatDistance(double metres, {int fractionDigits = 1}) =>
      '${distanceValue(metres).toStringAsFixed(fractionDigits)} $distanceUnitLabel';

  /// Canonical metres → a bare route/day-distance number in the reader's
  /// unit, no label — for pre-filling a text field whose unit is shown
  /// separately.
  String distanceInputValue(double metres, {int fractionDigits = 1}) =>
      distanceValue(metres).toStringAsFixed(fractionDigits);

  /// Canonical metres → the reader's short-length unit (feet / metres), as a
  /// number.
  double smallLengthValue(double metres) =>
      useMiles ? metres * _feetPerMetre : metres;

  /// Canonical metres → a short length in the reader's unit, e.g. `120 ft` /
  /// `37 m`. Whole units by default.
  String formatSmallLength(double metres, {int fractionDigits = 0}) =>
      '${smallLengthValue(metres).toStringAsFixed(fractionDigits)} $smallLengthUnitLabel';

  /// Canonical metres of altitude / climb → the reader's unit (feet /
  /// metres), as a number. Distinct from [smallLengthValue] only in intent —
  /// altitude is never yards and never miles/km.
  double elevationValue(double metres) =>
      useMiles ? metres * _feetPerMetre : metres;

  /// Canonical metres of altitude / climb → a string in the reader's unit,
  /// e.g. `1200 ft` / `366 m`. Whole units by default; callers add any `↑`
  /// or `+` marker themselves.
  String formatElevation(double metres, {int fractionDigits = 0}) =>
      '${elevationValue(metres).toStringAsFixed(fractionDigits)} $smallLengthUnitLabel';

  /// An Author-typed route/day distance in the active unit → canonical
  /// metres, so the value reaching the payload is always SI. Returns null
  /// when [text] is not a number.
  double? parseDistanceToMetres(String text) {
    final v = double.tryParse(text.trim());
    if (v == null) return null;
    return useMiles ? v * _metresPerMile : v * 1000;
  }

  /// An Author-typed short length in the active unit (feet / metres) →
  /// canonical metres. The inverse of [smallLengthValue]; returns null when
  /// [text] is not a number.
  double? parseSmallLengthToMetres(String text) {
    final v = double.tryParse(text.trim());
    if (v == null) return null;
    return useMiles ? v / _feetPerMetre : v;
  }
}
