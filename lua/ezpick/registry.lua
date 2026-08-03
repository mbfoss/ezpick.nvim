local M = {}

---@type table<string, ezpick.PickerSpec | fun(): ezpick.PickerSpec?>
local _pickers = {
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

---@param name string
---@param spec ezpick.PickerSpec | fun(): ezpick.PickerSpec?
function M.register(name, spec)
    _pickers[name] = spec
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
