/// `$defs/permit`, `$defs/permit_status`.
library;

import 'json_utils.dart';
import 'node.dart' show MediaRef;

/// FR26 / C10 — where a permit stands. `required` is the Author flagging it
/// needed with nothing done yet; `applied` is submitted/requested; `confirmed`
/// is in hand; `denied` is a rejected application — a reason to change the
/// route, not a state a checklist can quietly drop.
const List<String> kPermitStatuses = ['required', 'applied', 'confirmed', 'denied'];

/// FR26 / C10 — a permit, land-access rule, or parking pass the Author
/// attaches to a passage or a promoted anchor, surfaced to Characters as a
/// pre-trip checklist.
///
/// Trip-scoped ([Trip.permits]), not nested under a day or segment — mirrors
/// [Trip.anchors] rather than a segment's hazards, because a checklist reads
/// the whole trip in one pass and a permit is not itself a point on a route
/// the way a hazard's `distanceAlongM` can be.
///
/// [segmentId] / [anchorId] are optional and independently so — an all-trip
/// obligation (a state-park annual pass covering every day) is neither. When
/// both are set the model is contradictory (a permit pinned to two different
/// things), the same posture [Hazard.nodeId]/[Hazard.anchorId] takes.
class Permit {
  Permit({
    required this.id,
    required this.title,
    this.status = 'required',
    this.confirmationNumber,
    this.link,
    this.note,
    this.documents = const [],
    this.segmentId,
    this.anchorId,
  }) : assert(segmentId == null || anchorId == null,
            'permit $id: segment_id and anchor_id are mutually exclusive');

  final String id;
  final String title;

  /// One of [kPermitStatuses].
  final String status;
  final String? confirmationNumber;

  /// A URL to the issuing authority's reservation, confirmation, or permit page.
  final String? link;
  final String? note;

  /// Scanned or downloaded permit/pass documents kept with the trip.
  final List<MediaRef> documents;

  /// Set when the permit is attached to a passage rather than an anchor or
  /// the whole trip.
  final String? segmentId;

  /// Set when the permit is attached to a promoted anchor rather than a
  /// passage or the whole trip. Mutually exclusive with [segmentId].
  final String? anchorId;

  bool get needsAttention => status != 'confirmed';

  Permit copyWith({
    String? title,
    String? status,
    String? confirmationNumber,
    bool clearConfirmationNumber = false,
    String? link,
    bool clearLink = false,
    String? note,
    bool clearNote = false,
    List<MediaRef>? documents,
  }) =>
      Permit(
        id: id,
        title: title ?? this.title,
        status: status ?? this.status,
        confirmationNumber:
            clearConfirmationNumber ? null : (confirmationNumber ?? this.confirmationNumber),
        link: clearLink ? null : (link ?? this.link),
        note: clearNote ? null : (note ?? this.note),
        documents: documents ?? this.documents,
        segmentId: segmentId,
        anchorId: anchorId,
      );

  factory Permit.fromJson(Map<String, dynamic> json) {
    final f = JsonFields(json, 'permit');
    final p = Permit(
      id: f.takeString('id')!,
      title: f.takeString('title')!,
      status: f.takeString('status') ?? 'required',
      confirmationNumber: f.takeString('confirmation_number'),
      link: f.takeString('link'),
      note: f.takeString('note'),
      documents: f.takeList('documents', MediaRef.fromJson),
      segmentId: f.takeString('segment_id'),
      anchorId: f.takeString('anchor_id'),
    );
    f.done();
    return p;
  }

  Map<String, dynamic> toJson() => pruneJson({
        'id': id,
        'title': title,
        'status': status,
        'confirmation_number': confirmationNumber,
        'link': link,
        'note': note,
        'documents': documents.isEmpty ? null : documents.map((d) => d.toJson()).toList(),
        'segment_id': segmentId,
        'anchor_id': anchorId,
      });
}
