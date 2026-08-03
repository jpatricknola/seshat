# Audio output

The macOS Accessibility-backed audio-output tools. These checks are separate
from OSC transport: they exercise Live's semantic Settings UI, the native
helper's read-back, routed hardware, UI restoration, and the latency visible to
a caller.

## An unavailable output fails quickly and changes nothing

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
