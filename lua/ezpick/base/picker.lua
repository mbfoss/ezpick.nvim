local Spinner            = require("ezpick.util.Spinner")
local timer              = require("ezpick.util.timer")
local ui                 = require("ezpick.util.ui")
local floatwin           = require("ezpick.util.floatwin")
local layouts            = require("ezpick.base.layouts")
local queryflags         = require("ezpick.base.queryflags")
local pickertools        = require("ezpick.base.pickertools")
local tbl_new            = require("table.new")

---@mod ezpick.picker
---@brief Floating async picker with fuzzy filtering and optional preview.

local M                  = {}

local _NS_CURSOR         = vim.api.nvim_create_namespace("ezpick_PickerCursor")
local _NS_CONTENT        = vim.api.nvim_create_namespace("ezpick_PickerContent")
local _NS_PREVIEW        = vim.api.nvim_create_namespace("ezpick_PickerPreview")

-- Completion result carrying no candidates. `refresh = "always"` has to ride along
-- even on the empty answer, or Vim stops asking and the menu cannot come back as
-- the rest of the flag is typed.
local _EMPTY_COMPLETION  = { words = {}, refresh = "always" }

local _antiflicker_delay = 200
local _WINHL             = "NormalFloat:Normal,FloatBorder:Normal,FloatTitle:Title"

---@class ezpick.picker.ItemData
---@field filepath string?
---@field lnum number?
---@field col number?
---@field [string] any

---@class ezpick.Picker.Item
---@field label_chunks {[1]:string,[2]:string?}[]?
---@field virt_line? {[1]:string,[2]:string?}[] Single virtual line rendered below the entry.
---@field data ezpick.picker.ItemData
---@field score number? Match quality, as reported by `match_label`. Ranked descending; see `_rank_items`.

---@class ezpick.picker.ListItem
---@field label_chunks {[1]:string,[2]:string?}[]?
---@field virt_line? {[1]:string,[2]:string?}[]
---@field data ezpick.picker.ItemData

---@alias ezpick.Picker.Callback fun(data:ezpick.picker.ItemData?)

---@class ezpick.Picker.FetcherOpts
---@field list_width number
---@field list_height number
---@field virt_line_width number
---@field parsed ezpick.queryflags.ParseResult?
---@field data table? Setup data supplied by the picker spec.

---@class ezpick.Picker.QueryHistoryProvider
---@field load fun():string[]
---@field store fun(hist:string[])?

---@alias ezpick.Picker.Finder fun(query:string,flags:table,opts:ezpick.Picker.FetcherOpts,callback:fun(new_items:ezpick.Picker.Item[]?)):fun()?

---@class ezpick.Picker.AsyncPreviewOpts
---@field viewport_width number
---@field viewport_height number

---@alias ezpick.Picker.AsyncPreviewData {content:string|string[]|nil,filetype:string?,filepath:string?,pos?:{[1]:integer,[2]:integer},pos_end?:{[1]:integer,[2]:integer},error_msg:string?,bufnr:integer?}
---@alias ezpick.Picker.AsyncPreviewLoader fun(data:ezpick.picker.ItemData, opts:ezpick.Picker.AsyncPreviewOpts, callback:fun(preview:ezpick.Picker.AsyncPreviewData?)):fun()?

---@class ezpick.Picker.opts
---@field prompt string
---@field flags ezpick.queryflags.FlagDef[]?
---@field finder ezpick.Picker.Finder?
---@field enable_preview boolean?
---@field previewer ezpick.Picker.AsyncPreviewLoader?
---@field history_provider ezpick.Picker.QueryHistoryProvider?
---@field quickfix_formatter (fun(data:any):vim.quickfix.entry?)?
---@field layout ezpick.Picker.LayoutKind? Arrangement of list and preview (default "horizontal").
---@field width_ratio number? Fraction of the editor the whole picker spans.
---@field height_ratio number?
---@field list_wrap boolean?
---@field initial_query  string?
---@field initial_cursor (integer|fun(items:ezpick.Picker.Item[]):integer?)? Row to select on the first populated fetch, as a 1-based index into the ranked list or a function that finds one. Spent by that fetch; later queries start at the top.
---@field auto_complete_flags boolean? Auto-open flag completion while typing (default true).
---@field on_close fun(query:string, index:integer?)? Called when the picker closes, with the final raw prompt text and the highlighted item's 1-based list row.

---@class ezpick.Picker.Layout
---@field prompt_row number
---@field prompt_col number
---@field prompt_width number
---@field prompt_height number
---@field prompt_border string|table Border for the prompt float, as `nvim_open_win` takes it.
---@field list_row number
---@field list_col number
---@field list_width number
---@field list_height number
---@field list_border string|table Border for the list float; shares a frame with the prompt, so it draws no top edge.
---@field preview_row number
---@field preview_col number
---@field preview_width number
---@field preview_height number
---@field preview_border string|table Border for the preview float.


---Hints that describe an incomplete thing rather than a wrong one. Every flag
---passes through these states on the way to being written correctly, so they are
---held back until the cursor has moved off what they point at. The rest --- a
---flag given twice, a value on a switch --- are already settled mistakes and say
---so immediately, as does any hint `parse` itself marks `settled`: a kind that
---is usually mid-typing can still turn up in a state typing cannot get out of.
---
---`parse` reports everything it can see and holds nothing back, having no cursor
---to hold it against; this table and `_at_cursor` are the whole of that judgment.
---Marks the line under the query as a remark about the query rather than more of
---it. The trailing space is part of it: the two run together otherwise.
---@type string
local _HINT_ICON = "⚠ "

---@type table<ezpick.queryflags.HintKind, boolean>
local _HELD_WHILE_TYPING = {
	["missing-value"]  = true,
	["unclosed-quote"] = true,
	["unknown-flag"]   = true,
	["bad-value"]      = true,
}

---Whether the cursor is still in the span `hint` points at: it counts as inside
---while only whitespace separates the end of the span from the cursor, so the
---space after "--dir" is part of writing "--dir", not of having finished it.
---@param query  string
---@param hint   ezpick.queryflags.Hint
---@param cursor integer  -- 0-indexed byte column
---@return boolean
local function _at_cursor(query, hint, cursor)
	if cursor <= hint.start then return false end
	return not query:sub(hint.finish + 1, cursor):find("%S")
end

local function _show_help()
	local help_text = [[
`<CR>`        Confirm
`<C-c>`       Close picker
`<Esc>`       Leave insert mode, then close picker
`<C-n>`       Next item
`<C-p>`       Previous item
`<C-d>`       Scroll down half page
`<C-u>`       Scroll up half page
`<C-j>`       Next search history entry
`<C-k>`       Previous search history entry
`j` / `k`     Next / previous history entry (normal mode)
`<C-Space>`   Complete flags
`<C-q>`       Send results to quickfix list
`<C-r><C-w>`  Insert original <cword>
`g?`          Show help
]]
	floatwin.open(help_text, {
		title = "Picker",
		is_markdown = true,
	})
end

---@type fun(v:number,min:number,max:number):number
local function _clamp(v, min, max)
	return math.max(min, math.min(max, v))
end

local function _key_opts_of(buf)
	assert(buf and vim.api.nvim_buf_is_valid(buf))
	return { buffer = buf, nowait = true, silent = true }
end

---@param modifiable boolean
---@param on_delete fun()
---@param bufhidden 'hide'|'wipe'?
local function _create_buffer(modifiable, on_delete, bufhidden)
	return ui.create_scratch_buffer(false, {
			modifiable = modifiable,
			spelloptions = "noplainbuffer",
			bufhidden = bufhidden,
		},
		on_delete)
end

---@param win integer
---@param lnum integer
---@param col integer?
local function _place_preview_cursor(win, lnum, col)
	vim.api.nvim_win_call(win, function()
		if not col or col < 0 then col = 0 end
		local ok = pcall(vim.api.nvim_win_set_cursor, win, { lnum, col })
		if not ok then
			ok = pcall(vim.api.nvim_win_set_cursor, win, { lnum, 0 })
		end
		vim.cmd("normal! zz")
	end)
end

---@param win integer
---@param buf integer
---@param pos {[1]:integer,[2]:integer}?
---@param pos_end {[1]:integer,[2]:integer}?
local function _apply_preview_pos(win, buf, pos, pos_end)
	vim.api.nvim_buf_clear_namespace(buf, _NS_PREVIEW, 0, -1)
	if not pos then
		vim.api.nvim_win_set_cursor(win, { 1, 0 })
		return
	end
	local lnum = _clamp(pos[1], 1, vim.api.nvim_buf_line_count(buf))
	_place_preview_cursor(win, lnum, pos[2])
	if pos_end then
		vim.api.nvim_buf_set_extmark(buf, _NS_PREVIEW, lnum - 1, pos[2], {
			end_row  = _clamp(pos_end[1], lnum, vim.api.nvim_buf_line_count(buf) + 1) - 1,
			end_col  = pos_end[2],
			hl_group = "Visual",
			hl_eol   = true,
			hl_mode  = "blend",
		})
	else
		vim.api.nvim_buf_set_extmark(buf, _NS_PREVIEW, lnum - 1, 0, {
			end_row  = lnum,
			hl_group = "Visual",
			hl_eol   = true,
			hl_mode  = "blend",
		})
	end
end

---@param msg string
---@param width number
---@param height number
---@return string[]
local function _center_for_previewer(msg, width, height)
	-- Display cells, not bytes: an error message naming a non-ASCII path would
	-- otherwise be pushed off centre by one column per multibyte character.
	local pad_left = math.max(0, math.floor((width - vim.fn.strdisplaywidth(msg)) / 2))
	local centered = string.rep(" ", pad_left) .. msg
	-- `height` is the content area, and the message is one of its rows.
	local pad_top = math.max(0, math.floor((height - 1) / 2))

	local lines = {}
	for _ = 1, pad_top do
		table.insert(lines, "")
	end
	table.insert(lines, centered)
	return lines
end


local _active_picker = nil

---@param a table
---@param b table
---@return boolean
local function _flags_equal(a, b)
	for k, v in pairs(a) do
		if type(v) == "table" then
			if type(b[k]) ~= "table" or #v ~= #b[k] then return false end
			for i, x in ipairs(v) do if b[k][i] ~= x then return false end end
		elseif b[k] ~= v then
			return false
		end
	end
	for k in pairs(b) do if a[k] == nil then return false end end
	return true
end

---@param entry string
---@return string
local function _decode_history(entry)
	-- Older entries were stored as JSON `{q=..,f=..}`; decode them for
	-- compatibility. Only an object actually carrying `q` is one of those: a
	-- query that merely happens to parse as JSON -- `[1,2]`, `{}` -- is still
	-- just a query, and must come back verbatim rather than as "".
	local ok, t = pcall(vim.json.decode, entry)
	if ok and type(t) == "table" and type(t.q) == "string" then
		return t.q
	end
	return entry
end

--- Rank fetched items by match quality, best first.
---
--- A source opts in by handing back the score `match_label` gave it; whatever it
--- leaves unscored keeps the order the source produced. `match_label` reports no
--- score for an empty query, so an unfiltered list always reads in its source's
--- own order — references by file and position, buffers by number, the jumplist
--- by recency — and only ranks once there is a query to rank by.
---
--- The sort has to be stable, and `table.sort` is not: equal scores are the
--- common case (glob matches all score 0), and without the index tiebreak those
--- rows would reshuffle on every keystroke.
---
--- Sorts `items` in place and returns it.
---@param items ezpick.Picker.Item[]
---@return ezpick.Picker.Item[]
local function _rank_items(items)
	local n = #items
	if n < 2 then return items end

	-- Answered before the index map is built. An unscored list is what an empty
	-- query yields, which is also the longest list a source ever hands over, so
	-- it must not pay to fill in a map it is about to walk away from.
	local scored = false
	for i = 1, n do
		if items[i].score ~= nil then
			scored = true
			break
		end
	end
	if not scored then return items end

	local order = tbl_new(0, n)
	for i = 1, n do
		order[items[i]] = i
	end

	table.sort(items, function(a, b)
		local sa, sb = a.score, b.score
		if sa ~= sb then
			if sa == nil then return false end
			if sb == nil then return true end
			return sa > sb
		end
		return order[a] < order[b]
	end)
	return items
end

---Every list label is written behind this prefix, which leaves the room the
---cursor marker is drawn in.
local _LIST_PREFIX = "  "

---A label occupies one buffer line, and `nvim_buf_set_lines` refuses a string
---with a newline in it. The swap is byte for byte, so the byte columns the
---highlight chunks are placed at are unaffected by it.
---@param text string
---@return string
local function _one_line(text)
	if text:find("\n", 1, true) then return (text:gsub("\n", " ")) end
	return text
end

---@param item ezpick.picker.ListItem|ezpick.Picker.Item
---@return string
local function _item_label(item)
	if not item.label_chunks then return "" end
	local parts = {}
	for _, chunk in ipairs(item.label_chunks) do
		table.insert(parts, chunk[1] or "")
	end
	return _one_line(table.concat(parts))
end

---@class ezpick.util.Picker
---@field new fun(self: ezpick.util.Picker,opts:ezpick.Picker.opts,callback:ezpick.Picker.Callback) : ezpick.util.Picker
---@field opts ezpick.Picker.opts
---@field callback ezpick.Picker.Callback
---@field preview_enabled boolean
---@field layout ezpick.Picker.Layout
---@field pbuf integer?
---@field lbuf integer?
---@field vbuf integer?
---@field pwin integer?
---@field lwin integer?
---@field vwin integer?
---@field pwin_augroup number?
---@field spinner ezpick.util.Spinner?
---@field closed boolean
---@field list_items ezpick.picker.ListItem[]
---@field async_fetch_context number
---@field async_fetch_cancel fun()?
---@field async_preview_context number
---@field async_preview_cancel fun()?
---@field _preview_external_buf integer?
---@field preview_timer table?
---@field query_text string
---@field original_cword string
---@field history string[]
---@field history_idx number
---@field history_saved_query string?
---@field _set_init_cursor boolean
---@field _last_clean_query string?
---@field _last_flags table?
---@field _suppress_autocomplete boolean?
---@field _query_hint string? -- message of the query hint currently shown in the prompt
---@field _hint_col integer? -- prompt cursor column the shown hints were chosen for
---@field _spinner_frame string? -- spinner frame currently drawn on the prompt line, nil when idle
---@field _prompt_wrapped integer -- screen lines the prompt took when the picker was last laid out
---@field _in_relayout boolean? -- set while `relayout` runs, to keep the renderers it calls from calling it back
local Picker = {}
Picker.__index = Picker

function Picker:new(...)
	local obj = setmetatable({}, self)
	if obj.init then obj:init(...) end
	return obj
end

---@param opts ezpick.Picker.opts
---@param callback ezpick.Picker.Callback
function Picker:init(opts, callback)
	vim.validate("opts", opts, "table")
	vim.validate("callback", callback, "function")

	self.opts                  = vim.deepcopy(opts)
	self.opts.flags            = self.opts.flags or {}
	self.callback              = callback

	self.preview_enabled       = opts.enable_preview == true

	self.list_items            = {} ---@type ezpick.picker.ListItem[]

	self._prompt_wrapped       = 1

	self.closed                = false

	self.async_fetch_context   = 0
	self.async_fetch_cancel    = nil

	self._set_init_cursor      = true

	self.async_preview_context = 0
	self.async_preview_cancel  = nil

	self.spinner               = nil
	self._spinner_frame        = nil

	self.query_text            = ""

	self.history               = {}
	self.history_idx           = 0
	self.history_saved_query   = nil

	if self.opts.history_provider then
		self.history = self.opts.history_provider.load() or {}
		self.history_idx = #self.history + 1
	end

	-- Load-bearing pcall: `expand` throws E348 when there is no word under the
	-- cursor, which is the ordinary state of a blank line. It only returns a
	-- list when asked to, which this is not, hence the cast.
	local ok, cword     = pcall(vim.fn.expand, "<cword>")
	self.original_cword = (ok and cword or "") --[[@as string]]

	_active_picker      = self

	self:setup_ui()
	self:setup_input()

	assert(self.pwin)
	vim.api.nvim_set_current_win(self.pwin)

	if type(opts.initial_query) == "string" and opts.initial_query ~= "" then
		self:set_prompt_text(opts.initial_query .. " " --[[@as string]])
	else
		self:run_fetch()
	end
	vim.schedule(function()
		-- Anything closing the picker within the same tick leaves the focus on a
		-- normal buffer, and starting insert there is the user's file, not a prompt.
		if self.closed then return end
		vim.cmd("startinsert!")
	end)
end

function Picker:apply_prompt()
	if self.closed then return end
	-- A multi-line paste is flattened onto the one line the prompt has
	local nlines = vim.api.nvim_buf_line_count(self.pbuf)
	local lines = vim.api.nvim_buf_get_lines(self.pbuf, 0, -1, false)
	local raw = lines[1] or ""
	local text = raw:gsub("[%c]", "")
	if nlines > 1 or text ~= raw then
		local col = vim.api.nvim_win_get_cursor(self.pwin)[2]
		vim.api.nvim_buf_set_lines(self.pbuf, 0, -1, false, { text })
		vim.api.nvim_win_set_cursor(self.pwin, { 1, math.min(col, #text) })
	end
	-- Before the fetch: the query just typed may have wrapped onto another line,
	-- and the list is laid out again to make room for it. `render_prompt_highlight`
	-- syncs too, but it only runs when the query itself changed -- a line edited
	-- back to the same query can still have been rewrapped by the edit.
	self:_sync_prompt_height()

	if text ~= self.query_text then
		self.query_text = text
		self:render_prompt_highlight(text)
		self:run_fetch()
	end
end

--- Fire flag completion (the omnifunc, via <C-x><C-o>) while typing so the
--- menu appears without pressing <C-Space>. Only triggers inside an in-progress
--- flag (a dashed word, or a value slot after "--key"), never on query text.
---@return nil
function Picker:maybe_autocomplete()
	if self.closed or self.opts.auto_complete_flags == false then return end
	-- Skip while the menu is open (Vim filters it as you type) and just after
	-- accepting an item, so a chosen value does not immediately reopen its menu.
	if vim.fn.pumvisible() == 1 then return end
	if self._suppress_autocomplete then
		self._suppress_autocomplete = false
		return
	end

	local flags = self.opts.flags
	if not flags or #flags == 0 then return end

	local line = vim.api.nvim_get_current_line()
	local col  = vim.api.nvim_win_get_cursor(0)[2]
	if not queryflags.get_completions(flags, line, col, true) then return end

	vim.api.nvim_feedkeys(
		vim.api.nvim_replace_termcodes("<C-x><C-o>", true, false, true), "n", false
	)
end

---@return nil
function Picker:setup_ui()
	self:relayout()

	assert(self.pbuf ~= nil)
	-- Expose flag completion on the prompt buffer so <C-x><C-o>, <C-x><C-u>, or any
	-- completion engine on this buffer can drive it. The flag schema is stashed on the
	-- buffer once here; the function computes candidates live from it, needing no picker
	-- or module state.
	--
	-- The menu is driven through the *omnifunc*: while a menu is open Vim only keeps
	-- completing on characters `ins_compl_accept_char()` accepts, and for user-defined
	-- completion that is 'iskeyword' characters only. Flags are written with `-` and
	-- values may open with `"`, neither of which is a keyword character, so under
	-- <C-x><C-u> the second dash of "--" would dismiss the menu. Omni completion accepts
	-- any printable non-blank character, which is exactly the alphabet of a flag.
	local completefunc                 = "v:lua.require'ezpick.base.picker'._flag_completefunc"
	vim.bo[self.pbuf].omnifunc         = completefunc
	vim.bo[self.pbuf].completefunc     = completefunc
	vim.b[self.pbuf].ezpick_completion = { flags = self.opts.flags }
	-- Hook into CompleteDone to restore highlights and trigger a fetch update
	vim.api.nvim_create_autocmd("CompleteDone", {
		buffer = self.pbuf,
		callback = function()
			-- Accepting an item fires TextChangedI; suppress its auto-trigger.
			-- A menu dismissed by a keystroke it cannot complete on (a space
			-- ending a value) reports a stub item for the text typed so far, so
			-- what marks a real choice is the `abbr` every item here carries.
			if (vim.v.completed_item or {}).abbr ~= nil and vim.v.completed_item.abbr ~= "" then
				self._suppress_autocomplete = true
			end
			self:apply_prompt()
		end
	})
	vim.keymap.set("i", "<C-r><C-w>", function()
		vim.api.nvim_feedkeys(
			vim.api.nvim_replace_termcodes(self.original_cword, true, false, true),
			"i", false
		)
	end, { buffer = self.pbuf, desc = "Paste original <cword>" })
end

---Indent wrapped list lines so continuations are visually distinct from new
---entries: a continuation lines up under the label above it rather than under
---the prefix that label starts past.
---@return nil
function Picker:_apply_wrap_indent()
	if not self.lwin or not vim.api.nvim_win_is_valid(self.lwin) then return end
	vim.wo[self.lwin].breakindent = true
end

---Screen lines the query takes, wrapped to the prompt's current width. Neovim
---counts them: `nvim_win_text_height` measures the buffer as the window would
---draw it, wrapping, tabs, double-width characters and all.
---
---What it does not count is the cursor, which in insert mode sits one cell past
---the query -- on the row after, when the query fills its last row exactly. That
---row is the one being typed into, so the prompt is given it.
---@return integer
function Picker:_prompt_text_height()
	if not self.pwin or not vim.api.nvim_win_is_valid(self.pwin) then return 1 end
	local height = vim.api.nvim_win_text_height(self.pwin, {}).all
	local width = vim.api.nvim_win_get_width(self.pwin)
	local line = vim.api.nvim_buf_get_lines(self.pbuf, 0, 1, false)[1] or ""
	local last = vim.fn.strdisplaywidth(line) % width
	return height + (last == 0 and line ~= "" and 1 or 0)
end

---Re-lay the picker out when the query has grown or shrunk by a wrapped line.
---Called from wherever the prompt text changes; a query that still wraps the
---same way costs nothing but the measurement.
---@return nil
function Picker:_sync_prompt_height()
	if self.closed or not self.layout then return end
	-- `relayout` renders the list again on its way through, and rendering is what
	-- calls this: the measurement it would take is of a prompt half moved.
	if self._in_relayout then return end
	-- `relayout` dismisses the completion menu to move the floats out from under
	-- it. Growing the prompt is not worth that mid-completion; `CompleteDone`
	-- runs `apply_prompt` and the resize lands then.
	if vim.fn.pumvisible() == 1 then return end
	if self:_prompt_text_height() ~= self._prompt_wrapped then
		self:relayout()
	end
end

---Build the floats for the current editor size, creating whatever is not up yet
---and moving whatever is.
function Picker:relayout()
	if self.closed then return end
	self._in_relayout = true
	local opts = self.opts
	local title = opts.prompt and (" " .. opts.prompt .. " ") or ""

	if vim.fn.pumvisible() == 1 then
		vim.api.nvim_feedkeys(
			vim.api.nvim_replace_termcodes("<C-e>", true, false, true), "n", false
		)
	end

	---@param prompt_height integer
	---@return ezpick.Picker.Layout
	local function build(prompt_height)
		return layouts.build(self.opts.layout, {
			has_preview = self.preview_enabled,
			height_ratio = self.opts.height_ratio,
			width_ratio = self.opts.width_ratio,
			prompt_height = prompt_height,
		})
	end

	-- The wrapped query is measured off the prompt window, so the layout starts
	-- from the height the prompt has now and is settled below, once the window
	-- has been moved to the width this one gives it.
	self.layout = build(self.layout and self.layout.prompt_height or 1)

	-- The border is per float and comes from the layout: the prompt and the list
	-- share one frame, each drawing the half of it that is theirs.
	local base_cfg = {
		relative = "editor",
		style = "minimal",
	}

	local winhl = _WINHL

	---@return table
	local function prompt_cfg()
		return vim.tbl_extend("force", base_cfg, {
			row = self.layout.prompt_row,
			col = self.layout.prompt_col,
			width = self.layout.prompt_width,
			height = self.layout.prompt_height,
			border = self.layout.prompt_border,
			title = title,
			title_pos = "center",
			-- The rule below the prompt is this float's bottom border, so the
			-- status indicators ride on it as a footer; see `render_status`.
			footer = self:_status_chunks() or "",
			footer_pos = "right",
		})
	end

	if not self.pwin then
		if not self.pbuf then
			self.pbuf = _create_buffer(true, function()
				self.pbuf = nil
				if not self.closed then
					vim.schedule(function() self:close() end)
				end
			end)
		end
		local pwin_augroup
		self.pwin, pwin_augroup = ui.create_window(self.pbuf, true, prompt_cfg(),
			function()
				self.pwin = nil
				if not self.closed then
					vim.schedule(function() self:close() end)
				end
			end)
		vim.wo[self.pwin].winhighlight = winhl
		-- A query longer than the frame is wrapped rather than scrolled sideways:
		-- the float grows a line at a time to hold it, up to the even split with
		-- the list that `layouts` caps it at.
		vim.wo[self.pwin].wrap = true

		assert(type(pwin_augroup) == "number")
		self.pwin_augroup = pwin_augroup
		vim.api.nvim_create_autocmd("WinEnter", {
			group = pwin_augroup,
			callback = function(_)
				local win = vim.api.nvim_get_current_win()
				assert(not self.closed)
				local cfg = vim.api.nvim_win_get_config(win)
				local is_float = cfg.relative and cfg.relative ~= ""
				if not is_float and win ~= self.pwin and win ~= self.lwin and win ~= self.vwin then
					vim.schedule(function()
						self:close()
					end)
				end
			end
		})
		vim.api.nvim_create_autocmd("VimResized", {
			group = pwin_augroup,
			callback = function()
				assert(not self.closed)
				vim.schedule(function()
					self:relayout()
				end)
			end
		})
	else
		vim.api.nvim_win_set_config(self.pwin, prompt_cfg())
	end

	-- The prompt is where it will be and as wide as it will be, so what the query
	-- wraps to can be measured. Only its height is still open, and only the rows
	-- under it -- the list's -- answer to it; the widths and the preview do not,
	-- so nothing already decided above has to be revisited.
	local wrapped = self:_prompt_text_height()
	if wrapped ~= self.layout.prompt_height then
		self.layout = build(wrapped)
		vim.api.nvim_win_set_config(self.pwin, prompt_cfg())
	end
	-- What was measured, not what the layout granted: past the even split the
	-- prompt stops growing, and the two part company. Comparing against the
	-- measurement is what keeps a query that goes on growing from asking for a
	-- relayout on every keystroke.
	self._prompt_wrapped = wrapped

	if not self.lwin then
		if not self.lbuf then
			self.lbuf = _create_buffer(false, function()
				self.lbuf = nil
				if not self.closed then
					vim.schedule(function() self:close() end)
				end
			end)
		end
		self.lwin = ui.create_window(self.lbuf, false, vim.tbl_extend("force", base_cfg, {
				row = self.layout.list_row,
				col = self.layout.list_col,
				width = self.layout.list_width,
				height = self.layout.list_height,
				border = self.layout.list_border,
			}),
			function()
				self.lwin = nil
				if not self.closed then
					vim.schedule(function() self:close() end)
				end
			end)
		vim.wo[self.lwin].winhighlight = winhl
		vim.wo[self.lwin].wrap = self.opts.list_wrap ~= false
		self:_apply_wrap_indent()
	else
		vim.api.nvim_win_set_config(self.lwin, vim.tbl_extend("force", base_cfg, {
			row = self.layout.list_row,
			col = self.layout.list_col,
			width = self.layout.list_width,
			height = self.layout.list_height,
			border = self.layout.list_border,
		}))
	end

	-- The separators are drawn to the list width, so a list that survives a
	-- relayout has to be laid out again against the new one -- otherwise every
	-- separator keeps the length of the window the picker used to be. The
	-- labels themselves were cropped by their source and stay as they are until
	-- the next fetch re-crops them.
	if #self.list_items > 0 then
		local row = self:get_cursor()
		self:set_items(self.list_items)
		if row then self:move_cursor(row, true, true) end
	end

	if self.preview_enabled then
		if not self.vwin then
			if not self.vbuf then
				self.vbuf = _create_buffer(false, function()
					self.vbuf = nil
				end, "hide")
				local vbuf_key_opts = _key_opts_of(self.vbuf)
				vim.keymap.set("n", "<CR>", function() self:confirm() end, vbuf_key_opts)
				vim.keymap.set("n", "<Esc>", function() self:close() end, vbuf_key_opts)
			end
			self.vwin = ui.create_window(self.vbuf, false, {
					relative = "editor",
					style = "minimal",
					border = self.layout.preview_border,
					row = self.layout.preview_row,
					col = self.layout.preview_col,
					width = self.layout.preview_width,
					height = self.layout.preview_height,
				},
				function()
					self.vwin = nil
					if self.vbuf then
						vim.api.nvim_buf_delete(self.vbuf, { force = true })
						self.vbuf = nil
					end
					if not self.closed then
						vim.schedule(function() self:close() end)
					end
				end)
			vim.wo[self.vwin].wrap = true
			vim.wo[self.vwin].winhighlight = winhl
		else
			vim.api.nvim_win_set_config(self.vwin, vim.tbl_extend("force", base_cfg, {
				row = self.layout.preview_row,
				col = self.layout.preview_col,
				width = self.layout.preview_width,
				height = self.layout.preview_height,
				border = self.layout.preview_border,
			}))
		end
		self:update_preview()
	end

	self._in_relayout = false
end

---Show `msg` under the query, along the prompt's right edge.
---
---A virtual line rather than `eol_right_align` virtual text: aligning to the
---right edge pins the message to whatever screen row the query happens to end
---on, and a query long enough to reach it slides underneath and takes the
---corner. A virtual line is a screen row of its own, so the query cannot reach
---it -- and `nvim_win_text_height` counts it, so the prompt grows a row to hold
---it instead of pushing the query out of sight.
---
---Virtual lines are not wrapped ('wrap' does not reach them), and one wider than
---the prompt is cut off at the right -- so a message too long for the prompt
---loses its tail rather than its opening words. `virt_lines_overflow` says as
---much explicitly.
---@param ns integer Namespace, cleared by the caller.
---@param msg string
---@param hl string
---@param priority integer
---@return nil
function Picker:_set_prompt_hint(ns, msg, hl, priority)
	vim.api.nvim_buf_set_extmark(self.pbuf, ns, 0, 0, {
		virt_lines          = { { { _HINT_ICON .. msg, hl } } },
		virt_lines_overflow = "trunc",
		priority            = priority,
	})
end

---Flag highlights, and the hint about the first mistake among them, for `query`.
---@param query string
---@return nil
function Picker:render_prompt_highlight(query)
	self:_render_prompt_marks(query)
	-- A hint is a virtual line, and the prompt has to find it a row.
	self:_sync_prompt_height()
end

---@param query string
---@return nil
function Picker:_render_prompt_marks(query)
	if not self.pbuf then return end
	vim.api.nvim_buf_clear_namespace(self.pbuf, _NS_CONTENT, 0, -1)
	self._query_hint = nil
	if #self.opts.flags == 0 then return end

	-- Spans are measured against `query`, but the extmarks land on the prompt
	-- line as it is right now. Insert-mode completion changes that line without
	-- a TextChangedI, so the two can disagree; clamping keeps a stale span from
	-- erroring out of range instead of just highlighting a little too much.
	local line = #(vim.api.nvim_buf_get_lines(self.pbuf, 0, 1, false)[1] or "")

	for _, h in ipairs(queryflags.highlight(self.opts.flags, query)) do
		local start = math.min(h.start, line)
		local finish = math.min(h.finish, line)
		if start < finish then
			vim.api.nvim_buf_set_extmark(self.pbuf, _NS_CONTENT, 0, start, {
				end_col  = finish,
				hl_group = h.hl,
			})
		end
	end

	-- A hint about the span the cursor is still inside is a hint about
	-- unfinished typing: half of "--dir" is a missing value and an opening quote
	-- is an unclosed one, and saying so on the way through helps nobody. Those
	-- wait for the cursor to leave; a mistake that is already complete does not.
	local cursor   = self.pwin and vim.api.nvim_win_get_cursor(self.pwin)[2] or #query
	self._hint_col = cursor
	local shown    = {}
	for _, hint in ipairs(queryflags.parse(self.opts.flags, query).hints) do
		if hint.settled or not (_HELD_WHILE_TYPING[hint.kind] and _at_cursor(query, hint, cursor)) then
			table.insert(shown, hint)
		end
	end
	if #shown == 0 then return end

	for _, hint in ipairs(shown) do
		vim.api.nvim_buf_set_extmark(self.pbuf, _NS_CONTENT, 0, math.min(hint.start, line), {
			end_col  = math.min(hint.finish, line),
			hl_group = "DiagnosticUnderlineWarn",
			priority = 200,
		})
	end

	-- Only the first gets words; the prompt line is not a diagnostics window.
	self._query_hint = shown[1].msg
	self:_set_prompt_hint(_NS_CONTENT, shown[1].msg, "DiagnosticVirtualTextWarn", 100)
end

---Redraw the rule so the current spinner frame appears or disappears. The
---spinner rides in the footer next to the count, so drawing it is just a status
---redraw.
---@return nil
function Picker:render_spinner()
	self:render_status()
end

---Chunks for the rule below the prompt: the spinner while a fetch is in flight,
---then the position counter. They live on the rule rather than on the prompt
---line so that a query long enough to reach the right edge no longer collides
---with them.
---@return table[]? footer Footer chunks, nil for a bare rule: neither
---`nvim_open_win` nor `nvim_win_set_config` takes an empty array, so callers
---pass `""` in its place.
function Picker:_status_chunks()
	local chunks = {}
	if self._spinner_frame then
		chunks[#chunks + 1] = { " " .. self._spinner_frame, "NonText" }
	end
	-- A hint about the query says more than the count does, and only one of the
	-- two is shown at a time.
	local total = #self.list_items
	if not self._query_hint and total > 0 then
		local cur = self:get_cursor() or 1
		chunks[#chunks + 1] = { string.format(" %d/%d", cur, total), "NonText" }
	end
	if #chunks == 0 then return nil end
	return chunks
end

---Redraw the rule's right end. The footer is part of the window config, so it
---is also handed to `prompt_cfg` for the floats `relayout` builds from scratch.
function Picker:render_status()
	if not (self.pwin and vim.api.nvim_win_is_valid(self.pwin)) then return end
	vim.api.nvim_win_set_config(self.pwin, {
		-- An empty string is how the config clears a footer already drawn.
		footer = self:_status_chunks() or "",
		footer_pos = "right",
	})
end

---Kept as the name the count's own callers use; the rule carries the count.
function Picker:render_position()
	self:render_status()
end

function Picker:render_cursor()
	if not self.lbuf then return end
	vim.api.nvim_buf_clear_namespace(self.lbuf, _NS_CURSOR, 0, -1)
	local total = #self.list_items
	if total == 0 then
		self:render_status()
		return
	end
	local cur = self:get_cursor() or 1
	vim.api.nvim_buf_set_extmark(self.lbuf, _NS_CURSOR, cur - 1, 0, {
		virt_text = { { "❯ ", "Special" } },
		virt_text_pos = "overlay",
		priority = 100,
	})
end

---@return integer?
function Picker:get_cursor()
	if not self.lwin then return nil end
	return vim.api.nvim_win_get_cursor(self.lwin)[1]
end

---Neovim won't scroll to reveal virt_lines hanging below the cursor line, so an
---entry sitting on the bottom row of the viewport has its virtual line clipped.
---When that's the case, scroll the view up a row to bring it back.
---
---Only the *last* entry needs this. Scrolling to the cursor works for every
---other row, because there is a real line below it to scroll onto; past the end
---of the buffer there is nothing to scroll to and Neovim stops, leaving the
---hanging lines off screen. Callers gate on that -- see `move_cursor`.
---@param row integer
function Picker:_reveal_virt_lines(row)
	if not self.lwin or not vim.api.nvim_win_is_valid(self.lwin) then return end
	local item = self.list_items[row]
	-- Only the virtual line moves the view: a separator clipped at the very
	-- bottom of the list costs nothing to leave there.
	if not item or not item.virt_line then return end

	vim.api.nvim_win_call(self.lwin, function()
		-- Screen height of the entry's own text (wrapped rows, excluding virt_lines).
		local line_height = vim.api.nvim_win_text_height(self.lwin, {
			start_row = row - 1,
			end_row = row - 1,
		}).all
		-- Only act when the entry's last row is the bottom row of the viewport.
		local bottom_row = vim.fn.winline() + line_height - 1
		if bottom_row < vim.api.nvim_win_get_height(self.lwin) then return end
		local view = vim.fn.winsaveview()
		view.topline = view.topline + 1
		vim.fn.winrestview(view)
	end)
end

---@param row integer
---@param force boolean?
---@param clamp boolean?
function Picker:move_cursor(row, force, clamp)
	local total = #self.list_items
	if total == 0 then return end
	if not self.lwin or not vim.api.nvim_win_is_valid(self.lwin) then return end

	if clamp then
		row = _clamp(row, 1, total)
	else
		if row > total then row = 1 end
		if row < 1 then row = total end
	end

	-- Compared after clamping, not before: <C-d> on the last row resolves to
	-- the row the cursor already sits on, and re-selecting it would cancel the
	-- preview and load the same item again.
	if not force and row == self:get_cursor() then return end

	vim.api.nvim_win_set_cursor(self.lwin, { row, 0 })
	vim.schedule(function()
		if not self.closed and row == #self.list_items then
			self:_reveal_virt_lines(row)
		end
	end)

	self:render_cursor()
	self:render_position()
	self:update_preview()
end

---@return nil
function Picker:update_preview()
	self.async_preview_context = self.async_preview_context + 1
	local preview_context = self.async_preview_context
	local fetch_context = self.async_fetch_context

	if self.closed then return end
	if not self.vbuf then return end

	self:request_clear_preview()

	if self.async_preview_cancel then
		self.async_preview_cancel()
		self.async_preview_cancel = nil
	end

	local cursor = self:get_cursor()
	---@type ezpick.picker.ListItem?
	local item = cursor and self.list_items[cursor] or nil
	if not item then return end

	-- The layout's width and height are what `nvim_open_win` was handed, and it
	-- draws the border outside them (see `layouts._BORDER_SPAN`), so these are
	-- already the content area a previewer gets to fill.
	local preview_width = self.layout.preview_width
	local preview_height = self.layout.preview_height

	local preview_fn = self.opts.previewer or pickertools.file_preview

	self.async_preview_cancel = preview_fn(
		item.data,
		{
			viewport_width = preview_width,
			viewport_height = preview_height,
		},
		vim.schedule_wrap(function(preview)
			if self.closed or preview_context ~= self.async_preview_context or fetch_context ~= self.async_fetch_context then
				return
			end
			preview = preview or {}
			self:cancel_clear_preview_req()

			if preview.bufnr and vim.api.nvim_buf_is_valid(preview.bufnr) then
				if self.vwin and vim.api.nvim_win_is_valid(self.vwin) then
					self:release_external_preview_buf()
					self._preview_external_buf = preview.bufnr
					vim.api.nvim_win_set_buf(self.vwin, preview.bufnr)
					vim.wo[self.vwin].winhighlight =
						_WINHL -- nvim_win_set_buf mutates winhighlight (drops EndOfBuffer remap)
					_apply_preview_pos(self.vwin, preview.bufnr, preview.pos, preview.pos_end)
				end
				return
			end

			if self._preview_external_buf and self.vwin and vim.api.nvim_win_is_valid(self.vwin) then
				pcall(vim.api.nvim_win_set_buf, self.vwin, self.vbuf)
				vim.wo[self.vwin].winhighlight =
					_WINHL -- nvim_win_set_buf mutates winhighlight (drops EndOfBuffer remap)
				self:release_external_preview_buf()
			end

			local content = preview.content
			local lines ---@type string[]
			if content then
				if type(content) == "string" then
					lines = vim.split(content, "\n")
				else
					lines = content
				end
			elseif preview.error_msg then
				lines = _center_for_previewer(preview.error_msg, preview_width, preview_height)
			else
				lines = _center_for_previewer("No preview", preview_width, preview_height)
			end
			lines = lines or {}
			if self.vbuf then
				vim.bo[self.vbuf].modifiable = true
				vim.api.nvim_buf_set_lines(self.vbuf, 0, -1, false, lines)
				vim.bo[self.vbuf].modifiable = false
				local filetype = content and (preview.filetype
					or (preview.filepath and vim.filetype.match({ filename = preview.filepath }))
					or "") or ""
				-- Set only 'syntax' (not 'filetype') so no FileType autocmd fires and
				-- treesitter/lsp never attaches (avoid slowness and flickering); legacy vim-regex syntax highlighting is
				-- still loaded via the Syntax autocmd.
				vim.bo[self.vbuf].syntax = filetype
				_apply_preview_pos(self.vwin, self.vbuf, content and preview.pos or nil,
					content and preview.pos_end or nil)
			end
		end)
	)
end

function Picker:start_spinner()
	if self.spinner or self._spinner_delay_timer then return end
	self._spinner_delay_timer = vim.defer_fn(function()
		self._spinner_delay_timer = nil
		if not self.spinner then
			self.spinner = Spinner:new {
				interval = 100,
				on_update = function(frame)
					self._spinner_frame = frame
					self:render_spinner()
				end
			}
			self.spinner:start()
		end
	end, _antiflicker_delay)
end

function Picker:stop_spinner()
	if self._spinner_delay_timer then
		self._spinner_delay_timer:close()
		self._spinner_delay_timer = nil
	end
	if self.spinner then
		self.spinner:stop()
		self.spinner = nil
	end
	self._spinner_frame = nil
	self:render_spinner()
end

function Picker:release_external_preview_buf()
	if self._preview_external_buf and vim.api.nvim_buf_is_valid(self._preview_external_buf) then
		pcall(vim.api.nvim_buf_clear_namespace, self._preview_external_buf, _NS_PREVIEW, 0, -1)
	end
	self._preview_external_buf = nil
end

---@param immediate  boolean?
function Picker:request_clear_preview(immediate)
	local clear = function()
		if self.vbuf and not self.closed then
			if self._preview_external_buf and self.vwin and vim.api.nvim_win_is_valid(self.vwin) then
				pcall(vim.api.nvim_win_set_buf, self.vwin, self.vbuf)
				vim.wo[self.vwin].winhighlight =
					_WINHL -- nvim_win_set_buf mutates winhighlight (drops EndOfBuffer remap)
			end
			self:release_external_preview_buf()
			vim.bo[self.vbuf].modifiable = true
			vim.api.nvim_buf_set_lines(self.vbuf, 0, -1, false, {})
			vim.bo[self.vbuf].modifiable = false
			vim.api.nvim_buf_clear_namespace(self.vbuf, _NS_PREVIEW, 0, -1)
		end
	end
	if immediate then
		self:cancel_clear_preview_req()
		clear()
	elseif not self.preview_timer then
		self.preview_timer = vim.defer_fn(function()
			self.preview_timer = nil
			clear()
		end, _antiflicker_delay)
	end
end

function Picker:cancel_clear_preview_req()
	self.preview_timer = timer.stop_and_close_timer(self.preview_timer)
end

function Picker:clear_list()
	self.list_items = {}
	if not self.lbuf then return end

	vim.bo[self.lbuf].modifiable = true
	vim.api.nvim_buf_set_lines(self.lbuf, 0, -1, false, {})
	vim.bo[self.lbuf].modifiable = false
	if self.lwin and vim.api.nvim_win_is_valid(self.lwin) then
		vim.wo[self.lwin].cursorline = false
	end

	vim.api.nvim_buf_clear_namespace(self.lbuf, _NS_CONTENT, 0, -1)
	self:request_clear_preview()
	self:render_cursor()
	self:render_position()
end

---@param items (ezpick.Picker.Item|ezpick.picker.ListItem)[]?
function Picker:set_items(items)
	items = items or {}
	if not self.lbuf then return end

	local prefix     = _LIST_PREFIX
	local count      = #items

	local list_items = tbl_new(count, 0) ---@type ezpick.picker.ListItem[]
	local lines      = tbl_new(count, 0) ---@type string[]

	for row_idx = 1, count do
		local item          = items[row_idx]
		local chunks        = item.label_chunks

		list_items[row_idx] = {
			data = item.data,
			label_chunks = chunks,
			virt_line = item.virt_line,
		}

		if not chunks or #chunks == 0 then
			lines[row_idx] = prefix
		elseif #chunks == 1 then
			lines[row_idx] = prefix .. _one_line(chunks[1][1] or "")
		else
			local parts = tbl_new(#chunks + 1, 0)
			parts[1] = prefix
			for i = 1, #chunks do
				local text = chunks[i][1]
				if text and #text > 0 then parts[#parts + 1] = _one_line(text) end
			end
			lines[row_idx] = table.concat(parts)
		end
	end

	self.list_items = list_items

	vim.bo[self.lbuf].modifiable = true
	vim.api.nvim_buf_set_lines(self.lbuf, 0, -1, false, lines)
	vim.api.nvim_buf_clear_namespace(self.lbuf, _NS_CONTENT, 0, -1)

	-- Highlighting is a second pass because an extmark needs its line to exist
	-- first. It reads the chunks again rather than carrying a description of
	-- each mark over from the pass above: at ten thousand rows a keystroke, that
	-- description is two throwaway tables per highlighted chunk.
	for row_idx = 1, count do
		local item   = items[row_idx]
		local row    = row_idx - 1
		local chunks = item.label_chunks

		if chunks then
			local col = #prefix
			for i = 1, #chunks do
				local text, hl = chunks[i][1], chunks[i][2]
				if text and #text > 0 then
					if hl then
						vim.api.nvim_buf_set_extmark(self.lbuf, _NS_CONTENT, row, col, {
							end_col  = col + #text,
							hl_group = hl,
						})
					end
					col = col + #text
				end
			end
		end

		local vlines
		if item.virt_line and #item.virt_line > 0 then
			local vl = { { prefix }, { "╰─ ", "NonText" } }
			vim.list_extend(vl, item.virt_line)
			vlines = { vl }
		end
		if vlines then
			vim.api.nvim_buf_set_extmark(self.lbuf, _NS_CONTENT, row, 0, {
				virt_lines = vlines,
				hl_mode    = "blend",
			})
		end
	end

	vim.bo[self.lbuf].modifiable = false
	if self.lwin and vim.api.nvim_win_is_valid(self.lwin) then
		vim.wo[self.lwin].cursorline = count > 0
	end
end

-- Resolve which row the cursor starts on. The function form is handed the items
-- in their final ranked order, which is the only order a row number means
-- anything in, and rows map 1:1 onto `set_items`.
---@param items ezpick.Picker.Item[] ranked, in final list order
---@param initial_cursor (integer|fun(items:ezpick.Picker.Item[]):integer?)?
---@return integer? row 1-based, nil to leave the cursor at the top
local function _resolve_initial_cursor(items, initial_cursor)
	if type(initial_cursor) == "function" then return initial_cursor(items) end
	return initial_cursor
end

function Picker:run_fetch()
	local query_text = self.query_text

	---@type ezpick.Picker.FetcherOpts
	local fetch_opts = {
		-- The window width is the content area; the two columns come off for
		-- the prefix every row is written behind, not for the border.
		list_width      = math.max(1, self.layout.list_width - 2),
		list_height     = math.max(1, self.layout.list_height),
		virt_line_width = math.max(1, self.layout.list_width - 5),
	}

	local clean_query, flags
	if #self.opts.flags > 0 then
		-- `parse` never refuses: a half-typed quote or an unknown flag yields a
		-- hint beside a best-effort query, so the list keeps up with the typing
		-- instead of emptying at the first character of a mistake.
		local parsed      = queryflags.parse(self.opts.flags, query_text)
		clean_query       = parsed.query
		flags             = parsed.flags
		fetch_opts.parsed = parsed
	else
		clean_query = query_text
		flags       = {}
	end

	-- Parse before touching the in-flight fetch or the preview: an edit that
	-- leaves the parsed query unchanged (a trailing space, doubled separators)
	-- must be a no-op, not a cancel-and-clear of results that still apply.
	if clean_query == self._last_clean_query and _flags_equal(flags, self._last_flags or {}) then
		return
	end
	self._last_clean_query = clean_query
	self._last_flags       = flags

	if self.async_fetch_cancel then
		self.async_fetch_cancel()
		self.async_fetch_cancel = nil
	end

	self:request_clear_preview()

	self.async_fetch_context = self.async_fetch_context + 1
	local context            = self.async_fetch_context

	local complete           = false

	self.async_fetch_cancel  = self.opts.finder(
		clean_query,
		flags,
		fetch_opts,
		function(new_items)
			if complete or self.closed or context ~= self.async_fetch_context then return end
			complete = true
			self:stop_spinner()
			if new_items and #new_items > 0 then
				new_items = _rank_items(new_items)
				local target_row = 1
				if self._set_init_cursor then
					self._set_init_cursor = false
					target_row = _clamp(
						_resolve_initial_cursor(new_items, self.opts.initial_cursor) or 1, 1, #new_items)
				end
				self:set_items(new_items)
				self:move_cursor(target_row, true, true)
			else
				self:clear_list()
			end
		end
	)
	if not complete then
		assert(type(self.async_fetch_cancel) == "function",
			"finder with deferred result should return a function")
		self:start_spinner()
	end
end

function Picker:_apply_history_entry(q)
	self.query_text = q
	vim.api.nvim_buf_set_lines(self.pbuf, 0, -1, false, { q })
	vim.api.nvim_win_set_cursor(self.pwin, { 1, #q })
	self:render_prompt_highlight(q)
	self:run_fetch()
end

function Picker:history_prev()
	if not self.opts.history_provider or #self.history == 0 then return end

	if self.history_idx == #self.history + 1 then
		self.history_saved_query = self.query_text
	end

	local new_idx = math.max(1, self.history_idx - 1)
	if new_idx ~= self.history_idx then
		self.history_idx = new_idx
		self:_apply_history_entry(_decode_history(self.history[self.history_idx]))
	end
end

function Picker:history_next()
	if not self.opts.history_provider then return end

	local new_idx = self.history_idx + 1
	if new_idx <= #self.history then
		self.history_idx = new_idx
		self:_apply_history_entry(_decode_history(self.history[self.history_idx]))
	elseif new_idx == #self.history + 1 then
		self.history_idx         = new_idx
		local q                  = self.history_saved_query or ""
		self.history_saved_query = nil
		self:_apply_history_entry(q)
	end
end

function Picker:set_prompt_text(text)
	self.query_text = text
	vim.api.nvim_buf_set_lines(self.pbuf, 0, -1, false, { text })
	vim.api.nvim_win_set_cursor(self.pwin, { 1, #text })
	self:render_prompt_highlight(text)
	self:run_fetch()
end

function Picker:send_to_qf()
	if #self.list_items == 0 then return end
	local qf_entries = {} ---@type vim.quickfix.entry[]

	if self.opts.quickfix_formatter then
		for _, item in ipairs(self.list_items) do
			local entry = self.opts.quickfix_formatter(item.data)
			if entry then table.insert(qf_entries, entry) end
		end
	else
		for _, item in ipairs(self.list_items) do
			local data = item.data or {}
			---@type vim.quickfix.entry
			local entry = {
				text     = _item_label(item),
				filename = data.filepath,
				lnum     = data.lnum or 1,
				col      = data.col or 1,
			}
			table.insert(qf_entries, entry)
		end
	end
	if #qf_entries > 0 then
		self:close()
		vim.fn.setqflist(qf_entries, "r")
		vim.cmd("copen")
	end
end

function Picker:confirm()
	local cursor = self:get_cursor()
	---@type ezpick.picker.ListItem?
	local list_item = cursor and self.list_items[cursor] or nil
	self:close(list_item and list_item.data or nil)
end

---@param selected_data ezpick.picker.ItemData?
function Picker:close(selected_data)
	if self.closed then return end

	-- Capture the highlighted row before tearing down (get_cursor needs the list
	-- window), so on_close can report it and a reopen can reselect the same row.
	local cursor = self:get_cursor()

	self.closed = true
	if _active_picker == self then _active_picker = nil end

	-- The floats outlive this call by a tick (see the stopinsert note below),
	-- so their autocmds go now: each one asserts a picker that is still open.
	if self.pwin_augroup then pcall(vim.api.nvim_del_augroup_by_id, self.pwin_augroup) end
	self.pwin_augroup = nil

	self:stop_spinner()

	self.preview_timer = timer.stop_and_close_timer(self.preview_timer)

	if self.async_fetch_cancel then self.async_fetch_cancel() end
	if self.async_preview_cancel then self.async_preview_cancel() end

	self:release_external_preview_buf()

	-- Leaving insert mode steps the cursor one column left, and `:stopinsert`
	-- only takes effect once this returns -- so the floats have to outlive it,
	-- or that step lands in the window the focus falls back to.
	--
	-- Both go in ahead of the spec's own callbacks below. `closed` is already
	-- true and the prompt's autocmds are already gone, so an error raised out
	-- of one of those would otherwise leave three floats on screen that no
	-- keymap can shut: every one of them routes back through here.
	vim.cmd("stopinsert!")
	vim.schedule(function()
		for _, w in pairs({ self.pwin, self.lwin, self.vwin }) do
			if vim.api.nvim_win_is_valid(w) then
				vim.api.nvim_win_close(w, true)
			end
		end

		for _, b in pairs({ self.pbuf, self.lbuf, self.vbuf }) do
			if vim.api.nvim_buf_is_valid(b) then
				vim.api.nvim_buf_delete(b, { force = true })
			end
		end

		self.callback(selected_data)
	end)

	if self.opts.on_close then
		self.opts.on_close(self.query_text, cursor)
	end

	if self.opts.history_provider then
		local entry = self.query_text
		if entry ~= "" and entry ~= self.history[#self.history] then
			table.insert(self.history, entry)
			if self.opts.history_provider.store then
				self.opts.history_provider.store(self.history)
			end
		end
	end
end

function Picker:setup_input()
	do
		local pbuf_key_opts = _key_opts_of(self.pbuf)
		vim.keymap.set("n", "g?", _show_help, pbuf_key_opts)

		vim.keymap.set({ "i", "n" }, "<CR>", function() self:confirm() end, pbuf_key_opts)

		vim.keymap.set("n", "<Esc>", function() self:close() end, pbuf_key_opts)
		vim.keymap.set("i", "<C-c>", function() self:close() end, pbuf_key_opts)

		local expr_opts = vim.tbl_extend("force", pbuf_key_opts, { expr = true })

		vim.keymap.set("n", "<C-n>", function() self:move_cursor((self:get_cursor() or 0) + 1) end, pbuf_key_opts)
		vim.keymap.set("n", "<C-p>", function() self:move_cursor((self:get_cursor() or 1) - 1) end, pbuf_key_opts)

		vim.keymap.set("i", "<C-n>", function()
			if vim.fn.pumvisible() == 1 then return "<C-n>" end
			self:move_cursor((self:get_cursor() or 0) + 1)
			return ""
		end, expr_opts)
		vim.keymap.set("i", "<C-p>", function()
			if vim.fn.pumvisible() == 1 then return "<C-p>" end
			self:move_cursor((self:get_cursor() or 1) - 1)
			return ""
		end, expr_opts)

		vim.keymap.set("i", "<Down>", function()
			if vim.fn.pumvisible() == 1 then return "<Down>" end
			self:move_cursor((self:get_cursor() or 0) + 1)
			return ""
		end, expr_opts)
		vim.keymap.set("i", "<Up>", function()
			if vim.fn.pumvisible() == 1 then return "<Up>" end
			self:move_cursor((self:get_cursor() or 1) - 1)
			return ""
		end, expr_opts)

		vim.keymap.set({ "i", "n" }, "<C-d>", function()
			local cur = self:get_cursor()
			if cur then
				local step = math.floor(self.layout.list_height / 2)
				self:move_cursor(cur + step, false, true)
			end
		end, pbuf_key_opts)

		vim.keymap.set({ "i", "n" }, "<C-u>", function()
			local cur = self:get_cursor()
			if cur then
				local step = math.floor(self.layout.list_height / 2)
				self:move_cursor(cur - step, false, true)
			end
		end, pbuf_key_opts)

		vim.keymap.set("i", "<C-j>", function() self:history_next() end, pbuf_key_opts)
		vim.keymap.set("i", "<C-k>", function() self:history_prev() end, pbuf_key_opts)

		vim.keymap.set("n", "j", function() self:history_next() end, pbuf_key_opts)
		vim.keymap.set("n", "k", function() self:history_prev() end, pbuf_key_opts)

		vim.keymap.set({ "n", "i" }, "<C-q>", function() self:send_to_qf() end, pbuf_key_opts)

		vim.keymap.set("i", "<C-Space>", function()
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-x><C-o>", true, false, true), "n", false)
		end, pbuf_key_opts)

		vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
			buffer = self.pbuf,
			callback = function(ev)
				self:apply_prompt()
				if ev.event == "TextChangedI" then self:maybe_autocomplete() end
			end
		})

		-- Which hints are held depends on where the cursor is, so leaving a
		-- half-written flag has to be an event of its own: without this the
		-- hint waits for the next keystroke, and a query finished with a typo
		-- in it -- nothing left to type -- never says anything at all.
		if #self.opts.flags > 0 then
			vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
				buffer = self.pbuf,
				callback = function()
					if self.closed or not self.pwin then return end
					-- Typing moves the cursor too, and the text path has just
					-- drawn these same hints for this same column.
					if vim.api.nvim_win_get_cursor(self.pwin)[2] == self._hint_col then return end
					-- Not query_text: completion rewrites the line without a
					-- TextChangedI, so the cached query can lag behind it.
					self:render_prompt_highlight(vim.api.nvim_buf_get_lines(self.pbuf, 0, 1, false)[1] or "")
					self:render_position()
				end
			})
		end
	end

	do
		local lbuf_key_opts = _key_opts_of(self.lbuf)
		vim.keymap.set("n", "<Esc>", function() self:close() end, lbuf_key_opts)
		vim.keymap.set("n", "<CR>", function() self:confirm() end, lbuf_key_opts)
	end
end

--- Buffer-local 'omnifunc'/'completefunc' for picker flag completion. The flag schema is
--- read from a buffer variable set once at picker load; candidates are computed
--- live from the current prompt line, so this function needs no picker reference
--- or module-level state.
---@param findstart 0|1
---@param base string
---@return integer|table -- the 0-indexed start column, or a `complete-functions` dict
function M._flag_completefunc(findstart, base)
	local ctx   = vim.b.ezpick_completion
	local flags = ctx and ctx.flags
	if not flags or #flags == 0 then
		return findstart == 1 and -3 or _EMPTY_COMPLETION
	end

	-- Candidates depend on the whole prompt line, not just `base`: "l" alone is a
	-- bare word, but "--dir l" is a directory being named. On the second call Vim
	-- has cut `base` out of the buffer and parked the cursor at its start, so the
	-- line is put back together before parsing it.
	local line = vim.api.nvim_get_current_line()
	local col  = vim.api.nvim_win_get_cursor(0)[2]
	if findstart == 0 then
		line = line:sub(1, col) .. base .. line:sub(col + 1)
		col  = col + #base
	end

	local completions = queryflags.get_completions(flags, line, col, false)
	if not completions or #completions.items == 0 then
		return findstart == 1 and -3 or _EMPTY_COMPLETION
	end

	-- get_completions returns a 1-indexed byte column; completefunc wants 0-indexed.
	if findstart == 1 then return completions.startcol - 1 end

	-- Keep only candidates matching what was typed since startcol. Quotes are
	-- ignored so an unquoted partial still matches a quoted value (base
	-- `lang:fo` matches word `lang:"foo bar"`).
	local function unquoted(s) return (s:gsub("[\"']", "")) end
	local needle = unquoted(base)
	local items  = {}
	for _, item in ipairs(completions.items) do
		if vim.startswith(unquoted(item.word), needle) then
			items[#items + 1] = item
		end
	end
	return { words = items, refresh = "always" }
end

--- Exposed for the test suite; `run_fetch` is the only caller in anger.
M._rank_items = _rank_items

--- Exposed for the test suite.
M._resolve_initial_cursor = _resolve_initial_cursor

---@param opts ezpick.Picker.opts
---@param callback ezpick.Picker.Callback
function M.open(opts, callback)
	assert(opts.finder, "finder missing in opts")
	if _active_picker and not _active_picker.closed then
		_active_picker:close()
	end
	Picker:new(opts, callback)
end

return M
