-- Thrust tab: Frames, Direction, Axes (World / Object / Off)
local Rows = MGE.EditorRows
local ModData = MGE.ModData
local History = MGE.History
local FileHandler = MGE.FileHandler
local getSelected = ModData.getEditSelection -- objects, or atmo objects on the Atmo list
local atmoShown = Rows.atmoShown
local inwuts = Rows.inputs
local sharedChoice = Rows.sharedChoice
local createInputRow = Rows.createInputRow
local createChoiceRow = Rows.createChoiceRow

-- "thrust <frames> <x> <y> <z> <space>" pushes along x y z every <frames> frames. No live setter:
-- applies by reloading. On the Atmo list, props with thrust fly in Atmo Play
---@class Thrust
---@field frames integer
---@field dir number[] x y z
---@field space integer see THRUST_SPACES

-- <space>: 0 world axes (also when left out, as most mods do), 1 the object's
local THRUST_SPACES = {
    { label = "World", value = 0 },
    { label = "Object", value = 1 },
}
-- the parts of a thrust an object doesn't have yet
local THRUST_DEFAULT = { frames = 1, dir = { 0, 0, 0 }, space = 0 }

---@param line string? a thrust line's value
---@return Thrust? nil without one
local function parseThrust(line)
    if not line then return nil end
    local n = {}
    for v in line:gmatch("%S+") do table.insert(n, tonumber(v) or 0) end
    return {
        frames = math.floor(n[1] or THRUST_DEFAULT.frames),
        dir = { n[2] or 0, n[3] or 0, n[4] or 0 },
        space = (n[5] or THRUST_DEFAULT.space) ~= 0 and 1 or 0,
    }
end

---@param obj FileParserEnvObj
---@return Thrust? nil when the object has no thrust
local function getThrust(obj)
    return parseThrust(obj.props.thrust)
end

-- The thrust an object had before Off, so World / Object restores it. By id (reloads make new tables),
-- checked against pos and sides in case the id now belongs to another object. Session only
---@type table<string, { thrust: string, pos: string?, sides: string? }> by "o<id>" / "a<id>" (atmo ids are their own)
local thrustBeforeOff = {}

---@param obj FileParserEnvObj
---@return string
local function offKey(obj)
    return (obj.kind == "atmo" and "a" or "o") .. tostring(obj.id)
end

---@param obj FileParserEnvObj
---@return string? the thrust line obj had before Off, nil for another object on its id
local function rememberedThrust(obj)
    local kept = thrustBeforeOff[offKey(obj)]
    if kept and kept.pos == obj.props.pos and kept.sides == obj.props.sides then return kept.thrust end
    return nil
end

---@param thrust Thrust
---@return string
local function formatThrust(thrust)
    return thrust.frames .. " " .. FileHandler.formatNumbers(thrust.dir[1], thrust.dir[2], thrust.dir[3]) ..
        " " .. thrust.space
end

---Edits every selected object's thrust; commits if any changed
---@param edit fun(thrust: Thrust): Thrust? gets a copy (defaults without one), nil removes it
local function editThrust(edit)
    local changed = false
    for _, v in ipairs(getSelected()) do
        local had = getThrust(v)
        -- an object turned Off starts from its old thrust
        local current = had or parseThrust(rememberedThrust(v)) or THRUST_DEFAULT
        local thrust = edit({ frames = current.frames, dir = { current.dir[1], current.dir[2], current.dir[3] },
            space = current.space })
        local value = thrust and formatThrust(thrust) or nil
        -- compared formatted: "1.00" and "1" are the same
        if value ~= (had and formatThrust(had) or nil) then
            if not value and had then
                thrustBeforeOff[offKey(v)] = { thrust = formatThrust(had), pos = v.props.pos, sides = v.props.sides }
            elseif value then
                thrustBeforeOff[offKey(v)] = nil
            end
            v.props.thrust = value
            changed = true
        end
    end
    if not changed then return end
    History.commit()
    if atmoShown() then Rows.afterAtmoEdit() else MGE.apply() end
end

---Applies a typed thrust field: 1 frames, 2-4 direction x y z
---@param index integer
local function setThrustField(index)
    local input = (inwuts.thrust or {})[index]
    local value = input and tonumber(input.textfieldstr[1])
    if not value then return end
    editThrust(function(thrust)
        if index == 1 then
            thrust.frames = math.max(1, math.floor(value + 0.5)) -- 0 would never fire
        else
            thrust.dir[index - 1] = value
        end
        return thrust
    end)
end

---Thrust panel: Frames, Direction and Axes (or Off); objects without thrust show the defaults
---@param holder UIElement
---@param selected FileParserEnvObj[]
local function buildThrust(holder, selected)
    Rows.begin()
    local function shown(read)
        return sharedChoice(selected, function(obj) return read(getThrust(obj) or THRUST_DEFAULT) end)
    end
    local frames = shown(function(t) return tostring(t.frames) end) or tostring(THRUST_DEFAULT.frames)
    local dir = {}
    for i = 1, 3 do
        dir[i] = shown(function(t) return Rows.formatHint(t.dir[i]) end) or "0.00"
    end
    local framesInputs = createInputRow("Frames", holder, function() setThrustField(1) end, { frames },
        "Pushes every N frames, 1: every frame.", nil, { whole = true })
    local dirInputs = createInputRow("Direction", holder, function(_, i) setThrustField(i + 1) end, dir,
        "Push along the axes below. Turns thrust on if it's off.")
    inwuts.thrust = { framesInputs[1], dirInputs[1], dirInputs[2], dirInputs[3] }

    -- objects without thrust count as Off
    local choices = { { label = "Off", value = "off" } }
    for _, space in ipairs(THRUST_SPACES) do table.insert(choices, space) end
    local current = sharedChoice(selected, function(obj)
        local thrust = getThrust(obj)
        return thrust and thrust.space or "off"
    end)
    createChoiceRow("Axes", holder, choices, current, function(space)
        editThrust(function(thrust)
            if space == "off" then return nil end
            thrust.space = space
            return thrust
        end)
    end, "Off: no thrust. World: world axes.\nObject: turns with the object." ..
        (atmoShown() and "\nAtmo: only props (not Static) fly, in Atmo Play." or ""))
end


---@type EditorPanelModule
return {
    blocks = { { name = "thrust", build = buildThrust, panel = "thrust", row = 0, rows = 3 } },
    inputs = { rebuilt = { "thrust" } },
}
