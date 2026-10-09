# ptz_complete

A Chatterino plugin that makes Tab completion aware of PTZ chat commands:

| You type | Tab completes |
| --- | --- |
| `!pt<Tab>` | command names, e.g. `!ptzload` |
| `!ptzload pa<Tab>` | camera names only, e.g. `pasture` |
| `!ptzload pasture ba<Tab>` | presets of `pasture` only, e.g. `Back`, `Barn` |

Outside these commands, emote and username completion is unchanged.

## Install

1. Copy the `ptz_complete` folder into your Chatterino plugins directory.
2. Make sure the folder contains `init.lua`, `info.json`, and `data/presets.json`.
3. In Chatterino, open **Settings → Plugins**, enable the plugin system if it isn't on, then
   enable `ptz_complete`. 
   read, so look for the plugin settings page.
4. Restart Chatterino so the plugin loads.

Plugins only work in Chatterino builds compiled with plugin support (`CHATTERINO_PLUGINS`).

## Data file: `data/presets.json`

A JSON object mapping each camera name to a list of its presets:

```json
{
  "Pasture": ["Barn", "Back", "Pond", "Gate"],
  "Parrot": ["Perch", "Feeder"]
}
```

- Camera names are matched case-insensitively and shown in lowercase (`pasture`).
- Preset names keep their case.
- Names must not contain spaces, because commands are split on whitespace.
- The file is read on startup and on `/ptzreload`. A missing or invalid file logs a warning
  and does not crash Chatterino. Camera completion then returns nothing for PTZ commands.

## `/ptzreload`

Reloads `data/presets.json` and posts a system message:

- `ptz_complete: loaded 3 camera(s) from presets.json` on success.
- `ptz_complete: failed to reload presets.json, keeping previous data: <reason>` on failure.
  A bad edit doesn't wipe the data that was already loaded.

## Adding a command

Add a line to the `COMMANDS` table at the top of `init.lua`. Each entry lists the argument types
in order:

```lua
local COMMANDS = {
    ["!ptzload"] = { "camera", "preset" },
    ["!ptzhome"] = { "camera" },
    ["!ptzcopy"] = { "camera", "camera" },
}
```

- `"camera"` completes from camera names.
- `"preset"` completes from the presets of the camera in the previous word.
- Words past the last listed argument complete nothing, and other completions stay hidden.

Command names must be lowercase. After editing `presets.json`, run `/ptzreload`. After editing
`init.lua`, restart Chatterino so the new `COMMANDS` table is loaded.

## Known limitations

- **2-character minimum.** Chatterino doesn't start completion for a word of 1 character, so the
  plugin isn't called for `!ptzload p`. This is a Chatterino rule, not something the plugin can
  change.
- **Tab only.** Plugin results feed Tab cycling. The `:` emote popup doesn't show them, so no
  suggestion list appears while typing.
- **ASCII assumption.** `cursor_position` counts UTF-16 units, but the plugin slices bytes. This is
  correct only when the command text before the cursor is ASCII.
- **Whitespace-free names.** Camera and preset names can't contain spaces.
- **Reply prefix.** In a reply, the `@user` prefix is the first word, so `@user !ptzload pa<Tab>`
  doesn't complete. Plain `!ptzload pa<Tab>` works.
- **Only the first Tab is checked.** Chatterino calls completion once per Tab sequence and cycles
  through the results after that, so changing the text mid-cycle won't refresh them.
