local picker = require("ezpick.base.picker")

local schema = {
    { name = "dir",   type = "value", values = { "lua", "tests", "with space" } },
    { name = "fixed", type = "boolean" },
}

local buf

---Park the cursor at the end of `text`. Outside insert mode the cursor cannot sit
---past the last character, so a trailing space stands in for the room insert mode
---would have; nothing is parsed past the cursor, so it changes no answer.
---@param text string
---@return nil
local function set_prompt(text)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text .. " " })
    vim.api.nvim_win_set_cursor(0, { 1, #text })
end

---Put `line` in the prompt with the cursor at its end, as it would be mid-typing,
---then hand Vim's two completefunc calls the leader it would pass.
---@param line   string
---@param leader string  -- the text Vim cuts out from `startcol` to the cursor
---@return integer startcol -- 0-indexed
---@return string[] words
local function complete(line, leader)
    set_prompt(line)
    local startcol = picker._flag_completefunc(1, "") --[[@as integer]]

    -- Vim removes the leader from the buffer before asking for the candidates.
    assert.are.equal(leader, line:sub(startcol + 1))
    set_prompt(line:sub(1, startcol))

    local res = picker._flag_completefunc(0, leader)
    return startcol, vim.tbl_map(function(it) return it.word end, res.words)
end

describe("picker completefunc", function()
    before_each(function()
        buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_win_set_buf(0, buf)
        vim.b[buf].ezpick_completion = { flags = schema }
    end)

    it("completes flag names from a dashed word", function()
        local startcol, words = complete("--fi", "--fi")
        assert.are.equal(0, startcol)
        assert.are.same({ "--fixed" }, words)
    end)

    it("completes a value from the whole line, not from the leader alone", function()
        -- The leader "l" is a bare word on its own; only the "--dir " before it
        -- makes it a value. Parsing the leader in isolation offered flags here.
        local startcol, words = complete("--dir l", "l")
        assert.are.equal(6, startcol)
        assert.are.same({ "lua" }, words)
    end)

    it("offers values in the empty slot after a value flag", function()
        local _, words = complete("--dir ", "")
        assert.is_true(vim.tbl_contains(words, "lua"))
        assert.is_true(vim.tbl_contains(words, "tests"))
    end)

    it("keeps a query word from reaching the flag list", function()
        -- A bare word in the query is text, not a flag being typed, so there is
        -- nothing to complete: -3 cancels silently and leaves completion mode,
        -- which is why this one cannot go through `complete`.
        set_prompt("hello --fixed wor")
        assert.are.equal(-3, picker._flag_completefunc(1, ""))

        -- And should Vim ask anyway, the candidate list stays empty.
        set_prompt("hello --fixed ")
        assert.are.same({}, picker._flag_completefunc(0, "wor").words)
    end)

    it("matches a quoted candidate against an unquoted leader", function()
        local _, words = complete("--dir with", "with")
        assert.are.same({ '"with space"' }, words)
    end)

    it("asks to be called again on every keystroke", function()
        set_prompt("")
        -- Without `refresh` Vim filters one frozen candidate list, so a value
        -- can never be narrowed or a path descended into.
        assert.are.equal("always", picker._flag_completefunc(0, "").refresh)
    end)
end)
