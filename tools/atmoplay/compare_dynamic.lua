-- Compares probe_dynamic.lua's log: each real dynamic object against its drawn atmo copy (prop). Dev only.
-- In game probe_dynamic.lua echoes Compare.summary at the fight's end. Offline (Lua 5.1, from mgeDev):
--   lua5.1 tools/atmoplay/compare_dynamic.lua ../atmoplay_dynprobe.log [every]
-- prints, per section (the fight, then any replay) and pair: where the two part, how far each travelled, how much
-- each leaves the ground (the bounce question), spin, then a side-by-side series every `every` frames (10).
-- "Clean" frames: the prop still drawn (not carried by a pool object), neither one near a player's body part, and
-- neither touching another pair's object: only there the difference is the flight sim against the game's physics.

local Compare = {
    NEAR = 1.0, -- a body part's center this close to an object's center: a player is in it
    AIR = 0.02, -- the lowest point this high above the ground: in the air
    CHECKS = { 10, 25, 50, 100, 150, 200, 300, 400, 600, 800 },
    PARTS = { 0.05, 0.25, 1.0 }, -- the first frame the two are this far apart
}

local FIELDS = { "x", "y", "z", "vx", "vy", "vz", "wx", "wy", "wz", "clear", "tilt", "near" }

local function words(line)
    local out = {}
    for w in line:gmatch("%S+") do out[#out + 1] = w end
    return out
end

local function keyValues(line)
    local out = {}
    for k, v in line:gmatch("([%w_]+)=(%S+)") do out[k] = v end
    out.gravity = line:match("gravity=(.-) mod=") or out.gravity
    return out
end

---@param lines string[]
---@return table[] sections
function Compare.parse(lines)
    local sections, cur = {}, nil
    for _, line in ipairs(lines) do
        local kind = line:match("^(%u+)")
        if kind == "BEGIN" then
            cur = { info = keyValues(line), pairs = {}, rows = {}, order = {} }
            sections[#sections + 1] = cur
        elseif cur and kind == "PAIR" then
            local w = words(line)
            local k = tonumber(w[2])
            local info = keyValues(line)
            info.k = k
            info.offset = { tonumber(line:match("offset=(%S+)")), tonumber(line:match("offset=%S+ (%S+)")),
                tonumber(line:match("offset=%S+ %S+ (%S+)")) }
            info.radius = tonumber(info.radius) or 0.5
            cur.pairs[k] = info
            cur.order[#cur.order + 1] = k
            cur.rows[k] = {}
        elseif cur and kind == "P" then
            local w = words(line)
            local k = tonumber(w[4])
            local row = { frame = tonumber(w[2]), replay = tonumber(w[3]), r = {}, p = {} }
            -- the game went on into a replay (or a replay restarted) without a match_begin: a section of its own
            if k == cur.order[1] and cur.lastFrame and (row.frame < cur.lastFrame or row.replay ~= cur.lastReplay) then
                local info = {}
                for key, v in pairs(cur.info) do info[key] = v end
                info.replay = tostring(row.replay)
                local nxt = { info = info, pairs = cur.pairs, rows = {}, order = cur.order }
                for _, key in ipairs(cur.order) do nxt.rows[key] = {} end
                cur = nxt
                sections[#sections + 1] = cur
            end
            if k == cur.order[1] then cur.lastFrame, cur.lastReplay = row.frame, row.replay end
            for i, name in ipairs(FIELDS) do row.r[name] = tonumber(w[4 + i]) end
            row.st, row.pf = w[17], tonumber(w[18])
            for i, name in ipairs(FIELDS) do row.p[name] = tonumber(w[18 + i]) end
            row.dang = tonumber(w[31])
            if cur.rows[k] then table.insert(cur.rows[k], row) end
        end
    end
    return sections
end

local function dist(a, b)
    return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
end

local function hspeed(v) return math.sqrt(v.vx ^ 2 + v.vy ^ 2) end
local function spin(v) return math.sqrt(v.wx ^ 2 + v.wy ^ 2 + v.wz ^ 2) end

---Ground contact of one side over rows i..j: frames in the air, take-offs (2+ frames up), the highest lift, the
---fastest rise while in the air
local function airOf(rows, side, last)
    local air, hops, lift, run, rise = 0, 0, 0, 0, 0
    for i = 1, last do
        local v = rows[i][side]
        if v.clear > Compare.AIR then
            air, run = air + 1, run + 1
            if run == 2 then hops = hops + 1 end
            if v.vz > rise then rise = v.vz end
        else
            run = 0
        end
        if v.clear > lift then lift = v.clear end
    end
    return air, hops, lift, rise
end

---Rebounds of one side: vz from below -0.3 to above +0.3 within 3 frames (a hit that sent it back up), and the
---largest rebound share (up speed / down speed)
local function reboundsOf(rows, side, last)
    local count, share = 0, 0
    local i = 1
    while i <= last do
        local down = rows[i][side].vz
        if down < -0.3 then
            for j = i + 1, math.min(i + 3, last) do
                local up = rows[j][side].vz
                if up > 0.3 then
                    count = count + 1
                    if up / -down > share then share = up / -down end
                    i = j
                    break
                end
            end
        end
        i = i + 1
    end
    return count, share
end

---One pair's numbers in a section
function Compare.pair(section, k)
    local rows = section.rows[k]
    local info = section.pairs[k]
    if not rows or #rows == 0 then return nil end
    local a = { k = k, info = info, rows = rows, n = #rows, first = rows[1].frame, last = rows[#rows].frame }
    -- where the clean frames end (index of the last clean row) and why
    local cleanLast, why = #rows, "the end"
    local function cut(i, reason)
        if i - 1 < cleanLast then cleanLast, why = i - 1, reason end
    end
    for i, row in ipairs(rows) do
        if row.st == "c" then cut(i, "carried from " .. row.frame) break end
    end
    for i, row in ipairs(rows) do
        if row.r.near < Compare.NEAR or row.p.near < Compare.NEAR then
            cut(i, "player near from " .. row.frame)
            break
        end
    end
    -- another pair's object touching (bounding spheres), real against real, prop against prop
    for _, other in ipairs(section.order) do
        if other ~= k then
            local orows, oinfo = section.rows[other], section.pairs[other]
            local byFrame = {}
            for _, row in ipairs(orows or {}) do byFrame[row.frame] = row end
            local reach = info.radius + oinfo.radius
            for i, row in ipairs(rows) do
                local o = byFrame[row.frame]
                if o then
                    local side = dist(row.r, o.r) < reach and "real" or (dist(row.p, o.p) < reach and "atmo" or nil)
                    if side then
                        cut(i, ("%s %s touching %s from %d"):format(side, info.shape, oinfo.shape, row.frame))
                        break
                    end
                end
            end
        end
    end
    a.cleanLast, a.why = cleanLast, why
    a.cleanFrame = cleanLast >= 1 and rows[cleanLast].frame or a.first
    -- where they part
    a.parted = {}
    for _, limit in ipairs(Compare.PARTS) do
        for _, row in ipairs(rows) do
            if dist(row.r, row.p) > limit then
                a.parted[limit] = row.frame
                break
            end
        end
    end
    a.maxClean = 0
    for i = 1, cleanLast do
        local d = dist(rows[i].r, rows[i].p)
        if d > a.maxClean then a.maxClean = d end
    end
    -- travel and speed over the clean frames
    local r0, p0 = rows[1].r, rows[1].p
    local last = rows[math.max(cleanLast, 1)]
    a.travelReal, a.travelProp = dist(last.r, r0), dist(last.p, p0)
    local sr, sp, wr, wp = 0, 0, 0, 0
    for i = 1, cleanLast do
        sr, sp = sr + hspeed(rows[i].r), sp + hspeed(rows[i].p)
        wr, wp = wr + spin(rows[i].r), wp + spin(rows[i].p)
    end
    local n = math.max(cleanLast, 1)
    a.speedReal, a.speedProp, a.spinReal, a.spinProp = sr / n, sp / n, wr / n, wp / n
    -- off the ground
    a.airReal, a.hopsReal, a.liftReal, a.riseReal = airOf(rows, "r", cleanLast)
    a.airProp, a.hopsProp, a.liftProp, a.riseProp = airOf(rows, "p", cleanLast)
    a.rebReal, a.shareReal = reboundsOf(rows, "r", cleanLast)
    a.rebProp, a.shareProp = reboundsOf(rows, "p", cleanLast)
    -- drawn frames whose prop numbers aren't at the row's frame (the probe ran before the step)
    a.offFrame = 0
    for _, row in ipairs(rows) do
        if row.st ~= "c" and row.pf ~= row.frame and row.st == "f" then a.offFrame = a.offFrame + 1 end
    end
    return a
end

local function f2(n) return string.format("%.2f", n) end
local function f3(n) return string.format("%.3f", n) end

local function rowAt(a, frame)
    for _, row in ipairs(a.rows) do
        if row.frame >= frame then return row end
    end
    return nil
end

---Short lines for the chat (the last section of `lines`)
---@param lines string[]
---@return string[]
function Compare.summary(lines)
    local sections = Compare.parse(lines)
    local s = sections[#sections]
    if not s then return { "nothing logged" } end
    local out = { ("%s, flight %s: %d pairs (real / atmo)"):format(s.info.replay == "0" and "fight" or "replay",
        tostring(s.info.level), #s.order) }
    for _, k in ipairs(s.order) do
        local a = Compare.pair(s, k)
        if a then
            local errs = {}
            for _, f in ipairs({ 50, 100, 200 }) do
                local row = rowAt(a, f)
                if row then
                    errs[#errs + 1] = ("%d:%s%s"):format(f, f2(dist(row.r, row.p)), row.frame > a.cleanFrame and "*" or "")
                end
            end
            out[#out + 1] = ("%s clean to %d (%s); apart %s"):format(a.info.shape, a.cleanFrame, a.why,
                table.concat(errs, " "))
            out[#out + 1] = ("  air frames %d/%d, hops %d/%d, max lift %s/%s, rebounds %d/%d; speed %s/%s, spin %s/%s")
                :format(a.airReal, a.airProp, a.hopsReal, a.hopsProp, f3(a.liftReal), f3(a.liftProp), a.rebReal,
                    a.rebProp, f2(a.speedReal), f2(a.speedProp), f2(a.spinReal), f2(a.spinProp))
        end
    end
    out[#out + 1] = "(* past the clean frames) full report: lua5.1 tools/atmoplay/compare_dynamic.lua ../atmoplay_dynprobe.log"
    return out
end

---The full report
---@param lines string[]
---@param every integer? the series' step in frames
---@return string[]
function Compare.report(lines, every)
    every = every or 10
    local out = {}
    local function say(text) out[#out + 1] = text end
    for si, s in ipairs(Compare.parse(lines)) do
        say(("== section %d: %s, flight %s, host %s, gravity %s, mod %s"):format(si,
            s.info.replay == "0" and "fight" or ("replay " .. tostring(s.info.replay)), tostring(s.info.level),
            tostring(s.info.host), tostring(s.info.gravity), tostring(s.info.mod)))
        for _, k in ipairs(s.order) do
            local a = Compare.pair(s, k)
            local i = s.pairs[k]
            say("")
            say(("-- pair %d: %s, real obj %s vs prop %s (offset %s %s %s); mass %s / %s, bounce %s / %s, prop friction %s, sim e %s")
                :format(k, tostring(i.shape), tostring(i.real), tostring(i.prop), f3(i.offset[1] or 0), f3(i.offset[2] or 0),
                    f3(i.offset[3] or 0), tostring(i.real_mass), tostring(i.prop_mass), tostring(i.real_bounce),
                    tostring(i.prop_bounce), tostring(i.prop_friction), tostring(i.e)))
            if not a then
                say("   no rows")
            else
                say(("   frames %d-%d (%d rows), clean to %d: %s"):format(a.first, a.last, a.n, a.cleanFrame, a.why))
                local parted = {}
                for _, limit in ipairs(Compare.PARTS) do
                    parted[#parted + 1] = ("> %s at %s"):format(limit, tostring(a.parted[limit] or "never"))
                end
                say("   apart: " .. table.concat(parted, ", ") .. ("; most in the clean frames %s"):format(f3(a.maxClean)))
                local checks = {}
                for _, f in ipairs(Compare.CHECKS) do
                    local row = rowAt(a, f)
                    if row and row.frame <= a.last then
                        checks[#checks + 1] = ("%d:%s%s%s"):format(row.frame, f3(dist(row.r, row.p)), row.st,
                            row.frame > a.cleanFrame and "*" or "")
                    end
                end
                say("   apart by frame (f drawn, c carried, s still; * past clean): " .. table.concat(checks, " "))
                say(("   clean frames, real / atmo: travelled %s / %s, mean horizontal speed %s / %s, mean spin %s / %s")
                    :format(f3(a.travelReal), f3(a.travelProp), f3(a.speedReal), f3(a.speedProp), f3(a.spinReal),
                        f3(a.spinProp)))
                say(("   off the ground (lowest point > %s): frames %d / %d, hops %d / %d, max lift %s / %s, fastest rise in air %s / %s")
                    :format(Compare.AIR, a.airReal, a.airProp, a.hopsReal, a.hopsProp, f3(a.liftReal), f3(a.liftProp),
                        f3(a.riseReal), f3(a.riseProp)))
                say(("   rebounds (vz < -0.3 to > 0.3 in 3 frames): %d / %d, largest up/down share %s / %s")
                    :format(a.rebReal, a.rebProp, f2(a.shareReal), f2(a.shareProp)))
                if a.offFrame > 0 then say(("   %d drawn rows had the prop at another frame (probe order)"):format(a.offFrame)) end
                say("   frame st |  real y      z   clear     vy      vz  tilt  spin |  atmo y      z   clear     vy      vz  tilt  spin | apart  dang")
                for _, row in ipairs(a.rows) do
                    if (row.frame - a.first) % every == 0 or row.frame == a.cleanFrame then
                        local r, p = row.r, row.p
                        say(("   %5d %s%s | %7.3f %6.3f %6.3f %6.2f %7.2f %5.0f %5.1f | %7.3f %6.3f %6.3f %6.2f %7.2f %5.0f %5.1f | %5.3f %5.0f")
                            :format(row.frame, row.st, row.frame > a.cleanFrame and "*" or " ", r.y, r.z, r.clear,
                                r.vy, r.vz, r.tilt, spin(r), p.y, p.z, p.clear, p.vy, p.vz, p.tilt, spin(p),
                                dist(r, p), row.dang or 0))
                    end
                end
            end
        end
        say("")
    end
    return out
end

-- command line: lua5.1 compare_dynamic.lua <log> [every]
if arg and arg[0] and tostring(arg[0]):find("compare_dynamic") then
    local path = arg[1] or "atmoplay_dynprobe.log"
    local file = io.open(path, "r")
    if not file then
        print("can't open " .. path)
        os.exit(1)
    end
    local lines = {}
    for line in file:lines() do lines[#lines + 1] = line end
    file:close()
    for _, line in ipairs(Compare.report(lines, tonumber(arg[2]))) do print(line) end
end

return Compare
