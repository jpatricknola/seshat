# Ableton's Extensions SDK — a second bridge Seshat cannot reach yet

_Evaluation doc · 30 Aug 2026 · bridge-level, so it sits beside
[bridge-options.md](bridge-options.md) rather than inside the generative-feature
folder. Decides nothing by itself. Current decision: **AbletonOSC stays the
bridge; the Extensions SDK is a capability lane to open once beta access
exists.**_

Ableton announced the **Extensions SDK** on 2026-06-02: JavaScript/TypeScript
running on Node inside Live, bundled to a `.ablx` file the user drags into
Settings → Extensions. It reaches the Live Set — tracks, clips, MIDI notes,
devices, tempo, browser — and adds things the Live Object Model has no member
for. It is in public beta behind a Centercode sign-up we do not have.

Everything marked **measured** below was run on this Mac on 2026-08-30 against
the installed **Live 12.4.5 Suite, build 2026-08-19_225ce5e356** (the public
release of 2026-08-26) and its running process. Everything else is **reported**
from Ableton's own pages, press coverage, or third-party repositories, and was
not reproduced.

---

## Verdict up front

> **The SDK does not replace AbletonOSC and is not reachable today.** Its
> trigger model is a user right-clicking a context-menu entry; the extension
> runs once and stops. No launch hook, no event subscription, no background
> listener, no realtime stream. Seshat's whole shape — an outside process
> issuing commands whenever the model decides, against a mirror kept fresh by
> push — is exactly what that model forbids. It is also **Live 12 Suite only**,
> where Remote Scripts work on every edition, so it could never be a required
> component.
>
> What it *is*: the only sanctioned route to a specific set of capabilities the
> LOM does not expose at any spelling — offline render/bounce, audio→MIDI
> conversion, stem separation, warp commands, slicing, take lanes, project
> import. Those are the operations Seshat currently reaches through
> `Seshat.AX.Client` pressing menu items, or not at all. **Open the beta,
> measure, and revisit; build nothing on it before then.**

---

## 1. What is reported

- **Runtime.** TypeScript/JavaScript on Node.js v24.16.0 LTS; npm packages
  available; hot reload during development; `.ablx` bundle for distribution.
- **Requirements.** Live 12 **Suite** 12.4.5 or later. Not Standard, Intro or
  Lite.
- **Reach.** Set structure (tracks, clips, clip slots, scenes, devices
  including Simpler/Drum Rack/Sample), `createMidiClip` plus `clip.notes`,
  file import, `renderPreFxAudio()` for offline bounce, undo transactions,
  firing objects, operations across ranges.
- **UI.** Context-menu entries, modal dialogs with embedded webviews, progress
  dialogs.
- **Not available (beta).** Max for Live integration, tuning systems, hardware
  and control-surface support, and — the decisive one — **programmatic
  execution: no launch events, no automation triggers**. Extensions are not for
  continuous, realtime or background work.
- **Distribution.** SDK packages are confidential and cannot be vendored into a
  public repository (the `strudelton` repo says so explicitly and ships without
  them). Built `.ablx` files circulate freely; some are sold. The SDK EULA is
  unread — check it before shipping any `.ablx` of ours.
- **Ecosystem.** ~334 extensions listed at `ablx.directory` roughly three months
  after announcement, across an open registry that takes listings by pull
  request.

## 2. What is measured, on this machine

The Extensions machinery **ships in the released 12.4.5 binary**, not only in
the beta build. String-dumping
`/Applications/Ableton Live 12 Suite.app/Contents/MacOS/Live` finds:

- `TSandboxedExtensionHostProcess(TPtr<TSocketManager>, TPushApi*)`,
  `TExtensionHostUnsandboxedProcess`, `TExtensionHostManager`,
  `TExtensionHostRelay`, `TExtensionActionRegistry`,
  `NExtensionActionContextMenu`.
- Settings UI classes `AExtensionsPage`, `AExtensionsPreferencesModel`,
  `AInstalledExtension`, `AExtensionDropHintView`; `.ablx` as a file suffix.
- An `ExtensionsPreferencesModel` record, carrying a `DeveloperMode` key,
  already persisted in `~/Library/Preferences/Ableton/Live 12.4.5/Preferences.cfg`.
- Extension actions bind to one of three contexts:
  `TClipSlotSelectionContext`, `TArrangementSelectionContext`,
  `TCompoundContext` — i.e. what the right-click entry was invoked on.

### 2.1 The channel is the Push live model

An extension attaches to `ableton::push_live_model` — the same `flip` document
protocol Live speaks to Push, over a socket, bidirectional and push-based. The
`ExtensionHost` class in that document carries exactly:

`register_action` / `unregister_action` (with json and object callbacks) ·
`show_modal_web_view` · `show_progress_dialog` / `update_progress_dialog` /
`close_progress_dialog` (+ a cancelled callback) · **`render_pre_fx_audio`** ·
**`import_into_project`**

The rest of the document — shared with Push — contains many operations with no
LOM equivalent. Measured in the same binary, among others:

`bounce` · `audio_to_midi_clip` · `separate_stems` · `freeze` / `unfreeze` /
`flatten` / `crop` · `warp_to_grid` / `warp_as` / `warp_double` / `warp_half` ·
`create_drum_rack_from_audio_clip` · `sliced_simpler_to_drum_rack` ·
`insert_slice` / `clear_slices` · `create_take_lane` ·
`duplicate_clip_to_arrangement` · `insert_automation_step` / `clear_envelope` ·
`capture_and_insert_scene` · `group_tracks` / `group_devices` · `move_track` /
`move_scene` / `move_device` · `save_call` / `save_as_template` /
`load_song_call` / `new_song_call` · macro variations · cue points ·
`load_tuning` · `load_item_onto_new_audio_track` and siblings · pack install.

**That list is Live's internal document surface, not a promise about the JS
API.** Only `render_pre_fx_audio` and `import_into_project` are confirmed on
the `ExtensionHost` class itself. Treat the rest as "worth checking once the
SDK docs are readable."

### 2.2 The channel is closed to us

Live was running (pid 95796) during the measurement. Its only sockets:

| Socket | What it is |
|---|---|
| `UDP *:20909` | Ableton Link |
| `UDP 127.0.0.1:11000` | AbletonOSC — ours |
| `unix /tmp/com.cycling74.501/max_9.1.5_95796` | Max |
| `unix .../wc6354ea3`, `.../5874366` | Web Connector, Index |

No push-live-model endpoint, no TCP listener at all. `Log.txt` records only
Web Connector, Index and Splice subprocess starts across every session — the
Extension Host has never started here, and nothing matching `*xtension*` exists
under either `Application Support/Ableton` tree.

Three gates stack:

1. **The host binary is absent.** `TExtensionHostManager::RequestExtensionHostStart`
   resolves through `IAddOnManager` — the Extension Host is a downloadable
   AddOn, and this machine has not downloaded it.
2. **Live spawns the peer; you do not dial it.** The host is constructed
   sandboxed with a socket Live owns, and the protocol has
   `authorize_call`/`authorize_response`, `push_is_ready`, `wait_for_disconnect`.
3. **`flip` is a versioned binary document format** compiled into both ends,
   with no public specification.

Corroborating detail: `MIDI Remote Scripts/` ships `Push/`, `Push2/` and
`pushbase/` — **no `Push3`**. The modern Push path left Python for this
document, and it is not exposed as a Remote Script we could import.

**Reverse-engineering that channel is not an option worth arguing.** It would
be a third native-process door with worse odds than the AX helper: undocumented,
build-versioned, authenticated. The sanctioned route is the beta programme.

---

## 3. What the ecosystem already proves

Two extensions settle questions our own docs left open, and both are worth
knowing before any related work is planned.

### 3.1 Basic Pitch — audio→MIDI, MIT, offline, one drag

`federico-pepe/ableton-live-extensions`, v1.0.3, MIT repo, macOS and Windows.
Right-click any audio clip → Convert to MIDI → a new MIDI track appears beside
the original with polyphonic transcription and pitch bend preserved. The
engine is **Spotify's Basic Pitch** — an open-source CNN from their Audio
Intelligence Lab (ICASSP 2022), inferring on the local CPU. No account, no
API key, no Spotify service call, no cost; nothing leaves the machine.

**Licence, checked 2026-08-30 — it passes the distribution gate.** Code is
**Apache-2.0** (Copyright 2022 Spotify AB, with a GPL option) and the trained
**weights are Apache-2.0 too** (`license: apache-2.0` in the Hugging Face
model card's frontmatter), which is the check ADTOF and LarsNet failed.
Shipped as TensorFlow / CoreML / TFLite / ONNX, plus a TypeScript port
(`spotify/basic-pitch-ts`) — so it is runnable from Node or Python with no
extension involved at all. Residual, stated rather than resolved: the model
card lists GuitarSet, iKala, MAESTRO, MedleyDB-Pitch and Slakh as training
data, and some of those datasets carry non-commercial terms; Spotify's own
licence declarations were checked, each dataset's were not. Whether NC
training data taints permissively released weights is unsettled and is the
releaser's exposure, not a term binding a downstream user.

Its README answers §2.6 of
[live-native-options.md](generative%20features/live-native-options.md): **Session
clips are read from their source sample; Arrangement clips are rendered pre-FX
from the timeline before transcription; samples in Ableton's compressed format
cannot be decoded directly from Session.** So the SDK offers both a
sample-file route and a render route — the bounce prerequisite that doc filed
as unspiked, demonstrated by a third party.

Consequences for our queue, recorded in
[midi-generation-options.md](generative%20features/midi-generation-options.md):
the 2026-08-30 ruling against transcription-as-primary-strategy stands, and
gains a second, independent reason. Building a transcriber or a drum separator
was never going to be the differentiator — the ecosystem fills that lane for
free, offline, under a permissive licence — Apache-2.0 on both halves, checked
above, so the licence wall that stopped the earlier drum-transcription
candidates is not what stops this one.

### 3.2 Live Smith — our thesis, on the bridge we cannot reach

`SamKuler/live-smith`, v0.2.1, TypeScript, SDK `1.0.0-beta.1`, ~103 commits.
Right-click a track, clip or device → "Ask Live Smith" → a chat webview with
that object as context. It has sessions with conversation and action history,
**Approval modes** (Manual / Low Risk / Accept Everything), **Edit Scopes**
gating MIDI / Audio / Devices / Mixer / Structure separately, model and
reasoning-level switching, multimodal attachments, hosted web search, and it
renders Arrangement clip ranges for listening or transcription. Reasoning is
bring-your-own: an OpenAI/Anthropic/Gemini API key, or a ChatGPT subscription
through Codex CLI. Keys and sessions sit in local plaintext.

**Where Seshat is ahead**, taken from Live Smith's own published limitations:

- *"does not browse installed presets, or load a VST by plug-in identifier."*
  `Seshat.Library.Catalog` is exactly that, and it is the hardest thing in the
  codebase — Ableton's own SQLite tags merged with a browser export, alias
  folding, scored tag search, round-robin across device roots, answering with
  Live closed. **Live Smith can edit what is already in the Set; it cannot
  choose a sound.**
- **Continuous state.** Our mirror is push-fed and always warm; an extension
  runs on right-click and stops, so its context is rebuilt cold every time.
- **All editions.** Extensions are Suite-only, permanently.
- **No API key.** MCP into the user's own client means their subscription
  covers reasoning, inside the conversation they are already having.

**Where they are ahead:** installation (one drag, versus clone + submodule +
`mix abletonosc.install` + Live restart + a running server + `.mcp.json`);
triggering on the object the user pointed at, with no index to resolve; the
render/bounce we do not have; and in-Live UI where the user is looking. Their
approval-and-scope model is worth borrowing conceptually — our undo-step-per-call
is recovery, not consent.

**Where both are blocked:** automation (`does not inspect or edit Automation` —
an LOM gap on our side too) and raw audio bytes (`cannot expose selected Audio
Clip or Sample bytes`).

Note the pace: 334 extensions in about three months, and the Basic Pitch author
credits Claude Code for most of the work. The catalog advantage is real but not
permanent.

---

## 4. If access opens, the first thing to build is not the assistant

The obvious move — port Seshat into an extension — throws away the three
advantages above and buys a Suite-only, right-click-only product. The better
shape is a **capability shim**: a small `.ablx` whose context-menu entry means
"send this to Seshat", which performs the operations only the SDK can
(`render_pre_fx_audio`, `import_into_project`, and whatever of §2.1 the JS API
turns out to expose) and hands off to the already-running Seshat server. The
LLM stays in the user's client; the extension is a hand, not a brain.

Feasibility rests on one unmeasured question: **can an extension reach
localhost?** Freesound Sampler and yt-ableton both fetch from the network, so
outbound requests work; whether an extension can talk to a local server, and
whether it can hold a connection open while a modal webview is up, is
unmeasured and would be the first thing to test.

The shim would be an optional enhancement, never a requirement — the Suite gate
makes that non-negotiable.

## 5. Watch items

- **Programmatic triggering.** CDM's author expects launch/event triggers to
  arrive. If they do, the whole calculus changes: extensions become a genuine
  second bridge, and Live Smith-class products get a large lift.
- **General availability.** The host code ships in the 12.4.5 release; only the
  SDK and Extension Host AddOn appear gated. Re-check whether the Extensions
  pane is reachable in a released build before assuming beta access is required
  to *install* an extension.
- **Remote Scripts' future.** Ableton told CDM the Python API "has to stay, as
  it's the basis of other interactions and the foundation of hardware support."
  No deprecation clock on the fork.

## 6. Unmeasured

Whether an extension can open a socket to localhost or hold one open; the JS
API's actual surface versus §2.1's document-level list; whether the Extensions
pane appears in the released 12.4.5 build; the SDK EULA's terms on
redistributing a built `.ablx`; the individual licences of Basic Pitch's
training datasets (Spotify's own declarations were checked, §3.1); whether
an AX-driven context-menu press could invoke an extension action (and whether
that is a route worth having at all).

## Sources

[Extensions SDK — public beta](https://ableton.github.io/extensions-sdk/) ·
[Introducing Extensions SDK (Ableton blog, 2 Jun 2026)](https://www.ableton.com/en/blog/introducing-extensions-sdk/) ·
[Ableton Extensions page](https://www.ableton.com/en/live/extensions/) ·
[CDM: Ableton Extensions beta](https://cdm.link/ableton-extensions-beta/) ·
[ablx.live guide](https://ablx.live/guide/) ·
[ablx.directory](https://ablx.directory/) ·
[SamKuler/live-smith](https://github.com/SamKuler/live-smith) ·
[federico-pepe/ableton-live-extensions](https://github.com/federico-pepe/ableton-live-extensions) ·
[bfollington/strudelton](https://github.com/bfollington/strudelton) ·
[Live 12 release notes](https://www.ableton.com/en/release-notes/live-12/) ·
installed Live 12.4.5 Suite build 2026-08-19_225ce5e356: binary string dump,
`lsof` on pid 95796, `Preferences.cfg`, `Log.txt`, `MIDI Remote Scripts/` —
all 2026-08-30.
