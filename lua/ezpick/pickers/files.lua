local M           = {}

local ui          = require("ezpick.util.ui")
local strutil     = require("ezpick.util.strutil")
local fsutil      = require("ezpick.util.fsutil")
local pickertools = require("ezpick.base.pickertools")
local icons       = require("ezpick.icons")

---@class ezpick.filepicker.Opts
---@field prompt string?
---@field cwd string?
---@field max_results number?

---@alias ezpick.filepicker.Mode "fuzzy"|"fixed"|"glob"

---@class ezpick.filepicker.SearchOpts
---@field cwd string The root directory for the search
---@field mode ezpick.filepicker.Mode? how the query matches a file (default "fuzzy")
---@field max_results number?
---@field case_sensitive boolean?
---@field follow_symlinks boolean?
---@field show_hidden boolean?
---@field extensions string[]? only files with one of these extensions (no dot, lowercase)
---@field exclude_globs string[]? paths matching one of these globs are skipped

---@type ezpick.queryflags.FlagDef[]
local FLAGS       = {
    { name = "dir",           type = "value",   complete = "dir",                                alias = { "base-directory", "search-path" }, desc = "override search root directory" },
    { name = "mode",          type = "value",   strict = true,                                   values = { "fuzzy", "fixed", "glob" },       desc = "match: fuzzy (default) | fixed (literal substring) | glob (rg-style globs, space separated)" },
    { name = "case",          type = "value",   strict = true,                                   values = { "smart", "on", "off" },           desc = "case: smart (default) | on | off" },
    { name = "follow",        type = "boolean", alias = { "follow-symlinks" },                    desc = "follow symlinks" },
    { name = "hidden",        type = "boolean", desc = "include hidden (dotfiles)" },
    -- fd spellings, kept beside the flags above rather than in place of them: an
    -- fd habit types out here without a lookup, and each one is only another way
    -- to write a `--mode` / `--case` value.
    -- Single-letter fd spellings are deliberately absent: names here are matched
    -- case-insensitively, so `-e` and `-E` would be one flag rather than two.
    { name = "glob",          type = "boolean", desc = "same as --mode glob" },
    { name = "fixed-strings", type = "boolean", alias = { "fixed" },                             desc = "same as --mode fixed" },
    { name = "case-sensitive", type = "boolean", desc = "same as --case on" },
    { name = "ignore-case",   type = "boolean", desc = "same as --case off" },
    { name = "extension",     type = "value",   multi = true,                                    alias = { "ext" },                           desc = "only files with this extension (repeatable)" },
    { name = "exclude",       type = "value",   multi = true,                                    desc = "skip paths matching this glob (repeatable)" },
    { name = "max-results",   type = "value",   desc = "stop after this many matches" },
}

--- Resolve the match mode: `--mode` is the explicit spelling and wins, with the
--- fd switches (`--glob`, `--fixed-strings`) standing in for its values.
---@param flags table
---@return ezpick.filepicker.Mode
local function resolve_mode(flags)
    if flags.mode then return flags.mode end
    if flags.glob then return "glob" end
    if flags["fixed-strings"] then return "fixed" end
    return "fuzzy"
end

--- Resolve the case flag value the same way: `--case` wins over fd's
--- `--case-sensitive` / `--ignore-case` switches.
---@param flags table
---@return string? "on"|"off"|"smart"|nil
local function resolve_case_flag(flags)
    if flags.case then return flags.case end
    if flags["case-sensitive"] then return "on" end
    if flags["ignore-case"] then return "off" end
    return nil
end

--- Normalize `--extension` values into bare lowercase extensions, so `--ext .LUA`
--- and `--ext lua` name the same files. Returns nil when nothing usable is left,
--- which reads downstream as "no extension filter".
---@param values string[]|string|nil
---@return string[]?
local function normalize_extensions(values)
    if not values then return nil end
    if type(values) == "string" then values = { values } end
    local exts = {}
    for _, v in ipairs(values) do
        local ext = v:gsub("^%.+", ""):lower()
        if ext ~= "" then exts[#exts + 1] = ext end
    end
    return #exts > 0 and exts or nil
end

--- Does `filename` carry one of `exts`? A nil filter passes everything.
---@param filename string
---@param exts string[]?
---@return boolean
local function match_extension(filename, exts)
    if not exts then return true end
    local ext = filename:match("%.([^.]+)$")
    if not ext then return false end
    ext = ext:lower()
    return vim.tbl_contains(exts, ext)
end

--- Expand an `--exclude` glob into the patterns that make it match at any depth,
--- the way fd's `-E` does: a glob naming no directory (`node_modules`, `*.min.js`)
--- also gets a `**/` form, while one that spells a path out (`src/*.lua`) is
--- taken as written and stays anchored at the search root.
---@param globs string[]|string|nil
---@return string[]?
local function expand_exclude_globs(globs)
    if not globs then return nil end
    if type(globs) == "string" then globs = { globs } end
    local out = {}
    for _, g in ipairs(globs) do
        if g ~= "" then
            out[#out + 1] = g
            if not g:find("/") then out[#out + 1] = "**/" .. g end
        end
    end
    return #out > 0 and out or nil
end

--- Resolve a `case` flag value into a case-sensitivity decision.
---
--- `mode` is the user-facing flag value: "on" (always sensitive), "off" (always
--- insensitive) or "smart"/nil (the default): sensitive only when `query` itself
--- contains an uppercase character.
---@param mode string?    "on"|"off"|"smart"|nil
---@param query string
---@return boolean case_sensitive
local function resolve_case(mode, query)
    if mode == "on" then return true end
    if mode == "off" then return false end
    return query:match("%u") ~= nil
end

--- Fuzzy-match a filename against the query, then apply the case gate on top.
--- The matcher itself is case-insensitive; when `case_sensitive` is set the
--- subsequence is re-checked with case and re-highlighted on a hit.
---@param filename string
---@param query string
---@param case_sensitive boolean?
---@return {score:number, chunks:table[]}?
local function fuzzy_match(filename, query, case_sensitive)
    local res = pickertools.match_label(filename, query)
    if not res then return nil end
    if case_sensitive then
        local pos = pickertools.case_subseq(filename, query)
        if not pos then return nil end
        res = { score = res.score, chunks = pickertools.highlight_chunks(filename, pos) }
    end
    return res
end

--- Literal (fixed-string) substring match, highlighting the matched run.
--- Matches case-insensitively unless `case_sensitive`; earlier matches score
--- higher so they sort ahead.
---@param filename string
---@param query string
---@param case_sensitive boolean?
---@return {score:number, chunks:table[]}?
local function fixed_match(filename, query, case_sensitive)
    if query == "" then
        return { score = 0, chunks = pickertools.highlight_chunks(filename) }
    end
    local haystack = case_sensitive and filename or filename:lower()
    local needle   = case_sensitive and query or query:lower()
    local byte_s   = haystack:find(needle, 1, true)
    if not byte_s then return nil end

    -- Convert the matched byte span into 1-based char positions for highlighting.
    local char_s    = vim.fn.charidx(filename, byte_s - 1)
    local qn        = vim.fn.strchars(query)
    local positions = {}
    for k = 0, qn - 1 do positions[#positions + 1] = char_s + 1 + k end
    return { score = -byte_s, chunks = pickertools.highlight_chunks(filename, positions) }
end

--- Split a glob-mode query into the sequence of globs it names.
--- Globs are whitespace separated, so `*.lua !*_spec.lua` reads as an rg
--- `--glob *.lua --glob !*_spec.lua` invocation.
---@param query string
---@return string[]
local function split_globs(query)
    return vim.split(query, "%s+", { trimempty = true })
end

--- Match a file against the query under the selected `mode`:
---   * "fuzzy" (default) — fuzzy subsequence over the basename
---   * "fixed"           — literal substring over the basename
---   * "glob"            — rg-style globs over the relative path (unhighlighted)
--- The returned chunks always describe the basename, so the result row renders
--- identically regardless of mode.
---@param filename string
---@param relpath string
---@param query string
---@param mode ezpick.filepicker.Mode?
---@param case_sensitive boolean?
---@param globs string[]? `query` pre-split by `split_globs` (glob mode only)
---@return {score:number, chunks:table[]}?
local function do_match(filename, relpath, query, mode, case_sensitive, globs)
    if mode == "glob" then
        globs = globs or split_globs(query)
        if not pickertools.match_globs(globs, relpath, not case_sensitive) then return nil end
        return { score = 0, chunks = pickertools.highlight_chunks(filename) }
    elseif mode == "fixed" then
        return fixed_match(filename, query, case_sensitive)
    end
    return fuzzy_match(filename, query, case_sensitive)
end

--- Build a result row for a matched file: the filetype icon (when an icon
--- provider is available), its directory prefix, then the filename chunks
--- (fuzzy match highlight).
---@param filepath string
---@param filename string
---@param relative_path string
---@param name_chunks table[]
---@param score number? Match quality; the picker ranks on it.
---@return ezpick.Picker.Item
local function make_file_item(filepath, filename, relative_path, name_chunks, score)
    local filedir       = relative_path:sub(1, #relative_path - #filename)
    local icon, icon_hl = icons.get_icon(filename)
    local chunks        = icon and { { icon, icon_hl }, { " " }, { filedir } } or { { filedir } }
    vim.list_extend(chunks, name_chunks)
    return {
        label_chunks = chunks,
        score        = score,
        data         = { filepath = filepath },
    }
end

---@param query string User input
---@param opts ezpick.filepicker.SearchOpts
---@param fetch_opts ezpick.Picker.FetcherOpts
---@param callback fun(items:ezpick.Picker.Item[]?)
local function async_lua_search(query, opts, fetch_opts, callback)
    local count              = 0
    local max_results        = opts.max_results or 10000
    local items              = {}
    local mode               = opts.mode or "fuzzy"
    local globs              = mode == "glob" and split_globs(query) or nil

    local extensions         = opts.extensions

    local base_excludes      = opts.show_hidden and {} or { ".*", "**/.*" }
    vim.list_extend(base_excludes, opts.exclude_globs or {})
    local exclude_regex_list = strutil.compile_globs(base_excludes)

    local aborted            = false
    local walk_cancel ---@type fun()?
    -- `on_file` cancels the walk once `max_results` is reached, which must hold
    -- even if a slice ever runs before `walk_cancel` is assigned: latch the
    -- request and apply it on return.
    local cancel_requested   = false
    local function cancel_walk()
        cancel_requested = true
        if walk_cancel then walk_cancel() end
    end

    walk_cancel = fsutil.async_walk_dir(
        opts.cwd,
        {
            exclude_regex_list = exclude_regex_list,
            follow_symlinks    = opts.follow_symlinks,
            -- No per-directory redraw: results are only handed over in
            -- `on_done`, so a redraw mid-walk showed nothing new. The walk's
            -- inter-slice yield lets Neovim redraw (and animate the spinner)
            -- on its own.
            on_file            = function(filepath, filename, relative_path)
                if not match_extension(filename, extensions) then return end
                local res = do_match(filename, relative_path, query, mode, opts.case_sensitive, globs)
                if not res then return end
                if count >= max_results then
                    cancel_walk()
                    return
                end
                items[#items + 1] = make_file_item(filepath, filename, relative_path, res.chunks, res.score)
                count = count + 1
            end,
            on_done            = function()
                if aborted then return end
                -- Ranking is the picker's job: it sorts on the score carried by
                -- each item, and leaves the walk order alone for an empty query.
                callback(items)
                callback(nil)
            end
        })

    if cancel_requested then walk_cancel() end

    return function()
        aborted = true
        cancel_walk()
    end
end

---@param opts ezpick.filepicker.Opts?
---@return ezpick.PickerSpec
function M.spec(opts)
    opts = opts or {}
    return {
        prompt             = opts.prompt or "Files",
        flags              = opts.cwd and vim.tbl_filter(function(f) return f.name ~= "dir" end, FLAGS) or FLAGS,
        enable_preview     = true,
        finder             = function(query, flags, fetch_opts, callback)
            if not query or query == "" then
                callback()
                return
            end

            local target_cwd = flags.dir or opts.cwd or vim.fn.getcwd()
            target_cwd = vim.fn.expand(target_cwd)

            ---@type ezpick.filepicker.SearchOpts
            local search_opts = {
                cwd             = target_cwd,
                mode            = resolve_mode(flags),
                -- A non-numeric `--max-results` is ignored rather than read as 0:
                -- a typo there should not silently empty the result list.
                max_results     = tonumber(flags["max-results"]) or opts.max_results,
                case_sensitive  = resolve_case(resolve_case_flag(flags), query),
                follow_symlinks = flags.follow,
                show_hidden     = flags.hidden,
                extensions      = normalize_extensions(flags.extension),
                exclude_globs   = expand_exclude_globs(flags.exclude),
            }
            return async_lua_search(query, search_opts, fetch_opts, callback)
        end,
        quickfix_formatter = function(data)
            ---@type vim.quickfix.entry
            return { filename = data.filepath }
        end,
        on_confirm         = function(data)
            if data and data.filepath then ui.smart_open_file(data.filepath) end
        end,
    }
end

-- Exposed for tests.
M._resolve_case         = resolve_case
M._do_match             = do_match
M._resolve_mode         = resolve_mode
M._resolve_case_flag    = resolve_case_flag
M._normalize_extensions = normalize_extensions
M._match_extension      = match_extension
M._expand_exclude_globs = expand_exclude_globs

return M
