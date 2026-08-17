// A10 (PRD FR96, ARCH §17 D32/Q10) — an Author with nothing downloaded is
// prompted for a starting location before anything can generate. Declining
// defaults to a rectangular bbox over Buncombe County, NC.
//
// Open question (tracked in the MVP doc): the region-download pipeline this
// should trigger — fetching a 100 km-radius OSM extract + DEM tile for an
// arbitrary Author-chosen location — is not built. `sidecar_manager.dart`'s
// cache-dir resolution still falls back to the fixed SPIKE-00 Boulder
// fixture regardless of what's chosen here. This dialog captures and
// persists the Author's choice (so the prompt only ever fires once) without
// blocking on the download it should eventually kick off.
library;

import 'package:flutter/material.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

const String kBuncombeCountyDefault = 'Buncombe County, NC (default)';

/// Returns the chosen location description, or null if the sheet was
/// dismissed without a choice (which should not count as "asked").
Future<String?> showFirstRunLocationDialog(BuildContext context) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (context) => const _FirstRunDialog(),
  );
}

class _FirstRunDialog extends StatefulWidget {
  const _FirstRunDialog();
  @override
  State<_FirstRunDialog> createState() => _FirstRunDialogState();
}

class _FirstRunDialogState extends State<_FirstRunDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return AlertDialog(
      title: Text('Where do you ride, hike, or paddle?', style: PlotTypography.title(c.textPrimary)),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'We\'ll download routable map data for a 100 km radius around '
              'this location so you can plan offline.',
              style: PlotTypography.body(c.textSecondary),
            ),
            const SizedBox(height: PlotSpacing.s4),
            TextField(
              controller: _controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'City + state, zip, or country + city',
                hintText: 'e.g. Boulder, CO',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        PlotButton(
          label: 'Use $kBuncombeCountyDefault',
          variant: PlotButtonVariant.ghost,
          onPressed: () => Navigator.pop(context, kBuncombeCountyDefault),
        ),
        PlotButton(label: 'Download', onPressed: _submit),
      ],
    );
  }

  void _submit() {
    final value = _controller.text.trim();
    Navigator.pop(context, value.isEmpty ? kBuncombeCountyDefault : value);
  }
}
