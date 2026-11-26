-- Parts list (docs/body-parts-plan.md): a map of the classic tori seen from behind (its left on the left),
-- every body part and joint a clickable shape; Shift adds. Always the classic proportions, whatever the mod's
-- layout: a picker (custom layouts like a car body overlap too much to click). A player switch picks whose
-- parts the map selects; selections can span players. Mirror: edits also change the l_ / r_ twins

local PartList = {
    mirror = true, -- Mirror on the action bar
}
MGE.PartList = PartList

local Main = MGE.Main
local ModData = MGE.ModData
local BodyParts = MGE.BodyParts
local Widgets = MGE.Widgets

-- selection: Main.selectedParts["<player>:<body>"] / ["<player>:j:<joint>"] = true (body and joint names
-- overlap: chest, r_pecs, l_pecs), Main.partsPlayer the shown player
Main.selectedParts = Main.selectedParts or {}
Main.partsPlayer = Main.partsPlayer or 0

---@param player integer
---@param name string lower case
---@param kind "body"|"joint"?
---@return string
local function key(player, name, kind)
    return player .. (kind == "joint" and ":j:" or ":") .. name
end

---@param kind string
---@param name string
---@return integer
local function partId(kind, name)
    local ids = kind == "joint" and JOINTS or BODYPARTS
    return ids and ids[name:upper()] or 99
end

---@class SelectedPart
---@field player integer
---@field name string lower case
---@field kind "body"|"joint"

---Selected parts by player, bodies then joints, by id
---@param kind "body"|"joint"? only these
---@return SelectedPart[]
function PartList.selected(kind)
    local list = {}
    local count = Main.getPlayerCount()
    for k in pairs(Main.selectedParts) do
        local player, j, name = k:match("^(%d+):(j?):?(.+)$")
        local partKind = j == "j" and "joint" or "body"
        player = tonumber(player)
        if player and player < count and (not kind or kind == partKind) then
            list[#list + 1] = { player = player, name = name, kind = partKind }
        end
    end
    table.sort(list, function(a, b)
        if a.player ~= b.player then return a.player < b.player end
        if a.kind ~= b.kind then return a.kind == "body" end
        return partId(a.kind, a.name) < partId(b.kind, b.name)
    end)
    return list
end

---Selected names per player
---@param kind "body"|"joint"? default body
---@return table<integer, string[]>
function PartList.byPlayer(kind)
    local out = {}
    for _, part in ipairs(PartList.selected(kind or "body")) do
        out[part.player] = out[part.player] or {}
        table.insert(out[part.player], part.name)
    end
    return out
end

---Like a click on an object: only this part (clicking the only selected one deselects it); Shift toggles it
---@param player integer
---@param name string
---@param additive boolean?
---@param kind "body"|"joint"? default body
function PartList.select(player, name, additive, kind)
    name = name:lower()
    local k = key(player, name, kind)
    if additive then
        Main.selectedParts[k] = not Main.selectedParts[k] or nil
    else
        local only = Main.selectedParts[k] == true
        for other in pairs(Main.selectedParts) do
            if other ~= k then only = false end
        end
        Main.selectedParts = only and {} or { [k] = true }
    end
    local switched = Main.partsPlayer ~= player
    Main.partsPlayer = player
    Main.updateWindow()
    if switched then MGE.Camera.followPlayer({ player }) end
end

---Adds parts to the selection (box select). The map keeps its player when one of them is on it
---@param parts SelectedPart[]
function PartList.add(parts)
    local onShown = false
    for _, part in ipairs(parts) do
        Main.selectedParts[key(part.player, part.name, part.kind)] = true
        if part.player == Main.partsPlayer then onShown = true end
    end
    if parts[1] and not onShown then Main.partsPlayer = parts[1].player end
    Main.updateWindow()
end

---Ctrl + A: all of the shown player's bodies (on the Joints tab: joints), or none when all are selected
function PartList.toggleSelectAll()
    local kind = Main.activeTabs.parts == "partsJoints" and "joint" or "body"
    local names = kind == "joint" and BodyParts.DEFAULTS.joint or BodyParts.DEFAULTS.body
    local player, all = Main.partsPlayer, true
    for name in pairs(names) do
        if not Main.selectedParts[key(player, name, kind)] then all = false break end
    end
    for name in pairs(names) do Main.selectedParts[key(player, name, kind)] = (not all) or nil end
    Main.updateWindow()
end

---@param player integer
function PartList.showPlayer(player)
    if Main.partsPlayer == player then return end
    Main.partsPlayer = player
    Main.updateWindow()
    MGE.Camera.followPlayer({ player })
end

---Applies an edit to every player with selected parts (Mirror: mirrorX set, the twins get it mirrored), one
---undo step and a reload
---@param apply fun(section: BodySection, player: integer, bodies: string[], mirrorX: number?, joints: string[])
function PartList.edit(apply)
    local bodies, joints = PartList.byPlayer("body"), PartList.byPlayer("joint")
    local players = {}
    for p in pairs(bodies) do players[p] = true end
    for p in pairs(joints) do players[p] = true end
    if not next(players) then return end
    local parsed = ModData.parsed
    for player in pairs(players) do
        local section = BodyParts.section(parsed, player)
        apply(section, player, bodies[player] or {}, PartList.mirror and BodyParts.mirrorX(section) or nil,
            joints[player] or {})
        BodyParts.write(parsed, player, section)
    end
    MGE.History.commit()
    MGE.apply()
end

---A new mod: nothing selected, player 0 shown
function PartList.reset()
    Main.selectedParts, Main.partsPlayer = {}, 0
end

---------------------------------------------------------------------------------------------------- the map

---@class PartMapItem
---@field name string
---@field kind "body"|"joint"
---@field shape string "box"|"sphere"|"cylinder"
---@field u number center, map units (screen right = the player's -x: seen from behind)
---@field v number center (up = z)
---@field hw number half width
---@field hh number half height (pill: of its middle part)
---@field r number sphere / pill radius
---@field depth number file y: larger is nearer the viewer behind the player

---The classic tori's bodies projected onto the back view, its joints after them
---@return PartMapItem[] far to near, then the joints (drawn on top, hit first)
local function mapItems()
    local section = BodyParts.parseSection({}) -- no lines: every value classic
    local items = {}
    for name in pairs(BodyParts.DEFAULTS.body) do
        local p = BodyParts.vector(section, "body", name, "pos") or { 0, 0, 0 }
        local s = BodyParts.vector(section, "body", name, "sides") or { 0.1, 0.1, 0.1 }
        local shape = BodyParts.shape(section, name) or "box"
        local item = { name = name, kind = "body", shape = shape, u = -p[1], v = p[3], depth = p[2], r = 0 }
        if shape == "sphere" then
            item.r = math.abs(s[1])
            item.hw, item.hh = item.r, item.r
        elseif shape == "cylinder" then
            item.r = math.abs(s[1])
            item.hw, item.hh = item.r, math.abs(s[2]) / 2
        else
            item.hw, item.hh = math.abs(s[1]) / 2, math.abs(s[3]) / 2
        end
        items[#items + 1] = item
    end
    table.sort(items, function(a, b)
        if a.depth ~= b.depth then return a.depth < b.depth end
        return a.name < b.name
    end)
    local joints = {}
    for name in pairs(BodyParts.DEFAULTS.joint) do
        local p = BodyParts.vector(section, "joint", name, "pos") or { 0, 0, 0 }
        local r = math.abs(BodyParts.jointNumber(section, name, "radius") or 0.1)
        joints[#joints + 1] = { name = name, kind = "joint", shape = "sphere", u = -p[1], v = p[3], depth = p[2], r = r,
            hw = r, hh = r }
    end
    table.sort(joints, function(a, b)
        if a.depth ~= b.depth then return a.depth < b.depth end
        return a.name < b.name
    end)
    for _, j in ipairs(joints) do items[#items + 1] = j end
    return items
end

---Map units -> pixels inside rect, the whole body fitting
---@param items PartMapItem[]
---@param rect { x: number, y: number, w: number, h: number }
---@return fun(u: number, v: number): number, number toScreen
---@return number scale pixels per unit
local function fit(items, rect)
    local u0, u1, v0, v1 = math.huge, -math.huge, math.huge, -math.huge
    for _, it in ipairs(items) do
        local extraV = it.shape == "cylinder" and it.r or 0
        u0, u1 = math.min(u0, it.u - it.hw), math.max(u1, it.u + it.hw)
        v0, v1 = math.min(v0, it.v - it.hh - extraV), math.max(v1, it.v + it.hh + extraV)
    end
    local pad = 0.05
    u0, u1, v0, v1 = u0 - pad, u1 + pad, v0 - pad, v1 + pad
    local scale = math.min(rect.w / math.max(u1 - u0, 1e-3), rect.h / math.max(v1 - v0, 1e-3))
    local ox = rect.x + (rect.w - (u1 - u0) * scale) / 2
    local oy = rect.y + (rect.h - (v1 - v0) * scale) / 2
    return function(u, v) return ox + (u - u0) * scale, oy + (v1 - v) * scale end, scale
end

---@param it PartMapItem
---@param mx number map units
---@param mv number
---@return boolean
local function hits(it, mx, mv)
    local du, dv = math.abs(mx - it.u), math.abs(mv - it.v)
    if it.shape == "sphere" then return du * du + dv * dv <= it.r * it.r end
    if it.shape == "cylinder" then
        if du <= it.r and dv <= it.hh then return true end
        local cv = dv - it.hh
        return cv > 0 and du * du + cv * cv <= it.r * it.r
    end
    return du <= it.hw and dv <= it.hh
end

-- the map's geometry, for tests
PartList.mapItems, PartList.fitMap, PartList.hitsItem = mapItems, fit, hits

local COLOR = { 0.8, 0.8, 0.8, 0.45 }
local JOINT_COLOR = { 1, 0.75, 0.3, 0.55 }
local HOVER = { 1, 1, 1, 0.75 }
local MIN_PX = 3 -- tiny parts stay visible and clickable

local classicItems = nil ---@type PartMapItem[]? the same for every player and mod: made once

---@param el UIElement the map
---@param player integer whose parts it selects
local function buildMap(el, player)
    classicItems = classicItems or mapItems()
    local items = classicItems
    local rect = { x = 0, y = 0, w = el.size.w, h = el.size.h }
    local toScreen, scale = fit(items, rect)
    local hovered = nil ---@type PartMapItem?

    ---The nearest part under a screen point (absolute): joints first, then bodies near to far
    ---@return PartMapItem?
    local function partAt(x, y)
        local lx, ly = x - el.pos.x, y - el.pos.y
        local ax, ay = toScreen(0, 0) -- map units back from pixels
        local u, v = (lx - ax) / scale, (ay - ly) / scale
        local grow = MIN_PX / scale
        for i = #items, 1, -1 do -- near first
            local it = items[i]
            local big = { shape = it.shape, u = it.u, v = it.v, hw = math.max(it.hw, grow), hh = it.hh,
                r = math.max(it.r, grow) }
            if it.shape == "box" then big.hh = math.max(it.hh, grow) end
            if hits(big, u, v) then return it end
        end
        return nil
    end

    el:addCustomDisplay(true, function()
        if el.hoverState == BTN_NONE then hovered = nil end
        local Highlight = MGE.Highlight
        local sel = Highlight and Highlight.color or { 0, 0.333, 1 }
        for _, it in ipairs(items) do
            local c = Main.selectedParts[key(player, it.name, it.kind)] and { sel[1], sel[2], sel[3], 0.9 }
                or (it == hovered and HOVER or (it.kind == "joint" and JOINT_COLOR or COLOR))
            set_color(c[1], c[2], c[3], c[4])
            local cx, cy = toScreen(it.u, it.v)
            cx, cy = cx + el.pos.x, cy + el.pos.y
            local hw, hh, r = math.max(it.hw * scale, MIN_PX), it.hh * scale, math.max(it.r * scale, MIN_PX)
            if it.shape == "sphere" then
                draw_disk(cx, cy, 0, r, 24, 1, 0, 360, 0)
            elseif it.shape == "cylinder" then
                draw_quad(cx - r, cy - hh, r * 2, hh * 2)
                -- angles as the game's chat pills: 0 down, 90 right, 180 up
                draw_disk(cx, cy - hh, 0, r, 16, 1, 90, 180, 0)
                draw_disk(cx, cy + hh, 0, r, 16, 1, -90, 180, 0)
            else
                hh = math.max(hh, MIN_PX)
                draw_quad(cx - hw, cy - hh, hw * 2, hh * 2)
            end
        end
        if hovered then
            set_color(1, 1, 1, 0.9)
            draw_text(hovered.name .. (hovered.kind == "joint" and " (joint)" or ""), el.pos.x + 2,
                el.pos.y + el.size.h - 16, FONTS.SMALL)
        end
    end)
    el:addMouseHandlers(nil, function(_, x, y)
        local it = partAt(x, y)
        if it then PartList.select(player, it.name, get_keyboard_shift() ~= 0, it.kind) end
    end, function(x, y)
        hovered = partAt(x, y)
    end)
    el.killAction = function() hovered = nil end
end

---@param holder UIElement
---@param count integer
local function buildPlayerSwitch(holder, count)
    local items = {}
    for p = 0, count - 1 do
        items[#items + 1] = { label = "P" .. p, onClick = function() PartList.showPlayer(p) end }
    end
    local buttons = Widgets.buttonRow(holder, 0, holder.size.h, items, Widgets.GAP, Widgets.TAB_TEXT_SCALE,
        Widgets.PANEL_STYLE)
    for p, btn in ipairs(buttons) do
        if p - 1 == Main.partsPlayer then btn.bgColor = Widgets.ACTIVE_COLOR end
    end
end

---@return string
local function summary()
    local list = PartList.selected()
    if #list == 0 then return "Click a part or joint\n(Shift adds)" end
    local names = {}
    for i, part in ipairs(list) do
        if i > 4 then
            names[#names + 1] = "+" .. (#list - 4) .. " more"
            break
        end
        names[#names + 1] = "P" .. part.player .. " " .. part.name .. (part.kind == "joint" and " (joint)" or "")
    end
    return #list .. " selected" .. (PartList.mirror and " (Mirror on)" or "") .. "\n" .. table.concat(names, "\n")
end

---@param view UIElement list area, emptied by the caller
function PartList.create(view)
    local count = Main.getPlayerCount()
    if Main.partsPlayer >= count then Main.partsPlayer = 0 end
    local barIcons = Main.setListActions({
        { label = "Select / deselect all of the shown player's parts (Ctrl + A)",
            icon = MGE.scriptPath .. "textures/selectall.tga", wide = true, onClick = PartList.toggleSelectAll },
        { label = "Mirror", onClick = function()
            PartList.mirror = not PartList.mirror
            Main.updateWindow()
        end },
    })
    Main.lightWhile(barIcons[2], function() return PartList.mirror end)
    Widgets.popupBelow(barIcons[2], "Mirror: edits also change the left / right twin\n(mirrored across the body's middle).")

    local gap = Widgets.px(6)
    local mapW = math.min(view.size.h, view.size.w * 0.5)
    local map = view:addChild({ pos = { 0, 0 }, size = { mapW, view.size.h }, interactive = true })
    buildMap(map, Main.partsPlayer)

    local side = view:addChild({ pos = { mapW + gap, gap }, size = { view.size.w - mapW - gap * 2, view.size.h - gap * 2 } })
    local switchH = Widgets.LIST_ROW_H
    if count > 1 then
        buildPlayerSwitch(side:addChild({ pos = { 0, 0 }, size = { side.size.w, switchH } }), count)
    end
    local info = side:addChild({
        pos = { 0, count > 1 and switchH + gap or 0 },
        size = { side.size.w, side.size.h - (count > 1 and switchH + gap or 0) },
    })
    info:addAdaptedText(summary(), nil, nil, Widgets.FONT, LEFT, Widgets.TEXT_SCALE_SMALL, nil, nil)
end

return PartList
