# keepalive

Run any command in a tmux session that survives SSH disconnects. Attach from
anywhere (laptop, phone, desktop) and the process keeps going while you are away.

## Install (Windows)

```
winget install arndawg.tmux-windows
```

Copy `keepalive.cmd` from this repo to a folder on your PATH
(e.g. `C:\Users\<you>\.local\bin`). For git-bash, add an extensionless
`keepalive` file next to it that execs `keepalive-launch.ps1` via
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File`.

## Use

```
keepalive <name-or-command> [args...]   menu: attach, or start a new one
keepalive <x> -l                   list sessions of x
keepalive <x> -n [args]            start a new one (skip menu)
keepalive <x> -k                   stop all sessions of x
```

In the menu: `1-N` attach, `s1` (or `s 1`) stop session 1, Enter start new, `q` quit.

On an interactive terminal the menu is a small colored TUI; when output is
piped it falls back to plain text (same keys).

## Examples

```
keepalive pi          # pi coding agent; menu shows your prompt per session
keepalive qwen        # wrap the local llama server in tmux (optional; the
                      # plain `qwen` cmd uses the original launch script)
keepalive "npm run dev"
keepalive C:\tools\server.bat
keepalive python train.py --epochs 10
```

Any command works out of the box. It runs as `cmd.exe /c <your command>` inside
the tmux session.

## Hooks (optional)

Drop a folder into `hooks/<name>/` to add behaviour for profile `<name>`:

| file        | purpose                                                        |
|-------------|----------------------------------------------------------------|
| `start.ps1` | required. What runs in the pane. Keep the process in the foreground |
| `label.ps1` | optional. One short status line per session for the menu       |
| `stop.ps1`  | optional. Gracefully stop the underlying process before the session is killed |

See `AGENTS.md` for the full contract and the tmux/PowerShell gotchas.

## Scrolling history

`mouse on` is set in `~/.tmux.conf`. What you get depends on the terminal:

- Windows Terminal (sends real wheel events): at a bare shell, wheel-up enters
  tmux copy mode (scrollback); over a TUI such as pi, the wheel is forwarded
  to the app.
- conhost (what a double-clicked `.cmd` opens) converts the wheel to up/down
  arrow keys, so it scrolls command history instead. Run `keepalive` inside
  Windows Terminal to get real wheel behavior.
- Termius sends no mouse events at all; use the key fallback below.

Fallback that always works (including Termius): prefix `C-b` then `[` enters
copy mode; arrows/space/pageup scroll, `q` exits.
