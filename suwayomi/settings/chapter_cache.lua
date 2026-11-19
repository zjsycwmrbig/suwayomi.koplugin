-- Boundary: immutable chapter-list files and their small settings index.
-- The primary settings transaction is the only authority for published files.

local SettingsStore = require("suwayomi/settings/store")
local Cache = { version = 2 }
local sequence = 0

local function directory(store)
    return store.path:gsub("%.lua$", "") .. "_chapters"
end

local function validName(name)
    return type(name) == "string" and name:match("^list%-%x+%-%x+%-%x+%.lua$") ~= nil
end

local function pathFor(store, name)
    if validName(name) then return directory(store) .. "/" .. name end
end

local function ensureDirectory(store)
    local root = directory(store)
    if store.io.dir_exists and store.io.dir_exists(root) then return true end
    local mkdir = store.io.mkdir or require("suwayomi/fs").mkdir
    local called, made = pcall(mkdir, root)
    if not called or not made then return false end
    local parent = store.path:gsub(string.char(92), "/"):match("^(.*)/[^/]+$") or "."
    local synced, result, err = pcall(store.io.sync_dir, parent)
    return synced and result ~= false and (result ~= nil or err == nil)
end

function Cache.isCollection(index, scope)
    return type(index) == "table" and (index.version == 1 or index.version == Cache.version)
        and index.endpoint_scope == scope and type(index.mangas) == "table"
end

function Cache.read(store, index, id)
    local entry = index.mangas[id]
    if index.version == 1 then return entry end
    local path = type(entry) == "table" and pathFor(store, entry.file)
    if not path then return nil end
    local blob = SettingsStore:new{ path = path, io = store.io }:load()
    if blob.version == 1 and blob.endpoint_scope == index.endpoint_scope and blob.manga_id == id then
        return blob.listing
    end
end

local function files(index)
    local result = {}
    if type(index) == "table" and index.version == Cache.version and type(index.mangas) == "table" then
        for _, entry in pairs(index.mangas) do
            if type(entry) == "table" and validName(entry.file) then result[entry.file] = true end
        end
    end
    return result
end

local function remove(store, names, keep)
    for name in pairs(names) do
        if not (keep and keep[name]) then pcall(store.io.remove, pathFor(store, name)) end
    end
end

function Cache.finish(store, previous, staged, created, committed)
    -- A directory sync error may have left either settings version on disk.
    if store:isBlocked() then
        store.pending_chapter_cache = { previous = previous, staged = staged, created = created }
        return
    end
    if committed then remove(store, files(previous), files(staged))
    else remove(store, created or {}) end
end

function Cache.finishReconciliation(store, committed)
    local pending = store.pending_chapter_cache
    if not pending then return end
    store.pending_chapter_cache = nil
    Cache.finish(store, pending.previous, pending.staged, pending.created, committed)
end

local function write(store, scope, id, listing, created)
    if not ensureDirectory(store) then return nil, "chapter_cache_directory_unavailable" end
    local name, path
    repeat
        sequence = sequence + 1
        name = string.format("list-%x-%x-%08x.lua", os.time(), sequence, math.random(0, 0x7fffffff))
        path = pathFor(store, name)
    until not store.io.read(path)
    created[name] = true
    local blob = SettingsStore:new{ path = path, io = store.io }
    local saved, err = blob:saveDocument(function(doc)
        doc.version, doc.endpoint_scope, doc.manga_id, doc.listing = 1, scope, id, listing
    end)
    if not saved then return nil, err end
    local checked = SettingsStore:new{ path = path, io = store.io }:load()
    if checked.version ~= 1 or checked.endpoint_scope ~= scope or checked.manga_id ~= id
        or not SettingsStore.valuesEqual(checked.listing, listing) then
        return nil, "chapter_cache_verification_failed"
    end
    local manga = listing.manga
    return { file = name, manga = {
        id = manga.id, title = manga.title, source = manga.source, in_library = manga.in_library,
    } }
end

-- For a single directory refresh, retain other references. For a full sync,
-- publish exactly the server-confirmed directory set.
function Cache.stage(store, previous, scope, updates, replace, valid)
    if store:isBlocked() then return nil, "store_blocked" end
    local index = { version = Cache.version, endpoint_scope = scope, mangas = {} }
    local matching = Cache.isCollection(previous, scope)
    local listings, created = {}, {}
    if matching and not replace then
        for id, entry in pairs(previous.mangas) do
            if previous.version == Cache.version then
                if type(entry) == "table" and validName(entry.file) then index.mangas[id] = entry end
            elseif type(id) == "string" and valid(id, entry) then
                listings[id] = entry
            end
        end
    end
    for id, listing in pairs(updates) do listings[id] = listing end
    for id, listing in pairs(listings) do
        local entry, err
        if matching and previous.version == Cache.version then
            local cached = Cache.read(store, previous, id)
            if SettingsStore.valuesEqual(cached, listing) then entry = previous.mangas[id] end
        end
        if not entry then entry, err = write(store, scope, id, listing, created) end
        if not entry then
            remove(store, created)
            return nil, err
        end
        index.mangas[id] = entry
    end
    return index, nil, created
end

return Cache
