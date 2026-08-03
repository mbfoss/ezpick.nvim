# ezpick.nvim

A fast, dependency-free fuzzy picker for Neovim.

ezpick ships a broad set of built-in sources — files, live grep, buffers, LSP
symbols and references, diagnostics, quickfix, keymaps, commands and more —
behind a single `:Pick` command. It can optionally take over `vim.ui.select`,
and other plugins can register their own sources.

> **Requires Neovim ≥ 0.11.** No plugin dependencies. `live_grep` requires
> [ripgrep](https://github.com/BurntSushi/ripgrep) on `$PATH`; every other
> source, `files` included, is pure Lua.

## Installation

**lazy.nvim**

```lua
{
  "mbfoss/ezpick.nvim",
  config = function()
    require("ezpick").setup()
  end,
}
```

**Built-in packages** (`:help packages`)

```
git clone https://github.com/mbfoss/ezpick.nvim \
  ~/.config/nvim/pack/plugins/opt/ezpick.nvim
```

Then in your config:

```lua
vim.cmd.packadd("ezpick.nvim")
require("ezpick").setup()
```

## Configuration

`setup()` takes an optional table; every field has a default, so `setup()` with
no arguments is valid.

```lua
require("ezpick").setup({
  override_ui_select  = true, -- route vim.ui.select through the picker
  auto_complete_flags = true, -- auto-open flag completion while typing
})
```

## Usage

Open a source with `:Pick`, which completes both source names and their flags:

```vim
:Pick files
:Pick live_grep
:Pick buffers
```

An extra argument seeds the initial query:

```vim
:Pick live_grep TODO
```

`:Pick` with no argument lists the available sources through `vim.ui.select`.

### Built-in sources

| Source | What it lists |
| --- | --- |
| `files` | Files under the cwd |
| `config_files` | Files under `stdpath("config")` |
| `recent_files` | The oldfiles list |
| `live_grep` | ripgrep results, with optional search & replace |
| `buffer_lines` | Non-blank lines of the current buffer |
| `buffers` | Loaded buffers |
| `windows` | Open windows |
| `quickfix` / `loclist` | The quickfix or location list |
| `jumplist` | The jump list |
| `marks` | Buffer-local and global marks |
| `lsp_references` | References to the symbol under the cursor |
| `lsp_definitions` | Definitions of the symbol under the cursor |
| `lsp_declarations` | Declarations of the symbol under the cursor |
| `lsp_implementations` | Implementations of the symbol under the cursor |
| `lsp_type_definitions` | Type definitions of the symbol under the cursor |
| `document_symbols` | LSP symbols in the current buffer |
| `workspace_symbols` | LSP symbols across the workspace, queried live |
| `document_diagnostics` | Diagnostics in the current buffer |
| `workspace_diagnostics` | Diagnostics across the workspace |
| `keymaps` | Mappings, with their source location |
| `commands` | User and built-in commands |
| `command_history` / `search_history` | `:` and `/` history, newest first |
| `autocommands` | Registered autocommands |
| `highlights` | Highlight groups |
| `colorschemes` | Installed colorschemes, applied as you move |
| `registers` | Register contents |
| `help_tags` | `:help` tags from the runtimepath |
| `spell_suggest` | Spelling suggestions for the word under the cursor |

The four location sources (`lsp_definitions`, `lsp_declarations`,
`lsp_implementations`, `lsp_type_definitions`) jump straight to their target when
the server answers with exactly one. `colorschemes` applies each scheme as the
cursor moves over it and restores the original one if the picker is closed
without a choice. `command_history` and `search_history` put the chosen entry
back on the command line unexecuted, ready to edit.

`repeat_last` reopens the previous picker with its last query and cursor
position, without re-running the source's setup step.

### Keys

Inside a picker, `g?` shows the full list:

| Key | Action |
| --- | --- |
| `<CR>` | Confirm |
| `<Esc>` | Close |
| `<C-n>` / `<C-p>` | Next / previous item |
| `<C-d>` / `<C-u>` | Scroll half a page |
| `<C-j>` / `<C-k>` | Next / previous history entry |
| `<C-q>` | Send results to the quickfix list |
| `<C-r><C-w>` | Insert the original `<cword>` |

### Query flags

Sources can accept inline flags in the query. Boolean flags are written
`is:<name>`, value flags `<name>:<value>`; wrap a value in `"` if it contains
spaces. Completion opens as you type (disable with `auto_complete_flags`).

Everything after a standalone `--` is taken as literal query text: no flags, no
quoting, spacing kept as typed. Use it to search for something that would
otherwise look like a flag.

`files` accepts `dir:`, `case:`, `is:fixed`, `is:glob`, `is:follow`,
`is:hidden`. `live_grep` accepts `dir:`, `filter:`, `case:`, `replace:`,
`is:regex`, `is:follow`, `is:hidden`, `is:no-ignore`. `marks` accepts
`is:global` and `is:buffer`, `registers` accepts `is:empty`, and the symbol
sources accept one boolean per LSP symbol kind (`is:Function`, `is:Class`, …),
several of which are OR'd together.

```
:Pick files is:hidden dir:~/src
:Pick live_grep is:regex filter:*.lua fn%s+%w+
:Pick live_grep dir:~/src -- is:hidden   " searches for the text "is:hidden"
```

## Registering your own source

```lua
require("ezpick").register("my_source", {
  prompt     = "My source",
  finder     = function(query, flags, fetch_opts, callback)
    callback({ { label_chunks = { { "an item" } }, data = { ... } } })
  end,
  on_confirm = function(data) ... end,
})
```

The spec may also be a function returning a spec, in which case it is built
lazily on each open. See the `ezpick.PickerSpec` annotation in
[`lua/ezpick/init.lua`](lua/ezpick/init.lua) for every field.

## Highlight groups

| Group | Links to |
| --- | --- |
| `EzPickMatch` | `Label` |
| `EzPickPath` | `@namespace` |
| `EzPickBufferIndicator` | `Special` |

Filetype icons in the file picker come from
[keystone.nvim](https://github.com/mbfoss/keystone.nvim) (`keystone.icons`,
highlighted with its `KeystoneIcons*` groups) when that plugin is installed.
Without it, rows are rendered without icons.

## License

[MIT](LICENSE). See [ATTRIBUTIONS.md](ATTRIBUTIONS.md) for third-party credits.
