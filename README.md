# ezpick.nvim

A fast, dependency-free fuzzy picker for Neovim.

ezpick ships a broad set of built-in sources — files, live grep, buffers, LSP
symbols and references, diagnostics, quickfix, keymaps, commands and more —
behind a single `:Pick` command. It can optionally take over `vim.ui.select`,
and other plugins can register their own sources.

> **Requires Neovim ≥ 0.11.** No plugin dependencies. `live_grep` requires
> [ripgrep](https://github.com/BurntSushi/ripgrep) on `$PATH`; every other
> source, `files` included, is pure Lua.

## Installation <!-- tag: installation -->

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

## Configuring the picker <!-- tag: configuration -->

`setup()` takes an optional table; every field has a default, so `setup()` with
no arguments is valid.

```lua
require("ezpick").setup({
  -- Sizing, picked per source by whether it has a preview to show. The ratios
  -- are fractions of the editor the whole picker spans, borders and all.
  with_preview        = {
    layout       = "horizontal", -- or "vertical", stacking the preview below the list
    width_ratio  = 0.8,
    height_ratio = 0.7,
  },
  without_preview     = {
    width_ratio  = 0.6,
    height_ratio = 0.7,
  },
  override_ui_select  = false, -- opt in to route vim.ui.select through the picker
  auto_complete_flags = true, -- auto-open flag completion while typing
})
```

## Using the picker <!-- tag: usage -->

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

### Built-in sources <!-- tag: built-ins -->

| Source | What it lists |
| --- | --- |
| `files` | Files under the cwd |
| `config_files` | Files under `stdpath("config")` |
| `recent_files` | The oldfiles list |
| `live_grep` | ripgrep results |
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
| `lsp_incoming_calls` | Call sites of the symbol under the cursor |
| `lsp_outgoing_calls` | Functions the symbol under the cursor calls |
| `lsp_document_symbols` | LSP symbols in the current buffer |
| `lsp_workspace_symbols` | LSP symbols across the workspace |
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
the server answers with exactly one. `lsp_workspace_symbols` asks the server once
with an empty query and filters the answer locally; servers that refuse an empty
query return nothing. `lsp_incoming_calls` lands on each call site inside the
caller, while `lsp_outgoing_calls` lands on each callee's own definition. `colorschemes` applies each scheme as the cursor moves over
it and restores the original one if the picker is closed without a choice.
`command_history` and `search_history` put the chosen entry back on the command
line unexecuted, ready to edit.

`resume` reopens the previous picker with its last query and cursor position,
without re-running the source's setup step.

### Keys inside a picker <!-- tag: keys -->

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

### Flags in a query <!-- tag: flags -->

Sources can accept inline flags in the query. **Flags go first**; everything
from the first non-flag word onward is the query, verbatim — spaces, backslashes
and dashes in it are ordinary characters, so a flag name only needs escaping when
the query itself starts with one. Completion opens as you type (disable with
`auto_complete_flags`).

Switches are written `--<name>`, filters `--<name> <value>` or
`--<name>=<value>`; escape with `\` to put a space (or a backslash) in a value —
`--dir my\ src`, `--dir a\\b`. Escaping follows Neovim's own rule for command
arguments (`:h <f-args>`), plus `\,` for a literal comma: only whitespace, `,`
and `\` are escapable, and a `\`
before anything else is the character it is. The glued `=` form is the exact one:
it can carry an empty value (`--filter=`) or a value that looks like a flag
(`--dir=--x`). Names are matched loosely — `--no-ignore`, `--noignore` and
`--NoIgnore` are the same flag.

A filter that takes several values takes them comma-separated, in one go:
`--type lua,rust`, `--filter *.lua,*.md`. Every flag is written at most once —
repeating one is a mistake, and the last occurrence wins.

A switch is set by being written, so it takes no value at all: `--hidden=false`
and `--hidden=true` are the same mistake, and both leave the switch alone rather
than guess which reading was meant.

A standalone `--` ends the flagged section, for the one case that needs it: a
query starting with a flag name. Only flags go in front of it: a `--`
written once the query has started cannot end a section that already ended, so
the picker underlines it and reports the word before it as an invalid flag.

Every mistake reads the same way. A typo'd flag, a forgotten value, a value
outside a flag's set or a flag written after the query gets an underline and a
short hint under the prompt, and the search stops until the line is one reading
or the other — a query with a mistake in it would search for something other
than what is written. The words of a hint about the flag the cursor is still
inside wait until the cursor moves on, so writing one out correctly is silent.

A query too long for one line wraps rather than scrolling out of sight, and the
prompt grows a row at a time to hold it — taking the rows from the list, up to an
even split with it.

`files` accepts `--dir`, `--case`, `--mode` (`fuzzy`|`fixed`|`glob`),
`--follow`, `--hidden`. `live_grep` accepts `--dir`, `--filter`, `--type`, `--case`,
`--regex`, `--word`, `--line`, `--invert`, `--follow`, `--hidden`,
`--no-ignore`, `--max-depth`. `marks` accepts
`--global` and `--buffer`, `registers` accepts `--empty`, and the symbol
sources accept one boolean per LSP symbol kind (`--Function`, `--Class`, …),
several of which are OR'd together.

```
:Pick files --hidden --dir ~/src
:Pick live_grep --regex --filter *.lua fn%s+%w+
:Pick live_grep --type lua,!markdown --word setup
:Pick live_grep --dir ~/src -- --hidden               " searches for "--hidden"
```

## Writing your own source <!-- tag: custom-sources -->

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

Built-ins and third-party sources share one flat namespace, so `register` never
overwrites: a name already taken gets a counter appended (`tasks` → `tasks_2`),
with a warning, and `register` returns the name actually used. Both sources stay
reachable, and load order decides which one keeps the plain name — prefix yours
(`myplugin.tasks`) to stay out of the race.

A name that could never be opened is an error rather than a warning: the empty
string, a name containing whitespace (`:Pick` splits its arguments on it), and
`resume` (handled by `:Pick` before the registry is consulted).

## Highlight groups <!-- tag: highlights -->

| Group | Links to |
| --- | --- |
| `EzPickMatch` | `Label` |
| `EzPickPath` | `@namespace` |
| `EzPickBufferIndicator` | `Special` |

Filetype icons in the file picker come from
[keystone.nvim](https://github.com/mbfoss/keystone.nvim) (`keystone.icons`,
highlighted with its `KeystoneIcons*` groups) when that plugin is installed.
Without it, rows are rendered without icons.

<!-- panvimdoc-ignore-start -->

## License

[MIT](LICENSE). See [ATTRIBUTIONS.md](ATTRIBUTIONS.md) for third-party credits.

<!-- panvimdoc-ignore-end -->
