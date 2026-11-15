---
name: manuscript-consistency-audit
description: Comb a drafted research manuscript (LaTeX/Overleaf project, or Markdown/Word) for inconsistent terminology and for logical or narrative inconsistencies between the introduction/motivation, results, and discussion, then compile every finding into a self-contained HTML report whose locations link back to the Overleaf project (file:line plus a copyable snippet). Use this whenever someone wants a paper, thesis chapter, preprint, or grant draft checked for inconsistent terms, acronyms, or notation; asks whether the discussion matches the results or whether the intro's hypotheses actually get answered; says they wrote sections in different sittings or with different co-authors; or wants a pre-submission consistency or sanity pass over a .tex project or Overleaf link, even if they never say "audit".
argument-hint: "[path to LaTeX project or main .tex] [Overleaf project URL]"
---

# Manuscript consistency audit

This skill makes two passes over a finished draft and produces one HTML report:

1. **Terminology.** Catch the same thing called by different names, and one name used for different things.
2. **Logic and narrative.** Check whether the introduction's motivation and predictions, the results as reported, and the discussion's interpretation agree with each other.

Drafts written over several sittings drift in predictable ways. A construct gets renamed halfway through. An acronym is defined twice with different expansions. The discussion describes the effect the author expected instead of the one in the results. A hypothesis added late to the introduction never gets a result. Those problems are the targets. Grammar and prose style are out of scope unless they create ambiguity.

The audit is read-only, so never edit the manuscript. Offer fixes after the user has seen the report.

Bundled files live in this skill's base directory (shown when the skill loads; written `<skill-dir>` below):

- `scripts/texmap.py` flattens the project into reading order, tags every line with its source `file:line`, and prints an outline.
- `scripts/term_candidates.py` runs a heuristic scan for terminology variants: hyphenation, capitalization, acronyms, UK/US spelling, reference style, and number formatting.
- `scripts/render_report.py` turns `findings.json` into the HTML report and checks every quote against the source.
- `references/findings-schema.md` is the JSON format the renderer expects. Read it before step 5.

Put intermediate files (flat.txt, candidates, ledger, findings.json) in the session scratchpad directory if there is one, otherwise in a fresh temp directory. Never put them inside the manuscript folder.

## Step 1: Get the source and the Overleaf link

The audit needs two things: the LaTeX source on disk, and the Overleaf project URL so locations can link back.

**Source**, in order of preference:
- A local folder the user names. This could be an Overleaf git clone, a GitHub-synced repo, a Dropbox-synced folder, or an unzipped download.
- A source .zip downloaded from the Overleaf editor's Download menu. Unzip it into a new, empty directory in the scratchpad, never on top of existing files.
- If the user gives only an Overleaf URL: you can't read the Overleaf editor directly. Ask them to download the source .zip, or to clone it in their own terminal with `git clone https://git.overleaf.com/<project-id>`. Overleaf's Git integration needs a paid plan and a Git authentication token, so a credentials prompt there is expected.

**Overleaf URL.** Take it from the user's message (`https://www.overleaf.com/project/<id>`, or a self-hosted Overleaf/Server Pro address). Otherwise read it from `git -C <root> remote -v`: a remote of `https://git.overleaf.com/<id>` means the project is at `https://www.overleaf.com/project/<id>`. If neither is available and the source is a local folder, don't ask. Proceed without it: the report still works, with copy-snippet buttons plus the GitHub and editor links below. Mention in the hand-off that passing the Overleaf URL adds project links. Ask for the URL only when you already have to ask the user for the source.

The audit reads the local copy. If that copy may be behind Overleaf (for example, collaborators edit there), say so in the scope notes. Don't pull or fetch yourself: a pull changes the user's working tree, and a fetch from Overleaf can stall on a credentials prompt.

**Optional extra links**, both of which open a true line-level location:
- GitHub: if `git -C <root> remote get-url origin` points at github.com, set `github_blob_base` to `https://github.com/<owner>/<repo>/blob/<ref>`. Use the commit SHA as `<ref>` when HEAD is pushed (`git branch -r --contains HEAD` prints something) and `git status --porcelain` is empty. Otherwise use the branch name and add a scope note that line numbers reflect the local copy.
- Local editor: when the source is a folder the user keeps (not a scratch unzip) and VS Code or Cursor is installed (`command -v code` / `command -v cursor`, or the app in /Applications), set `editor_scheme` to `vscode` or `cursor`.

Overleaf has no URL that opens a given file at a given line. The report works around this. Each location shows `file:line`. Clicking it opens the Overleaf project in one reused tab and copies a verbatim snippet from that line, so the user can open the file, press Ctrl/Cmd+F and paste. That is why every location needs a short exact quote (step 5).

## Step 2: Map the manuscript

```bash
python3 <skill-dir>/scripts/texmap.py <project-dir-or-main.tex> --out <scratch>/flat.txt
```

It prints:
- the main file it chose
- every file in inclusion order (`\input`, `\include`, `\subfile`, `\import`)
- unresolved includes
- `.tex` files that exist but are never included. These are usually old drafts; leave them out of the audit and mention them in the scope notes.
- the section outline, with `file:line` and word counts

`flat.txt` holds the body in document order. Each line is prefixed `path:line |`, and comments and `\iffalse` blocks are removed. The line numbers are the source file's own, which is what the report links to. If the wrong main file was picked, or the project has a separate supplement, rerun with the explicit `.tex` path.

Read `flat.txt` in full. The point of this audit is comparing, say, the third paragraph of the introduction with the ninth paragraph of the discussion, and skimming misses exactly those. For a long document, read in chunks (Read with offset/limit) and keep notes in the ledger (step 4) as you go.

From the outline, label each part as abstract, introduction/motivation, methods, results, discussion/conclusion, or other (appendix, supplement). Multi-experiment papers often have per-experiment results and short discussions plus a general discussion. Treat each experiment's results and discussion as a unit, and the general discussion as the main discussion.

## Step 3: Terminology pass

Run the heuristic scan:

```bash
python3 <skill-dir>/scripts/term_candidates.py <project-dir-or-main.tex> --out <scratch>/term_candidates.md
```

The output is candidates, not findings. Check each one in context before reporting it. Common false positives:
- Hyphenation is often grammatical. "Long-term memory" (a compound modifier before a noun) and "in the long term" are both correct. Flag only when the same grammatical role is written two ways.
- Many journals want acronyms redefined in the abstract and in figure captions. A repeat definition there is not a problem unless the expansion changes.
- Some house styles use "Figure" at the start of a sentence and "Fig." elsewhere.
- A capitalized word may be a proper name in one place and a common noun in another.

Then do the part a script can't: read for meaning. These are usually the most important terminology findings.
- **Synonym drift for key constructs.** The same condition, group, measure, task, stimulus set, model, or variable gets different names in different sections, e.g. "recall accuracy" / "memory performance" / "hit rate", "participants" / "subjects", "congruent trials" / "matching trials", "the control group" / "the baseline condition". Make a list of the key constructs as Methods defines them, then check what the abstract, introduction, results, figure and table captions, and discussion call each one.
- **One term, two meanings.** For example, "performance" means accuracy in the results but RT in the discussion, or "significant" is used both statistically and colloquially.
- **Notation.** Look for one symbol used for two quantities, two symbols for one quantity, subscripts that change, and symbols used before they are defined. Preamble macros in `flat.txt` show intended notation.
- **Names of studies, experiments, datasets, models and analyses**, e.g. "Experiment 2" vs "the follow-up study", or "Model 3" vs "the full model".
- **Units and formatting of the same quantity**: ms vs s, or different decimal places for the same statistic.

Don't flag a distinction the paper deliberately makes. If two terms are defined as different things, they aren't drift; the problem would be using them interchangeably later.

For each real inconsistency, record:
- every variant with its locations
- which form to keep, and the rule behind the choice: the formally defined form, the form in the title or abstract, or the most frequent one
- why it matters, e.g. whether a reviewer could read the two names as two different things

## Step 4: Logic and narrative pass

Build a ledger before judging anything. Write it to `<scratch>/ledger.md` as you read. It records what each section actually says rather than what you remember it saying, and in a long paper it is the only reliable way to compare sections. Record locations as `file:line` throughout.

- **Motivation**: the gap or problem the introduction claims, and how it characterizes prior work (who found what).
- **Questions, hypotheses and predictions**: each one with its direction and the measure it concerns, labeled H1, H2, ... even if the paper doesn't number them. Include implicit predictions ("we expected...", "if X, then Y should...").
- **Promised contributions and analyses** ("we further test whether...").
- **Design facts that the results depend on**: what was manipulated and what was measured, within- vs between-subjects, N and exclusions, primary vs exploratory analyses, preregistration.
- **Results**: each analysis with its comparison, direction, test statistic, df, p, effect size and CI, and whether it was significant, null or marginal. Note every place the same number appears: text, tables, captions, abstract.
- **Claims in the discussion, abstract and conclusion**: each interpretive claim and the result it rests on.

Then cross-check:

1. **Hypothesis traceability.** Every prediction should be tested in the results and addressed in the discussion. Flag predictions that are never tested. Flag tests that were never motivated, but only if they are presented as confirmatory; a test labeled exploratory is fine. Flag discussion claims about analyses the results never report. Fill in the traceability table; it goes in the report.
2. **Direction and status.** The discussion and abstract should describe each effect with the same direction and significance as the results. Watch for "as predicted" when the prediction was the opposite or never made. Watch for null or marginal results that become effects in the discussion, e.g. a "trend" that later becomes "increased". Watch for "replicates prior work" when the introduction described that work differently.
3. **Numbers.** Compare each quantity everywhere it appears: N, percentages, means, effect sizes, p-values, dfs. Check df against N and exclusions where that is straightforward; t(38) with N = 45 and no stated exclusions deserves a "check" finding. Don't claim a statistic is wrong unless the manuscript itself contains the inputs that show it. Otherwise phrase it as "verify against the analysis output".
4. **Inferential overreach.** Look for causal language from correlational or quasi-experimental designs, absence of evidence treated as evidence of absence, generalization beyond the sample or stimuli, and mechanism claims the design can't separate from alternatives the introduction itself raised.
5. **Internal contradictions.** Find statements in different sections that can't both be true. Examples: prior work described one way in the introduction and another in the discussion; a design detail stated differently in two places; a limitation that undercuts a claim the abstract makes without qualification; "the first study to..." in the introduction while the discussion cites a similar study.
6. **Framing drift.** The introduction motivates the study with theory or problem A, but the discussion interprets the results through B with no bridge between them. The gap the introduction says the study fills isn't what the results address. The conclusion claims a contribution the introduction never set up. This is the typical result of writing the introduction before the data came in and the discussion after.
7. **Pointers.** "As shown in Figure 3" where the caption describes something else. "See Section 4.2" where the label points somewhere that doesn't contain what the sentence promises. "As described above" for something that comes later.

Calibrate before writing anything up:
- A logic finding must quote the text on both sides of the inconsistency. If you can't point to the conflicting passage, it is not a finding.
- Keep "this is wrong" separate from "this needs checking", e.g. numbers that appear only in a figure image you can't see. Use the `Needs author check` category for the second kind.
- Don't flag stylistic preferences, and don't rewrite the argument as you would have made it.
- Fewer solid findings beat a long speculative list. Still, don't drop a real problem because it is awkward to raise.

Severity:
- **high**: a reader or reviewer would be misled or would catch the contradiction.
- **medium**: a gap that weakens the paper, such as an untested hypothesis, overclaiming, or name drift for key constructs.
- **low**: consistency polish.

`references/findings-schema.md` has examples of each.

## Step 5: Write findings.json and render

Read `<skill-dir>/references/findings-schema.md`, write `<scratch>/findings.json`, then run:

```bash
python3 <skill-dir>/scripts/render_report.py <scratch>/findings.json --out <report-path>
```

Every location needs a `quote`: a short verbatim span (about 4 to 12 words) copied from that exact source line. Prefer plain prose without LaTeX commands, pick something unique within the file, and copy it from `flat.txt`, not from memory. The renderer:
- checks each quote against the file
- fixes line numbers that are off by a few lines, or quotes found elsewhere in the same file, and prints each correction
- exits 1 and lists any quote it can't find

Fix those and rerun. Don't hand over a report with unverified locations. For terminology variants you can omit `locations` and the renderer will find every occurrence of `form` itself.

**Report path.** Use the user's location if they named one. Otherwise save `manuscript-audit-<YYYY-MM-DD>.html` in the current working directory, unless that directory is inside the manuscript's repo or a synced folder (Overleaf git, GitHub sync, Dropbox). In that case save it one level above the project root, so the report doesn't get committed or synced into the Overleaf project. Then open it with `open <path>` (macOS) or `xdg-open <path>` (Linux).

## Step 6: Hand off

Keep the reply short. The report is the deliverable.
- The report's full path.
- Counts by severity for each pass.
- The 3 to 5 most serious findings, one sentence each.
- One sentence on how the links work: Overleaf can't link to a line, so a click opens the project and copies the snippet for Ctrl/Cmd+F.
- Anything you couldn't check (the scope notes).
- An offer to apply the terminology fixes, or draft rewrites for the logic findings, once they've chosen which forms to keep.

The report contains unpublished manuscript text. Don't upload or publish it anywhere, including as a hosted page or artifact, unless the user asks.

## Other formats

- **Markdown or plain text**: pass the file to texmap.py and term_candidates.py directly. Lines are numbered as-is and `#` headings form the outline.
- **Word (.docx)**: convert with `pandoc input.docx -t gfm --wrap=none -o <scratch>/manuscript.md` and audit that. Set `source_root` to the scratch directory. Tell the user the line numbers refer to the converted file and the snippets are for Word's Find.
- **Google Docs**: ask for a .docx export.

Overleaf links only apply to Overleaf projects. For everything else, the copy-snippet buttons are the way back to the text.

## Long documents

For a thesis or anything over roughly 25k words, the terminology scan and the per-chapter notes can go to a subagent. Do the logic pass yourself, because it depends on holding the whole argument in one context, and a summary of a chapter loses exactly the details that contradict each other.
