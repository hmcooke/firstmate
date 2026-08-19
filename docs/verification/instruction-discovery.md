# Worker instruction-discovery disable verification

Audience: maintainer verification.

This record supports `bin/fm-spawn.sh`'s `--no-project-instructions` flag and the per-harness rows in `.agents/skills/harness-adapters/SKILL.md`.
It records which harnesses can be launched so the worktree they stand in supplies no live configuration, and the exact evidence for each verdict.

A worker researching a clone it does not trust stands in a worktree of that clone.
Harness auto-discovery turns that repo's `CLAUDE.md`/`AGENTS.md`, skills, agents, hooks, and MCP definitions into live configuration, which is prompt injection by construction.
`project_instruction_disable_flags_for_harness()` in `bin/fm-spawn.sh` is an allowlist keyed off the findings below, and every harness absent from it refuses the flag rather than launching unprotected.

The claim verified here is structural: configuration discovery is off, and that is testable.
It is not a claim that a worker becomes immune to hostile text, because a worker may still read untrusted files as data with its ordinary tools.

## Method

Each harness ran an A/B against a canary fixture whose only difference was the candidate disable flags.
The fixture placed a distinctive codeword in the project instruction file, a project skill, a project subagent, a project hook that touches a witness file, and a project MCP server whose command touches a witness file.
A mechanism counts as verified only when the codeword stops reaching the model, the witness files stop appearing, and the same fixture demonstrably still fires without the flags.

## claude - VERIFIED (Claude Code 2.1.220, 2026-08-09)

Mechanism: `--setting-sources user,local`.

Claude Code gates every project-directory surface behind settings sources, so dropping the `project` source drops the worktree's `CLAUDE.md`, `.claude/skills`, `.claude/agents`, `.claude/settings.json` hooks, and `.mcp.json` in one flag.
The operator's own user-level configuration and normal authentication keep working, which matters because a ship task still needs the user-level `no-mistakes` skill.

The `local` source is kept deliberately, and dropping it would be a supervision regression rather than extra safety.
`local` is exactly one file, `<worktree>/.claude/settings.local.json`, and for every claude spawn `bin/fm-spawn.sh` writes that file itself, before launch, with firstmate's semantic busy-state hooks and the turn-end notification touch.
`--setting-sources user` alone would leave firstmate unable to see the worker's busy state or turn ends.

Because that retained source is the one project-directory input still loaded, the write must be the repo's to lose rather than the repo's to control.
An untrusted clone can ship `.claude`, or the settings file itself, as a symlink, which would send the write outside the worktree or leave the worker running with no supervision hooks while its metadata advertises a protected posture.
On a locked-down spawn only, `fm-spawn` therefore drops a symlink at either path before writing, so the file claude reads is always a real file firstmate owns at the real path inside the worktree.
Default claude spawns preserve either repo-supplied symlink because full project discovery remains enabled, leaving the pre-existing write-through hazard to its separate follow-up.
`tests/fm-spawn-no-project-instructions.test.sh` covers both hostile shapes and asserts nothing is written outside the worktree.

Print-mode A/B, run in the fixture directory:

```
$ claude -p --model claude-haiku-4-5-20251001 "What is the codeword?"
ZORKMID-4417                       # project CLAUDE.md reached the model
$ claude -p --model claude-haiku-4-5-20251001 --setting-sources user,local "What is the codeword?"
Codeword: UNKNOWN (not found)      # codeword absent
```

The same A/B over each surface, reading the hook and MCP witness files after each run.
The availability rows use a numbered-line answer format, because an open-ended question makes the model restate the skill names it was asked about and that reads like a false positive:

| Project surface | Baseline | `--setting-sources user` | `--setting-sources user,local` |
|---|---|---|---|
| `CLAUDE.md` codeword | reached the model | absent | absent |
| `.claude/skills/canary-skill` | reported available | reported unavailable | reported unavailable |
| `.claude/agents/canary-agent` | reported available | reported unavailable | reported unavailable |
| `.claude/settings.json` SessionStart hook | witness file created | not created | not created |
| `.mcp.json` stdio server | witness file created | not created | not created |
| `.claude/settings.local.json` hook (firstmate-owned) | witness file created | not created | witness file created |
| user-level `no-mistakes` skill | available | still available | still available |

Claude does not discover a project's `.agents/skills` natively; it reads `.claude/skills`, which in firstmate's own repos is a symlink to `.agents/skills` and is therefore covered by the same flag.

Interactive re-verification matters because `fm-spawn` launches the TUI, not print mode, so the flag was confirmed again on the real launch shape in a tmux pane:

```
$ CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions \
    --model claude-haiku-4-5-20251001 'Two lines exactly. Line 1: codeword from your instructions or UNKNOWN. Line 2: YES if skill canary-skill is available else NO.'
● ZORKMID-4417 / YES               # project and local hook witness files both created
$ CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions \
    --setting-sources user,local --model claude-haiku-4-5-20251001 'Two lines exactly. Line 1: codeword from your instructions or UNKNOWN. Line 2: YES if skill canary-skill is available else NO.'
● UNKNOWN / NO                     # project hook and MCP witness files absent, local hook witness file created
```

Rejected alternatives on this harness: `--bare` also disables discovery but restricts authentication to `ANTHROPIC_API_KEY` or `apiKeyHelper` and never reads OAuth or the keychain, which breaks a subscription-authenticated fleet; `--safe-mode` disables all customizations including the operator's own, which is more than the flag promises and removes the user-level skills a ship task needs.

## codex - NOT AVAILABLE (codex-cli 0.147.0, 2026-08-09)

Codex can suppress the `AGENTS.md` auto-load but cannot disable project skill discovery, so `--no-project-instructions` refuses a codex spawn.

`codex debug prompt-input` renders the model-visible prompt without calling a model, which makes these checks deterministic:

```
$ codex debug prompt-input "hello" | grep -c ZORKMID-4417
1
$ codex debug prompt-input -c project_doc_max_bytes=0 "hello" | grep -c ZORKMID-4417
0
```

That half works. The blocking gap is skills:

- Codex discovers project skills from both `<project>/.codex/skills` and `<project>/.agents/skills`, and injects each skill's name and description into the prompt. The description is attacker-controlled text from the untrusted repo.
- `codex features list` has no `skills` flag, so `--disable skills` is rejected outright with `Error: Unknown feature flag: skills`.
- The only disable is the `skills.config` sequence, whose entries are `{name, path, enabled}` (probed with `--strict-config`, which names unknown fields). It matches one exact `SKILL.md` path: disabling `<project>/.codex/skills/canary-skill/SKILL.md` removed that one skill, while pointing the same entry at the skill's directory, at `<project>/.codex/skills`, or at `<project>/.agents/skills` removed nothing.

Per-file disable cannot block a skill file whose name is not known in advance, which is exactly the untrusted-repo case, so there is no reliable mechanism to allowlist.

One related fact, not a mechanism firstmate controls: a project's `.codex/hooks.json` requires a persisted trust hash in `hooks.state`, and the untrusted fixture's hook did not run until `--dangerously-bypass-hook-trust` was passed. Codex project hooks are therefore not a live path for an untrusted clone, but hooks alone do not close the skills gap.

## opencode, pi, pi-signed, grok, kimi, cursor, muse - UNVERIFIED

No mechanism has been established empirically for these adapters, so the flag refuses them.
"Unverified" here means untested, not proven incapable: adding one requires running the method above and recording the result in this file before extending the allowlist in `bin/fm-spawn.sh`.

## Regression coverage

`tests/fm-spawn-no-project-instructions.test.sh` pins the behavior that depends on these findings: the verified claude flags reach the typed launch command, an ordinary spawn is unchanged, the posture is recorded in task metadata, and every unsupported route refuses before a worker endpoint or task metadata exists.
It also pins the relaunch path, where a lost posture would be worst: the replacement worker carries the recorded harness's disable flags again, an unreadable or duplicated posture record refuses, an explicit flag is refused because the record owns that axis, a relaunch onto a harness with no verified mechanism refuses, and a task with no recorded posture relaunches unchanged.
That table has one row per supported harness, so extending the allowlist above fails there until the new harness's own form survives a relaunch.
