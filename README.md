# wezterm-modes

A WezTerm plugin that gives your terminal a vim-like editing experience.

## Modes

| Mode    | Left status color | How to enter | Description |
|---------|------------------|--------------|-------------|
| INSERT  | Blue             | default; `i` from normal | Default mode; keystrokes pass through to the terminal |
| NORMAL  | Green            | `Escape` | Vim-like editing; all keybindings active |
| VISUAL  | Amber            | `v` from normal | WezTerm's built-in copy mode; press `v` again inside to begin selection |
| KEYMAP  | Purple           | `:` from normal | Listens for one configured keymap key, then runs it and returns to insert |
| JUMP    | Red              | `J` from normal | Label-jump pick; left status shows the label:word legend until you type one |

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
| `J`              | Label-jump: type a token's label on the current input line, cursor moves there (requires shell integration) |
| `CTRL+u`         | Scroll up half page   |
| `CTRL+d`         | Scroll down half page |
| `CTRL+f`         | Scroll down full page |
| `CTRL+b`         | Scroll up full page   |

Numeric prefixes (`1`-`9`, then any further digits) only apply to word motions and to `dw`/`db` below — other motions and operators don't accept a count.


#### Jumping

Switch to "jump" mode from normal mode via `J` key. This mode is useful for quickly moving the cursor to a specific token on the current line. This mode will update the left status bar with a legend of labels corresponding to each token on the current line, e.g the left status bar will display something like `JUMP  f:kubectl  j:exec  d:example-app  s:-it  a:--  l:bash` which allow you to move the cursor to the start of a selected token by typing the corresponding label key. In this example, typing `d` will move the cursor to the start of `example-app`.


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

## Keymap mode

Keymap mode lets you define custom commands to register as keyboard shortcuts that can be executed while in this mode. Switch to keymap mode from normal mode via `:` key.

#### Example

```lua
keymaps = {
    { key = "ga", description = "Git add all", action = "git add ." },
},
```

You can type `:` to enter keymap mode, then type `ga` to execute the command `git add .`


## Starship integration

Show the current mode in your [starship](https://starship.rs) prompt instead of (or alongside) the left status badge.

How it works:

1. The plugin writes the mode label (e.g. `NORMAL`) to `$XDG_RUNTIME_DIR/wezterm-modes/<pane_id>` whenever it changes (`/tmp` if `XDG_RUNTIME_DIR` is unset).
2. It then sends the shell a private escape sequence (`ESC [ 9001 ~`) so the shell redraws its prompt. This is only sent when the pane's foreground process is a shell that is at its prompt, never to a TUI, REPL or running command. A redraw that couldn't be sent is retried on a later tick.
3. A starship custom module reads the file for the shell's own pane (`$WEZTERM_PANE`).

Setup takes three pieces, and the shell binding should be in place before you enable the plugin option.

#### 1. Shell binding (zsh)

Bind the sequence to a widget that resets the prompt:

```zsh
wezterm-modes-redraw() { zle reset-prompt }
zle -N wezterm-modes-redraw
bindkey $'\e[9001~' wezterm-modes-redraw
```

With zsh's vi keymaps, also bind it in `viins` and `vicmd` (`bindkey -M viins ...`). Without a binding the shell prints the sequence's trailing characters at the prompt; set `redraw_sequence = false` if you don't want a redraw at all.

Also have the shell report whether it is at its prompt, so the redraw is never sent into a running command (e.g. an fzf launched by a bash script) and is retried once the prompt returns:

```zsh
wezterm-modes-prompt-state() { printf '\e]1337;SetUserVar=wezterm_modes_prompt=%s\a' "$1" }
wezterm-modes-line-init() { wezterm-modes-prompt-state MQ== }
wezterm-modes-line-finish() { wezterm-modes-prompt-state MA== }
wezterm-modes-prompt-preexec() { wezterm-modes-prompt-state MA== }
autoload -Uz add-zle-hook-widget
add-zle-hook-widget line-init wezterm-modes-line-init
add-zle-hook-widget line-finish wezterm-modes-line-finish
preexec_functions+=(wezterm-modes-prompt-preexec)
```

(`MQ==` and `MA==` are `1` and `0` in base64.) Report from the zle hooks rather than `precmd`: `precmd` runs before the shell is reading input, so a redraw sent in that window is echoed by the tty and ends up as literal `[9001~` in the line.

This is required for the redraw: a pane is only treated as being at a prompt once its shell has reported `1`, so nothing is sent while the shell is still loading its rc files or while a command runs. Until then the badge stays visible even with `badge = false`.

#### 2. Starship modules

Starship can't change a style based on a command's output, so use one module per mode. Each `when` checks the state file using shell builtins only:

```toml
format = """
${custom.wezterm_normal}${custom.wezterm_insert}${custom.wezterm_visual}${custom.wezterm_keymap}${custom.wezterm_leader}${custom.wezterm_jump}${custom.wezterm_jump_legend}$directory$character"""

[custom.wezterm_normal]
when = 'read -r mode 2>/dev/null < "${XDG_RUNTIME_DIR:-/tmp}/wezterm-modes/$WEZTERM_PANE"; [ "$mode" = NORMAL ]'
format = '[ NORMAL ](bg:#1c1c1c fg:#a4e400 bold)'

[custom.wezterm_insert]
when = 'read -r mode 2>/dev/null < "${XDG_RUNTIME_DIR:-/tmp}/wezterm-modes/$WEZTERM_PANE"; [ "$mode" = INSERT ]'
format = '[ INSERT ](bg:#1c1c1c fg:#5fafd7 bold)'

[custom.wezterm_visual]
when = 'read -r mode 2>/dev/null < "${XDG_RUNTIME_DIR:-/tmp}/wezterm-modes/$WEZTERM_PANE"; [ "$mode" = VISUAL ]'
format = '[ VISUAL ](bg:#1c1c1c fg:#e0a060 bold)'

[custom.wezterm_keymap]
when = 'read -r mode 2>/dev/null < "${XDG_RUNTIME_DIR:-/tmp}/wezterm-modes/$WEZTERM_PANE"; [ "$mode" = KEYMAP ]'
format = '[ KEYMAP ](bg:#1c1c1c fg:#c792ea bold)'

[custom.wezterm_leader]
when = 'read -r mode 2>/dev/null < "${XDG_RUNTIME_DIR:-/tmp}/wezterm-modes/$WEZTERM_PANE"; [ "$mode" = LEADER ]'
format = '[ LEADER ](bg:#1c1c1c fg:#ffff87 bold)'

[custom.wezterm_jump]
when = 'read -r mode 2>/dev/null < "${XDG_RUNTIME_DIR:-/tmp}/wezterm-modes/$WEZTERM_PANE"; [ "$mode" = JUMP ]'
format = '[ JUMP ](bg:#1c1c1c fg:#ff5555 bold)'

[custom.wezterm_jump_legend]
when = 'test -s "${XDG_RUNTIME_DIR:-/tmp}/wezterm-modes/$WEZTERM_PANE.jump"'
command = 'read -r legend < "${XDG_RUNTIME_DIR:-/tmp}/wezterm-modes/$WEZTERM_PANE.jump"; printf %s "$legend"'
format = '[ $output ](bg:#1c1c1c fg:#d0d0d0)'
```

Use `;` rather than `&&` after `read`: the state file has no trailing newline, so `read` exits non-zero even though it sets `mode`. Outside WezTerm (or with no state file) every module is hidden.

`wezterm_jump_legend` is optional. While a `J` pick is in progress the plugin also writes the `label:word` legend to `<pane_id>.jump` next to the state file and redraws the prompt as the legend narrows, so the hints show beside the JUMP block as well as in the WezTerm status bar. The file is removed when the pick ends.

#### 3. Plugin option

```lua
vim_modes.apply_to_config(config, {
    starship = {
        badge = false,                          -- hide the left-status badge at shell prompts (default: true)
        -- state_dir = "/some/dir",             -- default: $XDG_RUNTIME_DIR/wezterm-modes
        -- redraw_sequence = "\27[9001~",       -- or false to skip the prompt redraw
        -- debug = true,                        -- log per-pane active/at_shell/label changes (WezTerm debug overlay, Ctrl+Shift+L)
    },
})

config.status_update_interval = 150
```

`update-status` only fires on a timer, so the prompt lags a mode change by up to `status_update_interval` ms. Lower it for a snappier prompt.

With `badge = false` the badge is still shown in panes that are not at a shell prompt but where the plugin runs (e.g. a REPL allowed by your `should_run`), since starship isn't visible there.

Run the plugin tests with `lua tests/run.lua`.

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

    -- Customize the left status prefix, useful if you want to customize or inject something custom on the left side of the left bar when renders on every tick:
    --   left_status_prefix = function(pane)
    --       if pane:get_user_vars().my_app_open ~= "1" then
    --           return ""
    --       end
    --       return wezterm.format({
    --           { Background = { Color = "#050505" } },
    --           { Text = "   " },
    --       })
    --   end,
    left_status_prefix = nil,

    -- show the mode in your starship prompt; see "Starship integration" (omit to disable)
    starship = nil,

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

    -- label alphabet for J (word-jump), most-reachable keys first
    -- (default: "fjdkslaghrueiwotnvbc")
    jump_keys = "fjdkslaghrueiwotnvbc",

    -- Lua pattern selecting J's targets (default: "%S+" — every
    -- whitespace-separated token, so "pod-edge-0" or "-it" are each one
    -- target rather than split at their dashes)
    jump_pattern = "%S+",
})
```

## Shell integration

Required for `yy`, `yd`, `^`, and `J`. These operations use WezTerm's semantic zones to locate the current input line, which requires shell integration to be sourced. See the [WezTerm shell integration docs](https://wezterm.org/shell-integration.html) for setup instructions.

### Zsh Setup

Add the following to your `.zshrc` to enable the plugin's mode display in your starship prompt:

```zsh
# wezterm-modes sends \e[9001~ on mode change so starship can show the new mode.
if [[ -n $WEZTERM_PANE ]]; then
    wezterm-modes-redraw() { zle reset-prompt }
    zle -N wezterm-modes-redraw
    bindkey $'\e[9001~' wezterm-modes-redraw

    # Report "at prompt" only once zle is reading input; precmd is too early
    # (other precmd work still runs and the tty is not reading yet).
    wezterm-modes-prompt-state() { printf '\e]1337;SetUserVar=wezterm_modes_prompt=%s\a' "$1" }
    wezterm-modes-line-init() { wezterm-modes-prompt-state MQ== }
    wezterm-modes-line-finish() { wezterm-modes-prompt-state MA== }
    wezterm-modes-prompt-preexec() { wezterm-modes-prompt-state MA== }
    autoload -Uz add-zle-hook-widget
    add-zle-hook-widget line-init wezterm-modes-line-init
    add-zle-hook-widget line-finish wezterm-modes-line-finish
    preexec_functions+=(wezterm-modes-prompt-preexec)
fi
```

**With vi keybindings:** If you use zsh's vi keybindings, also add the bindings to the `viins` and `vicmd` keymaps:

```zsh
bindkey -M viins $'\e[9001~' wezterm-modes-redraw
bindkey -M vicmd $'\e[9001~' wezterm-modes-redraw
```

### Starship Configuration

To display the mode in your starship prompt, add custom modules to your `starship.toml`:

```toml
[custom.wezterm_normal]
when = 'read -r mode 2>/dev/null < "${XDG_RUNTIME_DIR:-/tmp}/wezterm-modes/$WEZTERM_PANE"; [ "$mode" = NORMAL ]'
format = '[ NORMAL ](bg:#1c1c1c fg:#a4e400 bold)'

[custom.wezterm_insert]
when = 'read -r mode 2>/dev/null < "${XDG_RUNTIME_DIR:-/tmp}/wezterm-modes/$WEZTERM_PANE"; [ "$mode" = INSERT ]'
format = '[ INSERT ](bg:#1c1c1c fg:#5fafd7 bold)'

[custom.wezterm_visual]
when = 'read -r mode 2>/dev/null < "${XDG_RUNTIME_DIR:-/tmp}/wezterm-modes/$WEZTERM_PANE"; [ "$mode" = VISUAL ]'
format = '[ VISUAL ](bg:#1c1c1c fg:#e0a060 bold)'

[custom.wezterm_keymap]
when = 'read -r mode 2>/dev/null < "${XDG_RUNTIME_DIR:-/tmp}/wezterm-modes/$WEZTERM_PANE"; [ "$mode" = KEYMAP ]'
format = '[ KEYMAP ](bg:#1c1c1c fg:#c792ea bold)'

[custom.wezterm_jump]
when = 'read -r mode 2>/dev/null < "${XDG_RUNTIME_DIR:-/tmp}/wezterm-modes/$WEZTERM_PANE"; [ "$mode" = JUMP ]'
format = '[ JUMP ](bg:#1c1c1c fg:#ff5555 bold)'

# Optional: show the label:word legend while a jump is in progress
[custom.wezterm_jump_legend]
when = 'test -s "${XDG_RUNTIME_DIR:-/tmp}/wezterm-modes/$WEZTERM_PANE.jump"'
command = 'read -r legend < "${XDG_RUNTIME_DIR:-/tmp}/wezterm-modes/$WEZTERM_PANE.jump"; printf %s "$legend"'
format = '[ $output ](bg:#1c1c1c fg:#d0d0d0)'
```

Add these modules to your format string:

```toml
format = """${custom.wezterm_normal}${custom.wezterm_insert}${custom.wezterm_visual}${custom.wezterm_keymap}${custom.wezterm_jump}${custom.wezterm_jump_legend}$directory$character"""
```

**Note:** Use `;` instead of `&&` in the `when` conditions. The state file has no trailing newline, so `read` exits non-zero even on success.
