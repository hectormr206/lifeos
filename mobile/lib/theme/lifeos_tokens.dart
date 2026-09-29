/// Spacing scale in logical pixels.
abstract final class Space {
  static const double xs = 4, sm = 8, md = 12, lg = 16;
  static const double xl = 20, xxl = 24, xxxl = 32, huge = 48;
}

/// Corner radii by surface hierarchy, in logical pixels.
abstract final class Radii {
  static const double chip = 10, input = 14, card = 16;
  static const double bubble = 20, bubbleTail = 6, panel = 24;
}

/// Maximum width of a page's readable content column.
const double kContentMaxWidth = 600;

/// Horizontal page inset on a phone.
const double kPageGutter = 20;
