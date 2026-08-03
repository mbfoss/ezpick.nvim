local M                  = {}

local ui                 = require("ezpick.util.ui")
local pickertools        = require("ezpick.base.pickertools")
local fsutil             = require("ezpick.util.fsutil")

local _kind_to_str_cache = {}
---@param kind number LSP SymbolKind (integer)
---@return string
local function kind_to_string(kind)
    if vim.tbl_isempty(_kind_to_str_cache) then
        local symbol_kinds = vim.lsp.protocol.SymbolKind
        for name, id in pairs(symbol_kinds) do
            if type(id) == "number" then
                _kind_to_str_cache[id] = name
            end
        end
    end
    return _kind_to_str_cache[kind] or ""
end

---@type ezpick.queryflags.FlagDef[]
local REF_FLAGS = {
    { name = "filter", type = "value", multi = true, desc = "glob filter: *.txt, **/dir/**" },
}

---Every LSP SymbolKind name, in protocol order (SymbolKind 1..26).
---@type string[]
local SYMBOL_KINDS = {
    "File",
    "Module",
    "Namespace",
    "Package",
    "Class",
    "Method",
    "Property",
    "Field",
    "Constructor",
    "Enum",
    "Interface",
    "Function",
    "Variable",
    "Constant",
    "String",
    "Number",
    "Boolean",
    "Array",
    "Object",
    "Key",
    "Null",
    "EnumMember",
    "Struct",
    "Event",
    "Operator",
    "TypeParameter",
}

-- One boolean flag per symbol kind, so kinds are selected as "is:Function
-- is:Class" rather than a single "kind:" value list. Several at once are OR'd.
---@type ezpick.queryflags.FlagDef[]
local SYMBOL_FLAGS = {}
for _, name in ipairs(SYMBOL_KINDS) do
    table.insert(SYMBOL_FLAGS, {
        name = name,
        type = "boolean",
        desc = ("%s symbols"):format(name),
    })
end

---@class ezpick.lsp.LocationsOpts
---@field method string LSP request method, e.g. "textDocument/definition"
---@field prompt string
---@field include_declaration boolean? Send `context.includeDeclaration` (references only).
---@field jump_single boolean? Jump straight to the location when the request yields exactly one.

---A picker over any request that answers with locations: references,
---definitions, declarations, implementations and type definitions all return
---`Location`, `Location[]` or `LocationLink[]`, so they differ only in the
---method sent and how a single result is treated.
---@param opts ezpick.lsp.LocationsOpts
---@return ezpick.PickerSpec
local function locations_spec(opts)
    local params = vim.lsp.util.make_position_params(0, "utf-8")
    if opts.include_declaration then
        ---@diagnostic disable-next-line: inject-field
        params.context = { includeDeclaration = true }
    end

    return {
        prompt          = opts.prompt,
        flags           = REF_FLAGS,
        enable_preview  = true,
        setup           = function(callback)
            local action = opts.method
            vim.lsp.buf_request_all(0, action, params, function(results_per_client)
                local lsp_items = {}
                local errors    = {}
                for client_id, result_or_error in pairs(results_per_client) do
                    local err, result = result_or_error.err, result_or_error.result
                    if err then
                        errors[client_id] = err
                    elseif result ~= nil then
                        local locations = vim.islist(result) and result or { result }
                        local enc       = vim.lsp.get_client_by_id(client_id).offset_encoding
                        vim.list_extend(lsp_items, vim.lsp.util.locations_to_items(locations, enc))
                    end
                end
                for _, err in pairs(errors) do
                    vim.notify(action .. " : " .. err.message, vim.log.levels.ERROR)
                end
                if vim.tbl_isempty(lsp_items) then
                    vim.notify("No " .. opts.prompt .. " found")
                    callback(nil)
                    return
                end
                -- A lone definition is what the user asked for; showing a
                -- one-entry picker for it would just add a keystroke.
                if opts.jump_single and #lsp_items == 1 then
                    local target = lsp_items[1]
                    vim.schedule(function()
                        ui.smart_open_file(target.filename, target.lnum, target.col - 1)
                    end)
                    callback(nil)
                    return
                end
                callback({ lsp_items = lsp_items })
            end)
        end,
        finder          = function(query, flags, fetch_opts, callback)
            local data         = fetch_opts.data
            local picker_items = {}
            for _, ref in ipairs(data.lsp_items) do
                local display_path = fsutil.get_relative_path(ref.filename) or ref.filename or ""
                local in_globs     = flags["filter"] or {}
                if not pickertools.match_globs(in_globs, display_path, true) then goto continue end

                local text  = ref.text and vim.fn.trim(ref.text) or ""
                local match = pickertools.match_label(text, query)
                if match then
                    local loc = ref.lnum and string.format("%s:%d", display_path, ref.lnum) or display_path
                    loc = fsutil.smart_crop_path(loc, fetch_opts.list_width)
                    ---@type ezpick.Picker.Item
                    table.insert(picker_items, {
                        label_chunks = match.chunks,
                        virt_line    = { { loc, "EzPickPath" } },
                        data         = {
                            filepath = ref.filename,
                            lnum     = ref.lnum,
                            col      = ref.col - 1,
                        }
                    })
                end
                ::continue::
            end
            if query == "" then
                table.sort(picker_items, function(a, b)
                    if a.data.filepath ~= b.data.filepath then
                        return a.data.filepath < b.data.filepath
                    end
                    if a.data.lnum ~= b.data.lnum then
                        return a.data.lnum < b.data.lnum
                    end
                    return a.data.col < b.data.col
                end)
            end
            callback(picker_items)
        end,
        on_confirm      = function(data)
            if data then ui.smart_open_file(data.filepath, data.lnum, data.col) end
        end,
    }
end

---@return ezpick.PickerSpec
function M.references_spec()
    return locations_spec({
        method              = "textDocument/references",
        prompt              = "LSP References",
        include_declaration = true,
    })
end

---@return ezpick.PickerSpec
function M.definitions_spec()
    return locations_spec({
        method      = "textDocument/definition",
        prompt      = "LSP Definitions",
        jump_single = true,
    })
end

---@return ezpick.PickerSpec
function M.declarations_spec()
    return locations_spec({
        method      = "textDocument/declaration",
        prompt      = "LSP Declarations",
        jump_single = true,
    })
end

---@return ezpick.PickerSpec
function M.implementations_spec()
    return locations_spec({
        method      = "textDocument/implementation",
        prompt      = "LSP Implementations",
        jump_single = true,
    })
end

---@return ezpick.PickerSpec
function M.type_definitions_spec()
    return locations_spec({
        method      = "textDocument/typeDefinition",
        prompt      = "LSP Type Definitions",
        jump_single = true,
    })
end

---@param opts {kinds:string[]?,prompt:string?}?
---@return ezpick.PickerSpec
function M.document_symbols_spec(opts)
    opts                   = opts or {}

    local params           = { textDocument = vim.lsp.util.make_text_document_params() }
    local filepath         = vim.api.nvim_buf_get_name(0)
    local cursor_lnum      = vim.api.nvim_win_get_cursor(0)[1]

    local opts_kind_filter = {}
    for _, k in ipairs(opts.kinds or {}) do opts_kind_filter[k:lower()] = true end

    return {
        prompt         = opts.prompt or "Document Symbols",
        flags          = SYMBOL_FLAGS,
        enable_preview = true,
        setup          = function(callback)
            vim.lsp.buf_request(0, "textDocument/documentSymbol", params, function(err, result, _)
                if err or not result then
                    callback(nil)
                    return
                end

                local items = {}
                local function flatten(symbols)
                    for _, s in ipairs(symbols) do
                        -- DocumentSymbol uses selectionRange; SymbolInformation uses location.range
                        local range = s.selectionRange or (s.location and s.location.range)
                        if range then
                            table.insert(items, {
                                kind = kind_to_string(s.kind),
                                data = {
                                    name     = s.name,
                                    filepath = filepath,
                                    lnum     = range.start.line + 1,
                                    col      = range.start.character,
                                },
                            })
                        end
                        if s.children then flatten(s.children) end
                    end
                end
                flatten(result)

                local best, best_lnum = nil, 0
                for _, item in ipairs(items) do
                    local lnum = item.data.lnum
                    if lnum <= cursor_lnum and lnum > best_lnum then
                        best      = item
                        best_lnum = lnum
                    end
                end
                if best then best.initial = true end

                if #items == 0 then
                    vim.notify("No symbols found")
                    callback(nil)
                    return
                end
                callback({ items = items })
            end)
        end,
        finder         = function(query, flags, fetch_opts, callback)
            local data       = fetch_opts.data
            -- Kind booleans select a union: "is:Function is:Class" keeps both,
            -- none set keeps every kind.
            local flag_kinds = {}
            local any_kind   = false
            for _, name in ipairs(SYMBOL_KINDS) do
                if flags[name] then
                    flag_kinds[name] = true
                    any_kind         = true
                end
            end

            local filtered = {}
            for _, item in ipairs(data.items) do
                if next(opts_kind_filter) ~= nil and not opts_kind_filter[item.kind:lower()] then
                    goto continue
                end
                if any_kind and not flag_kinds[item.kind] then goto continue end

                local match = pickertools.match_label(item.data.name, query)
                if match then
                    vim.list_extend(match.chunks, { { (" (%s)"):format(item.kind), "Comment" } })
                    table.insert(filtered, {
                        label_chunks = match.chunks,
                        data         = item.data,
                    })
                end
                ::continue::
            end
            callback(filtered)
        end,
        on_confirm     = function(data)
            if data then vim.api.nvim_win_set_cursor(0, { data.lnum, data.col }) end
        end,
    }
end

---Symbols across the whole workspace. Unlike every other source the query is
---not matched locally: each keystroke is forwarded to the server as the
---`workspace/symbol` query and the previous request is cancelled, since only
---the server knows what is out there. `match_label` is still run over the
---returned names, purely to highlight the part that matched.
---@return ezpick.PickerSpec?
function M.workspace_symbols_spec()
    if vim.tbl_isempty(vim.lsp.get_clients({ bufnr = 0, method = "workspace/symbol" })) then
        vim.notify("No LSP client supports workspace/symbol", vim.log.levels.WARN)
        return nil
    end

    return {
        prompt         = "Workspace Symbols",
        flags          = SYMBOL_FLAGS,
        enable_preview = true,
        finder         = function(query, flags, fetch_opts, callback)
            local flag_kinds = {}
            local any_kind   = false
            for _, name in ipairs(SYMBOL_KINDS) do
                if flags[name] then
                    flag_kinds[name] = true
                    any_kind         = true
                end
            end

            local cancelled  = false
            local cancel_all = vim.lsp.buf_request_all(0, "workspace/symbol", { query = query },
                function(results_per_client)
                    if cancelled then return end

                    local items = {}
                    for _, result_or_error in pairs(results_per_client) do
                        for _, sym in ipairs(result_or_error.result or {}) do
                            local kind = kind_to_string(sym.kind)
                            if any_kind and not flag_kinds[kind] then goto continue end

                            local location = sym.location
                            if not location or not location.uri then goto continue end

                            -- A 3.17 server may answer with a location carrying no
                            -- range (to be filled in by workspaceSymbol/resolve);
                            -- point at the top of the file in that case.
                            local range    = location.range
                            local filepath = vim.uri_to_fname(location.uri)
                            local match    = pickertools.match_label(sym.name, query)
                                or { chunks = pickertools.highlight_chunks(sym.name) }

                            local chunks   = match.chunks
                            table.insert(chunks, { (" (%s)"):format(kind), "Comment" })
                            if sym.containerName and sym.containerName ~= "" then
                                table.insert(chunks, { "  " .. sym.containerName, "Comment" })
                            end

                            local lnum = range and range.start.line + 1 or 1
                            local loc  = fsutil.smart_crop_path(
                                ("%s:%d"):format(fsutil.get_relative_path(filepath) or filepath, lnum),
                                fetch_opts.list_width)

                            ---@type ezpick.Picker.Item
                            table.insert(items, {
                                label_chunks = chunks,
                                virt_line    = { { loc, "EzPickPath" } },
                                data         = {
                                    filepath = filepath,
                                    lnum     = lnum,
                                    col      = range and range.start.character or 0,
                                },
                            })
                            ::continue::
                        end
                    end
                    callback(items)
                end)

            return function()
                cancelled = true
                if cancel_all then cancel_all() end
            end
        end,
        on_confirm     = function(data)
            if data then ui.smart_open_file(data.filepath, data.lnum, data.col) end
        end,
    }
end

return M
