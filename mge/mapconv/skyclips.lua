-- Sky clips: leaves out clips that are lids over the map. Loaded after convert.lua (shares boundsOf and
-- the solids grid). tools/mapconv_baseline.lua check shows what a change here drops or keeps per map
local MapConv = MGE.MapConv
local boundsOf = MapConv.boundsOf

-- Mappers fill open air with huge clip brushes (giant lids in Toribash). A clip is a lid when it's
--   wide:     both horizontal sides >= `width` (walls and pillars stay)
--   flat:     lower than it is wide
-- and either
--   close:    sky at most `gap` above its top over >= `cover` of it
-- or
--   floating: nothing solid from `clearance` under it up to its top on >= `floating` of its footprint
--   open:     and open sky right over >= `open` of it (ceiling clips under roofs stay)
-- or
--   ceiling:  its top is the map's clip ceiling: >= `ceilingCount` clips (sides >= `ceilingWidth`)
--             share that height, >= `ceilingBelow` of the solids end below it, sky over >= `ceilingSky`
--             of it, and it's lower than `ceilingTall` times its longest side. A solid above it on
--             `ceilingRoofed` of its footprint keeps it (indoor clips)
-- Tested on `samples` x `samples` footprint points
local SKY_CLIP = { width = 256, gap = 256, cover = 0.5, clearance = 72, floating = 0.5, open = 0.5, samples = 6,
    ceilingCount = 8, ceilingWidth = 128, ceilingBelow = 0.85, ceilingSky = 0.5, ceilingRoofed = 0.5,
    ceilingTall = 1 }

---Leaves out the clips that are lids over the map (SKY_CLIP), once every piece is there: what's under
---a clip can be terrain
---@param pieces MapConvPiece[]
---@param skies { min: number[], max: number[] }[] skyBounds
---@return MapConvPiece[] kept, integer lids
local function drop(pieces, skies)
    if #skies == 0 then return pieces, 0 end
    local candidates, clips = {}, {}
    for _, piece in ipairs(pieces) do
        if piece.role == "clip" then
            local min, max = boundsOf(piece)
            local across = math.min(max[1] - min[1], max[2] - min[2])
            local clip = { piece = piece, min = min, max = max, across = across,
                long = math.max(max[1] - min[1], max[2] - min[2]) }
            clips[#clips + 1] = clip
            if across >= SKY_CLIP.width and max[3] - min[3] < across then candidates[#candidates + 1] = clip end
        end
    end
    local lids = {}

    local grid = MapConv.solidsGrid(pieces) -- solids by footprint cell (MapConv.solidsAt)

    -- clip ceilings: top heights many wide clips share, above nearly all the solid pieces
    local shared = {}
    for _, c in ipairs(clips) do
        if c.across >= SKY_CLIP.ceilingWidth then
            local top = math.floor(c.max[3] + 0.5)
            shared[top] = (shared[top] or 0) + 1
        end
    end
    local ceilings = {}
    for top, count in pairs(shared) do
        if count >= SKY_CLIP.ceilingCount then ceilings[#ceilings + 1] = { top = top, below = 0 } end
    end
    if #ceilings > 0 then
        local solids = 0
        for _, piece in ipairs(pieces) do
            if piece.role ~= "clip" then
                solids = solids + 1
                local _, max = boundsOf(piece)
                for _, ceiling in ipairs(ceilings) do
                    if max[3] <= ceiling.top + 1 then ceiling.below = ceiling.below + 1 end
                end
            end
        end
        local isCeiling = {}
        for _, ceiling in ipairs(ceilings) do
            if solids > 0 and ceiling.below >= SKY_CLIP.ceilingBelow * solids then isCeiling[ceiling.top] = true end
        end
        local n = SKY_CLIP.samples
        for _, c in ipairs(clips) do
            local min, max = c.min, c.max
            if c.across >= SKY_CLIP.ceilingWidth and max[3] - min[3] < SKY_CLIP.ceilingTall * c.long and isCeiling[math.floor(max[3] + 0.5)] then
                -- footprint points with sky somewhere over them, and with a solid wholly above the
                -- clip (a roof: indoor clips stay; Italy's roofs poke through its ceiling, they start below)
                local under, roofed = 0, 0
                for i = 0, n - 1 do
                    for j = 0, n - 1 do
                        local x = min[1] + (i + 0.5) * (max[1] - min[1]) / n
                        local y = min[2] + (j + 0.5) * (max[2] - min[2]) / n
                        for _, sky in ipairs(skies) do
                            if x >= sky.min[1] and x <= sky.max[1] and y >= sky.min[2] and y <= sky.max[2]
                                and sky.min[3] >= max[3] - 1 then
                                under = under + 1
                                break
                            end
                        end
                        for _, s in ipairs(MapConv.solidsAt(grid, x, y)) do
                            if x >= s.min[1] and x <= s.max[1] and y >= s.min[2] and y <= s.max[2] and s.min[3] >= max[3] - 1 then
                                roofed = roofed + 1
                                break
                            end
                        end
                    end
                end
                if under >= SKY_CLIP.ceilingSky * n * n and roofed < SKY_CLIP.ceilingRoofed * n * n then
                    lids[c.piece] = true
                end
            end
        end
    end
    if #candidates == 0 and not next(lids) then return pieces, 0 end

    ---Close under the sky: sky starting at most SKY_CLIP.gap over its top covers enough of it
    local function close(min, max)
        local covered = 0
        for _, sky in ipairs(skies) do
            local above = sky.min[3] - max[3]
            if above >= -1 and above <= SKY_CLIP.gap then
                local ox = math.min(sky.max[1], max[1]) - math.max(sky.min[1], min[1])
                local oy = math.min(sky.max[2], max[2]) - math.max(sky.min[2], min[2])
                if ox > 0 and oy > 0 then covered = covered + ox * oy end
            end
        end
        return covered >= SKY_CLIP.cover * (max[1] - min[1]) * (max[2] - min[2])
    end

    local n = SKY_CLIP.samples
    for _, c in ipairs(candidates) do
        local min, max = c.min, c.max
        if close(min, max) then lids[c.piece] = true end
        local floating, open = 0, 0
        for i = 0, n - 1 do
            for j = 0, n - 1 do
                local x = min[1] + (i + 0.5) * (max[1] - min[1]) / n
                local y = min[2] + (j + 0.5) * (max[2] - min[2]) / n
                local skyZ = math.huge -- lowest sky bottom over this point
                for _, sky in ipairs(skies) do
                    if x >= sky.min[1] and x <= sky.max[1] and y >= sky.min[2] and y <= sky.max[2]
                        and sky.min[3] >= max[3] - 1 and sky.min[3] < skyZ then skyZ = sky.min[3] end
                end
                local free, clear = true, skyZ < math.huge
                for _, s in ipairs(MapConv.solidsAt(grid, x, y)) do
                    if x >= s.min[1] and x <= s.max[1] and y >= s.min[2] and y <= s.max[2] then
                        if s.max[3] > min[3] - SKY_CLIP.clearance and s.min[3] < max[3] then free = false end
                        if s.max[3] > max[3] + 1 and s.min[3] < skyZ - 1 then clear = false end
                    end
                end
                if free then floating = floating + 1 end
                if clear then open = open + 1 end
            end
        end
        if floating >= SKY_CLIP.floating * n * n and open >= SKY_CLIP.open * n * n then lids[c.piece] = true end
    end

    local kept, count = {}, 0
    for _, piece in ipairs(pieces) do
        if lids[piece] then count = count + 1 else kept[#kept + 1] = piece end
    end
    return kept, count
end

---@class MapConvSkyClips
MapConv.SkyClips = { drop = drop }
return MapConv.SkyClips
