-- Moves one static pool (Atmo Play's runtime and MGE's test mode). Timing makes replays work by themselves:
-- fights move in draw2d once per new match frame from FIRST_FRAME (enter_frame moves record a step late);
-- replays move nothing; returning to a fight sets every object again. Flag and bounce are never set
-- (replays don't record them): each pool object carries its group's

local NS = ATMOPLAY_LOADING

local Pool = NS.Pool
local Colliders = NS.Colliders

---@class AtmoPlayDriver
---@field pool AtmoPlayPoolState
---@field lastFrame integer? the match frame last moved for, nil after a reset
---@field wasReplay boolean the last draw was in a replay
---@field onDrive (fun(changes: AtmoPlayPoolChange[], ws: table))? before a step's moves (the dev debug log)
---@field moreCenters (fun(): number[][])? more points to cover (carried props)
---@field follow integer[]? 0-based ids of the mod's own dynamic objects: covered too
---@field fromFrame integer

---@class AtmoPlayDriverModule
local Driver = {
    PARK_Z = -100000,
    -- an R before the first recorded move puts moved objects at 0,0,0 (a crash with props): wait for frame 1
    FIRST_FRAME = 1,
}

---@param frame number[][]
---@return table MatrixTB (set_obj_rot_m)
function Driver.matrixTB(frame)
    return {
        r0 = frame[1][1], r1 = frame[1][2], r2 = frame[1][3], r3 = 0,
        r4 = frame[2][1], r5 = frame[2][2], r6 = frame[2][3], r7 = 0,
        r8 = frame[3][1], r9 = frame[3][2], r10 = frame[3][3], r11 = 0,
    }
end

---Equal to the engine (written and engine floats differ in the last digits)
local function near(a, b)
    a, b = tonumber(a), tonumber(b)
    if not a or not b then return false end
    return math.abs(a - b) <= 1e-5 * math.max(1, math.abs(a), math.abs(b))
end

---Whether the object's rotation (a MatrixTB or a list of 12) is this MatrixTB
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

---Puts a pool object on a collider, setting only what differs (after a replay most are already right)
local function place(entry, c)
    local id = entry.id - 1
    c.matrixTB = c.matrixTB or Driver.matrixTB(c.frame)
    local px, py, pz = get_obj_pos(id)
    if not (near(px, c.pos[1]) and near(py, c.pos[2]) and near(pz, c.pos[3]) and sameRot(id, c.matrixTB)) then
        set_obj_pos(id, c.pos[1], c.pos[2], c.pos[3])
        set_obj_rot_m(id, c.matrixTB)
    end
    local ok, x, y, z = pcall(get_obj_sides, id)
    if not (ok and near(x, c.sides[1]) and near(y, c.sides[2]) and near(z, c.sides[3])) then
        set_obj_sides(id, c.sides[1], c.sides[2], c.sides[3])
    end
end

local function park(entry)
    set_obj_pos(entry.id - 1, entry.id, 0, Driver.PARK_Z)
end

---Every player's center (the average of its body parts)
---@param count integer? players (get_world_state's num_players)
---@return number[][]
local function playerCenters(count)
    local centers = {}
    count = count or 2
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

---A driver for a pool in the world now (wasReplay: made mid-fight, it sets everything on its first draw)
---@param pool AtmoPlayPoolState
---@return AtmoPlayDriver
function Driver.new(pool)
    return { pool = pool, lastFrame = nil, wasReplay = true, fromFrame = Driver.FIRST_FRAME }
end

---The mod's own dynamic objects (no static bit), except `skip` (file ids): the pool keeps a floor under them too
---@param skip table<integer, boolean>?
---@return integer[] 0-based ids
function Driver.dynamicIds(skip)
    local ids = {}
    for id = 0, 255 do
        if not (skip and skip[id + 1]) then
            local okPos, x = pcall(get_obj_pos, id)
            if okPos and x then
                local ok, flag = pcall(get_obj_flag, id)
                if ok and Colliders.isDynamicFlag(flag) then ids[#ids + 1] = id end
            end
        end
    end
    return ids
end

---Start over: the next move assigns from scratch and sets every pool object again
function Driver.reset(d)
    Pool.reset(d.pool)
    d.lastFrame = nil
end

---Moves the pool for the frame the fight is at
---@param ws table get_world_state()
function Driver.drive(d, ws)
    local frame = ws.match_frame
    if frame < (d.fromFrame or 0) then return end
    if d.lastFrame ~= nil and frame < d.lastFrame then Driver.reset(d) end -- the frame went back
    d.lastFrame = frame
    local centers = playerCenters(ws.num_players)
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
        if change.collider then place(change.entry, change.collider) else park(change.entry) end
    end
end

---match_begin (inside /lm and open_replay): a fight places from FIRST_FRAME on, a replay has its own moves
function Driver.matchBegin(d, ws)
    Driver.reset(d)
    d.wasReplay = ws.replay_mode > 0
    if not d.wasReplay then Driver.drive(d, ws) end
end

---draw2d: in a fight the pool follows the players once per new match frame; replays move nothing
function Driver.draw(d, ws)
    if ws.replay_mode > 0 then
        d.wasReplay = true
        return
    end
    if d.wasReplay then
        d.wasReplay = false
        Driver.reset(d)
    end
    if ws.match_frame ~= d.lastFrame then Driver.drive(d, ws) end
end

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
