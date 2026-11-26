-- Players' actions (New, Duplicate, Delete, Export, model Reset, model info), for the Players list's Player tab
-- (ui/part_list.lua shows the list)

local player_list = {}
MGE.PlayerList = player_list -- for the shortcuts

local Main = MGE.Main
local ModData = MGE.ModData
local FileHandler = MGE.FileHandler

---@param lines string[]
---@return integer body and joint parts in a player section
local function countParts(lines)
    local count = 0
    for _, line in ipairs(lines) do
        if line:match("^%s*body%s") or line:match("^%s*joint%s") then count = count + 1 end
    end
    return count
end

---Where the player's model comes from
---@param id integer
---@return string
function player_list.describeModel(id)
    local own = FileHandler.getPlayerLines(ModData.parsed, id)
    if own then return countParts(own) .. " parts changed" end
    local shared = FileHandler.getSharedPlayerLines(ModData.parsed)
    if shared then return countParts(shared) .. " parts changed (all players)" end
    return "default body"
end

---Selects only these players, the panel shows the first
---@param ids integer[]
local function selectOnly(ids)
    Main.selectedPlayers = {}
    for _, id in ipairs(ids) do Main.selectedPlayers[id] = true end
    if ids[1] then Main.selectedPlayer = ids[1] end
end

---New player: the default body, in front of the camera
function player_list.newPlayer()
    local Players = MGE.Players
    local point = Players.exists(0) and MGE.Camera.spawnPoint(Players.bounds(0)) or nil
    Players.addNew(point, selectOnly)
end

---Duplicate: copies next to the selected players, selected
function player_list.duplicate()
    MGE.Players.duplicate(Main.selectedPlayerList(), selectOnly)
end

---Delete: asks first; a mod keeps at least one player
function player_list.deleteSelected()
    local list = Main.selectedPlayerList()
    local count = #list
    if count == 0 or (MGE.confirmOverlay and not MGE.confirmOverlay.destroyed) then return end
    if count >= Main.getPlayerCount() then
        MGE.say("a mod needs at least one player")
        return
    end
    local message = "Delete " .. (count == 1 and "player " .. list[1] or count .. " selected players") ..
        "?\nLater players move down to fill the numbers.\nUndo can bring them back."
    MGE.confirm(message, function()
        MGE.Players.remove(list, function(map)
            MGE.PartList.renumber(map)
            Main.selectedPlayers = {}
            -- the panel keeps its player, else the one now at its number
            local picked = map[Main.selectedPlayer]
            Main.selectedPlayer = picked or 0
            if not picked then
                for old, new in pairs(map) do
                    if new and old > Main.selectedPlayer then Main.selectedPlayer = new break end
                end
            end
        end)
    end)
end

---Export: the first selected player's model
function player_list.exportFirst()
    local first = Main.selectedPlayerList()[1]
    if not first then
        TBMenu:showStatusMessage("Select the player to export the model of first")
        return
    end
    MGE.Assets.exportPlayer(first)
end

---Model Reset: players with their own section back on the default body, one undo step
---@param players integer[]
function player_list.resetModels(players)
    local map, any = {}, false
    for _, id in ipairs(players) do
        if FileHandler.getPlayerLines(ModData.parsed, id) then map[id], any = false, true end
    end
    if not any then return end
    FileHandler.renumberPlayers(ModData.parsed, map) -- false: the section goes
    MGE.History.commit()
    MGE.apply()
end

---@return boolean every player is selected
function player_list.allSelected()
    for id = 0, Main.getPlayerCount() - 1 do
        if not Main.selectedPlayers[id] then return false end
    end
    return true
end

return player_list
