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
    lsp_references        = function() return require("ezpick.pickers.lsp").references_spec() end,
    document_symbols      = function() return require("ezpick.pickers.lsp").document_symbols_spec() end,
    document_diagnostics  = function() return require("ezpick.pickers.diagnosics").spec({ bufnr = 0 }) end,
    workspace_diagnostics = function() return require("ezpick.pickers.diagnosics").spec() end,
    buffers               = function() return require("ezpick.pickers.buffers").spec() end,
    windows               = function() return require("ezpick.pickers.windows").spec() end,
    spell_suggest         = function() return require("ezpick.pickers.spell").spec() end,
    highlights            = function() return require("ezpick.pickers.highlights").spec() end,
    autocommands          = function() return require("ezpick.pickers.autocommands").spec() end,
    keymaps               = function() return require("ezpick.pickers.keymaps").spec() end,
    commands              = function() return require("ezpick.pickers.commands").spec() end,
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
