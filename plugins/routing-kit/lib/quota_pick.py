"""Select among the rendered job's model choices using quota pace."""
import json
import re
import subprocess
import sys
from pathlib import Path

bin_dir, job = sys.argv[1:]
try:
    table = subprocess.check_output([bin_dir + '/kit-routing-table'], text=True)
except subprocess.CalledProcessError as exc:
    sys.exit(exc.returncode)
row = next((line.split('|')[2] for line in table.splitlines()
            if line.startswith('|') and line.split('|')[1].strip() == job), None)
if row is None:
    print('no such job', file=sys.stderr)
    sys.exit(3)
# Conditional advisers supplement the default choice.
row = re.split(r';|,\s*risky changes', row)[0]
if '→' in row:
    row = row.split('→', 1)[1]
models = json.loads((Path(bin_dir) / '../rules/models.json').read_text())
quota = json.loads(subprocess.check_output([bin_dir + '/kit-quota', '--json'], text=True))
choices = []
blocked = []
for lane in ('claude', 'codex', 'gemini'):
    reading = quota.get(lane) or {}
    if reading.get('stale'):
        continue
    for model in dict.fromkeys(models[lane].values()):
        if not re.search(r'(?<![\w-])' + re.escape(model) + r'(?![\w-])', row):
            continue
        five = reading.get('five_hour') or {}
        week = reading.get('week') or {}
        if lane == 'claude' and (week.get('percent') or 0) >= 100:
            continue
        if model == models['claude']['top']:
            fable = reading.get('weekly_fable') or {}
            if fable.get('stale') or fable.get('percent') is None or fable['percent'] >= 100:
                continue
        if lane == 'gemini' and 'argon' in model:
            week = reading.get('argon_week') or {}
            if week.get('percent') is None or week['percent'] >= 100:
                continue
        pace = week.get('pace')
        target = blocked if (five.get('percent') or 0) > 80 else choices
        target.append((pace if pace is not None else float('inf'), row.find(model), model))
choices = choices or blocked
if not choices:
    print('no eligible model', file=sys.stderr)
    sys.exit(1)
print(min(choices)[2])
