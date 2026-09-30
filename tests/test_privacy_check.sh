#!/bin/bash
. "$(dirname "$0")/lib.sh"
PC="$(dirname "$0")/../scripts/privacy-check"
d=$(mktmp)
echo 'hello world' > "$d/ok.md"
assert_exit 0 "clean tree passes" -- "$PC" "$d"
printf 'gitdir: /Us''ers/example/repo/.git\n' > "$d/.git"
assert_exit 0 "worktree .git pointer is skipped" -- "$PC" "$d"
rm "$d/.git"
echo "path /Us""ers/somebody/x" > "$d/home.md"
assert_exit 1 "home path caught" -- "$PC" "$d"; rm "$d/home.md"
echo "key sk-""ant-api03-$(printf 'A%.0s' {1..24})" > "$d/k.md"
assert_exit 1 "anthropic key caught" -- "$PC" "$d"; rm "$d/k.md"
echo "token gh""p_$(printf 'A%.0s' {1..36})" > "$d/g.md"
assert_exit 1 "github token caught" -- "$PC" "$d"; rm "$d/g.md"
echo "contact me at someone""@example.org" > "$d/e.md"
assert_exit 1 "email caught" -- "$PC" "$d"; rm "$d/e.md"
# private list: patterns that must never be published live OUTSIDE the repo
p=$(mktmp); echo 'Zanzibarquux' > "$p/banned.txt"
echo 'by Zanzibarquux' > "$d/n.md"
assert_exit 1 "private-list name caught" -- env ROUTING_KIT_PRIVATE_LIST="$p/banned.txt" "$PC" "$d"
out=$(ROUTING_KIT_PRIVATE_LIST="$p/banned.txt" "$PC" "$d" 2>&1)
case "$out" in *Zanzibarquux*) fail "matched text must not be printed";; esac
rm "$d/n.md"
echo 'see /Users/<you>/x' > "$d/ph.md"
assert_exit 0 "allowlisted placeholder passes" -- "$PC" "$d"  # /Users/<you> is allowed

prepush="$(cd "$(dirname "$0")/.." && pwd -P)/.githooks/pre-push"
assert_exit 1 "pre-push refuses missing explicit private list" -- env ROUTING_KIT_PRIVATE_LIST="$d/missing-list" "$prepush"
assert_exit 1 "pre-push refuses missing default private list" -- env -u ROUTING_KIT_PRIVATE_LIST HOME="$d" "$prepush"

# Each generic category is checked with a synthetic fixture.
for pair in \
  'api-key|sk-' 'github-pat|github_pat_' 'aws-key|AKIA' \
  'private-key|-----BEGIN PRI''VATE KEY-----' 'slack-token|xoxb-'; do
  kind=${pair%%|*}; prefix=${pair#*|}
  case "$kind" in
    private-key) sample=$prefix;;
    aws-key) sample="${prefix}1234567890AB";;
    *) sample="${prefix}abcdefgh1234";;
  esac
  printf '%s\n' "$sample" > "$d/category.md"
  result=$($PC "$d/category.md" 2>&1); code=$?
  assert_eq 1 "$code" "$kind fixture refused"
  assert_contains "$result" "$kind" "$kind category reported"
done
rm "$d/category.md"

# node_modules is git-ignored and never ships; its third-party files are out of scope.
mkdir -p "$d/pkg/node_modules/dep"
echo "author someone""@example.org" > "$d/pkg/node_modules/dep/package.json"
assert_exit 0 "node_modules skipped" -- "$PC" "$d"
echo "author someone""@example.org" > "$d/pkg/index.ts"
assert_exit 1 "email beside node_modules still caught" -- "$PC" "$d"; rm "$d/pkg/index.ts"
# npm's registry deprecation notices in a lockfile are third-party text.
printf '      "deprecated": "old, contact someone''@example.org",\n' > "$d/pkg/package-lock.json"
assert_exit 0 "lockfile deprecation notice skipped" -- "$PC" "$d"
printf '      "author": "someone''@example.org",\n' > "$d/pkg/package-lock.json"
assert_exit 1 "other lockfile email still caught" -- "$PC" "$d"; rm "$d/pkg/package-lock.json"

# "allow:" lines in the private list permit exact text only.
da=$(mktmp); pa=$(mktmp)
printf 'secretowner\nallow: secretowner/public-kit\n' > "$pa/banned.txt"
printf 'install from secretowner/public-kit\n' > "$da/ok.md"
assert_exit 0 "allowed exact text passes" -- env ROUTING_KIT_PRIVATE_LIST="$pa/banned.txt" "$PC" "$da"
printf 'mail secretowner about it\n' > "$da/bad.md"
assert_exit 1 "the term elsewhere is still caught" -- env ROUTING_KIT_PRIVATE_LIST="$pa/banned.txt" "$PC" "$da"

echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
