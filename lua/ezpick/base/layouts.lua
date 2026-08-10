local M = {}

---@alias ezpick.Picker.LayoutKind "horizontal"|"vertical"

---How the floats are sized, for one preview state. `width_ratio` and
---`height_ratio` are fractions of the usable editor area the whole picker spans
--- -- prompt, list and preview together -- not of any single float. The border
---ring adds `_BORDER_SPAN` on top; the usable area excludes the command line
---and the statusline, see `M.usable_lines`.
---@class ezpick.Picker.Geometry
---@field layout ezpick.Picker.LayoutKind? Arrangement of list and preview (default "horizontal").
---@field width_ratio number?
---@field height_ratio number?

---Last resort for callers that open a picker without going through
---`ezpick.setup`. The defaults meant for users to edit live in `ezpick.Config`;
---these only keep the geometry finite when nothing was passed at all.
local _FALLBACK = { width_ratio = 0.6, height_ratio = 0.7 }

---Rows and columns the outermost border eats. `nvim_open_win` draws a border on
---the row and column it is handed, so a float reaches one cell past the
---geometry on every side; the inner borders are already paid for by the gaps
---between the floats, only the ring around the whole picker is left. Centering
---has to allow for it or the picker sits two cells low and two cells right.
local _BORDER_SPAN = 2

---Helix-style framing: the prompt and the list are one box. The prompt draws
---the top, the sides and the rule dividing the query from the items; the list
---draws its sides and the bottom, and nothing of its own where the rule already
---is -- so the two floats read as a single frame. Border order is
---{tl, t, tr, r, br, b, bl, l}; an empty string means no border there, and no
---row or column reserved for it.
---The rule takes its own highlight, a `{char, hl}` pair where the rest of the
---border is a plain string on `FloatBorder`: it divides the frame rather than
---bounding it, so it reads better dimmed.
local _BORDER_TOP = { "╭", "─", "╮", "│", "│", { "─", "NonText" }, "│", "│" }
local _BORDER_BOTTOM = { "", "", "", "│", "╯", "─", "╰", "│" }
local _BORDER_FULL = "rounded"

---Rows between the frame's top edge and its first item: the top border, the
---prompt's line of text, and the rule below it. `nvim_open_win` places a
---bordered float by its outer edge, so the prompt float covers all three from
---`prompt_row` -- the list has to start past them or its first row is drawn
---over by the rule.
local _PROMPT_ROWS = 3

---@type fun(v:number,min:number,max:number):number
local function _clamp(v, min, max)
    return math.max(min, math.min(max, v))
end

---Nudge `span` so what is left over after centring it inside `available`
---divides in two. An odd leftover cannot be split evenly, and the `math.floor`
---the callers use would hand the spare cell to the bottom (or the right);
---spending it on the picker instead keeps the two gaps identical. It grows,
---falling back to shrinking only when there is no room to grow.
---@param span integer
---@param available integer
---@return integer
local function _even_gaps(span, available)
    if (available - span - _BORDER_SPAN) % 2 == 0 then
        return span
    elseif span + _BORDER_SPAN < available then
        return span + 1
    end
    return math.max(1, span - 1)
end

--- Whether a statusline is drawn at the bottom of the editor. With
--- `laststatus == 1`, assume no status line (for performance)
---@return boolean
local function _has_statusline()
    local laststatus = vim.o.laststatus
    return laststatus ~= 0 and laststatus ~=1
end

---Editor rows the picker may occupy: everything `vim.o.lines` counts, less the
---command line and the statusline. Floats are placed relative to the editor,
---whose row 0 is the top of the screen, so those rows come off the bottom and
---centering within what is left keeps the picker off the command line.
---@return integer
function M.usable_lines()
    local reserved = vim.o.cmdheight + (_has_statusline() and 1 or 0)
    return math.max(1, vim.o.lines - reserved)
end

---Prompt and list share one frame, helix style, with the preview beside it: the
---prompt sits directly on top of the items, divided by a rule rather than by two
---borders and a gap.
---@param opts {has_preview:boolean,height_ratio:number?,width_ratio:number?}
---@return ezpick.Picker.Layout
function M.get_horizontal_layout(opts)
    local cols = vim.o.columns
    local lines = M.usable_lines()

    local has_preview = opts.has_preview
    -- The two columns where the frame's right border and the preview's left one
    -- meet; without a preview there is nothing to make room for.
    local spacing = has_preview and 2 or 0

    local total_width = _even_gaps(math.ceil(cols * _clamp(opts.width_ratio or _FALLBACK.width_ratio, 0.2, 0.95)), cols)
    local list_width, preview_width
    if has_preview then
        -- Even split of what the spacing leaves, the odd column going to the preview.
        list_width = math.max(1, math.floor((total_width - spacing) / 2))
        preview_width = math.max(1, total_width - spacing - list_width)
    else
        list_width = total_width
        preview_width = 0
    end

    local total_height = _even_gaps(math.ceil(lines * _clamp(opts.height_ratio or _FALLBACK.height_ratio, 0.3, 0.8)), lines)
    -- The frame's own rows, off the top: the prompt line and the rule under it.
    -- Its outer border is the ring `_BORDER_SPAN` already pays for.
    local list_height = _clamp(total_height - 2, 1, lines)

    local row = math.floor((lines - total_height - _BORDER_SPAN) / 2)
    local col = math.floor((cols - (list_width + preview_width + spacing) - _BORDER_SPAN) / 2)

    return {
        -- The prompt is only as wide as the list: the two are one box.
        prompt_row = row,
        prompt_col = col,
        prompt_width = list_width,
        prompt_height = 1,
        prompt_border = _BORDER_TOP,

        -- Past the prompt's three rows; the list reserves none of its own up
        -- there, its first row being the one under the rule.
        list_row = row + _PROMPT_ROWS,
        list_col = col,
        list_width = list_width,
        list_height = list_height,
        list_border = _BORDER_BOTTOM,

        -- Level with the frame beside it, top and bottom alike: its top border
        -- lands on the same row as the prompt's, so its height is everything the
        -- frame holds.
        preview_row = row,
        preview_col = col + list_width + spacing,
        preview_width = preview_width,
        preview_height = list_height + 2,
        preview_border = _BORDER_FULL,
    }
end

---@param opts {has_preview:boolean,height_ratio:number?,width_ratio:number?}
---@return ezpick.Picker.Layout
function M.get_vertical_layout(opts)
    local cols = vim.o.columns
    local lines = M.usable_lines()

    local has_preview = opts.has_preview

    local width = _even_gaps(math.ceil(cols * _clamp(opts.width_ratio or _FALLBACK.width_ratio, 0.2, 0.95)), cols)
    local total_height = _even_gaps(math.ceil(lines * _clamp(opts.height_ratio or _FALLBACK.height_ratio, 0.3, 0.8)), lines)

    local row = math.floor((lines - total_height - _BORDER_SPAN) / 2)
    local col = math.floor((cols - width - _BORDER_SPAN) / 2)

    -- Layout (top to bottom): the shared prompt/list frame, then -- when there is
    -- one -- the preview directly below it, its top border on the row after the
    -- frame's bottom one. Flush, like the preview beside the frame in the
    -- horizontal layout.
    local list_row = row + _PROMPT_ROWS

    ---@type ezpick.Picker.Layout
    local layout = {
        prompt_row = row,
        prompt_col = col,
        prompt_width = width,
        prompt_height = 1,
        prompt_border = _BORDER_TOP,

        list_row = list_row,
        list_col = col,
        list_width = width,
        list_height = 1,
        list_border = _BORDER_BOTTOM,

        preview_row = list_row,
        preview_col = col,
        preview_width = 0,
        preview_height = 0,
        preview_border = _BORDER_FULL,
    }

    if not has_preview then
        -- The prompt line and the rule under it; the frame's outer border is the
        -- ring `_BORDER_SPAN` already pays for.
        layout.list_height = math.max(1, total_height - 2)
        return layout
    end

    -- Two rows for the prompt and its rule, and two more for the borders the
    -- frame and the preview meet on.
    local usable_height = math.max(2, total_height - 4)

    -- Even split, the odd row going to the list.
    local list_height = math.max(1, math.ceil(usable_height / 2))
    layout.list_height = list_height
    -- One past the frame's bottom border, which sits on `list_row + list_height`.
    layout.preview_row = list_row + list_height + 1
    layout.preview_width = width
    layout.preview_height = math.max(1, usable_height - list_height)

    return layout
end

---@type table<ezpick.Picker.LayoutKind, fun(opts:table):ezpick.Picker.Layout>
local _builders = {
    horizontal = M.get_horizontal_layout,
    vertical = M.get_vertical_layout,
}

---Geometry for `kind`, falling back to the horizontal layout for anything the
---table does not name.
---@param kind ezpick.Picker.LayoutKind?
---@param opts {has_preview:boolean,height_ratio:number?,width_ratio:number?}
---@return ezpick.Picker.Layout
function M.build(kind, opts)
    return (_builders[kind] or M.get_horizontal_layout)(opts)
end

return M
