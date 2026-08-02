local M            = {}

local pickertools  = require("ezpick.base.pickertools")
local fsutil       = require("ezpick.util.fsutil")

---@type ezpick.queryflags.FlagDef[]
local FLAGS        = {
    { name = "type",  type = "value",   multi = true, desc = "filter by type: error, warn, info, hint", values = { "error", "warn", "info", "hint" } },
    { name = "filter", type = "value",   multi = true, desc = "glob filter: *.txt, **/dir/**" },
    { name = "valid", type = "boolean",               desc = "only items with a resolved location" },
}

-- Map friendly type names (and the native single-letter codes) onto qf `type`.
local _type_alias  = {
    error = "E", e = "E",
    warn  = "W", warning = "W", w = "W",
    info  = "I", i = "I",
    hint  = "N", note = "N", n = "N",
}

---@alias ezpick.qflist_filter 'all'|"errors"|"warnings"|"info"
---@alias ezpick.qflist_type 'quickfix'|"loclist"

local _type_prefix = {
    E = { "󰅚 ", "DiagnosticError" },
    W = { "󰀪 ", "DiagnosticWarn" },
    I = { "󰋽 ", "DiagnosticInfo" },
    N = { "󰌶 ", "DiagnosticHint" },
}

---@param qf any
---@param filter ezpick.qflist_filter
---@return boolean
local function matches_filter(qf, filter)
    if filter == "all" or not filter then return true end
    local t = (qf.type or ""):upper()
    if filter == "errors" then return t == "E" or t == "" end
    if filter == "warnings" then return t == "W" end
    if filter == "info" then return t == "I" end
    return true
end

---@param item table
---@param rendered_text string?
---@return {filepath:string,relpath:string,filename:string,dir:string,lnum:number,col:number,bufnr:number,type:string,text:string,valid:boolean,qfidx:number}?
local function read_qf_item(item, rendered_text)
    local bufnr = item.bufnr
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return nil end
    local filepath = vim.api.nvim_buf_get_name(bufnr)
    local relpath  = fsutil.get_relative_path(filepath) or filepath
    return {
        bufnr    = bufnr,
        filepath = filepath,
        relpath  = relpath,
        filename = vim.fn.fnamemodify(relpath, ":t"):lower(),
        dir      = vim.fn.fnamemodify(relpath, ":h"):lower(),
        lnum     = item.lnum,
        col      = item.col > 0 and item.col - 1 or 0,
        type     = (item.type or ""):upper(),
        text     = rendered_text or item.text or "",
        valid    = item.valid == 1 and item.lnum and item.lnum > 0,
    }
end

-- Lists can customize their displayed label via the 'quickfixtextfunc' list-property
-- (:h quickfix-window-function); the native window renders through it, but `item.text`
-- from get{qf,loc}list() is raw. Render through it here too so pickers match the native label.
---@param list_type ezpick.qflist_type
---@param winid integer
---@param list table[]
---@return string[]? rendered_lines indexed 1..#list
local function render_qftf(list_type, winid, list)
    local is_loclist = list_type == "loclist"
    local get        = is_loclist
        and function(what) return vim.fn.getloclist(winid, what) end
        or function(what) return vim.fn.getqflist(what) end
    local qftf = get({ quickfixtextfunc = 1 }).quickfixtextfunc
    if not qftf or qftf == "" then return nil end
    local id = get({ id = 0 }).id
    local ok, lines = pcall(vim.fn.call, qftf, { {
        quickfix  = is_loclist and 0 or 1,
        winid     = winid,
        id        = id,
        start_idx = 1,
        end_idx   = #list,
    } })
    if ok and type(lines) == "table" then return lines end
    return nil
end

---@param list_type ezpick.qflist_type
---@param winid integer
---@return table[], integer, string[]?
local function get_list(list_type, winid)
    local list, idx
    if list_type == "loclist" then
        list, idx = vim.fn.getloclist(winid), vim.fn.getloclist(winid, { idx = 0 }).idx
    else
        list, idx = vim.fn.getqflist(), vim.fn.getqflist({ idx = 0 }).idx
    end
    return list, idx, render_qftf(list_type, winid, list)
end

---@param opts {filter:ezpick.qflist_filter?, list_type:ezpick.qflist_type?, winid:integer?}?
---@return ezpick.PickerSpec?
function M.spec(opts)
    opts = opts or {}
    local filter      = opts.filter or "all"
    local list_type   = opts.list_type or "quickfix"
    local winid       = opts.winid or vim.fn.win_getid()
    local is_loclist  = list_type == "loclist"
    local qflist, current_idx, rendered = get_list(list_type, winid)
    local list_label  = is_loclist and "Location List" or "Quickfix"

    local entries = {}
    for idx, qf in ipairs(qflist) do
        if matches_filter(qf, filter) then
            local data = read_qf_item(qf, rendered and rendered[idx])
            if data then
                data.qfidx = idx
                table.insert(entries, data)
            end
        end
    end

    if vim.tbl_isempty(entries) then
        if filter == "all" then
            vim.notify(("%s is empty"):format(list_label), vim.log.levels.WARN)
        else
            vim.notify(("No %s in %s"):format(filter, list_label), vim.log.levels.WARN)
        end
        return nil
    end

    return {
        prompt             = list_label .. " Items",
        flags              = FLAGS,
        enable_preview     = true,
        finder             = function(query, flags, _, callback)
            local items = {}
            for _, data in ipairs(entries) do
                if flags.valid and not data.valid then goto continue end

                local skip       = false
                local type_flags = flags.type or {}
                if #type_flags > 0 then
                    local matched = false
                    for _, v in ipairs(type_flags) do
                        local code = _type_alias[v:lower()] or v:upper()
                        if data.type == code then
                            matched = true; break
                        end
                    end
                    if not matched then skip = true end
                end
                local in_globs = flags["filter"] or {}
                if not skip and not pickertools.match_globs(in_globs, data.relpath, true) then
                    skip = true
                end
                if skip then goto continue end

                local text  = vim.trim(data.text ~= "" and data.text or "[No description]")
                local match = pickertools.match_label(text, query)
                if match then
                    local chunks = { _type_prefix[data.type] or _type_prefix.N }
                    vim.list_extend(chunks, match.chunks)
                    local virt_line = nil
                    if data.relpath and #data.relpath > 0 then
                        virt_line = { { string.format("%s:%d:%d", data.relpath, data.lnum, data.col), "EzPickPath" } }
                    end
                    ---@type ezpick.Picker.Item
                    table.insert(items, {
                        label_chunks = chunks,
                        virt_line    = virt_line,
                        data         = data,
                        initial      = data.qfidx == current_idx,
                    })
                end
                ::continue::
            end
            callback(items)
        end,
        quickfix_formatter = function(data)
            return data
        end,
        on_confirm         = function(data)
            if not data then return end
            if is_loclist then
                vim.fn.win_execute(winid, "ll " .. data.qfidx)
            else
                vim.cmd("cc " .. data.qfidx)
            end
        end,
    }
end

return M
