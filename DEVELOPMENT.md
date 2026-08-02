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
lua/ezpick/init.lua      public API: setup, pick, register, repeat_last
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
  glob matching), and `make_history_provider`, which persists per-source query
  history under `stdpath("data")/ezpick/pickhist.<name>.txt`.
- **`queryflags.lua`** — parses inline `is:<flag>` / `<flag>:<value>` tokens out
  of the query, and drives flag completion. Values containing spaces are
  `"`-quoted; those quoting rules are local to the query line.
- **`layouts.lua`** — geometry for the list/preview floats.

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
