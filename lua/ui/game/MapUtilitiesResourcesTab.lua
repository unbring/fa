
local UIUtil = import('/lua/ui/uiutil.lua')
local LayoutHelpers = import('/lua/maui/layouthelpers.lua')

local ItemList = import('/lua/maui/itemlist.lua').ItemList
local Group = import('/lua/maui/group.lua').Group

function CreateUI(state, window, lastElement)

    local group = Group(window)
    group.Left:Set(function() return window.Left() + LayoutHelpers.ScaleNumber(10) end )
    group.Right:Set(function() return window.Right() end )
    group.Top:Set(function() return lastElement.Bottom() + LayoutHelpers.ScaleNumber(10) end )
    group.Bottom:Set(function() return lastElement.Bottom() + LayoutHelpers.ScaleNumber(100) end ) -- dummy value 

    do 

        local resourcesLabel = UIUtil.CreateText(group, "Resource check", 14, UIUtil.bodyFont, false)
        LayoutHelpers.AtTopIn(resourcesLabel, group)
        LayoutHelpers.AtLeftIn(resourcesLabel, group)

        local resourcesCheckbox = UIUtil.CreateCheckboxStd(group, '/dialogs/check-box_btn/radio')
        LayoutHelpers.DepthOverParent(resourcesCheckbox, window, 10)
        LayoutHelpers.AtCenterIn(resourcesCheckbox, resourcesLabel)
        resourcesCheckbox.Left:Set(function() return group.Right() - (resourcesCheckbox.Width() + LayoutHelpers.ScaleNumber(10)) end )
        resourcesCheckbox.OnCheck = function (self, checked)
            state.DebugResources = checked 
            SimCallback({
                Func = 'MapResoureCheck', Args = { }
            })

            -- this can be done only once
            resourcesCheckbox:Disable()
        end

        local resourcesDescription = ItemList(group)
        resourcesDescription:SetFont(UIUtil.bodyFont, 14)
        resourcesDescription:SetColors(UIUtil.bodyColor, "00000000",  UIUtil.highlightColor, "00000000")
        resourcesDescription.Left:Set(function() return group.Left() end)
        resourcesDescription.Right:Set(function() return group.Right() end)
        resourcesDescription.Top:Set(function() return resourcesLabel.Bottom() + LayoutHelpers.ScaleNumber(8) end )
        resourcesDescription.Bottom:Set(function() return resourcesLabel.Bottom() + LayoutHelpers.ScaleNumber(64)  end )

        UIUtil.SetTextBoxText(
            resourcesDescription, 
            "Constructs an extractor or a hydrocarbon on each resource marker if it is possible to build one there. Attempts to ring each extractor with storages and fabricators. Can only be applied once."
        )

        group.Bottom:Set(function() return resourcesDescription.Bottom()  + LayoutHelpers.ScaleNumber(10) end)
    end

    group:Hide()
    return group
end