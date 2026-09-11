/// Water-carry distance — Story C9 (PRD FR25), the client half of
/// `plotlines_core.trips.water_carry`.
///
/// FR25's AC: "itineraries show water-carry distance between sources." A
/// water source is a [RoleKind.provision] role carrying
/// [ProvisionDetail.water] (`anchor.dart`) — a promoted anchor, not a placed
/// [Node] (contrast C5's `node.amenities`, a lighter-weight waypoint tag with
/// no reveal policy).
///
/// There is no routing-layer link from an anchor to a position on the route
/// yet (FR8a's `via_anchors` — unbuilt). So this projects each water anchor's
/// own coordinate onto the day's already-solved geometry via [snapToPath] —
/// the same nearest-point machinery the Route tab's alternate-fork gesture
/// uses — rather than waiting on that story. A source too far from the route
/// to be "on it" is reported (`.offRoute`), never silently dropped. Mirrors
/// `water_carry.py` field for field; a drift between the two is a bug here.
library;

import 'alternate_draft.dart' show snapToPath;
import 'anchor.dart';
import 'day.dart';
import 'json_utils.dart';
import 'trip.dart';

/// How far a water anchor's own coordinate may sit from the day's solved
/// line and still count as "on this day's route." No measured basis yet —
/// generous enough to catch a spigot set back from the trailhead, narrow
/// enough that a town's water tower a kilometre off-corridor reports as
/// off-route rather than folding into a gap that never happened on the
/// ground. Mirrors `water_carry.SNAP_TOLERANCE_M`.
const double waterCarrySnapToleranceM = 300.0;

/// One water-source anchor: FR25's "tagged potable or filter-required,"
/// carried alongside the id/title an itinerary needs to place it.
class WaterCarrySource {
  const WaterCarrySource({
    required this.anchorId,
    required this.roleId,
    required this.coord,
    required this.potable,
    this.title,
  });

  final String anchorId;
  final String roleId;
  final Coord coord;
  final bool potable;
  final String? title;
}

/// Every water-source anchor on [trip], in `Trip.anchors` order. A provision
/// role with no [Role.provision] set, or one with no `water`, contributes
/// nothing here.
List<WaterCarrySource> collectWaterSources(Trip trip) {
  final out = <WaterCarrySource>[];
  for (final anchor in trip.anchors) {
    for (final role in anchor.roles) {
      final water = role.provision?.water;
      if (role.kind != RoleKind.provision || water == null) continue;
      out.add(WaterCarrySource(
        anchorId: anchor.id,
        roleId: role.id,
        coord: anchor.roleGeometry(role),
        potable: water.potable,
        title: anchor.title,
      ));
    }
  }
  return out;
}

/// The gap between two consecutive water sources along a day's route.
class WaterCarryLeg {
  const WaterCarryLeg({
    required this.fromAnchorId,
    required this.toAnchorId,
    required this.distanceM,
    this.fromTitle,
    this.toTitle,
  });

  final String fromAnchorId;
  final String toAnchorId;
  final double distanceM;
  final String? fromTitle;
  final String? toTitle;
}

/// FR25 — one day's water-carry picture: the ordered legs between
/// consecutive on-route sources, plus any water source that could not be
/// placed on this day's route ([waterCarrySnapToleranceM]) — stated rather
/// than silently excluded from the gaps above.
class WaterCarryReport {
  const WaterCarryReport({
    required this.dayId,
    required this.dayIndex,
    this.legs = const [],
    this.offRoute = const [],
  });

  final String dayId;
  final int dayIndex;
  final List<WaterCarryLeg> legs;
  final List<WaterCarrySource> offRoute;
}

/// The day's segments concatenated into one polyline in segment order,
/// de-duplicating a shared vertex at a segment boundary — the same "one day,
/// one line" shape a day's cue sheet already assumes. `null` when the day
/// has no solved geometry to project against (an un-solved or rest day).
List<Coord>? _dayPath(Day day) {
  final coords = <Coord>[];
  for (final segment in day.segments) {
    final pts = segment.geometry?.coordinates;
    if (pts == null || pts.length < 2) continue;
    final startIndex = coords.isNotEmpty && _sameCoord(pts.first, coords.last) ? 1 : 0;
    coords.addAll(pts.sublist(startIndex));
  }
  return coords.length < 2 ? null : coords;
}

bool _sameCoord(Coord a, Coord b) => a[0] == b[0] && a[1] == b[1];

/// FR25 — this day's water-carry legs: every [waterSources] anchor projected
/// onto the day's route ([snapToPath]), kept when within
/// [waterCarrySnapToleranceM], ordered by distance along, and turned into the
/// gaps between consecutive ones. Sources too far from this day's route are
/// reported in [WaterCarryReport.offRoute] rather than silently skipped —
/// most days, that is every source belonging to a *different* day.
WaterCarryReport waterCarryForDay(Day day, List<WaterCarrySource> waterSources) {
  final path = _dayPath(day);
  if (path == null) {
    return WaterCarryReport(dayId: day.id, dayIndex: day.index, offRoute: waterSources);
  }

  final placed = <(double, WaterCarrySource)>[];
  final offRoute = <WaterCarrySource>[];
  for (final source in waterSources) {
    final snap = snapToPath(path, source.coord);
    if (snap != null && snap.offsetM <= waterCarrySnapToleranceM) {
      placed.add((snap.alongM, source));
    } else {
      offRoute.add(source);
    }
  }
  placed.sort((a, b) => a.$1.compareTo(b.$1));

  final legs = [
    for (var i = 0; i < placed.length - 1; i++)
      WaterCarryLeg(
        fromAnchorId: placed[i].$2.anchorId,
        toAnchorId: placed[i + 1].$2.anchorId,
        distanceM: placed[i + 1].$1 - placed[i].$1,
        fromTitle: placed[i].$2.title,
        toTitle: placed[i + 1].$2.title,
      ),
  ];
  return WaterCarryReport(dayId: day.id, dayIndex: day.index, legs: legs, offRoute: offRoute);
}

/// The trip-wide water-carry picture: one [WaterCarryReport] per day, built
/// from the single [collectWaterSources] traversal so every day reasons
/// about the same anchor set.
class TripWaterCarry {
  const TripWaterCarry({required this.waterSources, required this.byDay});

  final List<WaterCarrySource> waterSources;
  final List<WaterCarryReport> byDay;

  factory TripWaterCarry.fromTrip(Trip trip) {
    final sources = collectWaterSources(trip);
    return TripWaterCarry(
      waterSources: sources,
      byDay: [for (final day in trip.days) waterCarryForDay(day, sources)],
    );
  }
}
