// Wireframe screen "03 Node & Narrative" — curate a node: title, note,
// POI type/amenities, E2's narrative arc stage, and E4's authoring-only
// narration trigger distance (playback is field execution, out of scope —
// MVP doc §1.4.2).
//
// The field UI is [NodeEditorForm], shared by two containers: [showNodeEditorSheet]'s
// modal (Route tab's "tap map to add a node while routing" flow) and the Content
// tab's persistent drawer (`presentation/screens/plan_tabs/content_tab.dart`), which
// is the wireframe's actual container for this screen — a modal sheet was this
// repo's placeholder before the 2026-08-17 wireframe reconciliation.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plotlines_ui/plotlines_ui.dart';
import 'package:uuid/uuid.dart';

import '../../domain/domain.dart';
import '../../state/current_trip_provider.dart';
import '../../state/planner_ui_state.dart';
import '../../state/settings_provider.dart';
import '../map/route_geometry.dart';

const _uuid = Uuid();
const _arcStages = ['exposition', 'rising', 'crux', 'climax', 'resolution'];

/// #322 — the band a node's offset from the route has to fall in for "Snap to
/// route" to appear: closer than [_kSnapMinM] it is already on the line;
/// farther than [_kSnapMaxM] it was placed off-route deliberately and yanking
/// it onto the line would be a surprise, not a fix.
const double _kSnapMinM = 3;
const double _kSnapMaxM = 120;
// C5's seed set — one source of truth in domain/provision_node.dart.
const _amenityChoices = kKnownAmenities;

/// Opens the editor for a brand-new node at [coord] on [segmentId], or an
/// existing [existing] node to revise, as a modal sheet. Still used by the
/// Route tab's "Add node" affordance, which places a node while looking at
/// the map rather than switching to Content.
///
/// [routeGeometry] is the selected segment's solved line, when it has one — it
/// enables the "Snap to route" affordance (#322) for a node placed near but
/// not on the line. Resolves to the saved [Node] once the Author saves, or
/// `null` if the sheet is dismissed without saving, so the caller can select
/// and reveal what was just placed.
Future<Node?> showNodeEditorSheet(
  BuildContext context, {
  required String dayId,
  required String segmentId,
  required Coord coord,
  List<Coord>? routeGeometry,
  Node? existing,
}) {
  return showModalBottomSheet<Node>(
    context: context,
    isScrollControlled: true,
    builder: (context) => DraggableScrollableSheet(
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: NodeEditorForm(
          dayId: dayId,
          segmentId: segmentId,
          coord: coord,
          routeGeometry: routeGeometry,
          existing: existing,
          scrollController: scrollController,
          onSaved: (node) => Navigator.pop(context, node),
        ),
      ),
    ),
  );
}

/// The kind/title/note/POI/amenities/arc-stage/narration-trigger form itself,
/// container-agnostic: a modal sheet ([showNodeEditorSheet]) and the Content
/// tab's inline drawer both wrap this.
class NodeEditorForm extends ConsumerStatefulWidget {
  const NodeEditorForm({
    super.key,
    required this.dayId,
    required this.segmentId,
    required this.coord,
    required this.existing,
    required this.onSaved,
    this.routeGeometry,
    this.scrollController,
    this.trailing,
  });
  final String dayId;
  final String segmentId;
  final Coord coord;

  /// #322 — the selected segment's solved line, when it has one. Present ⇒ the
  /// form offers "Snap to route" while the node sits a short way off it.
  final List<Coord>? routeGeometry;

  final Node? existing;

  /// Called with the saved node after the domain state is updated — the
  /// container decides what to do next (pop a sheet, show a snackbar, …).
  final ValueChanged<Node> onSaved;
  final ScrollController? scrollController;

  /// Extra actions next to "Save node" (the Content tab drawer's close
  /// button lives here; the modal sheet has none).
  final Widget? trailing;

  @override
  ConsumerState<NodeEditorForm> createState() => _NodeEditorFormState();
}

class _NodeEditorFormState extends ConsumerState<NodeEditorForm> {
  late final _title = TextEditingController(text: widget.existing?.title ?? '');
  late final _note = TextEditingController(text: widget.existing?.note ?? '');
  late final _poiType = TextEditingController(text: widget.existing?.poiType ?? '');
  late final _triggerDistance =
      TextEditingController(text: _triggerAsInput());

  /// The stored narration trigger distance (canonical metres) as a bare
  /// number in the Author's active short-length unit — feet under imperial,
  /// metres otherwise (issue #312). Empty when no trigger is set.
  String _triggerAsInput() {
    final m = widget.existing?.narration?.triggerDistanceM;
    if (m == null) return '';
    final df = ref.read(displayFormatProvider);
    return df.useMiles ? df.smallLengthValue(m).toStringAsFixed(0) : m.toString();
  }
  late NodeKind _kind = widget.existing?.kind ?? NodeKind.waypoint;
  late String? _arcStage = widget.existing?.arcStage;
  late final Set<String> _amenities = {...(widget.existing?.amenities ?? const [])};

  /// The node's coordinate. Starts at what was tapped (or the existing node's
  /// own), and "Snap to route" (#322) moves it onto the line.
  late Coord _coord = widget.coord;

  @override
  void didUpdateWidget(covariant NodeEditorForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.existing?.id != widget.existing?.id) {
      _title.text = widget.existing?.title ?? '';
      _note.text = widget.existing?.note ?? '';
      _poiType.text = widget.existing?.poiType ?? '';
      _triggerDistance.text = _triggerAsInput();
      _kind = widget.existing?.kind ?? NodeKind.waypoint;
      _arcStage = widget.existing?.arcStage;
      _coord = widget.coord;
      _amenities
        ..clear()
        ..addAll(widget.existing?.amenities ?? const []);
    }
  }

  /// #322 — how far [_coord] sits off [NodeEditorForm.routeGeometry], and the
  /// point on the line to snap it to, when a "Snap to route" affordance makes
  /// sense: there is a line, and the node is off it by more than a trivial
  /// amount but not so far it was plainly placed off-route on purpose.
  ({Coord point, double distanceM})? get _snapTarget {
    final geom = widget.routeGeometry;
    if (geom == null || geom.length < 2) return null;
    final near = nearestPointOnPath(geom, _coord);
    if (near == null) return null;
    if (near.distanceM < _kSnapMinM || near.distanceM > _kSnapMaxM) return null;
    return near;
  }

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    _poiType.dispose();
    _triggerDistance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final df = ref.watch(displayFormatProvider);
    return ListView(
      controller: widget.scrollController,
      padding: const EdgeInsets.all(PlotSpacing.s5),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(widget.existing == null ? 'New node' : 'Edit node',
                  style: PlotTypography.h2(c.textPrimary).copyWith(fontSize: 20)),
            ),
            if (widget.trailing != null) widget.trailing!,
          ],
        ),
        const SizedBox(height: PlotSpacing.s2),
        Text(
          '${_coord[1].toStringAsFixed(5)}, ${_coord[0].toStringAsFixed(5)}',
          style: PlotTypography.data(c.textMuted),
        ),
        if (_snapTarget case final snap?) ...[
          const SizedBox(height: PlotSpacing.s2),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${df.smallLengthValue(snap.distanceM).toStringAsFixed(0)} '
                  '${df.smallLengthUnitLabel} off the route',
                  style: PlotTypography.small(c.textSecondary),
                ),
              ),
              const SizedBox(width: PlotSpacing.s2),
              PlotButton(
                label: 'Snap to route',
                variant: PlotButtonVariant.secondary,
                onPressed: () => setState(() => _coord = snap.point),
              ),
            ],
          ),
        ],
        const SizedBox(height: PlotSpacing.s4),
        Text('KIND', style: PlotTypography.data(c.textMuted).copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: PlotSpacing.s2),
        Wrap(
          spacing: PlotSpacing.s2,
          children: [
            for (final kind in NodeKind.values)
              ChoiceChip(
                label: Text(kind.wireValue.replaceAll('_', ' ')),
                selected: _kind == kind,
                onSelected: (_) => setState(() => _kind = kind),
              ),
          ],
        ),
        const SizedBox(height: PlotSpacing.s4),
        TextField(
          controller: _title,
          decoration: const InputDecoration(labelText: 'Title', border: OutlineInputBorder()),
        ),
        const SizedBox(height: PlotSpacing.s3),
        TextField(
          controller: _note,
          maxLines: 3,
          decoration: const InputDecoration(labelText: 'Note (Markdown)', border: OutlineInputBorder()),
        ),
        const SizedBox(height: PlotSpacing.s3),
        TextField(
          controller: _poiType,
          decoration: const InputDecoration(labelText: 'POI type (FR5)', border: OutlineInputBorder()),
        ),
        const SizedBox(height: PlotSpacing.s4),
        Text('AMENITIES (C5)', style: PlotTypography.data(c.textMuted).copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: PlotSpacing.s2),
        Wrap(
          spacing: PlotSpacing.s2,
          children: [
            for (final a in _amenityChoices)
              FilterChip(
                label: Text(a),
                selected: _amenities.contains(a),
                onSelected: (sel) => setState(() => sel ? _amenities.add(a) : _amenities.remove(a)),
              ),
          ],
        ),
        const SizedBox(height: PlotSpacing.s4),
        Text('NARRATIVE ARC (E2 / FR38)', style: PlotTypography.data(c.textMuted).copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: PlotSpacing.s2),
        Wrap(
          spacing: PlotSpacing.s2,
          children: [
            ChoiceChip(label: const Text('none'), selected: _arcStage == null, onSelected: (_) => setState(() => _arcStage = null)),
            for (final stage in _arcStages)
              ChoiceChip(
                label: Text(stage),
                selected: _arcStage == stage,
                onSelected: (_) => setState(() => _arcStage = stage),
              ),
          ],
        ),
        const SizedBox(height: PlotSpacing.s4),
        Text('NARRATION TRIGGER (E4 — authoring only)',
            style: PlotTypography.data(c.textMuted).copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: PlotSpacing.s2),
        Text('Playback is field execution and stays out of desktop MVP; this '
            'just records the distance a future field build should trigger at.',
            style: PlotTypography.small(c.textSecondary)),
        const SizedBox(height: PlotSpacing.s2),
        TextField(
          controller: _triggerDistance,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: 'Trigger distance (${df.smallLengthUnitLabel})',
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: PlotSpacing.s5),
        PlotButton(label: 'Save node', expand: true, onPressed: _save),
      ],
    );
  }

  void _save() {
    final triggerM = ref
        .read(displayFormatProvider)
        .parseSmallLengthToMetres(_triggerDistance.text);
    final node = Node(
      id: widget.existing?.id ?? _uuid.v4(),
      kind: _kind,
      coord: _coord,
      title: _title.text.trim().isEmpty ? null : _title.text.trim(),
      note: _note.text.trim().isEmpty ? null : _note.text.trim(),
      poiType: _poiType.text.trim().isEmpty ? null : _poiType.text.trim(),
      amenities: _amenities.toList(),
      arcStage: _arcStage,
      narration: triggerM == null ? null : Narration(triggerDistanceM: triggerM),
    );
    final notifier = ref.read(currentTripProvider.notifier);
    if (widget.existing == null) {
      notifier.addNodeToSegment(widget.dayId, widget.segmentId, node);
    } else {
      notifier.replaceNodeInSegment(widget.dayId, widget.segmentId, node);
    }
    // #322 / Q3(FR140) — a routing-constraint node (via / start / finish /
    // portage ends) invalidates a solved geometry the moment it is placed,
    // moved, or retyped into or out of a constraint kind. Mark the segment
    // stale; never silently re-solve (an Author mid-run of edits is stopped
    // zero times). `markSegmentStale` no-ops when nothing is solved yet.
    if (nodeKindIsRoutingConstraint(node.kind) ||
        (widget.existing != null &&
            nodeKindIsRoutingConstraint(widget.existing!.kind))) {
      notifier.markSegmentStale(widget.dayId, widget.segmentId);
    }
    widget.onSaved(node);
  }
}
