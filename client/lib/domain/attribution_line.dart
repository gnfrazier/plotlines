// K10 / FR86, FR95, FR101 (issue #116) — one credit line for one licensed
// data source, as shown on the About surface and carried into exports and
// print.
//
// The service derives the full list from the loaded layer set at
// `GET /about` / `GET /attribution` (attribution is never hardcoded — ARCH
// §12.2). But elevation, the basemap, and the routing graph always ship with
// the home region, so their three credits also exist here as a constant: a
// surface with no sidecar reachable (a fresh Web guest, a reading view) must
// still meet the licence obligation. The graph's credit (issue #269) is a
// separate ODbL obligation from the basemap's, not a free ride under its
// line — hence the distinct "Routing data: …" text rather than a repeat of
// the basemap's bare credit string. `test_web_about.py` pins the canonical
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

/// Elevation's CC BY (FR86), the basemap's ODbL (FR95), and the routing
/// graph's own ODbL (issue #269) — **separate obligations**, always owed
/// because all three ship with the home region (the graph is one of the
/// three capability gates that always starts, ARCH B1). The
/// offline/lightest-surface fallback for the dynamic list from `GET /about`.
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
];

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
