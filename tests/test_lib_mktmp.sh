#!/bin/bash
. "$(dirname "$0")/lib.sh"
LIBSH="$(cd "$(dirname "$0")" && pwd -P)/lib.sh"

# Regression: if `mktemp -d` fails, mktmp must fail loudly and must never
# queue a cleanup path that isn't the freshly created temp dir. Previously,
# a failed `mktemp -d` left mktmp's local `d` empty, `cd "" && pwd -P`
# silently resolved to the caller's cwd, and that cwd got queued for
# `rm -rf` when the process exited.
work=$(mktmp)
sentinel="$work/sentinel"
touch "$sentinel"

fakebin=$(mktmp)
cat > "$fakebin/mktemp" <<'EOF'
#!/bin/bash
for a in "$@"; do
  case "$a" in
    -d) exit 1 ;;
  esac
done
exec /usr/bin/mktemp "$@"
EOF
chmod +x "$fakebin/mktemp"

outfile="$work/out"
( cd "$work" && PATH="$fakebin:$PATH" bash -c '. "'"$LIBSH"'"; mktmp' ) >"$outfile" 2>/dev/null
code=$?

assert_eq 1 "$code" "mktmp exits non-zero when mktemp -d fails"
out=$(cat "$outfile" 2>/dev/null)
assert_eq "" "$out" "mktmp prints nothing on stdout when mktemp -d fails"
if [ -f "$sentinel" ]; then
  pass
else
  fail "cwd sentinel was deleted: cleanup ran rm -rf on the working directory"
fi

echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
