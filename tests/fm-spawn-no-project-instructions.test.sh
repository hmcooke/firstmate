#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh --no-project-instructions.
#
# The flag exists so a worker standing in an untrusted clone does not inherit that
# repo's instruction surfaces as live configuration. Two guarantees are load-bearing
# and both are asserted here through fm-spawn's own interface: a supported harness
# really carries the disable flags into the launch command and records the posture in
# meta, and every unsupported route REFUSES before the spawn creates anything.
#
# A fake tmux captures the literal command sent with `tmux send-keys -l`, so the
# launch assertions pin what firstmate would run without starting a real harness.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-no-project-instructions)
export FM_BACKEND=tmux

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# One isolated case: a firstmate home, a real git worktree for the task, briefs for
# every id, and a fake bin dir. Fields come back as a single '|' record.
make_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  # CLAUDE_CONFIG_DIR is forwarded onto claude launches by fm-spawn, so pin it empty
  # rather than leaking the invoking shell's value into launch assertions.
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' \
    FM_FAKE_LAUNCH_LOG="$launchlog" GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

# The positive path: the verified claude mechanism reaches the typed launch command,
# the brief still rides that command, and meta records the posture for supervision.
test_supported_harness_carries_flags_and_records_meta() {
  local rec id out status launch expected
  id=nopi-supported-z1
  rec=$(make_case supported claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --no-project-instructions)
  status=$?
  expect_code 0 "$status" "claude spawn with --no-project-instructions should succeed"
  assert_contains "$out" "spawned $id harness=claude" "spawn did not report claude"

  launch=$(cat "$LAUNCH_LOG")
  expected="CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions --setting-sources user,local \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "locked-down claude launch was not the expected command"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  assert_grep 'project_instructions=off' "$HOME_DIR/state/$id.meta" \
    "meta did not record the discovery-off posture"
  pass "--no-project-instructions carries the verified flags into the launch and records meta"
}

# Additivity: an ordinary spawn is byte-identical to before the flag existed, and its
# meta carries no project_instructions line at all.
test_default_spawn_is_unchanged() {
  local rec id out status launch expected
  id=nopi-default-z2
  rec=$(make_case default claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn without the flag should succeed"
  assert_contains "$out" "spawned $id harness=claude" "spawn did not report claude"

  launch=$(cat "$LAUNCH_LOG")
  expected="CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "default claude launch changed"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  assert_no_grep 'project_instructions' "$HOME_DIR/state/$id.meta" \
    "default spawn wrote a project_instructions line"
  pass "default spawns keep the unchanged launch command and meta"
}

# Firstmate's own per-task claude hooks (semantic busy state and the turn-end touch)
# live in the worktree's .claude/settings.local.json, which fm-spawn writes itself. The
# lockdown must not disable them or firstmate goes blind to this worker: it drops the
# repo-supplied `project` source while keeping the firstmate-owned `local` one.
test_lockdown_keeps_firstmate_own_supervision_hooks() {
  local rec id out status launch settings sources
  id=nopi-supervision-z9
  rec=$(make_case supervision claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --no-project-instructions)
  status=$?
  expect_code 0 "$status" "locked-down claude spawn should succeed"

  settings="$WT_DIR/.claude/settings.local.json"
  assert_present "$settings" "fm-spawn did not write its own per-task claude hooks"
  assert_grep 'UserPromptSubmit' "$settings" "per-task busy-state hooks are missing"
  assert_grep 'turn-ended' "$settings" "the turn-end notification hook is missing"

  # Read the settings-source list itself rather than scanning the whole command, whose
  # temp paths legitimately contain the word "project".
  launch=$(cat "$LAUNCH_LOG")
  sources=${launch#*--setting-sources }
  sources=${sources%% *}
  case ",$sources," in
    *,local,*) ;;
    *) fail "the lockdown dropped the firstmate-owned local settings source (sources=$sources)" ;;
  esac
  case ",$sources," in
    *,project,*) fail "the lockdown kept the repo-supplied project settings source (sources=$sources)" ;;
  esac
  pass "the lockdown keeps firstmate's own per-task hooks while dropping the repo's settings"
}

# Keeping the `local` settings source is only safe because firstmate owns that exact
# file. An untrusted clone can ship `.claude`, or the settings file itself, as a
# symlink - which would send the write outside the worktree, or leave the worker with
# no supervision hooks while its metadata advertises a protected posture. Both shapes
# must end with a real file at the real path and nothing written outside the worktree.
test_hostile_settings_symlinks_cannot_divert_the_write() {
  local label shape rec id out status outside n=0
  while IFS='|' read -r label shape; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    id="nopi-symlink-z1$n"
    rec=$(make_case "symlink$n" claude "$id")
    read_case_record "$rec"
    outside="$CASE_DIR/outside-target"
    : > "$outside"
    case "$shape" in
      dir) ln -s "$CASE_DIR/outside-dir" "$WT_DIR/.claude" ; mkdir -p "$CASE_DIR/outside-dir" ;;
      file) mkdir -p "$WT_DIR/.claude"; ln -s "$outside" "$WT_DIR/.claude/settings.local.json" ;;
    esac

    out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" --no-project-instructions)
    status=$?
    expect_code 0 "$status" "$label: spawn should still succeed"

    [ ! -L "$WT_DIR/.claude" ] || fail "$label: .claude is still a symlink"
    [ ! -L "$WT_DIR/.claude/settings.local.json" ] || fail "$label: settings file is still a symlink"
    assert_present "$WT_DIR/.claude/settings.local.json" "$label: no real settings file was written"
    assert_grep 'UserPromptSubmit' "$WT_DIR/.claude/settings.local.json" \
      "$label: firstmate's supervision hooks did not land in the real file"
    [ ! -s "$outside" ] || fail "$label: the write escaped the worktree to $outside"
    [ ! -e "$CASE_DIR/outside-dir/settings.local.json" ] || fail "$label: the write escaped into the symlinked directory"
  done <<'ROWS'
.claude symlinked out of the worktree|dir
settings.local.json symlinked elsewhere|file
ROWS
  pass "a repo-supplied symlink cannot divert or suppress firstmate's own settings write"
}

# The flag composes with the other launch axes rather than displacing them.
test_flag_composes_with_model_and_effort() {
  local rec id out status launch
  id=nopi-axes-z3
  rec=$(make_case axes claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --no-project-instructions --model opus --effort high)
  status=$?
  expect_code 0 "$status" "claude spawn with all launch axes should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--setting-sources user,local --model 'opus' --effort 'high'" \
    "the disable flags did not compose with --model/--effort"
  pass "--no-project-instructions composes with the model and effort axes"
}

# Fail closed. Every row must refuse BEFORE any worker exists, so each case also
# asserts that no task metadata was written.
test_unsupported_routes_refuse_before_spawning() {
  local label harness expect rec id out status n=0
  while IFS='|' read -r label harness expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    id="nopi-refuse-z4$n"
    rec=$(make_case "refuse$n" "$harness" "$id")
    read_case_record "$rec"
    out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" --no-project-instructions)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: --no-project-instructions should have been refused"
    assert_contains "$out" "$expect" "$label: refusal did not name the reason"
    assert_absent "$HOME_DIR/state/$id.meta" "$label: a refused spawn still wrote task metadata"
    [ ! -s "$LAUNCH_LOG" ] || fail "$label: a refused spawn still typed a launch command"
  done <<'ROWS'
codex has no blanket disable|codex|has no verified way to disable project instruction discovery
opencode is unverified|opencode|has no verified way to disable project instruction discovery
grok is unverified|grok|has no verified way to disable project instruction discovery
kimi is unverified|kimi|has no verified way to disable project instruction discovery
pi is unverified|pi|has no verified way to disable project instruction discovery
ROWS
  pass "an unsupported harness refuses the spawn instead of launching unprotected"
}

# A raw launch command is the unverified-adapter escape hatch: firstmate did not build
# it, so it cannot promise anything about it - even when it names a supported harness.
test_raw_launch_command_refuses() {
  local rec id out status
  id=nopi-raw-z5
  rec=$(make_case raw claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "claude --dangerously-skip-permissions" --no-project-instructions)
  status=$?
  [ "$status" -ne 0 ] || fail "a raw launch command should refuse --no-project-instructions"
  assert_contains "$out" "cannot be applied to a raw launch command" \
    "refusal did not name the raw launch command"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused raw-launch spawn still wrote task metadata"
  pass "a raw launch command refuses --no-project-instructions rather than assuming it applies"
}

# A secondmate's own home instructions are what it must load, so the flag is refused
# rather than silently breaking the agent it is applied to.
test_secondmate_refuses() {
  local rec id out status sub_home
  id=nopi-secondmate-z6
  rec=$(make_case secondmate claude "$id")
  read_case_record "$rec"
  sub_home="$CASE_DIR/sub-home"
  mkdir -p "$sub_home/bin" "$sub_home/data"
  printf '# Firstmate\n' > "$sub_home/AGENTS.md"
  printf '%s\n' "$id" > "$sub_home/.fm-secondmate-home"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$sub_home" --secondmate --no-project-instructions)
  status=$?
  [ "$status" -ne 0 ] || fail "a secondmate spawn should refuse --no-project-instructions"
  assert_contains "$out" "does not apply to --secondmate" "refusal did not name --secondmate"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused secondmate spawn still wrote task metadata"
  pass "--secondmate refuses --no-project-instructions instead of starving its own home"
}

# The batch loop must forward the flag, or a batch would silently lose the guarantee
# the caller asked for on every pair.
test_batch_forwards_the_flag() {
  local rec id_a id_b out status
  id_a=nopi-batch-a-z7
  id_b=nopi-batch-b-z8
  rec=$(make_case batch claude "$id_a" "$id_b")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id_a=$PROJ_DIR" "$id_b=$PROJ_DIR" --no-project-instructions)
  status=$?
  expect_code 0 "$status" "batch spawn with --no-project-instructions should succeed"
  assert_grep 'project_instructions=off' "$HOME_DIR/state/$id_a.meta" \
    "first batch pair lost the discovery-off posture"
  assert_grep 'project_instructions=off' "$HOME_DIR/state/$id_b.meta" \
    "second batch pair lost the discovery-off posture"
  pass "batch dispatch forwards --no-project-instructions to every pair"
}

test_supported_harness_carries_flags_and_records_meta
test_default_spawn_is_unchanged
test_lockdown_keeps_firstmate_own_supervision_hooks
test_hostile_settings_symlinks_cannot_divert_the_write
test_flag_composes_with_model_and_effort
test_unsupported_routes_refuse_before_spawning
test_raw_launch_command_refuses
test_secondmate_refuses
test_batch_forwards_the_flag
