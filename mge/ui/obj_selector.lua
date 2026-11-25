local obj_selector = {}
MGE.ObjSelector = obj_selector -- its grid is shared with the joint lists

local Main = MGE.Main
local ModData = MGE.ModData
local ScrollList = MGE.ScrollList
local Widgets = MGE.Widgets

local GRID_COLUMNS = 6
local GRID_GAP = MGE.Widgets.GAP

-- cell colors: selected lighter, the text stays white
local CELL_TEXT = { 1, 1, 1, 1 }
local CELL_SELECTED_TEXT = CELL_TEXT
local CELL_DIMMED_TEXT = { 1, 1, 1, 0.35 } -- e.g. an empty joint slot
local CELL_DIMMED_BG = { 0, 0, 0, 0.15 }

---@param cell UIElement
---@param selected boolean?
---@param dimmed boolean?
local function styleCell(cell, selected, dimmed)
    if selected then
        cell.bgColor = Widgets.SELECTED_COLOR
        cell.hoverColor = Widgets.SELECTED_COLOR
        cell.uiColor = CELL_SELECTED_TEXT
    else
        cell.bgColor = dimmed and CELL_DIMMED_BG or TB_MENU_DEFAULT_BG_COLOR
        cell.hoverColor = Widgets.HOVER_COLOR
        cell.uiColor = dimmed and CELL_DIMMED_TEXT or CELL_TEXT
    end
    cell.pressedColor = TB_MENU_DEFAULT_DARKEST_COLOR
end

---@class GridListOptions
---@field label fun(item: any): string cell text
---@field isSelected fun(item: any): boolean?
---@field onClick fun(item: any, additive: boolean) changes the selection, the cells are restyled after
---@field popup (fun(item: any): string?)? hover text of a cell
---@field isDimmed (fun(item: any): boolean?)? drawn faint while not selected
---@field columns integer? cells per row, default GRID_COLUMNS
---@field emptyText string? shown when there are no items

---Grid list: a button per item, selected ones pale. Clicks restyle the cells in place (a rebuild would
---reset the scroll)
---@param view UIElement
---@param rect { x: number, y: number, w: number, h: number }
---@param items any[]
---@param opts GridListOptions
---@param toReload UIElement? see ScrollList.create
---@return fun() restyles the cells (for selections changed elsewhere)
function obj_selector.grid(view, rect, items, opts, toReload)
    local columns = opts.columns or GRID_COLUMNS
    local gridRows = {}
    for i, item in ipairs(items) do
        local r = math.ceil(i / columns)
        gridRows[r] = gridRows[r] or {}
        table.insert(gridRows[r], item)
    end
    local function restyle(item, cell)
        styleCell(cell, opts.isSelected(item), opts.isDimmed and opts.isDimmed(item))
    end

    ---@type table<any, UIElement> cells on this page
    local cells = {}
    local function restyleAll()
        for item, cell in pairs(cells) do
            if not cell.destroyed then restyle(item, cell) end
        end
    end
    ScrollList.create(view, rect, gridRows, function(rowElement, rowItems)
        local cellW = (rowElement.size.w - GRID_GAP * (columns + 1)) / columns
        for c, item in ipairs(rowItems) do
            local cell = rowElement:addChild({
                -- GRID_GAP between cells and rows
                pos = { GRID_GAP + (c - 1) * (cellW + GRID_GAP), GRID_GAP / 2 },
                size = { cellW, rowElement.size.h - GRID_GAP },
                interactive = true,
                -- colors on creation: toriui sets up the hover animation from them
                bgColor = TB_MENU_DEFAULT_BG_COLOR,
                hoverColor = Widgets.HOVER_COLOR,
                pressedColor = TB_MENU_DEFAULT_DARKEST_COLOR,
            }, true)
            cells[item] = cell
            restyle(item, cell)
            cell:addAdaptedText(opts.label(item), nil, nil, MGE.Widgets.FONT, CENTERMID, MGE.Widgets.TEXT_SCALE, nil, nil)
            local text = opts.popup and opts.popup(item)
            if text then Widgets.popupBelow(cell, text) end
            cell:addMouseUpHandler(function()
                opts.onClick(item, get_keyboard_shift() ~= 0)
                restyleAll()
            end)
        end
    end, toReload, opts.emptyText, true)
    return restyleAll
end

---The Objects list, or with mode "atmo" the Atmo list (A1, A2...): same grid and bar
---@param view UIElement
---@param fullList FileParserEnvObj[] the objects, or the atmo objects (ui/main.lua)
---@param mode "atmo"?
local function create(view, fullList, mode)
    local atmo = mode == "atmo"

    local list, page, pageCount = ScrollList.paginate(fullList, Main.page, Main.pageSize)
    Main.page = page -- clamped
    local listElementHeight = ScrollList.rowHeight

    -- a pager row only with several pages
    local pagerH = pageCount > 1 and listElementHeight or 0
    if pageCount > 1 then
        local pagerRow = view:addChild({
            pos = { 0, 0 },
            size = { view.size.w, pagerH },
        })
        ScrollList.createPager(pagerRow, { x = 0, y = 0, w = pagerRow.size.w, h = pagerRow.size.h }, page, pageCount,
            function(newPage)
                Main.page = newPage
                Main.updateWindow()
            end)
    end

    obj_selector.grid(view, {
        x = 0,
        y = pagerH,
        w = view.size.w,
        h = view.size.h - pagerH
    }, list, {
        label = function(obj) return (atmo and "A" or "") .. tostring(obj.id) end,
        emptyText = atmo and "Atmo has no objects\nTry adding some"
            or "Mod has no objects\nTry adding some",
        isSelected = function(obj) return obj.selected end,
        onClick = function(obj, additive)
            local selected = ModData.clickSelect(obj, additive)
            Main.onSelectionChanged()
            if selected then Main.selectionMade() end
        end,
    })

    -- Select all is lit while everything is selected; long lists are checked every few frames only
    local RECHECK_FRAMES, LONG_LIST = 10, 500
    local lit, sinceCheck = false, RECHECK_FRAMES
    local function allSelected()
        if #fullList == 0 then return false end
        sinceCheck = sinceCheck + 1
        if #fullList > LONG_LIST and sinceCheck < RECHECK_FRAMES then return lit end
        sinceCheck = 0
        lit = true
        for _, obj in ipairs(fullList) do
            if not obj.selected then lit = false break end
        end
        return lit
    end

    -- the list's action bar (MGE.Editor loads after this module: looked up on click)
    local barIcons = Main.setListActions({
        { label = "Select / deselect all (Ctrl + A)", icon = MGE.scriptPath .. "textures/selectall.tga", wide = true,
            onClick = function() if atmo then Main.toggleSelectAllAtmo() else Main.toggleSelectAll() end end },
        { label = atmo and "New atmo box (Ctrl + N)" or "New (Ctrl + N)", icon = "../textures/menu/general/buttons/addsign.tga",
            wide = true, onClick = function() if atmo then MGE.Assets.newAtmo() else MGE.Assets.newObject() end end },
        { label = "Duplicate (Ctrl + D)", icon = MGE.scriptPath .. "textures/duplicate.tga", wide = true,
            onClick = function() MGE.Editor.duplicate() end },
        { label = atmo and "Import an .atmo" or "Import", icon = MGE.scriptPath .. "textures/import.tga", wide = true,
            onClick = function() if atmo then MGE.Assets.openAtmoImport() else MGE.Assets.openImport() end end },
        { label = atmo and "Export the selected as an .atmo" or "Export", icon = MGE.scriptPath .. "textures/export.tga",
            wide = true, onClick = function() if atmo then MGE.Assets.exportAtmo() else MGE.Assets.export() end end },
        { label = "Delete (Del)", icon = "../textures/menu/general/buttons/trash.tga", wide = true,
            onClick = function() MGE.Editor.deleteSelected() end },
    })
    Main.lightWhile(barIcons[1], allSelected)
end

obj_selector.create = create

return obj_selector
