# marksetta.nvim

Neovim plugin for [marksetta](https://github.com/merv1n34k/marksetta) — real-time `.mx` compilation with live PDF preview via [texpresso](https://github.com/let-def/texpresso).

Uses texpresso.vim's protocol API to send incremental `change-lines` updates instead of file-watching, targeting ~50ms edit-to-render latency.

## Requirements

- Neovim 0.10+
- [marksetta](https://github.com/merv1n34k/marksetta) — Lua library (must be in Lua path)
- [texpresso.vim](https://github.com/let-def/texpresso.vim) — optional, for live PDF preview

Without texpresso.vim, the plugin still compiles `.mx` files and writes TeX/Markdown to disk.

## Installation

### vim.pack (Neovim 0.12+)

```lua
vim.pack.add({
  "https://github.com/let-def/texpresso.vim",
  "https://github.com/merv1n34k/marksetta.nvim",
})

require("marksetta-nvim").setup()
```

### lazy.nvim

```lua
{
  "merv1n34k/marksetta.nvim",
  dependencies = { "let-def/texpresso.vim" },
  ft = "mx",
  opts = {},
}
```

## Configuration

```lua
require("marksetta-nvim").setup({
  debounce_ms = 50,       -- debounce interval for recompilation
  auto_start = false,     -- auto-launch texpresso on .mx file open
  pattern = "*.mx",       -- file pattern to watch
  outputs = {
    ["output/out.tex"] = { format = "tex", include = { "*" } },
    ["output/out.md"]  = { format = "md",  include = { "*" } },
  },
})
```

## Commands

| Command | Description |
|---|---|
| `:MarksettaStart` | Compile and launch texpresso for live preview |
| `:MarksettaStop` | Stop texpresso |
| `:MarksettaToggle` | Toggle texpresso |

## How it works

1. Edits to `.mx` buffers trigger a debounced recompilation via `marksetta.compile()` with `source_map=true`
2. The source map provides chunk-level output line ranges
3. Changed chunks are sent as `change-lines` commands to texpresso — no full file reloads
4. If chunk structure changes drastically, falls back to a full `open` reload
5. TeX output is always written to disk as well, keeping the file in sync

## License

Distributed under the MIT License. See `LICENSE` for more information.
