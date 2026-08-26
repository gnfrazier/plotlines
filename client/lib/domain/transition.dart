/// `$defs/transition`.
library;

import 'json_utils.dart';
import 'node.dart';

/// FR12 / B3 — the mode change between two segments of a day. A first-class
/// member of the day rather than a node on either segment, because it
/// belongs to neither: `compose_day(segments, transitions)` (ARCH §6.1)
/// takes them as separate lists for exactly this reason.
class Transition {
  Transition({
    required this.id,
    required this.fromSegmentId,
    required this.toSegmentId,
    this.fromMode,
    this.toMode,
    this.node,
    this.gapM,
    this.gapWarning,
  });

  final String id;
  final String fromSegmentId;
  final String toSegmentId;
  final String? fromMode;
  final String? toMode;
  final Node? node;

  /// B2's adjacency check: the straight-line distance between the previous
  /// segment's end and the next one's start, measured once by the composer.
  final double? gapM;
  final bool? gapWarning;

  factory Transition.fromJson(Map<String, dynamic> json) {
    final f = JsonFields(json, 'transition');
    final t = Transition(
      id: f.takeString('id')!,
      fromSegmentId: f.takeString('from_segment_id')!,
      toSegmentId: f.takeString('to_segment_id')!,
      fromMode: f.takeString('from_mode'),
      toMode: f.takeString('to_mode'),
      node: f.takeObject('node', Node.fromJson),
      gapM: f.takeNum('gap_m'),
      gapWarning: f.takeBool('gap_warning'),
    );
    f.done();
    return t;
  }

  Map<String, dynamic> toJson() => pruneJson({
        'id': id,
        'from_segment_id': fromSegmentId,
        'to_segment_id': toSegmentId,
        'from_mode': fromMode,
        'to_mode': toMode,
        'node': node?.toJson(),
        'gap_m': gapM == null ? null : finite(gapM!, 'transition.gap_m'),
        'gap_warning': gapWarning,
      });

  /// FR12 / B3 — [clearNode] is the only way to take a placed transition node
  /// off a junction: `node: null` reads as "leave it as it was" like every
  /// other optional field in this layer's `copyWith`s, and a caller removing
  /// an Author's instructions should have to say so.
  Transition copyWith({
    String? fromSegmentId,
    String? toSegmentId,
    String? fromMode,
    String? toMode,
    Node? node,
    bool clearNode = false,
    double? gapM,
    bool? gapWarning,
  }) =>
      Transition(
        id: id,
        fromSegmentId: fromSegmentId ?? this.fromSegmentId,
        toSegmentId: toSegmentId ?? this.toSegmentId,
        fromMode: fromMode ?? this.fromMode,
        toMode: toMode ?? this.toMode,
        node: clearNode ? null : (node ?? this.node),
        gapM: gapM ?? this.gapM,
        gapWarning: gapWarning ?? this.gapWarning,
      );

  /// True when this junction is an actual change of mode — ride to paddle —
  /// rather than two passages of the same mode laid end to end (a day split
  /// across two rides is still a sequence, just not a mode change). Unknown
  /// modes read as no change, since an unmeasured difference is not a fact.
  bool get isModeChange => fromMode != null && toMode != null && fromMode != toMode;

  /// FR12's payload: the Author's parking / gear-stash / put-in instructions,
  /// if a node has been placed here and carries any.
  String? get instructions => node?.instructions;
}
