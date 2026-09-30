#!/bin/bash
. "$(dirname "$0")/lib.sh"
PC="$(dirname "$0")/../scripts/privacy-check"

# Decision: token patterns match at a word boundary (start of line or a
# non-alphanumeric char before), and require a suffix of at least 8 chars
# of [A-Za-z0-9_-] after sk-, ghp_, github_pat_, xoxb-/xoxp-, and at least
# 12 of [A-Z0-9] after AKIA.
#
# The fixture tokens below are written as adjacent-quote concatenations
# (e.g. "sk-""abc123456") so the full token never appears as a contiguous
# run of characters in THIS source file — otherwise privacy-check would
# flag its own test fixtures.
d=$(mktmp)

echo "key sk-""abc123456" > "$d/1.md"
assert_exit 1 "sk- with 9-char suffix caught" -- "$PC" "$d"
rm "$d/1.md"

echo "token github_pat_""abcdefgh12" > "$d/2.md"
assert_exit 1 "github_pat_ with 10-char suffix caught" -- "$PC" "$d"
rm "$d/2.md"

echo "key AKIA""1234567890AB" > "$d/3.md"
assert_exit 1 "AKIA with 12-char suffix caught" -- "$PC" "$d"
rm "$d/3.md"

echo 'call ask-advisers now' > "$d/4.md"
assert_exit 0 "ask-advisers passes" -- "$PC" "$d"
rm "$d/4.md"

echo 'see task-brief for details' > "$d/5.md"
assert_exit 0 "task-brief passes" -- "$PC" "$d"
rm "$d/5.md"

echo 'this plan is risk-free' > "$d/6.md"
assert_exit 0 "risk-free passes" -- "$PC" "$d"
rm "$d/6.md"

echo 'put it on the desk-top' > "$d/7.md"
assert_exit 0 "desk-top passes" -- "$PC" "$d"
rm "$d/7.md"

echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
