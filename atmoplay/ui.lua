-- Atmo Play's window in MGE's look: Detail, Ghosts, Distant, Max draws and Quit, the current choices lit (nothing
-- redrawn per frame). The cross hides it behind a small "AP" button. Only atmoplay.lua loads this
local NS = ATMOPLAY_LOADING

---@class AtmoPlayUI
local UI = {
    W = 260,
    BAR_H = 28,
    ROW_H = 24,
    GAP = 2,
    PAD = 8,
    LABEL_W = 70,
    TEXT_SCALE = 0.6,
    LAUNCHER_W = 32, -- the "AP" button shown while the window is hidden
    window = nil, ---@type UIElement?
    launcher = nil, ---@type UIElement?
    pos = nil, ---@type number[]? where it was dragged to
    dragging = false, ---@type boolean the bar held (the camera's mouse movement is off)
}

---Where the window and its launcher go, kept on the screen
---@return number[]
function UI.position()
    local p = UI.pos or NS.Runtime.settings.uiPos or { 10, 120 }
    local x = math.max(0, math.min(p[1], (WIN_W or 1920) - UI.W))
    local y = math.max(0, math.min(p[2], (WIN_H or 1080) - UI.BAR_H))
    return { x, y }
end

local function mix(a, b, t)
    return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t, 1 }
end

---MGE's colors, mixed from the game's menu colors (they follow its theme)
local function colors()
    local d = TB_MENU_DEFAULT_DARKEST_COLOR
    local b = TB_MENU_DEFAULT_BG_COLOR
    return {
        bg = b, -- the buttons
        panel = { b[1] * 0.85, b[2] * 0.85, b[3] * 0.85, 1 }, -- darker, so the buttons stand out
        hover = mix(TB_MENU_DEFAULT_BG_COLOR, TB_MENU_DEFAULT_LIGHTER_COLOR, 0.4),
        active = mix(TB_MENU_DEFAULT_BG_COLOR, TB_MENU_DEFAULT_LIGHTEST_COLOR, 0.5),
        pressed = d,
        bar = { d[1] * 0.8, d[2] * 0.8, d[3] * 0.8, 1 },
    }
end

---A button as MGE makes one: the label without override, so the button keeps drawing its background and hover
local function button(parent, x, y, w, h, label, onClick, c, globalid)
    local opts = {
        pos = { x, y },
        size = { w, h },
        interactive = true,
        bgColor = c.bg,
        hoverColor = c.hover,
        pressedColor = c.pressed,
    }
    local btn
    if parent then
        btn = parent:addChild(opts, true)
    else
        opts.globalid = globalid
        btn = UIElement.new(opts)
    end
    btn:addAdaptedText(label, nil, nil, FONTS.LMEDIUM, CENTERMID, UI.TEXT_SCALE)
    btn:addMouseUpHandler(onClick)
    return btn
end

---Runs a setter, then lights the current choices
local function run(set, value)
    set(value)
    UI.refresh()
end

---A row: its label left, buttons sharing the rest, lit while get() is their value
---@param choices { [1]: string, [2]: any }[] label, value
local function choiceRow(parent, y, label, set, get, choices, c)
    local text = parent:addChild({ pos = { 0, y }, size = { UI.LABEL_W, UI.ROW_H } })
    text:addAdaptedText(true, label, nil, nil, FONTS.LMEDIUM, LEFTMID, UI.TEXT_SCALE)
    local x0 = UI.LABEL_W
    local w = (parent.size.w - x0 - UI.GAP * (#choices - 1)) / #choices
    for i, choice in ipairs(choices) do
        local value = choice[2]
        local btn = button(parent, x0 + (i - 1) * (w + UI.GAP), y, w, UI.ROW_H, choice[1],
            function() run(set, value) end, c)
        UI.lit[#UI.lit + 1] = { btn = btn, isOn = function() return get() == value end }
    end
end

---Builds the window (hidden until UI.show)
local function build()
    local c = colors()
    local Runtime = NS.Runtime
    local settings = Runtime.settings
    local rows = 4 -- detail, ghosts, far props, max draws; then quit
    local h = UI.BAR_H + UI.PAD + rows * (UI.ROW_H + UI.GAP) + UI.PAD + UI.ROW_H + UI.PAD
    local pos = UI.position()
    local window = UIElement.new({
        globalid = TB_MENU_HUB_GLOBALID,
        pos = { pos[1], pos[2] },
        size = { UI.W, h },
        bgColor = c.panel,
    })
    UI.window, UI.lit, UI.colors = window, {}, c

    -- the bar: drag it to move the window; the cross hides it
    local bar = window:addChild({
        pos = { 0, 0 },
        size = { UI.W, UI.BAR_H },
        interactive = true,
        bgColor = c.bar,
        hoverColor = c.bar,
        pressedColor = c.bar,
    })
    local title = bar:addChild({ pos = { UI.PAD, 0 }, size = { UI.W - UI.PAD - UI.BAR_H, UI.BAR_H } })
    title:addAdaptedText(true, "Atmo Play", nil, nil, FONTS.LMEDIUM, LEFTMID, 0.7)
    local function endDrag()
        enable_mouse_camera_movement()
        UI.dragging = false
        if UI.pos then NS.Runtime.setWindowPos(UI.pos[1], UI.pos[2]) end
    end
    bar:addMouseHandlers(function(_, x, y)
        disable_mouse_camera_movement()
        UI.dragging = true -- UI.close gives the camera's mouse back if killed mid-drag
        bar.pressedPos.x, bar.pressedPos.y = x - window.pos.x, y - window.pos.y
    end, endDrag, function(x, y)
        if bar.hoverState == BTN_DN then
            local nx = math.max(0, math.min(x - bar.pressedPos.x, WIN_W - window.size.w))
            local ny = math.max(0, math.min(y - bar.pressedPos.y, WIN_H - window.size.h))
            window:moveTo(nx, ny)
            UI.pos = { nx, ny }
        end
    end, nil, endDrag)
    TBMenu:spawnCloseButton(bar, { x = -UI.BAR_H, y = 0, w = UI.BAR_H, h = UI.BAR_H }, function() run(Runtime.setWindow, false) end,
        { default = c.bar, hover = c.hover, pressed = c.pressed, ui = { 1, 1, 1, 1 } })

    local content = window:addChild({
        pos = { UI.PAD, UI.BAR_H + UI.PAD },
        size = { UI.W - UI.PAD * 2, h - UI.BAR_H - UI.PAD * 2 },
    })
    local y = 0
    choiceRow(content, y, "Detail", Runtime.setFlight, function() return settings.flight end,
        { { "Low", "simple" }, { "Medium", "shapes" }, { "High", "full" } }, c)
    y = y + UI.ROW_H + UI.GAP
    choiceRow(content, y, "Ghosts", Runtime.setGhosts, function() return settings.ghosts end,
        { { "On", true }, { "Off", false } }, c)
    y = y + UI.ROW_H + UI.GAP
    choiceRow(content, y, "Distant", Runtime.setFarProps, function() return settings.pauseFar end,
        { { "Move", false }, { "Pause", true } }, c)
    y = y + UI.ROW_H + UI.GAP
    -- the nearest this many atmo shapes a frame: steadier fps on big maps
    local draws = {}
    for i, n in ipairs({ 5000, 1000, 500 }) do draws[i] = { tostring(n), n } end
    choiceRow(content, y, "Max draws", Runtime.setMaxDraws, function() return settings.maxDraws end, draws, c)
    y = y + UI.ROW_H + UI.GAP + UI.PAD
    button(content, 0, y, content.size.w, UI.ROW_H, "Quit Atmo Play", function() run(Runtime.stop) end, c)

    window:hide(true)
end

---The small "AP" button that opens the window
local function buildLauncher()
    local pos = UI.position()
    UI.launcher = button(nil, pos[1], pos[2], UI.LAUNCHER_W, UI.ROW_H, "AP",
        function() run(NS.Runtime.setWindow, true) end, UI.colors or colors(), TB_MENU_HUB_GLOBALID)
    UI.launcher:hide(true)
end

local function alive(e) return e ~= nil and not e.destroyed end

---The current choices lit, the launcher shown only while the window is hidden
function UI.refresh()
    if UI.closed then return end -- Atmo Play stopped
    local c = UI.colors
    for _, l in ipairs(UI.lit or {}) do
        if alive(l.btn) then l.btn.bgColor = l.isOn() and c.active or c.bg end
    end
    if not UI.shown() then
        if not alive(UI.launcher) then pcall(buildLauncher) end
        if alive(UI.launcher) then
            local pos = UI.position()
            UI.launcher:moveTo(pos[1], pos[2])
            UI.launcher:show(true)
        end
    elseif alive(UI.launcher) then
        UI.launcher:hide(true)
    end
end

---@return boolean
function UI.shown()
    return alive(UI.window) and UI.window.displayed == true
end

function UI.show()
    UI.closed = false
    if not alive(UI.window) then
        local ok, err = pcall(build)
        if not ok then
            echo("^04[Atmo Play] ^07the window couldn't open: " .. tostring(err))
            UI.window = nil
            return
        end
    end
    UI.window:show(true)
    UI.refresh()
end

function UI.hide()
    if alive(UI.window) then UI.window:hide(true) end
    UI.refresh()
end

---Atmo Play stopping: the window and the launcher go
function UI.close()
    if UI.dragging then -- killed mid-drag: no mouse-up comes
        UI.dragging = false
        pcall(enable_mouse_camera_movement)
    end
    for _, e in ipairs({ UI.window, UI.launcher }) do
        if alive(e) then pcall(function() e:kill() end) end
    end
    UI.window, UI.launcher, UI.lit, UI.closed = nil, nil, nil, true
end

NS.UI = UI
return UI
