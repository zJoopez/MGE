-- Undo/redo for mod edits. Stores copies of ModData.parsed taken after each change (History.commit),
-- the atmo layer (parsed.atmo) included. Live edits (pos/rot/scale/color) are restored directly on
-- world objects, structural changes (duplicate/delete/import/reindex) are restored by saving and
-- reloading the mod. Atmo changes only need the restored copy (MGE draws the atmo from it).

local ModData = MGE.ModData

---@class History
---@field states FileParserResult[]
---@field index integer current state in states
---@field limit integer max stored states
local History = {
    states = {},
    index = 0,
    limit = 20,
}

---@param obj FileParserEnvObj|FileParserEnvObjJoint
local function copyObject(obj)
    local copy = ModData.copy(obj)
    copy.props = ModData.copy(obj.props)
    -- lines, ignores and trailer are never modified after parsing (only replaced), safe to share
    return copy
end

---A stored atmo copy still matches the live object: same id, name, lines table and props. The selection doesn't
---count (restore sets it from what's selected now)
---@param stored FileParserEnvObj
---@param obj FileParserEnvObj
---@return boolean
local function sameAtmo(stored, obj)
    if stored.id ~= obj.id or stored.atmoName ~= obj.atmoName or stored.lines ~= obj.lines then return false end
    local a, b = stored.props, obj.props
    for key, value in pairs(b) do
        if a[key] ~= value then return false end
    end
    for key in pairs(a) do
        if b[key] == nil then return false end
    end
    return true
end

---@param parsed FileParserResult
---@param previous FileParserResult? the stored step before (commit): its atmo copies that still match are shared,
---not copied again. Stored steps are never changed (restore copies them out), so sharing is safe; with thousands
---of atmo objects every step copied all of them, also for an edit of one object
---@return FileParserResult
local function copyParsed(parsed, previous)
    local copy = { ignores = parsed.ignores, trailer = parsed.trailer, env_obj = {}, env_obj_joint = {}, atmo = {},
        sharedPlayers = parsed.sharedPlayers, -- the file's way of writing player models (FileHandler.splitSharedPlayers)
        playable = parsed.playable } -- a playable atmo mod's params (utils/playable.lua), never changed in place
    for i, obj in ipairs(parsed.env_obj or {}) do copy.env_obj[i] = copyObject(obj) end
    for i, obj in ipairs(parsed.env_obj_joint or {}) do copy.env_obj_joint[i] = copyObject(obj) end
    local before = previous and previous.atmo or {}
    for i, obj in ipairs(parsed.atmo or {}) do
        local stored = before[i]
        copy.atmo[i] = (stored and sameAtmo(stored, obj)) and stored or copyObject(obj)
    end
    return copy
end

-- object props applyLive can set on world objects, any other prop difference needs a save.
-- flag is live except for the static bit (see sameObjects)
local LIVE_KEYS = {
    pos = true, rot = true, sides = true, color = true, mass = true, bounce = true, flag = true, visible = true,
}

---@param props table<string, string>
---@return boolean
local function isStaticFlag(props)
    return bit.band(tonumber(props.flag) or 0, MGE.FLAGS.STATIC) ~= 0
end

---Same keys, and same values except for keys in `live` (those can be set on world objects).
---A live key that exists on one side only still counts as a difference: applyLive can only set
---values, it can't take a prop away (e.g. bounce added to an object that had none would stay on
---the world object after undo, leaving the world out of sync with the mod file)
---@param a table<string, string>
---@param b table<string, string>
---@param live table<string, boolean>?
local function sameProps(a, b, live)
    for key, value in pairs(a) do
        if b[key] == nil then return false end
        if not (live and live[key]) and b[key] ~= value then return false end
    end
    for key in pairs(b) do
        if a[key] == nil then return false end
    end
    return true
end

---Line lists (the mod's lines before its objects, its trailer) the same: the same table, or the same lines. Every
---reload parses new tables, so by table alone an undo after any reload rewrote and reloaded the mod
---@param a string[]?
---@param b string[]?
---@return boolean
local function sameLines(a, b)
    if a == b then return true end
    if not a or not b or #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

---True when only live-applicable changes differ, so undo can skip saving
---@param a FileParserResult
---@param b FileParserResult
---@return boolean
local function sameObjects(a, b)
    if #a.env_obj ~= #b.env_obj or #a.env_obj_joint ~= #b.env_obj_joint then return false end
    -- player model replaced (FileHandler.setPlayerLines swaps these tables), needs a reload
    if not sameLines(a.ignores, b.ignores) or not sameLines(a.trailer, b.trailer) then return false end
    for i, obj in ipairs(a.env_obj) do
        local other = b.env_obj[i]
        if obj.id ~= other.id or not sameProps(obj.props, other.props, LIVE_KEYS) then return false end
        -- tested in game: set_obj_flag doesn't switch static/dynamic, only a reload does
        if isStaticFlag(obj.props) ~= isStaticFlag(other.props) then return false end
    end
    -- joints can't be changed live, any difference in them needs a save
    for i, obj in ipairs(a.env_obj_joint) do
        local other = b.env_obj_joint[i]
        if obj.id ~= other.id or obj.obj1 ~= other.obj1 or obj.obj2 ~= other.obj2 or
            not sameProps(obj.props, other.props) then return false end
    end
    -- atmo objects (a.atmo) don't count: they aren't in the .tbm or the world, the restored copy is all
    -- there is to them (MGE draws them from it, Save writes their .atmo). An atmo-only undo needs no reload
    return true
end
History.sameObjects = sameObjects -- tests

---@param value string?
---@return number[]
local function parseNumbers(value)
    local numbers = {}
    for n in tostring(value or ""):gmatch("%S+") do table.insert(numbers, tonumber(n) or 0) end
    return numbers
end

---Applies pos/rot/sides/color/mass/bounce/flag/visible from props to the world objects, used when only
---live edits differ
---@param parsed FileParserResult
local function applyLive(parsed)
    for _, obj in ipairs(parsed.env_obj) do
        local id = obj.id - 1
        if get_obj_pos(id) ~= nil then
            local p = obj.props
            if p.pos then
                local v = parseNumbers(p.pos)
                set_obj_pos(id, v[1] or 0, v[2] or 0, v[3] or 0)
            end
            if p.rot then
                local v = parseNumbers(p.rot)
                set_obj_rot(id, math.rad(v[1] or 0), math.rad(v[2] or 0), math.rad(v[3] or 0))
            end
            if p.sides then
                local cur = { get_obj_sides(id) }
                local v = parseNumbers(p.sides)
                local s = {}
                for i = 1, 3 do
                    -- zero sides crash physics (old saves wrote 0.0001 as 0.00)
                    s[i] = math.max(math.abs(v[i] or cur[i] or 1), MGE.MIN_SIDE)
                end
                set_obj_sides(id, s[1], s[2], s[3])
            end
            if p.color then
                local v = parseNumbers(p.color)
                -- see-through while the Atmo list shows (AtmoLayer keeps this color to put back)
                local setColor = MGE.AtmoLayer and MGE.AtmoLayer.setObjectColor or set_obj_color
                setColor(id, v[1] or 1, v[2] or 1, v[3] or 1, v[4] or 1)
            end
            if p.mass then
                set_obj_mass(id, math.max(tonumber(p.mass) or 1, 0.0001)) -- zero mass breaks physics
            end
            if p.bounce then
                set_obj_bounce(id, math.max(tonumber(p.bounce) or 0, 0))
            end
            if p.flag then
                set_obj_flag(id, tonumber(p.flag) or 0)
            end
            if p.visible then
                set_obj_vis(id, tonumber(p.visible) or 1)
            end
        end
    end
end

-- Merged steps: while History.mergeKey is set, a commit with the same key as the last one replaces that state
-- instead of adding one. The mouse wheel over a number field (ui/editor_rows.lua) applies every step, the
-- whole scroll is one undo step: it ends when the mouse leaves the field (History.endMerge), any other
-- commit, an undo or redo
---@type string? set by the caller around a commit that may merge
History.mergeKey = nil
---@type string? key of the last commit, nil when it can't be merged into
History.lastMerge = nil

---Ends a run of merged steps: the next commit with this key adds a state again
---@param key string
function History.endMerge(key)
    if History.lastMerge == key then History.lastMerge = nil end
end

---Starts a new history from the current mod data, call after loading a mod
function History.reset()
    History.states = { copyParsed(ModData.parsed) }
    History.index = 1
    History.lastMerge = nil
end

---Stores the current mod data as a new state, call after each change
function History.commit()
    -- rules changed in the game's menu go into this step: synced later (MGE.apply) they were in no undo state, and
    -- an undo then redo wrote them away (MGE.syncGamerules makes them the baseline, so this is once per change)
    if MGE.syncGamerules then MGE.syncGamerules() end
    local key = History.mergeKey
    if key and key == History.lastMerge and History.index == #History.states and History.index > 1 then
        History.states[History.index] = copyParsed(ModData.parsed, History.states[History.index]) -- the same step, its newest value
        return
    end
    History.lastMerge = key
    for i = #History.states, History.index + 1, -1 do
        table.remove(History.states, i) -- new change drops redo states
    end
    table.insert(History.states, copyParsed(ModData.parsed, History.states[History.index]))
    if #History.states > History.limit then
        table.remove(History.states, 1)
    end
    History.index = #History.states
end

---@param index integer
local function restore(index)
    local state = History.states[index]
    if not state then return end
    History.index = index
    History.lastMerge = nil -- the next change is a new step
    local current = ModData.parsed
    ModData.parsed = copyParsed(state) -- copy so later edits don't change the stored state

    -- selection isn't part of history, keep what is selected now
    local selected = {}
    for _, obj in ipairs(current.env_obj) do selected[obj.id] = obj.selected end
    for _, obj in ipairs(ModData.parsed.env_obj) do obj.selected = selected[obj.id] end
    local atmoSelected = {}
    for i, obj in ipairs(current.atmo or {}) do atmoSelected[i] = obj.selected end
    for i, obj in ipairs(ModData.parsed.atmo) do obj.selected = atmoSelected[i] end

    -- undoing Convert (utils/playable.lua): the World tab's Atmo row shows the other button lit
    if current.playable ~= ModData.parsed.playable and MGE.EditorRows then
        MGE.EditorRows.refreshBlocks({ "playable" })
    end
    if sameObjects(current, ModData.parsed) then
        applyLive(ModData.parsed)
        -- a playable mod whose pools no longer fit the restored atmo reloads (Playable.reloadIfSplitChanged),
        -- else: refreshes the list and the editor's current values, typed inputs stay for the next edit
        local Main = MGE.Main -- created after this module loads
        local reloaded = MGE.Playable ~= nil and MGE.Playable.reloadIfSplitChanged()
        if Main and not reloaded then Main.updateWindow() end
    else
        MGE.apply() -- object list changed, rewrite file and reload
    end
end

function History.canUndo() return History.index > 1 end
function History.canRedo() return History.index < #History.states end

function History.undo()
    if not History.canUndo() then
        MGE.say("nothing to undo")
        return
    end
    restore(History.index - 1)
end

function History.redo()
    if not History.canRedo() then
        MGE.say("nothing to redo")
        return
    end
    restore(History.index + 1)
end

MGE.History = History
