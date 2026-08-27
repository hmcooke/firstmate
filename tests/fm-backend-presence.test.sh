#!/usr/bin/env bash
# tests/fm-backend-presence.test.sh - the tri-state endpoint-presence contract
# owned by bin/fm-backend.sh's fm_backend_target_presence, and each adapter's
# conforming classifier in bin/backends/.
#
# The gap under test (evidence 2026-08-27): every adapter's presence read was a
# two-way boolean, so a FAILED observation - a CLI error, a socket that is
# down, an inventory scoped to the wrong window, or a missing CLI - was
# reported as "the endpoint is gone". Absence of evidence became evidence of
# absence, and the consumers that act on it (the session-start digest, the
# structured fleet view, the watcher's busy classifier, and cleanup's durable
# record removal) then proceeded as if the worker had already exited.
#
# The guarantees under test:
#   - fm_backend_target_presence prints exactly present, absent, or unknown.
#   - absent requires POSITIVE evidence: a successful, in-scope observation
#     that shows the recorded endpoint gone, or a definitive server-is-not-
#     running answer that proves no endpoint can exist.
#   - Every failed, timed-out, unparseable, scope-limited, or tool-missing
#     observation is unknown, for all five adapters. A timed-out read is driven
#     as the exit status `timeout` itself returns, since none of these
#     primitives carries its own deadline - a deadline belongs to the caller,
#     and this is what its expiry looks like to the classifier.
#   - fm_backend_target_exists stays the boolean compatibility view of present.
#   - fm_backend_endpoint_confirmed_gone, the gate cleanup uses before erasing
#     a durable endpoint record, is true only for absent.
#   - tmux presence comes from a server-wide pane inventory, never from
#     display-message: tmux silently falls back to the active window, so
#     display-message reports a window that does not exist as live. The target's
#     shape selects a single-field alias format, and a shape the inventory
#     cannot enumerate by value stays unknown.
#   - cmux presence sweeps every window, because `workspace list` with no
#     --window is scoped to the current window only.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-backend-presence)

# Every probe runs with only <fakebin> plus the base path visible, so an
# installed real CLI can never answer for a fake one. EXTRA_PATH adds the
# directory of a required real interpreter (node, for the Orca adapter) without
# widening the search enough to expose a real backend CLI - the fakebin still
# comes first, and an absent-CLI case still sees no CLI at all.
EXTRA_PATH=

# PROBE_LOCALE pins the locale each probe runs under. It matters for exactly one
# guarantee - a non-ASCII target can never earn `absent` - because a
# collation-based check would answer differently per locale, so that case is
# driven under both a C and a UTF-8 locale.
PROBE_LOCALE=${LC_ALL:-${LANG:-C}}

# probe_utf8_locale: an installed UTF-8 locale name, or empty when the machine
# has none to offer.
probe_utf8_locale() {
  locale -a 2>/dev/null | grep -iE '\.(utf-?8)$' | head -1
}

probe_path() {
  if [ -n "$EXTRA_PATH" ]; then
    printf '%s:%s:%s' "$1" "$EXTRA_PATH" "$BASE_PATH"
  else
    printf '%s:%s' "$1" "$BASE_PATH"
  fi
}

presence() {  # <fakebin> <backend> <target> [expected-label]
  local fb=$1
  shift
  PATH="$(probe_path "$fb")" LC_ALL="$PROBE_LOCALE" bash -c \
    '. "$0/bin/fm-backend.sh"; fm_backend_target_presence "$@"' "$ROOT" "$@"
}

exists() {  # <fakebin> <backend> <target> [expected-label] -> "exists"|"gone"
  local fb=$1
  shift
  if PATH="$(probe_path "$fb")" LC_ALL="$PROBE_LOCALE" bash -c \
    '. "$0/bin/fm-backend.sh"; fm_backend_target_exists "$@"' "$ROOT" "$@"; then
    printf 'exists'
  else
    printf 'gone'
  fi
}

confirmed_gone() {  # <fakebin> <backend> <target> [expected-label] -> "yes"|"no"
  local fb=$1
  shift
  if PATH="$(probe_path "$fb")" LC_ALL="$PROBE_LOCALE" bash -c \
    '. "$0/bin/fm-backend.sh"; fm_backend_endpoint_confirmed_gone "$@"' "$ROOT" "$@"; then
    printf 'yes'
  else
    printf 'no'
  fi
}

expect_presence() {  # <fakebin> <backend> <target> <expected> <message> [label]
  local fb=$1 backend=$2 target=$3 want=$4 msg=$5 label=${6-} got
  if [ -n "$label" ]; then
    got=$(presence "$fb" "$backend" "$target" "$label")
  else
    got=$(presence "$fb" "$backend" "$target")
  fi
  [ "$got" = "$want" ] || fail "$msg (expected '$want', got '$got')"
}

# --- tmux --------------------------------------------------------------------

# make_tmux <dir> <mode>: a fake tmux driving one list-panes inventory outcome.
# display-message always answers with the ACTIVE pane, exactly like the real
# binary's documented target fallback, so a classifier that trusts it cannot
# tell a live window from a closed one.
make_tmux() {  # <dir> <mode>
  local dir=$1 mode=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  display-message) printf '%s\n' '%0'; exit 0 ;;
  list-panes)
    case '$mode' in
      present)
        printf '%s\n' '%7' '@3' 'sess:fm-task' 'sess:1' 'sess:fm-task.0' 'sess:1.0' 'sess' '\$1'
        exit 0 ;;
      other-window)
        printf '%s\n' '%0' '@0' 'sess:main' 'sess:0' 'sess:main.0' 'sess:0.0' 'sess' '\$1'
        exit 0 ;;
      no-server)
        printf '%s\n' 'no server running on /tmp/tmux-1000/default' >&2; exit 1 ;;
      no-socket)
        printf '%s\n' 'error connecting to /tmp/tmux-1000/default (No such file or directory)' >&2; exit 1 ;;
      long-path)
        printf '%s\n' 'error connecting to /very/long/socket/path (File name too long)' >&2; exit 1 ;;
      denied)
        printf '%s\n' 'permission denied' >&2; exit 1 ;;
      silent-failure)
        exit 1 ;;
      timed-out)
        exit 124 ;;
    esac
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

test_tmux_presence() {
  local fb saved_locale utf8_locale

  fb=$(make_tmux "$TMP_ROOT/tmux-present" present)
  expect_presence "$fb" tmux sess:fm-task present "a window in a readable inventory is present"
  [ "$(exists "$fb" tmux sess:fm-task)" = exists ] || fail "the boolean view must stay true for a present window"
  [ "$(confirmed_gone "$fb" tmux sess:fm-task)" = no ] || fail "a present window must never be confirmed gone"

  fb=$(make_tmux "$TMP_ROOT/tmux-other" other-window)
  expect_presence "$fb" tmux sess:fm-task absent "a readable inventory that omits the window is positive evidence of absence"
  [ "$(confirmed_gone "$fb" tmux sess:fm-task)" = yes ] || fail "an omitted window must be confirmed gone"
  expect_presence "$fb" tmux '%0' present "a recorded pane id present in the inventory is present"
  expect_presence "$fb" tmux '%9' absent "a pane id a readable inventory omits is absent"

  fb=$(make_tmux "$TMP_ROOT/tmux-no-server" no-server)
  expect_presence "$fb" tmux sess:fm-task absent "no tmux server running proves no pane can exist"

  fb=$(make_tmux "$TMP_ROOT/tmux-no-socket" no-socket)
  expect_presence "$fb" tmux sess:fm-task absent "a missing tmux socket proves no pane can exist"

  for mode in long-path denied silent-failure timed-out; do
    fb=$(make_tmux "$TMP_ROOT/tmux-$mode" "$mode")
    expect_presence "$fb" tmux sess:fm-task unknown \
      "a failed or timed-out tmux inventory ($mode) is unknown, never absent"
    [ "$(confirmed_gone "$fb" tmux sess:fm-task)" = no ] \
      || fail "a failed tmux inventory ($mode) must never confirm the endpoint gone"
  done

  fb=$(make_tmux "$TMP_ROOT/tmux-empty-target" present)
  expect_presence "$fb" tmux '' unknown "an empty tmux target is ambiguity, never absence"

  # A target shape the inventory cannot enumerate by value - tmux's exact-match
  # `=` syntax, or a glob - is ambiguity, never absence.
  fb=$(make_tmux "$TMP_ROOT/tmux-unenumerable" other-window)
  expect_presence "$fb" tmux '=sess:=fm-task' unknown "tmux's exact-match target syntax is ambiguity, never absence"
  expect_presence "$fb" tmux 'sess:fm-*' unknown "a glob tmux target is ambiguity, never absence"
  expect_presence "$fb" tmux 'sess:win:extra' unknown "a three-part tmux selector is ambiguity, never absence"
  expect_presence "$fb" tmux ':fm-task' unknown "a current-client :window shorthand is ambiguity, never absence"
  expect_presence "$fb" tmux 'sess:' unknown "a current-client session: shorthand is ambiguity, never absence"

  # A non-ASCII target cannot earn absence in ANY locale: whether tmux escapes
  # such a name depends on the SERVER's locale, which this client cannot read,
  # so a non-match proves nothing either way. Both locales are exercised because
  # a collation-based check would answer differently in each.
  saved_locale=$PROBE_LOCALE
  PROBE_LOCALE=C
  expect_presence "$fb" tmux 'sess:café' unknown \
    "a non-ASCII tmux window name is ambiguity under a C locale"
  utf8_locale=$(probe_utf8_locale)
  if [ -n "$utf8_locale" ]; then
    PROBE_LOCALE=$utf8_locale
    expect_presence "$fb" tmux 'sess:café' unknown \
      "a non-ASCII tmux window name is ambiguity under a UTF-8 locale too"
  fi
  PROBE_LOCALE=$saved_locale

  pass "tmux presence: inventory-backed, and every failed read stays unknown"
}

# --- herdr -------------------------------------------------------------------

make_herdr() {  # <dir> <mode>
  local dir=$1 mode=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
[ "\${1:-}" = pane ] && [ "\${2:-}" = get ] || exit 1
case '$mode' in
  present) printf '%s\n' '{"result":{"pane":{"pane_id":"p1"}}}'; exit 0 ;;
  gone) printf '%s\n' '{"ok":false,"error":{"code":"pane_not_found"}}'; exit 1 ;;
  unreachable) printf '%s\n' '{"ok":false,"error":{"code":"server_unreachable"}}'; exit 1 ;;
  garbage) printf '%s\n' 'herdr: connection reset' >&2; exit 1 ;;
  mismatch) printf '%s\n' '{"result":{"pane":{"pane_id":"p-other"}}}'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/herdr"
  printf '%s\n' "$fakebin"
}

test_herdr_presence() {
  local fb

  fb=$(make_herdr "$TMP_ROOT/herdr-present" present)
  expect_presence "$fb" herdr sess:p1 present "a pane that round-trips its own id is present"

  fb=$(make_herdr "$TMP_ROOT/herdr-gone" gone)
  expect_presence "$fb" herdr sess:p1 absent "a structured pane_not_found is positive evidence of absence"
  [ "$(confirmed_gone "$fb" herdr sess:p1)" = yes ] || fail "pane_not_found must be confirmed gone"

  for mode in unreachable garbage mismatch; do
    fb=$(make_herdr "$TMP_ROOT/herdr-$mode" "$mode")
    expect_presence "$fb" herdr sess:p1 unknown "an inconclusive herdr read ($mode) is unknown, never absent"
    [ "$(confirmed_gone "$fb" herdr sess:p1)" = no ] \
      || fail "an inconclusive herdr read ($mode) must never confirm the endpoint gone"
  done

  fb=$(make_herdr "$TMP_ROOT/herdr-malformed" present)
  expect_presence "$fb" herdr malformed unknown "a malformed herdr target is ambiguity, never absence"

  pass "herdr presence: only a structured pane_not_found is absence"
}

# --- zellij ------------------------------------------------------------------

# ZELLIJ_SCOPED_TITLE is the home-scoped tab title the adapter derives for the
# fm-task label, so the fake's tab list can carry a genuinely matching name.
ZELLIJ_SCOPED_TITLE=

make_zellij() {  # <dir> <mode>
  local dir=$1 mode=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/zellij" <<SH
#!/usr/bin/env bash
set -u
for a in "\$@"; do
  case "\$a" in
    list-sessions)
      case '$mode' in
        sessions-fail) printf '%s\n' 'zellij: could not connect' >&2; exit 1 ;;
        session-gone) printf '%s\n' 'other'; exit 0 ;;
        *) printf '%s\n' 'sess'; exit 0 ;;
      esac
      ;;
    list-panes)
      case '$mode' in
        pane-gone) printf '%s\n' '[{"id":9,"is_plugin":false,"tab_id":2}]'; exit 0 ;;
        panes-fail) printf '%s\n' 'zellij: query timed out' >&2; exit 1 ;;
        panes-timed-out) exit 124 ;;
        panes-garbage) printf '%s\n' 'not json'; exit 0 ;;
        *) printf '%s\n' '[{"id":7,"is_plugin":false,"tab_id":2}]'; exit 0 ;;
      esac
      ;;
    list-tabs)
      case '$mode' in
        tabs-fail) printf '%s\n' 'zellij: query timed out' >&2; exit 1 ;;
        label-mismatch) printf '%s\n' '[{"tab_id":2,"name":"someone-elses-tab"}]'; exit 0 ;;
        *) printf '%s\n' '[{"tab_id":2,"name":"$ZELLIJ_SCOPED_TITLE"}]'; exit 0 ;;
      esac
      ;;
  esac
done
exit 0
SH
  chmod +x "$fakebin/zellij"
  printf '%s\n' "$fakebin"
}

test_zellij_presence() {
  local fb
  command -v jq >/dev/null 2>&1 || { echo "skip - jq not found (required by the zellij adapter)"; return 0; }
  ZELLIJ_SCOPED_TITLE=$(PATH="$BASE_PATH" bash -c \
    '. "$0/bin/fm-backend.sh"; fm_backend_source zellij; fm_backend_zellij_scoped_title fm-task' "$ROOT")

  fb=$(make_zellij "$TMP_ROOT/zellij-present" present)
  expect_presence "$fb" zellij sess:7 present "a pane a readable inventory lists is present"

  fb=$(make_zellij "$TMP_ROOT/zellij-pane-gone" pane-gone)
  expect_presence "$fb" zellij sess:7 absent "a readable pane inventory that omits the pane is absence"
  [ "$(confirmed_gone "$fb" zellij sess:7)" = yes ] || fail "an omitted zellij pane must be confirmed gone"

  fb=$(make_zellij "$TMP_ROOT/zellij-session-gone" session-gone)
  expect_presence "$fb" zellij sess:7 absent "a readable session list that omits the session is absence"

  for mode in sessions-fail panes-fail panes-timed-out panes-garbage; do
    fb=$(make_zellij "$TMP_ROOT/zellij-$mode" "$mode")
    expect_presence "$fb" zellij sess:7 unknown \
      "a failed or timed-out zellij read ($mode) is unknown, never absent"
    [ "$(confirmed_gone "$fb" zellij sess:7)" = no ] \
      || fail "a failed zellij read ($mode) must never confirm the endpoint gone"
  done

  fb=$(make_zellij "$TMP_ROOT/zellij-malformed" present)
  expect_presence "$fb" zellij malformed unknown "a malformed zellij target is ambiguity, never absence"
  expect_presence "$fb" zellij sess:notanumber unknown "a non-numeric zellij pane id is ambiguity, never absence"

  # With the owning task label, only a positively different tab name is evidence
  # the recorded pane was reassigned; an unreadable tab list is not.
  fb=$(make_zellij "$TMP_ROOT/zellij-label-match" present)
  expect_presence "$fb" zellij sess:7 present "a pane whose tab carries the expected label is present" fm-task

  fb=$(make_zellij "$TMP_ROOT/zellij-label-mismatch" label-mismatch)
  expect_presence "$fb" zellij sess:7 absent "a pane whose tab carries a different name is a reused id, so this endpoint is absent" fm-task

  fb=$(make_zellij "$TMP_ROOT/zellij-tabs-fail" tabs-fail)
  expect_presence "$fb" zellij sess:7 unknown "an unreadable zellij tab list is unknown, never absent" fm-task
  [ "$(confirmed_gone "$fb" zellij sess:7 fm-task)" = no ] \
    || fail "an unreadable zellij tab list must never confirm the endpoint gone"

  pass "zellij presence: only a readable inventory that omits the endpoint is absence"
}

# --- orca --------------------------------------------------------------------

make_orca() {  # <dir> <mode>
  local dir=$1 mode=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  [ "$mode" = no-cli ] && { printf '%s\n' "$fakebin"; return 0; }
  cat > "$fakebin/orca" <<SH
#!/usr/bin/env bash
set -u
case '$mode' in
  present) printf '%s\n' '{"ok":true,"result":{"terminal":{"tail":["hi"]}}}'; exit 0 ;;
  gone) printf '%s\n' '{"ok":false,"error":{"code":"terminal_not_found","message":"no such terminal"}}'; exit 0 ;;
  other-error) printf '%s\n' '{"ok":false,"error":{"code":"runtime_unavailable","message":"runtime down"}}'; exit 0 ;;
  transport) printf '%s\n' 'orca: runtime not reachable' >&2; exit 1 ;;
  timed-out) exit 124 ;;
  garbage) printf '%s\n' 'not json'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/orca"
  printf '%s\n' "$fakebin"
}

test_orca_presence() {
  local fb node_bin
  node_bin=$(command -v node 2>/dev/null) || { echo "skip - node not found (required by the orca adapter)"; return 0; }
  EXTRA_PATH=$(dirname "$node_bin")

  fb=$(make_orca "$TMP_ROOT/orca-present" present)
  expect_presence "$fb" orca term-1 present "a readable orca terminal is present"

  fb=$(make_orca "$TMP_ROOT/orca-gone" gone)
  expect_presence "$fb" orca term-1 absent "a structured not-found is positive evidence of absence"
  [ "$(confirmed_gone "$fb" orca term-1)" = yes ] || fail "an orca not-found must be confirmed gone"

  for mode in other-error transport timed-out garbage no-cli; do
    fb=$(make_orca "$TMP_ROOT/orca-$mode" "$mode")
    expect_presence "$fb" orca term-1 unknown \
      "a failed or timed-out orca read ($mode) is unknown, never absent"
    [ "$(confirmed_gone "$fb" orca term-1)" = no ] \
      || fail "a failed orca read ($mode) must never confirm the endpoint gone"
  done

  EXTRA_PATH=
  pass "orca presence: only a structured not-found is absence"
}

# --- cmux --------------------------------------------------------------------

CMUX_WS=aaaaaaaa-0000-0000-0000-000000000000
CMUX_SF=bbbbbbbb-1111-1111-1111-111111111111
CMUX_OTHER_WS=dddddddd-3333-3333-3333-333333333333

# make_cmux <dir> <mode> <title>: a fake cmux whose `workspace list` honors the
# real binary's CURRENT-WINDOW scoping - the unscoped call only ever sees
# window w1, and the task's workspace lives in w2.
make_cmux() {  # <dir> <mode> <title>
  local dir=$1 mode=$2 title=$3 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/cmux" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  version) printf 'cmux 0.64.17 (97) [abcdef1]\n'; exit 0 ;;
  ping) printf 'PONG\n'; exit 0 ;;
esac
win=
prev=
for a in "\$@"; do [ "\$prev" = --window ] && win=\$a; prev=\$a; done
if [ "\${1:-}" = list-windows ]; then
  case '$mode' in
    windows-fail) printf '%s\n' 'error: control socket closed' >&2; exit 1 ;;
    *) printf '%s\n' '[{"id":"w1","workspace_count":1},{"id":"w2","workspace_count":1}]'; exit 0 ;;
  esac
fi
if [ "\${1:-}" = workspace ] && [ "\${2:-}" = list ]; then
  case '$mode' in
    workspaces-fail) printf '%s\n' 'error: control socket closed' >&2; exit 1 ;;
  esac
  case "\$win" in
    ''|w1) printf '%s\n' '{"workspaces":[{"id":"cccccccc-2222-2222-2222-222222222222","title":"scratch"}]}' ;;
    w2)
      case '$mode' in
        workspace-gone|workspace-gone-panes-fail) printf '%s\n' '{"workspaces":[]}' ;;
        *) printf '%s\n' '{"workspaces":[{"id":"$CMUX_WS","title":"$title"}]}' ;;
      esac
      ;;
    *) printf '%s\n' '{"workspaces":[]}' ;;
  esac
  exit 0
fi
if [ "\${1:-}" = list-panes ]; then
  case '$mode' in
    panes-fail|workspace-gone-panes-fail) printf '%s\n' 'error: control socket closed' >&2; exit 1 ;;
    panes-timed-out) exit 124 ;;
    panes-garbage) printf '%s\n' 'not json'; exit 0 ;;
    surface-gone) printf '%s\n' '{"panes":[{"selected_surface_id":"eeeeeeee-4444-4444-4444-444444444444","surface_ids":["eeeeeeee-4444-4444-4444-444444444444"]}]}'; exit 0 ;;
    *) printf '%s\n' '{"panes":[{"selected_surface_id":"$CMUX_SF","surface_ids":["$CMUX_SF"]}]}' ;;
  esac
  exit 0
fi
exit 1
SH
  chmod +x "$fakebin/cmux"
  printf '%s\n' "$fakebin"
}

cmux_title() {  # <label>
  PATH="$BASE_PATH" bash -c \
    '. "$0/bin/fm-backend.sh"; fm_backend_source cmux; fm_backend_cmux_scoped_title "$1"' "$ROOT" "$1"
}

test_cmux_presence() {
  local fb title
  command -v jq >/dev/null 2>&1 || { echo "skip - jq not found (required by the cmux adapter)"; return 0; }
  title=$(cmux_title fm-task)

  fb=$(make_cmux "$TMP_ROOT/cmux-present" present "$title")
  expect_presence "$fb" cmux "$CMUX_WS:$CMUX_SF" present "a listed workspace surface is present"

  # The reproduction: the task's workspace is live in a NON-current window, and
  # its recorded ids are stale. An inventory scoped to the current window alone
  # cannot see it, so a scope-limited miss must never read as absence.
  fb=$(make_cmux "$TMP_ROOT/cmux-other-window" present "$title")
  expect_presence "$fb" cmux "$CMUX_OTHER_WS:$CMUX_SF" present \
    "a live workspace in another window must be found, not read as gone" fm-task

  fb=$(make_cmux "$TMP_ROOT/cmux-workspace-gone" workspace-gone "$title")
  expect_presence "$fb" cmux "$CMUX_OTHER_WS:$CMUX_SF" absent \
    "a complete all-window inventory that omits the workspace is absence" fm-task
  [ "$(confirmed_gone "$fb" cmux "$CMUX_OTHER_WS:$CMUX_SF" fm-task)" = yes ] \
    || fail "a workspace absent from every window must be confirmed gone"

  fb=$(make_cmux "$TMP_ROOT/cmux-surface-gone" surface-gone "$title")
  expect_presence "$fb" cmux "$CMUX_WS:$CMUX_SF" absent \
    "a readable pane list that omits the surface is absence"

  fb=$(make_cmux "$TMP_ROOT/cmux-workspace-gone-panes-fail" workspace-gone-panes-fail "$title")
  expect_presence "$fb" cmux "$CMUX_WS:$CMUX_SF" absent \
    "an unreadable pane list plus a complete inventory that omits the workspace is absence"

  # An unreadable pane list on a workspace the inventory still holds is a read
  # we could not finish, not proof the surface went away.
  for mode in panes-fail panes-timed-out panes-garbage; do
    fb=$(make_cmux "$TMP_ROOT/cmux-$mode" "$mode" "$title")
    expect_presence "$fb" cmux "$CMUX_WS:$CMUX_SF" unknown \
      "a failed or timed-out cmux pane read ($mode) is unknown, never absent"
    [ "$(confirmed_gone "$fb" cmux "$CMUX_WS:$CMUX_SF")" = no ] \
      || fail "a failed cmux pane read ($mode) must never confirm the endpoint gone"
  done

  # A stale recorded workspace id can only be resolved through the all-window
  # inventory, so an unreadable inventory must stay unknown rather than absent.
  for mode in windows-fail workspaces-fail; do
    fb=$(make_cmux "$TMP_ROOT/cmux-$mode" "$mode" "$title")
    expect_presence "$fb" cmux "$CMUX_OTHER_WS:$CMUX_SF" unknown \
      "an unreadable cmux inventory ($mode) is unknown, never absent" fm-task
    [ "$(confirmed_gone "$fb" cmux "$CMUX_OTHER_WS:$CMUX_SF" fm-task)" = no ] \
      || fail "an unreadable cmux inventory ($mode) must never confirm the endpoint gone"
  done

  fb=$(make_cmux "$TMP_ROOT/cmux-malformed" present "$title")
  expect_presence "$fb" cmux malformed unknown "a malformed cmux target is ambiguity, never absence"

  pass "cmux presence: sweeps every window, and every failed read stays unknown"
}

# --- dispatcher --------------------------------------------------------------

test_dispatcher_contract() {
  local fb out
  fb=$(fm_fakebin "$TMP_ROOT/dispatch")

  out=$(presence "$fb" nosuchbackend some-target)
  [ "$out" = unknown ] || fail "an unknown backend cannot report absence, got '$out'"
  [ "$(confirmed_gone "$fb" nosuchbackend some-target)" = no ] \
    || fail "an unknown backend must never confirm an endpoint gone"

  pass "fm_backend_target_presence: an unroutable backend is unknown, never absent"
}

test_tmux_presence
test_herdr_presence
test_zellij_presence
test_orca_presence
test_cmux_presence
test_dispatcher_contract
