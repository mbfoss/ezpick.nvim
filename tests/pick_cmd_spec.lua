local ezpick = require("ezpick")
local picker = require("ezpick.base.picker")

local seen = {}

local source = ezpick.register("pick_cmd_spec", {
    prompt     = "Args",
    flags      = {
        { name = "dir",    type = "value" },
        { name = "hidden", type = "boolean" },
    },
    finder     = function(query, flags, _, cb)
        seen = { query = query, flags = flags }
        cb({})
    end,
    on_confirm = function() end,
})

describe(":Ezpick arguments", function()
    after_each(function() vim.cmd("silent! close!") end)

    ---Run `:Ezpick` and report the two prompt sections it opened on.
    ---@param args string
    ---@return string flag_text, string query
    local function run(args)
        vim.cmd(("Ezpick %s %s"):format(source, args))
        vim.wait(100)
        local p = assert(picker._active())
        return p.flag_text, p.query_text
    end

    it("takes one flag per -f", function()
        local flag_text = run("-f hidden -f dir=lua")
        assert.are.equal("hidden dir=lua", flag_text)
        assert.is_true(seen.flags.hidden)
        assert.are.equal("lua", seen.flags.dir)
    end)

    it("keeps an escaped space in a flag value", function()
        -- The backslash reaches the flags line as written, so the space it
        -- escapes is part of the value rather than the gap between two flags.
        assert.are.equal("dir=my\\ src", run("-f dir=my\\ src"))
        assert.are.equal("my src", seen.flags.dir)
    end)

    it("takes the rest of the line from the first non-flag as the query", function()
        local flag_text, query = run("-f hidden fn%s+%w+ two")
        assert.are.equal("hidden", flag_text)
        assert.are.equal("fn%s+%w+ two", query)
        assert.are.equal("fn%s+%w+ two", seen.query)
    end)

    it("needs no quoting in the query, flag-shaped or not", function()
        assert.are.equal("--hidden -x", select(2, run("--hidden -x")))
    end)

    it("opens on nothing at all with no arguments", function()
        vim.cmd("Ezpick " .. source)
        vim.wait(100)
        local p = assert(picker._active())
        assert.are.equal("", p.flag_text)
        assert.are.equal("", p.query_text)
    end)

    it("opens the query at a -- and drops it", function()
        local flag_text, query = run("-f hidden -- -f dir=x")
        assert.are.equal("hidden", flag_text)
        assert.are.equal("-f dir=x", query)
        assert.are.equal("-f dir=x", seen.query)
        assert.is_true(seen.flags.hidden)
    end)

    it("keeps a second -- in the query", function()
        assert.are.equal("-- one", select(2, run("-- -- one")))
    end)

    it("opens on nothing at all at a trailing --", function()
        local flag_text, query = run("-f hidden --")
        assert.are.equal("hidden", flag_text)
        assert.are.equal("", query)
    end)

    it("completes -f, then the source's flags behind it", function()
        local cmdline = require("ezpick.cmdline")
        ---@param line string
        ---@return string[]
        local function complete(line)
            return cmdline.complete(line:match("(%S*)$"), line, #line)
        end

        local line = ("Ezpick %s "):format(source)
        assert.are.same({ "-f", "--" }, complete(line))
        assert.are.same({ "--" }, complete(line .. "--"))
        assert.are.same({ "dir=", "hidden" }, complete(line .. "-f "))
        assert.are.same({ "hidden" }, complete(line .. "-f hid"))
        assert.are.same({ "hidden" }, complete(line .. "-f dir=lua -f hid"))
        -- Past the first non-flag the line is query: free text, nothing to add.
        assert.are.same({}, complete(line .. "some query hid"))
        assert.are.same({}, complete(line .. "-- hid"))
    end)

    it("reports a -f without a flag behind it", function()
        local warned
        local notify = vim.notify
        ---@diagnostic disable-next-line: duplicate-set-field
        vim.notify = function(msg) warned = msg end
        vim.cmd(("Ezpick %s -f hidden -f"):format(source))
        vim.notify = notify
        assert.is_truthy(warned:find("-f needs a flag", 1, true))
    end)
end)
