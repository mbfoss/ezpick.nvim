# Attributions

This project uses or is based on the following third-party projects:

## External programs (not bundled)

- **[ripgrep](https://github.com/BurntSushi/ripgrep)** (MIT or Unlicense) — the
  `livegrep` picker shells out to `rg` when it is on the user's `PATH`. ripgrep
  is invoked as a separate process; no part of it is bundled or modified.

## Runtime integrations (not bundled)

- Icon providers — `nvim-web-devicons`, `keystone.nvim` or `mini.icons`,
  whichever the user has installed (probed in that order). ezpick ships no
  icon data of its own and requires no particular provider; see
  `lua/ezpick/icons.lua`.

None of these are vendored. Where ezpick covers the same ground as an existing
picker plugin, the implementation was written for this plugin from Neovim's
public API rather than adapted from that plugin's source.

## Development-time only (not distributed)

- **[panvimdoc](https://github.com/kdheepak/panvimdoc)** (MIT) — generates
  `doc/ezpick.txt` from `README.md`; see `scripts/gendoc.sh`.
- **[busted](https://github.com/lunarmodules/busted)** and
  **[luassert](https://github.com/lunarmodules/luassert)** (MIT), and
  **[nlua](https://github.com/mfussenegger/nlua)** (GPL-3.0) — the test
  toolchain. These are installed locally by the developer and invoked as
  separate programs; no part of them is linked into or shipped with this plugin.
