-- Boundary: one-click server sync, presentation, and optional removal of local downloads.

local ArchiveIdentity = require("suwayomi/chapters/archive_identity")
local I18n = require("suwayomi/i18n")
local RequestJob = require("suwayomi/network/request_job")
local Settings = require("suwayomi/settings")
local Debug = require("suwayomi/debug")
local Snapshot = require("suwayomi/readsync/server_snapshot")
local UI = require("suwayomi/ui")

local Methods = {}

function Methods:cancelServerSync()
    local request = self.server_sync_request
    self.server_sync_request = nil
    if request and request.active then RequestJob.cancel(request.active) end
end

local function collectDepartedDownloads(owner, queue, doc, departed)
    local root = Settings:loadDownloadDirectory()
    local paths, groups = {}, {}
    for _, records in pairs({ ledger = doc.chapter_ledger, contexts = doc.reader_return_contexts }) do
        for _, entry in pairs(type(records) == "table" and records or {}) do
            if type(entry) == "table" and type(entry.path) == "string" and entry.path ~= "" then
                local previous = paths[entry.path]
                local id, chapter_id = tostring(entry.manga_id or ""), tostring(entry.chapter_id or "")
                if not previous then
                    paths[entry.path] = { id = id, chapter_id = chapter_id, entry = entry }
                elseif previous.id ~= id or previous.chapter_id ~= chapter_id
                    or previous.entry.endpoint_scope ~= entry.endpoint_scope then
                    previous.conflict = true
                end
            end
        end
    end
    for path, record in pairs(paths) do
        local manga = departed[record.id]
        if manga and owner:chapterArchiveExists(path) then
            local group = groups[record.id] or { title = manga.title or record.entry.manga_title or record.id, targets = {} }
            groups[record.id] = group
            local chapter = { id = record.chapter_id, name = record.entry.chapter_name }
            local target = { manga = manga, chapter = chapter, path = path }
            if not record.conflict and record.chapter_id ~= "" and queue.manual_deletion then
                local capture = queue.manual_deletion:capture(queue:getKey(manga, chapter), path, root)
                if not capture.reason then target.capture = capture end
            end
            group.targets[#group.targets + 1] = target
        end
    end
    return groups
end

local function isCurrent(owner, scope, auth)
    local credentials = Settings:load()
    return not owner.suwayomi_host_retired
        and Settings:normalizeEndpointScope(credentials.server_url) == scope
        and Settings:getAuthIdentity(credentials) == auth
end

local function showSyncResult(owner, queue, scope, auth, summary, doc, departed)
    if not next(departed) then owner:showMessage(summary); return end
    local groups = collectDepartedDownloads(owner, queue, doc, departed)
    local titles, count = {}, 0
    for _, group in pairs(groups) do
        titles[#titles + 1] = group.title
        count = count + #group.targets
    end
    if count == 0 then owner:showMessage(summary); return end
    table.sort(titles)
    local shown = table.concat(titles, "\n", 1, math.min(5, #titles))
    if #titles > 5 then shown = shown .. "\n…" end
    UI.showConfirm({
        text = summary .. "\n\n"
            .. I18n.f("The server Library no longer contains %1 manga with %2 local files. Delete these downloads?",
                #titles, count) .. "\n" .. shown,
        ok_text = I18n.t("Delete downloads"),
        cancel_text = I18n.t("Keep downloads"),
        ok_callback = function()
            if not isCurrent(owner, scope, auth) then return end
            local library = Settings:loadLibraryCache(Settings:load())
            if not library then return end
            local present, removed = {}, 0
            for _, manga in ipairs(library.manga) do present[tostring(manga.id)] = true end
            for id, group in pairs(groups) do
                if not present[id] then
                    for _, target in ipairs(group.targets) do
                        if target.capture and not queue:isArchivePathBusy(target.path) then
                            local deleted = owner:deleteChapterFromDeviceWithOptions(target.manga, target.chapter, {
                                chapter_path = target.path, expected_capture = target.capture, keep_reading_metadata = true,
                                quiet_active = true, quiet_missing = true, quiet_delete_failed = true, skip_refresh = true,
                            })
                            if deleted then removed = removed + 1 end
                        end
                    end
                end
            end
            owner:showMessage(I18n.f("Deleted %1 local files. Kept or unavailable: %2.", removed, count - removed))
        end,
    })
end

function Methods:syncLibraryFromServer()
    if self.server_sync_request or self.pending_read_sync_active then
        self:showMessage(I18n.t("Sync is already running."))
        return false
    end
    local credentials = Settings:load()
    local scope = Settings:normalizeEndpointScope(credentials.server_url)
    if not scope then
        self:showMessage(I18n.t("Set up your Suwayomi server login first."))
        return false
    end
    local auth, store = Settings:getAuthIdentity(credentials), Settings:getStore()
    local queue = self:getDownloadQueue()
    local root = Settings:loadDownloadDirectory()
    if not queue:checkStoreFence() or queue:isRecovering() then
        self:showMessage(I18n.t("Could not save server sync."))
        return false
    end
    local tracked = Snapshot.trackedManga(store:load())
    local context = self.current_chapter_context
    if context and context.manga and context.manga.id then tracked[tostring(context.manga.id)] = true end
    local filters = Settings:loadMangaScanlatorFilters()
    local request = {}
    self.server_sync_request = request

    local function release()
        if self.server_sync_request ~= request then return false end
        self.server_sync_request = nil
        if not isCurrent(self, scope, auth) or Settings:loadDownloadDirectory() ~= root then return false end
        self:schedulePendingReadSync()
        return true
    end

    local launched, active = pcall(RequestJob.start, {
        owner = self,
        credentials = credentials,
        request = { action = "fetch_server_sync", tracked_manga = tracked, scanlator_filters = filters },
        loading_message = I18n.t("Synchronizing with server…"),
        result_prefix = "server_sync",
        timeout_seconds = 120,
        on_cancel = release,
        on_finish = function(result)
            if not release() then return end
            if not result or not result.ok then
                self:showMessage(I18n.t("Could not sync with server. Local state was kept."))
                return
            end
            local selected = {}
            for _, manga in ipairs(type(result.manga) == "table" and result.manga or {}) do
                if type(manga) == "table" and Snapshot.isTracked(tracked, manga) then
                    selected[tostring(manga.id)] = true
                end
            end
            local library, chapters = Settings:prepareServerSyncCaches(scope, result, selected, filters)
            if not library then
                self:showMessage(I18n.t("Could not sync with server. Local state was kept."))
                return
            end
            local staged, stage_error = Settings:prepareChapterCacheIndex(scope, chapters.mangas, true)
            if not staged then
                Debug.log({ operation = "server_sync", event = "error", error = stage_error })
                self:showMessage(I18n.t("Could not save server sync."))
                return
            end
            self:cancelMangaNetworkRequests()
            local client = self:getClient()
            client:cancelLibraryNetworkRequests()
            local counts, departed
            local called, saved, err = pcall(store.saveDocument, store, function(doc)
                counts, departed = Snapshot.apply(doc, library, chapters, queue, function(path, key)
                    local state = doc.manual_archive_state
                    local archives = type(state) == "table" and state.archives
                    local archive = type(archives) == "table" and archives[key]
                    local original = type(archive) == "table" and archive.path == path and not archive.retired
                        and archive.evidence or nil
                    return ArchiveIdentity.inspect(path, root, original)
                end, staged.index)
            end)
            staged.finish(called and saved)
            if not called or not saved then
                Debug.log({ operation = "server_sync", event = "error", error = (not called and saved) or err })
                if queue:isBlocked() then queue:scheduleReconciliation() end
                self:showMessage(I18n.t("Could not save server sync."))
                return
            end
            if counts.jobs > 0 and not queue:reconcile() then queue:scheduleReconciliation() end
            local summary = I18n.f("Synced %1 manga and %2 chapters from the server. Cleared %3 outdated downloads and set aside %4 local read changes.",
                #library.manga, counts.chapters, counts.jobs, counts.pending)
            local deferred = 0
            for _ in pairs(type(result.deferred_chapters) == "table" and result.deferred_chapters or {}) do
                deferred = deferred + 1
            end
            if counts.relinked > 0 then
                summary = summary .. "\n" .. I18n.f("Reused %1 existing chapter files.", counts.relinked)
            end
            if deferred > 0 then
                summary = summary .. "\n" .. I18n.f("Open %1 manga to refresh their chapter lists.", deferred)
            end
            showSyncResult(self, queue, scope, auth, summary, store:load(), departed)
        end,
    })
    if self.server_sync_request == request then
        if not launched or not active then
            release()
            self:showMessage(I18n.t("Could not sync with server. Local state was kept."))
            return false
        end
        request.active = active
    end
    return launched and active ~= nil
end

return { methods = Methods }
