local M = {}

local pickertools = require("ezpick.base.pickertools")

---@type ezpick.queryflags.FlagDef[]
local FLAGS = {
    { name = "event", type = "value", multi = true, desc = "filter by event name" },
    { name = "group", type = "value", multi = true, desc = "filter by augroup"    },
    { name = "pat",   type = "value", multi = true, desc = "filter by pattern"    },
}

---@param ac vim.api.keyset.get_autocmds.ret
local function format_preview(ac)
    local function fmt(val)
        if val == nil then return nil end
        if type(val) == "table"   then return table.concat(val, ", ") end
        if type(val) == "boolean" then return val and "true" or "false" end
        return tostring(val)
    end

    local function add(lines, label, value)
        local v = fmt(value)
        if v and v ~= "" then
            table.insert(lines, string.format("- %s: %s", label, v))
        end
    end

    local lines = {}
    add(lines, "ID",          ac.id)
    add(lines, "Group",       ac.group_name or ac.group)
    add(lines, "Event",       ac.event)
    add(lines, "Pattern",     ac.pattern or "*")
    add(lines, "Description", ac.desc)
    add(lines, "Once",        ac.once)
    add(lines, "Buflocal",    ac.buflocal)
    ---@diagnostic disable-next-line: undefined-field
    add(lines, "Buffer",      ac.buffer)

    table.insert(lines, "")
    table.insert(lines, "Action:")

    if ac.command and ac.command ~= "" then
        vim.list_extend(lines, vim.split(ac.command, "\n"))
    elseif ac.callback then
        local info = debug.getinfo(ac.callback, "S")
        table.insert(lines, "- Type: Lua callback")
        if info then
            if info.short_src   then table.insert(lines, string.format("- Source: `%s`", info.short_src)) end
            if info.linedefined then table.insert(lines, string.format("- Line: %d",     info.linedefined)) end
        end
    else
        table.insert(lines, "_No action defined_")
    end

    return table.concat(lines, "\n")
end

---@return ezpick.PickerSpec?
function M.spec()
    local entries = vim.api.nvim_get_autocmds({})

    if vim.tbl_isempty(entries) then
        vim.notify("No autocommands found", vim.log.levels.WARN)
        return nil
    end

    return {
        prompt          = "Autocommands",
        flags           = FLAGS,
        enable_preview  = true,
        finder          = function(query, flags, _, callback)
            local items = {}

            for _, ac in ipairs(entries) do
                local group   = (ac.group_name or ac.group or ""):lower()
                local event   = (ac.event or ""):lower()
                local pattern = (ac.pattern and ac.pattern ~= "" and ac.pattern or "*"):lower()

                local skip = false
                for _, v in ipairs(flags.event or {}) do
                    if not event:find(v:lower(), 1, true) then skip = true; break end
                end
                if not skip then
                    for _, v in ipairs(flags.group or {}) do
                        if not group:find(v:lower(), 1, true) then skip = true; break end
                    end
                end
                if not skip then
                    for _, v in ipairs(flags.pat or {}) do
                        if not pattern:find(v:lower(), 1, true) then skip = true; break end
                    end
                end
                if skip then goto continue end

                local label = string.format(
                    "%s │ %s │ %s",
                    ac.group_name or ac.group or "",
                    ac.event or "",
                    (ac.pattern and ac.pattern ~= "") and ac.pattern or "*"
                )

                local match      = query ~= "" and pickertools.match_label(label, query)
                    or { chunks = { { label } } }
                local virt_line  = (ac.desc and ac.desc ~= "") and { { ac.desc, "Comment" } } or nil

                if match then
                    table.insert(items, {
                        label_chunks = match.chunks,
                        virt_line    = virt_line,
                        data         = { ac = ac },
                    })
                end

                ::continue::
            end
            callback(items)
        end,
        previewer = function(data, _, callback)
            callback({ content = format_preview(data.ac) })
            return function() end
        end,
        on_confirm = function(item)
            if not item then return end
            vim.notify(
                string.format("Autocmd: %s [%s]", item.command, item.event),
                vim.log.levels.INFO
            )
        end,
    }
end

return M
