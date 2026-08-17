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

---

## Plotlines repo notes (added on import, 2026-08-15)

Imported from the Claude Design project **"Plotlines - Design"**
(`https://claude.ai/design/p/29bd1f69-ef64-4208-8da4-7f38f5b7066f`), path
`flutter/plotlines_ui/`, via the Design MCP. Content is byte-for-byte the
upstream package apart from this section.

- The path in the snippet above (`path: flutter/plotlines_ui`) is the **upstream**
  layout. In this repo the package lives at `client/packages/plotlines_ui`, and
  `client/pubspec.yaml` declares `path: packages/plotlines_ui`.
- **The upstream "never compiled" warning above is discharged in this repo.**
  `flutter analyze` and `flutter test` both pass clean against this copy —
  `Color.withValues(alpha:)` and `ColorScheme`'s required-argument set were
  the two things worth checking, and both are fine on the SDK this repo pins.
  `flutter_lints` is `^6.0.0` here now, matching `client/pubspec.yaml` (was
  `^4.0.0` on import — reconciled).
- **Fonts are vendored, not fetched.** Unlike the upstream snippet above (which
  still calls `google_fonts`), this copy's `PlotTypography` reads local
  `fontFamily` names against `.ttf`s under `assets/fonts/`, declared in this
  package's own `pubspec.yaml` — desktop MVP is offline-first (ARCH P2), so a
  first run must never depend on reaching Google's CDN. `google_fonts` is not
  a dependency of this copy.
- Design reference for these components (brand guide, UI gallery, token CSS) is
  in `client/design/`.
