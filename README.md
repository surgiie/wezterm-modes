# wezterm-modes

A WezTerm plugin that gives your terminal a vim-like editing experience.

## Modes

| Mode    | Left status color | How to enter | Description |
|---------|------------------|--------------|-------------|
| INSERT  | Sky blue         | default; `i` from normal | Default mode; keystrokes pass through to the terminal |
| NORMAL  | Green            | `Escape` | Vim-like editing; all keybindings active |
| VISUAL  | Amber            | `v` from normal | WezTerm's built-in copy mode; press `v` again inside to begin selection |
| KEYMAP  | Purple           | `:` from normal | Listens for one configured keymap key, then runs it and returns to insert |

## Normal mode bindings

### Navigation

| Key              | Action                |
|------------------|-----------------------|
| `h/j/k/l`        | Arrow keys            |
| `w`              | Word forward          |
| `b`              | Word backward         |
| `e`              | Word end (forward)    |
| `{n}w/b/e`       | Repeat word motion `n` times (e.g. `3w`) |
| `0`              | Line start            |
| `$`              | Line end              |
| `^`              | First non-whitespace character (requires shell integration) |
| `G`              | End of input          |
| `gg`             | Start of input        |
| `CTRL+u`         | Scroll up half page   |
| `CTRL+d`         | Scroll down half page |
| `CTRL+f`         | Scroll down full page |
| `CTRL+b`         | Scroll up full page   |

Numeric prefixes (`1`-`9`, then any further digits) only apply to word motions and to `dw`/`db` below — other motions and operators don't accept a count.

### Editing

| Key       | Action                                  |
|-----------|------------------------------------------|
| `dd`      | Delete whole line                       |
| `dw`      | Delete word forward                     |
| `db`      | Delete word backward                    |
| `{n}dw/db`| Delete `n` words forward/backward (e.g. `3dw`) |
| `d$`      | Delete to end of line                   |
| `d0`      | Delete to start of line                 |
| `d^`      | Delete to start of line                 |
| `D`       | Delete to end of line                   |
| `C`       | Delete to end of line, enter insert     |
| `S`       | Delete whole line, enter insert         |
| `s`       | Delete char forward, enter insert       |
| `x`       | Delete char forward                     |
| `X`       | Delete char backward                    |
| `r{c}`    | Replace char under cursor with `{c}`    |
| `u`       | Undo (readline's line-edit undo — not a full vim undo stack) |
| `.`       | Repeat the last change (`x`, `X`, `D`, `dd`, `dw`, `db`, `d$`, `d0`, `d^`, `yd`, `r{c}`) |
| `yy`      | Yank (copy) current input line          |
| `yd`      | Yank and delete current input line      |
| `p`       | Paste from clipboard                    |
| `A`       | Move to end of line, enter insert       |
| `I`       | Move to start of line, enter insert     |

`.` does not repeat `s`, `S`, `C`, `A`, or `I` — those end by entering insert mode, and the plugin doesn't capture what you type afterward, so replaying just the delete portion would not match vim's actual `.` behavior for them.

### Other

| Key      | Action                   |
|----------|--------------------------|
| `v`      | Enter visual (copy) mode |
| `:`      | Enter keymap mode (listens for a configured keymap key) |
| `?`      | Fuzzy picker over keymaps |
| `i`      | Enter insert mode        |
| `Escape` | Pass escape through      |
| `CTRL+c` | Send CTRL+C              |
| `CTRL+z` | Send CTRL+Z              |
| `CTRL+l` | Send CTRL+L (clear)      |

## Custom keymaps

Custom keymaps are bound behind `:`, a dedicated keymap mode — press `:`, then the keymap's key. Configure them via `opts.keymaps`. Because keymap mode has its own namespace, keymaps are free to use any key, including ones vim normal mode already owns (`v`, `g`, `k`, etc.) — there's no conflict to configure around.

Single-char keys fire immediately after `:`. Two-char keys (e.g. `ga`) use the first char as a group prefix within keymap mode — the second key is awaited within the key table timeout.

A malformed or conflicting keymap (a key longer than 2 characters, a duplicate key, or a single-char key that collides with another keymap's two-char prefix) is logged via `wezterm.log_error` (visible in the WezTerm debug overlay, `CTRL+SHIFT+L`) and skipped, rather than raising and breaking the whole WezTerm config.

## Installation

**Via `wezterm.plugin.require`:**

```lua
local vim_modes = wezterm.plugin.require("https://github.com/surgiie/wezterm-modes")
vim_modes.apply_to_config(config)
```

**Via `dofile` (local development):**

```lua
local vim_modes = dofile(wezterm.home_dir .. "/projects/wezterm-modes/plugin/init.lua")
vim_modes.apply_to_config(config)
```

## Configuration

```lua
vim_modes.apply_to_config(config, {
    -- called each time a pane is focused to decide if the plugin runs;
    -- receives (pane, default_pane_is_shell) so you can reuse the default check
    should_run = function(pane, is_shell)
        return is_shell(pane)
    end,

    -- timeout in ms for multi-key sequences like gg, dd, yy (default: 2000)
    key_table_timeout = 2000,

    -- icon shown in the left status bar when the plugin is inactive (e.g. in an editor or TUI)
    icon = "🔥",

    -- custom keymaps bound behind ":" keymap mode (omit to disable)
    -- key: single char fires immediately after ":"; two chars use the first as a group prefix
    -- action: string or function(pane) → string
    -- execute: false types the action without running it (Enter not sent)
    -- <cursor>: placeholder — text before it is typed, cursor placed there, text after is typed and cursor moves back
    keymaps = {
        { key = "ga", description = "Git add all", action = "git add -A" },
        { key = "gc", description = "Git commit",  execute = false, action = "git commit -m '<cursor>'" },
        { key = "n",  description = "Open neovim", action = "nvim ." },
    },
})
```

## Shell integration

Required for `yy`, `yd`, and `^`. These operations use WezTerm's semantic zones to locate the current input line, which requires shell integration to be sourced. See the [WezTerm shell integration docs](https://wezterm.org/shell-integration.html) for setup instructions.
