#!/usr/bin/env python3
"""./askr docs:check -- every Pascal example in docs/ goes through fpc.

A page's examples are fragments: a statement that uses a variable the page
has in mind, a handler without the class around it. Each is wrapped in a
unit of its own:

    uses lines        -> the unit's uses, after the framework's units
    routines, types   -> the implementation section, as they stand
    statements        -> the body of one procedure

and compiled. An error is reported at the line of the page it came from.

What a page's examples take for granted is declared in a comment the page
does not show -- once for the page, or right before one block for that
block alone:

    <!-- check
    var
      K: TAiClient;
    -->

A line that is only `...` is read as a comment. Loose statements are the
body of `function DocBlock(Req: TRequest):
TResponse`, since most are a handler's. A block that is not meant to
compile -- one showing the error it talks about -- says so with ```pascal
nocheck, and is counted as skipped.

With no pages named, the programs in examples/ are compiled too.

    check.py <root> <fpc> <out dir> [page.md ...]
"""

import os
import re
import subprocess
import sys

ROOT, FPC, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
ONLY = sys.argv[4:]

UNIT_DIRS = ['core', 'http', 'urd', 'norn', 'inertia', 'runtime', 'desktop', 'cli', 'run']
# Everything an app can use, in dependency order, so a name defined in two
# units resolves the way it does in an app that uses the later one.
SKIP_UNITS = set()

FENCE = re.compile(r'^```(\S*)[ \t]*(.*)$')
ROUTINE = re.compile(r'^(procedure|function|constructor|destructor|class\s+(procedure|function))\b', re.I)
SECTION = re.compile(r'^(type|const|var|threadvar)\b', re.I)
USES = re.compile(r'^uses\b', re.I)
UNIT = re.compile(r'^(unit|program|library)\s+[\w.]+\s*;', re.I | re.M)


def framework_units():
    names = []
    for d in UNIT_DIRS:
        path = os.path.join(ROOT, 'src', d)
        for f in sorted(os.listdir(path)):
            if f.endswith('.pas'):
                name = f[:-4]
                if name not in SKIP_UNITS:
                    names.append(name)
    return names


def blocks(page):
    """(first line number, lines, info, own setup) for each fence, and the
    page's setup. A check comment with a pascal fence right after it --
    blank lines between at most -- belongs to that block; any other is the
    page's, for every block."""
    lines = open(page, encoding='utf-8').read().split('\n')
    out = []
    setup = []
    pending = None
    i = 0
    while i < len(lines):
        if lines[i].strip() == '<!-- check':
            chunk = []
            i += 1
            while i < len(lines) and lines[i].strip() != '-->':
                chunk.append(lines[i])
                i += 1
            i += 1
            k = i
            while k < len(lines) and lines[k].strip() == '':
                k += 1
            if k < len(lines) and lines[k].startswith('```pascal'):
                pending = chunk
            else:
                setup.extend(chunk)
            continue
        m = FENCE.match(lines[i])
        if m and m.group(1):
            lang, info = m.group(1), m.group(2)
            start = i + 1
            j = start
            while j < len(lines) and not lines[j].startswith('```'):
                j += 1
            if lang == 'pascal':
                out.append((start + 1, lines[start:j], info, pending or []))
            pending = None
            i = j + 1
            continue
        i += 1
    return out, setup


def split(body):
    """uses, declarations and statements, each a list of (page line, text)."""
    uses, decls, stmts = [], [], []
    i = 0
    n = len(body)
    while i < n:
        no, text = body[i]
        s = text.strip()
        if s == '':
            i += 1
            continue
        if USES.match(text):
            # up to the semicolon
            chunk = [(no, text)]
            # Up to the semicolon, reading past a comment after it:
            # `uses Askr.Notify.Slack;  { registers the channel }` ends there.
            def code_end(t):
                t = re.sub(r'\{[^}]*\}', '', t)
                t = re.sub(r'//.*$', '', t)
                return t.rstrip().endswith(';')
            while not code_end(chunk[-1][1]) and i + 1 < n:
                i += 1
                chunk.append(body[i])
            uses.extend(chunk)
            i += 1
            continue
        if ROUTINE.match(text) or SECTION.match(text):
            # A declaration runs until the next line at column 0 that is
            # neither indented nor a continuation: for a routine, up to its
            # own `end;` at column 0.
            chunk = [(no, text)]
            routine = bool(ROUTINE.match(text))
            i += 1
            while i < n:
                no2, t2 = body[i]
                if routine:
                    chunk.append((no2, t2))
                    i += 1
                    if t2.startswith('end;'):
                        break
                    continue
                if t2.strip() == '' or t2[0] in ' \t':
                    chunk.append((no2, t2))
                    i += 1
                    continue
                break
            decls.extend(chunk)
            continue
        stmts.append((no, text))
        i += 1
    return uses, decls, stmts


def uses_names(chunk):
    text = ' '.join(t for _, t in chunk)
    text = re.sub(r'\{[^}]*\}', ' ', text)
    text = re.sub(r'//[^\n]*', ' ', text)
    text = re.sub(r'^\s*uses\s+', '', text.strip(), flags=re.I).rstrip(';')
    return [u.strip() for u in text.split(',') if u.strip()]


def unit_text(name, fw, block_uses, setup, decls, stmts):
    """The unit's text, and a map from its line numbers to the page's."""
    lines = []
    where = {}

    def add(text, page_line=None):
        lines.append(text)
        if page_line is not None:
            where[len(lines)] = page_line

    add('unit %s;' % name)
    add('{$mode Delphi}{$H+}')
    add('{$warn 5024 off}{$warn 5025 off}{$warn 5028 off}{$warn 5089 off}{$warn 5091 off}{$warn 6058 off}')
    add('interface')
    add('implementation')
    all_uses = ['SysUtils', 'Classes', 'StrUtils', 'Math', 'DateUtils'] + fw
    for u in block_uses:
        # A unit of the reader's own app -- App.Schema.Customers, which
        # Norn writes in their project -- is not here to use. What the
        # example needs from it, the page's check comment declares.
        if u.startswith('App.'):
            continue
        if u not in all_uses:
            all_uses.append(u)
    add('uses')
    for k, u in enumerate(all_uses):
        add('  ' + u + (';' if k == len(all_uses) - 1 else ','))
    for s in setup:
        for part in s.split('\n'):
            add(part)
    for no, t in decls:
        add(t, no)
    # Most statements are a handler's body: Req and Result are what a
    # handler has. A page whose examples are something else declares what
    # they use in its check comment.
    add('function DocBlock(Req: TRequest): TResponse;')
    add('begin')
    for no, t in stmts:
        add('  ' + t, no)
    add('end;')
    add('end.')
    return '\n'.join(lines) + '\n', where


# The example programs, compiled as they stand. Two need something another
# step writes first, and are left to the commands that write it.
EXAMPLES_AFTER = {
    'examples/norndemo/verify.lpr': 'needs the schema units ./askr schema writes from a live database',
    'examples/run/rundemo.lpr': 'needs the Pascal ./askr run:demo transpiles from shop.run',
}


def examples(fu, units_dir):
    ok = failed = later = 0
    base = os.path.join(ROOT, 'examples')
    for d, _, files in sorted(os.walk(base)):
        for f in sorted(files):
            if not f.endswith('.lpr'):
                continue
            path = os.path.join(d, f)
            rel = os.path.relpath(path, ROOT)
            if rel in EXAMPLES_AFTER:
                later += 1
                continue
            out = os.path.join(OUT, 'examples', os.path.relpath(d, base))
            os.makedirs(out, exist_ok=True)
            r = subprocess.run([FPC, '-Sh', '-vew', '-FU' + units_dir, '-FE' + out,
                                '-Fu' + d] + fu + [path], capture_output=True, text=True)
            if r.returncode == 0:
                ok += 1
                continue
            failed += 1
            print('FAIL  ' + rel)
            errs = [l for l in r.stdout.splitlines() if MSG.match(l) and 'Warning' not in l]
            for l in (errs or r.stdout.strip().splitlines()[-3:])[:6]:
                print('      ' + l)
    return ok, failed, later


MSG = re.compile(r'^(\S+?\.pas)\((\d+)(?:,(\d+))?\) (Error|Fatal|Warning): (.*)$')


def main():
    fw = framework_units()
    os.makedirs(OUT, exist_ok=True)
    units_dir = os.path.join(OUT, 'units')
    os.makedirs(units_dir, exist_ok=True)
    fu = ['-Fu' + os.path.join(ROOT, 'src', d) for d in UNIT_DIRS]
    pages = ONLY or sorted(
        os.path.join('docs', f) for f in os.listdir(os.path.join(ROOT, 'docs')) if f.endswith('.md'))
    ok = failed = skipped = 0
    for page in pages:
        found, setup = blocks(os.path.join(ROOT, page))
        for idx, (first, body, info, own) in enumerate(found):
            label = '%s:%d' % (page, first)
            if 'nocheck' in info.split():
                skipped += 1
                continue
            # A line that is only "..." is "your code here": a comment.
            body = [re.sub(r'^(\s*)\.\.\.\s*$', r'\1{ ... }', t) for t in body]
            numbered = [(first + k, t) for k, t in enumerate(body)]
            text = '\n'.join(body)
            name = 'DocCheck_%s_%d' % (re.sub(r'\W', '_', os.path.basename(page)[:-3]), idx + 1)
            if UNIT.search(text):
                # A whole unit or program: as it stands.
                src_name = (re.search(r'^(?:unit|program|library)\s+([\w.]+)', text, re.I | re.M).group(1))
                path = os.path.join(OUT, src_name + ('.lpr' if re.search(r'^program', text, re.I | re.M) else '.pas'))
                open(path, 'w').write(text + '\n')
                where = {k + 1: first + k for k in range(len(body))}
            else:
                u, d, s = split(numbered)
                unit, where = unit_text(name, fw, uses_names(u), setup + own, d, s)
                path = os.path.join(OUT, name + '.pas')
                open(path, 'w').write(unit)
            r = subprocess.run([FPC, '-Sh', '-vew', '-FU' + units_dir] + fu + [path],
                               capture_output=True, text=True)
            if r.returncode == 0:
                ok += 1
                continue
            failed += 1
            print('FAIL  ' + label)
            shown = 0
            for line in r.stdout.splitlines():
                m = MSG.match(line)
                if not m or m.group(4) == 'Warning':
                    continue
                base = os.path.basename(m.group(1))
                if base != os.path.basename(path):
                    print('      ' + line)
                else:
                    ln = int(m.group(2))
                    print('      %s:%s: %s' % (page, where.get(ln, '?'), m.group(5)))
                shown += 1
                if shown >= 8:
                    break
            if shown == 0:
                print('      ' + '\n      '.join(r.stdout.strip().splitlines()[-3:]))
    ex_ok = ex_failed = ex_later = 0
    if not ONLY:
        ex_ok, ex_failed, ex_later = examples(fu, units_dir)
    print()
    print('docs:check: %d compiled, %d failed, %d marked nocheck' % (ok, failed, skipped))
    if not ONLY:
        print('examples: %d compiled, %d failed, %d left to the command that prepares them'
              % (ex_ok, ex_failed, ex_later))
    sys.exit(1 if failed or ex_failed else 0)


main()
