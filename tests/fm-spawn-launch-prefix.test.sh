#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh --launch-prefix.
#
# The flag exists so a caller that must confine, trace, or measure the agent PROCESS
# can interpose its own wrapper around the launch itself, instead of the engine
# growing a second seam per confinement technology (docs/launch-prefix.md).
#
# Four guarantees are load-bearing and all are asserted here through fm-spawn's own
# interface: a requested wrapper really reaches the composed launch and really becomes
# the agent's parent; every route that cannot carry it REFUSES before the spawn creates
# anything; a relaunch re-applies the recorded wrapper rather than quietly returning an
# unwrapped agent; and a spawn with no prefix is byte-identical to one from before the
# flag existed.
#
# A fake tmux captures the literal command sent with `tmux send-keys -l`, so the launch
# assertions pin what firstmate would run without starting a real harness. One test
# then EXECUTES that captured line against a fake wrapper and a fake harness, which is
# the only way to prove the composed text actually parents the agent rather than merely
# containing the right words in the right order.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
LOCK="$ROOT/bin/fm-lock.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-launch-prefix)
export FM_BACKEND=tmux

# The wrapper stands in for a real confinement command (sandbox-exec, a container
# runtime, a tracer). It records its own pid, publishes it to the process it starts,
# and runs that process as a CHILD - deliberately not exec - so an executed launch can
# prove the parent relationship rather than assume it.
make_wrapper() {  # <fakebin>
  cat > "$1/fmwrap" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_TEST_WRAP_LOG:-}" ] || printf 'wrapper pid=%s args=%s\n' "$$" "$#" >> "$FM_TEST_WRAP_LOG"
FM_TEST_WRAPPER_PID=$$ "$@"
SH
  chmod +x "$1/fmwrap"
}

# The harness the wrapper is supposed to be starting. It reports who its parent is and
# what argv survived the wrapping.
make_fake_harness() {  # <fakebin> <name>
  cat > "$1/$2" <<'SH'
#!/usr/bin/env bash
set -u
{
  printf 'agent ppid=%s wrapper=%s\n' "$PPID" "${FM_TEST_WRAPPER_PID:-none}"
  printf 'agent argc=%s\n' "$#"
  for a in "$@"; do printf 'agent arg=%s\n' "$a"; done
} >> "$FM_TEST_WRAP_LOG"
SH
  chmod +x "$1/$2"
}

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
  *"#{cursor_y}"*)
    if [ "${FM_FAKE_KIMI_SCREEN:-0}" = 1 ]; then
      printf '3\n'
      exit 0
    fi
    ;;
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
  capture-pane)
    if [ "${FM_FAKE_KIMI_SCREEN:-0}" = 1 ]; then
      printf '✨ Read the brief and follow it exactly.\ncontext: 1%% (2k/256k)\n╭────────────────────────────────╮\n│ >                              │\n╰────────────────────────────────╯\n'
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  make_wrapper "$fakebin"
  printf '%s\n' "$fakebin"
}

# One isolated case: a firstmate home, a real git worktree for the task, briefs for
# every id, and a fake bin dir carrying the wrapper. Fields come back as one '|' record.
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
    FM_FAKE_KIMI_SCREEN="${FM_FAKE_KIMI_SCREEN:-0}" \
    FM_FAKE_LAUNCH_LOG="$launchlog" GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

# Ship spawns carry an explicit delivery contract (AGENTS.md section 7); these tests
# are about the launch seam, so they pass a fixed valid one.
run_ship_spawn() {
  run_spawn "$@" --mode no-mistakes --yolo off
}

# The unwrapped claude ship launch, exactly as it read before this flag existed.
plain_claude_launch() {  # <home> <id>
  printf '%s' "env -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < '$1/data/$2/brief.md')\""
}

# --- 1. the wrapper reaches the composed launch ------------------------------

# The positive path: the wrapper words land immediately before the harness command
# word and after the launch's own environment assignments, the brief still rides the
# command, and the exact spliced text is recorded for later recovery.
test_prefix_wraps_the_composed_launch() {
  local rec id out status launch expected
  id=lp-wrap-a1
  rec=$(make_case wrap claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --launch-prefix fmwrap --launch-prefix -f --launch-prefix "$CASE_DIR/profile.sb")
  status=$?
  expect_code 0 "$status" "a wrapped claude spawn should succeed"$'\n'"$out"
  assert_contains "$out" "spawned $id harness=claude" "spawn did not report claude"
  assert_contains "$out" "launch prefix in effect for $id" "a wrapped spawn did not say so"

  launch=$(cat "$LAUNCH_LOG")
  expected="env -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false 'fmwrap' '-f' '$CASE_DIR/profile.sb' claude --dangerously-skip-permissions \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "the wrapped claude launch was not the expected command"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  assert_grep "launch_prefix='fmwrap' '-f' '$CASE_DIR/profile.sb'" "$HOME_DIR/state/$id.meta" \
    "meta did not record the exact spliced prefix"
  pass "--launch-prefix splices the wrapper immediately before the harness command"
}

# One occurrence is one argv word, so a wrapper argument containing spaces stays a
# single argument rather than word-splitting into several.
test_prefix_word_keeps_its_spaces() {
  local rec id out status launch profile
  id=lp-spaces-a2
  rec=$(make_case spaces claude "$id")
  read_case_record "$rec"
  profile="$CASE_DIR/my profile.sb"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --launch-prefix fmwrap --launch-prefix="--profile" --launch-prefix "$profile")
  status=$?
  expect_code 0 "$status" "a wrapped spawn with a spaced word should succeed"$'\n'"$out"

  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "'fmwrap' '--profile' '$profile' claude" \
    "a wrapper word containing spaces was not kept as one argument"
  pass "each --launch-prefix occurrence contributes exactly one argv word"
}

test_prefix_word_preserves_the_splice_literal() {
  local rec id out status launch
  id=lp-literal-a3
  rec=$(make_case literal-prefix claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --launch-prefix fmwrap --launch-prefix __LAUNCHPREFIX__)
  status=$?
  expect_code 0 "$status" "a wrapper argument matching the splice literal should succeed"$'\n'"$out"

  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "'fmwrap' '__LAUNCHPREFIX__' claude" \
    "a caller-owned wrapper argument was mistaken for the template splice point"
  pass "a wrapper argument matching the splice literal stays unchanged"
}

# The seam's actual promise is about processes, not text: run the composed line and
# prove the harness executed inside the wrapper, with its argv intact.
test_wrapped_launch_really_parents_the_agent() {
  local rec id out status launch wraplog wrapper_pid agent_ppid
  id=lp-parent-a3
  rec=$(make_case parent claude "$id")
  read_case_record "$rec"
  wraplog="$CASE_DIR/wrap.log"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --launch-prefix fmwrap)
  status=$?
  expect_code 0 "$status" "a wrapped claude spawn should succeed"$'\n'"$out"
  launch=$(cat "$LAUNCH_LOG")

  # The harness only has to exist for the executed line, not for the spawn, so it is
  # planted now - after the spawn - to keep it out of the resolution under test.
  make_fake_harness "$FAKEBIN_DIR" claude
  : > "$wraplog"
  ( cd "$WT_DIR" && PATH="$FAKEBIN_DIR:$PATH" FM_TEST_WRAP_LOG="$wraplog" \
      bash -c "$launch" ) || fail "the composed launch did not run cleanly"

  assert_grep 'wrapper pid=' "$wraplog" "the wrapper did not run"
  assert_grep 'agent ppid=' "$wraplog" "the harness did not run"
  wrapper_pid=$(sed -n 's/^wrapper pid=\([0-9]*\) .*/\1/p' "$wraplog")
  agent_ppid=$(sed -n 's/^agent ppid=\([0-9]*\) .*/\1/p' "$wraplog")
  [ -n "$wrapper_pid" ] && [ "$agent_ppid" = "$wrapper_pid" ] \
    || fail "the harness ran outside the wrapper (wrapper pid '$wrapper_pid', harness parent '$agent_ppid')"
  assert_grep "wrapper=$wrapper_pid" "$wraplog" "the harness did not inherit the wrapper's environment"
  assert_grep 'agent arg=--dangerously-skip-permissions' "$wraplog" "the harness lost its own flags"
  assert_grep "agent arg=" "$wraplog" "the harness received no arguments"
  grep -q "brief for $id" "$wraplog" || fail "the brief did not ride the wrapped launch"
  pass "the wrapped launch really runs the agent as a child of the wrapper"
}

# --- 2. no prefix changes nothing --------------------------------------------

# Additivity: an ordinary spawn is byte-identical to before the flag existed, its meta
# carries no launch_prefix line, and nothing announces a wrapper.
test_default_spawn_is_unchanged() {
  local rec id out status launch expected
  id=lp-default-b1
  rec=$(make_case default claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "an unwrapped claude spawn should succeed"$'\n'"$out"
  assert_not_contains "$out" "launch prefix" "an unwrapped spawn announced a prefix"

  launch=$(cat "$LAUNCH_LOG")
  expected=$(plain_claude_launch "$HOME_DIR" "$id")
  [ "$launch" = "$expected" ] || fail "the default claude launch changed"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  assert_no_grep 'launch_prefix' "$HOME_DIR/state/$id.meta" \
    "an unwrapped spawn wrote a launch_prefix line"
  assert_no_grep '__LAUNCHPREFIX__' "$HOME_DIR/state/$id.meta" \
    "the splice point leaked into task metadata"
  pass "a spawn with no prefix keeps the unchanged launch command and meta"
}

test_raw_launch_preserves_the_splice_literal_without_a_prefix() {
  local rec id out status launch expected
  id=lp-raw-literal-b2
  rec=$(make_case raw-literal claude "$id")
  read_case_record "$rec"
  expected='custom-agent --tag=__LAUNCHPREFIX__'

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "$expected")
  status=$?
  expect_code 0 "$status" "a raw no-prefix launch should pass through unchanged"$'\n'"$out"

  launch=$(cat "$LAUNCH_LOG")
  [ "$launch" = "$expected" ] || fail "the raw launch was rewritten"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  pass "a raw no-prefix launch keeps a literal splice token unchanged"
}

test_raw_known_harnesses_bypass_template_rendering() {
  local harness rec id out status raw launch expected n=0
  for harness in muse kimi; do
    n=$((n + 1))
    id="lp-raw-known-b2$n"
    rec=$(make_case "raw-known$n" claude "$id")
    read_case_record "$rec"
    raw="$harness --custom"
    expected="env -u CURSOR_AGENT -u CURSOR_INVOKED_AS $raw"
    mkdir -p "$HOME_DIR/.kimi-code/fm-turn-end.d"

    out=$(HOME="$HOME_DIR" FM_FAKE_KIMI_SCREEN=1 run_ship_spawn \
      "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" --harness "$raw")
    status=$?
    expect_code 0 "$status" "$harness: a raw no-prefix launch should succeed"$'\n'"$out"

    launch=$(sed -n '1p' "$LAUNCH_LOG")
    [ "$launch" = "$expected" ] || fail "$harness: the raw launch was rewritten"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  done
  pass "raw Muse and Kimi commands bypass template rendering"
}

# The splice point must never survive into a typed command, on any harness, wrapped or
# not - it would be a literal argument the harness cannot understand.
test_no_harness_leaks_the_splice_point() {
  local rec id out status launch harness n=0
  for harness in claude codex opencode grok; do
    n=$((n + 1))
    id="lp-leak-b2$n"
    rec=$(make_case "leak$n" "$harness" "$id")
    read_case_record "$rec"
    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
    status=$?
    expect_code 0 "$status" "$harness: an unwrapped spawn should succeed"$'\n'"$out"
    launch=$(cat "$LAUNCH_LOG")
    assert_not_contains "$launch" '__LAUNCHPREFIX__' "$harness: the splice point reached the typed launch"
    case "$launch" in
      *"$harness"*) ;;
      *) fail "$harness: the typed launch does not name the harness: $launch" ;;
    esac
  done
  pass "no harness leaks the splice point into an unwrapped launch"
}

# Placement is the whole correctness argument: the wrapper has to sit AFTER a
# template's own environment assignments and immediately BEFORE its command word. Put
# it earlier and the wrapper would try to execute an assignment; put it later and it
# would wrap an argument instead of the agent. Every harness whose launch can be
# composed without a vendor binary is checked, since each template's leading shape
# differs.
test_every_composable_harness_splices_at_the_command_word() {
  local label harness expect rec id out status launch n=0
  while IFS='|' read -r label harness expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    id="lp-place-c$n"
    rec=$(make_case "place$n" "$harness" "$id")
    read_case_record "$rec"
    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" --launch-prefix fmwrap)
    status=$?
    expect_code 0 "$status" "$label: a wrapped spawn should succeed"$'\n'"$out"
    launch=$(cat "$LAUNCH_LOG")
    assert_contains "$launch" "$expect" "$label: the wrapper is not at the command word"
  done <<'ROWS'
claude keeps its ghost-text env assignment outside the wrapper|claude|CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false 'fmwrap' claude
codex has no leading assignment to preserve|codex|CURSOR_INVOKED_AS 'fmwrap' codex
opencode keeps its permission config outside the wrapper|opencode|'{"permission":{"*":"allow"}}' 'fmwrap' opencode
grok has no leading assignment to preserve|grok|CURSOR_INVOKED_AS 'fmwrap' grok
ROWS
  pass "every composable harness splices the wrapper at its own command word"
}

# --- 3. composition with the other per-spawn guarantees ----------------------

# The intended consumer is a headless service running research scouts: it holds the
# home's session lock as a declared service owner, locks the worker out of the clone's
# instruction surfaces, and wraps the launch. All three must hold at once.
test_scout_composes_with_lockdown_and_a_service_owned_home() {
  local rec id out status launch expected lock_out
  id=lp-compose-c1
  rec=$(make_case compose claude "$id")
  read_case_record "$rec"

  lock_out=$(FM_HOME="$HOME_DIR" "$LOCK" service-acquire fm-test-service $$ 2>&1) \
    || fail "the service owner could not take the home's session lock: $lock_out"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --scout --no-project-instructions --launch-prefix fmwrap)
  status=$?
  expect_code 0 "$status" "a wrapped locked-down scout should succeed in a service-owned home"$'\n'"$out"
  assert_contains "$out" "kind=scout" "the spawn did not report a scout"

  launch=$(cat "$LAUNCH_LOG")
  expected="env -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false 'fmwrap' claude --dangerously-skip-permissions --setting-sources user,local \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "the wrapped locked-down scout launch was not the expected command"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  assert_grep 'project_instructions=off' "$HOME_DIR/state/$id.meta" \
    "the scout lost the discovery-off posture"
  assert_grep 'kind=scout' "$HOME_DIR/state/$id.meta" "the scout posture is missing from meta"
  assert_grep "launch_prefix='fmwrap'" "$HOME_DIR/state/$id.meta" "the scout lost the recorded prefix"

  lock_out=$(FM_HOME="$HOME_DIR" "$LOCK" service-verify fm-test-service $$ 2>&1) \
    || fail "the wrapped spawn disturbed the service owner's session lock: $lock_out"
  FM_HOME="$HOME_DIR" "$LOCK" service-release fm-test-service $$ >/dev/null 2>&1 || true
  pass "a wrapped scout composes with instruction lockdown and a service-owned home"
}

# A batch must carry the wrapper to every pair, or one confinement request would
# silently produce several unconfined workers.
test_batch_forwards_the_prefix() {
  local rec id_a id_b out status profile
  id_a=lp-batch-c2
  id_b=lp-batch-c3
  rec=$(make_case batch claude "$id_a" "$id_b")
  read_case_record "$rec"
  profile="$CASE_DIR/batch profile.sb"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id_a=$PROJ_DIR" "$id_b=$PROJ_DIR" --launch-prefix fmwrap --launch-prefix "$profile")
  status=$?
  expect_code 0 "$status" "a wrapped batch should succeed"$'\n'"$out"
  assert_grep "launch_prefix='fmwrap' '$profile'" "$HOME_DIR/state/$id_a.meta" \
    "the first batch pair lost the wrapper"
  assert_grep "launch_prefix='fmwrap' '$profile'" "$HOME_DIR/state/$id_b.meta" \
    "the second batch pair lost the wrapper"
  pass "batch dispatch forwards the wrapper, one argv word at a time, to every pair"
}

# --- 4. refusals -------------------------------------------------------------

# Every shape that cannot be honored exactly must refuse before the spawn creates task
# metadata or types a command, and must name the reason.
test_unusable_prefixes_refuse_before_spawning() {
  local label expect rec id out status n=0
  while IFS='|' read -r label expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    id="lp-refuse-d$n"
    rec=$(make_case "refuse$n" claude "$id")
    read_case_record "$rec"
    refusal_args_for "$label"
    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" "${LAUNCH_PREFIX_ARGS[@]}")
    status=$?
    [ "$status" -ne 0 ] || fail "$label: the spawn should have been refused"$'\n'"$out"
    assert_contains "$out" "$expect" "$label: the refusal did not name the reason"
    assert_absent "$HOME_DIR/state/$id.meta" "$label: a refused spawn still wrote task metadata"
    [ ! -s "$LAUNCH_LOG" ] || fail "$label: a refused spawn still typed a launch command"
  done < <(refusal_rows)
  pass "every unusable prefix refuses before the spawn creates anything"
}

# The refusal table. LAUNCH_PREFIX_ARGS is set per row because some rows need an
# argument the loop's own quoting must not reshape.
refusal_rows() {
  cat <<'ROWS'
an empty word|word 1 is empty
a word carrying a newline|contains a line break
an environment assignment first|not the environment assignment
an option first|not the option
an unknown command|was not found on PATH
a relative path|is a relative path
a missing absolute path|is not an executable file
ROWS
}

# Refusal arguments are chosen by label rather than parsed out of the table, so a value
# containing a newline or a space survives intact.
LAUNCH_PREFIX_ARGS=()
refusal_args_for() {  # <label>
  case "$1" in
    'an empty word') LAUNCH_PREFIX_ARGS=(--launch-prefix '') ;;
    'a word carrying a newline') LAUNCH_PREFIX_ARGS=(--launch-prefix "fmwrap"$'\n'"rm -rf /") ;;
    'an environment assignment first') LAUNCH_PREFIX_ARGS=(--launch-prefix 'SANDBOX=1') ;;
    'an option first') LAUNCH_PREFIX_ARGS=(--launch-prefix=-f) ;;
    'an unknown command') LAUNCH_PREFIX_ARGS=(--launch-prefix 'fm-no-such-wrapper-xyz') ;;
    'a relative path') LAUNCH_PREFIX_ARGS=(--launch-prefix './fmwrap') ;;
    'a missing absolute path') LAUNCH_PREFIX_ARGS=(--launch-prefix '/nonexistent/fmwrap') ;;
    *) fail "no refusal arguments defined for '$1'" ;;
  esac
}

# A secondmate is a firstmate instance that spawns its own workers, so wrapping its
# launch would confine the supervisor rather than the work.
test_secondmate_refuses() {
  local rec id out status sub_home
  id=lp-secondmate-d8
  rec=$(make_case secondmate claude "$id")
  read_case_record "$rec"
  sub_home="$CASE_DIR/sub-home"
  mkdir -p "$sub_home/bin" "$sub_home/data"
  printf '# Firstmate\n' > "$sub_home/AGENTS.md"
  printf '%s\n' "$id" > "$sub_home/.fm-secondmate-home"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$sub_home" --secondmate --launch-prefix fmwrap)
  status=$?
  [ "$status" -ne 0 ] || fail "a secondmate spawn should refuse --launch-prefix"$'\n'"$out"
  assert_contains "$out" "crewmate and scout spawns only" "the refusal did not name the kind"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused secondmate spawn still wrote task metadata"
  pass "--secondmate refuses a launch prefix instead of confining the supervisor"
}

test_registered_remote_secondmate_refuses() {
  local rec id out status
  id=lp-remote-secondmate-d9
  rec=$(make_case remote-secondmate claude "$id")
  read_case_record "$rec"
  printf '%s\n' "- $id - remote launch fixture (host: remote-mac; root: $CASE_DIR/remote-root; home: $CASE_DIR/remote-home; scope: remote launch testing; projects: none; added 2026-08-19)" \
    > "$HOME_DIR/data/secondmates.md"
  fm_fake_exit0 "$FAKEBIN_DIR" ssh

  out=$(FM_SSH_BIN="$FAKEBIN_DIR/ssh" run_spawn \
    "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" --secondmate --launch-prefix fmwrap)
  status=$?
  [ "$status" -ne 0 ] || fail "a registered remote secondmate should refuse --launch-prefix"$'\n'"$out"
  assert_contains "$out" "crewmate and scout spawns only" \
    "the remote route bypassed the launch-prefix refusal"
  assert_not_contains "$out" "spawned $id" "a refused remote secondmate reported success"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "a refused remote secondmate wrote task metadata"
  pass "a registered remote secondmate refuses before remote routing"
}

# A raw launch command is the unverified-adapter escape hatch: firstmate did not
# compose it, so it cannot know where the wrapper would have to go.
test_raw_launch_command_refuses() {
  local rec id out status
  id=lp-raw-d9
  rec=$(make_case raw claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "claude --dangerously-skip-permissions" --launch-prefix fmwrap)
  status=$?
  [ "$status" -ne 0 ] || fail "a raw launch command should refuse --launch-prefix"$'\n'"$out"
  assert_contains "$out" "cannot be applied to a raw launch command" \
    "the refusal did not name the raw launch command"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused raw-launch spawn still wrote task metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused raw-launch spawn still typed a launch command"
  pass "a raw launch command refuses a prefix rather than guessing where it goes"
}

# --- 5. relaunch -------------------------------------------------------------

# A relaunch adopts every identity axis from the task's own record, so it re-applies
# the recorded wrapper instead of handing back an unwrapped agent.
relaunch_case() {  # <name> <id> [extra-meta-line]
  local name=$1 id=$2 extra=${3:-} rec
  rec=$(make_case "$name" claude "$id")
  read_case_record "$rec"
  printf 'zsh' > "$CASE_DIR/pane-command"
  printf '%s\n' "fm-$id" > "$CASE_DIR/windows"
  {
    echo "window=firstmate:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$WT_DIR"
    echo "project=$PROJ_DIR"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=$CASE_DIR/tasktmp"
    echo "model=default"
    echo "effort=default"
    [ -z "$extra" ] || printf '%s\n' "$extra"
  } > "$HOME_DIR/state/$id.meta"
  mkdir -p "$CASE_DIR/tasktmp"
}

run_relaunch() {
  FM_FAKE_COMMAND_FILE="$CASE_DIR/pane-command" FM_FAKE_WINDOWS_FILE="$CASE_DIR/windows" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$@"
}

test_relaunch_reapplies_the_recorded_prefix() {
  local id out status launch
  id=lp-relaunch-e1
  relaunch_case relaunch-wrapped "$id" "launch_prefix='fmwrap' '-f' '/etc/hosts'"

  out=$(run_relaunch "$id" --relaunch)
  status=$?
  expect_code 0 "$status" "a relaunch of a wrapped task should succeed"$'\n'"$out"
  assert_contains "$out" "launch prefix in effect for $id" "the relaunch did not say the wrapper was applied"

  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "'fmwrap' '-f' '/etc/hosts' claude" \
    "the relaunch dropped the recorded wrapper"
  assert_grep "launch_prefix='fmwrap' '-f' '/etc/hosts'" "$HOME_DIR/state/$id.meta" \
    "the relaunch did not keep the recorded wrapper"
  pass "a relaunch re-applies the wrapper recorded for the task"
}

test_relaunch_without_a_recorded_prefix_is_unchanged() {
  local id out status launch expected
  id=lp-relaunch-e2
  relaunch_case relaunch-plain "$id"

  out=$(run_relaunch "$id" --relaunch)
  status=$?
  expect_code 0 "$status" "a relaunch of an unwrapped task should succeed"$'\n'"$out"
  assert_not_contains "$out" "launch prefix" "an unwrapped relaunch announced a prefix"

  launch=$(cat "$LAUNCH_LOG")
  expected="unset TRACEPARENT; $(plain_claude_launch "$HOME_DIR" "$id")"
  [ "$launch" = "$expected" ] || fail "an unwrapped relaunch changed"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  assert_no_grep 'launch_prefix' "$HOME_DIR/state/$id.meta" \
    "an unwrapped relaunch wrote a launch_prefix line"
  pass "a relaunch with nothing recorded keeps the unchanged launch command"
}

test_relaunch_refuses_an_explicit_prefix() {
  local id out status
  id=lp-relaunch-e3
  relaunch_case relaunch-explicit "$id" "launch_prefix='fmwrap'"

  out=$(run_relaunch "$id" --relaunch --launch-prefix fmwrap)
  status=$?
  [ "$status" -ne 0 ] || fail "a relaunch should refuse an explicit --launch-prefix"$'\n'"$out"
  assert_contains "$out" "reuses the task's recorded launch prefix" \
    "the refusal did not name the recorded prefix"
  pass "a relaunch refuses an explicit prefix like every other recorded axis"
}

# A record that could not be typed as one launch line must refuse rather than relaunch
# the task unwrapped.
test_relaunch_refuses_a_corrupt_recorded_prefix() {
  local id out status
  id=lp-relaunch-e4
  relaunch_case relaunch-corrupt "$id"
  # A record whose value carries a bare carriage return: still one meta line, but not
  # one shell line.
  printf "launch_prefix='fmwrap'\r' '-f'\n" >> "$HOME_DIR/state/$id.meta"

  out=$(run_relaunch "$id" --relaunch)
  status=$?
  [ "$status" -ne 0 ] || fail "a corrupt recorded prefix should refuse the relaunch"$'\n'"$out"
  assert_contains "$out" "cannot be typed as one launch line" \
    "the refusal did not name the unusable record"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused relaunch still typed a launch command"
  pass "a recorded prefix that cannot be typed refuses rather than relaunching unwrapped"
}

test_relaunch_refuses_a_duplicate_empty_record() {
  local id out status
  id=lp-relaunch-e5
  relaunch_case relaunch-duplicate "$id" "launch_prefix='fmwrap'"
  printf 'launch_prefix=\n' >> "$HOME_DIR/state/$id.meta"

  out=$(run_relaunch "$id" --relaunch)
  status=$?
  [ "$status" -ne 0 ] || fail "duplicate recorded prefixes should refuse the relaunch"$'\n'"$out"
  assert_contains "$out" "must be exactly one launch_prefix= line" \
    "the refusal did not name the duplicate record"
  [ ! -s "$LAUNCH_LOG" ] || fail "a duplicate empty record still launched an agent"
  pass "a duplicate empty prefix record cannot clear wrapping on relaunch"
}

test_relaunch_refuses_a_noncanonical_record() {
  local id out status
  id=lp-relaunch-e6
  relaunch_case relaunch-noncanonical "$id" 'launch_prefix=true;'

  out=$(run_relaunch "$id" --relaunch)
  status=$?
  [ "$status" -ne 0 ] || fail "an unquoted recorded prefix should refuse the relaunch"$'\n'"$out"
  assert_contains "$out" "not a nonempty canonical shell-quoted record" \
    "the refusal did not name the noncanonical record"
  [ ! -s "$LAUNCH_LOG" ] || fail "a noncanonical record still launched an agent"
  pass "a noncanonical prefix record cannot inject a separate relaunch command"
}

test_relaunch_refuses_an_lf_split_record() {
  local id out status
  id=lp-relaunch-e7
  relaunch_case relaunch-lf-split "$id"
  printf "launch_prefix='fmwrap'\n '-f' '/profile.sb'\n" >> "$HOME_DIR/state/$id.meta"

  out=$(run_relaunch "$id" --relaunch)
  status=$?
  [ "$status" -ne 0 ] || fail "an LF-split recorded prefix should refuse the relaunch"$'\n'"$out"
  assert_contains "$out" "cannot be reconstructed without truncation" \
    "the refusal did not name the truncated multiline record"
  [ ! -s "$LAUNCH_LOG" ] || fail "an LF-split record still launched a partial wrapper"
  pass "an LF-split prefix record cannot truncate confinement arguments"
}

test_prefix_wraps_the_composed_launch
test_prefix_word_keeps_its_spaces
test_prefix_word_preserves_the_splice_literal
test_wrapped_launch_really_parents_the_agent
test_default_spawn_is_unchanged
test_raw_launch_preserves_the_splice_literal_without_a_prefix
test_raw_known_harnesses_bypass_template_rendering
test_no_harness_leaks_the_splice_point
test_every_composable_harness_splices_at_the_command_word
test_scout_composes_with_lockdown_and_a_service_owned_home
test_batch_forwards_the_prefix
test_unusable_prefixes_refuse_before_spawning
test_secondmate_refuses
test_registered_remote_secondmate_refuses
test_raw_launch_command_refuses
test_relaunch_reapplies_the_recorded_prefix
test_relaunch_without_a_recorded_prefix_is_unchanged
test_relaunch_refuses_an_explicit_prefix
test_relaunch_refuses_a_corrupt_recorded_prefix
test_relaunch_refuses_a_duplicate_empty_record
test_relaunch_refuses_a_noncanonical_record
test_relaunch_refuses_an_lf_split_record
