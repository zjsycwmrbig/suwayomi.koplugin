package.path = "?.lua;" .. package.path

describe("main-screen bottom navigation", function()
    local saved, buttons
    local names = {
        "device", "ui/font", "ui/geometry", "ffi/blitbuffer",
        "ui/widget/button", "ui/widget/textwidget", "ui/widget/horizontalgroup",
        "ui/widget/verticalgroup", "ui/widget/container/framecontainer",
        "ui/widget/container/centercontainer", "suwayomi/ui/bottom_navigation",
    }
    before_each(function()
        saved, buttons = {}, {}
        for _, name in ipairs(names) do
            saved[name] = { loaded = package.loaded[name], preload = package.preload[name] }
            package.loaded[name], package.preload[name] = nil, nil
        end
        local function widgets()
            return { new = function(_, options) return options end }
        end
        for _, name in ipairs(names) do package.preload[name] = widgets end
        package.preload["suwayomi/ui/bottom_navigation"] = nil
        package.preload.device = function() return { screen = {
            scaleBySize = function(_, value) return value * 2 end,
            getHeight = function() return 1600 end,
        } } end
        package.preload["ui/font"] = function() return { getFace = function() return {} end } end
        package.preload["ffi/blitbuffer"] = function() return { COLOR_WHITE = "white" } end
        package.preload["ui/widget/button"] = function() return { new = function(_, options)
            options.label_widget = { icon = options.icon }
            options.dimen = { w = options.width, h = options.height }
            options.ges_events = { tap = { range = options.dimen } }
            buttons[#buttons + 1] = options
            return options
        end } end
    end)
    after_each(function()
        for _, name in ipairs(names) do
            package.loaded[name], package.preload[name] = saved[name].loaded, saved[name].preload
        end
    end)

    it("keeps the body height and gives each icon/label cell a full-height touch target", function()
        local Navigation = require("suwayomi/ui/bottom_navigation")
        local body = { height = 1456 }
        local menu = { body, dimen = { w = 1203, h = 1456 }, inner_dimen = { h = 1456 }, layout = {} }
        local selected = {}
        Navigation.attach(menu, { active = "library", tabs = {
            { id = "library", text = "库", icon = "book.opened" },
            { id = "browse", text = "浏览", icon = "appbar.search" },
            { id = "downloads", text = "下载", icon = "move.down" },
            { id = "settings", text = "设置", icon = "appbar.settings" },
        }, on_select = function(tab) selected[#selected + 1] = tab end })
        assert.are.equal(body, menu[1][1])
        assert.are.equal(1456, menu.inner_dimen.h)
        assert.are.equal(1600, menu.dimen.h)
        local width = 0
        for _, button in ipairs(buttons) do
            width = width + button.dimen.w
            assert.are.equal(144, button.dimen.h)
            assert.are.equal(button.dimen, button.ges_events.tap.range)
            assert.are.equal(button.frame, button[1])
            button.callback()
        end
        assert.are.equal(1203, width)
        assert.are.same({ "browse", "downloads", "settings" }, selected)
        assert.are.equal(menu._suwayomi_bottom_focus, menu.layout[1])
        assert.are.equal(4, buttons[1].frame.bordersize)
        assert.are.equal(0, buttons[2].frame.bordersize)
    end)
end)
