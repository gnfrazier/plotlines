// FR142(a) (Story K12), Flow 10 §01 — the undo affordance in the trip
// shell's app bar: labelled Undo and Redo that name the step they act on, and
// the session's history with its depth and its limits stated where the
// Author reads them — session-scoped, not a version history, derived work
// re-solved rather than undone, and Author-note deletion never undone.
//
// Ctrl+Z / Ctrl+Y (and Ctrl+Shift+Z, Cmd on macOS) act on the same history
// while no text field has focus; inside one, they stay the field's own.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../state/authoring_undo_provider.dart';

/// The fixed copy, kept in one place so the menu and its tests agree.
const undoSessionNotice =
    'History clears when you close the trip. It is not a version history.';
const undoDerivedNotice =
    'Routes, cue sheets, metrics and profiles are re-solved, not undone.';
const undoNotesNotice = 'Deleting what you hold about a person is never undone.';

class UndoControls extends ConsumerWidget {
  const UndoControls({super.key, this.compact = false});

  /// Icons without their words, for a narrow window — the tooltips still
  /// name the step, so the affordance stays labelled for a screen reader.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(authoringUndoProvider);
    final undo = ref.read(authoringUndoProvider.notifier);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: status.canUndo ? 'Undo: ${status.undoLabel}' : 'Nothing to undo',
          child: compact
              ? IconButton(
                  key: const ValueKey('undo-button'),
                  onPressed: status.canUndo ? undo.undo : null,
                  icon: const Icon(Icons.undo, size: 18),
                )
              : TextButton.icon(
                  key: const ValueKey('undo-button'),
                  onPressed: status.canUndo ? undo.undo : null,
                  icon: const Icon(Icons.undo, size: 18),
                  label: const Text('Undo'),
                ),
        ),
        Tooltip(
          message: status.canRedo ? 'Redo: ${status.redoLabel}' : 'Nothing to redo',
          child: compact
              ? IconButton(
                  key: const ValueKey('redo-button'),
                  onPressed: status.canRedo ? undo.redo : null,
                  icon: const Icon(Icons.redo, size: 18),
                )
              : TextButton.icon(
                  key: const ValueKey('redo-button'),
                  onPressed: status.canRedo ? undo.redo : null,
                  icon: const Icon(Icons.redo, size: 18),
                  label: const Text('Redo'),
                ),
        ),
        _HistoryMenu(status: status),
      ],
    );
  }
}

class _HistoryMenu extends StatelessWidget {
  const _HistoryMenu({required this.status});
  final UndoStatus status;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final n = status.history.length;
    return PopupMenuButton<void>(
      key: const ValueKey('undo-history'),
      tooltip: "This session's history",
      icon: const Icon(Icons.history, size: 18),
      itemBuilder: (context) => [
        PopupMenuItem<void>(
          enabled: false,
          child: Text('THIS SESSION · $n STEP${n == 1 ? '' : 'S'} · UP TO ${status.depth}',
              style: PlotTypography.data(c.textMuted)),
        ),
        if (n == 0)
          PopupMenuItem<void>(
            enabled: false,
            child: Text('Nothing to undo yet.', style: PlotTypography.body(c.textMuted)),
          ),
        // Newest first; the top one is what Undo reverses next.
        for (final label in status.history)
          PopupMenuItem<void>(
            enabled: false,
            height: 32,
            child: Text(label, style: PlotTypography.body(c.textPrimary)),
          ),
        const PopupMenuDivider(),
        PopupMenuItem<void>(
          enabled: false,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(undoSessionNotice, style: PlotTypography.small(c.textSecondary)),
                const SizedBox(height: PlotSpacing.s1),
                Text(undoDerivedNotice, style: PlotTypography.small(c.textSecondary)),
                const SizedBox(height: PlotSpacing.s1),
                Text(undoNotesNotice, style: PlotTypography.small(c.textSecondary)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Which history action, if any, [event] asks for: Ctrl/Cmd+Z undoes,
/// Ctrl/Cmd+Y and Ctrl/Cmd+Shift+Z redo.
enum UndoShortcut { undo, redo }

UndoShortcut? undoShortcutFor(KeyEvent event, HardwareKeyboard keyboard) {
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) return null;
  if (!(keyboard.isControlPressed || keyboard.isMetaPressed) || keyboard.isAltPressed) {
    return null;
  }
  final key = event.logicalKey;
  if (key == LogicalKeyboardKey.keyZ) {
    return keyboard.isShiftPressed ? UndoShortcut.redo : UndoShortcut.undo;
  }
  if (key == LogicalKeyboardKey.keyY && !keyboard.isShiftPressed) return UndoShortcut.redo;
  return null;
}

/// True while a text field holds focus — its own undo owns the keys then.
bool textFieldHasFocus() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  if (context.widget is EditableText) return true;
  return context.findAncestorStateOfType<EditableTextState>() != null;
}
