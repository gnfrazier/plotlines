// K10 / FR86, FR95, FR101 (issue #116) — one credit line for one licensed
// data source, as shown on the About surface and carried into exports and
// print.
//
// The service derives the full list from the loaded layer set at
// `GET /about` / `GET /attribution` (attribution is never hardcoded — ARCH
// §12.2). But elevation and the basemap always ship with the home region, so
// their two credits also exist here as a constant: a surface with no sidecar
// reachable (a fresh Web guest, a reading view) must still meet the licence
// obligation. `test_web_about.py` pins the canonical strings on the Python
// side; `settings_about_test.dart` pins that the fallback renders them.
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

/// Elevation's CC BY (FR86) and the basemap's ODbL (FR95) — **separate
/// obligations under different licences**, always owed because both ship with
/// the home region. The offline/lightest-surface fallback for the dynamic
/// list from `GET /about`.
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
