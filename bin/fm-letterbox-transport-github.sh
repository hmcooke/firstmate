#!/usr/bin/env bash
# The GitHub transport adapter for the agent-to-agent letterbox.
# THIS IS THE ONLY FILE IN THE LETTERBOX THAT KNOWS ABOUT GITHUB. A second
# transport implements the same verbs and nothing else in the letterbox changes.
#
# Usage: fm-letterbox-transport-github.sh <verb> [args]
#   require-private                    exit 0 only when the channel repository is
#                                      still private; otherwise print one reason
#                                      line and exit 2 when the repository is
#                                      confirmed NOT private, or exit 1 when its
#                                      visibility could not be read (gh-axi)
#   list-open                          print a JSON array of open letters:
#                                      [{number,title,body,author,updated}] (gh)
#   comments <number>                  print a JSON array of replies on one
#                                      letter: [{id,body,author,created}] (gh)
#   find-title <title>                 print "<number> <url>" for the most recent
#                                      issue whose title matches exactly, or
#                                      nothing when there is none (gh)
#   create --title <t> --body-file <f> [--label <l>]
#                                      create one letter; print "<number> <url>" (gh-axi)
#   comment <number> --body-file <f>   post one reply; print the comment URL (gh-axi)
#   close <number>                     close one letter (gh-axi)
#
# Every write verb exits 2 when its own visibility gate finds the repository
# NOT private and 3 when that gate could not read the visibility at all, so the
# caller can record the refusal under its class (visibility or transport)
# without re-deriving it from prose. Any other failure exits 1.
#
# The channel repository is FM_LETTERBOX_REPO, revalidated here rather than
# trusted, so a doctored setting cannot redirect a write at another repository.
# Authentication is firstmate's existing GitHub credential; this adapter
# introduces no new credential and needs no new authority.
#
# TWO CLIs, and the split is deliberate. Writes and the visibility precondition
# go through gh-axi, firstmate's standard GitHub tool. The three machine reads
# go through gh, because gh-axi renders an agent-display format rather than
# JSON: an array of objects comes back as a lossy comma-separated table, and a
# multi-line value comes back wrapped in an "api_response:/body:/truncated:"
# envelope with the newlines escaped. Neither can carry a letter body safely.
# This is the same tool and the same reason as bin/fm-pr-poll.sh, which is the
# watcher's other authenticated poll and already reads GitHub state through gh.
# Both CLIs are existing firstmate dependencies (bin/fm-bootstrap.sh's
# COMMON_TOOLS), so nothing new is required of a home.
#
# THE VISIBILITY PRECONDITION. Every write verb runs require-private first and
# refuses the write if the repository is not private. That converts "the channel
# repository was accidentally made public" from a silent ongoing exposure into a
# hard stop on the next write. It is one API call and it is not optional.
#
# list-open and comments are PAGINATED; find-title deliberately is not, because a
# retry looks for an issue created moments earlier and one page bounds that read.
# The watcher's per-check timeout bounds a paginated read on a pathological repo.
#
# The GitHub search API is NEVER used: its measured limit is 30 requests/minute
# against core's 5,000/hour, so it would be the first thing to break under
# polling. find-title reads the most recent 100 issues in one call instead,
# which is what an idempotent create retry needs and no more.
set -u
LC_ALL=C
export LC_ALL

die() {
  printf '%s\n' "$1" >&2
  exit 1
}

REPO=${FM_LETTERBOX_REPO:-}
case "$REPO" in
  */*/*|/*|*/|'') die "letterbox transport: FM_LETTERBOX_REPO is not owner/name" ;;
  */*) : ;;
  *) die "letterbox transport: FM_LETTERBOX_REPO is not owner/name" ;;
esac
case "${REPO%%/*}" in ''|*[!A-Za-z0-9._-]*) die "letterbox transport: bad repository owner" ;; esac
case "${REPO#*/}" in ''|*[!A-Za-z0-9._-]*) die "letterbox transport: bad repository name" ;; esac

command -v gh-axi >/dev/null 2>&1 || die "letterbox transport: gh-axi is not installed"
command -v gh >/dev/null 2>&1 || die "letterbox transport: gh is not installed"
command -v jq >/dev/null 2>&1 || die "letterbox transport: jq is not installed"

require_private() {
  local out
  out=$(gh-axi api "repos/$REPO" --jq '.private' 2>/dev/null) || {
    printf 'cannot read %s visibility\n' "$REPO"
    return 1
  }
  case "$out" in
    true) return 0 ;;
    false) printf '%s is not private\n' "$REPO"; return 2 ;;
    *) printf 'cannot read %s visibility\n' "$REPO"; return 1 ;;
  esac
}

paginated_json() {
  local path=$1 query=$2 tmp rc
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-letterbox-github.XXXXXX") || return 1
  if gh api --paginate "$path" --jq "$query" 2>/dev/null > "$tmp"; then
    jq -s '.' "$tmp" 2>/dev/null
    rc=$?
  else
    rc=$?
  fi
  rm -f -- "$tmp"
  return "$rc"
}

find_title_number() {
  local title=$1 tmp rc
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-letterbox-github.XXXXXX") || return 1
  if gh api "repos/$REPO/issues?state=all&sort=created&direction=desc&per_page=100" \
    --jq '[.[] | select(has("pull_request") | not) | {number, title}]' \
    2>/dev/null > "$tmp"; then
    jq -r --arg t "$title" '[.[] | select(.title == $t) | .number] | first // empty' \
      "$tmp" 2>/dev/null
    rc=$?
  else
    rc=$?
  fi
  rm -f -- "$tmp"
  return "$rc"
}

# A write refused for visibility must never be retried past the refusal, so
# every write verb funnels through this one gate. Its exit status carries the
# class: the caller checked visibility moments earlier, and a repository that
# flipped between that check and this one must still land as a durable
# visibility refusal rather than a generic failure.
gate_write() {
  local reason rc
  reason=$(require_private); rc=$?
  [ "$rc" -ne 0 ] || return 0
  printf '%s\n' "letterbox transport: refusing to write, $reason" >&2
  case "$rc" in
    2) exit 2 ;;
    *) exit 3 ;;
  esac
}

# A flag that takes a value must have one; otherwise "$2" is empty, "shift 2"
# fails without terminating the script, and the parser loops forever.
need_value() {
  [ "$#" -ge 2 ] || die "letterbox transport: $1 needs a value"
}

VERB=${1-}
shift 2>/dev/null || true

case "$VERB" in
  require-private)
    require_private
    ;;

  list-open)
    # One call. Pull requests can never appear in the channel repository, but
    # they are filtered anyway so a shared repository cannot inject one.
    # PAGINATED. The open-issue set is the poll's whole outstanding-obligation
    # view and the stale backstop's input, so an unrecorded 100-item cap would
    # silently drop letters out of both. --jq emits one object per line per page
    # and jq -s reassembles the pages into the single array the caller expects.
    paginated_json "repos/$REPO/issues?state=open&per_page=100" \
      '.[] | select(has("pull_request") | not)
       | {number, title, body: (.body // ""), author: (.user.login // ""), updated: (.updated_at // "")}' \
      || exit 1
    ;;

  comments)
    NUMBER=${1-}
    case "$NUMBER" in ''|*[!0-9]*) die "letterbox transport: bad issue number" ;; esac
    # PAGINATED for the same reason: a terminal reply on page two would never be
    # seen, while the cursor would still advance past the issue's updated_at and
    # suppress the refetch. Comments stay in oldest-first order across pages,
    # which is what "first terminal reply wins" depends on.
    paginated_json "repos/$REPO/issues/$NUMBER/comments?per_page=100" \
      '.[] | {id: (.id | tostring), body: (.body // ""), author: (.user.login // ""), created: (.created_at // "")}' \
      || exit 1
    ;;

  find-title)
    TITLE=${1-}
    [ -n "$TITLE" ] || die "letterbox transport: find-title needs a title"
    NUMBER=$(find_title_number "$TITLE") || exit 1
    case "$NUMBER" in
      ''|*[!0-9]*) exit 0 ;;
    esac
    printf '%s https://github.com/%s/issues/%s\n' "$NUMBER" "$REPO" "$NUMBER"
    ;;

  create)
    TITLE=; BODY_FILE=; LABEL=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --title) need_value "$@"; TITLE=$2; shift 2 ;;
        --body-file) need_value "$@"; BODY_FILE=$2; shift 2 ;;
        --label) need_value "$@"; LABEL=$2; shift 2 ;;
        *) die "letterbox transport: unknown create flag $1" ;;
      esac
    done
    [ -n "$TITLE" ] || die "letterbox transport: create needs --title"
    [ -f "$BODY_FILE" ] && [ ! -L "$BODY_FILE" ] || die "letterbox transport: create needs a readable --body-file"
    gate_write
    set -- issue create -R "$REPO" --title "$TITLE" --body-file "$BODY_FILE"
    [ -z "$LABEL" ] || set -- "$@" --label "$LABEL"
    OUT=$(gh-axi "$@" 2>&1) || {
      printf '%s\n' "letterbox transport: create failed: $OUT" >&2
      exit 1
    }
    URL=$(printf '%s\n' "$OUT" | grep -oE 'https://[A-Za-z0-9._/-]+/issues/[0-9]+' | tail -n1)
    if [ -n "$URL" ]; then
      printf '%s %s\n' "${URL##*/}" "$URL"
      exit 0
    fi
    # The letter did land; only its URL was not printed in a shape this adapter
    # recognises. Resolve the number the same way a retry would, by exact title,
    # rather than reporting a failure that would cause a duplicate letter.
    NUMBER=$(find_title_number "$TITLE") || NUMBER=
    case "$NUMBER" in
      ''|*[!0-9]*)
        printf '%s\n' "letterbox transport: create returned no issue URL and the letter could not be found by title" >&2
        exit 1
        ;;
    esac
    printf '%s https://github.com/%s/issues/%s\n' "$NUMBER" "$REPO" "$NUMBER"
    ;;

  comment)
    NUMBER=${1-}
    case "$NUMBER" in ''|*[!0-9]*) die "letterbox transport: bad issue number" ;; esac
    shift
    BODY_FILE=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --body-file) need_value "$@"; BODY_FILE=$2; shift 2 ;;
        *) die "letterbox transport: unknown comment flag $1" ;;
      esac
    done
    [ -f "$BODY_FILE" ] && [ ! -L "$BODY_FILE" ] || die "letterbox transport: comment needs a readable --body-file"
    gate_write
    OUT=$(gh-axi issue comment "$NUMBER" -R "$REPO" --body-file "$BODY_FILE" 2>&1) || {
      printf '%s\n' "letterbox transport: comment failed: $OUT" >&2
      exit 1
    }
    # The URL is informational; the reply landed either way, so a CLI that does
    # not print one is not a failure.
    printf '%s\n' "$OUT" | grep -oE 'https://[A-Za-z0-9._#/-]+' | tail -n1 || true
    ;;

  close)
    NUMBER=${1-}
    case "$NUMBER" in ''|*[!0-9]*) die "letterbox transport: bad issue number" ;; esac
    gate_write
    gh-axi issue close "$NUMBER" -R "$REPO" --reason completed >/dev/null 2>&1 \
      || die "letterbox transport: close failed"
    ;;

  *)
    die "letterbox transport: unknown verb ${VERB:-<none>}"
    ;;
esac
