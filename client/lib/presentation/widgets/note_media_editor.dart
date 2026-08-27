// FR37 / E1 — the one editing surface for "rich notes and media," reused for
// all three content homes the AC names: a role (`anchor_promotion_panel.dart`),
// a passage/segment, and a day (both in `plan_tabs/content_tab.dart`). Kept
// as one widget rather than three near-identical ones so a future change to
// how media gets picked/captioned only has one call site to update.
library;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../domain/domain.dart';

/// FR37 — `MediaRef.kind` is one of the schema's five (`media_ref` $def):
/// image/audio/video/document/link. Inferred from the picked file's
/// extension so the Author isn't asked to classify every attachment by
/// hand; `document` is the fallback for anything unrecognised, since a
/// picked *file* (as opposed to a pasted URL) is never a bare `link`.
String mediaKindForPath(String path) {
  final ext = path.contains('.') ? path.split('.').last.toLowerCase() : '';
  const image = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'bmp'};
  const audio = {'mp3', 'wav', 'm4a', 'aac', 'ogg'};
  const video = {'mp4', 'mov', 'avi', 'mkv', 'webm'};
  if (image.contains(ext)) return 'image';
  if (audio.contains(ext)) return 'audio';
  if (video.contains(ext)) return 'video';
  return 'document';
}

/// A multiline note field plus an attach/remove list for media, writing
/// through [onNoteChanged]/[onMediaChanged] rather than holding its own
/// source of truth — the caller (role/passage/day) owns the data and
/// decides how it persists.
class NoteMediaEditor extends StatefulWidget {
  const NoteMediaEditor({
    super.key,
    required this.note,
    required this.media,
    required this.onNoteChanged,
    required this.onMediaChanged,
    this.noteLabel = 'Note',
  });

  final String? note;
  final List<MediaRef> media;
  final ValueChanged<String> onNoteChanged;
  final ValueChanged<List<MediaRef>> onMediaChanged;
  final String noteLabel;

  @override
  State<NoteMediaEditor> createState() => _NoteMediaEditorState();
}

class _NoteMediaEditorState extends State<NoteMediaEditor> {
  late final _note = TextEditingController(text: widget.note ?? '');

  @override
  void didUpdateWidget(covariant NoteMediaEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.note != widget.note && widget.note != _note.text) {
      _note.text = widget.note ?? '';
    }
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _addMedia() async {
    final file = await openFile();
    if (file == null) return;
    final ref = MediaRef(
      id: 'media-${DateTime.now().microsecondsSinceEpoch}',
      kind: mediaKindForPath(file.path),
      path: file.path,
      caption: file.name,
    );
    widget.onMediaChanged([...widget.media, ref]);
  }

  void _removeMedia(String id) =>
      widget.onMediaChanged(widget.media.where((m) => m.id != id).toList());

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _note,
          maxLines: 4,
          minLines: 2,
          decoration: InputDecoration(labelText: widget.noteLabel, border: const OutlineInputBorder()),
          onChanged: widget.onNoteChanged,
        ),
        const SizedBox(height: PlotSpacing.s2),
        Row(
          children: [
            Text('MEDIA', style: PlotTypography.data(c.textMuted).copyWith(fontWeight: FontWeight.w700)),
            const Spacer(),
            PlotButton(
              label: 'Attach',
              variant: PlotButtonVariant.ghost,
              icon: Icons.attach_file,
              onPressed: _addMedia,
            ),
          ],
        ),
        if (widget.media.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: PlotSpacing.s1),
            child: Text('No media attached.', style: PlotTypography.small(c.textMuted)),
          )
        else
          Wrap(
            spacing: PlotSpacing.s2,
            runSpacing: PlotSpacing.s2,
            children: [
              for (final m in widget.media)
                Chip(
                  avatar: Icon(_iconFor(m.kind), size: 16),
                  label: Text(m.caption ?? m.path, overflow: TextOverflow.ellipsis),
                  onDeleted: () => _removeMedia(m.id),
                ),
            ],
          ),
      ],
    );
  }

  IconData _iconFor(String kind) => switch (kind) {
        'image' => Icons.image_outlined,
        'audio' => Icons.audiotrack_outlined,
        'video' => Icons.videocam_outlined,
        'link' => Icons.link,
        _ => Icons.insert_drive_file_outlined,
      };
}
