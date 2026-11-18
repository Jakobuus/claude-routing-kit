"""Read-only routing-kit diagnostics, with incremental hook acknowledgement."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


def load(path):
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def parse_line(line):
    try:
        data = json.loads(line)
    except ValueError:
        return {}
    return data if isinstance(data, dict) else {}


def size(path):
    return path.stat().st_size if path.is_file() else 0


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--fast', action='store_true')
    p.add_argument('--json', action='store_true')
    p.add_argument('--cost')
    for agent in ('claude', 'codex', 'gemini'):
        p.add_argument('--home-' + agent)
    p.add_argument('--repos-root')
    a = p.parse_args()
    kit = Path(os.environ.get('ROUTING_KIT_HOME', str(Path.home()/'.config/routing-kit')))
    homes = {n: Path(getattr(a, 'home_'+n) or (os.environ.get('CODEX_HOME') if n == 'codex' else None) or str(Path.home()/('.'+n))) for n in ('claude','codex','gemini')}
    root = Path(a.repos_root or load(kit/'profile.json').get('repos_root') or str(Path.home()/'Developer/Projects')).expanduser()
    findings = []
    def add(check, message):
        findings.append({'check':check, 'message':message})
    sync = load(kit/'sync-state.json')
    for name, entry in sync.get('files', {}).items():
        path = Path(name)
        text = path.read_text() if path.exists() else ''
        match = re.search(r'^<!-- routing-kit:rules:start -->[^\n]*\n(.*?)^<!-- routing-kit:rules:end -->', text, re.M|re.S)
        if not match or hashlib.sha256(match[1].encode()).hexdigest() != (entry if isinstance(entry, str) else entry['sha256']):
            add('edited_by_hand', 'edited by hand: '+name)
    for name, entry in sync.get('links', {}).items():
        link = Path(name)
        if not link.is_symlink() or not link.exists() or link.resolve() != Path(entry['target']).resolve():
            add('skill_missing', 'skill missing: %s in %s' % (entry['skill'],entry['agent']))
    import sys
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from sync_hooks import projection
    for name, entry in sync.get('hooks', {}).items():
        if projection(load(Path(name)), entry['agent'], set(entry.get('commands', []))) != entry['entries']:
            add('hook_drift', 'routing kit: hooks out of date for '+entry['agent'])
    config = homes['codex']/'config.toml'
    match = re.search(r'^\s*project_doc_max_bytes\s*=\s*(\d+)', config.read_text() if config.exists() else '', re.M)
    budget = int(match[1]) if match else 32768
    override = homes['codex']/'AGENTS.override.md'
    codex_global = size(override) if size(override) > 0 else size(homes['codex']/'AGENTS.md')
    for doc in sorted(root.glob('*/AGENTS.md')):
        if codex_global + size(doc) > budget:
            add('size','Codex would cut rules in '+str(doc.parent))
    for doc in [homes['gemini']/'AGENTS.md'] + sorted(root.glob('*/AGENTS.md')):
        if size(doc) > 24000:
            add('size','Antigravity would cut '+str(doc))
    if str(load(homes['claude']/'settings.json').get('env',{}).get('ENABLE_TOOL_SEARCH','')).lower() == 'false':
        add('tools_up_front','tools load up front in claude')
    servers = load(homes['gemini']/'config/mcp_config.json').get('mcpServers',{})
    if any(s.get('eager') is True for s in servers.values()):
        add('tools_up_front','tools load up front in gemini')
    log = kit/'hook-errors.log'
    count = len(log.read_text().splitlines()) if log.exists() else 0
    previous = load(kit/'doctor-state.json').get('hook_errors',0)
    if count > previous:
        add('hook_errors','routing kit: hooks had %d errors' % (count-previous))
    if count != previous:
        kit.mkdir(parents=True,exist_ok=True)
        (kit/'doctor-state.json').write_text(json.dumps({'hook_errors':count})+'\n')
    if not a.fast:
        from sync_hooks import max_timeout
        hook_root = Path(__file__).resolve().parent.parent
        targets = {homes['claude']/'settings.json', homes['codex']/'hooks.json',
                   homes['gemini']/'config/hooks.json'}
        targets.update(Path(name) for name in sync.get('hooks', {}))
        required = {}
        for target in sorted(targets):
            hooks = load(target).get('hooks', {})
            if not isinstance(hooks, dict):
                continue
            for event, groups in hooks.items():
                if not isinstance(groups, list):
                    continue
                for group in groups:
                    if not isinstance(group, dict):
                        continue
                    handlers = group.get('hooks', [group])
                    if not isinstance(handlers, list):
                        continue
                    for handler in handlers:
                        if not isinstance(handler, dict) or 'kit-hook' not in str(handler.get('command', '')):
                            continue
                        if event not in required:
                            required[event] = max_timeout(hook_root, event)
                        timeout = handler.get('timeout', 0)
                        if not isinstance(timeout, (int, float)) or timeout < required[event]:
                            add('hook_timeout', 'hook timeout too low: %s %s (needs %s s); run kit-sync hooks' %
                                (target, event, required[event]))
        import datetime  # only the full run reads the media log, so the fast run stays quick
        week_ago = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=7)).strftime('%Y-%m-%dT%H:%M:%SZ')
        routes = kit/'route-log.jsonl'
        seen = [e for e in map(parse_line, routes.read_text().splitlines() if routes.exists() else []) if str(e.get('time', '')) >= week_ago]
        if seen:
            add('media_jobs', 'media jobs: %d seen, %d routed' % (len(seen), sum(e.get('routed') is not False for e in seen)))
        # Build copies the kit moved aside instead of deleting. Walking them takes time: full run only.
        retained = kit/'retained'
        copies = [d for d in (sorted(retained.iterdir()) if retained.is_dir() and not retained.is_symlink() else []) if d.is_dir() and not d.is_symlink() and not d.name.startswith('.')]
        if copies:
            total = 0
            for copy in copies:
                for folder, _, names in os.walk(copy):
                    for name in names:
                        try:
                            total += os.lstat(os.path.join(folder, name)).st_size
                        except OSError:
                            pass
            add('retained', 'retained build copies: %d, %.1f MB (kit-retained list; kit-retained prune --older-than DAYS)' % (len(copies), total/1e6))
    if a.cost and not a.fast:
        commands = [('claude',['claude','-p','--output-format','json','--model','claude-haiku-5-5','reply ok']),('codex',['codex','exec','--json','--skip-git-repo-check','-m','gpt-6-luna','reply ok']),('gemini',['agy','--output-format','json','--model','gemini-4-hydrogen-low','-p','reply ok'])]
        for agent, command in commands:
            message = agent+': not installed'
            if shutil.which(command[0]):
                try:
                    r = subprocess.run(command,cwd=a.cost,stdin=subprocess.DEVNULL,capture_output=True,text=True,timeout=120,check=True)
                    if agent == 'codex':
                        usage = next(event['usage'] for event in map(parse_line, r.stdout.splitlines()) if event.get('type') == 'turn.completed')
                    else:
                        payload = json.loads(r.stdout)
                        if isinstance(payload, list):
                            payload = next(item for item in reversed(payload) if 'usage' in item)
                        usage = payload['usage']
                    tokens = sum(usage.get(k,0) for k in ('input_tokens','cache_creation_input_tokens','cache_read_input_tokens')) if agent == 'claude' else usage['input_tokens']
                    message = '%s: %s tokens at start' % (agent,tokens)
                except Exception:
                    message = agent+': probe failed'
            add('cost',message)
    if a.fast:
        if findings:
            msg = findings[0]['message']
            if not msg.startswith('routing kit: '):
                msg = 'routing kit: '+msg
            if len(findings)>1:
                msg += ' (+%d more; run kit-doctor)' % (len(findings)-1)
            print(msg)
    elif a.json:
        print(json.dumps(findings))
    else:
        for finding in findings:
            print(finding['message'])


if __name__ == '__main__':
    try:
        main()
    except (Exception, SystemExit) as error:
        print('kit-doctor: '+ ' '.join(str(error).splitlines()))
