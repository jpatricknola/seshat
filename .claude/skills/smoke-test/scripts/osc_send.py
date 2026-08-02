#!/usr/bin/env python3
"""Send-only OSC to AbletonOSC's command port.

Send-only is the point: Seshat's own reader owns 127.0.0.1:11001, and a client
that binds it to hear a reply makes Seshat deaf for as long as it holds the
port. Every reply to what this sends goes to the running Seshat, not here — so
the observable outcome of a send is a tool read-back, or a line in Live's
Log.txt, never this script's output.

    python3 .claude/skills/smoke-test/scripts/osc_send.py /live/song/set/tempo 120.0
    python3 .claude/skills/smoke-test/scripts/osc_send.py /live/browser/preview_item query:Sounds#Bass:FileId_5200

Arguments are typed by inspection: ints stay ints, floats stay floats,
everything else is a string. Force a string with a leading backslash.
"""

import sys

sys.path.insert(0, "priv/AbletonOSC")

from pythonosc.udp_client import SimpleUDPClient  # noqa: E402


def typed(arg):
    if arg.startswith("\\"):
        return arg[1:]
    for cast in (int, float):
        try:
            return cast(arg)
        except ValueError:
            pass
    return arg


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    address, args = argv[1], [typed(a) for a in argv[2:]]
    SimpleUDPClient("127.0.0.1", 11000).send_message(address, args)
    print(f"sent {address} {args} (no reply expected here — read it back with a tool)")


if __name__ == "__main__":
    main(sys.argv)
