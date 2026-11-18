package.path = "?.lua;" .. package.path

describe("on-device download inventory", function()
    local Inventory = require("suwayomi/downloads/local_library")
    local function fixture()
        local nodes = {
            ["/books"] = { mode = "directory", names = { ".", "..", "one.cbz", "nested", "alias", "two.cbz.part" } },
            ["/books/one.cbz"] = { mode = "file", size = 100 },
            ["/books/nested"] = { mode = "directory", names = { "two.CBZ" } },
            ["/books/nested/two.CBZ"] = { mode = "file", size = 200 },
            ["/books/alias"] = { mode = "link" },
            ["/books/two.cbz.part"] = { mode = "file" },
            ["/old/moved.cbz"] = { mode = "file", size = 300 },
        }
        local ledger = {
            ["1:2"] = { manga_id = "1", chapter_id = "2", manga_title = "Manga", chapter_name = "Two",
                path = "/books/nested/two.CBZ", endpoint_scope = "server-a", read = true },
        }
        local contexts = {
            ["/books/nested/two.CBZ"] = ledger["1:2"],
            ["/old/moved.cbz"] = { manga_id = "3", chapter_id = "4", path = "/old/moved.cbz", endpoint_scope = "server-b" },
        }
        local settings = {
            loadDownloadDirectory = function() return "/books" end,
            loadChapterLedger = function() return ledger end,
            loadReaderReturnContexts = function() return contexts end,
        }
        local fs = {
            symlinkattributes = function(path) return nodes[path] end,
            dir = function(path)
                assert.is_not.equal("/books/alias", path)
                local i = 0
                return function() i = i + 1; return nodes[path].names[i] end
            end,
        }
        return settings, fs, ledger, contexts
    end

    it("deduplicates records, finds nested CBZs and ignores links and partial files", function()
        local settings, fs = fixture()
        local items, issues = Inventory.collect(settings, fs)
        assert.equals(3, #items)
        assert.same({}, issues)
        local found = {}
        for _, item in ipairs(items) do found[item.path] = item end
        assert.is_nil(found["/books/two.cbz.part"])
        assert.is_true(found["/books/nested/two.CBZ"].read)
        assert.equals("server-b", found["/old/moved.cbz"].manga.endpoint_scope)
        assert.is_nil(found["/books/one.cbz"].read)
        assert.is_nil(found["/books/one.cbz"].manga.id)
    end)

    it("does not infer read state from conflicting or explicitly unread records", function()
        local settings, fs, ledger, contexts = fixture()
        ledger["1:2"].pending_read_sync, ledger["1:2"].pending_read_state = true, false
        local items = Inventory.collect(settings, fs)
        for _, item in ipairs(items) do assert.is_not_true(item.read) end
        contexts.extra = { path = "/books/nested/two.CBZ", manga_id = "1", chapter_id = "2", endpoint_scope = "other" }
        items = Inventory.collect(settings, fs)
        for _, item in ipairs(items) do
            if item.path == "/books/nested/two.CBZ" then
                assert.is_true(item.conflict)
                assert.is_nil(item.read)
            end
        end
    end)

    it("reports an incomplete scan without losing recorded files", function()
        local settings, fs = fixture()
        fs.dir = function() error("permission denied") end
        local items, issues = Inventory.collect(settings, fs)
        assert.equals(2, #items)
        assert.is_true(issues.inaccessible)
    end)
end)
