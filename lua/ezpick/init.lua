local M = {}

-- ---------------------------------------------------------------------------
-- ezpick
--
-- A dependency-free fuzzy picker. `plugin/ezpick.lua` registers the `:Ezpick`
-- command and the highlight groups, so `setup()` is optional and only changes
-- the defaults. Nothing else in the editor is touched; routing `vim.ui.select`
-- through the picker is left to the user:
--
--   vim.ui.select = require("ezpick.select")
--
-- Built-in sources live in `ezpick.pickers` and are wired up lazily by
-- `ezpick.registry`. Other plugins add their own with `M.register(name, spec)`.
-- ---------------------------------------------------------------------------

---A picker is sized by which of these two applies, so a source with nothing to
---preview can be narrower than one showing a file beside the list. `layout` only
---arranges a list against a preview, so it is meaningful in `with_preview`.
---@class ezpick.Config
---@field with_preview ezpick.Picker.Geometry? Sizing while the preview is showing.
---@field without_preview ezpick.Picker.Geometry? Sizing while it is not.
---@field auto_complete_flags boolean? Auto-open flag completion on an empty flags line and while typing (default true).
---@field command_alias string? Name of an extra user command running the same handler and completion as `:Ezpick` (for example "Pick").

---@class ezpick.PickerSpec
---@field prompt string
---@field flags ezpick.queryflags.FlagDef[]?
---@field enable_preview boolean?
---@field layout ezpick.Picker.LayoutKind? Overrides the configured layout for this source.
---@field height_ratio number? Overrides the configured height for this source, previewing or not.
---@field width_ratio number? Overrides the configured width for this source, previewing or not.
---@field list_wrap boolean?
---@field history_provider ezpick.Picker.QueryHistoryProvider?
---@field quickfix_formatter (fun(data:any):vim.quickfix.entry?)?
---@field setup (fun(callback:fun(data:table?)))?
---@field finder fun(query:string, flags:table, fetch_opts:ezpick.Picker.FetcherOpts, callback:fun(items:ezpick.Picker.Item[]?)):fun()?
---@field previewer ezpick.Picker.AsyncPreviewLoader?
---@field initial_cursor (integer|fun(items:ezpick.Picker.Item[]):integer?)? Row to highlight when the picker opens: a 1-based index into the ranked list, or a function that finds one in it. Resuming a picker overrides it with the row left behind.
---@field on_confirm fun(data:ezpick.picker.ItemData?)

---What a picker opens with. The two prompt sections are held apart: the flags
---are read against the source's schema, the query is text.
---@class ezpick.PickPrompt
---@field query string?
---@field flags string?

local function _get_default_config()
    ---@type ezpick.Config
    return {
        with_preview        = {
            layout       = "horizontal",
            width_ratio  = 0.8,
            height_ratio = 0.7,
        },
        without_preview     = {
            width_ratio  = 0.6,
            height_ratio = 0.7,
        },
        auto_complete_flags = true,
    }
end

---@type ezpick.Config
M.config = _get_default_config()

---Sizing for one source: the configured geometry for the preview state it opens
---in, with whatever the source states itself folded over it.
---@param spec ezpick.PickerSpec
---@return ezpick.Picker.Geometry
local function _resolve_geometry(spec)
    local base = spec.enable_preview and M.config.with_preview or M.config.without_preview
    -- Absent keys are absent from the table, so this only overrides what the
    -- spec actually set.
    return vim.tbl_extend("force", base or {}, {
        layout       = spec.layout,
        width_ratio  = spec.width_ratio,
        height_ratio = spec.height_ratio,
    })
end

---The most recent picker invocation, replayed by M.resume(). Holds the
---resolved spec and its setup data so repeat reopens without re-running setup,
---plus the final prompt text so the same query is restored.
---@type {spec:ezpick.PickerSpec, data:table?, query:string, index:integer?, items:ezpick.Picker.Item[]?}?
local _last_pick = nil

---@param spec ezpick.PickerSpec
---@param data table?
---@param prompt ezpick.PickPrompt?
---@param initial_index integer?
---@param replay_items ezpick.Picker.Item[]? Cached results to seed the first fetch instead of re-running the finder.
local function _do_open(spec, data, prompt, initial_index, replay_items)
    local picker = require("ezpick.base.picker")
    prompt     = prompt or {}
    _last_pick = {
        spec  = spec,
        data  = data,
        prompt = { query = prompt.query or "", flags = prompt.flags or "" },
        index = initial_index,
        items = replay_items,
    }
    local replayed = false
    local geometry = _resolve_geometry(spec)
    picker.open({
        prompt              = spec.prompt,
        flags               = spec.flags,
        enable_preview      = spec.enable_preview,
        layout              = geometry.layout,
        width_ratio         = geometry.width_ratio,
        height_ratio        = geometry.height_ratio,
        list_wrap           = spec.list_wrap,
        history_provider    = spec.history_provider,
        quickfix_formatter  = spec.quickfix_formatter,
        previewer           = spec.previewer,
        initial_query       = prompt.query,
        initial_flags       = prompt.flags,
        -- Resuming restores the row the picker was left on, which is a more
        -- specific intent than whatever the source would open on from scratch.
        initial_cursor      = initial_index or spec.initial_cursor,
        auto_complete_flags = M.config.auto_complete_flags,
        finder              = function(query, flags, fetch_opts, callback)
            -- Serve the cached snapshot for the first (unchanged) query so a
            -- repeated picker opens instantly; any edit falls through to a fresh
            -- finder run.
            if replay_items and not replayed then
                replayed = true
                callback(replay_items)
                return nil
            end
            -- Keep a reference to each fresh result set as it flows to the picker,
            -- capped, so resume can replay it without re-running the finder.
            fetch_opts.data = data
            return spec.finder(query, flags, fetch_opts, function(items)
                if _last_pick and _last_pick.spec == spec then
                    _last_pick.items = items
                end
                callback(items)
            end)
        end,
        on_close            = function(query, flag_text, index)
            -- Remember the final prompt and highlighted row so resume restores
            -- both.
            if _last_pick and _last_pick.spec == spec then
                _last_pick.prompt = { query = query, flags = flag_text }
                _last_pick.index  = index
            end
        end,
    }, spec.on_confirm or function() end)
end

--- Reopen the most recent picker with its last query. Reuses the resolved spec
--- and setup data, so setup is not run again.
function M.resume()
    if not _last_pick then
        vim.notify("No previous picker session", vim.log.levels.INFO)
        return
    end
    _do_open(_last_pick.spec, _last_pick.data, _last_pick.prompt, _last_pick.index, _last_pick.items)
end

---@param spec ezpick.PickerSpec?
---@param prompt ezpick.PickPrompt?
local function _open_spec(spec, prompt)
    if not spec then return end
    if spec.setup then
        spec.setup(function(data)
            if data ~= nil then _do_open(spec, data, prompt) end
        end)
    else
        _do_open(spec, nil, prompt)
    end
end

---@param picker_type string?
---@param prompt ezpick.PickPrompt?
function M.pick(picker_type, prompt)
    local registry    = require("ezpick.registry")
    local pickertools = require("ezpick.base.pickertools")
    if not picker_type or picker_type == "" then
        local keys = registry.keys()
        table.insert(keys, "resume")
        table.sort(keys)
        vim.ui.select(keys, { prompt = "Pick" }, function(choice)
            if choice then M.pick(choice) end
        end)
        return
    end

    if picker_type == "resume" then
        M.resume()
        return
    end

    local spec = registry.get(picker_type)
    if spec then
        spec.history_provider = spec.history_provider or pickertools.make_history_provider(picker_type)
        _open_spec(spec, prompt)
    elseif not registry.has(picker_type) then
        vim.notify("Invalid picker type: " .. tostring(picker_type), vim.log.levels.WARN)
    end
end

---Add a source under `name`. A name already taken by a built-in or another
---plugin is suffixed with a counter; the name actually used is returned.
---@param name string
---@param spec ezpick.PickerSpec | fun(): ezpick.PickerSpec?
---@return string name
function M.register(name, spec)
    return require("ezpick.registry").register(name, spec)
end

--- Define ezpick's own highlight groups, as defaults so a colorscheme can
--- override them. Links survive `:colorscheme` and re-resolve against the new
--- scheme, but lose the `default` that lets it have them, which is why anything
--- switching schemes while a picker is open (the `colorschemes` source) calls
--- this again afterwards.
function M.apply_highlights()
    vim.api.nvim_set_hl(0, "EzPickMatch", { default = true, link = "Visual" })
    vim.api.nvim_set_hl(0, "EzPickPath", { default = true, link = "@namespace" })
    vim.api.nvim_set_hl(0, "EzPickBufferIndicator", { default = true, link = "Special" })
    vim.api.nvim_set_hl(0, "EzPickFlagPill", { default = true, link = "Visual" })
end

---The alias currently created from `config.command_alias`, so a second
---`setup()` can drop the one it replaces.
---@type string?
local _alias_command = nil

---Optional: `:Ezpick` and the highlight groups are set up by
---`plugin/ezpick.lua`, so this is only needed to change the defaults.
---@param opts ezpick.Config?
function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", _get_default_config(), opts or {})

    local alias = M.config.command_alias
    if _alias_command and _alias_command ~= alias then
        vim.api.nvim_del_user_command(_alias_command)
        _alias_command = nil
    end
    if alias and alias ~= "" and alias ~= _alias_command then
        require("ezpick.cmdline").create_command(alias)
        _alias_command = alias
    end
end

return M
