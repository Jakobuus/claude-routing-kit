#!/bin/bash
. "$(dirname "$0")/lib.sh"
q="$(cd "$(dirname "$0")/.." && pwd)/plugins/routing-kit/bin/kit-quota"
d=$(mktmp)
printf '{"claude_plan":"pro","codex":"none","gemini":"none"}\n' > "$d/profile.json"
python3 - "$d/usage.db" <<'PY'
import sqlite3, sys
c=sqlite3.connect(sys.argv[1])
c.execute('CREATE TABLE limit_samples (sampled_epoch INTEGER, bucket_id TEXT, percent REAL, resets_epoch INTEGER)')
c.executemany('INSERT INTO limit_samples VALUES (?,?,?,?)', [(1999998000,'session',25,2000007200),(1999999990,'weekly_scoped:Fable',32,2000302400)])
c.commit()
PY
j=$(ROUTING_KIT_HOME="$d" QUOTA_NOW=2000000000 QUOTA_CLAUDE_DB="$d/usage.db" "$q" --json)
assert_eq 25 "$(echo "$j" | jq -r .claude.five_hour.percent)" 'database session read'
assert_eq true "$(echo "$j" | jq -r .claude.five_hour.stale)" 'database sample stale at thirty minutes'
assert_eq 32 "$(echo "$j" | jq -r .claude.weekly_fable.percent)" 'Fable cap read'
printf '{"sampled":1999999999,"five_hour":{"used_percentage":8,"resets_at":2000007200}}' > "$d/claude-limits.json"
j=$(ROUTING_KIT_HOME="$d" QUOTA_NOW=2000000000 QUOTA_CLAUDE_DB="$d/usage.db" "$q" --json)
assert_eq 8 "$(echo "$j" | jq -r .claude.five_hour.percent)" 'newer statusline beats database'
printf '{"claude_plan":"pro","codex":"pro","gemini":"pro","jules":true}' > "$d/profile.json"
printf '#!/bin/bash\necho "10 2000007200 20 2000302400 30 2000302400 40 2000007200 50 2000302400"\n' > "$d/reader"
printf '#!/bin/bash\necho "1 8 0 3 -"\n' > "$d/jules"
printf '#!/bin/bash\necho "3 - 1weekly+2fable"\n' > "$d/claude-resets"
printf '#!/bin/bash\necho "2 -"\n' > "$d/codex-resets"
chmod +x "$d/reader" "$d/jules" "$d/claude-resets" "$d/codex-resets"
j=$(ROUTING_KIT_HOME="$d" QUOTA_NOW=2000000000 QUOTA_CODEX_CMD="$d/reader" QUOTA_GEMINI_CMD="$d/reader" QUOTA_JULES_CMD="$d/jules" QUOTA_CODEX_RESETS_CMD="$d/codex-resets" QUOTA_CLAUDE_RESETS_CMD="$d/claude-resets" "$q" --json)
assert_eq 10 "$(echo "$j" | jq -r .codex.five_hour.percent)" 'Codex reader override'
assert_eq 50 "$(echo "$j" | jq -r .gemini.third_party_week.percent)" 'Gemini reader override'
assert_eq 12 "$(echo "$j" | jq -r .jules.percent)" 'Jules reader override'
assert_eq 2 "$(echo "$j" | jq -r .codex.resets.available)" 'Codex reset reader override'
assert_eq 2 "$(echo "$j" | jq -r .claude.resets.fable)" 'Claude reset reader override'
printf '{"claude_plan":"pro","codex":"none","gemini":"none","claude_usage_db":"%s"}' "$d/usage.db" > "$d/profile.json"
rm "$d/claude-limits.json"
j=$(ROUTING_KIT_HOME="$d" QUOTA_NOW=2000000000 QUOTA_STALE_SECS=3000 "$q" --json)
assert_eq false "$(echo "$j" | jq -r .claude.five_hour.stale)" 'stale threshold override and profile database'
assert_eq 25 "$(echo "$j" | jq -r .claude.five_hour.percent)" 'profile database path'
j=$(ROUTING_KIT_HOME="$d" QUOTA_NOW=2000000000 QUOTA_CLAUDE_DB="$d/missing" "$q" --json)
assert_eq null "$(echo "$j" | jq -r .claude.five_hour.percent)" 'environment database overrides profile'
[ ! -e "$d/missing" ] && pass || fail 'missing database must not be created'
# Review regressions: absent buckets must not replace database readings.
printf '{"sampled":1999999999,"five_hour":{"used_percentage":8,"resets_at":2000007200}}' > "$d/claude-limits.json"
j=$(ROUTING_KIT_HOME="$d" QUOTA_NOW=2000000000 "$q" --json)
assert_eq 32 "$(echo "$j" | jq -r .claude.weekly_fable.percent)" 'missing statusline Fable preserves database'
for threshold in abc 30m; do
  j=$(ROUTING_KIT_HOME="$d" QUOTA_NOW=2000000000 QUOTA_STALE_SECS="$threshold" "$q" --json)
  assert_eq 8 "$(echo "$j" | jq -r .claude.five_hour.percent)" 'invalid stale threshold falls back'
done
printf '#!/bin/bash\nexit 1\n' > "$d/claude-resets"
printf '#!/bin/bash\necho "0 -"\n' > "$d/codex-resets"
t=$(ROUTING_KIT_HOME="$d" QUOTA_NOW=2000000000 QUOTA_CLAUDE_RESETS_CMD="$d/claude-resets" QUOTA_CODEX_RESETS_CMD="$d/codex-resets" "$q")
assert_eq 'Claude 5h 8% (pace 13%) · wk – (incl. Fable wk 32% (pace 64%))' "$t" 'empty reset text does not leak JSON'
# Isolated regression probes also accept an extracted pre-fix executable.
python3 - "$q" <<'PYREG'
import json, os, pathlib, sqlite3, subprocess, sys, tempfile, time
q = os.environ.get('QUOTA_TEST_COMMAND', sys.argv[1])
failures = 0
with tempfile.TemporaryDirectory() as root:
    home = pathlib.Path(root)
    (home/'profile.json').write_text(json.dumps(dict(claude_plan='pro', codex='none', gemini='none')))
    db = home/'usage.db'
    c = sqlite3.connect(str(db))
    c.execute('CREATE TABLE limit_samples (sampled_epoch INTEGER, bucket_id TEXT, percent REAL, resets_epoch INTEGER)')
    def rows(age=100, fage=100):
        c.execute('DELETE FROM limit_samples')
        c.executemany('INSERT INTO limit_samples VALUES (?,?,?,?)', [(2000000000-age,'session',25,2000007200),(2000000000-age,'weekly_all',20,2000302400),(2000000000-fage,'weekly_scoped:Fable',32,2000302400)])
        c.commit()
    env = dict(os.environ, ROUTING_KIT_HOME=root, HOME=root, QUOTA_NOW='2000000000', QUOTA_CLAUDE_DB=str(db), QUOTA_STALE_SECS='1800')
    def run(text=False, **extra):
        return subprocess.run([q]+([] if text else ['--json']), env=dict(env, **extra), stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, timeout=15)
    def check(name, ok, detail):
        global failures
        print(('PASS: ' if ok else 'FAIL: ')+name+('' if ok else ' '+repr(detail)))
        if not ok: failures += 1
    rows(fage=3000)
    r=run(); j=json.loads(r.stdout)
    check('finding 3 stale Fable keeps Claude fresh', j['claude']['stale'] is False and j['claude']['weekly_fable']['stale'] is True, r.stdout)
    rows()
    env.pop('QUOTA_CLAUDE_DB')
    (home/'profile.json').write_text(json.dumps(dict(claude_plan='pro',codex='none',gemini='none',claude_usage_db='~/usage.db')))
    r=run(); check('finding 4 expands profile tilde', json.loads(r.stdout)['claude']['five_hour']['percent']==25, r.stdout)
    env['QUOTA_CLAUDE_DB']=str(db)
    c.execute('BEGIN EXCLUSIVE')
    start=time.monotonic(); r=run(); elapsed=time.monotonic()-start
    c.rollback()
    check('finding 5 locked DB returns within three seconds', elapsed<3 and r.returncode==0 and json.loads(r.stdout)['claude']['five_hour']['percent'] is None, (elapsed,r.stdout))
    (home/'claude-limits.json').write_text('['*200000+']'*200000)
    r=run(); check('finding 7 deeply nested JSON falls back to DB', r.returncode==0 and bool(r.stdout.strip()) and json.loads(r.stdout)['claude']['five_hour']['percent']==25, (r.stdout,r.stderr))
    (home/'claude-limits.json').unlink()
    reader=home/'resets'; reader.write_text('#!/bin/bash\necho "1 1796950000 1weekly"\n'); reader.chmod(0o755)
    r=run(True, TZ='PST8PDT', QUOTA_CLAUDE_RESETS_CMD=str(reader))
    check('finding 8 expiry uses local date', 'next expires 10 Dec' in r.stdout, r.stdout)
    rows(age=1801, fage=1801)
    (home/'claude-limits.json').write_text(json.dumps(dict(sampled=1999998200, five_hour=dict(used_percentage=25,resets_at=2000007200), seven_day=dict(used_percentage=20,resets_at=2000302400))))
    r=run(True)
    expected='Claude 5h 25% (pace 42%) · wk 20% (pace 40%) (incl. Fable wk 32% (pace 64%) (stale))\n'
    check('finding 9 whole segment at 1800 and 1801 seconds', r.stdout==expected, r.stdout)
print('Regression probes: PASS %d / FAIL %d' % (6-failures,failures))
sys.exit(bool(failures))
PYREG
[ "$?" -eq 0 ] && pass || fail 'review regression probes'
echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
