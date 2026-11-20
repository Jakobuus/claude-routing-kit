#!/bin/bash
. "$(dirname "$0")/lib.sh"
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktmp)
export ROUTING_KIT_HOME="$T/kit" CODEX_HOME="$T/codex"
cp "$ROOT/plugins/routing-kit/bin/kit-models-validate" "$T/kit-models-validate"
printf '#!/bin/sh\nexit 4\n' > "$T/kit-models-available"
chmod +x "$T/kit-models-available"
python3 - "$ROOT" "$T" <<'PY'
import copy, json, pathlib, subprocess, sys
root, tmp = map(pathlib.Path, sys.argv[1:])
base = json.loads((root/'plugins/routing-kit/rules/models.json').read_text())
cases = [({}, 'valid')]
def case(path, value, name):
    cases.append(((path, value), name))
case(['version'], '2', 'string version')
case(['version'], True, 'bool version')
case(['version'], 0, 'zero version')
case(['gemini'], None, 'missing gemini')
case(['pricing'], [], 'pricing object')
case(['pricing'], {'bad id': {}}, 'pricing id')
for value in (True, '2', -1, 1000):
    case(['pricing'], {'model-one': {'price_in_per_mtok': value, 'price_out_per_mtok': None}}, 'price '+str(value))
case(['pricing'], {'model-one': {}}, 'price fields')
case(['pricing_checked'], None, 'missing pricing date')
case(['pricing_checked'], '2026-13-40 note', 'pricing date')
case(['checked'], '2026-02-30', 'calendar date')
case(['kimi'], {'build':'model-one','base_url':'https://example.com','host':'other.com'}, 'host mismatch')
case(['kimi'], {'build':'model-one','base_url':'http://example.com','host':'example.com'}, 'http')
case(['codex','base_url'], 'https://example.com', 'codex endpoint')
case(['trials'], [], 'trial object')
case(['trials'], {'jules':{'runs':0,'ledger':'trials.tsv'}}, 'zero runs')
case(['trials'], {'jules':{'runs':1,'ledger':'a/b'}}, 'ledger slash')
case(['unexpected'], True, 'unknown key')
case(['codex','build'], None, 'lost role')
case(['fallbacks'], {'model-one':'model-two','model-two':'model-one'}, 'cycle')
failures=0
for i,(edit,name) in enumerate(cases):
    data=copy.deepcopy(base)
    if edit:
        path,value=edit
        target=data
        for key in path[:-1]: target=target[key]
        if value is None: target.pop(path[-1],None)
        else: target[path[-1]]=value
    file=tmp/'case.json'; file.write_text(json.dumps(data))
    result=subprocess.run([sys.executable,str(tmp/'kit-models-validate'),str(file)],capture_output=True,text=True)
    ok=result.returncode == (0 if i==0 else 1)
    if not ok: print('FAIL:',name,result.stderr); failures+=1
    elif i and len(result.stderr.splitlines())!=1: failures+=1
# The sibling tool, not PATH, supplies availability.
(tmp/'kit-models-available').write_text('#!/bin/sh\necho model-not-routed\n')
file.write_text(json.dumps(base))
result=subprocess.run([sys.executable,str(tmp/'kit-models-validate'),str(file)],capture_output=True,text=True)
if result.returncode!=1 or 'not offered' not in result.stderr: failures+=1
print('test_models_validate: %d cases, %d failures' % (len(cases)+1, failures))
sys.exit(bool(failures))
PY
exit $?
