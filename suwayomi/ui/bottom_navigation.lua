-- Boundary: main-screen bottom navigation renderer.
--
-- Responsibility: reserve footer space and render icon/label tabs on opted-in menus.
-- Owned state: widgets owned by the containing Menu; controllers own selection.
-- Dependencies: KOReader widgets, screen geometry, and font helpers.
-- External data: translated tab definitions and callbacks come from controllers.

local BottomNavigation = {}

function BottomNavigation.height()
    return require("device").screen:scaleBySize(72)
end

function BottomNavigation.attach(menu, navigation)
    local Screen = require("device").screen
    local Button = require("ui/widget/button")
    local Font = require("ui/font")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Geom = require("ui/geometry")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local TextWidget = require("ui/widget/textwidget")
    local Blitbuffer = require("ffi/blitbuffer")
    local row, focus_row = HorizontalGroup:new{}, {}
    local width = menu.dimen.w
    local height = BottomNavigation.height()
    local tabs = navigation.tabs
    for index, tab in ipairs(tabs) do
        local selected = tab.id == navigation.active
        local tab_width = math.floor(width * index / #tabs) - math.floor(width * (index - 1) / #tabs)
        local button = Button:new{
            icon = tab.icon,
            icon_width = Screen:scaleBySize(28),
            icon_height = Screen:scaleBySize(28),
            width = tab_width,
            height = Screen:scaleBySize(42),
            padding = 0, margin = 0, bordersize = 0,
            show_parent = menu,
            callback = function()
                if not selected then navigation.on_select(tab.id) end
            end,
        }
        local label = TextWidget:new{
            text = tab.text, face = Font:getFace("cfont", 16),
            bold = selected, max_width = tab_width,
        }
        -- One button owns the entire cell so both the icon and label are tappable.
        local border = selected and Screen:scaleBySize(2) or 0
        button.frame = FrameContainer:new{
            padding = 0, margin = 0, bordersize = border,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen = Geom:new{ w = tab_width - 2 * border, h = height - 2 * border },
                VerticalGroup:new{ align = "center", button.label_widget, label },
            },
        }
        button[1] = button.frame
        button.dimen.w, button.dimen.h = tab_width, height
        row[#row + 1] = button
        focus_row[#focus_row + 1] = button
    end
    menu[1] = VerticalGroup:new{ align = "left", menu[1], row }
    menu.dimen.h = Screen:getHeight()
    menu._suwayomi_bottom_focus = focus_row
    menu.layout[#menu.layout + 1] = focus_row
end

return BottomNavigation
