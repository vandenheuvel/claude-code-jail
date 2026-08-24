# Claude Code workstation image

A container a Claude Code session can be dropped into and be productive in
immediately — on Rust, Python and R projects, data analysis, scraping, LLM
evaluation, and performance work — without stopping to install anything.

```sh
make            # Claude Code on the current directory
make install    # a `claude-box` launcher on PATH, to skip the `make` entirely
make test       # verify the image, and the mounts and uid mapping it runs under
make shell      # bash instead
make help       # everything else
```

`make` is the whole setup. It builds the image if it is missing, creates the
home volume if it is missing, repairs that volume's ownership if it needs it,
and starts Claude Code on the current directory. Every later run skips
straight to the last step. There is nothing to configure first and no flags to
remember.

It mounts the current directory at `/workspace`, keeps `/home/claude` in a
named volume so credentials and settings survive `--rm`, mounts your
`~/.gitconfig` read-only so commits are attributed, and forwards
`ANTHROPIC_API_KEY`, `GH_TOKEN` and friends when they are set on the host.

`make install` writes a `claude-box` script that does the same thing from any
directory, so the single command becomes:

```sh
cd ~/src/myproject && claude-box
```

Base is `node:26-trixie-slim` (Debian 13). Builds for `linux/amd64` and
`linux/arm64`; see [Architecture notes](#architecture-notes) for the two
things that differ.

---

## What's in it

### Languages

| | |
|---|---|
| **Rust** | rustup stable, `rustfmt` `clippy` `rust-src` `rust-analyzer` `llvm-tools`; `mold` and `lld` linkers |
| **Python** | 3.13 in a venv at `/opt/venv`, first on `PATH`; `uv` for everything else |
| **R** | 4.5 with ~70 prebuilt `r-cran-*` packages; Posit binary mirror configured for the rest |
| **JS/TS** | node 26, `pnpm`, `tsx`, `typescript`, `biome`, `prettier`, `vitest` |
| **C/C++** | gcc and clang 19, cmake, ninja, `nasm`/`yasm` |

### Data and analysis

`numpy` `scipy` `pandas` `polars` `pyarrow` `duckdb` `statsmodels`
`scikit-learn` `xgboost` `lightgbm` `lifelines` `scikit-survival`, plus
`matplotlib` `seaborn` `plotly` `altair` `great-tables` and JupyterLab.

On the R side the package set leans toward survival analysis and resampling:
`tidyverse` `data.table` `survival` `prodlim` `pec` `riskregression` `cmprsk`
`timereg` `survminer` `survey` `quantreg` `glmnet` `ranger` `mgcv` `lme4`
`Rcpp` `RcppArmadillo` `RcppEigen`, with `testthat` `tinytest` `lintr` `covr`
`bench` `microbenchmark` `profvis` for development.

At the command line: `duckdb` (query CSV/Parquet/JSON in place), `mlr`
(Miller, for streaming CSV/JSON), `sqlite3`, `jq`, `yq`.

### Scraping

`httpx[http2]` `requests` `curl-cffi` `beautifulsoup4` `lxml` `selectolax`
`parsel` `trafilatura` `feedparser` `scrapy` `pypdf`, and Playwright with
Chromium already downloaded to `/opt/playwright`. `make run` passes
`--shm-size=1g`; Docker's 64 MB default is where headless Chromium starts
crashing on real pages, and it fails in ways that don't name the cause.

### LLM evaluation

`anthropic` `openai` `litellm` `tiktoken` `tokenizers` `huggingface-hub`
`datasets`, plus two harnesses: `inspect-ai` (Python) and `promptfoo` (CLI).
Build with `WITH_TORCH=1` to add CPU PyTorch, `transformers`, `accelerate` and
`sentence-transformers` — left out by default because most evaluation here is
API-side and it costs about a gigabyte.

### Documents and figures

pandoc, Quarto, a full TeX Live (`latexmk`, `biber`, `xetex`, `luatex`),
graphviz, gnuplot, ghostscript, poppler, qpdf, ImageMagick, ffmpeg, librsvg.

### Everything else

`rg` `fd` `bat` `fzf` `delta` `gh` `git-lfs` `just` `direnv` `entr` `tmux`
`parallel` `moreutils` `shellcheck` `shfmt` `ctags`, and `sudo` without a
password.

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

Sampling profilers: `samply` and `cargo flamegraph` (Rust), `py-spy`
`scalene` `pyinstrument` `viztracer` `line_profiler` (Python), `profvis` (R).

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

`perf` needs capabilities a default container doesn't have:

```sh
make bench    # shell with PERFMON, SYS_PTRACE, SYS_ADMIN, seccomp=unconfined
```

`perf_event_paranoid` is a **host** sysctl and cannot be set per container. If
`perf stat` still reports limited access, on the host:

```sh
sudo sysctl kernel.perf_event_paranoid=1
```

`bpftrace` needs more than that — run it with `--privileged`.

Once inside, pin the work and disable ASLR so runs are comparable:

```sh
taskset -c 2 setarch -R hyperfine -w 3 './target/release/bench'
```

For changes too small to see through timing noise, skip the clock entirely and
count instructions:

```sh
valgrind --tool=callgrind --callgrind-out-file=a.out ./bench && callgrind_annotate a.out
```

---

## Build options

Everything optional is a build arg. All default to on except `WITH_TORCH`.

| Arg | Drops / adds |
|---|---|
| `WITH_LATEX=0` | TeX Live |
| `WITH_R=0` | R and the CRAN package set |
| `WITH_RUST=0` | rustup and the cargo tooling |
| `WITH_BROWSERS=0` | Playwright's Chromium |
| `WITH_QUARTO=0` | Quarto |
| `WITH_GHIDRA=0` | Ghidra and the JDK it needs |
| `WITH_TORCH=1` | adds CPU PyTorch, transformers, accelerate |
| `RUST_VERSION=` | rustup toolchain, default `stable` |
| `USER_UID=`, `USER_GID=` | the container user's ids, default 1000 (see [Rootless podman](#rootless-podman)) |

```sh
make slim                                  # no LaTeX, Ghidra or browser
make minimal                               # languages and core CLI only
make build BUILDARGS='--build-arg WITH_TORCH=1 --build-arg WITH_R=0'
```

`make size` breaks the built image down by layer.

The build uses BuildKit cache mounts for apt, uv, npm and the cargo registry,
so a rebuild after editing one package list re-downloads almost nothing. This
needs BuildKit, which is the default in Docker 23+; the Makefile sets
`DOCKER_BUILDKIT=1` anyway.

---

## Notes for a session running inside the image

**Python.** `/opt/venv/bin` is first on `PATH`, so `python3`, `pip` and
`pytest` are the venv's, and `pip install X` lands there — the venv is
world-writable on purpose. For project-scoped work prefer `uv venv` and
`uv run`, which use the project's own `.venv`.

**R.** `install.packages()` is pointed at Posit Package Manager's Debian
binary repo, so installs are downloads rather than compiles, and
`/usr/local/lib/R/site-library` is writable without sudo. Note that
`R_LIBS_SITE` is deliberately *not* exported: Debian's `Renviron` defines it as
`${R_LIBS_SITE-'…:/usr/lib/R/site-library:…'}`, so setting it to a single path
would hide every `r-cran-*` package.

**Rust.** `CARGO_HOME` and `RUSTUP_HOME` are under `/opt/rust`, writable, so
`cargo install` and `rustup toolchain add nightly` work as the normal user.
`sccache` is installed but not wired in; export `RUSTC_WRAPPER=sccache` per
project if you want it, rather than globally where it surprises build scripts.

**Git.** `safe.directory` is `*` system-wide, so bind-mounted repositories work
regardless of who owns them on the host. `delta` is the pager.

**Not root.** The container runs as `claude` with passwordless `sudo`. This is
what makes `claude --dangerously-skip-permissions` usable — Claude Code refuses
that flag under uid 0. `--user root` is available if you need it, but pass
`-e HOME=/root` with it.

**Login shells.** Debian's `/etc/profile` overwrites `PATH`, which would drop
`/opt/venv`, cargo, npm-global and quarto from any `bash -l`, `su -` or ssh
into the container — and would quietly demote `python3` from the venv to
`/usr/bin/python3` rather than failing outright. `/etc/profile.d/10-claude-path.sh`
puts it back. The smoke test checks this.

**What isn't here.** Geospatial (GDAL/PROJ/GEOS and `sf`), CUDA, and databases
beyond SQLite and DuckDB. All are one `sudo apt-get install` away, and the apt
cache is intact.

---

## Rootless podman

The Makefile detects the engine and adapts. On docker nothing below applies; on
rootless podman three things differ, and each one is a silent failure if it is
left out.

**Bind mounts.** Rootless podman maps your account to container uid 0 and every
other container uid into your subuid range. `/workspace` therefore arrives
root-owned, and the `claude` user cannot write to it — Claude Code can read a
project and cannot edit one file in it, with no error until the first write.
`--userns=keep-id:uid=1000,gid=1000` maps your account onto uid 1000 instead:
`/workspace` becomes writable and new files land on the host owned by you.

**The build uid.** `USER_UID=$(id -u)` is the docker answer to the same
problem, and it cannot work here. A host uid above the subuid range — 218189
against a 65539-entry range is typical for a directory-backed account — cannot
be chown'd to inside a rootless build, so the non-root-user layer fails:

```
chown: changing ownership of '/workspace': Invalid argument
```

So the image is built at uid 1000 and the mapping happens at run time, which
is where it belongs. The uid is no longer baked into the image at all.

**Image format.** podman builds OCI format by default, and there the
Dockerfile's `SHELL` directive is ignored with only a warning — silently
dropping `set -e` and `pipefail` from every `RUN` in the build, which is
exactly what that `SHELL` line exists to prevent. The Makefile passes
`--format docker`.

**The home volume.** podman seeds a fresh `/home/claude` volume correctly under
keep-id. A volume first populated *without* keep-id is owned by a subuid, and
then Claude Code cannot read its own credentials: it reports `Not logged in`
with `.credentials.json` sitting right there. `make` detects and repairs that
before starting, so switching an existing setup over needs no manual step.

---

## Architecture notes

`linux/amd64` and `linux/arm64` both build. Two differences:

- `cpuid` and `likwid` are amd64-only in Debian and are skipped on arm64.
- Posit's binary R packages and `scikit-survival`'s wheels are amd64-only;
  on arm64 both fall back to compiling from source.

---

## Layout

```
Dockerfile        the image
Makefile          build, run, test, bench — and the engine-specific handling
claude-box.in     template for the launcher `make install` writes
smoke-test.sh     baked in as `image-smoke-test`; run by `make test`
```

`make test` is worth running after any change to the Dockerfile — it checks
that each tool is on `PATH`, that every Python module imports, that R can see
its package library, that a Rust hello-world compiles, that Chromium launches,
that ImageMagick will read a PDF, and that the runtime user can write where it
needs to.
