# keepalive

Run any command in a tmux session that survives SSH disconnects. Attach from
anywhere (laptop, phone, desktop) and the process keeps going while you are away.

## Install (Windows)

```
winget install arndawg.tmux-windows
```

Copy `ka.cmd` and `keepalive.cmd` from this repo to a folder on your PATH
(e.g. `C:\Users\<you>\.local\bin`).

## Use

```
ka <name-or-command> [args...]    menu: attach to a running one, or start a new one
ka <x> -l                         list sessions of x
ka <x> -n [args]                  start a new one (skip menu)
ka <x> -k                         stop all sessions of x
```

In the menu: `1-N` attach, `s1` (or `s 1`) stop session 1, Enter start new, `q` quit.

## Examples

```
ka pi                 # pi coding agent; menu shows your prompt per session
ka qwen               # wrap the local llama server in tmux (optional; the
                      # plain `qwen` cmd uses the original launch script)
ka "npm run dev"
ka C:\tools\server.bat
ka python train.py --epochs 10
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

`mouse on` is set in `~/.tmux.conf`, so wheel scroll enters tmux copy mode on
terminals that send real wheel events. Termius (and some terminals) convert
scroll gestures to arrow keys; those do not scroll the buffer. Fallback that
always works: prefix (`C-b`) then `[` for copy mode, arrows/space scroll,
`q` exits.
