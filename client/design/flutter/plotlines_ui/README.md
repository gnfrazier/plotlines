# Plotlines UI (Flutter)

The Plotlines design system as a Flutter package. Material 3, themed to the
brand, adaptive across **Android, iOS, web, and desktop**. One import gives you
the theme, tokens, and every component.

```yaml
# pubspec.yaml
dependencies:
  plotlines_ui:
    path: flutter/plotlines_ui   # or a git/hosted ref
  google_fonts: ^6.2.1
```

```dart
import 'package:plotlines_ui/plotlines_ui.dart';

MaterialApp(
  theme: PlotTheme.light(),      // canvas cream + warm ink
  darkTheme: PlotTheme.dark(),   // warm dusk
  // For the outdoor high-contrast field mode, set theme: PlotTheme.highContrast()
  home: const HomeScreen(),
);
```

## Themes / modes
| Builder | Use |
|---|---|
| `PlotTheme.light()` | Default — canvas cream, warm ink |
| `PlotTheme.dark()` | Warm dusk dark mode |
| `PlotTheme.highContrast()` | Outdoor high-contrast — black field, white strokes, saturated accents. Toggleable, never the default. |

Colors resolve through a `PlotColors` theme extension, so widget code is
mode-agnostic: `final c = PlotColors.of(context);` then `c.primary`,
`c.textPrimary`, `c.success`, etc.

## Foundations
- **Type** — `PlotTypography`: Instrument Serif (display), Archivo (UI/body),
  JetBrains Mono (data). Loaded via `google_fonts`.
- **Spacing** — `PlotSpacing` on a 4px rhythm; `PlotSpacing.touchMin` = 44.
- **Shape** — `PlotRadii` (4px controls, 6px cards); `PlotElevation` soft shadows.

## Components
Standard: `PlotButton` (primary / secondary / ghost / danger), `PlotCard`,
`PlotBadge`, `PlotDialog` (confirm + bottom sheet), `PlotListTile`.

Brand: `NodeMarker` (six topographic map markers via CustomPainter),
`CueSheetRow`, `ElevationProfile`, `TripCard`.

## Accessibility notes baked in
- Primary (Blaze) buttons use a **≥16 bold** label with paper text so they clear
  WCAG contrast; ghost/text buttons use **Ink** labels, not Blaze, so small
  controls stay legible on canvas.
- **Gold** is only ever a fill or marker, never text.
- Every `NodeMarker` carries a distinct silhouette **plus** an internal mark, so
  shape (not color) carries the meaning.

## Example
See `example/lib/main.dart` — a one-screen gallery with a light/dark/HC toggle.

> Authored in a design tooling environment that can't compile Flutter, so this
> code has **not been run through `flutter analyze`/`flutter run`**. Treat it as
> a high-fidelity starting point; wire up a real Flutter project and verify.
