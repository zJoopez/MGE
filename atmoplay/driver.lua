-- Moves one pool in the world (docs/atmo-play-plan.md, part 3): Atmo Play's runtime drives the loaded
-- playable mod's pool with it, MGE's test mode the pool of the map being edited. When moves happen is what
-- makes replays work by themselves (measured, see the plan):
--   * the pool is placed in match_begin: recorded under FRAME 0
--   * in a fight it's moved between physics steps (draw2d), once per new match frame: recorded under the
--     step it affects, so the replay (the game's own EOBJ playback, cached or not) is exact. Moves made in
--     enter_frame are recorded one step late; moving objects during a replay crashed the game at its end
--   * replays: nothing is moved. Back in a fight (replay view left, a replay edited), or when the frame went
--     back, every pool object is set again
-- Flag and bounce are set only when they differ from what was last set; a reset forgets that (the game puts
-- objects back to their file values when a fight starts).

local NS = ATMOPLAY_LOADING -- the namespace the loader gives (Atmo Play's ATMOPLAY, MGE's MGE.AtmoPlay)

local Pool = NS.Pool

---@class AtmoPlayDriver
---@field pool AtmoPlayPoolState
---@field lastFrame integer? the match frame the pool was last moved for, nil after a reset
---@field wasReplay boolean the last draw was in a replay: back in a fight, the pool is set again
---@field show boolean debug: pool objects visible (green) where they stand in for an atmo object
---@field hold boolean debug: the pool isn't moved at all
---@field onDrive (fun(changes: AtmoPlayPoolChange[], ws: table))? called before a step's moves are made (debug log)
---@field steps integer frames driven, for the status
---@field stepTime number ms in all
---@field worstStep number ms, the slowest frame

---@class AtmoPlayDriverModule
local Driver = {
    PARK_Z = -100000,
    STATIC_FLAG = 8,
}

local clock = os and os.clock or function() return 0 end

---@param frame number[][]
---@return table MatrixTB (set_obj_rot_m), as MGE's Highlight.toMatrixTB / Utils3D.MatrixToMatrixTB build it
local function matrixTB(frame)
    return {
        r0 = frame[1][1], r1 = frame[1][2], r2 = frame[1][3], r3 = 0,
        r4 = frame[2][1], r5 = frame[2][2], r6 = frame[2][3], r7 = 0,
        r8 = frame[3][1], r9 = frame[3][2], r10 = frame[3][3], r11 = 0,
    }
end

---@param flag integer
---@return integer the flag with the static bit on (a pool object must stay static)
local function staticFlag(flag)
    if math.floor(flag / Driver.STATIC_FLAG) % 2 == 1 then return flag end
    return flag + Driver.STATIC_FLAG
end

---Puts a pool object on a collider: position, size, rotation, and the collider's flag and bounce (the pool
---object's own when the collider has none)
---@param d AtmoPlayDriver
---@param entry AtmoPlayPoolEntry
---@param c AtmoPlayCollider
local function place(d, entry, c)
    local id = entry.id - 1
    c.matrixTB = c.matrixTB or matrixTB(c.frame)
    set_obj_pos(id, c.pos[1], c.pos[2], c.pos[3])
    set_obj_sides(id, c.sides[1], c.sides[2], c.sides[3])
    set_obj_rot_m(id, c.matrixTB)
    local flag = staticFlag(c.flag or entry.baseFlag or Driver.STATIC_FLAG)
    if entry.flag ~= flag then
        pcall(set_obj_flag, id, flag)
        entry.flag = flag
    end
    local bounce = c.bounce or entry.baseBounce
    if bounce and entry.bounce ~= bounce then
        pcall(set_obj_bounce, id, bounce)
        entry.bounce = bounce
    end
    if d.show then
        set_obj_color(id, 0.3, 1, 0.4, 0.6)
        set_obj_vis(id, 1)
    end
end

---@param d AtmoPlayDriver
---@param entry AtmoPlayPoolEntry
local function park(d, entry)
    local id = entry.id - 1
    set_obj_pos(id, entry.id, 0, Driver.PARK_Z)
    if d.show then set_obj_vis(id, 0) end
end

---Every player's center (the average of its body parts), the pool rule's input
---@return number[][]
local function playerCenters()
    local centers = {}
    local count = get_world_state().num_players or 2
    for player = 0, count - 1 do
        local s, n = { 0, 0, 0 }, 0
        for _, part in pairs(BODYPARTS) do
            local ok, info = pcall(get_body_info, player, part)
            if ok and info and info.pos then
                s[1], s[2], s[3], n = s[1] + info.pos.x, s[2] + info.pos.y, s[3] + info.pos.z, n + 1
            end
        end
        if n > 0 then centers[#centers + 1] = { s[1] / n, s[2] / n, s[3] / n } end
    end
    return centers
end

---A driver for a pool whose objects are in the world now (right after /lm): each one's own flag and bounce
---are read there (what it gets for colliders without those lines)
---@param pool AtmoPlayPoolState
---@return AtmoPlayDriver
function Driver.new(pool)
    for _, entry in ipairs(pool.entries) do
        local okFlag, flag = pcall(get_obj_flag, entry.id - 1)
        local okBounce, bounce = pcall(get_obj_bounce, entry.id - 1)
        entry.baseFlag = okFlag and tonumber(flag) or Driver.STATIC_FLAG
        entry.baseBounce = okBounce and tonumber(bounce) or nil
    end
    return { pool = pool, lastFrame = nil, wasReplay = false, show = false, hold = false, steps = 0, stepTime = 0,
        worstStep = 0 }
end

---Start over: the next move assigns from scratch and sets every pool object, flag and bounce included
---@param d AtmoPlayDriver
function Driver.reset(d)
    Pool.reset(d.pool)
    for _, entry in ipairs(d.pool.entries) do entry.flag, entry.bounce = nil, nil end
    d.lastFrame = nil
end

---Moves the pool for the frame the fight is at
---@param d AtmoPlayDriver
---@param ws table get_world_state()
function Driver.drive(d, ws)
    local frame = ws.match_frame
    -- the frame went back (a replay edited and played on from earlier): assign from scratch
    if d.lastFrame ~= nil and frame < d.lastFrame then Driver.reset(d) end
    d.lastFrame = frame
    if d.hold then
        if d.onDrive then d.onDrive({}, ws) end
        return
    end
    local start = clock()
    local changes = Pool.step(d.pool, playerCenters())
    if d.onDrive then d.onDrive(changes, ws) end
    for _, change in ipairs(changes) do
        if change.collider then place(d, change.entry, change.collider) else park(d, change.entry) end
    end
    local took = (clock() - start) * 1000
    d.steps, d.stepTime = d.steps + 1, d.stepTime + took
    if took > d.worstStep then d.worstStep = took end
end

---match_begin (inside /lm and open_replay): a fight places the pool now, a replay has it in its FRAME 0
---@param d AtmoPlayDriver
---@param ws table get_world_state()
function Driver.matchBegin(d, ws)
    Driver.reset(d)
    d.wasReplay = ws.replay_mode > 0
    if not d.wasReplay then Driver.drive(d, ws) end
end

---draw2d (between physics steps): in a fight, the pool follows the players once per new match frame
---@param d AtmoPlayDriver
---@param ws table get_world_state()
function Driver.draw(d, ws)
    if ws.replay_mode > 0 then
        d.wasReplay = true -- replays play the recorded pool moves by themselves
        return
    end
    if d.wasReplay then
        d.wasReplay = false
        Driver.reset(d) -- back in a fight: set every pool object again
    end
    if ws.match_frame ~= d.lastFrame then Driver.drive(d, ws) end
end

---Debug: pool objects visible (green) where they stand in for an atmo object, or hidden again
---@param d AtmoPlayDriver
---@param on boolean
function Driver.setShow(d, on)
    d.show = on
    for _, entry in ipairs(d.pool.entries) do set_obj_vis(entry.id - 1, 0) end
    Driver.reset(d) -- every pool object is set again, now (in)visible
end

---@param d AtmoPlayDriver
---@return integer pool objects standing in for a collider now
function Driver.active(d)
    local active = 0
    for _, entry in ipairs(d.pool.entries) do
        if entry.target then active = active + 1 end
    end
    return active
end

NS.Driver = Driver
return Driver
