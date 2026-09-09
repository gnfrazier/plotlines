// The one place a `NodeKind` becomes a map `NodeMarkerType`. The mapping
// lives in the client (not `plotlines_ui`) because `NodeKind` is a domain
// type and the marker enum is a brand-kit type — the package must not depend
// on the app. Both the Content tab and #322's Route-tab node rendering draw
// from here, so a kind only ever picks one mark.
library;

import 'package:plotlines_ui/plotlines_ui.dart';

import '../../domain/node.dart';

/// The marker a node of [kind] is drawn as. `start`/`finish` get their own
/// marks (#320); the rest fall back to the nearest existing shape, and
/// anything without a better fit is a plain [NodeMarkerType.waypoint] rather
/// than the narrative `plot` marker it used to inherit by list position.
NodeMarkerType markerForNodeKind(NodeKind kind) => switch (kind) {
      NodeKind.start => NodeMarkerType.start,
      NodeKind.finish => NodeMarkerType.finish,
      NodeKind.regroup => NodeMarkerType.regroup,
      NodeKind.restStop => NodeMarkerType.rest,
      NodeKind.poi => NodeMarkerType.plot,
      NodeKind.event => NodeMarkerType.plot,
      NodeKind.transition => NodeMarkerType.portage,
      NodeKind.portageStart => NodeMarkerType.portage,
      NodeKind.portageEnd => NodeMarkerType.portage,
      NodeKind.waypoint => NodeMarkerType.waypoint,
      NodeKind.via => NodeMarkerType.waypoint,
    };
