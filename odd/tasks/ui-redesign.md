# UI redesign — "the axolotl's water"

Branch `feat/ui-redesign` (from `feat/english-model-settings` @ `40a2e688`). User request: "mejora la
interface, tienes un skill nuevo para eso" → scope chosen: **Todo** (whole Flutter app).
Skill: `frontend-design`. Flutter lives on devbox only: owned workspace `devbox:~/work/lifeos-ui/mobile`
(rsync from gama-dev, never the original devbox checkout). Baseline: 6/6 goldens pass there.

## Brief

- Subject: LifeOS, a private local-first life platform; Axi (an axolotl) is who you talk to.
- Audience: one person, daily, Android phone + Linux laptop, Spanish UI (English-learning area).
- Primary job: talk/type to Axi fast, see what is pending, find any record.
- Current state: stock Material 3 seeded from teal — mint everywhere, Roboto, outlined-button menus,
  cards + dividers, Axi's identity absent outside the Home avatar. No shared component library.

## Design plan

Concept: the app is the water, Axi is the creature in it. Pink belongs to Axi (Axi's voice, avatar,
bubbles); gill teal is for action; everything else is quiet ink on a skin-white page.

Color (light): page `#FBF5F4` (skin-white), ink `#14131F` (brand dark, Axi's eyes), muted ink
`#6B5560`, gill teal fill `#00D4AA` / teal text `#007159`, pink text `#C0155B`, Axi skin `#FE8FAF`
(bubble tint `#FFD9E3`). Outline `#8A7680` (3.9:1), divider `#BFAAB2` (2.0:1).
Color (dark — the user likes it; refine, do not repaint): page `#14131F`, ink `#F3EEF8`, muted
`#B7B2CC`, teal `#00D4AA`, pink `#FF4D88`, containers `#1A1927…#2E2B42`, outline `#8C88A0`,
divider `#4A4663`.

Type: Bricolage Grotesque (static instances opsz 36, wdth 92; 600/700/800) for display, headline and
titleLarge — the personality. Atkinson Hyperlegible Next (400/500/600/700 + 400 italic) for
everything read: titles M/S, body, labels. Body 17/26, 15/22, 13/18. Bundled (OFL), no runtime fetch.

Shape by hierarchy (not one radius everywhere): buttons stadium, page panels 24, grouped lists and
cards 16, inputs 14, chips 10, chat bubbles 20 with a 6 tail corner. Light theme uses a 1px divider
border instead of shadows; dark uses a lifted container.

Layout: content column max 600 wide, left-aligned, 20 gutters; grouped lists (settings-style inset
groups) replace stacks of outlined buttons and identical cards. Sentence-case section headers in
titleSmall weight, no tracking, no all caps.

Signature (the one bold thing): Axi's greeting on Home — Axi avatar beside a large Bricolage
time-of-day greeting, then the talk action. Axi's pink bubbles in chat carry the same identity.

Reviewed against the generic defaults: not cream+serif+terracotta (skin-white is Axi's own body
tint, sans display); not the SaaS card kit (grouped lists + radius hierarchy); no eyebrow caps, no
`→` buttons, no monospace labels. Motion: none added beyond existing behavior.

Non-goals: no navigation architecture change (no bottom bar/shell), no copy rewrites or l10n
migration beyond strings touched by a redesigned widget, no Brain3D canvas repaint (its dark graph
is intentional), no behavior changes.

## Tasks

- [x] T1 Design foundation: bundle fonts, rebuild `lifeos_theme.dart` (both schemes, type scale,
      component themes), `LifeOSPalette` ThemeExtension (success/warning/info + Axi skin), spacing
      constants, golden harness uses the real theme fonts; theme/contrast tests updated; goldens
      regenerated; `docs/design-system.md`.
- [x] T2 Shared components in `lib/core/widgets/`: section header, grouped list + row, page scaffold
      body (max-width column), empty state, scrollable-center; restyle offline/pending-sync banners
      off hardcoded `Colors.*`.
- [x] T3 Home redesign (greeting signature, grouped navigation, responsive width) + home golden.
- [x] T4 Chat redesign: bubbles (Axi pink / you quiet surface), day chip, composer, banners + chat golden.
- [x] T5 Mi vida, domains hub/list, reminders on shared components + goldens.
- [x] T6 English area screens on shared components.
- [x] T7 Settings hub + settings sub-screens (morning briefing hardcoded colors, backups, sync…).
- [x] T8 Remaining screens: onboarding, dictate, desahogo, body/insights/digest/meetings/briefings,
      lock screen; Brain3D panels only.
- [x] T9 Final visual QA light+dark goldens and full suite through independent verification.

## Evidence

- T1: `ea99f95f` feat(theme) + `docs(theme)` rationale restore. Worker RED (palette/fonts absent) ->
  GREEN 42 theme tests; theme+goldens 48/48; home/chat/body/morning_briefing/app 695/695 on devbox;
  analyze clean. Native review lineage `review-2d28872a3a194364` APPROVED + acknowledged (burned);
  3 non-blocking readability advisories (doc comments stripped -> restored).
- T2: `8027ece0` feat(ui) components. RED (missing widgets) -> GREEN 23/23; test/core+goldens 472/472
  (after fixing env: sync `shared/` too, keep `.flutter-plugins-dependencies`); banner-host screens
  594/594. Review `review-6c11e2201f3ec9fc` (medium, 1 lens) APPROVED + acknowledged.
- Devbox sync command (use this): rsync -a --delete --exclude build --exclude .dart_tool
  --exclude .flutter-plugins --exclude .flutter-plugins-dependencies mobile/ devbox:work/lifeos-ui/mobile/
  and rsync -a --delete shared/ (and parity/) to devbox:work/lifeos-ui/.
- T3: `572fa4dc` feat(home). RED 10 -> GREEN; home/app_update/first_day/goldens/app/l10n 249/249.
  Native review `review-2e461a4571466575` blocked (review-resilience empty output, stopReason length,
  6 relaunches — too many) -> user chose abandon + independent verify; abandoned (operator_disposition).
  Independent verify PASS: full suite 3959 pass/1 skip, sole failure = missing parity/ in export
  (passes 7/7 with it, same on base); analyzer 19 = base 19; no new hardcoded colors; fonts+OFL ok.
- T4: `063bf0d6` feat(chat). RED 6 -> GREEN 36/36; chat+goldens+redirects 397/397; analyze no new.
  Review `review-94544a49caad5245` (medium, 1 lens) APPROVED + acknowledged.
- T5: `9959fdc9` feat(records). Worker crashed once (model error) and was resumed. RED 5 -> GREEN
  32/32; records+goldens+redirects 256/256. Review `review-59220bf504fe610f` (medium) APPROVED + ack.
  Follow-up advisory R3-eager-reminder-list: reminders list is no longer lazy (GroupedList) — T9.
- T6: baseline English goldens captured first, then `b5336b60` feat(english): RED 5 -> GREEN; english
  480/480. Review `review-f9bd506f1f5cded5` APPROVED + ack; advisory (subtitle clamp hid info) fixed in
  `31244144` fix(ui) subtitleMaxLines (RED -> GREEN 37; 522/522), review `review-661c3ee96e6245d1` APPROVED + ack.
- T7a: `cd17b6b3` settings hub + briefing/digest/briefings; 432/432. Review `review-fd20517833d992cb` APPROVED + ack.
- T7b: `1b72fcd1` model/dictation/updates/permissions/timezone/web search/voice/catalog; RED 8 -> GREEN;
  688/688. Review `review-08389e326865e206` (high, 4 lenses) APPROVED + ack; 3 readability suggestions.
- T7c: `6b05f706` sync/backup/danger/memory graph; 302 tests (1 fixed via ensureVisible). Review
  `review-8c688fca5c0bb768` APPROVED + ack; advisory = eager graph list -> fixed in `07c00126`
  fix(ui) GroupedListView.builder (graph, reminders, conflict history lazy again; RED -> GREEN; 783/783;
  DEBUG ribbon removed from settings_b goldens). Review `review-447f0db77c32b073` APPROVED + ack.
- T8: `abc754c6` onboarding/lock/dictate/desahogo/brain3d chrome/model managers; RED 6 -> GREEN; 731/731.
  Review `review-4743a37f96811470` (high; 1 transport relaunch) APPROVED + ack. Legacy unreachable screens
  (Body/Insights/Meetings/MeetingDetail/Briefings/Connection/Digest/old GraphBrowser/GraphNode) left as-is.
- T9: `774f4ad7` style(theme) selection=primaryContainer, list titles w600, banner icon top-align,
  catalog hairlines, wide/dark QA goldens. Review `review-b01b3ecd70a38686` (high) -> correction_required
  on a FALSE deterministic claim (Dart String has operator *; test compiled and passed); applied the
  harmless 2-line rewrite `325665b4`, targeted validator APPROVED + ack. `f4903db1` braces 2 new
  analyzer infos; review `review-e72f82c049a10d61` APPROVED + ack.
  Final independent verify @325665b4: full suite 4073 pass / 0 fail / 1 skip; goldens 79/79; analyzer
  21 vs base 19 (the 2 new infos fixed in f4903db1, rechecked: 1 remaining = pre-existing); no color/
  fontSize leaks; diff 189 files +7833/-3469.
- (resolved) T9 polish backlog: SegmentedButton/chip selection uses pink secondaryContainer (should be teal
  primaryContainer); ListTile titles regular vs GroupedRow w600; StatusBanner icon should top-align on multi-line; catalog
  dividers darker than hairline; required_models_manager + english_models_manager still Colors.green
  and sit outside groups on the local-model screen (T8).
- Pending cleanup (rm -rf blocked by policy; needs user): devbox ~/work/lifeos-ui (owned sync copy),
  ~/work/lifeos-ui-verify{,-base}, ~/work/lifeos-ui-final{,-base}.
- Suggested follow-ups (not done): delete unreachable legacy screens (Body/Insights/Meetings/
  MeetingDetail/Briefings/Connection/Digest/old GraphBrowser/GraphNode); tracked
  mobile/test/goldens/failures/*.png (pre-existing at base) look like stale diff output; device QA
  on the Pixel + Linux build; chat app bar spans full width on desktop.

## Release 0.22.0 (2026-09-30, user: "haz las 3")

- Cleanup: devbox ~/work/lifeos-ui{,-verify,-verify-base,-final,-final-base} deleted.
- `4a29c7b6` chore(versión): 0.22.0 (review `review-96a20eead5e9248d` APPROVED + ack). Branch pushed;
  PR #167 -> sync-over-vpn-pr1-mesh-trust (main is 278 commits stale).
- Clean devbox clone from origin @4a29c7b6 (count 1049) with signing/OTA env copied 0600.
- Pixel 7 Pro 29291FDH300LVM: release APK sha aebe5b0c…, cert 247f9966… = installed; `install -r`
  0.20.1/1024 -> 0.22.0/1049, no uninstall. Screens checked dark+light with real data (evidence
  odd/reports/ui-redesign/pixel/). Restored theme Sistema and stay_on_while_plugged_in=0.
- Linux: release bundle under Xvfb (isolated HOME) renders Home two-pane with bundled fonts.
  Installed xvfb, x11-apps, imagemagick on devbox (apt) for this.
- Published: Android 0.22.0/1049 sha aebe5b0c… (byte-identical to the Pixel-tested APK); Linux x64
  0.22.0/1049 sha ec7b1d9a…; both live manifests re-read; /download 206. PR comment with evidence.
- Cleanup: secret copies in the release clone deleted; container-212 APK deleted. rm -rf of
  ~/work/lifeos-release (4.9G, no secrets) and /tmp/lifeos-linux-qa blocked by policy -> user.

## Follow-up after release (2026-09-30)

- Incident: Proxmox host rebooted ~10:00 UTC; devbox wg-quick@wg0 failed at boot (default route not
  yet up: "Nexthop has invalid gateway") -> mesh IP unreachable. Restarted the unit; OK. Unit already
  has After=network-online.target, so the race can recur on the next host reboot (not fixed).
  android-lab (212) stayed stopped by design (onboot: 0).
- `f4d77703` test(goldens): sync fixture dated relative to now (the golden drifted daily; my T7c defect).
- `27dd91a2` fix(home): backup + update notices scroll with Home; restart notice pinned. RED 4 -> GREEN;
  309/309. Review `review-f2a9632a1efd122e` (high) APPROVED + ack; 7 non-blocking advisories.
  Pushed to PR #167. NOT released (0.22.0 live still has the pinned notice).

## Release 0.22.1 — DONE 2026-09-30 (user: "Si hazlo" = publish 0.22.1)

Done:
- `602b9682` chore(versión): 0.22.1 (version 0.22.1+1052, count 1052). Review
  `review-626e6af2e56d0758` APPROVED + ack. Pushed to origin/feat/ui-redesign (PR #167).
- devbox clean clone `~/work/lifeos-release-0221` @602b9682. Release APK built there:
  sha a0e12426d559898f6512534443c39976bd663942b807d7f55efcc2ce8446a015, cert 247f9966…,
  versionCode 1052 / 0.22.1. Secret copies (key.properties, ota-publish.env) DELETED again.
- android-lab 212 was started for the Pixel test and stopped again (original state: stopped, onboot 0).
- Pixel test DONE (2026-09-30 ~17:03): APK sha a0e12426… verified inside 212, `install -r` 1049/0.22.0 ->
  1052/0.22.1 (no uninstall). Home: greeting -> CTA -> backup notice -> Tus registros; after a swipe the
  notice scrolls away with the content (evidence odd/reports/ui-redesign/pixel/30-home-0221*, 31-home-0221-scroll*).
  Restored stayon false (stay_on_while_plugged_in=0), APK copies removed from asus and 212, 212 stopped.
- devbox: ~/work/lifeos-release (clean @4a29c7b6, no secrets) and ~/work/lifeos-ui (scratch, no secrets)
  re-inspected; rm -rf blocked again by policy -> waiting for the user.

- User deleted devbox ~/work/lifeos-release and ~/work/lifeos-ui (6.4 GB free after).
- Secrets copied 0600 into the 0221 clone (gitignored), then deleted after publishing.
- Android: publish-to-vps.sh -> PUBLISHED 1052 / 0.22.1, APK sha a0e12426… (byte-identical to the
  Pixel-tested APK). Live manifest re-read: 1052 / 0.22.1; /download 206.
- Linux x64: publish-linux-to-vps.sh -> PUBLISHED 1052 / 0.22.1, tarball sha c2b4ad4ef909…; live
  linux/x64/manifest.json re-read: 1052 / 0.22.1, sha matches.
- PR #167 comment: https://github.com/hectormr206/lifeos/pull/167#issuecomment-5916528870
Live now: Android + Linux 0.22.1 / 1052. Logs on devbox ~/work/publish-{android,linux}-0221.log.
Other pending (user): merge PR #167; optional `sudo apt remove xvfb x11-apps imagemagick` on devbox;
devbox wg-quick@wg0 boot race after host reboots (restart the unit if the mesh IP 10.66.66.6 times out).

## Status

Closed 2026-09-30. All 9 tasks done on `feat/ui-redesign` (HEAD `f4903db1`). Pushed, PR #167 open, 0.22.0 released
on Android and Linux (user-authorized). Merge of #167 remains the user's decision.
