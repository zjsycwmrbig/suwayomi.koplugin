-- Boundary: observational on-device archive inventory.
-- Lists recorded paths and CBZs under the configured root; never adopts files,
-- infers server identity, reads archives, or mutates read state. No symlink traversal.
local Inventory = {}

function Inventory.collect(settings, fs)
    fs = fs or require("suwayomi/fs")
    local by_path, entries, issues = {}, {}, {}
    local ledger = settings:loadChapterLedger() or {}
    local contexts = settings:loadReaderReturnContexts() or {}
    local function add(path)
        if type(path) ~= "string" or path == "" or path:find("\0", 1, true) then return end
        if by_path[path] then return by_path[path] end
        local attributes = fs.symlinkattributes(path)
        if not attributes or attributes.mode ~= "file" then return end
        local item = { path = path, size = attributes.size or 0, records = {} }
        by_path[path], entries[#entries + 1] = item, item
        return item
    end
    for _, records in ipairs({ ledger, contexts }) do
        for _, record in pairs(records) do
            if type(record) == "table" then
                local item = add(record.path)
                if item then item.records[#item.records + 1] = record end
            end
        end
    end
    local root = settings:loadDownloadDirectory()
    local visited = 0
    local function walk(directory, depth)
        if depth > 20 or visited >= 20000 then issues.limited = true; return end
        local ok = pcall(function()
            for name in fs.dir(directory) do
                if name ~= "." and name ~= ".." then
                    visited = visited + 1
                    if visited > 20000 then issues.limited = true; return end
                    local path = directory .. "/" .. name
                    local attributes = fs.symlinkattributes(path)
                    if attributes and attributes.mode == "directory" then walk(path, depth + 1)
                    elseif attributes and attributes.mode == "file" and name:lower():match("%.cbz$") then add(path) end
                end
            end
        end)
        if not ok then issues.inaccessible = true end
    end
    if type(root) == "string" and root ~= "" and root ~= "/" then
        local attributes = fs.symlinkattributes(root)
        if attributes and attributes.mode == "directory" then walk(root, 0) end
    end
    for _, item in ipairs(entries) do
        local chosen = item.records[1]
        for _, record in ipairs(item.records) do
            if chosen and (record.endpoint_scope ~= chosen.endpoint_scope
                or tostring(record.manga_id) ~= tostring(chosen.manga_id)
                or tostring(record.chapter_id) ~= tostring(chosen.chapter_id)) then item.conflict = true end
        end
        if chosen and chosen.manga_id and chosen.chapter_id and not item.conflict then
            item.manga = { id = chosen.manga_id, title = chosen.manga_title, endpoint_scope = chosen.endpoint_scope }
            item.chapter = { id = chosen.chapter_id, name = chosen.chapter_name, local_path = item.path }
            local entry = ledger[tostring(chosen.manga_id) .. ":" .. tostring(chosen.chapter_id)]
            item.read = type(entry) == "table" and entry.path == item.path
                and entry.endpoint_scope == chosen.endpoint_scope and entry.read == true
                and not (entry.pending_read_sync and entry.pending_read_state == false)
        else
            item.manga = { title = "local" }
            item.chapter = { name = item.path, local_path = item.path }
        end
        item.key = tostring(item.manga.id or item.manga.title) .. ":" .. tostring(item.chapter.id or item.chapter.name)
        item.label = (item.manga.title and item.manga.id and (item.manga.title .. " / ") or "")
            .. (chosen and chosen.chapter_name or item.path:match("[^/]+$") or item.path)
    end
    table.sort(entries, function(a, b) return a.label == b.label and a.path < b.path or a.label < b.label end)
    return entries, issues
end

return Inventory
