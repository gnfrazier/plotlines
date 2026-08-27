// D4a (FR78a, FR123) — the Author requests the specific profile fields and
// permissions a trip needs, adjusted from a default set, and sees per
// Character which fields were granted, declined, or volunteered unprompted.
//
// `domain/profile_request.dart` carries the full reasoning for why this is a
// session-only client model rather than a wire/`trip_payload.schema.json`
// type, and why there is no affordance here for the Author to directly mark
// a field granted/declined on a Character's behalf — FR78's "sharing is
// always an explicit Character action" (K2, not built in this app) means the
// honest state for a freshly added roster entry's requested fields is
// "pending" until a real response exists. What this tab *does* let the
// Author do — record a response, or a volunteered field — stands in for
// that not-yet-built Character-side surface (`recordResponse` on
// `ProfileRequestNotifier`) so the granted/declined/volunteered read model
// (`resolveCharacterStatuses`) is exercised against real data rather than
// staying permanently empty; it is explicitly framed as recording an answer
// received elsewhere ("what they told you"), not the app inventing consent.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../../domain/domain.dart';
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
    ref.read(profileRequestProvider.notifier).addCharacter(name);
    _nameController.clear();
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final state = ref.watch(profileRequestProvider);
    return ListView(
      padding: const EdgeInsets.all(PlotSpacing.s5),
      children: [
        Text('PROFILE & PERMISSIONS REQUEST',
            style: PlotTypography.h2(c.textPrimary).copyWith(fontSize: 16)),
        const SizedBox(height: PlotSpacing.s2),
        Text(
          'Choose what to ask each Character for this trip. Requesting never '
          'shares anything on its own — a Character grants, declines, or '
          'volunteers each field themselves.',
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
              child: _CharacterStatusCard(request: state.request, response: response),
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
  const _CharacterStatusCard({required this.request, required this.response});
  final FieldRequestSet request;
  final CharacterResponse response;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    final statuses = resolveCharacterStatuses(request, response);
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
                onPressed: () =>
                    ref.read(profileRequestProvider.notifier).removeCharacter(response.characterId),
              ),
            ],
          ),
          if (statuses.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: PlotSpacing.s2),
              child: Text('Nothing requested yet.', style: PlotTypography.small(c.textMuted)),
            ),
          for (final s in requested) _StatusRow(status: s, response: response, ref: ref),
          // D4a's AC: volunteered fields "surfaced prominently... nothing
          // shared for safety is buried" — a distinct block, not interleaved
          // with the requested rows above.
          if (volunteeredOutsideRequest.isNotEmpty) ...[
            const SizedBox(height: PlotSpacing.s2),
            Text('VOLUNTEERED UNPROMPTED',
                style: PlotTypography.data(c.textMuted).copyWith(fontWeight: FontWeight.w700, fontSize: 10)),
            for (final s in volunteeredOutsideRequest) _StatusRow(status: s, response: response, ref: ref),
          ],
          const SizedBox(height: PlotSpacing.s2),
          _AddVolunteeredField(request: request, response: response),
        ],
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.status, required this.response, required this.ref});
  final CharacterFieldStatus status;
  final CharacterResponse response;
  final WidgetRef ref;

  PlotBadge _badge() => switch (status.status) {
        ConsentStatus.granted => const PlotBadge('Granted', tone: PlotBadgeTone.spruce, solid: true),
        ConsentStatus.declined => const PlotBadge('Declined', tone: PlotBadgeTone.ember),
        ConsentStatus.requested => const PlotBadge('Pending', tone: PlotBadgeTone.gold, solid: true),
        ConsentStatus.volunteered => const PlotBadge('Volunteered', tone: PlotBadgeTone.blaze, solid: true),
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

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: PlotSpacing.s1),
      child: Row(
        children: [
          Expanded(child: Text(status.field.label, style: PlotTypography.body(c.textSecondary))),
          _badge(),
          if (status.status == ConsentStatus.requested || status.status == ConsentStatus.declined) ...[
            const SizedBox(width: PlotSpacing.s2),
            IconButton(
              tooltip: 'Record as granted',
              icon: Icon(Icons.check_circle_outline, size: 16, color: c.success),
              onPressed: () => _record(true),
            ),
          ],
          if (status.status == ConsentStatus.requested || status.status == ConsentStatus.granted)
            IconButton(
              tooltip: 'Record as declined',
              icon: Icon(Icons.cancel_outlined, size: 16, color: c.danger),
              onPressed: () => _record(false),
            ),
        ],
      ),
    );
  }
}

class _AddVolunteeredField extends ConsumerStatefulWidget {
  const _AddVolunteeredField({required this.request, required this.response});
  final FieldRequestSet request;
  final CharacterResponse response;

  @override
  ConsumerState<_AddVolunteeredField> createState() => _AddVolunteeredFieldState();
}

class _AddVolunteeredFieldState extends ConsumerState<_AddVolunteeredField> {
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
            decoration: const InputDecoration(labelText: 'Volunteer a field', isDense: true),
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
