#!/usr/bin/env python3
"""Detect lines damaged by the 1.5.0 CRLF bug (trailing "r" stripped) and broken inline Python.

Checks:
  1. vs baseline 1.4.0 tarball: a current line equal to a baseline line with trailing "r"s removed.
  2. heuristic: a line-final token that only ever appears line-final, while token+"r"/"rr" exists.
  3. every `python3 -c "..."` / `python3 - <<EOF` snippet must compile (bash expansions -> X).
"""
import re
import sys
import tarfile
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BASELINE = ROOT / "tests" / "baseline" / "cecp-panel-1.4.0-beta.tar.gz"
IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def shell_files():
    files = [ROOT / "cecp-panel"]
    files += sorted((ROOT / "lib").glob("*.sh"))
    files += sorted(ROOT.glob("*.sh"))
    files += sorted((ROOT / "tests").rglob("*.sh"))
    return files


def text_files():
    files = shell_files()
    files += sorted((ROOT / "templates").rglob("*"))
    return [f for f in files if f.is_file() and f.suffix not in (".gz", ".png")]


def rel(p):
    return p.relative_to(ROOT).as_posix()


def read(p):
    return p.read_text(encoding="utf-8", errors="replace").replace("\r\n", "\n")


def load_baseline():
    out = {}
    with tarfile.open(BASELINE) as t:
        for m in t.getmembers():
            if not m.isfile() or "/" not in m.name:
                continue
            try:
                data = t.extractfile(m).read().decode("utf-8")
            except UnicodeDecodeError:
                continue
            out[m.name.split("/", 1)[1]] = data.replace("\r\n", "\n").split("\n")
    return out


def check_baseline(files, problems):
    base = load_baseline()
    for f in files:
        old = base.get(rel(f))
        if old is None:
            continue
        old_set = set(old)
        stripped = {l.rstrip("r"): l for l in old if l.endswith("r")}
        for n, line in enumerate(read(f).split("\n"), 1):
            if line not in old_set and line in stripped:
                problems.append(f"{rel(f)}:{n}: truncated line (1.4.0 had {stripped[line].strip()[-40:]!r})")


def check_heuristic(files, problems):
    texts = {f: read(f) for f in files}
    total = Counter()
    final = Counter()
    for t in texts.values():
        for line in t.split("\n"):
            toks = IDENT.findall(line)
            total.update(toks)
            m = re.search(r"([A-Za-z_][A-Za-z0-9_]*)\s*$", line)
            if m:
                final[m.group(1)] += 1
    for f, t in texts.items():
        for n, line in enumerate(t.split("\n"), 1):
            m = re.search(r"([A-Za-z_][A-Za-z0-9_]*)\s*$", line)
            if not m:
                continue
            tok = m.group(1)
            if len(tok) < 2 or total[tok] != final[tok]:
                continue
            if total[tok + "r"] or total[tok + "rr"]:
                problems.append(f"{rel(f)}:{n}: line ends with {tok!r} but {tok}r exists — truncated?")


# --- bash string expansion (just enough to recover the Python source) -------------

def _skip_cmdsub(s, i):
    depth = 1
    while i < len(s):
        c = s[i]
        if c == "\\":
            i += 2
            continue
        if c == "'":
            j = s.find("'", i + 1)
            i = len(s) if j < 0 else j + 1
            continue
        if c == '"':
            _, i = _read_dq(s, i)
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return i


_EXPANSIONS = [0]


def _expand_dollar(s, i, out):
    _EXPANSIONS[0] += 1
    nxt = s[i + 1] if i + 1 < len(s) else ""
    if nxt == "(":
        out.append("X")
        return _skip_cmdsub(s, i + 2)
    if nxt == "{":
        j = s.find("}", i)
        out.append("X")
        return len(s) if j < 0 else j + 1
    m = re.match(r"\$([A-Za-z_][A-Za-z0-9_]*|[0-9@*#?])", s[i:])
    if m:
        out.append("X")
        return i + m.end()
    _EXPANSIONS[0] -= 1
    out.append("$")
    return i + 1


def _read_dq(s, i):
    i += 1
    out = []
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            n = s[i + 1]
            if n in '"\\$`':
                out.append(n)
                i += 2
                continue
            if n == "\n":
                i += 2
                continue
            out.append(c)
            i += 1
            continue
        if c == '"':
            return "".join(out), i + 1
        if c == "$":
            i = _expand_dollar(s, i, out)
            continue
        out.append(c)
        i += 1
    return None, i


def _expand_heredoc(body):
    out = []
    i = 0
    while i < len(body):
        c = body[i]
        if c == "\\" and i + 1 < len(body) and body[i + 1] in "\\$`":
            out.append(body[i + 1])
            i += 2
            continue
        if c == "$":
            i = _expand_dollar(body, i, out)
            continue
        out.append(c)
        i += 1
    return "".join(out)


def python_snippets(text):
    """Yield (line, code, interpolated) for inline python; interpolated = bash expanded vars into it."""
    for m in re.finditer(r"\bpython3? -c\s+", text):
        i = m.end()
        if i >= len(text):
            continue
        _EXPANSIONS[0] = 0
        if text[i] == '"':
            code, _ = _read_dq(text, i)
        elif text[i] == "'":
            j = text.find("'", i + 1)
            code = text[i + 1:j] if j > 0 else None
        else:
            continue
        if code is not None:
            yield text.count("\n", 0, m.start()) + 1, code, _EXPANSIONS[0] > 0
    for m in re.finditer(r"\bpython3?\b[^\n]*?<<(-?)\s*(['\"]?)(\w+)\2[^\n]*\n", text):
        strip_tabs, quoted, delim = m.group(1), m.group(2), m.group(3)
        lines = []
        for line in text[m.end():].split("\n"):
            if (line.lstrip("\t") if strip_tabs else line) == delim:
                break
            lines.append(line.lstrip("\t") if strip_tabs else line)
        body = "\n".join(lines)
        if quoted:
            yield text.count("\n", 0, m.start()) + 1, body, False
        else:
            _EXPANSIONS[0] = 0
            code = _expand_heredoc(body)
            yield text.count("\n", 0, m.start()) + 1, code, _EXPANSIONS[0] > 0


def check_python(files, problems):
    for f in files:
        for line_no, code, interpolated in python_snippets(read(f)):
            try:
                compile(code, f"{rel(f)}:{line_no}", "exec")
            except SyntaxError as e:
                problems.append(f"{rel(f)}:{line_no}: inline python does not compile: {e.msg}")
            if interpolated:
                problems.append(f"{rel(f)}:{line_no}: bash variables interpolated into python code "
                                "(injection risk) — pass them via sys.argv")


def main():
    problems = []
    check_baseline(text_files(), problems)
    check_heuristic(shell_files(), problems)
    check_python(shell_files(), problems)
    for p in sorted(set(problems)):
        print(p)
    if problems:
        print(f"check_truncation: {len(set(problems))} problem(s)", file=sys.stderr)
        return 1
    print("check_truncation: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
