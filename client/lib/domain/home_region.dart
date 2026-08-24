// A10 (PRD FR96) — the app's shipped home region: a constant rectangular
// bbox over Buncombe County, NC. It is a constant, not a default — there is
// no override, no first-run prompt, and no eager download of any kind. It
// exists so the map is never blank before any trip does, and costs nothing
// at runtime because it ships with the app rather than being fetched.
//
// Distinct from a trip's bbox (N1, FR120): this region never scopes
// extraction, routing, or elevation for any trip — it is only ever a map
// backdrop before a trip exists.
library;

/// [lon, lat] pair, matching the rest of the client's coordinate convention
/// (see `TapToPickMap.LatLonPoint`).
typedef LatLon = List<double>;

class HomeRegion {
  const HomeRegion._();

  static const String label = 'Buncombe County, NC';

  static const double minLat = 35.36;
  static const double minLon = -82.83;
  static const double maxLat = 35.79;
  static const double maxLon = -82.14;

  static double get centerLat => (minLat + maxLat) / 2;
  static double get centerLon => (minLon + maxLon) / 2;

  static LatLon get center => [centerLon, centerLat];

  /// Zoom level that keeps the whole county roughly in frame on first paint.
  static const double previewZoom = 9;

  static List<LatLon> get outline => [
        [minLon, minLat],
        [maxLon, minLat],
        [maxLon, maxLat],
        [minLon, maxLat],
      ];
}
