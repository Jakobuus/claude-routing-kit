#!/bin/bash
# tests/test_board_dm.sh -- board presence and direct messages (task 4.3a, tests first).
#
# Covers `kit-board who|send|sent` (lib/board_dm.py) and the hook check
# hooks/checks/messages.py. Neither exists yet: every case here fails until a
# correct build lands.
#
# Contract these tests pin down (beyond the shared Phase 4 contract in the plan):
#   kit-board who             one line per live session (presence last_seen within 3 h)
#                             on stdout; each line contains the session name.
#   kit-board send NAME TEXT  posts a kind "dm" record (from = my name, to = NAME,
#                             text = TEXT) and prints one stdout line "<board id> <status>".
#                             status: waiting (target last_seen < 60 s; hook delivers),
#                             queued (handed to paseo, or to codex with --resume),
#                             never "seen" at send time. Unknown NAME: exit 3, stderr
#                             says "no such session", nothing posted, nothing called.
#   kit-board sent            one line per dm I sent, containing the dm id and its
#                             current status (waiting | queued | seen).
#   Paseo call:  paseo send --no-wait <paseo_id> --prompt "<text> ... <board id>"
#   Codex call:  codex queue --thread <codex_thread> --message "<text...>" --resume
#   messages.py  run as `kit_python3 hooks/checks/messages.py` with one common event JSON
#                on stdin; name from KIT_BOARD_NAME. For unread dms to this session it
#                prints {"action":"context","text":"Message from <from>: <text> (board
#                id <id>)"} and posts a kind "seen" record (ref = dm id). Refreshes
#                presence last_seen on every call; SessionStart registers presence.
#   KIT_BOARD_TRACE=FILE      the code appends one line "open board.jsonl" to FILE each
#                time it opens the board file. Tests count these lines instead of
#                timing anything (python start-up alone is 10-30 ms).
# Stubs: tests/fixtures/board-dm/bin/{ok,noeffect}/{paseo,codex} log their argv to
# $STUB_LOG ("--CALL name--", one argument per line, "--END--"). "ok" prints success;
# "noeffect" exits 0 having done nothing (the failure mode codex 0.166 has).

. "$(dirname "$0")/lib.sh"
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
BOARD="$ROOT/plugins/routing-kit/bin/kit-board"
HOOK="$ROOT/plugins/routing-kit/hooks/checks/messages.py"
# NAMED_HOOK runs the same check but takes the session name from KIT_BOARD_NAME (the real hook ignores it).
NAMED_HOOK="$ROOT/tests/fixtures/board-dm/named_hook.py"
STUBS="$ROOT/tests/fixtures/board-dm/bin"
. "$ROOT/plugins/routing-kit/bin/kit-common"

export HOME=$(mktmp)
export KIT_BOARD_FAMILY=claude
unset KIT_BOARD_TRACE
REPO=$(mktmp)

reset() {
  export ROUTING_KIT_HOME=$(mktmp)
  export STUB_LOG="$ROUTING_KIT_HOME/stub.log"
  : > "$STUB_LOG"
}
check() { if "$@"; then pass; else fail "$*"; fi; }

# as NAME ARGS... -- run kit-board as session NAME, stubs from $STUB_DIR on PATH.
STUB_DIR="$STUBS/ok"
as() {
  local name="$1"; shift
  (cd "$REPO" && PATH="$STUB_DIR:$PATH" KIT_BOARD_NAME="$name" "$BOARD" "$@")
}

# presence NAME FAMILY AGE_SECONDS PASEO_ID CODEX_THREAD -- write a presence file
# (empty string = null) with last_seen = now - AGE_SECONDS.
presence() {
  python3 - "$ROUTING_KIT_HOME/board/presence" "$REPO" "$@" <<'PY'
import datetime, json, os, sys
d, repo, name, family, age, paseo, thread = sys.argv[1:8]
os.makedirs(d, exist_ok=True)
now = datetime.datetime.now(datetime.timezone.utc)
iso = lambda s: (now - datetime.timedelta(seconds=s)).strftime('%Y-%m-%dT%H:%M:%SZ')
with open(os.path.join(d, name + '.json'), 'w') as f:
    json.dump(dict(name=name, family=family, model=None, repo=repo, started=iso(int(age) + 3600),
                   last_seen=iso(int(age)), paseo_id=paseo or None, codex_thread=thread or None), f)
PY
}

# hook NAME EVENT [CWD] -- feed one common event JSON to messages.py as session NAME.
hook() {
  local name="$1" event="$2" cwd="${3:-$REPO}"
  printf '{"agent":"claude","event":"%s","session_id":"sid-%s","cwd":"%s","prompt":"hello","first_in_turn":true,"stop_hook_active":false,"tool":{}}' \
    "$event" "$name" "$cwd" |
    (cd "$REPO" && KIT_BOARD_NAME="$name" kit_python3 "$NAMED_HOOK")
}

# board_has EXPR -- eval is safe here: EXPR is a literal written in this file, never input.
board_has() { # PYTHON-EXPRESSION over `rows` (list of dicts); exit 0 if true
  python3 - "$ROUTING_KIT_HOME/board/board.jsonl" "$1" <<'PY'
import json, os, sys
p, expr = sys.argv[1:3]
rows = [json.loads(l) for l in open(p)] if os.path.exists(p) else []
sys.exit(0 if eval(expr, {'rows': rows}) else 1)
PY
}

# dm_id -- id of the single dm record on the board (empty if none).
dm_id() {
  python3 - "$ROUTING_KIT_HOME/board/board.jsonl" <<'PY'
import json, os, sys
p = sys.argv[1]
rows = [json.loads(l) for l in open(p)] if os.path.exists(p) else []
ids = [r['id'] for r in rows if r['kind'] == 'dm']
print(ids[0] if len(ids) == 1 else '')
PY
}

# calls -- print the stub log as a JSON list of [name, [args...]].
stub_calls() {
  python3 - "$STUB_LOG" <<'PY'
import json, sys
calls, cur = [], None
for line in open(sys.argv[1]).read().split('\n'):
    if line.startswith('--CALL ') and line.endswith('--'):
        cur = [line[7:-2], []]
    elif line == '--END--' and cur is not None:
        calls.append(cur); cur = None
    elif cur is not None:
        cur[1].append(line)
print(json.dumps(calls))
PY
}

# sent_line NAME ID -- the `sent` line for dm ID, as seen by session NAME.
sent_line() { as "$1" sent 2>/dev/null | grep -F -- "$2" | head -1; }

# ---------------------------------------------------------------- case 1: who
reset
presence fresh claude 30 "" ""
presence twohours claude 7200 "" ""
presence fourhours claude 14400 "" ""
out=$(as A who 2>&1); code=$?
assert_eq 0 "$code" 'case 1 who: exit 0'
assert_contains "$out" 'fresh' 'case 1 who: lists a session seen 30 s ago'
assert_contains "$out" 'twohours' 'case 1 who: lists a session seen 2 h ago (inside the 3 h window)'
case "$out" in *fourhours*) fail 'case 1 who: listed a session last seen 4 h ago' ;; *) pass ;; esac

# --------------------------------------------- case 2: busy target -> waiting
reset
STUB_DIR="$STUBS/ok"
presence busy claude 5 "pas-1" ""
out=$(as A send busy 'are you there' 2>&1); code=$?
assert_eq 0 "$code" 'case 2 busy: send exits 0'
assert_contains "$out" 'waiting' 'case 2 busy: status is waiting'
check test "$(stub_calls)" = '[]'
id=$(dm_id)
check test -n "$id"
check board_has "any(r['kind']=='dm' and r['from']=='A' and r['to']=='busy' and r['text']=='are you there' for r in rows)"
line=$(sent_line A "$id")
assert_contains "$line" 'waiting' 'case 2 busy: sent shows waiting'
check board_has "not any(r['kind']=='seen' for r in rows)"

# ------------------------------------------------- case 3: paseo stub -> queued
reset
STUB_DIR="$STUBS/ok"
presence pas claude 600 "pas-77" ""
out=$(as A send pas 'please review PR 12' 2>&1); code=$?
assert_eq 0 "$code" 'case 3 paseo: send exits 0'
assert_contains "$out" 'queued' 'case 3 paseo: status is queued'
id=$(dm_id)
check test -n "$id"
check python3 - "$(stub_calls)" "$id" <<'PY'
import json, sys
calls, bid = json.loads(sys.argv[1]), sys.argv[2]
assert len(calls) == 1, calls
name, argv = calls[0]
assert name == 'paseo', name
assert argv[:4] == ['send', '--no-wait', 'pas-77', '--prompt'], argv
assert len(argv) == 5, argv
assert 'please review PR 12' in argv[4] and bid in argv[4], argv[4]
PY
line=$(sent_line A "$id")
assert_contains "$line" 'queued' 'case 3 paseo: sent shows queued'
case "$line" in *seen*) fail 'case 3 paseo: sent claims seen' ;; *) pass ;; esac

# --------------------------------- case 4: codex stub -> queued with --resume
reset
STUB_DIR="$STUBS/ok"
presence cdx codex 600 "" "thr-42"
out=$(as A send cdx 'rebase onto main' 2>&1); code=$?
assert_eq 0 "$code" 'case 4 codex: send exits 0'
assert_contains "$out" 'queued' 'case 4 codex: status is queued'
id=$(dm_id)
check test -n "$id"
check python3 - "$(stub_calls)" <<'PY'
import json, sys
calls = json.loads(sys.argv[1])
assert len(calls) == 1, calls
name, argv = calls[0]
assert name == 'codex', name
assert argv[0] == 'queue', argv
assert '--resume' in argv, argv
assert argv[argv.index('--thread') + 1] == 'thr-42', argv
assert 'rebase onto main' in argv[argv.index('--message') + 1], argv
PY
line=$(sent_line A "$id")
assert_contains "$line" 'queued' 'case 4 codex: sent shows queued'

# -------------------- case 5: stubs that exit 0 without effect stay queued
for kind in paseo codex; do
  reset
  STUB_DIR="$STUBS/noeffect"
  if [ "$kind" = paseo ]; then presence quiet claude 600 "pas-5" ""; else presence quiet codex 600 "" "thr-5"; fi
  out=$(as A send quiet 'did you get this' 2>&1); code=$?
  assert_eq 0 "$code" "case 5 no-effect $kind: send exits 0"
  assert_contains "$out" 'queued' "case 5 no-effect $kind: status is queued"
  check python3 - "$(stub_calls)" "$kind" <<'PY'
import json, sys
calls = json.loads(sys.argv[1])
assert len(calls) == 1 and calls[0][0] == sys.argv[2], calls
PY
  id=$(dm_id)
  check test -n "$id"
  line=$(sent_line A "$id")
  assert_contains "$line" 'queued' "case 5 no-effect $kind: sent shows queued"
  case "$line$out" in *seen*) fail "case 5 no-effect $kind: claimed seen" ;; *) pass ;; esac
  check board_has "not any(r['kind']=='seen' for r in rows)"
done

# --------------------------------------------------- case 6: unknown -> exit 3
reset
STUB_DIR="$STUBS/ok"
presence real claude 600 "pas-9" ""
out=$(as A send nobody 'hello?' 2>&1 >/dev/null); code=$?
assert_eq 3 "$code" 'case 6 unknown: exit 3'
assert_contains "$out" 'no such session' 'case 6 unknown: stderr says no such session'
check board_has "not any(r['kind']=='dm' for r in rows)"
check test "$(stub_calls)" = '[]'

# ------------- case 7: hook delivers an unread dm as context and posts seen
reset
STUB_DIR="$STUBS/ok"
presence B claude 5 "" ""
as A send B 'ship it after lunch' >/dev/null 2>&1
id=$(dm_id)
check test -n "$id"
assert_contains "$(sent_line A "$id")" 'waiting' 'case 7 deliver: sent shows waiting before the hook runs'
out=$(hook B UserPromptSubmit); code=$?
assert_eq 0 "$code" 'case 7 deliver: hook exits 0'
check python3 - "$out" "$id" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert d['action'] == 'context', d
assert 'Message from A: ship it after lunch (board id %s)' % sys.argv[2] in d['text'], d['text']
PY
check board_has "any(r['kind']=='seen' and r['from']=='B' and r['ref']=='$id' for r in rows)"
line=$(sent_line A "$id")
assert_contains "$line" 'seen' 'case 7 deliver: sent shows seen after the hook ran'
case "$line" in *waiting*|*queued*) fail 'case 7 deliver: sent still shows an old status' ;; *) pass ;; esac
out=$(hook B UserPromptSubmit); code=$?
assert_eq 0 "$code" 'case 7 deliver: second hook call exits 0'
case "$out" in *'ship it after lunch'*) fail 'case 7 deliver: dm delivered twice' ;; *) pass ;; esac

# -------- case 8: unchanged board -> prints nothing and opens no board file
reset
STUB_DIR="$STUBS/ok"
presence B claude 5 "" ""
as A post 'first note' >/dev/null 2>&1
export KIT_BOARD_TRACE="$ROUTING_KIT_HOME/trace-1"; : > "$KIT_BOARD_TRACE"
hook B UserPromptSubmit >/dev/null 2>&1; assert_eq 0 "$?" 'case 8 unchanged: first call exits 0'
# Age last_seen so a silent no-op cannot pass: the check must still refresh it.
presence B claude 3000 "" ""
export KIT_BOARD_TRACE="$ROUTING_KIT_HOME/trace-2"; : > "$KIT_BOARD_TRACE"
out=$(hook B UserPromptSubmit); code=$?
assert_eq 0 "$code" 'case 8 unchanged: second call exits 0'
assert_eq '' "$out" 'case 8 unchanged: prints nothing'
assert_eq 0 "$(grep -c '^open board.jsonl$' "$KIT_BOARD_TRACE")" 'case 8 unchanged: opened the board file'
check python3 - "$ROUTING_KIT_HOME/board/presence/B.json" <<'PY'
import datetime, json, sys
t = json.load(open(sys.argv[1]))['last_seen']
age = datetime.datetime.now(datetime.timezone.utc) - datetime.datetime.fromisoformat(t.replace('Z', '+00:00'))
assert age.total_seconds() < 60, age
PY
# Control: a changed board must be read (proves the trace line can fire).
as A post --to B --kind dm 'second note' >/dev/null 2>&1
export KIT_BOARD_TRACE="$ROUTING_KIT_HOME/trace-3"; : > "$KIT_BOARD_TRACE"
out=$(hook B UserPromptSubmit); code=$?
assert_eq 0 "$code" 'case 8 control: call after a change exits 0'
check test "$(grep -c '^open board.jsonl$' "$KIT_BOARD_TRACE")" -ge 1
assert_contains "$out" 'second note' 'case 8 control: new dm delivered'
unset KIT_BOARD_TRACE

# ---------- case 9: SessionStart registers presence, later calls refresh it
reset
STUB_DIR="$STUBS/ok"
check test ! -e "$ROUTING_KIT_HOME/board/presence/B.json"
hook B SessionStart "$REPO" >/dev/null 2>&1; assert_eq 0 "$?" 'case 9 presence: SessionStart exits 0'
check python3 - "$ROUTING_KIT_HOME/board/presence/B.json" "$REPO" <<'PY'
import datetime, json, sys
p = json.load(open(sys.argv[1]))
assert set(p) == {'name', 'family', 'model', 'repo', 'started', 'last_seen', 'paseo_id', 'codex_thread'}, sorted(p)
assert p['name'] == 'B' and p['family'] == 'claude' and p['repo'] == sys.argv[2], p
for k in ('started', 'last_seen'):
    datetime.datetime.fromisoformat(p[k].replace('Z', '+00:00'))
PY
assert_contains "$(as A who 2>&1)" 'B' 'case 9 presence: who lists the registered session'
started=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['started'])" "$ROUTING_KIT_HOME/board/presence/B.json" 2>/dev/null)
python3 - "$ROUTING_KIT_HOME/board/presence/B.json" <<'PY'
import datetime, json, sys
p = json.load(open(sys.argv[1]))
p['last_seen'] = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%SZ')
json.dump(p, open(sys.argv[1], 'w'))
PY
hook B UserPromptSubmit >/dev/null 2>&1; assert_eq 0 "$?" 'case 9 presence: later call exits 0'
check python3 - "$ROUTING_KIT_HOME/board/presence/B.json" "$started" <<'PY'
import datetime, json, sys
p = json.load(open(sys.argv[1]))
age = datetime.datetime.now(datetime.timezone.utc) - datetime.datetime.fromisoformat(p['last_seen'].replace('Z', '+00:00'))
assert age.total_seconds() < 60, p['last_seen']
assert p['started'] == sys.argv[2] and sys.argv[2], (p['started'], sys.argv[2])
PY

# ======================================================================
# Rework (4.3c): cases 10-22 answer the Opus review of 4.3b, one per finding.
# ======================================================================
# mkevent AGENT EVENT SESSION CWD PROMPT SUBAGENT(0|1) -- one common event JSON.
mkevent() {
  python3 - "$@" <<'PY'
import json, sys
agent, event, sid, cwd, prompt, sub = sys.argv[1:7]
print(json.dumps(dict(agent=agent, event=event, session_id=sid, cwd=cwd, prompt=prompt,
                      first_in_turn=True, stop_hook_active=False, subagent=sub == '1', tool={})))
PY
}
# hookx NAME EVENT PROMPT [CWD] [SUBAGENT] -- like hook, with the prompt and subagent flag chosen.
hookx() {
  mkevent claude "$2" "sid-$1" "${4:-$REPO}" "$3" "${5:-0}" | (cd "$REPO" && KIT_BOARD_NAME="$1" kit_python3 "$NAMED_HOOK")
}
# hook_anon AGENT SESSION [EVENT] -- no KIT_BOARD_NAME: the name comes from the event's session id.
hook_anon() {
  mkevent "$1" "${3:-SessionStart}" "$2" "$REPO" "" 0 | (cd "$REPO" && unset KIT_BOARD_NAME && kit_python3 "$HOOK")
}
# anon_name FAMILY SESSION -- the name the contract derives: <family>-<first 4 hex of sha1(session)>.
anon_name() { python3 -c 'import hashlib,sys; print(sys.argv[1] + "-" + hashlib.sha1(sys.argv[2].encode()).hexdigest()[:4])' "$1" "$2"; }
# seen_count -- number of seen records on the board.
seen_count() { python3 -c "import json,sys; print(sum(1 for l in open(sys.argv[1]) if json.loads(l)['kind']=='seen'))" "$ROUTING_KIT_HOME/board/board.jsonl"; }

# --- case 10 (finding 1): a subagent's call never takes the lead's dm
reset
presence B claude 5 "" ""
as A send B 'lead only' >/dev/null 2>&1
out=$(hookx B PostToolUse "" "$REPO" 1)
assert_eq '' "$out" 'case 10 subagent: prints nothing'
check board_has "not any(r['kind']=='seen' for r in rows)"
check test ! -e "$ROUTING_KIT_HOME/board/hook-cursors/B.json"
assert_contains "$(hookx B PostToolUse "" "$REPO" 0)" 'lead only' 'case 10 subagent: the lead still gets the dm afterwards'

# --- case 11 (finding 2): the hook has its own cursor and never moves the read cursor
reset
presence B claude 5 "" ""
hookx B SessionStart "" >/dev/null 2>&1
as A post --to B --kind question 'can you take PR 7?' >/dev/null 2>&1
as A post --kind done 'merged PR 6' >/dev/null 2>&1
out=$(hookx B PostToolUse ""); assert_eq '' "$out" 'case 11 cursors: question and done are not hook messages'
check test ! -e "$ROUTING_KIT_HOME/board/cursors/B.json"
check test -e "$ROUTING_KIT_HOME/board/hook-cursors/B.json"
out=$(as B read 2>&1)
assert_contains "$out" 'can you take PR 7?' 'case 11 cursors: read still shows the question'
assert_contains "$out" 'merged PR 6' 'case 11 cursors: read still shows the done post'

# --- case 12 (findings 3 and 4a): three hook runs at once deliver a dm once and post one seen
bad=0
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  reset
  presence B claude 5 "" ""
  as A send B "race $i" >/dev/null 2>&1
  for k in 1 2 3; do hookx B PostToolUse "" > "$ROUTING_KIT_HOME/out$k" 2>/dev/null & done
  wait
  shown=$(cat "$ROUTING_KIT_HOME"/out[123] | grep -c "race $i")
  [ "$shown" = 1 ] && [ "$(seen_count)" = 1 ] || bad=$((bad + 1))
done
assert_eq 0 "$bad" 'case 12 race: trials where the dm was shown or marked seen more than once'

# --- case 13 (finding 4): one malformed row neither blocks delivery nor swallows a dm
reset
presence B claude 5 "" ""
as A send B 'good one' >/dev/null 2>&1
id=$(dm_id)
python3 - "$ROUTING_KIT_HOME/board/board.jsonl" "$REPO" <<'PY'
import datetime, json, sys
row = dict(id='b-badbadbadbad', time=datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.999999Z'),
           **{'from': 'bad name'}, family='claude', to='B', repo=sys.argv[2], kind='dm', ref=None, text='bad row', owner_quote=False)
open(sys.argv[1], 'a').write(json.dumps(row) + '\n')
PY
out=$(hookx B PostToolUse ""); code=$?
assert_eq 0 "$code" 'case 13 bad row: hook exits 0'
assert_contains "$out" 'good one' 'case 13 bad row: the good dm is shown'
case "$out" in *'bad row'*) fail 'case 13 bad row: the malformed row was shown' ;; *) pass ;; esac
assert_contains "$(sent_line A "$id")" 'seen' 'case 13 bad row: the shown dm is seen'
as A send B 'later one' >/dev/null 2>&1
assert_contains "$(hookx B PostToolUse "")" 'later one' 'case 13 bad row: later dms still arrive'

# --- case 14 (finding 5): Gemini (agy) sessions get presence and messages; unknown agents do not crash
reset
gname=$(anon_name gemini agy-session)
hook_anon agy agy-session PreInvocation >/dev/null 2>&1; assert_eq 0 "$?" 'case 14 agy: hook exits 0'
check python3 - "$ROUTING_KIT_HOME/board/presence/$gname.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
assert p['family'] == 'gemini', p
PY
as A send "$gname" 'for gemini' >/dev/null 2>&1
assert_contains "$(hook_anon agy agy-session PreInvocation)" 'for gemini' 'case 14 agy: the dm is delivered'
out=$(hook_anon martian x-session 2>&1); assert_eq 0 "$?" 'case 14 agy: unknown agent exits 0'
assert_eq '' "$out" 'case 14 agy: unknown agent prints nothing'

# --- case 15 (finding 6): Paseo's own variable PASEO_AGENT_ID fills paseo_id
reset
STUB_DIR="$STUBS/ok"
(export PASEO_AGENT_ID=pas-real; hookx B SessionStart "" >/dev/null 2>&1)
(export PASEO_SESSION_ID=not-the-name; hookx C SessionStart "" >/dev/null 2>&1)
check python3 - "$ROUTING_KIT_HOME/board/presence" <<'PY'
import json, sys
d = sys.argv[1]
assert json.load(open(d + '/B.json'))['paseo_id'] == 'pas-real'
assert json.load(open(d + '/C.json'))['paseo_id'] is None
PY
python3 - "$ROUTING_KIT_HOME/board/presence/B.json" <<'PY'
import datetime, json, sys
p = json.load(open(sys.argv[1]))
p['last_seen'] = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=600)).strftime('%Y-%m-%dT%H:%M:%SZ')
json.dump(p, open(sys.argv[1], 'w'))
PY
out=$(as A send B 'wake up' 2>&1)
assert_contains "$out" 'queued' 'case 15 paseo id: an idle session registered by the hook is queued'
check python3 - "$(stub_calls)" <<'PY'
import json, sys
calls = json.loads(sys.argv[1])
assert len(calls) == 1 and calls[0][1][2] == 'pas-real', calls
PY

# --- case 16 (finding 7): a session inside a repo gets that repo's notes (prefix match, not string prefix)
reset
mkdir -p "$REPO/sub"
presence B claude 5 "" ""
hookx B SessionStart "" "$REPO/sub" >/dev/null 2>&1
as A post 'all hands: freeze main' >/dev/null 2>&1
as A post --to "repo:$REPO" 'repo note' >/dev/null 2>&1
as A post --repo "${REPO}x" 'other repo note' >/dev/null 2>&1
out=$(hookx B PostToolUse "" "$REPO/sub")
assert_contains "$out" 'all hands: freeze main' 'case 16 repo: broadcast reaches a session in a subfolder'
assert_contains "$out" 'repo note' 'case 16 repo: repo note reaches a session in a subfolder'
case "$out" in *'other repo note'*) fail 'case 16 repo: a repo whose path only starts the same leaked in' ;; *) pass ;; esac

# --- case 17 (finding 8): a dm whose id is in the prompt is marked seen, not shown again
reset
STUB_DIR="$STUBS/ok"
presence P claude 600 "pas-1" ""
as A send P 'please rebase' >/dev/null 2>&1
id=$(dm_id)
out=$(hookx P UserPromptSubmit "please rebase (board id $id)")
assert_eq '' "$out" 'case 17 handed prompt: the dm is not shown a second time'
assert_contains "$(sent_line A "$id")" 'seen' 'case 17 handed prompt: sent shows seen'

# --- case 18 (finding 9): a session's own posts never come back to it
reset
presence B claude 5 "" ""
hookx B SessionStart "" >/dev/null 2>&1
as B post 'I am on the parser' >/dev/null 2>&1
out=$(hookx B PostToolUse ""); assert_eq '' "$out" 'case 18 own post: not returned to its author'
as C post 'C here' >/dev/null 2>&1
assert_contains "$(hookx B PostToolUse "")" 'C here' 'case 18 own post: control, another session note arrives'

# --- case 19 (finding 10): a new session's first call skips history and delivers only waiting dms
reset
presence NEW claude 5 "" ""
for i in 1 2 3 4 5; do as A post "old note $i" >/dev/null 2>&1; done
as A send NEW 'still waiting' >/dev/null 2>&1
out=$(hookx NEW SessionStart "")
assert_contains "$out" 'still waiting' 'case 19 first call: the unseen dm arrives'
case "$out" in *'old note'*) fail 'case 19 first call: history flooded in' ;; *) pass ;; esac
as A post 'fresh note' >/dev/null 2>&1
assert_contains "$(hookx NEW PostToolUse "")" 'fresh note' 'case 19 first call: later notes arrive'

# --- case 20 (finding 11): a failing or missing paseo/codex makes the dm failed, never queued
reset
FAILDIR=$(mktmp)
printf '#!/bin/bash\necho "agent not found" >&2\nexit 1\n' > "$FAILDIR/paseo"; chmod +x "$FAILDIR/paseo"
STUB_DIR="$FAILDIR"
presence gone claude 600 "pas-x" ""
out=$(as A send gone 'hi there' 2>&1); code=$?
assert_eq 0 "$code" 'case 20 failed: send exits 0'
assert_contains "$out" 'failed' 'case 20 failed: status is failed'
id=$(dm_id)
line=$(sent_line A "$id")
assert_contains "$line" 'failed' 'case 20 failed: sent shows failed'
case "$line$out" in *queued*) fail 'case 20 failed: claimed queued' ;; *) pass ;; esac
STUB_DIR="$STUBS/ok"

# --- case 21 (finding 12): reading a dm with kit-board read marks it seen
reset
presence B claude 5 "" ""
as A send B 'read me' >/dev/null 2>&1
id=$(dm_id)
as A post 'a plain note' >/dev/null 2>&1
out=$(as B read 2>&1)
assert_contains "$out" 'read me' 'case 21 read: the dm is shown'
assert_contains "$(sent_line A "$id")" 'seen' 'case 21 read: sent shows seen'
assert_eq 1 "$(seen_count)" 'case 21 read: only the dm got a seen record'

# --- case 22 (finding 13): the event's session id decides the name, not an inherited KIT_BOARD_SESSION
reset
(export KIT_BOARD_SESSION=parent; mkevent claude SessionStart child "$REPO" "" 0 |
  (cd "$REPO" && unset KIT_BOARD_NAME && kit_python3 "$HOOK") >/dev/null 2>&1)
check test -e "$ROUTING_KIT_HOME/board/presence/$(anon_name claude child).json"
check test ! -e "$ROUTING_KIT_HOME/board/presence/$(anon_name claude parent).json"
(export KIT_BOARD_SESSION=parent; hookx named SessionStart "" >/dev/null 2>&1)
check test -e "$ROUTING_KIT_HOME/board/presence/named.json"

# --- case 22b (B1, F4): the real hook ignores an inherited KIT_BOARD_NAME; the event's session id names the session
reset
mkevent claude SessionStart child "$REPO" "" 0 | (cd "$REPO" && KIT_BOARD_NAME=intruder KIT_BOARD_SESSION=parent kit_python3 "$HOOK") >/dev/null 2>&1
check test -e "$ROUTING_KIT_HOME/board/presence/$(anon_name claude child).json"
check test ! -e "$ROUTING_KIT_HOME/board/presence/intruder.json"
check test ! -e "$ROUTING_KIT_HOME/board/presence/$(anon_name claude parent).json"
# A dm to the session's own name is delivered, and the seen is the session's, not the intruder's.
as B send "$(anon_name claude child)" 'for the real name' >/dev/null 2>&1
out=$(mkevent claude PostToolUse child "$REPO" "" 0 | (cd "$REPO" && KIT_BOARD_NAME=intruder kit_python3 "$HOOK"))
assert_contains "$out" 'for the real name' 'case 22b: the dm reaches the session by its session-id name even with an inherited KIT_BOARD_NAME'
check board_has "any(r['kind']=='seen' and r['from']=='$(anon_name claude child)' for r in rows)"

# --- case 22c (B1, F1): the name an agent infers from its own environment is the name its hook gave it
reset
for spec in 'claude CLAUDE_CODE_SESSION_ID claude' 'codex CODEX_SESSION_ID codex' 'codex CODEX_THREAD_ID codex' 'agy ANTIGRAVITY_CONVERSATION_ID gemini'; do
  set -- $spec
  agent="$1" var="$2" family="$3"
  mkevent "$agent" SessionStart "env-$var" "$REPO" "" 0 | (cd "$REPO" && unset KIT_BOARD_NAME KIT_BOARD_SESSION KIT_BOARD_FAMILY && kit_python3 "$HOOK") >/dev/null 2>&1
  who_am_i=$(cd "$REPO" && env -u KIT_BOARD_NAME -u KIT_BOARD_SESSION -u KIT_BOARD_FAMILY -u CLAUDE_CODE_SESSION_ID -u CODEX_SESSION_ID -u CODEX_THREAD_ID -u ANTIGRAVITY_CONVERSATION_ID "$var=env-$var" "$BOARD" whoami)
  assert_eq "$(anon_name "$family" "env-$var") $family" "$who_am_i" "case 22c: $var infers the name the $agent hook registered"
  check test -e "$ROUTING_KIT_HOME/board/presence/$(anon_name "$family" "env-$var").json"
done

# ======================================================================
# Message targets (G1): send --to NAME | repo:<abs path> | all, and the old positional form.
# ======================================================================
# presence_in NAME FAMILY AGE_SECONDS REPO -- presence for a session whose repo is REPO.
presence_in() {
  python3 - "$ROUTING_KIT_HOME/board/presence" "$@" <<'PY'
import datetime, json, os, sys
d, name, family, age, repo = sys.argv[1:6]
os.makedirs(d, exist_ok=True)
now = datetime.datetime.now(datetime.timezone.utc)
iso = lambda s: (now - datetime.timedelta(seconds=s)).strftime('%Y-%m-%dT%H:%M:%SZ')
with open(os.path.join(d, name + '.json'), 'w') as f:
    json.dump(dict(name=name, family=family, model=None, repo=repo, started=iso(int(age) + 3600),
                   last_seen=iso(int(age)), paseo_id=None, codex_thread=None), f)
PY
}
# dm_targets -- the sorted `to` of every dm, one per line.
dm_targets() {
  python3 - "$ROUTING_KIT_HOME/board/board.jsonl" <<'PY'
import json, os, sys
p = sys.argv[1]
rows = [json.loads(l) for l in open(p)] if os.path.exists(p) else []
print('\n'.join(sorted(r['to'] for r in rows if r['kind'] == 'dm')))
PY
}
REPO2=$(mktmp)

# --- case 23: --to NAME works like the positional form
reset
presence B claude 5 "" ""
out=$(as A send --to B 'via option' 2>&1); code=$?
assert_eq 0 "$code" 'case 23 --to NAME: exit 0'
assert_contains "$out" 'waiting' 'case 23 --to NAME: status printed'
check board_has "any(r['kind']=='dm' and r['from']=='A' and r['to']=='B' and r['text']=='via option' for r in rows)"
out=$(as A send B 'via position' 2>&1); code=$?
assert_eq 0 "$code" 'case 23 positional form still works: exit 0'
check board_has "any(r['kind']=='dm' and r['to']=='B' and r['text']=='via position' for r in rows)"
out=$(as A send --to nobody 'x' 2>&1 >/dev/null); code=$?
assert_eq 3 "$code" 'case 23 --to unknown name: exit 3'
assert_contains "$out" 'no such session' 'case 23 --to unknown name: stderr says no such session'
as A send >/dev/null 2>&1; case $? in 0) fail 'case 23 no arguments: accepted' ;; *) pass ;; esac
as A send --to B >/dev/null 2>&1; case $? in 0) fail 'case 23 --to without text: accepted' ;; *) pass ;; esac

# --- case 24: --to all reaches every live session except the sender and stale ones
reset
presence A claude 5 "" ""
presence S1 claude 5 "" ""
presence S2 codex 120 "" ""
presence STALE claude 14400 "" ""
out=$(as A send --to all 'everyone listen' 2>&1); code=$?
assert_eq 0 "$code" 'case 24 --to all: exit 0'
assert_eq 'S1
S2' "$(dm_targets)" 'case 24 --to all: one dm per live session, not the sender, not the stale one'
check board_has "all(r['text']=='everyone listen' for r in rows if r['kind']=='dm')"
assert_contains "$out" 'S1' 'case 24 --to all: output names each receiver'
assert_contains "$(hookx S1 PostToolUse "")" 'everyone listen' 'case 24 --to all: a receiver gets it from its hook'
reset
out=$(as A send --to all 'nobody home' 2>&1 >/dev/null); code=$?
assert_eq 3 "$code" 'case 24 --to all with nobody live: exit 3'
check board_has "not any(r['kind']=='dm' for r in rows)"

# --- case 25: --to repo:PATH reaches the live sessions whose repo is that path
reset
presence_in R1 claude 5 "$REPO"
presence_in R2 claude 5 "$REPO"
presence_in O1 claude 5 "$REPO2"
presence_in RSTALE claude 14400 "$REPO"
out=$(as A send --to "repo:$REPO" 'repo news' 2>&1); code=$?
assert_eq 0 "$code" 'case 25 --to repo: exit 0'
assert_eq 'R1
R2' "$(dm_targets)" 'case 25 --to repo: only live sessions of that repo'
out=$(as A send --to "repo:$REPO2" 'other repo news' 2>&1); code=$?
assert_eq 0 "$code" 'case 25 --to repo (other): exit 0'
check board_has "any(r['kind']=='dm' and r['to']=='O1' and r['text']=='other repo news' for r in rows)"
out=$(as A send --to "repo:/no/such/repo" 'x' 2>&1 >/dev/null); code=$?
assert_eq 3 "$code" 'case 25 --to repo with nobody there: exit 3'
as A send --to 'repo:' 'x' >/dev/null 2>&1; case $? in 0) fail 'case 25 empty repo path: accepted' ;; *) pass ;; esac

# --- case 26: a fan-out hands over to each idle session its own way
reset
presence P1 claude 600 "pas-1" ""
presence P2 claude 600 "pas-2" ""
out=$(as A send --to all 'wake all' 2>&1); code=$?
assert_eq 0 "$code" 'case 26 fan-out queue: exit 0'
check python3 - "$(stub_calls)" <<'PY'
import json, sys
calls = json.loads(sys.argv[1])
assert sorted(c[1][2] for c in calls) == ['pas-1', 'pas-2'], calls
assert all(c[0] == 'paseo' for c in calls), calls
PY

# R2 regression
python3 - "$ROOT" <<'R2PY'
import sys, datetime, tempfile, contextlib
from pathlib import Path
sys.path.insert(0,str(Path(sys.argv[1])/'plugins/routing-kit/lib'))
import board_dm as d
with tempfile.TemporaryDirectory() as tmp:
 root=Path(tmp); (root/'presence').mkdir()
 d.board.directory=lambda:root
 d.board.locked=contextlib.nullcontext
 for name,seconds in [('fresh',899),('stale',901),('old',10801)]:
  d.save(root/'presence'/(name+'.json'),dict(name=name,last_seen=(d.now()-datetime.timedelta(seconds=seconds)).isoformat()))
 assert set(d.live_sessions('sender'))=={'fresh'}
R2PY
[ $? -eq 0 ] && pass || fail "R2 regression: broadcasts reach only sessions seen in 15 minutes"

echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
