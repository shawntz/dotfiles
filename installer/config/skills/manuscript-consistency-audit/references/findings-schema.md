# findings.json

The input to `scripts/render_report.py`. One JSON object with four keys: `meta`, `terminology`, `logic` and `traceability`.

JSON escaping matters here: a LaTeX backslash inside a string has to be written `\\`. Quotes made of plain prose avoid most of that, and they search better in Overleaf too.

In `summary`, `explanation`, `recommendation` and `note`, you can use `` `code` ``, `**bold**`, `*italic*`, and blank lines between paragraphs. Everything else is escaped.

## meta

```json
"meta": {
  "title": "Paper title, from \\title",
  "source_root": "/absolute/path/to/project",
  "main_file": "main.tex",
  "overleaf_url": "https://www.overleaf.com/project/0123456789abcdef01234567",
  "github_blob_base": "https://github.com/owner/repo/blob/3f2c1ab",
  "editor_scheme": "cursor",
  "generated": "2026-10-27",
  "summary": "Two to four sentences: the overall state of the draft and the most serious problems.",
  "scope_notes": [
    "supplement.tex is a separate root document and was not audited.",
    "Figure images were not inspected, so values shown only in figures are unverified."
  ]
}
```

- `source_root` (required): the renderer checks every quote against files under this directory.
- `main_file`: path relative to `source_root`. It gives each location a section breadcrumb and lets terminology variants be located automatically.
- `overleaf_url`, `github_blob_base`, `editor_scheme`: each is optional and may be `null`. `editor_scheme` takes `vscode`, `vscode-insiders`, `cursor` or `windsurf`.

## Location

```json
{"file": "sections/results.tex", "line": 42, "quote": "the effect was larger under high load", "role": "Result", "note": "optional"}
```

- `file`: relative to `source_root`. Use the path exactly as texmap.py prints it.
- `line`: 1-based line in that file. This is the number on the left of `flat.txt`, not a position in flat.txt.
- `quote`: 4 to 12 words copied verbatim from that line. Pick a span that is unique in the file. It gets copied to the clipboard for Overleaf's search, and the renderer uses it to check and correct the line number.
- `role`: optional short label, e.g. `Prediction`, `Result`, `Interpretation`, `Abstract`, `Table 2`, `Methods`.

## Terminology finding

```json
{
  "id": "T1",
  "severity": "medium",
  "category": "Synonym drift",
  "title": "\"participants\" vs \"subjects\"",
  "explanation": "Why this reads as an inconsistency, and whether a reviewer could take the two names for different things.",
  "recommendation": "Use \"participants\" throughout (the form used in the abstract and Methods).",
  "variants": [
    {"form": "participants", "preferred": true},
    {"form": "subjects"},
    {"form": "long term", "pattern": "long\\s+term(?=\\s+(?:retention|memory))"},
    {"form": "recall accuracy", "locations": [{"file": "sections/discussion.tex", "line": 12, "quote": "recall accuracy dropped"}]}
  ]
}
```

- A variant without `locations` is located automatically: every whole-word, case-sensitive match of `form` in the document body. Set `"case_sensitive": false` or give a Python regex in `pattern` to change the matching.
- Give explicit `locations` when automatic matching would over-match, e.g. "subjects" used for both people and topics. Also give them for meaning-level variants that only make sense in context.
- `count` is optional. It defaults to the number of locations.
- A terminology finding can use `locations` instead of `variants`, e.g. for an acronym defined in three places or a symbol given two meanings.

Suggested categories, in this order: `Synonym drift`, `One term, two meanings`, `Acronym`, `Notation`, `Names of conditions, measures, models`, `Hyphenation and spelling`, `Capitalization`, `Cross-reference style`, `Number and statistics format`.

## Logic finding

```json
{
  "id": "L1",
  "severity": "high",
  "category": "Result–interpretation mismatch",
  "title": "Discussion reverses the direction of the load effect",
  "explanation": "The introduction predicts a smaller benefit under high load (H2), and the Results report a larger one. The discussion still says the benefit was reduced, as predicted.",
  "recommendation": "Report the observed direction and treat H2 as unsupported, or explain the reversal.",
  "locations": [
    {"file": "sections/intro.tex", "line": 8, "quote": "this benefit would be smaller under high load", "role": "Prediction"},
    {"file": "sections/results.tex", "line": 3, "quote": "the practice effect was larger, not smaller", "role": "Result"},
    {"file": "sections/discussion.tex", "line": 2, "quote": "this benefit was reduced under high load", "role": "Interpretation"}
  ]
}
```

Cite both sides of every inconsistency. Suggested categories: `Result–interpretation mismatch`, `Hypothesis not tested`, `Unmotivated analysis`, `Number mismatch`, `Overclaiming`, `Internal contradiction`, `Framing drift`, `Cross-reference error`, `Needs author check`.

## Traceability row

```json
{
  "item": "H2: smaller practice benefit under high load",
  "intro": {"file": "sections/intro.tex", "line": 8, "quote": "smaller under high load"},
  "results": {"file": "sections/results.tex", "line": 3, "quote": "larger, not smaller"},
  "discussion": {"file": "sections/discussion.tex", "line": 2, "quote": "reduced under high load"},
  "status": "mismatch",
  "finding": "L1",
  "note": "optional"
}
```

Use `null` for a column with no corresponding text. Statuses `consistent`, `ok`, `supported` and `addressed` render green. `partial`, `unclear`, `weak` and `check` render amber. Anything else, such as `mismatch`, `untested` or `not discussed`, renders red. `finding` links the row to a finding card.

## Severity

- `high`: a reader or reviewer would be misled or would spot the contradiction. Examples: a claim that contradicts the reported result, numbers that disagree, a key term used with two meanings, an acronym with two different expansions.
- `medium`: a gap that weakens the paper. Examples: a prediction that is never tested, a confirmatory test with no motivation, overclaiming, inconsistent names for key constructs, undefined acronyms.
- `low`: consistency polish, such as hyphenation, UK/US spelling, Fig./Figure, or p-value formatting.
