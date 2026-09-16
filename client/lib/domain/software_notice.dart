// Issue #267, addendum L5 — one licence notice for one third-party package
// the sidecar ships, as carried on `GET /about`'s `software_notices` field.
//
// Distinct from `AttributionLine` (attribution_line.dart): that is FR101's
// *data* attribution, derived from the loaded layer set. This is *software*
// notices — the licence texts owed for the sidecar's own dependencies, a
// static build artifact (`packaging/generate_third_party_licenses.py`) that
// only exists once a frozen sidecar has generated one. A source-run sidecar
// or a fresh Web guest surface reports an empty list with
// `software_notices_available: false` — "no bundle to show", not a build
// failure the way a missing FR101 credit is.
library;

/// One third-party package's licence notice.
class SoftwareNotice {
  const SoftwareNotice({
    required this.name,
    required this.version,
    required this.licence,
    required this.text,
  });

  final String name;
  final String version;
  final String licence;
  final String text;

  factory SoftwareNotice.fromJson(Map<String, dynamic> json) => SoftwareNotice(
        name: json['name'] as String? ?? '',
        version: json['version'] as String? ?? '',
        licence: json['licence'] as String? ?? '',
        text: json['text'] as String? ?? '',
      );
}

/// Parse the `software_notices` list from a `GET /about` payload. Empty
/// (never a fallback list — unlike [AttributionLine], there is no static
/// obligation here to fall back to; an unreachable sidecar or an unfrozen
/// dev build both mean "nothing to show yet") when absent or malformed.
List<SoftwareNotice> softwareNoticesFrom(Object? aboutSoftwareNotices) {
  if (aboutSoftwareNotices is List) {
    try {
      return aboutSoftwareNotices
          .map((e) => SoftwareNotice.fromJson(e as Map<String, dynamic>))
          .toList(growable: false);
    } catch (_) {
      // Malformed — show nothing rather than throw.
    }
  }
  return const [];
}
