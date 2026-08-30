/// FR21 / C5 — the provision-logistics half of a placed [Node]: the amenity
/// vocabulary an Author tags a rest stop with, and the bridge that lets
/// N4 / FR104's provision-cluster proposals feed straight into placed nodes
/// instead of being re-typed and re-tagged by hand.
///
/// Waypoints, regroup points, and rest stops are placed [Node]s on a passage
/// (`segment.nodes`), not `Anchor` roles — a deliberate, shipped decision
/// (`trip_payload.schema.json` `$defs/node_kind`): a regroup point is a
/// [NodeKind], not a boolean on a waypoint, so every list that groups by kind
/// still finds it.
library;

import 'candidate.dart' show RoleAffinity;
import 'cluster_proposal.dart';
import 'node.dart';

/// C5's amenity seed set — water, toilets, food, shelter.
///
/// **A seed set, not a closed vocabulary** (punch-list §0). [Node.amenities]
/// stays an open `List<String>`: a plugin layer or a later taxonomy pass may
/// contribute a tag outside this list and it must still round-trip. The rule
/// the four share — and what [amenityForType] maps toward — is *a service a
/// mixed-pace group stops for*: potable water, a toilet, somewhere to get
/// food, weatherproof shelter. These four are what the authoring UI offers as
/// chips; anything else is still storable, just not suggested.
const List<String> kKnownAmenities = ['water', 'toilets', 'food', 'shelter'];

/// Maps a source feature's resolved `key=value` tag — as carried on a
/// [ClusterMember.type] or in a candidate's tags — to one of [kKnownAmenities],
/// or `null` when the feature is not a recognised provision service.
///
/// The OSM keys on the left are the current *evidence*; the value on the right
/// is the rule ("a service a group stops for"). Extend the left side as
/// `taxonomy.py`'s provision affinity grows — an unmapped type is dropped from
/// the suggested set, never turned into a bogus amenity and never an error.
String? amenityForType(String keyValue) {
  switch (keyValue.trim().toLowerCase()) {
    case 'amenity=drinking_water':
    case 'amenity=water_point':
    case 'man_made=water_tap':
    case 'man_made=water_well':
    case 'natural=spring':
      return 'water';
    case 'amenity=toilets':
      return 'toilets';
    case 'amenity=cafe':
    case 'amenity=restaurant':
    case 'amenity=fast_food':
    case 'shop=bakery':
    case 'shop=convenience':
    case 'shop=supermarket':
      return 'food';
    case 'amenity=shelter':
    case 'amenity=ranger_station':
    case 'tourism=alpine_hut':
    case 'tourism=wilderness_hut':
      return 'shelter';
    default:
      return null;
  }
}

/// FR21 / FR104 — "N4's provision-cluster proposals feed this directly."
///
/// Turns a co-location [proposal] carrying a provision affinity into a single
/// placed [Node] the Author drops onto a passage in one action, with the kind
/// and amenities already set: [NodeKind.restStop] at the cluster centroid,
/// titled with the proposal's generated name, its amenity set the sorted
/// union of what its provision members map to via [amenityForType].
///
/// Returns `null` when [proposal] carries no provision affinity — a purely
/// narrative cluster is O1's promotion path, not C5's. Does not consult or
/// mutate the proposal-review list; accepting a proposal for review is N4a's
/// concern, separate from placing one.
Node? provisionNodeFromProposal(
  ClusterProposal proposal, {
  required String id,
  NodeKind kind = NodeKind.restStop,
  double? distanceAlongM,
}) {
  if (!proposal.roleAffinities.contains(RoleAffinity.provision)) return null;
  final amenities = <String>{
    for (final m in proposal.members)
      if (m.roleAffinity == RoleAffinity.provision) ?amenityForType(m.type),
  }.toList()
    ..sort();
  return Node(
    id: id,
    kind: kind,
    coord: proposal.centroid,
    distanceAlongM: distanceAlongM,
    title: proposal.name,
    amenities: amenities,
  );
}
