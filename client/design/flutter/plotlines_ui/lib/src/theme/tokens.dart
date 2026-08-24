import 'package:flutter/widgets.dart';

/// Layout + shape tokens. 4px base rhythm; subtle corners; borders do the
/// structural work and shadows stay soft.
class PlotSpacing {
  PlotSpacing._();
  static const double s1 = 4;
  static const double s2 = 8;
  static const double s3 = 12;
  static const double s4 = 16;
  static const double s5 = 24;
  static const double s6 = 32;
  static const double s7 = 48;
  static const double s8 = 64;
  static const double s9 = 96;

  /// Minimum touch target — one-handed, gloved, in the field.
  static const double touchMin = 44;
}

class PlotRadii {
  PlotRadii._();
  static const Radius sm = Radius.circular(3);
  static const Radius md = Radius.circular(4); // default component corner
  static const Radius lg = Radius.circular(6); // cards
  static const Radius xl = Radius.circular(12);

  static const BorderRadius cardShape = BorderRadius.all(lg);
  static const BorderRadius controlShape = BorderRadius.all(md);

  static const double strokeMarker = 2; // icon + map-marker stroke width
}

class PlotElevation {
  PlotElevation._();
  static List<BoxShadow> soft(Color ink) => [
        BoxShadow(color: ink.withValues(alpha: 0.08), blurRadius: 8, offset: const Offset(0, 2)),
      ];
  static List<BoxShadow> lifted(Color ink) => [
        BoxShadow(color: ink.withValues(alpha: 0.12), blurRadius: 24, offset: const Offset(0, 8)),
      ];
}
