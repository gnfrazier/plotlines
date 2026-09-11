/// Story C7 (issue #43, FR23) — "Authors filter and place lodging/campground
/// options on the planning map by type."
///
/// Mirrors `core/plotlines_core/curation/taxonomy.py`'s C7 addition: five
/// `tourism=*` OSM tags scored under the "amenity" layer with
/// `role_affinity="station"` (RULESET_VERSION 1.3.0) — a place a Character
/// stops and stays for the night, the same shape FR109/O4 gives a station
/// activity, not a utility a passing group stops at (`provision`) or a sight
/// (`narrative`). [LodgingType] is the client-side seed set over the same
/// four groupings the issue's own acceptance criteria name (campsite, hotel,
/// hut, hostel) — "hut" folds `alpine_hut` and `wilderness_hut` together,
/// since neither the AC nor the filter UI distinguishes them.
///
/// A placed lodging choice attaches to the day the same way any other
/// hand-placed or promoted point of interest does — a [Node] (`node.dart`)
/// with `kind: NodeKind.poi` and `poiType` set to this type's wire value, in
/// `Day.nodes` — no schema change: `Node.poiType` is already the free-string
/// "the Author-set type this node counts as" field `current_trip_provider
/// .dart`'s `promoteCandidate` was built for.
library;

import 'candidate.dart' show Candidate;
import 'node.dart' show Node, NodeKind;

/// The four lodging/campground groupings FR23's acceptance criteria name.
enum LodgingType {
  campsite,
  hotel,
  hut,
  hostel;

  /// The stored/wire value — what [Node.poiType] carries for a placed
  /// lodging node, and what a filter chip's selection state keys off.
  String get wireValue => switch (this) {
        LodgingType.campsite => 'campsite',
        LodgingType.hotel => 'hotel',
        LodgingType.hut => 'hut',
        LodgingType.hostel => 'hostel',
      };

  /// Display label for the filter chips and the placed-lodging list.
  String get label => switch (this) {
        LodgingType.campsite => 'Campsite',
        LodgingType.hotel => 'Hotel',
        LodgingType.hut => 'Hut',
        LodgingType.hostel => 'Hostel',
      };
}

/// Maps a source feature's `tourism` tag value — as carried on a
/// [Candidate]'s tags, the same evidence [amenityForType] in
/// `provision_node.dart` reads for a different purpose — to one of
/// [LodgingType], or `null` when the feature is not a lodging/campground
/// type. The OSM values on the left are the current evidence; extend this
/// as `taxonomy.py`'s lodging rows grow, never by branching code here.
LodgingType? lodgingTypeForTags(Map<String, String> tags) {
  switch (tags['tourism']) {
    case 'hotel':
      return LodgingType.hotel;
    case 'hostel':
      return LodgingType.hostel;
    case 'camp_site':
      return LodgingType.campsite;
    case 'alpine_hut':
    case 'wilderness_hut':
      return LodgingType.hut;
    default:
      return null;
  }
}

/// The [LodgingType] a candidate represents, or `null` when it is not a
/// lodging/campground candidate at all — the filter predicate every lodging
/// surface narrows its candidate list with.
LodgingType? lodgingTypeOfCandidate(Candidate candidate) => lodgingTypeForTags(candidate.tags);

/// True when [node] is a placed lodging node — one this file's own
/// [lodgingNodeFromCandidate] produced, or hand-edited to the same shape:
/// a POI node whose `poiType` is one of [LodgingType]'s wire values.
bool isLodgingNode(Node node) =>
    LodgingType.values.any((t) => t.wireValue == node.poiType);

/// Turns a picked lodging [candidate] into the [Node] `promoteCandidate`
/// attaches to a day — mirrors `provisionNodeFromProposal`'s shape one level
/// down (a single candidate rather than a cluster), and `layers_tab.dart`'s
/// inline `_promote` (`poiType: candidate.layer`) except that a lodging
/// node's `poiType` is the specific [LodgingType], not the bare "amenity"
/// layer id — FR23's "filter by type" only means something downstream if
/// the placed node still remembers which type it was.
///
/// Returns `null` when [candidate] carries no lodging tag — a purely
/// narrative or provision candidate is a different placement path.
Node? lodgingNodeFromCandidate(Candidate candidate, {required String id}) {
  final type = lodgingTypeOfCandidate(candidate);
  if (type == null) return null;
  return Node(
    id: id,
    kind: NodeKind.poi,
    coord: candidate.coord,
    title: candidate.title,
    poiType: type.wireValue,
  );
}
