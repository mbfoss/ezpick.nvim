local M = {}

---A source for a value flag's completion candidates: either a
---`vim.fn.getcompletion()` type (e.g. "file", "dir", "buffer", "color"), or a
---function returning candidates for the partial value typed so far.
---@alias ezpick.queryflags.CompleteSpec string|fun(partial:string):string[]

---@class ezpick.queryflags.FlagDef
---@field name     string
---@field type     "boolean"|"value"
---@field multi    boolean?   -- allow multiple occurrences (type=value only)
---@field allow_empty boolean? -- keep an empty value instead of dropping the flag (type=value only)
---@field values   string[]?  -- known static values offered in completion (type=value only)
---@field complete ezpick.queryflags.CompleteSpec?  -- dynamic value completion source (type=value only)
---@field desc     string?    -- shown in the completion menu

---@class ezpick.queryflags.ParseResult
---@field query string  -- the literal query (all non-flag tokens joined by space, followed by the raw text after "--")
---@field flags table   -- {[name] = true | string | string[]}
---@field error string? -- set when the query is malformed (e.g. an unclosed quote)

---@class ezpick.queryflags.Completions
---@field startcol integer  -- 1-indexed column for vim.fn.complete()
---@field items    table[]

---Marks a flag ("--name"); alone it is the separator that ends the flagged
---section, after which everything is literal text.
local _PREFIX = "--"

---`vim.fn.getcompletion()` types whose candidates are path fragments: a
---completed value is often only a prefix of what the user is after, so its
---quote is left open for further typing.
---@type table<string, boolean>
local _PATH_COMPLETE = {
    dir = true,
    dir_in_path = true,
    file = true,
    file_in_path = true,
    runtime = true,
    shellcmdline = true,
}

---@param schema ezpick.queryflags.FlagDef[]
---@return table<string, ezpick.queryflags.FlagDef>
local function _build_map(schema)
    local m = {}
    for _, def in ipairs(schema) do m[def.name] = def end
    return m
end

-- Syntax:
--
--   <token> <token> ... [-- <literal text>]
--
-- Up to the optional "--" separator the input is a flat list of
-- whitespace-separated tokens; flags and query text may appear in any order.
-- Each token is classified:
--   boolean flag:  "--flagname"      → flags.flagname = true  (matching a boolean def)
--   value flag:    "--key value"     → flags.key = value      (or string[] if multi)
--   anything else: query text
-- The query is every non-flag token joined back together with single spaces,
-- in the order written, followed by the raw text after the separator.
-- "--name" is a flag only when `name` is in the schema; an unknown one is
-- ordinary query text, as is a bare "name" without the dashes.
--
-- A value flag takes the *next* token as its value, whatever that token looks
-- like ("--dir --nope" → dir = "--nope"); only the "--" separator is never
-- taken as a value. A value flag with no token after it stays unset.
--
-- Quoting (via ") only applies to a value flag's value, and only when the
-- opening quote is the first character of the token in value position. It lets
-- the value contain spaces:
--   '--path "foo bar"' → value flag whose value contains a space
--   'nope "foo bar"'   → query text 'nope', '"foo' and 'bar"' (no such flag)
-- A '"' anywhere else -- in query text, or in the middle of a value -- is an
-- ordinary literal character. Inside a quoted value a literal double quote is
-- written as \". Text after the closing quote simply continues the value
-- ('--path "foo bar"baz' → value "foo barbaz"), but an unterminated quote is
-- an error.
--
-- There is no escape character. A flag-looking string is searched for verbatim
-- by writing it after the "--" separator: a standalone "--" token ends the
-- flagged section, and the rest of the line is literal query text -- no
-- tokenizing, no flags, no quoting, whitespace kept as typed:
--   '--fixed -- --fixed'   → flag fixed, query text "--fixed"
--   'foo -- --path a  "b"' → query text 'foo --path a  "b"'
-- Only the first standalone "--" separates; one inside a quoted value
-- ('--path "a -- b"') or glued to other text ("--x") is ordinary content. The
-- whitespace between the separator and the literal text is not part of it.

---@class ezpick.queryflags.Token
---@field text    string                         -- token text, with the value quote chars stripped
---@field raw     string                         -- verbatim slice of source
---@field start   integer                        -- 1-indexed start in source
---@field finish  integer                        -- 1-indexed finish in source (inclusive)
---@field kind    "flag"|"value"|"text"          -- how the token was classified
---@field name    string?                        -- the flag this token names (kind="flag") or feeds (kind="value")
---@field quote   {open:integer,close:integer?}? -- raw-relative 1-indexed positions of the value quote chars; close=nil when unterminated
---@field escapes integer[]?                     -- raw-relative 1-indexed positions of each escaping '\' (the '\' of a \" inside a quoted value)

---Scan up to the first standalone "--": the tokens before it carry the flags,
---everything after it is literal text taken verbatim. A "--" that is part of a
---quoted value or glued to other characters is not a separator.
---
---Classification is done here because it is stateful: only the token right
---after a value flag's name is a value, and only there may a quote open.
---@param str  string
---@param defs table<string, ezpick.queryflags.FlagDef>
---@return ezpick.queryflags.Token[] tokens, {start:integer,finish:integer}? separator, string? literal
local function _scan(str, defs)
    local tokens = {}
    local i      = 1
    local len    = #str
    local wanted = nil -- name of the value flag whose value the next token is

    while i <= len do
        while i <= len and str:sub(i, i):match("%s") do i = i + 1 end
        if i > len then break end

        local tok_start = i
        local chars     = {}
        ---@type {open:integer, close:integer?}?
        local quote     = nil   -- the value quote span once one has opened
        local quote_idx = nil   -- index in `chars` where the value quote opened
        local in_quote  = false -- inside the value quote span
        local escapes   = {}    -- raw-relative 1-indexed positions of each escaping '\'

        while i <= len do
            local c = str:sub(i, i)
            if in_quote then
                -- inside the value quote: whitespace is literal, the delimiting
                -- quote char is stripped from `text` but remains in `raw`, and
                -- \" is a literal double quote that does not close the span.
                if c == "\\" and str:sub(i + 1, i + 1) == '"' then
                    table.insert(escapes, i - tok_start + 1)
                    table.insert(chars, '"')
                    i = i + 2
                elseif c == '"' then
                    quote.close = i - tok_start + 1
                    in_quote    = false
                    i           = i + 1
                else
                    table.insert(chars, c)
                    i = i + 1
                end
            elseif c:match("%s") then
                break
            elseif c == '"' and wanted and not quote and i == tok_start then
                -- a quote opening a token in value position delimits that value;
                -- every other quote is an ordinary literal character.
                quote     = { open = 1 }
                quote_idx = 1
                in_quote  = true
                i         = i + 1
            else
                table.insert(chars, c)
                i = i + 1
            end
        end

        -- An unterminated quote is not a real delimiter: keep it as a literal
        -- char instead of silently swallowing it.
        if in_quote and quote_idx then table.insert(chars, quote_idx, '"') end

        local raw = str:sub(tok_start, i - 1)
        -- The separator wins over everything, including a pending value: it is
        -- the one token a value flag never swallows.
        if raw == _PREFIX then
            local literal = (str:sub(i):gsub("^%s+", ""))
            return tokens, { start = tok_start, finish = i - 1 }, literal
        end

        local text = table.concat(chars)
        local kind, name
        if wanted then
            kind, name, wanted = "value", wanted, nil
        else
            local flag = #text > #_PREFIX and text:sub(1, #_PREFIX) == _PREFIX
                and defs[text:sub(#_PREFIX + 1)]
            if flag then
                kind, name = "flag", flag.name
                if flag.type == "value" then wanted = flag.name end
            else
                kind = "text"
            end
        end

        tokens[#tokens + 1] = {
            text    = text,
            raw     = raw,
            start   = tok_start,
            finish  = i - 1,
            kind    = kind,
            name    = name,
            quote   = quote,
            escapes = #escapes > 0 and escapes or nil,
        }
    end

    return tokens, nil, nil
end

---@param schema ezpick.queryflags.FlagDef[]
---@param raw    string
---@return ezpick.queryflags.ParseResult
function M.parse(schema, raw)
    local defs               = _build_map(schema)
    local flags              = {}
    local tokens, _, literal = _scan(raw, defs)
    local parts              = {}

    for _, token in ipairs(tokens) do
        if token.quote and not token.quote.close then
            return { query = "", flags = {}, error = "Unclosed quote" }
        end
    end

    for _, token in ipairs(tokens) do
        if token.kind == "value" then
            local def   = defs[token.name]
            local value = token.text
            if value ~= "" or def.allow_empty then
                if def.multi then
                    flags[token.name] = flags[token.name] or {}
                    table.insert(flags[token.name], value)
                else
                    flags[token.name] = value
                end
            end
        elseif token.kind == "flag" then
            -- A value flag's value lives in the next token; only booleans are
            -- carried by the name token itself.
            if defs[token.name].type == "boolean" then flags[token.name] = true end
        elseif token.text ~= "" then
            parts[#parts + 1] = token.text
        end
    end

    -- Text after the separator is verbatim: it joins the query as a single
    -- trailing chunk, keeping its own spacing.
    if literal and literal ~= "" then parts[#parts + 1] = literal end

    return { query = table.concat(parts, " "), flags = flags }
end

---@param schema ezpick.queryflags.FlagDef[]
---@param raw    string
---@return {start:integer, finish:integer, hl:string}[]
function M.highlight(schema, raw)
    local defs                 = _build_map(schema)
    local hls                  = {}
    local tokens, separator, _ = _scan(raw, defs)

    for _, token in ipairs(tokens) do
        local s0 = token.start - 1
        local e0 = token.finish

        if token.kind == "flag" then
            table.insert(hls, { start = s0, finish = e0, hl = "Keyword" })
        elseif token.kind == "value" and e0 > s0 then
            table.insert(hls, { start = s0, finish = e0, hl = "String" })
        end

        -- The quote chars delimiting a value (--path "foo bar") are syntax:
        -- highlight them as such. An unterminated quote still highlights its
        -- opening char so the open span is visible. Inserted last so they win
        -- over String/Keyword.
        local q = token.quote
        if q then
            table.insert(hls, { start = s0 + q.open - 1, finish = s0 + q.open, hl = "Delimiter" })
            if q.close then
                table.insert(hls, { start = s0 + q.close - 1, finish = s0 + q.close, hl = "Delimiter" })
            end
        end

        -- The '\' of an escaped quote (\") is syntax, not content: dim it so the
        -- quote it protects still reads as a literal character.
        if token.escapes then
            for _, pos in ipairs(token.escapes) do
                table.insert(hls, { start = s0 + pos - 1, finish = s0 + pos, hl = "NonText" })
            end
        end
    end

    -- The separator is syntax; what follows it is literal text and stays plain,
    -- so a flag-looking word there visibly reads as an ordinary query word.
    if separator then
        table.insert(hls, {
            start  = separator.start - 1,
            finish = separator.finish,
            hl     = "Delimiter",
        })
    end

    return hls
end

---Candidates for the value of `def`, as completion items replacing the whole
---value token. A value is quoted when it contains a space, or when the cursor
---already sits inside an open quote -- otherwise the unquoted candidates would
---not share the typed `"` prefix and Vim's live pum filter would drop them all.
---@param def      ezpick.queryflags.FlagDef
---@param partial  string  -- value text typed so far, unquoted and unescaped
---@param in_quote boolean -- the cursor sits inside an unterminated value quote
---@return table[]
local function _value_items(def, partial, in_quote)
    local items = {}

    -- `open_ended` candidates (paths) keep the quote open so the value can be
    -- extended -- completing a directory is usually a step towards a deeper
    -- path, and a closing quote would sit in the way.
    local function add(v, open_ended)
        local word = (in_quote or v:find('[%s"]'))
            and ('"' .. v:gsub('"', '\\"') .. (open_ended and "" or '"'))
            or v
        table.insert(items, { word = word, abbr = v })
    end

    for _, v in ipairs(def.values or {}) do
        if vim.startswith(v, partial) then add(v) end
    end

    if def.complete then
        local cands, open_ended
        if type(def.complete) == "function" then
            cands = def.complete(partial)
        else
            open_ended = _PATH_COMPLETE[def.complete] or false
            -- getcompletion already filters by `partial`; trust its output.
            local ok, res = pcall(vim.fn.getcompletion, partial, def.complete)
            cands = ok and res or nil
        end
        for _, v in ipairs(cands or {}) do add(v, open_ended) end
    end

    return items
end

---The value flag a token leaves waiting for its value, if any.
---@param defs  table<string, ezpick.queryflags.FlagDef>
---@param token ezpick.queryflags.Token?
---@return ezpick.queryflags.FlagDef?
local function _pending_value(defs, token)
    if not token or token.kind ~= "flag" or not token.name then return nil end
    local def = defs[token.name]
    return def.type == "value" and def or nil
end

---Flag names -- and the separator -- matching the word typed so far.
---@param schema       ezpick.queryflags.FlagDef[]
---@param current_word string
---@return table[]
local function _flag_items(schema, current_word)
    local items = {}

    -- The separator is always on offer: everything after it is literal.
    if vim.startswith(_PREFIX, current_word) then
        table.insert(items, {
            word = _PREFIX,
            abbr = _PREFIX,
            menu = "[literal text]",
        })
    end

    for _, def in ipairs(schema) do
        -- The dashes are part of the flag's written form, so the menu shows
        -- them: what is listed is exactly what accepting the item inserts.
        local word = _PREFIX .. def.name
        if vim.startswith(word, current_word) then
            table.insert(items, {
                word = word,
                abbr = word,
                menu = def.desc or (def.type == "boolean" and "[flag]" or "[filter]"),
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

    local defs              = _build_map(schema)
    local before            = line:sub(1, cursor_byte)
    local tokens, separator = _scan(before, defs)

    if separator then
        -- A separator right under the cursor is still being typed: it is as
        -- much the start of "--flag" as it is the separator, so keep
        -- completing. Past a settled separator every character is literal.
        if separator.finish ~= #before then return nil end
        -- ... unless a value flag is waiting for its value here: offering a
        -- flag name would quietly turn the accepted name into that value.
        if _pending_value(defs, tokens[#tokens]) then return nil end
        local items = _flag_items(schema, _PREFIX)
        return #items > 0 and { startcol = separator.start, items = items } or nil
    end

    local last = tokens[#tokens]
    -- The token the cursor sits at the end of -- what a completion replaces.
    -- With none, the cursor is in fresh space after `last`.
    local word = (last and last.finish == #before) and last or nil

    -- Case 1: on the value of a value flag -- either typing it, or sitting in
    -- the empty slot right after the flag's name. A value is all that can be
    -- written here, so nothing else is offered.
    local value_def, partial, in_quote
    if word and word.kind == "value" and word.name then
        value_def = defs[word.name]
        in_quote  = word.quote ~= nil and word.quote.close == nil
        -- \" is only an escape inside a quoted value; unquoted it is literal.
        partial   = in_quote and word.text:sub(2):gsub('\\"', '"') or word.text
    elseif not word then
        value_def, partial, in_quote = _pending_value(defs, last), "", false
    end

    if value_def then
        if not (value_def.values or value_def.complete) then return nil end
        local items = _value_items(value_def, partial, in_quote)
        return #items > 0 and { startcol = word and word.start or #before + 1, items = items } or nil
    end

    -- Case 2: a flag name. A bare word could be query text, so only offer names
    -- once the leading dash makes the intent explicit, or on an explicit
    -- (non-auto) trigger.
    local current_word = word and word.text or ""
    if auto and current_word:sub(1, 1) ~= "-" then return nil end

    local items = _flag_items(schema, current_word)
    return #items > 0 and { startcol = word and word.start or #before + 1, items = items } or nil
end

return M
