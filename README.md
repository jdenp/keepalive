# keepalive

Run any command in a tmux session that survives SSH disconnects. Attach from
anywhere (laptop, phone, desktop) and the process keeps going while you are away.

## Install (Windows)

tmux is bundled: `tmux/tmux.exe` is a local fork of
[arndawg/tmux-windows](https://github.com/arndawg/tmux-windows) `v3.6a-win32.7`
with `tmux/wide-char-width.patch` applied. Upstream counts every non-ASCII
character as one column, which corrupts TUIs (pi, Claude Code) on any screen
with emoji or CJK text. `tmux/build.ps1` rebuilds it. A tmux server that is
already running keeps the old behaviour until it exits.

Copy `keepalive.cmd` from this repo to a folder on your PATH
(e.g. `C:\Users\<you>\.local\bin`). For git-bash, add an extensionless
`keepalive` file next to it that execs `keepalive-launch.ps1` via
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File`.

## Use

```
keepalive                        dashboard of all sessions (all profiles)
keepalive <name-or-command> [args...]   start it as a new session and attach
keepalive <x> -l                   list sessions of x
keepalive <x> -k                   stop all sessions of x
keepalive <x> --detach             start a new session, print its name, exit
keepalive --flat                   list all sessions, one per line
                                   name|profile|started|label
keepalive --flat --launch <x>      start a new session of x, print its name
keepalive --flat --stop <name>     stop one session by exact name
keepalive --flat --log <name>      print recent pane output of a session
keepalive --help                   full human and agent usage
```

Dashboard: `1-N` attach, `s1` (or `s 1`) stop session 1, Enter start new
(prompts for a name), `q` quit. On an interactive terminal the dashboard is a
small colored TUI; when output is piped it falls back to plain text (same keys).

`--flat` is the AI-agent path: no prompts, plain stdout. Lock your own session
before any stop/kill work so you cannot kill yourself:

```
keepalive --flat --launch <x> --lock     start a new session and lock it
keepalive --lock-process <name>          refuse --stop/-k for a session
keepalive --unlock-process <name>        clear the lock
```

A locked session is refused with a warning until unlocked.

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

## Hung server

Every tmux call times out after 10 seconds (`KEEPALIVE_TMUX_TIMEOUT_SEC`). On a
timeout keepalive prints the server's process id and CPU use, writes a memory
dump to `%LOCALAPPDATA%\keepalive\dumps`, and exits 3. Recover by stopping the
server process (this ends every session) and starting the sessions again. Keep
the dump: it shows where the server is stuck.

