#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Fail on ucode constructs that parse, run, and silently do the wrong thing.

One so far: ASSIGNING THE RESULT OF A PARENTHESIZED `??` THAT IS CALLED,

    let c = (o.cursor_isolated ?? o.cursor)();
    x = (a ?? b)(args);

yields null whenever the left operand is set — no error, the value is just
gone. `return (a ?? b)()` and the bare statement `(a ?? b)();` are fine, and so
is the assignment when the left operand is null, which is why a test that only
exercises the fallback passes. Verified on the host ucode and on the target's
ucode-2026.07.09~b885dd0f (NR7101, 2026-10-04). Write it as two statements:

    let mk = o.cursor_isolated ?? o.cursor;
    let c = mk();

transport.uc already did, with a comment; deps.uc did not, and its device
detour got a null cursor until this was found.

Usage: check-ucode-pitfalls.py [root]   (default: src-ucode)
"""

import os
import re
import sys

# `=` that is an assignment (not ==, !=, <=, >=, =>), then `( … ?? … )(`
PATTERN = re.compile(r'(?<![=!<>])=(?![=>])\s*\(([^()]*\?\?[^()]*)\)\s*\(')


def strip_comment(line):
    # good enough for this tree: `//` inside a string literal on the same line
    # as such an assignment does not occur
    i = line.find('//')
    return line if i < 0 else line[:i]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else 'src-ucode'
    hits = []
    files = 0

    for dirpath, _, names in os.walk(root):
        for name in sorted(names):
            if not name.endswith('.uc'):
                continue

            path = os.path.join(dirpath, name)
            files += 1

            with open(path, encoding='utf-8') as f:
                for n, line in enumerate(f, 1):
                    if PATTERN.search(strip_comment(line)):
                        hits.append((path, n, line.strip()))

    for path, n, text in hits:
        print(f'{path}:{n}: assigned call of a parenthesized `??` — null when the left side is set; split it into two statements')
        print(f'    {text}')

    print(f'checked {files} .uc files under {root}: {len(hits)} assigned `(a ?? b)()` call(s)')
    return 1 if hits else 0


if __name__ == '__main__':
    sys.exit(main())
