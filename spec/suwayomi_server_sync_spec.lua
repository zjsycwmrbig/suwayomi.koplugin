package.path = "?.lua;" .. package.path

local runtime = require("spec/support/plugin_runtime_spec_helper")

describe("one-click server sync", function()
    local settings, store, owner, request, confirmation, reconciles, deletions, messages
    local current, old = "https://current.example", "https://old.example"
    local kept_file = "/books/departed.cbz"

    local function savedEntry(manga_id, chapter_id, scope, fields)
        local entry = { manga_id = manga_id, chapter_id = chapter_id, endpoint_scope = scope, read = true }
        for key, value in pairs(fields or {}) do entry[key] = value end
        return entry
    end

    local function downloadedJob(key, chapter_id, scope)
        return { key = key, manga = { id = "536", endpoint_scope = scope },
            chapter = { id = chapter_id }, state = "failed" }
    end

    local function snapshot()
        return {
            ok = true, total_count = 1, manga = { { id = "536", title = "On the shelf" } }, categories = {},
            chapter_lists = { ["536"] = { { id = "1921", is_read = false },
                { id = "1926", is_read = false }, { id = "1930", is_read = true } } },
        }
    end

    local function clear()
        runtime.teardown()
        for _, name in ipairs({ "suwayomi/readsync/server_controller", "suwayomi/network/request_job" }) do
            package.loaded[name], package.preload[name] = nil, nil
        end
    end

    before_each(function()
        clear()
        runtime.install()
        request, confirmation, reconciles, deletions, messages = nil, nil, 0, {}, {}
        package.preload["suwayomi/settings"] = nil
        package.preload["suwayomi/network/request_job"] = function()
            return { start = function(options) request = options; return {} end,
                cancel = function() end }
        end
        settings = require("suwayomi/settings")
        store = require("spec/support/checked_queue_settings")():getStore()
        settings:setStore(store)
        assert(settings:save{ server_url = current })
        assert(store:saveDocument(function(doc)
            doc.download_directory = "/books"
            doc.library_cache = { version = 1, endpoint_scope = old, categories = {},
                manga = { { id = "536", title = "On the shelf" }, { id = "17", title = "Departed" } } }
            doc.chapter_ledger = {
                ["536:1921"] = savedEntry("536", "1921", old, { pending_read_sync = true }),
                ["536:1930"] = savedEntry("536", "1930", current, { read = false,
                    pending_read_sync = true, pending_read_state = false, path = "/books/active.cbz" }),
                ["17:7"] = savedEntry("17", "7", old, { path = kept_file }),
            }
            doc.download_queue = { downloadedJob("536:1926", "1926", old), downloadedJob("536:1930", "1930", current) }
        end))
        require("suwayomi/ui").showConfirm = function(options) confirmation = options end
        local queue = {
            checkStoreFence = function() return true end,
            isRecovering = function() return false end,
            isChapterBusy = function() return false end,
            isArchivePathBusy = function() return false end,
            reconcile = function() reconciles = reconciles + 1; return true end,
            getKey = function(_, manga, chapter) return manga.id .. ":" .. chapter.id end,
            manual_deletion = {
                applyRead = function() end,
                invalidateForServerSync = function() end,
                capture = function(_, key, path, root) return { key = key, target = { path = path, root = root } } end,
            },
        }
        local client = {
            cancelLibraryNetworkRequests = function() end,
            showLibrary = function() error("Sync must not close the current page") end,
        }
        owner = require("suwayomi/readsync/server_controller").methods
        owner.getClient = function() return client end
        owner.getDownloadQueue = function() return queue end
        owner.showMessage = function(_, message) messages[#messages + 1] = message end
        owner.schedulePendingReadSync = function() end
        owner.cancelMangaNetworkRequests = function() end
        owner.chapterArchiveExists = function(_, path) return path == kept_file end
        owner.deleteChapterFromDeviceWithOptions = function(_, manga, chapter, options)
            assert.is_true(options.keep_reading_metadata)
            deletions[#deletions + 1] = { manga.id, chapter.id, options.chapter_path }
            return true
        end
    end)
    after_each(clear)

    it("realigns the old-address chapter ledger and failed jobs before asking about departed downloads", function()
        assert.is_true(owner:syncLibraryFromServer())
        assert.is_true(request.request.tracked_manga["536"])
        request.on_finish(snapshot())
        local doc = store:load()
        assert.equals(1, #doc.library_cache.manga)
        assert.is_false(doc.chapter_cache.mangas["536"].chapters[1].is_read)
        assert.is_nil(doc.chapter_ledger["536:1921"])
        assert.is_true(doc.chapter_ledger["536:1930"].read)
        assert.is_nil(doc.chapter_ledger["536:1930"].pending_read_sync)
        assert.equals("/books/active.cbz", doc.chapter_ledger["536:1930"].path)
        assert.is_true(doc.server_sync_retained.read[old]["536:1921"].pending_read_sync)
        assert.is_false(doc.server_sync_retained.read[current]["536:1930"].pending_read_state)
        assert.equals("536:1930", doc.download_queue[1].key)
        assert.equals(1, #doc.download_queue)
        assert.equals(1, reconciles)
        assert.matches("Departed", confirmation.text, 1, true)
        assert.same({}, deletions)
        assert.equals(kept_file, doc.chapter_ledger["17:7"].path)

        confirmation.ok_callback()
        assert.same({ { "17", "7", kept_file } }, deletions)
    end)

    it("keeps local state intact on request failure or an incomplete chapter snapshot", function()
        local transaction = store:load().store_transaction.id
        assert.is_true(owner:syncLibraryFromServer())
        request.on_finish({ ok = false, error = "offline" })
        assert.equals(transaction, store:load().store_transaction.id)
        assert.is_nil(confirmation)
        assert.is_true(owner:syncLibraryFromServer())
        local incomplete = snapshot()
        incomplete.chapter_lists = {}
        request.on_finish(incomplete)
        assert.equals(transaction, store:load().store_transaction.id)
        assert.is_nil(confirmation)
    end)

    it("rejects a response after the configured server changes", function()
        assert.is_true(owner:syncLibraryFromServer())
        assert(settings:save{ server_url = old })
        local transaction = store:load().store_transaction.id
        request.on_finish(snapshot())
        assert.equals(transaction, store:load().store_transaction.id)
        assert.is_nil(confirmation)
    end)

    it("publishes the shelf and keeps records for directories that need a later refresh", function()
        assert.is_true(owner:syncLibraryFromServer())
        local result = snapshot()
        result.chapter_lists = {}
        result.deferred_chapters = { ["536"] = true }
        request.on_finish(result)
        local doc = store:load()
        assert.equals(current, doc.library_cache.endpoint_scope)
        assert.is_nil(doc.chapter_cache.mangas["536"])
        assert.equals(old, doc.chapter_ledger["536:1921"].endpoint_scope)
        assert.equals(2, #doc.download_queue)
    end)

    it("reuses a verified archive for the same source and chapter after IDs change", function()
        local path = "/books/reused.cbz"
        assert(store:saveDocument(function(doc)
            doc.reader_return_contexts = { [path] = {
                path = path, endpoint_scope = old, manga_id = "536", manga_title = "On the shelf",
                chapter_id = "1921", chapter_name = "Chapter one", chapter_number = 1,
                source = { id = "source1" }, in_library = true,
            } }
            doc.chapter_ledger["536:1921"].path = path
            doc.library_cache.manga[1].source = { id = "source1" }
        end))
        local identity = require("suwayomi/chapters/archive_identity")
        local original = identity.inspect
        identity.inspect = function(file, root)
            assert.equals(path, file)
            assert.equals("/books", root)
            return {}
        end
        assert.is_true(owner:syncLibraryFromServer())
        local result = snapshot()
        result.manga = { { id = "537", title = "On the shelf", source = { id = "source1" } } }
        result.chapter_lists = { ["537"] = { { id = "2200", name = "Chapter one", chapter_number = 1, is_read = false } } }
        request.on_finish(result)
        identity.inspect = original
        local doc = store:load()
        assert.equals(path, doc.chapter_ledger["537:2200"].path)
        assert.is_false(doc.chapter_ledger["537:2200"].read)
        assert.is_nil(doc.chapter_ledger["536:1921"].path)
        assert.is_nil(doc.chapter_ledger["536:1921"].pending_read_sync)
        assert.is_true(doc.server_sync_retained.read[old]["536:1921"].pending_read_sync)
        assert.equals(current, doc.reader_return_contexts[path].endpoint_scope)
        assert.equals("2200", doc.reader_return_contexts[path].chapter_id)
        assert.matches("Departed", confirmation.text, 1, true)
    end)

    it("drops only a positively missing path and keeps an uncertain path for the same source", function()
        local paths = { "/books/missing.cbz", "/books/unknown.cbz" }
        assert(store:saveDocument(function(doc)
            doc.reader_return_contexts = {}
            for i, path in ipairs(paths) do
                doc.reader_return_contexts[path] = {
                    path = path, endpoint_scope = old, manga_id = "536", manga_title = "On the shelf",
                    chapter_id = tostring(1920 + i), chapter_name = "Chapter " .. i,
                    source = { id = "source1" }, in_library = true,
                }
            end
        end))
        local identity = require("suwayomi/chapters/archive_identity")
        local original = identity.inspect
        identity.inspect = function(path)
            return nil, path == paths[1] and "missing" or "stat_failed"
        end
        assert.is_true(owner:syncLibraryFromServer())
        local result = snapshot()
        result.manga[1].source = { id = "source1" }
        result.chapter_lists["536"] = {
            { id = "1921", name = "Chapter 1", is_read = false },
            { id = "1922", name = "Chapter 2", is_read = false },
        }
        request.on_finish(result)
        identity.inspect = original
        local contexts = store:load().reader_return_contexts
        assert.is_nil(contexts[paths[1]])
        assert.equals(old, contexts[paths[2]].endpoint_scope)
    end)

    it("indexes chapter names once for many archive matches", function()
        local archives = require("suwayomi/readsync/sync_archives")
        local reads, chapters, contexts = 0, {}, {}
        local manga = { id = "m", title = "Series", source = { id = "source" } }
        for i = 1, 140 do
            local name = "Chapter " .. i
            chapters[i] = setmetatable({ id = tostring(i), chapter_number = i }, {
                __index = function(_, key)
                    if key == "name" then reads = reads + 1; return name end
                end,
            })
            if i <= 80 then
                local path = "/books/" .. i .. ".cbz"
                contexts[path] = {
                    endpoint_scope = old, path = path, manga_id = "m", manga_title = manga.title, source = manga.source,
                    chapter_id = tostring(i), chapter_name = name, chapter_number = i,
                }
            end
        end
        local doc = { reader_return_contexts = contexts, chapter_ledger = {} }
        local count = archives.relink(doc, { endpoint_scope = current, manga = { manga } },
            { mangas = { m = { chapters = chapters } } }, owner:getDownloadQueue(),
            function() return {} end, {}, function() end)
        assert.equals(80, count)
        assert.equals(#chapters + count, reads)
    end)

    it("rechecks the saved shelf before deleting from an earlier prompt", function()
        assert.is_true(owner:syncLibraryFromServer())
        request.on_finish(snapshot())
        assert(store:saveDocument(function(doc)
            doc.library_cache.manga[2] = { id = "17", title = "Restored" }
        end))
        confirmation.ok_callback()
        assert.same({}, deletions)
    end)
end)
