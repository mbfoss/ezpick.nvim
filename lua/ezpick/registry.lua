local M = {}

---@type table<string, ezpick.PickerSpec | fun(): ezpick.PickerSpec?>
local _pickers = {
    parser_test           = function() return require("ezpick.pickers.parsertest").spec() end,
    files                 = function() return require("ezpick.pickers.files").spec() end,
    live_grep             = function() return require("ezpick.pickers.livegrep").spec() end,
    recent_files          = function() return require("ezpick.pickers.recentfiles").spec() end,
    config_files          = function()
        return require("ezpick.pickers.files").spec({
            cwd    = vim.fn.stdpath("config"),
            prompt = "Config files",
        })
    end,
    quickfix              = function() return require("ezpick.pickers.qflist").spec() end,
    loclist               = function() return require("ezpick.pickers.qflist").spec({ list_type = "loclist" }) end,
    jumplist              = function() return require("ezpick.pickers.jumplist").spec() end,
    marks                 = function() return require("ezpick.pickers.marks").spec() end,
    buffer_lines          = function() return require("ezpick.pickers.lines").spec() end,
    lsp_references        = function() return require("ezpick.pickers.lsp").references_spec() end,
    lsp_definitions       = function() return require("ezpick.pickers.lsp").definitions_spec() end,
    lsp_declarations      = function() return require("ezpick.pickers.lsp").declarations_spec() end,
    lsp_implementations   = function() return require("ezpick.pickers.lsp").implementations_spec() end,
    lsp_type_definitions  = function() return require("ezpick.pickers.lsp").type_definitions_spec() end,
    lsp_incoming_calls    = function() return require("ezpick.pickers.lsp").incoming_calls_spec() end,
    lsp_outgoing_calls    = function() return require("ezpick.pickers.lsp").outgoing_calls_spec() end,
    lsp_document_symbols  = function() return require("ezpick.pickers.lsp").document_symbols_spec() end,
    lsp_workspace_symbols = function() return require("ezpick.pickers.lsp").workspace_symbols_spec() end,
    document_diagnostics  = function() return require("ezpick.pickers.diagnosics").spec({ bufnr = 0 }) end,
    workspace_diagnostics = function() return require("ezpick.pickers.diagnosics").spec() end,
    buffers               = function() return require("ezpick.pickers.buffers").spec() end,
    windows               = function() return require("ezpick.pickers.windows").spec() end,
    registers             = function() return require("ezpick.pickers.registers").spec() end,
    spell_suggest         = function() return require("ezpick.pickers.spell").spec() end,
    highlights            = function() return require("ezpick.pickers.highlights").spec() end,
    colorschemes          = function() return require("ezpick.pickers.colorschemes").spec() end,
    autocommands          = function() return require("ezpick.pickers.autocommands").spec() end,
    keymaps               = function() return require("ezpick.pickers.keymaps").spec() end,
    commands              = function() return require("ezpick.pickers.commands").spec() end,
    command_history       = function() return require("ezpick.pickers.history").spec({ kind = "cmd" }) end,
    search_history        = function() return require("ezpick.pickers.history").spec({ kind = "search" }) end,
    help_tags             = function() return require("ezpick.pickers.helptags").spec() end,
}

---`M.pick` intercepts these before the registry is consulted, so a source
---taking one of these names could never be opened.
local _reserved = {
    resume = true,
}

---Add a source under `name`. A name already in use is suffixed with a counter
---(`files_2`) instead of replacing what is there, so neither source is lost to
---load order.
---@param name string
---@param spec ezpick.PickerSpec | fun(): ezpick.PickerSpec?
---@return string name The name the source was registered under.
function M.register(name, spec)
    if type(name) ~= "string" or name == "" then
        error("ezpick.register: name must be a non-empty string", 2)
    end
    -- `:Pick <name> <query>` splits on whitespace and the picker list shows the
    -- name verbatim, so a name with spaces in it is unreachable.
    if name:find("%s") then
        error("ezpick.register: name must not contain whitespace: " .. name, 2)
    end
    if _reserved[name] then
        error("ezpick.register: '" .. name .. "' is reserved by ezpick", 2)
    end
    local spec_type = type(spec)
    if spec_type ~= "table" and spec_type ~= "function" then
        error("ezpick.register: spec must be a table or a function returning one, got " .. spec_type, 2)
    end

    if _pickers[name] ~= nil then
        local taken = name
        local n = 1
        repeat
            n = n + 1
            name = taken .. "_" .. n
        until _pickers[name] == nil
        vim.notify(
            string.format("ezpick: source '%s' is already registered; using '%s' instead", taken, name),
            vim.log.levels.WARN
        )
    end

    _pickers[name] = spec
    return name
end

---@param name string
---@return boolean
function M.has(name)
    return _pickers[name] ~= nil
end

---@return string[]
function M.keys()
    return vim.tbl_keys(_pickers)
end

---@param name string
---@return ezpick.PickerSpec?
function M.get(name)
    local entry = _pickers[name]
    if entry == nil then return nil end
    if type(entry) == "function" then return entry() end
    return entry
end

---@param name string
---@return ezpick.queryflags.FlagDef[]?
function M.get_flags(name)
    local spec = M.get(name)
    return spec and spec.flags or nil
end

return M
