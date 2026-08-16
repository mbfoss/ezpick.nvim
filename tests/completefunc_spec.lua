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

    it("matches an escaped candidate against an unescaped leader", function()
        local _, words = complete("--dir with", "with")
        assert.are.same({ "with\\ space" }, words)
    end)

    it("matches an escaped candidate against a leader written with escapes", function()
        -- The leader is the whole value token, escapes and all, and a '\' still
        -- waiting on its character must not drop the candidate it is leading to.
        assert.are.same({ "with\\ space" }, select(2, complete("--dir with\\ sp", "with\\ sp")))
        assert.are.same({ "with\\ space" }, select(2, complete("--dir with\\", "with\\")))
    end)

    it("asks to be called again on every keystroke", function()
        set_prompt("")
        -- Without `refresh` Vim filters one frozen candidate list, so a value
        -- can never be narrowed or a path descended into.
        assert.are.equal("always", picker._flag_completefunc(0, "").refresh)
    end)
end)

describe("picker query hints", function()
    ---Open a picker whose finder records what it was asked for, type `text` into
    ---its prompt, and report back. `cursor` defaults to the end of `text`, where
    ---it would sit having just been typed. `moved_to` moves it afterwards
    ---without touching the text, as arrowing away from what was typed does.
    ---@param text     string
    ---@param cursor   integer?  -- 0-indexed byte column
    ---@param moved_to integer|integer[]|nil  -- 0-indexed column(s) to move to, in turn, once typed
    ---@return string? query, table? flags, string? hint, integer marked, boolean counted
    ---`marked`: spans underlined as a problem. `counted`: the position counter,
    ---which shares the hint's corner, is the one showing there.
    local function type_query(text, cursor, moved_to)
        local seen_query, seen_flags
        picker.open({
            prompt = "Hints",
            flags  = {
                { name = "dir",    type = "value" },
                { name = "case",   type = "value", strict = true, values = { "smart", "on", "off" } },
                { name = "hidden", type = "boolean" },
            },
            finder = function(query, flags, _, cb)
                seen_query, seen_flags = query, flags
                cb({ { label_chunks = { { "item" } }, data = {} } })
            end,
            on_confirm = function() end,
        }, function() end)

        local pbuf, pwin
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_valid(b) and (vim.bo[b].omnifunc or ""):find("ezpick", 1, true) then
                pbuf = b
            end
        end
        assert.not_nil(pbuf)
        for _, w in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_get_buf(w) == pbuf then pwin = w end
        end
        assert.not_nil(pwin)

        -- Insert mode is where this is typed, and there the cursor may sit one
        -- past the last character; without `onemore` normal mode clamps it back
        -- onto the text and every hint looks like one being typed.
        vim.wo[pwin].virtualedit = "onemore"

        vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, { text })
        vim.api.nvim_win_set_cursor(pwin, { 1, cursor or #text })
        vim.api.nvim_exec_autocmds("TextChanged", { buffer = pbuf })
        vim.wait(50)

        ---@type integer[]
        local moves = type(moved_to) == "table" and moved_to or { moved_to }
        for _, col in ipairs(moves) do
            vim.api.nvim_win_set_cursor(pwin, { 1, col })
            vim.api.nvim_exec_autocmds("CursorMoved", { buffer = pbuf })
            vim.wait(50)
        end

        -- The hint gets a virtual line under the query; the position counter
        -- rides on the rule below it, at the right end of the list float's winbar.
        local hint
        local marked = 0
        local counted = false
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(pbuf, -1, 0, -1, { details = true })) do
            -- A rule is drawn above the words, so the message is the chunk
            -- carrying the hint's own highlight rather than the first one.
            for _, vline in ipairs(m[4] and m[4].virt_lines or {}) do
                for _, chunk in ipairs(vline) do
                    if chunk[2] == "DiagnosticVirtualTextWarn" then hint = vim.trim(chunk[1]) end
                end
            end
            if m[4] and m[4].hl_group == "DiagnosticUnderlineWarn" then marked = marked + 1 end
        end
        -- Any float but the prompt's: the counter is the list window's winbar,
        -- and the list is the only other one this picker opens.
        for _, w in ipairs(vim.api.nvim_list_wins()) do
            if w ~= pwin and vim.wo[w].winbar:find("%d+/%d+") then counted = true end
        end

        return seen_query, seen_flags, hint, marked, counted
    end

    after_each(function() vim.cmd("silent! close!") end)

    it("searches for a backslash waiting on the space it will escape", function()
        -- The moment between the '\' and the whitespace it is there to escape is
        -- not a mistake to report: the backslash stands for itself until the
        -- next character says otherwise, and the list keeps up either way.
        local query, flags, hint = type_query("--dir My\\")
        assert.are.equal("", query)
        assert.are.equal("My\\", flags.dir)
        assert.is_nil(hint)
    end)

    it("keeps complaining about a value slot the rest of the line has closed", function()
        -- Deleting the value from "--dir a --dir b" leaves the cursor in the gap,
        -- where the usual hold rule would read it as a value being typed. It is
        -- not: the flag after it stands where the value would go, so no amount of
        -- typing at the end fixes it, and going quiet would reward the deletion.
        local hint, marked = select(3, type_query("--dir --dir b", 6))
        assert.is_truthy(hint:find("needs a value", 1, true))
        assert.are.equal(1, marked)
    end)

    it("says nothing about a flag the cursor is still writing", function()
        -- Every one of these is a state on the way to a correct flag; nagging
        -- through them turns the prompt into a stream of complaints.
        assert.is_nil(select(3, type_query("--dir")))
        assert.is_nil(select(3, type_query("--dir ")))
        assert.is_nil(select(3, type_query("--case sm")))
    end)

    it("speaks up once the cursor leaves what it points at", function()
        assert.is_truthy(select(3, type_query("--case sm x")):find("smart|on|off", 1, true))
    end)

    it("speaks up on the cursor leaving alone, with nothing more typed", function()
        -- Held hints are chosen against where the cursor is, so moving away has
        -- to be reason enough to look again. Waiting on the next keystroke never
        -- comes for the line that is finished except for the mistake in it.
        assert.is_truthy(select(3, type_query("--case sm", nil, 0)):find("smart|on|off", 1, true))
        assert.is_truthy(select(3, type_query("--hiddn", nil, 0)):find("unknown option --hiddn", 1, true))
        assert.is_truthy(select(3, type_query("--dir", nil, 0)):find("needs a value", 1, true))
    end)

    it("hands the corner back to the position counter when the cursor returns", function()
        -- The two share one corner and the hint takes it; showing a hint has to
        -- put the count back on the way out, or it goes missing for good.
        assert.is_false(select(5, type_query("--case sm", nil, 0)))
        local hint, _, counted = select(3, type_query("--case sm", nil, { 0, 9 }))
        assert.is_nil(hint)
        assert.is_true(counted)
    end)

    it("searches for a typo'd flag and flags it as unknown", function()
        local query, _, hint = type_query("--hiddn x")
        assert.are.equal("--hiddn x", query)
        assert.is_truthy(hint:find("unknown option --hiddn", 1, true))
    end)

    it("leaves a flag written after the query entirely alone", function()
        -- It is a word in the search text like any other: unset as a flag, and
        -- neither underlined nor remarked upon.
        local query, flags, hint, marked = type_query("hello --hidden")
        assert.are.equal("hello --hidden", query)
        assert.is_nil(flags.hidden)
        assert.is_nil(hint)
        assert.are.equal(0, marked)
    end)

    it("marks a flag whose value another occurrence threw away", function()
        local _, flags, hint, marked = type_query("--dir a --dir b x")
        assert.are.equal("b", flags.dir)
        assert.is_truthy(hint:find("2 times", 1, true))
        assert.are.equal(2, marked)
    end)

    it("passes the query through byte for byte", function()
        local query = type_query("--hidden foo  bar ")
        assert.are.equal("foo  bar ", query)
    end)
end)
