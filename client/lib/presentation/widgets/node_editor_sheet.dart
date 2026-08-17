// Wireframe screen "03 Node & Narrative" — curate a node: title, note,
// POI type/amenities, E2's narrative arc stage, and E4's authoring-only
// narration trigger distance (playback is field execution, out of scope —
// MVP doc §1.4.2).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plotlines_ui/plotlines_ui.dart';
import 'package:uuid/uuid.dart';

import '../../domain/domain.dart';
import '../../state/current_trip_provider.dart';

const _uuid = Uuid();
const _arcStages = ['exposition', 'rising', 'crux', 'climax', 'resolution'];
const _amenityChoices = ['water', 'toilets', 'food', 'shelter'];

/// Opens the editor for a brand-new node at [coord] on [segmentId], or an
/// existing [existing] node to revise.
Future<void> showNodeEditorSheet(
  BuildContext context, {
  required String dayId,
  required String segmentId,
  required Coord coord,
  Node? existing,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => DraggableScrollableSheet(
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => _NodeEditor(
        dayId: dayId,
        segmentId: segmentId,
        coord: coord,
        existing: existing,
        scrollController: scrollController,
      ),
    ),
  );
}

class _NodeEditor extends ConsumerStatefulWidget {
  const _NodeEditor({
    required this.dayId,
    required this.segmentId,
    required this.coord,
    required this.existing,
    required this.scrollController,
  });
  final String dayId;
  final String segmentId;
  final Coord coord;
  final Node? existing;
  final ScrollController scrollController;

  @override
  ConsumerState<_NodeEditor> createState() => _NodeEditorState();
}

class _NodeEditorState extends ConsumerState<_NodeEditor> {
  late final _title = TextEditingController(text: widget.existing?.title ?? '');
  late final _note = TextEditingController(text: widget.existing?.note ?? '');
  late final _poiType = TextEditingController(text: widget.existing?.poiType ?? '');
  late final _triggerDistance =
      TextEditingController(text: widget.existing?.narration?.triggerDistanceM.toString() ?? '');
  late NodeKind _kind = widget.existing?.kind ?? NodeKind.waypoint;
  late String? _arcStage = widget.existing?.arcStage;
  late final Set<String> _amenities = {...(widget.existing?.amenities ?? const [])};

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
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: ListView(
        controller: widget.scrollController,
        padding: const EdgeInsets.all(PlotSpacing.s5),
        children: [
          Text(widget.existing == null ? 'New node' : 'Edit node',
              style: PlotTypography.h2(c.textPrimary).copyWith(fontSize: 20)),
          const SizedBox(height: PlotSpacing.s2),
          Text(
            '${widget.coord[1].toStringAsFixed(5)}, ${widget.coord[0].toStringAsFixed(5)}',
            style: PlotTypography.data(c.textMuted),
          ),
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
            decoration: const InputDecoration(labelText: 'Trigger distance (m)', border: OutlineInputBorder()),
          ),
          const SizedBox(height: PlotSpacing.s5),
          PlotButton(label: 'Save node', expand: true, onPressed: _save),
        ],
      ),
    );
  }

  void _save() {
    final triggerM = double.tryParse(_triggerDistance.text);
    final node = Node(
      id: widget.existing?.id ?? _uuid.v4(),
      kind: _kind,
      coord: widget.coord,
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
    Navigator.pop(context);
  }
}
