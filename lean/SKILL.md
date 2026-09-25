---
name: lean
description: Lean 4 and Mathlib in this container -- prebuilt, nothing to install. Use for any Lean, Lake, Mathlib or formal-proof task, before running lake or elan.
---

# Lean 4 in this container

Everything is already installed and built. Do not install elan, download a
toolchain, or build Mathlib:

- `lean`, `lake`, `elan` on PATH; toolchains under `/opt/elan`. The default
  one is the toolchain Mathlib was built with.
- `/opt/lean`: the Lean image, mounted read-only. `/opt/lean/project` is a Lake
  project with Mathlib and the Lean REPL fully built; its `lean-toolchain` and
  `lake-manifest.json` say which versions. If `/opt/lean` is empty, this session
  was started without the Lean image: ask the user to restart it with
  `claude-box lean`, which builds the image the first time. Do not install Lean
  yourself.
- Mathlib's source, for reading and `rg`:
  `/opt/lean/project/.lake/packages/mathlib/Mathlib`.
- `loogle`: Mathlib search by name, type pattern or subterm, local and
  unlimited (see *Finding lemmas*).
- Two Claude Code plugins, off until a project turns them on:
  `lean-lsp@claude-box` (the lean-lsp-mcp server, whose tools are named
  `lean_*`) and `lean4@claude-box` (lean4-skills: `/lean4:prove`,
  `/lean4:autoprove`, `/lean4:formalize`, `/lean4:autoformalize`, ...).

## Setting up

Run `lean-init` in the session's working directory. It is idempotent:

- A directory with no lakefile becomes a Lake project on the prebuilt Mathlib:
  `lakefile.toml`, `lean-toolchain`, `lake-manifest.json`, a `Proof.lean`, and
  `.lake/packages` linked to the built packages. `import Mathlib` works at once.
- An existing Lake project keeps its own lakefile. If it pins a different
  Mathlib, fetch that one's build with `lake exe cache get`. Never build Mathlib
  from source: it takes hours.
- Either way it enables both plugins in `.claude/settings.local.json`, for that
  exact directory only, so run it in the directory the session was started in,
  not a subdirectory.

The plugins load in the *next* session started here, or in this one after the
user types `/reload-plugins`. You cannot run that command yourself, so say it
once, in one line, and carry on with the Bash loop below. Do not wait for it.
`lean_*` tools in your tool list mean the plugins are already loaded.

## The loop

Put the formal statement in a file with `sorry`, and check that the statement
elaborates before trying to prove it. Then iterate:

```sh
lake env lean Proof.lean      # any file: errors, warnings, goals left at sorry
lake build                    # Proof.lean and Proof/**, when files import each other
```

`import Mathlib` takes a few seconds to load; that is expected. Leave
`sorry` in the steps you have not reached, and read the errors for the rest.
Inline probes are cheap: `#check`, `#eval`, `example : ... := by exact?`.

Once `lean-lsp` is loaded, prefer its tools to recompiling the file:
`lean_goal` (the goal at a line), `lean_diagnostic_messages`,
`lean_multi_attempt` (try several tactics at one spot and see which one closes
the goal), `lean_local_search` (fast, local, unlimited), `lean_loogle` (local
and unlimited in a project on the prebuilt Mathlib), `lean_hover_info`, and
`lean_verify` at the end. `lean_leansearch`, `lean_leanfinder`,
`lean_state_search` and `lean_hammer_premise` are remote and rate-limited, so
use them after local search has failed.

## Finding lemmas

- Try a name first. Mathlib's names are predictable: `Nat.succ_le_iff`,
  `mul_pos`, `Finset.sum_range_succ`. Check a guess with `#check`.
- `rg -n 'theorem .*sq_nonneg' /opt/lean/project/.lake/packages/mathlib/Mathlib`
- By the shape of the statement, with Loogle (`lean_loogle`, or `loogle` from
  Bash): `loogle 'Real.sqrt ?a * Real.sqrt ?a'` (a subterm),
  `loogle '⊢ _ < _ → tsum _ < tsum _'` (the conclusion, hypotheses in any
  order), `loogle '"succ_le"'` (a name substring), `loogle 'Finset.sum, _ ^ 2'`
  (every filter at once). A `loogle` call loads Mathlib first, which takes
  seconds, so give it several queries at once.
- At a goal: `exact?`, `apply?`, `rw?`, `simp?` and `hint` search for you.
- Automation worth trying before a manual proof: `omega` (ℕ/ℤ linear),
  `decide`, `norm_num`, `simp`, `ring`, `field_simp`, `linarith`, `nlinarith`
  (give it products of hypotheses), `positivity`, `gcongr`, `aesop`, `grind`,
  and `interval_cases` or `fin_cases` for finite case splits.

## Before calling a proof finished

- The statement must say what the problem says. Watch for the usual traps: ℕ
  subtraction and division truncate, `x / 0 = 0`, ranges are off by one, and a
  hypothesis you added can make the theorem vacuous. Never weaken the statement
  to get a proof through. Tell the user if the problem turned out ambiguous.
- For a "find all x such that ..." problem, state the answer explicitly as a set
  or value and prove both directions.
- No `sorry`, `admit`, new `axiom`, `native_decide`, `implemented_by` or
  `set_option debug.*` in the final proof.
- `lake env lean` on the file shows no errors and no "declaration uses 'sorry'".
- `#print axioms your_theorem` lists at most `propext`, `Classical.choice` and
  `Quot.sound`, or `lean_verify` says the same.

For a longer proof, once the plugins are loaded, the lean4 plugin's
`/lean4:prove` (guided) and `/lean4:autoprove` (autonomous, with stop budgets)
run a plan, search, check and review cycle over each `sorry`, and
`/lean4:formalize` turns an informal statement into Lean. Use them when the task
is that size.
