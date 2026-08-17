local M = {}

-- ---------------------------------------------------------------------------
-- ezpick
--
-- A dependency-free fuzzy picker. `setup()` registers the `:Pick` command and
-- leaves the rest of the editor alone; routing `vim.ui.select` through the
-- picker replaces a global other plugins may also want, so it is opt-in:
--
--   require("ezpick").setup({ override_ui_select = true })
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
---@field override_ui_select boolean? Route `vim.ui.select` through the picker (default false).
---@field auto_complete_flags boolean? Auto-open flag completion while typing (default true).

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
        override_ui_select  = false,
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
---@param initial_query string?
---@param initial_index integer?
---@param replay_items ezpick.Picker.Item[]? Cached results to seed the first fetch instead of re-running the finder.
local function _do_open(spec, data, initial_query, initial_index, replay_items)
    local picker = require("ezpick.base.picker")
    _last_pick = { spec = spec, data = data, query = initial_query or "", index = initial_index, items = replay_items }
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
        initial_query       = initial_query,
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
        on_close            = function(query, index)
            -- Remember the final query and highlighted row so resume restores
            -- both.
            if _last_pick and _last_pick.spec == spec then
                _last_pick.query = query
                _last_pick.index = index
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
    _do_open(_last_pick.spec, _last_pick.data, _last_pick.query, _last_pick.index, _last_pick.items)
end

---@param spec ezpick.PickerSpec?
---@param initial_query string?
local function _open_spec(spec, initial_query)
    if not spec then return end
    if spec.setup then
        spec.setup(function(data)
            if data ~= nil then _do_open(spec, data, initial_query) end
        end)
    else
        _do_open(spec, nil, initial_query)
    end
end

---@param picker_type string?
---@param initial_query string?
function M.pick(picker_type, initial_query)
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
        _open_spec(spec, initial_query)
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
--- override them. `:colorscheme` clears every group, so anything that switches
--- schemes while a picker is open (the `colorschemes` source) has to call this
--- again afterwards.
function M.apply_highlights()
    vim.api.nvim_set_hl(0, "EzPickMatch", { default = true, link = "Label" })
    vim.api.nvim_set_hl(0, "EzPickPath", { default = true, link = "@namespace" })
    vim.api.nvim_set_hl(0, "EzPickBufferIndicator", { default = true, link = "Special" })
end

---@param opts ezpick.Config?
function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", _get_default_config(), opts or {})

    M.apply_highlights()

    vim.api.nvim_create_user_command("Pick", function(cmd_opts)
        local picker_type   = cmd_opts.fargs[1]
        local initial_query = #cmd_opts.fargs > 1 and cmd_opts.args:match("^%S+%s+(.+)$") or nil
        M.pick(picker_type, initial_query)
    end, {
        nargs    = "*",
        desc     = "Picker for files, grep etc...",
        complete = function(arg_lead, cmd_line, cursor_pos)
            local registry   = require("ezpick.registry")
            local queryflags = require("ezpick.base.queryflags")
            local before     = cmd_line:sub(1, cursor_pos)
            local parts      = vim.split(before, "%s+", { trimempty = true })
            if #parts <= 1 or (#parts == 2 and not before:match("%s$")) then
                local keys = registry.keys()
                table.insert(keys, "resume")
                table.sort(keys)
                return vim.tbl_filter(function(k) return vim.startswith(k, arg_lead) end, keys)
            end

            local flags = registry.get_flags(parts[2])
            if not flags then return {} end

            -- Everything after the source name is the picker's query, so the same
            -- flag parser that drives the prompt completes it here: flag names on
            -- their own, values once a value flag is waiting for one.
            local head  = before:match("^%s*%S+%s+%S+%s+") or ""
            local query = before:sub(#head + 1)
            local comps = queryflags.get_completions(flags, query, #query, false)
            if not comps then return {} end

            local out = {}
            for _, item in ipairs(comps.items) do
                -- The cmdline replaces the whitespace-delimited word under the
                -- cursor, so only candidates extending it can be offered.
                if vim.startswith(item.word, arg_lead) then table.insert(out, item.word) end
            end
            return out
        end,
    })

    if M.config.override_ui_select then
        vim.ui.select = require("ezpick.select").select
    end
end

return M
