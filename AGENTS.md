# keepalive - notes for agents

## Architecture

`ka.cmd` -> `ka-launch.ps1` (core, PowerShell 5.1, no dependencies) +
`hooks/<name>/*.ps1` (optional per-profile behaviour).

A "profile" is either a `hooks/<name>/` folder or any ad-hoc command line,
wrapped as `cmd.exe /c <command>` and named after its first word
(`C:\tools\server.bat` -> `server`, `npm run dev` -> `npm`).
Sessions live in tmux (arndawg/tmux-windows); the tmux server survives SSH
disconnects, which is the whole point.

Session names: `<profile>-<HHmmss>` (with a `-N` suffix on same-second races,
serialized by a per-profile named mutex `Local\keepalive-<profile>`).

## Wrapping an existing script (the common task)

1. `ka <path-to-script> [args]` already works with zero setup.
2. For menu labels or graceful stop, add `hooks/<name>/`:
   - `start.ps1` (required): must end with the foreground process; the pane
     dies when it exits. Set the cwd here with `Set-Location` (the tmux port's
     `-c` flag is broken, do not use it).
   - `label.ps1` (optional): args are `name epochSeconds` pairs, one pair per
     session, in menu order. Print exactly one line per input, in the same
     order. Short, ASCII, no trailing blank line.
   - `stop.ps1` (optional): kill the underlying process (e.g. the port
     listener); the core kills the tmux session afterwards. Must be idempotent
     and fast (it runs on every stop, including `-k` with several sessions).
3. Keep hooks PowerShell-5.1 compatible, no external dependencies.
4. Test hooks with `powershell -NoProfile -ExecutionPolicy Bypass -File tests/test.ps1`
   and add cases there.

## tmux-windows quirks (learned the hard way, do not retry)

- Pane command argv[0] must be a bare name with `.exe` (`powershell.exe`,
  `cmd.exe`). Full paths as argv[0] fail to spawn; full paths as later args
  are fine.
- `tmux new-session -c <dir>` breaks spawn in this build. Set the cwd inside
  `start.ps1`.
- `tmux source-file` called from inside a pane deadlocks in this build. Set
  options directly (`tmux set-option -g ...`) or rely on server startup.
- The tmux server here is usually started with a custom socket
  (`-S tmux-short-default`); client commands from a shell that is itself
  inside tmux inherit `$TMUX` and target the right server.
- Kill the server before upgrading `tmux.exe` (Windows cannot overwrite a
  running exe). The server auto-exits when the last session dies.
- `list-panes -s` only lists the current session's panes in this build. Query
  each session with `list-panes -t <name>` instead.
- The server starts from sshd with a minimal environment. The user PATH is
  injected via `set-environment -g PATH` in `~/.tmux.conf`; panes otherwise
  cannot find `python` etc.
- `kill-session` can orphan grandchild processes (e.g. a python port
  listener). Stop hooks must kill the listener explicitly.

## PowerShell gotchas

- Never set `$ErrorActionPreference = 'Stop'` in a hook or the core: native
  command stderr becomes a terminating error. Check `$LASTEXITCODE` instead.
- Console output: ASCII only (ssh console codepages mangle unicode).
- `Read-Host` prompts: double quotes, or variables will not expand.
- Variables are case-insensitive: a local `$pairs` silently overwrites a
  `$Pairs` param, and loops over `.Count` then never run.
- `$pid` is a read-only automatic variable. Do not assign to it.
- Child processes: `Get-CimInstance Win32_Process -Filter "ParentProcessId = N"`
  (ProcessId matches the process itself, not its children).
- The 9-arg `[DateTimeOffset]::new()` does not resolve here. Use the 8-arg
  `[DateTime]::new(..., [DateTimeKind]::Utc)` and wrap with
  `[DateTimeOffset]::new($dt)`.
- `.bat`/`.cmd` files must be CRLF; LF-only ones misparse or leave cmd
  interactive.
- From git-bash, MSYS can mangle `cmd.exe /c` args. Use PowerShell for
  spawn diagnostics.

## Test seams (env vars)

- `KA_NO_MAIN=1`: dot-source `ka-launch.ps1` for its functions without running main.
- `KA_HOOKS_DIR`: override the hooks directory (tests use `tests/hooks`).
- `PI_SESSIONS_DIR`: override the pi sessions directory (label/conflict tests).
- `KA_PI_DRY_RUN=1`: pi hook prints `DRYRUN: <args>` instead of launching pi.
- `QWEN_SERVER`: override the qwen server bat (tests use a dummy on port 18099).
- Tests own the 18099 port lifecycle; a stale listener from a killed pane
  must be cleaned before the qwen tests.

## Conventions

- One-line code comments only.
- Do not commit or push without the user's go-ahead.
