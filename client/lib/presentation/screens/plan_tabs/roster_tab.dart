// D4a (FR78a, FR123) — the Author requests the specific profile fields and
// permissions a trip needs, adjusted from a default set, and sees per
// Character which fields were granted, declined, or volunteered unprompted.
//
// D4b (FR78a) — the Author can also **fill in a field they already hold**
// from outside the app, per Character, without sending or resolving the
// request. Those values carry provenance (`entered by the Author`), never
// read as granted, never satisfy the pending request, and are superseded by
// a real Character response. They live in `currentRosterProvider`
// (`domain/roster.dart`'s `AuthorEnteredValue`) because — unlike the
// session-only request/response grid — they are authored data the Author
// holds: persisted with the trip and carried by a roster clone (FR74/FR74b).
// The session response grid and the persisted roster share one Character id
// (`ProfileRequestNotifier.addCharacter` returns it; this tab mirrors every
// add/remove into `currentRosterProvider`).
//
// `domain/profile_request.dart` carries the full reasoning for why the
// request/response half is a session-only client model rather than a
// wire/`trip_payload.schema.json` type, and why there is no affordance here
// for the Author to invent a grant on a Character's behalf — FR78's "sharing
// is always an explicit Character action" (K2, not built in this app). What
// this tab lets the Author do — record a response received elsewhere, record
// a volunteered field, or fill in a value they already hold — is framed as
// exactly that, not the app originating consent.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../../domain/domain.dart';
import '../../../state/current_roster_provider.dart';
import '../../../state/profile_request_provider.dart';

class RosterTab extends ConsumerStatefulWidget {
  const RosterTab({super.key});

  @override
  ConsumerState<RosterTab> createState() => _RosterTabState();
}

class _RosterTabState extends ConsumerState<RosterTab> {
  final _nameController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _addCharacter() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    // D4b — one identity across both stores: the session response grid and
    // the persisted roster the clone reads.
    final id = ref.read(profileRequestProvider.notifier).addCharacter(name);
    ref.read(currentRosterProvider.notifier).addEntry(id, name);
    _nameController.clear();
  }

  void _removeCharacter(String characterId) {
    ref.read(profileRequestProvider.notifier).removeCharacter(characterId);
    // D6a in miniature — the Author's own values for this Character go with
    // them, not left dangling.
    ref.read(currentRosterProvider.notifier).removeEntry(characterId);
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final state = ref.watch(profileRequestProvider);
    final roster = ref.watch(currentRosterProvider);
    return ListView(
      padding: const EdgeInsets.all(PlotSpacing.s5),
      children: [
        Text('PROFILE & PERMISSIONS REQUEST',
            style: PlotTypography.h2(c.textPrimary).copyWith(fontSize: 16)),
        const SizedBox(height: PlotSpacing.s2),
        Text(
          'Choose what to ask each Character for this trip. Requesting never '
          'shares anything on its own — a Character grants, declines, or '
          'volunteers each field themselves. Where you already hold a field '
          '(it came by text or email weeks ago), fill it in on the Character '
          'below; the request stays open until they respond.',
          style: PlotTypography.body(c.textMuted),
        ),
        const SizedBox(height: PlotSpacing.s4),
        _CatalogSection(
          title: 'PROFILE FIELDS',
          category: ProfileFieldCategory.profile,
          request: state.request,
        ),
        const SizedBox(height: PlotSpacing.s4),
        _CatalogSection(
          title: 'PERMISSIONS',
          category: ProfileFieldCategory.permission,
          request: state.request,
        ),
        const SizedBox(height: PlotSpacing.s5),
        Text('ROSTER', style: PlotTypography.data(c.textMuted).copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: PlotSpacing.s2),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Character name',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _addCharacter(),
              ),
            ),
            const SizedBox(width: PlotSpacing.s2),
            PlotButton(label: 'Add', variant: PlotButtonVariant.secondary, onPressed: _addCharacter),
          ],
        ),
        const SizedBox(height: PlotSpacing.s3),
        if (state.responses.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: PlotSpacing.s4),
            child: Text(
              'No Characters on this trip\'s roster yet — add one above to '
              'start tracking what they\'ve shared.',
              style: PlotTypography.body(c.textMuted),
            ),
          )
        else
          for (final response in state.responses)
            Padding(
              padding: const EdgeInsets.only(bottom: PlotSpacing.s3),
              child: _CharacterStatusCard(
                request: state.request,
                response: response,
                authorEntered: {
                  for (final v in roster.authorEnteredValues)
                    if (v.subjectCharacterId == response.characterId) v.fieldId: v.value,
                },
                onRemove: () => _removeCharacter(response.characterId),
              ),
            ),
      ],
    );
  }
}

class _CatalogSection extends ConsumerWidget {
  const _CatalogSection({required this.title, required this.category, required this.request});
  final String title;
  final ProfileFieldCategory category;
  final FieldRequestSet request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    final fields = defaultProfileFieldCatalog.where((f) => f.category == category).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: PlotTypography.data(c.textMuted).copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: PlotSpacing.s2),
        PlotCard(
          sunk: true,
          padding: const EdgeInsets.symmetric(vertical: PlotSpacing.s1),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              children: [
                for (final field in fields)
                  CheckboxListTile(
                    dense: true,
                    value: request.isRequested(field.id),
                    onChanged: (_) =>
                        ref.read(profileRequestProvider.notifier).toggleField(field.id),
                    title: Text(field.label, style: PlotTypography.body(c.textPrimary)),
                    subtitle: Text(field.description, style: PlotTypography.small(c.textMuted)),
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _CharacterStatusCard extends ConsumerWidget {
  const _CharacterStatusCard({
    required this.request,
    required this.response,
    required this.authorEntered,
    required this.onRemove,
  });
  final FieldRequestSet request;
  final CharacterResponse response;

  /// D4b — fieldId → the value the Author recorded for this Character.
  final Map<String, String> authorEntered;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    final statuses = resolveCharacterStatuses(
      request,
      response,
      authorEnteredFieldIds: authorEntered.keys.toSet(),
    );
    final volunteeredOutsideRequest = statuses.where((s) => s.status == ConsentStatus.volunteered);
    final requested = statuses.where((s) => s.status != ConsentStatus.volunteered);
    return PlotCard(
      padding: const EdgeInsets.all(PlotSpacing.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(response.characterName,
                    style: PlotTypography.body(c.textPrimary).copyWith(fontWeight: FontWeight.w700)),
              ),
              IconButton(
                tooltip: 'Remove ${response.characterName} from roster',
                icon: Icon(Icons.close, size: 16, color: c.textMuted),
                onPressed: onRemove,
              ),
            ],
          ),
          if (statuses.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: PlotSpacing.s2),
              child: Text('Nothing requested yet.', style: PlotTypography.small(c.textMuted)),
            ),
          for (final s in requested)
            _StatusRow(
              status: s,
              response: response,
              authorEnteredValue: authorEntered[s.field.id],
              ref: ref,
            ),
          // D4a's AC: volunteered fields "surfaced prominently... nothing
          // shared for safety is buried" — a distinct block, not interleaved
          // with the requested rows above.
          if (volunteeredOutsideRequest.isNotEmpty) ...[
            const SizedBox(height: PlotSpacing.s2),
            Text('VOLUNTEERED UNPROMPTED',
                style: PlotTypography.data(c.textMuted).copyWith(fontWeight: FontWeight.w700, fontSize: 10)),
            for (final s in volunteeredOutsideRequest)
              _StatusRow(
                status: s,
                response: response,
                authorEnteredValue: authorEntered[s.field.id],
                ref: ref,
              ),
          ],
          const SizedBox(height: PlotSpacing.s2),
          _RecordVolunteeredField(request: request, response: response),
        ],
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.status,
    required this.response,
    required this.authorEnteredValue,
    required this.ref,
  });
  final CharacterFieldStatus status;
  final CharacterResponse response;

  /// D4b — non-null when the Author has recorded a value for this field.
  final String? authorEnteredValue;
  final WidgetRef ref;

  PlotBadge _badge() => switch (status.status) {
        ConsentStatus.granted => const PlotBadge('Granted', tone: PlotBadgeTone.spruce, solid: true),
        ConsentStatus.declined => const PlotBadge('Declined', tone: PlotBadgeTone.ember),
        ConsentStatus.requested => const PlotBadge('Pending', tone: PlotBadgeTone.gold, solid: true),
        ConsentStatus.volunteered => const PlotBadge('Volunteered', tone: PlotBadgeTone.blaze, solid: true),
        // D4b — provenance, not consent: distinct from the green Granted fill,
        // and the row still carries the Pending badge so the outstanding
        // request is never hidden.
        ConsentStatus.authorEntered => const PlotBadge('Entered by you', tone: PlotBadgeTone.slate),
        ConsentStatus.notRequested => const PlotBadge('Not requested'),
      };

  void _record(bool? grant) {
    final grants = {...response.grants};
    if (grant == null) {
      grants.remove(status.field.id);
    } else {
      grants[status.field.id] = grant;
    }
    ref.read(profileRequestProvider.notifier).recordResponse(
          CharacterResponse(
            characterId: response.characterId,
            characterName: response.characterName,
            grants: grants,
            volunteeredFieldIds: response.volunteeredFieldIds,
          ),
        );
  }

  Future<void> _editValue(BuildContext context) async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _ValueDialog(
        fieldLabel: status.field.label,
        characterName: response.characterName,
        initial: authorEnteredValue ?? '',
      ),
    );
    if (result == null) return; // cancelled
    ref.read(currentRosterProvider.notifier).setAuthorEnteredValue(
          characterId: response.characterId,
          fieldId: status.field.id,
          value: result, // '' clears it
          nowIso: DateTime.now().toUtc().toIso8601String(),
        );
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final outstanding = requestOutstanding(status.status);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: PlotSpacing.s1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(status.field.label, style: PlotTypography.body(c.textSecondary))),
              if (status.status == ConsentStatus.authorEntered) ...[
                const PlotBadge('Pending', tone: PlotBadgeTone.gold, solid: true),
                const SizedBox(width: PlotSpacing.s1),
              ],
              _badge(),
              // Recording a Character's spoken answer stays available even
              // once the Author has filled a value in — the value never
              // satisfies the request (D4b).
              if (status.status == ConsentStatus.requested ||
                  status.status == ConsentStatus.declined ||
                  status.status == ConsentStatus.authorEntered) ...[
                const SizedBox(width: PlotSpacing.s2),
                IconButton(
                  tooltip: 'Record as granted',
                  icon: Icon(Icons.check_circle_outline, size: 16, color: c.success),
                  onPressed: () => _record(true),
                ),
              ],
              if (status.status == ConsentStatus.requested ||
                  status.status == ConsentStatus.granted ||
                  status.status == ConsentStatus.authorEntered)
                IconButton(
                  tooltip: 'Record as declined',
                  icon: Icon(Icons.cancel_outlined, size: 16, color: c.danger),
                  onPressed: () => _record(false),
                ),
              // D4b — fill in / edit / clear a value the Author already holds.
              // Only where the request is still open: once a Character has
              // granted, declined, or volunteered, their answer stands.
              if (outstanding)
                IconButton(
                  tooltip: authorEnteredValue == null
                      ? 'Fill in what they already told you'
                      : 'Edit what you entered',
                  icon: Icon(
                    authorEnteredValue == null ? Icons.edit_outlined : Icons.edit,
                    size: 16,
                    color: c.textMuted,
                  ),
                  onPressed: () => _editValue(context),
                ),
            ],
          ),
          if (status.status == ConsentStatus.authorEntered && authorEnteredValue != null)
            Padding(
              padding: const EdgeInsets.only(left: PlotSpacing.s1, top: 2),
              child: Text(
                authorEnteredValue!,
                style: PlotTypography.small(c.textMuted),
              ),
            ),
        ],
      ),
    );
  }
}

/// D4b — a plain editor for a value the Author already holds. Pops `null` on
/// cancel, `''` on Clear, or the trimmed text on Save. The value is shown and
/// stored as data, never composed into a sentence (FR145).
class _ValueDialog extends StatefulWidget {
  const _ValueDialog({
    required this.fieldLabel,
    required this.characterName,
    required this.initial,
  });
  final String fieldLabel;
  final String characterName;
  final String initial;

  @override
  State<_ValueDialog> createState() => _ValueDialogState();
}

class _ValueDialogState extends State<_ValueDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return AlertDialog(
      title: Text('${widget.fieldLabel} — ${widget.characterName}',
          style: PlotTypography.h2(c.textPrimary).copyWith(fontSize: 16)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'A value you already hold. This does not answer the request — '
            '${widget.characterName} can still grant, decline, or change it, '
            'and their response replaces what you entered.',
            style: PlotTypography.small(c.textMuted),
          ),
          const SizedBox(height: PlotSpacing.s3),
          TextField(
            controller: _controller,
            autofocus: true,
            minLines: 1,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Value',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        if (widget.initial.isNotEmpty)
          TextButton(
            onPressed: () => Navigator.of(context).pop(''),
            child: const Text('Clear'),
          ),
        PlotButton(
          label: 'Save',
          variant: PlotButtonVariant.secondary,
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
        ),
      ],
    );
  }
}

class _RecordVolunteeredField extends ConsumerStatefulWidget {
  const _RecordVolunteeredField({required this.request, required this.response});
  final FieldRequestSet request;
  final CharacterResponse response;

  @override
  ConsumerState<_RecordVolunteeredField> createState() => _RecordVolunteeredFieldState();
}

class _RecordVolunteeredFieldState extends ConsumerState<_RecordVolunteeredField> {
  String? _pending;

  @override
  Widget build(BuildContext context) {
    final available = defaultProfileFieldCatalog
        .where((f) => !widget.response.volunteeredFieldIds.contains(f.id))
        .toList();
    return Row(
      children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            initialValue: _pending,
            isDense: true,
            // Volunteering is a Character action (FR78); this records one the
            // Author heard about elsewhere, it does not originate it.
            decoration: const InputDecoration(
                labelText: 'Record a field they volunteered', isDense: true),
            items: [
              for (final f in available) DropdownMenuItem(value: f.id, child: Text(f.label)),
            ],
            onChanged: (v) => setState(() => _pending = v),
          ),
        ),
        const SizedBox(width: PlotSpacing.s2),
        PlotButton(
          label: 'Add',
          variant: PlotButtonVariant.ghost,
          onPressed: _pending == null
              ? null
              : () {
                  ref.read(profileRequestProvider.notifier).recordResponse(
                        CharacterResponse(
                          characterId: widget.response.characterId,
                          characterName: widget.response.characterName,
                          grants: widget.response.grants,
                          volunteeredFieldIds: {...widget.response.volunteeredFieldIds, _pending!},
                        ),
                      );
                  setState(() => _pending = null);
                },
        ),
      ],
    );
  }
}
