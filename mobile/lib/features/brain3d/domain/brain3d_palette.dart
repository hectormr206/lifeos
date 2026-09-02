/// Node colours for the memory graph.
///
/// Copied verbatim from the palette the laptop's `/brain3d` uses (and which the
/// deleted `assets/brain3d/brain3d.html` copied before it) — one consistent
/// brain across every surface. A memory that is pink on the laptop and blue on
/// the phone is a memory the user has to re-learn to read.
library;

import 'package:flutter/painting.dart';

const Map<String, Color> kDomainColors = {
  'relationships': Color(0xFFFF6B9D),
  'health': Color(0xFF22CC55),
  'finance': Color(0xFFFFAA33),
  'conversation': Color(0xFF33AAFF),
  'fact': Color(0xFF00D4AA),
  'event': Color(0xFFEE55FF),
  'meeting': Color(0xFFFF8844),
  'exercise': Color(0xFF44DDFF),
  'learning': Color(0xFFBBFF44),
  'spirituality': Color(0xFFFF44AA),
  'person': Color(0xFFFF6B9D),
  'reminder': Color(0xFFFFAA33),
  // Phone-side addition: the laptop never drew generic `entity` nodes, so it
  // has no colour for them. Periwinkle, far from fact-teal, person-pink and
  // event-magenta — the alternative was the fallback grey, which reads as "we
  // do not know what this is".
  'entity': Color(0xFF9B8CFF),
};

const Color kDefaultNodeColor = Color(0xFF888888);

/// Colour for a node, preferring its domain and falling back to its kind.
///
/// Grey rather than a guess for anything unrecognised: an invented colour would
/// read as a category that does not exist.
Color brain3dColorFor({String? domain, String? kind}) =>
    kDomainColors[domain] ?? kDomainColors[kind] ?? kDefaultNodeColor;
