#!/bin/bash
. "$(dirname "$0")/lib.sh"
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
P="$ROOT/plugins/routing-kit"
. "$P/bin/kit-common"
START='<!-- routing-kit:rules:start -->'
END='<!-- routing-kit:rules:end -->'
setup() {
 s=$(mktmp)
 export HOME="$s/home" CODEX_HOME="$s/codex" ROUTING_KIT_HOME="$s/kit"
 c="$s/claude"; g="$s/gemini"; x="$CODEX_HOME"
 mkdir -p "$HOME" "$c" "$g" "$x" "$ROUTING_KIT_HOME/private"
 printf '%s\n' '{"version":1,"claude_plan":"pro","codex":"plus","gemini":"pro","jules":false,"kimi":false,"glm":false,"paseo":false}' > "$ROUTING_KIT_HOME/profile.json"
 a="$c/CLAUDE.md"; b="$x/AGENTS.md"; d="$g/AGENTS.md"
}
run() {
 out=$("$P/bin/kit-sync" rules --home-claude "$c" --home-codex "$x" --home-gemini "$g" "$@" 2>&1); code=$?
}
ok() { assert_eq 0 "$code" "$1"; }
same() { diff -u "$1" "$2" && pass || fail "$3"; }
snapshot() {
 kit_python3 - "$s" <<'PY'
import os,sys,hashlib
for root,dirs,files in os.walk(sys.argv[1]):
 for name in sorted(dirs+files):
  p=os.path.join(root,name); st=os.lstat(p)
  if name=='sync.lock': continue  # the shared lock file may appear on any run; folder mtimes move with it
  print(p,st.st_mode,'' if os.path.isdir(p) else st.st_mtime_ns,os.readlink(p) if os.path.islink(p) else hashlib.sha256(open(p,'rb').read()).hexdigest() if os.path.isfile(p) else '')
PY
}
# 1. Fresh targets, exact renderer bytes and exactly one marker pair.
setup
assert_exit 0 '1 fresh command succeeds' -- "$P/bin/kit-sync" rules --home-claude "$c" --home-codex "$x" --home-gemini "$g"
run; ok '1 fresh sync'
# All three files carry the same table: the one for the lead named in the
# profile (main_agent, Claude by default). The renderer resolves lane: blocks
# from the profile.
"$P/bin/kit-routing-table" --profile "$ROUTING_KIT_HOME/profile.json" > "$s/table"
for agent in claude codex gemini; do
 case "$agent" in claude) f="$a";; codex) f="$b";; gemini) f="$d";; esac
 kit_python3 "$P/lib/render_rules.py" --agent "$agent" --kit-rules "$P/rules/RULES.md" --private-rules - --table "$s/table" --profile "$ROUTING_KIT_HOME/profile.json" --role lead < /dev/null > "$s/expected"
 assert_eq 0 "$?" 'renderer succeeds'
 kit_python3 - "$f" "$s/expected" "$START" "$END" <<'PY'
import sys,pathlib
p,e,start,end=sys.argv[1:]; t=pathlib.Path(p).read_bytes() if pathlib.Path(p).exists() else b''
s=(start+'\n').encode(); z=(end+'\n').encode()
assert t.count(s)==t.count(z)==1
assert t.split(s)[1].split(z)[0]==pathlib.Path(e).read_bytes()
PY
 assert_eq 0 "$?" "1 $agent exact block"
done
# 2. Sync replaces only the block; every byte outside it stays; no backup files are written.
setup
printf 'Above\n\n%s\nold\n%s\n\nBelow\n' "$START" "$END" > "$a"
cp "$a" "$s/original"; run
[ "$code" -ne 0 ] && pass || fail '2 a block with no record was replaced'
assert_contains "$out" 'not recorded as written by kit-sync' '2 unrecorded block refused'
run --force; ok '2 force over an unrecorded block'
kit_python3 - "$a" "$s/original" "$START" "$END" <<'PY'
import pathlib,sys
p,q,s,e=sys.argv[1:]
def outside(p):
 t=pathlib.Path(p).read_bytes(); return (t.split((s+'\n').encode())[0],t.split((e+'\n').encode())[1])
assert outside(p)==outside(q)
PY
assert_eq 0 "$?" '2 outside bytes'
printf 'Changed private source\n' > "$ROUTING_KIT_HOME/private/rules.md"
run; ok '2 changed source replaces the block'
grep -q 'Changed private source' "$a" && pass || fail '2 block not replaced on resync'
kit_python3 - "$a" "$START" "$END" <<'PY'
import pathlib,sys
p,s,e=sys.argv[1:]; t=pathlib.Path(p).read_bytes()
assert t.count((s+'\n').encode())==1 and t.startswith(b'Above\n\n'+(s+'\n').encode()) and t.endswith((e+'\n').encode()+b'\nBelow\n')
PY
assert_eq 0 "$?" '2 one block, same place, same surroundings'
[ -z "$(find "$s" -name '*.bak')" ] && pass || fail '2 a backup file was written'
# 3. No changes, including config and state.
before=$(snapshot); run; ok '3 repeat'; assert_contains "$out" 'no changes' '3 message'; assert_eq "$before" "$(snapshot)" '3 identical files'
# 4. Nonempty override wins.
setup; printf 'Normal\n' > "$b"; cp "$b" "$s/normal"
printf 'Override\n' > "$x/AGENTS.override.md"; run; ok '4 override'
same "$s/normal" "$b" '4 normal untouched'
assert_contains "$(cat "$x/AGENTS.override.md")" "$START" '4 override selected'
# 5. Config: our line goes on top of config.toml; any other spelling of the key is only a hint.
setup; cp "$ROOT/tests/fixtures/sync/config.toml" "$x/config.toml"; cp "$x/config.toml" "$s/config-before"
run; ok '5 absent'
{ printf 'project_doc_max_bytes = 65536\n'; cat "$s/config-before"; } > "$s/config-expected"
same "$s/config-expected" "$x/config.toml" '5 absent: our line on top, every other byte kept'
case "$out" in *yourself*) fail '5 absent: hint';; *) pass;; esac
# the second run finds our exact line: nothing to do
before=$(snapshot); run; ok '5 repeat'; assert_contains "$out" 'no changes' '5 repeat message'; assert_eq "$before" "$(snapshot)" '5 repeat identical'
# a missing config.toml is created with just our line
setup; run; ok '5 no file'; assert_eq 'project_doc_max_bytes = 65536' "$(cat "$x/config.toml")" '5 no file: created'
# any other spelling of the key, or a BOM: untouched, plus the hint
for kind in 131072 32768 hex quoted dotted elsewhere comment bom; do
 setup
 case "$kind" in
  131072|32768) printf 'project_doc_max_bytes = %s\nmodel = "a"\n' "$kind" > "$x/config.toml";;
  hex) printf 'project_doc_max_bytes = 0x10000\n[x]\ny = 1\n' > "$x/config.toml";;
  quoted) printf '"project_doc_max_bytes" = 100\n[x]\ny = 1\n' > "$x/config.toml";;
  dotted) printf 'project_doc_max_bytes.x = 100\n[x]\ny = 1\n' > "$x/config.toml";;
  elsewhere) printf '[x]\nproject_doc_max_bytes = 1\n' > "$x/config.toml";;
  comment) printf '# project_doc_max_bytes = 1\n[x]\ny = 1\n' > "$x/config.toml";;
  bom) printf '\357\273\277model = "a"\n' > "$x/config.toml";;
 esac
 cp "$x/config.toml" "$s/config-before"; run; ok "5 $kind exit"
 same "$s/config-before" "$x/config.toml" "5 $kind untouched"
 assert_contains "$out" "set project_doc_max_bytes = 65536 in $x/config.toml yourself" "5 $kind hint"
 assert_contains "$(cat "$a")" "$START" "5 $kind rules still synced"
done
# our exact line elsewhere in the file counts as present: no hint, no change
setup; printf 'model = "a"\nproject_doc_max_bytes = 65536\n' > "$x/config.toml"; cp "$x/config.toml" "$s/config-before"; run; ok '5 exact line'
same "$s/config-before" "$x/config.toml" '5 exact line untouched'
case "$out" in *yourself*) fail '5 exact line: hint';; *) pass;; esac
# 6. Dry run creates nothing and preserves mtimes.
setup; printf 'Keep\n' > "$a"; before=$(snapshot); run --dry-run; ok '6 dry run'
for f in "$a" "$b" "$d" "$x/config.toml"; do assert_contains "$out" "$f" '6 target path'; done
assert_contains "$out" '@@' '6 diff summary'
assert_eq "$before" "$(snapshot)" '6 nothing written'
# 7. Undo takes the block out and nothing else; a file left with zero bytes goes away.
setup; printf 'Original\n' > "$a"; cp "$a" "$s/original"
cp "$ROOT/tests/fixtures/sync/config.toml" "$x/config.toml"
run; ok '7 sync'; cp "$x/config.toml" "$s/config-synced"; printf '\nLater user text\n' >> "$d"; run --undo; ok '7 undo'
same "$s/original" "$a" '7 original rules'; same "$s/config-synced" "$x/config.toml" '7 undo leaves config.toml alone'
assert_contains "$out" "left project_doc_max_bytes in $x/config.toml; remove it by hand if you want" '7 undo says what it left'
[ ! -e "$b" ] && pass || fail '7 file with nothing left remains'
assert_contains "$(cat "$d" 2>/dev/null)" 'Later user text' '7 user addition survives'
[ -z "$(find "$s" -name '*.bak')" ] && pass || fail '7 backup file around'
# no blank line is added; the one newline added to a file without a final newline is not taken back
setup; printf 'Orig\n' > "$a"; run; ok '7 plain'
printf 'Orig\n%s' '<!--' > "$s/head"; head -c "$(wc -c < "$s/head" | tr -d ' ')" "$a" | cmp -s - "$s/head" && pass || fail '7 a separator or other bytes before the block'
setup; printf 'No final newline' > "$a"; run; ok '7 no newline'
printf 'No final newline\n<!--' > "$s/head"; head -c "$(wc -c < "$s/head" | tr -d ' ')" "$a" | cmp -s - "$s/head" && pass || fail '7 exactly one newline added before the block'
run --undo; ok '7 no newline undo'; printf 'No final newline\n' > "$s/expected"; same "$s/expected" "$a" '7 the added newline stays, nothing else'
setup; printf 'a\r\nb\r\n  \r\n' > "$a"; cp "$a" "$s/crlf"; run; ok '7 crlf'; run --undo; ok '7 crlf undo'; same "$s/crlf" "$a" '7 crlf and whitespace byte for byte'
setup; printf '  \n\n' > "$a"; cp "$a" "$s/ws"; run; ok '7 whitespace'; run --undo; ok '7 whitespace undo'; same "$s/ws" "$a" '7 whitespace-only file stays'
# undo does not read or restore any backup file an older version left
setup; printf 'Current\n' > "$a"; printf 'Ancient backup\n' > "$a.routing-kit.bak"; run; ok '7 sync with old bak'; run --undo; ok '7 undo with old bak'
assert_eq 'Current' "$(cat "$a")" '7 undo ignores backups'; assert_eq 'Ancient backup' "$(cat "$a.routing-kit.bak")" '7 old backup left alone'
# 8a. A home folder reached through a symlinked system folder (/tmp on a Mac, /home on Fedora Atomic) syncs;
# a symlink from the home folder down is still refused.
setup; mkdir -p "$s/real-homes/u"; ln -s "$s/real-homes" "$s/homes"; export HOME="$s/homes/u"
c="$HOME/.claude"; x="$HOME/.codex"; g="$HOME/.gemini"; mkdir -p "$c" "$x" "$g"; a="$c/CLAUDE.md"
run; ok '8a home under a symlinked system folder syncs'
assert_contains "$(cat "$a")" "$START" '8a block written'
setup; mkdir -p "$s/real-homes/u" "$s/dotfiles"; ln -s "$s/real-homes" "$s/homes"; export HOME="$s/homes/u"
ln -s "$s/dotfiles" "$HOME/.claude"; c="$HOME/.claude"; x="$HOME/.codex"; g="$HOME/.gemini"; mkdir -p "$x" "$g"
run; [ "$code" -ne 0 ] && pass || fail '8a symlinked ~/.claude accepted'
assert_contains "$out" "symlink: $HOME/.claude" '8a names the symlink inside the home folder'
# 8. Symlink refusal is atomic and one line.
setup; printf 'Referent\n' > "$s/referent"; ln -s "$s/referent" "$d"
before=$(snapshot); run
[ "$code" -ne 0 ] && pass || fail '8 symlink accepted'
assert_eq 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" '8 one line'
assert_contains "$out" "$d" '8 names file'; assert_eq "$before" "$(snapshot)" '8 unchanged'
# 9. Unwritable final home: earlier targets must roll back.
setup; for f in "$a" "$b" "$d"; do printf 'Before\n' > "$f"; done
cp "$a" "$s/before"; chmod 555 "$g"; run; chmod 755 "$g"
[ "$code" -ne 0 ] && pass || fail '9 failed move accepted'
for f in "$a" "$b" "$d"; do same "$s/before" "$f" '9 rollback'; done
# 10. State hash detects hand edits; force rewrites them; a block with no record is refused the same way.
setup; run; ok '10 initial sync'
kit_python3 - "$a" "$ROUTING_KIT_HOME/sync-state.json" "$START" "$END" <<'PYHASH'
import pathlib,sys,json,hashlib
p,state,start,end=sys.argv[1:]
t=pathlib.Path(p).read_bytes() if pathlib.Path(p).exists() else b''
block=t.split((start+'\n').encode())[1].split((end+'\n').encode())[0]
st=json.loads(pathlib.Path(state).read_text())
assert st['files'][p]==hashlib.sha256(block).hexdigest()
assert set(st)=={'files'},set(st)
PYHASH
assert_eq 0 "$?" '10 persisted block hash, nothing else'
cp "$a" "$s/rendered"
kit_python3 - "$a" "$START" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]); t=p.read_bytes() if p.exists() else b''
p.write_bytes(t.replace((sys.argv[2]+'\n').encode(),(sys.argv[2]+'\nHand edit\n').encode()))
PY
before=$(snapshot); run
[ "$code" -ne 0 ] && pass || fail '10 edit accepted'
assert_contains "$out" "edited by hand: $a; kit-sync rules --force overwrites it" '10 guidance'
case "$out" in *adopt*) fail '10 mentions adopt';; *) pass;; esac
assert_eq "$before" "$(snapshot)" '10 refusal writes nothing'
run --force; ok '10 force'; same "$s/rendered" "$a" '10 force restores rendering'
# no state record at all: the block is not ours to replace
rm "$ROUTING_KIT_HOME/sync-state.json"; before=$(snapshot); run
[ "$code" -ne 0 ] && pass || fail '10 unrecorded block accepted'
assert_contains "$out" "not recorded as written by kit-sync" '10 unrecorded message'; assert_eq "$before" "$(snapshot)" '10 unrecorded: nothing written'
run --undo; [ "$code" -ne 0 ] && pass || fail '10 undo of an unrecorded block accepted'
assert_eq "$before" "$(snapshot)" '10 unrecorded undo: nothing written'
run --force; ok '10 force on unrecorded'; same "$s/rendered" "$a" '10 force on unrecorded rewrites'
run --undo; ok '10 undo after force'
grep -q routing-kit:rules "$a" 2>/dev/null && fail '10 undo left the block' || pass
# a record in the older format (a table of fields) still counts, and is rewritten as path: sha
setup; run; ok '10 old record sync'
kit_python3 - "$ROUTING_KIT_HOME/sync-state.json" <<'PY'
import json,sys
st=json.load(open(sys.argv[1])); st['files']={k:{'sha256':v,'backup':k+'.routing-kit.bak'} for k,v in st['files'].items()}; st['undo']={'x':{}}
open(sys.argv[1],'w').write(json.dumps(st))
PY
printf 'Changed private source\n' > "$ROUTING_KIT_HOME/private/rules.md"; run; ok '10 old record resync'
kit_python3 - "$ROUTING_KIT_HOME/sync-state.json" <<'PY'
import json,sys
st=json.load(open(sys.argv[1])); assert set(st)=={'files'} and all(isinstance(v,str) for v in st['files'].values()),st
PY
assert_eq 0 "$?" '10 old record rewritten as path: sha'
# 12. Undo refuses a hand-edited block without --force; with it only the block goes.
setup; printf 'Original\n' > "$a"; run; ok '12 sync'
printf 'My note\n' >> "$a"; printf 'Codex note\n' >> "$b"
kit_python3 - "$a" "$START" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]); p.write_bytes(p.read_bytes().replace((sys.argv[2]+'\n').encode(),(sys.argv[2]+'\nHand edit\n').encode()))
PY
before=$(snapshot); run --undo
[ "$code" -ne 0 ] && pass || fail '12 undo accepted a hand-edited block'
assert_contains "$out" "edited by hand: $a" '12 undo names file'; assert_eq "$before" "$(snapshot)" '12 refused undo writes nothing'
run --undo --force; ok '12 forced undo'
assert_eq 'Original
My note' "$(cat "$a")" '12 forced undo: user text kept, block gone'
assert_eq 'Codex note' "$(cat "$b")" '12 created file keeps user text'
# 15. One lock for all writers: a second run waits, then gives up with one line.
setup; mkdir -p "$s/agents"
kit_python3 - "$P/bin/kit-sync" "$ROUTING_KIT_HOME" "$c" "$x" "$g" "$s/agents" <<'PY'
import fcntl,json,os,subprocess,sys,time
sync,kit,c,x,g,ag=sys.argv[1:]
rules=[sync,'rules','--home-claude',c,'--home-codex',x,'--home-gemini',g]
skills=[sync,'skills','--home-claude',c,'--home-gemini',g,'--agents-dir',ag]
fd=os.open(kit+'/sync.lock',os.O_RDWR|os.O_CREAT); fcntl.flock(fd,fcntl.LOCK_EX)
for cmd in (rules,skills):
    r=subprocess.run(cmd,env=dict(os.environ,KIT_SYNC_LOCK_WAIT='1'),capture_output=True,text=True)
    assert r.returncode==1 and 'another kit-sync is running' in r.stdout+r.stderr,(cmd,r)
assert not os.path.exists(kit+'/sync-state.json')
# a run that waits sees what the lock holder wrote, and keeps it
q=subprocess.Popen(rules,env=dict(os.environ,KIT_SYNC_LOCK_WAIT='30'),stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
time.sleep(1.0)
assert q.poll() is None and not os.path.exists(kit+'/sync-state.json'),'ran while the lock was held'
open(kit+'/sync-state.json','w').write(json.dumps({'links':{'/l':{'target':'/t'}}}))
os.close(fd)
out,_=q.communicate(timeout=30)
assert q.returncode==0,out
assert json.load(open(kit+'/sync-state.json'))['links']=={'/l':{'target':'/t'}},'lost the holder state'
assert os.path.exists(c+'/CLAUDE.md')
PY
assert_eq 0 "$?" '15 lock: refuses after wait, waits for holder, keeps its state'
# 16. Interrupts roll everything back; targets first, state last.
setup
kit_python3 - "$P/lib/sync_rules.py" "$s" "$ROOT/tests/fixtures/sync/config.toml" "$ROUTING_KIT_HOME/profile.json" <<'PY'
import importlib.util,os,pathlib,shutil,signal,sys
mod,base,cfg,prof=sys.argv[1:]
spec=importlib.util.spec_from_file_location('sync_rules',mod); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
real=os.replace
def fresh(n):
    d=pathlib.Path(base)/('int%d'%n); d.mkdir()
    for h in ('claude','codex','gemini','kit'): (d/h).mkdir()
    for f in ('claude/CLAUDE.md','codex/AGENTS.md','gemini/AGENTS.md'): (d/f).write_text('Before\n')
    shutil.copy(cfg,d/'codex/config.toml'); shutil.copy(prof,d/'kit/profile.json')
    return d
def files(d): return {str(p.relative_to(d)):p.read_bytes() for p in d.rglob('*') if p.is_file() and p.name!='sync.lock'}
def go(d,n):
    calls=[]
    def rep(src,dst,*a,**k):
        calls.append(str(dst))
        if len(calls)==n: raise (KeyboardInterrupt if n%2 else SystemExit(2))
        return real(src,dst,*a,**k)
    os.environ['ROUTING_KIT_HOME']=str(d/'kit')
    sys.argv=['x','--home-claude',str(d/'claude'),'--home-codex',str(d/'codex'),'--home-gemini',str(d/'gemini')]
    os.replace=rep
    try: m.main()
    except BaseException as e: raised=e
    else: raised=None
    finally: os.replace=real
    signal.signal(signal.SIGINT,signal.default_int_handler)
    return calls,raised
d=fresh(0); calls,raised=go(d,0)
assert raised is None
assert len(calls)==5,calls  # three rules files, config.toml, state
assert calls[-1].endswith('sync-state.json'),calls
assert not any(c.endswith('.bak') for c in calls),calls
for n in range(1,len(calls)+1):
    d=fresh(n); before=files(d); _,raised=go(d,n)
    assert isinstance(raised,KeyboardInterrupt if n%2 else SystemExit),(n,raised)
    assert files(d)==before,(n,sorted(set(files(d).items())^set(before.items())))
PY
assert_eq 0 "$?" '16 interrupt at every replacement rolls back; state last, no backups'
# 17. A resync that keeps a user's edit: undo still gives the outside bytes back.
setup; printf 'Original\n' > "$a"; run; ok '17 sync'
printf 'User note\n' >> "$a"; printf 'Changed private source\n' > "$ROUTING_KIT_HOME/private/rules.md"
run; ok '17 resync'; run --undo; ok '17 undo'
assert_eq 'Original
User note' "$(cat "$a")" '17 user note survives undo after a resync'
# 18. Undo never edits config.toml, whatever the user did to it; a second undo has nothing to do.
setup; : > "$x/config.toml"; run; ok '18 sync'
printf 'notes = """\nproject_doc_max_bytes = 65536\n"""\n' | cat - "$x/config.toml" > "$s/cfg-new"; cp "$s/cfg-new" "$x/config.toml"
run --undo; ok '18 undo'
same "$s/cfg-new" "$x/config.toml" '18 config untouched by undo'
run --undo; ok '18 undo again'; assert_contains "$out" 'no changes' '18 nothing more'
# 19. The old adopt options are gone.
setup; for opt in --adopt --adopt-whole-file; do run "$opt"; [ "$code" -ne 0 ] && pass || fail "19 $opt still accepted"; done
# 21. Property test: random outside bytes through random sequences of sync, outside edits, block edits, resync and undo
# (renderer stubbed: only the file logic is under test). After every step the bytes outside our block are
# unchanged, apart from the one newline added when a block is appended to a file that did not end in one;
# after undo the file equals the outside bytes; a refusal writes nothing.
setup
kit_python3 - "$P/lib/sync_rules.py" "$s" <<'PY'
import contextlib,importlib.util,io,pathlib,random,sys
mod,base=sys.argv[1:]
spec=importlib.util.spec_from_file_location('sync_rules',mod); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.sync_lock.acquire=lambda home: None
m.subprocess.check_output=lambda *a,**k: b'Rules body\n'
S,E,BODY=m.START,m.END,b'Rules body\n'
base=pathlib.Path(base)/'prop'
for h in ('claude','codex','gemini','kit'): (base/h).mkdir(parents=True,exist_ok=True)
P={'claude':base/'claude/CLAUDE.md','codex':base/'codex/AGENTS.md','gemini':base/'gemini/AGENTS.md'}
EXTRA=[base/'codex/config.toml',base/'kit/sync-state.json']
def outside(t):
    i=t.find(S)
    if i<0: return t
    return t[:i]+t[t.find(E,i)+len(E):]
def unsafe(B,mine):
    # text for which a refusal is legitimate: marker-like text outside our block, an unrecorded block, damaged markers
    cnt=(B.count(S),B.count(E))
    if cnt==(0,0): return b'routing-kit:rules' in B
    if cnt!=(1,1): return True
    i=B.index(S)
    return (not mine) or b'routing-kit:rules' in outside(B) or B.find(E)<i or (i>0 and B[i-1:i]!=b'\n')
def snap(): return {str(p):(p.read_bytes() if p.exists() else None) for p in list(P.values())+EXTRA}
def run(*flags):
    sys.argv=['x','--home-claude',str(base/'claude'),'--home-codex',str(base/'codex'),'--home-gemini',str(base/'gemini')]+list(flags)
    try:
        with contextlib.redirect_stdout(io.StringIO()): m.main()
        return True
    except ValueError: return False
rng=random.Random(20261117)
FR=[b'',b'a',b'Plain line\n',b'no trailing newline',b'dos\r\nlines\r\n',b'   ',b'\n',b'\t \r\n',b'\n\n\n',b'text\n\n',b'# Heading\n- item',b'trailing  ',b'tab\t',b'\r',b'\xe2\x9c\x93 utf8 \xff raw\n']
MARK=[b'<!-- routing-kit:rules:start -->',b'<!-- routing-kit:rules:end -->\n',b'routing-kit:rules:start -->\n',b'x <!-- routing-kit:rules:end --> y\n']
def frag(): return b''.join(rng.choice(MARK) if rng.random()<.07 else rng.choice(FR) for _ in range(rng.randint(0,4)))
RUNS=300; stats={'ok':0,'refused':0,'undo_exact':0}
for run_no in range(RUNS):
    for p in list(P.values())+EXTRA:
        if p.exists(): p.unlink()
    orig,touched,ours,edited={},{},{},{}
    for n,p in P.items():
        orig[n]=None if rng.random()<.4 else frag()
        if orig[n] is not None: p.write_bytes(orig[n])
        touched[n]=False; ours[n]=False; edited[n]=False
    for step in range(rng.randint(4,10)):
        op=rng.choice(['sync','sync','undo','edit-out','edit-out','edit-block','force-sync','force-undo'])
        where=(run_no,step,op)
        if op=='edit-out':
            for n,p in P.items():
                if rng.random()<.6:
                    t=p.read_bytes() if p.exists() else b''
                    x=frag()
                    if S in t and rng.random()<.5: t=x+b'\n'+t   # text above the block must keep ending in a newline
                    else: t=t+x
                    p.write_bytes(t); touched[n]=True
            continue
        if op=='edit-block':
            for n,p in P.items():
                if p.exists() and S in p.read_bytes() and E in p.read_bytes() and rng.random()<.7:
                    p.write_bytes(p.read_bytes().replace(S,S+b'HAND ',1)); edited[n]=True
            continue
        force=op.startswith('force'); undo=op.endswith('undo')
        before=snap()
        risky=any(unsafe(before[str(p)] or b'',ours[n]) for n,p in P.items())
        any_edited=any(edited.values())
        okay=run(*(['--undo'] if undo else [])+(['--force'] if force else []))
        if not okay:
            assert risky or (any_edited and not force),('refused without reason',where)
            assert snap()==before,('refusal wrote something',where)
            stats['refused']+=1
            continue
        assert not (any_edited and not force),('accepted an edited block',where)
        stats['ok']+=1
        after=snap()
        for n,p in P.items():
            B=before[str(p)]; A=after[str(p)]
            ob=outside(B or b'')
            if undo:
                if B is not None and S in B:
                    assert A==ob or (A is None and ob==b''),('undo changed more than the block',where,n,B,A)
                else: assert A==B,('undo touched a file without a block',where,n)
                ours[n]=False; edited[n]=False
                if not touched[n] and not (orig[n] and S in orig[n]):
                    o=orig[n]
                    okset=[o,o+b'\n'] if o else [None,b'']
                    assert A in okset,('undo is not the original',where,n,o,A)
                    stats['undo_exact']+=1
            else:
                assert A is not None and A.count(S)==1 and A.count(E)==1,('no single block',where,n,A)
                assert A[A.index(S)+len(S):A.index(E)]==BODY,('block content',where,n)
                oa=outside(A)
                added=(B is None or S not in B) and ob and not ob.endswith(b'\n') and oa==ob+b'\n'
                assert oa==ob or added,('sync changed outside bytes',where,n,B,A)
                ours[n]=True; edited[n]=False
assert stats['ok']>600 and stats['refused']>100 and stats['undo_exact']>200,stats
print('RUNS',RUNS,stats)
PY
assert_eq 0 "$?" '21 property: outside bytes never lost over 300 random sequences'
# 22. All readers get the short shared rules, without the retired board/media steps.
setup; run; ok '22 sync'
for f in "$a" "$b" "$d"; do
 grep -q 'Name the model' "$f" && pass || fail "22 $f: launch rule missing"
 ! grep -qF 'run `kit-board claims` and post a claim' "$f" && pass || fail "22 $f: board claim line missing"
 grep -qF '<owner> says (quoted via' "$f" && pass || fail "22 $f: board approval line missing"
 ! grep -qF 'run `kit-route "<the request>"`' "$f" && pass || fail "22 $f: media line missing"
 [ "$(wc -c < "$f" | tr -d ' ')" -lt 24000 ] && pass || fail "22 $f: over 24000 bytes"
done
grep -q 'Name the model on every worker' "$a" && pass || fail '22 claude file lacks the Agent-call rule'
for f in "$b" "$d"; do
 sed '/^| Work/,$d' "$f" | grep -qi 'subagent\|Agent call\|writing-plans' && fail "22 $f: Claude-only wording in the rules text" || pass
done
# The private rules file may be a symlink (the owner keeps it in his own git); it is only read.
setup; mv "$ROUTING_KIT_HOME/private/rules.md" "$s/real-rules.md"; printf 'Linked private rule\n' > "$s/real-rules.md"
ln -s "$s/real-rules.md" "$ROUTING_KIT_HOME/private/rules.md"; run; ok 'symlinked private rules sync'
assert_contains "$(cat "$a")" 'Linked private rule' 'symlinked private rules are rendered'
# A private rules link to a missing file is refused, never silently skipped.
setup; mv "$ROUTING_KIT_HOME/private/rules.md" "$s/gone.md"; ln -s "$s/missing.md" "$ROUTING_KIT_HOME/private/rules.md"
run; [ "$code" -ne 0 ] && pass || fail 'broken private rules link refused'
echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
