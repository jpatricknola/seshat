# Audio output

The macOS Accessibility-backed audio-output tools. These checks are separate
from OSC transport: they exercise Live's semantic Settings UI, the native
helper's read-back, routed hardware, UI restoration, and the latency visible to
a caller.

## The available outputs and current selection agree with Live

*Run mode: user — requires comparing the tool result with Live's visible Audio Settings*
*Last run: —*

Start with Live frontmost and Settings closed. Put another application in front,
then call `get_audio_outputs` over MCP and time the call. Its current value and
available names must match the Audio Output Device popup when Settings is opened
by hand immediately afterward. The call must finish within 5 seconds, return no
generic AX tree or unrelated UI labels, restore the previously frontmost
application, and leave Settings closed because it was closed initially.

Repeat once with Settings already open on a page other than Audio. The same
device list must return, the previously selected page must be restored, and
Settings must remain open. A disagreement means the bounded selectors or menu
normalization drifted; lost foreground/page/window state means the helper's
transaction cleanup is incomplete.

## A named output changes, verifies, and restores

*Run mode: user — requires safe routed hardware and hearing the output transition*
*Last run: —*

Call `get_audio_outputs`, note the current choice, and choose one other safe
connected output by its exact returned name. With Settings closed and another
application frontmost, call `set_audio_output` with that exact name over MCP and
time the call. It must return within 5 seconds, report the observed previous and
new Live values, move the audible output to the requested hardware, restore the
previously frontmost application, and leave Settings closed without a second
cleanup tool call.

Read `get_audio_outputs` again: its current value must name the requested
device. Then set the original choice back and repeat the read-back so the test
leaves routing as it found it. A success reply without both audible movement and
the independent second read means native post-action verification or handler
reporting is false; a Settings window left behind means one helper invocation no
longer owns the complete transaction.

## An unavailable output fails quickly and changes nothing

*Run mode: agent*
*Last run: —*

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
