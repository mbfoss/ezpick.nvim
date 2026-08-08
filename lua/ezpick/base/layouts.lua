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

---@param opts {has_preview:boolean,height_ratio:number?,width_ratio:number?}
---@return ezpick.Picker.Layout
function M.get_horizontal_layout(opts)
    local cols = vim.o.columns
    local lines = M.usable_lines()

    local has_preview = opts.has_preview
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
    local list_height = _clamp(total_height - 3, 1, lines)

    local row = math.floor((lines - total_height - _BORDER_SPAN) / 2)
    local col = math.floor((cols - (list_width + preview_width + spacing) - _BORDER_SPAN) / 2)

    return {
        prompt_row = row,
        prompt_col = col,
        prompt_width = list_width + preview_width + spacing,
        prompt_height = 1,

        list_row = row + 3,
        list_col = col,
        list_width = list_width,
        list_height = list_height,

        preview_row = row + 3,
        preview_col = col + list_width + spacing,
        preview_width = preview_width,
        preview_height = list_height
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

    -- layout (top to bottom): prompt, gap, list, gap, preview (optional)

    local prompt_height = 1
    local gap = 2

    if not has_preview then
        local list_row = row + prompt_height + gap
        local list_height = total_height - prompt_height - gap

        return {
            prompt_row = row,
            prompt_col = col,
            prompt_width = width,
            prompt_height = prompt_height,

            list_row = list_row,
            list_col = col,
            list_width = width,
            list_height = list_height,

            preview_row = list_row,
            preview_col = col,
            preview_width = 0,
            preview_height = 0,
        }
    end

    local usable_height = total_height - prompt_height - (gap * 2)

    -- Even split, the odd row going to the list.
    local list_height = math.max(1, math.ceil(usable_height / 2))
    local preview_height = math.max(1, usable_height - list_height)

    local list_row = row + prompt_height + gap
    local preview_row = list_row + list_height + gap

    return {
        prompt_row = row,
        prompt_col = col,
        prompt_width = width,
        prompt_height = prompt_height,

        list_row = list_row,
        list_col = col,
        list_width = width,
        list_height = list_height,

        preview_row = preview_row,
        preview_col = col,
        preview_width = width,
        preview_height = preview_height,
    }
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
