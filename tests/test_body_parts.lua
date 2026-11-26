-- utils/body_parts.lua: player sections' body / joint blocks, the classic defaults, the player frame fit,
-- rot lines and mirror twins, and the edit rule (joints move only between moved bodies)
local T = ...
local BodyParts, Mat3, FileHandler = MGE.BodyParts, MGE.Mat3, MGE.FileHandler

local function vec(section, kind, name, key) return BodyParts.vector(section, kind, name, key) end

T.test("body parts: a section reads and writes back as written; a change rewrites only its line", function()
    local lines = { "  # model by someone", "   body head", "      shape sphere", "      pos 1.00 0.85 2.65",
        "\tbody GROIN", "      sides 0.2 0.15 0.2", "   joint neck", "     radius 0.11" }
    local section = BodyParts.parseSection(lines)
    T.eq(table.concat(BodyParts.sectionLines(section), "\n"), table.concat(lines, "\n"), "round trip")
    T.eq(#section.preamble, 1, "the line before the first part")
    local head = BodyParts.part(section, "body", "head") --[[@as BodyPart]]
    BodyParts.setProp(head, "pos", "1 2 3")
    local out = BodyParts.sectionLines(section)
    T.eq(out[4], "      pos 1 2 3", "the changed line")
    T.eq(out[3], "      shape sphere", "the others as written")
    T.ok(BodyParts.part(section, "body", "groin") ~= nil, "names read lower case")
    T.eq(BodyParts.part(section, "body", "r_hand"), nil, "missing without create")
    local hand = BodyParts.part(section, "body", "R_HAND", true) --[[@as BodyPart]]
    BodyParts.setProp(hand, "sides", "0.1 0.1 0.1")
    out = BodyParts.sectionLines(section)
    T.eq(out[#out - 1], "   body r_hand", "a new part at the end")
    T.eq(out[#out], "      sides 0.1 0.1 0.1", "with its line")
end)

T.test("body parts: a player's section from the mod, written back to that player only", function()
    T.files["bodies.tbm"] = table.concat({ "version 15", "gamerule", "   numplayers 2",
        "player 0", "   body head", "      pos 1 0.85 3", "player 1", "   body head", "      pos 1 0.85 2.65", "" }, "\n")
    local parsed = FileHandler.ParseMod("bodies.tbm")
    local s0, own = BodyParts.section(parsed, 0)
    T.ok(own, "player 0 has its own section")
    T.nearList(vec(s0, "body", "head", "pos"), { 1, 0.85, 3 }, 1e-9, "its line")
    T.nearList(vec(s0, "body", "groin", "pos"), { 1, 1, 1.55 }, 1e-9, "a missing one: the classic default")
    BodyParts.setProp(BodyParts.part(s0, "body", "head") --[[@as BodyPart]], "pos", "2 2 2")
    BodyParts.write(parsed, 0, s0)
    T.nearList(vec(BodyParts.section(parsed, 0), "body", "head", "pos"), { 2, 2, 2 }, 1e-9, "written")
    T.nearList(vec(BodyParts.section(parsed, 1), "body", "head", "pos"), { 1, 0.85, 2.65 }, 1e-9, "player 1 kept")

    T.files["nobody.tbm"] = "version 15\ngamerule\n   numplayers 2\n"
    local _, ownNone = BodyParts.section(FileHandler.ParseMod("nobody.tbm"), 0)
    T.ok(not ownNone, "no section: not its own")
end)

T.test("body parts: shapes as MGE writes them; the head keeps its sphere", function()
    local section = BodyParts.parseSection({ "   body l_leg", "      shape capsule", "   body chest", "      shape Cube",
        "   body breast", "      shape cylinder" })
    T.eq(BodyParts.shape(section, "l_leg"), "cylinder", "capsule reads as cylinder")
    T.eq(BodyParts.shape(section, "chest"), "box", "cube as box")
    T.eq(BodyParts.shape(section, "breast"), "cylinder", "as written")
    T.eq(BodyParts.shape(section, "head"), "sphere", "missing: the default")
    T.ok(not BodyParts.canChangeShape("head") and not BodyParts.canChangeShape("HEAD"), "not the head")
    T.ok(BodyParts.canChangeShape("r_thigh"), "the others")
end)

T.test("body parts: rot lines turn as env_obj's, and back", function()
    local m = BodyParts.rotMatrix({ 0, 0, 30 })
    local expected = Mat3.rotZ(math.rad(-30))
    for i = 1, 3 do T.nearList(m[i], expected[i], 1e-12, "rotZ(-z) row " .. i) end
    local r = BodyParts.rotLine(BodyParts.rotMatrix({ 10, 20, 30 }))
    T.nearList(r, { 10, 20, 30 }, 1e-9, "round trip")
end)

---The classic bodies placed by a frame (what the game does to a player's file layout)
local function placed(R, t)
    local points = {}
    local names = {}
    for name in pairs(BodyParts.DEFAULTS.body) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local p = BodyParts.DEFAULTS.body[name].pos
        local q = Mat3.apply(R, p)
        points[#points + 1] = { file = { p[1], p[2], p[3] }, live = { q[1] + t[1], q[2] + t[2], q[3] + t[3] }, name = name }
    end
    return points
end

T.test("body parts: the player frame fit, file <-> world", function()
    local R, t = Mat3.rotZ(math.pi), { 2, 0.25, -0.06 } -- classic player 1 (measured)
    local frame = BodyParts.fitFrame(placed(R, t)) --[[@as BodyFrame]]
    T.ok(frame ~= nil, "fitted")
    T.near(frame.worst, 0, 1e-9, "every part fits")
    for i = 1, 3 do T.nearList(frame.R[i], R[i], 1e-9, "R row " .. i) end
    T.nearList(frame.t, t, 1e-9, "t")
    local w = BodyParts.toWorld(frame, { 0.45, 0.9, 2.3 })
    T.nearList(BodyParts.toFile(frame, w), { 0.45, 0.9, 2.3 }, 1e-9, "toFile undoes toWorld")
    -- a world turn about z by 90 degrees is the same turn in a frame turned about z
    local f = BodyParts.rotationToFile(frame, Mat3.rotZ(math.pi / 2))
    local z = Mat3.rotZ(math.pi / 2)
    for i = 1, 3 do T.nearList(f[i], z[i], 1e-9, "rotationToFile row " .. i) end

    local bent = placed(Mat3.rotZ(math.pi / 2), { 4.85, 0.9, -0.06 })
    bent[1].live[3] = bent[1].live[3] + 0.5 -- one part not where the file puts it
    T.ok(BodyParts.fitFrame(bent).worst > 0.1, "a part off: worst shows it")
    T.eq(BodyParts.fitFrame({ { file = { 0, 0, 0 }, live = { 0, 0, 0 } }, { file = { 1, 0, 0 }, live = { 1, 0, 0 } },
        { file = { 2, 0, 0 }, live = { 2, 0, 0 } } }), nil, "points on a line: no fit")
end)

T.test("body parts: measureFrame from the live bodies", function()
    local saved = { BODYPARTS = BODYPARTS, get_body_info = get_body_info }
    local ok, err = pcall(function()
        BODYPARTS = {}
        local id = 0
        for name in pairs(BodyParts.DEFAULTS.body) do
            BODYPARTS[name:upper()] = id
            id = id + 1
        end
        local live = {}
        for _, p in ipairs(placed(Mat3.rotZ(math.pi), { 2, 0.25, -0.06 })) do live[BODYPARTS[p.name:upper()]] = p.live end
        get_body_info = function(_, bid)
            local p = live[bid]
            return { pos = { x = p[1], y = p[2], z = p[3] } }
        end
        local frame = BodyParts.measureFrame(1, BodyParts.parseSection({})) --[[@as BodyFrame]]
        T.near(frame.worst, 0, 1e-9, "fits")
        T.nearList(frame.t, { 2, 0.25, -0.06 }, 1e-9, "t")
    end)
    BODYPARTS, get_body_info = saved.BODYPARTS, saved.get_body_info
    if not ok then error(err, 0) end
end)

T.test("body parts: mirror twins", function()
    T.eq(BodyParts.twin("r_biceps"), "l_biceps", "r to l")
    T.eq(BodyParts.twin("L_FOOT"), "r_foot", "l to r")
    T.eq(BodyParts.twin("breast"), nil, "middle")
    local section = BodyParts.parseSection({})
    T.near(BodyParts.mirrorX(section), 1, 1e-9, "classic middle x")
    T.nearList(BodyParts.mirrorPos({ 0.45, 0.9, 2.3 }, 1), { 1.55, 0.9, 2.3 }, 1e-9, "r_biceps to l_biceps")
    -- a mirrored rot line is the rotation seen in the mirror: S M S
    local S = { { -1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } }
    local r = { 10, 20, 30 }
    local want = Mat3.mul(S, Mat3.mul(BodyParts.rotMatrix(r), S))
    local got = BodyParts.rotMatrix(BodyParts.mirrorRot(r))
    for i = 1, 3 do T.nearList(got[i], want[i], 1e-9, "S M S row " .. i) end
end)

T.test("body parts: an edit moves the joints between moved bodies only; Mirror moves the twins", function()
    local section = BodyParts.parseSection({})
    local up = { pos = function(p) return { p[1], p[2], p[3] + 0.3 } end }
    BodyParts.transform(section, 0, { "r_biceps", "r_triceps" }, up)
    T.nearList(vec(section, "body", "r_biceps", "pos"), { 0.45, 0.9, 2.6 }, 1e-9, "biceps up")
    T.nearList(vec(section, "body", "r_triceps", "pos"), { 0.05, 0.9, 2.6 }, 1e-9, "triceps up")
    T.nearList(vec(section, "joint", "r_elbow", "pos"), { 0.25, 0.9, 2.6 }, 1e-9, "the elbow between them")
    T.eq(BodyParts.part(section, "joint", "r_shoulder"), nil, "the shoulder (to r_pecs) not written")
    T.eq(BodyParts.part(section, "joint", "r_wrist"), nil, "nor the wrist")
    T.eq(BodyParts.part(section, "body", "l_biceps"), nil, "no Mirror: the twin left")

    section = BodyParts.parseSection({})
    local inward = { pos = function(p) return { p[1] + 0.1, p[2], p[3] } end,
        rot = function(r) return { r[1], r[2], r[3] + 10 } end }
    BodyParts.transform(section, 0, { "breast", "r_pecs" }, inward, BodyParts.mirrorX(section))
    -- turned parts: where the game places them (their pos lines make up for its pivots)
    T.nearList(BodyParts.placed(section, "r_pecs"), { 0.85, 0.9, 2.15 }, 1e-9, "r_pecs +x")
    T.nearList(BodyParts.placed(section, "l_pecs"), { 1.15, 0.9, 2.15 }, 1e-9, "its twin -x")
    T.nearList(BodyParts.placed(section, "breast"), { 1.1, 0.9, 2.2 }, 1e-9, "the middle one as typed")
    T.nearList(vec(section, "body", "r_pecs", "rot"), { 0, 0, 10 }, 1e-9, "rot")
    T.nearList(vec(section, "body", "l_pecs", "rot"), { 0, 0, -10 }, 1e-9, "the twin's mirrored")
    T.nearList(vec(section, "joint", "r_pecs", "pos"), { 0.95, 0.85, 2.2 }, 1e-9, "joint breast-r_pecs: the edit")
    T.nearList(vec(section, "joint", "l_pecs", "pos"), { 1.05, 0.85, 2.2 }, 1e-9, "joint breast-l_pecs: mirrored")
    T.eq(BodyParts.part(section, "joint", "neck"), nil, "neck (to the head) stays")

    section = BodyParts.parseSection({})
    BodyParts.transform(section, 0, { "r_hand", "l_hand" }, inward, 1)
    T.nearList(BodyParts.placed(section, "l_hand"), { 2.45, 0.85, 2.3 }, 1e-9, "both selected: both as typed")
end)

T.test("body parts: shape changes convert the sides; the head refuses", function()
    T.nearList(BodyParts.convertSides("box", "sphere", { 0.2, 0.4, 0.3 }), { 0.2, 0, 0 }, 1e-9, "box to sphere")
    T.nearList(BodyParts.convertSides("box", "cylinder", { 0.2, 0.2, 0.6 }), { 0.1, 0.4, 0 }, 1e-9, "box to pill")
    T.nearList(BodyParts.convertSides("cylinder", "box", { 0.1, 0.4, 0 }), { 0.2, 0.2, 0.6 }, 1e-9, "pill to box")
    T.nearList(BodyParts.convertSides("sphere", "box", { 0.2, 0, 0 }), { 0.4, 0.4, 0.4 }, 1e-9, "sphere to box")
    T.ok(BodyParts.convertSides("box", "cylinder", { 0.4, 0.4, 0.1 })[2] > 0, "a flat box: the pill keeps a length")
    local section = BodyParts.parseSection({})
    T.ok(not BodyParts.setShape(section, "head", "box"), "head refused")
    T.eq(BodyParts.part(section, "body", "head"), nil, "and not written")
    T.ok(BodyParts.setShape(section, "r_thigh", "box"), "thigh changed")
    T.eq(BodyParts.shape(section, "r_thigh"), "box", "written as box")
    T.nearList(vec(section, "body", "r_thigh", "sides"), { 0.24, 0.24, 0.54 }, 1e-9, "classic pill 0.12 0.3 as a box")
    T.ok(not BodyParts.setShape(section, "r_thigh", "box"), "same shape: nothing")
end)

T.test("parts map: seen from behind, the nearest part takes the click", function()
    local saved = { Main = MGE.Main, Widgets = MGE.Widgets, PartList = MGE.PartList, BODYPARTS = BODYPARTS }
    local ok, err = pcall(function()
        MGE.Main, MGE.Widgets = {}, {}
        BODYPARTS = BODYPARTS or { HEAD = 0 }
        dofile(MGE.scriptPath .. "ui/part_list.lua")
        local L = MGE.PartList
        local items = L.mapItems()
        local byName = {}
        for _, it in ipairs(items) do byName[it.name] = it end
        local toScreen = L.fitMap(items, { x = 0, y = 0, w = 100, h = 100 })
        local rx = toScreen(byName.r_hand.u, byName.r_hand.v)
        local lx = toScreen(byName.l_hand.u, byName.l_hand.v)
        T.ok(lx < rx, "left hand on the left, right on the right (from behind)")
        local _, headY = toScreen(byName.head.u, byName.head.v)
        local _, footY = toScreen(byName.l_foot.u, byName.l_foot.v)
        T.ok(headY < footY, "head on top")
        T.ok(L.hitsItem(byName.head, byName.head.u, byName.head.v + 0.15), "inside the head's circle")
        T.ok(not L.hitsItem(byName.head, byName.head.u + 0.2, byName.head.v + 0.2), "outside it")
        T.ok(L.hitsItem(byName.r_thigh, byName.r_thigh.u, byName.r_thigh.v + 0.15 + 0.1), "a pill's cap")
        T.ok(items[1].depth <= items[#items].depth, "far to near")
    end)
    MGE.Main, MGE.Widgets, MGE.PartList, BODYPARTS = saved.Main, saved.Widgets, saved.PartList, saved.BODYPARTS
    if not ok then error(err, 0) end
end)

T.test("parts gizmo: previews mirror the twins, releases write each player's frame", function()
    local G = { "BODYPARTS", "get_body_info", "set_body_pos", "set_body_rotation_m", "get_world_state" }
    local savedG, savedM = {}, {}
    for _, k in ipairs(G) do savedG[k] = _G[k] end
    for _, k in ipairs({ "PartList", "Players", "Highlight", "PartTarget", "reloadPending" }) do savedM[k] = MGE[k] end
    local ok, err = pcall(function()
        BODYPARTS = {}
        local names = {}
        for name in pairs(BodyParts.DEFAULTS.body) do names[#names + 1] = name end
        table.sort(names)
        for i, name in ipairs(names) do BODYPARTS[name:upper()] = i - 1 end
        -- player 1 as the game places the classic body: turned 180 degrees about z, moved
        local R, t = Mat3.rotZ(math.pi), { 2, 0.25, -0.06 }
        local live = {}
        for _, name in ipairs(names) do
            local p = Mat3.apply(R, BodyParts.DEFAULTS.body[name].pos)
            live[BODYPARTS[name:upper()]] = { p[1] + t[1], p[2] + t[2], p[3] + t[3] }
        end
        local placedAt = {}
        get_body_info = function(_, id)
            local p = placedAt[id] or live[id]
            return { pos = { x = p[1], y = p[2], z = p[3] }, sides = { x = 0.1, y = 0.1, z = 0.1 }, shape = 1,
                rot = { r0 = R[1][1], r1 = R[1][2], r2 = R[1][3], r4 = R[2][1], r5 = R[2][2], r6 = R[2][3],
                    r8 = R[3][1], r9 = R[3][2], r10 = R[3][3] } }
        end
        set_body_pos = function(_, id, x, y, z) placedAt[id] = { x, y, z } end
        set_body_rotation_m = function() end
        get_world_state = function() return { match_frame = 0 } end
        MGE.reloadPending = nil
        MGE.Highlight = { toMatrixTB = function(m) return m end }
        MGE.Players = { exists = function() return true end }
        local section = BodyParts.parseSection({})
        local commits = 0
        MGE.PartList = {
            mirror = true,
            selected = function() return { { player = 1, name = "r_hand", kind = "body" } } end,
            edit = function(apply)
                apply(section, 1, { "r_hand" }, BodyParts.mirrorX(section), {})
                commits = commits + 1
            end,
        }
        dofile(MGE.scriptPath .. "utils/part_target.lua")
        local target = MGE.PartTarget.get()
        T.ok(target ~= nil, "a target")
        target.begin()
        target.previewMove({ 1, 0, 0 })
        local rh, lh = BODYPARTS.R_HAND, BODYPARTS.L_HAND
        T.nearList(placedAt[rh], { live[rh][1] + 1, live[rh][2], live[rh][3] }, 1e-9, "the part moves by the offset")
        T.nearList(placedAt[lh], { live[lh][1] - 1, live[lh][2], live[lh][3] }, 1e-9, "its twin mirrored")
        target.restoreLive()
        T.nearList(placedAt[rh], live[rh], 1e-9, "restored")

        target.moveBy({ 1, 0, 0 }) -- world +x is the turned player's file -x
        T.eq(commits, 1, "one edit")
        T.nearList(vec(section, "body", "r_hand", "pos"), { -1.35, 0.85, 2.3 }, 1e-9, "file -x")
        T.nearList(vec(section, "body", "l_hand", "pos"), { 3.35, 0.85, 2.3 }, 1e-9, "twin file +x")

        section = BodyParts.parseSection({})
        target.rotateByMatrix(Mat3.rotZ(math.pi / 2)) -- about the hand itself: it only turns
        T.nearList(BodyParts.placed(section, "r_hand"), { -0.35, 0.85, 2.3 }, 1e-9, "turned in place")
        T.nearList(vec(section, "body", "r_hand", "rot"), { 0, 0, -90 }, 1e-9, "rot line: rotZ(-z) = +90 about z")
        T.nearList(vec(section, "body", "l_hand", "rot"), { 0, 0, 90 }, 1e-9, "twin turned the other way")

        section = BodyParts.parseSection({})
        target.scaleBy({ 2, 1, 1 })
        T.nearList(vec(section, "body", "r_hand", "sides"), { 0.44, 0.22, 0.22 }, 1e-9, "box x doubled")
        T.nearList(MGE.PartTarget.scaleSides("cylinder", { 0.1, 0.3, 0 }, { 1, 1, 2 }), { 0.1, 0.6, 0 }, 1e-9,
            "pill length along z")
    end)
    for _, k in ipairs(G) do _G[k] = savedG[k] end -- nil ones too
    for _, k in ipairs({ "PartList", "Players", "Highlight", "PartTarget", "reloadPending" }) do MGE[k] = savedM[k] end
    if not ok then error(err, 0) end
end)

T.test("body parts: single-number lines, classic values, set with the twins", function()
    local section = BodyParts.parseSection({ "   body r_thigh", "      density 0.6956", "      flag 24" })
    T.near(BodyParts.number(section, "r_thigh", "density"), 0.6956, 1e-12, "as written")
    T.eq(BodyParts.number(section, "r_thigh", "flag"), 24, "flag as written")
    T.eq(BodyParts.number(section, "l_thigh", "density"), 0.25, "missing: classic")
    T.eq(BodyParts.number(section, "R_HAND", "flag"), 1, "hands: flag 1")
    T.eq(BodyParts.number(section, "head", "flag"), 0, "others 0")
    T.eq(table.concat(BodyParts.withTwins({ "r_thigh", "breast", "l_thigh" }, true), " "), "r_thigh l_thigh breast",
        "twins once, middle alone")
    BodyParts.setNumber(section, { "r_thigh" }, "friction", 0.5, true)
    T.eq(BodyParts.number(section, "l_thigh", "friction"), 0.5, "twin set too")
    BodyParts.setNumber(section, { "r_thigh" }, "flag", 16.4, false)
    T.eq(BodyParts.getProp(BodyParts.part(section, "body", "r_thigh") --[[@as BodyPart]], "flag"), "16", "flag whole")
    T.eq(BodyParts.number(section, "l_thigh", "flag"), 0, "no Mirror: twin kept")
end)

T.test("body parts: joint lines, classic values, moves with Mirror and without moving one twice", function()
    local section = BodyParts.parseSection({ "   joint r_elbow", "      range 2.00 0.10", "      strength 3.00" })
    T.nearList(BodyParts.range(section, "r_elbow"), { 2, 0.1 }, 1e-12, "range as written")
    T.nearList(BodyParts.range(section, "l_elbow"), { 2.3, 0.05 }, 1e-12, "classic range")
    T.eq(BodyParts.jointNumber(section, "r_elbow", "strength"), 3, "strength as written")
    T.eq(BodyParts.jointNumber(section, "l_knee", "velocity"), 40, "classic velocity")
    T.nearList(BodyParts.vector(section, "joint", "r_shoulder", "axis"), { 0, 1, 0 }, 1e-12, "classic axis")
    BodyParts.setJointLine(section, { "r_elbow" }, "axis", "0 0 1", true)
    T.eq(BodyParts.getProp(BodyParts.part(section, "joint", "l_elbow") --[[@as BodyPart]], "axis"), "0 0 1",
        "the twin gets the same line")

    section = BodyParts.parseSection({})
    local out = function(p) return { p[1] - 0.1, p[2], p[3] } end
    BodyParts.transformJoints(section, { "r_elbow", "neck" }, out, BodyParts.mirrorX(section))
    T.nearList(BodyParts.vector(section, "joint", "r_elbow", "pos"), { 0.15, 0.9, 2.3 }, 1e-9, "r_elbow -x")
    T.nearList(BodyParts.vector(section, "joint", "l_elbow", "pos"), { 1.85, 0.9, 2.3 }, 1e-9, "its twin +x")
    T.nearList(BodyParts.vector(section, "joint", "neck", "pos"), { 0.9, 0.9, 2.5 }, 1e-9, "middle as typed")

    section = BodyParts.parseSection({})
    local up = function(p) return { p[1], p[2], p[3] + 0.3 } end
    local moved = BodyParts.transform(section, 0, { "r_biceps", "r_triceps" }, { pos = up }, nil, { "r_elbow", "r_wrist" })
    T.ok(moved.r_elbow and moved.r_wrist, "the elbow (between) and the wrist (selected) moved")
    T.nearList(BodyParts.vector(section, "joint", "r_elbow", "pos"), { 0.25, 0.9, 2.6 }, 1e-9, "not moved twice")
    T.nearList(BodyParts.vector(section, "joint", "r_wrist", "pos"), { -0.2, 0.9, 2.6 }, 1e-9, "a selected joint")
end)

T.test("parts selection: bodies and joints apart (names overlap)", function()
    local saved = { Main = MGE.Main, Widgets = MGE.Widgets, PartList = MGE.PartList }
    local ok, err = pcall(function()
        MGE.Main = { getPlayerCount = function() return 2 end, activeTabs = { players = "parts" } }
        MGE.Widgets = {}
        dofile(MGE.scriptPath .. "ui/part_list.lua")
        local L = MGE.PartList
        MGE.Main.selectedParts = { ["0:chest"] = true, ["0:j:chest"] = true, ["1:j:r_knee"] = true, ["3:head"] = true }
        local list = L.selected()
        T.eq(#list, 3, "player 3 out of range")
        T.eq(list[1].kind .. " " .. list[1].name, "body chest", "body first")
        T.eq(list[2].kind .. " " .. list[2].name, "joint chest", "then the joint of the same name")
        T.eq(list[3].player .. " " .. list[3].kind, "1 joint", "player 1's joint")
        T.eq(#L.selected("joint"), 2, "joints only")
        T.eq(table.concat(L.byPlayer("joint")[0], " "), "chest", "joint names per player")
        T.eq(table.concat(L.byPlayer()[0], " "), "chest", "bodies by default")
        local updated = 0
        MGE.Main.updateWindow = function() updated = updated + 1 end
        MGE.Main.selectedParts, MGE.Main.selectedPlayer = {}, 0
        L.add({ { player = 1, name = "r_knee", kind = "joint" }, { player = 1, name = "head", kind = "body" } })
        T.ok(MGE.Main.selectedParts["1:j:r_knee"] and MGE.Main.selectedParts["1:head"], "box select adds")
        T.eq(MGE.Main.selectedPlayer, 1, "the map shows their player")
        L.add({ { player = 0, name = "groin", kind = "body" }, { player = 1, name = "chest", kind = "body" } })
        T.eq(MGE.Main.selectedPlayer, 1, "kept when one is on the shown player")
        T.eq(updated, 2, "window rebuilt each time")
    end)
    MGE.Main, MGE.Widgets, MGE.PartList = saved.Main, saved.Widgets, saved.PartList
    if not ok then error(err, 0) end
end)

T.test("parts gizmo: joints alone move only, previewed by the highlight, written mirrored", function()
    local G = { "BODYPARTS", "JOINTS", "get_body_info", "get_joint_pos", "set_body_pos", "set_body_rotation_m",
        "get_world_state" }
    local M = { "PartList", "Players", "Highlight", "PartTarget", "Gizmo", "reloadPending" }
    local savedG, savedM = {}, {}
    for _, k in ipairs(G) do savedG[k] = _G[k] end
    for _, k in ipairs(M) do savedM[k] = MGE[k] end
    local ok, err = pcall(function()
        BODYPARTS, JOINTS = {}, {}
        local bodies, joints = {}, {}
        for name in pairs(BodyParts.DEFAULTS.body) do bodies[#bodies + 1] = name end
        for name in pairs(BodyParts.DEFAULTS.joint) do joints[#joints + 1] = name end
        table.sort(bodies)
        table.sort(joints)
        for i, name in ipairs(bodies) do BODYPARTS[name:upper()] = i - 1 end
        for i, name in ipairs(joints) do JOINTS[name:upper()] = i - 1 end
        local byId = {}
        for _, name in ipairs(joints) do byId[JOINTS[name:upper()]] = BodyParts.DEFAULTS.joint[name].pos end
        get_body_info = function(_, id) -- player 0 unmoved: file = world
            local p = BodyParts.DEFAULTS.body[bodies[id + 1]].pos
            return { pos = { x = p[1], y = p[2], z = p[3] }, sides = { x = 0.1, y = 0.1, z = 0.1 }, shape = 1,
                rot = { r0 = 1, r1 = 0, r2 = 0, r4 = 0, r5 = 1, r6 = 0, r8 = 0, r9 = 0, r10 = 1 } }
        end
        get_joint_pos = function(_, id) local p = byId[id] return p[1], p[2], p[3] end
        set_body_pos, set_body_rotation_m = function() end, function() end
        get_world_state = function() return { match_frame = 0 } end
        MGE.reloadPending = nil
        MGE.Highlight = { toMatrixTB = function(m) return m end }
        MGE.Players = { exists = function() return true end }
        MGE.Gizmo = { mode = "rotate" }
        local section = BodyParts.parseSection({})
        MGE.PartList = {
            mirror = true,
            selected = function() return { { player = 0, name = "r_elbow", kind = "joint" } } end,
            edit = function(apply) apply(section, 0, {}, BodyParts.mirrorX(section), { "r_elbow" }) end,
        }
        dofile(MGE.scriptPath .. "utils/part_target.lua")
        T.eq(MGE.PartTarget.get(), nil, "joints alone: no Rotate")
        MGE.Gizmo.mode = "move"
        local target = MGE.PartTarget.get() --[[@as table]]
        T.ok(target ~= nil and not target.scalable, "Move, no Scale")
        target.begin()
        target.previewMove({ -0.1, 0, 0 })
        local previews = {}
        for _, e in ipairs(MGE.PartTarget.preview or {}) do previews[e.name] = e.preview end
        T.nearList(previews.r_elbow, { 0.15, 0.9, 2.3 }, 1e-9, "preview where it goes")
        T.nearList(previews.l_elbow, { 1.85, 0.9, 2.3 }, 1e-9, "twin mirrored")
        target.moveBy({ -0.1, 0, 0 })
        T.eq(MGE.PartTarget.preview, nil, "preview cleared")
        T.nearList(BodyParts.vector(section, "joint", "r_elbow", "pos"), { 0.15, 0.9, 2.3 }, 1e-9, "written")
        T.nearList(BodyParts.vector(section, "joint", "l_elbow", "pos"), { 1.85, 0.9, 2.3 }, 1e-9, "twin written")
        T.eq(BodyParts.part(section, "body", "r_biceps"), nil, "no body touched")
    end)
    for _, k in ipairs(G) do _G[k] = savedG[k] end
    for _, k in ipairs(M) do MGE[k] = savedM[k] end
    if not ok then error(err, 0) end
end)

T.test("body parts: turned parts placed about their pivot joint (probe 2b), pos lines written to land there", function()
    -- shifts measured in game (body_rot_x / _y, 30 degrees, classic layout)
    local function shiftOf(name, rot)
        local section = BodyParts.parseSection({ "   body " .. name, "      rot " .. rot })
        local c, p = BodyParts.vector(section, "body", name, "pos"), BodyParts.placed(section, name)
        return { p[1] - c[1], p[2] - c[2], p[3] - c[3] }
    end
    T.nearList(shiftOf("r_thigh", "30 0 0"), { 0, -0.150, 0.040 }, 1e-3, "r_thigh about r_hip")
    T.nearList(shiftOf("r_thigh", "0 30 0"), { 0.149, 0, 0.045 }, 1e-3, "and about y")
    T.nearList(shiftOf("l_leg", "0 30 0"), { -0.125, 0, -0.033 }, 1e-3, "l_leg about l_ankle")
    T.nearList(shiftOf("head", "30 0 0"), { 0, 0.082, 0.005 }, 1e-3, "head about neck")
    T.nearList(shiftOf("r_biceps", "0 0 30"), { 0.027, 0.100, 0 }, 1e-3, "biceps about shoulder")
    T.nearList(shiftOf("groin", "30 0 0"), { 0, 0, 0 }, 1e-12, "groin about itself")
    T.nearList(shiftOf("r_foot", "0 30 0"), { 0, 0, 0 }, 1e-12, "feet about themselves")

    local section = BodyParts.parseSection({ "   body r_thigh", "      rot 20 -10 35" })
    BodyParts.setPlaced(section, "r_thigh", { 0.7, 1.2, 1.0 })
    T.nearList(BodyParts.placed(section, "r_thigh"), { 0.7, 1.2, 1.0 }, 1e-5, "setPlaced lands where asked")
end)

T.test("body parts: a whole leg turned stays together; a pivot joint moved alone leaves its body in place", function()
    local section = BodyParts.parseSection({})
    local legs = { "r_thigh", "r_leg", "r_foot" }
    local before = {}
    for _, n in ipairs(legs) do before[n] = BodyParts.placed(section, n) end
    local hip0 = BodyParts.vector(section, "joint", "r_hip", "pos")
    local knee0 = BodyParts.jointPlaced(section, "r_knee")
    local W = Mat3.rotX(math.rad(30))
    local about = { 0.8, 1, 0.8 }
    local function turn(p)
        local q = Mat3.apply(W, { p[1] - about[1], p[2] - about[2], p[3] - about[3] })
        return { about[1] + q[1], about[2] + q[2], about[3] + q[3] }
    end
    BodyParts.transform(section, 0, legs, {
        pos = turn,
        rot = function(r) return BodyParts.rotLine(Mat3.mul(W, BodyParts.rotMatrix(r))) end,
    }, nil, { "r_hip" })
    for _, n in ipairs(legs) do
        T.nearList(BodyParts.placed(section, n), turn(before[n]), 1e-5, n .. " where the turn takes it")
        T.nearList(BodyParts.vector(section, "body", n, "rot"), { -30, 0, 0 }, 1e-5, n .. " turned")
    end
    T.nearList(BodyParts.vector(section, "joint", "r_hip", "pos"), turn(hip0), 1e-5, "the selected hip turned too")
    T.nearList(BodyParts.jointPlaced(section, "r_knee"), turn(knee0), 1e-5, "the knee (between) lands with them")

    local thigh = BodyParts.placed(section, "r_thigh")
    BodyParts.transformJoints(section, { "r_hip" }, function(p) return { p[1] + 0.1, p[2], p[3] } end)
    T.nearList(BodyParts.placed(section, "r_thigh"), thigh, 1e-5, "the turned thigh keeps its place")
end)

T.test("body parts: knees move with a turned thigh (measured), kept in place when it turns", function()
    -- body_rot_knee: r_thigh rot 30 0 0 alone moved r_knee by (0, -0.19, -0.029); l_leg turned alone left l_knee
    local section = BodyParts.parseSection({ "   body r_thigh", "      rot 30 0 0", "   body l_leg", "      rot 30 0 0" })
    T.nearList(BodyParts.jointPlaced(section, "r_knee"), { 0.8, 0.81, 0.771 }, 1e-3, "r_knee carried by its thigh")
    T.nearList(BodyParts.jointPlaced(section, "l_knee"), { 1.2, 1, 0.8 }, 1e-12, "a turned leg doesn't move it")
    T.nearList(BodyParts.jointPlaced(section, "r_hip"), { 0.79, 1, 1.4 }, 1e-12, "other joints at their line")
    BodyParts.setJointPlaced(section, "r_knee", { 0.8, 1, 0.8 })
    T.nearList(BodyParts.jointPlaced(section, "r_knee"), { 0.8, 1, 0.8 }, 1e-5, "setJointPlaced lands where asked")

    -- the Rot row on a thigh alone: it turns in place, its knee stays
    section = BodyParts.parseSection({})
    local knee0, thigh0 = BodyParts.jointPlaced(section, "r_knee"), BodyParts.placed(section, "r_thigh")
    BodyParts.transform(section, 0, { "r_thigh" }, { rot = function() return { 40, 0, 0 } end })
    T.nearList(BodyParts.placed(section, "r_thigh"), thigh0, 1e-5, "thigh in place")
    T.nearList(BodyParts.jointPlaced(section, "r_knee"), knee0, 1e-5, "knee in place")
    T.ok(BodyParts.vector(section, "joint", "r_knee", "pos")[2] ~= knee0[2], "its line makes up for the thigh")
end)

T.test("parts selection: the camera looks at the selected parts and joints (follow on), zoom kept", function()
    local G = { "BODYPARTS", "JOINTS", "get_body_info", "get_joint_pos" }
    local savedG = {}
    for _, k in ipairs(G) do savedG[k] = _G[k] end
    local saved = { Main = MGE.Main, Widgets = MGE.Widgets, PartList = MGE.PartList, Camera = MGE.Camera,
        Players = MGE.Players }
    local ok, err = pcall(function()
        BODYPARTS, JOINTS = { HEAD = 0 }, { R_KNEE = 16 }
        get_body_info = function() return { pos = { x = 1, y = 0, z = 3 } } end
        get_joint_pos = function() return 1, 0, 1 end
        local calls = {}
        MGE.Camera = { followMoves = true, focusOn = function(c, r, fit) calls[#calls + 1] = { c = c, r = r, fit = fit } end }
        MGE.Players = { exists = function() return true end }
        MGE.Main = { getPlayerCount = function() return 2 end, activeTabs = { players = "parts" },
            selectedParts = { ["0:head"] = true, ["0:j:r_knee"] = true } }
        MGE.Widgets = {}
        dofile(MGE.scriptPath .. "ui/part_list.lua")
        MGE.PartList.follow()
        T.eq(#calls, 1, "one look")
        T.nearList(calls[1].c, { 1, 0, 2 }, 1e-9, "at the middle of the head and the knee")
        T.near(calls[1].r, 1.3, 1e-9, "radius: the farthest plus a part's size")
        T.ok(not calls[1].fit, "keeps the zoom")
        MGE.Camera.followMoves = false
        MGE.PartList.follow()
        T.eq(#calls, 1, "camera follow off: no look")
    end)
    for _, k in ipairs(G) do _G[k] = savedG[k] end
    for _, k in ipairs({ "Main", "Widgets", "PartList", "Camera", "Players" }) do MGE[k] = saved[k] end -- nil ones too
    if not ok then error(err, 0) end
end)
