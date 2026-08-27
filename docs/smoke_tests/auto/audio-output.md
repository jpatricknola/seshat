# Audio output

The macOS Accessibility-backed audio-output tools. These checks are separate
from OSC transport: they exercise Live's semantic Settings UI, the native
helper's read-back, routed hardware, UI restoration, and the latency visible to
a caller.

## The available outputs and current selection agree with Live

*Last run: 2026-08-27 — **partly**, and not as written. Ten consecutive native
helper runs and one `Seshat.Tools.Handlers.call/2` run passed against Live
12.4.3 / macOS 15.7.4: identical replies every time (`Use System: MacBook Pro
Speakers (0 In, 2 Out)` plus `No Device` and `Use System Device`), 0.33–1.04s
native and 736ms through the handler, VSCode frontmost again and Live holding
one window after every run. **No MCP client was involved**, so the wire schema
and the client's own latency are still unmeasured — re-run this as written.
The first two attempts failed and found two real defects, both now fixed: a
`while (!live.active)` wait that hung on a stale activation flag, and an
unwaited focus restore that made every third back-to-back run press a menu Live
was not listening to.*

With Live running, Settings closed, and a non-Live application frontmost
(record which one from the shell first), issue one direct MCP call to
`get_audio_outputs` and time it. The reply must arrive within 5 seconds and
carry both Live's current selection and the exact installed display names — at
minimum `Use System Device` plus this machine's built-in output. A current
value beginning `Use System:` is the current selection, not an extra device.
Call it a second time: the same names and value must come back, and after each
call the recorded application must be frontmost again.

More than 5 seconds means the native or Port deadline is not bounding the read
path. Names differing between two idle back-to-back calls means enumeration is
reading unstable elements rather than the chooser's menu items. A changed
frontmost application means the helper's cleanup did not restore focus.
Whether an *already open* Settings window and its selected page survive the
read is judged by a person:
[engineered-state.md § An open Settings window survives an audio-output read](../manual/engineered-state.md).

## A named output changes, verifies, and restores

*Last run: 2026-08-27 — **partly**, and not as written. Through
`Seshat.Tools.Handlers.call/2` rather than an MCP client: explicit device (757ms),
idempotent repeat reporting no change (302ms), restore to `Use System Device`
(890ms), independent read agreeing (333ms). Previous and current values were both
read off Live's own popup, and the frontmost application and Settings visibility
were unchanged afterwards. Two caveats: **no MCP client**, and this machine has
one physical output, so `Use System Device` and the built-in speakers are the
same hardware — nothing moved audibly and nothing could. Re-run as written.*

Call `get_audio_outputs` and pick an installed choice other than the current
one (on a machine with one real device, `Use System Device` and the built-in
output are still two distinct choices). Issue one direct MCP call to
`set_audio_output` with that exact returned name and time only that call. The
reply must arrive within 5 seconds and state the observed previous and current
values, with the current value read back from Live rather than echoed from the
request. Confirm independently with a fresh `get_audio_outputs`, then restore
the original selection the same way and confirm again. The frontmost
application must be unchanged after every call.

A success reply whose current value disagrees with the follow-up read means
verification read a stale element, or success was claimed from the press
rather than the observed popup value. Over 5 seconds means the deadlines are
not bounding the set path. A changed frontmost application means the
transaction leaked UI state. Whether the switch is audible on real hardware is
judged by ear in
[conversation.md § Headphones resolve and switch within the user-visible budget](../manual/conversation.md).

## An unavailable output fails quickly and changes nothing

*Last run: 2026-08-27 — **partly**, and not as written. `Seshat Missing Output
Device` was refused in 371ms through `Seshat.Tools.Handlers.call/2` (0.79s
native), carrying all three real names and the unchanged current value, with
nothing claimed to have changed and a following read confirming it. **No MCP
client**, so re-run as written.*

Read the current value with `get_audio_outputs`, then issue one direct MCP call
to `set_audio_output` with the exact impossible name
`Seshat Missing Output Device` and time only that call. It must return an MCP
tool error within 5 seconds, include the fresh available names, and must not
claim that anything changed. Read `get_audio_outputs` again; the current value
must be unchanged.

A timeout means the native or Port deadline is not bounding failure. A generic
error with no choices means the model cannot recover without another exploratory
call. A changed value means matching was not exact or cleanup selected an
unintended menu item.
