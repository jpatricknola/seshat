# Architecture Evaluation: Option 3 (Tool Use) vs Option 4 (Structured JSON)

## Context

We're evaluating two approaches for how the LLM integrates with our DAW assistant:

- **Option 4 (Structured JSON):** What we have today. User input goes to the Anthropic API with a system prompt. Claude returns a single JSON object. Our Elixir code parses it and executes the corresponding OSC command(s).
- **Option 3 (Tool Use):** Claude receives tool definitions (e.g. `pan_track`, `search_presets`, `load_instrument`) and calls them directly. Our app executes each tool call and returns results. Claude can chain multiple calls and reason between steps. Still uses our custom UI and the Anthropic API — not Claude Desktop.

## Use Cases

### 1. Simple mixer commands

> "Pan track 1 to the left," "Set volume on drums to 50%"

**Status:** Already supported.

Single input, single action, deterministic mapping.

**Verdict: Option 4 is fine.** One prompt, one JSON, one OSC message. Tool use adds overhead with no benefit. This is the sweet spot for the current architecture.

---

### 2. Track creation / project scaffolding

> "Add a MIDI track for synth pads," "Start a new hip-hop project"

**Status:** Already supported.

Still single-turn, though `new_project` creates multiple tracks.

**Verdict: Option 4 is fine.** The LLM returns a list of tracks, our code iterates. No need for Claude to see intermediate results.

---

### 3. Batch mixer operations

> "Mute everything except drums and bass," "Reset all panning to center"

**Status:** Not yet supported.

Requires knowing all tracks and applying logic across them.

**Verdict: Option 4 still works**, but the JSON schema needs to support arrays of commands. The parser would return `[{command, track, value}, ...]`. Claude already gets session state in the system prompt, so it can figure out which tracks to mute. No back-and-forth needed.

---

### 4. Relative / contextual adjustments

> "Turn the vocals up a bit," "Pan the guitars wider," "That's too much, back off"

**Status:** Partially supported (history and session state are passed to the API).

The hard part is "a bit" and "too much" — Claude needs current values to infer deltas.

**Verdict: Option 4 is fine.** Session state is already injected into the system prompt. Claude can see the current volume is 0.6 and decide "a bit" means 0.75. History handles "too much, back off."

---

### 5. Tempo / transport control

> "Set BPM to 128," "Start playback," "Loop bars 4-8"

**Status:** Not yet supported.

Simple, deterministic commands.

**Verdict: Option 4.** Same pattern as mixer commands — just new entries in the command schema and registry.

---

### 6. Instrument / preset loading

> "Load a synth that sounds like Tame Impala," "Put a Kontakt piano on track 2"

**Status:** Not yet supported.

Requires searching a large preset library, filtering by musical attributes, and selecting the best match.

**Verdict: Option 3 is better.** The workflow is inherently multi-step:

1. Claude calls `search_presets(category: "synth", tags: ["analog", "warm", "detuned"])`
2. Gets back 15 results
3. Picks the best match based on musical knowledge
4. Calls `load_instrument(track: 2, preset_path: "...")`

With Option 4, all retrieval logic must be built in Elixir, hoping the LLM picks right from a pre-filtered list it can't refine. With tool use, Claude drives the search iteratively.

---

### 7. Effects chain management

> "Add reverb and delay to the vocals," "Put a compressor before the EQ on track 3"

**Status:** Not yet supported.

Requires knowing what devices exist on a track and inserting at specific positions.

**Verdict: Option 3 is better.** Claude needs to:

1. Query current device chain on the track
2. Decide where to insert (before/after existing devices)
3. Load the effect
4. Optionally set initial parameters

With Option 4, the JSON schema would need to encode device chain position logic, and the chain would need to be pre-fetched and injected into the prompt. Doable but brittle. Tool use lets Claude inspect and act.

---

### 8. Multi-step mixing workflows

> "Make the mix more spacious," "The low end is muddy, clean it up"

**Status:** Not yet supported.

These are subjective, multi-action requests. "More spacious" might mean: widen pans, add reverb sends, reduce mid-frequency content, increase stereo width on specific tracks.

**Verdict: Option 3 is clearly better.** Claude can:

1. Query session state (all tracks, current panning, effects)
2. Make a plan (widen guitars, add reverb send on vocals, cut 400Hz on bass)
3. Execute multiple tool calls
4. Check results between steps

Option 4 cannot do this without pre-building an entire mixing-decision engine. The whole point is to let the LLM reason about what "spacious" means and take multiple actions.

---

### 9. Session query / analysis

> "Which tracks are the loudest?", "What effects are on the drums?", "Summarize my mix"

**Status:** Not yet supported.

User wants information, not action.

**Verdict: Either works, but differently.** With Option 4, Claude can answer from the session state injected in the system prompt — but only if all that data has already been fetched and included. With Option 3, Claude can query for exactly what it needs. Option 3 scales better as session state grows (dozens of tracks, each with device chains and automation).

---

### 10. Sound design guidance

> "How do I make a reese bass?", "What settings would give me a plucky synth?"

**Status:** Not yet supported.

Conversational. May or may not result in actions.

**Verdict: Option 3 is better.** This might start as a question, then become "OK do it." With tool use, the conversation flows naturally — Claude explains, then acts when asked. With Option 4, every user input must produce a command JSON or an error. A separate "not a command" path would be needed.

---

### 11. Automation

> "Automate the filter cutoff to open up during the chorus"

**Status:** Not yet supported.

Requires knowing song structure (where the chorus is), track device parameters, and writing automation points.

**Verdict: Option 3.** Multi-step: identify chorus position, find filter device, find cutoff parameter, write automation breakpoints. Too many intermediate lookups for a single JSON response.

---

### 12. Arrangement operations

> "Copy the chorus and paste it after the bridge," "Double the length of the intro"

**Status:** Not yet supported.

Requires understanding song structure and clip/scene layout.

**Verdict: Option 3.** Claude needs to query clip positions, understand the arrangement, then make surgical edits. Multi-step with intermediate data dependencies.

---

### 13. Recording workflow

> "Arm track 3, set input to mic, and start recording"

**Status:** Not yet supported.

Sequential operations with a specific order.

**Verdict: Option 4 could work** (return an ordered list of commands), **but Option 3 is safer.** Confirming the track is armed before starting recording is important. Tool use lets Claude verify each step succeeded.

---

## Summary Table

| Use case                      | Option 4 (JSON) | Option 3 (Tool use) |
| ----------------------------- | ---------------- | -------------------- |
| Simple mixer commands         | **Best**         | Overkill             |
| Track creation / scaffolding  | **Best**         | Overkill             |
| Batch mixer operations        | Good             | Good                 |
| Relative adjustments          | Good             | Good                 |
| Tempo / transport             | **Best**         | Overkill             |
| Instrument / preset loading   | Weak             | **Best**             |
| Effects chain management      | Weak             | **Best**             |
| Multi-step mixing workflows   | Can't do it      | **Best**             |
| Session queries               | Limited          | **Best**             |
| Sound design guidance         | Awkward          | **Best**             |
| Automation                    | Can't do it      | **Best**             |
| Arrangement operations        | Can't do it      | **Best**             |
| Recording workflow            | Possible         | **Better**           |

## Conclusion

Option 4 wins for simple, single-action commands. Option 3 wins for anything that requires inspecting state, chaining actions, or reasoning across multiple steps.

These options are not mutually exclusive. Tool use via the API is a superset of structured JSON parsing. Simple commands still work (Claude just calls one tool instead of returning JSON), but complex workflows become possible. The migration path: convert current command types into tool definitions, then let Claude call them. The existing registry already maps commands to OSC — it just needs to be exposed as tools instead of parsed from JSON.
