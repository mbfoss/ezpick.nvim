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

    it("leaves quotes in the query literal", function()
        local r = qf.parse(schema, '--fixed "foo bar" baz')
        assert.is_true(r.flags.fixed)
        assert.are.equal('"foo bar" baz', r.query)
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
        local r = qf.parse(schema, '--path "foo bar" --fixed -- --path hello')
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

    it("silences the misplaced-flag hint", function()
        assert.is_nil(hint_of(qf.parse(schema, "-- --fixed here"), "misplaced-flag"))
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

    it("hints when a value is glued on", function()
        local r = qf.parse(schema, "--fixed=x y")
        assert.is_true(r.flags.fixed)
        assert.are.equal("y", r.query)
        assert.is_not_nil(hint_of(r, "unexpected-value"))
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

    it("keeps an explicitly empty quoted value", function()
        local r = qf.parse(schema, '--repl "" here')
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

    it("takes a flag-looking value when it is quoted", function()
        local r = qf.parse(schema, '--path "--fixed"')
        assert.are.equal("--fixed", r.flags.path)
        assert.is_nil(r.flags.fixed)
    end)

    it("stays unset when nothing follows", function()
        local r = qf.parse(schema, "--path")
        assert.is_nil(r.flags.path)
        assert.is_not_nil(hint_of(r, "missing-value"))
    end)

    it("parses a double-quoted value with spaces", function()
        local r = qf.parse(schema, '--path "foo bar" rest')
        assert.are.equal("foo bar", r.flags.path)
        assert.are.equal("rest", r.query)
    end)

    it("parses a double-quoted value glued on with =", function()
        local r = qf.parse(schema, '--path="foo bar" rest')
        assert.are.equal("foo bar", r.flags.path)
        assert.are.equal("rest", r.query)
    end)

    it("treats single quotes as literal characters", function()
        local r = qf.parse(schema, "--path 'foo")
        assert.are.equal("'foo", r.flags.path)
    end)

    it("inserts a literal double quote inside a quoted value via \\\"", function()
        local r = qf.parse(schema, '--path "foo \\"bar\\" baz"')
        assert.are.equal('foo "bar" baz', r.flags.path)
    end)

    it("only opens a quote at the start of the value", function()
        local r = qf.parse(schema, '--path foo"bar baz')
        assert.are.equal('foo"bar', r.flags.path)
        assert.are.equal("baz", r.query)
    end)

    it("keeps a backslash-quote outside a quoted value literal", function()
        local r = qf.parse(schema, '--path foo\\"bar')
        assert.are.equal('foo\\"bar', r.flags.path)
    end)

    it("continues the value with text after the closing quote", function()
        local r = qf.parse(schema, '--path "foo bar"baz')
        assert.are.equal("foo barbaz", r.flags.path)
    end)

    it("does not treat -- inside a quoted value as a separator", function()
        local r = qf.parse(schema, '--path "a -- b" c')
        assert.are.equal("a -- b", r.flags.path)
        assert.are.equal("c", r.query)
    end)

    it("collects values for multi flags", function()
        local r = qf.parse(schema, '--kind "a b" --kind=c --kind d q')
        assert.are.same({ "a b", "c", "d" }, r.flags.kind)
        assert.are.equal("q", r.query)
    end)
end)

describe("queryflags hints", function()
    it("keeps a usable query and flags beside every hint", function()
        -- nothing here may empty the result list: a hint is advice, not a stop.
        local r = qf.parse(schema, '--fixed --path "My Doc')
        assert.is_true(r.flags.fixed)
        assert.are.equal("My Doc", r.flags.path)
        assert.is_not_nil(hint_of(r, "unclosed-quote"))
    end)

    it("suggests the flag a typo was reaching for", function()
        local h = hint_of(qf.parse(schema, "--fixd hello"), "unknown-flag")
        assert.is_not_nil(h)
        assert.is_truthy(h.msg:find("--fixed", 1, true))
        -- ... and the typo is still searched for rather than swallowed
        assert.are.equal("--fixd hello", qf.parse(schema, "--fixd hello").query)
    end)

    it("stays quiet on a flag name still being typed", function()
        assert.is_nil(hint_of(qf.parse(schema, "--fi"), "unknown-flag"))
        assert.is_not_nil(hint_of(qf.parse(schema, "--fi x"), "unknown-flag"))
    end)

    it("points out a flag written after the query", function()
        local h = hint_of(qf.parse(schema, "hello --fixed"), "misplaced-flag")
        assert.is_not_nil(h)
        assert.are.equal(6, h.start)
        assert.are.equal(13, h.finish)
    end)

    it("points out a value flag written after the query", function()
        assert.is_not_nil(hint_of(qf.parse(schema, "hello --path=src"), "misplaced-flag"))
    end)

    it("ignores a word that merely starts with a flag name", function()
        assert.is_nil(hint_of(qf.parse(schema, "hello --fixedly"), "misplaced-flag"))
    end)

    it("rejects a value outside a strict flag's values", function()
        local h = hint_of(qf.parse(schema, "--case bogus zzz"), "bad-value")
        assert.is_not_nil(h)
        assert.is_truthy(h.msg:find("smart|on|off", 1, true))
        -- the value still reaches the picker, which has its own fallback
        assert.are.equal("bogus", qf.parse(schema, "--case bogus zzz").flags.case)
    end)

    it("stays quiet on a strict value still being typed", function()
        assert.is_nil(hint_of(qf.parse(schema, "--case sm"), "bad-value"))
        assert.is_not_nil(hint_of(qf.parse(schema, "--case sm x"), "bad-value"))
    end)

    it("does not police a non-strict flag's values", function()
        assert.is_nil(hint_of(qf.parse(schema, "--path whatever x"), "bad-value"))
    end)

    it("orders hints by position", function()
        local r = qf.parse(schema, "--case bogus hello --fixed")
        assert.is_true(#r.hints >= 2)
        for i = 2, #r.hints do
            assert.is_true(r.hints[i - 1].start <= r.hints[i].start)
        end
    end)

    it("reports nothing for a clean query", function()
        assert.are.same({}, qf.parse(schema, "--fixed --path src hello").hints)
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

    it("highlights the quotes delimiting a value", function()
        local delimiters = {}
        for _, h in ipairs(qf.highlight(schema, '--path "foo bar"')) do
            if h.hl == "Delimiter" then table.insert(delimiters, h) end
        end
        assert.are.same({
            { start = 7,  finish = 8,  hl = "Delimiter" },
            { start = 15, finish = 16, hl = "Delimiter" },
        }, delimiters)
    end)

    it("highlights the opening quote of an unterminated quote", function()
        local delimiters = {}
        for _, h in ipairs(qf.highlight(schema, '--path "foo ba')) do
            if h.hl == "Delimiter" then table.insert(delimiters, h) end
        end
        assert.are.same({
            { start = 7, finish = 8, hl = "Delimiter" },
        }, delimiters)
    end)

    it("does not highlight quotes in query text", function()
        for _, h in ipairs(qf.highlight(schema, '"--fixed"')) do
            assert.is_true(h.hl ~= "Delimiter")
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

    it("wraps a spaced value in quotes so it re-parses", function()
        local comps = qf.get_completions(schema, "--path foo", 10)
        assert.not_nil(comps)
        assert.are.equal(8, comps.startcol)

        local spaced
        for _, item in ipairs(comps.items) do
            if item.abbr == "foo bar" then spaced = item end
        end
        assert.not_nil(spaced)
        assert.are.equal('"foo bar"', spaced.word)
        assert.are.equal("foo bar", qf.parse(schema, "--path " .. spaced.word).flags.path)
    end)

    it("offers value completions while inside an open quote", function()
        local line  = '--path "foo '
        local comps = qf.get_completions(schema, line, #line)
        assert.not_nil(comps)

        local found = false
        for _, item in ipairs(comps.items) do
            if item.abbr == "foo bar" then found = true end
        end
        assert.is_true(found)
    end)

    it("quotes space-free candidates when inside an open quote", function()
        -- Inside an open quote every candidate must carry the quote so it keeps
        -- the typed `"` prefix; otherwise Vim's live pum filter drops them all.
        local line  = '--path "f'
        local comps = qf.get_completions(schema, line, #line)
        assert.not_nil(comps)

        local plain
        for _, item in ipairs(comps.items) do
            if item.abbr == "foo" then plain = item end
        end
        assert.not_nil(plain)
        assert.are.equal('"foo"', plain.word)
        assert.are.equal("foo", qf.parse(schema, "--path " .. plain.word).flags.path)
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
