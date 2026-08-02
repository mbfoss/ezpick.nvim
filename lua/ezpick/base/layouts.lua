local M = {}


---@type fun(v:number,min:number,max:number):number
local function _clamp(v, min, max)
    return math.max(min, math.min(max, v))
end

---@param opts {has_preview:boolean,height_ratio:number?,width_ratio:number?,list_width:number?}
---@return ezpick.Picker.Layout
function M.get_horizontal_layout(opts)
    local cols = vim.o.columns
    local lines = vim.o.lines

    local has_preview = opts.has_preview
    local spacing = has_preview and 2 or 0
    local half_spacing = math.floor(spacing / 2)

    local list_width = math.ceil(cols * _clamp(opts.width_ratio or 0.4, 0.1, 0.8))
    local preview_width
    if has_preview then
        local width = math.min(list_width * 2, cols)
        preview_width = _clamp(width - list_width - half_spacing, 1, width)
    else
        preview_width = 0
    end

    local total_height = math.ceil(lines * _clamp(opts.height_ratio or .7, 0.3, 0.8))
    local list_height = _clamp(total_height - 3, 1, lines)

    local row = math.floor((lines - total_height - 1) / 2)
    local col = math.floor((cols - (list_width + preview_width + spacing)) / 2)

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
    local lines = vim.o.lines

    local has_preview = opts.has_preview

    -- vertical layout defaults
    local width = math.ceil(cols * _clamp(opts.width_ratio or 0.4, 0.1, 0.9))
    local total_height = math.ceil(lines * _clamp(opts.height_ratio or 0.6, 0.3, 0.95))

    local row = math.floor((lines - total_height) / 2)
    local col = math.floor((cols - width) / 2)

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

    local list_height = math.max(1, math.floor(usable_height / 3))
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

return M
