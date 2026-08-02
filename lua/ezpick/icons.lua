--- Filetype icons, sourced from keystone.nvim when that plugin is installed.
--- ezpick has no icon data of its own: without keystone.nvim, no icons.
---@class ezpick.icon.Module
local M = {}

---@type boolean
local _resolved = false

---@type table|nil keystone.icon.Module, when keystone.nvim is installed
local _keystone

--- Look up `keystone.icons` on first use. The lookup happens lazily so ezpick
--- never forces keystone.nvim to load, and is cached either way.
---@return table|nil
local function _resolve()
    if not _resolved then
        _resolved = true
        local ok, mod = pcall(require, "keystone.icons")
        _keystone = ok and mod or nil
    end
    return _keystone
end

--- Icon and highlight group for a file, or `nil, nil` when no icon provider is
--- available.
---@param filename? string
---@param extension? string
---@param opts? table
---@return string?, string?
function M.get_icon(filename, extension, opts)
    local keystone = _resolve()
    if not keystone then
        return nil, nil
    end
    return keystone.get_icon(filename, extension, opts)
end

return M
