-- Settings overlay (toolbar's settings button). Every row explains itself on its "?". Saved to config.cfg
-- when the overlay closes, the UI size when it's picked. A click outside, Close or Esc closes it
if MGE.settingsOverlay and not MGE.settingsOverlay.destroyed then return end

local Widgets = MGE.Widgets
local Rows = MGE.EditorRows
local Camera = MGE.Camera

---@class MgeNumberSetting a typed number: applied on Enter, leaving or closing; an invalid one reverts
---@field label string
---@field get fun(): number
---@field set fun(value: number)
---@field min number smallest value accepted (exclusive unless minInclusive)
---@field minInclusive boolean?
---@field max number largest value accepted
---@field whole boolean? rounded down to a whole number

-- snap steps (MGE.Config), shared by the wheel over number fields and the gizmo's Ctrl snap
local Config = MGE.Config
---@param label string
---@param key "wheelStep"|"wheelFineStep"|"rotateStep" field on Config
---@param max number
local function stepField(label, key, max)
    return { label = label, min = 0, max = max, get = function() return Config[key] end, set = function(v) Config[key] = v end }
end

---@type MgeNumberSetting[]
local SNAP_STEPS = {
    stepField("Step", "wheelStep", 1000),
    stepField("Shift step", "wheelFineStep", 1000),
    stepField("Rotate step", "rotateStep", 180),
}
local SNAP_INFO = "Wheel over a number field, or Ctrl while\ndragging the gizmo. Hold Shift for the\n" ..
    "Shift step (rotation: 1 degree)."

local SHORTCUTS = table.concat({
    "F1: show / hide window",
    "Esc: close the open prompt / popup / settings",
    "Ctrl + S: save (name: World > Name)",
    "Ctrl + A: select / deselect all (of the shown list)",
    "Click object, id, joint or player: select it, Shift + click: add / remove",
    "Ctrl + N / D: new / duplicate selected (of the shown list)",
    "Delete: delete selected, of the shown list (asks first)",
    "Shift + Z / Y: undo / redo",
    "Ctrl + Shift + Z / Y: selection back / forward (Objects, Atmo)",
    "Number fields apply when you leave them (or Enter), Esc drops the typing",
    "Wheel over a number field: + / - the step, Shift: the Shift step (one undo step a scroll)",
    "Alt + Q / W / E: Move / Rotate / Scale gizmo on / off",
    "Ctrl while dragging the gizmo: snap to the steps, Ctrl + Shift: the Shift step",
    "Drag (off the gizmo) / wheel: orbit / zoom camera",
    "Shift + drag: box select what shows, Ctrl + Shift + drag: everything inside",
}, "\n")

local px = Widgets.px
local PANEL_W = px(340)
local PAD = px(12)
local TITLE_H = px(44)
local ROW_H = Widgets.ROW_H
local ROW_GAP = px(4)
local SETTING_H = ROW_H + ROW_GAP
local SECTION_H = px(26) -- section heading
local CHOICE_ROWS = 6 -- UI size, Camera follow, Max draws, Detail, Ghosts, Distant
local SHORTCUTS_H = SECTION_H + px(4)
local CLOSE_H = Widgets.ROW_H
local LABEL_W = px(150)
-- headings: Snapping, Dynamic atmo
local panelH = TITLE_H + CHOICE_ROWS * SETTING_H + 2 * SECTION_H + #SNAP_STEPS * SETTING_H + SHORTCUTS_H + CLOSE_H +
    PAD * 2

local overlay = TBMenu:spawnWindowOverlay(true) -- true: a click on the background closes it
MGE.settingsOverlay = overlay

---@type { step: MgeNumberSetting, input: UIElement }[] every number field
local numberInputs = {}

---@param value number
---@return string text like "0.1" (not 0.10000000000000001)
local function formatStep(value)
    return string.format("%g", value)
end

---Applies a typed value, or puts the current one back when it isn't valid
---@param entry { step: MgeNumberSetting, input: UIElement }
local function applySnap(entry)
    local step, input = entry.step, entry.input
    -- not skipped once destroyed: kill destroys fields before the killAction that applies them
    if not input.textfieldstr then return end
    local value = tonumber(input.textfieldstr[1])
    if value and step.whole then value = math.floor(value) end
    local aboveMin = value and (step.minInclusive and value >= step.min or value > step.min)
    if aboveMin and value <= step.max then step.set(value) end
    Rows.setText(input, formatStep(step.get()))
end

local defaultKillAction = overlay.killAction
overlay.killAction = function()
    for _, entry in ipairs(numberInputs) do applySnap(entry) end -- typed but not entered counts too
    if MGE and MGE.Config then MGE.Config.save() end
    if defaultKillAction then defaultKillAction() end
    Widgets.releaseKeyboard(overlay)
    if MGE then MGE.settingsOverlay = nil end
end

local panel = overlay:addChild({
    pos = { (WIN_W - PANEL_W) / 2, (WIN_H - panelH) / 2 },
    size = { PANEL_W, panelH },
    bgColor = Widgets.CONTENT_BG,
    shapeType = ROUNDED,
    rounded = 5,
    interactive = true, -- clicks don't reach the background's close handler
})

local title = panel:addChild({
    pos = { PAD, 0 },
    size = { PANEL_W - PAD * 2, TITLE_H },
})
title:addAdaptedText(true, "Settings", nil, nil, Widgets.FONT, nil, Widgets.TITLE_SCALE)

local HELP_SIZE = ROW_H - px(6)
local HELP_GAP = px(6)

---A row: label with its "?" at the label column's end; returns the space right of it
---@param y number
---@param label string
---@param help string?
---@return UIElement content
local function addRow(y, label, help)
    local row = panel:addChild({
        pos = { PAD, y },
        size = { PANEL_W - PAD * 2, ROW_H },
    })
    local labelElement = row:addChild({
        pos = { 0, 0 },
        size = { LABEL_W - (help and HELP_SIZE + HELP_GAP or 0), ROW_H },
    })
    labelElement:addAdaptedText(label, nil, nil, Widgets.FONT, LEFTMID, Widgets.TEXT_SCALE)
    if help then
        Widgets.helpIcon(row, LABEL_W - HELP_GAP - HELP_SIZE, (ROW_H - HELP_SIZE) / 2, HELP_SIZE, help)
    end
    return row:addChild({
        pos = { LABEL_W, 0 },
        size = { row.size.w - LABEL_W, ROW_H },
        interactive = true,
    })
end

---Centered heading with a "?" right after its text: the heading area is one icon narrower, so text and
---icon center together (a negative x would count from the right edge)
---@param y number
---@param text string
---@param help string
local function addHelpHeading(y, text, help)
    local heading = panel:addChild({
        pos = { PAD, y },
        size = { PANEL_W - PAD * 2 - (HELP_SIZE + HELP_GAP), SECTION_H },
    })
    heading:addAdaptedText(text, nil, nil, Widgets.FONT, CENTERMID, Widgets.TEXT_SCALE)
    local textW = get_string_length(heading.dispstr and heading.dispstr[1] or text, heading.textFont)
        * (heading.textScale or 1)
    Widgets.helpIcon(panel, (PANEL_W + textW - HELP_SIZE - HELP_GAP) / 2 + HELP_GAP, y + (SECTION_H - HELP_SIZE) / 2,
        HELP_SIZE, help)
end

local y = TITLE_H

---A row of choice buttons, the current value lit
---@param label string
---@param help string?
---@param choices { label: string, value: any }[]
---@param get fun(): any
---@param set fun(value: any)
local function addChoiceRow(label, help, choices, get, set)
    local content = addRow(y, label, help)
    local buttons
    local function show()
        local current = get()
        for i, choice in ipairs(choices) do
            local btn = buttons[i]
            if btn and not btn.destroyed then
                btn.bgColor = current == choice.value and Widgets.ACTIVE_COLOR or Widgets.STYLE.bg
            end
        end
    end
    local items = {}
    for i, choice in ipairs(choices) do
        items[i] = { label = choice.label, onClick = function()
            set(choice.value)
            show()
        end }
    end
    buttons = Widgets.buttonRow(content, 0, ROW_H, items, Widgets.GAP)
    show()
    y = y + SETTING_H
end

-- UI size: every size is computed when the window is built, so a new one restarts MGE (the mod and
-- atmo survive a restart, the undo history doesn't)
do
    local choices = {}
    for i, scale in ipairs(Widgets.UI_SCALES) do
        choices[i] = { label = math.floor(scale * 100 + 0.5) .. "%", value = scale }
    end
    addChoiceRow("UI size", nil, choices, function() return Widgets.UI_SCALE end, function(scale)
        if scale == Widgets.UI_SCALE then return end
        MGE_UI_SCALE = scale
        MGE.Config.save() -- before the restart
        local entry = MGE.scriptPath:gsub("mge/$", "") .. "mge.lua"
        MGE.say("UI size " .. math.floor(scale * 100 + 0.5) .. "%, restarting MGE")
        pcall(MGE.quit)
        -- restarted next frame, outside this click (its window is gone)
        add_hook("draw2d", "mge_restart", function()
            remove_hooks("mge_restart")
            dofile(entry)
        end)
    end)
end

local ON_OFF = { { label = "On", value = true }, { label = "Off", value = false } }

addChoiceRow("Camera follow", nil, ON_OFF, function() return Camera.followMoves end,
    function(on) Camera.followMoves = on end)

---A heading and one number field per setting
---@param name string
---@param fields MgeNumberSetting[]
---@param infoText string? the heading's "?"
local function addNumberSection(name, fields, infoText)
    if infoText then
        addHelpHeading(y, name, infoText)
    else
        local heading = panel:addChild({
            pos = { PAD, y },
            size = { PANEL_W - PAD * 2, SECTION_H },
        })
        heading:addAdaptedText(name, nil, nil, Widgets.FONT, CENTERMID, Widgets.TEXT_SCALE)
    end
    y = y + SECTION_H
    for _, step in ipairs(fields) do
        local content = addRow(y, step.label)
        local entry = { step = step }
        entry.input = Rows.createInput(content, function() applySnap(entry) end, formatStep(step.get()),
            { mode = "keep", whole = step.whole })
        Widgets.closeOnEscape(entry.input) -- Esc while typing closes too
        table.insert(numberInputs, entry)
        applySnap(entry) -- fills in the current value
        y = y + SETTING_H
    end
end

do
    local AtmoLayer = MGE.AtmoLayer
    local choices = {}
    for i, n in ipairs(AtmoLayer.DRAW_CHOICES) do choices[i] = { label = tostring(n), value = n } end
    addChoiceRow("Max draws", "Atmo shapes drawn a frame, nearest first.\nLower: steadier fps on big maps.", choices,
        function() return AtmoLayer.maxDraws end, function(n) AtmoLayer.maxDraws = n end)
end

addNumberSection("Snapping", SNAP_STEPS, SNAP_INFO)
addHelpHeading(y, "Dynamic atmo", "Props (atmo objects with Static off)\nin a playable mod.")
y = y + SECTION_H
do
    local LABELS = { simple = "Low", shapes = "Medium", full = "High" }
    local choices = {}
    for i, level in ipairs(MGE.AtmoPlay.Dynamics.LEVELS) do choices[i] = { label = LABELS[level] or level, value = level } end
    addChoiceRow("Detail", "How props fly:\nLow: as spheres, least work.\nMedium: real shapes.\n" ..
        "High: real shapes that hit each other, most work.", choices,
        function() return MGE.Playable.flightLevel end, MGE.Playable.setFlightLevel)
end
-- ghosts run the flights ahead: as much work as playing them
addChoiceRow("Ghosts", "Flying props' ghosts while a turn waits.\nOff saves work with many flying props.", ON_OFF,
    function() return MGE.Playable.ghosts end, MGE.Playable.setGhosts)
addChoiceRow("Distant", "Moving props far from every player:\nMove: keep moving. Pause: wait until\n" ..
    "someone comes near (less work).", { { label = "Move", value = false }, { label = "Pause", value = true } },
    function() return MGE.Playable.pauseFar end, MGE.Playable.setPauseFar)

addHelpHeading(y, "Shortcuts", SHORTCUTS)
y = y + SECTION_H

Widgets.button(panel, { x = PAD, y = panelH - PAD - CLOSE_H, w = PANEL_W - PAD * 2, h = CLOSE_H }, "Close",
    function() overlay:kill() end)
