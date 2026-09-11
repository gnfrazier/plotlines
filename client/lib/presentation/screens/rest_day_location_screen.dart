/// Issue #325 — the rest-day location picker, full-height, replacing the
/// 480×360 `TapToPickMap` dialog `logistics_tab.dart` used to open.
///
/// From the UX review (#271, `rest-day-need-a-search-by-address-not-usable.png`):
/// at 480×360 an Author could only guess at a pixel — no address search, no
/// view of what is nearby, no relationship to the route, no confirmation
/// beyond a bare coordinate on the day card. This screen is the fix, built
/// from pieces that already exist rather than a second implementation:
///
/// * **Full-height**, not a dialog card — a real screen ([showRestDayLocationScreen]
///   pushes a full-screen route), the same room the Route tab's map gets.
/// * **Browse** — [CandidateMap] (the Curation Workspace's own candidate
///   rendering, reused) shows the Author's live layer selection so a rest
///   day is chosen from what is actually there.
/// * **Search by address**, explicit-submit only (issue #249's Nominatim
///   policy forbids per-keystroke autocomplete — the field has no
///   `onChanged` wired to [geocode] at all, matching
///   `trip_location_prompt.dart`'s `_TripLocationDialog`), with Nominatim's
///   own display-attribution credit (issue #296) shown beside the results
///   it actually produced.
/// * **The offline buffer is the default extent** — [bufferM]
///   (`Trip.offlineBufferM`, C14/#51) around [routeLines] ("the finished
///   route") frames the map's initial view; a pick outside it earns a
///   non-blocking warning, never a refusal (every stage after display stays
///   skippable — an Author who knows the spot places it anyway).
/// * **Confirms a resolved place**, not a coordinate: [RestDayLocationChoice]
///   carries a [RestDayLocationChoice.label] wherever one was resolvable
///   (a candidate's title or the geocoded address), which is what
///   `logistics_tab.dart`'s day card shows in place of a bare coordinate
///   (`Day.locationLabel`, issue #325's schema addition). A raw map tap
///   still works — hand-placement is never blocked — but it honestly
///   carries no label, since nothing was resolved.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' show CameraFit, LatLngBounds;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../data/routing_client.dart' show GeocodeResult;
import '../../domain/attribution_line.dart' show nominatimSearchAttribution;
import '../../domain/domain.dart';
import '../map/candidate_map.dart';
import '../../state/trip_candidates_provider.dart';

/// What the Author chose: a coordinate and, where one was resolvable, the
/// place's name.
class RestDayLocationChoice {
  const RestDayLocationChoice({required this.coord, this.label});
  final Coord coord;
  final String? label;
}

/// Every segment's solved geometry across the whole trip — "the finished
/// route" the offline buffer wraps around, per FR35/C14 and this screen's
/// own doc comment. A day or segment with no geometry yet (unsolved, or a
/// rest day, which has none by definition) contributes nothing; a
/// brand-new trip with no segments at all contributes an empty list, which
/// every buffer/extent computation in [_RestDayLocationScreenState]
/// already treats as "no route to measure against".
List<List<Coord>> routeLinesOf(Trip trip) => [
      for (final day in trip.days)
        for (final segment in day.segments)
          if (segment.geometry != null && segment.geometry!.coordinates.length >= 2)
            segment.geometry!.coordinates,
    ];

/// Pushes the full-height picker and returns the Author's choice, or `null`
/// if they backed out without picking anything.
///
/// [routeLines] is every segment's geometry across the whole trip — "the
/// finished route" the offline buffer wraps around. [bufferM] is
/// `Trip.offlineBufferM`; when unset (the Author has not set one, or no
/// route exists yet) the map opens on its ordinary default view and nothing
/// is ever flagged as "outside" anything.
Future<RestDayLocationChoice?> showRestDayLocationScreen(
  BuildContext context, {
  Coord? initial,
  String? initialLabel,
  List<List<Coord>> routeLines = const [],
  double? bufferM,
  required Future<List<GeocodeResult>> Function(String query) geocode,
}) {
  return Navigator.of(context, rootNavigator: true).push<RestDayLocationChoice>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _RestDayLocationScreen(
        initial: initial,
        initialLabel: initialLabel,
        routeLines: routeLines,
        bufferM: bufferM,
        geocode: geocode,
      ),
    ),
  );
}

class _RestDayLocationScreen extends ConsumerStatefulWidget {
  const _RestDayLocationScreen({
    this.initial,
    this.initialLabel,
    required this.routeLines,
    this.bufferM,
    required this.geocode,
  });

  final Coord? initial;
  final String? initialLabel;
  final List<List<Coord>> routeLines;
  final double? bufferM;
  final Future<List<GeocodeResult>> Function(String query) geocode;

  @override
  ConsumerState<_RestDayLocationScreen> createState() => _RestDayLocationScreenState();
}

class _RestDayLocationScreenState extends ConsumerState<_RestDayLocationScreen> {
  Coord? _picked;
  String? _pickedLabel;
  final _searchController = TextEditingController();
  bool _searching = false;
  List<GeocodeResult> _results = const [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _picked = widget.initial;
    _pickedLabel = widget.initialLabel;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// The closest [_picked] comes to any segment of [_RestDayLocationScreen
  /// .routeLines], or `null` when there is nothing picked or no route to
  /// measure against.
  double? get _offsetFromRouteM {
    final picked = _picked;
    if (picked == null || widget.routeLines.isEmpty) return null;
    double? best;
    for (final line in widget.routeLines) {
      final snap = snapToPath(line, picked);
      if (snap == null) continue;
      if (best == null || snap.offsetM < best) best = snap.offsetM;
    }
    return best;
  }

  /// The AC's "outside it warns rather than blocks" — never true with no
  /// buffer set and no route to measure against (there is nothing to be
  /// outside of yet).
  bool get _outsideBuffer {
    final buffer = widget.bufferM;
    final offset = _offsetFromRouteM;
    if (buffer == null || offset == null) return false;
    return offset > buffer;
  }

  /// The buffer-around-the-route default extent. `null` (falls back to
  /// [CandidateMap]'s ordinary centering) when there is no route yet — a
  /// brand-new trip with no segments has nothing to buffer around.
  CameraFit? get _initialCameraFit {
    final points = <Coord>[for (final line in widget.routeLines) ...line];
    if (points.isEmpty) return null;

    var minLon = points.first[0], maxLon = points.first[0];
    var minLat = points.first[1], maxLat = points.first[1];
    for (final p in points) {
      minLon = math.min(minLon, p[0]);
      maxLon = math.max(maxLon, p[0]);
      minLat = math.min(minLat, p[1]);
      maxLat = math.max(maxLat, p[1]);
    }
    // Degrees-per-metre approximation, local to this bbox — plenty accurate
    // for framing a camera view, never used for the actual buffer check
    // above (that's real great-circle distance via `snapToPath`).
    final bufferM = widget.bufferM ?? 0;
    final avgLatRad = (minLat + maxLat) / 2 * math.pi / 180;
    final dLat = bufferM / 111320;
    final dLon = bufferM / (111320 * math.cos(avgLatRad).clamp(0.01, 1.0));

    return CameraFit.bounds(
      bounds: LatLngBounds(
        ll.LatLng(minLat - dLat, minLon - dLon),
        ll.LatLng(maxLat + dLat, maxLon + dLon),
      ),
      padding: const EdgeInsets.all(32),
    );
  }

  void _pick(Coord coord, {String? label}) {
    setState(() {
      _picked = coord;
      _pickedLabel = label;
      _results = const [];
      _error = null;
    });
  }

  Future<void> _search() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final results = await widget.geocode(query);
      if (!mounted) return;
      setState(() {
        _searching = false;
        _results = results;
        if (results.isEmpty) {
          _error = 'The geocoder is reachable and returned nothing. Check the '
              'spelling, or browse the map instead.';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _error = "Couldn't resolve that location: $e";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final candidates = ref.watch(tripCandidatesProvider).candidates;

    return Scaffold(
      appBar: AppBar(title: const Text('Set rest day location')),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                CandidateMap(
                  candidates: candidates,
                  route: widget.routeLines,
                  initialCameraFit: _initialCameraFit,
                  pickedCoord: _picked,
                  onCandidateTap: (candidate) => _pick(candidate.coord, label: candidate.title),
                  onMapTap: _pick,
                ),
                Positioned(
                  top: PlotSpacing.s3,
                  left: PlotSpacing.s3,
                  right: PlotSpacing.s3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_results.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: PlotSpacing.s2),
                          child: PlotCard(
                            padding: const EdgeInsets.symmetric(vertical: PlotSpacing.s1),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                for (final r in _results)
                                  PlotListTile(
                                    title: r.label,
                                    onTap: () => _pick(r.coord, label: r.label),
                                  ),
                                // Issue #296 — Nominatim's display-attribution
                                // obligation, next to the results it produced.
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: PlotSpacing.s3, vertical: PlotSpacing.s1),
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text(nominatimSearchAttribution,
                                        style: PlotTypography.small(c.textMuted)),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: PlotSpacing.s3),
                        decoration: BoxDecoration(
                          color: c.surfaceCard.withValues(alpha: 0.96),
                          border: Border.all(color: c.border),
                          borderRadius: PlotRadii.controlShape,
                          boxShadow: [
                            BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 8),
                          ],
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.search, size: 18, color: c.textSecondary),
                            const SizedBox(width: PlotSpacing.s2),
                            Expanded(
                              child: TextField(
                                controller: _searchController,
                                decoration: const InputDecoration(
                                  hintText: 'Search an address, hotel, or campground',
                                  isDense: true,
                                  border: InputBorder.none,
                                ),
                                onSubmitted: (_) => _search(),
                              ),
                            ),
                            if (_searching)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: PlotSpacing.s2),
                                child: SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2)),
                              )
                            else
                              IconButton(
                                icon: const Icon(Icons.arrow_forward, size: 18),
                                onPressed: _search,
                              ),
                          ],
                        ),
                      ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: PlotSpacing.s2),
                          child: PlotCard(
                            padding: const EdgeInsets.all(PlotSpacing.s2),
                            child: Text(_error!, style: PlotTypography.small(c.danger)),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          _ConfirmBar(
            coord: _picked,
            label: _pickedLabel,
            offsetFromRouteM: _offsetFromRouteM,
            outsideBuffer: _outsideBuffer,
            onConfirm: _picked == null
                ? null
                : () => Navigator.pop(
                      context,
                      RestDayLocationChoice(coord: _picked!, label: _pickedLabel),
                    ),
            onCancel: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }
}

/// The AC's "confirm what was chosen, not the coordinate" footer: a
/// resolved place's name when there is one, the bare coordinates (honestly
/// unresolved) when there is not, and the non-blocking outside-buffer
/// warning.
class _ConfirmBar extends StatelessWidget {
  const _ConfirmBar({
    required this.coord,
    required this.label,
    required this.offsetFromRouteM,
    required this.outsideBuffer,
    required this.onConfirm,
    required this.onCancel,
  });

  final Coord? coord;
  final String? label;
  final double? offsetFromRouteM;
  final bool outsideBuffer;
  final VoidCallback? onConfirm;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return Container(
      padding: const EdgeInsets.all(PlotSpacing.s4),
      decoration: BoxDecoration(
        color: c.surfaceCard,
        border: Border(top: BorderSide(color: c.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (outsideBuffer)
            Container(
              margin: const EdgeInsets.only(bottom: PlotSpacing.s2),
              padding: const EdgeInsets.symmetric(
                  horizontal: PlotSpacing.s3, vertical: PlotSpacing.s2),
              color: c.warning.withValues(alpha: 0.16),
              child: Row(
                children: [
                  // Gold (`c.warning`) is a fill/marker color, never text
                  // (brand guardrail) — the icon carries it, the message
                  // stays `textPrimary` on the tinted ground.
                  Icon(Icons.warning_amber_rounded, size: 16, color: c.warning),
                  const SizedBox(width: PlotSpacing.s2),
                  Expanded(
                    child: Text(
                      'This is ${(offsetFromRouteM! / 1000).toStringAsFixed(1)} km outside '
                      "the trip's offline buffer — it can still be chosen, but Characters "
                      "won't have downloaded map data this far out.",
                      style: PlotTypography.small(c.textPrimary),
                    ),
                  ),
                ],
              ),
            ),
          Row(
            children: [
              Expanded(
                child: coord == null
                    ? Text('Tap the map, or search above, to place this day',
                        style: PlotTypography.body(c.textMuted))
                    : Text(
                        label ?? '${coord![1].toStringAsFixed(5)}, ${coord![0].toStringAsFixed(5)}',
                        style: PlotTypography.body(c.textPrimary),
                        overflow: TextOverflow.ellipsis,
                      ),
              ),
              const SizedBox(width: PlotSpacing.s3),
              PlotButton(label: 'Cancel', variant: PlotButtonVariant.ghost, onPressed: onCancel),
              const SizedBox(width: PlotSpacing.s2),
              PlotButton(label: 'Confirm', onPressed: onConfirm),
            ],
          ),
        ],
      ),
    );
  }
}
