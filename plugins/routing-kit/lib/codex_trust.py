"""Codex hook trust for the kit's own hooks: the hash Codex expects, and exact-text edits of config.toml.

Codex 0.166 runs a hook from a hooks file only if $CODEX_HOME/config.toml holds
    [hooks.state."<hooks.json path>:<event>:<group>:<handler>"]
    trusted_hash = "sha256:..."
and the hash equals the one it computes from the hook's normalized definition (codex-rs/hooks/src/engine/
discovery.rs `hook_hash` over codex-rs/config/src/fingerprint.rs `version_for_toml`): the identity
{event_name, matcher?, hooks:[{type, command, async, timeout, statusMessage?}]} as compact JSON with sorted keys,
sha256, "sha256:" + hex. Verified against the real binary (`hooks/list` over `codex app-server`, and a headless
`codex exec` run that only runs the hooks while the tables are present).

Ownership: the kit's tables are ONE block appended at the very end of config.toml between two comment lines it
owns (START and END). It is removed only when the file still ends with exactly the block the kit recorded at its
last write (plus the one separating newline it added, if it added one); the file is never searched for it. If
anything else was added after the block, nothing is removed and the owner is told to remove it by hand.
Everything else in config.toml is foreign and never touched; a hook whose key already appears elsewhere in the
file gets no table.
"""
import hashlib
import json
import re

try:
    import tomllib
except ImportError:  # Python < 3.11: no parser to double-check the result with
    tomllib = None

LABEL = {'PreToolUse': 'pre_tool_use', 'PermissionRequest': 'permission_request', 'PostToolUse': 'post_tool_use',
         'PreCompact': 'pre_compact', 'PostCompact': 'post_compact', 'PreModelRequest': 'pre_model_request',
         'PostModelRequest': 'post_model_request', 'SessionStart': 'session_start', 'SessionEnd': 'session_end',
         'UserPromptSubmit': 'user_prompt_submit', 'SubagentStart': 'subagent_start',
         'SubagentStop': 'subagent_stop', 'Stop': 'stop', 'Interrupt': 'interrupt'}
# Events where Codex keeps the matcher; for the others it is dropped before hashing.
MATCHER_EVENTS = {'PreToolUse', 'PermissionRequest', 'PostToolUse', 'SessionStart', 'SessionEnd',
                  'SubagentStart', 'SubagentStop', 'PreCompact', 'PostCompact'}


def hook_hash(event, matcher, handler):
    """Codex's trust hash for one command handler, or None when Codex would not accept the handler as written."""
    if event not in LABEL or not isinstance(handler, dict) or handler.get('type') != 'command':
        return None
    command, timeout = handler.get('command'), handler.get('timeout', 600)
    if not isinstance(command, str) or not command.strip() or not isinstance(handler.get('async', False), bool):
        return None
    if isinstance(timeout, bool) or not isinstance(timeout, int) or timeout < 0:
        return None
    ident_handler = {'type': 'command', 'command': command, 'async': handler.get('async', False), 'timeout': max(timeout, 1)}
    if handler.get('statusMessage') is not None:
        if not isinstance(handler['statusMessage'], str):
            return None
        ident_handler['statusMessage'] = handler['statusMessage']
    ident = {'event_name': LABEL[event], 'hooks': [ident_handler]}
    if event in MATCHER_EVENTS and matcher is not None:
        if not isinstance(matcher, str):
            return None
        ident['matcher'] = matcher
    text = json.dumps(ident, sort_keys=True, separators=(',', ':'), ensure_ascii=False)
    return 'sha256:' + hashlib.sha256(text.encode('utf-8')).hexdigest()


def entries_for(hooks_path, data, owned):
    """{key: hash} for every handler in the hooks file (parsed JSON `data`) whose command is in `owned`."""
    out = {}
    hooks = data.get('hooks') if isinstance(data, dict) else None
    for event, groups in (hooks.items() if isinstance(hooks, dict) else []):
        for gi, group in enumerate(groups if isinstance(groups, list) else []):
            handlers = group.get('hooks') if isinstance(group, dict) else None
            for hi, handler in enumerate(handlers if isinstance(handlers, list) else []):
                if isinstance(handler, dict) and handler.get('command') in owned:
                    h = hook_hash(event, group.get('matcher'), handler)
                    if h:
                        out['%s:%s:%d:%d' % (hooks_path, LABEL[event], gi, hi)] = h
    return out


START = '# routing-kit hook trust: start (written by kit-sync hooks; kit-sync hooks --undo removes it)\n'
END = '# routing-kit hook trust: end\n'
BY_HAND = ("config.toml no longer ends with the kit's Codex trust block (between the two '# routing-kit hook trust' "
           "comment lines); remove it by hand")


def _table(key, digest):
    return '[hooks.state.%s]\ntrusted_hash = %s\n' % (json.dumps(key, ensure_ascii=False), json.dumps(digest))


def block(items):
    """The exact text the kit appends for [(key, hash), ...]."""
    return START + ''.join(_table(k, h) for k, h in items) + END


def _parses(text):
    if tomllib is None:
        return True
    try:
        tomllib.loads(text)
        return True
    except tomllib.TOMLDecodeError:
        return False


def strip(text, rec):
    """(text without the recorded block, True) or (text, False) when the file does not end with exactly it.
    rec: {'items': [[key, hash], ...], 'sep': bool}. Removes the block and, if the kit added one, its separating newline."""
    old = block([tuple(i) for i in rec['items']])
    if not text.endswith(old):
        return text, False
    base = text[:-len(old)]
    if rec.get('sep'):
        if not base.endswith('\n'):
            return text, False
        base = base[:-1]
    return base, True


def sync_text(text, wanted, rec):
    """(new text, new record or None, notes): the block for `wanted` {key: hash} is the file's last bytes.

    rec is the record of the block written last time (None if none). Foreign text is never changed."""
    if rec:
        base, ok = strip(text, rec)
        if not ok and 'routing-kit hook trust' not in text and not any(
                k in text or json.dumps(k, ensure_ascii=False)[1:-1] in text or json.dumps(k)[1:-1] in text
                for k, _ in rec['items']):
            # The owner removed our block by hand: forget the stale record and write a fresh block.
            base, ok, rec = text, True, None
        if not ok:
            return text, rec, [BY_HAND]
    else:
        base = text
        if START in text:
            return text, None, [BY_HAND]
    if not _parses(base):
        return text, rec, ['config.toml is not valid TOML, left alone; Codex trust not written']
    items, notes = [], []
    for key, digest in wanted.items():
        if json.dumps(key, ensure_ascii=False) in base:
            notes.append('config.toml already has its own entry for %s, left alone' % key)
        else:
            items.append((key, digest))
    if not items:
        return base, None, notes
    sep = bool(base) and not base.endswith('\n')
    new = base + ('\n' if sep else '') + block(items)
    if not _parses(new):
        return text, rec, ['would make config.toml invalid TOML, left alone; Codex trust not written']
    return new, {'items': [list(i) for i in items], 'sep': sep}, notes


def remove_text(text, rec, created=False):
    """(new text, notes). New text is None only to delete a file the kit created and has emptied entirely."""
    if not rec:
        return text, []
    base, ok = strip(text, rec)
    if not ok:
        return text, [BY_HAND]
    return (None if base == '' and created else base), []
