# syntax=docker/dockerfile:1.9
#
# Claude Code workstation image.
#
# Goal: a container a Claude Code session can be dropped into and be immediately
# productive on Rust / Python / R projects, data analysis, web scraping and LLM
# evaluation, without ever needing to stop and `apt-get install` mid-task.
#
# Build knobs (see README for sizes):
#   WITH_LATEX=0     drop the TeX Live layer
#   WITH_R=0         drop R and the CRAN binary set
#   WITH_RUST=0      drop rustup and the cargo tooling
#   WITH_BROWSERS=0  drop Chromium, both Playwrights and the screenshot stack
#   WITH_QUARTO=0    drop Quarto
#   WITH_TORCH=1     add CPU-only PyTorch + transformers
#   WITH_GHIDRA=0    drop Ghidra's headless decompiler and the JDK it needs
#   USER_UID/USER_GID  match your host account so bind mounts stay writable
#
# `node:26-slim` resolves to Debian 13 "trixie". Pinned explicitly: every apt
# package name below is a trixie name, and an upstream retag of the floating
# alias must not be able to move the whole package set to a different suite.
FROM node:26-trixie-slim

ARG TARGETARCH
ARG DEBIAN_SUITE=trixie
ARG USERNAME=claude

# -e: a failing command inside a multi-command RUN aborts the build instead of
# being masked by the exit status of the last one.
# pipefail: `curl ... | sh` cannot succeed on a failed download.
SHELL ["/bin/bash", "-eo", "pipefail", "-c"]

# Toolchains live under /opt and are made world-writable at the end of each
# layer, so the image behaves whether it runs as the baked-in user, as root, or
# under an arbitrary `docker run --user`.
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    TZ=UTC \
    VENV=/opt/venv \
    RUSTUP_HOME=/opt/rust/rustup \
    CARGO_HOME=/opt/rust/cargo \
    NPM_CONFIG_PREFIX=/opt/npm-global \
    NPM_CONFIG_FUND=false \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    PLAYWRIGHT_BROWSERS_PATH=/opt/playwright \
    UV_CACHE_DIR=/opt/uv-cache \
    NPM_CONFIG_CACHE=/opt/npm-cache \
    UV_LINK_MODE=copy \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    HOME=/home/${USERNAME}
ENV PATH=/opt/venv/bin:/opt/rust/cargo/bin:/opt/npm-global/bin:/opt/quarto/bin:/home/${USERNAME}/.local/bin:$PATH

# ---- apt plumbing -----------------------------------------------------------
# Two adjustments to what the slim base does by default.
#
# 1. Keep downloaded .debs, so the BuildKit cache mounts below actually help.
#    The Debian base ships docker-clean, which throws every .deb away the moment
#    apt finishes, which would make the cache mounts inert.
#
# 2. Re-include manual pages and exclude TeX Live's PDF manuals. The slim base
#    drops /usr/share/{doc,man,info,locale}; docs and info are no loss, but
#    `man perf-stat`, `man objdump`, `man valgrind` are working references for
#    the profiling tools installed further down, and losing them silently is
#    worse than the ~100 MB they cost. TeX Live's doc tree is the opposite
#    trade: about a gigabyte nobody reads from a container.
#
# dpkg applies path filters in file order and last match wins, so this file has
# to sort after the base's /etc/dpkg/dpkg.cfg.d/docker. Hence the zz- prefix.
# (dpkg also ignores any filename in that directory containing a dot.)
RUN rm -f /etc/apt/apt.conf.d/docker-clean \
 && echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache \
 && printf '%s\n' \
      'path-include=/usr/share/man/*' \
      'path-exclude=/usr/share/texlive/texmf-dist/doc/*' \
      'path-exclude=/usr/share/texmf/doc/*' \
    > /etc/dpkg/dpkg.cfg.d/zz-claude-image

ARG APT="apt-get install -y --no-install-recommends"

# ---- core CLI: search, nav, VCS, net, archives, process ---------------------
# The two ln -sf calls matter: Debian ships ripgrep's neighbours as `fdfind`
# and `batcat` (name clashes with unrelated packages), so an unpatched image
# fails every `fd`/`bat` invocation a script or a habit produces.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked,id=apt-cache-${TARGETARCH} \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked,id=apt-lists-${TARGETARCH} \
    apt-get update && $APT \
      ripgrep fd-find fzf bat tree less \
      git git-lfs git-delta openssh-client ca-certificates gnupg rsync sudo \
      curl wget jq sqlite3 zstd \
      procps psmisc htop time parallel moreutils entr \
      file patch diffutils unzip zip xz-utils p7zip-full \
      make cmake ninja-build build-essential pkg-config just direnv \
      libssl-dev zlib1g-dev libbz2-dev liblzma-dev libffi-dev \
      libreadline-dev libsqlite3-dev libcurl4-openssl-dev libxml2-dev \
      netcat-openbsd bind9-dnsutils iputils-ping socat \
      shellcheck shfmt vim nano tmux locales bash-completion man-db tzdata \
 && ln -sf "$(command -v fdfind)" /usr/local/bin/fd \
 && ln -sf "$(command -v batcat)" /usr/local/bin/bat \
 && sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen \
 && locale-gen

# ---- compilers, debuggers, numeric system libs ------------------------------
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked,id=apt-cache-${TARGETARCH} \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked,id=apt-lists-${TARGETARCH} \
    apt-get update && $APT \
      clang lld mold llvm gfortran nasm yasm \
      gdb strace ltrace universal-ctags \
      miller \
      libopenblas-dev libgsl-dev libglpk-dev libnlopt-dev libgit2-dev \
      python3 python3-dev python3-venv python3-pip pipx

# ---- measurement, profiling, disassembly ------------------------------------
# The pieces a micro-optimisation loop needs, and why each is here:
#
#   hyperfine          wall-clock A/B with warmup, outlier detection, CI output
#   valgrind           callgrind/cachegrind + callgrind_annotate, cg_annotate:
#                      deterministic instruction and cache-miss counts, which is
#                      the only way to measure a 2% change on a noisy machine
#   linux-perf         sampling profiles and hardware counters (see README: the
#                      container needs --cap-add PERFMON to read them)
#   heaptrack          allocation profiles when the cost turns out to be malloc
#   google-perftools   pprof + tcmalloc, for the same question from the other end
#   bpftrace           ad-hoc kernel/user tracing when the cost is off-CPU
#   papi-tools/likwid  raw PMU counters, per-core pinning
#   numactl, cpuset    pin the benchmark so the scheduler stops being a variable
#   stress-ng          generate the contention you want to measure under
#   pahole             struct layout, padding and cacheline straddling
#   elfutils/patchelf  ELF surgery and eu-* inspectors
#   libbenchmark-dev   Google Benchmark, for C/C++ comparison harnesses
#
# Disassembly comes from the already-installed llvm and binutils packages:
#   objdump -d / llvm-objdump -d --x86-asm-syntax=intel
#   llvm-mca       static throughput/port-pressure model for a basic block
#   llvm-exegesis  measures real instruction latency and throughput on this CPU
#   opt / llc      inspect what LLVM does to your IR between -O levels
#   cpuid, lscpu   what ISA extensions the target actually has
#
# cpuid and likwid are amd64-only in Debian, so they are installed conditionally
# rather than failing an arm64 build outright.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked,id=apt-cache-${TARGETARCH} \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked,id=apt-lists-${TARGETARCH} \
    apt-get update && $APT \
      hyperfine valgrind linux-perf heaptrack bpftrace \
      google-perftools libgoogle-perftools-dev \
      papi-tools libpapi-dev numactl stress-ng sysstat trace-cmd \
      pahole elfutils patchelf binutils-dev libcapstone-dev \
      libunwind-dev libdw-dev libelf-dev \
      libbenchmark-dev libbenchmark-tools \
 && if [ "$TARGETARCH" = "amd64" ]; then $APT cpuid likwid; fi

# ---- document / figure toolchain -------------------------------------------
# Two traps in this layer.
#
# The `gnuplot` metapackage's first alternative is gnuplot-qt, so plain
# `gnuplot` drags Qt6 and X11 into a headless image. gnuplot-nox is the same
# plotter without them.
#
# And ImageMagick's policy needs adjusting. Trixie's ImageMagick 7 policy no
# longer blocks the PDF/PS/EPS coders — that was the ImageMagick 6 era — but it
# does cap memory at 1 GiB, area at 256 MP and width/height at 32 KP, which a
# high-DPI render of a multi-panel figure runs into. The failure reads as a
# cryptic "cache resources exhausted", so the caps are raised here; the
# container's own memory limit is the real guard. The coder deletion is kept as
# a no-op on trixie, in case this ever gets rebased onto a suite shipping
# ImageMagick 6, where those restrictions are active and do break pdf->png.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked,id=apt-cache-${TARGETARCH} \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked,id=apt-lists-${TARGETARCH} \
    apt-get update && $APT \
      pandoc graphviz libgraphviz-dev imagemagick ghostscript \
      poppler-utils poppler-data qpdf gnuplot-nox librsvg2-bin \
      optipng pngquant jpegoptim ffmpeg \
      libcairo2-dev libxt-dev libfontconfig1-dev libharfbuzz-dev \
      libfribidi-dev libfreetype-dev libpng-dev libtiff-dev libjpeg-dev \
      fonts-dejavu fonts-lmodern fonts-liberation fonts-firacode \
      fonts-noto-core fonts-noto-color-emoji \
 && for p in /etc/ImageMagick-7/policy.xml /etc/ImageMagick-6/policy.xml; do \
      [ -f "$p" ] || continue; \
      sed -i -E \
        -e '/rights="none"[[:space:]]+pattern="(PS|PS2|PS3|EPS|PDF|XPS|gs)"/d' \
        -e 's/(name="memory" value=)"[^"]*"/\1"8GiB"/' \
        -e 's/(name="map" value=)"[^"]*"/\1"16GiB"/' \
        -e 's/(name="area" value=)"[^"]*"/\1"4GP"/' \
        -e 's/(name="disk" value=)"[^"]*"/\1"32GiB"/' \
        -e 's/(name="(width|height)" value=)"[^"]*"/\1"128KP"/' \
        "$p"; \
    done

# ---- LaTeX ------------------------------------------------------------------
# texlive-plain-generic is the engine-independent tree, and none of the
# latex-* sets above pull it in. ulem lives there -- \sout, \uline, \uwave and
# the rest of the underlining macros -- and twenty-odd styles that *are*
# installed here (changes, dashundergaps, pdfreview, ezedits, ...) require it,
# so without this the build dies on a missing ulem.sty in a package the
# document never named.
ARG WITH_LATEX=1
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked,id=apt-cache-${TARGETARCH} \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked,id=apt-lists-${TARGETARCH} \
    if [ "$WITH_LATEX" = "1" ]; then \
      apt-get update && $APT \
        texlive-latex-base texlive-latex-recommended texlive-latex-extra \
        texlive-fonts-recommended texlive-fonts-extra \
        texlive-science texlive-pictures texlive-bibtex-extra \
        texlive-plain-generic \
        texlive-luatex texlive-xetex \
        latexmk biber chktex dvipng cm-super; \
    fi

# ---- R ----------------------------------------------------------------------
# Debian's r-cran-* packages are prebuilt binaries, so this layer is minutes
# rather than the hour a source install of the tidyverse costs. The set leans
# toward survival analysis, resampling and reproducible reporting.
#
# /usr/local/lib/R/site-library is made writable so a session can install into
# it without sudo. Note that R_LIBS_SITE is deliberately NOT exported: Debian's
# Renviron defines it as ${R_LIBS_SITE-'/usr/local/lib/R/site-library:/usr/lib/
# R/site-library:/usr/lib/R/library'}, so setting it to a single path would drop
# /usr/lib/R/site-library — where every r-cran-* package above lives — off the
# search path, and library(tidyverse) would stop resolving.
ARG WITH_R=1
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked,id=apt-cache-${TARGETARCH} \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked,id=apt-lists-${TARGETARCH} \
    if [ "$WITH_R" = "1" ]; then \
      apt-get update && $APT \
        r-base r-base-dev r-recommended \
        r-cran-tidyverse r-cran-data.table r-cran-vroom r-cran-nanoarrow \
        r-cran-jsonlite r-cran-httr2 r-cran-rvest r-cran-xml2 r-cran-curl \
        r-cran-knitr r-cran-rmarkdown r-cran-tinytex \
        r-cran-flextable r-cran-kableextra r-cran-dt \
        r-cran-survival r-cran-prodlim r-cran-pec r-cran-riskregression \
        r-cran-cmprsk r-cran-timereg r-cran-survminer r-cran-survey \
        r-cran-quantreg r-cran-nnls r-cran-isoband \
        r-cran-glmnet r-cran-ranger r-cran-randomforest r-cran-mgcv \
        r-cran-lme4 r-cran-caret r-cran-recipes r-cran-broom \
        r-cran-rcpp r-cran-rcpparmadillo r-cran-rcppeigen r-cran-matrixstats \
        r-cran-devtools r-cran-usethis r-cran-remotes r-cran-renv \
        r-cran-testthat r-cran-tinytest r-cran-roxygen2 r-cran-covr r-cran-lintr \
        r-cran-bench r-cran-microbenchmark r-cran-profvis \
        r-cran-future r-cran-furrr r-cran-foreach r-cran-doparallel r-cran-progressr \
        r-cran-patchwork r-cran-ggrepel r-cran-viridis r-cran-scales r-cran-plotly \
        r-cran-here r-cran-fs r-cran-cli r-cran-withr r-cran-reticulate \
      && mkdir -p /usr/local/lib/R/site-library \
      && chmod -R a+rwX /usr/local/lib/R/site-library; \
    fi

# Point install.packages() at Posit Package Manager's Debian binary repo, so
# that anything not packaged by Debian still installs in seconds. The
# HTTPUserAgent line is the load-bearing part: without it P3M serves source
# tarballs and every install compiles from scratch.
RUN if [ "$WITH_R" = "1" ]; then \
      { echo 'local({'; \
        echo '  repo <- "https://packagemanager.posit.co/cran/__linux__/'"$DEBIAN_SUITE"'/latest"'; \
        echo '  options(repos = c(P3M = repo, CRAN = "https://cloud.r-project.org"))'; \
        echo '  options(HTTPUserAgent = sprintf("R/%s R (%s)", getRversion(),'; \
        echo '    paste(getRversion(), R.version$platform, R.version$arch, R.version$os)))'; \
        echo '  options(Ncpus = max(1L, parallel::detectCores()))'; \
        echo '  options(warn = 1)'; \
        echo '})'; } >> /etc/R/Rprofile.site; \
    fi

# ---- Rust -------------------------------------------------------------------
# rustup rather than Debian's rustc: trixie ships 1.85 and freezes the whole
# toolchain to the distro release, which is not a workable floor for crates
# tracking current stable. cargo-binstall fetches prebuilt release binaries for
# the tool set below; `cargo install` for the same list is an hour of compiling.
ARG WITH_RUST=1
ARG RUST_VERSION=stable
RUN --mount=type=cache,target=/opt/rust/cargo/registry,sharing=locked,id=cargo-reg-${TARGETARCH} \
    if [ "$WITH_RUST" = "1" ]; then \
      case "$TARGETARCH" in \
        arm64) BINSTALL_TRIPLE=aarch64-unknown-linux-musl ;; \
        *)     BINSTALL_TRIPLE=x86_64-unknown-linux-musl ;; \
      esac; \
      curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --no-modify-path --profile minimal \
            --default-toolchain "$RUST_VERSION" \
            -c rustfmt -c clippy -c rust-src -c rust-analyzer -c llvm-tools; \
      curl -fsSL "https://github.com/cargo-bins/cargo-binstall/releases/latest/download/cargo-binstall-${BINSTALL_TRIPLE}.tgz" \
        | tar xz -C "$CARGO_HOME/bin"; \
      cargo binstall --no-confirm \
        cargo-nextest cargo-llvm-cov cargo-insta cargo-expand \
        cargo-audit cargo-deny cargo-machete cargo-hack \
        sccache bacon taplo-cli \
        cargo-show-asm cargo-binutils cargo-criterion critcmp \
        flamegraph samply iai-callgrind-runner \
        cargo-llvm-lines cargo-bloat cargo-pgo; \
      chmod -R a+rwX /opt/rust; \
    fi

# ---- Python -----------------------------------------------------------------
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

# A real venv on PATH, not pip-into-dist-packages: PIP_BREAK_SYSTEM_PACKAGES is
# a way to lose an argument with the OS package manager, not a way to win it.
# Numeric core is its own layer so that editing the list below it doesn't
# rebuild scipy.
RUN --mount=type=cache,target=/opt/uv-cache,sharing=locked,id=uv-${TARGETARCH} \
    uv venv --python /usr/bin/python3 "$VENV" \
 && uv pip install --python "$VENV/bin/python" \
      numpy scipy pandas polars pyarrow duckdb \
      statsmodels scikit-learn xgboost lightgbm \
      lifelines scikit-survival \
      matplotlib seaborn plotly altair great-tables \
 && chmod -R a+rwX "$VENV"

# Notebooks and reporting; scraping and HTTP; LLM clients and evaluation;
# testing, profiling and glue.
RUN --mount=type=cache,target=/opt/uv-cache,sharing=locked,id=uv-${TARGETARCH} \
    uv pip install --python "$VENV/bin/python" \
      jupyterlab ipykernel ipython nbformat nbclient jupytext papermill \
      "httpx[http2]" requests curl-cffi beautifulsoup4 lxml selectolax parsel \
      trafilatura feedparser scrapy pypdf \
      playwright shot-scraper pytest-playwright selenium \
      anthropic openai litellm tiktoken tokenizers huggingface-hub datasets \
      inspect-ai pydantic jsonschema \
      ruff mypy pytest pytest-xdist pytest-cov pytest-benchmark hypothesis \
      coverage pandera ipdb rich typer tqdm python-dotenv pyyaml orjson \
      tenacity python-dateutil sqlalchemy openpyxl xlsxwriter \
      line-profiler memory-profiler py-spy scalene pyinstrument viztracer \
      asv pyperf perfplot \
      capstone iced-x86 pyelftools \
      maturin cython cffi yq \
 && chmod -R a+rwX "$VENV"

# Off by default: CPU torch plus transformers is about a gigabyte, and most
# evaluation work here is API-side.
ARG WITH_TORCH=0
RUN --mount=type=cache,target=/opt/uv-cache,sharing=locked,id=uv-${TARGETARCH} \
    if [ "$WITH_TORCH" = "1" ]; then \
      uv pip install --python "$VENV/bin/python" \
        --extra-index-url https://download.pytorch.org/whl/cpu \
        torch transformers accelerate sentence-transformers \
      && chmod -R a+rwX "$VENV"; \
    fi

# ---- headless browsers and screenshots --------------------------------------
# Seeing the page is faster than reasoning about it, so a session should never
# have to stop and download a browser before it can take a screenshot. Three
# ways to drive one, because a project arrives already committed to one of them:
#
#   playwright (Python)  `playwright screenshot`, `shot-scraper`, pytest-playwright
#   @playwright/test     the JS/TS runner: `npx playwright test`
#   /usr/bin/chromium    Debian's browser, which is what puppeteer, lighthouse
#                        and selenium (via chromedriver) reach for, and what
#                        answers `chromium --headless --screenshot`
#
# Both Playwright packages are installed here rather than next to their own
# languages, so that one layer owns every browser byte and WITH_BROWSERS=0
# really does drop all of it. They are versioned separately and each pins its
# own Chromium revision, so this normally holds two Playwright builds alongside
# Debian's: about 1.7 GB of browser, and the price of the paragraph above.
#
# Three details, each a silent failure if left out:
#
#   chromium-sandbox is only Recommends, so --no-install-recommends skips it and
#   chromium then dies with "SUID sandbox helper binary was not found" wherever
#   the namespace sandbox is unavailable -- which is many container hosts.
#
#   The library list is Playwright's own dependency set and stays explicit
#   rather than being inherited from chromium's. The bundled browser is not
#   Debian's build and must not lose a library because Debian repackaged theirs.
#
#   fonts-noto-cjk, because without it every CJK glyph in a screenshot is a tofu
#   box while the page itself reports as having loaded perfectly.
ARG WITH_BROWSERS=1
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked,id=apt-cache-${TARGETARCH} \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked,id=apt-lists-${TARGETARCH} \
    --mount=type=cache,target=/opt/npm-cache,sharing=locked,id=npm-${TARGETARCH} \
    if [ "$WITH_BROWSERS" = "1" ]; then \
      apt-get update && $APT \
        libnss3 libnspr4 libdbus-1-3 libglib2.0-0t64 libatk1.0-0t64 \
        libatk-bridge2.0-0t64 libatspi2.0-0t64 libcups2t64 libasound2t64 \
        libdrm2 libgbm1 libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 \
        libxrandr2 libxext6 libx11-6 libxcb1 libexpat1 libpango-1.0-0 libcairo2 \
        chromium chromium-sandbox chromium-driver \
        xvfb fonts-unifont fonts-noto-cjk \
      && playwright install chromium \
      && npm install -g @playwright/test \
      && ln -sf /opt/npm-global/bin/playwright /usr/local/bin/playwright-node \
      && playwright-node install chromium \
      && chmod -R a+rwX "$PLAYWRIGHT_BROWSERS_PATH" /opt/npm-global; \
    fi

# Both Playwright CLIs are called `playwright`, and /opt/venv/bin wins the PATH
# race, so bare `playwright` is the Python one. The npm CLI -- the half that has
# `playwright test` -- gets a name of its own rather than being reachable only
# through an ordering accident or `npx`.
#
# Everything that is not Playwright finds Chrome through one of these variables:
# puppeteer (PUPPETEER_EXECUTABLE_PATH), lighthouse (CHROME_PATH), karma and
# testcafe (CHROME_BIN). Pointing them at the browser already in the image is
# also why puppeteer's own ~180 MB download is turned off; unset
# PUPPETEER_SKIP_DOWNLOAD for a project that genuinely needs its pinned build.
# Under WITH_BROWSERS=0 these name a binary that is not there, which is the
# honest answer: that build has no browser and no libraries to run one either.
ENV CHROME_BIN=/usr/bin/chromium \
    CHROME_PATH=/usr/bin/chromium \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium \
    PUPPETEER_SKIP_DOWNLOAD=true

# ---- Quarto -----------------------------------------------------------------
# Tarball rather than the .deb: no dpkg entanglement, and it drops cleanly into
# /opt/quarto which is already on PATH.
ARG WITH_QUARTO=1
RUN if [ "$WITH_QUARTO" = "1" ]; then \
      V="$(curl -fsSL https://api.github.com/repos/quarto-dev/quarto-cli/releases/latest | jq -r .tag_name | sed 's/^v//')"; \
      mkdir -p /opt/quarto; \
      curl -fsSL "https://github.com/quarto-dev/quarto-cli/releases/download/v${V}/quarto-${V}-linux-${TARGETARCH}.tar.gz" \
        | tar xz -C /opt/quarto --strip-components=1; \
    fi

# ---- Ghidra (headless decompiler) -------------------------------------------
# For the cases where the asm is not yours: a third-party .so, a vendored blob,
# a binary whose source you do not have. `analyzeHeadless` is scriptable, so a
# session can drive decompilation without a GUI. Roughly a gigabyte with the
# JDK, so it is a knob rather than a given.
ARG WITH_GHIDRA=1
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked,id=apt-cache-${TARGETARCH} \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked,id=apt-lists-${TARGETARCH} \
    if [ "$WITH_GHIDRA" = "1" ]; then \
      apt-get update && $APT openjdk-21-jdk-headless; \
      url="$(curl -fsSL https://api.github.com/repos/NationalSecurityAgency/ghidra/releases/latest \
             | jq -r '.assets[] | select(.name | endswith(".zip")) | .browser_download_url' | head -n1)"; \
      curl -fsSL -o /tmp/ghidra.zip "$url"; \
      unzip -q /tmp/ghidra.zip -d /opt; \
      rm /tmp/ghidra.zip; \
      mv /opt/ghidra_* /opt/ghidra; \
      ln -sf /opt/ghidra/support/analyzeHeadless /usr/local/bin/ghidra-headless; \
      chmod -R a+rwX /opt/ghidra; \
    fi

# ---- standalone binaries: gh, duckdb ----------------------------------------
# gh from upstream: trixie packages 2.46, old enough to be missing flags that
# current PR and issue workflows use.
RUN V="$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest | jq -r .tag_name | sed 's/^v//')" \
 && curl -fsSL "https://github.com/cli/cli/releases/download/v${V}/gh_${V}_linux_${TARGETARCH}.tar.gz" \
    | tar xz -C /tmp \
 && install -m 0755 "/tmp/gh_${V}_linux_${TARGETARCH}/bin/gh" /usr/local/bin/gh \
 && rm -rf "/tmp/gh_${V}_linux_${TARGETARCH}" \
 && curl -fsSL -o /tmp/duckdb.zip \
      "https://github.com/duckdb/duckdb/releases/latest/download/duckdb_cli-linux-${TARGETARCH}.zip" \
 && unzip -q -o /tmp/duckdb.zip -d /usr/local/bin \
 && rm /tmp/duckdb.zip \
 && chmod 0755 /usr/local/bin/duckdb

# ---- JS ---------------------------------------------------------------------
# Playwright's JS runner is not here: it is installed in the browser layer
# above, with the Chromium build it pins.
RUN --mount=type=cache,target=/opt/npm-cache,sharing=locked,id=npm-${TARGETARCH} \
    npm install -g \
      prettier typescript tsx pnpm @biomejs/biome vitest promptfoo \
 && chmod -R a+rwX /opt/npm-global

# ---- non-root user ----------------------------------------------------------
# Claude Code refuses --dangerously-skip-permissions while running as root,
# which is exactly the mode an unattended container wants. Pass USER_UID and
# USER_GID matching the host account so bind-mounted work stays writable on
# both sides; the Makefile does this by default.
ARG USER_UID=1000
ARG USER_GID=1000
RUN userdel -r node 2>/dev/null || true; \
    groupadd -g "$USER_GID" "$USERNAME" 2>/dev/null \
      || groupmod -n "$USERNAME" "$(getent group "$USER_GID" | cut -d: -f1)"; \
    useradd -m -u "$USER_UID" -g "$USER_GID" -s /bin/bash "$USERNAME"; \
    echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$USERNAME"; \
    chmod 0440 "/etc/sudoers.d/90-$USERNAME"; \
    mkdir -p /workspace "/home/$USERNAME/.claude" "/home/$USERNAME/.local/bin" \
             "/home/$USERNAME/.config" "/home/$USERNAME/.cache" \
             /opt/uv-cache /opt/npm-cache; \
    chmod -R a+rwX /opt/uv-cache /opt/npm-cache; \
    chown -R "$USER_UID:$USER_GID" /workspace "/home/$USERNAME"

# Repos arrive as bind mounts owned by a uid git may not recognise as its own.
RUN git config --system --add safe.directory '*' \
 && git config --system init.defaultBranch main \
 && git config --system core.pager delta \
 && git config --system interactive.diffFilter 'delta --color-only'

# Debian's /etc/profile overwrites PATH outright, so any login shell -- `bash -lc`,
# `su -`, an ssh into the container -- loses /opt/venv, cargo, npm-global and
# quarto. The quiet half of that is worse than the loud half: `claude` and
# `cargo` fail with "command not found", but `python3` keeps working and simply
# becomes /usr/bin/python3 instead of the venv. Put PATH back for login shells.
RUN printf 'export PATH=%s\n' "$PATH" > /etc/profile.d/10-claude-path.sh \
 && chmod 0644 /etc/profile.d/10-claude-path.sh

# ---- Claude Code ------------------------------------------------------------
# Last, because this is the layer that changes daily. ADD of the registry's
# `latest` metadata makes the published version the cache key, so a rebuild
# picks up a new release instead of silently serving a stale one.
#
# --allow-scripts names the one package whose postinstall this image genuinely
# depends on: it replaces bin/claude.exe with the native binary for the
# platform. npm 11.19 still runs unreviewed install scripts and only warns
# about them, but the warning is the announcement of a stricter default, and
# under that default the skip is silent -- the build would succeed and ship a
# placeholder stub instead of `claude`. Naming the package also keeps the
# warning out of every start-up update check. `claude --version` then proves
# the native binary actually landed, so the failure is a failed build rather
# than a broken image.
ADD https://registry.npmjs.org/@anthropic-ai/claude-code/latest /tmp/cc-latest.json
RUN --mount=type=cache,target=/opt/npm-cache,sharing=locked,id=npm-${TARGETARCH} \
    npm install -g --allow-scripts=@anthropic-ai/claude-code @anthropic-ai/claude-code \
 && claude --version \
 && chmod -R a+rwX /opt/npm-global \
 && rm /tmp/cc-latest.json \
 && chown -R "$USER_UID:$USER_GID" "/home/$USERNAME"

LABEL org.opencontainers.image.title="Claude Code workstation" \
      org.opencontainers.image.description="Claude Code with Rust, Python, R, data analysis, scraping, LLM evaluation and a profiling/disassembly toolchain" \
      org.opencontainers.image.base.name="docker.io/library/node:26-trixie-slim"

USER $USERNAME
WORKDIR /workspace
ENTRYPOINT ["claude"]
