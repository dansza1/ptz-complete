-- ptz_complete: positional Tab completion for PTZ chat commands.
--
-- Also refreshes cameras.json from the bot's replies to !ptzlist.
--
-- Assumes ASCII command text and that camera/preset names contain no whitespace.

local json = require("chatterino.json")

-- Maps each command (lowercase) to its positional argument types, in order.
--   "camera" completes from camera names.
--   "preset" completes from the presets of the camera in the previous token.
-- Adding a command is one line, e.g. ["!ptzhome"] = { "camera" }.
local COMMANDS = {
    ["!ptzload"] = { "camera", "preset" },
    ["!ptzzoom"] = { "camera", "preset" },
    ["!ptzfocus"] = { "camera", "preset" },
    ["!ptzfocusa"] = { "camera", "preset" },
    ["!swap"] = { "camera", "camera" },
}

-- Same format as the other PTZ app: { "cameras": [ { "name": "Pasture", "presets": [...] } ] }
local CAMERAS_FILE = "cameras.json"
-- Optional. Maps a camera to its aliases, as a comma-separated string or an array:
-- { "parrot": "birdy, feathers" }
local ALIASES_FILE = "aliases.json"

-- Chat listening. The bot answers `!ptzlist <camera>` with
-- `PTZ Presets: a,b,c`. The reply doesn't name the camera, so each reply is paired
-- with the oldest unanswered request, and only if that request is recent.
local LIST_CHANNEL = "alveusgg"
local LIST_BOT = "alveussanctuary"
local PAIR_WINDOW_MS = 30000
-- How long to wait for the rest of a long reply.
local CONTINUATION_WINDOW_MS = 10000

-- Loaded from cameras.json. cameras[lowerName] = { name = "Pasture", presets = {...}, raw = {...} }
-- `raw` is the entry as read from the file, so fields we don't use are kept on save.
local cameras = {}
-- Sorted (case-insensitive) camera keys, and camera names plus aliases for completion.
local cameraNames = {}
local cameraChoices = {}
-- aliases[lowerAlias] = lowerCamera
local aliases = {}
local commandNames = {}

-- Requests waiting for a reply, oldest first: { camera = "servalc", time = ms }
local pendingRequests = {}
-- A reply whose list is still arriving over several bot messages.
local awaitingPart = nil

for name in pairs(COMMANDS) do
    commandNames[#commandNames + 1] = name
end

local function caseInsensitiveLess(a, b)
    local la, lb = a:lower(), b:lower()
    if la ~= lb then
        return la < lb
    end
    return a < b
end

table.sort(commandNames, caseInsensitiveLess)

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Returns the entries of `list` that start with `partial`, ignoring case.
-- `list` must already be sorted, so the result is too.
local function filterPrefix(list, partial)
    local prefix = partial:lower()
    local out = {}
    for _, value in ipairs(list) do
        if value:lower():sub(1, #prefix) == prefix then
            out[#out + 1] = value
        end
    end
    return out
end

local function rebuildCameraNames()
    cameraNames = {}
    for key in pairs(cameras) do
        cameraNames[#cameraNames + 1] = key
    end
    table.sort(cameraNames, caseInsensitiveLess)

    cameraChoices = {}
    for _, name in ipairs(cameraNames) do
        cameraChoices[#cameraChoices + 1] = name
    end
    for alias in pairs(aliases) do
        cameraChoices[#cameraChoices + 1] = alias
    end
    table.sort(cameraChoices, caseInsensitiveLess)
end

-- Turns a typed camera name (or alias) into the camera key used for lookups.
local function resolveCamera(name)
    local lowered = name:lower()
    return aliases[lowered] or lowered
end

-- Reads and parses cameras.json. Returns the decoded object, or nil and a message.
local function readCamerasFile()
    local readOk, content = pcall(function()
        local file, err = io.open(CAMERAS_FILE, "r")
        if not file then
            error(err, 0)
        end
        local text = file:read("a")
        file:close()
        return text
    end)
    if not readOk then
        return nil, tostring(content)
    end

    local parseOk, data = pcall(json.parse, content)
    if not parseOk then
        return nil, "invalid JSON: " .. tostring(data)
    end
    if type(data) ~= "table" or type(data.cameras) ~= "table" then
        return nil, 'top level must be an object with a "cameras" array'
    end
    return data
end

-- Builds the lookup table from the decoded file. Returns the cameras, or nil and a
-- message on the first malformed entry so a bad file never half-loads.
local function buildCameras(data)
    local built = {}
    for _, entry in ipairs(data.cameras) do
        if type(entry) ~= "table" or type(entry.name) ~= "string" or type(entry.presets) ~= "table" then
            return nil, 'each camera needs a "name" string and a "presets" array'
        end

        local key = entry.name:lower()
        local camera = built[key]
        if camera == nil then
            camera = { name = entry.name, presets = {}, seen = {}, raw = entry }
            built[key] = camera
        end

        for _, preset in ipairs(entry.presets) do
            if type(preset) ~= "string" then
                return nil, 'preset for camera "' .. entry.name .. '" is not a string'
            end
            if not camera.seen[preset] then
                camera.seen[preset] = true
                camera.presets[#camera.presets + 1] = preset
            end
        end
    end

    for _, camera in pairs(built) do
        table.sort(camera.presets, caseInsensitiveLess)
        camera.seen = nil
    end
    return built
end

-- Reads aliases.json. A missing file just means no aliases. Returns a table of
-- alias -> camera, and a message if the file exists but is invalid (the table is
-- then empty).
local function loadAliases()
    local file = io.open(ALIASES_FILE, "r")
    if not file then
        return {}
    end
    local text = file:read("a")
    file:close()

    local ok, data = pcall(json.parse, text)
    if not ok or type(data) ~= "table" then
        return {}, "could not parse " .. ALIASES_FILE .. (ok and "" or ": " .. tostring(data))
    end

    local result = {}
    for camera, value in pairs(data) do
        if type(camera) ~= "string" then
            return {}, ALIASES_FILE .. " keys must be camera names"
        end

        local list = value
        if type(value) == "string" then
            list = {}
            for part in value:gmatch("[^,]+") do
                list[#list + 1] = part
            end
        end
        if type(list) ~= "table" then
            return {}, ALIASES_FILE .. ": aliases for " .. camera .. " must be a string or an array"
        end

        for _, alias in ipairs(list) do
            if type(alias) == "string" and trim(alias) ~= "" then
                result[trim(alias):lower()] = camera:lower()
            end
        end
    end
    return result
end

-- Reloads cameras.json and aliases.json. On failure the previously loaded data is kept.
-- Returns true and the camera count, or false and an error message.
local function reload()
    local data, readErr = readCamerasFile()
    if not data then
        c2.log(c2.LogLevel.Warning, "ptz_complete: could not load " .. CAMERAS_FILE .. ": " .. readErr)
        return false, readErr
    end

    local built, buildErr = buildCameras(data)
    if not built then
        c2.log(c2.LogLevel.Warning, "ptz_complete: could not load " .. CAMERAS_FILE .. ": " .. buildErr)
        return false, buildErr
    end

    cameras = built
    local loadedAliases, aliasErr = loadAliases()
    aliases = loadedAliases
    if aliasErr then
        c2.log(c2.LogLevel.Warning, "ptz_complete: " .. aliasErr)
    end
    rebuildCameraNames()
    return true, #cameraNames
end

-- Saves one camera's presets to cameras.json. The file is read again first, so
-- edits made by the other app since startup are kept. Only this camera changes.
-- Returns true, or false and a message.
local function saveCamera(name, presets)
    local data, readErr = readCamerasFile()
    if not data then
        return false, readErr
    end

    local key = name:lower()
    local entry
    for _, existing in ipairs(data.cameras) do
        if type(existing) == "table" and type(existing.name) == "string" and existing.name:lower() == key then
            entry = existing
            break
        end
    end
    if entry == nil then
        entry = { name = name }
        data.cameras[#data.cameras + 1] = entry
    end
    entry.presets = presets

    local ok, err = pcall(function()
        local text = json.stringify(data, { pretty = true })
        local file, openErr = io.open(CAMERAS_FILE, "w")
        if not file then
            error(openErr, 0)
        end
        file:write(text, "\n")
        file:close()
    end)
    if not ok then
        return false, tostring(err)
    end
    return true
end

-- Result for "not ours": hide nothing, add nothing, so emotes and users complete as usual.
local function passThrough()
    return { hide_others = false, values = {} }
end

-- Result for "ours but nothing matches": hide everything else so emotes never appear.
local function noMatches()
    return { hide_others = true, values = {} }
end

local function onCompletionRequested(event)
    -- cursor_position is a UTF-16 index; for ASCII text it equals the byte offset.
    local before = event.full_text_content:sub(1, event.cursor_position)
    local partial = before:match("(%S*)$")

    if event.is_first_word then
        local values = filterPrefix(commandNames, partial)
        if #values == 0 then
            return passThrough()
        end
        return { hide_others = true, values = values }
    end

    -- Completed words before the one being typed, command name first.
    local words = {}
    for word in before:gmatch("%S+") do
        words[#words + 1] = word
    end
    if partial ~= "" then
        words[#words] = nil
    end

    local args = COMMANDS[(words[1] or ""):lower()]
    if args == nil then
        return passThrough()
    end

    -- words[1] is the command, so the word being typed is argument #words.
    local argType = args[#words]
    if argType == "camera" then
        return { hide_others = true, values = filterPrefix(cameraChoices, partial) }
    elseif argType == "preset" then
        -- The previous token is the camera (or alias) this preset belongs to.
        local camera = cameras[resolveCamera(words[#words])]
        if camera == nil then
            return noMatches()
        end
        return { hide_others = true, values = filterPrefix(camera.presets, partial) }
    end

    -- Past the last positional argument, or an unknown type: nothing to suggest.
    return noMatches()
end

-- Chat messages that were already in the channel when Chatterino started
-- (recent-messages history) must not change cameras.json. Compared as ISO strings,
-- which sort by time.
local startedAt = c2.DateTime.current_utc():to_iso_string()

-- Saves one complete reply for `request`.
local function applyReply(request, list)
    local presets = {}
    for name in list:gmatch("[^,]+") do
        local preset = trim(name)
        if preset ~= "" then
            presets[#presets + 1] = preset
        end
    end
    if #presets == 0 then
        return
    end

    local saved, err = saveCamera(request.camera, presets)
    if not saved then
        c2.log(c2.LogLevel.Warning, "ptz_complete: not saving !ptzlist update for " .. request.camera .. ": " .. err)
        return
    end

    -- Reload from the file, so memory matches what was written.
    reload()
    c2.log(c2.LogLevel.Info, "ptz_complete: updated " .. request.camera .. " from !ptzlist (" .. #presets .. " presets)")
end

local function onChatMessage(msg)
    local time = msg.server_received_time
    if time == nil or c2.DateTime.from_unix_milliseconds(time):to_iso_string() < startedAt then
        return
    end

    local login = (msg.login_name or ""):lower()
    local text = msg.message_text or ""
    local lowered = text:lower()

    local requested = lowered:match("^!ptzlist%s+(%S+)")
    if requested then
        pendingRequests[#pendingRequests + 1] = { camera = resolveCamera(requested), time = time }
        return
    end

    if login ~= LIST_BOT then
        return
    end

    local isNewReply = lowered:match("^ptz presets:") ~= nil

    if awaitingPart then
        if not isNewReply and time - awaitingPart.time <= CONTINUATION_WINDOW_MS then
            awaitingPart.list = awaitingPart.list .. trim(lowered)
            awaitingPart.time = time
            if awaitingPart.list:sub(-1) == "," then
                return
            end
            applyReply(awaitingPart.request, awaitingPart.list)
            awaitingPart = nil
            return
        end
        -- The earlier reply never finished, so its list can't be trusted.
        c2.log(c2.LogLevel.Warning, "ptz_complete: dropped an incomplete !ptzlist reply for " .. awaitingPart.request.camera)
        awaitingPart = nil
    end

    if not isNewReply then
        return
    end
    local list = lowered:match("^ptz presets:%s*(.-)%s*$")

    -- Drop requests too old to be answered by this reply, then pair with the oldest.
    while pendingRequests[1] and time - pendingRequests[1].time > PAIR_WINDOW_MS do
        table.remove(pendingRequests, 1)
    end
    local request = table.remove(pendingRequests, 1)
    if request == nil then
        return
    end

    if list:sub(-1) == "," then
        awaitingPart = { request = request, list = list, time = time }
        return
    end
    applyReply(request, list)
end

local function subscribeToChannel()
    local channel = c2.Channel.by_name(LIST_CHANNEL)
    if channel == nil or not channel:is_valid() then
        c2.log(c2.LogLevel.Warning, "ptz_complete: channel " .. LIST_CHANNEL .. " is not open, presets won't update from chat")
        return
    end
    channel:on_message_appended(onChatMessage)
end

reload()

c2.register_callback(c2.EventType.CompletionRequested, onCompletionRequested)
subscribeToChannel()

c2.register_command("/ptzreload", function(ctx)
    local ok, result = reload()
    local message
    if ok then
        message = ("ptz_complete: loaded %d camera(s) from %s"):format(result, CAMERAS_FILE)
    else
        message = "ptz_complete: failed to reload " .. CAMERAS_FILE .. ", keeping previous data: " .. result
    end
    ctx.channel:add_system_message(message)
end)
