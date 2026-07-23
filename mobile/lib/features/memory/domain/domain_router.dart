/// On-device heuristic domain router (roadmap SLICE A3).
///
/// The laptop general-chat router (`axi/src/axi/chat_router.py`) is two-stage:
/// a fast LLM `classify_domain` picks a lane, then the domain spec confirms.
/// On-device we START with the cheap, deterministic HALF only: a keyword match
/// derived from each domain's `router_hint` (mirrored into
/// [DomainDescriptor.keywords]). This is intentionally conservative —
///
///   "the router picks the lane; the domain spec is the authority on its own
///    data. A misroute degrades to general conversation, never to wrong data."
///
/// So [routeDomain] returns a domain key ONLY when the signal is unambiguous
/// (one domain clearly dominates); otherwise it returns null (-> general chat,
/// no fact write, no wrong data).
///
/// C1 SEAM: the LLM `classify_domain` second opinion is NOT wired here (it
/// needs the on-device brain, a chat-presentation concern). C1 layers it on:
/// call [routeDomain] first (free, deterministic); when it returns null AND the
/// message looks like a fact worth saving ([looksLikePersonalRecall]), C1 may
/// ask the local model to classify using [DomainDescriptor.routerHint] as the
/// prompt lines — exactly `chat_router._build_router_system`. This file leaves
/// that hook open and never calls the model itself.
library;

import '../../domains/domain/domain_descriptor.dart';
import 'subject.dart';

/// The graph `domain` value stored on a fact for the given domain [key].
///
/// Calendar facts are stored as `'lifeos-events'` for wire-compat with the
/// laptop graph (`axi/src/axi/domain_bridge.py` uses that domain string); every
/// other domain stores its own key. A null/unknown key stays null (general).
String? graphDomainForKey(String? key) {
  if (key == null) return null;
  if (key == 'calendar') return 'lifeos-events';
  return key;
}

/// Domain keys this slice knows how to route to. Order is irrelevant — routing
/// is score-based, not first-match.
const Set<String> routableDomainKeys = <String>{
  'health',
  'finance',
  'exercise',
  'relationships',
  'learning',
  'spirituality',
  'calendar',
};

/// A deterministic keyword router over [domainDescriptors].
///
/// [routeDomain] folds accents + lowercases the message, then counts distinct
/// keyword hits per domain (word-boundary matches). It returns the single
/// dominant domain, or null when the outcome is ambiguous:
///   - zero hits -> null (general / no domain signal), or
///   - two-or-more domains tie for the top score -> null (ambiguous).
/// Null ALWAYS means "let general chat handle it" — never a wrong write.
class DomainRouter {
  const DomainRouter({List<DomainDescriptor>? descriptors})
      : _descriptors = descriptors ?? domainDescriptors;

  final List<DomainDescriptor> _descriptors;

  /// Route [message] to a domain key, or null when unclear/ambiguous.
  String? routeDomain(String message) {
    final folded = foldAccents(message.toLowerCase());
    if (folded.trim().isEmpty) return null;

    var bestKey = <String>[];
    var bestScore = 0;
    for (final d in _descriptors) {
      if (!routableDomainKeys.contains(d.key)) continue;
      final score = _score(folded, d.keywords);
      if (score == 0) continue;
      if (score > bestScore) {
        bestScore = score;
        bestKey = <String>[d.key];
      } else if (score == bestScore) {
        bestKey.add(d.key);
      }
    }
    if (bestScore == 0 || bestKey.length != 1) return null; // none or ambiguous
    return bestKey.first;
  }

  /// Number of distinct [keywords] that hit [foldedText] on a word boundary.
  int _score(String foldedText, List<String> keywords) {
    var hits = 0;
    for (final kw in keywords) {
      if (_wordBoundaryMatch(foldedText, kw)) hits++;
    }
    return hits;
  }

  static final Map<String, RegExp> _cache = <String, RegExp>{};

  bool _wordBoundaryMatch(String foldedText, String keyword) {
    final re = _cache[keyword] ??=
        RegExp(r'\b' + RegExp.escape(keyword) + r'\b', caseSensitive: false);
    return re.hasMatch(foldedText);
  }
}

// ---------------------------------------------------------------------------
// Personal-recall heuristic (ported from axi/src/axi/recall.py)
// ---------------------------------------------------------------------------

// Personal-health/finance/identity/family vocabulary (ES + EN). Ported from
// `_PERSONAL_RECALL_PATTERN`. Accent tolerance here comes from folding the
// input first (Python got it from explicit accent character classes), so every
// alternative below is written in its UNACCENTED form. Word boundaries prevent
// partial matches in unrelated words. Bare ambiguous EN tokens (gas, sugar,
// ran, felt) are intentionally omitted, matching the laptop.
final RegExp _personalRecallPattern = RegExp(
  <String>[
    // ES health / finance / exercise vocabulary
    'presion', 'pulso', 'dormi', 'dormir', 'dormido', 'sueno', 'dormiste',
    'peso', 'pesaba', 'pese', 'glucosa', 'azucar', 'gasto', 'gaste',
    'gasolina', 'ejercicio', 'corri', 'entrene', 'animo', 'humor', 'senti',
    'sentia', 'sintoma', 'medicamento', 'pastilla', r'frecuencia\s+cardiaca',
    // ES identity / family / relationships / biographical
    'espos[oa]', 'marido', 'mujer', 'pareja', 'novi[oa]s?', 'casad[oa]s?',
    'matrimonio', 'boda', 'aniversario', 'familia', 'hij[oa]s?',
    'herman[oa]s?', 'mama', 'papa', 'madre', 'padre', 'nombre', 'llamo',
    'cumpleanos', r'quien\s+soy', r'sobre\s+mi', r'de\s+mi', 'sabes',
    'recuerd[ao]s?', 'relacion',
    // EN identity / family
    'wife', 'husband', 'spouse', 'partner', 'girlfriend', 'boyfriend',
    'married', 'marriage', 'wedding', 'anniversary', 'family', 'son',
    'daughter', 'mother', 'father', 'brother', 'sister', r'my\s+name',
    r'about\s+me', r'who\s+am\s+i', 'remember', 'birthday',
    // EN health / finance vocabulary
    r'blood\s+pressure', 'pressure', 'pulse', r'heart\s+rate', 'slept',
    'sleep', 'sleeping', 'weight', 'weighed', 'glucose', r'blood\s+sugar',
    'expense', 'spent', 'gasoline', 'fuel', 'exercise', 'workout', 'mood',
    'symptoms?', 'medication', 'pill',
  ].map((p) => r'\b' + p + r'\b').join('|'),
  caseSensitive: false,
);

/// True when [text] mentions personal health/finance/identity vocabulary.
///
/// Cheap PRE-filter (ported from `recall.looks_like_personal_recall`) to tell a
/// personal-data query ("¿qué presión tenía cuando dormí mal?") from casual
/// chat ("hola Axi cómo estás"). Used by C1 to decide whether to build a recall
/// block / escalate to the LLM classifier — NOT a safety boundary on its own.
bool looksLikePersonalRecall(String text) =>
    _personalRecallPattern.hasMatch(foldAccents(text.toLowerCase()));
