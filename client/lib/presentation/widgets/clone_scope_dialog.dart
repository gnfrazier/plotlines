// FR74b (Story G2b) — the scope picker shown before a trip is cloned. It
// offers the four scopes, and for the current selection it **states what the
// clone will and will not bring before the clone is created** — the carried /
// not-carried lists come straight from `describeClone` (`domain/clone.dart`),
// so the dialog cannot drift from the copy semantics it is describing.
library;

import 'package:flutter/material.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../domain/domain.dart';

/// The Author's choice from [showCloneScopeDialog].
class CloneRequest {
  const CloneRequest(this.scope, this.parts);
  final CloneScope scope;
  final CloneParts parts;
}

Future<CloneRequest?> showCloneScopeDialog(
  BuildContext context, {
  required String tripTitle,
}) {
  return showDialog<CloneRequest>(
    context: context,
    builder: (_) => _CloneScopeDialog(tripTitle: tripTitle),
  );
}

const _scopeLabels = {
  CloneScope.wholeTrip: 'Whole trip',
  CloneScope.rosterOnly: 'Roster only',
  CloneScope.authoredTripOnly: 'Authored trip only',
  CloneScope.perPart: 'Choose parts',
};

const _scopeBlurbs = {
  CloneScope.wholeTrip: 'The route and the people — same trip, ready to adjust.',
  CloneScope.rosterOnly: 'Same crew, new trip. Starts at the location prompt.',
  CloneScope.authoredTripOnly: 'Same route, new people. Starts with an empty roster.',
  CloneScope.perPart: 'Pick exactly what carries over.',
};

class _CloneScopeDialog extends StatefulWidget {
  const _CloneScopeDialog({required this.tripTitle});
  final String tripTitle;

  @override
  State<_CloneScopeDialog> createState() => _CloneScopeDialogState();
}

class _CloneScopeDialogState extends State<_CloneScopeDialog> {
  CloneScope _scope = CloneScope.wholeTrip;
  bool _partRoster = true;
  bool _partAuthored = true;

  CloneParts get _parts => CloneParts(roster: _partRoster, authoredTrip: _partAuthored);

  bool get _valid =>
      _scope != CloneScope.perPart || _partRoster || _partAuthored;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final manifest = describeClone(_scope, parts: _parts);

    return AlertDialog(
      title: Text('Clone "${widget.tripTitle}"',
          style: PlotTypography.title(c.textPrimary)),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RadioGroup<CloneScope>(
                groupValue: _scope,
                onChanged: (v) => setState(() => _scope = v!),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final scope in CloneScope.values)
                      RadioListTile<CloneScope>(
                        value: scope,
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(_scopeLabels[scope]!,
                            style: PlotTypography.body(c.textPrimary)
                                .copyWith(fontWeight: FontWeight.w700)),
                        subtitle: Text(_scopeBlurbs[scope]!,
                            style: PlotTypography.small(c.textMuted)),
                      ),
                  ],
                ),
              ),
              if (_scope == CloneScope.perPart)
                Padding(
                  padding: const EdgeInsets.only(left: PlotSpacing.s4),
                  child: Column(
                    children: [
                      CheckboxListTile(
                        value: _partAuthored,
                        onChanged: (v) => setState(() => _partAuthored = v ?? false),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text('Authored trip',
                            style: PlotTypography.body(c.textSecondary)),
                      ),
                      CheckboxListTile(
                        value: _partRoster,
                        onChanged: (v) => setState(() => _partRoster = v ?? false),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text('Roster',
                            style: PlotTypography.body(c.textSecondary)),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: PlotSpacing.s3),
              const Divider(height: 1),
              const SizedBox(height: PlotSpacing.s3),
              _ManifestList(
                heading: 'CARRIES',
                icon: Icons.check,
                tone: c.success,
                items: manifest.carried,
                emptyText: 'Nothing — pick at least one part.',
              ),
              const SizedBox(height: PlotSpacing.s3),
              _ManifestList(
                heading: 'DOES NOT CARRY',
                icon: Icons.block,
                tone: c.textMuted,
                items: manifest.notCarried,
              ),
              if (manifest.runsTripInitiation) ...[
                const SizedBox(height: PlotSpacing.s3),
                Text(
                  'This clone has no route to inherit, so it starts trip '
                  'initiation — location, area, and travel modes — like a new trip.',
                  style: PlotTypography.small(c.textSecondary),
                ),
              ],
            ],
          ),
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      actions: [
        PlotButton(
          label: 'Cancel',
          variant: PlotButtonVariant.ghost,
          onPressed: () => Navigator.pop(context),
        ),
        PlotButton(
          label: 'Clone',
          variant: PlotButtonVariant.primary,
          onPressed: _valid
              ? () => Navigator.pop(context, CloneRequest(_scope, _parts))
              : null,
        ),
      ],
    );
  }
}

class _ManifestList extends StatelessWidget {
  const _ManifestList({
    required this.heading,
    required this.icon,
    required this.tone,
    required this.items,
    this.emptyText,
  });

  final String heading;
  final IconData icon;
  final Color tone;
  final List<String> items;
  final String? emptyText;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(heading,
            style: PlotTypography.data(c.textMuted)
                .copyWith(fontWeight: FontWeight.w700, fontSize: 10)),
        const SizedBox(height: PlotSpacing.s1),
        if (items.isEmpty && emptyText != null)
          Text(emptyText!, style: PlotTypography.small(c.textMuted))
        else
          for (final item in items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, size: 14, color: tone),
                  const SizedBox(width: PlotSpacing.s2),
                  Expanded(
                    child: Text(item, style: PlotTypography.small(c.textSecondary)),
                  ),
                ],
              ),
            ),
      ],
    );
  }
}
