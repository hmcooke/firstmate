#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh --no-project-instructions.
#
# The flag exists so a worker standing in an untrusted clone does not inherit that
# repo's instruction surfaces as live configuration. Three guarantees are load-bearing
# and all are asserted here through fm-spawn's own interface: a supported harness
# really carries the disable flags into the launch command and records the posture in
# meta; every unsupported route REFUSES before the spawn creates anything; and a
# relaunch re-applies the recorded posture rather than returning an unprotected worker
# into the same untrusted clone.
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
  *"#{pane_current_command}"*)
    if [ -n "${FM_FAKE_COMMAND_FILE:-}" ] && [ -f "$FM_FAKE_COMMAND_FILE" ]; then
      cat "$FM_FAKE_COMMAND_FILE"; printf '\n'
    else
      printf 'zsh\n'
    fi
    exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    if [ -n "${FM_FAKE_WINDOWS_FILE:-}" ] && [ -f "$FM_FAKE_WINDOWS_FILE" ]; then
      cat "$FM_FAKE_WINDOWS_FILE"
    fi
    exit 0 ;;
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
    FM_FAKE_COMMAND_FILE="${FM_FAKE_COMMAND_FILE:-}" \
    FM_FAKE_WINDOWS_FILE="${FM_FAKE_WINDOWS_FILE:-}" \
    FM_FAKE_LAUNCH_LOG="$launchlog" GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

# Ship spawns carry an explicit delivery contract (AGENTS.md section 7); these
# tests are about instruction discovery, so they pass a fixed valid one.
run_ship_spawn() {
  run_spawn "$@" --mode no-mistakes --yolo off
}

# Plant a repo-supplied settings symlink the way an untrusted clone really ships one:
# committed on the default branch. A fresh ship worktree is reset to origin's default
# tip before launch, so a symlink staged only in the worktree would be discarded before
# fm-spawn ever sees it and the hostile shape would go untested.
plant_repo_symlink() {  # <repo> <shape> <target>
  local repo=$1 shape=$2 target=$3
  case "$shape" in
    dir) ln -s "$target" "$repo/.claude" ;;
    file) mkdir -p "$repo/.claude"; ln -s "$target" "$repo/.claude/settings.local.json" ;;
  esac
  git -C "$repo" add -f .claude
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm "symlink fixture" || return 1
  git -C "$repo" push --quiet origin HEAD || return 1
}

# The positive path: the verified claude mechanism reaches the typed launch command,
# the brief still rides that command, and meta records the posture for supervision.
test_supported_harness_carries_flags_and_records_meta() {
  local rec id out status launch expected
  id=nopi-supported-z1
  rec=$(make_case supported claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --no-project-instructions)
  status=$?
  expect_code 0 "$status" "claude spawn with --no-project-instructions should succeed"
  assert_contains "$out" "spawned $id harness=claude" "spawn did not report claude"

  launch=$(cat "$LAUNCH_LOG")
  expected="env -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions --setting-sources user,local \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/brief.md')\""
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

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn without the flag should succeed"
  assert_contains "$out" "spawned $id harness=claude" "spawn did not report claude"

  launch=$(cat "$LAUNCH_LOG")
  expected="env -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "default claude launch changed"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  assert_no_grep 'project_instructions' "$HOME_DIR/state/$id.meta" \
    "default spawn wrote a project_instructions line"
  pass "default spawns keep the unchanged launch command and meta"
}

# A default claude spawn must preserve the repo's discovery surfaces exactly as it
# did before the lockdown flag existed, even when either settings path is a symlink.
test_default_spawn_preserves_repo_settings_symlinks() {
  local label shape rec id out status outside expected_link dirty n=0
  while IFS='|' read -r label shape; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    id="nopi-default-symlink-z2$n"
    rec=$(make_case "default-symlink$n" claude "$id")
    read_case_record "$rec"
    outside="$CASE_DIR/outside-target"
    : > "$outside"
    case "$shape" in
      dir) mkdir -p "$CASE_DIR/outside-dir"; expected_link="$CASE_DIR/outside-dir" ;;
      file) expected_link="$outside" ;;
    esac
    plant_repo_symlink "$PROJ_DIR" "$shape" "$expected_link" \
      || fail "$label: could not commit the symlink fixture"

    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR")
    status=$?
    expect_code 0 "$status" "$label: default spawn should still succeed"

    case "$shape" in
      dir) [ -L "$WT_DIR/.claude" ] || fail "$label: default spawn replaced .claude" ;;
      file) [ -L "$WT_DIR/.claude/settings.local.json" ] || fail "$label: default spawn replaced settings.local.json" ;;
    esac
    case "$shape" in
      dir) [ "$(readlink "$WT_DIR/.claude")" = "$expected_link" ] || fail "$label: default spawn retargeted .claude" ;;
      file) [ "$(readlink "$WT_DIR/.claude/settings.local.json")" = "$expected_link" ] || fail "$label: default spawn retargeted settings.local.json" ;;
    esac
    dirty=$(git -C "$WT_DIR" status --porcelain)
    [ -z "$dirty" ] || fail "$label: default spawn dirtied the worktree: $dirty"
  done <<'ROWS'
.claude symlink remains part of project discovery|dir
settings.local.json symlink remains part of project discovery|file
ROWS
  pass "default claude spawns preserve repo-supplied settings symlinks"
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

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
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
  local label shape rec id out status outside link_target n=0
  while IFS='|' read -r label shape; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    id="nopi-symlink-z1$n"
    rec=$(make_case "symlink$n" claude "$id")
    read_case_record "$rec"
    outside="$CASE_DIR/outside-target"
    : > "$outside"
    case "$shape" in
      dir) mkdir -p "$CASE_DIR/outside-dir"; link_target="$CASE_DIR/outside-dir" ;;
      file) link_target="$outside" ;;
    esac
    plant_repo_symlink "$PROJ_DIR" "$shape" "$link_target" \
      || fail "$label: could not commit the symlink fixture"

    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
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

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
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
    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
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
cursor is unverified|cursor|has no verified way to disable project instruction discovery
muse is unverified|muse|has no verified way to disable project instruction discovery
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

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
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

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id_a=$PROJ_DIR" "$id_b=$PROJ_DIR" --no-project-instructions)
  status=$?
  expect_code 0 "$status" "batch spawn with --no-project-instructions should succeed"
  assert_grep 'project_instructions=off' "$HOME_DIR/state/$id_a.meta" \
    "first batch pair lost the discovery-off posture"
  assert_grep 'project_instructions=off' "$HOME_DIR/state/$id_b.meta" \
    "second batch pair lost the discovery-off posture"
  pass "batch dispatch forwards --no-project-instructions to every pair"
}

# --- relaunch ----------------------------------------------------------------
#
# A relaunch replaces the worker in an existing task's endpoint, so it must re-apply the
# recorded posture. Handing back a worker with full discovery, in the same untrusted
# clone, while the record still reads project_instructions=off is the worst shape: it
# looks protected and is not.

# A task record as fm-spawn writes one, plus whatever posture line the case is about.
# The harness is explicit because a relaunch takes it from the record, not from config.
relaunch_case() {  # <name> <harness> <id> [extra-meta-line...]
  local name=$1 harness=$2 id=$3 rec line
  shift 3
  rec=$(make_case "$name" "$harness" "$id")
  read_case_record "$rec"
  printf 'zsh' > "$CASE_DIR/pane-command"
  printf '%s\n' "fm-$id" > "$CASE_DIR/windows"
  {
    echo "window=firstmate:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$WT_DIR"
    echo "project=$PROJ_DIR"
    echo "harness=$harness"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=$CASE_DIR/tasktmp"
    echo "model=default"
    echo "effort=default"
    for line in "$@"; do printf '%s\n' "$line"; done
  } > "$HOME_DIR/state/$id.meta"
  mkdir -p "$CASE_DIR/tasktmp"
}

run_relaunch() {
  FM_FAKE_COMMAND_FILE="$CASE_DIR/pane-command" FM_FAKE_WINDOWS_FILE="$CASE_DIR/windows" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$@"
}

# The replacement worker must carry the same disable flags the original did. One row per
# harness the allowlist supports, so extending it here fails until the relaunch path
# carries that harness's own form too.
test_relaunch_reapplies_the_recorded_lockdown() {
  local label harness expect id out status launch n=0
  while IFS='|' read -r label harness expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    id="nopi-relaunch-r1$n"
    relaunch_case "relaunch-locked$n" "$harness" "$id" 'project_instructions=off'

    out=$(run_relaunch "$id" --relaunch)
    status=$?
    expect_code 0 "$status" "$label: a relaunch of a protected task should succeed"$'\n'"$out"

    launch=$(cat "$LAUNCH_LOG")
    assert_contains "$launch" "$expect" "$label: the relaunch dropped the disable flags"
    [ "$(grep -c '^project_instructions=off$' "$HOME_DIR/state/$id.meta")" = 1 ] \
      || fail "$label: the relaunch did not leave exactly one recorded posture line"$'\n'"$(cat "$HOME_DIR/state/$id.meta")"
  done <<'ROWS'
claude re-applies its verified settings-source form|claude|--setting-sources user,local
ROWS
  pass "a relaunch re-applies the discovery-disable flags recorded for the task"
}

# Additivity on the relaunch path too: a task with no recorded posture relaunches exactly
# as it did before this axis existed.
test_relaunch_without_a_recorded_posture_is_unchanged() {
  local id out status launch expected
  id=nopi-relaunch-r2
  relaunch_case relaunch-plain claude "$id"

  out=$(run_relaunch "$id" --relaunch)
  status=$?
  expect_code 0 "$status" "a relaunch of an ordinary task should succeed"$'\n'"$out"

  launch=$(cat "$LAUNCH_LOG")
  expected="unset TRACEPARENT; env -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "an ordinary relaunch changed"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  assert_no_grep 'project_instructions' "$HOME_DIR/state/$id.meta" \
    "an ordinary relaunch invented a posture line"
  pass "a relaunch with no recorded posture keeps the unchanged launch command"
}

test_relaunch_refuses_an_explicit_flag() {
  local id out status
  id=nopi-relaunch-r3
  relaunch_case relaunch-explicit claude "$id" 'project_instructions=off'

  out=$(run_relaunch "$id" --relaunch --no-project-instructions)
  status=$?
  [ "$status" -ne 0 ] || fail "a relaunch should refuse an explicit --no-project-instructions"$'\n'"$out"
  assert_contains "$out" "reuses the task's recorded project-instruction posture" \
    "the refusal did not name the recorded posture"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused relaunch still typed a launch command"
  pass "a relaunch refuses an explicit flag like every other recorded axis"
}

# A record firstmate cannot read as a posture must refuse. Treating an unreadable or
# ambiguous record as "discovery on" would silently downgrade the guarantee on exactly the
# path that exists to recover a protected worker.
test_relaunch_refuses_a_corrupt_recorded_posture() {
  local label recorded expect id out status n=0
  local -a lines
  # Each row carries the posture line(s) the record holds, ';'-separated.
  while IFS='|' read -r label recorded expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    id="nopi-relaunch-r4$n"
    IFS=';' read -r -a lines <<EOF
$recorded
EOF
    relaunch_case "relaunch-corrupt$n" claude "$id" "${lines[@]}"

    out=$(run_relaunch "$id" --relaunch)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: a corrupt recorded posture should refuse the relaunch"$'\n'"$out"
    assert_contains "$out" "$expect" "$label: the refusal did not name the unusable record"
    [ ! -s "$LAUNCH_LOG" ] || fail "$label: a refused relaunch still typed a launch command"
  done <<'ROWS'
an unknown value is not a posture firstmate wrote|project_instructions=on|off is the only recorded value
an empty value cannot clear protection silently|project_instructions=|off is the only recorded value
a truncated value is not a posture firstmate wrote|project_instructions=of|off is the only recorded value
a duplicate empty line cannot clear protection|project_instructions=off;project_instructions=|must be exactly one project_instructions= line
even identical duplicates are ambiguous|project_instructions=off;project_instructions=off|must be exactly one project_instructions= line
ROWS
  pass "a recorded posture firstmate cannot read refuses rather than relaunching unprotected"
}

# A relaunch may move a task onto another harness. If that harness has no verified way to
# disable discovery, the protected task must refuse rather than land there unprotected.
test_relaunch_refuses_a_harness_without_a_disable_form() {
  local id out status
  id=nopi-relaunch-r5
  relaunch_case relaunch-harness-swap claude "$id" 'project_instructions=off'

  out=$(run_relaunch "$id" --relaunch --harness codex)
  status=$?
  [ "$status" -ne 0 ] || fail "a protected task should refuse a relaunch onto codex"$'\n'"$out"
  assert_contains "$out" "has no verified way to disable project instruction discovery" \
    "the refusal did not name the missing mechanism"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused harness swap still typed a launch command"
  assert_grep 'harness=claude' "$HOME_DIR/state/$id.meta" \
    "a refused harness swap rewrote the task record"
  pass "a relaunch onto a harness with no disable form refuses rather than dropping protection"
}

test_supported_harness_carries_flags_and_records_meta
test_default_spawn_is_unchanged
test_default_spawn_preserves_repo_settings_symlinks
test_lockdown_keeps_firstmate_own_supervision_hooks
test_hostile_settings_symlinks_cannot_divert_the_write
test_flag_composes_with_model_and_effort
test_unsupported_routes_refuse_before_spawning
test_raw_launch_command_refuses
test_secondmate_refuses
test_batch_forwards_the_flag
test_relaunch_reapplies_the_recorded_lockdown
test_relaunch_without_a_recorded_posture_is_unchanged
test_relaunch_refuses_an_explicit_flag
test_relaunch_refuses_a_corrupt_recorded_posture
test_relaunch_refuses_a_harness_without_a_disable_form
