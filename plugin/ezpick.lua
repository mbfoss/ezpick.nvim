if vim.fn.has("nvim-0.11") ~= 1 then
    error("ezpick.nvim requires Neovim >= 0.11")
end

if vim.g.loaded_ezpick then return end
vim.g.loaded_ezpick = true

-- Nothing under `lua/ezpick/` is required here: the command and the highlight
-- groups are all that has to exist before the first pick, so they are written
-- out rather than pulled in. `ezpick.apply_highlights()` states the same groups
-- for the `colorschemes` source, which re-applies them after a scheme switch.
vim.api.nvim_set_hl(0, "EzPickMatch", { default = true, link = "Visual" })
vim.api.nvim_set_hl(0, "EzPickPath", { default = true, link = "@namespace" })
vim.api.nvim_set_hl(0, "EzPickBufferIndicator", { default = true, link = "Special" })
vim.api.nvim_set_hl(0, "EzPickFlagPill", { default = true, link = "Visual" })

vim.api.nvim_create_user_command("Ezpick", function(cmd_opts)
    require("ezpick.cmdline").run(cmd_opts)
end, {
    nargs    = "*",
    desc     = "Picker for files, grep etc...",
    complete = function(arg_lead, cmd_line, cursor_pos)
        return require("ezpick.cmdline").complete(arg_lead, cmd_line, cursor_pos)
    end,
})
