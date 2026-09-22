local M = {}

-- ---------------------------------------------------------------------------
-- The `:Ezpick` command line: cutting its arguments into the picker's two
-- prompt sections, and completing the word under the cursor.
-- `plugin/ezpick.lua` registers the command and requires this only when one is
-- run.
-- ---------------------------------------------------------------------------

---Read one whitespace-delimited token from `str`, starting at `i`. A '\'
---takes the character after it along, so an escaped space stays inside the
---token it was written in and the flags section receives it as written.
---@param str string
---@param i   integer
---@return string? token, integer next_i
local function _read_token(str, i)
    local n = #str
    while i <= n and str:sub(i, i):match("%s") do i = i + 1 end
    if i > n then return nil, i end

    local start = i
    while i <= n do
        local c = str:sub(i, i)
        if c == "\\" and i < n then
            i = i + 2
        elseif c:match("%s") then
            break
        else
            i = i + 1
        end
    end
    return str:sub(start, i - 1), i
end

---Cut the `:Ezpick` arguments past the source name into the two prompt sections.
---`-f` takes one flag, written as the flags line writes it; the first token that
---is not a flag opens the query, which runs to the end of the line, so a query
---needs no quoting and nothing in it is read as a flag. A `--` opens the query
---as well and is dropped, for a query whose first word is `-f` or `--`.
---@param rest string
---@return string flags, string query, string? err
local function _parse_cmdline(rest)
    local flags = {}
    local i     = 1

    while true do
        local start = i
        local tok
        tok, i = _read_token(rest, i)
        if not tok then break end

        if tok == "-f" then
            local flag
            flag, i = _read_token(rest, i)
            if not flag then return "", "", "-f needs a flag" end
            flags[#flags + 1] = flag
        elseif tok == "--" then
            return table.concat(flags, " "), (rest:sub(i):gsub("^%s+", ""))
        else
            return table.concat(flags, " "), (rest:sub(start):gsub("^%s+", ""))
        end
    end

    return table.concat(flags, " "), ""
end

---Candidates for the word under the cursor on the `:Ezpick` line, past the source
---name. Only a `-f` argument is completed: the flag parser answers for it, and
---the query, whether it was opened by a word or by `--`, is free text.
---@param registry table
---@param source string
---@param before string    -- the command line up to the cursor
---@param arg_lead string
---@return string[]
local function _complete_cmdline(registry, source, before, arg_lead)
    -- The word under the cursor, and the token in front of it. The command name
    -- and the source name are read off first: the arguments start past them.
    local head       = before:sub(1, #before - #arg_lead)
    local prev       = nil
    local i          = 1
    i = select(2, _read_token(head, i))
    i = select(2, _read_token(head, i))
    while true do
        local tok
        tok, i = _read_token(head, i)
        if not tok then break end
        -- Anything that is not `-f` or its value opens the query: free text.
        if prev ~= "-f" and tok ~= "-f" then return {} end
        prev = tok
    end

    if prev ~= "-f" then
        return vim.tbl_filter(function(k) return vim.startswith(k, arg_lead) end, { "-f", "--" })
    end

    local flags = registry.get_flags(source)
    if not flags then return {} end

    local queryflags = require("ezpick.base.queryflags")
    local comps      = queryflags.get_completions(flags, arg_lead, #arg_lead)
    if not comps then return {} end

    -- The cmdline replaces the whole argument, so each candidate is put back
    -- behind whatever of it the completion did not claim ("dir=" before a path).
    local kept = arg_lead:sub(1, comps.startcol - 1)
    local out  = {}
    for _, item in ipairs(comps.items) do
        table.insert(out, kept .. item.word)
    end
    return out
end

---Open the picker named on the `:Ezpick` line, seeded with the rest of it.
---@param cmd_opts vim.api.keyset.create_user_command.command_args
function M.run(cmd_opts)
    local source = cmd_opts.fargs[1]
    -- `args` rather than `fargs`: Vim resolves the backslashes in `fargs`,
    -- and a flag value keeps its own (`-f dir=my\ src`).
    local rest = cmd_opts.args:match("^%S+%s+(.*)$") or ""
    local flags, query, err = _parse_cmdline(rest)
    if err then
        vim.notify(err, vim.log.levels.WARN)
        return
    end
    require("ezpick").pick(source, { flags = flags, query = query })
end

---Completion for the `:Ezpick` line: source names in the first argument, the
---source's flags past it.
---@param arg_lead string
---@param cmd_line string
---@param cursor_pos integer
---@return string[]
function M.complete(arg_lead, cmd_line, cursor_pos)
    local registry = require("ezpick.registry")
    local before   = cmd_line:sub(1, cursor_pos)
    local parts    = vim.split(before, "%s+", { trimempty = true })
    if #parts <= 1 or (#parts == 2 and not before:match("%s$")) then
        local keys = registry.keys()
        table.insert(keys, "resume")
        table.sort(keys)
        return vim.tbl_filter(function(k) return vim.startswith(k, arg_lead) end, keys)
    end

    return _complete_cmdline(registry, parts[2], before, arg_lead)
end

return M
