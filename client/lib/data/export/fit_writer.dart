// F3 — Garmin FIT *course* file. The fourth export writer, alongside
// gpx_writer.dart / tcx_writer.dart / geojson_writer.dart.
//
// **Why this is here and not a service call (issue #211).** The other three
// writers each carry a note that `core/plotlines_core/export/` had no writers
// and no `/trips/{id}/export` endpoint, so they ran client-side. That has
// half-changed: `core/plotlines_core/export/fit.py` now ships a FIT course
// writer (the SPIKE-16 / issue #163 verdict — a dependency-free in-language
// writer, *not* Dart FFI against Garmin's SDK). There is still no endpoint,
// and the FIT container is small and dependency-free by design, so the
// consistent move is a Dart port that sits beside the other three rather
// than a lone format that round-trips to a server the rest don't need. This
// file is a direct port of `_fit_encoder.py` (the byte container + CRC),
// `_fit_profile.py` (the seven-message course sub-profile), and `fit.py`
// (the trip -> course-file mapping and the F3 name-truncation rules).
//
// **Reveal policy is not applied here**, matching the sibling writers and the
// cue-sheet / itinerary previews in `export_tab.dart`: this is the Author
// exporting their own trip from the desktop, where every plot point is
// already visible to them. The byte-level reveal assertions in punch-list
// §6A.2 gate the Character-facing surfaces, which this is not.
//
// **Synthetic trackpoint time.** Like TCX, a FIT course needs a timestamp on
// every record and course point (that is how a head unit paces a virtual
// partner). The payload has no per-vertex time, so times are backfilled from
// a nominal pace — a device-compatibility fiction, the same one every FIT
// course importer already assumes, not a claim about how fast the Author
// will ride.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../domain/domain.dart';
import 'export_options.dart';
import 'geo_utils.dart';

/// Fallback pace by mode, m/s — the same seed table as tcx_writer.dart's
/// `_fallbackSpeedMps` (mirrors `core/plotlines_core/multimodal/modes.py`).
/// Only used when the trip carries no `moving_time_s` to divide distance by.
const Map<String, double> _fallbackSpeedMps = {
  'cycling': 4.17,
  'hiking': 1.39,
  'paddling': 1.11,
  'cross_country_skiing': 2.22,
  'packrafting': 1.25,
  'riverboarding': 1.11,
  'mountain_biking': 3.33,
  'driving': 16.67,
  'transit': 8.33,
};

/// `file_id.manufacturer`. `255` is FIT's "development / not a real
/// manufacturer" id; head units accept it. Swap this one constant (and
/// [_fitProduct]) when Plotlines has a Garmin-issued id. (SPIKE-16; mirrors
/// `fit.py`'s `FIT_MANUFACTURER`.)
const int _fitManufacturer = 255;
const int _fitProduct = 1;
const int _fitSoftwareVersion = 1;

/// Practical `course_point.name` cap in characters, and the hard byte ceiling
/// behind it. Garmin head units have historically shown ~15-30 characters of
/// a course point's name in the cue list (`spikes/SPIKE-16/HARNESS.md`); the
/// measured floor is a device-run finding still to be pinned. Mirrors
/// `FIT_CUE_NAME_CAP` / `FIT_NAME_BYTE_CEILING` in `fit.py`.
const int _fitCueNameCap = 30;
const int _fitNameByteCeiling = 64;

const String _ellipsis = '…';

/// Encode [trip] as a single FIT course file.
///
/// One flattened course across the trip's routed days (FIT course files carry
/// one track; a multi-day trip's segments are laid end to end with cumulative
/// distance, matching how gpx/tcx put every day in one file). Per-day
/// splitting is the caller's job, exactly as for the other writers — it calls
/// this once per `trip.copyWith(days: [day])`.
///
/// Throws [StateError] if the trip has no routed geometry: a FIT course needs
/// a line, and the Export tab already blocks the attempt when `dayCount == 0`.
Uint8List tripToFit(Trip trip, {ExportOptions options = const ExportOptions()}) {
  final track = <_TrackPoint>[];
  final coursePoints = <_CoursePoint>[];
  var cumulativeM = 0.0;

  double totalDistM = 0;
  double totalMovingS = 0;
  String? firstMode;
  for (final day in trip.days) {
    for (final s in day.segments) {
      firstMode ??= s.mode;
      totalDistM += s.metrics?.distanceM ?? 0;
      totalMovingS += s.metrics?.movingTimeS ?? 0;
    }
  }
  final speedMps = (totalDistM > 0 && totalMovingS > 0)
      ? totalDistM / totalMovingS
      : (_fallbackSpeedMps[firstMode] ?? 3.0);

  for (final day in trip.days) {
    for (final segment in day.segments) {
      final coords = segment.geometry?.coordinates ?? const <Coord>[];
      if (coords.isEmpty) continue;
      final segBaseM = cumulativeM;
      for (var i = 0; i < coords.length; i++) {
        final c = coords[i];
        if (i > 0) cumulativeM += haversineM(coords[i - 1], c);
        track.add(_TrackPoint(
          lat: c[1],
          lon: c[0],
          distanceM: cumulativeM,
          elevationM: c.length > 2 ? c[2] : null,
        ));
      }
      if (options.includeWaypoints) {
        for (final node in segment.nodes) {
          coursePoints.add(_coursePointForNode(node, segBaseM, coords));
        }
        // Hazards ride as `danger` course points — the format has a native
        // slot and a hazard is never withheld (PRD §1.5). Same gate as the
        // GeoJSON writer: they travel with the waypoint toggle.
        for (final hazard in segment.hazards) {
          final hc = hazard.coord;
          if (hc == null) continue;
          coursePoints.add(_CoursePoint(
            type: 'danger',
            name: _fitCueName(hazard.title ?? 'Hazard', null),
            lat: hc[1],
            lon: hc[0],
            distanceM: segBaseM + _distanceAtCoord(coords, hc),
          ));
        }
      }
      if (options.includeCueSheet) {
        final sheet = options.cueSheetsBySegmentId[segment.id];
        if (sheet != null) {
          for (final cue in sheet.cues) {
            final at = pointAtDistance(coords, cue.distanceAlongM);
            coursePoints.add(_CoursePoint(
              type: _cueCoursePointType(cue),
              name: _fitCueName(cue.instruction ?? cue.kind, null),
              lat: at[1],
              lon: at[0],
              distanceM: segBaseM + cue.distanceAlongM,
            ));
          }
        }
      }
    }
    // Day-scoped nodes (regroup points, rest stops not pinned to a segment)
    // carry no segment-relative distance; place them at the running total,
    // matching gpx/tcx.
    if (options.includeWaypoints) {
      for (final node in day.nodes) {
        coursePoints.add(_coursePointForNode(node, cumulativeM, const []));
      }
    }
  }

  if (track.isEmpty) {
    throw StateError('This trip has no routed geometry to export as FIT.');
  }

  final t0 = DateTime.now().toUtc().millisecondsSinceEpoch / 1000.0;
  int clock(double distanceM) =>
      _fitTime(t0 + (speedMps != 0 ? distanceM / speedMps : 0.0));

  final enc = _FitEncoder();

  // Message order matches Garmin's own course exporter (see fit.py):
  //   file_id -> file_creator -> course -> event(start)
  //     -> [record ...] -> [course_point ...] -> lap -> event(stop)
  enc.write('file_id', {
    0: _fileCourse,
    1: _fitManufacturer,
    2: _fitProduct,
    3: 0xA5A5A5A5,
    4: _fitTime(t0),
    5: 1,
  });
  enc.write('file_creator', {0: _fitSoftwareVersion, 1: 1});
  enc.write('course', {
    4: _sport[_sportForMode(firstMode)] ?? _sport['generic']!,
    5: trip.title.length > _fitNameByteCeiling
        ? trip.title.substring(0, _fitNameByteCeiling)
        : trip.title,
  });
  enc.write('event', {253: _fitTime(t0), 0: _eventTimer, 1: _eventTypeStart});

  for (final tp in track) {
    final rec = <int, Object?>{
      253: clock(tp.distanceM),
      0: _semicircles(tp.lat),
      1: _semicircles(tp.lon),
      5: _distanceRaw(tp.distanceM),
      6: speedMps != 0 ? (speedMps * 1000).round() : null,
    };
    if (tp.elevationM != null) rec[2] = _altitudeRaw(tp.elevationM!);
    enc.write('record', rec);
  }

  var idx = 0;
  for (final cp in coursePoints) {
    enc.write('course_point', {
      254: idx,
      1: clock(cp.distanceM),
      2: _semicircles(cp.lat),
      3: _semicircles(cp.lon),
      4: _distanceRaw(cp.distanceM),
      5: _coursePointType[cp.type] ?? _coursePointType['generic']!,
      6: cp.name,
    });
    idx++;
  }

  final totalM = track.last.distanceM;
  final lastT = t0 + (speedMps != 0 ? totalM / speedMps : 0.0);
  enc.write('lap', {
    253: _fitTime(lastT),
    2: _fitTime(t0),
    3: _semicircles(track.first.lat),
    4: _semicircles(track.first.lon),
    5: _semicircles(track.last.lat),
    6: _semicircles(track.last.lon),
    7: ((lastT - t0) * 1000).round(),
    8: ((lastT - t0) * 1000).round(),
    9: _distanceRaw(totalM),
  });
  enc.write('event', {253: _fitTime(lastT), 0: _eventTimer, 1: _eventTypeStopAll});

  return enc.getValue();
}

// --------------------------------------------------------------- course model

class _TrackPoint {
  _TrackPoint({
    required this.lat,
    required this.lon,
    required this.distanceM,
    this.elevationM,
  });
  final double lat;
  final double lon;
  final double distanceM;
  final double? elevationM;
}

class _CoursePoint {
  _CoursePoint({
    required this.type,
    required this.name,
    required this.lat,
    required this.lon,
    required this.distanceM,
  });
  final String type; // a `_coursePointType` key
  final String name;
  final double lat;
  final double lon;
  final double distanceM;
}

_CoursePoint _coursePointForNode(Node node, double baseM, List<Coord> coords) {
  final distanceM = node.distanceAlongM != null
      ? baseM + node.distanceAlongM!
      : (coords.isEmpty ? baseM : baseM + _distanceAtCoord(coords, node.coord));
  return _CoursePoint(
    type: _nodeCoursePointType(node.kind),
    // The device draws an icon for the type and `course_point` has no
    // description field, so the note rides in `name` (FR45), exactly as
    // fit.py does it. `_fitCueName` cuts it to the device's cue-list window.
    name: _fitCueName(node.title ?? node.kind.wireValue, node.note),
    lat: node.coord[1],
    lon: node.coord[0],
    distanceM: distanceM,
  );
}

/// `course_point.type` is the enum a head unit switches on to pick an icon and
/// a cue behaviour. The rule, not just the list (punch-list §0): map each
/// Plotlines node kind to the nearest native FIT slot, and fall back to
/// `generic` — which every device renders — when none fits. `_fit_profile.py`
/// holds the full `COURSE_POINT_TYPE` table this draws from.
String _nodeCoursePointType(NodeKind kind) => switch (kind) {
      NodeKind.restStop => 'rest_area',
      NodeKind.start => 'segment_start',
      NodeKind.finish => 'segment_end',
      NodeKind.waypoint ||
      NodeKind.regroup ||
      NodeKind.poi ||
      NodeKind.transition ||
      NodeKind.via ||
      NodeKind.portageStart ||
      NodeKind.portageEnd ||
      NodeKind.event =>
        'generic',
    };

/// Same rule for a derived cue: a hazard cue is `danger`, a turn maps through
/// its modifier to the matching FIT turn slot, everything else is `generic`.
String _cueCoursePointType(Cue cue) {
  if (cue.kind == 'hazard') return 'danger';
  return switch (cue.modifier) {
    'left' => 'left',
    'right' => 'right',
    'sharp_left' => 'sharp_left',
    'sharp_right' => 'sharp_right',
    'slight_left' => 'slight_left',
    'slight_right' => 'slight_right',
    'straight' => 'straight',
    'uturn' || 'u_turn' => 'u_turn',
    _ => 'generic',
  };
}

/// The `course_point.name` string: the marker name, then its note where it
/// fits, cut on a **word** boundary at [cap] characters and hard-capped at
/// [_fitNameByteCeiling] bytes (SPIKE-16 F3 task 1; port of `fit_cue_name`).
String _fitCueName(String name, String? note, {int cap = _fitCueNameCap}) {
  final combined =
      (note != null && note.isNotEmpty) ? '$name — $note' : name;
  var out = _clipToWords(combined, cap);
  while (utf8.encode(out).length > _fitNameByteCeiling) {
    final stripped = out.endsWith(_ellipsis)
        ? out.substring(0, out.length - 1).trimRight()
        : out;
    final next = stripped.length - 4;
    out = _clipToWords(stripped, next < 1 ? 1 : next);
  }
  return out;
}

final RegExp _alnum = RegExp(r'[0-9A-Za-z]');

String _clipToWords(String text, int cap) {
  if (cap <= 0) return '';
  if (text.length <= cap) return text;
  var head = text.substring(0, cap);
  final cutMidWord =
      _alnum.hasMatch(text[cap]) && _alnum.hasMatch(head[head.length - 1]);
  if (cutMidWord) {
    final space = head.lastIndexOf(' ');
    if (space > 0) head = head.substring(0, space);
  }
  return _rstrip(head, ' —-') + _ellipsis;
}

String _rstrip(String s, String chars) {
  var end = s.length;
  while (end > 0 && chars.contains(s[end - 1])) {
    end--;
  }
  return s.substring(0, end);
}

/// Cumulative distance along [coords] to the vertex nearest [target] — the
/// stand-in for a `distance_along_m` a node/hazard doesn't carry.
double _distanceAtCoord(List<Coord> coords, Coord target) {
  if (coords.isEmpty) return 0;
  var cumulative = 0.0;
  var bestDist = double.infinity;
  var bestCumulative = 0.0;
  for (var i = 0; i < coords.length; i++) {
    if (i > 0) cumulative += haversineM(coords[i - 1], coords[i]);
    final d = haversineM(coords[i], target);
    if (d < bestDist) {
      bestDist = d;
      bestCumulative = cumulative;
    }
  }
  return bestCumulative;
}

// --------------------------------------------------------- FIT course profile
// The slice of the FIT profile a course file touches — seven messages — ported
// verbatim from `_fit_profile.py`. A device parses by message/field *number*.

const int _fileCourse = 6;
const int _eventTimer = 0;
const int _eventTypeStart = 0;
const int _eventTypeStopAll = 4;

const Map<String, int> _sport = {
  'cycling': 2,
  'hiking': 17,
  'running': 1,
  'paddling': 19,
  'walking': 11,
  'generic': 0,
};

String _sportForMode(String? mode) => switch (mode) {
      'cycling' || 'mountain_biking' => 'cycling',
      'hiking' => 'hiking',
      'paddling' || 'packrafting' || 'riverboarding' => 'paddling',
      _ => 'generic',
    };

const Map<String, int> _coursePointType = {
  'generic': 0,
  'summit': 1,
  'valley': 2,
  'water': 3,
  'food': 4,
  'danger': 5,
  'left': 6,
  'right': 7,
  'straight': 8,
  'sharp_left': 9,
  'sharp_right': 10,
  'slight_left': 11,
  'slight_right': 12,
  'u_turn': 13,
  'segment_start': 14,
  'segment_end': 15,
  'first_category': 17,
  'second_category': 18,
  'third_category': 19,
  'fourth_category': 20,
  'general_distance': 24,
  'rest_area': 28,
};

// message name -> global message number (mirrors `MESG` in `_fit_profile.py`).
const Map<String, int> _mesgNum = {
  'file_id': 0,
  'file_creator': 49,
  'event': 21,
  'course': 31,
  'lap': 19,
  'record': 20,
  'course_point': 32,
};

// field number -> base-type key, per message — only the fields a course writer
// sets (mirrors `FIELDS` in `_fit_profile.py`).
const Map<String, Map<int, String>> _fields = {
  'file_id': {
    0: 'enum',
    1: 'uint16',
    2: 'uint16',
    3: 'uint32z',
    4: 'uint32',
    5: 'uint16',
  },
  'file_creator': {0: 'uint16', 1: 'uint8'},
  'event': {253: 'uint32', 0: 'enum', 1: 'enum'},
  'course': {4: 'enum', 5: 'string'},
  'lap': {
    253: 'uint32',
    2: 'uint32',
    3: 'sint32',
    4: 'sint32',
    5: 'sint32',
    6: 'sint32',
    7: 'uint32',
    8: 'uint32',
    9: 'uint32',
  },
  'record': {
    253: 'uint32',
    0: 'sint32',
    1: 'sint32',
    2: 'uint16',
    5: 'uint32',
    6: 'uint16',
  },
  'course_point': {
    254: 'uint16',
    1: 'uint32',
    2: 'sint32',
    3: 'sint32',
    4: 'uint32',
    5: 'enum',
    6: 'string',
  },
};

// base-type key -> definition type byte.
const Map<String, int> _baseTypeByte = {
  'enum': 0x00,
  'uint8': 0x02,
  'uint16': 0x84,
  'uint32': 0x86,
  'sint32': 0x85,
  'uint32z': 0x8C,
  'string': 0x07,
};

const double _semiPerDeg = 2147483648.0 / 180.0; // 2^31 / 180
const int _fitEpochUnix = 631065600; // 1989-12-31T00:00:00Z

int _semicircles(double deg) => (deg * _semiPerDeg).round();
int _fitTime(double unixS) => (unixS - _fitEpochUnix).round();
int _altitudeRaw(double m) => ((m + 500.0) * 5.0).round();
int _distanceRaw(double m) => (m * 100.0).round();

// ------------------------------------------------------------- byte container
// Port of `_fit_encoder.py`: the 14-byte header + CRC, the definition/data
// message framing, and CRC-16/ARC. Layout:
//   [14-byte header + header CRC] [data records] [file CRC]

final List<int> _crcTable = _buildCrcTable();

List<int> _buildCrcTable() {
  const poly = 0xA001; // CRC-16/ARC, reflected
  final table = List<int>.filled(256, 0);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (c >> 1) ^ poly : c >> 1;
    }
    table[n] = c & 0xFFFF;
  }
  return table;
}

/// Running FIT CRC-16/ARC over [data], seeded with [crc] (0 for a fresh run) —
/// what `FitCRC_Get16` in Garmin's `fit_crc.c` computes. Check value for
/// `"123456789"` is `0xBB3D`.
int fitCrc16(List<int> data, [int crc = 0]) {
  for (final byte in data) {
    crc = (crc >> 8) ^ _crcTable[(crc ^ byte) & 0xFF];
  }
  return crc & 0xFFFF;
}

class _EncodedField {
  _EncodedField(this.fieldNum, this.baseType, this.raw);
  final int fieldNum;
  final String baseType;
  final List<int> raw;
}

class _FitEncoder {
  final BytesBuilder _body = BytesBuilder();
  final Map<String, int> _localFor = {};
  final Map<int, String> _defSig = {};
  int _nextLocal = 0;

  /// Append one data message. [fields] is `{fieldNumber: value}`; a `null`
  /// value is dropped (that is how FIT says "absent").
  void write(String mesgName, Map<int, Object?> fields) {
    final mesgNum = _mesgNum[mesgName]!;
    final fieldDefs = _fields[mesgName]!;
    final present = fields.entries.where((e) => e.value != null).toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    final encoded = <_EncodedField>[];
    for (final e in present) {
      final baseType = fieldDefs[e.key]!;
      encoded.add(_EncodedField(
          e.key, baseType, _encodeValue(baseType, e.value as Object)));
    }

    final local = _ensureDefinition(mesgName, mesgNum, encoded);
    _body.addByte(local & 0x0F); // normal data header
    for (final f in encoded) {
      _body.add(f.raw);
    }
  }

  /// The finished file: header + header CRC + data + trailing file CRC.
  Uint8List getValue() {
    final body = _body.toBytes();

    final head = BytesBuilder();
    head.addByte(14); // header size
    head.addByte(0x20); // FIT protocol 2.0
    head.add(_u16(21158)); // profile version — informational
    head.add(_u32(body.length)); // data size (body only)
    head.add(ascii.encode('.FIT'));
    final head12 = head.toBytes();

    final out = BytesBuilder();
    out.add(head12);
    out.add(_u16(fitCrc16(head12)));
    out.add(body);
    final withoutFileCrc = out.toBytes();

    final result = BytesBuilder();
    result.add(withoutFileCrc);
    result.add(_u16(fitCrc16(withoutFileCrc)));
    return result.toBytes();
  }

  int _ensureDefinition(
      String mesgName, int mesgNum, List<_EncodedField> encoded) {
    final sig = StringBuffer()..write(mesgNum);
    for (final f in encoded) {
      sig.write(',${f.fieldNum}:${f.raw.length}:${_baseTypeByte[f.baseType]}');
    }
    final signature = sig.toString();

    var local = _localFor[mesgName];
    if (local == null) {
      local = _nextLocal++;
      _localFor[mesgName] = local;
    }
    if (_defSig[local] == signature) return local;
    _defSig[local] = signature;

    final d = BytesBuilder();
    d.addByte(0x40 | (local & 0x0F)); // definition header
    d.addByte(0x00); // reserved
    d.addByte(0x00); // architecture = little-endian
    d.add(_u16(mesgNum));
    d.addByte(encoded.length);
    for (final f in encoded) {
      d.addByte(f.fieldNum);
      d.addByte(f.raw.length);
      d.addByte(_baseTypeByte[f.baseType]!);
    }
    _body.add(d.toBytes());
    return local;
  }

  static List<int> _encodeValue(String baseType, Object value) {
    if (baseType == 'string') {
      return [...utf8.encode(value as String), 0x00]; // NUL-terminated
    }
    final v = (value as num).toInt();
    return switch (baseType) {
      'enum' || 'uint8' => [v & 0xFF],
      'uint16' => _u16(v),
      'uint32' || 'uint32z' => _u32(v),
      'sint32' => _i32(v),
      _ => throw ArgumentError('unhandled FIT base type "$baseType"'),
    };
  }
}

List<int> _u16(int v) {
  final b = ByteData(2)..setUint16(0, v & 0xFFFF, Endian.little);
  return b.buffer.asUint8List();
}

List<int> _u32(int v) {
  final b = ByteData(4)..setUint32(0, v & 0xFFFFFFFF, Endian.little);
  return b.buffer.asUint8List();
}

List<int> _i32(int v) {
  final b = ByteData(4)..setInt32(0, v, Endian.little);
  return b.buffer.asUint8List();
}
