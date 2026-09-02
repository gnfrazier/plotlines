// K10 / FR95 (issue #230 C1) — the basemap credit, on the map.
//
// ODbL §4.3 requires the notice to travel with the produced work, and the
// mockups put it on the map frame itself (`Flow 1 - Trip initiation.dc.html`
// §01/§04). It existed only in Preferences → DATA & ATTRIBUTION, which is a
// preferences pane, not the surface the data is on: a screenshot of the map
// carried no credit at all. This is the one widget every map surface
// composes so a new map screen cannot ship without it.
//
// The *complete* credit list is still derived from the loaded layer set at
// `GET /attribution` (ARCH §12.2) and shown in full on the About pane. This
// line is the basemap's obligation only, which is why it can be a constant:
// the basemap always ships with the home region, so it is always owed, and
// it must render with no sidecar reachable.
library;

import 'package:flutter/material.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

/// The basemap credit line, sized and placed for a map corner.
class MapAttribution extends StatelessWidget {
  const MapAttribution({super.key});

  /// The exact string the licences require. Protomaps builds the vector
  /// tiles; the data underneath them is OpenStreetMap's, under ODbL.
  static const String line = '© OpenStreetMap contributors (ODbL) · Protomaps';

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.surfaceCard.withValues(alpha: 0.82),
        borderRadius: const BorderRadius.all(PlotRadii.sm),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: PlotSpacing.s2, vertical: 3),
        child: Text(
          line,
          style: PlotTypography.data(c.textMuted).copyWith(fontSize: 11, letterSpacing: 0.02),
        ),
      ),
    );
  }
}
