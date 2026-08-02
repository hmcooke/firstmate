#!/usr/bin/env bash
# tests/fm-composer-lib.test.sh - the shared composer-content classifier
# (bin/fm-composer-lib.sh), the ONE fleet-wide owner every backend adapter
# delegates its empty|pending|unknown verdict to.
#
# The load-bearing contract, task fm-composer-shellglyph-safety:
#   1. A BARE shell prompt glyph (`>`/`$`/`%`/`#`) on an unstructured row is a
#      dead shell, NOT an empty agent composer - it must read `unknown`
#      (unsafe-for-injection), never `empty`. This is the safety fix.
#   2. The SAME shell glyph INSIDE a bordered composer box is the harness's own
#      prompt and still reads `empty` (existing behavior preserved).
#   3. The AGENT prompt glyphs `❯` (claude) and `›` (codex) are a genuine empty
#      agent composer either way, bordered or bare.
#   4. Real unsubmitted text reads `pending`; a known idle placeholder reads
#      `empty`.
#   5. A Unicode blank a harness renders in an otherwise-empty composer must not
#      make it read as typed text (task fm-afk-wedge-investigate), and folding
#      those blanks must not make a blank-only row with no prompt glyph
#      injectable.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

# classify <bordered> <content> [idle_re] -> echoes the verdict.
classify() { fm_composer_classify_content "$@"; }

# --- Safety fix: bare shell prompt is NOT an empty agent composer -----------

test_bare_shell_glyphs_are_unknown() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 0 "$g")
    [ "$out" = unknown ] \
      || fail "bare shell glyph '$g' must read unknown (dead shell, unsafe), got '$out'"
  done
  pass "fm_composer_classify_content: a bare shell prompt glyph (>/\$/%/#) reads unknown, never empty"
}

test_stripped_unbordered_content_uses_plain_content() {
  local plain out
  for plain in '$' 'user@host $'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = unknown ] \
      || fail "stripped unbordered content '$plain' must retain its unknown safety verdict, got '$out'"
  done
  for plain in '❯' '›'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = empty ] \
      || fail "a stripped agent glyph '$plain' must remain empty, got '$out'"
  done
  pass "fm_composer_classify_content: stripped unbordered content is unknown except verified agent glyphs"
}

test_bare_shell_prompt_with_command_is_not_empty() {
  local out
  # A dead shell showing a typed command must not read empty either.
  out=$(classify 0 '$ ls -la')
  [ "$out" != empty ] || fail "a bare shell prompt with a command must not read empty, got '$out'"
  pass "fm_composer_classify_content: a bare shell prompt carrying a command is not empty"
}

# --- Preserved: shell glyph inside a composer box is the harness prompt ------

test_bordered_shell_glyph_is_empty() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 1 "$g")
    [ "$out" = empty ] \
      || fail "a shell glyph '$g' inside a bordered composer box must read empty, got '$out'"
  done
  pass "fm_composer_classify_content: a bare prompt glyph inside a bordered composer box reads empty (claude's own idle composer)"
}

# --- Agent glyphs are empty either way --------------------------------------

test_agent_glyphs_are_empty_bordered_and_bare() {
  local out
  out=$(classify 0 '❯'); [ "$out" = empty ] || fail "bare claude '❯' should read empty, got '$out'"
  out=$(classify 0 '›'); [ "$out" = empty ] || fail "bare codex '›' should read empty, got '$out'"
  out=$(classify 1 '❯'); [ "$out" = empty ] || fail "bordered claude '❯' should read empty, got '$out'"
  out=$(classify 1 '›'); [ "$out" = empty ] || fail "bordered codex '›' should read empty, got '$out'"
  pass "fm_composer_classify_content: agent prompt glyphs (❯ claude, › codex) read empty bordered or bare"
}

# --- Empty content and idle placeholder -------------------------------------

test_empty_content_is_empty() {
  local out
  out=$(classify 0 ''); [ "$out" = empty ] || fail "empty bare content should read empty, got '$out'"
  out=$(classify 1 ''); [ "$out" = empty ] || fail "empty bordered content should read empty, got '$out'"
  pass "fm_composer_classify_content: an empty composer reads empty"
}

test_idle_placeholder_is_empty() {
  local idle='^Type a message\.\.\.$' out
  # Placeholder with no prompt glyph (grok's bordered empty composer).
  out=$(classify 1 'Type a message...' "$idle")
  [ "$out" = empty ] || fail "the grok idle placeholder should read empty, got '$out'"
  # Placeholder after an agent glyph (post-strip match).
  out=$(classify 0 '❯ Type a message...' "$idle")
  [ "$out" = empty ] || fail "the idle placeholder after a glyph should read empty, got '$out'"
  # Without the idle regex it is just text -> pending.
  out=$(classify 1 'Type a message...')
  [ "$out" = pending ] || fail "without an idle regex the placeholder text is pending, got '$out'"
  pass "fm_composer_classify_content: a known idle placeholder reads empty, before and after glyph stripping"
}

test_idle_placeholder_case_mode_is_explicit() {
  local idle='^Type a message\.\.\.$' out
  out=$(classify 1 'type a message...' "$idle")
  [ "$out" = pending ] || fail "a case-variant idle placeholder should remain pending by default, got '$out'"
  out=$(classify 1 'type a message...' "$idle" insensitive)
  [ "$out" = empty ] || fail "an explicitly insensitive idle placeholder should read empty, got '$out'"
  pass "fm_composer_classify_content: idle matching preserves the caller's case mode"
}

# --- Real text is pending ---------------------------------------------------

test_real_text_is_pending() {
  local out
  out=$(classify 0 '❯ fix findings 1 and 3'); [ "$out" = pending ] || fail "bare '❯ <text>' should be pending, got '$out'"
  out=$(classify 1 '> deploy staging now'); [ "$out" = pending ] || fail "bordered '> <text>' should be pending, got '$out'"
  # A slash-command popup argument-hint placeholder is still unsubmitted text.
  out=$(classify 1 '/compact compaction instructions'); [ "$out" = pending ] || fail "a popup placeholder fill should be pending, got '$out'"
  pass "fm_composer_classify_content: real unsubmitted text reads pending (including a popup argument-hint fill)"
}

# --- Unicode blanks in an otherwise-empty composer --------------------------
#
# Regression, task fm-afk-wedge-investigate. Claude Code draws its idle prompt
# prefix as `❯` + U+00A0 NO-BREAK SPACE. The callers' [![:space:]] trims cover
# ASCII whitespace only, so the NBSP reached this classifier attached to the
# glyph, matched none of the glyph cases, and a genuinely empty composer read
# `pending` - which permanently deferred away-mode escalation delivery, because
# the injector proceeds only on an affirmative `empty`.
#
# The blanks are built from octal escapes rather than pasted literals so the
# captured byte sequences stay visible here and no editor or copy step can
# silently normalize them back into ASCII spaces, which would quietly retire the
# regression these tests exist to hold. bin/fm-composer-lib.sh owns why the
# escapes are octal rather than the backslash-u form.
FM_TEST_NBSP=$(printf '\302\240')       # U+00A0 NO-BREAK SPACE
FM_TEST_FIGURE_SPACE=$(printf '\342\200\207')   # U+2007
FM_TEST_NARROW_NBSP=$(printf '\342\200\257')    # U+202F
FM_TEST_ZWNBSP=$(printf '\357\273\277')         # U+FEFF

test_idle_claude_composer_with_nbsp_is_empty() {
  local out
  # The exact row captured from an idle claude pane: `❯` + U+00A0.
  out=$(classify 0 "❯$FM_TEST_NBSP")
  [ "$out" = empty ] \
    || fail "an idle claude composer ('❯' + NBSP) must read empty, got '$out'"
  out=$(classify 1 "❯$FM_TEST_NBSP")
  [ "$out" = empty ] \
    || fail "a bordered idle claude composer ('❯' + NBSP) must read empty, got '$out'"
  pass "fm_composer_classify_content: an idle claude composer ('❯' + U+00A0) reads empty, bordered or bare"
}

test_other_unicode_blanks_after_a_glyph_are_empty() {
  local blank out
  for blank in "$FM_TEST_FIGURE_SPACE" "$FM_TEST_NARROW_NBSP" "$FM_TEST_ZWNBSP"; do
    out=$(classify 0 "❯$blank")
    [ "$out" = empty ] \
      || fail "an agent glyph followed only by a Unicode blank must read empty, got '$out'"
  done
  pass "fm_composer_classify_content: U+2007/U+202F/U+FEFF after an agent glyph read empty"
}

test_real_text_after_a_unicode_blank_is_pending() {
  local out
  # The load-bearing disconfirming case: folding the blank must not swallow the
  # text behind it, or the injector would type over unsubmitted human input.
  out=$(classify 0 "❯${FM_TEST_NBSP}rm -rf /")
  [ "$out" = pending ] \
    || fail "real typed text after an NBSP must still read pending, got '$out'"
  out=$(classify 1 "❯${FM_TEST_NBSP}deploy staging now")
  [ "$out" = pending ] \
    || fail "bordered real text after an NBSP must still read pending, got '$out'"
  pass "fm_composer_classify_content: real typed text after a Unicode blank still reads pending"
}

test_unicode_blank_without_a_glyph_is_not_injectable() {
  local blank out
  # <plain_content> is deliberately left un-normalized, so a blank-only row that
  # carries no prompt glyph stays the unstructured row it is. Normalising it too
  # would turn this into `empty` and widen the injectable surface.
  for blank in "$FM_TEST_NBSP" "$FM_TEST_FIGURE_SPACE" "$FM_TEST_NARROW_NBSP" "$FM_TEST_ZWNBSP"; do
    out=$(classify 0 "$blank")
    [ "$out" = unknown ] \
      || fail "a Unicode-blank-only row with no prompt glyph must not become injectable, got '$out'"
  done
  pass "fm_composer_classify_content: a Unicode-blank-only row with no prompt glyph reads unknown, never empty"
}

test_dead_shell_glyphs_survive_blank_normalization() {
  local g out
  # The original safety rule must be unaffected by the fold, including when the
  # dead shell's prompt is followed by a Unicode blank.
  for g in '>' '$' '%' '#'; do
    out=$(classify 0 "$g")
    [ "$out" = unknown ] || fail "bare shell glyph '$g' must still read unknown, got '$out'"
    out=$(classify 0 "$g$FM_TEST_NBSP")
    [ "$out" = unknown ] \
      || fail "bare shell glyph '$g' plus an NBSP must still read unknown, got '$out'"
  done
  pass "fm_composer_classify_content: bare shell prompt glyphs stay unknown with or without a trailing Unicode blank"
}

test_bare_shell_glyphs_are_unknown
test_stripped_unbordered_content_uses_plain_content
test_bare_shell_prompt_with_command_is_not_empty
test_bordered_shell_glyph_is_empty
test_agent_glyphs_are_empty_bordered_and_bare
test_empty_content_is_empty
test_idle_placeholder_is_empty
test_idle_placeholder_case_mode_is_explicit
test_real_text_is_pending
test_idle_claude_composer_with_nbsp_is_empty
test_other_unicode_blanks_after_a_glyph_are_empty
test_real_text_after_a_unicode_blank_is_pending
test_unicode_blank_without_a_glyph_is_not_injectable
test_dead_shell_glyphs_survive_blank_normalization
