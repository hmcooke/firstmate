# The launch-prefix seam

Firstmate composes a harness launch command and types it into the pane shell of a session the runtime backend created.
The agent is therefore a child of that backend's server process, not of whoever called [`bin/fm-spawn.sh`](../bin/fm-spawn.sh).
That is exactly what an interactive fleet wants, and it is the one thing a caller cannot work around: there is no point at which the caller holds the agent process and could confine, trace, or account for it.

`--launch-prefix` is the seam that closes that gap, and it is the ONLY one.
The caller supplies a wrapper command; the composed launch becomes `<leading environment> <wrapper words...> <harness command...>`, so the wrapper is the process that starts the agent whoever owns the pane.
The engine carries the wrapper and guarantees it is applied exactly or refused loudly.
The caller owns what the wrapper does; no confinement, sandbox, or tracing policy lives in the engine.

## Using it

```sh
bin/fm-spawn.sh <id> <project> --scout \
  --launch-prefix sandbox-exec \
  --launch-prefix -f \
  --launch-prefix /path/to/research.sb
```

Each occurrence contributes exactly one argv word, in order.
That surface is deliberate on both sides.

The flag is repeatable rather than one quoted string because the engine then never re-parses caller quoting: a word containing spaces stays one word, and no shell-splitting rule has to be invented, documented, and matched by every caller.
A programmatic caller already holds an argv array and maps onto it directly; a human at a shell writes one flag per word.
Use `--launch-prefix=<word>` for a word that begins with `--`, which the shared missing-value guard would otherwise reject.

There is no environment variable form, and adding one would be a mistake.
An ambient variable is inherited by every child process, so it would apply invisibly to unrelated spawns - including a secondmate's own workers - and its absence would be equally invisible.
Confinement has to be an auditable property of one exact launch, which is what a per-spawn flag makes it.

Every word is shell-quoted into the launch line, so a wrapper contributes argv words and never shell syntax.
The exact spliced text is recorded in the task's durable record as `launch_prefix=`; an absent line means an unwrapped launch.
[`bin/fm-spawn.sh`](../bin/fm-spawn.sh)'s header and `--help` own the flag's exact mechanics.

## What the seam guarantees

The wrapper is applied exactly, or the spawn refuses before it creates a worktree, an endpoint, or task metadata.
It is never silently dropped, and it is never partially applied.

Refusal covers every shape that could not be honored exactly:

- An empty word, or a word carrying a line break - the launch is typed as a single line, so a break would run part of it early.
- A leading word that is an environment assignment, or that starts with `-`; a wrapper has to be the command that starts the agent.
- A leading word that resolves to no executable, given as an absolute path or a PATH command name.
- A leading word given as a relative path, because the launch runs in the worker's worktree, where it would name a different file.
- `--secondmate`, because a secondmate is a firstmate instance that spawns its own workers, so wrapping it would confine the supervisor rather than the work; wrap those launches inside that home instead.
- A raw launch command, which firstmate did not compose and whose command word it therefore cannot locate, when any other insertion point would change what the command means.
- A launch template with no splice point, which is what makes a new template unable to carry a wrapper a refusal rather than a silent omission.

A relaunch ([`bin/fm-control.sh`](../bin/fm-control.sh) `relaunch`) re-applies the recorded prefix rather than re-deriving it, so a replacement agent cannot come back unwrapped - the failure that would matter most, since that path exists to recover a confined worker.
Like every other axis a relaunch takes from the task's own record, an explicit `--launch-prefix` is refused alongside it, and a record that could not be typed as one launch line refuses the relaunch instead of running it unwrapped.
A wrapper removed from the machine between spawn and relaunch fails in the pane, which supervision reads as a worker that never started; it never yields an unwrapped agent.

## What the caller still owns

The wrapper must keep the agent in the pane's foreground process group.
Firstmate's liveness classifier reads that group rather than the pane's own command name ([`bin/backends/tmux.sh`](../bin/backends/tmux.sh)), and `tests/fm-tmux-agent-liveness.test.sh` already pins the wrapped shape with real processes: a launcher whose own identity reads as a bare shell, running the harness as a child in the same group, classifies as a live agent.
A wrapper that execs the agent or runs it as an ordinary child is therefore supervised normally, while one that detaches it into another session or hides it behind a PID namespace would read as an agent-free pane.
The engine cannot enforce this, so a wrapper that isolates process visibility needs its own supervision story.

Resolution of a bare wrapper name happens against firstmate's PATH, while the launch runs with the pane shell's PATH.
Give an absolute path when those can differ.

## Who this is for

This is the settled answer for every consumer that needs to own the launched process, and new consumers extend their wrapper rather than commissioning another seam:

- A headless service driving this engine as its toolbelt - holding the home's session lock as a declared service owner ([service-owner session locks](service-owner-lock.md)), launching research workers into untrusted clones with instruction discovery disabled, and confining those workers with an OS sandbox profile.
- Any future need to join a launched agent to a caller-owned shell, tracer, resource accounting group, or measurement harness.

All of these are the same requirement - be the parent of the launched process - and one hook serves them.
The composition is orthogonal by construction: `--launch-prefix` decides who starts the agent, `--no-project-instructions` decides what the agent's worktree may configure, and the session lock decides who owns the home.
