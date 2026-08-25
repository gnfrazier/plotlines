// A10 (PRD FR96) — trip creation prompts for a single location every time,
// prefilled with the last-used value and freely editable. Its only job is
// to center the map: it never becomes the trip's bbox by inference, radius,
// or accepted default (the Author draws that separately, N1/FR120).
//
// Replaces the v1.0 first-run dialog, which gated trip creation once ever
// and framed itself as kicking off a 100 km-radius download — both wrong
// under the amended FR96 (no first-run prompt, no eager download of any
// kind, and the location prompt fires on every trip creation, not once).
library;

import 'package:flutter/material.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../data/routing_client.dart';
import '../../domain/home_region.dart';

/// What the Author chose. [center] is null when they chose the shipped home
/// region — a legitimate, non-eager choice, not a failure to resolve one.
class TripLocationChoice {
  const TripLocationChoice({required this.label, this.center, this.bbox});
  final String label;
  final LatLon? center;

  /// Nominatim's bounding geometry for [center] (issue #154), `[west,
  /// south, east, north]` — lets the trip-area draw map frame itself on a
  /// real extent instead of an arbitrary zoom. **Never the trip bbox**
  /// (FR96): this only ever feeds `TripAreaMap.initialCameraFit`, never
  /// `tripBboxProvider`.
  final List<double>? bbox;
}

/// Returns the Author's choice, or null if they cancelled trip creation
/// entirely (distinct from choosing the home region).
Future<TripLocationChoice?> showTripLocationPrompt(
  BuildContext context, {
  required String prefill,
  required Future<List<GeocodeResult>> Function(String query) geocode,
}) {
  return showDialog<TripLocationChoice>(
    context: context,
    builder: (context) => _TripLocationDialog(prefill: prefill, geocode: geocode),
  );
}

class _TripLocationDialog extends StatefulWidget {
  const _TripLocationDialog({required this.prefill, required this.geocode});
  final String prefill;
  final Future<List<GeocodeResult>> Function(String query) geocode;

  @override
  State<_TripLocationDialog> createState() => _TripLocationDialogState();
}

class _TripLocationDialogState extends State<_TripLocationDialog> {
  late final _controller = TextEditingController(text: widget.prefill);
  bool _resolving = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return AlertDialog(
      title: Text('Where are we going?', style: PlotTypography.title(c.textPrimary)),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "This only centers the map so you can draw the trip's area — "
              'it never becomes that area by itself.',
              style: PlotTypography.body(c.textSecondary),
            ),
            const SizedBox(height: PlotSpacing.s4),
            TextField(
              controller: _controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'City + state, zip code, or country + city',
                hintText: 'e.g. Boulder, CO',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _continue(),
            ),
            if (_error != null) ...[
              const SizedBox(height: PlotSpacing.s2),
              Text(_error!, style: PlotTypography.small(c.danger)),
            ],
          ],
        ),
      ),
      actions: [
        PlotButton(
          label: 'Cancel',
          variant: PlotButtonVariant.ghost,
          onPressed: _resolving ? null : () => Navigator.pop(context),
        ),
        PlotButton(
          label: 'Use ${HomeRegion.label}',
          variant: PlotButtonVariant.ghost,
          onPressed: _resolving
              ? null
              : () => Navigator.pop(
                    context,
                    const TripLocationChoice(label: HomeRegion.label),
                  ),
        ),
        PlotButton(
          label: _resolving ? 'Finding…' : 'Continue',
          onPressed: _resolving ? null : _continue,
        ),
      ],
    );
  }

  Future<void> _continue() async {
    final query = _controller.text.trim();
    if (query.isEmpty) {
      Navigator.pop(context, const TripLocationChoice(label: HomeRegion.label));
      return;
    }
    setState(() {
      _resolving = true;
      _error = null;
    });
    try {
      final results = await widget.geocode(query);
      if (!mounted) return;
      if (results.isEmpty) {
        setState(() {
          _resolving = false;
          _error = 'The geocoder is reachable and returned nothing. Check the '
              'spelling, or continue and place the map yourself — the '
              'location only centers the view.';
        });
        return;
      }
      Navigator.pop(context, TripLocationChoice(
        label: query,
        center: results.first.coord,
        bbox: results.first.bbox,
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _resolving = false;
        _error = "Couldn't resolve that location: $e";
      });
    }
  }
}
