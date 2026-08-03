local M           = {}

local pickertools = require("ezpick.base.pickertools")

--- Rows handed to the picker per query. A runtimepath with a few plugins on it
--- carries tens of thousands of tags, and rendering them all costs more than the
--- tail of a fuzzy ranking is ever worth.
local _MAX_ITEMS  = 1000

--- Index of `:help` tags -> { help file, in-file anchor }, parsed from the
--- `doc/tags` files across the runtimepath (the same index `:help` consults).
--- Each line reads `tag<tab>file<tab>/*tag*`; the anchor is the address with its
--- leading `/` dropped (`/*:write*` -> `*:write*`), searched for literally since
--- the surrounding `*` make it unique. Rebuilt on each picker open rather than
--- memoised, so nothing is retained in module memory between invocations and a
--- newly installed plugin's docs show up straight away.
---@return table<string, { file: string, anchor: string }>
function M.tag_index()
    local tags = {}
    for _, tagfile in ipairs(vim.api.nvim_get_runtime_file("doc/tags", true)) do
        local dir = vim.fs.dirname(tagfile)
        local ok, lines = pcall(vim.fn.readfile, tagfile)
        if ok then
            for _, line in ipairs(lines) do
                local tag, rel, addr = line:match("^([^\t]+)\t([^\t]+)\t(.+)$")
                if tag then
                    tags[tag] = { file = vim.fs.joinpath(dir, rel), anchor = (addr:gsub("^/", "")) }
                end
            end
        end
    end
    return tags
end

--- Build the previewer for a help tag: the whole help file, positioned on the
--- line carrying the tag's anchor. Files are cached for as long as the picker is
--- open so scrolling through tags of the same file re-reads nothing.
---@param index table<string, { file: string, anchor: string }>
---@return ezpick.Picker.AsyncPreviewLoader
local function make_previewer(index)
    ---@type table<string, string[]>
    local file_cache = {}

    return function(data, _, callback)
        local hit = index[data.tag]
        if not hit then
            callback({})
            return
        end

        local lines = file_cache[hit.file]
        if not lines then
            local ok, content = pcall(vim.fn.readfile, hit.file)
            lines             = (ok and content) or {}
            file_cache[hit.file] = lines
        end

        local lnum = 1
        for i, line in ipairs(lines) do
            if line:find(hit.anchor, 1, true) then
                lnum = i
                break
            end
        end

        callback({
            content  = lines,
            filepath = hit.file,
            filetype = "help",
            pos      = { lnum, 0 },
        })
    end
end

---@return ezpick.PickerSpec?
function M.spec()
    local index = M.tag_index()
    local tags  = vim.tbl_keys(index)

    if #tags == 0 then
        vim.notify("No help tags found; is 'helptags' up to date?", vim.log.levels.WARN)
        return nil
    end
    table.sort(tags)

    return {
        prompt         = "Help Tags",
        enable_preview = true,
        previewer      = make_previewer(index),
        finder         = function(query, _, _, callback)
            -- Help tag lists run to tens of thousands of entries, so they are
            -- matched in a single batched `matchfuzzypos` (which also ranks them)
            -- instead of one call per tag.
            local matched, positions
            if query == "" then
                matched = tags
            else
                local result = vim.fn.matchfuzzypos(tags, query:lower())
                matched, positions = result[1], result[2]
            end

            local items = {}
            for i = 1, math.min(#matched, _MAX_ITEMS) do
                local tag    = matched[i]
                local chunks = pickertools.highlight_chunks(tag, positions and vim.tbl_map(
                    function(p) return p + 1 end, positions[i]) or nil)
                table.insert(chunks, { "  " .. vim.fs.basename(index[tag].file), "Comment" })
                ---@type ezpick.Picker.Item
                table.insert(items, {
                    label_chunks = chunks,
                    data         = { tag = tag },
                })
            end
            callback(items)
        end,
        on_confirm     = function(data)
            if data then vim.cmd("help " .. vim.fn.fnameescape(data.tag)) end
        end,
    }
end

return M
