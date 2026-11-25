-- Joints list: all MAX_ENV_JOINTS slots in a grid (empty ones faint). One slot is always current and
-- selected; Shift + click adds slots. An empty slot opens the Link tab, where Create makes the joint

local joint_list = {}
MGE.JointList = joint_list -- for the shortcuts

local Main = MGE.Main
local ModData = MGE.ModData
local Joints = MGE.Joints
local ScrollList = MGE.ScrollList

---@class JointSlot
---@field id integer
---@field joint FileParserEnvObjJoint? nil for an empty slot

---@return JointSlot[] every slot in id order
local function slots()
    local list = {}
    for id = 1, MGE.MAX_ENV_JOINTS do list[id] = { id = id, joint = Joints.find(id) } end
    return list
end

---@return boolean every joint is selected (false without joints)
local function allSelected()
    local joints = ModData.parsed.env_obj_joint
    if #joints == 0 then return false end
    for _, joint in ipairs(joints) do
        if not Main.selectedJoints[joint.id] then return false end
    end
    return true
end

---New: the lowest empty slot on the Link tab, with up to two selected objects already picked
function joint_list.newJoint()
    local id = Joints.nextId()
    if not id then
        Joints.haveRoom(1) -- says they're full
        return
    end
    Main.selectJointsOnly({ id })
    Joints.resetDraft()
    local draft = Joints.editDraft(id)
    local objects = ModData.getSelected()
    if #objects >= 1 and #objects <= 2 then
        draft.obj1 = objects[1].id
        draft.obj2 = objects[2] and objects[2].id or nil
    end
    Main.setTab("jointLink")
    Main.updateWindow()
end

---Duplicate: copies in the lowest empty slots, selected
function joint_list.duplicate()
    local ids = Joints.duplicate(Main.selectedJoints)
    if ids then Main.selectJointsOnly(ids) end
end

---Delete: asks first; the emptied slots stay selected
function joint_list.deleteSelected()
    local joints = Main.selectedJointList()
    local count = #joints
    if count == 0 or (MGE.confirmOverlay and not MGE.confirmOverlay.destroyed) then return end
    local message = "Delete " .. (count == 1 and "joint " .. joints[1].id or count .. " selected joints") ..
        "?\nUndo can bring them back."
    MGE.confirm(message, function()
        Joints.resetDraft()
        Joints.remove(Main.selectedJoints)
    end)
end

---@param view UIElement list area, emptied by the caller
function joint_list.create(view)
    -- Select all and Delete only: new joints are empty slots, joints export with their objects
    local barIcons = Main.setListActions({
        { label = "Select all joints, or only the current slot (Ctrl + A)", icon = MGE.scriptPath .. "textures/selectall.tga", wide = true,
            onClick = function() Main.toggleSelectAllJoints() end },
        { label = "Delete selected joints (Del)", icon = "../textures/menu/general/buttons/trash.tga", wide = true,
            onClick = joint_list.deleteSelected },
    })
    Main.lightWhile(barIcons[1], allSelected)

    MGE.ObjSelector.grid(view, { x = 0, y = 0, w = view.size.w, h = view.size.h }, slots(), {
        label = function(slot) return tostring(slot.id) end,
        isSelected = function(slot) return Main.selectedJoints[slot.id] end,
        isDimmed = function(slot) return slot.joint == nil end,
        onClick = function(slot, additive) Main.selectJoint(slot.id, additive) end,
        popup = function(slot)
            if not slot.joint then return "Joint " .. slot.id .. ": empty, link 2 objects on the Link tab" end
            return "Joint " .. slot.id .. ": objects " .. tostring(slot.joint.obj1) .. " and " .. tostring(slot.joint.obj2)
        end,
    })
end

return joint_list
