# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Run tests (requires nvim + plenary.nvim)
make test

# Run tests with a custom plenary path
NVIM_PLENARY_DIR=/path/to/plenary.nvim make test
```

Tests use [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)'s busted runner. If `NVIM_PLENARY_DIR` is not set, plenary is cloned into `/tmp/plenary.nvim` automatically. Tests live in `tests/` and are discovered by `PlenaryBustedDirectory`.

Requires Neovim >= 0.11.

## Architecture

ezpick is a standalone fuzzy picker with no plugin dependencies. `lua/ezpick/base/` is the engine, `lua/ezpick/pickers/` holds one file per built-in source, and `lua/ezpick/registry.lua` maps source names to lazily-built specs.

`lua/ezpick/util/` is vendored from neotoolkit.nvim via `scripts/vendor-neotoolkit.sh` — change it upstream and re-vendor rather than editing in place.

See DEVELOPMENT.md for details.

### Styling

Add Lua annotations (`---@param`, `---@return`, `---@class`, etc.) whenever possible.

Class-based modules are named in PascalCase and functional modules are named in snake_case.

Module local variable names that are not required module names or function names are to be prefixed with underscore

Function local variable names should NOT begin with underscore

module-scope `local` variables should be prefixed with `_` with exception: 
- a local module name from `require()`
- the typical `M` module table.
-  class types like `MyType`

Inside a class, private members are prefixed with `_`

avoid pcall() when not required
