# visionclass fairness notes (STAGING — nothing regenerated, nothing applied)

Scope: audit whether the ~0.83 (5/6) visionclass ceiling is a model weakness or an
asset-ambiguity artifact. Source of truth for the geometry: `ensure_posture_assets()`
in `scripts/bench/model_audit.py` (~line 4935) and `VISIONCLASS_PROMPT_ES` (~line 2712).
All six scenes are 256x256 side-view desk stick figures; the posture is encoded ONLY by
the spine polyline + head-circle center.

## Per-scene geometry (as shipped)

| label / case | spine polyline | head center | distinguishing cue |
|---|---|---|---|
| good (`vc-good-01`) | `(95,176)->(95,96)` straight vertical | `(95,74)` directly above spine | upright |
| good_2 (`vc-good-02`) | `(90,176)->(90,94)` straight vertical | `(90,72)` directly above spine | upright (near-duplicate of good) |
| slouched (`vc-slouched-01`) | `(95,176)->(98,140)->(116,116)->(136,106)` C-curve forward | `(150,106)` forward + low | curved spine, head forward AND low |
| forward_head (`vc-forward-01`) | `(95,176)->(95,100)` straight vertical | `(138,84)` forward, detached | straight spine, head juts forward |
| leaning (`vc-leaning-01`) | `(95,176)->(58,104)` tilted left | `(48,82)` far left | whole figure tilted to one side |
| not_at_desk (`vc-empty-01`) | none (empty chair) | none | no figure |

## Verdict

- **Reliably distinguishable:** `good`/`good_2`, `leaning`, `not_at_desk`. `leaning` puts
  the head on the OPPOSITE side (x=48) from every other scene; `not_at_desk` is an empty
  chair; `good` is a dead-vertical spine with the head centered on top. These three (four
  cases) are fair.
- **NOT reliably distinguishable — `forward_head` vs `slouched`.** Confirmed by geometry:
  both put the head forward at nearly the same location (slouched head `(150,106)`,
  forward_head head `(138,84)` — ~12 px apart in x, ~22 px in y). The ONLY real difference
  is spine curvature (curved C vs straight vertical), rendered at 6 px line width on a
  256 px canvas. On a crude stick figure this cue is not reliably perceivable, even to a
  human, so a miss here is an **asset-ambiguity artifact**, not a model weakness. This is
  the archetype the PRD flagged and is the most likely single source of the ~0.83 ceiling.
- **Prompt is fair.** `VISIONCLASS_PROMPT_ES` enumerates all six labels verbatim
  (`good`, `slouched`, `forward_head`, `leaning`, `not_at_desk`, `face_not_visible`), so
  models are not guessing synonyms and `in_labels` is not the source of the miss. No prompt
  change needed. (Note `face_not_visible` is an allowed label with no asset — harmless.)

## Recommendation

Prefer **(a) regenerate the two seated postures to exaggerate the geometric contrast** so
the cue is unambiguous, over dropping a label. Do NOT regenerate now — this is the exact
spec for a later asset pass (edit only the two `scene(...)` calls in
`ensure_posture_assets`; the PNGs are idempotent, so also delete the two stale files or
bump their names so they regenerate):

- **forward_head** — keep the spine dead-vertical AND keep the shoulders/back at x=95, but
  make the head unmistakably a HORIZONTAL neck jut at shoulder height: head center around
  `(150,96)` at the SAME y as the spine top, and draw an explicit horizontal neck segment
  `(95,100)->(134,96)` so the reader sees "upright back, head poked forward." No downward
  drop, no spine bend.
- **slouched** — round the WHOLE upper back into a pronounced C and DROP the head low, only
  mildly forward: spine e.g. `(95,176)->(100,150)->(118,132)->(132,128)`, head center
  around `(140,132)` (clearly LOWER than forward_head's head), and lower the shoulder/arm
  origin so the figure reads "collapsed downward" rather than "poked forward." The key
  separation is vertical: slouched head sits low, forward_head head sits high.

Fallback **(b)** if a later inspection still can't separate them on the stick-figure form:
collapse `forward_head` + `slouched` into a single label (e.g. `slouched`) and drop one of
the two cases (`vc-forward-01`), leaving a 5-case set — this removes the un-scoreable pair
at the cost of one posture distinction.

Optional cleanup: `good` and `good_2` are near-identical duplicates (both correct); harmless
but they add no discrimination. A later pass could make `good_2` a visibly different-but-still-
upright pose (e.g. slight recline) so the second good case is not a copy.
