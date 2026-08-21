local M = {}

---A value flag's completion source: a `vim.fn.getcompletion()` type (e.g.
---"file", "dir", "buffer") or a function returning candidates for the partial.
---@alias ezpick.queryflags.CompleteSpec string|fun(partial:string):string[]

---@class ezpick.queryflags.FlagDef
---@field name     string
---@field type     "boolean"|"value"
---@field multi    boolean?   -- value is a comma-separated list (type=value only)
---@field strict   boolean?   -- `values` is the complete set; anything else is hinted (type=value only, requires `values`)
---@field values   string[]?  -- known static values offered in completion (type=value only)
---@field complete ezpick.queryflags.CompleteSpec?  -- dynamic value completion source (type=value only)
---@field alias    string[]?  -- extra names accepted for this flag
---@field slot     string?    -- short word for what the value stands for, shown as "--name <slot>"
---@field desc     string?    -- shown in the completion menu, beside the form the flag takes

---A mistake in the line. `parse` still returns a best-effort query beside its
---hints, but a hinted line has no single reading and the picker does not search
---it. `parse` reports the half-written states a correct flag passes through too;
---telling those apart takes the cursor, which the consumer holds -- see `settled`.
---@class ezpick.queryflags.Hint
---@field start   integer  -- 0-indexed byte start of the offending span
---@field finish  integer  -- 0-indexed byte end of the offending span (exclusive)
---@field msg     string   -- terse; it shares the prompt line with the query
---@field settled boolean? -- typing on cannot resolve this one, so show it even
---                        -- while the cursor is still inside the span

---@class ezpick.queryflags.ParseResult
---@field query       string  -- the query, verbatim: every byte from where the flags stop
---@field query_start integer -- 1-indexed byte offset where `query` begins (#raw+1 when empty)
---@field flags       table   -- {[name] = true | string | string[]}
---@field hints       ezpick.queryflags.Hint[]

---@class ezpick.queryflags.Completions
---@field startcol integer  -- 1-indexed column for vim.fn.complete()
---@field items    table[]

---Marks a flag ("--name"); alone it is the separator ending the flagged section.
local _PREFIX = "--"

-- Syntax (README has the full account):
--
--   [--flag] [--flag value] [--flag=value] ... [--] <query, verbatim>
--
-- Flags come first; the query is every byte from the first token that names no
-- flag, so a picker that greps for what was typed gets exactly that. Names
-- ignore case, '-' and '_'. A flag is written at most once, a `multi` one
-- taking its several values comma-separated in the one token.
--
--   '--hidden --dir src foo  bar'  → flags hidden, dir=src; query 'foo  bar'
--   'foo --hidden'                 → query 'foo --hidden', flag unset
--   '--kind a,b\,c'                → kind = {'a', 'b,c'}
--   '-- --hidden'                  → query '--hidden'
--
---@class ezpick.queryflags.Piece
---@field kind     "flag"|"value"|"separator"
---@field start    integer     -- 1-indexed start in source
---@field finish   integer     -- 1-indexed finish in source (inclusive)
---@field name     string?     -- canonical flag this piece names (kind="flag") or feeds (kind="value")
---@field typed    string?     -- how that flag was actually spelled here, which `name` may only be a synonym of
---@field text     string?     -- decoded value, escapes resolved (kind="value")
---@field parts    string[]?   -- `text` cut at its unescaped commas; one entry when it has none (kind="value")
---@field seps     integer[]?  -- 1-indexed position of each comma that cut `parts`
---@field eq       integer?    -- 1-indexed position of the '=' gluing a value on (kind="flag")
---@field escapes  integer[]?  -- 1-indexed position of each '\' that escaped a character

---Lookup key for a flag name: case and the word separators '-' and '_' carry no
---meaning, so --noignore and --no-ignore are one flag.
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
        -- Strictness is enforced against `values`, so a strict flag listing none
        -- would quietly accept everything: a schema mistake, said on first render.
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

local _BSLASH = 92 -- '\'
local _COMMA  = 44 -- ','

---Whether `b` is what `%s` matches. Nil (past the end of the line) is not
---whitespace, which is what makes a trailing '\' content.
---@param b integer?
---@return boolean
local function _is_space(b)
    return b == 32 or (b ~= nil and b >= 9 and b <= 13)
end

---Read a value starting at `i`: a whitespace-delimited run in which '\' escapes
---a following '\', whitespace or comma (`:h <f-args>`, plus the list separator),
---cut into `parts` at its unescaped commas. Read in runs between those three
---bytes; an ordinary character is never handled on its own.
---@param str string
---@param i   integer
---@return ezpick.queryflags.Piece piece, integer next_i
local function _read_value(str, i)
    local len       = #str
    local tok_start = i
    local escapes   = {}
    local parts     = {}
    local chunks    = {} -- the current part, in runs
    local plain     = i  -- start of the ordinary run not yet taken

    ---@type integer[]
    local seps      = {}

    while true do
        local j = str:find("[%s\\,]", i)
        if not j then
            i = len + 1
            break
        end

        local b = str:byte(j)
        if b == _BSLASH then
            local after = str:byte(j + 1)
            if after == _BSLASH or after == _COMMA or _is_space(after) then
                if j > plain then chunks[#chunks + 1] = str:sub(plain, j - 1) end
                escapes[#escapes + 1] = j
                chunks[#chunks + 1]   = str:sub(j + 1, j + 1)
                i, plain              = j + 2, j + 2
            else
                -- A '\' with nothing escapable behind it, the end of the line
                -- included, is content: the run carries on over it.
                i = j + 1
            end
        elseif b == _COMMA then
            if j > plain then chunks[#chunks + 1] = str:sub(plain, j - 1) end
            seps[#seps + 1]   = j
            parts[#parts + 1] = table.concat(chunks)
            chunks            = {}
            i, plain          = j + 1, j + 1
        else
            i = j -- whitespace ends the value
            break
        end
    end

    if i > plain then chunks[#chunks + 1] = str:sub(plain, i - 1) end
    parts[#parts + 1] = table.concat(chunks)

    return {
        kind    = "value",
        start   = tok_start,
        finish  = i - 1,
        -- Rejoining the parts rebuilds the value: an escaped comma is already
        -- inside the part holding it, so only the separators go back.
        text    = table.concat(parts, ","),
        parts   = parts,
        seps    = #seps > 0 and seps or nil,
        escapes = #escapes > 0 and escapes or nil,
    }, i
end

---The parts of a value piece with the span each was written in, so a hint or a
---completion can point at one of several values rather than at all of them.
---@param piece ezpick.queryflags.Piece
---@return {text:string, start:integer, finish:integer}[]
local function _spanned_parts(piece)
    local parts = assert(piece.parts)
    local seps  = piece.seps or {}
    local out   = {}

    for k, text in ipairs(parts) do
        out[k] = {
            text   = text,
            start  = k == 1 and piece.start or (seps[k - 1] + 1),
            finish = seps[k] and (seps[k] - 1) or piece.finish,
        }
    end

    return out
end

---Mark the word that ended the flags when a bare "--" is written after it. Only
---flags stand in front of the separator, so the word that named none of them is
---where the mistake is, not the "--" it stranded: the mark points at what has to
---change, and one mark does for however many "--" follow.
---@param str  string
---@param from integer -- 1-indexed start of the query
---@param hint fun(s:integer, e:integer, msg:string, settled:boolean?)
local function _hint_late_separators(str, from, hint)
    -- The query starts on a non-space, and never on a bare "--": `_scan` takes
    -- that as the separator itself.
    local word_s, word_e = str:find("%S+", from)
    if not word_s then return end

    local i = word_e + 1
    while i <= #str do
        local s, e = str:find("%S+", i)
        if not s then break end
        if str:sub(s, e) == _PREFIX then
            hint(word_s, word_e, ("invalid flag before %s"):format(_PREFIX), true)
            return
        end
        i = e + 1
    end
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

    ---@param s       integer  -- 1-indexed inclusive
    ---@param e       integer  -- 1-indexed inclusive
    ---@param msg     string
    ---@param settled boolean? -- see `Hint.settled`
    local function hint(s, e, msg, settled)
        hints[#hints + 1] = { start = s - 1, finish = e, msg = msg, settled = settled or nil }
    end

    ---Echoes the spelling on the line, not the canonical name: the mark and the
    ---words have to describe one thing, and an alias hides the canonical one.
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
            -- Not a flag, so the query begins here. Whether a dashed word is a
            -- typo or a prefix still being typed is the cursor's to answer.
            if name then
                assert(name_end)
                hint(tok_start, name_end, ("unknown option %s%s"):format(_PREFIX, name))
            end
            _hint_late_separators(str, tok_start, hint)
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
                -- A switch is written by being there: "--fixed=false" and
                -- "--fixed=true" are the same mistake, and neither is acted on.
                hint(tok_start, value.finish,
                    ("%s%s takes no value"):format(_PREFIX, name), true)
            else
                pieces[#pieces + 1] = value
            end
        elseif def.type == "value" then
            local j = i
            while j <= len and str:sub(j, j):match("%s") do j = j + 1 end
            local next_name = _dashed_name(str, j)
            local next_sep  = str:sub(j, j + 1) == _PREFIX and (j + 2 > len or str:sub(j + 2, j + 2):match("%s"))
            if j > len then
                -- An open slot, prompting for what goes there -- but only once
                -- something separates it from the name: "--mode" with the cursor
                -- on it is a name still being typed, perhaps into "--modes".
                if i <= len then pending = def end
                hint(tok_start, name_end, needs_value(def, name))
            elseif next_sep or (next_name and defs[_key(next_name)]) then
                -- Something already stands where the value would go, so typing
                -- on can never fill the slot: settled, and said at once.
                hint(tok_start, name_end, needs_value(def, name), true)
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
    ---Name spans of every occurrence of each value flag, left to right.
    ---@type table<string, {start:integer, finish:integer, typed:string}[]>
    local occurrences                  = {}
    ---@type ezpick.queryflags.Piece?
    local last_flag                    = nil

    -- The separator carries nothing of its own: its effect was on where `_scan`
    -- stopped.
    for _, piece in ipairs(pieces) do
        if piece.kind == "flag" then
            last_flag = piece
            -- Only a switch is carried by its name, and only written as one: an
            -- assignment to it is a mistake either way round, so it turns
            -- nothing on (see the "unexpected-value" hint).
            if defs[_key(piece.name)].type == "boolean" and not piece.eq then
                flags[piece.name] = true
            end
        elseif piece.kind == "value" then
            local def   = defs[_key(piece.name)]
            local value = piece.text
            -- A value is only ever pushed right behind the flag it feeds.
            local flag  = assert(last_flag)

            -- A value written out is a value meant, even an empty one.
            if def.strict then
                local values = assert(def.values)
                -- Each value of a list stands or falls on its own.
                local spans = def.multi and _spanned_parts(piece)
                    or { { text = value, start = piece.start, finish = piece.finish } }
                for _, span in ipairs(spans) do
                    if not vim.tbl_contains(values, span.text) then
                        -- An empty value has no span to point at ("--case="), so
                        -- the mark falls back to the flag that went without one.
                        local spanned = span.finish >= span.start
                        hints[#hints + 1] = {
                            start  = (spanned and span.start or flag.start) - 1,
                            finish = spanned and span.finish or flag.finish,
                            msg    = ("%s%s: %s"):format(_PREFIX, piece.typed, table.concat(values, "|")),
                        }
                    end
                end
            end

            -- Only the last value of a repeated flag survives, `multi` included,
            -- and the ones it displaces leave no mark on the line. Note where
            -- they are, to say so once the winner is known.
            local spans = occurrences[piece.name] or {}
            spans[#spans + 1] = {
                start  = flag.start - 1,
                finish = flag.eq and (flag.eq - 1) or flag.finish,
                typed  = assert(flag.typed),
            }
            occurrences[piece.name] = spans
            flags[piece.name] = def.multi and assert(piece.parts) or value
        end
    end

    -- Every occurrence is marked, so the repetition is visible as a whole, and
    -- all of them carry the message.
    for _, spans in pairs(occurrences) do
        if #spans > 1 then
            for _, span in ipairs(spans) do
                hints[#hints + 1] = {
                    start   = span.start,
                    finish  = span.finish,
                    -- A repetition already written: the flag ahead of it is not
                    -- going to be unwritten by typing on.
                    settled = true,
                    -- Each mark speaks for the spelling it sits on: two aliases
                    -- of one flag are one repetition, told twice in two names.
                    msg     = ("%s%s set %d times"):format(_PREFIX, span.typed, #spans),
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
            -- A comma only separates where the flag takes a list.
            if defs[_key(piece.name)].multi then
                for _, pos in ipairs(piece.seps or {}) do
                    table.insert(hls, { start = pos - 1, finish = pos, hl = "@tag.delimiter" })
                end
            end
        end

        -- An escaping '\' is syntax; one that escapes nothing is content and
        -- keeps the value's own highlight. The difference, visible.
        for _, pos in ipairs(piece.escapes or {}) do
            table.insert(hls, { start = pos - 1, finish = pos, hl = "NonText" })
        end
    end

    -- Nothing past `query_start` is styled, so a flag name typed there reads as
    -- the ordinary word it became.
    return hls
end

---Candidates for the value of `def`, as items replacing the whole value token.
---The inserted word is escaped so it re-parses as the candidate it names, which
---is also how the typed value is written, so the live pum filter keeps it.
---@param def     ezpick.queryflags.FlagDef
---@param partial string  -- value text typed so far, unescaped
---@return table[]
local function _value_items(def, partial)
    local items = {}

    -- A comma is syntax only in a list. Escaping it elsewhere would put a
    -- backslash in the word that the typed text has not got, and the pum filter
    -- would drop the item on the next keystroke.
    local pat = def.multi and "[\\,%s]" or "[\\%s]"

    local function add(v)
        table.insert(items, { word = (v:gsub(pat, "\\%0")), abbr = v })
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
    -- Without a name of its own the slot only says that something goes here; a
    -- list says so too, this being the only place the comma form is visible.
    if def.type == "boolean" then return "" end
    return (" <%s%s>"):format(def.slot or "value", def.multi and ",..." or "")
end

---Flag names matching the word typed so far.
---@param schema       ezpick.queryflags.FlagDef[]
---@param current_word string
---@return table[]
local function _flag_items(schema, current_word)
    local items = {}

    -- The separator is not offered: it matters only for a query that has to
    -- start with a flag name, and typing it is two characters.
    for _, def in ipairs(schema) do
        -- What is listed is what accepting the item inserts, plus the slot it
        -- wants filled next.
        local word = _PREFIX .. def.name
        if vim.startswith(_key(word), _key(current_word)) then
            table.insert(items, {
                word = word,
                -- The slot goes in `abbr`, not `kind`: a column of its own would
                -- be padded out, leaving a gap where the value is meant to sit.
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

    -- Case 1: on the value of a value flag, typing it or sitting in the empty
    -- slot after the name. A value is all that can be written here.
    local value_def, partial, value_start
    if last and last.kind == "value" and last.finish == #before then
        -- A trailing '\' parses as a literal backslash, but under the cursor it
        -- is as likely half of a "\ " being typed: it is dropped from the
        -- partial rather than searched for.
        value_def = defs[_key(last.name)]
        local text, start = assert(last.text), last.start
        if value_def.multi then
            -- Only the value being written is completed.
            local parts = _spanned_parts(last)
            text, start = parts[#parts].text, parts[#parts].start
        end
        partial     = (text:gsub("\\$", ""))
        value_start = start
    elseif pending then
        value_def, partial, value_start = pending, "", #before + 1
    end

    if value_def then
        if not (value_def.values or value_def.complete) then return nil end
        local items = _value_items(value_def, partial)
        return #items > 0 and { startcol = value_start, items = items } or nil
    end

    -- Case 2: a flag name. Once the query has started a dashed word in it is
    -- text, and completing it would offer a flag that could not take effect.
    local word_start = assert(tonumber(before:match("()%S*$")))
    if query_start < word_start then return nil end

    local current_word = before:sub(word_start)
    -- Past a settled separator every character is literal; one under the cursor
    -- is as much the start of "--flag" as it is the separator.
    if last and last.kind == "separator" and last.finish ~= #before then return nil end

    -- A bare word could be query text, so names are offered only once a leading
    -- dash makes the intent explicit, or on an explicit (non-auto) trigger.
    if auto and current_word:sub(1, 1) ~= "-" then return nil end

    local items = _flag_items(schema, current_word)
    return #items > 0 and { startcol = word_start, items = items } or nil
end

return M
