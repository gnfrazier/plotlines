/// Issue #563 — a day's start time, stored as a UTC instant beside the IANA
/// zone the Author declared it in (`$defs/day.start_at` / `start_timezone`,
/// the `scheduled_window` convention). This file is the one place the two
/// are converted to and from a wall clock in that zone; nothing else in the
/// client needs zone rules.
library;

import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'day.dart';
import 'trip.dart';

bool _loaded = false;

void _ensureZones() {
  if (_loaded) return;
  tzdata.initializeTimeZones();
  _loaded = true;
}

/// Every IANA zone name the client knows, sorted — what the start-time
/// picker offers.
List<String> knownTimeZones() {
  _ensureZones();
  return tz.timeZoneDatabase.locations.keys.toList()..sort();
}

bool isKnownTimeZone(String name) {
  _ensureZones();
  return tz.timeZoneDatabase.locations.containsKey(name);
}

/// [date] (`yyyy-MM-dd`) at [hour]:[minute] on [zone]'s wall clock, as the
/// stored UTC stamp (`2026-08-28T13:00:00Z`).
String startAtFromLocal(String date, int hour, int minute, String zone) {
  _ensureZones();
  final day = DateTime.parse(date);
  final local = tz.TZDateTime(tz.getLocation(zone), day.year, day.month, day.day, hour, minute);
  return utcStamp(local.toUtc());
}

/// A stored UTC stamp read back on [zone]'s wall clock. The result's
/// `hour` / `minute` / `day` are that zone's, so `DisplayFormat` renders it
/// as the Author declared it. Null when either input does not parse.
DateTime? wallClockIn(String utcStamp, String zone) {
  final parsed = DateTime.tryParse(utcStamp);
  if (parsed == null || !isKnownTimeZone(zone)) return null;
  return tz.TZDateTime.from(parsed.toUtc(), tz.getLocation(zone));
}

/// `build_dashboard`'s stamp shape: whole seconds, `Z`.
String utcStamp(DateTime instant) {
  final u = instant.toUtc();
  String p2(int v) => v.toString().padLeft(2, '0');
  return '${u.year.toString().padLeft(4, '0')}-${p2(u.month)}-${p2(u.day)}'
      'T${p2(u.hour)}:${p2(u.minute)}:${p2(u.second)}Z';
}

/// The zone a new start time defaults to: another day of [trip] that already
/// has one (a trip usually stays in one zone), else the zone this machine is
/// in, matched on its current offset and abbreviation, else `UTC`. Only a
/// default — the Author can change it.
String defaultStartZone(Trip trip, {DateTime? now}) {
  for (final d in trip.days) {
    final zone = d.startTimezone;
    if (zone != null && isKnownTimeZone(zone)) return zone;
  }
  return machineTimeZone(now: now);
}

/// Best guess at this machine's IANA zone. `dart:core` only exposes an
/// offset and an abbreviation (`EDT`), so this picks a zone that matches
/// both now, preferring the common ones a planner is likely in.
String machineTimeZone({DateTime? now}) {
  _ensureZones();
  final at = now ?? DateTime.now();
  final offset = at.timeZoneOffset;
  final abbreviation = at.timeZoneName;
  bool matches(tz.Location loc, {bool byName = true}) {
    final zone = loc.timeZone(at.toUtc().millisecondsSinceEpoch);
    return zone.offset == offset &&
        (!byName || zone.abbreviation == abbreviation);
  }

  for (final name in _preferredZones) {
    final loc = tz.timeZoneDatabase.locations[name];
    if (loc != null && matches(loc)) return name;
  }
  for (final name in knownTimeZones()) {
    if (matches(tz.timeZoneDatabase.locations[name]!)) return name;
  }
  for (final name in _preferredZones) {
    final loc = tz.timeZoneDatabase.locations[name];
    if (loc != null && matches(loc, byName: false)) return name;
  }
  return 'UTC';
}

/// A tie-break, not a rule: the rule is "any zone whose offset and
/// abbreviation match this machine's right now". Several always do
/// (`America/Detroit` and `America/New_York`), so this seed set only says
/// which of equals to offer first. A zone not listed is still found by the
/// full scan in [machineTimeZone].
const _preferredZones = [
  'America/New_York', 'America/Chicago', 'America/Denver', 'America/Phoenix',
  'America/Los_Angeles', 'America/Anchorage', 'Pacific/Honolulu', 'America/Halifax',
  'America/St_Johns', 'Europe/London', 'Europe/Paris', 'Europe/Berlin', 'Europe/Helsinki',
  'Asia/Tokyo', 'Australia/Sydney', 'Pacific/Auckland',
];

/// FR16b / O4 — each day's time at stations: the expected durations of the
/// station activities whose role is attached to that day (`Role.dayId`).
/// `dashboard.station_hold_s` over the day's anchors; a station with no
/// duration is a stop of unknown length and adds nothing. Only days with at
/// least one timed station appear.
Map<String, double> dayStationHoldS(Trip trip) {
  final holds = <String, double>{};
  for (final anchor in trip.anchors) {
    for (final role in anchor.roles) {
      final dayId = role.dayId;
      final seconds = role.activity?.durationS;
      if (dayId == null || seconds == null) continue;
      holds.update(dayId, (v) => v + seconds, ifAbsent: () => seconds);
    }
  }
  return holds;
}

/// A day's start, ready to send or show — null unless both halves are set.
({String startAt, String zone})? dayStart(Day day) {
  final at = day.startAt, zone = day.startTimezone;
  if (at == null || zone == null) return null;
  return (startAt: at, zone: zone);
}
