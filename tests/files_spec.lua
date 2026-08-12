local files = require("ezpick.pickers.files")

local resolve_case         = files._resolve_case
local do_match             = files._do_match
local resolve_mode         = files._resolve_mode
local resolve_case_flag    = files._resolve_case_flag
local normalize_extensions = files._normalize_extensions
local match_extension      = files._match_extension
local expand_exclude_globs = files._expand_exclude_globs

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

describe("fd-style flag aliases", function()
    it("reads --glob / --fixed-strings as modes, with --mode winning", function()
        assert.equals("fuzzy", resolve_mode({}))
        assert.equals("glob", resolve_mode({ glob = true }))
        assert.equals("fixed", resolve_mode({ ["fixed-strings"] = true }))
        assert.equals("fixed", resolve_mode({ mode = "fixed", glob = true }))
    end)

    it("reads --case-sensitive / --ignore-case as cases, with --case winning", function()
        assert.is_nil(resolve_case_flag({}))
        assert.equals("on", resolve_case_flag({ ["case-sensitive"] = true }))
        assert.equals("off", resolve_case_flag({ ["ignore-case"] = true }))
        assert.equals("smart", resolve_case_flag({ case = "smart", ["ignore-case"] = true }))
    end)
end)

describe("extension filter", function()
    it("normalizes away the leading dot and case", function()
        assert.same({ "lua" }, normalize_extensions({ ".LUA" }))
        assert.same({ "lua", "md" }, normalize_extensions({ "lua", "md" }))
        assert.same({ "lua" }, normalize_extensions("lua"))
        assert.is_nil(normalize_extensions({ ".", "" }))
        assert.is_nil(normalize_extensions(nil))
    end)

    it("passes everything when unset", function()
        assert.is_true(match_extension("foo.lua", nil))
    end)

    it("matches the last extension, case-insensitively", function()
        assert.is_true(match_extension("foo.LUA", { "lua" }))
        assert.is_true(match_extension("foo.spec.lua", { "lua" }))
        assert.is_false(match_extension("foo.luac", { "lua" }))
        assert.is_false(match_extension("Makefile", { "lua" }))
    end)
end)

describe("exclude globs", function()
    it("makes a bare glob match at any depth", function()
        assert.same({ "node_modules", "**/node_modules" }, expand_exclude_globs({ "node_modules" }))
        assert.same({ "*.min.js", "**/*.min.js" }, expand_exclude_globs("*.min.js"))
    end)

    it("leaves a path-shaped glob anchored at the root", function()
        assert.same({ "src/*.lua" }, expand_exclude_globs({ "src/*.lua" }))
    end)

    it("drops empties", function()
        assert.is_nil(expand_exclude_globs({ "" }))
        assert.is_nil(expand_exclude_globs(nil))
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
