-- Gizmo target for the Parts list (docs/body-parts-plan.md). Previews move the selected bodies and their Mirror
-- twins with set_body_*; selected joints are drawn by the highlight (joints alone: Move only). The release
-- rewrites their lines in each player's frame (BodyParts.measureFrame, fitted at frame 0), one undo step and a
-- reload. Bodies can't be resized live: Scale previews through the highlight (PartTarget.scalePreview), in
-- place, along each part's own axes

local Mat3 = MGE.Mat3
local BodyParts = MGE.BodyParts

---@class PartTarget
local PartTarget = {
    ---@type { factors: number[], entries: table[] }? a scale drag in progress (drawn by the highlight)
    scalePreview = nil,
    ---@type table[]? a move / rotate drag's entries: joints carry .preview (drawn by the highlight)
    preview = nil,
    MAX_MISS = 0.02, -- a fitted frame missing more: the bodies aren't where the mod puts them
}
MGE.PartTarget = PartTarget

-- the mirror across the player frame's x plane
local S = { { -1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } }

---Rows like the game's matrix, columns the part's axes in the world
local function bodyRot(b)
    local r = b.rot
    return { { r.r0, r.r1, r.r2 }, { r.r4, r.r5, r.r6 }, { r.r8, r.r9, r.r10 } }
end

---The world mirror that swaps a player's twins (across its frame's x = cx plane)
---@param frame BodyFrame
---@param cx number
local function reflector(frame, cx)
    local M = Mat3.mul(frame.R, Mat3.mul(S, Mat3.transpose(frame.R)))
    return {
        point = function(w) return BodyParts.toWorld(frame, BodyParts.mirrorPos(BodyParts.toFile(frame, w), cx)) end,
        vector = function(v) return Mat3.apply(M, v) end,
        rotation = function(W) return Mat3.mul(M, Mat3.mul(W, M)) end,
    }
end

---The factor of a, b, c (and d) furthest from 1: one handle's pull for a shape with one size there
local function dominant(...)
    local best = 1
    for _, f in ipairs({ ... }) do
        if math.abs(f - 1) > math.abs(best - 1) then best = f end
    end
    return best
end

---Sides scaled along the part's axes: box per axis, sphere by its strongest factor, pill radius by x / y and
---length by z
---@param shape string
---@param s number[]
---@param f number[]
---@return number[]
function PartTarget.scaleSides(shape, s, f)
    if shape == "sphere" then return { s[1] * dominant(f[1], f[2], f[3]), s[2], s[3] } end
    if shape == "cylinder" then return { s[1] * dominant(f[1], f[2]), s[2] * f[3], s[3] } end
    return { s[1] * f[1], s[2] * f[2], s[3] * f[3] }
end

local warnedKey = nil

---@param parts SelectedPart[]
---@param key string
---@return table? target
local function build(parts, key)
    local PartList, Players = MGE.PartList, MGE.Players
    local info, entries, selected = {}, {}, {}
    local anyBody = false
    for _, part in ipairs(parts) do
        if not info[part.player] and Players.exists(part.player) then
            local section = BodyParts.section(MGE.ModData.parsed, part.player)
            local frame = BodyParts.measureFrame(part.player, section)
            if not frame or frame.worst > PartTarget.MAX_MISS then
                if warnedKey ~= key then
                    warnedKey = key
                    MGE.say("parts gizmo: player " .. part.player .. "'s bodies aren't where the mod puts them " ..
                        "(a fight moved them?): back to frame 0 first")
                end
                return nil
            end
            info[part.player] = { frame = frame, reflect = reflector(frame, BodyParts.mirrorX(section)) }
        end
        local ids = part.kind == "joint" and JOINTS or BODYPARTS
        local id = ids and ids[part.name:upper()]
        if info[part.player] and id then
            selected[part.player .. part.kind .. part.name] = true
            entries[#entries + 1] = { player = part.player, id = id, name = part.name, kind = part.kind }
            if part.kind == "body" then anyBody = true end
        end
    end
    if #entries == 0 then return nil end
    -- joints alone: Move only (a joint has no turn or size of its own here)
    local mode = MGE.Gizmo and MGE.Gizmo.mode
    if not anyBody and mode ~= "move" then return nil end
    if PartList.mirror then
        for i = 1, #entries do
            local e = entries[i]
            local twin = BodyParts.twin(e.name)
            local ids = e.kind == "joint" and JOINTS or BODYPARTS
            if twin and not selected[e.player .. e.kind .. twin] and ids[twin:upper()] then
                entries[#entries + 1] = { player = e.player, id = ids[twin:upper()], name = twin, kind = e.kind,
                    twin = true }
            end
        end
    end

    ---@return number[]
    local function livePos(e)
        if e.kind == "joint" then return { get_joint_pos(e.player, e.id) } end
        local b = get_body_info(e.player, e.id)
        return { b.pos.x, b.pos.y, b.pos.z }
    end
    local pivot, n = { 0, 0, 0 }, 0
    for _, e in ipairs(entries) do
        if not e.twin then
            local p = livePos(e)
            pivot, n = { pivot[1] + p[1], pivot[2] + p[2], pivot[3] + p[3] }, n + 1
        end
    end
    pivot = { pivot[1] / n, pivot[2] / n, pivot[3] / n }
    local axes = Mat3.IDENTITY
    for _, e in ipairs(entries) do
        if e.kind == "body" then
            axes = bodyRot(get_body_info(e.player, e.id))
            break
        end
    end

    local t = { parts = entries, scalable = anyBody }
    function t.pivot() return { pivot[1], pivot[2], pivot[3] } end
    function t.frame() return axes end
    function t.begin()
        for _, e in ipairs(entries) do
            e.pos = livePos(e)
            if e.kind == "body" then e.rot = bodyRot(get_body_info(e.player, e.id)) end
        end
    end
    -- bodies move live; joints are drawn at e.preview by the highlight (set_joint_pos isn't measured)
    local function place(e, p, m)
        if e.kind == "joint" then
            e.preview = p
            PartTarget.preview = entries
            return
        end
        set_body_pos(e.player, e.id, p[1], p[2], p[3])
        set_body_rotation_m(e.player, e.id, MGE.Highlight.toMatrixTB(m))
    end
    function t.previewMove(offset)
        for _, e in ipairs(entries) do
            if e.pos then
                local o = e.twin and info[e.player].reflect.vector(offset) or offset
                place(e, { e.pos[1] + o[1], e.pos[2] + o[2], e.pos[3] + o[3] }, e.rot)
            end
        end
    end
    function t.previewRotate(W)
        for _, e in ipairs(entries) do
            if e.pos then
                local r = info[e.player].reflect
                local w = e.twin and r.rotation(W) or W
                local c = e.twin and r.point(pivot) or pivot
                local q = Mat3.apply(w, { e.pos[1] - c[1], e.pos[2] - c[2], e.pos[3] - c[3] })
                place(e, { c[1] + q[1], c[2] + q[2], c[3] + q[3] }, e.rot and Mat3.mul(w, e.rot))
            end
        end
    end
    function t.previewScale(factors)
        PartTarget.scalePreview = { factors = factors, entries = entries }
    end
    function t.restoreLive()
        PartTarget.scalePreview, PartTarget.preview = nil, nil
        for _, e in ipairs(entries) do
            e.preview = nil
            if e.pos and e.kind == "body" then place(e, e.pos, e.rot) end
        end
    end
    ---Commits a position edit: the bodies, the joints between them and the selected joints, in one go
    ---@param posFn fun(fr: BodyFrame): fun(p: number[]): number[]
    ---@param rotFn (fun(fr: BodyFrame): fun(r: number[]): number[])?
    local function editPositions(posFn, rotFn)
        PartList.edit(function(section, player, bodies, mirrorX, joints)
            local fr = info[player] and info[player].frame
            if not fr then return end
            local p, r = posFn(fr), rotFn and rotFn(fr)
            BodyParts.transform(section, player, bodies, { pos = p, rot = r }, mirrorX, joints)
        end)
    end
    function t.moveBy(offset)
        t.restoreLive()
        editPositions(function(fr)
            local d = Mat3.apply(Mat3.transpose(fr.R), offset)
            return function(p) return { p[1] + d[1], p[2] + d[2], p[3] + d[3] } end
        end)
    end
    function t.rotateByMatrix(W)
        t.restoreLive()
        editPositions(function(fr)
            local wf, pf = BodyParts.rotationToFile(fr, W), BodyParts.toFile(fr, pivot)
            return function(p)
                local q = Mat3.apply(wf, { p[1] - pf[1], p[2] - pf[2], p[3] - pf[3] })
                return { pf[1] + q[1], pf[2] + q[2], pf[3] + q[3] }
            end
        end, function(fr)
            local wf = BodyParts.rotationToFile(fr, W)
            return function(r) return BodyParts.rotLine(Mat3.mul(wf, BodyParts.rotMatrix(r))) end
        end)
    end
    function t.scaleBy(factors)
        t.restoreLive()
        PartList.edit(function(section, player, bodies, mirrorX)
            BodyParts.transform(section, player, bodies, {
                sides = function(s, name)
                    return PartTarget.scaleSides(BodyParts.shape(section, name) or "box", s, factors)
                end,
            }, mirrorX)
        end)
    end
    return t
end

local cached, cachedKey = nil, nil

---The Parts list's gizmo target, nil without a selection or while the bodies aren't at the loaded pose
---@return table?
function PartTarget.get()
    if MGE.reloadPending then return nil end
    local parts = MGE.PartList.selected()
    if #parts == 0 then return nil end
    local keys = {}
    for i, p in ipairs(parts) do keys[i] = p.player .. ":" .. p.kind .. ":" .. p.name end
    local ws = get_world_state()
    local key = table.concat(keys, ",") .. "|" .. tostring(MGE.History.index) .. "|" .. tostring(ws.match_frame) ..
        "|" .. tostring(MGE.PartList.mirror) .. "|" .. tostring(MGE.Gizmo and MGE.Gizmo.mode)
    if key ~= cachedKey then
        cachedKey = key
        cached = build(parts, key)
    end
    return cached
end

---Forgets the cached target (a reload placed the bodies again)
function PartTarget.reset()
    cached, cachedKey = nil, nil
    PartTarget.scalePreview, PartTarget.preview = nil, nil
end

return PartTarget
