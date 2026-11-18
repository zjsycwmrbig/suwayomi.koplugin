-- Boundary: Downloads hub and download-ahead setup UI.
--
-- Responsibility: format download and refill rows, display their details, and
-- offer optional automatic finish marking after explicit download-ahead setup.
-- Owned state: returned widgets own their dialog and checkbox state.
-- Dependencies: KOReader widgets/UIManager, plugin i18n, shared list menus,
-- status formatting, and menu utilities.
-- External data: queue snapshots are display-only here; controller actions own
-- retries, cancellation, deletion, and navigation.

local I18n = require("suwayomi/i18n")
local StatusFormatter = require("suwayomi/downloads/status_formatter")
local menu_utils = require("suwayomi/ui/menu_utils")

local DownloadsUI = {}
local formatDownloadProgress
local formatFailedDownloadText
local formatRefillReason
local formatRefillState

function DownloadsUI.showLocalDownloads(items, selected, options)
    local list_menu = require("suwayomi/ui/list_menu")
    local rows = {}
    for _, item in ipairs(items) do
        local archive = item
        rows[#rows + 1] = {
            text = (selected[item.path] and "[x] " or "[ ] ") .. item.label,
            subtitle = item.path,
            mandatory = I18n.f("%1 MB", string.format("%.1f", item.size / 1048576))
                .. (item.read and (" · " .. I18n.t("Read")) or ""),
            keep_menu_open = true,
            callback = function() options.onToggle(archive.path) end,
        }
    end
    if #rows == 0 then rows[1] = { text = I18n.t("No local chapter archives found."), select_enabled = false } end
    local menu_options = {}
    for key, value in pairs(options) do menu_options[key] = value end
    menu_options.title = I18n.f("On-device downloads (%1)", #items)
    menu_options.item_table = rows
    if options.menu then
        menu_utils.bindMenuCallbacks(rows, options.menu)
        list_menu.update(options.menu, menu_options)
        return options.menu
    end
    local menu = list_menu.show(menu_options)
    menu_utils.bindMenuCallbacks(rows, menu)
    return menu
end

function DownloadsUI.showAutoMarkPrompt(options)
    local ConfirmBox = require("ui/widget/confirmbox")
    local CheckButton = require("ui/widget/checkbutton")
    local UIManager = require("ui/uimanager")
    local checkbox
    local dialog = ConfirmBox:new{
        text = I18n.t("Automatically mark all KOReader documents finished at their end-of-document action?")
            .. "\n\n" .. I18n.t("Helps Auto-download refill after chapters close. Manual marking still works.")
            .. "\n\n" .. I18n.t("Your end action stays unchanged. Finished chapters follow your automatic removal settings."),
        ok_text = I18n.t("Enable"),
        cancel_text = I18n.t("Keep disabled"),
        ok_callback = options.onEnable,
        cancel_callback = function() options.onKeepDisabled(checkbox.checked) end,
        -- Native ConfirmBox treats dismissal as Cancel; only the button may retire this prompt.
        onClose = function(self)
            UIManager:close(self)
            return true
        end,
    }
    checkbox = CheckButton:new{
        text = I18n.t("Don't ask again"),
        checked = false,
        parent = dialog,
    }
    dialog:addWidget(checkbox)
    UIManager:show(dialog)
    return dialog
end

local function getErrorText(job)
    local error_message = job and job.progress and job.progress.error
    if error_message ~= nil and tostring(error_message):find("%S") then
        return tostring(error_message)
    end
    return I18n.t("No error details were recorded.")
end

function DownloadsUI.showDownloadErrorDetails(job, options)
    options = options or {}
    local TextViewer = require("ui/widget/textviewer")
    local UIManager = require("ui/uimanager")
    local text = options.context or ""
    if job and job.state == "queued" and job.retry_at then
        text = text .. "\n\n" .. I18n.t("Retry scheduled") .. "\n" .. StatusFormatter.formatRetryTime(job.retry_at)
    end
    local archive_status = StatusFormatter.formatArchiveStatus(job and job.progress)
    if archive_status then text = text .. "\n\n" .. archive_status end
    if text ~= "" then
        text = text .. "\n\n"
    end
    local viewer
    local buttons = {}
    local function addAction(id, label, callback, include_disabled)
        if not callback and not include_disabled then return end
        buttons[#buttons + 1] = {
            id = id,
            text = label,
            enabled = callback ~= nil,
            callback = function()
                if callback then
                    viewer:onClose()
                    callback()
                end
            end,
        }
    end
    addAction("retry", I18n.t("Retry"), options.onRetry, not archive_status)
    addAction("verify_download", I18n.t("Verify download"), options.onVerify)
    addAction("redownload", I18n.t("Redownload"), options.onRedownload)
    buttons[#buttons + 1] = {
        id = "close",
        text = I18n.t("Close"),
        callback = function() viewer:onClose() end,
    }
    viewer = TextViewer:new{
        title = I18n.t("Error details"),
        text = text .. getErrorText(job),
        buttons_table = { buttons },
    }
    UIManager:show(viewer)
    return viewer
end

local function getListMenu()
    return require("suwayomi/ui/list_menu")
end

local function formatDownloadJobLabel(job)
    local manga_title = job and job.manga and job.manga.title or nil
    local chapter_name = job and job.chapter and job.chapter.name or nil
    local label = manga_title or tostring(job and job.key or "")
    if chapter_name and chapter_name ~= "" then
        label = label .. " / " .. chapter_name
    end
    return label
end

local function getMangaGroupKey(manga)
    if type(manga) ~= "table" then return "" end
    return tostring(manga.id or manga.title or "")
end

local function getMangaGroupTitle(manga, fallback)
    if type(manga) == "table" and manga.title and manga.title ~= "" then
        return tostring(manga.title)
    end
    return fallback or I18n.t("Unknown manga")
end

local function appendMangaJob(groups, job, state)
    local manga = job and job.manga or {}
    local key = getMangaGroupKey(manga)
    if key == "" then key = tostring(job and job.key or "unknown") end
    local group = groups[key]
    if not group then
        group = { key = key, manga = manga, jobs = {}, active = 0, queued = 0, failed = 0 }
        groups[key] = group
    end
    group.jobs[#group.jobs + 1] = job
    group[state] = group[state] + 1
end

function DownloadsUI.groupDownloadJobs(snapshot)
    local groups = {}
    for _, job in ipairs(snapshot and snapshot.active or {}) do appendMangaJob(groups, job, "active") end
    for _, job in ipairs(snapshot and snapshot.queued or {}) do appendMangaJob(groups, job, "queued") end
    for _, job in ipairs(snapshot and snapshot.failed or {}) do appendMangaJob(groups, job, "failed") end
    for _, item in ipairs(snapshot and snapshot.local_downloads or {}) do
        local manga = item.manga or {}
        local key = getMangaGroupKey(manga)
        if key == "" then key = item.key or item.label or item.path end
        local group = groups[key]
        if not group then
            group = { key = key, manga = manga, jobs = {}, active = 0, queued = 0, failed = 0, downloaded = 0 }
            groups[key] = group
        end
        group.jobs[#group.jobs + 1] = {
            key = item.key, manga = manga, chapter = item.chapter, state = "downloaded",
            local_item = item, progress = {},
        }
        group.downloaded = (group.downloaded or 0) + 1
    end
    for _, request in ipairs(snapshot and snapshot.refills or {}) do
        local key = tostring(request.manga_id or request.manga_title or "")
        if key ~= "" then
            local group = groups[key]
            if not group then
                group = {
                    key = key,
                    manga = { id = request.manga_id, title = request.manga_title },
                    jobs = {}, active = 0, queued = 0, failed = 0,
                }
                groups[key] = group
            end
            group.refill = request
        end
    end
    local result = {}
    for key, group in pairs(groups) do
        group.paused = snapshot and snapshot.paused_mangas and snapshot.paused_mangas[key] == true
        result[#result + 1] = group
    end
    table.sort(result, function(a, b) return getMangaGroupTitle(a.manga, a.key) < getMangaGroupTitle(b.manga, b.key) end)
    return result
end

function DownloadsUI.buildDownloadMangaMenuTable(groups, options)
    options = options or {}
    local rows = {}
    for _, group in ipairs(groups or {}) do
        local counts = {}
        if group.active > 0 then counts[#counts + 1] = I18n.f("%1 downloading", group.active) end
        if group.queued > 0 then counts[#counts + 1] = I18n.f("%1 queued", group.queued) end
        if group.failed > 0 then counts[#counts + 1] = I18n.f("%1 failed", group.failed) end
        if (group.downloaded or 0) > 0 then counts[#counts + 1] = I18n.f("%1 downloaded", group.downloaded) end
        if group.refill then counts[#counts + 1] = formatRefillState(group.refill.state) end
        if group.paused then table.insert(counts, 1, I18n.t("Paused")) end
        local subtitle = #counts > 0 and table.concat(counts, " · ") or I18n.t("No active download tasks")
        if group.refill and group.refill.next_retry_at then
            subtitle = subtitle .. "\\n" .. StatusFormatter.formatRetryTime(group.refill.next_retry_at)
        end
        rows[#rows + 1] = {
            text = getMangaGroupTitle(group.manga, group.key),
            subtitle = subtitle,
            mandatory = #group.jobs > 0 and I18n.count(#group.jobs, "%1 task", "%1 tasks")
                or I18n.t("Auto-download"),
            manga = group.manga,
            thumbnail_url = group.manga.thumbnail_url,
            thumbnail_placeholder = true,
            thumbnail_variant = "manga_cover",
            thumbnail_width = 64,
            thumbnail_height = 96,
            download_group = group,
            keep_menu_open = true,
            callback = function(menu)
                if options.on_select then return options.on_select(group, menu) end
            end,
        }
    end
    if #rows == 0 then
        rows[1] = { text = I18n.t("No manga download tasks."), select_enabled = false }
    end
    return rows
end

function DownloadsUI.buildDownloadMangaDetailTable(group, options)
    options = options or {}
    local rows = {}
    local filter = options.filter or "all"
    for _, job in ipairs(group and group.jobs or {}) do
        local state = job.state or "queued"
        local include = filter == "all"
            or filter == "active" and state == "downloading"
            or filter == "queued" and state == "queued"
            or filter == "failed" and state == "failed"
            or filter == "downloaded" and state == "downloaded"
        if include then
            rows[#rows + 1] = {
                text = formatDownloadJobLabel(job),
                subtitle = state == "failed" and formatFailedDownloadText(job)
                    or StatusFormatter.formatArchiveStatus(job.progress),
                mandatory = state == "downloading" and (I18n.t("Downloading")
                    .. (formatDownloadProgress(job) ~= "" and (" " .. formatDownloadProgress(job)) or ""))
                    or I18n.t(state == "failed" and "Failed" or state == "downloaded" and "Downloaded" or "Queued"),
                keep_menu_open = true,
                job = job,
                callback = function(menu)
                    if options.on_select then options.on_select(job, menu) end
                end,
            }
        end
    end
    if #rows == 0 then
        rows[1] = { text = I18n.t("No chapters match this filter."), select_enabled = false }
    end
    return rows
end

formatDownloadProgress = function(job)
    local progress = job and job.progress or nil
    local current = progress and tonumber(progress.current) or nil
    local total = progress and tonumber(progress.total) or nil
    if current and total and total > 0 then
        return tostring(current) .. "/" .. tostring(total)
    end
    return ""
end

formatFailedDownloadText = function(job)
    local summary = getErrorText(job):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return StatusFormatter.shortenChapterTitle(summary, 0, 100)
end

formatRefillReason = function(reason)
    if reason == "endpoint_changed" then
        return I18n.t("Server changed. Open this manga on the current server and choose Auto-download again.")
    elseif reason == "origin_unknown" then
        return I18n.t("Server association unknown. Open this manga on the current server and choose Auto-download again.")
    elseif reason == "configuration_missing" then
        return I18n.t("Check the connection and download folder in Settings.")
    elseif reason == "metadata_missing" then
        return I18n.t("Manga or source details are unavailable. Refresh the chapter list.")
    elseif reason == "unsupported_state" then
        return I18n.t("Saved auto-download data is unsupported. Existing data is preserved.")
    elseif reason == "scanlator_missing" then
        return I18n.t("No chapters match the saved scanlator filter. Other scanlators are not selected.")
    elseif reason == "terminal_failure" then
        return I18n.t("An unread chapter could not be downloaded. Use its Retry or Redownload action.")
    elseif reason == "manual_delete_pending" then
        return I18n.t("An unread chapter is waiting for manual deletion. Auto-download will not replace it.")
    elseif reason == "ownership_unproved" then
        return I18n.t("Archive or download ownership is not verified. Existing files and work are preserved.")
    elseif reason == "fetch_failed" then
        return I18n.t("Could not load chapters. Auto-download will try again automatically.")
    elseif reason == "fetch_rejected" then
        return I18n.t("The server rejected the chapter request. Check connection settings, then choose Check again.")
    elseif reason == "persistence_failed" then
        return I18n.t("Could not confirm that the auto-download request was saved. No new downloads are confirmed.")
    elseif reason == "choices_changed" then
        return I18n.t("Reading or download choices changed. Auto-download will use the current choices.")
    end
    return I18n.t("Waiting to check which unread chapters need downloading.")
end

formatRefillState = function(state)
    if state == "blocked" then
        return I18n.t("Auto-download blocked")
    elseif state == "waiting" then
        return I18n.t("Auto-download waiting")
    end
    return I18n.t("Auto-download pending")
end

function DownloadsUI.formatRefillStatus(request)
    local text = formatRefillState(request.state) .. "\n" .. formatRefillReason(request.reason)
    if request.next_retry_at then
        text = text .. "\n\n" .. I18n.t("Retry scheduled") .. "\n"
            .. StatusFormatter.formatRetryTime(request.next_retry_at)
    end
    return text
end

function DownloadsUI.showRefillDetails(request, callbacks)
    local TextViewer = require("ui/widget/textviewer")
    local UIManager = require("ui/uimanager")
    local text = DownloadsUI.formatRefillStatus(request)
    text = text .. "\n\n" .. I18n.t("Check again checks which unread chapters need downloading. It does not retry failed chapters or cancel pending manual deletion.")
        .. "\n\n" .. I18n.t("Turn off auto-download stops future automatic additions for this manga. Queued and running downloads continue.")
    local viewer
    viewer = TextViewer:new{
        title = I18n.f("Auto-download: %1", request.manga_title or tostring(request.manga_id or "")),
        text = text,
        buttons_table = {
            {
                {
                    id = "retry_refill",
                    text = I18n.t("Check again"),
                    enabled = callbacks.retry_refill ~= nil,
                    callback = function()
                        if callbacks.refill_is_current and not callbacks.refill_is_current(request) then return end
                        if callbacks.retry_refill then
                            viewer:onClose()
                            callbacks.retry_refill(request)
                        end
                    end,
                },
                {
                    id = "stop_refill",
                    text = I18n.t("Turn off auto-download"),
                    enabled = callbacks.stop_refill ~= nil,
                    callback = function()
                        if callbacks.refill_is_current and not callbacks.refill_is_current(request) then return end
                        if callbacks.stop_refill then
                            viewer:onClose()
                            callbacks.stop_refill(request)
                        end
                    end,
                },
            },
            {
                {
                    id = "close",
                    text = I18n.t("Close"),
                    callback = function() viewer:onClose() end,
                },
            },
        },
    }
    UIManager:show(viewer)
end

local function isDownloadsSnapshotEmpty(snapshot)
    return #(snapshot.active or {}) == 0
        and #(snapshot.queued or {}) == 0
        and #(snapshot.failed or {}) == 0
        and #(snapshot.refills or {}) == 0
end

local function buildMenuOptions(snapshot, callbacks, options)
    options = options or {}
    return {
        title = options.title or I18n.t("Suwayomi Downloads"),
        bottom_navigation = options.bottom_navigation,
        view_mode = options.view_mode,
        thumbnail_credentials = options.thumbnail_credentials,
        title_bar_left_icon = options.title_bar_left_icon,
        item_table = DownloadsUI.buildDownloadsMenuTable(snapshot, callbacks, options),
        close_callback = options.close_callback,
        on_title_bar_left_tap = options.on_title_bar_left_tap,
        on_title_bar_left_hold = options.on_title_bar_left_hold,
    }
end

local function appendEmptyStateRows(menu_table, snapshot, options)
    local active_count = #(snapshot.active or {})
    local queued_count = #(snapshot.queued or {})
    local failed_count = #(snapshot.failed or {})
    local folder = options.download_directory_summary
    local has_folder = folder and folder ~= ""
    if not has_folder then
        folder = I18n.t("not set")
    end

    table.insert(menu_table, {
        text = I18n.t("Download folder"),
        subtitle = folder,
        select_enabled = false,
    })
    table.insert(menu_table, {
        text = I18n.t("Queue"),
        -- Translators: %1 active downloads, %2 queued downloads, %3 failed downloads.
        subtitle = I18n.f("%1 active, %2 queued, %3 failed", active_count, queued_count, failed_count),
        select_enabled = false,
    })
    table.insert(menu_table, {
        text = I18n.t("No downloads queued."),
        select_enabled = false,
    })
    table.insert(menu_table, {
        text = has_folder
            and I18n.f("Downloaded chapters are in %1.", folder)
            or I18n.t("Set a download folder in Settings > Downloads."),
        select_enabled = false,
    })
end

function DownloadsUI.buildDownloadsMenuTable(snapshot, callbacks, options)
    snapshot = snapshot or {}
    callbacks = callbacks or {}
    options = options or {}
    local menu_table = {}

    if isDownloadsSnapshotEmpty(snapshot) then
        appendEmptyStateRows(menu_table, snapshot, options)
    end

    for _, job in ipairs(snapshot.active or {}) do
        local progress = formatDownloadProgress(job)
        local prefix = progress ~= ""
            and I18n.f("Downloading %1", progress)
            or I18n.t("Downloading")
        table.insert(menu_table, {
            text = formatDownloadJobLabel(job),
            -- Job actions open overlays; native selection must not run the
            -- hub's close callback and detach its live status updates.
            keep_menu_open = true,
            subtitle = StatusFormatter.formatArchiveStatus(job.progress),
            mandatory = prefix,
            callback = callbacks.onSelectActive and function(menu)
                callbacks.onSelectActive(job, menu)
            end or nil,
        })
    end

    local queued_label = I18n.t("Queued")
    for _, job in ipairs(snapshot.queued or {}) do
        table.insert(menu_table, {
            text = formatDownloadJobLabel(job),
            keep_menu_open = true,
            mandatory = snapshot.paused and I18n.t("Paused") or (job.retry_at and I18n.t("Retry scheduled") or queued_label),
            subtitle = StatusFormatter.formatArchiveStatus(job.progress)
                or (job.retry_at and StatusFormatter.formatRetryTime(job.retry_at) or nil),
            callback = function(menu)
                if callbacks.onSelectQueued then
                    callbacks.onSelectQueued(job, menu)
                end
            end,
        })
    end

    local failed_label = I18n.t("Failed")
    for _, job in ipairs(snapshot.failed or {}) do
        table.insert(menu_table, {
            text = formatDownloadJobLabel(job),
            keep_menu_open = true,
            subtitle = formatFailedDownloadText(job),
            mandatory = StatusFormatter.formatArchiveStatus(job.progress) or failed_label,
            callback = function(menu)
                if callbacks.onSelectFailed then
                    callbacks.onSelectFailed(job, menu)
                elseif callbacks.onRetryFailed then
                    callbacks.onRetryFailed(job, menu)
                end
            end,
        })
    end

    for _, request in ipairs(snapshot.refills or {}) do
        local subtitle = formatRefillReason(request.reason)
        if request.next_retry_at then
            subtitle = subtitle .. "\n" .. StatusFormatter.formatRetryTime(request.next_retry_at)
        end
        table.insert(menu_table, {
            text = request.manga_title or tostring(request.manga_id or ""),
            keep_menu_open = true,
            mandatory = formatRefillState(request.state),
            subtitle = subtitle,
            callback = function()
                if callbacks.refill_is_current and not callbacks.refill_is_current(request) then return end
                DownloadsUI.showRefillDetails(request, callbacks)
            end,
        })
    end

    if #(snapshot.failed or {}) > 0 then
        table.insert(menu_table, {
            text = I18n.t("Clear failed"),
            callback = function(menu)
                if callbacks.onClearFailed then
                    callbacks.onClearFailed(menu)
                end
            end,
        })
    end

    if callbacks.onLocalDownloads then
        table.insert(menu_table, { text = I18n.t("On-device downloads"), keep_menu_open = true,
            callback = callbacks.onLocalDownloads })
    end
    if callbacks.onPauseDownloads then
        table.insert(menu_table, { text = snapshot.paused and I18n.t("Resume all downloads") or I18n.t("Pause all downloads"),
            keep_menu_open = true, callback = callbacks.onPauseDownloads })
    end
    return menu_table
end

function DownloadsUI.showDownloadMangaDetail(group, callbacks, options)
    options = options or {}
    local list_menu = getListMenu()
    local rows = {}
    local filters = {
        { id = "all", text = I18n.t("All chapters") },
        { id = "undownloaded", text = I18n.t("Undownloaded") },
        { id = "downloaded", text = I18n.t("Downloaded"), count = group and (group.downloaded or 0) },
        { id = "failed", text = I18n.t("Failed"), count = group and group.failed or 0 },
        { id = "active", text = I18n.t("Downloading or queued"),
            count = group and ((group.active or 0) + (group.queued or 0)) },
    }
    for _, choice in ipairs(filters) do
        rows[#rows + 1] = {
            text = choice.text,
            mandatory = choice.count and I18n.count(choice.count, "%1 chapter", "%1 chapters") or nil,
            keep_menu_open = true,
            callback = function(menu)
                if callbacks and callbacks.onFilter then callbacks.onFilter(group, choice.id, menu) end
            end,
        }
    end
    if group and group.refill then
        rows[#rows + 1] = {
            text = formatRefillState(group.refill.state),
            subtitle = formatRefillReason(group.refill.reason),
            refill = group.refill,
            keep_menu_open = true,
            callback = function(menu)
                if callbacks and callbacks.onSelectRefill then
                    callbacks.onSelectRefill(group.refill, menu)
                end
            end,
        }
    end
    rows[#rows + 1] = {
        text = I18n.t("Download undownloaded chapters"),
        subtitle = I18n.t("Adds missing chapters in batches of up to 50."),
        keep_menu_open = true,
        callback = function(menu)
            if callbacks and callbacks.onDownloadUndownloaded then
                callbacks.onDownloadUndownloaded(group, menu)
            end
        end,
    }
    rows[#rows + 1] = {
        text = group and group.paused and I18n.t("Resume downloads for this manga")
            or I18n.t("Pause downloads for this manga"),
        subtitle = I18n.t("Current active chapter finishes; queued chapters wait."),
        destructive = group and group.paused ~= true,
        keep_menu_open = true,
        callback = function(menu)
            if callbacks and callbacks.onTogglePause then callbacks.onTogglePause(group, menu) end
        end,
    }
    rows[#rows + 1] = {
        text = I18n.t("Cancel all tasks for this manga"),
        subtitle = I18n.t("Stops current work and clears queued chapters for this manga."),
        destructive = true,
        keep_menu_open = true,
        callback = function(menu)
            if callbacks and callbacks.onCancelTasks then callbacks.onCancelTasks(group, menu) end
        end,
    }
    rows[#rows + 1] = {
        text = I18n.t("Delete downloaded chapters for this manga"),
        subtitle = I18n.t("Removes on-device archives. Server chapters and read state stay unchanged."),
        destructive = true,
        keep_menu_open = true,
        callback = function(menu)
            if callbacks and callbacks.onDeleteDownloads then callbacks.onDeleteDownloads(group, menu) end
        end,
    }
    for _, filter in ipairs({ "active", "queued", "failed" }) do
        local task_rows = DownloadsUI.buildDownloadMangaDetailTable(group, {
            filter = filter,
            on_select = callbacks and callbacks.onSelectJob,
        })
        if not (task_rows[1] and task_rows[1].select_enabled == false) then
            local headings = {
                active = I18n.t("Active downloads"),
                queued = I18n.t("Queued downloads"),
                failed = I18n.t("Failed downloads"),
            }
            rows[#rows + 1] = { text = headings[filter], select_enabled = false }
            for _, row in ipairs(task_rows) do rows[#rows + 1] = row end
        end
    end
    local menu_options = {
        title = getMangaGroupTitle(group and group.manga),
        item_table = rows,
        title_bar_left_icon = options.title_bar_left_icon,
        on_title_bar_left_tap = options.on_title_bar_left_tap,
        close_callback = options.close_callback,
        bottom_navigation = options.bottom_navigation,
    }
    local menu = list_menu.show(menu_options)
    menu_utils.bindMenuCallbacks(rows, menu)
    return menu
end

function DownloadsUI.showDownloadsMenu(snapshot, callbacks, options)
    options = options or {}
    if options.grouped_by_manga then
        local groups = DownloadsUI.groupDownloadJobs(snapshot)
        local rows = DownloadsUI.buildDownloadMangaMenuTable(groups, {
            on_select = callbacks and callbacks.onSelectManga,
        })
        local menu = getListMenu().show({
            title = options.title or I18n.t("Downloads"),
            bottom_navigation = options.bottom_navigation,
            view_mode = options.view_mode,
            thumbnail_credentials = options.thumbnail_credentials,
            title_bar_left_icon = options.title_bar_left_icon,
            on_title_bar_left_tap = options.on_title_bar_left_tap,
            on_title_bar_left_hold = options.on_title_bar_left_hold,
            close_callback = options.close_callback,
            item_table = rows,
        })
        menu_utils.bindMenuCallbacks(rows, menu)
        return menu
    end
    local menu_options = buildMenuOptions(snapshot, callbacks, options)
    local menu = getListMenu().show(menu_options)
    menu_utils.bindMenuCallbacks(menu.item_table, menu)
    return menu
end

function DownloadsUI.updateDownloadsMenu(menu, snapshot, callbacks, options)
    if not menu then
        return
    end
    local menu_options = buildMenuOptions(snapshot, callbacks, options)
    if options and options.grouped_by_manga then
        menu_options.item_table = DownloadsUI.buildDownloadMangaMenuTable(
            DownloadsUI.groupDownloadJobs(snapshot),
            { on_select = callbacks and callbacks.onSelectManga }
        )
    end
    menu_utils.bindMenuCallbacks(menu_options.item_table, menu)
    return getListMenu().update(menu, menu_options)
end

return DownloadsUI
