# Plan — AX-backed audio-output selection

Roadmap item **“AX-backed audio output — the first narrow UI workflow.”** Two
new MCP tools — `get_audio_outputs` and `set_audio_output` — backed by a
prebuilt native macOS Accessibility helper rather than OSC. This feature also
establishes the smallest reusable AX execution boundary Seshat needs for future
operations that pass the same LOM-gap and named-element/read-back tests.

**Acceptance is user-perceived, not helper-only.** With Live and Seshat already
running and Accessibility permission granted, a fresh local MCP conversation
asking “change Live’s audio output to the headphones” must resolve the installed
device, select it, verify Live’s value, and leave the UI restored within **10
seconds** in three consecutive runs. The normal target is under 5 seconds. The
setter’s own handler-to-verified-result budget is 5 seconds; a 30-second result
is a failure even if the native AX calls themselves were fast.

## Context

Live’s application-wide audio input/output preferences are absent from the
installed Live 12.4.3 Live Object Model and from AbletonOSC. The absence was
rechecked against the installed LOM allowlist, the fork, and
[../priv/AbletonOSC/API.md](../priv/AbletonOSC/API.md); this is a genuine LOM gap, not
a missing fork address. The LOM-first rule therefore permits a narrow AX
implementation while still rejecting AX for anything the fork can expose.

The 2026-08-03 spike in
[evaluating/ui-scripting-options.md](evaluating/ui-scripting-options.md)
established the complete mechanism on macOS 15.7.4 and Live 12.4.3:

- Accessibility permission attached to the direct helper executable; no Apple
  Events or Screen Recording permission and no restart were required.
- Live is found by bundle identifier `com.ableton.live`; its process and bundle
  name is merely `Live`.
- Live reports zero AX windows while inactive, so the helper must activate it
  before reading Settings.
- Settings, the Audio page, the output popup, its choices, and its current value
  are semantic AX elements with direct actions; no coordinates or keystrokes
  are required.
- A bounded helper changed `Use System: 25 AirPods` to MacBook Pro Speakers,
  read the new value, restored the original choice, and read that back in 1.55
  seconds. A later single change completed in 0.37 seconds.

Those timings prove the native mechanism can fit the budget; they are not the
feature acceptance. The user also observed a 37-second conversational turn
whose native close action took 1.07 seconds because the exploratory code was
being edited and compiled inside the request. Production must remove compiling,
permission prompting, generic tree dumps, and multiple model-requested cleanup
steps from the action path, then measure the whole request in a real client.

### Architectural decisions

- **A reusable executable means prebuilt and stable, not necessarily
  long-running.** V1 starts the same installed helper once per tool call. The
  measured process-plus-action time is already small, while a persistent Port
  would add protocol recovery, restart, and stale-state concerns before startup
  cost has proved material. Timing instrumentation leaves that decision
  measurable; promotion to a persistent Port requires evidence that process
  startup consumes a meaningful part of the 5-second tool budget.
- **One helper invocation owns one complete UI transaction.** The setter
  activates Live, preserves initial UI state, opens/navigates Settings, selects,
  verifies, closes only what it opened, and restores the prior foreground
  application before replying. Closing Settings is not a second MCP action.
- **Two tools preserve Seshat’s resolver boundary.** Installed names are
  machine-specific. `get_audio_outputs` returns them; the model resolves
  “headphones” to (for example) `25 AirPods`; `set_audio_output` accepts an exact
  returned name. The native layer does case-insensitive exact matching after
  stripping the menu’s checkmark, never fuzzy or semantic matching.
- **AX calls are serialized separately from OSC.** Concurrent clients must not
  manipulate the same Settings popup at once, but an AX call must neither open
  an Ableton undo step nor hold the global OSC undo lock.
- **The helper is intentionally not a generic UI remote.** Its protocol offers
  only audio-output listing, setting, and permission status. Every future AX
  operation still needs an independent LOM-gap, safety, semantic-target, and
  read-back case.

## OSC contract

**None.** No OSC address can read or write Live’s application-wide audio-device
preference, and this feature adds no AbletonOSC Python, submodule commit, pin
bump, `mix abletonosc.install`, or Live restart. In particular, the AX-backed
tools must emit no `/live/song/begin_undo_step` or
`/live/song/end_undo_step` datagrams.

The mechanism boundary below `Seshat.Tools.Handlers` becomes:

```text
MCP tool → Handlers → Seshat.AX.Client → installed seshat-ax → AXUIElement → Live
```

## Native helper contract

The installed executable accepts only these commands:

| Command | Arguments | JSON result |
|---|---|---|
| `version` | none | `{ok, protocol_version}` |
| `permission` | optional `--prompt` (installer only) | `{ok, trusted, protocol_version}` |
| `list-outputs` | none | `{ok, current, devices, elapsed_ms, protocol_version}` |
| `set-output` | `--device <exact display name>` | `{ok, previous, current, elapsed_ms, protocol_version}` |

Normal commands carry `protocol_version` in the same response, so no extra
version subprocess sits in the latency path. Errors use one JSON shape and a
non-zero exit status:

```json
{"ok":false,"code":"permission_required","message":"…","protocol_version":1}
```

Required codes are `permission_required`, `live_not_running`,
`settings_unavailable`, `device_not_found`, `ax_failure`, and `timeout`.
`device_not_found` also returns the currently available names so the model can
recover rather than guess again. Stdout contains one JSON document only; no
human log text is mixed into the protocol. Device names are argv entries passed
directly to `Port.open` — never shell-interpolated.

### Bounded AX selector path

The native implementation uses only the measured semantic path:

1. Find `NSRunningApplication` by bundle identifier `com.ableton.live` and
   remember the previous frontmost application.
2. Activate Live and wait, under the single operation deadline, for it to report
   active.
3. Read `AXWindows`. If Settings is absent, press the named `Settings...` menu
   item through `AXPress` and remember that the helper opened it.
4. In the `Settings` window, preserve the selected Settings page, press the
   radio button with identifier `audioTabButton` when necessary, then find the
   group identifier `audio`.
5. Within that bounded group, find the `AXPopUpButton` described as
   `Audio Output Device`; read `AXValue` for the current selection.
6. Press it and read the temporary AX window containing group identifier
   `ChooserPopUp`; enumerate its direct `AXMenuItem` children. Strip only the
   leading checkmark from returned display names.
7. For a set, press the case-insensitive exact menu-title match and re-read the
   output popup until its value reflects the selected choice. `Use System
   Device` is the one special verification: its resulting value begins `Use
   System:` and names the current macOS device.
8. In cleanup on success and every handled error: dismiss any chooser left
   open; restore the original Settings page when Settings was already open;
   close Settings only when the helper opened it; restore the previously
   frontmost application.

No step falls back to sibling order, coordinates, screenshots, AppleScript, or
synthetic keys. AX messaging calls use short per-call timeouts and targeted
50ms polling under one monotonic deadline; V1 does not add an `AXObserver`
runloop for the handful of transitions already measured below one second.
Element references are reacquired after a device change or window transition,
not cached across window lifecycles.

The initial implementation supports the measured English Live 12.4.3 labels.
Other localizations are out of scope until their semantic labels are measured;
coordinates are not an acceptable localization fallback.

## Numbered parts

### 1. Native executable — `native/seshat_ax/main.m`

Promote the spike into a small Objective-C command-line program linked directly
to AppKit and ApplicationServices. Keep one source file while this helper has
one domain; do not introduce a Swift dependency (the installed Swift compiler
and SDK were mismatched during the spike, while `clang` compiled the same API
successfully).

Implement the four-command JSON protocol and bounded selector path above.
Additional requirements:

- `AXIsProcessTrustedWithOptions` receives `prompt: false` for normal commands;
  only `permission --prompt` may open macOS setup UI.
- An already-selected device is an idempotent verified success.
- Selection success means the popup’s post-action value was observed, never
  merely that `AXPress` returned zero.
- The helper owns a 4,000ms monotonic action deadline and always attempts UI
  cleanup before returning an error. It must not recursively enumerate Live’s
  full AX tree or print AX diagnostics to stdout.
- Output size is bounded (device names only); malformed/non-string AX values
  produce structured errors rather than Objective-C descriptions in JSON.
- `version` returns a helper/protocol version so Elixir can reject an old
  installed binary after the repository protocol changes.

### 2. Stable installation and permission setup —
`lib/mix/tasks/ax.install.ex`, `README.md`

Add `mix ax.install`, a macOS-only task that:

1. Compiles `native/seshat_ax/main.m` with `/usr/bin/clang`, ARC, and the AppKit
   and ApplicationServices frameworks, treating warnings as errors.
2. Writes a temporary executable and atomically replaces the stable
   `~/.seshat/bin/seshat-ax` target only after compilation succeeds. The spike
   observed Accessibility trust surviving repeated recompiles at one stable
   helper path; after replacement the task checks trust again and never assumes
   it survived.
3. Runs `permission --prompt` unless `--no-prompt` was passed, then prints the
   exact Privacy & Security path and installed executable path when trust is
   still absent. Granting permission needs no Live or Seshat restart.
4. Accepts `--destination` for an isolated macOS CI build/check without writing
   the real user installation.

Do not put this task in `mix compile` or the existing Linux CI job: ordinary
Elixir compilation must remain cross-platform and must not prompt for macOS
privacy permission. Add the explicit `mix ax.install` step to README setup and
document that permission setup is one-time onboarding, excluded from normal
latency acceptance. A normal tool call with a missing helper or permission
returns the same actionable install instruction immediately; it does not open
System Settings behind the user’s back.

### 3. Elixir execution boundary — `lib/seshat/ax/client.ex`

Add `Seshat.AX.Client` as the only Elixir module allowed to execute the native
helper.

- Resolve the helper from `Application.get_env(:seshat, :ax_helper_path)` or
  the stable default under `~/.seshat/bin`.
- Start the exact executable with `Port.open({:spawn_executable, path}, ...)` and
  an argv list. Do not use a shell or `System.cmd/3`.
- Buffer the one JSON response, require an exit status, reject an oversized or
  malformed response, and translate native error codes into concise user-facing
  errors. Permission/missing-binary errors name `mix ax.install`.
- Enforce a 5,000ms outer Port deadline around the native 4-second action
  budget; close a hung Port and return an honest `timeout` error. This keeps
  failure inside the same 5-second MCP-call acceptance as success.
- Serialize calls with a dedicated node-wide AX lock. Do not reuse the OSC undo
  lock: an output change may overlap ordinary OSC work and is not part of Live’s
  undo history.
- Measure handler-to-result duration with `System.monotonic_time/1` and log the
  operation, success/error code, and elapsed milliseconds. Do not encourage the
  model to relay plumbing timings in normal prose.

V1 is intentionally one process per call. If live measurements show helper
startup materially consumes the tool budget, a later change may place the same
versioned JSON protocol behind a supervised persistent Port without changing
the tool contracts or native selector logic.

### 4. Tool definitions and undo-boundary metadata —
`lib/seshat/tools/definitions.ex`, `lib/seshat/tools/handlers.ex`,
`.claude/docs/adding-a-tool.md`, `.claude/rules/osc.md`

Add internal `undo_step: false` metadata to both AX definitions. Definitions
remain the single tool list; `Handlers` derives the set of undo-stepped names
from it, defaulting missing metadata to `true` for all 65 existing tools. A
known `undo_step: false` tool dispatches directly after validation, without the
OSC global lock or any begin/end datagrams. Unknown tools remain wire-silent.

Document this opt-out in the adding-tool and OSC rules: it is for a tool whose
mechanism cannot contribute to Live’s LOM undo history, not a convenience for
ordinary read-only OSC tools (which remain wrapped by deliberate policy).

Update the `undo` and `redo` descriptions and their pinned tests so they no
longer make the now-false claim that every tool call is an Ableton undo step.
They must say AX-backed audio-output calls are outside Live’s undo history and
must be reversed with `set_audio_output`, not counted in repeated `undo`/`redo`
sequences.

Draft definitions:

`get_audio_outputs`:

> List the audio output choices currently available in Ableton Live and report
> Live’s current selection. Call this before set_audio_output when the user
> gives a human description such as “headphones” or the installed device name
> is not already known; device names are machine-specific. Resolve the user’s
> wording to one exact returned name, then call set_audio_output in the same
> request. This may briefly bring Live to the foreground while it reads Audio
> Settings, then restores the prior application and Settings visibility.

No parameters.

`set_audio_output`:

> Set Ableton Live’s application-wide audio output to an exact name returned by
> get_audio_outputs. For “headphones”, “speakers”, or another generic target,
> call get_audio_outputs first and resolve it to an installed name; never invent
> a device. “Use System Device” is a real choice when the user wants Live to
> follow macOS. Switching can briefly interrupt audio. The tool selects by
> semantic Accessibility elements, reads Live’s resulting value back, restores
> the prior application and Settings visibility, and reports an error rather
> than success when verification fails. This change is outside Live’s undo
> history; change it back with this tool, not undo.

Parameters: required string `device`, described as “Exact display name returned
by get_audio_outputs.” Current tool count becomes 65 → 67; generated MCP
components and schema remain automatic.

### 5. Handler integration — `lib/seshat/tools/handlers.ex`

Add `do_call/2` clauses that delegate to a configurable AX client module
(`Application.get_env(:seshat, :ax_client, Seshat.AX.Client)`) so pure tests can
substitute a fake without executing UI automation.

- `get_audio_outputs` renders the current value and the exact available names
  compactly enough for the model to resolve the next call.
- `set_audio_output` renders the observed previous → current values only after
  native verification. It never claims success from exit status alone.
- Native errors remain MCP tool errors with recovery guidance. A missing device
  includes the fresh choices; missing permission/helper names `mix ax.install`;
  Live absent says to start Live. No Objective-C or AX constants leak to the
  user-facing text.

Do not use `%Command{}`, `Registry`, `FollowCam`, `Transport`, or
`Session.State`. Audio-device state is query-on-demand and external to the Live
Set; it does not belong in the session mirror.

### 6. Automated tests and macOS compile check

Files:

- `test/seshat/ax/client_test.exs`
- `test/support/fake_ax_client.ex`
- `test/seshat/tools/definitions_test.exs`
- `test/seshat/tools/handlers_test.exs`
- `test/seshat/mcp/tools_test.exs` (existing generated sweeps; add only a
  focused assertion if the new schema exposes a combination they do not cover)
- `.github/workflows/ci.yml`

Cover without Live or Accessibility permission:

1. Client protocol: success list/set decoding, every structured error,
   non-zero exit, malformed/oversized output, missing executable, helper
   version mismatch, and outer timeout. Tests use an injected fixture
   executable/path; they never invoke AX or the installed helper.
2. AX serialization: two concurrent fake operations cannot overlap, while an
   OSC handler call is not held behind the AX lock.
3. Definitions: count 65 → 67, schemas and required fields, the resolver text,
   exact-name contract, latency-relevant same-request guidance, and
   `undo_step: false` on exactly the AX tools.
4. Dispatch: both AX handlers call the fake client and format success/error
   honestly with no `Seshat.OSC.Transport` running. An OSCSink-backed assertion
   proves each sends **zero** OSC datagrams; an ordinary OSC tool still retains
   the existing defensive-end/begin/action/end trace.
5. Undo/redo prompt tests: audio-output changes are explicitly excluded from
   the counted Ableton steps and routed back through `set_audio_output`.
6. Boundary tripwire, in `client_test.exs`: grep `lib/seshat/` and assert
   `Port.open`, `:spawn_executable`, and `System.cmd` appear only in
   `lib/seshat/ax/client.ex` — pinning the "only Elixir module allowed to
   execute the native helper" claim the way `vendored_addresses_test` pins the
   fork's address surface. With the `undo_step: false` set pinned in item 3,
   no future tool can quietly grow a second AX or subprocess path.

Add a small `macos-latest` CI job that compiles the Objective-C source with the
same warnings-as-errors command as `mix ax.install`, runs only the permission
status command, and asserts the reply is well-formed and internally consistent.
It originally asserted `permission_required` on the reasoning that a fresh
runner holds no grant; that assertion failed on its first run (2026-08-27) —
the runner reported `trusted: true` — so the step now accepts either answer and
checks that `trusted` agrees with `ok`, `code` and the exit status. The existing
Ubuntu Elixir job remains unchanged. Neither CI job controls a real
application.

`mix precommit` remains the Elixir bar. On macOS, also run
`mix ax.install --no-prompt --destination <temporary path>` so the exact native
build path is verified without replacing the user-authorized installed helper.

### 7. Documentation and bookkeeping

- `README.md`: macOS-only helper install/permission setup, stable path, no
  Apple Events or Screen Recording requirement, no restart, troubleshooting,
  and the foreground/UI restoration behavior.
- `CLAUDE.md`: add `Seshat.AX.Client` and `native/seshat_ax/main.m` to the
  module map; revise “every tool gets an undo step” to describe the
  definition-owned AX opt-out.
- `docs/evaluating/ui-scripting-options.md`: link this plan, change the stale
  “only rung 1 is validated” sentence, distinguish helper timings from the
  end-to-end acceptance, and mark the audio-output go/no-go spike complete.
- `docs/ROADMAP.md`: retain the full issue and link this plan; `/ship` removes
  it only after the feature and live latency evidence land.
- No change to `priv/AbletonOSC/API.md`: there is deliberately no OSC
  contract.

## Testing

Automated coverage stops at the native process protocol and fake AX client.
Ubuntu CI cannot compile AppKit code; the macOS job can compile and exercise
permission failure but has neither Live nor granted Accessibility permission.
Therefore no automated test proves that Live’s identifiers, popup actions,
device transition, focus restoration, or Settings cleanup work. Those are live
checks below.

Latency tests must report distinct clocks:

- native `elapsed_ms` (diagnostic evidence only),
- MCP tool-call wall time from request to verified result, and
- user-perceived time from submitting natural language until Live’s output
  value changes.

No result may present the first clock as though it were the third.

## Live verification

Nothing in `mix test` reaches AX, Live’s Settings, macOS foreground behavior,
routed audio hardware, or a real client’s model loop. Run with `/smoke-test`.

- `smoke_tests/auto/audio-output.md § The available outputs and current selection agree with Live`
  — semantic discovery, bounded direct-tool latency, reply stability across
  repeated reads, and foreground restoration from the Settings-closed state.
- `smoke_tests/manual/engineered-state.md § An open Settings window survives an audio-output read`
  — preservation of an initially open Settings window and its selected page.
  Manual because that starting state cannot be created by any tool and the
  window must be judged by eye.
- `smoke_tests/auto/audio-output.md § A named output changes, verifies, and restores`
  — exact-name set, independent read-back, 5-second tool budget, and
  foreground cleanup; audible hardware movement is judged by ear in the
  manual conversation check below.
- `smoke_tests/auto/audio-output.md § An unavailable output fails quickly and changes nothing`
  — agent-runnable exact-match error, fresh recovery choices, unchanged state,
  and bounded failure.
- `smoke_tests/manual/conversation.md § Headphones resolve and switch within the user-visible budget`
  — the acceptance criterion: one fresh-conversation request, model resolution
  through both tools, three runs at no more than 10 seconds each, and no
  separate cleanup action.
- `smoke_tests/auto/mcp-surface.md § The tool list survives a real handshake` — the
  two generated components reach an actual MCP client.
- `smoke_tests/auto/mcp-surface.md § A changed property carries what you intended`
  — `set_audio_output.device` is a required string on the advertised wire
  schema.
- `smoke_tests/manual/engineered-state.md § A blocked Settings window still gives focus back`
  — added in the 2026-08-27 PR review round, closing the round's blocking
  finding: a Settings window that never opens (a modal dialog in front of it)
  must not leave Live's UI focus changed forever. Manual because the blocking
  state cannot be created by any tool.

**Uncovered:** first-time Accessibility consent (one-time manual onboarding,
not a normal request); unplugging the selected device during the AX action (not
deterministically reproducible); non-English Live labels (out of scope); and
Bluetooth/CoreAudio behavior on hardware other than the devices installed on
this Mac. The macOS CI job proves compilation and a well-formed permission
reply, not trusted cross-process control.

Also uncovered, and now with evidence against the assumption it rests on:
whether Accessibility trust is scoped to the installed executable's path.
Three observations on 2026-08-27 say a never-approved build can read as
trusted — two PR reviews running a scratch build from an already-approved
terminal, and the macOS CI runner, a machine with no grant at all, which is
what broke the CI step above. The terminal cases point at parent-process
attribution; the CI case is equally consistent with that environment being
trusted wholesale (a runner as root would be), so the two explanations are
still not separated. README.md's "Open question" note under "Install the
Accessibility helper" and `mix ax.install`'s moduledoc both carry the
corrected picture. Resolving it needs the one comparison nobody has run: the
same installed build launched from an approved parent and from an unapproved
one, on a real machine — the kind of experiment this repo's process rules do
not let an agent phase run unsupervised.

## Out of scope

- Audio input-device selection; prove and plan it separately even though it is
  adjacent in the same Settings group.
- Changing the macOS system-wide output. `Use System Device` may be selected in
  Live, but Seshat does not alter the system default.
- A generic AX tree walker, generic menu command, coordinate clicking,
  screenshots, keystrokes, or AppleScript/System Events.
- File lifecycle operations and pressing arbitrary dialogs; the existing
  prohibition on choosing how to handle unsaved work is unchanged.
- Non-English Live labels until each localization’s semantic AX exposure is
  measured. No coordinate fallback.
- Windows/Linux UI automation. Elixir CI remains cross-platform, but the
  feature itself is macOS-only.
- A persistent AX daemon/Port. Reconsider only if instrumented one-shot startup
  materially threatens the tool budget.
- Mirroring audio-device state in `Session.State`; it is infrequent,
  application-wide state read on demand.

There are no open questions. The implementation choices above use the measured
Live 12.4.3/macOS 15.7.4 behavior. The only unproved claims are deliberately
expressed as live acceptance tests rather than deferred design decisions.
