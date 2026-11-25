-- Color picker overlay (Core tab's Color name): saturation / brightness square, hue and alpha bars, old
-- and new color, a palette saved in config.cfg (+ saves, click uses, right click removes) and Pick from
-- world. Enter applies, Esc cancels. Colors are r g b a with 1 for 255 (the fields allow brighter)

---@class ColorPickerOptions
---@field color number[] r g b a to start from, 1 is 255
---@field onApply fun(color: number[]) runs after closing
---@field onPickWorld fun()? Pick from world (no button without it), runs after closing

local ColorPicker = {}
MGE.ColorPicker = ColorPicker

local Widgets = MGE.Widgets
local px = Widgets.px

local BOX_W = px(320)
local PAD = px(10)
local TITLE_H = px(36)
local BAR_W = px(18) -- the hue and alpha bars
local BAR_GAP = px(8)
local PREVIEW_H = px(34)
local TEXT_H = px(22)
local BUTTON_H = px(32)
local SWATCH_H = px(24) -- the palette's row
local PALETTE_SIZE = 10
local STRIPS = 48 -- quads per gradient

---@param v number
---@return number
local function clamp01(v) return math.max(0, math.min(1, v)) end

---@param h number 0-1
---@param s number 0-1
---@param v number 0-1
---@return number r, number g, number b
local function hsvToRgb(h, s, v)
    local i = math.floor(h * 6) % 6
    local f = h * 6 - math.floor(h * 6)
    local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
    if i == 0 then return v, t, p
    elseif i == 1 then return q, v, p
    elseif i == 2 then return p, v, t
    elseif i == 3 then return p, q, v
    elseif i == 4 then return t, p, v
    end
    return v, p, q
end

---@return number h, number s, number v all 0-1 (h 0 for grays)
local function rgbToHsv(r, g, b)
    local max, min = math.max(r, g, b), math.min(r, g, b)
    local d = max - min
    local h = 0
    if d > 0 then
        if max == r then h = ((g - b) / d) % 6
        elseif max == g then h = (b - r) / d + 2
        else h = (r - g) / d + 4 end
        h = h / 6
    end
    return h, max > 0 and d / max or 0, max
end
ColorPicker.hsvToRgb, ColorPicker.rgbToHsv = hsvToRgb, rgbToHsv -- tests

---@param x number
---@param y number
---@param w number
---@param h number
---@param cell number
local function drawChecker(x, y, w, h, cell)
    set_color(0.8, 0.8, 0.8, 1)
    draw_quad(x, y, w, h)
    set_color(0.55, 0.55, 0.55, 1)
    local row = 0
    for cy = y, y + h - 1, cell do
        local col = row % 2
        for cx = x + col * cell, x + w - 1, cell * 2 do
            draw_quad(cx, cy, math.min(cell, x + w - cx), math.min(cell, y + h - cy))
        end
        row = row + 1
    end
end

---A gradient as STRIPS quads: color(t) sets the color for t from 0 to 1 (left to right, or top to bottom)
---@param vertical boolean strips stacked top to bottom
---@param color fun(t: number)
local function drawStrips(x, y, w, h, vertical, color)
    for i = 0, STRIPS - 1 do
        color((i + 0.5) / STRIPS)
        if vertical then
            local y1, y2 = math.floor(y + h * i / STRIPS), math.floor(y + h * (i + 1) / STRIPS)
            draw_quad(x, y1, w, y2 - y1)
        else
            local x1, x2 = math.floor(x + w * i / STRIPS), math.floor(x + w * (i + 1) / STRIPS)
            draw_quad(x1, y, x2 - x1, h)
        end
    end
end

---A frame visible on any color: dark outside, light inside
local function drawMarker(x, y, w, h)
    set_color(0, 0, 0, 0.9)
    draw_quad(x - 2, y - 2, w + 4, 2); draw_quad(x - 2, y + h, w + 4, 2)
    draw_quad(x - 2, y, 2, h); draw_quad(x + w, y, 2, h)
    set_color(1, 1, 1, 1)
    draw_quad(x, y, w, 1); draw_quad(x, y + h - 1, w, 1)
    draw_quad(x, y, 1, h); draw_quad(x + w - 1, y, 1, h)
end

---Readable text color over c on the checkerboard
---@param c number[] r g b a
---@return number[]
local function textColor(c)
    local light = (0.3 * c[1] + 0.59 * c[2] + 0.11 * c[3]) * c[4] + 0.7 * (1 - c[4])
    return light > 0.55 and { 0, 0, 0, 1 } or { 1, 1, 1, 1 }
end

---Calls onPoint(fx, fy) (0-1 of the element's size) while the mouse is pressed on it
---@param element UIElement
---@param onPoint fun(fx: number, fy: number)
local function addDrag(element, onPoint)
    local function at(x, y)
        onPoint(clamp01((x - element.pos.x) / element.size.w), clamp01((y - element.pos.y) / element.size.h))
    end
    element:addMouseHandlers(function(_, x, y) at(x, y) end, nil, function(x, y)
        if element.hoverState == BTN_DN then at(x, y) end
    end)
end

---@param c number[] r g b a, 1 is 255
---@return string "r g b a" 0-255
local function colorKey(c) return MGE.Config.colorText(c) end

---Adds a color at the end
---@param list number[][]
---@param color number[]
---@param max integer
---@return "added"|"exists"|"full"
function ColorPicker.addToPalette(list, color, max)
    local key = colorKey(color)
    for _, c in ipairs(list) do
        if colorKey(c) == key then return "exists" end
    end
    if #list >= max then return "full" end
    local copy = {}
    for i = 1, 4 do copy[i] = math.floor(clamp01(color[i]) * 255 + 0.5) / 255 end
    list[#list + 1] = copy
    return "added"
end

---@param options ColorPickerOptions
function ColorPicker.open(options)
    if MGE.overlayOpen() then return end
    local old = {}
    for i = 1, 4 do old[i] = clamp01(options.color[i] or 1) end
    local h, s, v = rgbToHsv(old[1], old[2], old[3])
    local alpha = old[4]

    ---@return number[] r g b a
    local function current()
        local r, g, b = hsvToRgb(h, s, v)
        return { r, g, b, alpha }
    end

    local overlay = TBMenu:spawnWindowOverlay()
    MGE.colorOverlay = overlay
    local defaultKillAction = overlay.killAction
    overlay.killAction = function()
        if defaultKillAction then defaultKillAction() end
        if MGE then MGE.colorOverlay = nil end
        ColorPicker.confirm = nil
        enable_camera_movement()
    end
    local function close() overlay:kill() end
    local function apply()
        local color = current()
        close()
        options.onApply(color)
    end
    ColorPicker.confirm = apply -- Enter

    local w = math.min(BOX_W, WIN_W - 20)
    local innerW = w - PAD * 2
    local squareSize = innerW - (BAR_W + BAR_GAP) * 2
    local boxH = TITLE_H + squareSize + PAD + PREVIEW_H + TEXT_H + SWATCH_H + PAD + BUTTON_H + PAD
    local box = overlay:addChild({
        pos = { (WIN_W - w) / 2, (WIN_H - boxH) / 2 },
        size = { w, boxH },
        bgColor = Widgets.CONTENT_BG,
        shapeType = ROUNDED,
        rounded = 5,
        interactive = true,
    })
    local title = box:addChild({ pos = { PAD, 0 }, size = { innerW, TITLE_H } })
    title:addAdaptedText(true, "Color", nil, nil, Widgets.FONT, nil, Widgets.TITLE_SCALE)

    -- saturation left to right, brightness bottom to top
    local square = box:addChild({ pos = { PAD, TITLE_H }, size = { squareSize, squareSize }, interactive = true })
    square:addCustomDisplay(true, function()
        local x, y, sw, sh = square.pos.x, square.pos.y, square.size.w, square.size.h
        local hr, hg, hb = hsvToRgb(h, 1, 1)
        drawStrips(x, y, sw, sh, false, function(t) set_color(1 + (hr - 1) * t, 1 + (hg - 1) * t, 1 + (hb - 1) * t, 1) end)
        drawStrips(x, y, sw, sh, true, function(t) set_color(0, 0, 0, t) end) -- value 1 at the top
        local m = px(8)
        drawMarker(x + s * sw - m / 2, y + (1 - v) * sh - m / 2, m, m)
    end)
    addDrag(square, function(fx, fy) s, v = fx, 1 - fy end)

    local hueBar = box:addChild({ pos = { PAD + squareSize + BAR_GAP, TITLE_H }, size = { BAR_W, squareSize },
        interactive = true })
    hueBar:addCustomDisplay(true, function()
        local x, y, bw, bh = hueBar.pos.x, hueBar.pos.y, hueBar.size.w, hueBar.size.h
        drawStrips(x, y, bw, bh, true, function(t)
            local r, g, b = hsvToRgb(t, 1, 1)
            set_color(r, g, b, 1)
        end)
        drawMarker(x, y + h * bh - 2, bw, 4)
    end)
    addDrag(hueBar, function(_, fy) h = math.min(fy, 0.9999) end) -- 1 would wrap to red

    local alphaBar = box:addChild({ pos = { PAD + squareSize + BAR_GAP * 2 + BAR_W, TITLE_H },
        size = { BAR_W, squareSize }, interactive = true })
    alphaBar:addCustomDisplay(true, function()
        local x, y, bw, bh = alphaBar.pos.x, alphaBar.pos.y, alphaBar.size.w, alphaBar.size.h
        drawChecker(x, y, bw, bh, math.floor(bw / 2))
        local r, g, b = hsvToRgb(h, s, v)
        drawStrips(x, y, bw, bh, true, function(t) set_color(r, g, b, 1 - t) end) -- opaque at the top
        drawMarker(x, y + (1 - alpha) * bh - 2, bw, 4)
    end)
    addDrag(alphaBar, function(_, fy) alpha = 1 - fy end)

    -- old | new over a checkerboard; clicking Old goes back to it
    local previewY = TITLE_H + squareSize + PAD
    local preview = box:addChild({ pos = { PAD, previewY }, size = { innerW, PREVIEW_H }, interactive = true })
    preview:addCustomDisplay(true, function()
        local x, y, pw, ph = preview.pos.x, preview.pos.y, preview.size.w, preview.size.h
        drawChecker(x, y, pw, ph, math.floor(ph / 3))
        local half = math.floor(pw / 2)
        set_color(old[1], old[2], old[3], old[4])
        draw_quad(x, y, half, ph)
        local c = current()
        set_color(c[1], c[2], c[3], c[4])
        draw_quad(x + half, y, pw - half, ph)
        -- x offsets are { from the left, from the right }
        local pad = px(6)
        preview:uiText("Old", { pad, pw - half + pad }, nil, Widgets.FONT, LEFTMID, Widgets.TEXT_SCALE_SMALL, nil, 0,
            textColor(old))
        preview:uiText("New", { half + pad, pad }, nil, Widgets.FONT, RIGHTMID, Widgets.TEXT_SCALE_SMALL, nil, 0,
            textColor(c))
    end)
    preview:addMouseUpHandler(function()
        if MOUSE_X < preview.pos.x + preview.size.w / 2 then
            h, s, v = rgbToHsv(old[1], old[2], old[3])
            alpha = old[4]
        end
    end)

    local values = box:addChild({ pos = { PAD, previewY + PREVIEW_H }, size = { innerW, TEXT_H } })
    values:addCustomDisplay(false, function()
        local c = current()
        local n = {}
        for i = 1, 4 do n[i] = math.floor(c[i] * 255 + 0.5) end
        values:uiText(string.format("R %d   G %d   B %d   A %d      #%02X%02X%02X", n[1], n[2], n[3], n[4],
            n[1], n[2], n[3]), nil, nil, Widgets.FONT, CENTERMID, Widgets.TEXT_SCALE_SMALL)
    end)

    -- palette slots and +
    local colors = MGE.Config.palette
    local gap = Widgets.GAP
    local slotW = (innerW - SWATCH_H - gap * PALETTE_SIZE) / PALETTE_SIZE
    local paletteY = previewY + PREVIEW_H + TEXT_H
    for i = 1, PALETTE_SIZE do
        local slot = box:addChild({ pos = { PAD + (i - 1) * (slotW + gap), paletteY }, size = { slotW, SWATCH_H },
            interactive = true })
        slot:addCustomDisplay(true, function()
            local x, y, sw, sh = slot.pos.x, slot.pos.y, slot.size.w, slot.size.h
            local c = colors[i]
            if not c then
                set_color(Widgets.BAR_COLOR[1], Widgets.BAR_COLOR[2], Widgets.BAR_COLOR[3], Widgets.BAR_COLOR[4])
                draw_quad(x, y, sw, sh)
                return
            end
            drawChecker(x, y, sw, sh, math.floor(sh / 3))
            set_color(c[1], c[2], c[3], c[4])
            draw_quad(x, y, sw, sh)
            if slot.hoverState ~= BTN_NONE then drawMarker(x + 2, y + 2, sw - 4, sh - 4) end
        end)
        slot:addMouseHandlers(nil, function()
            local c = colors[i]
            if not c then return end
            h, s, v = rgbToHsv(c[1], c[2], c[3])
            alpha = c[4]
        end, nil, function()
            if not colors[i] then return end
            table.remove(colors, i)
            MGE.Config.save()
        end)
    end
    local plus = Widgets.button(box, { x = PAD + innerW - SWATCH_H, y = paletteY, w = SWATCH_H, h = SWATCH_H }, "+",
        function()
            local result = ColorPicker.addToPalette(colors, current(), PALETTE_SIZE)
            if result == "added" then
                MGE.Config.save()
            elseif result == "full" then
                MGE.say("the palette is full: right click a color to remove it")
            end
        end)
    Widgets.popupBelow(plus, "Save the new color to the palette.\nOn a color: click uses it, right click removes it.")

    local buttons = box:addChild({ pos = { PAD, boxH - PAD - BUTTON_H }, size = { innerW, BUTTON_H } })
    -- Cancel on the left, like other backing-out buttons
    local list = { { label = TB_MENU_LOCALIZED.BUTTONCANCEL, onClick = close } }
    if options.onPickWorld then
        list[#list + 1] = { label = "Pick from world", onClick = function()
            close()
            options.onPickWorld()
        end }
    end
    list[#list + 1] = { label = "Apply", onClick = apply }
    Widgets.buttonRow(buttons, 0, BUTTON_H, list, Widgets.GAP)

    disable_camera_movement()
end

return ColorPicker
