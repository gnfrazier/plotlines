// FR140/FR140a (Story Q3) / Author Flows MVP Flow 6 "Narrative layering and
// outputs" — the stale list is its own surface, never routed through M13's
// shared error surface (`error_states.dart`): stale work is pending work the
// Author caused deliberately by editing, not a failure. Shown on an export
// (or, once print exists, a print) attempt while any route is stale; each
// item is individually resolvable (re-solve or drop), with re-solve-all as
// one unconfirmed action at the top since it destroys nothing — unlike
// dropping an item, which does confirm.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../domain/domain.dart';
import '../../state/current_trip_provider.dart';

/// Shows the stale list if [trip] has any stale route, and returns whether
/// the caller (export, eventually print) should proceed: true immediately
/// if nothing was stale to begin with, true once the Author has cleared
/// every item (by resolving or dropping it), false if they closed the
/// dialog with items still stale.
Future<bool> ensureNoStaleWork(BuildContext context, Trip trip) async {
  if (tripReadyToExport(trip)) return true;
  final proceeded = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => const _StaleListDialog(),
  );
  return proceeded ?? false;
}

class _StaleListDialog extends ConsumerStatefulWidget {
  const _StaleListDialog();

  @override
  ConsumerState<_StaleListDialog> createState() => _StaleListDialogState();
}

class _StaleListDialogState extends ConsumerState<_StaleListDialog> {
  bool _resolvingAll = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final trip = ref.watch(currentTripProvider);
    final items = tripStaleItems(trip);

    // FR140's own reason re-solve-all never confirms — it destroys nothing —
    // is exactly why clearing the list here can close the dialog on its
    // own rather than waiting for another tap: "after which the export
    // proceeds."
    if (items.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop(true);
      });
    }

    return AlertDialog(
      title: Text('${items.length} stale ${items.length == 1 ? 'route needs' : 'routes need'} re-solving',
          style: PlotTypography.title(c.textPrimary)),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'An edit changed what these were asked to solve for. Re-solve all at '
              'once, or resolve each on its own below.',
              style: PlotTypography.body(c.textSecondary),
            ),
            const SizedBox(height: PlotSpacing.s3),
            PlotButton(
              label: _resolvingAll ? 'Re-solving all…' : 'Re-solve all',
              expand: true,
              onPressed: _resolvingAll ? null : _resolveAll,
            ),
            if (_error != null) ...[
              const SizedBox(height: PlotSpacing.s2),
              Text(_error!, style: PlotTypography.small(c.danger)),
            ],
            const SizedBox(height: PlotSpacing.s3),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: SingleChildScrollView(
                child: Column(
                  children: [for (final item in items) _StaleRow(item: item)],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        PlotButton(
          label: 'Close',
          variant: PlotButtonVariant.ghost,
          onPressed: () => Navigator.pop(context, false),
        ),
      ],
    );
  }

  Future<void> _resolveAll() async {
    setState(() {
      _resolvingAll = true;
      _error = null;
    });
    try {
      await ref.read(currentTripProvider.notifier).resolveAllStale();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _resolvingAll = false);
    }
  }
}

class _StaleRow extends ConsumerStatefulWidget {
  const _StaleRow({required this.item});
  final StaleItem item;

  @override
  ConsumerState<_StaleRow> createState() => _StaleRowState();
}

class _StaleRowState extends ConsumerState<_StaleRow> {
  bool _resolving = false;
  String? _error;

  Future<void> _resolve() async {
    setState(() {
      _resolving = true;
      _error = null;
    });
    try {
      await ref
          .read(currentTripProvider.notifier)
          .regenerateSegment(widget.item.dayId, widget.item.segmentId);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  /// FR140's own callout: "where the list offers dropping an object instead
  /// of re-solving it, that action does confirm" — the one confirming step
  /// anywhere in this dialog.
  Future<void> _drop() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Drop this route?'),
        content: Text(
          '${widget.item.label} will be removed rather than re-solved. '
          'Its anchors survive unattached.',
        ),
        actions: [
          PlotButton(
            label: 'Keep',
            variant: PlotButtonVariant.ghost,
            onPressed: () => Navigator.pop(context, false),
          ),
          PlotButton(
            label: 'Drop',
            variant: PlotButtonVariant.danger,
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      ref.read(currentTripProvider.notifier).dropStaleSegment(widget.item.dayId, widget.item.segmentId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: PlotSpacing.s1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.sync_problem, size: 16, color: c.warning),
              const SizedBox(width: PlotSpacing.s2),
              Expanded(child: Text(widget.item.label, style: PlotTypography.data(c.textPrimary))),
              TextButton(
                onPressed: _resolving ? null : _resolve,
                child: Text(_resolving ? 'Re-solving…' : 'Re-solve'),
              ),
              TextButton(onPressed: _resolving ? null : _drop, child: const Text('Drop')),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(left: 24),
              child: Text(_error!, style: PlotTypography.small(c.danger)),
            ),
        ],
      ),
    );
  }
}
