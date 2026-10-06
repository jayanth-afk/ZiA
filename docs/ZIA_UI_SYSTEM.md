# ZiA — UI / UX System

> Companion to `PROJECT_CONTEXT.md`. That document covers the brain, authority and
> voice subsystems; this one covers the interface built on top of them.
> Visual reference board: [`docs/design/zia-design-reference.html`](design/zia-design-reference.html)

---

## 1. Design intent

ZiA should read as a calm, present assistant — not a dashboard and not a demo.
The rules the implementation follows:

1. **The presence is the product.** ZiA is a bead of intelligent light in glass. It is the
   first thing seen, the largest thing in every state, and the only element that is always
   present. There is no header, badge, status table, latency readout or provider name in the
   voice surface.
2. **Nothing fake.** Every status, list, progress row and availability light is read from
   live state. Where a behaviour is automatic by design (automatic endpointing, barge-in)
   the UI explains it instead of exposing a slider that does nothing.
3. **Focus is never stolen.** The overlay is a non-activating panel that joins all Spaces.
   The main window opens only from an explicit user action.
4. **Motion is a signal, not decoration.** Idle is almost still (a 12 fps breath); only
   active states are time-driven at 30 fps, nothing renders while the HUD is hidden, and
   everything honours macOS *Reduce Motion*.
5. **Less UI, always.** When choosing between another card/button/readout and making the
   presence better, the presence wins. Controls appear only when they can be used.
6. **Hierarchy before style.** Deep atmospheric background → luminous presence → floating
   typography → minimal native controls. Colour belongs to the presence; everything else
   stays restrained.

---

## 2. Layers

```
UI/
├── Theme/
│   └── ZiaTheme.swift            ZiaColors · ZiaType · ZiaSpace · ZiaRadius ·
│                                 ZiaMotion · ZiaElevation · ZiaMetric ·
│                                 ZiaAppearance(+Store) · ZiaState<T>
├── Components/
│   ├── ZiaSurfaces.swift         ZiaSurface · ZiaCard · ZiaSection · ZiaDivider
│   ├── ZiaControls.swift         ZiaButton · ZiaIconButton · ZiaBadge · ZiaStatusDot ·
│   │                             ZiaSettingRow · ZiaToggleRow · ZiaEmptyState · ZiaErrorView
│   ├── ZiaPresence.swift         ZiaPresenceState · ZiaPresenceProfile · ZiaAudioMeter ·
│   │                             ZiaPresenceOrb · ZiaEnergyField · ZiaTranscript
│   ├── ZiaComposer.swift         ZiaComposer (one capsule: text + voice + send)
│   └── ZiaStatusCards.swift      ZiaProviderCard · ZiaPermissionCard · ZiaTaskCard ·
│                                 ZiaActivityStrip (+ their observable models)
├── Overlay/                      FloatingPanel · OverlayView · ZiaHUDVisibility
├── Main/                         ZiaWindowController · ZiaWindowView (conversation surface)
├── MenuBar/                      MenuBarManager · MenuBarView
├── Settings/                     SettingsView (sidebar) · SettingsDetailViews · APIKeysView
└── Render/                       UIRenderHarness  (`--render-ui`)
```

`UI/Theme/DesignTokens.swift` is kept unchanged for compatibility (SelfTest asserts its
values); new code reads the `Zia*` tokens.

---

## 3. Surfaces and screens

| Surface | Presentation | Notes |
|---|---|---|
| Overlay HUD | `NSPanel` `.nonactivatingPanel`, joins all Spaces, 400 pt wide, sizes to content | Presence + one line of truth, nothing else. Verified live at 400×175 pt |
| Main window | `NSWindow` 980×680, min 760×520 | Conversation surface: floating identity bar, centred reading column, composer. No inspector, no dividers |
| Menu bar | `NSStatusItem` + popover 320×430 | Identity + status, then only the actions that are available; health appears only when something is wrong |
| Settings | Sidebar layout, 820×580 | 11 panes, each built only from real controls |
| Onboarding / permissions | Shown first time the main window opens; `ZiaPermissionCard` in Settings | Real TCC state with System Settings deep links |

### State language

`ZiaPresenceState.resolve(phase:appEnabled:stopped:)` maps the backend
`InteractionPhase` to: `disabled · idle · listening · understanding · thinking · working ·
speaking · done · error · stopped`. An explicit user stop always overrides a stale phase.

- **Idle** — a slow, shallow breath. "ZiA" and one hint line; the composer appears only on hover or tap.
- **Listening** — the presence is driven by **measured** microphone energy; floating transcript
  plus a fluid energy field. The composer is hidden (typing is not what you are doing).
- **Understanding** — the body folds inward (ZiA detected the end of speech itself) and the
  transcript settles.
- **Thinking / Working** — one quiet word beside a presence whose light has reorganised. No
  spinner, no progress bar; the only control is Stop.
- **Speaking** — the body expands outward; barge-in remains armed.
- **Done** — everything settles back to calm. Responses longer than 320 characters are
  truncated with a single "Read in ZiA" action that opens the window.
- **Error** — user-facing wording, typed-error aware, technical detail collapsed.
- **Background work** — real tasks from `TaskStateMachine` appear above the composer in the
  window, and only while they exist.

---

## 4. Presence architecture

`ZiaPresenceProfile.forState(_:audioEnergy:)` is the single source of the presence's physics:
`energy`, `deform`, `bloom`, `spin`, `turbulence`, `hue`, `saturation`, `fold`. Hue is pinned
to `ZiaPresenceState.hue`, so the presence, the HUD backdrop and the window atmosphere can
never disagree about what colour a state is.

`ZiaPresenceOrb` renders seven layers on a `Canvas`: atmospheric bloom → an organically
deformed glass body (five radial modes, never a uniform scale) → clipped interior (inner base
light + a travelling spectral band + two drifting lobes) → radial glass shell → asymmetric
blurred rim light → a specular pair → a volumetric inner shadow. It runs at 30 fps while
active and 12 fps for the idle breath, and freezes to a still frame when the HUD is hidden or
Reduce Motion is on (which also zeroes spin/turbulence and dampens deformation).

## 5. Real audio, never synthetic

`ZiaAudioMeter` keeps a 48-sample ring of measured energy plus an attack/release smoothed
envelope (0.55 attack, 0.10 release) that the presence deforms with. While a listening
surface is on screen it samples `AudioDiagnostic.latestLevels()` (a lock-only read that does
not touch the VAD, recognizer or pipeline) every ~33 ms inside a bounded `.task`. **No timer
exists while ZiA is idle**, and there is no synthetic sine or random noise anywhere.
`ZiaEnergyField` draws three overlapping blurred bands from that measured history — a fluid
field, deliberately not an equaliser, with no discrete bars. If capture is unavailable the
field renders the calm zero-input baseline rather than inventing motion.

---

## 6. Appearance

`ZiaAppearanceStore` persists `system | light | dark` in `UserDefaults`
(`zia.appearance.v1`) and applies `.preferredColorScheme` to every ZiA surface: overlay,
main window, menu bar popover and Settings. Colours are dynamic `NSColor`s with separate
light and dark values.

---

## 7. Verification

Run in this order:

```bash
# 1. Build
swift build

# 2. Unit + integration tests (design system, presence mapping, truthful status)
swift test

# 3. Broad in-process integration suite (includes UI-architecture assertions)
.build/debug/Jarvis --self-test

# 4. Render reference images from the real views, then check them mechanically
rm -rf build/ui-references
.build/debug/Jarvis --render-ui build/ui-references
python3 Scripts/ui_reference_stats.py build/ui-references    # fails if any image is blank
python3 Scripts/ui_layout_profile.py build/ui-references/02-hud-idle.png   # content bbox + vertical structure
python3 Scripts/ui_ascii_view.py build/ui-references/02-hud-idle.png       # coarse ASCII impression
swiftc -O -o /tmp/zia_ocr Scripts/ui_reference_ocr.swift -framework Vision -framework AppKit
/tmp/zia_ocr build/ui-references/*.png                    # reads back the text that actually landed

# 5. Release bundle
./Scripts/build-app.sh release

# 6. Live inspection (presents the overlay + main window and logs their frames)
open build/Jarvis.app --args --show-ui
log show --predicate 'subsystem == "com.jarvis.app"' --last 2m --info | grep UI_TRACE
```

`--render-ui` renders the *actual* views (same components and tokens as production), so the
reference board cannot drift from the shipped UI. `Scripts/ui_reference_stats.py` converts
each PNG to BMP with `sips` and reports mean luminance, standard deviation and distinct
colour count, so a blank or flat capture fails instead of passing silently.

### Known limits of the harness

- `ImageRenderer` captures a **single static frame**: time-driven presence layers appear at
  one phase, and system materials (`.hudWindow` vibrancy) render as their flat fallback.
- Views wrapped in a `ScrollView` do not rasterise, so the harness renders pane content
  directly. This was found by the stats script (14 of 34 images were blank before the fix).
- `ImageRenderer` cannot drive `.task`/`.onAppear`; the harness preloads provider,
  permission and activity models before capturing.
- Dynamic `NSColor`s need the matching `NSAppearance` to be current while drawing; the
  harness sets `performAsCurrentDrawingAppearance` per variant.
- AppKit-backed controls do not rasterise faithfully: a plain `TextField` renders as an
  opaque light bar in a reference image. The capsule fills around it resolve to the correct
  token values (measured), and the live app draws the field normally — confirmed by reading
  the running window's "Ask ZiA…" placeholder out of a screen capture.
- A surface reachable only after first-run onboarding (the conversation window) is captured
  by completing onboarding for that capture and restoring the previous state afterwards.

---

## 8. Toolchain constraint (important)

This host builds against the Command Line Tools SwiftUI interface, where the
`@State` / `@Environment` macro plugins are **not shipped**. Property wrappers that are real
types (`@StateObject`, `@ObservedObject`, `@Binding`) work fine. Therefore:

- **Never use `@State`** in this project. Use `@StateObject` with a `ZiaState<Value>` box
  (simple local value) or a small `ObservableObject` model (a group of related values).
- `@Observable` (Observation module) is available and is used by `AppState`.

`grep -rn "@State\b" Sources/Jarvis/UI` must stay empty apart from documentation comments.
