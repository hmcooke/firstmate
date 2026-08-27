# cmux runtime backend

cmux is an experimental macOS GUI terminal backend.
It provides task workspaces and surfaces while Treehouse continues to provide git worktrees.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared selection and metadata semantics.

## Setup

Pick cmux when you already use the app as your terminal and want task workspaces in its sidebar.
cmux is macOS-only, GUI-first, and unsuitable for a headless or SSH-only Firstmate session.

Prerequisites:

- cmux 0.64 or newer, installed from [cmux.com](https://cmux.com) or with `brew install --cask cmux`.
- `jq` for JSON responses.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).

The CLI is not always installed on `PATH` with the app.
The adapter prefers `command -v cmux` and otherwise uses `/Applications/cmux.app/Contents/Resources/bin/cmux`.

### Required socket access

cmux defaults to a control mode that rejects external shells, while Firstmate always controls it from an external process.
Open Settings > Automation and choose a viable Socket Control Mode before the first cmux-backed spawn.

| Setting | Value | Firstmate support | Security boundary |
| --- | --- | --- | --- |
| Off | `off` | No | The socket listener is disabled. |
| cmux processes only | `cmuxOnly` | No | Only descendants of the cmux app can connect. |
| Automation mode | `automation` | Yes, recommended | The owner-only 0600 socket admits processes of the current macOS user. |
| Password mode | `password` | Yes | The 0600 socket also requires an auth handshake. |
| Full open access | `allowAll` | Yes, not recommended | The 0666 socket admits every local user without authentication. |

Automation mode is the recommended same-user boundary.
`allowAll` can execute commands through a world-writable control socket and should be selected only as an explicit security tradeoff.

For Password mode, store the password as the first line of local gitignored `config/cmux-socket-password` or provide `CMUX_SOCKET_PASSWORD` in Firstmate's environment.
The adapter reads the file fresh from the effective config directory and does not overwrite an ambient password when the file is absent.
Configure the mode and password through the cmux UI rather than editing `cmux.json`; the app does not retain a hand-added password key, and socket-based reload cannot fix a socket that is rejecting the caller.

Select cmux with local `config/backend` containing `cmux`, `FM_BACKEND=cmux` for one launch, or an explicit request to Firstmate.
It can also be runtime auto-detected when Firstmate itself runs inside cmux.
A spawn stops with an actionable setup message when the app, minimum version, `jq`, socket access, or password is unavailable.
The adapter may launch the app with `open -a cmux` only when the socket is down; it does not relaunch the app for access-denied or authentication errors.

Routine supervision uses `bin/fm-peek.sh <id>` and `FM_HOME=<home> bin/fm-send.sh <id> '<text>'` without bringing the cmux window forward.
Task workspace and surface creation use `focus=false`.

Verify setup by spawning a small task and confirming metadata contains `backend=cmux`, `cmux_workspace_id=`, and `cmux_surface_id=`.

## Runtime detection

`CMUX_WORKSPACE_ID` is the primary cmux runtime marker.
`CMUX_SOCKET_PATH` is not sufficient because operators may set it outside cmux.
Detection checks tmux first, then Herdr, then cmux, so a multiplexer nested inside cmux remains the active backend.

cmux's bundled Claude wrapper can remove every `CMUX_*` variable when its internal socket probe fails, including in Password mode.
On macOS only, detection therefore falls back first to `__CFBundleIdentifier=com.cmuxterm.app`, then to process ancestry reaching the running cmux app.
Those fallbacks are consulted only when neither tmux nor Herdr already won.
An environment-scrubbed or launchd-reparented process with no reliable marker is not auto-detected.

Auto-detection selects only the backend.
It never changes socket access or grants credentials.
The spawn refusal explains how to finish cmux setup or opt back into tmux.

## Task shape and metadata

Each task owns one cmux workspace with one surface.
The caller-facing label remains `fm-<id>`, while the visible workspace title is `fm-<home-label>-<id>`.
The home label is `firstmate` or `2ndmate-<id>` plus a stable short hash of the resolved Firstmate root.
cmux does not enforce title uniqueness, so create, recovery, list, and cleanup paths all validate this scoped title.
Relocating the Firstmate installation changes the hash and leaves old titles unmatched, consistent with recorded worktree paths also becoming stale.

```text
backend=cmux
window=<workspace-uuid>:<surface-uuid>
cmux_workspace_id=<workspace-uuid>
cmux_surface_id=<surface-uuid>
```

The UUID pair is the active endpoint authority within one app run.
Workspace UUIDs are not stable across an app relaunch, so recovery searches by the scoped title and then resolves the current surface id.

## Current operation and safety

### Endpoint presence

Every runtime backend answers "is this recorded endpoint still there?" with a three-way verdict - present, absent, or unknown - and absence needs positive evidence.
An observation that failed, timed out, or could not cover the endpoint is unknown, and no consumer may treat unknown as gone: [architecture](architecture.md#endpoint-presence-is-tri-state) owns the rule and `bin/fm-backend.sh` owns the contract.

For cmux, "could not cover the endpoint" is the load-bearing case: `workspace list` with no `--window` is scoped to the current window only, so a task workspace sitting in another window is invisible to it.
A scoped miss is therefore a limit of what was observed and never evidence the workspace is gone.
Absence needs the whole-app inventory, which walks `list-windows` and asks each window for its own scoped list, and which refuses to answer at all if any of those reads fails - a partial inventory can prove a workspace present but never prove one absent.
The cheap current-window lookup is still tried first, so the common case costs exactly what it always did and the sweep is paid only when that view cannot see the endpoint.

A readable `list-panes` response that omits the recorded surface is absent, and so is a complete inventory that holds neither the recorded workspace id nor the expected title.
When the owning task label is known, a workspace id reused under a different title is also absent, because the title is the identity that survives an app relaunch while ids do not.
Every failed or unparseable read is unknown.

A genuinely fresh surface returns an internal error from `read-screen` until something has been written.
Target readiness therefore uses the structural `list-panes` response instead of a content read.
Capture remains bounded and locally trimmed after `read-screen` becomes available.

`current_directory` follows a top-level shell `cd` but not the foreground subshell opened by `treehouse get`.
Spawn-time worktree discovery sends begin and end markers around `pwd`, captures the marked block, and joins wrapped path lines.

Literal send and Enter are separate calls.
Enter, Escape, and Ctrl-C are supported.
The composer verifier is a thin adapter: it captures a bounded plain-text tail and hands it with cmux's capability facts to the fleet-wide classifier in `bin/fm-composer-lib.sh`, which owns every shape, including Claude's borderless `❯` row with its U+00A0 separator.
`read-screen` is plain text with no cursor primitive, so the shared classifier degrades a glyph row carrying trailing text to `unknown` rather than misreading a harness's own idle suggestion as unsent input.
An unstructured bare prompt is `unknown`, and a slash-popup placeholder remains `pending`, so only Enter is retried and text is never retyped.
cmux exposes no native generic agent busy signal, so supervision uses capture/hash polling for screen changes and each harness adapter's semantic lifecycle for worker state.
Grok alone retains its isolated rendered-tail fallback.

A task workspace's last surface cannot be closed directly.
Cleanup owns the whole workspace and uses `close-workspace`.
cmux also refuses to remove the only workspace in a macOS window while returning a misleading success response.
When the task is last in its window, Firstmate creates one unfocused unnamed sibling workspace in that same window, closes the task workspace, and leaves the window with cmux's fresh default workspace.
The sibling never carries an `fm-` title and is ignored by recovery.

The exact window membership is re-read before this operation.
A selected workspace that is not last closes normally; selection itself is not the trigger.
Firstmate does not attempt to close the macOS window because cmux's socket cannot close a window holding a live terminal.

Real tests share the captain's running app rather than creating an isolated cmux session.
`tests/cmux-test-safety.sh` permits cleanup only for an exact currently listed `fm-test-` workspace and never enumerates and closes unrelated workspaces or relaunches the app.

## Active limits

- cmux is experimental, macOS-only, GUI-first, and requires the app running.
- Socket access requires a one-time manual Settings change.
- Secondmate spawns are unsupported until a per-home lifecycle design is verified.
- There is no native busy or push-event signal.
- A target can disappear after structural readiness and before the operation.
- The only-workspace cleanup path leaves a fresh default workspace and cannot close the window.
- Label lookup and endpoint presence sweep every window, so a task moved to a non-current window is found rather than read as gone.
  Orphan discovery (`fm_backend_cmux_list_live`) is still scoped to the current window; it produces a listing rather than a liveness verdict and has no consumer today.
- Workspace ids do not survive app relaunch and are never recovery authority.

## Regression entry points

```sh
tests/fm-backend-cmux.test.sh
tests/fm-backend-presence.test.sh
tests/fm-backend-cmux-smoke.test.sh
```

[`verification/runtime-backends.md`](verification/runtime-backends.md#cmux) records the active source and live evidence, including socket modes and last-in-window cleanup.
