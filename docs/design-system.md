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

## Typography

Both bundled OFL families are declared in `mobile/pubspec.yaml`, with no network
font fetching. Bricolage Grotesque (700–800) is for display, headlines and
`titleLarge`; Atkinson Hyperlegible Next is for `titleMedium/Small`, body and
labels. Body sizes/line heights: 17/26, 15/22, 13/18. Use the theme text styles
rather than local font declarations; they carry on-surface colors and weights.

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
