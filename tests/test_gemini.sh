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
assert_contains "$rows" "Gemini $(routed_model gemini build)" 'Gemini build row'
assert_contains "$(printf '%s\n' "$rows" | grep '| Lookups, bulk edits, data entry |')" "Gemini $(routed_model gemini lookup)" 'Gemini lookup model in lookup row'
assert_contains "$(printf '%s\n' "$rows" | grep '| Exploration, big reads, web research |')" "Gemini $(routed_model gemini research)" 'Gemini hydrogen in research row'
assert_contains "$(printf '%s\n' "$rows" | grep '| Review |')" "Gemini $(routed_model gemini long_read)" 'Gemini may review'
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
if [ "$KIT_AGY_CASE" = capture ]; then printf '%s\n' "$@" > "$KIT_AGY_MARKER"; fi
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
assert_contains "$(cat "$capture")" '--dangerously-skip-permissions' 'Gemini receives the full-access flag'
if grep -Fxq -- '--sandbox' "$capture"; then
  fail 'sandbox flag reached Gemini'
else
  pass
fi
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
watch_run=$(printf '%s\n' "$watch_out" | sed -n 's/^kit-gemini-build: run dir: //p')
assert_no_watchdog "$watch_run/watchdog-watchdog$" 'successful build'
out=$(env ROUTING_KIT_HOME="$home" KIT_AGY_BIN="$fake" KIT_AGY_CASE=denied "$BIN" --repo "$repo" --name denied --brief "$brief" 2>&1)
assert_contains "$out" 'WARNING: agy denied actions' 'denied actions warn loudly'
assert_exit 4 'failure exits 4' -- env ROUTING_KIT_HOME="$home" KIT_AGY_BIN="$fake" KIT_AGY_CASE=failure "$BIN" --repo "$repo" --name failure --brief "$brief"
marker=$(mktmp)/child-marker
out=$(env ROUTING_KIT_HOME="$home" KIT_AGY_BIN="$fake" KIT_AGY_CASE=timeout KIT_AGY_TIMEOUT_GRACE=0 KIT_AGY_MARKER="$marker" "$BIN" --repo "$repo" --name timeout --brief "$brief" --timeout 1 2>&1)
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
# --- agy inherits exported variables except the caller's Claude session --------------
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
  CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=caller CLAUDE_CODE_TEST=caller CLAUDE_CONFIG_DIR=/x/claude KIT_ROLE=lead \
  "$BIN" --repo "$erepo" --name envscrub --brief "$brief" >"$envmark.out" 2>&1
code=$?
exec 9>&-
assert_eq 0 "$code" "build with the caller environment succeeds ($(head -c 400 "$envmark.out"))"
assert_contains "$(cat "$envmark")" "KIT_ROLE=worker" "Gemini worker role"
seen=$(cat "$envmark")
for var in DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR MY_SERVICE_TOKEN GITHUB_TOKEN GH_HOST GITHUB_ACTOR AWS_ACCESS_KEY_ID AWS_REGION SSH_AUTH_SOCK OPENAI_API_KEY SOME_SECRET ANTIGRAVITY_API_KEY UNRELATED_VAR; do
  case "$seen" in *"$var="*) pass ;; *) fail "agy did not inherit $var" ;; esac
done
for var in HOME PATH LANG LC_ALL TERM ANTIGRAVITY_HOME AGY_FLAG TMPDIR XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME; do
  case "$seen" in *"$var="*) pass ;; *) fail "agy did not get $var" ;; esac
done
for pair in AWS_ACCESS_KEY_ID=a1 SSH_AUTH_SOCK=/tmp/sock OPENAI_API_KEY=k1 UNRELATED_VAR=u1 CLAUDE_CONFIG_DIR=/x/claude; do
  assert_contains "$seen" "$pair" "agy preserves $pair"
done
for var in CLAUDECODE CLAUDE_CODE_SESSION_ID CLAUDE_CODE_TEST; do
  case "$seen" in *"$var="*) fail "agy inherited caller session $var" ;; *) pass ;; esac
done
case "$seen" in *OPENFD*) fail "agy inherited an open file descriptor: $(grep OPENFD "$envmark" | tr '\n' ' ')" ;; *) pass ;; esac

# The legacy DBus switch is consumed; desktop variables already pass through.
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

# Credential-looking input has the same access as an ordinary build.
accessrepo=$(mktmp)
git -C "$accessrepo" init -q
git -C "$accessrepo" config user.email you@example.com
git -C "$accessrepo" config user.name test
printf 'old\n' > "$accessrepo/a.txt"
key="sk-""ant-api03-$(printf 'A%.0s' {1..24})"
printf 'API_KEY=%s\n' "$key" > "$accessrepo/.env.example"
git -C "$accessrepo" add a.txt .env.example
git -C "$accessrepo" commit -qm init
accessbrief="$(mktmp)/brief.md"
printf 'edit a.txt\nkey: %s\n' "$key" > "$accessbrief"
accesshome=$(mktmp)
accessmark="$(mktmp)/argv"
env ROUTING_KIT_HOME="$accesshome" KIT_AGY_BIN="$fake" KIT_AGY_CASE=capture KIT_AGY_MARKER="$accessmark" \
  "$BIN" --repo "$accessrepo" --name access --brief "$accessbrief" >/dev/null 2>&1
assert_eq 0 "$?" 'Gemini accepts key-looking repo and brief content'
[ -s "$accessmark" ] && pass || fail 'Gemini was not started'
accessrun=$(find "$accesshome/runs" -mindepth 1 -maxdepth 1 -type d | head -1)
[ -s "$accessrun/build.patch" ] && grep -q a.txt "$accessrun/build.patch" && pass || fail 'Gemini did not save the build patch'
[ -z "$(find "$accesshome" -name 'secret-scan*.txt')" ] && pass || fail 'Gemini wrote a scan report'

# Shared staging scratch is always removed.
if [ -d "$home/scratch" ] && [ -n "$(ls -A "$home/scratch")" ]; then
  fail 'staging scratch was not removed'
else
  pass
fi


# Snapshot safety regressions:
# 1. Directory swapped for an outside symlink (10 builds).
# 2. File swapped for an outside symlink (10 builds).
# 3. Sparse apparent size exceeds the growth budget.
# 4. Many small files exceed the growth budget together.
# 5. Executable mode survives the snapshot.
for safety_case in dirswap fileswap sparse many executable; do
 repetitions=1
 case "$safety_case" in dirswap|fileswap) repetitions=10 ;; esac
 for ((iteration=1; iteration<=repetitions; iteration++)); do
  shome=$(mktmp); srepo=$(mktmp); sbindir=$(mktmp); smarks=$(mktmp)
  git -C "$srepo" init -q
  git -C "$srepo" config user.name Test
  git -C "$srepo" config user.email you@example.com
  echo old > "$srepo/base"
  git -C "$srepo" add .; git -C "$srepo" commit -qm initial
  mkdir "$smarks/outside"
  echo OUTSIDE-SECRET-MARKER > "$smarks/outside/secret"
  cat > "$sbindir/agy" <<SH
#!/bin/bash
cat >/dev/null
while [ "\$#" -gt 0 ]; do
 if [ "\$1" = -C ]; then shift; cd "\$1" || exit 1; fi
 shift
done
python3 - '$safety_case' '$smarks' <<'PYSAFE'
import os, sys, time
case, marks = sys.argv[1:]
if case in ('dirswap', 'fileswap'):
    if case == 'dirswap':
        os.mkdir('sub')
        open('sub/safe', 'w').write('safe')
        target = marks + '/outside'
    else:
        open('sub', 'w').write('safe')
        target = marks + '/outside/secret'
    if os.fork() == 0:
        end = time.monotonic() + 5
        while time.monotonic() < end:
            try:
                os.rename('sub', 'saved')
                os.symlink(target, 'sub')
                os.unlink('sub')
                os.rename('saved', 'sub')
            except OSError:
                pass
        os._exit(0)
elif case == 'sparse':
    with open('large', 'wb') as f: f.truncate(1024 * 1024 * 1024)
elif case == 'many':
    for i in range(1000):
        with open('small%d' % i, 'wb') as f: f.write(b'x' * 4096)
else:
    open('executable', 'w').write('#!/bin/sh\nexit 0\n')
    os.chmod('executable', 0o755)
PYSAFE
printf '{"status":"SUCCESS","response":"done"}\n'
SH
  chmod +x "$sbindir/agy"
  echo edit > "$smarks/brief.md"
  start=$SECONDS
  sout=$(env PATH="$sbindir:/usr/bin:/bin" ROUTING_KIT_HOME="$shome" ROUTING_KIT_MAX_GROWTH_MB=1 KIT_AGY_BIN="$sbindir/agy" "$BIN" --repo "$srepo" --name safety --brief "$smarks/brief.md" 2>&1)
  scode=$?
  spatch=$(find "$shome/runs" -name build.patch | head -1)
  case "$safety_case" in
   dirswap|fileswap)
    case "$scode" in 0|4) pass ;; *) fail "swap exit $scode" ;; esac
    case "$sout" in *Traceback*) fail 'snapshot traceback' ;; *) pass ;; esac
    if [ -n "$spatch" ] && grep -q OUTSIDE-SECRET-MARKER "$spatch"; then fail 'outside content copied'; else pass; fi ;;
   sparse|many)
    assert_eq 4 "$scode" 'size refused'
    assert_contains "$sout" 'it grew by more than 1 MB' 'growth message'
    [ $((SECONDS-start)) -lt 10 ] && pass || fail 'size refusal too slow' ;;
   executable)
    assert_eq 0 "$scode" 'executable succeeds'
    assert_contains "$(cat "$spatch")" 'new file mode 100755' 'executable mode' ;;
  esac
  [ -z "$(ls -A "$shome/scratch" 2>/dev/null)" ] && pass || fail 'scratch remains'
 done
done

# Seven shared staging regressions, exercised through the provider stub.
for staging_case in moved deep partial location success failure timeout race symlink fifo hardlink nested diff merge; do
  shome=$(mktmp); srepo=$(mktmp); sbindir=$(mktmp); smarks=$(mktmp)
  git -C "$srepo" init -q
  git -C "$srepo" config user.name Test
  git -C "$srepo" config user.email you@example.com
  printf 'old\n' > "$srepo/changed.txt"
  case "$staging_case" in
    diff|merge)
      printf '*.txt %s=x\n' "$staging_case" > "$srepo/.gitattributes"
      if [ "$staging_case" = diff ]; then key=diff.x.textconv; else key=merge.x.driver; fi
      git -C "$srepo" config "$key" "touch '$smarks/driver'; cat" ;;
  esac
  git -C "$srepo" add .; git -C "$srepo" commit -qm initial
  if [ "$staging_case" = deep ]; then
    i=1
    while [ "$i" -lt 300 ]; do
      git -C "$srepo" -c commit.gpgsign=false commit -qm history --allow-empty
      i=$((i + 1))
    done
    assert_eq 300 "$(git -C "$srepo" rev-list --count HEAD)" 'source history'
  fi
  if [ "$staging_case" = partial ]; then
    git -C "$srepo" config uploadpack.allowFilter true
    partial_repo=$(mktmp)
    git clone -q --filter=blob:none "file://$srepo" "$partial_repo"
    srepo="$partial_repo"
    assert_eq true "$(git -C "$srepo" config remote.origin.promisor)" 'source is partial clone'
  fi
  printf 'OUTSIDE-SECRET-MARKER\n' > "$smarks/outside"
  cat > "$sbindir/agy" <<SH
#!/bin/bash
cat >/dev/null
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = -C ]; then shift; cd "\$1" || exit 1; fi
  shift
done
touch '$smarks/started'
printf 'complete-version\n' > changed.txt
case '$staging_case' in
 failure) exit 1 ;;
 timeout) sleep 10 ;;
 symlink) ln -s '$smarks/outside' link ;;
 fifo) mkfifo pipe ;;
 hardlink) ln changed.txt second ;;
 nested) mkdir -p sub/.git ;;
 race)
   (end=\$(( \$(date +%s) + 5 )); while [ \$(date +%s) -lt \$end ]; do
      printf 'rewrite-version\n' > '$smarks/next'; mv '$smarks/next' changed.txt
    done) >/dev/null 2>&1 &
   echo \$! > '$smarks/pid' ;;
esac
printf '{"status":"SUCCESS","response":"done"}\n'
SH
  chmod +x "$sbindir/agy"
  build_bin="$BIN"
  if [ "$staging_case" = moved ]; then
    # kit_git deliberately ignores PATH. Instrument an isolated copy only.
    instrumented=$(mktmp)
    cp -R "$(dirname "$BIN")/.." "$instrumented/plugin"
    build_bin="$instrumented/plugin/bin/$(basename "$BIN")"
    python3 - "$instrumented/plugin/bin/kit-common" "$sbindir" <<'INSTRUMENT'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace('PATH=/usr/bin:/bin', 'PATH=' + sys.argv[2] + ':/usr/bin:/bin'))
INSTRUMENT
    real_git=$(command -v git)
    cat > "$sbindir/git" <<SH
#!/bin/bash
case "\$*" in
  *'-C $srepo rev-parse HEAD')
  if [ ! -e '$smarks/moved' ]; then
  '$real_git' "\$@"
  : > '$smarks/moved'
  '$real_git' -C '$srepo' -c commit.gpgsign=false commit --allow-empty -qm moved
  exit 0
  fi ;;
esac
exec '$real_git' "\$@"
SH
    chmod +x "$sbindir/git"
  fi
  sbrief="$smarks/brief.md"; echo edit > "$sbrief"
  # Observe scratch without entering it or changing staging's environment.
  if [ "$staging_case" = location ] || [ "$staging_case" = deep ]; then
    python3 -I - "$shome" "$smarks" <<'OBS' &
import glob, os, stat, subprocess, sys, time
home, marks = sys.argv[1:]
end = time.monotonic() + 15
while time.monotonic() < end:
    for path in glob.glob(home + '/scratch/kit-build-git.*'):
        try:
            mode = stat.S_IMODE(os.stat(path).st_mode)
        except FileNotFoundError:
            continue
        if os.path.isfile(path + '/git/.git/shallow'):
            result = subprocess.run(['/usr/bin/git', '-C', path + '/git', 'rev-list', '--count', 'HEAD'], capture_output=True, text=True)
            if result.returncode == 0:
                with open(marks + '/depth', 'w') as depth:
                    depth.write(result.stdout.strip())
        if not os.path.isfile(marks + '/depth'):
            continue
        with open(marks + '/observed', 'w') as f:
            f.write('%s %o' % (path, mode))
        sys.exit(0)
    time.sleep(.001)
OBS
    observer=$!
  fi
  sout=$(env PATH="$sbindir:/usr/bin:/bin" ROUTING_KIT_HOME="$shome" KIT_AGY_TIMEOUT_GRACE=0 KIT_AGY_BIN="$sbindir/agy" \
    "$build_bin" --repo "$srepo" --name staging --brief "$sbrief" --timeout 2 2>&1)
  scode=$?
  spatch=$(find "$shome/runs" -name build.patch | head -1)
  case "$staging_case" in
    # 1. Scratch location and private mode.
    location)
      wait "$observer"
      observed=$(cat "$smarks/observed" 2>/dev/null)
      case "$observed" in "$shome"/scratch/kit-build-git.*' 700') pass ;; *) fail "scratch location/mode: $observed" ;; esac ;;
    # 2. Cleanup after success, provider failure, and timeout.
    moved)
      assert_eq 2 "$scode" 'moved source refused'
      assert_contains "$sout" 'repo changed' 'moved source explanation'
      [ ! -e "$smarks/started" ] && pass || fail 'agent started after source moved'
      [ -z "$(find "$shome/runs" "$shome/scratch" -mindepth 1 -print 2>/dev/null)" ] && pass || fail 'moved source left artifacts' ;;
    deep)
      wait "$observer"
      assert_eq 0 "$scode" 'deep source builds'
      assert_eq 1 "$(cat "$smarks/depth" 2>/dev/null)" 'scratch has one commit'
      assert_contains "$(cat "$spatch" 2>/dev/null)" '+complete-version' 'deep source patch' ;;
    partial)
      assert_eq 0 "$scode" 'partial clone builds'
      assert_contains "$(cat "$spatch" 2>/dev/null)" '+complete-version' 'partial clone patch' ;;
    success) assert_eq 0 "$scode" 'successful staging' ;;
    failure|timeout) assert_eq 4 "$scode" "$staging_case status" ;;
    # 3. A racing writer cannot produce mixed or empty content.
    race)
      assert_eq 0 "$scode" 'racing snapshot finishes'
      added=$(sed -n '/^+++ /d; s/^+//p' "$spatch")
      case "$added" in complete-version|rewrite-version) pass ;; *) fail "inconsistent snapshot: $added" ;; esac
      kill "$(cat "$smarks/pid")" 2>/dev/null || true ;;
    # 4. Symlinks remain links and never disclose their target content.
    symlink)
      assert_eq 0 "$scode" 'symlink build'
      assert_contains "$(cat "$spatch")" '120000' 'symlink mode'
      if grep -q OUTSIDE-SECRET-MARKER "$spatch"; then fail 'symlink target disclosed'; else pass; fi ;;
    # 5. Snapshot refuses unsafe filesystem entries with the established errors.
    fifo|hardlink|nested)
      assert_eq 4 "$scode" "$staging_case refused"
      case "$staging_case" in
        fifo) reason='a FIFO, socket or device file' ;;
        hardlink) reason='a file with more than one hard link' ;;
        nested) reason='a nested git repository or submodule' ;;
      esac
      assert_contains "$sout" 'refusing to stage the build in' 'refusal prefix'
      assert_contains "$sout" "$reason" 'refusal reason'
      [ -z "$spatch" ] && pass || fail 'refusal left patch' ;;
    # 6 and 7. Source diff and merge drivers cannot execute.
    diff|merge)
      assert_eq 0 "$scode" "$staging_case driver build"
      [ ! -e "$smarks/driver" ] && pass || fail "$staging_case driver executed"
      assert_contains "$(cat "$spatch")" '-old' 'real deletion'
      assert_contains "$(cat "$spatch")" '+complete-version' 'real addition' ;;
  esac
  [ -z "$(find "$shome/scratch" -mindepth 1 -print 2>/dev/null)" ] && pass || fail "$staging_case left scratch"
done

# Sleep guard receives the build script PID, once, without changing output.
src="$erepo"
fakebin=$(mktmp)
caflog=$(mktmp)/caffeinate
cat > "$fakebin/caffeinate" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$caflog"
SH
chmod +x "$fakebin/caffeinate"
nocaf=$(mktmp)
for tool in /usr/bin/* /bin/*; do
  [ "${tool##*/}" = caffeinate ] && continue
  [ -e "$nocaf/${tool##*/}" ] || ln -s "$tool" "$nocaf/${tool##*/}"
done
for awake in yes no; do
  [ "$awake" = yes ] || rm "$fakebin/caffeinate"
  env PATH="$fakebin:$nocaf" ROUTING_KIT_HOME="$home" KIT_AGY_BIN="$fake" "$BIN" --repo "$src" --name awake --brief "$brief" >"$caflog.$awake" 2>&1 &
  build_pid=$!
  wait "$build_pid"
  assert_eq 0 "$?" "$awake caffeinate status"
  if [ "$awake" = yes ]; then
    for ((retry=0; retry<50; retry++)); do
      [ -f "$caflog" ] && break
      sleep .02
    done
    assert_eq "-is -w $build_pid" "$(cat "$caflog")" 'caffeinate arguments and script PID, exactly once'
  fi
done
# Run directories vary; compare all other output bytes.
sed "s|$home/runs/[^ /]*|RUN|g; s|kit-gemini/[^ ]*|BRANCH|" "$caflog.yes" > "$caflog.normalized"
sed "s|$home/runs/[^ /]*|RUN|g; s|kit-gemini/[^ ]*|BRANCH|" "$caflog.no" > "$caflog.other"
assert_eq "$(cat "$caflog.normalized")" "$(cat "$caflog.other")" 'sleep guard preserves output'

echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
