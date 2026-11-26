-- utils/selection_history.lua: back / forward over selections, per layer. Loads its own copy over a stand-in
-- ModData and puts the original back
local T = ...

---@param fn fun(SH: SelectionHistory, parsed: table)
local function withHistory(fn)
    local saved = { ModData = MGE.ModData, SelectionHistory = MGE.SelectionHistory }
    local parsed = { env_obj = {}, atmo = {} }
    for i = 1, 4 do parsed.env_obj[i] = { id = i + 10, props = {} } end
    for i = 1, 3 do parsed.atmo[i] = { id = i, kind = "atmo", props = {} } end
    MGE.ModData = { parsed = parsed, keyObjects = saved.ModData.keyObjects }
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

T.test("selection history: steps follow objects through renumbering, undo copies and duplicates", function()
    withHistory(function(SH, parsed)
        local atmo = parsed.atmo
        selectOnly(atmo, 3); SH.record()
        selectOnly(atmo, 1); SH.record()
        table.remove(atmo, 2) -- an unselected one deleted: the old #3 is now #2
        for i, obj in ipairs(atmo) do obj.id = i end
        SH.move("atmo", -1)
        T.eq(selectedIndices(atmo), "2", "the same object, renumbered")

        local copy = {}
        for k, v in pairs(atmo[2]) do copy[k] = v end
        atmo[2] = copy -- undo restores copies
        atmo[3] = {}
        for k, v in pairs(copy) do atmo[3][k] = v end -- a duplicate of it
        atmo[3].selected = nil
        SH.record()
        selectOnly(atmo, 1); SH.record()
        SH.move("atmo", -1)
        T.eq(selectedIndices(atmo), "2", "the copy, not its duplicate")
    end)
end)

T.test("selection history: the Parts list's steps (Main.selectedParts keys)", function()
    withHistory(function(SH)
        local saved, savedList = MGE.Main, MGE.PartList
        local followed = 0
        MGE.PartList = { follow = function() followed = followed + 1 end }
        local ok, err = pcall(function()
            local Main = { listTab = "players", activeTabs = { players = "parts" }, selectedParts = {}, updated = 0 }
            function Main.partsShown() return true end
            function Main.updateWindow() Main.updated = Main.updated + 1 end
            function Main.selectionMade() error("parts follow through PartList.follow, not selectionMade") end
            MGE.Main = Main
            SH.record()
            Main.selectedParts = { ["0:r_hand"] = true, ["0:j:r_wrist"] = true }
            SH.record()
            Main.selectedParts = { ["1:head"] = true } -- the misclick
            SH.record()
            SH.step(-1)
            local keys = {}
            for k in pairs(Main.selectedParts) do keys[#keys + 1] = k end
            table.sort(keys)
            T.eq(table.concat(keys, " "), "0:j:r_wrist 0:r_hand", "the hand and wrist back")
            T.eq(Main.updated, 1, "window rebuilt")
            T.eq(followed, 1, "the camera follows the parts")
            SH.step(1)
            T.ok(Main.selectedParts["1:head"] and not Main.selectedParts["0:r_hand"], "forward again")
            T.eq(#SH.layers.objects.states, 1, "objects' steps apart (only the empty start)")
        end)
        MGE.Main, MGE.PartList = saved, savedList
        if not ok then error(err, 0) end
    end)
end)
