local M = {}

local ui          = require("ezpick.util.ui")
local pickertools = require("ezpick.base.pickertools")

---@return ezpick.PickerSpec
function M.spec()
    local cwd     = vim.fn.getcwd()
    local curbuf  = vim.api.nvim_get_current_buf()
    local seen    = {}
    seen[vim.fn.fnamemodify(vim.api.nvim_buf_get_name(curbuf), ":p")] = true

    local recent_files = {}

    local bufs = vim.fn.getbufinfo({ buflisted = 1 })
    table.sort(bufs, function(a, b) return a.lastused > b.lastused end)
    for _, info in ipairs(bufs) do
        if info.bufnr ~= curbuf and vim.bo[info.bufnr].buflisted then
            local full_path = vim.fn.fnamemodify(info.name, ":p")
            if full_path ~= "" and not seen[full_path] and vim.fn.filereadable(full_path) == 1 then
                seen[full_path] = true
                local match_path = (full_path:find(cwd, 1, true) == 1)
                    and vim.fn.fnamemodify(full_path, ":.")
                    or vim.fn.fnamemodify(full_path, ":~")
                table.insert(recent_files, {
                    full_path  = full_path,
                    match_path = match_path,
                })
            end
        end
    end
    for _, path in ipairs(vim.v.oldfiles) do
        if #recent_files >= 500 then break end
        local full_path = vim.fn.fnamemodify(path, ":p")
        if not seen[full_path] and vim.fn.filereadable(full_path) == 1 then
            seen[full_path] = true
            local match_path = (full_path:find(cwd, 1, true) == 1)
                and vim.fn.fnamemodify(full_path, ":.")
                or vim.fn.fnamemodify(full_path, ":~")
            table.insert(recent_files, {
                full_path  = full_path,
                match_path = match_path,
            })
        end
    end

    return {
        prompt         = "Recent Files",
        enable_preview = true,
        finder         = function(query, _, _, callback)
            local items = {}
            for _, file in ipairs(recent_files) do
                local res = pickertools.match_label(file.match_path, query)
                if res then
                    -- Deliberately unscored: the list is ordered by last use, and
                    -- that recency is the only reason to reach for it over the
                    -- files picker.
                    table.insert(items, {
                        label_chunks = res.chunks,
                        data         = { filepath = file.full_path },
                    })
                end
            end
            callback(items)
        end,
        on_confirm = function(data)
            if data then ui.smart_open_file(data.filepath) end
        end,
    }
end

return M
