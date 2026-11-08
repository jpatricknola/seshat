#!/usr/bin/env python3
"""Wrap an NKS preset's plugin state chunk as a Live `.adv` device preset.

Spike tooling for the NKS load path (docs/PLAN_nks_load_path.md). Development
only, standard library only, never imported by `lib/`. It reads a `.nksf` with
nksf_read.py, takes the plugin class id out of `PLID` and the opaque state out
of `PCHK`, and emits a gzipped `PluginDevice` XML document of the shape Live
itself writes.

    python3 experiments/nks_load/write_adv.py \\
        "/Library/.../Massive X/Presets/Agonic Drone.nksf" \\
        --out "~/Music/Ableton/User Library/Presets/Instruments/Spike/X.adv"
    python3 experiments/nks_load/write_adv.py <nksf> --out <adv> --check

The template is transcribed from a real Live-written `<PluginDevice>` (the
public `krfantasy/alsdiff` fixture `test/data/plugin_device.xml`, re-derived
at plan-review), with the plan's Appendix recording every deliberate
deviation. Every framing question the spike still has is a flag, so a variant
is a command line rather than an edit:

    --no-source-context          drop SourceContext/BranchDeviceId entirely
    --processor-state raw|skip   PCHK bytes, or no state at all
    --stored-all-parameters      true (fixture's value) | false
    --device-role instr|audiofx  the BranchDeviceId role word
    --minor-version STR          the <Ableton MinorVersion> string
    --name NAME                  preset name (default: NISI's, else filename)

Nothing here validates against Live. A rejected `.adv` is a silent no-op whose
`load_device` reply still reads as success (measured 2026-09-01), so the only
oracle is a `get_track_devices` read-back on an empty track — see
docs/smoke_tests/auto/nks-load.md.
"""
import argparse
import gzip
import os
import sys
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import nksf_read  # noqa: E402

T = "\t"
HEX_BYTES_PER_LINE = 48  # 96 hex characters, the fixture's measured width

# Live writes the four class-id words as signed int32; identical to unsigned
# for every id whose fields are below 2**31, which is not guaranteed, so sign
# them explicitly rather than relying on it.


def signed32(value):
    return value - 0x100000000 if value >= 0x80000000 else value


def uid_block(fields, indent):
    return "".join('%s<Fields.%d Value="%d" />\n' % (indent, i, signed32(f))
                   for i, f in enumerate(fields))


def hex_block(payload, indent):
    """The ProcessorState buffer: opened by a newline, 48 bytes per line."""
    out = "\n"
    for i in range(0, len(payload), HEX_BYTES_PER_LINE):
        out += indent + payload[i:i + HEX_BYTES_PER_LINE].hex().upper() + "\n"
    return out + indent


TEMPLATE = '''<?xml version="1.0" encoding="UTF-8"?>
<Ableton MajorVersion="5" MinorVersion="@MINOR@" SchemaChangeCount="1" Creator="Ableton Live 12.4.5" Revision="">
\t<PluginDevice Id="0">
\t\t<LomId Value="0" />
\t\t<LomIdView Value="0" />
\t\t<IsExpanded Value="true" />
\t\t<BreakoutIsExpanded Value="false" />
\t\t<On>
\t\t\t<LomId Value="0" />
\t\t\t<Manual Value="true" />
\t\t\t<AutomationTarget Id="0">
\t\t\t\t<LockEnvelope Value="0" />
\t\t\t</AutomationTarget>
\t\t\t<MidiCCOnOffThresholds>
\t\t\t\t<Min Value="64" />
\t\t\t\t<Max Value="127" />
\t\t\t</MidiCCOnOffThresholds>
\t\t</On>
\t\t<ModulationSourceCount Value="0" />
\t\t<ParametersListWrapper LomId="0" />
\t\t<Pointee Id="0" />
\t\t<LastSelectedTimeableIndex Value="0" />
\t\t<LastSelectedClipEnvelopeIndex Value="0" />
\t\t<LastPresetRef>
\t\t\t<Value />
\t\t</LastPresetRef>
\t\t<LockedScripts />
\t\t<IsFolded Value="false" />
\t\t<ShouldShowPresetName Value="true" />
\t\t<UserName Value="" />
\t\t<Annotation Value="" />
@SOURCECONTEXT@\t\t<MpePitchBendUsesTuning Value="true" />
\t\t<PluginDesc>
\t\t\t<Vst3PluginInfo Id="0">
\t\t\t\t<WinPosX Value="100" />
\t\t\t\t<WinPosY Value="100" />
\t\t\t\t<NumAudioInputs Value="1" />
\t\t\t\t<NumAudioOutputs Value="1" />
\t\t\t\t<IsPlaceholderDevice Value="false" />
\t\t\t\t<Preset>
\t\t\t\t\t<Vst3Preset Id="0">
\t\t\t\t\t\t<OverwriteProtectionNumber Value="3074" />
\t\t\t\t\t\t<MpeEnabled Value="0" />
\t\t\t\t\t\t<MpeSettings>
\t\t\t\t\t\t\t<ZoneType Value="0" />
\t\t\t\t\t\t\t<FirstNoteChannel Value="1" />
\t\t\t\t\t\t\t<LastNoteChannel Value="15" />
\t\t\t\t\t\t</MpeSettings>
\t\t\t\t\t\t<ParameterSettings />
\t\t\t\t\t\t<IsOn Value="true" />
\t\t\t\t\t\t<PowerMacroControlIndex Value="-1" />
\t\t\t\t\t\t<PowerMacroMappingRange>
\t\t\t\t\t\t\t<Min Value="64" />
\t\t\t\t\t\t\t<Max Value="127" />
\t\t\t\t\t\t</PowerMacroMappingRange>
\t\t\t\t\t\t<IsFolded Value="false" />
\t\t\t\t\t\t<StoredAllParameters Value="@STOREDALL@" />
\t\t\t\t\t\t<DeviceLomId Value="0" />
\t\t\t\t\t\t<DeviceViewLomId Value="0" />
\t\t\t\t\t\t<IsOnLomId Value="0" />
\t\t\t\t\t\t<ParametersListWrapperLomId Value="0" />
\t\t\t\t\t\t<Uid>
@UID6@\t\t\t\t\t\t</Uid>
\t\t\t\t\t\t<DeviceType Value="@DEVICETYPE@" />
@PROCESSORSTATE@\t\t\t\t\t\t<ControllerState />
\t\t\t\t\t\t<Name Value="" />
\t\t\t\t\t\t<PresetRef />
\t\t\t\t\t</Vst3Preset>
\t\t\t\t</Preset>
\t\t\t\t<Name Value="@NAME@" />
\t\t\t\t<Uid>
@UID5@\t\t\t\t</Uid>
\t\t\t\t<DeviceType Value="@DEVICETYPE@" />
\t\t\t</Vst3PluginInfo>
\t\t</PluginDesc>
\t\t<MpeEnabled Value="0" />
\t\t<MpeSettings>
\t\t\t<ZoneType Value="0" />
\t\t\t<FirstNoteChannel Value="1" />
\t\t\t<LastNoteChannel Value="15" />
\t\t</MpeSettings>
\t\t<ParameterList />
\t</PluginDevice>
</Ableton>
'''

SOURCE_CONTEXT = '''\t\t<SourceContext>
\t\t\t<Value>
\t\t\t\t<BranchSourceContext Id="0">
\t\t\t\t\t<OriginalFileRef />
\t\t\t\t\t<BrowserContentPath Value="@BROWSERPATH@" />
\t\t\t\t\t<LocalFiltersJson Value="" />
\t\t\t\t\t<PresetRef />
\t\t\t\t\t<BranchDeviceId Value="device:vst3:@ROLE@:@GUID@" />
\t\t\t\t</BranchSourceContext>
\t\t\t</Value>
\t\t</SourceContext>
'''


def xml_escape(text):
    return (text.replace("&", "&amp;").replace("<", "&lt;")
                .replace(">", "&gt;").replace('"', "&quot;"))


def url_quote(text):
    out = []
    for ch in text:
        if ch.isalnum() or ch in "-_.~":
            out.append(ch)
        else:
            out.extend("%%%02X" % b for b in ch.encode("utf-8"))
    return "".join(out)


def build_xml(fields, state, name, plugin_name, plugin_vendor, opts):
    guid = nksf_read.vst3_guid(fields)
    device_type = "2" if opts.device_role == "audiofx" else "1"

    if opts.no_source_context:
        source_context = ""
    else:
        browser_path = opts.browser_content_path or (
            "query:Plugins#VST3:%s:%s" % (url_quote(plugin_vendor or "Native Instruments"),
                                          url_quote(plugin_name))
            if plugin_name else "query:Plugins#VST3")
        source_context = (SOURCE_CONTEXT
                          .replace("@BROWSERPATH@", xml_escape(browser_path))
                          .replace("@ROLE@", opts.device_role)
                          .replace("@GUID@", guid))

    if opts.processor_state == "skip":
        processor_state = ""
    else:
        processor_state = "%s<ProcessorState>%s</ProcessorState>\n" % (
            T * 6, hex_block(state, T * 6))

    return (TEMPLATE
            .replace("@MINOR@", opts.minor_version)
            .replace("@SOURCECONTEXT@", source_context)
            .replace("@STOREDALL@", opts.stored_all_parameters)
            .replace("@UID6@", uid_block(fields, T * 6))
            .replace("@UID5@", uid_block(fields, T * 5))
            .replace("@PROCESSORSTATE@", processor_state)
            .replace("@DEVICETYPE@", device_type)
            .replace("@NAME@", xml_escape(name)))


def check_output(path, fields, state, opts):
    """Re-read the written file: gunzip, parse, round-trip uid and state."""
    with gzip.open(path, "rb") as f:
        text = f.read().decode("utf-8")
    root = ET.fromstring(text)
    info = root.find("./PluginDevice/PluginDesc/Vst3PluginInfo")
    if info is None:
        raise SystemExit("--check: no Vst3PluginInfo in the written document")
    read_fields = [int(info.find("./Uid/Fields.%d" % i).get("Value"))
                   for i in range(4)]
    if [signed32(f) for f in fields] != read_fields:
        raise SystemExit("--check: uid round-trip mismatch: %r vs %r"
                         % (fields, read_fields))
    preset = info.find("./Preset/Vst3Preset")
    node = preset.find("./ProcessorState")
    if opts.processor_state == "skip":
        if node is not None:
            raise SystemExit("--check: --processor-state=skip still wrote a state")
    else:
        read_state = bytes.fromhex("".join(node.text.split()))
        if read_state != state:
            raise SystemExit("--check: ProcessorState round-trip mismatch "
                             "(%d bytes written, %d read)"
                             % (len(state), len(read_state)))
        lines = [line.strip() for line in node.text.splitlines() if line.strip()]
        widths = {len(line) for line in lines[:-1]}
        if widths - {HEX_BYTES_PER_LINE * 2}:
            raise SystemExit("--check: unexpected hex line widths %r" % sorted(widths))
        if len(lines[-1]) > HEX_BYTES_PER_LINE * 2:
            raise SystemExit("--check: final hex line is %d chars" % len(lines[-1]))
    if preset.find("./StoredAllParameters").get("Value") != opts.stored_all_parameters:
        raise SystemExit("--check: StoredAllParameters did not round-trip")
    branch = root.find("./PluginDevice/SourceContext/Value/BranchSourceContext"
                       "/BranchDeviceId")
    if opts.no_source_context:
        if branch is not None:
            raise SystemExit("--check: --no-source-context still wrote a BranchDeviceId")
    elif branch.get("Value") != "device:vst3:%s:%s" % (opts.device_role,
                                                       nksf_read.vst3_guid(fields)):
        raise SystemExit("--check: BranchDeviceId is %r" % branch.get("Value"))
    print("check: ok (%d bytes gzipped, %d bytes of state)"
          % (os.path.getsize(path), 0 if opts.processor_state == "skip" else len(state)))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("nksf", help="path to the .nksf preset")
    parser.add_argument("--out", required=True, help="path of the .adv to write")
    parser.add_argument("--name", help="preset name (default: the NKS name)")
    parser.add_argument("--no-source-context", action="store_true",
                        help="omit SourceContext/BranchDeviceId (a variant "
                             "measured to no-op — the smoke tests' control)")
    parser.add_argument("--processor-state", choices=["raw", "skip"], default="raw",
                        help="raw PCHK bytes (default) or no state at all")
    parser.add_argument("--stored-all-parameters", choices=["true", "false"],
                        default="true", help="the fixture's value is true")
    parser.add_argument("--device-role", choices=["instr", "audiofx"], default="instr")
    parser.add_argument("--minor-version", default="12.0_12402",
                        help="the <Ableton MinorVersion> string; a Live 11 "
                             "value engages Live's schema-migration path")
    parser.add_argument("--browser-content-path",
                        help="override the BranchSourceContext BrowserContentPath")
    parser.add_argument("--check", action="store_true",
                        help="re-read the written file and assert the round trip")
    opts = parser.parse_args(argv)

    chunks = dict(nksf_read.read_file(os.path.expanduser(opts.nksf)))
    if b"PLID" not in chunks:
        raise SystemExit("%s has no PLID chunk — no plugin id to write"
                         % opts.nksf)
    plid = nksf_read.unpack_chunk(chunks[b"PLID"])
    fields = nksf_read.vst3_uid_fields(plid)
    state = chunks.get(b"PCHK", b"")
    if not state and opts.processor_state == "raw":
        raise SystemExit("%s has no PCHK chunk — pass --processor-state skip "
                         "to write the framing without state" % opts.nksf)

    name = opts.name
    if not name and b"NISI" in chunks:
        try:
            name = nksf_read.unpack_chunk(chunks[b"NISI"]).get("name")
        except nksf_read.NksfError:
            name = None
    if not name:
        name = os.path.splitext(os.path.basename(opts.nksf))[0]

    xml = build_xml(fields, state, name, plid.get("pluginName"),
                    plid.get("pluginVendor"), opts)
    out = os.path.expanduser(opts.out)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with gzip.open(out, "wb") as f:
        f.write(xml.encode("utf-8"))
    print("wrote %s (%d bytes gzipped, plugin %r, class id %s)"
          % (out, os.path.getsize(out), plid.get("pluginName"),
             nksf_read.vst3_guid(fields)))
    if opts.check:
        check_output(out, fields, state, opts)
    return 0


if __name__ == "__main__":
    sys.exit(main())
