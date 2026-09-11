// K10 / FR86, FR95, FR101 (issue #116) — one credit line for one licensed
// data source, as shown on the About surface and carried into exports and
// print.
//
// The service derives the full list from the loaded layer set at
// `GET /about` / `GET /attribution` (attribution is never hardcoded — ARCH
// §12.2). But elevation, the basemap, the routing graph, and `/geocode`
// always ship with the home region, so their four credits also exist here
// as a constant: a surface with no sidecar reachable (a fresh Web guest, a
// reading view) must still meet the licence obligation. The graph's credit
// (issue #269) is a separate ODbL obligation from the basemap's, not a free
// ride under its line — hence the distinct "Routing data: …" text rather
// than a repeat of the basemap's bare credit string. Nominatim's credit
// (issue #296) is a third, unrelated to either — its own usage policy, its
// own surface (`/geocode` results). `test_web_about.py` pins the canonical
// strings on the Python side; `attribution_line_test.dart` pins them here,
// and `settings_about_test.dart` pins that the fallback renders them.
library;

/// One line of credit: which source, under which licence, with the exact
/// attribution string the licence requires.
class AttributionLine {
  const AttributionLine({
    required this.layer,
    required this.licence,
    required this.attribution,
    this.termsUrl = '',
    this.builtin = false,
  });

  final String layer;
  final String licence;
  final String attribution;
  final String termsUrl;
  final bool builtin;

  factory AttributionLine.fromJson(Map<String, dynamic> json) => AttributionLine(
        layer: json['layer'] as String,
        licence: json['licence'] as String? ?? '',
        attribution: json['attribution'] as String? ?? '',
        termsUrl: json['terms_url'] as String? ?? '',
        builtin: json['builtin'] as bool? ?? false,
      );
}

/// Elevation's CC BY (FR86), the basemap's ODbL (FR95), the routing
/// graph's own ODbL (issue #269), and Nominatim's own display-attribution
/// credit (issue #296) — **separate obligations**, always owed because all
/// four ship with the home region (the graph is one of the three
/// capability gates that always starts, ARCH B1; `/geocode` is reachable
/// from every trip-creation and search flow). The offline/lightest-surface
/// fallback for the dynamic list from `GET /about`.
const List<AttributionLine> aboutStaticAttribution = [
  AttributionLine(
    layer: 'elevation',
    licence: 'CC-BY-4.0',
    attribution: 'Elevation: GEDTM30 (Global Ensemble Digital Terrain Model, '
        '30 m) © OpenTopography and contributors — CC BY 4.0',
    termsUrl: 'https://creativecommons.org/licenses/by/4.0/',
    builtin: true,
  ),
  AttributionLine(
    layer: 'basemap',
    licence: 'ODbL-1.0',
    attribution: '© OpenStreetMap contributors',
    termsUrl: 'https://www.openstreetmap.org/copyright',
    builtin: true,
  ),
  AttributionLine(
    layer: 'graph',
    licence: 'ODbL-1.0',
    attribution: 'Routing data: © OpenStreetMap contributors',
    termsUrl: 'https://www.openstreetmap.org/copyright',
    builtin: true,
  ),
  AttributionLine(
    layer: 'geocode',
    licence: 'ODbL-1.0',
    attribution: 'Search by Nominatim — © OpenStreetMap contributors',
    termsUrl: 'https://operations.osmfoundation.org/policies/nominatim/',
    builtin: true,
  ),
];

/// The exact text `NOMINATIM_ATTRIBUTION`/`nominatim_attribution()` carry on
/// the Python side (issue #296) — the inline copy a geocode-results surface
/// shows near the results themselves, per the Nominatim usage policy's own
/// example ("Search by Nominatim ... where reasonably practical"), rather
/// than relying on the About surface alone to satisfy "reasonably
/// practical". Kept as a standalone constant (not only the list entry above)
/// so a search widget can render it without threading the whole static list
/// through.
const String nominatimSearchAttribution =
    'Search by Nominatim — © OpenStreetMap contributors';

/// Parse the `attributions` list from a `GET /about` payload, falling back to
/// [aboutStaticAttribution] when it is absent or malformed.
List<AttributionLine> attributionLinesFrom(Object? aboutAttributions) {
  if (aboutAttributions is List && aboutAttributions.isNotEmpty) {
    try {
      return aboutAttributions
          .map((e) => AttributionLine.fromJson(e as Map<String, dynamic>))
          .toList(growable: false);
    } catch (_) {
      // Malformed — fall through to the bundled copy.
    }
  }
  return aboutStaticAttribution;
}
