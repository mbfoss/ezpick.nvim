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
---@field query string  -- the literal query (all non-flag tokens and "query:" values, joined by space)
---@field flags table   -- {[name] = true | string | string[]}
---@field error string? -- set when the query is malformed (e.g. an unclosed quote)

---@class ezpick.queryflags.Completions
---@field startcol integer  -- 1-indexed column for vim.fn.complete()
---@field items    table[]

---The implicit flag every flagged query carries: its value is appended to the
---query as literal text instead of becoming a flag. Reserved -- a schema may
---not define a flag by this name.
local _QUERY = "query"

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

---Add the implicit "query" flag to a schema. The name is reserved: a schema
---that defines it is a programming error, not a flag that shadows the literal.
---@param schema ezpick.queryflags.FlagDef[]
---@return ezpick.queryflags.FlagDef[]
local function _augment(schema)
    if #schema == 0 then return schema end
    for _, def in ipairs(schema) do
        assert(def.name ~= _QUERY, '"' .. _QUERY .. '" is a reserved flag name')
    end

    local out = vim.list_extend({}, schema)
    out[#out + 1] = {
        name  = _QUERY,
        type  = "value",
        multi = true,
        desc  = "[literal text]",
    }
    return out
end

---@param schema ezpick.queryflags.FlagDef[] -- already augmented
---@return table<string, ezpick.queryflags.FlagDef>
local function _build_map(schema)
    local m = {}
    for _, def in ipairs(schema) do m[def.name] = def end
    return m
end

-- Syntax:
--
--   <token> <token> ...
--
-- The input is a flat list of whitespace-separated tokens with no separator;
-- flags and query text may appear in any order. Each token is classified:
--   boolean flag:  "is:flagname" → flags.flagname = true  (matching a boolean def)
--   value flag:    "key:value"   → flags.key = value      (or string[] if multi)
--   anything else: query text
-- The query is every non-flag token (plus every "query:" value, see below)
-- joined back together with single spaces, in the order written.
-- Boolean flags have no standalone form — "flagname" alone is always query
-- text; the "is:" prefix is what distinguishes a flag from a query word.
--
-- Quoting (via ") only applies to a value flag's value, and only when the
-- opening quote sits directly after the ':' of a key that really is one of the
-- schema's value flags. It lets the value contain spaces:
--   'path:"foo bar"' → value flag whose value contains a space
--   'nope:"foo bar"' → query text 'nope:"foo' and 'bar"' (no such flag)
-- A '"' anywhere else -- in query text, inside a key, or in the middle of an
-- unquoted value -- is an ordinary literal character. Inside a quoted value a
-- literal double quote is written as \". Text after the closing quote simply
-- continues the value ('key:"foo bar"baz' → value "foo barbaz"), but an
-- unterminated quote is an error.
--
-- There is no escape character. A flag-looking string is searched for verbatim
-- by passing it through the implicit "query" flag -- a reserved name every
-- schema carries -- which appends its value to the query instead of setting a
-- flag:
--   'query:"is:fixed"'   → query text "is:fixed"
--   'query:"path:foo x"' → query text "path:foo x"

---@class ezpick.queryflags.Token
---@field text          string                         -- verbatim token text
---@field raw           string                         -- verbatim slice of source
---@field start         integer                        -- 1-indexed start in source
---@field finish        integer                        -- 1-indexed finish in source (inclusive)
---@field colon_pos     integer?                       -- 1-indexed position of the separating ':' in text
---@field colon_raw_pos integer?                       -- 1-indexed position of the separating ':' in raw (for buffer offsets)
---@field quote         {open:integer,close:integer?}? -- raw-relative 1-indexed positions of the value quote chars; close=nil when unterminated
---@field escapes       integer[]?                     -- raw-relative 1-indexed positions of each escaping '\' (the '\' of a \" inside a quoted value)

---Only a key that really is a value flag can quote its value; after any other
---key a '"' is an ordinary character, so query text keeps its quotes verbatim.
---@param defs table<string, ezpick.queryflags.FlagDef>
---@param key  string
---@return boolean
local function _quotable(defs, key)
    local def = defs[key]
    return def ~= nil and def.type == "value"
end

---@param str  string
---@param defs table<string, ezpick.queryflags.FlagDef> -- decides which keys may quote a value
---@return ezpick.queryflags.Token[]
local function _tokenize(str, defs)
    local tokens = {}
    local i      = 1
    local len    = #str

    while i <= len do
        while i <= len and str:sub(i, i):match("%s") do i = i + 1 end
        if i > len then break end

        local tok_start     = i
        local chars         = {}
        local colon_pos     = nil
        local colon_raw_pos = nil
        ---@type {open:integer, close:integer?}?
        local _quote        = nil   -- the value quote span once one has opened
        local _quote_idx    = nil   -- index in `chars` where the value quote opened
        local _in_quote     = false -- inside the value quote span
        local _escapes      = {}    -- raw-relative 1-indexed positions of each escaping '\'

        while i <= len do
            local c = str:sub(i, i)
            if _in_quote then
                -- inside the value quote: whitespace is literal, the delimiting
                -- quote char is stripped from `text` but remains in `raw`, and
                -- \" is a literal double quote that does not close the span.
                if c == "\\" and str:sub(i + 1, i + 1) == '"' then
                    table.insert(_escapes, i - tok_start + 1)
                    table.insert(chars, '"')
                    i = i + 2
                elseif c == '"' then
                    _quote.close = i - tok_start + 1
                    _in_quote    = false
                    i            = i + 1
                else
                    table.insert(chars, c)
                    i = i + 1
                end
            elseif c:match("%s") then
                break
            elseif c == '"' and colon_pos and not _quote
                and (i - tok_start + 1) == colon_raw_pos + 1
                and _quotable(defs, table.concat(chars, "", 1, colon_pos - 1)) then
                -- a quote directly after a known value flag's ':' opens the value
                -- span; every other quote is an ordinary literal character.
                _quote     = { open = i - tok_start + 1 }
                _quote_idx = #chars + 1
                _in_quote  = true
                i          = i + 1
            else
                if c == ":" and colon_pos == nil then
                    colon_pos     = #chars + 1
                    colon_raw_pos = i - tok_start + 1
                end
                table.insert(chars, c)
                i = i + 1
            end
        end

        -- An unterminated quote is not a real delimiter: keep it as a literal
        -- char instead of silently swallowing it.
        if _in_quote and _quote_idx then table.insert(chars, _quote_idx, '"') end

        local text = table.concat(chars)
        if text ~= "" then
            tokens[#tokens + 1] = {
                text          = text,
                raw           = str:sub(tok_start, i - 1),
                start         = tok_start,
                finish        = i - 1,
                colon_pos     = colon_pos,
                colon_raw_pos = colon_raw_pos,
                quote         = _quote,
                escapes       = #_escapes > 0 and _escapes or nil,
            }
        end
    end

    return tokens
end

-- Classify a single token against the flag schema. A value flag is "key:value" (key
-- matching a value def; the value may be quoted); a boolean flag is "is:flagname"
-- matching a boolean def. Anything else is query text.
---@param defs  table<string, ezpick.queryflags.FlagDef>
---@param token ezpick.queryflags.Token
---@return "boolean"|"value"|nil kind, string? key, string? value
local function _classify(defs, token)
    local colon = token.colon_pos
    if not colon or colon <= 1 then return nil end

    local key  = token.text:sub(1, colon - 1)
    local rest = token.text:sub(colon + 1)

    if key == "is" then
        local def = defs[rest]
        if def and def.type == "boolean" then
            return "boolean", rest, nil
        end
        return nil
    end

    local def = defs[key]
    if def and def.type == "value" then
        return "value", key, rest
    end
    return nil
end

---@param schema ezpick.queryflags.FlagDef[]
---@param raw    string
---@return ezpick.queryflags.ParseResult
function M.parse(schema, raw)
    local defs   = _build_map(_augment(schema))
    local flags  = {}
    local tokens = _tokenize(raw, defs)
    local parts  = {}

    for _, token in ipairs(tokens) do
        if token.quote and not token.quote.close then
            return { query = "", flags = {}, error = "Unclosed quote" }
        end
    end

    for _, token in ipairs(tokens) do
        local kind, key, value = _classify(defs, token)
        if kind == "value" and key == _QUERY then
            -- the implicit "query" flag carries literal text: it joins the query
            -- in the position it was written rather than becoming a flag.
            if value and value ~= "" then parts[#parts + 1] = value end
        elseif kind == "value" and key then
            local def = defs[key]
            if value and (value ~= "" or def.allow_empty) then
                if def.multi then
                    flags[key] = flags[key] or {}
                    table.insert(flags[key], value)
                else
                    flags[key] = value
                end
            end
        elseif kind == "boolean" and key then
            flags[key] = true
        elseif token.text ~= "" then
            parts[#parts + 1] = token.text
        end
    end

    return { query = table.concat(parts, " "), flags = flags }
end

---@param schema ezpick.queryflags.FlagDef[]
---@param raw    string
---@return {start:integer, finish:integer, hl:string}[]
function M.highlight(schema, raw)
    local defs   = _build_map(_augment(schema))
    local hls    = {}
    local tokens = _tokenize(raw, defs)

    for _, token in ipairs(tokens) do
        local kind, _, value = _classify(defs, token)
        local s0 = token.start - 1
        local e0 = token.finish

        if kind == "value" then
            table.insert(hls, { start = s0, finish = s0 + token.colon_raw_pos, hl = "Keyword" })
            if value and #value > 0 then
                table.insert(hls, { start = s0 + token.colon_raw_pos, finish = e0, hl = "String" })
            end
        elseif kind == "boolean" then
            table.insert(hls, { start = s0, finish = e0, hl = "Keyword" })
        end

        -- The quote chars delimiting a value (path:"foo bar") are syntax: highlight
        -- them as such. An unterminated quote still highlights its opening char so
        -- the open span is visible. Inserted last so they win over String/Keyword.
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

    return hls
end

---@param schema      ezpick.queryflags.FlagDef[]
---@param line        string
---@param cursor_byte integer  -- 0-indexed byte offset from nvim_win_get_cursor
---@param auto        boolean? -- when true, only complete inside an in-progress flag (a "key:" token)
---@return ezpick.queryflags.Completions?
function M.get_completions(schema, line, cursor_byte, auto)
    local char_after = line:sub(cursor_byte + 1, cursor_byte + 1)
    if char_after ~= "" and not char_after:match("%s") then return nil end

    local list         = _augment(schema)
    local defs         = _build_map(list)
    local before       = line:sub(1, cursor_byte)
    local tokens       = _tokenize(before, defs)

    local last         = tokens[#tokens]
    local word_start_1 = #before + 1
    local current_word = ""
    if last and last.finish == #before then
        word_start_1 = last.start
        current_word = last.text
    end

    local colon = last and last.finish == #before and last.colon_pos
    if colon and colon > 1 then
        local prefix   = current_word:sub(1, colon - 1)
        local raw_val  = current_word:sub(colon + 1)
        local in_quote = raw_val:sub(1, 1) == '"' -- cursor sits inside an open quote
        -- \" is only an escape inside a quoted value; unquoted it is literal.
        local partial  = in_quote and raw_val:sub(2):gsub('\\"', '"') or raw_val

        -- Case 1: Inside an "is:<partial_boolean_flag>" block
        if prefix == "is" then
            local items = {}
            for _, def in ipairs(list) do
                if def.type == "boolean" and vim.startswith(def.name, partial) then
                    table.insert(items, {
                        word = "is:" .. def.name,
                        abbr = def.name,
                        menu = def.desc or "[flag]",
                    })
                end
            end
            return #items > 0 and { startcol = word_start_1, items = items } or nil
        end

        -- Case 2: Inside a "value_flag:<partial_value>" block. Candidates come
        -- from the flag's static `values` and/or its dynamic `complete` source
        -- (e.g. file/dir completion). A value is quoted when it contains a space,
        -- or when the cursor already sits inside an open quote -- otherwise the
        -- unquoted candidates would not share the typed `"` prefix and Vim's live
        -- pum filter would drop them all as more of the value is typed.
        local def = defs[prefix]
        if def and def.type == "value" and (def.values or def.complete) then
            local items = {}
            -- `open_ended` candidates (paths) keep the quote open so the value can
            -- be extended -- completing a directory is usually a step towards a
            -- deeper path, and a closing quote would sit in the way.
            local function add(v, open_ended)
                local word = (in_quote or v:find('[%s"]'))
                    and (prefix .. ':"' .. v:gsub('"', '\\"') .. (open_ended and "" or '"'))
                    or (prefix .. ":" .. v)
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

            return #items > 0 and { startcol = word_start_1, items = items } or nil
        end
        return nil
    end

    -- A bare word could be query text; only offer flag-name suggestions on an
    -- explicit (non-auto) trigger.
    if auto then return nil end

    local items = {}
    -- If they have already started typing "is", suggest "is:" right away
    if vim.startswith("is:", current_word) and #current_word > 0 then
        table.insert(items, {
            word = "is:",
            abbr = "is:",
            menu = "[boolean prefix]",
        })
    end

    for _, def in ipairs(list) do
        if def.type == "value" and vim.startswith(def.name, current_word) then
            table.insert(items, {
                word = def.name .. ":",
                abbr = def.name,
                menu = def.desc or "[filter]",
            })
        elseif def.type == "boolean" then
            -- Boolean flags are generated dynamically behind "is:<name>".
            -- We can suggest the full "is:<name>" string matching current_word.
            local full_bool = "is:" .. def.name
            if vim.startswith(full_bool, current_word) then
                table.insert(items, {
                    word = full_bool,
                    abbr = full_bool,
                    menu = def.desc or "[flag]",
                })
            end
        end
    end
    return #items > 0 and { startcol = word_start_1, items = items } or nil
end

return M
