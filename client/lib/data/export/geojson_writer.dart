// E5 (PRD MVP doc §1.4.2 — promoted: "F3 already builds the export
// pipeline; GeoJSON [RFC 7946] is the cheapest of the four writers").
//
// This is genuinely the whole writer: every Segment already carries an
// RFC 7946 LineString (domain/segment.dart's `LineString`), and every
// Node/Hazard already carries an RFC 7946 coord — GeoJSON needs no
// derivation core doesn't already do, unlike GPX's route/track distinction
// or TCX/FIT's binary/lap structure. `core/plotlines_core/export/` is still
// an empty package (no writers exist there at all, GeoJSON included) and no
// `/trips/{id}/export` endpoint is registered, so this runs entirely
// client-side rather than waiting on server work it doesn't need.
library;

import 'dart:convert';

import '../../domain/domain.dart';

/// Feature per segment geometry, feature per node, feature per hazard.
/// `properties` carries just enough to be useful in a general GIS viewer —
/// this is not a re-implementation of the schema, only its geometry half.
String tripToGeoJson(Trip trip) {
  final features = <Map<String, dynamic>>[];

  for (final day in trip.days) {
    for (final segment in day.segments) {
      if (segment.geometry != null) {
        features.add({
          'type': 'Feature',
          'geometry': {
            'type': 'LineString',
            'coordinates': segment.geometry!.coordinates,
          },
          'properties': {
            'day_index': day.index,
            'segment_id': segment.id,
            'mode': segment.mode,
            'shape': segment.shape,
            if (segment.title != null) 'title': segment.title,
            if (segment.metrics?.distanceM != null) 'distance_m': segment.metrics!.distanceM,
            if (segment.metrics?.climbM != null) 'climb_m': segment.metrics!.climbM,
          },
        });
      }
      for (final node in segment.nodes) {
        features.add(_pointFeature(
          coord: node.coord,
          properties: {
            'kind': 'node',
            'node_kind': node.kind.wireValue,
            if (node.title != null) 'title': node.title,
            if (node.poiType != null) 'poi_type': node.poiType,
            if (node.arcStage != null) 'arc_stage': node.arcStage,
          },
        ));
      }
      for (final hazard in segment.hazards) {
        if (hazard.coord == null) continue;
        features.add(_pointFeature(
          coord: hazard.coord!,
          properties: {
            'kind': 'hazard',
            'severity': hazard.severity,
            if (hazard.title != null) 'title': hazard.title,
          },
        ));
      }
    }
    for (final node in day.nodes) {
      features.add(_pointFeature(
        coord: node.coord,
        properties: {
          'kind': 'node',
          'node_kind': node.kind.wireValue,
          'day_index': day.index,
          if (node.title != null) 'title': node.title,
        },
      ));
    }
  }

  final collection = {
    'type': 'FeatureCollection',
    'properties': {
      'trip_id': trip.id,
      'trip_title': trip.title,
      'schema_version': trip.schemaVersion,
    },
    'features': features,
  };
  return const JsonEncoder.withIndent('  ').convert(collection);
}

Map<String, dynamic> _pointFeature({required Coord coord, required Map<String, dynamic> properties}) => {
      'type': 'Feature',
      'geometry': {'type': 'Point', 'coordinates': coord},
      'properties': properties,
    };
