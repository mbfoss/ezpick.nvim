local files = require("ezpick.pickers.files")

local resolve_case = files._resolve_case
local do_match     = files._do_match

describe("resolve_case", function()
    it("honors explicit on/off", function()
        assert.is_true(resolve_case("on", "foo"))
        assert.is_false(resolve_case("off", "FOO"))
    end)

    it("smart-cases on uppercase for literal text", function()
        assert.is_false(resolve_case("smart", "foo"))
        assert.is_true(resolve_case("smart", "Foo"))
        assert.is_false(resolve_case(nil, "foo"))
    end)
end)

describe("do_match (fuzzy)", function()
    it("matches case-insensitively then gates on case_sensitive", function()
        assert.not_nil(do_match("README.md", "README.md", "rdme", "fuzzy", false))
        assert.not_nil(do_match("FooBar", "FooBar", "foo", "fuzzy", false))
        assert.is_nil(do_match("FooBar", "FooBar", "foo", "fuzzy", true))
        assert.not_nil(do_match("FooBar", "FooBar", "Foo", "fuzzy", true))
    end)

    it("defaults to fuzzy when mode is nil", function()
        assert.not_nil(do_match("README.md", "README.md", "rdme", nil, false))
    end)
end)

describe("do_match (fixed)", function()
    it("requires a contiguous substring, not a subsequence", function()
        assert.not_nil(do_match("README.md", "README.md", "adme", "fixed", false))
        assert.is_nil(do_match("README.md", "README.md", "rdme", "fixed", false))
    end)

    it("matches case-insensitively then gates on case_sensitive", function()
        assert.not_nil(do_match("FooBar", "FooBar", "oob", "fixed", false))
        assert.is_nil(do_match("FooBar", "FooBar", "oob", "fixed", true))
        assert.not_nil(do_match("FooBar", "FooBar", "ooB", "fixed", true))
    end)
end)

describe("do_match (glob)", function()
    it("matches the relative path with rg-style globs", function()
        assert.not_nil(do_match("foo.lua", "src/foo.lua", "*.lua", "glob", false))
        assert.is_nil(do_match("foo.txt", "src/foo.txt", "*.lua", "glob", false))
        assert.not_nil(do_match("foo.lua", "src/foo.lua", "src/*.lua", "glob", false))
        assert.is_nil(do_match("foo.lua", "lib/foo.lua", "src/*.lua", "glob", false))
    end)

    it("honors case sensitivity", function()
        assert.not_nil(do_match("Foo.LUA", "Foo.LUA", "*.lua", "glob", false))
        assert.is_nil(do_match("Foo.LUA", "Foo.LUA", "*.lua", "glob", true))
    end)

    it("takes a whitespace-separated sequence of globs", function()
        local q = "*.lua *.txt"
        assert.not_nil(do_match("foo.lua", "src/foo.lua", q, "glob", false))
        assert.not_nil(do_match("foo.txt", "src/foo.txt", q, "glob", false))
        assert.is_nil(do_match("foo.md", "src/foo.md", q, "glob", false))
    end)

    it("lets a later negation exclude, like rg --glob", function()
        local q = "*.lua  !*_spec.lua"
        assert.not_nil(do_match("foo.lua", "lua/foo.lua", q, "glob", false))
        assert.is_nil(do_match("foo_spec.lua", "tests/foo_spec.lua", q, "glob", false))
    end)
end)
