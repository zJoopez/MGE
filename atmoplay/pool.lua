-- The pool rule: which pool object stands in for which atmo collider, every frame of a fight. Pure logic:
-- Pool.step returns the changes, the runtime moves the objects (set_obj_*). Replays don't run it: the game
-- records every move and plays it back (docs/atmo-play-plan.md, part 3). A playable mod names its rule in the header
-- (rule=1) so a later, different rule gets a new number. It reads only the players' centers given to step
-- and its own previous assignment: the same frames give the same moves.
-- A grid built once (colliders never move) limits each step to the colliders around the players' cells;
-- the result is the same as looking at all of them (tests/test_pool.lua compares).
--
-- Rule 1 (stable nearest), per group (shape|friction|hardness|bounce|flag bits, see Colliders.groupKey): the colliders within `radius`
-- of any player's center (distance to the collider's surface), nearest first, ties by collider index,
-- as many as the group has pool objects. A pool object keeps its collider while that collider is still
-- among them; the others, in id order, take the wanted colliders nobody holds, nearest first; pool
-- objects left over are parked. Keeping instead of re-sorting means few moves per frame (each move is a
-- set_obj_* call and an EOBJ line in the replay).

local NS = ATMOPLAY_LOADING -- the namespace the loader gives (Atmo Play's ATMOPLAY, MGE's MGE.AtmoPlay)

local Colliders = NS.Colliders

---@class AtmoPlayPoolEntry
---@field id integer env_obj id as the file writes it
---@field group string
---@field target AtmoPlayCollider? the collider it stands in for, nil when parked
---@field dirty boolean the next step reports it even when its target stays (after a reset)

---@class AtmoPlayPoolChange
---@field entry AtmoPlayPoolEntry
---@field collider AtmoPlayCollider|false false: park it

---@class AtmoPlayPoolState
---@field rule integer
---@field radius number
---@field entries AtmoPlayPoolEntry[] by id
---@field groups table<string, AtmoPlayPoolEntry[]> pool objects per group, by id
---@field targets table<string, AtmoPlayCollider[]> colliders per group, by index
---@field groupKeys string[] the groups with pool objects, sorted (a fixed order for step)
---@field cellSize number? grid cell edge (2 x radius); nil without the grid
---@field cells table<string, table<integer, AtmoPlayCollider[]>>? per group, x/y cell (cellKey) -> the colliders a
---player's center in that cell can reach (built once: colliders never move)

---@class AtmoPlayPool
local Pool = {
    RULES = { [1] = "stable nearest" },
    DEFAULT_RULE = 1,
    DEFAULT_RADIUS = 4,
}

---@param state AtmoPlayPoolState
---@param v number
---@return integer the grid cell along one axis
local function cellOf(state, v)
    return math.floor(v / state.cellSize)
end

---A grid cell's key: one number (faster than strings), cells -32768..32767 per axis (±262k units at 8)
---@param x integer
---@param y integer
---@return integer
local function cellKey(x, y)
    return (x + 32768) * 65536 + (y + 32768)
end
Pool.cellKey = cellKey -- dynamics.lua's grid too

---@param objects AtmoPlayPoolObject[] the mod's pool objects (Format.read)
---@param colliders AtmoPlayCollider[]
---@param params { rule: integer?, radius: number? }? the mod header's
---@param options { grid: boolean? }? grid = false: look at every collider each step (the tests compare)
---@return AtmoPlayPoolState? state, string? error
function Pool.new(objects, colliders, params, options)
    params = params or {}
    local rule = params.rule or Pool.DEFAULT_RULE
    if not Pool.RULES[rule] then return nil, "unknown pool rule " .. tostring(rule) .. " (newer Atmo Play needed)" end
    local state = {
        rule = rule,
        radius = tonumber(params.radius) or Pool.DEFAULT_RADIUS,
        entries = {},
        groups = {},
        targets = {},
        groupKeys = {},
    }
    for _, object in ipairs(objects) do
        local shape = Colliders.shapeOf(object.shape) or "box"
        state.entries[#state.entries + 1] = {
            id = object.id,
            group = Colliders.groupKey(shape, object),
            target = nil,
            dirty = true,
        }
    end
    table.sort(state.entries, function(a, b) return a.id < b.id end)
    for _, entry in ipairs(state.entries) do
        local list = state.groups[entry.group]
        if not list then
            list = {}
            state.groups[entry.group] = list
            state.groupKeys[#state.groupKeys + 1] = entry.group
        end
        list[#list + 1] = entry
    end
    table.sort(state.groupKeys)
    for _, collider in ipairs(colliders) do
        if state.groups[collider.group] then
            local list = state.targets[collider.group] or {}
            state.targets[collider.group] = list
            list[#list + 1] = collider
        end
    end
    for _, list in pairs(state.targets) do
        table.sort(list, function(a, b) return a.index < b.index end)
    end
    if not (options and options.grid == false) then
        state.cellSize = math.max(state.radius * 2, 1)
        state.cells = {}
        for group, list in pairs(state.targets) do
            local cells = {}
            state.cells[group] = cells
            for _, c in ipairs(list) do
                -- every cell (x, y: maps are flat, height is checked per collider anyway) a player's
                -- center can be in while within reach of the collider
                local r = c.radius + state.radius
                local x0, x1 = cellOf(state, c.pos[1] - r), cellOf(state, c.pos[1] + r)
                local y0, y1 = cellOf(state, c.pos[2] - r), cellOf(state, c.pos[2] + r)
                for x = x0, x1 do
                    for y = y0, y1 do
                        local key = cellKey(x, y)
                        local cell = cells[key]
                        if not cell then
                            cell = {}
                            cells[key] = cell
                        end
                        cell[#cell + 1] = c
                    end
                end
            end
        end
    end
    return state
end

---Forget the assignment: the next step assigns from scratch (as at a fight's start) and reports every pool
---object, so all of them are set again (after a replay restart, a frame jump, a mod reload)
---@param state AtmoPlayPoolState
function Pool.reset(state)
    for _, entry in ipairs(state.entries) do
        entry.target = nil
        entry.dirty = true
    end
end

local function before(a, b)
    if a.distance ~= b.distance then return a.distance < b.distance end
    return a.collider.index < b.collider.index
end

---Keeps `list` the `limit` nearest candidates, sorted (binary insert; most colliders are out of reach)
local function insertNearest(list, candidate, limit)
    local low, high = 1, #list
    while low <= high do
        local mid = math.floor((low + high) / 2)
        if before(candidate, list[mid]) then high = mid - 1 else low = mid + 1 end
    end
    if low > limit then return end
    table.insert(list, low, candidate)
    if #list > limit then table.remove(list) end
end

---The colliders a group wants this frame, nearest first
---@param state AtmoPlayPoolState
---@param group string
---@param centers number[][]
---@return { collider: AtmoPlayCollider, distance: number }[]
local function wanted(state, group, centers)
    local limit = #state.groups[group]
    local radius = state.radius
    -- the colliders to look at: with the grid, those registered in the players' cells (each once); the
    -- result doesn't depend on their order (nearest first, ties by index)
    local candidates = state.targets[group] or {}
    if state.cells then
        local cells = state.cells[group] or {}
        local seen = {}
        candidates = {}
        for _, p in ipairs(centers) do
            local cell = cells[cellKey(cellOf(state, p[1]), cellOf(state, p[2]))]
            for _, c in ipairs(cell or {}) do
                if not seen[c] then
                    seen[c] = true
                    candidates[#candidates + 1] = c
                end
            end
        end
    end
    local list = {}
    for _, collider in ipairs(candidates) do
        local reach = radius + collider.radius
        local reachSquared = reach * reach
        local best
        for _, p in ipairs(centers) do
            local dx, dy, dz = p[1] - collider.pos[1], p[2] - collider.pos[2], p[3] - collider.pos[3]
            if dx * dx + dy * dy + dz * dz <= reachSquared then
                local d = Colliders.distance(collider, p)
                if not best or d < best then best = d end
            end
        end
        if best and best <= radius then
            local candidate = { collider = collider, distance = best }
            if #list < limit or before(candidate, list[#list]) then insertNearest(list, candidate, limit) end
        end
    end
    return list
end

---One frame of rule 1
---@param state AtmoPlayPoolState
---@param centers number[][] every player's center
---@return AtmoPlayPoolChange[] changes in group order, then id order
function Pool.step(state, centers)
    local changes = {}
    for _, group in ipairs(state.groupKeys) do
        local entries = state.groups[group]
        local list = wanted(state, group, centers)
        local isWanted = {}
        for _, candidate in ipairs(list) do isWanted[candidate.collider] = true end
        local held, free = {}, {}
        for _, entry in ipairs(entries) do
            if entry.target and isWanted[entry.target] then
                held[entry.target] = true
            else
                free[#free + 1] = entry
            end
        end
        -- held entries aren't dirty: a reset clears every target, so after one all entries are free
        local cursor = 1
        for _, entry in ipairs(free) do
            while list[cursor] and held[list[cursor].collider] do cursor = cursor + 1 end
            local candidate = list[cursor]
            cursor = cursor + 1
            local target = candidate and candidate.collider or nil
            if target ~= entry.target or entry.dirty then
                changes[#changes + 1] = { entry = entry, collider = target or false }
            end
            entry.target = target
            entry.dirty = false
        end
    end
    return changes
end

---------------------------------------------------------------------------------------------------- making a pool

---Per group, the most colliders a player can have in reach at once: what the pool has to cover. Sampled
---at every collider's position (players stand on and around the map's objects), counting the colliders
---whose bounding sphere is within `reach` (a 2D grid finds the candidates, the distance check is 3D)
---@param colliders AtmoPlayCollider[]
---@param reach number the pool rule's radius
---@return table<string, integer> peak per group
local function demandPeaks(colliders, reach)
    local size = math.max(reach * 2, 1)
    local grid = {}
    local function cell(v) return math.floor(v / size) end
    for _, c in ipairs(colliders) do
        local r = c.radius + reach
        for x = cell(c.pos[1] - r), cell(c.pos[1] + r) do
            for y = cell(c.pos[2] - r), cell(c.pos[2] + r) do
                local key = cellKey(x, y)
                local list = grid[key]
                if not list then
                    list = {}
                    grid[key] = list
                end
                list[#list + 1] = c
            end
        end
    end
    local peaks = {}
    for _, sample in ipairs(colliders) do
        local p, counts = sample.pos, {}
        for _, c in ipairs(grid[cellKey(cell(p[1]), cell(p[2]))] or {}) do
            local dx, dy, dz = p[1] - c.pos[1], p[2] - c.pos[2], p[3] - c.pos[3]
            local r = c.radius + reach
            if dx * dx + dy * dy + dz * dz <= r * r then counts[c.group] = (counts[c.group] or 0) + 1 end
        end
        for group, n in pairs(counts) do
            if n > (peaks[group] or 0) then peaks[group] = n end
        end
    end
    return peaks
end

---@class AtmoPlayPoolPlan
---@field objects { id: integer, group: string }[] the pool objects to write, by id
---@field groups { group: string, colliders: integer, peak: integer, pool: integer }[] most needed first

---The pool a playable mod gets (MGE's Save, the offline builder): the free ids split by group (Colliders.groupKey:
---what a pool object can't change once loaded), one per group first (most needed first), then in
---proportion to each group's peak demand (always to the group with the highest peak / (pool + 1)), never
---more than a group has colliders. Splitting by collider count instead starves a group of few but big
---objects (a map's floors) that are near the players all the time. Deterministic: ties by group name
---@param colliders AtmoPlayCollider[] the atmo's (Colliders.build)
---@param free integer[] free ids, in the order they're handed out
---@param radius number the pool rule's radius
---@return AtmoPlayPoolPlan
function Pool.plan(colliders, free, radius)
    local counts = {}
    for _, c in ipairs(colliders) do counts[c.group] = (counts[c.group] or 0) + 1 end
    local peaks = demandPeaks(colliders, radius)
    local groups = {}
    for group, count in pairs(counts) do
        groups[#groups + 1] = { group = group, colliders = count, peak = math.max(peaks[group] or 1, 1), pool = 0 }
    end
    table.sort(groups, function(a, b)
        if a.peak ~= b.peak then return a.peak > b.peak end
        if a.colliders ~= b.colliders then return a.colliders > b.colliders end
        return a.group < b.group
    end)
    local slots = math.min(#free, #colliders)
    for _, g in ipairs(groups) do
        if slots > 0 then
            g.pool = 1
            slots = slots - 1
        end
    end
    while slots > 0 do
        local best, bestScore
        for _, g in ipairs(groups) do
            if g.pool < g.colliders then
                local score = g.peak / (g.pool + 1)
                if not best or score > bestScore then best, bestScore = g, score end
            end
        end
        if not best then break end
        best.pool = best.pool + 1
        slots = slots - 1
    end
    local objects, nextFree = {}, 1
    for _, g in ipairs(groups) do
        for _ = 1, g.pool do
            objects[#objects + 1] = { id = free[nextFree], group = g.group }
            nextFree = nextFree + 1
        end
    end
    table.sort(objects, function(a, b) return a.id < b.id end)
    return { objects = objects, groups = groups }
end

NS.Pool = Pool
return Pool
