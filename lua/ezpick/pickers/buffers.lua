local M           = {}

local pickertools = require("ezpick.base.pickertools")
local ui          = require("ezpick.util.ui")
local fsutil      = require("ezpick.util.fsutil")

---@type ezpick.queryflags.FlagDef[]
local FLAGS       = {
    { name = "ft",       type = "value",   multi = true,                     desc = "filter by filetype" },
    { name = "modified", type = "boolean", desc = "only modified buffers" },
    { name = "unloaded", type = "boolean", desc = "include unloaded buffers" },
    { name = "unlisted", type = "boolean", desc = "include unlisted buffers" },
}

---@param bufnr number
---@param query string
---@param flags table
---@return ezpick.Picker.Item?
local function buffer_to_picker_item(bufnr, query, flags)
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    local label
    if bufname ~= "" then
        label = fsutil.get_relative_path(bufname) or bufname
    else
        label = "[No Name]"
    end
    local modified = vim.bo[bufnr].modified
    local ft       = vim.bo[bufnr].filetype

    if flags.modified and not modified then return nil end
    for _, v in ipairs(flags.ft or {}) do
        if not ft:find(v:lower(), 1, true) then return nil end
    end

    local match = pickertools.match_label(label, query)
    if not match then return nil end

    local label_chunks = { { string.format("%3d", bufnr), "Comment" }, { ": ", "Nontext" } }
    vim.list_extend(label_chunks, match.chunks)
    if ft ~= "" then
        table.insert(label_chunks, { "  " .. ft, "Comment" })
    end
    if modified then
        table.insert(label_chunks, { " [+]", "Special" })
    end
    if not vim.api.nvim_buf_is_loaded(bufnr) then
        table.insert(label_chunks, { " [unloaded]", "Special" })
    end
    if not vim.bo[bufnr].buflisted then
        table.insert(label_chunks, { " [unlisted]", "Special" })
    end

    local mark      = vim.api.nvim_buf_get_mark(bufnr, '"')
    local lnum, col = unpack(mark)
    ---@type ezpick.Picker.Item
    return {
        label_chunks = label_chunks,
        score        = match.score,
        data         = { bufnr = bufnr, lnum = lnum, col = col },
    }
end

---@return ezpick.PickerSpec
function M.spec()
    local max_preview_size = 1024 * 1024
    local buffers          = vim.api.nvim_list_bufs()
    local current_buf      = vim.api.nvim_get_current_buf()

    return {
        prompt         = "Open Buffers",
        flags          = FLAGS,
        enable_preview = true,
        initial_cursor = function(items)
            for row, item in ipairs(items) do
                if item.data.bufnr == current_buf then return row end
            end
        end,
        finder         = function(query, flags, _, callback)
            local include_unloaded = flags.unloaded
            local include_unlisted = flags.unlisted
            local items = {}
            for _, bufnr in ipairs(buffers) do
                if (include_unloaded or vim.api.nvim_buf_is_loaded(bufnr))
                    and (include_unlisted or vim.bo[bufnr].buflisted)
                then
                    local item = buffer_to_picker_item(bufnr, query, flags)
                    if item then table.insert(items, item) end
                end
            end
            callback(items)
        end,
        previewer      = function(data, _, callback)
            local bufnr     = data.bufnr
            local cancelled = false
            vim.schedule(function()
                if bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
                    if not cancelled then
                        local size = vim.api.nvim_buf_get_offset(bufnr, vim.api.nvim_buf_line_count(bufnr))
                        if size > max_preview_size then
                            callback({ error_msg = "Buffer too large for preview" })
                            return
                        end
                        callback({
                            content  = vim.api.nvim_buf_get_lines(bufnr, 0, -1, true),
                            filetype = vim.bo[bufnr].filetype,
                        })
                    end
                else
                    callback({})
                end
            end)
            return function() cancelled = true end
        end,
        on_confirm     = function(data)
            if data then ui.smart_open_buffer(data.bufnr, data.lnum, data.col) end
        end,
    }
end

return M
