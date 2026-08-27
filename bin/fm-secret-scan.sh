#!/usr/bin/env bash
# Credential-refusal scanner for the agent-to-agent letterbox.
# Usage: fm-secret-scan.sh <file>
#        fm-secret-scan.sh --stdin
#
# Exit contract, and it is the whole interface:
#   0  clean       - the caller may proceed
#   1  refused     - the caller MUST NOT proceed; one line naming the detection
#                    class is printed to stdout, and never the matched value
#   2  usage error - unreadable input or bad arguments; the caller must treat
#                    this as a refusal too, because nothing was scanned
#
# It REFUSES; it never redacts. A redacted secret is still a secret that reached
# the pipeline, so the only safe outcome is that the content is not sent, not
# stashed and not logged. Callers run it BEFORE the transport call, BEFORE the
# local outbox write on the send path, and BEFORE the inbox stash on the receive
# path, because a server-side rejection would already be too late.
#
# HONESTY, and this belongs here rather than being discovered later:
#   - This is DEFENCE IN DEPTH, NOT A BOUNDARY. It reduces the chance that a
#     credential crosses the channel by accident. It is not a control that may
#     be relied on to stop a determined or unlucky leak, and no other safety
#     property in the letterbox design is allowed to rest on it.
#   - It will NOT catch a secret that has been split across lines, encoded,
#     compressed, or otherwise transformed. That limit is measured rather than
#     assumed: control N7 of the letterbox measurement plan (docs/letterbox.md)
#     exercises exactly that case and records the result as a stated limit.
#
# Detection classes, each with a named negative control in the test suite:
#   provider-key-prefix   ghp_ / gho_ / ghs_ / ghu_ / ghr_ / github_pat_ /
#                         sk- / xoxb- / xoxp- / xoxa- / AKIA prefixes
#   private-key-header    a PEM "BEGIN ... PRIVATE KEY" header
#   telegram-bot-token    <digits>:<35 base64url characters>
#   env-assignment        NAME=VALUE where NAME contains TOKEN, SECRET, KEY,
#                         PASSWORD or SESSION and VALUE is >=8 unbroken chars
#   high-entropy          a >=32-character hex run, or a >=40-character
#                         base64url run carrying both cases and a digit
#   vault-note-name       the literal vault note name hermes-archie-env
#
# Known and accepted false positive: a bare 40-character git object id is a
# >=32-character hex run and is refused as high-entropy. Cards refer to commits
# by short id or by role, which is the same discipline the grammar already
# applies to file paths.
set -u
LC_ALL=C
export LC_ALL

usage() {
  echo "usage: fm-secret-scan.sh <file> | fm-secret-scan.sh --stdin" >&2
  exit 2
}

[ "$#" -eq 1 ] || usage

TMP=
trap '[ -z "$TMP" ] || rm -f -- "$TMP"' EXIT HUP INT TERM

case "$1" in
  --stdin)
    TMP=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-secret-scan.XXXXXX") || exit 2
    cat > "$TMP" || exit 2
    TARGET=$TMP
    ;;
  -*)
    usage
    ;;
  *)
    TARGET=$1
    [ -f "$TARGET" ] && [ ! -L "$TARGET" ] && [ -r "$TARGET" ] || {
      echo "error: unreadable scan target" >&2
      exit 2
    }
    ;;
esac

# Each check prints only its class name. The matched text never leaves this
# script, so a refusal can be logged, echoed into a status line, or shown to the
# captain without re-leaking what it found.
refuse() {
  printf 'refused: %s\n' "$1"
  exit 1
}

# grep -q keeps the match out of stdout even under set -x tracing of the caller.
# -e guards a pattern that begins with a dash; -- guards the target path.
match() {
  grep -qE -e "$1" -- "$TARGET" 2>/dev/null
}

match '(^|[^A-Za-z0-9_])(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})' \
  && refuse provider-key-prefix
match '(^|[^A-Za-z0-9_])sk-[A-Za-z0-9_-]{20,}' && refuse provider-key-prefix
match '(^|[^A-Za-z0-9_])xox[baprs]-[A-Za-z0-9-]{10,}' && refuse provider-key-prefix
match '(^|[^A-Za-z0-9_])AKIA[0-9A-Z]{16}([^0-9A-Z]|$)' && refuse provider-key-prefix

match '-----BEGIN( [A-Z0-9]+)* PRIVATE KEY-----' && refuse private-key-header

match '(^|[^A-Za-z0-9_])[0-9]{6,12}:[A-Za-z0-9_-]{35}([^A-Za-z0-9_-]|$)' \
  && refuse telegram-bot-token

# An assignment, not the word in prose: the name must carry a credential noun and
# the value must be at least eight unbroken characters immediately after "=".
# "a token = the build phase name" has spaces and a short value, so it passes.
match '(^|[^A-Za-z0-9_])[A-Za-z0-9_]*(TOKEN|SECRET|KEY|PASSWORD|SESSION|token|secret|key|password|session)[A-Za-z0-9_]*=[^[:space:]]{8,}' \
  && refuse env-assignment

match 'hermes-archie-env' && refuse vault-note-name

# High-entropy runs are the catch-all for a credential with no recognised
# prefix. Two shapes qualify: a long hex run (which is what most opaque ids and
# hashes look like), and a long base64url run that mixes both cases with digits.
# The conjunction is done in the shell rather than in awk, because interval
# expressions like {40,} are not portable across every awk this can run on,
# while grep -E supports them on both GNU and BSD.
match '[A-Fa-f0-9]{32,}' && refuse high-entropy

while IFS= read -r token; do
  [ -n "$token" ] || continue
  case "$token" in *[a-z]*) ;; *) continue ;; esac
  case "$token" in *[A-Z]*) ;; *) continue ;; esac
  case "$token" in *[0-9]*) ;; *) continue ;; esac
  refuse high-entropy
done < <(grep -oE -e '[A-Za-z0-9_+/=-]{40,}' -- "$TARGET" 2>/dev/null || true)

exit 0
