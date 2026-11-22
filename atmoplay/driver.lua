-- Moves one pool in the world (docs/atmo-play-plan.md, part 3): Atmo Play's runtime drives the loaded
-- playable mod's pool with it, MGE's test mode the pool of the map being edited. When moves happen is what
-- makes replays work by themselves (measured, see the plan):
--   * the pool is placed in match_begin: recorded under FRAME 0
--   * in a fight it's moved between physics steps (draw2d), once per new match frame: recorded under the
--     step it affects, so the replay (the game's own EOBJ playback, cached or not) is exact. Moves made in
--     enter_frame are recorded one step late; moving objects during a replay crashed the game at its end
--   * replays: nothing is moved. Back in a fight (replay view left, a replay edited), or when the frame went
--     back, every pool object is set again
-- Flag and bounce are never set: each pool object is written with its group's (Colliders.groupKey), as
-- replays don't record them.

local NS = ATMOPLAY_LOADING -- the namespace the loader gives (Atmo Play's ATMOPLAY, MGE's MGE.AtmoPlay)

local Pool = NS.Pool

---@class AtmoPlayDriver
---@field pool AtmoPlayPoolState
---@field lastFrame integer? the match frame the pool was last moved for, nil after a reset
---@field wasReplay boolean the last draw was in a replay: back in a fight, the pool is set again
---@field onDrive (fun(changes: AtmoPlayPoolChange[], ws: table))? called before a step's moves are made (the dev debug log)
---@field moreCenters (fun(): number[][])? more points to cover than the players' centers (carried props)
---@field follow integer[]? 0-based ids of the mod's own dynamic objects: the pool covers them too
---@field fromFrame integer nothing is moved before this match frame (Driver.FIRST_FRAME)

---@class AtmoPlayDriverModule
local Driver = {
    PARK_Z = -100000,
    STATIC_FLAG = 8,
    -- The pools aren't moved before this match frame. R before the first move replays a fight with nothing
    -- recorded, and the game puts every object moved so far at 0,0,0 there: a mod's pools placed in
    -- match_begin all landed at the origin, the props' dynamic objects inside the static ones, and the game
    -- crashed (owo, 2026-11-21; RPH saw the same teleport). Frame 0 -> 1 is one physics step without them
    FIRST_FRAME = 1,
}

---@param frame number[][]
---@return table MatrixTB (set_obj_rot_m), as MGE's Highlight.toMatrixTB / Utils3D.MatrixToMatrixTB build it
local function matrixTB(frame)
    return {
        r0 = frame[1][1], r1 = frame[1][2], r2 = frame[1][3], r3 = 0,
        r4 = frame[2][1], r5 = frame[2][2], r6 = frame[2][3], r7 = 0,
        r8 = frame[3][1], r9 = frame[3][2], r10 = frame[3][3], r11 = 0,
    }
end
Driver.matrixTB = matrixTB -- dynamics.lua's props too

---@return boolean the same value for the engine (written lines and engine floats differ in the last digits)
local function near(a, b)
    a, b = tonumber(a), tonumber(b)
    if not a or not b then return false end
    return math.abs(a - b) <= 1e-5 * math.max(1, math.abs(a), math.abs(b))
end

---@return boolean the object's rotation (get_obj_rot: a MatrixTB or a list of 12) is this MatrixTB
local function sameRot(id, tb)
    local ok, m = pcall(get_obj_rot, id)
    if not ok or type(m) ~= "table" then return false end
    for k = 0, 10 do
        local value = m["r" .. k]
        if value == nil then value = m[k + 1] end
        if k ~= 3 and k ~= 7 and not near(value, tb["r" .. k]) then return false end
    end
    return true
end

---Puts a pool object on a collider: position, size and rotation (its bounce and flag are its group's, in the
---mod: Colliders.groupKey). Only what differs, as RPH changes objects: going back to a fight from a replay sets
---every pool object again, and most are already right where the replay left them
---@param d AtmoPlayDriver
---@param entry AtmoPlayPoolEntry
---@param c AtmoPlayCollider
local function place(d, entry, c)
    local id = entry.id - 1
    c.matrixTB = c.matrixTB or matrixTB(c.frame)
    local px, py, pz = get_obj_pos(id)
    if not (near(px, c.pos[1]) and near(py, c.pos[2]) and near(pz, c.pos[3]) and sameRot(id, c.matrixTB)) then
        set_obj_pos(id, c.pos[1], c.pos[2], c.pos[3])
        set_obj_rot_m(id, c.matrixTB)
    end
    -- the size read from the object too (a replay restores sizes from its EOBJ lines). Bounce and flag aren't set
    -- at all: replays don't record them, so each pool object has its group's in the mod (Colliders.groupKey)
    local ok, x, y, z = pcall(get_obj_sides, id)
    if not (ok and near(x, c.sides[1]) and near(y, c.sides[2]) and near(z, c.sides[3])) then
        set_obj_sides(id, c.sides[1], c.sides[2], c.sides[3])
    end
end

---@param d AtmoPlayDriver
---@param entry AtmoPlayPoolEntry
local function park(d, entry)
    local id = entry.id - 1
    set_obj_pos(id, entry.id, 0, Driver.PARK_Z)
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

---A driver for a pool whose objects are in the world now (right after /lm)
---@param pool AtmoPlayPoolState
---@return AtmoPlayDriver
function Driver.new(pool)
    return { pool = pool, lastFrame = nil, wasReplay = false, fromFrame = Driver.FIRST_FRAME }
end

---The mod's own dynamic objects in the world now (right after /lm): every object without the static bit
---that isn't one of Atmo Play's (the dynamic pool). An atmo floor is only solid where the pool is, so
---the pool follows them too or they fall through the map
---@param skip table<integer, boolean>? file ids to leave out (the dynamic pool, dynamics.lua)
---@return integer[] 0-based ids
function Driver.dynamicIds(skip)
    local ids = {}
    for id = 0, 255 do
        if not (skip and skip[id + 1]) then
            local okPos, x = pcall(get_obj_pos, id)
            if okPos and x then
                local ok, flag = pcall(get_obj_flag, id)
                flag = ok and tonumber(flag) or Driver.STATIC_FLAG
                if math.floor(flag / Driver.STATIC_FLAG) % 2 == 0 then ids[#ids + 1] = id end
            end
        end
    end
    return ids
end

---Start over: the next move assigns from scratch and sets every pool object again
---@param d AtmoPlayDriver
function Driver.reset(d)
    Pool.reset(d.pool)
    d.lastFrame = nil
end

---Moves the pool for the frame the fight is at
---@param d AtmoPlayDriver
---@param ws table get_world_state()
function Driver.drive(d, ws)
    local frame = ws.match_frame
    if frame < (d.fromFrame or 0) then return end -- not yet (lastFrame stays, the next draw tries again)
    -- the frame went back (a replay edited and played on from earlier): assign from scratch
    if d.lastFrame ~= nil and frame < d.lastFrame then Driver.reset(d) end
    d.lastFrame = frame
    local centers = playerCenters()
    -- more points the pool covers, so they keep a floor under them: the mod's own dynamic objects
    -- (Driver.dynamicIds) and the props being pushed (dynamics.lua)
    for _, id in ipairs(d.follow or {}) do
        local x, y, z = get_obj_pos(id)
        if x then centers[#centers + 1] = { x, y, z } end
    end
    if d.moreCenters then
        for _, c in ipairs(d.moreCenters()) do centers[#centers + 1] = c end
    end
    local changes = Pool.step(d.pool, centers)
    if d.onDrive then d.onDrive(changes, ws) end
    for _, change in ipairs(changes) do
        if change.collider then place(d, change.entry, change.collider) else park(d, change.entry) end
    end
end

---match_begin (inside /lm and open_replay): a fight places the pool from FIRST_FRAME on (drive waits), a
---replay has its own moves. A replay started by match_begin was opened: every frame of it is recorded
---@param d AtmoPlayDriver
---@param ws table get_world_state()
function Driver.matchBegin(d, ws)
    Driver.reset(d)
    d.wasReplay = ws.replay_mode > 0
    if not d.wasReplay then Driver.drive(d, ws) end
end

---draw2d (between physics steps): in a fight, the pool follows the players once per new match frame. Replays
---move nothing, R ones included: the game replays every recorded move by itself. (Driving the frames after an
---R replay's recorded ones, the "tail", was tried on 2026-11-21 and dropped: nobody played those frames, so
---there's nothing right to match, saved replays can't have it, an edit there didn't give a correct replay,
---and it took a crash fix after a crash fix.)
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
