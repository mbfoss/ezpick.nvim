local qf = require("ezpick.base.queryflags")

local schema = {
    { name = "path",      type = "value", values = { "foo", "foo bar", "baz" } },
    { name = "kind",      type = "value", multi = true },
    { name = "repl",      type = "value" },
    { name = "case",      type = "value", strict = true, values = { "smart", "on", "off" } },
    { name = "no-ignore", type = "boolean" },
    { name = "fixed",     type = "boolean" },
}

---@param result ezpick.queryflags.ParseResult
---@param kind   string
---@return ezpick.queryflags.Hint?
local function hint_of(result, kind)
    for _, h in ipairs(result.hints) do
        if h.kind == kind then return h end
    end
    return nil
end

---@param result ezpick.queryflags.ParseResult
---@param kind   string
---@return ezpick.queryflags.Hint[]  -- in the order parse sorted them, left to right
local function hints_of(result, kind)
    local found = {}
    for _, h in ipairs(result.hints) do
        if h.kind == kind then found[#found + 1] = h end
    end
    return found
end

describe("queryflags query", function()
    it("treats plain words as the query", function()
        local r = qf.parse(schema, "hello world")
        assert.are.equal("hello world", r.query)
        assert.are.same({}, r.flags)
    end)

    it("takes everything after the flags as the query", function()
        local r = qf.parse(schema, "--fixed --path src hello world")
        assert.is_true(r.flags.fixed)
        assert.are.equal("src", r.flags.path)
        assert.are.equal("hello world", r.query)
    end)

    it("keeps the query verbatim", function()
        -- the whole point of the ordering: a literal search gets exactly the
        -- bytes that were typed, inner spacing and all.
        local r = qf.parse(schema, "--fixed  a  b   c ")
        assert.are.equal("a  b   c ", r.query)
    end)

    it("reports where the query starts", function()
        local line = "--fixed hello"
        local r    = qf.parse(schema, line)
        assert.are.equal(9, r.query_start)
        assert.are.equal(r.query, line:sub(r.query_start))
        -- an all-flags line points just past the end
        assert.are.equal(#"--fixed" + 1, qf.parse(schema, "--fixed").query_start)
    end)

    it("stops parsing flags at the first query word", function()
        local r = qf.parse(schema, "hello --fixed world")
        assert.is_nil(r.flags.fixed)
        assert.are.equal("hello --fixed world", r.query)
    end)

    it("leaves quotes and backslashes in the query literal", function()
        local r = qf.parse(schema, '--fixed "foo\\ bar" baz')
        assert.is_true(r.flags.fixed)
        assert.are.equal('"foo\\ bar" baz', r.query)
    end)

    it("yields an empty query when only flags are present", function()
        local r = qf.parse(schema, "--fixed --path src")
        assert.is_true(r.flags.fixed)
        assert.are.equal("src", r.flags.path)
        assert.are.equal("", r.query)
    end)

    it("needs no escaping for a flag name inside the query", function()
        local r = qf.parse(schema, "see --fixed here")
        assert.are.equal("see --fixed here", r.query)
    end)
end)

describe("queryflags flag names", function()
    it("ignores case and word separators", function()
        for _, written in ipairs({ "--no-ignore", "--noignore", "--no_ignore", "--NO_IGNORE" }) do
            local r = qf.parse(schema, written .. " x")
            assert.is_true(r.flags["no-ignore"], written)
            assert.are.equal("x", r.query)
        end
    end)

    it("accepts a declared alias", function()
        local aliased = { { name = "hidden", type = "boolean", alias = { "all", "a" } } }
        assert.is_true(qf.parse(aliased, "--all x").flags.hidden)
        assert.is_true(qf.parse(aliased, "--a x").flags.hidden)
    end)

    it("treats a bare flag name as query text", function()
        local r = qf.parse(schema, "fixed hello")
        assert.is_nil(r.flags.fixed)
        assert.are.equal("fixed hello", r.query)
    end)
end)

describe("queryflags literal separator", function()
    it("lets the query start with a flag name", function()
        local r = qf.parse(schema, "-- --fixed")
        assert.is_nil(r.flags.fixed)
        assert.are.equal("--fixed", r.query)
    end)

    it("parses flags written before it", function()
        local r = qf.parse(schema, "--path foo\\ bar --fixed -- --path hello")
        assert.are.equal("foo bar", r.flags.path)
        assert.is_true(r.flags.fixed)
        assert.are.equal("--path hello", r.query)
    end)

    it("is only reached while still in the flags", function()
        -- the query already started, so this "--" is ordinary text
        local r = qf.parse(schema, "a b -- c d")
        assert.are.equal("a b -- c d", r.query)
        assert.are.same({}, r.flags)
    end)

    it("keeps the query after it verbatim", function()
        local r = qf.parse(schema, '--fixed -- a  "b" -- c ')
        assert.is_true(r.flags.fixed)
        assert.are.equal('a  "b" -- c ', r.query)
    end)

    it("is not a separator when glued to other text", function()
        local r = qf.parse(schema, "--x --fixed")
        assert.is_nil(r.flags.fixed)
        assert.are.equal("--x --fixed", r.query)
    end)

    it("yields an empty query when trailing", function()
        local r = qf.parse(schema, "--fixed --")
        assert.is_true(r.flags.fixed)
        assert.are.equal("", r.query)
    end)

    it("leaves a colon-looking token in the query", function()
        local r = qf.parse(schema, "http://example.com here")
        assert.are.same({}, r.flags)
        assert.are.equal("http://example.com here", r.query)
    end)
end)

describe("queryflags boolean flags", function()
    it("sets a boolean flag from its dashed name", function()
        local r = qf.parse(schema, "--fixed hello world")
        assert.is_true(r.flags.fixed)
        assert.are.equal("hello world", r.query)
    end)

    it("does not consume a following token", function()
        local r = qf.parse(schema, "--fixed hello")
        assert.is_true(r.flags.fixed)
        assert.are.equal("hello", r.query)
    end)

    it("refuses a value glued onto a switch, whichever way it reads", function()
        -- A switch is written by being there, so no value assigned to it can be
        -- right: "=false" reads as off and "=true" as belt and braces, and
        -- neither is a form this understands. Rather than act on the reading
        -- that happens to be spelled out, it leaves the switch alone and says so
        -- -- guessing "on" at "--fixed=false" would be the opposite of the words.
        for _, raw in ipairs({ "--fixed=x y", "--fixed=true y", "--fixed=false y", "--fixed= y" }) do
            local r = qf.parse(schema, raw)
            assert.is_nil(r.flags.fixed, raw)
            assert.are.equal("y", r.query, raw)
            assert.is_not_nil(hint_of(r, "unexpected-value"), raw)
        end
    end)
end)

describe("queryflags value flags", function()
    it("takes the next token as the value", function()
        local r = qf.parse(schema, "--path src rest")
        assert.are.equal("src", r.flags.path)
        assert.are.equal("rest", r.query)
    end)

    it("takes a value glued on with =", function()
        local r = qf.parse(schema, "--path=src rest")
        assert.are.equal("src", r.flags.path)
        assert.are.equal("rest", r.query)
    end)

    it("keeps an explicitly empty glued value", function()
        local r = qf.parse(schema, "--repl= here")
        assert.are.equal("", r.flags.repl)
        assert.are.equal("here", r.query)
    end)


    it("does not swallow a following flag as its value", function()
        local r = qf.parse(schema, "--path --fixed")
        assert.is_nil(r.flags.path)
        assert.is_true(r.flags.fixed)
        assert.is_not_nil(hint_of(r, "missing-value"))
    end)

    it("does not swallow the separator as its value", function()
        local r = qf.parse(schema, "--path -- foo")
        assert.is_nil(r.flags.path)
        assert.are.equal("foo", r.query)
    end)

    it("takes a flag-looking value when it is glued on", function()
        local r = qf.parse(schema, "--path=--fixed")
        assert.are.equal("--fixed", r.flags.path)
        assert.is_nil(r.flags.fixed)
    end)

    it("takes a flag-looking value when its dash is escaped", function()
        local r = qf.parse(schema, "--path \\--fixed")
        assert.are.equal("--fixed", r.flags.path)
        assert.is_nil(r.flags.fixed)
    end)

    it("takes an escaped separator as a value", function()
        local r = qf.parse(schema, "--path \\-- foo")
        assert.are.equal("--", r.flags.path)
        assert.are.equal("foo", r.query)
    end)

    it("stays unset when nothing follows", function()
        local r = qf.parse(schema, "--path")
        assert.is_nil(r.flags.path)
        assert.is_not_nil(hint_of(r, "missing-value"))
    end)

    it("parses a value whose spaces are escaped", function()
        local r = qf.parse(schema, "--path foo\\ bar rest")
        assert.are.equal("foo bar", r.flags.path)
        assert.are.equal("rest", r.query)
    end)

    it("parses an escaped value glued on with =", function()
        local r = qf.parse(schema, "--path=foo\\ bar rest")
        assert.are.equal("foo bar", r.flags.path)
        assert.are.equal("rest", r.query)
    end)

    it("treats quotes as literal characters", function()
        local r = qf.parse(schema, "--path \"foo 'bar")
        assert.are.equal('"foo', r.flags.path)
        assert.are.equal("'bar", r.query)
    end)

    it("inserts a literal backslash via \\\\", function()
        local r = qf.parse(schema, "--path a\\\\b c")
        assert.are.equal("a\\b", r.flags.path)
        assert.are.equal("c", r.query)
    end)

    it("escapes any character, not just the special ones", function()
        local r = qf.parse(schema, "--path fo\\o")
        assert.are.equal("foo", r.flags.path)
    end)

    it("escapes anywhere in the value, not only at its start", function()
        local r = qf.parse(schema, "--path foo\\ bar\\ baz q")
        assert.are.equal("foo bar baz", r.flags.path)
        assert.are.equal("q", r.query)
    end)

    it("does not treat an escaped -- inside a value as a separator", function()
        local r = qf.parse(schema, "--path a\\ --\\ b c")
        assert.are.equal("a -- b", r.flags.path)
        assert.are.equal("c", r.query)
    end)

    it("collects values for multi flags", function()
        local r = qf.parse(schema, "--kind a\\ b --kind=c --kind d q")
        assert.are.same({ "a b", "c", "d" }, r.flags.kind)
        assert.are.equal("q", r.query)
    end)
end)

describe("queryflags hints", function()
    it("keeps a usable query and flags beside every hint", function()
        -- nothing here may empty the result list: a hint is advice, not a stop.
        local r = qf.parse(schema, "--fixed --path My\\")
        assert.is_true(r.flags.fixed)
        assert.are.equal("My", r.flags.path)
        assert.is_not_nil(hint_of(r, "dangling-escape"))
    end)

    it("marks only the trailing backslash, not the value it sits on", function()
        local h = assert(hint_of(qf.parse(schema, "--path My\\"), "dangling-escape"))
        assert.are.equal(9, h.start)
        assert.are.equal(10, h.finish)
    end)

    it("reports a typo'd flag as unknown", function()
        local h = hint_of(qf.parse(schema, "--fixd hello"), "unknown-flag")
        assert.is_not_nil(h)
        assert.is_truthy(h.msg:find("unknown option --fixd", 1, true))
        -- ... and the typo is still searched for rather than swallowed
        assert.are.equal("--fixd hello", qf.parse(schema, "--fixd hello").query)
    end)

    it("reports a dashed word naming no flag, finished or not", function()
        -- Whether "--fi" is a typo or the start of "--fixed" is a question only
        -- the cursor answers, and `parse` does not have it: it reports what it
        -- sees and leaves the holding to whoever is watching the typing.
        assert.is_not_nil(hint_of(qf.parse(schema, "--fi"), "unknown-flag"))
        assert.is_not_nil(hint_of(qf.parse(schema, "--fi x"), "unknown-flag"))
    end)

    it("says nothing about a flag name inside the query, which is ordinary text", function()
        -- The query is searched for exactly as written, so a word in it that
        -- happens to spell a flag is not a mistake to report -- it is what was
        -- asked for.
        assert.are.same({}, qf.parse(schema, "hello --fixed").hints)
        assert.are.same({}, qf.parse(schema, "hello --path=src").hints)
        assert.are.same({}, qf.parse(schema, "hello --fixedly").hints)

        -- ... including after flags that did parse, whose values stand
        local r = qf.parse(schema, "--path . a --path")
        assert.are.same({}, r.hints)
        assert.are.equal("a --path", r.query)
        assert.are.equal(".", r.flags.path)
    end)

    it("points out a single-valued flag given twice, and keeps the last value", function()
        local r = qf.parse(schema, "--path a --path b")
        assert.are.equal("b", r.flags.path)
        local hs = hints_of(r, "duplicate-flag")
        assert.are.equal(2, #hs)
        assert.is_truthy(hs[1].msg:find("2 times", 1, true))
        assert.is_truthy(hs[1].msg:find("'b'", 1, true))
    end)

    it("marks every occurrence of a repeated flag", function()
        local hs = hints_of(qf.parse(schema, "--path a --path b --path c"), "duplicate-flag")
        assert.are.equal(3, #hs)
        -- the winner named is the last one, not the second
        assert.is_truthy(hs[1].msg:find("'c'", 1, true))
        assert.is_truthy(hs[1].msg:find("3 times", 1, true))
    end)

    it("marks the flag name only, glued or spaced alike", function()
        local hs = hints_of(qf.parse(schema, "--path=a --path b"), "duplicate-flag")
        assert.are.equal(2, #hs)
        assert.are.same({ start = 0, finish = 6 }, { start = hs[1].start, finish = hs[1].finish })
        assert.are.same({ start = 9, finish = 15 }, { start = hs[2].start, finish = hs[2].finish })
    end)

    it("counts an explicitly empty value as a value given", function()
        local r = qf.parse(schema, "--repl= --repl x")
        assert.are.equal("x", r.flags.repl)
        assert.are.equal(2, #hints_of(r, "duplicate-flag"))
    end)

    it("says nothing about a flag given once", function()
        assert.is_nil(hint_of(qf.parse(schema, "--path a hello"), "duplicate-flag"))
    end)

    it("says nothing about a repeated multi flag", function()
        local r = qf.parse(schema, "--kind x --kind y")
        assert.are.same({ "x", "y" }, r.flags.kind)
        assert.is_nil(hint_of(r, "duplicate-flag"))
    end)

    it("says nothing about a repeated switch, which discards nothing", function()
        local r = qf.parse(schema, "--fixed --fixed hello")
        assert.is_true(r.flags.fixed)
        assert.is_nil(hint_of(r, "duplicate-flag"))
    end)

    it("rejects a value outside a strict flag's values", function()
        local h = hint_of(qf.parse(schema, "--case bogus zzz"), "bad-value")
        assert.is_not_nil(h)
        assert.is_truthy(h.msg:find("smart|on|off", 1, true))
        -- the value still reaches the picker, which has its own fallback
        assert.are.equal("bogus", qf.parse(schema, "--case bogus zzz").flags.case)
    end)

    it("reports a strict value that is only a prefix, finished or not", function()
        -- Same as an unfinished flag name: a prefix of a valid choice is still
        -- not one of them, and the cursor decides whether saying so is nagging.
        assert.is_not_nil(hint_of(qf.parse(schema, "--case sm"), "bad-value"))
        assert.is_not_nil(hint_of(qf.parse(schema, "--case sm x"), "bad-value"))
    end)

    it("marks the flag when the bad value is an empty one", function()
        -- "--case=" has no value span to point at, and an underline of nothing
        -- leaves the message with nowhere to have come from.
        local h = assert(hint_of(qf.parse(schema, "--case= x"), "bad-value"))
        assert.are.same({ start = 0, finish = 7 }, { start = h.start, finish = h.finish })
    end)

    it("names the flag the way the line spells it", function()
        -- The mark and the words have to describe one thing, so an alias is
        -- echoed back as written: underlining "--dir" while talking about
        -- "--path" sends the reader hunting for a flag that is nowhere in sight.
        local aliased = {
            { name = "path",  type = "value",   alias = { "dir" } },
            { name = "case",  type = "value",   alias = { "ci" }, strict = true, values = { "on", "off" } },
            { name = "fixed", type = "boolean", alias = { "F" } },
        }
        ---@param raw  string
        ---@param kind string
        ---@return string
        local function msg(raw, kind) return assert(hint_of(qf.parse(aliased, raw), kind)).msg end

        assert.are.equal("--dir needs a value", msg("--dir --fixed", "missing-value"))
        assert.are.equal("--ci: on|off", msg("--ci bogus x", "bad-value"))
        assert.are.equal("--F takes no value", msg("--F=x y", "unexpected-value"))
        assert.is_truthy(msg("--dir a --dir b", "duplicate-flag"):find("--dir set 2 times", 1, true))
        assert.are.equal("unknown option --di", msg("--di x", "unknown-flag"))
    end)

    it("does not police a non-strict flag's values", function()
        assert.is_nil(hint_of(qf.parse(schema, "--path whatever x"), "bad-value"))
    end)

    it("orders hints by position", function()
        -- Duplicates are appended once the winning value is known, so they land
        -- in the list after hints that sit to their left.
        local r = qf.parse(schema, "--path a --path b --case bogus zzz")
        assert.is_true(#r.hints >= 3)
        for i = 2, #r.hints do
            assert.is_true(r.hints[i - 1].start <= r.hints[i].start)
        end
    end)

    it("reports nothing for a clean query", function()
        assert.are.same({}, qf.parse(schema, "--fixed --path src hello").hints)
    end)
end)

describe("queryflags schema", function()
    it("refuses a strict flag with no values to be strict about", function()
        -- Nothing could ever fail the check, so the flag would quietly accept
        -- anything while claiming not to. That is a mistake in the schema rather
        -- than in what was typed, and it is worth hearing about on the first
        -- render instead of never.
        assert.has_error(function()
            qf.parse({ { name = "case", type = "value", strict = true } }, "--case x")
        end)
    end)
end)

describe("queryflags highlight", function()
    it("highlights a value flag's name and its value apart", function()
        assert.are.same({
            { start = 0, finish = 6,  hl = "Keyword" },
            { start = 7, finish = 10, hl = "String" },
        }, qf.highlight(schema, "--path foo"))
    end)

    it("highlights the = gluing a value on", function()
        assert.are.same({
            { start = 0, finish = 6,  hl = "Keyword" },
            { start = 6, finish = 7,  hl = "Delimiter" },
            { start = 7, finish = 10, hl = "String" },
        }, qf.highlight(schema, "--path=foo"))
    end)

    it("leaves the query unhighlighted", function()
        local hls = qf.highlight(schema, "--fixed --path foo hello --fixed")
        for _, h in ipairs(hls) do
            assert.is_true(h.finish <= 18, "highlight leaked into the query")
        end
    end)

    it("highlights the separator and nothing after it", function()
        assert.are.same({
            { start = 0, finish = 7,  hl = "Keyword" },
            { start = 8, finish = 10, hl = "Delimiter" },
        }, qf.highlight(schema, "--fixed -- --fixed --path foo"))
    end)

    it("dims the escaping backslashes in a value", function()
        local escapes = {}
        for _, h in ipairs(qf.highlight(schema, "--path foo\\ bar")) do
            if h.hl == "NonText" then table.insert(escapes, h) end
        end
        assert.are.same({
            { start = 10, finish = 11, hl = "NonText" },
        }, escapes)
    end)

    it("dims a trailing backslash that escapes nothing", function()
        local escapes = {}
        for _, h in ipairs(qf.highlight(schema, "--path foo\\")) do
            if h.hl == "NonText" then table.insert(escapes, h) end
        end
        assert.are.same({
            { start = 10, finish = 11, hl = "NonText" },
        }, escapes)
    end)

    it("does not dim a backslash in query text", function()
        for _, h in ipairs(qf.highlight(schema, "a\\ b")) do
            assert.is_true(h.hl ~= "NonText")
        end
    end)
end)

describe("queryflags completion", function()
    local function words(s, line, auto)
        local comps = qf.get_completions(s, line, #line, auto)
        if not comps then return {} end
        return vim.tbl_map(function(it) return it.word end, comps.items)
    end

    it("completes a partial boolean flag", function()
        assert.is_true(vim.tbl_contains(words(schema, "--fi"), "--fixed"))
    end)

    it("completes a partial value flag name", function()
        assert.is_true(vim.tbl_contains(words(schema, "--pa"), "--path"))
    end)

    it("completes a name written without its separators", function()
        assert.is_true(vim.tbl_contains(words(schema, "--noig"), "--no-ignore"))
    end)

    it("offers every flag on an empty prompt", function()
        assert.is_true(vim.tbl_contains(words(schema, ""), "--fixed"))
    end)

    it("never offers the -- separator", function()
        -- it only matters for a query starting with a flag name, and typing it
        -- is two characters; listing it only puts a riddle among the flags.
        for _, line in ipairs({ "", "-", "--" }) do
            assert.is_false(vim.tbl_contains(words(schema, line), "--"), line)
        end
    end)

    it("keeps completing a bare -- as an in-progress flag", function()
        assert.is_true(vim.tbl_contains(words(schema, "--"), "--fixed"))
    end)

    it("offers nothing after the separator", function()
        assert.is_nil(qf.get_completions(schema, "-- --fi", 7))
        assert.is_nil(qf.get_completions(schema, "-- pa", 5))
    end)

    it("offers nothing once the query has started", function()
        -- a flag completed here could not take effect, so it is not offered
        assert.is_nil(qf.get_completions(schema, "hello --fi", 10))
        assert.is_nil(qf.get_completions(schema, "hello --path ", 13))
    end)

    it("suppresses bare-word completions when auto is set", function()
        assert.is_nil(qf.get_completions(schema, "fi", 2, true))
    end)

    it("completes a value flag's name when auto is set", function()
        assert.is_true(vim.tbl_contains(words(schema, "--pa", true), "--path"))
    end)

    it("offers values in the empty slot after a value flag", function()
        assert.is_true(vim.tbl_contains(words(schema, "--path ", true), "foo"))
    end)

    it("offers names, not values, while the flag name is still under the cursor", function()
        -- "--path" is a complete name, but nothing separates it from its value
        -- slot yet, so the cursor is on the name: completing it must not jump
        -- ahead to what the flag will eventually take.
        local w = words(schema, "--path", true)
        assert.is_true(vim.tbl_contains(w, "--path"))
        assert.is_false(vim.tbl_contains(w, "foo"))
    end)

    it("offers values after an = ", function()
        assert.is_true(vim.tbl_contains(words(schema, "--path=f"), "foo"))
        assert.is_true(vim.tbl_contains(words(schema, "--path="), "baz"))
    end)

    it("offers nothing but values where a value is expected", function()
        for _, word in ipairs(words(schema, "--path ")) do
            assert.is_false(vim.startswith(word, "-"))
        end
        -- a value flag with no candidates of its own has nothing to offer
        assert.is_nil(qf.get_completions(schema, "--kind ", 7))
        assert.is_nil(qf.get_completions(schema, "--kind=", 7))
    end)

    it("offers nothing once a value is complete", function()
        assert.is_nil(qf.get_completions(schema, "--path foo ", 11, true))
    end)

    it("escapes the spaces in a candidate so it re-parses", function()
        local comps = qf.get_completions(schema, "--path foo", 10)
        assert.not_nil(comps)
        assert.are.equal(8, comps.startcol)

        local spaced
        for _, item in ipairs(comps.items) do
            if item.abbr == "foo bar" then spaced = item end
        end
        assert.not_nil(spaced)
        assert.are.equal("foo\\ bar", spaced.word)
        assert.are.equal("foo bar", qf.parse(schema, "--path " .. spaced.word).flags.path)
    end)

    it("matches candidates against a partial written with escapes", function()
        -- The escaped candidate keeps the typed prefix, so Vim's live pum filter
        -- keeps it; the menu still shows the plain value.
        local line  = "--path foo\\ b"
        local comps = qf.get_completions(schema, line, #line)
        assert.not_nil(comps)
        assert.are.equal(8, comps.startcol)
        assert.are.same({ { word = "foo\\ bar", abbr = "foo bar" } }, comps.items)
    end)

    it("replaces a half-written escape rather than completing after it", function()
        local line  = "--path fo\\"
        local comps = qf.get_completions(schema, line, #line)
        assert.not_nil(comps)
        assert.are.equal(8, comps.startcol)
        assert.is_true(vim.tbl_contains(
            vim.tbl_map(function(it) return it.word end, comps.items), "foo"))
    end)
end)

describe("queryflags value completion type", function()
    local sources = {
        { name = "tag",  type = "value", complete = function(partial)
            return vim.tbl_filter(
                function(v) return vim.startswith(v, partial) end,
                { "alpha", "beta", "gamma" }
            )
        end },
        { name = "lang", type = "value", values = { "lua", "vim" }, complete = function() return { "rust" } end },
        { name = "win",  type = "value", complete = "with spaces source" },
    }

    local function words(s, line)
        local comps = qf.get_completions(s, line, #line)
        if not comps then return {} end
        return vim.tbl_map(function(it) return it.word end, comps.items)
    end

    it("completes values from a function source, filtered by the partial", function()
        assert.are.same({ "beta" }, words(sources, "--tag be"))
    end)

    it("merges static values with a dynamic complete source", function()
        local got = words(sources, "--lang ")
        assert.is_true(vim.tbl_contains(got, "lua"))
        assert.is_true(vim.tbl_contains(got, "vim"))
        assert.is_true(vim.tbl_contains(got, "rust"))
    end)

    it("does not error on an unknown getcompletion type", function()
        local one = { { name = "x", type = "value", complete = "definitely_not_a_type" } }
        assert.has_no.errors(function() qf.get_completions(one, "--x foo", 7) end)
    end)
end)
