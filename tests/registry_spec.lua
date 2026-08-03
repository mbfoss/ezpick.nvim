local registry = require("ezpick.registry")

-- Sources are wired into the registry as functions, so a typo in a module path
-- or a renamed spec builder only shows up when that source is first opened.
-- Building every one of them here keeps that failure in the test suite instead.

local FETCH_OPTS = { list_width = 60, list_height = 20 }

describe("registry", function()
    it("builds every registered source", function()
        for _, name in ipairs(registry.keys()) do
            -- A source with nothing to show (no marks set, an empty quickfix
            -- list) legitimately returns nil; an error does not.
            assert.has_no.errors(function() registry.get(name) end, name)
        end
    end)

    it("runs the finder of every synchronous source", function()
        for _, name in ipairs(registry.keys()) do
            local spec = registry.get(name)
            if spec and not spec.setup then
                assert.has_no.errors(function()
                    spec.finder("", {}, FETCH_OPTS, function() end)
                    spec.finder("e", {}, FETCH_OPTS, function() end)
                end, name)
            end
        end
    end)
end)

describe("ranking", function()
    local rank_items  = require("ezpick.base.picker")._rank_items
    local match_label = require("ezpick.base.pickertools").match_label

    ---@param items table[]
    ---@return string[]
    local function names_of(items)
        return vim.tbl_map(function(item) return item.data.name end, items)
    end

    ---@param spec table<string, number?> name -> score, as a list of pairs
    ---@return table[]
    local function items_of(spec)
        local items = {}
        for _, pair in ipairs(spec) do
            items[#items + 1] = { data = { name = pair[1] }, score = pair[2] }
        end
        return items
    end

    it("leaves a wholly unscored list in source order", function()
        local items = items_of({ { "zebra" }, { "alpha" }, { "mango" } })
        assert.same({ "zebra", "alpha", "mango" }, names_of(rank_items(items)))
    end)

    it("sorts by score, best first", function()
        local items = items_of({ { "low", 1 }, { "high", 30 }, { "mid", 10 } })
        assert.same({ "high", "mid", "low" }, names_of(rank_items(items)))
    end)

    it("keeps equal scores in source order", function()
        -- Enough items that an unstable sort would almost certainly permute
        -- them: table.sort still swaps while partitioning all-equal input.
        local spec = {}
        for i = 1, 64 do spec[i] = { ("item%02d"):format(i), 100 } end

        local expected = names_of(items_of(spec))
        assert.same(expected, names_of(rank_items(items_of(spec))))
    end)

    it("sorts unscored items after scored ones without erroring on nil", function()
        local items = items_of({ { "none_a" }, { "scored_low", 1 }, { "none_b" }, { "scored_high", 9 } })
        assert.same({ "scored_high", "scored_low", "none_a", "none_b" }, names_of(rank_items(items)))
    end)

    it("ranks nothing for an empty query, because match_label scores nothing", function()
        assert.is_nil(match_label("anything", "").score)
        assert.is_number(match_label("anything", "a").score)
    end)
end)

describe("buffer_lines", function()
    it("lists the non-blank lines of the current buffer, numbered", function()
        local bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "alpha", "", "   ", "beta" })
        vim.api.nvim_win_set_buf(0, bufnr)

        local spec = require("ezpick.pickers.lines").spec({ bufnr = bufnr })
        local items
        spec.finder("", {}, FETCH_OPTS, function(new_items) items = new_items end)

        assert.equals(2, #items)
        assert.equals(1, items[1].data.lnum)
        assert.equals(4, items[2].data.lnum)
        assert.equals(bufnr, items[1].data.bufnr)

        spec.finder("beta", {}, FETCH_OPTS, function(new_items) items = new_items end)
        assert.equals(1, #items)
        assert.equals(4, items[1].data.lnum)
    end)
end)

describe("registers", function()
    it("skips empty registers unless --empty is set", function()
        vim.fn.setreg("q", "")
        vim.fn.setreg("z", "picked up")

        local spec = require("ezpick.pickers.registers").spec()

        local items
        spec.finder("picked", {}, FETCH_OPTS, function(new_items) items = new_items end)
        assert.equals(1, #items)
        assert.same({ "picked up" }, items[1].data.lines)

        local all, listed = nil, nil
        spec.finder("", { empty = true }, FETCH_OPTS, function(new_items) all = new_items end)
        spec.finder("", {}, FETCH_OPTS, function(new_items) listed = new_items end)
        assert.is_true(#all > #listed)
    end)

    it("renders multi-line contents on a single row", function()
        vim.fn.setreg("z", "one\ntwo", "V")

        local spec = require("ezpick.pickers.registers").spec()
        local items
        spec.finder("", {}, FETCH_OPTS, function(new_items) items = new_items end)

        local entry
        for _, item in ipairs(items) do
            if item.data.name == "z" then entry = item end
        end
        assert.is_not_nil(entry)
        assert.same({ "one", "two" }, entry.data.lines)
        for _, chunk in ipairs(entry.label_chunks) do
            assert.is_nil(chunk[1]:find("\n"))
        end
    end)
end)

describe("marks", function()
    it("separates buffer-local marks from global ones", function()
        local file = vim.fn.tempname() .. ".txt"
        vim.fn.writefile({ "first", "second", "third" }, file)
        vim.cmd("edit " .. vim.fn.fnameescape(file))
        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        vim.cmd("normal! ma")
        vim.api.nvim_win_set_cursor(0, { 3, 0 })
        vim.cmd("normal! mZ")

        local spec = require("ezpick.pickers.marks").spec()

        local locals, globals
        spec.finder("", { buffer = true }, FETCH_OPTS, function(items) locals = items end)
        spec.finder("", { global = true }, FETCH_OPTS, function(items) globals = items end)

        local function has_line(items, lnum)
            for _, item in ipairs(items) do
                if item.data.lnum == lnum then return true end
            end
            return false
        end

        assert.is_true(has_line(locals, 2))
        assert.is_true(has_line(globals, 3))
        assert.is_false(has_line(globals, 2))

        vim.cmd("delmarks! | delmarks Z")
        vim.fn.delete(file)
    end)
end)

describe("colorschemes", function()
    ---@param spec ezpick.PickerSpec
    ---@param name string
    local function preview(spec, name)
        spec.previewer({ name = name }, { viewport_width = 60, viewport_height = 20 }, function() end)
    end

    it("applies while previewing, restores when dismissed, keeps the choice on confirm", function()
        vim.cmd("colorscheme habamax")
        local original = vim.g.colors_name

        local spec = require("ezpick.pickers.colorschemes").spec()

        preview(spec, "blue")
        assert.equals("blue", vim.g.colors_name)
        -- `:colorscheme` runs `:highlight clear`, so the picker's own groups have
        -- to be put back for the list to stay readable.
        assert.is_true(next(vim.api.nvim_get_hl(0, { name = "EzPickMatch" })) ~= nil)

        spec.on_confirm(nil)
        assert.equals(original, vim.g.colors_name)

        preview(spec, "blue")
        spec.on_confirm({ name = "blue" })
        assert.equals("blue", vim.g.colors_name)

        vim.cmd("colorscheme " .. original)
    end)

    it("reports a broken colorscheme in the preview instead of throwing", function()
        local spec = require("ezpick.pickers.colorschemes").spec()

        local preview_data
        assert.has_no.errors(function()
            spec.previewer({ name = "no_such_colorscheme" }, { viewport_width = 60, viewport_height = 20 },
                function(data) preview_data = data end)
        end)
        assert.is_not_nil(preview_data.error_msg)
    end)
end)

describe("history", function()
    it("lists the newest entry first", function()
        vim.fn.histadd("cmd", "Pick files")
        vim.fn.histadd("cmd", "Pick buffers")

        local spec = require("ezpick.pickers.history").spec({ kind = "cmd" })
        local items
        spec.finder("", {}, FETCH_OPTS, function(new_items) items = new_items end)

        assert.equals("Pick buffers", items[1].data.entry)
    end)
end)
