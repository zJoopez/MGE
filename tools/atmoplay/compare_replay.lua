-- Compares probe_replay.lua's log: each replay watched against its fight, frame by frame. Dev only.
--   lua5.1 tools/atmoplay/compare_replay.lua ../atmoplay_replayprobe.log [every]
-- For each replay viewing: the replay cache seen, where the mod's own dynamic objects and the pool objects part from
-- the fight's, which pool object carries another prop than in the fight, the takes and releases only one of them had,
-- the replay misses; then a table every `every` frames (25).

local function words(line)
    local out = {}
    for w in line:gmatch("%S+") do out[#out + 1] = w end
    return out
end

local function parse(lines)
    local sections, cur, frame = {}, nil, nil
    local function newSection(mode, info)
        cur = { mode = mode, info = info or (cur and cur.info) or {}, frames = {}, order = {}, events = {} }
        sections[#sections + 1] = cur
    end
    for _, line in ipairs(lines) do
        local w = words(line)
        local kind = w[1]
        if kind == "BEGIN" then
            local info = {}
            for k, v in line:gmatch("(%w+)=(%S+)") do info[k] = v end
            newSection(tonumber(info.replay), info)
            frame = nil
        elseif kind == "F" then
            local mode, f = tonumber(w[2]), tonumber(w[3])
            -- the fight went on into its replay, or a replay restarted: a section of its own
            if not cur or (mode > 0) ~= (cur.mode > 0) or (cur.last and f < cur.last) then newSection(mode) end
            cur.last = f
            frame = { f = f, line = line, pool = {}, real = {}, props = {} }
            frame.cache = line:match("cache=(%S+)")
            frame.misses = line:match("misses=(%S+)")
            frame.carried = tonumber(line:match("carried=(%d+)"))
            cur.frames[f] = frame
            cur.order[#cur.order + 1] = f
        elseif frame and kind == "E" then
            frame.pool[tonumber(w[2])] = { prop = w[3], x = tonumber(w[4]), y = tonumber(w[5]), z = tonumber(w[6]),
                vx = tonumber(w[7]), vy = tonumber(w[8]), vz = tonumber(w[9]) }
        elseif frame and kind == "R" then
            frame.real[tonumber(w[2])] = { x = tonumber(w[3]), y = tonumber(w[4]), z = tonumber(w[5]),
                vx = tonumber(w[6]), vy = tonumber(w[7]), vz = tonumber(w[8]) }
        elseif frame and kind == "P" then
            frame.props[tonumber(w[2])] = { x = tonumber(w[3]), y = tonumber(w[4]), z = tonumber(w[5]), st = w[6] }
        elseif cur and kind == "V" then
            cur.events[#cur.events + 1] = { kind = w[2], frame = tonumber(w[3]), id = tonumber(w[4]), prop = tonumber(w[5]) }
        end
    end
    return sections
end

local function dist(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2) end

local function compare(fight, replay, every, say)
    local firstReal, firstPool, firstCarry, firstMissing = {}, {}, nil, nil
    local rows = {}
    local caches = {}
    for _, f in ipairs(replay.order) do
        local a, b = fight.frames[f], replay.frames[f]
        caches[b.cache or "?"] = (caches[b.cache or "?"] or 0) + 1
        if a then
            local realMax, poolMax, carryDiff, onlyOne = 0, 0, 0, 0
            for id, r in pairs(a.real) do
                local o = b.real[id]
                if o then
                    local d = dist(r, o)
                    if d > realMax then realMax = d end
                    for _, lim in ipairs({ 0.01, 0.1, 1 }) do
                        if d > lim and not firstReal[lim] then firstReal[lim] = ("%d (obj %d, %.3f)"):format(f, id, d) end
                    end
                end
            end
            for id, e in pairs(a.pool) do
                local o = b.pool[id]
                if o then
                    local d = dist(e, o)
                    if d > poolMax then poolMax = d end
                    for _, lim in ipairs({ 0.01, 0.1, 1 }) do
                        if d > lim and not firstPool[lim] then firstPool[lim] = ("%d (obj %d, %.3f)"):format(f, id, d) end
                    end
                    if e.prop ~= o.prop then
                        carryDiff = carryDiff + 1
                        if not firstCarry then
                            firstCarry = ("%d: obj %d carries prop %s in the fight, %s in the replay"):format(f, id, e.prop, o.prop)
                        end
                    end
                else
                    onlyOne = onlyOne + 1
                    if not firstMissing then firstMissing = ("%d: obj %d out in the fight (prop %s), parked in the replay"):format(f, id, e.prop) end
                end
            end
            for id, o in pairs(b.pool) do
                if not a.pool[id] then
                    onlyOne = onlyOne + 1
                    if not firstMissing then firstMissing = ("%d: obj %d parked in the fight, out in the replay (prop %s)"):format(f, id, o.prop) end
                end
            end
            rows[#rows + 1] = { f = f, real = realMax, pool = poolMax, carryDiff = carryDiff, onlyOne = onlyOne,
                ca = a.carried or 0, cb = b.carried or 0, misses = b.misses or "?" }
        end
    end
    local cacheText = {}
    for k, n in pairs(caches) do cacheText[#cacheText + 1] = ("%s x%d"):format(k, n) end
    say("   replay cache (option/active): " .. table.concat(cacheText, ", "))
    say(("   frames %d-%d, %d compared with the fight"):format(replay.order[1] or -1, replay.order[#replay.order] or -1, #rows))
    for _, lim in ipairs({ 0.01, 0.1, 1 }) do
        say(("   apart > %s: the mod's objects at %s; pool objects at %s"):format(lim, firstReal[lim] or "never",
            firstPool[lim] or "never"))
    end
    say("   first other prop carried: " .. (firstCarry or "never"))
    say("   first pool object out in only one: " .. (firstMissing or "never"))
    -- events only one of them had (by kind, prop; frames may differ by one)
    local function key(ev) return ev.kind .. " prop " .. ev.prop end
    local inFight, inReplay = {}, {}
    local lastFrame = replay.order[#replay.order] or 0
    for _, ev in ipairs(fight.events) do
        if ev.frame <= lastFrame then inFight[key(ev)] = (inFight[key(ev)] or 0) + 1 end
    end
    for _, ev in ipairs(replay.events) do inReplay[key(ev)] = (inReplay[key(ev)] or 0) + 1 end
    local onlyFight, onlyReplay = {}, {}
    for k, n in pairs(inFight) do
        if (inReplay[k] or 0) < n then onlyFight[#onlyFight + 1] = k end
    end
    for k, n in pairs(inReplay) do
        if (inFight[k] or 0) < n then onlyReplay[#onlyReplay + 1] = k end
    end
    table.sort(onlyFight)
    table.sort(onlyReplay)
    say(("   events: fight %d, replay %d; only in the fight (%d): %s"):format(#fight.events, #replay.events, #onlyFight,
        table.concat(onlyFight, ", "):sub(1, 400)))
    say(("   only in the replay (%d): %s"):format(#onlyReplay, table.concat(onlyReplay, ", "):sub(1, 400)))
    say("   frame | mod objs apart | pool apart | carried fight/replay | other prop | out in one | misses far/none")
    for i, r in ipairs(rows) do
        if (r.f % every == 0) or i == #rows then
            say(("   %5d | %14.4f | %10.4f | %8d/%-6d | %10d | %10d | %s"):format(r.f, r.real, r.pool, r.ca, r.cb,
                r.carryDiff, r.onlyOne, r.misses))
        end
    end
end

local Compare = {}

function Compare.report(lines, every)
    every = every or 25
    local out = {}
    local function say(t) out[#out + 1] = t end
    local fight
    for i, s in ipairs(parse(lines)) do
        if s.mode == 0 then
            fight = s
            say(("== fight (section %d): host %s, level %s, mod %s, cache option at start %s; frames %d-%d, %d events")
                :format(i, tostring(s.info.host), tostring(s.info.level), tostring(s.info.mod), tostring(s.info.cache),
                    s.order[1] or -1, s.order[#s.order] or -1, #s.events))
        elseif fight then
            say(("== replay viewing (section %d, mode %d)"):format(i, s.mode))
            compare(fight, s, every, say)
        else
            say(("== replay (section %d) without a fight logged before it"):format(i))
        end
    end
    return out
end

if arg and arg[0] and tostring(arg[0]):find("compare_replay") then
    local file = io.open(arg[1] or "atmoplay_replayprobe.log", "r")
    if not file then
        print("can't open " .. tostring(arg[1]))
        os.exit(1)
    end
    local lines = {}
    for line in file:lines() do lines[#lines + 1] = line end
    file:close()
    for _, line in ipairs(Compare.report(lines, tonumber(arg[2]))) do print(line) end
end

return Compare
