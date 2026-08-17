# Development

Technical notes for working on ezpick.nvim.

## Requirements

- Neovim ≥ 0.11 (enforced at load time in [`plugin/ezpick.lua`](plugin/ezpick.lua))
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) for the test suite
- [ripgrep](https://github.com/BurntSushi/ripgrep) for the `files` and
  `live_grep` sources at runtime

## Testing

Tests use plenary.nvim's busted runner and live in [`tests/`](tests/), where
they are discovered by `PlenaryBustedDirectory`.

```bash
# Run the whole suite
make test

# Run against a custom plenary checkout
NVIM_PLENARY_DIR=/path/to/plenary.nvim make test
```

If `NVIM_PLENARY_DIR` is not set, plenary is cloned into `/tmp/plenary.nvim`
automatically. The runner is defined in the [`Makefile`](Makefile) and boots
Neovim headless with [`tests/init.lua`](tests/init.lua).

## Architecture

```
plugin/ezpick.lua        Neovim version guard (loaded on startup)
lua/ezpick/init.lua      public API: setup, pick, register, resume
lua/ezpick/registry.lua  name -> spec table for the built-in sources
lua/ezpick/select.lua    vim.ui.select implementation
lua/ezpick/base/         the picker engine
lua/ezpick/pickers/      one file per built-in source
lua/ezpick/icons.lua     filetype icons (optional, via keystone.nvim)
lua/ezpick/util/         shared low-level toolkit (vendored, see below)
tests/                   plenary busted specs
```

### The engine (`base`)

- **`picker.lua`** — the window, list rendering, preview, keymaps and the async
  fetch loop. Everything user-visible happens here.
- **`pickertools.lua`** — matching and highlighting helpers shared by sources:
  `match_label` (fuzzy subsequence + highlight chunks), `match_globs` (rg-style
  glob matching), the `file_preview` / `buffer_preview` loaders (the latter
  previews `data.bufnr` when that buffer is loaded and falls back to the file on
  disk), and `make_history_provider`, which persists per-source query history
  under `stdpath("data")/ezpick/pickhist.<name>.txt`.
- **`queryflags.lua`** — splits a query line into its leading `--<flag>` /
  `--<flag> <value>` / `--<flag>=<value>` section and the query, and drives flag
  completion. Flags come first and scanning stops at the first word that names
  none, so `ParseResult.query` is a verbatim slice from `query_start` — pickers
  that grep for what was typed depend on that. `\` escaping is local to a value
  and follows `:h <f-args>` plus the list separator: only whitespace, `,` and
  `\` are escapable. A `multi` flag takes its values comma-separated in one
  token (`--type lua,rust`) and comes back as a `string[]`; every flag is
  written at most once, and a repetition is hinted with the last one winning. A
  standalone `--` ends the flagged section for a query that must start with a
  flag name. `parse` never fails on what was typed: anything doubtful comes back
  as an advisory `ParseResult.hints` entry beside a usable query, which the
  picker underlines in the prompt rather than acting on. (A malformed *schema*
  does fail, at once — `strict` without `values` asserts.) Every problem is
  reported, including the half-written states a correct flag passes through:
  telling those apart takes the cursor, so the picker is where a hint is held
  back until the cursor leaves what it points at.
- **`layouts.lua`** — geometry for the list/preview floats. The prompt's height is
  an input: the picker measures what the query wraps to with
  `nvim_win_text_height` and asks for that many rows, which `_split_frame` grants
  out of the list's share, never past an even split with it.

### Sources

A source is a `ezpick.PickerSpec`: a `prompt`, a `finder` that turns
(query, flags) into items, an `on_confirm`, and optional `flags`, `previewer`,
`setup` and `quickfix_formatter`. Nothing about a source is special-cased by the
engine — the built-ins in [`lua/ezpick/pickers/`](lua/ezpick/pickers/) use
exactly the same interface as anything registered with `require("ezpick").register`.

[`registry.lua`](lua/ezpick/registry.lua) maps each built-in name to a *function*
returning its spec, so a source's module is only `require`d the first time it is
opened. Keep `setup()` cheap and defer heavy work to first use.

A `finder` may return a cancel function; the engine calls it when the query
changes or the picker closes, so long-running work (rg, LSP requests) must be
cancellable.

### Ranking

The engine sorts each result set by `item.score`, best first, before rendering.
A source opts in by passing through the score `match_label` gave it:

```lua
local match = pickertools.match_label(label, query)
if match then
    table.insert(items, { label_chunks = match.chunks, score = match.score, data = ... })
end
```

Two properties make this work without any per-source configuration:

- `match_label` reports **no score for an empty query**, so an unfiltered list
  always reads in the order its source produced — `lsp_references` by file and
  position, `buffers` by number, `marks` grouped local-then-global. Ranking only
  kicks in once there is a query to rank by.
- The sort is **stable**. `table.sort` is not, and equal scores are the common
  case, so the engine sorts an index array and breaks ties on position. Without
  that, equal-scoring rows reshuffle on every keystroke.

A source that leaves `score` unset is never reordered. Three do so deliberately,
each with the reason in the code: `spell_suggest` (`spellsuggest()` already ranks
by likelihood), `quickfix`/`loclist` (the list's order belongs to whatever built
it), and `jumplist` (recency is the reason you opened it).

A source can decline to open twice over: its spec builder may return `nil` (no
marks are set, no LSP client answers `workspace/symbol`), and an async `setup`
may call back with `nil` data. The LSP location sources use the latter to jump
straight to a lone result instead of showing a one-row picker.

`on_confirm` is called on *every* close, with `nil` when the picker was
dismissed — that is where a source undoes anything it did while previewing, as
`colorschemes` does when it restores the original scheme.

### Shared toolkit (`util`)

[`lua/ezpick/util/`](lua/ezpick/util/) is **vendored** from
[neotoolkit.nvim](https://github.com/mbfoss/neotoolkit.nvim) — do not edit it by
hand. Change it upstream, then re-vendor:

```bash
./scripts/vendor-neotoolkit.sh

# or against a local checkout
LOCAL=/path/to/neotoolkit.nvim ./scripts/vendor-neotoolkit.sh
```

The script copies only the modules ezpick needs (the transitive closure of
`Spinner`, `floatwin`, `fsutil`, `spawn`, `strutil`, `timer`, `ui`) and rewrites
`neotoolkit.` to `ezpick.util.`. Adding a new dependency means adding it to
`FILES` in the script.

### Icons

`lua/ezpick/icons.lua` holds no icon data. It resolves `keystone.icons` lazily
on first use and forwards to it; when keystone.nvim is not installed,
`get_icon` returns `nil` and rows are rendered without an icon. This keeps
ezpick free of hard plugin dependencies without duplicating keystone's icon
table.

## Coding style

- Add Lua annotations (`---@param`, `---@return`, `---@class`, …) wherever
  possible.
- **Class-based modules** are named in PascalCase; **functional modules** are
  named in snake_case.
- Module-scope `local` variables are prefixed with `_`, except: a module name
  from `require()`, the conventional `M` module table, and class types
  (`MyType`).
- Function-local variables are **not** prefixed with `_`.
- Inside a class, private members are prefixed with `_`.
- Avoid `pcall()` when it isn't required.
