# Claude Code workstation image

A container a Claude Code session can be dropped into and be productive in
immediately — Rust, Python and R, data analysis, scraping, LLM evaluation and
performance work — without stopping to install anything.

## Running it

Point `make` at this repo's Makefile from whatever project you want to work
on — nothing to install, nothing to configure first:

```sh
cd ~/src/myproject
make -f ~/git/claude-code-container/Makefile
```

The build context is the Makefile's own directory, which leaves the current
directory free to be the thing that gets mounted. Worth an alias:

```sh
alias claude-box='make -f ~/git/claude-code-container/Makefile'
```

Inside a clone, plain `make` does the same on the current directory:

```sh
make            # Claude Code on the current directory
make shell      # bash instead
make bench      # shell with the capabilities perf needs
make help       # everything else
```

The first run builds the image, creates the home volume and repairs that
volume's ownership as needed; every later run skips straight to the last step.
It mounts the target directory at `/workspace` (override with `WORK=`), keeps
`/home/claude` in a named volume so credentials and settings survive `--rm`,
mounts `~/.gitconfig` read-only so commits are attributed, forwards
`ANTHROPIC_API_KEY`, `GH_TOKEN` and friends when set on the host, and passes
`--shm-size=1g` — Docker's 64 MB default is where headless Chromium starts
crashing on real pages, in ways that don't name the cause.

Base is `node:26-trixie-slim` (Debian 13), building for `linux/amd64` and
`linux/arm64`; see [Architecture notes](#architecture-notes) for the two things
that differ.

---

## What's in it

| | |
|---|---|
| **Rust** | rustup stable, `rustfmt` `clippy` `rust-src` `rust-analyzer` `llvm-tools`; `mold` and `lld` linkers |
| **Python** | 3.13 in a venv at `/opt/venv`, first on `PATH`; `uv` for everything else |
| **R** | 4.5 with ~70 prebuilt `r-cran-*` packages; Posit binary mirror configured for the rest |
| **JS/TS** | node 26, `pnpm` `tsx` `typescript` `biome` `prettier` `vitest` |
| **C/C++** | gcc and clang 19, cmake, ninja, `nasm` `yasm` |
| **Data** | `numpy` `scipy` `pandas` `polars` `pyarrow` `duckdb` `statsmodels` `scikit-learn` `xgboost` `lightgbm` `lifelines` `scikit-survival`; `matplotlib` `seaborn` `plotly` `altair` `great-tables` and JupyterLab; `duckdb` `mlr` `sqlite3` `jq` `yq` at the command line |
| **R packages** | survival analysis and resampling: `tidyverse` `data.table` `survival` `prodlim` `pec` `riskregression` `cmprsk` `timereg` `survminer` `survey` `quantreg` `glmnet` `ranger` `mgcv` `lme4` `Rcpp` `RcppArmadillo` `RcppEigen`; `testthat` `tinytest` `lintr` `covr` `bench` `microbenchmark` `profvis` |
| **Scraping** | `httpx[http2]` `requests` `curl-cffi` `beautifulsoup4` `lxml` `selectolax` `parsel` `trafilatura` `feedparser` `scrapy` `pypdf`; Playwright with Chromium already downloaded to `/opt/playwright` |
| **LLM eval** | `anthropic` `openai` `litellm` `tiktoken` `tokenizers` `huggingface-hub` `datasets`; harnesses `inspect-ai` (Python) and `promptfoo` (CLI) |
| **Documents** | pandoc, Quarto, full TeX Live (`latexmk` `biber` `xetex` `luatex`), graphviz, gnuplot, ghostscript, poppler, qpdf, ImageMagick, ffmpeg, librsvg |
| **CLI** | `rg` `fd` `bat` `fzf` `delta` `gh` `git-lfs` `just` `direnv` `entr` `tmux` `parallel` `moreutils` `shellcheck` `shfmt` `ctags`, and passwordless `sudo` |

---

## Performance work

The image is set up so a micro-optimisation loop never has to leave it.

### Measuring

| Tool | Use |
|---|---|
| `hyperfine` | wall-clock A/B with warmup and outlier detection |
| `valgrind --tool=callgrind` + `callgrind_annotate` | deterministic instruction counts — the only reliable way to see a 2% change on a noisy machine |
| `valgrind --tool=cachegrind` + `cg_annotate` | cache miss and branch misprediction counts |
| `perf stat` / `perf record` | real hardware counters and sampling profiles |
| `heaptrack`, `google-pprof` | allocation profiles, when the cost turns out to be `malloc` |
| `papi_avail`, `likwid-perfctr` | raw PMU counters, per-core pinning |
| `stress-ng`, `numactl`, `taskset` | create and control the conditions you measure under |

Per language: `cargo criterion` / `critcmp` / `iai-callgrind` (Rust),
`pytest-benchmark` / `pyperf` / `asv` (Python), `bench` / `microbenchmark` (R).
Sampling profilers: `samply` and `cargo flamegraph` (Rust), `py-spy` `scalene`
`pyinstrument` `viztracer` `line_profiler` (Python), `profvis` (R).

### Reading the machine code

| Tool | Use |
|---|---|
| `cargo asm` (`cargo-show-asm`) | the asm for one Rust function, demangled, source-interleaved |
| `objdump -d`, `llvm-objdump -d --x86-asm-syntax=intel` | disassemble anything |
| `llvm-mca` | static throughput and port-pressure model for a basic block |
| `llvm-exegesis` | *measured* latency and reciprocal throughput of an instruction on this CPU |
| `opt`, `llc` | what LLVM does to your IR between `-O` levels |
| `cargo llvm-lines`, `cargo bloat` | where monomorphisation and binary size went |
| `pahole` | struct layout, padding, cacheline straddling |
| `cpuid`, `lscpu` | which ISA extensions the target actually has |
| `ghidra-headless` | scriptable decompilation, for binaries whose source you don't have |
| `capstone`, `iced-x86`, `pyelftools` | disassembly and ELF parsing from Python |

`cargo-binutils` also gives you `cargo objdump`, `cargo nm` and `cargo size`
against the crate's own artifacts.

### Getting trustworthy numbers

`perf` needs capabilities a default container doesn't have, so `make bench`
adds `PERFMON`, `SYS_PTRACE`, `SYS_ADMIN` and `seccomp=unconfined`. Two things
it cannot do for you: `perf_event_paranoid` is a **host** sysctl, so if `perf
stat` still reports limited access run `sudo sysctl kernel.perf_event_paranoid=1`
on the host; and `bpftrace` needs `--privileged` on top.

Once inside, pin the work and disable ASLR so runs are comparable — and for
changes too small to see through timing noise, skip the clock entirely:

```sh
taskset -c 2 setarch -R hyperfine -w 3 './target/release/bench'
valgrind --tool=callgrind --callgrind-out-file=a.out ./bench && callgrind_annotate a.out
```

---

## Build options

Everything optional is a build arg, all default to on except `WITH_TORCH`:
`WITH_LATEX` (TeX Live), `WITH_R` (R and the CRAN set), `WITH_RUST` (rustup and
cargo tooling), `WITH_BROWSERS` (Playwright's Chromium), `WITH_QUARTO`,
`WITH_GHIDRA` (Ghidra and its JDK). `WITH_TORCH=1` adds CPU PyTorch,
`transformers`, `accelerate` and `sentence-transformers` — left out by default
because most evaluation here is API-side and it costs about a gigabyte. Also
`RUST_VERSION=` (default `stable`) and `USER_UID=` / `USER_GID=` (default 1000,
see [Rootless podman](#rootless-podman)).

```sh
make slim                                  # no LaTeX, Ghidra or browser
make minimal                               # languages and core CLI only
make build BUILDARGS='--build-arg WITH_TORCH=1 --build-arg WITH_R=0'
make size                                  # per-layer breakdown
```

The build uses BuildKit cache mounts for apt, uv, npm and the cargo registry,
so a rebuild after editing one package list re-downloads almost nothing. That
needs BuildKit, the default in Docker 23+; the Makefile sets `DOCKER_BUILDKIT=1`
anyway.

---

## Notes for a session running inside the image

**Python.** `/opt/venv/bin` is first on `PATH`, so `python3`, `pip` and `pytest`
are the venv's and `pip install X` lands there — it is world-writable on
purpose. For project-scoped work prefer `uv venv` and `uv run`.

**R.** `install.packages()` points at Posit Package Manager's Debian binary
repo, so installs are downloads rather than compiles, and
`/usr/local/lib/R/site-library` is writable without sudo. `R_LIBS_SITE` is
deliberately *not* exported: Debian's `Renviron` defines it as
`${R_LIBS_SITE-'…:/usr/lib/R/site-library:…'}`, so setting it to a single path
would hide every `r-cran-*` package.

**Rust.** `CARGO_HOME` and `RUSTUP_HOME` are under `/opt/rust` and writable, so
`cargo install` and `rustup toolchain add nightly` work as the normal user.
`sccache` is installed but not wired in — export `RUSTC_WRAPPER=sccache` per
project rather than globally, where it surprises build scripts.

**Git.** `safe.directory` is `*` system-wide, so bind-mounted repositories work
regardless of who owns them on the host. `delta` is the pager.

**Not root.** The container runs as `claude` with passwordless `sudo`, which is
what makes `claude --dangerously-skip-permissions` usable — Claude Code refuses
that flag under uid 0. `--user root` is available if you need it, but pass
`-e HOME=/root` with it.

**Login shells.** Debian's `/etc/profile` overwrites `PATH`, dropping
`/opt/venv`, cargo, npm-global and quarto from any `bash -l`, `su -` or ssh in —
which demotes `python3` to `/usr/bin/python3` rather than failing outright.
`/etc/profile.d/10-claude-path.sh` puts it back.

**What isn't here.** Geospatial (GDAL/PROJ/GEOS and `sf`), CUDA, and databases
beyond SQLite and DuckDB. All are one `sudo apt-get install` away, and the apt
cache is intact.

---

## Rootless podman

The Makefile detects the engine and adapts. On docker none of this applies; on
rootless podman three things differ, and each is a silent failure if left out.

**Bind mounts.** Rootless podman maps your account to container uid 0 and every
other container uid into your subuid range, so `/workspace` arrives root-owned
and the `claude` user cannot write to it — Claude Code can read a project but
not edit one file in it, with no error until the first write.
`--userns=keep-id:uid=1000,gid=1000` maps your account onto uid 1000 instead:
`/workspace` becomes writable and new files land on the host owned by you.

**The build uid.** `USER_UID=$(id -u)` is the docker answer to the same problem
and cannot work here: a host uid above the subuid range — 218189 against a
65539-entry range is typical for a directory-backed account — cannot be chown'd
to inside a rootless build, so that layer fails with `chown: changing ownership
of '/workspace': Invalid argument`. The image is built at uid 1000 and the
mapping happens at run time, where it belongs.

**Image format.** podman builds OCI format by default, and there the
Dockerfile's `SHELL` directive is ignored with only a warning — silently
dropping `set -e` and `pipefail` from every `RUN` in the build, which is exactly
what that `SHELL` line exists to prevent. The Makefile passes `--format docker`.

**The home volume.** podman seeds a fresh `/home/claude` volume correctly under
keep-id. One first populated *without* keep-id is owned by a subuid, and then
Claude Code cannot read its own credentials: `Not logged in`, with
`.credentials.json` sitting right there. `make` detects and repairs that before
starting, so switching an existing setup over needs no manual step.

---

## Architecture notes

`linux/amd64` and `linux/arm64` both build. Two differences:

- `cpuid` and `likwid` are amd64-only in Debian and are skipped on arm64.
- Posit's binary R packages and `scikit-survival`'s wheels are amd64-only; on
  arm64 both fall back to compiling from source.
