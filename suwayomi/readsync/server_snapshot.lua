-- Boundary: explicit server-authoritative sync planning and checked settings updates.
-- This module never writes to the server or touches archive files.

local Archives = require("suwayomi/readsync/sync_archives")
local Snapshot = {}

local function members(library)
    local result = {}
    for _, manga in ipairs(type(library) == "table" and type(library.manga) == "table" and library.manga or {}) do
        if type(manga) == "table" and manga.id ~= nil then result[tostring(manga.id)] = manga end
    end
    return result
end

local function trackIdentity(tracked, title, source)
    local identity = Archives.mangaIdentity(title, source)
    if identity then tracked[identity] = true end
end

function Snapshot.isTracked(tracked, manga)
    local identity = Archives.mangaIdentity(manga.title, manga.source)
    return tracked[tostring(manga.id)] or (identity and tracked[identity])
end

function Snapshot.trackedManga(doc)
    local tracked = {}
    local cache = doc.chapter_cache
    if type(cache) == "table" and type(cache.mangas) == "table" then
        for id, listing in pairs(cache.mangas) do
            tracked[tostring(id)] = true
            if type(listing) == "table" and type(listing.manga) == "table" then
                trackIdentity(tracked, listing.manga.title, listing.manga.source)
            end
        end
    end
    for _, records in pairs({ ledger = doc.chapter_ledger, contexts = doc.reader_return_contexts }) do
        if type(records) == "table" then
            for _, entry in pairs(records) do
                if type(entry) == "table" and entry.manga_id ~= nil then
                    tracked[tostring(entry.manga_id)] = true
                    trackIdentity(tracked, entry.manga_title, entry.source)
                end
            end
        end
    end
    for _, job in ipairs(type(doc.download_queue) == "table" and doc.download_queue or {}) do
        if type(job) == "table" and type(job.manga) == "table" and job.manga.id ~= nil then
            tracked[tostring(job.manga.id)] = true
        end
    end
    return tracked
end

local function retain(doc, bucket, key, record, origin)
    doc.server_sync_retained = doc.server_sync_retained or {}
    local retained = doc.server_sync_retained
    retained[bucket] = retained[bucket] or {}
    local scope = type(origin) == "string" and origin or ""
    retained[bucket][scope] = retained[bucket][scope] or {}
    retained[bucket][scope][key] = record
end

function Snapshot.apply(doc, library, chapter_cache, queue, inspect, chapter_index)
    local scope = library.endpoint_scope
    local previous, current = members(doc.library_cache), members(library)
    local old_chapters = doc.chapter_cache
    if type(old_chapters) == "table" and type(old_chapters.mangas) == "table" then
        for id, listing in pairs(old_chapters.mangas) do
            local manga = type(listing) == "table" and listing.manga
            if type(manga) == "table" and tostring(manga.id) == id and manga.in_library == true then
                previous[id] = previous[id] or manga
            end
        end
    end
    for _, context in pairs(doc.reader_return_contexts or {}) do
        if type(context) == "table" and context.in_library == true and context.manga_id then
            local id = tostring(context.manga_id)
            previous[id] = previous[id] or { id = id, title = context.manga_title, source = context.source }
        end
    end
    local identities = {}
    for _, manga in ipairs(library.manga) do
        local identity = Archives.mangaIdentity(manga.title, manga.source)
        if identity then identities[identity] = true end
    end
    local departed, retired_refills = {}, {}
    for id, manga in pairs(previous) do
        local identity = Archives.mangaIdentity(manga.title, manga.source)
        if not current[id] and not (identity and identities[identity]) then
            departed[id], retired_refills[id] = manga, true
        end
    end

    local ledger = doc.chapter_ledger or {}
    doc.chapter_ledger = ledger
    local original_ledger = {}
    for key, entry in pairs(ledger) do original_ledger[key] = entry end
    local counts = { chapters = 0, pending = 0, jobs = 0 }
    local remote_chapters, revoke, invalidate_archives = {}, {}, {}
    for id, listing in pairs(chapter_cache.mangas) do
        local rows = {}
        remote_chapters[id] = rows
        for _, chapter in ipairs(listing.chapters) do
            counts.chapters = counts.chapters + 1
            local key = id .. ":" .. tostring(chapter.id)
            rows[tostring(chapter.id)] = true
            local entry = ledger[key]
            if type(entry) == "table" then
                local same_chapter = entry.endpoint_scope == scope
                    and tostring(entry.manga_id) == id and tostring(entry.chapter_id) == tostring(chapter.id)
                local disagrees = entry.pending_read_sync == true
                    and (not same_chapter or (entry.pending_read_state == nil and entry.read == true
                        or entry.pending_read_state == true) ~= chapter.is_read)
                if not same_chapter or disagrees then
                    retain(doc, "read", key, entry, entry.endpoint_scope)
                end
                if disagrees then counts.pending = counts.pending + 1 end
                if not same_chapter then
                    ledger[key] = nil
                    revoke[key] = true
                else
                    local updated = {}
                    for field, value in pairs(entry) do updated[field] = value end
                    updated.read = chapter.is_read
                    updated.pending_read_sync, updated.pending_read_state = nil, nil
                    ledger[key] = updated
                end
            end
            if not chapter.is_read then revoke[key] = true end
        end
    end

    -- Removed chapters can no longer acknowledge an upload; keep their local files and prior intent.
    for key, entry in pairs(ledger) do
        if type(entry) == "table" then
            local id = tostring(entry.manga_id)
            local rows = remote_chapters[id]
            if departed[id] or (rows and not rows[tostring(entry.chapter_id)]) then
                if entry.pending_read_sync == true then
                    retain(doc, "read", key, entry, entry.endpoint_scope)
                    local updated = {}
                    for field, value in pairs(entry) do updated[field] = value end
                    updated.pending_read_sync, updated.pending_read_state = nil, nil
                    ledger[key] = updated
                    counts.pending = counts.pending + 1
                end
                revoke[key] = true
                invalidate_archives[key] = true
            end
        end
    end

    local jobs = doc.download_queue or {}
    for index = #jobs, 1, -1 do
        local job = jobs[index]
        if type(job) == "table" and job.version == nil and type(job.manga) == "table"
            and type(job.chapter) == "table" and type(job.key) == "string"
            and (job.state == "failed" or job.state == "queued") and not queue:isChapterBusy(job.key) then
            local id = tostring(job.manga.id)
            local origin = job.manga.endpoint_scope
            local rows = remote_chapters[id]
            if departed[id] or (rows and (origin ~= scope or not rows[tostring(job.chapter.id)])) then
                retain(doc, "downloads", job.key, job, origin)
                table.remove(jobs, index)
                counts.jobs = counts.jobs + 1
            end
        end
    end
    local refill = doc.download_refill
    if queue.refill and type(refill) == "table" and type(refill.requests) == "table" then
        for id, request in pairs(refill.requests) do
            if remote_chapters[id] and type(request) == "table" and request.endpoint_scope ~= scope then
                retired_refills[id] = true
            end
        end
        if next(retired_refills) then queue.refill:retire(doc, retired_refills) end
    end
    counts.relinked = Archives.relink(doc, library, chapter_cache, queue, inspect, original_ledger, function(old_key, key)
        invalidate_archives[old_key], invalidate_archives[key] = true, true
        revoke[old_key], revoke[key] = true, true
        local old_entry = ledger[old_key]
        if old_key ~= key and type(old_entry) == "table" and old_entry.pending_read_sync == true then
            retain(doc, "read", old_key, original_ledger[old_key], old_entry.endpoint_scope)
            old_entry.pending_read_sync, old_entry.pending_read_state = nil, nil
            counts.pending = counts.pending + 1
        end
    end)
    if queue.manual_deletion then
        queue.manual_deletion:invalidateForServerSync(doc, invalidate_archives)
        queue.manual_deletion:applyRead(doc, nil, revoke)
    end

    doc.library_cache = library
    doc.chapter_cache = chapter_index or chapter_cache
    return counts, departed
end

return Snapshot
