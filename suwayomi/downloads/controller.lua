-- Boundary: DownloadsController.
--
-- Responsibility: Owns Downloads controls, local inventory/batch removal, durable refill commands, finish-marking setup, and read reconciliation.
-- Owned state: Uses the device-local queue only; it must not call Suwayomi server download mutations.
-- Dependencies: KOReader UI helpers and Suwayomi runtime modules, including the plugin i18n facade.
-- External data: callers must continue to treat API responses, settings values, worker files, and filesystem paths as untrusted until checked locally.

local SuwayomiSettings = require("suwayomi/settings")
local SuwayomiUI = require("suwayomi/ui")
local StatusFormatter = require("suwayomi/downloads/status_formatter")
local I18n = require("suwayomi/i18n")

local DownloadsController = {}
DownloadsController.__index = DownloadsController

-- Controllers expose new(deps) for a consistent boundary; methods remain plugin-bound mixins so this refactor can move code without changing callback behavior.
function DownloadsController:new(deps)
    deps = deps or {}
    return setmetatable({
        plugin = deps.plugin,
    }, self)
end

local Methods = {}

function Methods:showLocalDownloads(refresh, rescan)
    if self.suwayomi_host_retired then return false end
    local previous = self.current_local_downloads_menu
    if not refresh or not previous then self.local_download_selection = {} end
    local items, issues = self.local_download_items, {}
    if not refresh or rescan or not items then
        items, issues = require("suwayomi/downloads/local_library").collect(SuwayomiSettings)
    end
    self.local_download_items = items
    local valid = {}
    for _, item in ipairs(items) do valid[item.path] = true end
    for path in pairs(self.local_download_selection) do
        if not valid[path] then self.local_download_selection[path] = nil end
    end
    local menu
    local function live()
        return not self.suwayomi_host_retired and menu and self.current_local_downloads_menu == menu
            and (not self.isSuwayomiScreenActive or self:isSuwayomiScreenActive(menu))
    end
    local actions = {
        { id = "select_all", text = I18n.t("Select all") },
        { id = "clear_selection", text = I18n.t("Clear selection") },
        { id = "refresh", text = I18n.t("Refresh") },
        { id = "delete_selected", text = I18n.t("Delete selected local downloads"), destructive = true },
        { id = "delete_read", text = I18n.t("Delete all read local downloads"), destructive = true },
        { id = "delete_all", text = I18n.t("Delete all local downloads"), destructive = true },
    }
    local options = self:getTitleBarMenuOptions({
        title = I18n.t("On-device downloads"), actions = actions,
        captureActionGuard = function() return live end,
        onSelect = function(action)
            if not live() then return false end
            if action.id == "select_all" then
                for _, item in ipairs(items) do self.local_download_selection[item.path] = true end
            elseif action.id == "clear_selection" then self.local_download_selection = {}
            elseif action.id ~= "refresh" then return self:confirmLocalDownloadDeletion(action.id, menu) end
            return self:showLocalDownloads(true, action.id == "refresh")
        end,
    })
    options.onToggle = function(path)
        if not live() then return end
        self.local_download_selection[path] = not self.local_download_selection[path] or nil
        self:showLocalDownloads(true)
    end
    options.close_callback = function()
        if self.current_local_downloads_menu == menu then self.current_local_downloads_menu = nil end
    end
    options.menu = refresh and previous or nil
    menu = SuwayomiUI.showLocalDownloads(items, self.local_download_selection, options)
    self.current_local_downloads_menu = menu
    if not options.menu and self.trackSuwayomiScreen then self:trackSuwayomiScreen("local_downloads", menu) end
    if issues.limited or issues.inaccessible then
        self:showMessage(I18n.t("Some folders could not be scanned or the scan limit was reached. The list may be incomplete."))
    end
    return menu
end

function Methods:confirmLocalDownloadDeletion(mode, menu)
    if mode ~= "delete_selected" and mode ~= "delete_read" and mode ~= "delete_all" then return false end
    local queue = self:getDownloadQueue()
    local captures, blocked = {}, 0
    for _, item in ipairs(self.local_download_items or {}) do
        if mode == "delete_all" or mode == "delete_read" and item.read
            or mode == "delete_selected" and self.local_download_selection[item.path] then
            local capture = not item.conflict and not queue:isArchivePathBusy(item.path)
                and queue.manual_deletion:capture(item.key, item.path, SuwayomiSettings:loadDownloadDirectory())
            if capture and not capture.reason then
                captures[#captures + 1] = { item = item, capture = capture }
            else blocked = blocked + 1 end
        end
    end
    if #captures == 0 then
        self:showMessage(I18n.t("No eligible local downloads. Busy, open, conflicting, or unverified files are preserved."))
        return false
    end
    SuwayomiUI.showConfirm({
        text = I18n.f("Delete %1 local chapter files and their KOReader sidecars? This cannot be undone. Server files and read flags are unchanged. %2 files are blocked.", #captures, blocked),
        ok_text = I18n.t("Delete downloads"),
        ok_callback = function()
            if self.suwayomi_host_retired or self.current_local_downloads_menu ~= menu
                or (self.isSuwayomiScreenActive and not self:isSuwayomiScreenActive(menu)) then return end
            local removed, failed = 0, blocked
            local current = {}
            for _, item in ipairs(require("suwayomi/downloads/local_library").collect(SuwayomiSettings)) do current[item.path] = item end
            for _, prepared in ipairs(captures) do
                local item, capture = prepared.item, prepared.capture
                local latest = current[item.path]
                if latest and not latest.conflict and latest.key == item.key and (mode ~= "delete_read" or latest.read)
                    and not queue:ownsChapter(item.key) and not queue:isArchivePathBusy(item.path) then
                    local ok = self:deleteChapterFromDeviceWithOptions(item.manga, item.chapter, {
                        chapter_path = item.path, expected_capture = capture, skip_refresh = true,
                        quiet_active = true, quiet_missing = true, quiet_delete_failed = true,
                    })
                    if ok then removed = removed + 1 else failed = failed + 1 end
                else failed = failed + 1 end
            end
            self.local_download_selection = {}
            self:showLocalDownloads(true, true)
            self:showMessage(I18n.f("Deleted %1 local downloads; %2 skipped or failed.", removed, failed))
            self:refreshDownloadsMenu()
        end,
    })
    return true
end

local function cancellationFailureMessage(state)
    if state == "store_blocked" or (type(state) == "string" and state:match("^ambiguous_post_replacement")) then
        return I18n.t("Cannot cancel download: storage is ambiguous")
    end
    if state and state ~= "missing" and state ~= "queued" and state ~= "downloading" and state ~= "downloaded"
        and state ~= "skipped" and state ~= "failed" then
        return I18n.f("Could not cancel download: %1", state)
    end
end

local function currentDownloadJob(queue, job)
    local current = job and queue:findPersistentJob(job.key)
    return current and queue:copySnapshotJob(current, current.state)
end

function Methods:getDownloadJobTitle(job)
    local manga_title = job and job.manga and job.manga.title or nil
    local chapter_name = job and job.chapter and job.chapter.name or nil
    if manga_title and manga_title ~= "" and chapter_name and chapter_name ~= "" then
        return manga_title .. " / " .. chapter_name
    end
    return manga_title or chapter_name or tostring(job and job.key or "")
end


function Methods:canOpenDownloadJobChapterList(job)
    return job and job.manga and job.manga.id ~= nil and tostring(job.manga.id) ~= ""
end


function Methods:formatCancelQueuedDownloadMessage(state)
    local failure = cancellationFailureMessage(state)
    if failure then return failure end
    if state == "downloading" then
        return I18n.t("Download is already downloading.")
    end
    return I18n.t("Download is no longer queued.")
end


function Methods:getDownloadsTitleActions(snapshot)
    snapshot = snapshot or {}
    local actions = {}
    if #(snapshot.active or {}) > 0 or #(snapshot.queued or {}) > 0 or #(snapshot.refills or {}) > 0 then
        table.insert(actions, { id = "cancel_all", text = I18n.t("Cancel all downloads"), destructive = true })
    end
    if #(snapshot.failed or {}) > 0 then
        table.insert(actions, { id = "clear_failed", text = I18n.t("Clear failed") })
    end
    table.insert(actions, snapshot.paused
        and { id = "resume_all", text = I18n.t("Resume all downloads") }
        or { id = "pause_all", text = I18n.t("Pause all downloads") })
    table.insert(actions, { id = "local_downloads", text = I18n.t("On-device downloads") })

    return actions
end


function Methods:performDownloadsTitleAction(action, menu)
    if not action then
        return false
    end

    local queue = self:getDownloadQueue()
    if action.id == "local_downloads" then
        self:showLocalDownloads()
        return true
    elseif action.id == "pause_all" or action.id == "resume_all" then
        if self.suwayomi_host_retired then return false end
        local ok, err = queue:setPaused(action.id == "pause_all")
        if not ok then self:showMessage(I18n.f("Could not update download pause state: %1", err or "unknown")) end
        self:refreshDownloadsMenu()
        return ok
    elseif action.id == "cancel_all" then
        local callback = function()
            local _count, err = queue:cancelAll()
            if err and self.showMessage then
                local message = err == "store_blocked" and I18n.t("Cannot cancel downloads: storage is ambiguous") or err
                self:showMessage(message)
            end
            self:closeMenu(menu)
            self:showDownloads()
        end
        if SuwayomiUI.showConfirm then
            SuwayomiUI.showConfirm({
                text = I18n.t("Cancel all downloads?"),
                ok_text = I18n.t("Cancel downloads"),
                ok_callback = callback,
                cancel_text = I18n.t("Keep downloading"),
            })
        else
            callback()
        end
        return true
    elseif action.id == "cancel_queued" then
        local _count, err = queue:cancelQueued()
        if err and self.showMessage then
            local message = err == "store_blocked" and I18n.t("Cannot cancel downloads: storage is ambiguous") or err
            self:showMessage(message)
        end
        self:closeMenu(menu)
        self:showDownloads()
        return true
    elseif action.id == "clear_failed" then
        local _count, err = queue:clearFailed()
        if err then
            self:showMessage(I18n.f("Could not clear failed downloads: %1", err))
        end
        self:closeMenu(menu)
        self:showDownloads()
        return true
    end
    return false
end


function Methods:getDownloadsTitleBarOptions(snapshot)
    if not self.getTitleBarMenuOptions then
        return {}
    end
    return self:getTitleBarMenuOptions({
        title = I18n.t("Downloads"),
        actions = self:getDownloadsTitleActions(snapshot),
        onSelect = function(action, menu)
            return self:performDownloadsTitleAction(action, menu)
        end,
    })
end

function Methods:getDownloadsMenuOptions(snapshot)
    local options = self:getDownloadsTitleBarOptions(snapshot)
    if self.getDownloadDirectorySummary then
        options.download_directory_summary = self:getDownloadDirectorySummary()
    else
        options.download_directory_summary = SuwayomiSettings:loadDownloadDirectory()
        if not options.download_directory_summary or options.download_directory_summary == "" then
            options.download_directory_summary = I18n.t("not set")
        end
    end
    return options
end


function Methods:retryDownloadJob(job)
    local ok, state = self:getDownloadQueue():retryFailed(job and job.key)
    if not ok then
        self:showMessage(state == "missing" and I18n.t("Download is no longer failed.")
            or I18n.t("Could not retry download."))
    end
    -- Rejected stale actions emit no queue notification. Rebuild chapter rows
    -- from current state instead of retaining cached failure labels.
    if self.refreshChapterMenu then
        self:refreshChapterMenu()
    end
    self:refreshDownloadsMenu()
    if self.refreshHomeDownloads then
        self:refreshHomeDownloads()
    end
    return ok, state
end


function Methods:redownloadDownloadJob(job)
    if self.suwayomi_host_retired then return false end
    self.chapter_archive_request = nil
    local queue = self:getDownloadQueue()
    local current = currentDownloadJob(queue, job)
    if not current or current.state ~= "failed"
        or not (current.repair or current.progress and current.progress.archive_state == "damaged") then
        self:showMessage(I18n.t("Download error is no longer available."))
        return false
    end
    local ok, state = queue:redownload(current.manga, current.chapter,
        current.download_directory or SuwayomiSettings:loadDownloadDirectory())
    if not ok then self:showMessage(I18n.t("Could not redownload chapter.")) end
    if self.refreshChapterMenu then self:refreshChapterMenu() end
    self:refreshDownloadsMenu()
    return ok, state
end

function Methods:verifyDownloadJob(job, is_current)
    local completed = false
    if self.suwayomi_host_retired or (is_current and not is_current()) then return false end
    local request = {}
    self.chapter_archive_request = request
    local queue = self:getDownloadQueue()
    local current = currentDownloadJob(queue, job)
    if not current or current.state ~= "failed" or not (current.progress and current.progress.archive_state) then
        self:showMessage(I18n.t("Download error is no longer available."))
        return false
    end
    local function live()
        return not self.suwayomi_host_retired and self.chapter_archive_request == request
            and (not is_current or is_current())
    end
    local accepted, err = queue:verifyArchive(current.manga, current.chapter,
        current.progress and current.progress.path, function(result)
            if completed or not live() then return end
            completed = true
            if result.stage == "persistence" then
                self:showMessage(result.error)
                return
            end
            if self.refreshChapterMenu then self:refreshChapterMenu() end
            self:refreshDownloadsMenu()
            if result.state ~= "valid" then
                self:showDownloadJobError(current, is_current)
            end
        end, { is_current = live })
    if not accepted then
        self:showMessage(StatusFormatter.formatVerificationStartError(err))
    end
    return accepted, err
end

function Methods:showDownloadJobError(job, is_current)
    local queue = self:getDownloadQueue()
    local current = currentDownloadJob(queue, job)
    if not current or not (current.state == "failed" or (current.state == "queued" and current.retry_at)) then
        self:showMessage(I18n.t("Download error is no longer available."))
        return false
    end

    local archive_state = current.progress and current.progress.archive_state
    local function live()
        return not self.suwayomi_host_retired and (not is_current or is_current())
    end
    return SuwayomiUI.showDownloadErrorDetails(current, {
        context = self:getDownloadJobTitle(current),
        -- Only an explicitly authorized repair may use ordinary Retry.
        onRetry = current.state == "failed" and (not archive_state or current.repair) and function()
            if not live() then return false end
            local latest = currentDownloadJob(queue, current)
            if latest and latest.state == "failed"
                and latest.progress and latest.progress.archive_state and not latest.repair then return false end
            return self:retryDownloadJob(latest or current)
        end or nil,
        onVerify = archive_state and current.state == "failed" and function()
            if not live() then return false end
            return self:verifyDownloadJob(current, live)
        end or nil,
        onRedownload = archive_state == "damaged" and current.state == "failed" and function()
            if not live() then return false end
            return self:redownloadDownloadJob(current)
        end or nil,
    })
end

function Methods:showFailedDownloadActions(job, menu)
    return self:showDownloadJobError(job, function()
        return not self.suwayomi_host_retired and (not menu or self.current_downloads_menu == menu)
    end)
end

function Methods:showChapterDownloadError(manga, chapter)
    local is_current = self.captureChapterActionGuard and self:captureChapterActionGuard()
    return self:showDownloadJobError({ key = self:getDownloadQueue():getKey(manga, chapter) }, function()
        return (not is_current or is_current())
            and (not self.isChapterInCurrentContext or self:isChapterInCurrentContext(manga, chapter))
    end)
end

function Methods:getDownloadsMenuCallbacks(view)
    view = view or self.current_downloads_menu
    local function live()
        local menu = type(view) == "function" and view() or view
        return not self.suwayomi_host_retired and menu ~= nil and self.current_downloads_menu == menu
            and (not self.isSuwayomiScreenActive or self:isSuwayomiScreenActive(menu))
            and (not self.suwayomi_navigation or self.suwayomi_navigation:isCurrent(menu))
    end
    local function refill_is_current(request)
        if not live() or not request or request.manga_id == nil or request.revision == nil then return false end
        local current = self:getMangaRefillRequest({ id = request.manga_id })
        return current ~= nil and current.revision == request.revision
    end
    return {
        onLocalDownloads = self.showLocalDownloads and function()
            if live() then return self:showLocalDownloads() end
        end or nil,
        onPauseDownloads = function()
            if live() then
                local queue = self:getDownloadQueue()
                return self:performDownloadsTitleAction({ id = queue:isPaused() and "resume_all" or "pause_all" })
            end
        end,
        refill_is_current = refill_is_current,
        retry_refill = function(request)
            if not refill_is_current(request) then return false end
            return self:performRefillAction("retry", request)
        end,
        stop_refill = function(request)
            if not refill_is_current(request) then return false end
            return self:performRefillAction("stop", request)
        end,
        onSelectActive = function(job, menu)
            self:showActiveDownloadActions(job, menu)
        end,
        onSelectQueued = function(job, menu)
            self:showQueuedDownloadActions(job, menu)
        end,
        onSelectFailed = function(job, menu)
            self:showFailedDownloadActions(job, menu)
        end,
        onClearFailed = function(menu)
            self:performDownloadsTitleAction({ id = "clear_failed" }, menu)
        end,
    }
end

function Methods:withDownloadsMenuTracking(options)
    options = options or {}
    local previous_close_callback = options.close_callback
    local tracked_menu
    options.close_callback = function(...)
        if self.current_downloads_menu == tracked_menu then
            self.current_downloads_menu = nil
        end
        if previous_close_callback then
            return previous_close_callback(...)
        end
    end
    return options, function(menu)
        tracked_menu = menu
        self.current_downloads_menu = menu
    end
end

function Methods:refreshDownloadsMenu()
    local menu = self.current_downloads_menu
    if not menu or not SuwayomiUI.updateDownloadsMenu then
        return false
    end
    if self.isSuwayomiScreenActive and not self:isSuwayomiScreenActive(menu) then
        self.current_downloads_menu = nil
        return false
    end

    local queue = self:getDownloadQueue()
    local snapshot = queue:getSnapshot()
    local options = self:getDownloadsMenuOptions(snapshot)
    SuwayomiUI.updateDownloadsMenu(menu, snapshot, self:getDownloadsMenuCallbacks(), options)
    return true
end


function Methods:showQueuedDownloadActions(job, menu)
    if not SuwayomiUI.showChapterActionsMenu then
        return
    end

    local actions = {
        { id = "cancel_queued", text = I18n.t("Cancel queued download") },
    }
    if self:canOpenDownloadJobChapterList(job) then
        table.insert(actions, { id = "open_chapter_list", text = I18n.t("Open chapter list") })
    end
    if job.retry_at then
        table.insert(actions, { id = "download_error", text = I18n.t("Download error") })
    end

    SuwayomiUI.showChapterActionsMenu({
        title = self:getDownloadJobTitle(job),
        actions = actions,
    }, function(action)
        if action and action.id == "download_error" then
            self:showDownloadJobError(job)
        elseif action and action.id == "cancel_queued" then
            local cancelled, state = self:getDownloadQueue():cancelPending(job.manga, job.chapter)
            self:closeMenu(menu)
            if not cancelled then
                self:showMessage(self:formatCancelQueuedDownloadMessage(state), { timeout = 2 })
            end
            self:showDownloads()
        elseif action and action.id == "open_chapter_list" then
            self:showChaptersForManga(job.manga)
        end
    end)
end


function Methods:showActiveDownloadActions(job, menu)
    if not SuwayomiUI.showChapterActionsMenu then
        return
    end
    local actions = {}
    if self:canOpenDownloadJobChapterList(job) then
        table.insert(actions, { id = "open_chapter_list", text = I18n.t("Open chapter list") })
    end
    table.insert(actions, { id = "cancel_download", text = I18n.t("Cancel download"), destructive = true })

    SuwayomiUI.showChapterActionsMenu({
        title = self:getDownloadJobTitle(job),
        actions = actions,
    }, function(action)
        if action and action.id == "open_chapter_list" then
            self:showChaptersForManga(job.manga)
        elseif action and action.id == "cancel_download" then
            local cancelled, state = self:getDownloadQueue():cancelPending(job.manga, job.chapter)
            self:closeMenu(menu)
            if not cancelled then
                self:showMessage(cancellationFailureMessage(state)
                    or I18n.t("Download is no longer active."), { timeout = 2 })
            end
            self:showDownloads()
        end
    end)
end


function Methods:showDownloads()
    local queue = self:getDownloadQueue()
    local snapshot = queue:getSnapshot()
    local options, trackMenu = self:withDownloadsMenuTracking(self:getDownloadsMenuOptions(snapshot))
    options.bottom_navigation = self.getBottomNavigation and self:getBottomNavigation("downloads")

    local menu
    local callbacks = self:getDownloadsMenuCallbacks(function() return menu end)
    menu = SuwayomiUI.showDownloadsMenu(snapshot, callbacks, options)
    trackMenu(menu)
    if self.trackSuwayomiScreen then
        self:trackSuwayomiScreen("downloads", menu)
    end
    return menu
end


function Methods:reconcileDownloadedChapterLedger(ledger)
    ledger = ledger or self:loadChapterLedger()
    local changed = false
    local read_count = 0

    for _index, entry in pairs(ledger or {}) do
        if type(entry) == "table" and type(entry.path) == "string" and entry.path ~= "" then
            local metadata_finished = self:isChapterPathFinishedInKoreader(entry.path)
            local explicit_unread = entry.pending_read_sync == true and entry.pending_read_state == false
            if metadata_finished and entry.read ~= true and not explicit_unread then
                entry.read = true
                if SuwayomiSettings:normalizeEndpointScope(entry.endpoint_scope) then
                    entry.pending_read_sync = true
                    entry.pending_read_state = true
                end
                changed = true
                read_count = read_count + 1
            end
        end
    end

    if changed then
        local saved, err = self:saveChapterLedger(ledger)
        if not saved then return 0, err end
        for _, entry in pairs(saved) do self:markCurrentContextChapterReadFromLedger(entry) end
    end

    return read_count
end




function Methods:performRefillAction(action, request)
    if self.suwayomi_host_retired or not request or request.manga_id == nil or request.revision == nil then return false end
    local refill = self:getDownloadQueue().refill
    local ok, err
    if action == "retry" then
        ok, err = refill:retry(request.manga_id, request.revision)
    elseif action == "stop" then
        ok, err = refill:stop(request.manga_id, request.revision)
    end
    if not ok and err then self:showMessage(I18n.f("Could not update auto-download: %1", err)) end
    self:refreshDownloadsMenu()
    if self.refreshChapterMenu then self:refreshChapterMenu({ quick = true }) end
    return ok, err
end

function Methods:getMangaRefillRequest(manga)
    for _, request in ipairs(self:getDownloadQueue().refill:snapshot()) do
        if request.manga_id == nil or tostring(request.manga_id) == tostring(manga and manga.id) then return request end
    end
end

function Methods:requestMangaRefill(manga)
    if self.suwayomi_host_retired then return false end
    local ok, err = self:getDownloadQueue().refill:request(manga)
    if not ok and err then self:showMessage(I18n.f("Could not update auto-download: %1", err)) end
    return ok, err
end

local function offerAutoMarkPrompt(self)
    local reader_settings = _G.G_reader_settings
    if not reader_settings or reader_settings:readSetting("end_document_auto_mark") == true
        or SuwayomiSettings:loadAutoMarkPromptDismissed() then return end

    local function retirePrompt()
        if self.suwayomi_host_retired then return false end
        local ok, err = SuwayomiSettings:dismissAutoMarkPrompt()
        if not ok then self:showMessage(err or I18n.t("Failed to save settings.")) end
        return ok
    end
    SuwayomiUI.showAutoMarkPrompt({
        onEnable = function()
            if retirePrompt() then reader_settings:saveSetting("end_document_auto_mark", true) end
        end,
        onKeepDisabled = function(dont_ask_again)
            if dont_ask_again then retirePrompt() end
        end,
    })
end

function Methods:setMangaDownloadAhead(manga, limit)
    if self.suwayomi_host_retired then return false end
    local ok, err = self:getDownloadQueue().refill:setPolicy(manga, limit)
    if not ok then
        self:showMessage(err or I18n.t("Failed to save settings."))
        return false, err
    end
    if self.refreshChapterMenu then self:refreshChapterMenu({ quick = true }) end
    if SuwayomiSettings:loadMangaKeepNextUnreadDownloads(manga) > 0 then offerAutoMarkPrompt(self) end
    return ok
end

function Methods:keepNextUnreadChaptersDownloaded(limit)
    if not self.current_chapter_context then return false end
    return self:keepNextUnreadChaptersForManga(self.current_chapter_context.manga, limit)
end


DownloadsController.methods = Methods

return DownloadsController
