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
import 'export_options.dart';
import 'geo_utils.dart';

/// Feature per segment geometry, feature per node, feature per hazard.
/// `properties` carries just enough to be useful in a general GIS viewer —
/// this is not a re-implementation of the schema, only its geometry half.
String tripToGeoJson(Trip trip, {ExportOptions options = const ExportOptions()}) {
  final features = <Map<String, dynamic>>[];

  // FR106/FR107 (O1, O2) — one feature per anchor, plus one further feature
  // per role that carries its own offset (FR107 / O2's "offsets appear on
  // the map and export as distinct features"). An anchor with no role
  // offsets exports exactly one point — its own — never an extra feature,
  // which is O2's "behaves exactly as a single point" AC read onto export.
  if (options.includeWaypoints) {
    for (final anchor in trip.anchors) {
      features.add(_pointFeature(
        coord: anchor.coord,
        properties: {
          'kind': 'anchor',
          'anchor_id': anchor.id,
          if (anchor.title != null) 'title': anchor.title,
          'role_kinds': [for (final role in anchor.roles) role.kind.wireValue],
        },
      ));
      // FR108 / O3 — the anchor's own area, when it has one, exports as a
      // second feature alongside its point (never in place of it): the point
      // stays the representative pin every consumer already reads, and the
      // polygon is the added shape a GIS viewer or the field runtime can use
      // as the district's actual boundary.
      if (anchor.area != null) {
        features.add(_polygonFeature(
          area: anchor.area!,
          properties: {
            'kind': 'anchor_area',
            'anchor_id': anchor.id,
            if (anchor.title != null) 'title': anchor.title,
            'role_kinds': [for (final role in anchor.roles) role.kind.wireValue],
          },
        ));
      }
      for (final role in anchor.roles) {
        if (role.coord != null) {
          features.add(_pointFeature(
            coord: role.coord!,
            properties: {
              'kind': 'role_offset',
              'anchor_id': anchor.id,
              'role_id': role.id,
              'role_kind': role.kind.wireValue,
              if (role.title != null) 'title': role.title,
            },
          ));
        }
        if (role.area != null) {
          features.add(_polygonFeature(
            area: role.area!,
            properties: {
              'kind': 'role_area',
              'anchor_id': anchor.id,
              'role_id': role.id,
              'role_kind': role.kind.wireValue,
              if (role.title != null) 'title': role.title,
            },
          ));
        }
      }
    }
  }

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
      if (options.includeWaypoints) {
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
      if (options.includeAlternates) {
        for (final alt in segment.alternates) {
          features.add({
            'type': 'Feature',
            'geometry': {'type': 'LineString', 'coordinates': alt.geometry.coordinates},
            'properties': {
              'kind': 'alternate',
              'alternate_kind': alt.kind,
              'day_index': day.index,
              'segment_id': segment.id,
              if (alt.label != null) 'title': alt.label,
            },
          });
        }
      }
      if (options.includeCueSheet) {
        final sheet = options.cueSheetsBySegmentId[segment.id];
        final coords = segment.geometry?.coordinates ?? const [];
        if (sheet != null && coords.isNotEmpty) {
          for (final cue in sheet.cues) {
            features.add(_pointFeature(
              coord: pointAtDistance(coords, cue.distanceAlongM),
              properties: {
                'kind': 'cue',
                'cue_kind': cue.kind,
                if (cue.modifier != null) 'modifier': cue.modifier,
                if (cue.instruction != null) 'title': cue.instruction,
                'distance_along_m': cue.distanceAlongM,
              },
            ));
          }
        }
      }
    }
    if (options.includeWaypoints) {
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

/// FR108 / O3 — RFC 7946 Polygon feature for an anchor's or a role's [area].
Map<String, dynamic> _polygonFeature({required Area area, required Map<String, dynamic> properties}) => {
      'type': 'Feature',
      'geometry': {'type': 'Polygon', 'coordinates': area.rings},
      'properties': properties,
    };
