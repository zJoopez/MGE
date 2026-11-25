-- The pool rule: which pool object stands in for which atmo collider each fight frame. Pure logic: Pool.step returns
-- the changes, driver.lua moves the objects. It reads only the players' centers and its own previous assignment, so
-- the same frames give the same moves. A mod names its rule in the header (rule=1), so a later rule gets a new number.
--
-- Rule 1 (stable nearest), per group (Colliders.groupKey): the colliders within `radius` of any center (distance to
-- the surface), nearest first, ties by index, as many as the group has pool objects. A pool object keeps its collider
-- while that one is still wanted; the others, in id order, take the wanted ones nobody holds, nearest first; the rest
-- park. Keeping means few moves (each one a set_obj_* call and a replay line).

local NS = ATMOPLAY_LOADING

local Colliders = NS.Colliders

---@class AtmoPlayPoolEntry
---@field id integer env_obj id as the file writes it
---@field group string
---@field target AtmoPlayCollider? nil when parked
---@field dirty boolean reported by the next step even when its target stays (after a reset)

---@class AtmoPlayPoolChange
---@field entry AtmoPlayPoolEntry
---@field collider AtmoPlayCollider|false false: park it

---@class AtmoPlayPoolState
---@field rule integer
---@field radius number
---@field entries AtmoPlayPoolEntry[] by id
---@field groups table<string, AtmoPlayPoolEntry[]> by id
---@field targets table<string, AtmoPlayCollider[]> colliders per group, by index
---@field groupKeys string[] sorted
---@field cellSize number? grid cell edge (2 x radius); nil without the grid
---@field cells table<string, table<integer, AtmoPlayCollider[]>>? per group, x/y cell -> the colliders a center there can reach

---@class AtmoPlayPool
local Pool = {
    RULES = { [1] = "stable nearest" },
    DEFAULT_RULE = 1,
    DEFAULT_RADIUS = 4,
}

---A grid cell's key: one number, cells -32768..32767 per axis
---@return integer
local function cellKey(x, y)
    return (x + 32768) * 65536 + (y + 32768)
end
Pool.cellKey = cellKey

---Lists collider c in every x / y cell (edge `size`) a point within `reach` of its bounding sphere can be in
local function addToCells(cells, c, reach, size)
    local r = c.radius + reach
    for x = math.floor((c.pos[1] - r) / size), math.floor((c.pos[1] + r) / size) do
        for y = math.floor((c.pos[2] - r) / size), math.floor((c.pos[2] + r) / size) do
            local key = cellKey(x, y)
            local list = cells[key]
            if not list then
                list = {}
                cells[key] = list
            end
            list[#list + 1] = c
        end
    end
end

---@param objects AtmoPlayPoolObject[] the mod's pool objects
---@param colliders AtmoPlayCollider[]
---@param params { rule: integer?, radius: number? }? the mod header's
---@param options { grid: boolean? }? grid = false: every collider each step (tests compare)
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
        state.entries[#state.entries + 1] = { id = object.id, group = Colliders.groupKey(shape, object), target = nil,
            dirty = true }
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
        -- built once (colliders never move); x / y only: height is checked per collider anyway
        state.cellSize = math.max(state.radius * 2, 1)
        state.cells = {}
        for group, list in pairs(state.targets) do
            local cells = {}
            state.cells[group] = cells
            for _, c in ipairs(list) do addToCells(cells, c, state.radius, state.cellSize) end
        end
    end
    return state
end

---Forget the assignment: the next step assigns from scratch and reports every pool object
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

---Keeps `list` the `limit` nearest candidates, sorted
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
---@return { collider: AtmoPlayCollider, distance: number }[]
local function wanted(state, group, centers)
    local limit = #state.groups[group]
    local radius = state.radius
    local candidates = state.targets[group] or {}
    if state.cells then -- those registered in the centers' cells, each once
        local cells, size = state.cells[group] or {}, state.cellSize
        local seen = {}
        candidates = {}
        for _, p in ipairs(centers) do
            local cell = cells[cellKey(math.floor(p[1] / size), math.floor(p[2] / size))]
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
---@param centers number[][]
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

---Per group, the most colliders a player can have in reach at once, sampled at every collider's position
---@return table<string, integer> peak per group
local function demandPeaks(colliders, reach)
    local size = math.max(reach * 2, 1)
    local grid = {}
    for _, c in ipairs(colliders) do addToCells(grid, c, reach, size) end
    local peaks = {}
    for _, sample in ipairs(colliders) do
        local p, counts = sample.pos, {}
        for _, c in ipairs(grid[cellKey(math.floor(p[1] / size), math.floor(p[2] / size))] or {}) do
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

---The pool a playable mod gets: the free ids split by group, one per group first (most needed first), then always to
---the group with the highest peak / (pool + 1), never more than a group has colliders. By peak demand, not by
---collider count: a group of few big floors is near the players all the time. Ties by group name
---@param colliders AtmoPlayCollider[]
---@param free integer[] free ids in the order they're handed out
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
