# syntax=docker/dockerfile:1.9
#
# The Lean image: a Lean 4 toolchain, Mathlib already built on it, the Lean
# REPL, and the two Lean plugins. It is not run. The Makefile mounts it,
# read-only, into the workstation image at /opt/lean -- see `leanmount` there --
# and builds it with `make lean-image` (only when missing) or `make lean-update`
# (newest Mathlib release, or MATHLIB_REV).
#
# Why this is not a layer of the main image: rootless podman cannot shift
# ownership on native overlay, so the first container from every new image
# under --userns=keep-id is preceded by a chown'd copy of the whole image,
# flattened, made through overlayfs copy-up. With Mathlib inside, that copy is
# 29 GB and 555,000 files instead of 18 GB and 390,000, and it is made again
# after every Claude Code update, each of which is a new main image. An image
# mount is not remapped and not copied: it is the image's own layers, mounted as
# they are, so Mathlib is written once, when it is built.
#
# Layout, as it appears once mounted at /opt/lean:
#
#   /opt/lean/project     Lake project: Mathlib, its dependencies and the REPL,
#                         all built. lean-init links projects' packages here.
#   /opt/lean/toolchains  the toolchain, in the directory elan names it by
#   /opt/lean/toolchain   a link to it, whatever its version
#   /opt/lean/loogle      Loogle, built, and mathlib.idx, its index of that
#                         Mathlib. Absent if Loogle did not build.
#   /opt/lean/plugins     the claude-box plugin marketplace
#
# The toolchain is mounted a second time, at /opt/elan/toolchains/<its name>,
# where the main image's elan looks for it. That is also where it sat while
# Mathlib was built, so nothing Lake recorded refers to a path that is not there.
#
# MATHLIB_REV and LEAN_TOOLCHAIN are resolved by the Makefile rather than here,
# because the Makefile needs the toolchain's name before any container runs,
# and a label is the only place to read it from; a label cannot be set from
# what a RUN found out.
FROM debian:trixie-slim AS build

SHELL ["/bin/bash", "-eo", "pipefail", "-c"]

ARG TARGETARCH
ARG MATHLIB_REV
ARG LEAN_TOOLCHAIN

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git \
 && rm -rf /var/lib/apt/lists/*

ENV ELAN_HOME=/opt/elan \
    PATH=/opt/elan/bin:$PATH

# The cache can have a hole or two even for a tag -- v4.34.0 was missing one
# module -- so whatever is missing gets built, up to 200 modules. Past that the
# cache is not a cache for this rev at all, and the build stops rather than
# compiling Mathlib for hours.
#
# elan only records the default toolchain and downloads it on first use, so it
# is installed explicitly: the check below needs it there, and otherwise lake
# would be what fetched it. `dir` is elan's directory name for the toolchain,
# worked out the way the Makefile works it out; if elan ever names it
# differently, that check fails the build instead of leaving a mount pointed at
# nothing.
#
# The chmod is not optional. Mathlib's cache unpacks every .olean as 0600, and
# under docker, where the mount shows these files as root's, `import Mathlib`
# then fails for the container user on the first .olean it reaches, as
# "Permission denied". It runs in this RUN, over files this RUN created: in a
# later one it would copy all 8 GB up into a new layer to change their modes.
#
# The REPL is tagged for each Lean release but not for patch releases: there is
# a v4.34.0 and no v4.34.1. A patch release keeps the interface the REPL builds
# on, so when the toolchain's own tag is missing, the .0 of its minor is used.
RUN --mount=type=cache,target=/opt/lean-cache,sharing=locked,id=lean-cache-${TARGETARCH} \
    [ -n "$MATHLIB_REV" ] && [ -n "$LEAN_TOOLCHAIN" ] \
      || { echo "MATHLIB_REV and LEAN_TOOLCHAIN are required; build with make lean-image" >&2; exit 1; }; \
    pinned="$(curl -fsSL "https://raw.githubusercontent.com/leanprover-community/mathlib4/$MATHLIB_REV/lean-toolchain")"; \
    [ "$pinned" = "$LEAN_TOOLCHAIN" ] \
      || { echo "Mathlib $MATHLIB_REV pins $pinned, not $LEAN_TOOLCHAIN" >&2; exit 1; }; \
    echo "==> Mathlib $MATHLIB_REV on $LEAN_TOOLCHAIN"; \
    curl -fsSL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh \
      | sh -s -- -y --no-modify-path --default-toolchain "$LEAN_TOOLCHAIN"; \
    elan toolchain install "$LEAN_TOOLCHAIN"; \
    dir="${LEAN_TOOLCHAIN//\//--}"; dir="${dir//:/---}"; \
    [ -x "$ELAN_HOME/toolchains/$dir/bin/lean" ] \
      || { echo "no toolchain at $ELAN_HOME/toolchains/$dir" >&2; ls "$ELAN_HOME/toolchains" >&2; exit 1; }; \
    mkdir -p /opt/lean/project && ln -s "toolchains/$dir" /opt/lean/toolchain; \
    repl="${LEAN_TOOLCHAIN##*:}"; \
    git ls-remote --exit-code --tags https://github.com/leanprover-community/repl "$repl" >/dev/null \
      || repl="${repl%.*}.0"; \
    cd /opt/lean/project; \
    echo "$LEAN_TOOLCHAIN" > lean-toolchain; \
    printf '%s\n' \
      'name = "proof"' 'defaultTargets = ["Proof"]' '' \
      '[[require]]' 'name = "mathlib"' \
      'git = "https://github.com/leanprover-community/mathlib4"' "rev = \"$MATHLIB_REV\"" '' \
      '[[require]]' 'name = "REPL"' \
      'git = "https://github.com/leanprover-community/repl"' "rev = \"$repl\"" '' \
      '[[lean_lib]]' 'name = "Proof"' > lakefile.toml; \
    printf '%s\n' 'import Mathlib' '' \
      'theorem sanity (a b : ℕ) : a + b = b + a := by omega' > Proof.lean; \
    export XDG_CACHE_HOME=/opt/lean-cache MATHLIB_NO_CACHE_ON_UPDATE=1; \
    lake update; \
    lake exe cache get; \
    if ! lake build --no-build Mathlib > /tmp/nobuild.log 2>&1; then \
      n="$(grep -c '^- ' /tmp/nobuild.log || true)"; \
      echo "==> $n Mathlib module(s) missing from the cache; building them"; \
      [ "$n" -gt 0 ] && [ "$n" -le 200 ] || { cat /tmp/nobuild.log; exit 1; }; \
    fi; \
    rm -f /tmp/nobuild.log; \
    lake build; \
    lake build repl; \
    lake build --no-build Mathlib Proof repl; \
    chmod -R a+rX /opt/lean "$ELAN_HOME/toolchains"

# Loogle, which searches Mathlib by name, type pattern and subterm, built here
# along with its index of the Mathlib above. lean-lsp-mcp's lean_loogle and the
# main image's `loogle` command then search locally instead of going to
# loogle.lean-lang.org, which lean-lsp-mcp limits to 3 queries per 30 s. Left to
# itself, lean-lsp-mcp would clone and build Loogle in the home volume on first
# use, then index Mathlib again for every project directory, a few minutes and
# several GB of memory each time. The lean-lsp plugin's `start` points it here.
#
# Loogle depends on nothing but Lean. It imports Mathlib when it runs, from
# LEAN_PATH, and in a project lean-init set up that is this Mathlib. The index
# stores the depHash from Mathlib.trace and counts as stale when that changes,
# so one index serves every such project. Loogle's master is built on this
# toolchain rather than the one it pins, as lean-lsp-mcp does too. Only the
# executable, which is static, and the index are kept: 620 MB. Indexing needs
# about 7 GB of memory, here and nowhere else.
#
# It is an extra. If it does not build on this toolchain, the image is made
# without it, and lean_loogle falls back to the remote service.
RUN cd /opt/lean; \
    if git clone -q --depth 1 https://github.com/nomeata/loogle loogle \
       && echo "==> Loogle $(git -C loogle rev-parse --short HEAD) on $LEAN_TOOLCHAIN" \
       && echo "$LEAN_TOOLCHAIN" > loogle/lean-toolchain \
       && (cd loogle && lake build loogle) \
       && (cd project && lake env /opt/lean/loogle/.lake/build/bin/loogle \
             --index-mode write --index-file /opt/lean/loogle/mathlib.idx) \
       && (cd project && lake env /opt/lean/loogle/.lake/build/bin/loogle \
             --index-mode read --index-file /opt/lean/loogle/mathlib.idx \
             --max-results 5 '(?a → ?b) → List ?a → List ?b') | tee /tmp/loogle.out \
       && grep -qw 'List.map' /tmp/loogle.out; \
    then \
      find loogle -mindepth 1 -maxdepth 1 ! -name .lake ! -name mathlib.idx -exec rm -rf {} +; \
      find loogle/.lake -mindepth 1 -maxdepth 2 ! -path loogle/.lake/build ! -path loogle/.lake/build/bin -exec rm -rf {} +; \
      rm -f /tmp/loogle.out; \
      chmod -R a+rX loogle; \
    else \
      echo "==> WARNING: Loogle did not build on $LEAN_TOOLCHAIN; lean_loogle stays remote" >&2; \
      rm -rf loogle /tmp/loogle.out; \
    fi

# lean4-skills (cameronfreer) at its newest release tag, found through the
# release page's redirect rather than api.github.com and its hourly quota.
COPY plugins /opt/lean/plugins
RUN url="$(curl -fsSL -I -o /dev/null -w '%{url_effective}' \
             https://github.com/cameronfreer/lean4-skills/releases/latest)"; \
    tag="${url##*/releases/tag/}"; \
    [ "$tag" != "$url" ] || { echo "lean4-skills has no release ($url)" >&2; exit 1; }; \
    git clone -q --depth 1 --branch "$tag" \
      https://github.com/cameronfreer/lean4-skills /opt/lean/plugins/lean4-skills; \
    rm -rf /opt/lean/plugins/lean4-skills/.git; \
    chmod -R a+rX /opt/lean/plugins

FROM scratch
ARG MATHLIB_REV
ARG LEAN_TOOLCHAIN
COPY --from=build /opt/lean/ /
COPY --from=build /opt/elan/toolchains/ /toolchains/
LABEL org.opencontainers.image.title="Lean 4 and Mathlib for claude-box" \
      org.opencontainers.image.description="Lean $LEAN_TOOLCHAIN with Mathlib $MATHLIB_REV built, the Lean REPL, Loogle and its index, and the claude-box Lean plugins; mounted at /opt/lean, never run" \
      org.claude-box.mathlib="$MATHLIB_REV" \
      org.claude-box.lean-toolchain="$LEAN_TOOLCHAIN"
