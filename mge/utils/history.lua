-- Undo/redo: copies of ModData.parsed (atmo included) taken after each change (History.commit).
-- Live-settable differences are applied to world objects; structural ones reload the mod.
-- Atmo changes only need the restored copy (MGE draws the atmo from it).

local ModData = MGE.ModData

---@class History
---@field states FileParserResult[]
---@field index integer current state in states
---@field limit integer max stored states
local History = {
    states = {},
    index = 0,
    limit = 50,
}

---@param obj FileParserEnvObj|FileParserEnvObjJoint
local function copyObject(obj)
    local copy = ModData.copy(obj)
    copy.props = ModData.copy(obj.props)
    -- lines, ignores and trailer are only ever replaced, never modified: safe to share
    return copy
end

---A stored atmo copy still matches the live object (selection doesn't count)
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
---@param previous FileParserResult? the step before: its still-matching atmo copies are shared, not
---copied again (stored steps are never changed). Copying thousands of atmo objects per edit was slow
---@return FileParserResult
local function copyParsed(parsed, previous)
    local copy = { ignores = parsed.ignores, trailer = parsed.trailer, env_obj = {}, env_obj_joint = {}, atmo = {},
        sharedPlayers = parsed.sharedPlayers,
        playable = parsed.playable } -- never changed in place
    for i, obj in ipairs(parsed.env_obj or {}) do copy.env_obj[i] = copyObject(obj) end
    for i, obj in ipairs(parsed.env_obj_joint or {}) do copy.env_obj_joint[i] = copyObject(obj) end
    local before = previous and previous.atmo or {}
    for i, obj in ipairs(parsed.atmo or {}) do
        local stored = before[i]
        copy.atmo[i] = (stored and sameAtmo(stored, obj)) and stored or copyObject(obj)
    end
    return copy
end

-- props applyLive can set on world objects; other differences need a reload.
-- flag is live except for the static bit
local LIVE_KEYS = {
    pos = true, rot = true, sides = true, color = true, mass = true, bounce = true, flag = true, visible = true,
}

---@param props table<string, string>
---@return boolean
local function isStaticFlag(props)
    return bit.band(tonumber(props.flag) or 0, MGE.FLAGS.STATIC) ~= 0
end

---Same keys, and same values except for `live` keys. A key on one side only is still a difference:
---applyLive can set values but not remove a prop
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

---Same table or same lines (every reload parses new tables)
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

---True when only live-applicable changes differ, so undo can skip the reload
---@param a FileParserResult
---@param b FileParserResult
---@return boolean
local function sameObjects(a, b)
    if #a.env_obj ~= #b.env_obj or #a.env_obj_joint ~= #b.env_obj_joint then return false end
    -- player model replaced (setPlayerLines swaps these tables)
    if not sameLines(a.ignores, b.ignores) or not sameLines(a.trailer, b.trailer) then return false end
    for i, obj in ipairs(a.env_obj) do
        local other = b.env_obj[i]
        if obj.id ~= other.id or not sameProps(obj.props, other.props, LIVE_KEYS) then return false end
        -- set_obj_flag can't switch static/dynamic, only a reload does
        if isStaticFlag(obj.props) ~= isStaticFlag(other.props) then return false end
    end
    -- joints can't change live
    for i, obj in ipairs(a.env_obj_joint) do
        local other = b.env_obj_joint[i]
        if obj.id ~= other.id or obj.obj1 ~= other.obj1 or obj.obj2 ~= other.obj2 or
            not sameProps(obj.props, other.props) then return false end
    end
    -- atmo doesn't count: it's not in the world, the restored copy is all there is
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

---Applies the LIVE_KEYS props to the world objects
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
                    -- zero sides crash physics
                    s[i] = math.max(math.abs(v[i] or cur[i] or 1), MGE.MIN_SIDE)
                end
                set_obj_sides(id, s[1], s[2], s[3])
            end
            if p.color then
                local v = parseNumbers(p.color)
                -- keeps see-through while the Atmo list shows
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

-- Merged steps: while mergeKey is set, a commit with the last commit's key replaces that state. A mouse
-- wheel scroll over a number field is one undo step; endMerge, other commits, undo or redo end it
---@type string? set by the caller around a commit that may merge
History.mergeKey = nil
---@type string? key of the last commit, nil when it can't be merged into
History.lastMerge = nil

---@param key string
function History.endMerge(key)
    if History.lastMerge == key then History.lastMerge = nil end
end

---New history from the current data (after loading a mod)
function History.reset()
    History.states = { copyParsed(ModData.parsed) }
    History.index = 1
    History.lastMerge = nil
end

---Stores the current data as a new state, after each change
function History.commit()
    -- menu-changed gamerules join this step, or undo/redo would drop them
    if MGE.syncGamerules then MGE.syncGamerules() end
    local key = History.mergeKey
    if key and key == History.lastMerge and History.index == #History.states and History.index > 1 then
        History.states[History.index] = copyParsed(ModData.parsed, History.states[History.index])
        return
    end
    History.lastMerge = key
    for i = #History.states, History.index + 1, -1 do
        table.remove(History.states, i) -- drop redo states
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
    History.lastMerge = nil
    local current = ModData.parsed
    ModData.parsed = copyParsed(state) -- later edits mustn't change the stored state

    -- selection isn't history: keep the current one
    local selected = {}
    for _, obj in ipairs(current.env_obj) do selected[obj.id] = obj.selected end
    for _, obj in ipairs(ModData.parsed.env_obj) do obj.selected = selected[obj.id] end
    local atmoSelected = {}
    for i, obj in ipairs(current.atmo or {}) do atmoSelected[i] = obj.selected end
    for i, obj in ipairs(ModData.parsed.atmo) do obj.selected = atmoSelected[i] end

    if current.playable ~= ModData.parsed.playable and MGE.EditorRows then
        MGE.EditorRows.refreshBlocks({ "playable" })
    end
    if sameObjects(current, ModData.parsed) then
        applyLive(ModData.parsed)
        -- a playable mod whose pools no longer fit reloads; else refresh the window
        local Main = MGE.Main -- created after this module loads
        local reloaded = MGE.Playable ~= nil and MGE.Playable.reloadIfSplitChanged()
        if Main and not reloaded then Main.updateWindow() end
    else
        MGE.apply()
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
