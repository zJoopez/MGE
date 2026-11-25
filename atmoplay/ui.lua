-- Atmo Play's window: everything a player sets, in MGE's look (a plain UIElement panel with a dark bar to drag it by,
-- buttons lit for the current choice): Detail (the flight level), Ghosts, Far props and Quit, set through the runtime's silent setters (no chat
-- command or message for any of them). Fixed labels, nothing drawn or refreshed per frame: the lit buttons change on a
-- click or when it's shown. The bar's cross hides it behind a small "AP" button where it was, which opens it again;
-- atmoplay.cfg `ui` keeps whether it's open. Only atmoplay.lua loads this file (MGE has its own window)
local NS = ATMOPLAY_LOADING -- the namespace the loader gives (Atmo Play's ATMOPLAY)

---@class AtmoPlayUI
local UI = {
    W = 260,
    BAR_H = 28,
    ROW_H = 24,
    GAP = 2,
    PAD = 8,
    LABEL_W = 70,
    TEXT_SCALE = 0.6,
    LAUNCHER_W = 32, -- the "AP" button: small, always there while the window is hidden
    window = nil, ---@type UIElement?
    launcher = nil, ---@type UIElement?
    pos = nil, ---@type number[]? where it was dragged to (kept while the game runs)
}

---Where the window (and its launcher) goes: where it was dragged to this session, else atmoplay.cfg's, else the
---default; kept on the screen
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

---MGE's colors (mge/ui/widgets.lua), mixed from the game's menu colors so they follow its theme
local function colors()
    local d = TB_MENU_DEFAULT_DARKEST_COLOR
    return {
        bg = TB_MENU_DEFAULT_BG_COLOR,
        hover = mix(TB_MENU_DEFAULT_BG_COLOR, TB_MENU_DEFAULT_LIGHTER_COLOR, 0.4),
        active = mix(TB_MENU_DEFAULT_BG_COLOR, TB_MENU_DEFAULT_LIGHTEST_COLOR, 0.5),
        pressed = d,
        bar = { d[1] * 0.8, d[2] * 0.8, d[3] * 0.8, 1 },
    }
end

---A button as MGE makes one: the label added without override, so the button still draws its own background,
---hover and lit color (with override the text replaced all of it: the buttons showed as bare text)
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

---A row: its label left, buttons sharing the rest. choices: { label, setter, value, isOn() }
local function choiceRow(parent, y, label, choices, c)
    local text = parent:addChild({ pos = { 0, y }, size = { UI.LABEL_W, UI.ROW_H } })
    text:addAdaptedText(true, label, nil, nil, FONTS.LMEDIUM, LEFTMID, UI.TEXT_SCALE) -- a plain label: override is fine
    local x0 = UI.LABEL_W
    local w = (parent.size.w - x0 - UI.GAP * (#choices - 1)) / #choices
    for i, choice in ipairs(choices) do
        local btn = button(parent, x0 + (i - 1) * (w + UI.GAP), y, w, UI.ROW_H, choice[1],
            function() run(choice[2], choice[3]) end, c)
        UI.lit[#UI.lit + 1] = { btn = btn, isOn = choice[4] }
    end
end

---Builds the window (hidden until UI.show)
local function build()
    local c = colors()
    local Runtime = NS.Runtime
    local settings = Runtime.settings
    local rows = 3 -- detail, ghosts, far props; then quit
    local h = UI.BAR_H + UI.PAD + rows * (UI.ROW_H + UI.GAP) + UI.PAD + UI.ROW_H + UI.PAD
    local pos = UI.position()
    local window = UIElement.new({
        globalid = TB_MENU_HUB_GLOBALID,
        pos = { pos[1], pos[2] },
        size = { UI.W, h },
        bgColor = c.bg,
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
    bar:addMouseHandlers(function(_, x, y)
        disable_mouse_camera_movement()
        bar.pressedPos.x, bar.pressedPos.y = x - window.pos.x, y - window.pos.y
    end, function()
        enable_mouse_camera_movement()
        if UI.pos then NS.Runtime.setWindowPos(UI.pos[1], UI.pos[2]) end -- a drag ended: kept in atmoplay.cfg
    end, function(x, y)
        if bar.hoverState == BTN_DN then
            local nx = math.max(0, math.min(x - bar.pressedPos.x, WIN_W - window.size.w))
            local ny = math.max(0, math.min(y - bar.pressedPos.y, WIN_H - window.size.h))
            window:moveTo(nx, ny)
            UI.pos = { nx, ny }
        end
    end, nil, function()
        enable_mouse_camera_movement()
        if UI.pos then NS.Runtime.setWindowPos(UI.pos[1], UI.pos[2]) end -- kept in atmoplay.cfg
    end)
    TBMenu:spawnCloseButton(bar, { x = -UI.BAR_H, y = 0, w = UI.BAR_H, h = UI.BAR_H }, function() run(Runtime.setWindow, false) end,
        { default = c.bar, hover = c.hover, pressed = c.pressed, ui = { 1, 1, 1, 1 } })

    local content = window:addChild({
        pos = { UI.PAD, UI.BAR_H + UI.PAD },
        size = { UI.W - UI.PAD * 2, h - UI.BAR_H - UI.PAD * 2 },
    })
    local y = 0
    -- how props fly while no pool object carries them (by how much work the computer can take): "Detail" to a player
    choiceRow(content, y, "Detail", {
        { "Low", Runtime.setFlight, "simple", function() return settings.flight == "simple" end },
        { "Medium", Runtime.setFlight, "shapes", function() return settings.flight == "shapes" end },
        { "High", Runtime.setFlight, "full", function() return settings.flight == "full" end },
    }, c)
    y = y + UI.ROW_H + UI.GAP
    -- the flying props' move predictions while a turn waits
    choiceRow(content, y, "Ghosts", {
        { "On", Runtime.setGhosts, true, function() return settings.ghosts end },
        { "Off", Runtime.setGhosts, false, function() return not settings.ghosts end },
    }, c)
    y = y + UI.ROW_H + UI.GAP
    -- flying props far from every player: all move, or those far pause until someone comes near (less work)
    choiceRow(content, y, "Far props", {
        { "Move", Runtime.setFarProps, false, function() return not settings.pauseFar end },
        { "Pause", Runtime.setFarProps, true, function() return settings.pauseFar end },
    }, c)
    y = y + UI.ROW_H + UI.GAP + UI.PAD
    -- stops Atmo Play: the player's own atmo back
    button(content, 0, y, content.size.w, UI.ROW_H, "Quit Atmo Play", function() run(Runtime.stop) end, c)

    window:hide(true)
end

---The small "AP" button that opens the window, where the window is (it shows only while the window is hidden)
local function buildLauncher()
    local pos = UI.position()
    UI.launcher = button(nil, pos[1], pos[2], UI.LAUNCHER_W, UI.ROW_H, "AP",
        function() run(NS.Runtime.setWindow, true) end, UI.colors or colors(), TB_MENU_HUB_GLOBALID)
    UI.launcher:hide(true)
end

local function alive(e) return e ~= nil and not e.destroyed end

---The current choices lit, the launcher shown only while the window is hidden
function UI.refresh()
    if UI.closed then return end -- Atmo Play stopped (Quit): nothing comes back
    local c = UI.colors
    for _, l in ipairs(UI.lit or {}) do
        if alive(l.btn) then l.btn.bgColor = l.isOn() and c.active or c.bg end
    end
    if not UI.shown() then
        if not alive(UI.launcher) then pcall(buildLauncher) end
        if alive(UI.launcher) then
            local pos = UI.position()
            UI.launcher:moveTo(pos[1], pos[2]) -- where the window was
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
    UI.refresh() -- the launcher, if it's on
end

---Atmo Play stopping: the window and the launcher go
function UI.close()
    for _, e in ipairs({ UI.window, UI.launcher }) do
        if alive(e) then pcall(function() e:kill() end) end
    end
    UI.window, UI.launcher, UI.lit, UI.closed = nil, nil, nil, true
end

NS.UI = UI
return UI
