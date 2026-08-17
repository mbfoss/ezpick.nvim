local M = {}

---A source for a value flag's completion candidates: either a
---`vim.fn.getcompletion()` type (e.g. "file", "dir", "buffer", "color"), or a
---function returning candidates for the partial value typed so far.
---@alias ezpick.queryflags.CompleteSpec string|fun(partial:string):string[]

---@class ezpick.queryflags.FlagDef
---@field name     string
---@field type     "boolean"|"value"
---@field multi    boolean?   -- allow multiple occurrences (type=value only)
---@field strict   boolean?   -- `values` is the complete set; anything else is hinted (type=value only, requires `values`)
---@field values   string[]?  -- known static values offered in completion (type=value only)
---@field complete ezpick.queryflags.CompleteSpec?  -- dynamic value completion source (type=value only)
---@field alias    string[]?  -- extra names accepted for this flag
---@field desc     string?    -- shown in the completion menu, beside the form the flag takes

---@alias ezpick.queryflags.HintKind
---| "unknown-flag"     -- a dashed word that names no flag
---| "duplicate-flag"   -- a single-valued flag given more than once
---| "missing-value"    -- a value flag with nothing to take
---| "bad-value"        -- a value outside a strict flag's `values`
---| "unexpected-value" -- a value glued onto a switch

---A problem worth pointing out that is never worth refusing to search over:
---every hint is advisory, and `parse` always returns a usable query beside it.
---
---Everything wrong with the line is reported, including the half-written states
---any correct flag passes through on the way to being one. Telling those apart
---takes the cursor, which `parse` does not have: a consumer that shows hints as
---they are typed holds back the kinds that typing can still resolve until the
---cursor leaves the span --- except where `settled` says typing on cannot.
---@class ezpick.queryflags.Hint
---@field start   integer  -- 0-indexed byte start of the offending span
---@field finish  integer  -- 0-indexed byte end of the offending span (exclusive)
---@field msg     string   -- terse; it shares the prompt line with the query
---@field kind    ezpick.queryflags.HintKind
---@field settled boolean? -- typing on cannot resolve this one, so a consumer that
---                        -- holds hints back while they are being written should
---                        -- show it anyway

---@class ezpick.queryflags.ParseResult
---@field query       string  -- the query, verbatim: every byte from where the flags stop
---@field query_start integer -- 1-indexed byte offset where `query` begins (#raw+1 when empty)
---@field flags       table   -- {[name] = true | string | string[]}
---@field hints       ezpick.queryflags.Hint[]

---@class ezpick.queryflags.Completions
---@field startcol integer  -- 1-indexed column for vim.fn.complete()
---@field items    table[]

---Marks a flag ("--name"); alone it is the separator that ends the flagged
---section, after which everything is literal text.
local _PREFIX = "--"

-- Syntax:
--
--   [--flag] [--flag value] [--flag=value] ... [--] <query, verbatim>
--
-- Flags come first. Scanning stops at the first token that does not name a
-- known flag, and everything from there to the end of the line is the query,
-- byte for byte -- spaces, backslashes and dashes in it are ordinary characters.
-- That verbatim tail is the point of the ordering: a picker that greps for what
-- was typed must receive exactly what was typed.
--
--   '--hidden --dir src foo  bar'  → flags hidden, dir=src; query 'foo  bar'
--   'foo --hidden'                 → query 'foo --hidden', flag unset
--
-- Flag names are matched loosely: case, '-' and '_' are ignored, so --no-ignore,
-- --noignore and --NoIgnore are the same flag, as is any name listed in `alias`.
--
-- A value flag takes its value either glued on with '=' or as the next token.
-- The glued form is the precise one: it can express an empty value ("--repl=")
-- and a value that looks like a flag ("--dir=--x"). In the spaced form a token
-- naming a known flag is not swallowed as a value -- '--dir --hidden' is a
-- forgotten value, not a directory called "--hidden".
--
-- Escaping (via \) applies only to a value, anywhere in it, by Neovim's own
-- rule for command arguments (:h <f-args>): '\\' is one backslash, '\' before
-- whitespace is that whitespace as an ordinary character, and a '\' before
-- anything else -- including the end of the line -- is left exactly as written.
--   '--path foo\ bar'   → path = 'foo bar'
--   '--path=foo\ bar'   → path = 'foo bar'
--   '--path a\\b'       → path = 'a\b'
--   '--path a\b'        → path = 'a\b'   -- 'b' is not escapable
-- So nothing typed here is ever malformed: an escape half-written is a literal
-- backslash until the character that gives it meaning arrives. Quotes have no
-- meaning at all -- '--path "foo' is the value '"foo'.
--
-- Because the query is whatever follows the flags, a flag name only needs
-- escaping when the query *starts* with one. A standalone "--" ends the flagged
-- section for that case:
--   '-- --hidden'  → query '--hidden'
--
---@class ezpick.queryflags.Piece
---@field kind     "flag"|"value"|"separator"
---@field start    integer     -- 1-indexed start in source
---@field finish   integer     -- 1-indexed finish in source (inclusive)
---@field name     string?     -- canonical flag this piece names (kind="flag") or feeds (kind="value")
---@field typed    string?     -- how that flag was actually spelled here, which `name` may only be a synonym of
---@field text     string?     -- decoded value, escapes resolved (kind="value")
---@field eq       integer?    -- 1-indexed position of the '=' gluing a value on (kind="flag")
---@field escapes  integer[]?  -- 1-indexed position of each '\' that escaped a character

---Lookup key for a flag name: the form in which two spellings of the same flag
---are equal. Case and the word separators '-' and '_' carry no meaning, so a
---user who writes --noignore gets the flag they obviously meant.
---@param name string
---@return string
local function _key(name)
    return (name:lower():gsub("[-_]", ""))
end

---@param schema ezpick.queryflags.FlagDef[]
---@return table<string, ezpick.queryflags.FlagDef>
local function _build_map(schema)
    local m = {}
    for _, def in ipairs(schema) do
        -- Strictness is enforced against `values`, so a strict flag that lists
        -- none would quietly accept everything. That is a schema mistake rather
        -- than a user one, and it is worth hearing about on the first render
        -- instead of never: everything downstream may take the pair as given.
        assert(not def.strict or (def.values and #def.values > 0),
            ("%s%s is strict but lists no values"):format(_PREFIX, def.name))
        m[_key(def.name)] = def
        for _, alias in ipairs(def.alias or {}) do m[_key(alias)] = def end
    end
    return m
end

---A "--name" at `i`, if one is written there. Returns nil for a bare "--" and
---for anything that is not dashed, so the caller can tell the three apart.
---@param str string
---@param i   integer
---@return string? name, integer? finish  -- 1-indexed finish of the dashes+name
local function _dashed_name(str, i)
    if str:sub(i, i + 1) ~= _PREFIX then return nil, nil end
    local name = str:match("^[^%s=]*", i + #_PREFIX)
    if name == "" then return nil, nil end
    return name, i + #_PREFIX + #name - 1
end

---Read a value starting at `i`: a whitespace-delimited run, except that a
---backslash escapes a following backslash or whitespace, which is what lets a
---value hold either. Anything else a backslash precedes is not escapable, and
---the backslash then stands for itself -- `:h <f-args>`, exactly.
---@param str string
---@param i   integer
---@return ezpick.queryflags.Piece piece, integer next_i
local function _read_value(str, i)
    local len       = #str
    local tok_start = i
    local chars     = {}
    local escapes   = {}

    while i <= len do
        local c     = str:sub(i, i)
        local after = str:sub(i + 1, i + 1)
        if c == "\\" and (after == "\\" or after:match("%s")) then
            escapes[#escapes + 1] = i
            chars[#chars + 1]     = after
            i                     = i + 2
        elseif c:match("%s") then
            break
        else
            -- A '\' with nothing escapable behind it, the end of the line
            -- included: content, not syntax. There is no half-written escape to
            -- report, and none to repair.
            chars[#chars + 1] = c
            i                 = i + 1
        end
    end

    return {
        kind    = "value",
        start   = tok_start,
        finish  = i - 1,
        text    = table.concat(chars),
        escapes = #escapes > 0 and escapes or nil,
    }, i
end

---Walk the flagged prefix of `str`, stopping at the query.
---@param str    string
---@param defs   table<string, ezpick.queryflags.FlagDef>
---@return ezpick.queryflags.Piece[] pieces, integer query_start, ezpick.queryflags.Hint[] hints, ezpick.queryflags.FlagDef? pending
local function _scan(str, defs)
    local pieces  = {}
    local hints   = {}
    local len     = #str
    local i       = 1
    ---@type ezpick.queryflags.FlagDef?
    local pending = nil -- a value flag left waiting for its value at end of input

    ---@param kind    ezpick.queryflags.HintKind
    ---@param s       integer  -- 1-indexed inclusive
    ---@param e       integer  -- 1-indexed inclusive
    ---@param msg     string
    ---@param settled boolean? -- see `Hint.settled`
    local function hint(kind, s, e, msg, settled)
        hints[#hints + 1] = { kind = kind, start = s - 1, finish = e, msg = msg, settled = settled or nil }
    end

    ---Every message echoes the spelling on the line rather than the canonical
    ---name: the mark and the words have to describe the same thing, and with an
    ---alias in play the canonical name may be nowhere in sight.
    ---@param def   ezpick.queryflags.FlagDef
    ---@param typed string  -- the flag as written here
    ---@return string
    local function needs_value(def, typed)
        if def.strict then
            return ("%s%s: %s"):format(_PREFIX, typed, table.concat(assert(def.values), "|"))
        end
        return ("%s%s needs a value"):format(_PREFIX, typed)
    end

    while i <= len do
        while i <= len and str:sub(i, i):match("%s") do i = i + 1 end
        if i > len then break end

        local tok_start = i

        -- The separator ends the flagged section: everything after it is query.
        if str:sub(i, i + 1) == _PREFIX and (i + 2 > len or str:sub(i + 2, i + 2):match("%s")) then
            pieces[#pieces + 1] = { kind = "separator", start = i, finish = i + 1 }
            i = i + 2
            while i <= len and str:sub(i, i):match("%s") do i = i + 1 end
            return pieces, i, hints, nil
        end

        local name, name_end = _dashed_name(str, i)
        local def            = name and defs[_key(name)]
        if not def then
            -- Not a flag, so this is where the query begins. A dashed word that
            -- merely misses the schema is worth a nudge. Whether it is a typo or
            -- a prefix still being typed is not decided here: only the cursor
            -- tells those two apart, and the consumer is the one holding it.
            if name then
                assert(name_end)
                hint("unknown-flag", tok_start, name_end, ("unknown option %s%s"):format(_PREFIX, name))
            end
            return pieces, tok_start, hints, nil
        end

        -- A def was only found by looking a name up, so both are written here.
        assert(name and name_end)
        i = name_end + 1

        ---@type ezpick.queryflags.Piece
        local flag_piece = { kind = "flag", start = tok_start, finish = name_end, name = def.name, typed = name }
        pieces[#pieces + 1] = flag_piece

        if str:sub(i, i) == "=" then
            -- The glued form is exact: it can carry an empty value, or one that
            -- would otherwise read as the next flag.
            flag_piece.eq = i
            i = i + 1
            local value
            value, i = _read_value(str, i)
            value.name = def.name
            value.typed = name
            flag_piece.finish = value.finish
            if def.type == "boolean" then
                -- A switch is written by being there, so there is no value it
                -- could be assigned that would be right: "--fixed=false" reads
                -- as turning something off and "--fixed=true" as belt and
                -- braces, and neither is a form this understands. Both are the
                -- same mistake, and `parse` leaves the switch alone rather than
                -- picking the reading that happens to be spelled out.
                hint("unexpected-value", tok_start, value.finish,
                    ("%s%s takes no value"):format(_PREFIX, name))
            else
                pieces[#pieces + 1] = value
            end
        elseif def.type == "value" then
            local j = i
            while j <= len and str:sub(j, j):match("%s") do j = j + 1 end
            local next_name = _dashed_name(str, j)
            local next_sep  = str:sub(j, j + 1) == _PREFIX and (j + 2 > len or str:sub(j + 2, j + 2):match("%s"))
            if j > len then
                -- Nothing typed yet: the slot is open rather than wrong, so this
                -- doubles as the prompt for what to put there. The slot only
                -- exists once something separates it from the name, though:
                -- "--mode" is a name still being typed -- perhaps into "--modes"
                -- -- and offering it values would complete the wrong thing.
                if i <= len then pending = def end
                hint("missing-value", tok_start, name_end, needs_value(def, name))
            elseif next_sep or (next_name and defs[_key(next_name)]) then
                -- Something already stands where the value would go, so the slot
                -- is closed: unlike the open one above, typing on at the end of
                -- the line will never fill it. Settled, and said at once --- it
                -- is exactly the state a value deleted from the middle leaves
                -- behind, and going quiet there rewards making the line worse.
                hint("missing-value", tok_start, name_end, needs_value(def, name), true)
            else
                local value
                value, i = _read_value(str, j)
                value.name = def.name
                value.typed = name
                pieces[#pieces + 1] = value
            end
        end
    end

    return pieces, len + 1, hints, pending
end

---@param schema ezpick.queryflags.FlagDef[]
---@param raw    string
---@return ezpick.queryflags.ParseResult
function M.parse(schema, raw)
    local defs                         = _build_map(schema)
    local flags                        = {}
    local pieces, query_start, hints   = _scan(raw, defs)
    ---Name spans of every occurrence of each single-valued flag, left to right.
    ---@type table<string, {start:integer, finish:integer, typed:string}[]>
    local occurrences                  = {}
    ---@type ezpick.queryflags.Piece?
    local last_flag                    = nil

    -- The separator carries nothing of its own: its whole effect is on where
    -- `_scan` stopped, and the query starts past it either way.
    for _, piece in ipairs(pieces) do
        if piece.kind == "flag" then
            last_flag = piece
            -- A value flag's value is a piece of its own; only switches are
            -- carried by the name itself -- and only when written as one. An
            -- assignment to a switch is a mistake either way round (see the
            -- "unexpected-value" hint), so it turns nothing on: reading
            -- "--fixed=false" as fixed would be the opposite of what it says.
            if defs[_key(piece.name)].type == "boolean" and not piece.eq then
                flags[piece.name] = true
            end
        elseif piece.kind == "value" then
            local def   = defs[_key(piece.name)]
            local value = piece.text
            -- A value is only ever pushed right behind the flag it feeds.
            local flag  = assert(last_flag)

            -- A value written out is a value meant, even an empty one: "--repl="
            -- is how an empty replacement is asked for.
            if def.strict then
                local values = assert(def.values)
                if not vim.tbl_contains(values, value) then
                    -- Whether a prefix of a valid choice is a wrong value or an
                    -- unfinished one is the cursor's answer to give, not ours.
                    -- An empty value has no span of its own to point at
                    -- ("--case="), so the mark falls back to the flag that went
                    -- without one.
                    local spanned = piece.finish >= piece.start
                    hints[#hints + 1] = {
                        kind   = "bad-value",
                        start  = (spanned and piece.start or flag.start) - 1,
                        finish = spanned and piece.finish or flag.finish,
                        msg    = ("%s%s: %s"):format(_PREFIX, piece.typed, table.concat(values, "|")),
                    }
                end
            end

            if def.multi then
                flags[piece.name] = flags[piece.name] or {}
                table.insert(flags[piece.name], value)
            else
                -- Only the last value of a repeated flag survives, and the ones
                -- it displaces leave no mark on the line: every occurrence still
                -- reads as an accepted flag. Note where they are, to say so once
                -- the winner is known.
                local spans = occurrences[piece.name] or {}
                spans[#spans + 1] = {
                    start  = flag.start - 1,
                    finish = flag.eq and (flag.eq - 1) or flag.finish,
                    typed  = assert(flag.typed),
                }
                occurrences[piece.name] = spans
                flags[piece.name] = value
            end
        end
    end

    -- Every occurrence is marked, so the repetition is visible as a whole, and
    -- all of them carry the message: only the leftmost is ever given words, and
    -- which one that is depends on what else the line has to say.
    for name, spans in pairs(occurrences) do
        if #spans > 1 then
            for _, span in ipairs(spans) do
                hints[#hints + 1] = {
                    kind   = "duplicate-flag",
                    start  = span.start,
                    finish = span.finish,
                    -- Each mark speaks for the spelling it sits on: two aliases
                    -- of one flag are one repetition, told twice in two names.
                    msg    = ("%s%s set %d times, using '%s'"):format(_PREFIX, span.typed, #spans, flags[name]),
                }
            end
        end
    end

    table.sort(hints, function(a, b) return a.start < b.start end)

    return {
        query       = raw:sub(query_start),
        query_start = query_start,
        flags       = flags,
        hints       = hints,
    }
end

---@param schema ezpick.queryflags.FlagDef[]
---@param raw    string
---@return {start:integer, finish:integer, hl:string}[]
function M.highlight(schema, raw)
    local defs        = _build_map(schema)
    local hls         = {}
    local pieces      = _scan(raw, defs)

    for _, piece in ipairs(pieces) do
        local s0 = piece.start - 1
        local e0 = piece.finish

        if piece.kind == "separator" then
            table.insert(hls, { start = s0, finish = e0, hl = "@tag.delimiter" })
        elseif piece.kind == "flag" then
            -- `finish` spans a glued value too; the name alone is the keyword.
            local name_end = piece.eq and (piece.eq - 1) or piece.finish
            table.insert(hls, { start = s0, finish = name_end, hl = "@keyword" })
            if piece.eq then
                table.insert(hls, { start = piece.eq - 1, finish = piece.eq, hl = "@tag.delimiter" })
            end
        elseif e0 > s0 then
            table.insert(hls, { start = s0, finish = e0, hl = "@string" })
        end

        -- An escaping '\' is syntax, use a special highlight. A '\' that escapes
        -- nothing is content and keeps the value's own: the difference, visible.
        for _, pos in ipairs(piece.escapes or {}) do
            table.insert(hls, { start = pos - 1, finish = pos, hl = "NonText" })
        end
    end

    -- The query is plain by construction: nothing past `query_start` is styled,
    -- so a flag name typed there visibly reads as the ordinary word it became.
    return hls
end

---Candidates for the value of `def`, as completion items replacing the whole
---value token. The inserted word is escaped so it re-parses as the candidate it
---names; the menu shows the plain text. Escaping is what the typed value uses
---too, so an escaped candidate still shares the typed prefix and Vim's live pum
---filter keeps it.
---@param def     ezpick.queryflags.FlagDef
---@param partial string  -- value text typed so far, unescaped
---@return table[]
local function _value_items(def, partial)
    local items = {}

    local function add(v)
        table.insert(items, { word = (v:gsub("[\\%s]", "\\%0")), abbr = v })
    end

    for _, v in ipairs(def.values or {}) do
        if vim.startswith(v, partial) then add(v) end
    end

    if def.complete then
        local cands
        if type(def.complete) == "function" then
            cands = def.complete(partial)
        else
            -- getcompletion already filters by `partial`; trust its output.
            local ok, res = pcall(vim.fn.getcompletion, partial, def.complete)
            cands = ok and res or nil
        end
        for _, v in ipairs(cands or {}) do add(v) end
    end

    return items
end

---@param def ezpick.queryflags.FlagDef
---@return string  -- "" for a switch, else " <...>" with its leading space
local function _slot(def)
    if def.type == "boolean" then return "" end
    local slot = "value"
    return (" <%s>"):format(slot)
end

---Flag names matching the word typed so far.
---@param schema       ezpick.queryflags.FlagDef[]
---@param current_word string
---@return table[]
local function _flag_items(schema, current_word)
    local items = {}

    -- The separator is not offered. It matters only for a query that has to
    -- start with a flag name, and anyone in that corner can type the two
    -- characters; everyone else would just be reading a cryptic entry sitting
    -- among the flags they actually want.
    for _, def in ipairs(schema) do
        -- The dashes are part of the flag's written form, so the menu shows
        -- them: what is listed is what accepting the item inserts, plus the
        -- slot it wants filled next.
        local word = _PREFIX .. def.name
        if vim.startswith(_key(word), _key(current_word)) then
            table.insert(items, {
                word = word,
                -- The slot goes in `abbr`, glued to the name by a single space:
                -- `kind` is a column of its own and would be padded out to the
                -- widest entry, leaving a gap where the value is meant to sit.
                abbr = word .. _slot(def),
                menu = def.desc or "",
            })
        end
    end

    return items
end

---@param schema      ezpick.queryflags.FlagDef[]
---@param line        string
---@param cursor_byte integer  -- 0-indexed byte offset from nvim_win_get_cursor
---@param auto        boolean? -- when true, only complete inside an in-progress flag (a dashed word or a value)
---@return ezpick.queryflags.Completions?
function M.get_completions(schema, line, cursor_byte, auto)
    local char_after = line:sub(cursor_byte + 1, cursor_byte + 1)
    if char_after ~= "" and not char_after:match("%s") then return nil end

    local defs                            = _build_map(schema)
    local before                          = line:sub(1, cursor_byte)
    local pieces, query_start, _, pending = _scan(before, defs)
    local last                            = pieces[#pieces]

    -- Case 1: on the value of a value flag -- either typing it, or sitting in
    -- the empty slot right after the flag's name. A value is all that can be
    -- written here, so nothing else is offered.
    local value_def, partial, value_start
    if last and last.kind == "value" and last.finish == #before then
        -- The whole token is replaced, backslashes and all. A trailing one is a
        -- literal backslash by the parse, but under the cursor it is as likely
        -- the '\' of a "\ " being typed, and matching candidates against it
        -- would empty the menu for a keystroke; it is dropped from the partial
        -- rather than searched for.
        value_def   = defs[_key(last.name)]
        partial     = (assert(last.text):gsub("\\$", ""))
        value_start = last.start
    elseif pending then
        value_def, partial, value_start = pending, "", #before + 1
    end

    if value_def then
        if not (value_def.values or value_def.complete) then return nil end
        local items = _value_items(value_def, partial)
        return #items > 0 and { startcol = value_start, items = items } or nil
    end

    -- Case 2: a flag name. Only the word the flags could still extend to is
    -- completable -- once the query has started, a dashed word in it is text and
    -- completing it would offer a flag that could not take effect there.
    local word_start = assert(tonumber(before:match("()%S*$")))
    if query_start < word_start then return nil end

    local current_word = before:sub(word_start)
    -- Past a settled separator every character is literal. One right under the
    -- cursor is still being typed: it is as much the start of "--flag" as it is
    -- the separator, so keep completing.
    if last and last.kind == "separator" and last.finish ~= #before then return nil end

    -- A bare word could be query text, so only offer names once the leading dash
    -- makes the intent explicit, or on an explicit (non-auto) trigger.
    if auto and current_word:sub(1, 1) ~= "-" then return nil end

    local items = _flag_items(schema, current_word)
    return #items > 0 and { startcol = word_start, items = items } or nil
end

return M
