local qf = require("ezpick.base.queryflags")

local schema = {
    { name = "path",  type = "value", values = { "foo", "foo bar", "baz" } },
    { name = "kind",  type = "value", multi = true },
    { name = "repl",  type = "value", allow_empty = true },
    { name = "fixed", type = "boolean" },
}

describe("queryflags query", function()
    it("treats plain words as the query", function()
        local r = qf.parse(schema, "hello world")
        assert.are.equal("hello world", r.query)
        assert.are.same({}, r.flags)
    end)

    it("pulls flags out from anywhere, leaving the rest as the query", function()
        local r = qf.parse(schema, "--fixed hello --path src world")
        assert.is_true(r.flags.fixed)
        assert.are.equal("src", r.flags.path)
        assert.are.equal("hello world", r.query)
    end)

    it("accepts flags and query in any order", function()
        local r = qf.parse(schema, "hello --path src --fixed world")
        assert.is_true(r.flags.fixed)
        assert.are.equal("src", r.flags.path)
        assert.are.equal("hello world", r.query)
    end)

    it("treats quotes in query text as literal characters", function()
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
end)

describe("queryflags literal separator", function()
    it("takes a flag-looking string after -- as query text", function()
        local r = qf.parse(schema, "--fixed -- --fixed")
        assert.is_true(r.flags.fixed)
        assert.are.equal("--fixed", r.query)
    end)

    it("takes a value flag after -- as query text", function()
        local r = qf.parse(schema, "-- --path foo bar")
        assert.is_nil(r.flags.path)
        assert.are.equal("--path foo bar", r.query)
    end)

    it("parses flags written before the separator", function()
        local r = qf.parse(schema, '--path "foo bar" --fixed -- hello')
        assert.are.equal("foo bar", r.flags.path)
        assert.is_true(r.flags.fixed)
        assert.are.equal("hello", r.query)
    end)

    it("appends the literal text after the leading query text", function()
        local r = qf.parse(schema, "a b -- c d")
        assert.are.equal("a b c d", r.query)
        assert.are.same({}, r.flags)
    end)

    it("keeps the literal text verbatim", function()
        local r = qf.parse(schema, 'x --  a  "b" -- c ')
        assert.is_nil(r.error)
        assert.are.equal('x a  "b" -- c ', r.query)
        assert.are.same({}, r.flags)
    end)

    it("does not treat -- inside a quoted value as a separator", function()
        local r = qf.parse(schema, '--path "a -- b" c')
        assert.are.equal("a -- b", r.flags.path)
        assert.are.equal("c", r.query)
    end)

    it("only separates on a standalone --", function()
        local r = qf.parse(schema, "--x --fixed")
        assert.is_true(r.flags.fixed)
        assert.are.equal("--x", r.query)
    end)

    it("yields an empty query for a trailing separator", function()
        local r = qf.parse(schema, "--fixed --")
        assert.is_true(r.flags.fixed)
        assert.are.equal("", r.query)
    end)

    it("is never swallowed as a value", function()
        local r = qf.parse(schema, "--path -- foo")
        assert.is_nil(r.flags.path)
        assert.are.equal("foo", r.query)
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

    it("treats a bare boolean flag name as query text", function()
        local r = qf.parse(schema, "fixed hello world")
        assert.is_nil(r.flags.fixed)
        assert.are.equal("fixed hello world", r.query)
    end)

    it("leaves an unknown dashed token in the query", function()
        local r = qf.parse(schema, "--nope hello")
        assert.is_nil(r.flags.nope)
        assert.are.equal("--nope hello", r.query)
    end)

    it("does not consume a following token", function()
        local r = qf.parse(schema, "--fixed hello")
        assert.is_true(r.flags.fixed)
        assert.are.equal("hello", r.query)
    end)
end)

describe("queryflags value flags", function()
    it("takes the next token as the value", function()
        local r = qf.parse(schema, "--path src rest")
        assert.are.equal("src", r.flags.path)
        assert.are.equal("rest", r.query)
    end)

    it("takes a flag-looking token as the value", function()
        local r = qf.parse(schema, "--path --fixed")
        assert.are.equal("--fixed", r.flags.path)
        assert.is_nil(r.flags.fixed)
        assert.are.equal("", r.query)
    end)

    it("stays unset when no token follows", function()
        local r = qf.parse(schema, "hello --path")
        assert.is_nil(r.flags.path)
        assert.are.equal("hello", r.query)
    end)

    it("parses a double-quoted value with spaces", function()
        local r = qf.parse(schema, '--path "foo bar"')
        assert.are.equal("foo bar", r.flags.path)
        assert.are.equal("", r.query)
    end)

    it("treats single quotes as literal characters", function()
        local r = qf.parse(schema, "--path 'foo")
        assert.are.equal("'foo", r.flags.path)
        assert.are.equal("", r.query)
    end)

    it("inserts a literal double quote inside a quoted value via \\\"", function()
        local r = qf.parse(schema, '--path "foo \\"bar\\" baz"')
        assert.are.equal('foo "bar" baz', r.flags.path)
        assert.are.equal("", r.query)
    end)

    it("only opens a quoted value after a known value flag", function()
        -- "nope" is not a flag, so the quotes are literal and the space still
        -- ends the token.
        local r = qf.parse(schema, '--nope "foo bar"')
        assert.is_nil(r.error)
        assert.are.equal('--nope "foo bar"', r.query)
        assert.are.same({}, r.flags)
    end)

    it("does not open a quoted value after a boolean flag", function()
        local r = qf.parse(schema, '--fixed "foo bar"')
        assert.is_true(r.flags.fixed)
        assert.are.equal('"foo bar"', r.query)
    end)

    it("only opens a quoted value at the start of the value token", function()
        -- the quote does not open the token so it is an ordinary character and
        -- the space still ends the value.
        local r = qf.parse(schema, '--path foo"bar baz')
        assert.are.equal('foo"bar', r.flags.path)
        assert.are.equal("baz", r.query)
    end)

    it("treats quotes around a flag-looking token as literal query text", function()
        local r = qf.parse(schema, '"--path" foo')
        assert.is_nil(r.flags.path)
        assert.are.equal('"--path" foo', r.query)
    end)

    it("does not open a quoted span in query text", function()
        local r = qf.parse(schema, 'say "hi there')
        assert.is_nil(r.error)
        assert.are.equal('say "hi there', r.query)
        assert.are.same({}, r.flags)
    end)

    it("keeps a backslash-quote outside a quoted value literal", function()
        local r = qf.parse(schema, '--path foo\\"bar')
        assert.are.equal('foo\\"bar', r.flags.path)
        assert.are.equal("", r.query)
    end)

    it("continues the value with text after the closing quote", function()
        local r = qf.parse(schema, '--path "foo bar"baz')
        assert.is_nil(r.error)
        assert.are.equal("foo barbaz", r.flags.path)
        assert.are.equal("", r.query)
    end)

    it("accepts a quoted value ending the token", function()
        local r = qf.parse(schema, '--path "foo bar" baz')
        assert.is_nil(r.error)
        assert.are.equal("foo bar", r.flags.path)
        assert.are.equal("baz", r.query)
    end)

    it("reports an error on an unterminated value quote", function()
        local r = qf.parse(schema, '--path "foo ba')
        -- an unclosed quote is a malformed query: report it instead of guessing.
        assert.is_truthy(r.error)
        assert.are.same({}, r.flags)
        assert.are.equal("", r.query)
    end)

    it("collects quoted values for multi flags", function()
        local r = qf.parse(schema, '--kind "a b" --kind c')
        assert.are.same({ "a b", "c" }, r.flags.kind)
    end)

    it("drops an empty value", function()
        local r = qf.parse(schema, '--path "" here')
        assert.is_nil(r.flags.path)
        assert.are.equal("here", r.query)
    end)

    it("keeps an empty value for an allow_empty flag", function()
        local r = qf.parse(schema, '--repl "" here')
        assert.are.equal("", r.flags.repl)
        assert.are.equal("here", r.query)
    end)
end)

describe("queryflags highlight", function()
    it("highlights flags wherever they appear", function()
        local hls = qf.highlight(schema, "hello --fixed --path foo")
        local has_keyword = false
        local has_string  = false
        for _, h in ipairs(hls) do
            if h.hl == "Keyword" then has_keyword = true end
            if h.hl == "String" then has_string = true end
        end
        assert.is_true(has_keyword)
        assert.is_true(has_string)
    end)

    it("highlights a value flag's name and its value apart", function()
        assert.are.same({
            { start = 0, finish = 6,  hl = "Keyword" },
            { start = 7, finish = 10, hl = "String" },
        }, qf.highlight(schema, "--path foo"))
    end)

    it("highlights the separator and nothing after it", function()
        local hls = qf.highlight(schema, "--fixed -- --fixed --path foo")
        assert.are.same({
            { start = 0, finish = 7,  hl = "Keyword" },
            { start = 8, finish = 10, hl = "Delimiter" },
        }, hls)
    end)

    it("highlights the opening quote of an unterminated quote", function()
        local hls = qf.highlight(schema, '--path "foo ba')
        local delimiters = {}
        for _, h in ipairs(hls) do
            if h.hl == "Delimiter" then table.insert(delimiters, h) end
        end
        assert.are.same({
            { start = 7, finish = 8, hl = "Delimiter" },
        }, delimiters)
    end)

    it("does not highlight quotes in query text", function()
        -- quotes only delimit a flag value; in query text they are literal.
        for _, h in ipairs(qf.highlight(schema, '"--fixed"')) do
            assert.is_true(h.hl ~= "Delimiter")
        end
    end)

    it("highlights the quotes delimiting a value", function()
        local hls = qf.highlight(schema, '--path "foo bar"')
        local delimiters = {}
        for _, h in ipairs(hls) do
            if h.hl == "Delimiter" then table.insert(delimiters, h) end
        end
        assert.are.same({
            { start = 7,  finish = 8,  hl = "Delimiter" },
            { start = 15, finish = 16, hl = "Delimiter" },
        }, delimiters)
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

    it("offers the -- separator alongside the flag names", function()
        assert.is_true(vim.tbl_contains(words(schema, ""), "--"))
        assert.is_true(vim.tbl_contains(words(schema, "-"), "--"))
    end)

    it("keeps completing a bare -- as an in-progress flag", function()
        local got = words(schema, "--")
        assert.is_true(vim.tbl_contains(got, "--"))
        assert.is_true(vim.tbl_contains(got, "--fixed"))
    end)

    it("offers nothing after the separator", function()
        assert.is_nil(qf.get_completions(schema, "-- --fi", 7))
        assert.is_nil(qf.get_completions(schema, "-- pa", 5))
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

    it("offers nothing but values where a value is expected", function()
        for _, word in ipairs(words(schema, "--path ")) do
            assert.is_false(vim.startswith(word, "-"))
        end
        -- a value flag with no candidates of its own has nothing to offer
        assert.is_nil(qf.get_completions(schema, "--kind ", 7))
        -- ... and neither slot falls back to the separator or another flag
        assert.is_nil(qf.get_completions(schema, "--kind --", 9))
        assert.is_nil(qf.get_completions(schema, "--path --", 9))
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

        local r = qf.parse(schema, "--path " .. spaced.word)
        assert.are.equal("foo bar", r.flags.path)
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
        local schema = { { name = "x", type = "value", complete = "definitely_not_a_type" } }
        assert.has_no.errors(function() qf.get_completions(schema, "--x foo", 7) end)
    end)
end)
