-- Boundary: match recorded local downloads to a fresh server snapshot.
-- Only unambiguous source/title and chapter matches can publish a new association.

local Archives = {}

local function copy(row)
    local result = {}
    for field, value in pairs(row or {}) do result[field] = value end
    return result
end

function Archives.mangaIdentity(title, source)
    local id = type(source) == "table" and source.id
    if id and tostring(id) ~= "" and type(title) == "string" and title ~= "" then
        return tostring(id) .. "\n" .. title
    end
end

local function originKey(row)
    return tostring(row.endpoint_scope or "") .. "\n" .. tostring(row.manga_id or "")
end

local function unique(index, key, item)
    if key then index[key] = index[key] == nil and item or false end
end

local function chapterMatch(chapters, record)
    local matches = {}
    for _, chapter in ipairs(chapters) do
        if chapter.name == record.chapter_name
            and (record.chapter_number == nil or chapter.chapter_number == record.chapter_number)
            and (record.scanlator == nil or chapter.scanlator == record.scanlator) then
            matches[#matches + 1] = chapter
        end
    end
    if #matches ~= 1 then return nil end
    local chapter = matches[1]
    if tostring(chapter.id) == tostring(record.chapter_id) or record.chapter_number ~= nil then
        return chapter
    end
end

function Archives.relink(doc, library, chapter_cache, queue, inspect, original_ledger, onRelink)
    if not inspect then return 0 end
    local scope = library.endpoint_scope
    local destinations = {}
    for _, manga in ipairs(library.manga) do
        unique(destinations, Archives.mangaIdentity(manga.title, manga.source), manga)
    end
    local contexts, ledger = doc.reader_return_contexts or {}, doc.chapter_ledger or {}
    local candidates, hints = {}, {}

    local function addHint(row)
        local identity = Archives.mangaIdentity(row.manga_title, row.source)
        if not identity then return end
        local origin = originKey(row)
        if hints[origin] == nil then hints[origin] = identity
        elseif hints[origin] ~= identity then hints[origin] = false end
    end
    local function addRecord(row, has_context)
        if type(row) ~= "table" or type(row.path) ~= "string" or not row.manga_id or not row.chapter_id then return end
        if has_context then addHint(row) end
        local record = candidates[row.path]
        if not record then
            candidates[row.path] = { row = row }
        elseif originKey(record.row) ~= originKey(row) or tostring(record.row.chapter_id) ~= tostring(row.chapter_id) then
            record.conflict = true
        end
    end
    for _, context in pairs(contexts) do addRecord(context, true) end
    for _, row in pairs(original_ledger) do addRecord(row, false) end
    -- Earlier syncs could detach a file-backed ledger entry without a reader context.
    local retained = type(doc.server_sync_retained) == "table" and doc.server_sync_retained.read
    for _, scoped in pairs(type(retained) == "table" and retained or {}) do
        for _, row in pairs(type(scoped) == "table" and scoped or {}) do
            if type(row) == "table" and row.path and not candidates[row.path] then addRecord(row, false) end
        end
    end

    for _, manga in ipairs(type(doc.library_cache) == "table" and doc.library_cache.manga or {}) do
        addHint({ endpoint_scope = doc.library_cache.endpoint_scope, manga_id = manga.id,
            manga_title = manga.title, source = manga.source })
    end
    local associations = type(doc.download_refill) == "table" and doc.download_refill.associations
    for _, association in pairs(type(associations) == "table" and associations or {}) do
        local manga = type(association) == "table" and association.manga
        if type(manga) == "table" then
            addHint({ endpoint_scope = association.endpoint_scope, manga_id = manga.id,
                manga_title = manga.title, source = manga.source })
        end
    end

    local by_key = {}
    for path, candidate in pairs(candidates) do
        local row = candidate.row
        if not candidate.conflict and type(row.chapter_name) == "string" then
            local identity = hints[originKey(row)]
            local manga = identity and destinations[identity]
            local listing = manga and chapter_cache.mangas[tostring(manga.id)]
            local chapter = listing and chapterMatch(listing.chapters, row)
            if chapter and identity == Archives.mangaIdentity(row.manga_title, manga.source) then
                local key = queue:getKey(manga, chapter)
                local old_key = queue:getKey({ id = row.manga_id }, { id = row.chapter_id })
                if row.endpoint_scope ~= scope or key ~= old_key then
                    if not queue:isChapterBusy(key) and not queue:isChapterBusy(old_key) then
                        local evidence, reason = inspect(path, old_key)
                        if evidence then
                            unique(by_key, key, { path = path, manga = manga, chapter = chapter, old_key = old_key })
                        elseif reason == "missing" then
                            if type(ledger[old_key]) == "table" and ledger[old_key].path == path then
                                local detached = copy(ledger[old_key])
                                detached.path, detached.archive_generation = nil, nil
                                ledger[old_key] = detached
                            end
                            contexts[path] = nil
                            onRelink(old_key, old_key)
                        end
                    end
                end
            end
        end
    end

    local count = 0
    for key, target in pairs(by_key) do
        local entry = ledger[key]
        if target and (not entry or not entry.path or entry.path == target.path) then
            local manga, chapter = target.manga, target.chapter
            local old_key = target.old_key
            if old_key ~= key and type(ledger[old_key]) == "table" then
                local old = copy(ledger[old_key])
                if old.path == target.path then old.path, old.archive_generation = nil, nil end
                ledger[old_key] = old
            end
            local linked = {
                manga_id = tostring(manga.id), manga_title = manga.title, chapter_id = tostring(chapter.id),
                chapter_name = chapter.name, endpoint_scope = scope, path = target.path, read = chapter.is_read,
            }
            ledger[key] = linked
            local context = copy(contexts[target.path])
            for field, value in pairs(linked) do context[field] = value end
            context.archive_generation, context.read = nil, nil
            context.source, context.in_library = manga.source, true
            context.chapter_number, context.source_order, context.scanlator =
                chapter.chapter_number, chapter.source_order, chapter.scanlator
            context.thumbnail_url = manga.thumbnail_url
            contexts[target.path] = context
            onRelink(old_key, key)
            count = count + 1
        end
    end
    doc.reader_return_contexts = contexts
    return count
end

return Archives
