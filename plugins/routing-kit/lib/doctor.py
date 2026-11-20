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


def used_agents(profile):
    main = profile.get('main_agent')
    return [name for name in ('claude', 'codex', 'gemini', 'jules')
            if main == name or (name == 'claude' and profile.get('claude_plan') not in (None, 'none'))
            or (name in ('codex', 'gemini') and profile.get(name) not in (None, 'none'))
            or (name == 'jules' and profile.get(name) is True)]


def valid_profile(profile, require_main=False):
    """Cheap file-only check for session start; `kit-profile validate` does the full check in --setup."""
    main = profile.get('main_agent', None if require_main else 'claude')
    return profile.get('version') == 1 and main in ('claude', 'codex', 'gemini')


def paseo_installed():
    import sys
    return bool(shutil.which('paseo') or (sys.platform == 'darwin' and Path('/Applications/Paseo.app').is_dir()))


def probe(command):
    """Bound a read-only probe, including children inheriting its output pipes."""
    import signal
    try:
        proc = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True, errors='replace', start_new_session=True)
    except OSError:
        return 1, '', 'could not run command'
    try:
        out, err = proc.communicate(timeout=10)
        return proc.returncode, out, err
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.communicate()
        return 1, '', 'did not answer in 10 s'


def setup_checks(kit, homes, drift):
    root = Path(__file__).resolve().parent.parent
    profile = load(kit/'profile.json')
    rows = []
    def add(check, ok, message='', fix=''):
        rows.append({'check': check, 'status': 'ok' if ok else 'fix',
                     'message': check + (': '+message if ok and message else ': '+fix if not ok else '')})
    def recommend(message):
        rows.append({'check': 'paseo', 'status': 'recommended', 'message': message})
    code, _, err = probe([str(root/'bin/kit-profile'), 'validate'])
    add('profile', code == 0 and valid_profile(profile, require_main=True), fix=(err if 'did not answer' in err else 'run START-HERE.md to set a valid profile and main_agent'))
    agents = used_agents(profile)
    for agent in agents:
        cli = 'agy' if agent == 'gemini' else agent
        if not shutil.which(cli):
            add(agent+' installed', False, fix='install '+cli+'; see START-HERE.md')
            continue
        if agent == 'jules':
            # Jules has no documented offline-cheap sign-in or version probe.
            add('jules installed', True)
            continue
        code, out, err = probe([cli, '--version'])
        add(agent+' installed', code == 0, ' '.join(out.split()),
            (err if 'did not answer' in err else 'check '+cli+' --version'))
        if 'did not answer' in err:
            continue
        command = {'claude': [cli, 'auth', 'status'], 'codex': [cli, 'login', 'status'],
                   'gemini': [cli, 'models']}[agent]
        code, out, err = probe(command)
        signed = code == 0
        if agent == 'claude':
            signed = signed and parse_line(out).get('loggedIn') is True
        elif agent == 'gemini':
            signed = signed and any(re.match(r'^gemini-[a-z0-9.-]+(?:\s|$)', line.strip()) for line in out.splitlines())
        login = {'claude': 'claude auth login', 'codex': 'codex login', 'gemini': 'agy (complete sign-in)'}[agent]
        add(agent+' signed in', signed, fix=(err+'; ' if 'did not answer' in err else '')+login)
    models = load(root/'rules/models.json')
    for lane in ('codex', 'gemini'):
        if lane not in agents:
            continue
        code, out, err = probe([str(root/'bin/kit-models-available'), lane])
        if code == 4:
            add('models '+lane, True, 'list not known yet')
        elif code:
            add('models '+lane, False, fix=(err if 'did not answer' in err else 'run kit-models-available '+lane))
        else:
            routed = {v for k, v in models.get(lane, {}).items() if k not in ('base_url', 'host')}
            missing = sorted(routed - set(out.splitlines()))
            add('models '+lane, bool(routed) and not missing,
                fix=('unavailable: '+', '.join(missing)+'; update the routing table or account model list') if missing else 'restore rules/models.json')
    sync = load(kit/'sync-state.json')
    for name, key, kinds in (('rules', 'files', ('edited_by_hand',)), ('skills', 'links', ('skill_missing',)),
                             ('hooks', 'hooks', ('hook_drift', 'hook_timeout'))):
        ok = key in sync and not any(f['check'] in kinds for f in drift)
        add(name, ok, fix='run kit-sync '+name)
    if 'codex' in agents:
        import codex_trust
        wanted = {}
        for name, entry in sync.get('hooks', {}).items():
            if entry.get('agent') == 'codex':
                wanted.update(codex_trust.entries_for(name, load(Path(name)), set(entry.get('commands', []))))
        cfg = homes['codex']/'config.toml'
        text = cfg.read_text() if cfg.is_file() else ''
        # Compare complete tables, so a hash in a comment or another hook cannot grant trust.
        tables = dict(re.findall(r'^\[hooks\.state\.("(?:[^"\\]|\\.)*")\]\s*\n(.*?)(?=^\[|\Z)', text, re.M|re.S))
        trusted = bool(wanted) and all(re.search(r'^\s*trusted_hash\s*=\s*'+re.escape(json.dumps(digest))+r'\s*(?:#.*)?$',
                         tables.get(json.dumps(key, ensure_ascii=False), ''), re.M) for key, digest in wanted.items())
        add('codex hooks trusted', trusted, fix='run kit-sync hooks')
    installed = paseo_installed()
    chosen = profile.get('codex_build_transport') == 'paseo' or profile.get('paseo') is True
    if not installed:
        if chosen:
            add('paseo installed', False, fix='install Paseo; see START-HERE step 5')
        add('codex_build_transport', True, profile.get('codex_build_transport', 'direct'))
        recommend('Paseo lets you watch and stop builds from the app or your phone, keeps builds running, and shows your usage; see START-HERE step 5')
        return rows
    add('paseo installed', True)
    code, out, err = probe(['paseo', 'status', '--json'])
    status = parse_line(out)
    running = code == 0 and status.get('localDaemon') == 'running'
    add('paseo daemon', running, fix=(err+'; ' if 'did not answer' in err else '')+'open Paseo and start its daemon')
    if running:
        providers = status.get('providers', [])
        if not isinstance(providers, list):
            providers = []
        available = [a for a in agents if any(isinstance(p, dict) and p.get('provider') in (a, 'agy' if a == 'gemini' else a) and p.get('available') is True for p in providers)]
        add('paseo providers', True, ', '.join(available) if available else 'none of the configured agents available')
    transport = profile.get('codex_build_transport', 'direct')
    add('codex_build_transport', True, transport)
    if transport == 'direct':
        recommend('Use Paseo for builds: kit-profile set codex_build_transport paseo')
    code, out, err = probe(['paseo', 'plugin', 'ls'])
    pill = False
    for line in out.splitlines():
        fields = line.split()
        if len(fields) >= 3 and fields[1:3] == ['running', 'yes'] and (fields[0] == 'routing-kit-pill' or any('paseo-pill' in v or 'limits-pill' in v for v in fields[3:])):
            pill = True
    add('paseo pill', code == 0 and (pill or not profile.get('paseo')), 'on' if pill else 'off',
        (err+'; ' if 'did not answer' in err else '')+'paseo plugin install https://github.com/Jakobuus/claude-routing-kit.git --path paseo-pill')
    return rows


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--fast', action='store_true')
    p.add_argument('--setup', action='store_true')
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
    if a.fast:
        profile = load(kit/'profile.json')
        if not valid_profile(profile):
            add('profile', 'profile missing or invalid; run START-HERE.md')
        for agent in used_agents(profile):
            cli = 'agy' if agent == 'gemini' else agent
            if not shutil.which(cli):
                add('installed', agent+' not installed; install '+cli)
        if profile.get('codex_build_transport') == 'paseo' and not paseo_installed():
            add('paseo', 'Paseo chosen but not installed; see START-HERE step 5')
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
    if count != previous and not a.setup:
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
    if a.setup:
        rows = setup_checks(kit, homes, findings)
        failures = sum(row['status'] == 'fix' for row in rows)
        if a.json:
            print(json.dumps(rows))
        else:
            for row in rows:
                print(('recommended: ' if row['status'] == 'recommended' else row['status'].ljust(6)) + row['message'])
            print('setup: '+(str(failures)+' to fix' if failures else 'all ok'))
        return 1 if failures else 0
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
        status = main()
    except Exception as error:
        print('kit-doctor: '+ ' '.join(str(error).splitlines()))
        status = 1
    raise SystemExit(status or 0)
