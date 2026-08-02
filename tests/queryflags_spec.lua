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
        local r = qf.parse(schema, "is:fixed hello path:src world")
        assert.is_true(r.flags.fixed)
        assert.are.equal("src", r.flags.path)
        assert.are.equal("hello world", r.query)
    end)

    it("accepts flags and query in any order", function()
        local r = qf.parse(schema, "hello path:src is:fixed world")
        assert.is_true(r.flags.fixed)
        assert.are.equal("src", r.flags.path)
        assert.are.equal("hello world", r.query)
    end)

    it("treats quotes in query text as literal characters", function()
        local r = qf.parse(schema, 'is:fixed "foo bar" baz')
        assert.is_true(r.flags.fixed)
        assert.are.equal('"foo bar" baz', r.query)
    end)

    it("yields an empty query when only flags are present", function()
        local r = qf.parse(schema, "is:fixed path:src")
        assert.is_true(r.flags.fixed)
        assert.are.equal("src", r.flags.path)
        assert.are.equal("", r.query)
    end)
end)

describe("queryflags implicit query flag", function()
    it("passes a flag-looking string through as query text", function()
        local r = qf.parse(schema, 'query:"is:fixed" hello')
        assert.is_nil(r.flags.fixed)
        assert.is_nil(r.flags.query)
        assert.are.equal("is:fixed hello", r.query)
    end)

    it("passes a key:value string through as query text", function()
        local r = qf.parse(schema, 'query:"path:foo" bar')
        assert.is_nil(r.flags.path)
        assert.are.equal("path:foo bar", r.query)
    end)

    it("keeps spaces inside a quoted query value", function()
        local r = qf.parse(schema, 'query:"path:foo bar"')
        assert.are.equal("path:foo bar", r.query)
        assert.are.same({}, r.flags)
    end)

    it("joins each occurrence in the position it was written", function()
        local r = qf.parse(schema, "a query:b c query:d")
        assert.are.equal("a b c d", r.query)
        assert.are.same({}, r.flags)
    end)

    it("works without quotes for a plain value", function()
        local r = qf.parse(schema, "query:hello is:fixed")
        assert.is_true(r.flags.fixed)
        assert.are.equal("hello", r.query)
    end)

    it("rejects a schema that defines its own query flag", function()
        local own = { { name = "query", type = "value" } }
        assert.has_error(function() qf.parse(own, "hello") end)
    end)

    it("leaves an unknown key:value token in the query", function()
        local r = qf.parse(schema, "http://example.com here")
        assert.are.same({}, r.flags)
        assert.are.equal("http://example.com here", r.query)
    end)
end)

describe("queryflags boolean flags", function()
    it("sets a boolean flag via the is: prefix", function()
        local r = qf.parse(schema, "is:fixed hello world")
        assert.is_true(r.flags.fixed)
        assert.are.equal("hello world", r.query)
    end)

    it("treats a bare boolean flag name as query text", function()
        local r = qf.parse(schema, "fixed hello world")
        assert.is_nil(r.flags.fixed)
        assert.are.equal("fixed hello world", r.query)
    end)

    it("leaves an unknown is: token in the query", function()
        local r = qf.parse(schema, "is:nope hello")
        assert.is_nil(r.flags.nope)
        assert.are.equal("is:nope hello", r.query)
    end)
end)

describe("queryflags value flags", function()
    it("parses a double-quoted value with spaces", function()
        local r = qf.parse(schema, 'path:"foo bar"')
        assert.are.equal("foo bar", r.flags.path)
        assert.are.equal("", r.query)
    end)

    it("treats single quotes as literal characters", function()
        local r = qf.parse(schema, "path:'foo")
        assert.are.equal("'foo", r.flags.path)
        assert.are.equal("", r.query)
    end)

    it("inserts a literal double quote inside a quoted value via \\\"", function()
        local r = qf.parse(schema, 'path:"foo \\"bar\\" baz"')
        assert.are.equal('foo "bar" baz', r.flags.path)
        assert.are.equal("", r.query)
    end)

    it("only opens a quoted value after a known value flag", function()
        -- "nope" is not a flag, so its quotes are literal and the space still
        -- ends the token.
        local r = qf.parse(schema, 'nope:"foo bar"')
        assert.is_nil(r.error)
        assert.are.equal('nope:"foo bar"', r.query)
        assert.are.same({}, r.flags)
    end)

    it("does not quote after a boolean flag's is: prefix", function()
        local r = qf.parse(schema, 'is:"fixed"')
        assert.is_nil(r.flags.fixed)
        assert.are.equal('is:"fixed"', r.query)
    end)

    it("only opens a quoted value directly after the key colon", function()
        -- the quote is not adjacent to the ':' so it is an ordinary character
        -- and the space still ends the token.
        local r = qf.parse(schema, 'path:foo"bar baz')
        assert.are.equal('foo"bar', r.flags.path)
        assert.are.equal("baz", r.query)
    end)

    it("treats quotes around a flag-looking token as literal query text", function()
        local r = qf.parse(schema, '"path:foo"')
        assert.is_nil(r.flags.path)
        assert.are.equal('"path:foo"', r.query)
    end)

    it("does not open a quoted span in query text", function()
        local r = qf.parse(schema, 'say "hi there')
        assert.is_nil(r.error)
        assert.are.equal('say "hi there', r.query)
        assert.are.same({}, r.flags)
    end)

    it("keeps a backslash-quote outside a quoted value literal", function()
        local r = qf.parse(schema, 'path:foo\\"bar')
        assert.are.equal('foo\\"bar', r.flags.path)
        assert.are.equal("", r.query)
    end)

    it("continues the value with text after the closing quote", function()
        local r = qf.parse(schema, 'path:"foo bar"baz')
        assert.is_nil(r.error)
        assert.are.equal("foo barbaz", r.flags.path)
        assert.are.equal("", r.query)
    end)

    it("accepts a quoted value ending the token", function()
        local r = qf.parse(schema, 'path:"foo bar" baz')
        assert.is_nil(r.error)
        assert.are.equal("foo bar", r.flags.path)
        assert.are.equal("baz", r.query)
    end)

    it("reports an error on an unterminated value quote", function()
        local r = qf.parse(schema, 'path:"foo ba')
        -- an unclosed quote is a malformed query: report it instead of guessing.
        assert.is_truthy(r.error)
        assert.are.same({}, r.flags)
        assert.are.equal("", r.query)
    end)

    it("collects quoted values for multi flags", function()
        local r = qf.parse(schema, 'kind:"a b" kind:c')
        assert.are.same({ "a b", "c" }, r.flags.kind)
    end)

    it("consumes a value flag with an empty value", function()
        local r = qf.parse(schema, "path: here")
        assert.is_nil(r.flags.path)
        assert.are.equal("here", r.query)
    end)

    it("keeps an empty value for an allow_empty flag", function()
        local r = qf.parse(schema, "repl: here")
        assert.are.equal("", r.flags.repl)
        assert.are.equal("here", r.query)
    end)

    it("keeps a quoted empty value for an allow_empty flag", function()
        local r = qf.parse(schema, 'repl:"" here')
        assert.are.equal("", r.flags.repl)
        assert.are.equal("here", r.query)
    end)
end)

describe("queryflags highlight", function()
    it("highlights flags wherever they appear", function()
        local hls = qf.highlight(schema, "hello is:fixed path:foo")
        local has_keyword = false
        local has_string  = false
        for _, h in ipairs(hls) do
            if h.hl == "Keyword" then has_keyword = true end
            if h.hl == "String" then has_string = true end
        end
        assert.is_true(has_keyword)
        assert.is_true(has_string)
    end)

    it("highlights the implicit query flag like any other value flag", function()
        local hls = qf.highlight(schema, 'query:"is:fixed"')
        local kinds = {}
        for _, h in ipairs(hls) do kinds[h.hl] = true end
        assert.is_true(kinds.Keyword)
        assert.is_true(kinds.String)
        assert.is_true(kinds.Delimiter)
    end)

    it("highlights the opening quote of an unterminated quote", function()
        local hls = qf.highlight(schema, 'path:"foo ba')
        local delimiters = {}
        for _, h in ipairs(hls) do
            if h.hl == "Delimiter" then table.insert(delimiters, h) end
        end
        assert.are.same({
            { start = 5, finish = 6, hl = "Delimiter" },
        }, delimiters)
    end)

    it("does not highlight quotes in query text", function()
        -- quotes only delimit a flag value; in query text they are literal.
        for _, h in ipairs(qf.highlight(schema, '"is:fixed"')) do
            assert.is_true(h.hl ~= "Delimiter")
        end
    end)

    it("highlights the quotes delimiting a value", function()
        local hls = qf.highlight(schema, 'path:"foo bar"')
        local delimiters = {}
        for _, h in ipairs(hls) do
            if h.hl == "Delimiter" then table.insert(delimiters, h) end
        end
        assert.are.same({
            { start = 5,  finish = 6,  hl = "Delimiter" },
            { start = 13, finish = 14, hl = "Delimiter" },
        }, delimiters)
    end)
end)

describe("queryflags completion", function()
    it("completes a partial is:<boolean> token", function()
        local comps = qf.get_completions(schema, "is:fi", 5)
        assert.not_nil(comps)
        local found = false
        for _, item in ipairs(comps.items) do
            if item.word == "is:fixed" then found = true end
        end
        assert.is_true(found)
    end)

    it("offers value-flag key prefixes", function()
        local comps = qf.get_completions(schema, "pa", 2)
        assert.not_nil(comps)
        local found = false
        for _, item in ipairs(comps.items) do
            if item.word == "path:" then found = true end
        end
        assert.is_true(found)
    end)

    it("offers the implicit query flag", function()
        local comps = qf.get_completions(schema, "qu", 2)
        assert.not_nil(comps)
        local found = false
        for _, item in ipairs(comps.items) do
            if item.word == "query:" then found = true end
        end
        assert.is_true(found)
    end)

    it("suppresses bare-word completions when auto is set", function()
        assert.is_nil(qf.get_completions(schema, "fi", 2, true))
    end)

    it("wraps a spaced value in quotes so it re-parses", function()
        local line  = "path:foo"
        local comps = qf.get_completions(schema, line, #line)
        assert.not_nil(comps)

        local spaced
        for _, item in ipairs(comps.items) do
            if item.abbr == "foo bar" then spaced = item end
        end
        assert.not_nil(spaced)
        assert.are.equal('path:"foo bar"', spaced.word)

        local r = qf.parse(schema, spaced.word)
        assert.are.equal("foo bar", r.flags.path)
    end)

    it("offers value completions while inside an open quote", function()
        local line  = 'path:"foo '
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
        local line  = 'path:"f'
        local comps = qf.get_completions(schema, line, #line)
        assert.not_nil(comps)

        local plain
        for _, item in ipairs(comps.items) do
            if item.abbr == "foo" then plain = item end
        end
        assert.not_nil(plain)
        assert.are.equal('path:"foo"', plain.word)
        assert.are.equal("foo", qf.parse(schema, plain.word).flags.path)
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
        assert.are.same({ "tag:beta" }, words(sources, "tag:be"))
    end)

    it("merges static values with a dynamic complete source", function()
        local got = words(sources, "lang:")
        assert.is_true(vim.tbl_contains(got, "lang:lua"))
        assert.is_true(vim.tbl_contains(got, "lang:vim"))
        assert.is_true(vim.tbl_contains(got, "lang:rust"))
    end)

    it("does not error on an unknown getcompletion type", function()
        local schema = { { name = "x", type = "value", complete = "definitely_not_a_type" } }
        assert.has_no.errors(function() qf.get_completions(schema, "x:foo", 5) end)
    end)
end)
