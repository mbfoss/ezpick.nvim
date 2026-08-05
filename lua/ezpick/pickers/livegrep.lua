local M           = {}

local ui          = require("ezpick.util.ui")
local strutil     = require("ezpick.util.strutil")
local fsutil      = require("ezpick.util.fsutil")
local spawn       = require("ezpick.util.spawn")
local pickertools = require("ezpick.base.pickertools")

--- High-water mark (bytes) for stdin backpressure: buffers are fed to rg ahead
--- of itself for throughput, but once its stdin write queue is backed up past
--- this we wait for it to drain before pushing more, so buffered memory stays
--- bounded even with very large or very many open buffers.
local _MAX_WRITE_QUEUE = 1024 * 1024

---@class ezpick.rgutil.Submatch
---@field s    integer  -- 0-indexed byte start in the line
---@field e    integer  -- 0-indexed byte end (exclusive) in the line
---@field repl string?  -- rg-computed replacement text (nil unless --replace was used)

---@class ezpick.rgutil.Match
---@field path string
---@field lnum integer
---@field col  integer  -- 1-indexed byte column of the first submatch
---@field text string
---@field subs ezpick.rgutil.Submatch[]

---@param line string
---@return ezpick.rgutil.Match?
local function parse_match(line)
    local ok, decoded = pcall(vim.json.decode, line)
    if not ok or not decoded or decoded.type ~= "match" then return end

    local data = decoded.data
    local path = data.path and data.path.text
    if not path then return end

    local text = data.lines.text or data.lines.bytes or ""
    text       = text:gsub("\r?\n$", "")

    local subs = {}
    for _, m in ipairs(data.submatches or {}) do
        subs[#subs + 1] = {
            s    = m.start,
            e    = m["end"],
            repl = m.replacement and m.replacement.text or nil,
        }
    end

    local col = (subs[1] and subs[1].s + 1) or 1
    return { path = path, lnum = data.line_number, col = col, text = text, subs = subs }
end

---@param text      string
---@param subs      ezpick.rgutil.Submatch[]
---@param show_repl boolean?  -- render "old → new" diff chunks instead of a single highlighted match
---@return {[1]:string,[2]:string?}[]
local function build_chunks(text, subs, show_repl)
    local chunks = {}
    local last   = 1
    for _, sm in ipairs(subs) do
        local s = sm.s + 1
        local e = sm.e
        if s > last then
            chunks[#chunks + 1] = { text:sub(last, s - 1) }
        end
        if show_repl and sm.repl then
            if #sm.repl > 0 then
                chunks[#chunks + 1] = { sm.repl, "IncSearch" }
            end
        else
            chunks[#chunks + 1] = { text:sub(s, e), "EzPickMatch" }
        end
        last = e + 1
    end
    if last <= #text then
        chunks[#chunks + 1] = { text:sub(last) }
    end
    return chunks
end

---@param text string
---@param subs ezpick.rgutil.Submatch[]
---@return string
local function apply_subs(text, subs)
    local parts = {}
    local last  = 1
    for _, sm in ipairs(subs) do
        local s = sm.s + 1
        local e = sm.e
        parts[#parts + 1] = text:sub(last, s - 1)
        parts[#parts + 1] = sm.repl or text:sub(s, e)
        last              = e + 1
    end
    parts[#parts + 1] = text:sub(last)
    return table.concat(parts)
end

---@param items ezpick.Picker.Item[]
---@return integer total_occurrences, integer file_count
local function count_matches(items)
    local files = {}
    local total = 0
    for _, item in ipairs(items) do
        local d = item.data
        if d and d.filepath and d.subs then
            files[d.filepath] = true
            total             = total + #d.subs
        end
    end
    return total, vim.tbl_count(files)
end

---@param items ezpick.Picker.Item[]
local function apply_replace_all(items)
    local by_file = {}
    local order   = {}
    for _, item in ipairs(items) do
        local d = item.data
        if d and d.filepath and d.lnum and d.subs then
            if not by_file[d.filepath] then
                by_file[d.filepath] = {}
                order[#order + 1]   = d.filepath
            end
            table.insert(by_file[d.filepath], { lnum = d.lnum, subs = d.subs })
        end
    end

    for _, filepath in ipairs(order) do
        local bufnr = vim.fn.bufadd(filepath)
        vim.bo[bufnr].buflisted = true
        vim.fn.bufload(bufnr)
        for _, edit in ipairs(by_file[filepath]) do
            local lnum = edit.lnum
            if lnum >= 1 and lnum <= vim.api.nvim_buf_line_count(bufnr) then
                local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
                if line then
                    local new_line = apply_subs(line, edit.subs)
                    if new_line ~= line then
                        vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { new_line })
                    end
                end
            end
        end
    end
end

---@class ezpick.livegrep.opts
---@field max_results number?

---@class ezpick.livegrep.grep_opts
---@field cwd         string
---@field max_results number?

--- rg's file types (`rg --type-list`), parsed once per session: `{ lua = { "*.lua" }, … }`.
---@type table<string, string[]>?
local _rg_types

---@return table<string, string[]>
local function rg_types()
    if _rg_types then return _rg_types end

    local types = {}
    if vim.fn.executable("rg") == 1 then
        local res = vim.system({ "rg", "--type-list" }, { text = true }):wait()
        if res.code == 0 then
            for line in vim.gsplit(res.stdout or "", "\n", { trimempty = true }) do
                local name, globs = line:match("^([^:]+):%s*(.+)$")
                if name then
                    local list = {}
                    for g in vim.gsplit(globs, ",", { trimempty = true }) do
                        list[#list + 1] = vim.trim(g)
                    end
                    types[name] = list
                end
            end
        end
    end

    _rg_types = types
    return types
end

---@param partial string
---@return string[]
local function complete_type(partial)
    local names = vim.tbl_keys(rg_types())
    table.sort(names)
    return vim.tbl_filter(function(n) return vim.startswith(n, partial) end, names)
end

---@type ezpick.queryflags.FlagDef[]
local FLAGS       = {
    { name = "dir",     type = "value",   complete = "dir",          desc = "search root directory"              },
    { name = "filter",  type = "value",   multi = true,              desc = "glob filter: *.txt, !*.lua, **/dir/**" },
    { name = "type",      type = "value", multi = true, complete = complete_type, desc = "rg file type: lua, rust, !md (see rg --type-list)" },
    { name = "regex",   type = "boolean", desc = "enable regex mode"                                             },
    { name = "case",    type = "value",   values = { "smart", "on", "off" }, desc = "case: smart (default) | on | off" },
    { name = "word",      type = "boolean", desc = "match whole words only"                                      },
    { name = "line",      type = "boolean", desc = "match whole lines only"                                      },
    { name = "invert",    type = "boolean", desc = "show lines that do NOT match"                                 },
    { name = "follow",    type = "boolean", desc = "follow symlinks"                                             },
    { name = "hidden",    type = "boolean", desc = "include hidden (dotfiles)"                                   },
    { name = "no-ignore", type = "boolean", desc = "disable .gitignore / .ignore rules"                         },
    { name = "max-depth", type = "value",   desc = "max directory depth to descend"                              },
    { name = "replace",   type = "value", allow_empty = true,        desc = "replacement text (search & replace)" },
}


--- Common rg flags shared by the disk and in-buffer searches. Excludes globs,
--- the query, and the search target (those differ per search).
---@param parsed ezpick.queryflags.ParseResult
---@return string[] args
local function build_rg_base(parsed)
    local flags = parsed.flags
    local args  = { "--json", "--no-heading", "--glob-case-insensitive" }

    if flags.follow then
        table.insert(args, "--follow")
    end

    if flags.hidden then
        table.insert(args, "--hidden")
    end

    if flags["no-ignore"] then
        table.insert(args, "--no-ignore")
    end

    if flags.case == "on" then
        table.insert(args, "--case-sensitive")
    elseif flags.case == "off" then
        table.insert(args, "--ignore-case")
    else
        table.insert(args, "--smart-case")
    end

    if not flags.regex then
        table.insert(args, "--fixed-strings")
    end

    if flags.word then
        table.insert(args, "--word-regexp")
    end

    if flags.line then
        table.insert(args, "--line-regexp")
    end

    if flags.invert then
        table.insert(args, "--invert-match")
    end

    if flags.replace then
        table.insert(args, "--replace")
        table.insert(args, flags.replace)
    end

    return args
end

--- Directory search. Disk matches for files that are open in a buffer are
--- dropped by the caller (post-filter) so their in-memory versions take
--- priority — cheaper and more robust than emitting a glob per open file.
---@param parsed ezpick.queryflags.ParseResult
---@return string[] cmd
local function build_rg_dir_cmd(parsed)
    local args = build_rg_base(parsed)
    table.insert(args, "--sort")
    table.insert(args, "path")
    for _, g in ipairs(parsed.flags["filter"] or {}) do
        table.insert(args, "-g")
        table.insert(args, g)
    end
    for _, t in ipairs(parsed.flags["type"] or {}) do
        if t:sub(1, 1) == "!" then
            table.insert(args, "--type-not")
            table.insert(args, t:sub(2))
        else
            table.insert(args, "--type")
            table.insert(args, t)
        end
    end
    local depth = tonumber(parsed.flags["max-depth"])
    if depth then
        table.insert(args, "--max-depth")
        table.insert(args, tostring(math.floor(depth)))
    end
    table.insert(args, "--")
    table.insert(args, parsed.query)
    table.insert(args, ".")
    return vim.list_extend({ "rg" }, args)
end

--- Split a flag-glob list ("*.lua", "!*_spec.lua") into compiled include/exclude
--- regexes. rg's own `-g` only filters disk traversal, not stdin input, so open
--- buffers are filtered in-process instead.
---@param filters string[]?
---@return vim.regex[]? include, vim.regex[]? exclude
local function compile_filter_globs(filters)
    local include, exclude = {}, {}
    for _, g in ipairs(filters or {}) do
        if g:sub(1, 1) == "!" then
            exclude[#exclude + 1] = g:sub(2)
        else
            include[#include + 1] = g
        end
    end
    return (#include > 0 and strutil.compile_globs(include) or nil),
        (#exclude > 0 and strutil.compile_globs(exclude) or nil)
end

--- Same idea for `--type`: rg's own `-t` filters files it walks, not stdin, so
--- the type globs are expanded here and matched against each buffer's basename
--- (rg matches a slashless type glob the same way).
---@param types string[]?
---@return vim.regex[]? include, vim.regex[]? exclude
local function compile_type_globs(types)
    if not types or #types == 0 then return nil, nil end

    local known = rg_types()
    local include, exclude = {}, {}
    for _, t in ipairs(types) do
        local negated = t:sub(1, 1) == "!"
        local name    = negated and t:sub(2) or t
        local target  = negated and exclude or include
        for _, g in ipairs(known[name] or {}) do
            target[#target + 1] = g
        end
    end
    return (#include > 0 and strutil.compile_globs(include) or nil),
        (#exclude > 0 and strutil.compile_globs(exclude) or nil)
end

---@class ezpick.livegrep.OpenBuf
---@field bufnr   integer
---@field path    string  absolute file path
---@field relpath string  path relative to the search cwd

--- Loaded, file-backed buffers under `cwd` that pass the filter globs. These are
--- searched from their in-memory text so unsaved (and stale-on-disk) edits win.
---@param cwd       string
---@param filters   string[]?
---@param types     string[]?
---@param max_depth number?  -- directory depth limit, mirroring rg's --max-depth
---@return ezpick.livegrep.OpenBuf[]
local function collect_open_buffers(cwd, filters, types, max_depth)
    local include_re, exclude_re = compile_filter_globs(filters)
    local type_include, type_exclude = compile_type_globs(types)
    local out = {}
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buftype == "" then
            local name = vim.api.nvim_buf_get_name(bufnr)
            if name ~= "" then
                local path = vim.fn.fnamemodify(name, ":p")
                local rel  = fsutil.get_relative_path(path, cwd)
                local base = rel and vim.fs.basename(rel) or ""
                if rel
                    and strutil.check_path_pattern(rel, false, include_re, exclude_re)
                    and strutil.check_path_pattern(base, false, type_include, type_exclude)
                    and (not max_depth or select(2, rel:gsub("/", "")) < max_depth)
                then
                    out[#out + 1] = { bufnr = bufnr, path = path, relpath = rel }
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.relpath < b.relpath end)
    return out
end

--- Marker prefixed to the location line for matches sourced from an open
--- buffer's in-memory text rather than the on-disk file.
local _BUFFER_INDICATOR = "≡ "
local _BUFFER_INDICATOR_WIDTH = vim.fn.strdisplaywidth(_BUFFER_INDICATOR)

--- Build a picker item from a parsed rg match at an absolute path.
---@param m           ezpick.rgutil.Match
---@param abs_path    string
---@param cwd         string
---@param list_width  integer
---@param show_repl   boolean?
---@param rel_path    string?  precomputed cwd-relative path (avoids recomputation)
---@param from_buffer boolean?  match came from an open buffer, not disk
---@return ezpick.Picker.Item
local function make_item(m, abs_path, cwd, list_width, show_repl, rel_path, from_buffer)
    rel_path = rel_path or fsutil.get_relative_path(abs_path, cwd) or abs_path
    local indicator_width = from_buffer and _BUFFER_INDICATOR_WIDTH or 0
    local location = fsutil.smart_crop_path(
        string.format("%s:%s", rel_path, m.lnum),
        list_width - indicator_width
    )
    local virt_line = {}
    if from_buffer then
        virt_line[#virt_line + 1] = { _BUFFER_INDICATOR, "EzPickBufferIndicator" }
    end
    virt_line[#virt_line + 1] = { location, "EzPickPath" }
    return {
        label_chunks = build_chunks(m.text, m.subs, show_repl),
        virt_line    = virt_line,
        data         = { filepath = abs_path, lnum = m.lnum, col = m.col, subs = m.subs },
    }
end

---@param filepath string  absolute path
---@return integer? bufnr  a loaded buffer holding this exact file, if any
local function loaded_buf_for(filepath)
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr)
            and vim.api.nvim_buf_get_name(bufnr) == filepath then
            return bufnr
        end
    end
end

--- Preview the live buffer when the file is open, so the preview matches the
--- (possibly modified or stale-on-disk) text the result list was built from.
--- Falls back to the on-disk previewer for files with no open buffer.
---@type ezpick.Picker.AsyncPreviewLoader
local function buffer_preview(data, opts, callback)
    local filepath = data.filepath
    if filepath and filepath ~= "" then
        local bufnr = loaded_buf_for(filepath)
        if bufnr then
            callback({
                bufnr = bufnr,
                pos   = data.lnum and { data.lnum, data.col or 0 } or nil,
            })
            return
        end
    end
    return pickertools.file_preview(data, opts, callback)
end

--------------------------------------------------------------------------------
-- In-buffer search (single rg over stdin): every open buffer's in-memory text is
-- concatenated into one stdin doc streamed to `rg -` (unsaved edits win; N buffers
-- cost one subprocess), and the continuous line counter is mapped back per buffer.
--------------------------------------------------------------------------------

--- Build the rg command for the in-buffer search. Mirrors the disk flags (case,
--- fixed-strings, replace) but adds --line-buffered so matches stream out while
--- later buffers are still being fed, and targets `-` (stdin).
---@param parsed ezpick.queryflags.ParseResult
---@return string[] cmd
local function build_rg_stdin_cmd(parsed)
    local args = build_rg_base(parsed)
    table.insert(args, "--line-buffered")
    table.insert(args, "--")
    table.insert(args, parsed.query)
    table.insert(args, "-")
    return vim.list_extend({ "rg" }, args)
end

--- Precompute where each buffer begins in the concatenated stdin stream:
--- `starts[i]` is the 1-based line number of `bufs[i]`'s first line. Buffers are
--- newline-joined and newline-separated, and Neovim buffer lines never contain a
--- newline, so the stream's line counter is exact and matches never straddle a
--- buffer boundary (the search is line-oriented).
---@param bufs ezpick.livegrep.OpenBuf[]
---@return integer[] starts
local function buffer_line_offsets(bufs)
    local starts    = {}
    local next_line = 1
    for i, b in ipairs(bufs) do
        starts[i]  = next_line
        next_line  = next_line + vim.api.nvim_buf_line_count(b.bufnr)
    end
    return starts
end

--- Map a 1-based stream line back to its buffer: the largest `starts[i] <= gline`.
---@param starts integer[]  ascending buffer start lines
---@param gline  integer    1-based line in the concatenated stream
---@return integer buf_index, integer local_lnum
local function locate_line(starts, gline)
    local lo, hi = 1, #starts
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if starts[mid] <= gline then lo = mid else hi = mid - 1 end
    end
    return lo, gline - starts[lo] + 1
end

---@param parsed     ezpick.queryflags.ParseResult
---@param grep_opts  ezpick.livegrep.grep_opts
---@param fetch_opts ezpick.Picker.FetcherOpts
---@param callback   fun(items:table[]?)
---@return fun()? cancel
local function async_grep(parsed, grep_opts, fetch_opts, callback)
    if parsed.query == "" then
        callback()
        return
    end

    local show_repl   = parsed.flags.replace ~= nil
    local max_results = grep_opts.max_results or 10000
    local cwd         = grep_opts.cwd
    local list_width  = fetch_opts.list_width

    -- Open buffers take priority: search their in-memory text, then drop the
    -- on-disk matches for those same files so stale disk content never wins.
    local bufs = collect_open_buffers(
        cwd,
        parsed.flags["filter"],
        parsed.flags["type"],
        tonumber(parsed.flags["max-depth"])
    )
    local open_relpaths = {} ---@type table<string, true>
    for _, b in ipairs(bufs) do
        open_relpaths[b.relpath] = true
    end

    local cancelled = false
    local buf_items = {} ---@type ezpick.Picker.Item[]
    local dir_items = {} ---@type ezpick.Picker.Item[]
    local buf_handle ---@type ezpick.util.SpawnHandle?
    local dir_handle ---@type ezpick.util.SpawnHandle?

    -- Both searches run as async rg jobs; finish() fires once both have settled,
    -- with buffer matches leading the merged list.
    local pending = 2
    local function finish()
        if cancelled then return end
        local merged = {}
        vim.list_extend(merged, buf_items)
        vim.list_extend(merged, dir_items)
        for i = #merged, max_results + 1, -1 do
            merged[i] = nil
        end
        callback(merged)
    end
    local function settle()
        if cancelled then return end
        pending = pending - 1
        if pending == 0 then finish() end
    end

    ----------------------------------------------------------------------------
    -- In-buffer search: one rg reading every open buffer's in-memory text from stdin.
    -- Buffers are pumped one at a time with backpressure (peak extra memory ~one buffer),
    -- and each match's stream line is mapped back to its owning buffer.
    ----------------------------------------------------------------------------
    if #bufs == 0 then
        settle()
    else
        local starts   = buffer_line_offsets(bufs)
        local stop_buf = false
        local buf_done = false
        local buf_count = 0

        local buf_feed = strutil.create_line_buffered_feed(function(lines)
            for _, line in ipairs(lines) do
                if stop_buf then return end
                local m = parse_match(line)
                if m and m.lnum then
                    local idx, lnum = locate_line(starts, m.lnum)
                    local b = bufs[idx]
                    if b then
                        m.lnum = lnum
                        m.path = b.path
                        buf_items[#buf_items + 1] =
                            make_item(m, b.path, cwd, list_width, show_repl, b.relpath, true)
                        buf_count = buf_count + 1
                        if buf_count >= max_results then
                            stop_buf = true
                            if buf_handle then buf_handle.kill() end
                            return
                        end
                    end
                end
            end
        end)

        -- Pump one buffer per stdin write, resuming the next on the main loop (buffer
        -- reads are banned in libuv's fast callbacks). Writes fire ahead without blocking,
        -- but once rg's stdin backs up past the high-water mark we drain before feeding more.
        local function pump(i)
            if cancelled or stop_buf or buf_done then return end
            if i > #bufs then
                if buf_handle then buf_handle.write(nil) end
                return
            end
            if not buf_handle then return end
            local lines = vim.api.nvim_buf_get_lines(bufs[i].bufnr, 0, -1, false)
            local chunk = table.concat(lines, "\n") .. "\n"
            if buf_handle.get_write_queue_size() >= _MAX_WRITE_QUEUE then
                buf_handle.write(chunk, function()
                    vim.schedule(function() pump(i + 1) end)
                end)
            else
                buf_handle.write(chunk)
                vim.schedule(function() pump(i + 1) end)
            end
        end

        local ok = pcall(function()
            buf_handle = spawn(
                build_rg_stdin_cmd(parsed),
                {
                    cwd    = cwd,
                    stdin  = true,
                    stdout = function(data)
                        if not stop_buf then buf_feed(data) end
                    end,
                },
                function()
                    buf_done = true
                    settle()
                end
            )
        end)

        if ok and buf_handle then
            pump(1)
        else
            buf_done = true
            settle()
        end
    end

    ----------------------------------------------------------------------------
    -- Directory search (rg over the filesystem, open buffers excluded).
    ----------------------------------------------------------------------------
    local stop_read = false
    local count     = 0

    local function on_error(msg)
        ---@type ezpick.Picker.Item
        table.insert(dir_items, {
            label_chunks = { { "ERROR: ", "Error" }, { msg } },
            data         = {},
        })
    end

    local buffered_feed = strutil.create_line_buffered_feed(function(lines)
        for _, line in ipairs(lines) do
            if stop_read then return end
            local m = parse_match(line)
            if m then
                local abs_path = vim.fs.joinpath(cwd, m.path)
                local rel_path = fsutil.get_relative_path(abs_path, cwd)
                -- Skip files already covered by the in-buffer search.
                if not (rel_path and open_relpaths[rel_path]) then
                    dir_items[#dir_items + 1] =
                        make_item(m, abs_path, cwd, list_width, show_repl, rel_path)
                    count = count + 1
                    if count >= max_results then
                        stop_read = true
                        if dir_handle then dir_handle.kill() end
                        break
                    end
                end
            end
        end
    end)

    local ok, err = pcall(function()
        dir_handle = spawn(
            build_rg_dir_cmd(parsed),
            {
                cwd    = cwd,
                stdout = function(data)
                    if not stop_read then buffered_feed(data) end
                end,
                stderr = function(data)
                    on_error(data)
                end,
            },
            function() settle() end
        )
    end)

    if not ok then
        on_error(err or "failed to launch ripgrep")
        vim.schedule(settle)
    end

    return function()
        cancelled = true
        if buf_handle then buf_handle.kill() end
        if dir_handle then dir_handle.kill() end
    end
end

---@param opts ezpick.livegrep.opts?
---@return ezpick.PickerSpec
function M.spec(opts)
    opts = opts or {}

    local _last_items    = {} ---@type ezpick.Picker.Item[]
    local _replace_value ---@type string?

    ---@type ezpick.PickerSpec
    return {
        prompt          = "Live Grep",
        flags           = FLAGS,
        enable_preview  = true,
        previewer       = buffer_preview,
        finder           = function(query, flags, fetch_opts, callback)
            local parsed     = { query = query, flags = flags }
            local target_cwd = flags.dir and vim.fn.expand(flags.dir) or vim.fn.getcwd()
            _replace_value   = flags.replace
            return async_grep(parsed, {
                cwd         = target_cwd,
                max_results = opts.max_results or 10000,
            }, fetch_opts, function(items)
                _last_items = items or {}
                callback(items)
            end)
        end,
        on_confirm = function(data)
            if not data then return end
            if _replace_value then
                local total, file_count = count_matches(_last_items)
                if total == 0 then return end
                ui.confirm_action(
                    string.format("Replace %d occurrence(s) across %d file(s)?", total, file_count),
                    false,
                    function(confirmed)
                        if not confirmed then return end
                        apply_replace_all(_last_items)
                        vim.notify(
                            string.format(
                                "Replaced %d occurrence(s) in %d file(s) (buffers modified, not saved)",
                                total, file_count
                            ),
                            vim.log.levels.INFO
                        )
                    end
                )
            else
                if data.filepath and data.lnum and data.col then
                    ui.smart_open_file(data.filepath, data.lnum, data.col - 1)
                end
            end
        end,
    }
end

return M
