# ZiA — Owner Checklist (hardware- and permission-verified steps)

> Contract: **Frozen Architecture & Implementation Contract v1.0** (9 frozen
> principles + Principle 10).
> Status: **INITIAL** — created in the executor R4 pass with the items already
> known. Completed with expected results in Phase 9.
>
> **Why this file exists.** Some capabilities cannot be verified by an unattended
> agent: they depend on macOS TCC permissions, a live on-screen session, or a
> Safari setting. This checklist is the honest boundary between *verified by
> tests* and *verified by the owner at the machine*. Anything on this list must
> NEVER be relabeled REAL from an unattended run.

## How to use

1. Run each step on the Mac, in the listed order.
2. Record what you actually saw (not what you expected).
3. Paste the **Paste back** block into the message to Claude (architecture
   reviewer) so it can reconcile the capability audit.

---

## 1. Microphone

**Current known state:** reports **"Not Determined"**; captured audio is
**exact-zero samples** because macOS has not granted Microphone permission to the
invoking process. This is the "Not Determined" problem the onboarding TCC-truth
work (Phase 7.3) must surface honestly.

| Step | Action | Expected result | Paste back |
|---|---|---|---|
| 1.1 | Open **System Settings → Privacy & Security → Microphone** and enable the entry that runs ZiA (Terminal, or `build/Jarvis.app`). | The ZiA/terminal entry is toggled on. | App name + previous state |
| 1.2 | Re-run the mic check (self-test mic capture, or a live voice turn). | Non-zero samples; no longer exact-zero. | First non-zero sample count |
| 1.3 | In-app: Settings → Permissions shows Microphone **Granted**. | Badge "Granted". | screenshot note |

## 2. Speech Recognition

| Step | Action | Expected result | Paste back |
|---|---|---|---|
| 2.1 | Enable ZiA under **Privacy & Security → Speech Recognition**. | Toggled on. | App name |
| 2.2 | Speak a short request. | On-device transcript appears (no cloud). | Transcript text |

## 3. Accessibility (computer control)

| Step | Action | Expected result | Paste back |
|---|---|---|---|
| 3.1 | Enable ZiA under **Privacy & Security → Accessibility**. | `AXIsProcessTrusted()` returns true (health shows "computer control: healthy"). | Health line |
| 3.2 | Ask ZiA to `inspect_ui` over the frontmost app. | A real element list, not `unavailable`. | element count |
| 3.3 | `click_element` / `set_text` on a harmless target. | Postcondition verification passes (or `.inconclusive` for a bare click). | verification outcome |

## 4. Screen Recording

**Current known state:** the screenshot self-test now **runs and passes** when
the host terminal has Screen Recording granted. This is a **host dependency**:
the pass reflects the *invoking* app's grant, not ZiA.app's. `build/Jarvis.app`
must be granted separately for the packaged app.

| Step | Action | Expected result | Paste back |
|---|---|---|---|
| 4.1 | Enable Screen Recording for the launched ZiA app. | Screenshot capability verified (`system.screenshot`). | file path + byte size |
| 4.2 | Confirm the packaged `build/Jarvis.app` has its own grant. | Screenshot works from the app, not just the terminal. | yes/no |

## 5. Automation (AppleScript / browser)

| Step | Action | Expected result | Paste back |
|---|---|---|---|
| 5.1 | Trigger `open_browser` / Safari automation; allow the **Automation** prompt. | No `-1743` ("not authorized") error. | error string if any |
| 5.2 | Safari → **Develop → Allow JavaScript from Apple Events**. | `inspect_browser_page` / `extract_browser_text` return live DOM data. | DOM summary |

## 6. Voice pipeline (wake word, barge-in, TTS)

| Step | Action | Expected result | Paste back |
|---|---|---|---|
| 6.1 | Say the wake alias ("Jarvis" / "Zia"). | Wake detected from the streaming transcript. | detected? |
| 6.2 | Speak while ZiA is talking. | Barge-in stops playback in < 50 ms. | perceived latency |
| 6.3 | Complete one spoken turn. | Spoken reply; text overlay shows the transcript. | transcript + reply |
| 6.4 | Latency telemetry for the turn. | Numbers recorded in `VoiceTraceState`. | p50/p95 |

> Note: acoustic DSP wake-word engine is **deferred**; wake detection uses
> `SFSpeechRecognizer` transcript matching. This is expected, not a bug.

## 7. Live UI (on-screen appearance)

| Step | Action | Expected result | Paste back |
|---|---|---|---|
| 7.1 | Launch the app; open the presence HUD, main window, menu bar, all settings panes. | Renders without clipping/overlap; dark + light; no missing assets. | screenshots |
| 7.2 | Tab/keyboard through every control; check VoiceOver labels. | Every control reachable; labels announced. | issues |
| 7.3 | Toggle each setting; confirm it persists across relaunch. | Persists. | issues |

## 8. Release build

| Step | Action | Expected result | Paste back |
|---|---|---|---|
| 8.1 | Build the release app bundle (`./Scripts/build-app.sh release`). | Bundle assembled; Info.plist usage strings present for Mic/Speech/Screen. | plist keys |
| 8.2 | Sign/notarize (owner-only). | Launches without Gatekeeper block. | signature status |

---

## Verified by tests vs hardware-unverified (summary)

- **Verified by tests / deterministic runners:** all routing, planners,
  sandboxing, verification, memory, filesystem, and provider logic (see
  `docs/CAPABILITY_AUDIT.md` and the ledger gate counts).
- **Hardware/permission-unverified (this file):** microphone capture, speech
  recognition, accessibility control, screen recording, automation, live voice
  loop, live on-screen UI, release signing.

> Populated in Phase 9 with exact expected outputs and the paste-back format.
