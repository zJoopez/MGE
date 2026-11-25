-- Shared button helpers so every button looks the same and rows line up with the window edges

---@class Widgets
local Widgets = {}

---@class WidgetRect
---@field x number
---@field y number
---@field w number
---@field h number

-- MGE's own size factor on top of the game's GUI scale (Settings > UI size; a global so the restart
-- that applies it keeps it)
Widgets.UI_SCALE = tonumber(MGE_UI_SCALE) or 1.3
Widgets.UI_SCALES = { 1, 1.15, 1.3, 1.5, 1.75 } -- the choices Settings offers

---A size in MGE's layout units as pixels at UI_SCALE, whole pixels
---@param n number
---@return number
function Widgets.px(n)
    return math.floor(n * Widgets.UI_SCALE + 0.5)
end

-- the number fields' plain font reads better small than the game's bold one
Widgets.FONT = FONTS.LMEDIUM

-- text sizes (adapted text only shrinks to fit)
Widgets.TEXT_SCALE = 0.5 * Widgets.UI_SCALE
Widgets.TEXT_SCALE_SMALL = 0.45 * Widgets.UI_SCALE -- inputs, hints, second columns
Widgets.TAB_TEXT_SCALE = 0.42 * Widgets.UI_SCALE
Widgets.BUTTON_TEXT_SCALE = 0.45 * Widgets.UI_SCALE
Widgets.TITLE_SCALE = 0.7 * Widgets.UI_SCALE -- overlay titles
Widgets.ROW_H = Widgets.px(24) -- editor rows and tabs
Widgets.PANEL_ROWS = 9 -- every editor panel's height in rows (the tallest: Generate)
Widgets.LIST_ROW_H = Widgets.px(20)
-- space between cells in grids and button rows
Widgets.GAP = 2
-- each cell's free margin: half the gap (number fields sit this far in, buttons match)
Widgets.INSET = Widgets.GAP / 2

---A color between two others (t = 0: a, 1: b), opaque
---@param a number[]
---@param b number[]
---@param t number
---@return number[]
function Widgets.mix(a, b, t)
    return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t, 1 }
end

-- highlights mixed from the game's menu colors, so they follow its theme
Widgets.HOVER_COLOR = Widgets.mix(TB_MENU_DEFAULT_BG_COLOR, TB_MENU_DEFAULT_LIGHTER_COLOR, 0.4)
Widgets.SELECTED_COLOR = Widgets.mix(TB_MENU_DEFAULT_BG_COLOR, TB_MENU_DEFAULT_LIGHTEST_COLOR, 0.5)
-- toggles that are on: same as selected, so everything chosen reads alike
Widgets.ACTIVE_COLOR = Widgets.SELECTED_COLOR

---The menu's darkest color at a share of its brightness
---@param share number
---@return number[]
local function darkest(share)
    local c = TB_MENU_DEFAULT_DARKEST_COLOR
    return { c[1] * share, c[2] * share, c[3] * share, 1 }
end
-- bars, darker than the panel
Widgets.BAR_COLOR = darkest(0.8)
-- content areas (lists, editor panel, overlays): between panel and bar
Widgets.CONTENT_BG = darkest(0.9)

---@class WidgetStyle
---@field bg number[]
---@field hover number[]
---@field pressed number[]

---MGE's button colors everywhere: the window's red on the dark areas
---@type WidgetStyle
Widgets.STYLE = {
    bg = TB_MENU_DEFAULT_BG_COLOR,
    hover = Widgets.HOVER_COLOR,
    pressed = TB_MENU_DEFAULT_DARKEST_COLOR,
}
Widgets.PANEL_STYLE = Widgets.STYLE

---Tab panel color: darkens the window; the active tab uses it too
Widgets.TAB_PANEL_COLOR = { 0, 0, 0, 0.15 }
---TAB_PANEL_COLOR over the window color, solid: for parts that must cover what's behind them
Widgets.TAB_PANEL_SOLID = {
    TB_MENU_DEFAULT_BG_COLOR[1] * (1 - Widgets.TAB_PANEL_COLOR[4]),
    TB_MENU_DEFAULT_BG_COLOR[2] * (1 - Widgets.TAB_PANEL_COLOR[4]),
    TB_MENU_DEFAULT_BG_COLOR[3] * (1 - Widgets.TAB_PANEL_COLOR[4]),
    1,
}

---Standard MGE button
---@param parent UIElement
---@param rect WidgetRect position relative to parent
---@param label string|fun(): string function labels are re-read every frame
---@param onClick function?
---@param textScale number? defaults to Widgets.BUTTON_TEXT_SCALE
---@param style WidgetStyle? defaults to Widgets.STYLE
---@return UIElement
function Widgets.button(parent, rect, label, onClick, textScale, style)
    textScale = textScale or Widgets.BUTTON_TEXT_SCALE
    style = style or Widgets.STYLE
    local btn = parent:addChild({
        pos = { rect.x, rect.y },
        size = { rect.w, rect.h },
        interactive = true,
        bgColor = style.bg,
        hoverColor = style.hover,
        pressedColor = style.pressed,
    }, true)
    if type(label) == "function" then
        btn:addCustomDisplay(false, function()
            btn:uiText(label(), nil, nil, Widgets.FONT, CENTERMID, textScale, nil, nil, nil)
        end)
    elseif label ~= "" then -- "" for icon buttons
        btn:addAdaptedText(label, nil, nil, Widgets.FONT, CENTERMID, textScale, nil, nil)
    end
    if onClick then btn:addMouseUpHandler(onClick) end
    return btn
end

---Standard MGE button showing an image instead of text, the image is a square centered in the button
---@param parent UIElement
---@param rect WidgetRect position relative to parent
---@param image string texture path, "../textures/..." for game textures or relative to data/script
---@param onClick function?
---@param style WidgetStyle?
---@return UIElement
function Widgets.iconButton(parent, rect, image, onClick, style)
    local btn = Widgets.button(parent, rect, "", onClick, nil, style)
    local size = math.min(rect.w, rect.h) - 6
    Widgets.trackImage(btn:addChild({
        pos = { (rect.w - size) / 2, (rect.h - size) / 2 },
        size = { size, size },
        bgImage = image,
    }), image)
    return btn
end

-- A graphics reload (resolution_changed) invalidates loaded texture ids, garbling icons, so image
-- elements are tracked and reload their images then. Weak keys: killed elements drop out
---@type table<UIElement, string>
local trackedImages = setmetatable({}, { __mode = "k" })

---Tracks an image element for reloading after a graphics reload
---@param element UIElement made with bgImage = image
---@param image string the same path
---@return UIElement element
function Widgets.trackImage(element, image)
    trackedImages[element] = image
    return element
end

---Reloads every tracked image (the old ids aren't unloaded: they're no longer those images)
function Widgets.reloadImages()
    for element, image in pairs(trackedImages) do
        if element.destroyed then
            trackedImages[element] = nil
        else
            element.bgImage = nil
            element:updateImage(image, nil, true)
        end
    end
end

---@type fun()[] called after a graphics reload, window size or GUI scale change
Widgets.onScreenChanged = {}

add_hook("resolution_changed", MGE.hookname, function()
    Widgets.reloadImages()
    for _, callback in ipairs(Widgets.onScreenChanged) do pcall(callback) end
end)

---@class WidgetRowButton
---@field label string|fun(): string text; for icon buttons the hover name
---@field icon string? image shown instead of the label
---@field wide boolean? icon buttons are square unless wide
---@field onClick function?
---@field popupLeft boolean? hover name opens to the left (Widgets.popupBelowLeft)

---Hover popup under its element, right edges lined up (near the screen's right edge the game's own
---placement split the popup's text from its background)
---@param element UIElement
---@param message string
---@return UIElement? popup nil on mobile (the game shows its own)
function Widgets.popupBelowLeft(element, message)
    local popup = TBMenu:displayPopup(element, message) ---@type UIElement?
    if popup then popup:moveTo(-popup.size.w, element.size.h + 4) end -- negative x: from the right edge
    return popup
end

---Hover popup under its element (the game's own can cover the button), kept on screen
---@param element UIElement
---@param message string
---@return UIElement? popup nil on mobile (the game shows its own)
function Widgets.popupBelow(element, message)
    local popup = TBMenu:displayPopup(element, message) ---@type UIElement?
    if not popup then return nil end
    local gap, margin = 4, 10
    -- from the element's top left (element.pos is current, the popup's isn't after a move)
    local x, y = 0.0, element.size.h + gap ---@type number, number
    local overflow = element.pos.x + popup.size.w - (WIN_W - margin)
    if overflow > 0 then x = -overflow end
    if element.pos.y + y + popup.size.h > WIN_H - margin then y = -(popup.size.h + gap) end
    -- as a shift from 0: a negative position set directly counts from the right / bottom edge
    popup:moveTo(0, 0)
    popup:moveTo(x, y, true)
    return popup
end

---Esc in an overlay's text field closes the overlay (a focused field takes keys before MGE's hook)
---@param field UIElement text field inside an MGE overlay
function Widgets.closeOnEscape(field)
    field:addKeyboardHandlers(function(key)
        if key == 27 and MGE and MGE.closeTopOverlay then MGE.closeTopOverlay() end
    end)
end

---Runs func every frame before the element draws, chained after what's there (hover popups use the
---same single slot)
---@param element UIElement
---@param func fun()
function Widgets.addDrawBefore(element, func)
    local previous = element.customDisplayBefore
    element:addCustomDisplay(false, function(...)
        if previous then previous(...) end
        func()
    end, true)
end

---Buttons filling the parent's width: icon buttons are square (unless wide) with their label on hover,
---the others share the rest
---@param parent UIElement
---@param y number
---@param h number
---@param buttons WidgetRowButton[]
---@param gap number space between buttons
---@param textScale number?
---@param style WidgetStyle?
---@return UIElement[]
function Widgets.buttonRow(parent, y, h, buttons, gap, textScale, style)
    local squareCount = 0
    for _, info in ipairs(buttons) do
        if info.icon and not info.wide then squareCount = squareCount + 1 end
    end
    local sharedCount = #buttons - squareCount
    local sharedW = sharedCount > 0 and (parent.size.w - gap * (#buttons - 1) - squareCount * h) / sharedCount or 0
    local created = {}
    local x = 0
    for i, info in ipairs(buttons) do
        local w = (info.icon and not info.wide) and h or sharedW
        local rect = { x = x, y = y, w = w, h = h }
        if info.icon then
            created[i] = Widgets.iconButton(parent, rect, info.icon, info.onClick, style)
            local label = info.label
            if type(label) == "string" and label ~= "" then
                local place = info.popupLeft and Widgets.popupBelowLeft or Widgets.popupBelow
                place(created[i], label)
            end
        else
            created[i] = Widgets.button(parent, rect, info.label, info.onClick, textScale, style)
        end
        x = x + w + gap
    end
    return created
end

---Removes an element and its descendants from toriui's UIKeyboardHandler. kill() only removes the
---focused one, so rebuilt UI piled up dead entries that toriui walks on every key and click
---@param element UIElement
function Widgets.releaseKeyboard(element)
    if not UIKeyboardHandler or not element then return end
    local owned = { [element] = true }
    local function collect(e)
        for _, c in ipairs(e.child or {}) do
            owned[c] = true
            collect(c)
        end
    end
    collect(element)
    for i = #UIKeyboardHandler, 1, -1 do
        local v = UIKeyboardHandler[i]
        if owned[v] then
            if v.menuKeyboardId then v:disableMenuKeyboard() end
            table.remove(UIKeyboardHandler, i)
        end
    end
end

---Destroys an element's children (kill(true)) without leaving them in toriui's keyboard list
---@param element UIElement
function Widgets.clearChildren(element)
    for _, c in ipairs(element.child or {}) do Widgets.releaseKeyboard(c) end
    element:kill(true)
end

---Round "?" icon with a hover explanation (like the game's mods menu), opening to its right
---@param parent UIElement
---@param x number negative values count from the parent's right edge
---@param y number
---@param size number
---@param message string
---@param mark string? icon text, defaults to "?"
---@param style WidgetStyle? bg color from the style, defaults to Widgets.STYLE
---@return UIElement
function Widgets.helpIcon(parent, x, y, size, message, mark, style)
    style = style or Widgets.STYLE
    local icon = parent:addChild({
        pos = { x, y },
        size = { size, size },
        bgColor = style.bg,
        hoverColor = style.hover,
        pressedColor = style.pressed,
        interactive = true,
        shapeType = ROUNDED,
        rounded = size,
    })
    icon:addChild({}):addAdaptedText(true, mark or "?", nil, nil, Widgets.FONT, nil, Widgets.TEXT_SCALE)
    local popup = TBMenu:displayHelpPopup(icon, message, nil, true) -- true: our own mark
    if popup then
        popup:moveTo(size + 5, (size - popup.size.h) / 2, true)
    end
    return icon
end

---True over MGE's window or any interactive UI: world clicks and zoom ignore those
---@param x number
---@param y number
---@return boolean
function Widgets.isMouseOverUI(x, y)
    local window = MGE.Main and MGE.Main.window
    if window and window.displayed and x >= window.pos.x and x <= window.pos.x + window.size.w
        and y >= window.pos.y and y <= window.pos.y + window.size.h then
        return true
    end
    -- toriui's own button test, covering popups and other menus
    for _, element in ipairs(UIMouseHandler or {}) do
        if not element.clickThrough and element:shouldReceiveInput()
            and x > element.pos.x and x < element.pos.x + element.size.w
            and y > element.pos.y and y < element.pos.y + element.size.h then
            return true
        end
    end
    return false
end

-- footer info lines
Widgets.INFO_HEIGHT = Widgets.px(18)
local INFO_MAX_SCALE = 0.7 * Widgets.UI_SCALE

---Small info text (default centered), replacing the element's previous text
---@param element UIElement
---@param text string
---@param align UIElementTextAlign? default CENTERMID
function Widgets.infoText(element, text, align)
    element:addAdaptedText(true, text, nil, nil, FONTS.SMALL, align or CENTERMID, INFO_MAX_SCALE)
end

MGE.Widgets = Widgets
return Widgets
