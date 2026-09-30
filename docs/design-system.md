# LifeOS design foundation

## Concept

The app is the water; Axi the axolotl is the creature in it. A quiet skin-white
page carries dark ink. Gill teal means action; pink belongs to Axi's voice,
avatar and bubbles. Dark mode keeps its familiar near-black water rather than
repainting the app. The expressive moment is Axi's greeting, not every card.

## Color

Use `Theme.of(context).colorScheme` for Material roles. These are the pinned
light / dark values (hex RGB); remaining error roles come from the teal seed.

| Role | Light | Dark |
| --- | --- | --- |
| surface / onSurface | FB F5 F4 / 14 13 1F | 14 13 1F / F3 EE F8 |
| onSurfaceVariant | 6B 55 60 | B7 B2 CC |
| primary / onPrimary | 00 71 59 / FF FF FF | 00 D4 AA / 14 13 1F |
| primaryContainer / on | CF F5 EA / 00 38 2B | 00 51 3F / 9F F2 DA |
| secondary / onSecondary | C0 15 5B / FF FF FF | FF 4D 88 / 14 13 1F |
| secondaryContainer / on | FF D9 E3 / 3E 0A 20 | 5C 1F 3A / FF D9 E3 |
| tertiary / onTertiary | C0 15 5B / FF FF FF | FE 8F AF / 14 13 1F |
| outline / outlineVariant | 8A 76 80 / BF AA B2 | 8C 88 A0 / 4A 46 63 |
| containers lowest → highest | FF FF FF, F7 EF EF, F2 E8 E9, ED E1 E3, E9 DA DD | 0F 0E 18, 1A 19 27, 20 1E 2E, 28 26 38, 2E 2B 42 |
| inverseSurface / on | 2B 2A 3A / F3 EE F8 | F3 EE F8 / 14 13 1F |
| inversePrimary | 00 D4 AA | 00 71 59 |

The bright `LifeOSColors.teal` fills primary actions in *both* themes with
dark ink. Light-mode text and icons use the darker scheme `primary` instead.

Pink is Axi-only. Selection states (selected segments, selected/checked chips)
use `primaryContainer` with `onPrimaryContainer`, never `secondary` pink; the
theme sets this for `SegmentedButton` and `ChoiceChip`/`FilterChip`.

## Typography

Both bundled OFL families are declared in `mobile/pubspec.yaml`, with no network
font fetching. Bricolage Grotesque (700–800) is for display, headlines and
`titleLarge`; Atkinson Hyperlegible Next is for `titleMedium/Small`, body and
labels. Body sizes/line heights: 17/26, 15/22, 13/18. Use the theme text styles
rather than local font declarations; they carry on-surface colors and weights.
List titles are `bodyLarge` at w600 and subtitles `bodyMedium` in
`onSurfaceVariant`; `ListTileTheme` carries both, so `GroupedRow` and plain
`ListTile`s match without local overrides.

## Shape and layout

Buttons are stadiums; panels and sheets have 24 px corners, grouped lists and
cards 16, inputs 14, chips 10, chat bubbles 20 (6 at the tail). Prefer a 1 px
hairline on light cards, lifted fill without borders in dark mode. `Space` in
`lifeos_tokens.dart` gives 4, 8, 12, 16, 20, 24, 32, 48 px steps; page gutters
are 20 px and the readable content column is at most 600 px, left-aligned.

## Additional semantic colors

`LifeOSPalette.of(context)` supplies Axi skin/bubble, hairline and readable
success, warning and info colors plus container/on-container pairs. It tracks
light and dark themes as a `ThemeExtension`; for a plain host theme it falls
back by brightness. For example:

```dart
final scheme = Theme.of(context).colorScheme;
final palette = LifeOSPalette.of(context);
// Icon(color: palette.success) on scheme.surface.
// Text(style: Theme.of(context).textTheme.bodyMedium) in a palette.axiBubble.
```

In feature widgets, avoid hardcoded `Colors.*`: use the color scheme or palette.
Use sentence-case section headers, no tracked uppercase eyebrow labels. Group
related rows rather than stacking identical cards or outlined buttons.

## Components

Import `package:lifeos/core/widgets/widgets.dart` for shared page elements:

| Widget | When to use | Example |
| --- | --- | --- |
| `PageBody` | Readable, centered page content with optional scrolling | `PageBody(children: [const Text('Today')])` |
| `ScrollableCenter` | Center a short loading/empty state inside a pull-to-refresh area | `ScrollableCenter(child: CircularProgressIndicator())` |
| `SectionHeader` | Sentence-case label for a group | `SectionHeader('Your records')` |
| `GroupedList` | Inset collection of related rows | `GroupedList(children: [GroupedRow(title: 'Health')])` |
| `GroupedRow` | A settings/navigation row with optional icon tone and action | `GroupedRow(title: 'Talk to Axi', tone: RowTone.axi, icon: Icons.chat, onTap: openChat)` |
| `EmptyState` | Explain a blank collection and suggest a next step | `EmptyState(icon: Icons.inbox, title: 'Nothing yet')` |
| `StatusBanner` | Semantic inline info, warning, success or error notice | `StatusBanner(tone: BannerTone.info, icon: Icons.info, message: Text('Saved'))` |
| `OfflineBanner` | Show the cached-data notice only while offline with cache | `OfflineBanner()` |
| `PendingSyncBanner` | Show a queued-mutation count only when nonzero | `PendingSyncBanner()` |

### Lazy lists

`GroupedList` builds every child eagerly, so use it only for short, fixed sections (settings, home). For collections that can grow without bound (memory nodes, reminders, history), use `GroupedListView.builder(itemCount:, itemBuilder:)`: it renders the same inset group lazily, with rounded outer corners, the hairline border and inset dividers drawn per row, and it keeps content within `kContentMaxWidth`. It accepts `padding`, `physics` (for example `AlwaysScrollableScrollPhysics` inside a `RefreshIndicator`), `controller` and an optional scrolling `header`.

## Golden updates

On a machine with Flutter, sync the mobile package to a dedicated devbox
workspace (not another developer's checkout), excluding `build` and `.dart_tool`:

```sh
rsync -a --delete --exclude build --exclude .dart_tool mobile/ devbox:work/lifeos-ui/mobile/
ssh devbox 'bash -lc "source ~/.buildenv.sh >/dev/null 2>&1; cd ~/work/lifeos-ui/mobile && timeout 900 flutter test test/goldens --update-goldens"'
rsync -a devbox:work/lifeos-ui/mobile/test/goldens/images/ mobile/test/goldens/images/
```

Only synchronize generated PNGs back; never manually edit them. Keep one
Flutter process running at a time and review the images for legible text.
