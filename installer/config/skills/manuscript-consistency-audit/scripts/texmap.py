#!/usr/bin/env python3
"""Flatten a LaTeX project into reading order, keeping every line's source file and line number.

Usage:
    python3 texmap.py <project_dir | main.tex> [--out flat.txt] [--root DIR]

Prints the main file it chose, the include tree, unresolved includes, .tex files that are
never included, and a section outline with file:line and approximate word counts.

With --out, writes the document as LaTeX would read it, one source line per output line,
each prefixed "path/relative/to/root.tex:LINE | ". Comments, \\iffalse...\\fi blocks and
comment environments are dropped. From the preamble only definitions are kept
(\\newcommand, \\newacronym, \\title, ...) because they can carry terminology and notation.

Markdown or plain-text input is passed through line by line; Markdown headings become the outline.

Importable: flatten(path, root=None) -> Document
"""
from __future__ import annotations

import argparse
import bisect
import os
import re
import sys
from dataclasses import dataclass, field

INCLUDE_RE = re.compile(
    r"\\(input|include|subfile|import|subimport|inputfrom|subinputfrom|includefrom|subincludefrom)\*?"
    r"\s*\{([^{}]*)\}(?:\s*\{([^{}]*)\})?"
)
TWO_ARG_INCLUDES = {"import", "subimport", "inputfrom", "subinputfrom", "includefrom", "subincludefrom"}
BARE_INPUT_RE = re.compile(r"\\input\s+([^\s{}\\%]+)")
SECTION_RE = re.compile(
    r"\\(part|chapter|section|subsection|subsubsection|paragraph)\*?\s*(?:\[[^\]]*\])?\s*(?=\{)"
)
LEVELS = {"part": 0, "chapter": 1, "section": 2, "subsection": 3, "subsubsection": 4, "paragraph": 5}
PREAMBLE_KEEP_RE = re.compile(
    r"\\(newcommand|renewcommand|providecommand|DeclareMathOperator|def|newacronym|"
    r"newglossaryentry|DeclareAcronym|acrodef|newabbreviation|title)(?![A-Za-z@])"
)
IF_TOKEN_RE = re.compile(r"\\(if[A-Za-z@]*|fi)(?![A-Za-z@])")
MD_HEADING_RE = re.compile(r"^(#{1,6})\s+(.*\S)")
SKIP_DIRS = {".git", "node_modules", "__pycache__", ".venv"}


def strip_comment(line: str) -> str:
    """Remove a LaTeX comment, respecting \\% and \\\\%."""
    out, i = [], 0
    while i < len(line):
        c = line[i]
        if c == "\\":
            out.append(line[i : i + 2])
            i += 2
            continue
        if c == "%":
            break
        out.append(c)
        i += 1
    return "".join(out)


def brace_content(s: str, i: int) -> str:
    """Content of the brace group starting at s[i] == '{' (to end of string if unbalanced)."""
    depth, j, out = 0, i, []
    while j < len(s):
        c = s[j]
        if c == "\\" and j + 1 < len(s):
            out.append(s[j : j + 2])
            j += 2
            continue
        if c == "{":
            depth += 1
            if depth > 1:
                out.append(c)
        elif c == "}":
            depth -= 1
            if depth == 0:
                return "".join(out)
            out.append(c)
        else:
            out.append(c)
        j += 1
    return "".join(out)


def plain_text(s: str) -> str:
    """Rough LaTeX-to-prose: drop citations, labels, math and commands; keep command arguments."""
    s = re.sub(r"\\\$", " ", s)
    s = re.sub(
        r"\\(?:cite[a-zA-Z]*|nocite|label|url|includegraphics|bibliography[a-zA-Z]*|usepackage|"
        r"documentclass|begin|end|input|include|subfile|vspace|hspace|setlength|"
        r"ac[fslp]*|Ac[fslp]*|acrshort|acrlong|acrfull|[gG]ls[a-z]*|GLS[a-z]*)\*?(?:\[[^\]]*\])*\{[^{}]*\}",
        " ",
        s,
    )
    s = re.sub(r"\\(?:ref|cref|Cref|autoref|eqref|pageref|nameref)\*?\{[^{}]*\}", " 0 ", s)
    s = re.sub(r"\$[^$]*\$", " ", s)
    s = re.sub(r"\\\(.*?\\\)", " ", s)
    s = re.sub(r"\\\[.*?\\\]", " ", s)
    s = re.sub(r"\\([%&#_])", r"\1", s)
    s = re.sub(r"\\[A-Za-z@]+\*?", " ", s)
    s = re.sub(r"\\.", " ", s)
    s = s.replace("~", " ").replace("{", " ").replace("}", " ")
    return re.sub(r"\s+", " ", s).strip()


def count_words(s: str) -> int:
    return len(re.findall(r"[A-Za-z]+(?:['-][A-Za-z]+)*", plain_text(s)))


@dataclass
class Line:
    file: str
    num: int
    text: str  # comment-stripped source text
    preamble: bool = False
    heading: str | None = None  # set when a section starts on this line
    section: str = ""  # breadcrumb of enclosing sections


@dataclass
class Section:
    level: int
    title: str
    file: str
    num: int
    words: int = 0


@dataclass
class Document:
    root: str
    main: str
    title: str | None = None
    lines: list[Line] = field(default_factory=list)
    sections: list[Section] = field(default_factory=list)
    files: list[tuple[str, int, int]] = field(default_factory=list)  # (relpath, depth, n_lines)
    unresolved: list[tuple[str, int, str]] = field(default_factory=list)
    not_included: list[str] = field(default_factory=list)
    other_roots: list[str] = field(default_factory=list)
    _index: dict[str, tuple[list[int], list[str]]] | None = None

    def body(self) -> list[Line]:
        return [l for l in self.lines if not l.preamble]

    def section_of(self, file: str, num: int) -> str:
        """Breadcrumb of the section containing file:num ('' if the line isn't in the document)."""
        if self._index is None:
            idx: dict[str, tuple[list[int], list[str]]] = {}
            for l in self.lines:
                nums, secs = idx.setdefault(l.file, ([], []))
                nums.append(l.num)
                secs.append(l.section)
            self._index = idx
        if file not in self._index:
            return ""
        nums, secs = self._index[file]
        k = bisect.bisect_right(nums, num) - 1
        return secs[k] if k >= 0 else ""


def _read(path: str) -> list[str]:
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read().splitlines()


def _is_root_doc(path: str) -> bool:
    body = "\n".join(strip_comment(l) for l in _read(path))
    if not re.search(r"\\documentclass", body) or "\\begin{document}" not in body:
        return False
    return not re.search(r"\\documentclass\s*(\[[^\]]*\])?\s*\{(subfiles|standalone)\}", body)


def _all_tex(root: str) -> list[str]:
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and not d.startswith(".")]
        found += [os.path.join(dirpath, f) for f in filenames if f.endswith(".tex")]
    return sorted(found)


def find_main(root: str) -> tuple[str, list[str]]:
    roots = [p for p in _all_tex(root) if _is_root_doc(p)]
    if not roots:
        sys.exit(f"texmap: no .tex file with \\documentclass and \\begin{{document}} under {root}")

    def rank(p: str):
        rel = os.path.relpath(p, root)
        return (os.path.basename(p) != "main.tex", rel.count(os.sep), -os.path.getsize(p))

    roots.sort(key=rank)
    return roots[0], roots[1:]


class _Flattener:
    def __init__(self, root: str, main: str):
        self.root = root
        self.main_dir = os.path.dirname(main)
        self.doc = Document(root=root, main=self._rel(main))
        self.visited: set[str] = set()
        self.in_preamble = True
        self.done = False
        self.stack: list[Section] = []

    def _rel(self, p: str) -> str:
        return os.path.relpath(p, self.root)

    def _resolve(self, cmd: str, a: str, b: str | None, cur_dir: str) -> str | None:
        if cmd in TWO_ARG_INCLUDES:
            if b is None:
                return None
            name = os.path.join(a.strip(), b.strip())
            bases = [cur_dir] if cmd.startswith("sub") else [self.main_dir, self.root]
        else:
            name = a.strip()
            bases = [self.main_dir, cur_dir, self.root]
        for base in dict.fromkeys(bases):
            p = os.path.normpath(os.path.join(base, name))
            for cand in (p, p + ".tex"):
                if os.path.isfile(cand):
                    return cand
        return None

    def _open_section(self, level: int, title: str, rel: str, num: int) -> Section:
        sec = Section(level, title or "(untitled)", rel, num)
        self.doc.sections.append(sec)
        while self.stack and self.stack[-1].level >= level:
            self.stack.pop()
        self.stack.append(sec)
        return sec

    def _emit(self, rel: str, num: int, text: str, heading: str | None = None):
        if not self.in_preamble and self.stack:
            self.stack[-1].words += count_words(text)
        crumb = " › ".join(s.title for s in self.stack)
        self.doc.lines.append(Line(rel, num, text.rstrip(), self.in_preamble, heading, crumb))

    def run_markdown(self, path: str):
        rel = self._rel(path)
        self.in_preamble = False
        raw = _read(path)
        self.doc.files.append((rel, 0, len(raw)))
        for i, line in enumerate(raw, 1):
            m = MD_HEADING_RE.match(line)
            heading = None
            if m:
                heading = m.group(2)
                self._open_section(len(m.group(1)), heading, rel, i)
            self._emit(rel, i, line, heading)

    def process(self, path: str, depth: int, mode: str):
        """mode: 'main', 'input' (\\input/\\include/\\import), or 'subfile'."""
        path = os.path.abspath(path)
        if path in self.visited:
            return
        self.visited.add(path)
        rel = self._rel(path)
        raw = _read(path)
        self.doc.files.append((rel, depth, len(raw)))
        cur_dir = os.path.dirname(path)
        skip_if = 0
        in_comment_env = False
        sub_active = mode != "subfile"

        for num, rawline in enumerate(raw, 1):
            if self.done:
                return
            if not rawline.strip():
                if sub_active and not self.in_preamble and not in_comment_env and not skip_if:
                    self._emit(rel, num, "")  # paragraph break
                continue
            s = strip_comment(rawline)
            if not s.strip():
                continue  # comment-only line: no paragraph break in LaTeX either

            if in_comment_env:
                m = re.search(r"\\end\{comment\}", s)
                if not m:
                    continue
                in_comment_env = False
                s = s[m.end() :]
            if skip_if:
                rest = None
                for m in IF_TOKEN_RE.finditer(s):
                    tok = m.group(1)
                    if tok == "fi":
                        skip_if -= 1
                        if skip_if == 0:
                            rest = s[m.end() :]
                            break
                    elif tok != "ifthenelse":
                        skip_if += 1
                if rest is None:
                    continue
                s = rest
            m = re.search(r"\\iffalse(?![A-Za-z@])", s)
            if m:
                before, after, depth_if = s[: m.start()], "", 1
                for mm in IF_TOKEN_RE.finditer(s, m.end()):
                    tok = mm.group(1)
                    if tok == "fi":
                        depth_if -= 1
                        if depth_if == 0:
                            after = s[mm.end() :]
                            break
                    elif tok != "ifthenelse":
                        depth_if += 1
                skip_if = depth_if
                s = before + after
            m = re.search(r"\\begin\{comment\}", s)
            if m:
                end = re.search(r"\\end\{comment\}", s[m.end() :])
                if end:
                    s = s[: m.start()] + s[m.end() + end.end() :]
                else:
                    s, in_comment_env = s[: m.start()], True

            if not sub_active:
                if "\\begin{document}" in s:
                    sub_active = True
                continue
            if mode == "subfile" and "\\end{document}" in s:
                s = s.split("\\end{document}")[0]
                if s.strip():
                    self._emit(rel, num, s)
                return
            if self.in_preamble and "\\begin{document}" in s:
                self.in_preamble = False
                s = s.split("\\begin{document}", 1)[1]
            if mode != "subfile" and "\\end{document}" in s:
                s = s.split("\\end{document}")[0]
                self.done = True
            if not s.strip():
                continue

            if self.in_preamble:
                tm = re.search(r"\\title\s*(?:\[[^\]]*\])?\s*(?=\{)", s)
                if tm and self.doc.title is None:
                    self.doc.title = plain_text(brace_content(s, tm.end())) or None
                if PREAMBLE_KEEP_RE.search(s):
                    self._emit(rel, num, s)
            else:
                heading = None
                sm = SECTION_RE.search(s)
                if sm:
                    title = plain_text(brace_content(s, sm.end()))
                    heading = title
                    self._open_section(LEVELS[sm.group(1)], title, rel, num)
                elif re.search(r"\\begin\{abstract\}|\\abstract\s*\{", s):
                    heading = "Abstract"
                    self._open_section(2, heading, rel, num)
                elif re.search(r"\\appendix(?![A-Za-z@])", s):
                    heading = "Appendix"
                    self._open_section(1, heading, rel, num)
                elif re.search(r"\\(bibliography|printbibliography)(?![A-Za-z@])", s):
                    heading = "References"
                    self._open_section(1, heading, rel, num)
                self._emit(rel, num, s, heading)

            targets = [(m.group(1), m.group(2), m.group(3)) for m in INCLUDE_RE.finditer(s)]
            targets += [("input", m.group(1), None) for m in BARE_INPUT_RE.finditer(s)]
            for cmd, a, b in targets:
                child = self._resolve(cmd, a, b if cmd in TWO_ARG_INCLUDES else None, cur_dir)
                if child is None:
                    self.doc.unresolved.append((rel, num, f"\\{cmd}{{{a}}}" + (f"{{{b}}}" if b else "")))
                    continue
                if child.endswith(".tex") or "." not in os.path.basename(child):
                    self.process(child, depth + 1, "subfile" if cmd == "subfile" else "input")
            if self.done:
                return


def flatten(path: str, root: str | None = None) -> Document:
    path = os.path.abspath(os.path.expanduser(path))
    if os.path.isdir(path):
        root = os.path.abspath(root or path)
        main, others = find_main(path)
    else:
        main, others = path, []
        root = os.path.abspath(root or os.path.dirname(path))
    fl = _Flattener(root, main)
    fl.doc.other_roots = [os.path.relpath(p, root) for p in others]
    if main.endswith(".tex"):
        fl.process(main, 0, "main")
        if fl.in_preamble:  # no \begin{document}: treat as a fragment
            fl.in_preamble = False
            fl.visited.clear()
            fl.doc.lines.clear()
            fl.doc.files.clear()
            fl.process(main, 0, "input")
        included = {os.path.abspath(os.path.join(root, f)) for f, _, _ in fl.doc.files}
        fl.doc.not_included = [
            os.path.relpath(p, root) for p in _all_tex(root) if os.path.abspath(p) not in included
        ]
    else:
        fl.run_markdown(main)
    return fl.doc


def write_flat(doc: Document, out: str):
    with open(out, "w", encoding="utf-8") as f:
        started_pre = started_body = False
        blank = False
        for L in doc.lines:
            if L.preamble and not started_pre:
                f.write("==== PREAMBLE (definitions only) ====\n")
                started_pre = True
            if not L.preamble and not started_body:
                f.write("\n==== BODY ====\n")
                started_body = True
            if L.heading:
                f.write(f"\n==== {L.heading}  [{L.file}:{L.num}] ====\n")
                blank = False
            if not L.text.strip():
                if not blank:
                    f.write("\n")
                    blank = True
                continue
            blank = False
            f.write(f"{L.file}:{L.num} | {L.text}\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("path", help="project directory, main .tex file, or a .md/.txt manuscript")
    ap.add_argument("--out", help="write the flattened, line-tagged document here")
    ap.add_argument("--root", help="project root that file paths are reported relative to")
    args = ap.parse_args()

    doc = flatten(args.path, args.root)
    print(f"Root: {doc.root}")
    print(f"Main file: {doc.main}")
    if doc.title:
        print(f"Title: {doc.title}")
    if doc.other_roots:
        print("Other root documents (not audited unless passed explicitly): " + ", ".join(doc.other_roots))
    print("\nFiles in inclusion order:")
    for rel, depth, n in doc.files:
        print(f"  {'  ' * depth}{rel} ({n} lines)")
    if doc.unresolved:
        print("\nUnresolved includes:")
        for rel, num, target in doc.unresolved:
            print(f"  {rel}:{num}  {target}")
    if doc.not_included:
        print("\n.tex files never included (old drafts or figure code; not part of the document):")
        for rel in doc.not_included:
            print(f"  {rel}")
    print("\nOutline:")
    base = min((s.level for s in doc.sections), default=0)
    for s in doc.sections:
        print(f"  {'  ' * (s.level - base)}[{s.file}:{s.num}] {s.title} (~{s.words} words)")
    total = sum(count_words(l.text) for l in doc.body())
    print(f"\nBody words: ~{total}")
    if args.out:
        write_flat(doc, args.out)
        print(f"Flattened document: {args.out} ({len(doc.lines)} source lines)")


if __name__ == "__main__":
    main()
