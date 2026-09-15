# lack.nvim

Declare plugins with familiar table syntax.

`lack.nvim` is a thin, declarative front-end for `vim.pack.add()`. It resolves
sources, gathers nested dependencies, and passes one deduplicated,
dependency-ordered list to Neovim's native package manager.

## Motivation and scope

I believe `vim.pack` is good enough, but I prefer the declarative style of
`lazy.nvim` or `packer.nvim`. However, I don't find any use for lazy loading,
plugin configuration, or any of the other advanced features that those plugins
provide.

So, lazy + pack = lack.

`lack.nvim` intentionally provides only declaration shorthand and dependency
collection. It does not provide:

- lazy loading
- plugin configuration execution
- commands or a user interface
- build orchestration
- version consolidation across separate `lack()`/`vim.pack.add()` calls
  (`lack.nvim` only warns; see [Dependencies](#dependencies))
- a lockfile
- updates, removal, or automatic bootstrap behavior

Installation, loading, updates, removal, and lockfile handling remain native
`vim.pack` responsibilities.

## Requirements

- Neovim 0.12 or newer
- Git

`vim.pack` is currently experimental, so its API may change between Neovim
releases.

## Installation

Add `lack.nvim` near the beginning of your `init.lua`. `load = true` makes the
module available immediately during startup:

```lua
vim.pack.add({ "https://github.com/eduardomcv/lack.nvim" }, {
  load = true,
})

local lack = require("lack")
```

To stay on a specific release, set `version` to a published tag:

```lua
vim.pack.add({
  {
    src = "https://github.com/eduardomcv/lack.nvim",
    version = "v0.1.0",
  },
}, {
  load = true,
})

local lack = require("lack")
```

Use a range instead to allow compatible `0.1.x` updates:

```lua
version = vim.version.range("~0.1.0")
```

## Usage

```lua
lack({
  {
    "nvim-telescope/telescope.nvim",
    dependencies = {
      "nvim-lua/plenary.nvim",
    },
  },
})

require("telescope").setup({})
```

`lack.nvim` only declares plugins. Configuration remains ordinary Lua and native
`vim.pack` loading rules still apply.

### Specifications

Strings, positional tables, and `src` fields use the same source-resolution
path:

```lua
lack({
  "owner/string-plugin",
  { "owner/positional-plugin" },
  { src = "owner/src-plugin" },
})
```

`src` takes precedence if a table contains both `src` and a positional source.
Native fields such as `name`, `version`, and `data` are forwarded unchanged:

```lua
lack({
  {
    "owner/plugin",
    name = "plugin",
    version = "v1.2.3",
    data = { channel = "stable" },
  },
}, {
  confirm = false,
})
```

Fields unknown to `lack.nvim` are also forwarded, but `lack.nvim` does not execute
lazy.nvim-style `config`, `init`, `opts`, or build hooks.

### Sources

Bare sources are prefixed with `https://github.com/` by default. Sources using
`scheme://` or SCP-style `user@host:path` syntax pass through unchanged:

```lua
lack({
  "owner/github-plugin",
  "https://example.com/owner/https-plugin",
  "ssh://git@example.com/owner/ssh-plugin",
  "git@example.com:owner/scp-plugin",
  "file:///absolute/path/local-plugin",
})
```

Set another repository prefix before declaring plugins:

```lua
require("lack").setup({
  repository = "https://gitlab.com/",
})
```

Trailing slashes are normalized to one slash.

### Global

lack.nvim does not register a global. Assign the module yourself if you prefer
calling it without `require`:

```lua
_G.use = require("lack")

use({ "owner/plugin" })
```

`lack.Module` is inferred automatically, giving completion and diagnostics on
`use`, as long as `lack.nvim`'s `lua` directory is on LuaLS's
`workspace.library`.

### Dependencies

Dependencies may be nested to any depth:

```lua
lack({
  {
    "NeogitOrg/neogit",
    dependencies = {
      "nvim-lua/plenary.nvim",
      {
        "sindrets/diffview.nvim",
        dependencies = {
          "nvim-lua/plenary.nvim",
        },
      },
    },
},
})
```

`lack.nvim` gathers every relationship, emits each effective native plugin name
once, and orders dependencies before their dependents. Independent plugins
retain declaration order where the graph permits it. Dependency cycles are
reported before `vim.pack.add()` is called.

When a plugin occurs more than once, the first occurrence supplies its fields
and stable position while every occurrence contributes dependencies. Versions
merge regardless of declaration order:

- A missing version means "any" and never conflicts with an explicit version.
- Two [`vim.version.range()`](<https://neovim.io/doc/user/lua.html#vim.version.range()>)
  values merge into their intersection.
- A semver pin found inside a declared range wins over the range.
- A resolved source conflict, disjoint ranges, a pin outside a declared range,
  or a range paired with a non-semver version (a branch or commit) all
  produce a `lack:` error.

Version merging only applies within a single `lack()` call. If a plugin is
already active with a different version from an earlier call in the same
session, `vim.pack` silently keeps the first call's version; `lack.nvim` emits a
`vim.notify()` warning in that case so the inconsistency is visible. Collect
every declaration into one `lack()` call to resolve versions globally instead.

Each `lack()` invocation results in exactly one call:

```lua
vim.pack.add(resolved_plugins, opts)
```

## Development

Run the checks from the repository root:

```sh
stylua --check lua tests
luacheck lua tests
nvim --headless --clean -u tests/minimal_init.lua -l tests/lack_spec.lua
```

The included LuaLS configuration reads Neovim's Lua annotations from
`${env:VIMRUNTIME}/lua`. Ensure `VIMRUNTIME` is exported when LuaLS is launched
outside Neovim.

## License

[MIT](LICENSE)
