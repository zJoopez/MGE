require("toriui.uielement")

---@class Main
---@field window UIElement
---@field page integer
---@field pageSize integer
---@field activeTabs table<string, string> each list's active editor tab (panel id), by list
---@field listTab "objects"|"atmo"|"joints"|"players"|"misc" the shown list (misc: World)
---@field selectedPlayer integer last picked player, shown by the panel even when none is selected
---@field selectedPlayers table<integer, boolean>
---@field selectPlayer fun(id: integer, additive: boolean?)
---@field selectedJoints table<integer, boolean> selected joint slots (empty ones too), never empty
---@field jointSlot integer current slot (last clicked, always selected): the Link tab edits it
local Main = { page = 1, pageSize = 66, listTab = "objects", selectedPlayer = 0,
    selectedPlayers = { [0] = true }, selectedJoints = { [1] = true }, jointSlot = 1,
    activeTabs = { objects = "core", atmo = "core", players = "player", joints = "jointLink", misc = "misc" } }
MGE.Main = Main -- before the UI modules load, so they can alias it

local ModData = MGE.ModData
local History = MGE.History
local Widgets = dofile(MGE.scriptPath .. "ui/widgets.lua")

local defaultPos = { 0, 0 }
local PAD = 0 -- the sections reach the panel's edges
local SECTION_GAP = 6 -- space between window sections
---Moves the next section's position under one that is height tall
---@param height number?
---@param gap number? space before the next section, defaults to SECTION_GAP
local function updateContentHeight(height, gap)
    defaultPos[2] = defaultPos[2] + (height or 0) + (gap or SECTION_GAP)
end

-- Layout: a bar across the screen's top (list tabs, Mods, Rules; tools and close on the right), a panel
-- on the left (list, its action buttons, editor tabs and panel) and a footer row (counters, messages,
-- the mod name). Sizes are layout units scaled by Widgets.px
local px = Widgets.px
local PANEL_W = px(300)
local BAR_H = px(30) -- the top bar
local BAR_ICON = BAR_H - px(6)
local BAR_GAP = Widgets.GAP
local BAR_SEP = px(14) -- between button groups
local EDITOR_TABS_H = px(20)
local TAB_PADDING = px(6) -- a tab panel's edge to its content
local EDITOR_H = Widgets.PANEL_ROWS * Widgets.ROW_H
local FOOTER_H = Widgets.INFO_HEIGHT + px(4)
local LIST_ROWS = 6 -- fewer when the panel wouldn't fit the screen (below)
local rowH = Widgets.LIST_ROW_H
local screenW = WIN_W or 1280 -- Main.fitScreen keeps the bar fitted
local listH = LIST_ROWS * rowH
-- the list's action bar, lined up with the grid's cells
local ACTIONS_H = px(18)
local ACTIONS_GAP = Widgets.INSET + Widgets.GAP
local panelH = BAR_H + listH + ACTIONS_GAP + ACTIONS_H + TAB_PADDING * 2 + EDITOR_TABS_H + EDITOR_H + TAB_PADDING * 2
-- big UI sizes: the list gives up rows (down to 3) so the panel ends above the footer
local fitH = (WIN_H or 720) - FOOTER_H
while panelH > fitH and LIST_ROWS > 3 do
    LIST_ROWS, listH, panelH = LIST_ROWS - 1, listH - rowH, panelH - rowH
end
Main.LIST_ROWS = LIST_ROWS -- the Link tab's object grid matches

local BAR_COLOR = Widgets.BAR_COLOR
local BAR_STYLE = { bg = BAR_COLOR, hover = Widgets.HOVER_COLOR, pressed = TB_MENU_DEFAULT_DARKEST_COLOR }
local LIST_BG = Widgets.CONTENT_BG

Main.window = UIElement.new({
    globalid = TB_MENU_HUB_GLOBALID,
    pos = { 0, 0 },
    size = { PANEL_W, panelH },
    bgColor = TB_MENU_DEFAULT_BG_COLOR,
})
local content = Main.window:addChild({
    pos = { PAD, BAR_H },
    size = { PANEL_W - PAD * 2, panelH - BAR_H },
}, true)

-- the top bar: a child of the panel reaching past it, so it shows, hides and dies with it.
-- Interactive so clicks don't reach the world
local topBar = Main.window:addChild({
    pos = { 0, 0 },
    size = { screenW, BAR_H },
    interactive = true,
    bgColor = BAR_COLOR,
    hoverColor = BAR_COLOR,
    pressedColor = BAR_COLOR,
})
Main.topBar = topBar

-- right end: close
local closeButton = TBMenu:spawnCloseButton(topBar, { x = -BAR_H, y = 0, w = BAR_H, h = BAR_H }, function()
    Main.window:kill() -- killAction quits
end, { default = BAR_COLOR, hover = Widgets.HOVER_COLOR, pressed = TB_MENU_DEFAULT_DARKEST_COLOR,
    ui = { 1, 1, 1, 1 } }) -- the bar's colors instead of the default red
Widgets.popupBelowLeft(closeButton, "Close MGE (F1 only hides it)")
if closeButton.child and closeButton.child[1] then -- reload the cross after a graphics change
    Widgets.trackImage(closeButton.child[1], "../textures/menu/general/buttons/crosswhite.tga")
end

-- the tools, left of close
local ICON_COUNT = 8 -- in place, move, rotate, scale, undo, redo, save, settings
local toolsW = BAR_ICON * ICON_COUNT + BAR_GAP * (ICON_COUNT - 1)
-- negative x: from the bar's right edge, so it follows screen size changes
local toolsX = -(BAR_H + BAR_SEP + toolsW)
local iconButtons = topBar:addChild({
    pos = { toolsX, (BAR_H - BAR_ICON) / 2 },
    size = { toolsW, BAR_ICON },
})

---@type UIElement the bar under the list, set with the list panel (below)
local actionsHolder

---The shown list's action buttons in the bar under it, sharing its width (called by each list)
---@param items WidgetRowButton[]
---@return UIElement[] buttons in the same order
function Main.setListActions(items)
    Widgets.clearChildren(actionsHolder)
    return Widgets.buttonRow(actionsHolder, 0, actionsHolder.size.h, items, Widgets.GAP, nil, Widgets.PANEL_STYLE)
end
-- unlit Select all (lit: Widgets.ACTIVE_COLOR)
Main.ACTIONS_BG = Widgets.PANEL_STYLE.bg

---Lights a list action button while isOn() holds, checked every frame (cell clicks don't rebuild lists)
---@param button UIElement
---@param isOn fun(): boolean
function Main.lightWhile(button, isOn)
    Widgets.addDrawBefore(button, function()
        button.bgColor = isOn() and Widgets.ACTIVE_COLOR or Main.ACTIONS_BG
    end)
end

-- gizmo tool toggles, at most one on. Icons in mge/textures/
local TOOLS = {
    { mode = "move", label = "Move (Alt + Q)" },
    { mode = "rotate", label = "Rotate (Alt + W)" },
    { mode = "scale", label = "Scale (Alt + E)" },
}
local bar = {}
-- In place (Transforms.inPlace), lit while on, saved in config.cfg
local IN_PLACE_LABEL = "In place: Rotate / Scale each object\naround itself, positions stay"
table.insert(bar, { label = IN_PLACE_LABEL, icon = MGE.scriptPath .. "textures/inplace.tga", onClick = function()
    MGE.Transforms.inPlace = not MGE.Transforms.inPlace
    Main.updateInPlaceButton()
    MGE.say(MGE.Transforms.inPlace and "In place: on" or "In place: off")
    if MGE.Config then MGE.Config.save() end
end })
for _, tool in ipairs(TOOLS) do
    table.insert(bar, { label = tool.label, icon = MGE.scriptPath .. "textures/" .. tool.mode .. ".tga",
        onClick = function() MGE.Gizmo.toggle(tool.mode) end })
end
-- redo.tga is the game's undo icon mirrored
table.insert(bar, { label = "Undo (Shift + Z)", icon = "../textures/menu/general/buttons/undo.tga", onClick = function() History.undo() end })
table.insert(bar, { label = "Redo (Shift + Y)", icon = MGE.scriptPath .. "textures/redo.tga", onClick = function() History.redo() end })
-- the footer's right end names the file Save writes
table.insert(bar, { label = "Save (Ctrl + S) into " .. MGE.saveFolder .. ".\nName: World > Name", icon = "../textures/menu/general/buttons/savewhite.tga", onClick = function() MGE.save() end })
table.insert(bar, { label = "Settings", icon = "../textures/menu/general/buttons/settingswhite.tga",
    onClick = function() dofile(MGE.scriptPath .. "ui/settings_overlay.lua") end })
for _, item in ipairs(bar) do item.popupLeft = true end -- near the right edge
local icons = Widgets.buttonRow(iconButtons, 0, BAR_ICON, bar, BAR_GAP, nil, BAR_STYLE)

---The in place toggle lit while on
function Main.updateInPlaceButton()
    local btn = icons[1]
    if btn and not btn.destroyed then
        btn.bgColor = MGE.Transforms.inPlace and Widgets.ACTIVE_COLOR or BAR_COLOR
    end
end
Main.updateInPlaceButton()

---Lights the active tool's button (after the in place toggle)
local function updateToolButtons()
    for i, tool in ipairs(TOOLS) do
        local btn = icons[i + 1]
        if btn and not btn.destroyed then
            btn.bgColor = MGE.Gizmo.mode == tool.mode and Widgets.ACTIVE_COLOR or BAR_COLOR
        end
    end
end
table.insert(MGE.Gizmo.modeListeners, updateToolButtons)
updateToolButtons()

-- an active tab takes its panel's color and touches it, reading as one shape
local TAB_PANEL_COLOR = Widgets.TAB_PANEL_COLOR

---Active tabs: the panel's color, no hover / press change. Inactive: the normal button look
---@param btn UIElement
---@param active boolean
---@param activeColor number[]? the panel's color as the tab is drawn (default TAB_PANEL_COLOR)
---@param idleColor number[]? default TB_MENU_DEFAULT_DARKER_COLOR
local function styleTab(btn, active, activeColor, idleColor)
    if active then
        activeColor = activeColor or TAB_PANEL_COLOR
        btn.bgColor, btn.hoverColor, btn.pressedColor = activeColor, activeColor, activeColor
    else
        btn.bgColor = idleColor or TB_MENU_DEFAULT_DARKER_COLOR
        btn.hoverColor = Widgets.HOVER_COLOR
        btn.pressedColor = TB_MENU_DEFAULT_DARKEST_COLOR
    end
end

-- list tabs on the top bar; the active one is drawn solid (the see-through panel color would show the bar)
local listTabNames = {
    { id = "objects", label = "Objects" },
    { id = "atmo", label = "Atmo" },
    { id = "joints", label = "Joints" },
    { id = "players", label = "Players" },
    { id = "misc", label = "World" },
}
local listTabItems = {}
for i, tab in ipairs(listTabNames) do
    listTabItems[i] = { label = tab.label, onClick = function() Main.setListTab(tab.id) end }
end
-- the bar's text buttons, not stretched over the panel
local BAR_TEXT_W = px(56)
local listTabRow = topBar:addChild({
    pos = { PAD, 0 },
    size = { BAR_TEXT_W * #listTabItems + BAR_GAP * (#listTabItems - 1), BAR_H },
})
local listTabButtons = {}
for i, btn in ipairs(Widgets.buttonRow(listTabRow, 0, BAR_H, listTabItems, BAR_GAP, Widgets.TAB_TEXT_SCALE, BAR_STYLE)) do
    listTabButtons[listTabNames[i].id] = btn
end

-- the game's own mod list and gamerules menus, right of the tabs
local gameMenus = topBar:addChild({
    pos = { PAD + listTabRow.size.w + BAR_GAP, 0 },
    size = { BAR_TEXT_W * 2 + BAR_GAP, BAR_H },
})
Widgets.buttonRow(gameMenus, 0, BAR_H, {
    { label = "Mods", onClick = function() dofile("system/mods.lua") end },
    { label = "Rules", onClick = function() dofile("system/gamerules.lua") end },
}, BAR_GAP, Widgets.TAB_TEXT_SCALE, BAR_STYLE)

-- the list's panel, which the active list tab touches
local listPanel = content:addChild({
    pos = defaultPos,
    size = { content.size.w, listH + ACTIONS_GAP + ACTIONS_H + TAB_PADDING * 2 },
    bgColor = TAB_PANEL_COLOR,
})
-- the list and its buttons share one dark background
local listArea = listPanel:addChild({
    pos = { TAB_PADDING, TAB_PADDING },
    size = { listPanel.size.w - TAB_PADDING * 2, listH + ACTIONS_GAP + ACTIONS_H },
    bgColor = LIST_BG,
})
local obj_selector_container = listArea:addChild({
    pos = { 0, 0 },
    size = { listArea.size.w, listH },
})
actionsHolder = listArea:addChild({
    pos = { Widgets.GAP, listH + Widgets.INSET },
    size = { listArea.size.w - Widgets.GAP * 2, ACTIONS_H },
})
updateContentHeight(listPanel.size.h, 0)

-- editor tabs, right above the panel they switch
local TAB_GAP = Widgets.GAP
local tabRow = content:addChild({
    pos = defaultPos,
    size = { content.size.w, EDITOR_TABS_H },
    bgColor = Widgets.TAB_PANEL_SOLID, -- the gaps: the inactive tabs' color
})
updateContentHeight(tabRow.size.h, 0)

-- editor tabs per list; a tab's id is the panel it shows (PANELS in ui/editor.lua)
local OBJECT_TABS = {
    { id = "core", label = "Core" },
    { id = "advanced", label = "Advanced" },
    { id = "thrust", label = "Thrust" },
    { id = "generate", label = "Generate" },
}
local TAB_SETS = {
    objects = OBJECT_TABS,
    atmo = OBJECT_TABS, -- the same panels, on atmo objects' lines
    players = { { id = "player", label = "Core" } },
    misc = { { id = "misc", label = "Core" } },
    joints = { { id = "jointLink", label = "Link" }, { id = "joint", label = "Properties" } },
}
-- tabs as wide as the objects' ones, so rows line up
local TAB_SLOTS = #TAB_SETS.objects
local tabW = (tabRow.size.w - TAB_GAP * (TAB_SLOTS - 1)) / TAB_SLOTS
---@type table<string, UIElement> tab rows by list
local tabRows = {}
---@type table<string, table<string, UIElement>> tab buttons by list, then panel id
local tabButtons = {}
---@type table<string, string> a list each panel id is on (for setTab when the shown list lacks it)
local tabList = {}
for list, tabs in pairs(TAB_SETS) do
    tabRows[list] = tabRow:addChild({
        pos = { 0, 0 },
        size = { #tabs * tabW + (#tabs - 1) * TAB_GAP, tabRow.size.h },
    })
    local items = {}
    for i, tab in ipairs(tabs) do
        items[i] = { label = tab.label, onClick = function() Main.setTab(tab.id) end }
        if not tabList[tab.id] or list == "objects" then tabList[tab.id] = list end
    end
    tabButtons[list] = {}
    for i, btn in ipairs(Widgets.buttonRow(tabRows[list], 0, tabRow.size.h, items, TAB_GAP, Widgets.TAB_TEXT_SCALE)) do
        tabButtons[list][tabs[i].id] = btn
    end
end

---@param list string
---@param id string panel id
---@return boolean the list has that tab
local function listHasTab(list, id)
    for _, tab in ipairs(TAB_SETS[list] or {}) do
        if tab.id == id then return true end
    end
    return false
end

local areaH = EDITOR_H
local tabPanel = content:addChild({
    pos = defaultPos,
    size = { content.size.w, areaH + TAB_PADDING * 2 },
    bgColor = LIST_BG, -- the active editor tab joins it
})
local editorContainer = tabPanel:addChild({
    pos = { TAB_PADDING, TAB_PADDING },
    size = { tabPanel.size.w - TAB_PADDING * 2, areaH },
})
updateContentHeight(tabPanel.size.h)

-- Footer along the screen's bottom (children of the panel, placed by Main.fitScreen): counters left,
-- messages in the middle (chat is hidden with the HUD), the mod Save writes on the right
local FOOTER_EDGE = px(8) -- from the screen's sides
local MESSAGE_W = px(380)
local MESSAGE_SHOW, MESSAGE_FADE = 7, 1 -- seconds shown, then fading
local MESSAGE_MAX = 3 -- newest in the middle, older ones stacked above
---@return UIElement
local function addFooterPart()
    return Main.window:addChild({ pos = { 0, 0 }, size = { 1, FOOTER_H } })
end
local limitsRow = addFooterPart() -- object, dynamic id and joint usage
local fileRow = addFooterPart() -- the file Save writes, unsaved changes
local shown = {} -- what the file row shows (below)

-- message rows, bottom up
---@type UIElement[]
local messageRows = {}
for k = 1, MESSAGE_MAX do
    local row = addFooterPart()
    row.uiColor = { 0, 0, 0, 0 }
    messageRows[k] = row
end

---@type { text: string, at: number }[] shown messages, oldest first
local messages = {}
---@type string[] what each message row has laid out
local rowTexts = {}

---MGE.say's footer half: one line without color codes. A repeated text moves to the newest slot
---@param text string
function MGE.onMessage(text)
    text = text:gsub("%^%d%d", ""):gsub("%s*\n%s*", "  ")
    for i = #messages, 1, -1 do
        if messages[i].text == text then table.remove(messages, i) end
    end
    messages[#messages + 1] = { text = text, at = os.clock_real() }
    if #messages > MESSAGE_MAX then table.remove(messages, 1) end
end

Widgets.addDrawBefore(messageRows[1], function()
    local now = os.clock_real()
    for i = #messages, 1, -1 do
        if now - messages[i].at >= MESSAGE_SHOW + MESSAGE_FADE then table.remove(messages, i) end
    end
    for k, row in ipairs(messageRows) do
        local m = messages[#messages - k + 1] -- row 1 the newest
        -- empty rows are cleared, else their old text stays drawn
        local text, alpha = "", 0
        if m then
            local age = now - m.at
            text, alpha = m.text, age > MESSAGE_SHOW and 1 - (age - MESSAGE_SHOW) / MESSAGE_FADE or 1
        end
        row.uiColor[4] = alpha
        if text ~= rowTexts[k] then
            Widgets.infoText(row, text)
            rowTexts[k] = text
        end
    end
end)

---Fits the top bar and footer to the screen (at start and on resolution / GUI scale changes)
function Main.fitScreen()
    local w, h = get_window_size()
    w, h = w or WIN_W or 1280, h or WIN_H or 720
    topBar.size.w = w
    topBar:moveTo(0, 0) -- repositions its children
    local sideW = (w - MESSAGE_W) / 2 - FOOTER_EDGE - BAR_SEP
    for _, part in ipairs({ { limitsRow, FOOTER_EDGE }, { fileRow, w - FOOTER_EDGE - sideW } }) do
        part[1].size.w = sideW
        part[1]:moveTo(part[2], h - FOOTER_H)
    end
    for k, row in ipairs(messageRows) do
        row.size.w = MESSAGE_W
        row:moveTo((w - MESSAGE_W) / 2, h - FOOTER_H * k)
    end
    rowTexts, shown = {}, {} -- lay text out again for the new widths
    if Main.refreshCounters then Main.refreshCounters() end
end
table.insert(Widgets.onScreenChanged, Main.fitScreen)
Main.fitScreen()

-- footer text: black over the light game view, dark red for warnings
local WARNING_COLOR = { 0.6, 0.02, 0.02, 1 }
local FOOTER_COLOR = { 0, 0, 0, 1 }

-- File row: checked every frame but recomputed only when the data (undo state, reload) or the source
-- changed. Interned strings make the comparisons cheap
Widgets.addDrawBefore(fileRow, function()
    local parsed, state, saved = ModData.parsed, History.states[History.index], MGE.savedText
    local source = tostring(MGE.sourcePath) .. "|" .. tostring(MGE.saveName)
    -- the atmo's saved text compared alone: joining it would copy hundreds of KB a frame
    local atmo, header = MGE.Atmo.state.text, MGE.Atmo.headerVersion
    if shown.parsed == parsed and shown.state == state and shown.source == source and shown.saved == saved
        and shown.atmo == atmo and shown.header == header and shown.done then return end
    shown = { parsed = parsed, state = state, source = source, saved = saved, atmo = atmo, header = header, done = true }
    local target = MGE.saveTarget()
    local unsaved = MGE.hasUnsavedChanges()
    local text = "Mod: " .. target .. (unsaved and "  (unsaved changes)" or "")
    fileRow.uiColor = unsaved and WARNING_COLOR or FOOTER_COLOR
    Widgets.infoText(fileRow, text, RIGHTMID)
end)


dofile(MGE.scriptPath .. "ui/scroll_list.lua")
MGE.ScrollList.bgColor = LIST_BG
dofile(MGE.scriptPath .. "ui/file_picker.lua")
dofile(MGE.scriptPath .. "ui/color_picker.lua")
dofile(MGE.scriptPath .. "ui/assets.lua")
local obj_selector = dofile(MGE.scriptPath .. "ui/obj_selector.lua")
local joint_list = dofile(MGE.scriptPath .. "ui/joint_list.lua")
local player_list = dofile(MGE.scriptPath .. "ui/player_list.lua")
local editor = dofile(MGE.scriptPath .. "ui/editor.lua")

---Shows the shown list's tab row and active panel
function Main.applyTab()
    for list, row in pairs(tabRows) do
        if list == Main.listTab then row:show(true) else row:hide(true) end
    end
    tabPanel:show(true)
    local active = Main.activeTabs[Main.listTab]
    editor.applyPanel(active)
    for id, btn in pairs(tabButtons[Main.listTab] or {}) do
        styleTab(btn, id == active, LIST_BG, Widgets.TAB_PANEL_SOLID)
    end
    -- window hidden (F1): show() above draws children even under a hidden parent; hide again, keeping the
    -- flags so F1 shows the right row and panel
    if Main.window and not Main.window.destroyed and not Main.window.displayed then Main.window:hide() end
end

---Makes a tab its list's active one; a panel on several lists goes to the shown one if it has it
---@param id string panel id, see TAB_SETS
function Main.setTab(id)
    local list = listHasTab(Main.listTab, id) and Main.listTab or tabList[id]
    if not list then return end
    Main.activeTabs[list] = id
    Main.applyTab()
end

---Selecting on a list showing Generate switches it to Core, so the gizmo and rows work on the selection
---@param list string? "objects" or "atmo", default the shown one
function Main.leaveGenerate(list)
    list = list or Main.listTab
    if (list ~= "objects" and list ~= "atmo") or Main.activeTabs[list] ~= "generate" then return end
    Main.activeTabs[list] = "core"
    if list == Main.listTab then Main.applyTab() end
end

---Every way of selecting ends here (not deselecting): Generate back to Core, camera follow
function Main.selectionMade()
    Main.leaveGenerate()
    MGE.Camera.followSelection()
end

---Players in the mod (numplayers), keeping the selection in range
---@return integer
function Main.getPlayerCount()
    local count = math.max(tonumber(get_game_rules().numplayers) or 2, 1)
    for id in pairs(Main.selectedPlayers) do
        if id >= count then Main.selectedPlayers[id] = nil end
    end
    if Main.selectedPlayer >= count then Main.selectedPlayer = 0 end
    return count
end

---Selected players in order (can be empty)
---@return integer[]
function Main.selectedPlayerList()
    Main.getPlayerCount() -- keeps it in range
    local list = {}
    for id in pairs(Main.selectedPlayers) do table.insert(list, id) end
    table.sort(list)
    return list
end

local function applyListTab()
    for id, btn in pairs(listTabButtons) do
        styleTab(btn, id == Main.listTab, Widgets.TAB_PANEL_SOLID, BAR_COLOR)
    end
end

---Picks a player like ModData.clickSelect picks objects; the panel shows the last picked one
---@param id integer 0-based
---@param additive boolean?
function Main.selectPlayer(id, additive)
    if not additive then
        local onlySelected = Main.selectedPlayers[id] == true
        for p in pairs(Main.selectedPlayers) do
            if p ~= id then onlySelected = false end
        end
        Main.selectedPlayers = onlySelected and {} or { [id] = true }
        Main.selectedPlayer = id
    elseif Main.selectedPlayers[id] then
        Main.selectedPlayers[id] = nil
        if id == Main.selectedPlayer then -- the panel moves to another selected one
            for p in pairs(Main.selectedPlayers) do Main.selectedPlayer = p break end
        end
    else
        Main.selectedPlayers[id] = true
        Main.selectedPlayer = id
    end
    Main.updateWindow()
    MGE.Camera.followPlayer(Main.selectedPlayerList())
end

---Ctrl + A on the Players list: all, or none when all are selected
function Main.toggleSelectAllPlayers()
    local count = Main.getPlayerCount()
    local all = true
    for id = 0, count - 1 do
        if not Main.selectedPlayers[id] then all = false break end
    end
    Main.selectedPlayers = {}
    if not all then
        for id = 0, count - 1 do Main.selectedPlayers[id] = true end
        MGE.Camera.followPlayer(Main.selectedPlayerList())
    end
    Main.updateWindow()
end

---Selected joints in id order (empty slots left out)
---@return FileParserEnvObjJoint[]
function Main.selectedJointList()
    local list = {}
    for _, joint in ipairs(ModData.parsed.env_obj_joint) do
        if joint.id and Main.selectedJoints[joint.id] then table.insert(list, joint) end
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

---The current joint slot (see jointSlot)
---@return integer
function Main.selectedSlot()
    return Main.jointSlot
end

---The slot world clicks pick objects for: the current one while the Link tab shows
---@return integer?
function Main.linkSlot()
    if Main.listTab ~= "joints" or Main.activeTabs.joints ~= "jointLink" then return nil end
    return Main.jointSlot
end

---Camera follow on the Joints list: frames the objects the selected joints link
local function followJoints()
    local ids = MGE.Joints.getObjectIds(Main.selectedJointList())
    local objects = {}
    for _, obj in ipairs(ModData.parsed.env_obj) do
        if ids[obj.id] then table.insert(objects, obj) end
    end
    if MGE.Camera.followMoves and #objects > 0 then MGE.Camera.focus(objects) end
end
Main.followJoints = followJoints

---Drops a draft for another slot after the joint selection changed
local function dropOtherDraft()
    local draft = MGE.Joints.draft
    if draft and draft.jointId ~= Main.jointSlot then MGE.Joints.resetDraft() end
end

---Picks a joint slot: click selects only it, Shift toggles it; one always stays selected. An empty
---slot opens the Link tab
---@param id integer joint id
---@param additive boolean?
function Main.selectJoint(id, additive)
    local selected = Main.selectedJoints
    if additive and selected[id] then
        if next(selected, nil) ~= id or next(selected, id) ~= nil then -- not the only one
            selected[id] = nil
            if Main.jointSlot == id then Main.jointSlot = next(selected) end
        end
    elseif additive then
        selected[id] = true
        Main.jointSlot = id
    else
        Main.selectedJoints = { [id] = true }
        Main.jointSlot = id
    end
    dropOtherDraft()
    if Main.selectedJoints[id] then
        followJoints()
        if not MGE.Joints.find(id) and Main.activeTabs.joints ~= "jointLink" then Main.setTab("jointLink") end
    end
    Main.onSelectionChanged() -- the grid restyles its cells itself
end

---Selects only these joint slots, the first is the current one, e.g. a new joint
---@param ids integer[]
function Main.selectJointsOnly(ids)
    if not ids[1] then return end
    Main.selectedJoints = {}
    for _, id in ipairs(ids) do Main.selectedJoints[id] = true end
    Main.jointSlot = ids[1]
    dropOtherDraft()
end

---Ctrl + A on the Joints list: every joint, or only the current slot when all are selected
function Main.toggleSelectAllJoints()
    local joints = ModData.parsed.env_obj_joint
    local all = #joints > 0
    for _, joint in ipairs(joints) do
        if not Main.selectedJoints[joint.id] then all = false break end
    end
    Main.selectedJoints = { [Main.jointSlot] = true }
    if not all then
        for _, joint in ipairs(joints) do
            if joint.id then Main.selectedJoints[joint.id] = true end
        end
        followJoints()
    end
    Main.updateWindow()
end

---Switches the shown list (the Atmo list makes the mod's objects see-through)
---@param id "objects"|"atmo"|"joints"|"players"
function Main.setListTab(id)
    local changed = Main.listTab ~= id
    Main.listTab = id
    if id ~= "joints" then MGE.Joints.worldPick = false end
    MGE.AtmoLayer.setObjectsSeeThrough(id == "atmo")
    applyListTab()
    Main.applyTab()
    Main.updateWindow()
    if changed then
        if id == "players" then
            MGE.Camera.followPlayer(Main.selectedPlayerList())
        elseif id == "joints" then
            followJoints()
        else
            MGE.Camera.followSelection()
        end
    end
end

---Why dynamic objects won't fully work yet, nil when they do
---@return string?
function Main.dynamicWarning()
    local dynamic, misplaced = ModData.countDynamic(), ModData.countMisplaced()
    if dynamic > MGE.MAX_NONSTATIC_OBJECTS then
        return (dynamic - MGE.MAX_NONSTATIC_OBJECTS) .. " too many dynamic, make some static"
    elseif misplaced > 0 then
        return misplaced .. " dynamic above id " .. MGE.MAX_NONSTATIC_OBJECTS .. ", Reindex"
    end
    return nil
end

local function setDynamicStrings()
    local warning = Main.dynamicWarning()
    limitsRow.uiColor = warning and WARNING_COLOR or FOOTER_COLOR
    local atmoCount = #ModData.parsed.atmo
    Widgets.infoText(limitsRow, "Objects " .. #ModData.parsed.env_obj .. "/" .. MGE.MAX_ENV_OBJECTS ..
        (atmoCount > 0 and (" +" .. atmoCount .. " atmo") or "") ..
        "    Dynamic " .. ModData.countDynamic() .. "/" .. MGE.MAX_NONSTATIC_OBJECTS ..
        (warning and " (" .. warning .. ")" or "") ..
        "    Joints " .. #ModData.parsed.env_obj_joint .. "/" .. MGE.MAX_ENV_JOINTS, LEFTMID)
end
Main.refreshCounters = setDynamicStrings

local function createObjSelector()
    if Main.listTab == "players" then
        player_list.create(obj_selector_container)
    elseif Main.listTab == "joints" then
        joint_list.create(obj_selector_container)
    elseif Main.listTab == "atmo" then
        obj_selector.create(obj_selector_container, ModData.parsed.atmo, "atmo")
    elseif Main.listTab == "misc" then
        Main.setListActions({})
        obj_selector_container:addChild({
            pos = { Widgets.px(8), 0 },
            size = { obj_selector_container.size.w - Widgets.px(16), obj_selector_container.size.h },
        }):addAdaptedText("There's only one world\n ...for now", nil, nil, Widgets.FONT, CENTERMID,
            Widgets.TEXT_SCALE_SMALL, nil, nil)
    else
        obj_selector.create(obj_selector_container, ModData.parsed.env_obj)
    end
end

local function createEditor()
    editor.create(editorContainer)
end

---Selection changed: editor shows the new selection's current values
function Main.onSelectionChanged()
    editor.onSelectionChanged()
end

function Main.updateWindow()
    if not Main.window.displayed then return end
    Widgets.clearChildren(obj_selector_container)
    setDynamicStrings()
    createObjSelector()
    Main.onSelectionChanged()
end

---Selects or deselects every object of a list
---@param list FileParserEnvObj[]
---@param value boolean? nil selects all, or deselects all when all are selected
local function selectAllIn(list, value)
    if value == nil then
        value = false
        for _, obj in ipairs(list) do
            if not obj.selected then value = true break end
        end
    end
    for _, obj in ipairs(list) do obj.selected = value or nil end
    Main.updateWindow()
    if value then Main.selectionMade() end
end

---Select all / Ctrl + A on the Objects list
---@param value boolean? see selectAllIn
function Main.toggleSelectAll(value)
    selectAllIn(ModData.parsed.env_obj, value)
end

---Select all / Ctrl + A on the Atmo list
function Main.toggleSelectAllAtmo()
    selectAllIn(ModData.parsed.atmo)
end

function Main.resetWindow()
    Main.page = 1
    Main.selectedJoints, Main.jointSlot = { [1] = true }, 1 -- another mod's joints
    MGE.Joints.resetDraft()
    Main.updateWindow()
end

setDynamicStrings()
createObjSelector();
createEditor()
Main.applyTab()
applyListTab()

-- closing the window quits (quit skips the window, it's already dying)
Main.window.killAction = function() MGE.quit(true) end
return Main
