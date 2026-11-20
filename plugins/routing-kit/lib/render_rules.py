#!/usr/bin/env python3
"""Render agent rules with validated, whole-line conditional blocks.

only:<agents>  kept for the program that reads the file (--agent).
main:<agent>   kept for the agent that leads: --main, else the profile's
               main_agent, else claude. It is the same in all three files.
lane:<name>    kept when the profile has that lane.
"""
import argparse
import json
import re
import sys
from pathlib import Path

AGENTS = ('claude', 'codex', 'gemini')
LANES = ('codex', 'gemini', 'jules', 'kimi', 'glm')
MARKER = re.compile(r'^\s*<!--\s*(/)?(only|main|lane)(?::(.*?))?\s*-->\s*$')


def filter_blocks(text, agent, profile, lead):
    stack = []
    output = []
    for number, line in enumerate(text.splitlines(keepends=True), 1):
        match = MARKER.fullmatch(line)
        if not match:
            if all(entry[3] for entry in stack):
                output.append(line)
            continue
        closing, kind, value = match.groups()
        value = value.strip() if value is not None else None
        if closing:
            if not stack:
                raise ValueError('stray close at line {}'.format(number))
            if (kind, value) != stack[-1][:2]:
                raise ValueError('mismatched close at line {}'.format(number))
            stack.pop()
            continue
        if kind == 'only':
            names = [name.strip() for name in (value or '').split(',')]
            if any(name not in AGENTS for name in names):
                raise ValueError('unknown agent at line {}'.format(number))
            if any(entry[0] == 'only' for entry in stack):
                raise ValueError('nested only at line {}'.format(number))
            keep = agent in names
        elif kind == 'main':
            if value not in AGENTS:
                raise ValueError('unknown agent at line {}'.format(number))
            keep = value == lead
        else:
            if value not in LANES:
                raise ValueError('unknown lane at line {}'.format(number))
            keep = (profile is None or
                    (profile.get(value) not in (None, 'none')
                     if value in ('codex', 'gemini') else
                     profile.get(value) is True))
        stack.append((kind, value if kind != 'only' else None, number, keep))
    if stack:
        raise ValueError('unclosed {} at line {}'.format(stack[-1][0], stack[-1][2]))
    return ''.join(output)



def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--agent', required=True, choices=AGENTS)
    parser.add_argument('--role', required=True, choices=('lead',))
    parser.add_argument('--kit-rules', required=True)
    parser.add_argument('--private-rules', required=True)
    parser.add_argument('--table', required=True)
    parser.add_argument('--profile')
    parser.add_argument('--main', choices=AGENTS)
    args = parser.parse_args()
    try:
        profile = json.loads(Path(args.profile).read_text()) if args.profile else None
        lead = args.main or (profile or {}).get('main_agent')
        lead = lead if lead in AGENTS else 'claude'
        parts = []
        for filename in (args.kit_rules, args.private_rules, args.table):
            text = sys.stdin.read() if filename == '-' else Path(filename).read_text()
            if (filename == args.kit_rules and args.private_rules
                    and (profile or {}).get('kit_rules') == 'replace'):
                text = ''
            part = filter_blocks(text, args.agent, profile, lead).rstrip('\n')
            if part:
                parts.append(part)
    except (ValueError, OSError) as error:
        print(str(error).replace('\n', ' '), file=sys.stderr)
        return 2
    sys.stdout.write('\n\n'.join(parts) + '\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
