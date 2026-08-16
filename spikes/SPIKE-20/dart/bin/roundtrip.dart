/// SPIKE-20's Dart leg: JSON → domain → drift → domain → JSON, plus an Author edit.
///
///     dart run bin/roundtrip.dart --input <payload.json> --outdir <dir>
///
/// Writes three files per input — the re-serialization before any edit, the one
/// after the simulated Author edit, and a report of timings, sizes and probe
/// outcomes — and exits non-zero if its own invariants fail. Python's `run.py` does
/// the authoritative field-level diffing; this side proves the client can hold the
/// payload without losing anything, which is a different claim from the schema
/// validating.
library;

import 'dart:convert';
import 'dart:io';

import 'package:spike20_roundtrip/database.dart' as db;
import 'package:spike20_roundtrip/domain.dart' as domain;

const _encoder = JsonEncoder();

/// The canonical form: keys sorted, no whitespace — the same rule
/// `plotlines_core.trips.payload.dumps` applies. Two producers that agree on it
/// produce byte-identical files for the same trip, which is what makes a content
/// digest (`cue_sheet.derived_from.geometry_digest`) meaningful across the boundary.
/// Dart's `JsonEncoder` preserves insertion order, so the sort has to be explicit.
String canonical(Object? value) => _encoder.convert(_sorted(value));

Object? _sorted(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => k as String).toList()..sort();
    return {for (final key in keys) key: _sorted(value[key])};
  }
  if (value is List) return value.map(_sorted).toList();
  return value;
}

void main(List<String> args) async {
  final options = _parseArgs(args);
  final inputPath = options['input']!;
  final outDir = Directory(options['outdir'] ?? '.')..createSync(recursive: true);
  final stem = inputPath.split(Platform.pathSeparator).last.replaceAll('.json', '');

  final report = <String, dynamic>{'input': inputPath, 'failures': <String>[]};
  final failures = report['failures'] as List<String>;

  final raw = File(inputPath).readAsStringSync();
  report['input_bytes'] = raw.length;

  // ---- 1. decode + build the domain layer -------------------------------
  // Five passes, reporting the best: the first pass through a cold JIT measures the
  // VM warming up, not the payload. The client's real cost is the steady state — it
  // decodes a trip on every open, not once per process.
  final decodeMs = <double>[];
  final buildMs = <double>[];
  final encodeMs = <double>[];
  late Map<String, dynamic> decoded;
  late domain.Trip trip;
  late String reserialized;
  for (var pass = 0; pass < 5; pass++) {
    final decodeStart = Stopwatch()..start();
    decoded = jsonDecode(raw) as Map<String, dynamic>;
    decodeStart.stop();
    decodeMs.add(decodeStart.elapsedMicroseconds / 1000.0);

    final buildStart = Stopwatch()..start();
    trip = domain.Trip.fromJson(decoded);
    buildStart.stop();
    buildMs.add(buildStart.elapsedMicroseconds / 1000.0);

    final encodeStart = Stopwatch()..start();
    reserialized = canonical(trip.toJson());
    encodeStart.stop();
    encodeMs.add(encodeStart.elapsedMicroseconds / 1000.0);
  }
  double best(List<double> values) => values.reduce((a, b) => a < b ? a : b);
  report['json_decode_ms'] = best(decodeMs);
  report['domain_build_ms'] = best(buildMs);
  report['json_encode_ms'] = best(encodeMs);
  report['json_decode_ms_first'] = decodeMs.first;
  report['domain_build_ms_first'] = buildMs.first;
  report['days'] = trip.days.length;
  report['segments'] = trip.segmentCount;
  report['geometry_vertices'] = trip.vertexCount;
  report['reserialized_bytes'] = reserialized.length;
  report['byte_identical_to_producer'] = reserialized == raw.trimRight();

  final prePath = '${outDir.path}${Platform.pathSeparator}$stem.dart_reserialized.json';
  File(prePath).writeAsStringSync(reserialized);

  // ---- 2. drift: write, read back, prove the text survives ---------------
  final dbPath = '${outDir.path}${Platform.pathSeparator}$stem.drift.sqlite';
  final dbFile = File(dbPath);
  if (dbFile.existsSync()) dbFile.deleteSync();

  final database = db.LocalDatabase.atPath(dbPath);
  final writeStart = Stopwatch()..start();
  await database.saveTrip(
      id: trip.id, name: trip.title, payload: reserialized, version: 1);
  writeStart.stop();
  report['drift_write_ms'] = writeStart.elapsedMicroseconds / 1000.0;

  final readStart = Stopwatch()..start();
  final stored = await database.loadTrip(trip.id);
  readStart.stop();
  report['drift_read_ms'] = readStart.elapsedMicroseconds / 1000.0;

  if (stored.payload != reserialized) {
    failures.add('drift returned different bytes than were written');
  }
  report['drift_bytes_identical'] = stored.payload == reserialized;

  // G2a's list surface, measured both ways: `SELECT *` (which drags every payload
  // into memory to draw a title) against a three-column projection.
  final listStart = Stopwatch()..start();
  final listed = await database.listTrips();
  listStart.stop();
  report['drift_list_ms'] = listStart.elapsedMicroseconds / 1000.0;
  report['drift_listed_rows'] = listed.length;

  final summaryStart = Stopwatch()..start();
  final summaries = await database.listTripSummaries();
  summaryStart.stop();
  report['drift_list_summary_ms'] = summaryStart.elapsedMicroseconds / 1000.0;
  report['drift_summary_rows'] = summaries.length;

  // A library, not a single trip: 20 saved trips is an ordinary Author's shelf, and
  // it is the case where "which columns does the list read" stops being pedantry.
  for (var i = 0; i < 19; i++) {
    await database.saveTrip(
        id: 'library-$i', name: 'Saved trip $i', payload: reserialized, version: 1);
  }
  final libraryStart = Stopwatch()..start();
  final libraryRows = await database.listTrips();
  libraryStart.stop();
  final librarySummaryStart = Stopwatch()..start();
  await database.listTripSummaries();
  librarySummaryStart.stop();
  report['drift_library_rows'] = libraryRows.length;
  report['drift_library_list_ms'] = libraryStart.elapsedMicroseconds / 1000.0;
  report['drift_library_summary_ms'] =
      librarySummaryStart.elapsedMicroseconds / 1000.0;

  // ---- 3. the Author edit ------------------------------------------------
  // Round-trip through the database first: the edit must be applied to what came
  // OUT of storage, not to the object still in memory, or the test proves nothing
  // about storage.
  final fromStore = domain.Trip.fromJson(
      jsonDecode(stored.payload) as Map<String, dynamic>);
  final edit = _applyAuthorEdit(fromStore);
  report['edit'] = edit.description;

  final editedJson = canonical(edit.trip.toJson());
  await database.saveTrip(
      id: edit.trip.id, name: edit.trip.title, payload: editedJson, version: 2);
  final storedEdited = await database.loadTrip(edit.trip.id);
  final finalTrip = domain.Trip.fromJson(
      jsonDecode(storedEdited.payload) as Map<String, dynamic>);
  final finalJson = canonical(finalTrip.toJson());

  if (finalJson != editedJson) {
    failures.add('edited payload changed on its second trip through drift');
  }
  report['edit_stable_across_storage'] = finalJson == editedJson;

  final postPath = '${outDir.path}${Platform.pathSeparator}$stem.dart_edited.json';
  File(postPath).writeAsStringSync(finalJson);

  report['drift_file_bytes'] = dbFile.lengthSync();
  await database.close();

  // ---- 4. coercion probes ------------------------------------------------
  report['probes'] = _probes(raw);

  report['reserialized_path'] = prePath;
  report['edited_path'] = postPath;

  final reportPath = '${outDir.path}${Platform.pathSeparator}$stem.dart_report.json';
  File(reportPath).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));

  stdout.writeln('SPIKE-20 dart: $stem — ${trip.segmentCount} segments, '
      '${trip.vertexCount} vertices, ${failures.length} failure(s)');
  if (failures.isNotEmpty) {
    for (final failure in failures) {
      stderr.writeln('  FAIL: $failure');
    }
    exit(1);
  }
}

class _Edit {
  _Edit(this.trip, this.description);

  final domain.Trip trip;
  final Map<String, dynamic> description;
}

/// The three edits SPIKE-20 specifies: add a via-node, reword a node note, change
/// one surface weight. All three are applied through the domain classes, not to the
/// decoded map — an edit path that pokes the JSON directly would prove nothing about
/// whether the domain layer can represent the change.
_Edit _applyAuthorEdit(domain.Trip trip) {
  final days = <domain.Day>[];
  final description = <String, dynamic>{};

  for (final day in trip.days) {
    final segments = <domain.Segment>[];
    for (final segment in day.segments) {
      if (segment.shape == 'loop' && segment.via.isNotEmpty) {
        // 1. a third via-node, placed a little off the first one.
        final anchor = segment.via.first;
        final added = <double>[
          double.parse((anchor[0] + 0.01).toStringAsFixed(7)),
          double.parse((anchor[1] - 0.006).toStringAsFixed(7)),
        ];

        // 2. reword one node's note.
        final nodes = <domain.Node>[];
        var reworded = false;
        for (final node in segment.nodes) {
          if (!reworded && node.note != null) {
            nodes.add(node.withNote(
                'Rewritten by the Author: the gravel starts a kilometre earlier '
                'than the map suggests — regroup at the cattle guard.'));
            reworded = true;
            description['note_node_id'] = node.id;
            description['note_before'] = node.note;
            description['note_after'] = nodes.last.note;
          } else {
            nodes.add(node);
          }
        }

        // 3. change one surface weight (FR4's per-class bipolar axis).
        final weights = segment.weights;
        final beforeGravel = weights?.surface['gravel'];
        final newWeights = weights?.withSurface('gravel', 2.0);

        description['segment_id'] = segment.id;
        description['via_before'] = segment.via.length;
        description['via_after'] = segment.via.length + 1;
        description['via_added'] = added;
        description['surface_gravel_before'] = beforeGravel;
        description['surface_gravel_after'] = 2.0;

        // All three edits change inputs the geometry was solved from, so the
        // segment's derived half is stale until the sidecar re-solves it. Without
        // this the payload would keep presenting the previous route's distance,
        // climbing and elevation profile as if they described the edited one.
        description['marked_stale'] = true;

        segments.add(segment.copyWith(
          via: [...segment.via, added],
          nodes: nodes,
          weights: newWeights,
          solve: (segment.solve ?? domain.SolveProvenance()).markStale(),
        ));
      } else {
        segments.add(segment);
      }
    }
    days.add(day.withSegments(segments));
  }

  return _Edit(trip.withDays(days), description);
}

/// The four ways a payload can cross this boundary and come out subtly wrong. Each
/// probe reports what happens with a strict reader and with the reader this codebase
/// actually ships, because the difference is the argument for the rule.
List<Map<String, dynamic>> _probes(String raw) {
  final probes = <Map<String, dynamic>>[];

  // (a) an integer where a float was meant — Python's `round(x)` vs `round(x, 1)`.
  const intWhereFloat = '{"distance_m": 4, "climb_m": 0.0, "descent_m": 0.0}';
  probes.add({
    'probe': 'int_where_float',
    'input': intWhereFloat,
    'strict_as_double': _outcome(() {
      final map = jsonDecode(intWhereFloat) as Map<String, dynamic>;
      return (map['distance_m'] as double).toString();
    }),
    'shipped_as_num': _outcome(() =>
        domain.RouteMetrics.fromJson(jsonDecode(intWhereFloat) as Map<String, dynamic>)
            .distanceM
            .toString()),
  });

  // (b) an explicit null where the schema says "omit".
  final nulled = jsonDecode(raw) as Map<String, dynamic>;
  nulled['duration'] = null;
  probes.add({
    'probe': 'explicit_null',
    'shipped_reader': _outcome(() =>
        domain.Trip.fromJson(Map<String, dynamic>.from(nulled)).title),
  });

  // (c) an unknown key — a producer that added a field the client does not know.
  final extra = jsonDecode(raw) as Map<String, dynamic>;
  extra['unexpected_field'] = 'added by a newer producer';
  probes.add({
    'probe': 'unknown_key',
    'shipped_reader': _outcome(() =>
        domain.Trip.fromJson(Map<String, dynamic>.from(extra)).title),
  });

  // (d) a non-finite float — what an unguarded elevation void (FR88) would emit.
  probes.add({
    'probe': 'non_finite',
    'input': '{"ascent_m": NaN}',
    'shipped_reader': _outcome(() => jsonDecode('{"ascent_m": NaN}').toString()),
  });

  return probes;
}

Map<String, dynamic> _outcome(Object? Function() body) {
  try {
    return {'ok': true, 'value': body().toString()};
  } catch (error) {
    return {'ok': false, 'error': error.toString().split('\n').first};
  }
}

Map<String, String> _parseArgs(List<String> args) {
  final out = <String, String>{};
  for (var i = 0; i < args.length - 1; i += 2) {
    out[args[i].replaceFirst('--', '')] = args[i + 1];
  }
  if (!out.containsKey('input')) {
    stderr.writeln('usage: roundtrip.dart --input <payload.json> --outdir <dir>');
    exit(2);
  }
  return out;
}
