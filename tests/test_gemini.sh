#!/bin/bash
. "$(dirname "$0")/lib.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BIN="$ROOT/plugins/routing-kit/bin/kit-gemini-build"
KP="$ROOT/plugins/routing-kit/bin/kit-profile"
RT="$ROOT/plugins/routing-kit/bin/kit-routing-table"
QUOTA="$ROOT/plugins/routing-kit/bin/kit-quota"
repo=$(mktmp)
git -C "$repo" init -q
git -C "$repo" config user.email you@example.com
git -C "$repo" config user.name test
printf 'old\n' > "$repo/a.txt"
git -C "$repo" add a.txt
git -C "$repo" commit -qm init
brief=$(mktmp)/brief.md
printf 'edit a.txt\n' > "$brief"
home=$(mktmp)
assert_exit 0 'Gemini profile accepts Pro' -- env ROUTING_KIT_HOME="$home" "$KP" set claude_plan pro
assert_exit 0 'Gemini profile set Pro' -- env ROUTING_KIT_HOME="$home" "$KP" set gemini pro
assert_exit 0 'Gemini profile validates' -- env ROUTING_KIT_HOME="$home" "$KP" validate
assert_exit 2 'Gemini profile rejects invalid plan' -- env ROUTING_KIT_HOME="$home" "$KP" set gemini plus
rows=$(env CODEX_HOME="$home/no-codex" ROUTING_KIT_HOME="$home" "$RT")
assert_contains "$rows" 'Gemini gemini-4-argon-high' 'Gemini build row'
assert_contains "$rows" 'Gemini gemini-4-hydrogen-medium' 'Gemini bulk row'
assert_contains "$(printf '%s\n' "$rows" | grep '| Read-only lookups |')" 'Gemini gemini-4-hydrogen-low' 'Gemini hydrogen in lookup row'
assert_contains "$(printf '%s\n' "$rows" | grep '| Web research |')" 'Gemini gemini-4-hydrogen-high' 'Gemini hydrogen in research row'
assert_contains "$rows" 'Gemini work → Claude opus' 'Gemini cross-company review'
assert_contains "$rows" "Argon's weekly pool is small on Pro" 'Argon pool note'
fixture=$(mktmp)/quota.json
cat > "$fixture" <<'JSON'
{"command":{"data":{"groups":[{"buckets":[{"id":"3p-weekly","window":"weekly","remaining_fraction":0.8,"reset_time":"2099-01-01T00:00:00Z"},{"id":"gemini-argon-wtu-weekly","window":"weekly","remaining_fraction":0.7,"reset_time":"2099-01-01T00:00:00Z"},{"id":"gemini-5h","window":"5h","remaining_fraction":0.9,"reset_time":"2099-01-01T00:00:00Z"},{"id":"3p-5h","window":"5h","remaining_fraction":0.6,"reset_time":"2099-01-01T00:00:00Z"},{"id":"gemini-weekly","window":"weekly","remaining_fraction":0.5,"reset_time":"2099-01-01T00:00:00Z"}]}]}}}
JSON
fake=$(mktmp)/agy
cat > "$fake" <<'SH'
#!/bin/bash
if [ "$1" = '--output-format' ]; then cat "$KIT_AGY_FIXTURE"; exit 0; fi
[ "$KIT_AGY_CASE" = timeout ] && { (sleep 2; echo leaked > "$KIT_AGY_MARKER") & wait; exit 0; }
[ "$KIT_AGY_CASE" = failure ] && { echo failed >&2; exit 1; }
[ "$KIT_AGY_CASE" = parent ] && { printf 'bad\n' > ../build.patch; printf 'bad\n' > ../git.pristine/HEAD 2>/dev/null; }
if [ "$KIT_AGY_CASE" = tamper ]; then
  base=$(git rev-parse HEAD)
  if [ -e ../git.pristine ] || find "$TMPDIR" -type d -name 'kit-gemini-git.*' 2>/dev/null | grep -q .; then
    touch "$KIT_AGY_EARLY_GIT_MARKER"
  fi
  while IFS= read -r p; do
    mkdir -p "$p/refs/replace" "$p/info"
    printf '%s\n' "$base" > "$p/refs/replace/$base"
    git --git-dir="$p" --work-tree="$PWD" update-index --skip-worktree a.txt 2>/dev/null || true
    git config --file "$p/config" filter.x.clean "sh -c 'touch $KIT_AGY_FILTER_MARKER; cat'"
    printf '* filter=x\n' > "$p/info/attributes"
  done < <(find "$TMPDIR" "$PWD/.." -type d -name .git -o -type d -name git.pristine -o -type d -name git 2>/dev/null)
fi
if [ "$KIT_AGY_CASE" = quota_timeout ]; then
  (sleep 3; echo leaked > "$KIT_AGY_MARKER") &
  wait
fi
if [ "$KIT_AGY_CASE" = env ]; then
  env | sort > "$KIT_AGY_MARKER"
  for n in 3 4 5 6 7 8 9; do [ -e "/dev/fd/$n" ] && echo "OPENFD $n" >> "$KIT_AGY_MARKER"; done
fi
if [ "$KIT_AGY_CASE" = capture ]; then printf '%s\n' "$*" > "$KIT_AGY_MARKER"; fi
printf 'new\n' > a.txt
if [ "$KIT_AGY_CASE" = denied ]; then
  printf '{"status":"SUCCESS","response":"done","denied_actions":[{"action":"command","display_name":"Bash"}]}\n'
else
  printf '{"status":"SUCCESS","response":"done"}\n'
fi
SH
chmod +x "$fake"
json=$(env ROUTING_KIT_HOME="$home" KIT_AGY_BIN="$fake" KIT_AGY_FIXTURE="$fixture" "$QUOTA" --json)
assert_eq 10 "$(printf '%s' "$json" | jq -r '.gemini.five_hour.percent')" 'Gemini 5h bucket by ID'
assert_eq 50 "$(printf '%s' "$json" | jq -r '.gemini.week.percent')" 'Gemini weekly bucket by ID'
assert_eq 30 "$(printf '%s' "$json" | jq -r '.gemini.argon_week.percent')" 'Argon bucket by ID'
assert_eq 40 "$(printf '%s' "$json" | jq -r '.gemini.third_party_five_hour.percent')" 'third-party 5h bucket by ID'
assert_eq 20 "$(printf '%s' "$json" | jq -r '.gemini.third_party_week.percent')" 'third-party weekly bucket by ID'
fraction_fixture=$(mktmp)/quota-fraction.json
jq '(.command.data.groups[0].buckets[] | select(.id == "gemini-5h") | .reset_time) = "2099-01-01T00:00:00.123456789Z" | del(.command.data.groups[0].buckets[] | select(.id == "gemini-weekly") | .remaining_fraction)' "$fixture" > "$fraction_fixture"
fraction_home=$(mktmp)
cp "$home/profile.json" "$fraction_home/profile.json"
fraction_json=$(env ROUTING_KIT_HOME="$fraction_home" KIT_AGY_BIN="$fake" KIT_AGY_FIXTURE="$fraction_fixture" "$QUOTA" --json)
assert_eq 10 "$(printf '%s' "$fraction_json" | jq -r '.gemini.five_hour.percent')" 'nanosecond reset time parses'
assert_eq null "$(printf '%s' "$fraction_json" | jq -r '.gemini.week.percent')" 'reset without remaining fraction stays unknown'
bad_home=$(mktmp)
cp "$home/profile.json" "$bad_home/profile.json"
unknown=$(env ROUTING_KIT_HOME="$bad_home" KIT_AGY_BIN="$bad_home/no-agy" "$QUOTA" --json)
assert_eq null "$(printf '%s' "$unknown" | jq -r '.gemini.five_hour.percent')" 'missing agy keeps usage unknown'

out=$(env ROUTING_KIT_HOME="$home" KIT_AGY_BIN="$fake" "$BIN" --repo "$repo" --name gemini-test --brief "$brief" 2>&1)
code=$?
assert_eq 0 "$code" 'Gemini build succeeds'
patch=$(printf '%s\n' "$out" | tail -1 | sed 's/.*build patch: //')
assert_contains "$(cat "$patch")" '+new' 'patch contains edited file'
assert_eq old "$(cat "$repo/a.txt")" 'source branch unchanged'
assert_exit 2 '--verify is refused' -- env ROUTING_KIT_HOME="$home" KIT_AGY_BIN="$fake" "$BIN" --repo "$repo" --name no-verify --brief "$brief" --verify true
capture=$(mktmp)/args
slash=$(mktmp)/slash.md
printf '/edit a.txt\n' > "$slash"
env ROUTING_KIT_HOME="$home" KIT_AGY_BIN="$fake" KIT_AGY_CASE=capture KIT_AGY_MARKER="$capture" "$BIN" --repo "$repo" --name slash --brief "$slash" >/dev/null
assert_contains "$(cat "$capture")" '--disable-slash-commands' 'slash commands disabled'
large=$(mktmp)/large.md
head -c 102401 /dev/zero | tr '\0' x > "$large"
out=$(env ROUTING_KIT_HOME="$home" KIT_AGY_BIN="$fake" "$BIN" --repo "$repo" --name large --brief "$large" 2>&1)
assert_eq 2 "$?" 'oversize brief refused'
assert_contains "$out" '100 KB limit' 'oversize brief explained'
out=$(env ROUTING_KIT_HOME="$home" KIT_AGY_BIN="$fake" KIT_AGY_CASE=parent "$BIN" --repo "$repo" --name parent --brief "$brief" 2>&1)
assert_eq 0 "$?" 'parent-directory writes cannot alter patch'
parent_patch=$(printf '%s\n' "$out" | tail -1 | sed 's/.*build patch: //')
assert_contains "$(cat "$parent_patch")" '+new' 'parent-directory patch is genuine'
isolated=$(mktmp)
filter_marker=$(mktmp)/filter-ran
early_git_marker=$(mktmp)/early-git
out=$(env TMPDIR="$isolated" ROUTING_KIT_HOME="$home" KIT_AGY_BIN="$fake" KIT_AGY_CASE=tamper KIT_AGY_FILTER_MARKER="$filter_marker" KIT_AGY_EARLY_GIT_MARKER="$early_git_marker" "$BIN" --repo "$repo" --name tamper --brief "$brief" 2>&1)
assert_eq 0 "$?" 'git directory tampering cannot change Gemini patch'
tampered_patch=$(printf '%s\n' "$out" | tail -1 | sed 's/.*build patch: //')
assert_contains "$(cat "$tampered_patch")" '+new' 'tampered run patch contains the edit'
[ ! -e "$filter_marker" ] && pass || fail 'tampered clean filter ran'
[ ! -e "$early_git_marker" ] && pass || fail 'Gemini staging git directory existed during agy'
[ ! -d "$(dirname "$patch")/wt" ] && pass || fail 'worktree removed after success'
[ -f "$(dirname "$patch")/manifest.json" ] && pass || fail 'manifest saved'
[ -f "$(dirname "$patch")/result.md" ] && pass || fail 'result saved'
assert_no_watchdog() {
  local marker="$1" context="$2" status
  pgrep -f "$marker" >/dev/null 2>&1
  status=$?
  case "$status" in
    0) fail "$context left watchdog python running" ;;
    1) pass ;;
    *) echo "SKIP: $context watchdog process check (pgrep cannot read process list)" >&2 ;;
  esac
}
watch_out=$(env ROUTING_KIT_HOME="$home" KIT_AGY_BIN="$fake" "$BIN" --repo "$repo" --name watchdog --brief "$brief" --timeout 30)
watch_run=$(printf '%s\n' "$watch_out" | tail -2 | head -1 | sed 's/.*run dir: //')
assert_no_watchdog "$watch_run/watchdog-watchdog$" 'successful build'
out=$(env ROUTING_KIT_HOME="$home" KIT_AGY_BIN="$fake" KIT_AGY_CASE=denied "$BIN" --repo "$repo" --name denied --brief "$brief" 2>&1)
assert_contains "$out" 'WARNING: agy denied actions' 'denied actions warn loudly'
assert_exit 4 'failure exits 4' -- env ROUTING_KIT_HOME="$home" KIT_AGY_BIN="$fake" KIT_AGY_CASE=failure "$BIN" --repo "$repo" --name failure --brief "$brief"
marker=$(mktmp)/child-marker
out=$(env ROUTING_KIT_HOME="$home" KIT_AGY_BIN="$fake" KIT_AGY_CASE=timeout KIT_AGY_MARKER="$marker" "$BIN" --repo "$repo" --name timeout --brief "$brief" --timeout 1 2>&1)
code=$?
assert_eq 4 "$code" 'timeout exits 4'
assert_contains "$out" 'timed out' 'timeout reported'
timeout_run=$(find "$home/runs" -maxdepth 1 -type d -name '*-timeout-*' | head -1)
assert_no_watchdog "$timeout_run/watchdog-timeout$" 'timeout'
sleep 3
[ ! -f "$marker" ] && pass || fail 'timeout killed agy child process'
quota_home=$(mktmp)
cp "$home/profile.json" "$quota_home/profile.json"
quota_marker=$(mktmp)/quota-child
start=$(date +%s)
quota_out=$(env ROUTING_KIT_HOME="$quota_home" KIT_AGY_BIN="$fake" KIT_AGY_CASE=quota_timeout KIT_AGY_MARKER="$quota_marker" KIT_AGY_QUOTA_TIMEOUT=1 "$QUOTA" --json)
elapsed=$(( $(date +%s) - start ))
assert_eq null "$(printf '%s' "$quota_out" | jq -r '.gemini.five_hour.percent')" 'timed-out quota unknown'
(( elapsed < 3 )) && pass || fail 'quota fetch exceeded timeout'
sleep 3
[ ! -f "$quota_marker" ] && pass || fail 'quota timeout killed agy child'
printf 'dirty\n' >> "$repo/a.txt"
assert_exit 2 'dirty repo refused' -- env ROUTING_KIT_HOME="$home" KIT_AGY_BIN="$fake" "$BIN" --repo "$repo" --name dirty --brief "$brief"
# --- release review: agy starts with an allowlisted environment --------------
envmark=$(mktmp)/env.txt
erepo=$(mktmp)
git -C "$erepo" init -q; git -C "$erepo" config user.email you@example.com; git -C "$erepo" config user.name test
printf 'old\n' > "$erepo/a.txt"; git -C "$erepo" add a.txt; git -C "$erepo" commit -qm init
fdfile=$(mktmp)/fd9
exec 9>"$fdfile"
env ROUTING_KIT_HOME="$home" KIT_AGY_BIN="$fake" KIT_AGY_CASE=env KIT_AGY_MARKER="$envmark" \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1/bus XDG_RUNTIME_DIR=/run/user/1 XDG_CONFIG_HOME=/x/cfg \
  XDG_DATA_HOME=/x/data XDG_CACHE_HOME=/x/cache XDG_STATE_HOME=/x/state \
  TMPDIR="${TMPDIR:-/tmp}" LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 TERM=xterm-256color ANTIGRAVITY_HOME=/x/agy AGY_FLAG=1 \
  MY_SERVICE_TOKEN=t0k GITHUB_TOKEN=gh1 GH_HOST=h GITHUB_ACTOR=a AWS_ACCESS_KEY_ID=a1 AWS_REGION=r \
  SSH_AUTH_SOCK=/tmp/sock OPENAI_API_KEY=k1 SOME_SECRET=s1 ANTIGRAVITY_API_KEY=agykey UNRELATED_VAR=u1 \
  "$BIN" --repo "$erepo" --name envscrub --brief "$brief" >"$envmark.out" 2>&1
code=$?
exec 9>&-
assert_eq 0 "$code" "build with a scrubbed environment succeeds ($(head -c 400 "$envmark.out"))"
seen=$(cat "$envmark")
for var in DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR MY_SERVICE_TOKEN GITHUB_TOKEN GH_HOST GITHUB_ACTOR AWS_ACCESS_KEY_ID AWS_REGION SSH_AUTH_SOCK OPENAI_API_KEY SOME_SECRET ANTIGRAVITY_API_KEY UNRELATED_VAR; do
  case "$seen" in *"$var="*) fail "agy inherited $var" ;; *) pass ;; esac
done
for var in HOME PATH LANG LC_ALL TERM ANTIGRAVITY_HOME AGY_FLAG TMPDIR XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME; do
  case "$seen" in *"$var="*) pass ;; *) fail "agy did not get $var" ;; esac
done
case "$seen" in *OPENFD*) fail "agy inherited an open file descriptor: $(grep OPENFD "$envmark" | tr '\n' ' ')" ;; *) pass ;; esac

# The session bus and runtime dir (and with them the desktop keyring) go to agy only on request.
dmark=$(mktmp)/env.txt
env ROUTING_KIT_HOME="$home" KIT_AGY_BIN="$fake" KIT_AGY_CASE=env KIT_AGY_MARKER="$dmark" KIT_AGY_ALLOW_DBUS=1 \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1/bus XDG_RUNTIME_DIR=/run/user/1 \
  "$BIN" --repo "$erepo" --name envdbus --brief "$brief" >/dev/null 2>&1
dseen=$(cat "$dmark" 2>/dev/null)
for var in DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR; do
  case "$dseen" in *"$var="*) pass ;; *) fail "$var not forwarded with KIT_AGY_ALLOW_DBUS=1" ;; esac
done
case "$dseen" in *KIT_AGY_ALLOW_DBUS*) fail "the opt-in variable itself was forwarded" ;; *) pass ;; esac
case "$seen" in *KIT_AGY_ALLOW_DBUS*) fail "the opt-in variable leaked without being set" ;; *) pass ;; esac

echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
