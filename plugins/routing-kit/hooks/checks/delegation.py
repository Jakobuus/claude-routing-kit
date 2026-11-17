#!/usr/bin/env python3
"""Require deliberate model choices when delegating work; fail open on bad input."""
import json
import re
import sys

ASSIGNMENT = re.compile(r'[A-Za-z_][A-Za-z0-9_]*=')
REDIRECT = re.compile(r'&>>?|<<<|<<-?|>>|>[&|]?|<[&>]?')
SEPARATORS = ';|&()'
RESERVED = {'if', 'then', 'else', 'elif', 'while', 'until', 'do', '{', '!'}
# Wrapper commands that run the rest of their words; value = options that take an argument.
WRAPPERS = {
    'env': ('-u', '-C'), 'nohup': (), 'sudo': ('-u', '-g', '-h', '-p', '-C', '-D', '-R', '-T', '-U'),
    'doas': ('-u', '-C'), 'nice': ('-n',), 'time': (), 'command': (), 'exec': ('-a',), 'setsid': (),
    'caffeinate': ('-t', '-w'), 'stdbuf': ('-i', '-o', '-e'), 'timeout': ('-s', '-k'),
    'xargs': ('-n', '-I', '-L', '-P', '-d', '-E', '-s', '-a', '-l'),
}
SHELLS = {'bash', 'sh', 'zsh', 'dash'}
HELP_FLAGS = ('-h', '--help', '-V', '--version')
# Options that swallow the next word, so a help flag right after one is a value, not a request.
VALUE_OPTIONS = {'--repo', '--name', '--brief', '--model', '-m', '--prompt', '--timeout',
                 '--effort', '--thinking', '-c', '--config', '--system-prompt', '--append-system-prompt', '--output-format', '--max-turns'}
# Commands that only look a name up and never run it.
LOOKUPS = {'type', 'which', 'hash'}


def substitution_end(text, i):
    """Index just past the `$(...)`, `<(...)`, `name=(...)` or backtick group opening at text[i].

    Raises ValueError when it never closes.
    """
    if text[i] == '`':
        j = i + 1
        while j < len(text) and text[j] != '`':
            j += 2 if text[j] == '\\' else 1
        if j >= len(text):
            raise ValueError('unbalanced backtick')
        return j + 1
    depth, j = 0, text.index('(', i)
    while j < len(text):
        c = text[j]
        if c == '\\':
            j += 1
        elif c in '\'"':
            j = text.find(c, j + 1)
            if j < 0:
                raise ValueError('unbalanced quote')
        elif c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                return j + 1
        j += 1
    raise ValueError('unbalanced parenthesis')


def split_commands(text):
    """Split a shell line into simple commands, each a list of words.

    Handles quotes, backslashes, comments, heredoc bodies and redirections; it is not a
    full shell parser. Raises ValueError on an unbalanced quote.
    """
    commands, words, cur = [], [], []
    in_word = False   # a word is being built (an empty "" still counts)
    heredocs = []     # (delimiter, strip_tabs) waiting for their body
    next_is = None    # None, 'skip' (redirect target) or 'heredoc' (its delimiter)
    tabs = False
    i, n = 0, len(text)

    def end_word():
        nonlocal in_word, cur, next_is
        if in_word:
            word = ''.join(cur)
            if next_is == 'heredoc':
                heredocs.append((word, tabs))
            elif next_is is None:
                words.append(word)
            next_is = None
        cur, in_word = [], False

    def end_command():
        nonlocal words
        end_word()
        if words:
            commands.append(words)
        words = []

    while i < n:
        c = text[i]
        if c in ' \t\r':
            end_word()
        elif c == '\n':
            end_command()
            i += 1
            for delim, strip in heredocs:  # skip heredoc bodies
                while i < n:
                    j = text.find('\n', i)
                    j = n if j < 0 else j
                    line = text[i:j].rstrip('\r')
                    i = j + 1
                    if (line.lstrip('\t') if strip else line) == delim:
                        break
            heredocs = []
            continue
        elif c == '\\':
            if i + 1 < n and text[i + 1] != '\n':
                cur.append(text[i + 1])
                in_word = True
            i += 1
        elif c == "'":
            j = text.find("'", i + 1)
            if j < 0:
                raise ValueError('unbalanced quote')
            cur.append(text[i + 1:j])
            in_word = True
            i = j
        elif c == '"':
            i += 1
            while i < n and text[i] != '"':
                if text[i] == '`' or text.startswith('$(', i):
                    j = substitution_end(text, i)
                    cur.append(text[i:j])
                    i = j
                    continue
                if text[i] == '\\' and i + 1 < n and text[i + 1] in '"\\$`':
                    i += 1
                cur.append(text[i])
                i += 1
            if i >= n:
                raise ValueError('unbalanced quote')
            in_word = True
        elif c == '#' and not in_word:
            j = text.find('\n', i)
            i = n if j < 0 else j
            continue
        elif c == '`' or text.startswith('$(', i) or (c in '<>' and text.startswith('(', i + 1)):
            # A substitution is one opaque word; its own commands are checked separately.
            j = substitution_end(text, i)
            cur.append(text[i:j])
            in_word = True
            commands.extend(split_commands(text[text.index('(', i) + 1 if c != '`' else i + 1:j - 1]))
            i = j
            continue
        elif c == '(' and in_word and cur[-1:] == ['=']:  # array assignment: args=(a b)
            j = substitution_end(text, i)
            cur.append(text[i:j])
            i = j
            continue
        elif c in '<>' or (c == '&' and text.startswith('&>', i)):
            if in_word and ''.join(cur).isdigit():  # the fd in 2>&1 is not a word
                cur, in_word = [], False
            end_word()
            op = REDIRECT.match(text, i).group()
            next_is = 'heredoc' if op in ('<<', '<<-') else 'skip'
            tabs = op == '<<-'
            i += len(op)
            continue
        elif c in SEPARATORS:
            end_command()
        else:
            cur.append(c)
            in_word = True
        i += 1
    end_command()
    return commands


def skip_options(words, with_arg):
    i = 0
    while i < len(words):
        w = words[i]
        if w == '--':
            i += 1
            break
        if not w.startswith('-') or len(w) < 2:
            break
        i += 2 if w in with_arg else 1
    return words[i:]


def shell_reason(command, depth=0):
    if depth > 3:
        return
    for words in split_commands(command):
        reason = command_reason(words, depth)
        if reason:
            return reason


def shell_c_body(args):
    """The script text after a shell's -c (also -lc, -ic ...), or None if it runs a file."""
    i = 0
    while i < len(args):
        arg = args[i]
        if arg[:1] not in '-+' or len(arg) < 2:
            return None
        if arg[0] == '-' and not arg.startswith('--') and 'n' in arg:
            return None  # -n only syntax-checks
        if arg[0] == '-' and not arg.startswith('--') and 'c' in arg:
            return args[i + 1] if i + 1 < len(args) else None
        # -o NAME / -euo NAME / +O NAME take an argument
        i += 2 if not arg.startswith('--') and arg[-1] in 'oO' else 1


def command_reason(words, depth):
    while True:
        while words and (ASSIGNMENT.match(words[0]) or words[0] in RESERVED):
            words = words[1:]
        if not words:
            return
        executable, args = words[0].rsplit('/', 1)[-1], words[1:]
        if executable in LOOKUPS:
            return
        if executable not in WRAPPERS:
            break
        if executable == 'command' and any(set(a[1:]) & set('vV') for a in args[:2] if a[:1] == '-'):
            return  # `command -v X` looks X up, it does not run it
        words = skip_options(args, WRAPPERS[executable])
        if executable == 'timeout':
            words = words[1:]  # the duration
    if executable in SHELLS:
        body = shell_c_body(args)
        return shell_reason(body, depth + 1) if body else None
    # Words after `--` are prompt text, never options.
    if '--' in args:
        args = args[:args.index('--')]
    flags = ['--model']
    if executable == 'claude':
        if not any(x in args for x in ('-p', '--print')):
            return
    elif executable == 'codex':
        if not args or args[0] != 'exec':
            return
        flags.append('-m')
    elif executable == 'paseo':
        if not args or args[0] != 'run':
            return
    elif executable == 'agy':
        if not any(a in args for a in ('-p', '--print', '--prompt')):
            return
    elif executable not in {'codex-build', 'agy-build', 'kit-codex-build', 'kit-gemini-build'}:
        return
    if any(a in HELP_FLAGS and (i == 0 or args[i - 1] not in VALUE_OPTIONS) for i, a in enumerate(args)):
        return
    models = []
    for i, arg in enumerate(args):
        for flag in flags:
            if arg == flag and i + 1 < len(args) and not args[i + 1].startswith('-'):
                models.append(args[i + 1])
            elif arg.startswith(flag + '=') and arg[len(flag) + 1:]:
                models.append(arg[len(flag) + 1:])
    if not models:
        return 'Delegation requires an explicit --model.'
    if executable in {'claude', 'paseo'} and any('fable' in model.lower() for model in models):
        return 'Shell delegation must not use a Fable model.'
    effort_flag = {'claude': '--effort', 'agy': '--effort',
                   'agy-build': '--effort',
                   'paseo': '--thinking', 'codex': '-c model_reasoning_effort=…'}.get(executable)
    if not effort_flag:
        return  # Build wrappers expose no effort option.
    if executable == 'codex':
        values = []
        for i, arg in enumerate(args):
            if arg in ('-c', '--config') and i + 1 < len(args):
                values.append(args[i + 1])
            elif arg.startswith('--config='):
                values.append(arg[len('--config='):])
            elif arg.startswith('-c') and len(arg) > 2:
                values.append(arg[2:])
        present = any(re.match(r'^model_reasoning_effort\s*=\s*.+', v) for v in values)
    else:
        present = any(
            (arg == effort_flag and i + 1 < len(args)
             and bool(args[i + 1]) and not args[i + 1].startswith('-'))
            or (arg.startswith(effort_flag + '=') and bool(arg[len(effort_flag) + 1:]))
            for i, arg in enumerate(args))
    # Models that carry their effort in the name (gemini-4-argon-high) need no separate flag.
    present = present or any(re.search(r'-(low|medium|high|xhigh|max)$', m) for m in models)
    if not present:
        return f'Delegation requires an explicit {effort_flag}.'



def main():
    data = json.load(sys.stdin)
    if data.get('event') != 'PreToolUse':
        return
    tool = data.get('tool') or {}
    reason = None
    if tool.get('kind') == 'agent' and data.get('agent') == 'claude' and tool.get('name') == 'Agent':
        params = tool.get('params') or {}
        kind = (params.get('subagent_type') or 'general-purpose').strip()
        if kind != 'fork' and not params.get('effort'):
            reason = 'This Agent call has no `effort`. Pick one on purpose for this task (low = lookups, medium = standard build work, high = tricky work, xhigh/max = only when the task needs it) and re-issue the call.'
        elif kind in {'general-purpose', 'claude', 'Plan'} and not params.get('model'):
            reason = f"Subagent '{kind}' would silently inherit the main session model. Re-issue this Agent call with an explicit model."
    elif tool.get('kind') == 'shell':
        reason = shell_reason(tool.get('command') or '')
    if reason:
        print(json.dumps({'action': 'deny', 'reason': reason}))


if __name__ == '__main__':
    try:
        main()
    except Exception:  # fail open: bad input (or a bug here) never blocks work
        pass
