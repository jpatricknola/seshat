# LLM System Prompt Contract

The intent parser (`Seshat.Commands.Parser`) calls Claude Haiku with a constrained system prompt. This document specifies the contract so that when adding new commands, the system prompt, command struct, registry, and session state all stay in sync.

## Checklist: Adding a New Command

1. **Command struct** (`command.ex`) — Add the atom to `@type t`, add any new fields
2. **System prompt** (`parser.ex` `@system_prompt`) — Add JSON shape and value rules
3. **Parser `@valid_commands`** (`parser.ex`) — Add the string version
4. **Parser `build_command/1`** (`parser.ex`) — Add clause if JSON shape differs from existing ones
5. **Parser `encode_command_for_history/1`** (`parser.ex`) — Add clause if the command has a different field set
6. **Registry `execute/1`** (`registry.ex`) — Add clause mapping command to transport calls
7. **Session.State** (`state.ex`) — If the command introduces new state to track:
   - Add `handle_info` for the corresponding property push
   - Add to `@listened_properties`
   - Add to `do_refresh/1` initial query

## Future Shape Evolution

Some commands will need more than `{command, track, value}`:
- **Send levels**: need `send_id` in addition to `track_id`
- **Device parameters**: need `device_id` and `param_id`
- **Clip operations**: need `track_id` and `scene_id`
- **Song-level commands**: no track at all (tempo, play/stop)

The command struct already supports optional fields — add new ones as needed:
```json
{"command": "send", "track": 0, "send": 1, "value": 0.5}
{"command": "tempo", "value": 120.0}
{"command": "fire_clip", "track": 0, "scene": 2}
```
