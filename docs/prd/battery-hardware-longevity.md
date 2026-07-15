# PRD — Battery & Hardware Longevity Guardian

- **Status:** Documented pending — awaiting greenlight from Héctor
- **Date:** 2026-07-15
- **Owner surface:** Axi interoception organ (laptop first), mobile app later
- **Repo:** `lifeos` (`axi/` daemon + `mobile/` Flutter app)

---

## 1. Problem statement

Héctor's laptop is a <1-year-old gaming machine (Thunderobot RS, RTX 5070 Ti,
CachyOS) that doubles as a 24x7 HomeLab: always plugged in at 100% charge,
running games, Axi's morning news, remote phone answering, and nightly
self-development jobs. High temperatures are frequent (gaming + LLM inference).

**Always-plugged at 100% SoC + sustained heat is the single worst combination
for Li-ion battery longevity** — it accelerates calendar aging, permanent
capacity fade, and is the main precursor to battery swelling. The laptop also
carries other wear-limited components (NVMe SSDs, fans, GPU/CPU thermal paste)
whose degradation is currently invisible to Axi.

Axi already *nudges* about battery care (unplug after N days at full, replug at
40%), but nudging is reactive and depends on Héctor physically acting. The goal
is to make Axi a **guardian**: enforce a healthy charge window automatically
where possible, adapt policy to context (home vs. travel), and become conscious
of the lifespan of every hardware component it lives in.

## 2. User stories (Héctor's exact scenarios)

1. *As Héctor*, my laptop lives plugged in 24x7 as a HomeLab; I want the
   battery kept in a healthy charge window (60–80%) **without me thinking
   about it**, so it doesn't swell or die early.
2. *As Héctor*, when Axi can't control charging directly, I want it to track
   how long I've been plugged in at full and tell me *when* to unplug and
   *when* to replug (threshold-based), so manual care is at least guided.
   (Already partially shipped — see §4.)
3. *As Héctor*, when I'm at home or at my in-laws (known Wi-Fi SSIDs where I
   stay long periods), cap the charge at 60–80%; when I'm on an unknown
   network (traveling), charge to 100% because I'll need the full battery.
   I also want a manual override ("voy a viajar") to force 100% ahead of a trip.
4. *As Héctor*, I want Axi to be conscious of **all** hardware component
   lifespans — battery wear, SSD wear, fan hours, thermal history — so it can
   tell me when a replacement is coming and act to prevent damage before it
   happens.
5. *As Héctor*, I want this surfaced on my phone too (the LifeOS mobile app),
   since I often interact with Axi remotely.

## 3. Evidence summary — Li-ion longevity facts (verified, with sources)

### 3.1 The facts

| # | Fact | Evidence |
|---|------|----------|
| 1 | **High SoC + heat is the worst case.** Li-ion stored at 100% SoC at 40 °C retains only ~65% capacity after 1 year (vs. ~85% if stored at 40% SoC at the same temperature). At 60 °C and 100% SoC, capacity drops to ~60% in just **3 months**. "Exposing the battery to high temperature and dwelling in a full state-of-charge for an extended time can be more stressful than cycling." | [Battery University BU-808, Table 3](https://www.batteryuniversity.com/article/bu-808-how-to-prolong-lithium-based-batteries/) |
| 2 | **Lower peak charge voltage multiplies cycle life.** ~4.20 V/cell (100%) → 300–500 cycles; 4.00 V/cell (~75–80%) → 850–1,500 cycles; 3.92 V/cell → 1,200–2,000 cycles. Rule of thumb: every −0.10 V/cell of peak charge voltage roughly **doubles** cycle life. This is the entire physical basis of the 60–80% cap. | [BU-808, Table 4](https://www.batteryuniversity.com/article/bu-808-how-to-prolong-lithium-based-batteries/) |
| 3 | **Shallow cycling beats deep cycling.** Cycles to 70% capacity (NMC): 100% DoD ≈ 300 cycles; 40% DoD ≈ 1,000; 20% DoD ≈ 2,000; 10% DoD ≈ 6,000. Keeping the battery in a mid-range window (≈20–80%, ideally 40–80%) minimizes both cycle and calendar stress. | [BU-808, Table 2](https://www.batteryuniversity.com/article/bu-808-how-to-prolong-lithium-based-batteries/); [40–80 rule overview](https://udpwr.com/blogs/portable-power-station-knowledge/40-80-rule-for-lithium-ion-batteries) |
| 4 | **Calendar aging vs. cycle aging:** a battery ages even when unused, and calendar aging is governed by *SoC and temperature*, not use. A 24x7-plugged laptop suffers almost pure calendar aging at the worst possible operating point (100% SoC, elevated temp). Largest permanent capacity losses are recorded at high charge voltage, high SoC, and elevated temperature. | [BU-808](https://www.batteryuniversity.com/article/bu-808-how-to-prolong-lithium-based-batteries/); [ScienceDirect — high-temperature calendar aging & optimal SoC ranges](https://www.sciencedirect.com/science/article/abs/pii/S2352152X25017013) |
| 5 | **Swelling** is driven by electrolyte decomposition and gas generation, accelerated by exactly these two factors: dwelling at high voltage (full charge) and heat. A hot gaming laptop pinned at 100% is the textbook swelling scenario. | [BU-808](https://www.batteryuniversity.com/article/bu-808-how-to-prolong-lithium-based-batteries/); [Large Battery — aging → swelling/safety](https://www.large-battery.com/blog/lithium-battery-degradation-performance-safety/) |

### 3.2 Correcting a misconception (respectfully, with evidence)

The belief that Li-ion needs **periodic full charge/discharge cycles** ("hay
que ciclarla") is a holdover from Ni-Cd/Ni-MH memory-effect batteries. It is
**not true for Li-ion — and it's actively harmful**:

> "Partial discharge on Li-ion is fine. **There is no memory and the battery
> does not need periodic full discharge cycles to prolong life.**"
> — [Battery University BU-808](https://www.batteryuniversity.com/article/bu-808-how-to-prolong-lithium-based-batteries/)

Deep discharges (100% DoD) are the *most* stressful cycling regime (Fact 3).
The only legitimate reason to run an occasional full cycle is to let the
battery's fuel gauge **recalibrate** its percentage estimate (once every few
months at most) — it does nothing for battery health itself.

Consequence for this PRD: the existing "replug at 40%" advisor is correct as a
*floor*; the design must never encourage draining to near-0% "to exercise the
battery."

### 3.3 Best practice for 24x7 plugged-in laptops (laptop-as-homelab)

Consensus across sources (BU-808's proposed "Long Life" mode ≈ 4.05 V/cell;
vendor implementations like Lenovo Conservation Mode, ASUS Battery Health
Charging, TUXEDO charging profiles — see
[TLP battery-care vendor matrix](https://linrunner.de/tlp/settings/bc-vendors.html)
and [TUXEDO charging profiles](https://www.tuxedocomputers.com/en/Battery-charging-profiles-inside-the-TUXEDO-Control-Center.tuxedo)):

- Cap charge at **~60–80%** when permanently on AC. (Vendors ship 60% "max
  lifespan" and 80% "balanced" presets.)
- Keep the battery **cool**: elevate the laptop for airflow / use a cooling
  stand; heat compounds every other stressor. On a gaming laptop the battery
  often sits next to hot components, so chassis thermals matter directly.
- Avoid both extremes: don't park at 100%, don't deep-discharge.
- If charge capping is impossible and the machine truly never moves, removing
  the battery (storage at ~40–60% in a cool place) is the extreme fallback —
  not proposed here, but it frames the design space.

## 4. Current-state map — what Axi already does

All in `axi/src/axi/` (laptop daemon):

| Capability | Where | Detail |
|---|---|---|
| Power-source detection | `power.py` | `power_state()` → `ac`/`battery`; `on_battery()`; `battery_scaled()` slows daemon loops on battery |
| Battery vitals snapshot | `interoception.py` `_battery_snapshot()` | Reads sysfs BAT0: `battery_pct`, `battery_status`, `battery_health_pct` (charge_full / charge_full_design), `battery_cycles` (cycle_count) |
| **Battery-care advisor** | `interoception.py` `battery_alerts()` | UNPLUG nudge: plugged + ≥98% (`BATTERY_FULL_PCT`) continuously for `body_battery_full_days` (default 7) days → desktop notification. REPLUG nudge: discharging at ≤ `body_battery_replug_pct` (default 40%). Severity `normal`; deferred during meetings AND game mode. `full_since` persisted in `interoception_battery.json` (survives restarts) |
| Config keys | `config_schema.py` | `body_battery_care_enabled` (bool, true), `body_battery_full_days` (int, 7), `body_battery_replug_pct` (int, 40), `battery_loop_slowdown_factor` (int, 4); thermal keys `body_gpu_temp_max_c` (85), `body_cpu_temp_max_c` (90), game-mode recalibration `body_game_gpu_temp_max_c` (92), `body_game_cpu_temp_max_c` (95); `body_check_interval_s` (120) |
| Thermal/VRAM/disk alerts | `interoception.py` vital rules | GPU/CPU temp episodes with hysteresis, VRAM near-full, disk low; meeting suppression + game-mode threshold recalibration |
| Alert delivery | `interoception.py` `_notify()` | Desktop notification ("Axi" channel), independent of the autonomous tick's daily cap |
| Organs registry | `organs.py`, `/api/organs` (`dashboard.py`, `api_v1.py`) | Declarative organ list (Spanish organ metaphor); interoception = Pulmones (vitals) + Olfato (anomaly sniffing) |
| Network identity | `feet.py` `_net_name()` | Active connection name via `nmcli -t -f NAME,TYPE,DEVICE` — **the SSID-detection primitive for P2 already exists** |
| Mobile mirror | `mobile/` (Flutter) | Mirrors laptop surfaces; reminders/notifications path exists |

**Gap:** everything today is *advice* (notifications). Nothing *controls*
charging, nothing understands context (home vs. travel), and hardware wear
beyond instantaneous temps is not tracked over time.

## 5. Hardware findings — Héctor's exact machine (verified on-device, 2026-07-15)

| Item | Value |
|---|---|
| Vendor / product | `THUNDEROBOT` / `RS` (board `RS`, family `RS Series`, BIOS `N.1.17THU10`) |
| Kernel | `7.1.3-2-cachyos` |
| Battery sysfs | `/sys/class/power_supply/BAT0/` — has `capacity`, `status`, `charge_full`, `charge_full_design`, `charge_now`, `cycle_count`, `voltage_now` |
| **`charge_control_end_threshold`** | **ABSENT** — no native charge-cap knob exposed today |
| `charge_behaviour` / `charge_type` | Absent |
| EC telemetry quality | **Unreliable:** `charge_full` == `charge_full_design` == 5,200,000 µAh (reports 0% wear after ~1 year of the worst-case regime — implausible) and `cycle_count` == 0. The EC does not track wear or cycles. |
| ODM identity | The Uniwill/Tongfang WMI GUIDs `ABBC0F6A…ABBC0F72` are present in `/sys/bus/wmi/devices/` — this Thunderobot RS is a **Tongfang/Uniwill barebone** (same ODM family as TUXEDO/Schenker/XMG machines) |
| In-tree driver | Kernel 7.1 ships `uniwill-laptop.ko` (`drivers/platform/x86/uniwill/`, author Armin Wolf) — the upstreamed Uniwill notebook driver ([Phoronix: TUXEDO features upstreamed for Linux 7.1](https://www.phoronix.com/news/TUXEDO-More-Uniwill-Linux-7.1)). Its DMI whitelist covers TUXEDO/Schenker/Intel strings only — `THUNDEROBOT` is **not** whitelisted, so it doesn't auto-load. It exposes a **`force=1` module parameter** to load anyway. |
| Other | `asus_wmi` loaded (0 users, spurious bind — not useful here). `smartctl` + `upower` installed; TLP not installed. Two NVMe drives (`nvme0`: WDC PC SN530 256G, `nvme1`). NetworkManager active (`nmcli` works; current SSID `Totalplay-5G-3070`). |

### The one command Héctor must run to unlock P1-native (reversible, 2 min)

```bash
sudo modprobe uniwill_laptop force=1
ls /sys/class/power_supply/BAT0/ | grep -i charge_control
# if present:
echo 80 | sudo tee /sys/class/power_supply/BAT0/charge_control_end_threshold
# undo at any time:
sudo rmmod uniwill_laptop
```

If the file appears and the EC honors it (watch `status` flip to
`Not charging` around 80%), **P1 becomes a pure-software feature**. The DMI
whitelist exists because EC behavior varies across Uniwill barebones — `force=1`
is a probe, not a guarantee; the machine has the right WMI interface, which is
the strong signal. (Reference implementations: TLP's
[vendor battery-care matrix](https://linrunner.de/tlp/settings/bc-vendors.html)
lists Uniwill/Tongfang support via these drivers; TUXEDO ships 60/80/100%
charging profiles on this same platform. On some Uniwill ECs an additional
`echo Custom > .../charge_type` step is required for thresholds to take effect
— [TLP issue #803](https://github.com/linrunner/TLP/issues/803).)

Secondary avenue if `force=1` fails: the out-of-tree
[tuxedo-drivers](https://github.com/tuxedocomputers) DKMS package supports a
broader set of Tongfang barebones (charging profiles 60/80/100%), and
Thunderobot's own BIOS updates occasionally add a firmware charge-limit toggle
(check BIOS setup and [Thunderobot's driver page](https://global.thunderobot.com/pages/download)).

### Fallback if no EC path works: smart-plug automation

A Wi-Fi smart plug (Tasmota/ESPHome/Matter — local API, no cloud) between wall
and power brick, driven by Axi:

- Battery ≥ cap (e.g. 80%) → Axi turns plug **off** → laptop discharges.
- Battery ≤ floor (e.g. 60%) → Axi turns plug **on** → charges back to cap.
- This turns the existing UNPLUG/REPLUG *advisor* into an *actuator* with the
  same thresholds. Sawtooth cycling between 60–80% is shallow-DoD cycling
  (~20% DoD ≈ thousands of cycles, Fact 3) — vastly better than parking at
  100%, though strictly worse than a native EC cap (which holds SoC with zero
  cycling). Safety interlocks required (see §7 P1 and §9).

## 6. Proposed feature set (phased)

### P1 — Charge-threshold capping (the actuator)

**Goal:** battery never dwells at 100% while at home. Two implementation paths,
selected by a probe at setup:

1. **Native EC path (preferred):** if `uniwill_laptop force=1` exposes a
   working `charge_control_end_threshold`, Axi manages it:
   - Install a `modules-load.d` + `modprobe.d` config (`force=1`) and a small
     privileged helper (systemd unit or polkit-scoped script) so the daemon —
     which runs unprivileged — can write the threshold.
   - Default cap 80% (config `body_battery_charge_cap_pct`), with the option
     of a start threshold if the EC supports one.
   - Verification loop: after writing, confirm the EC honors it (status
     `Not charching`/`Full` near the cap); if not honored, degrade to path 2
     and tell Héctor once.
2. **Smart-plug path (fallback):** Axi drives a local-API smart plug
   (Tasmota/ESPHome HTTP) with hysteresis (on at ≤ floor, off at ≥ cap).
   Safety interlocks: fail-safe **ON** (if Axi/daemon/Wi-Fi dies, plug stays
   powered), never cut power below a minimum SoC, never cut during game mode
   or meetings (performance/PSU draw), re-check every `body_check_interval_s`.

In both paths, the existing `battery_alerts()` advisor stays as the human
fallback layer and gains awareness of the actuator (don't nudge "unplug" when
the cap is active and holding).

### P2 — Context-aware charge policy (SSID-based)

**Goal:** 60–80% cap at "long-stay" locations, 100% when traveling.

- **Location signal:** active Wi-Fi SSID via `nmcli` (primitive already in
  `feet.py::_net_name()`). Config `body_home_ssids` (list) — Héctor seeds it
  with home + in-laws SSIDs; Axi may *suggest* additions when it observes an
  unknown SSID connected >N cumulative hours over M days.
- **Policy:** known SSID → apply cap (P1); unknown SSID or no Wi-Fi (ethernet
  elsewhere/hotspot) → lift cap to 100%.
- **Manual override:** "voy a viajar" / "I'm traveling tomorrow" via chat or
  dashboard toggle → force 100% now and hold until back on a known SSID (plus
  a TTL, e.g. 48 h, so a forgotten override doesn't park at 100% forever).
  Inverse override: "modo casa" pins the cap regardless of SSID.
- **Transition behavior:** lifting the cap starts charging immediately (so an
  overnight "travel tomorrow" wakes up at 100%); re-applying the cap does not
  force-discharge (native path: EC just stops charging; plug path: normal
  sawtooth resumes).
- **Privacy:** SSID names stay local (config + logs on-device only); never
  sent to any cloud/LLM context beyond the local brains. See §8.

### P3 — Hardware-lifespan consciousness ("esperanza de vida" per component)

**Goal:** Axi knows the wear state and expected remaining life of every
wear-limited component, and advises replacement *before* failure.

- **New time-series wear ledger** (SQLite or JSON-lines under the axi state
  dir), sampled daily + on-demand:
  - **Battery:** `charge_full/charge_full_design` wear %, `cycle_count`,
    cumulative hours at ≥98% SoC, cumulative hours above temp bands. *On this
    machine the EC reports no wear/cycles (see §5), so Axi must track
    **proxy metrics** (time-at-full × temperature exposure) and optionally a
    periodic `upower -d` capacity estimate; if the EC ever starts reporting
    real numbers, prefer them.*
  - **SSDs (x2 NVMe):** SMART via `smartctl -j` / `nvme smart-log`:
    `percentage_used`, spare %, data-units-written, media errors, temp. Linear
    projection → estimated end-of-warranty-life date.
  - **CPU/GPU thermals history:** aggregate the existing interoception temp
    samples into daily max/p95; drift in idle temps over months → "repaste
    coming" signal. GPU memory-junction temp if exposed (`nvidia-smi` field
    varies by driver).
  - **Fans:** hours-of-operation estimate (uptime × duty proxy from temp
    bands; direct RPM from hwmon if the uniwill driver exposes it), plus
    anomaly detection: rising temps at same load = dust/fan degradation.
- **Surfacing:** a new organ entry (or an extension of Pulmones) in
  `organs.py` — proposed key `esqueleto` (skeleton/chassis wear) — reported in
  `/api/organs` with per-component `state` (ok/aging/replace-soon/replace-now)
  and a one-line prognosis.
- **Proactive advice:** monthly digest via the existing notification path
  ("SSD1 at 12% wear, ~5 years left; battery has spent 62% of its life above
  80% SoC — cap is working"). Replacement thresholds configurable.

### P4 — Multiplatform surface (mobile)

**Goal:** the guardian is visible and actionable from the phone.

- **Battery/hardware card** in the Flutter app (`mobile/`): current SoC, cap
  state (capped-at-80 / travel-100 / plug-off), wear summary per component.
  Data flows through the existing laptop API the app already mirrors
  (`/api/organs` + a new `/api/body/longevity` endpoint).
- **Notifications** ride the existing reminder/notification path — no new
  channel: unplug/replug nudges (when actuator absent), travel-override
  confirmations, monthly wear digest, replace-soon alerts.
- **Actions from phone:** toggle travel mode, toggle smart plug (if P1
  fallback), acknowledge nudges.
- **Design constraint:** phone batteries have the same physics; the schema
  (component → wear metrics → prognosis) must be device-generic so a future
  mobile-side self-report (Android BatteryManager) plugs into the same model.

## 7. Axi integration design sketch

- **Owning organ:** interoception (Pulmones) owns sensing + policy;
  actuation lives in a small new module `axi/src/axi/battery_guardian.py`
  (policy engine + actuator drivers: `ec_threshold`, `smart_plug`, `advisor`),
  called from the interoception loop. Organs registry gains the wear/prognosis
  reader (P3). One parameterized engine, per-actuator config — no duplicated
  per-path logic (reusable-components rule).
- **Proposed config keys** (extending the existing `body_*` family in
  `config_schema.py`):
  - `body_battery_guardian_mode`: `off | advisor | ec | smart_plug | auto`
    (default `advisor` = today's behavior; `auto` probes ec → plug → advisor)
  - `body_battery_charge_cap_pct` (int, 80), `body_battery_charge_floor_pct`
    (int, 60 — plug path hysteresis floor; distinct from the existing
    `body_battery_replug_pct` advisor floor of 40)
  - `body_home_ssids` (list[str], []), `body_travel_override_ttl_h` (int, 48)
  - `body_smart_plug_url` (str, "") + `body_smart_plug_kind` (`tasmota|esphome|http`)
  - `body_wear_ledger_enabled` (bool, true), `body_wear_digest_days` (int, 30)
- **Alert flows:** reuse `battery_alerts()`'s episode/hysteresis pattern and
  the meeting-defer / game-mode-defer semantics already in `alerts()`.
  Actuator state changes log an event (existing `events` module) so Olfato can
  sniff flapping (e.g., plug toggling too often → misconfigured hysteresis).
- **SSID detection:** extend `feet.py` with `wifi_ssid()`
  (`nmcli -t -f active,ssid dev wifi`, already verified working on-device);
  the guardian consumes it — network sensing stays in Feet, policy in the
  guardian (single source of truth).
- **State:** guardian state (mode, override, last actuation, `full_since`)
  merges into/next to `interoception_battery.json`; wear ledger is a separate
  append-only file.
- **Privacy note:** SSIDs and location-implying data (home vs. in-laws vs.
  travel) are sensitive. They are stored only in local config/state, never in
  engram memories by default, never in prompts to remote services, and the
  mobile API returns policy *state* ("capped"/"travel") rather than SSID names
  unless the client is the authenticated owner device.

## 8. Rollout / phasing summary

| Phase | Ships | Depends on |
|---|---|---|
| P0 (now, manual) | Héctor runs the `modprobe uniwill_laptop force=1` probe (§5); elevates laptop for airflow | nothing |
| P1 | Charge-cap actuator (ec or smart-plug), advisor integration | P0 result decides path |
| P2 | SSID-aware policy + travel override | P1 |
| P3 | Wear ledger + esperanza-de-vida organ + digests | none (parallel to P2) |
| P4 | Mobile card + notifications + remote toggles | P1–P3 APIs |

## 9. Open questions & risks

1. **Does the EC honor the threshold?** Unknown until Héctor runs the P0 probe
   (§5). `force=1` bypasses a DMI whitelist that exists because Uniwill EC
   firmware varies; the correct WMI GUIDs being present is encouraging but not
   proof. Mitigation: probe is read-mostly and reversible (`rmmod`); if it
   misbehaves (wrong fan/keyboard side effects), don't persist the module.
   Some Uniwill ECs also need `charge_type=Custom` set before thresholds bite.
2. **EC telemetry is blind:** `cycle_count`=0 and 0% reported wear mean Axi
   cannot *measure* battery health on this machine — only *infer* it from
   exposure history. P3's proxy-metrics design is mandatory, not optional.
   Risk: proxies drift from reality; mitigation: periodic manual capacity
   check (full-charge runtime test) offered as an opt-in calibration.
3. **Smart-plug failure modes:** plug offline while battery drains → laptop
   dies mid-HomeLab-duty. Interlocks: fail-safe ON, hard floor (never leave
   plug off below e.g. 50%), watchdog (if plug unreachable, notify + assume
   ON), never toggle during games/meetings/high-load inference.
4. **Threshold persistence:** EC thresholds may reset on reboot/BIOS update —
   the privileged helper must re-apply on boot and after resume.
5. **BIOS updates:** `N.1.17THU10` — a newer Thunderobot BIOS might add a
   native charge-limit toggle; check before building the plug path.
6. **SSID spoofing / false "home":** an attacker-named SSID could flip policy
   to "home" — impact is trivial (battery caps at 80%), accept the risk; never
   attach security decisions to SSID.
7. **Mobile scope creep:** P4 is a *mirror*, not a second guardian; the phone
   never actuates directly against sysfs/plug except through the laptop API.
8. **Battery pinned at 100% today:** dropping from 100% to an 80% cap requires
   one partial discharge. Native EC path won't discharge on its own — Axi
   should nudge one unplug-to-80% (or briefly use the plug) at rollout.

## 10. Non-goals (v1)

- **No forced deep discharges / "battery exercise" cycles** — explicitly
  anti-goal (see §3.2).
- No support for capping on machines other than the primary laptop (desktop
  agents without batteries already no-op via the existing `battery_pct is
  None` guard).
- No geolocation (GPS/geofencing) — SSID only.
- No cloud-connected smart-plug ecosystems (local API only).
- No automatic BIOS/EC firmware updates.
- No battery *purchase* automation (advice includes replacement timing, not
  ordering).
- No phone-battery guardian (schema is designed for it, implementation is
  future work).
- No UPS/power-outage management (separate HomeLab concern).

## 11. References

- [Battery University BU-808 — How to Prolong Lithium-based Batteries](https://www.batteryuniversity.com/article/bu-808-how-to-prolong-lithium-based-batteries/) (Tables 2–4: DoD/voltage/temperature vs. life)
- [ScienceDirect — High-temperature calendar aging at low SoC: optimal SOC ranges for Li-ion storage](https://www.sciencedirect.com/science/article/abs/pii/S2352152X25017013)
- [TLP — Battery Care Vendor Specifics](https://linrunner.de/tlp/settings/bc-vendors.html)
- [TLP issue #803 — Battery care for TUXEDO/Uniwill laptops (`charge_type=Custom` quirk)](https://github.com/linrunner/TLP/issues/803)
- [TUXEDO — Battery charging profiles (60/80/100%) on Tongfang/Uniwill platforms](https://www.tuxedocomputers.com/en/Battery-charging-profiles-inside-the-TUXEDO-Control-Center.tuxedo)
- [Phoronix — TUXEDO/Uniwill features upstreamed in Linux 7.1](https://www.phoronix.com/news/TUXEDO-More-Uniwill-Linux-7.1)
- [Baeldung — Limiting battery charge level on Linux (`charge_control_end_threshold`)](https://www.baeldung.com/linux/limit-battery-charge-level)
- [UDPWR — the 40–80 rule for Li-ion](https://udpwr.com/blogs/portable-power-station-knowledge/40-80-rule-for-lithium-ion-batteries)
- [Large Battery — Li-ion degradation, performance and safety (swelling)](https://www.large-battery.com/blog/lithium-battery-degradation-performance-safety/)
- [Thunderobot Global — driver/BIOS downloads](https://global.thunderobot.com/pages/download)
