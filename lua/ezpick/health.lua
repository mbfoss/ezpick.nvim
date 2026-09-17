---@brief Health check for ezpick.nvim — run with `:checkhealth ezpick`.
---
---Reports the Neovim version, the commands, and the options that differ from
---the defaults. `setup()` is optional, so the config is reported either way.

local M = {}

local health = vim.health

---Check the Neovim version against the plugin's minimum (see
---`plugin/ezpick.lua`). Silent on a supported version: a health check is for
---what is wrong, not for what is unremarkable.
local function _check_requirements()
    if vim.fn.has("nvim-0.11") ~= 1 then
        health.start("ezpick: requirements")
        health.error("ezpick.nvim requires Neovim >= 0.11")
    end
end

---`:Ezpick` comes from `plugin/ezpick.lua`, so it exists without a `setup()`.
---The alias is registered by `setup()` from `command_alias`.
local function _check_commands()
    health.start("ezpick: commands")

    if vim.fn.exists(":Ezpick") == 2 then
        health.ok(":Ezpick is registered")
    else
        health.error(":Ezpick is not registered", {
            "plugin/ezpick.lua did not run; check the plugin is on the runtimepath",
        })
    end

    local alias = require("ezpick.config").current.command_alias
    if not alias or alias == "" then
        health.info("`command_alias` is unset, so no second command is registered")
    elseif vim.fn.exists(":" .. alias) == 2 then
        health.ok((":%s is registered (command_alias)"):format(alias))
    else
        health.warn((":%s is not registered"):format(alias), {
            "require('ezpick').setup() has not been called yet",
        })
    end
end

---Options that are valid but have no default, so `defaults[key]` is nil for
---them and the unknown-key test below would otherwise call them misspellings.
local _OPTIONAL = {
    command_alias = true,
}

---Collect the options whose value differs from the default, as flat paths with
---the value now in force. Lists are compared whole rather than descended into:
---a list-valued option is one option, not one option per element.
---@param current table
---@param defaults table
---@param prefix string  path of the enclosing table, "" at the top level
---@param out table[]
---@return table[]
local function _diff_config(current, defaults, prefix, out)
    for key, value in pairs(current) do
        local path = prefix .. tostring(key)
        local default = defaults[key]
        if type(value) == "table" and type(default) == "table" and not vim.islist(value) then
            _diff_config(value, default, path .. ".", out)
        elseif not vim.deep_equal(value, default) then
            table.insert(out, {
                path    = path,
                value   = vim.inspect(value, { newline = " ", indent = "" }),
                unknown = default == nil and not _OPTIONAL[path],
            })
        end
    end
    return out
end

---Report the options that differ from the defaults — the whole config would be
---mostly untouched defaults, and the point here is what this user changed.
---Anything set that the plugin does not define is flagged: `setup()` merges
---`opts` wholesale, so a misspelled option is kept silently.
local function _check_config()
    health.start("ezpick: configuration")

    local config = require("ezpick.config")
    local diffs  = _diff_config(config.current, config.defaults(), "", {})
    table.sort(diffs, function(a, b) return a.path < b.path end)

    if #diffs == 0 then
        health.ok("every option is at its default")
        return
    end

    local lines = {}
    for _, entry in ipairs(diffs) do
        table.insert(lines, ("  %s = %s"):format(entry.path, entry.value))
    end
    health.ok(("%d option%s differ%s from the defaults:\n%s")
        :format(#diffs, #diffs == 1 and "" or "s", #diffs == 1 and "s" or "",
            table.concat(lines, "\n")))

    for _, entry in ipairs(diffs) do
        if entry.unknown then
            health.warn(("`%s` is not an option ezpick defines"):format(entry.path), {
                "Check its spelling against :help ezpick-configuration",
            })
        end
    end
end

function M.check()
    _check_requirements()
    _check_commands()
    _check_config()
end

return M
