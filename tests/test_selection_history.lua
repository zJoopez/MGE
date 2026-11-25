-- utils/selection_history.lua: back / forward over selections, per layer. Loads its own copy over a stand-in
-- ModData and puts the original back
local T = ...

---@param fn fun(SH: SelectionHistory, parsed: table)
local function withHistory(fn)
    local saved = { ModData = MGE.ModData, SelectionHistory = MGE.SelectionHistory }
    local parsed = { env_obj = {}, atmo = {} }
    for i = 1, 4 do parsed.env_obj[i] = { id = i + 10, props = {} } end
    for i = 1, 3 do parsed.atmo[i] = { id = i, kind = "atmo", props = {} } end
    MGE.ModData = { parsed = parsed }
    local ok, err = pcall(function()
        dofile(MGE.scriptPath .. "utils/selection_history.lua")
        fn(MGE.SelectionHistory, parsed)
    end)
    MGE.ModData, MGE.SelectionHistory = saved.ModData, saved.SelectionHistory
    if not ok then error(err, 0) end
end

local function selectOnly(list, ...)
    local want = {}
    for _, i in ipairs({ ... }) do want[i] = true end
    for i, obj in ipairs(list) do obj.selected = want[i] or nil end
end

local function selectedIndices(list)
    local out = {}
    for i, obj in ipairs(list) do if obj.selected then out[#out + 1] = i end end
    return table.concat(out, " ")
end

T.test("selection history: back restores a replaced selection, forward redoes it", function()
    withHistory(function(SH, parsed)
        SH.record() -- nothing selected
        selectOnly(parsed.env_obj, 1, 2, 3)
        SH.record()
        selectOnly(parsed.env_obj, 4) -- the misclick
        SH.record()
        T.ok(SH.move("objects", -1), "back")
        T.eq(selectedIndices(parsed.env_obj), "1 2 3", "the group is back")
        SH.record() -- the rebuild after it: no new step
        T.ok(SH.move("objects", -1), "back again")
        T.eq(selectedIndices(parsed.env_obj), "", "the empty start")
        T.ok(not SH.move("objects", -1), "nothing earlier")
        T.ok(SH.move("objects", 1) and SH.move("objects", 1), "forward twice")
        T.eq(selectedIndices(parsed.env_obj), "4", "the latest")
        T.ok(not SH.move("objects", 1), "nothing later")
    end)
end)

T.test("selection history: a change after going back drops the forward steps", function()
    withHistory(function(SH, parsed)
        selectOnly(parsed.env_obj, 1); SH.record()
        selectOnly(parsed.env_obj, 2); SH.record()
        SH.move("objects", -1)
        selectOnly(parsed.env_obj, 3); SH.record()
        T.ok(not SH.move("objects", 1), "2 is gone")
        SH.move("objects", -1)
        T.eq(selectedIndices(parsed.env_obj), "1", "back to 1")
    end)
end)

T.test("selection history: an unrecorded change becomes a step; layers apart; limit; reset", function()
    withHistory(function(SH, parsed)
        selectOnly(parsed.env_obj, 1); SH.record()
        selectOnly(parsed.env_obj, 2) -- no hook saw it
        SH.move("objects", -1)
        T.eq(selectedIndices(parsed.env_obj), "1", "back from the unseen change")
        SH.move("objects", 1)
        T.eq(selectedIndices(parsed.env_obj), "2", "and forward to it")

        selectOnly(parsed.atmo, 2); SH.record()
        selectOnly(parsed.atmo, 3); SH.record()
        SH.move("atmo", -1)
        T.eq(selectedIndices(parsed.atmo), "2", "atmo by index")
        T.eq(selectedIndices(parsed.env_obj), "2", "objects untouched")

        selectOnly(parsed.env_obj, 1, 2); SH.record() -- ids 11 12
        selectOnly(parsed.env_obj, 4); SH.record()
        table.remove(parsed.env_obj, 1) -- object 11 deleted since
        SH.move("objects", -1)
        T.eq(selectedIndices(parsed.env_obj), "1", "id 12 kept, the deleted one skipped")

        SH.reset()
        for n = 1, SH.limit + 10 do
            selectOnly(parsed.env_obj, n % 2 + 1); SH.record()
        end
        T.eq(#SH.layers.objects.states, SH.limit, "capped")
    end)
end)
