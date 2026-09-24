# Build and run the Claude Code workstation image.
#
#   make              Claude Code on the current directory (builds first if needed)
#   make codex        Codex instead, same image and same directory
#   make lean         Claude Code with the Lean tools on for this directory
#   make install      put a `claude-box` launcher on PATH, for use from anywhere
#   make shell        bash in the image instead of either agent
#   make bench        shell with the capabilities perf and bpftrace need
#   make update       refresh both agents (also checked before every run)
#   make prune        reclaim the disk earlier builds are still holding
#   make help         everything else
#
# There is nothing to configure before the first run. The engine is detected,
# the image is built if it is missing, and the home volume is created and
# repaired as needed.

IMAGE   ?= claude-code
TAG     ?= latest
REF     := $(IMAGE):$(TAG)

# This file, and the directory holding it. The build context is that directory
# rather than $(CURDIR), so `make -f /path/to/Makefile` works from inside
# whatever project you actually want to mount.
THIS    := $(abspath $(lastword $(MAKEFILE_LIST)))
CTX     := $(patsubst %/,%,$(dir $(THIS)))

# Container engine. podman and docker need different handling to keep a
# bind-mounted /workspace writable, and every conditional below follows from
# which one this is. On a podman host `docker` is a shim for podman, so podman
# is probed first and the shim is never what gets detected.
ENGINE  ?= $(shell command -v podman 2>/dev/null || command -v docker 2>/dev/null)
ifeq ($(ENGINE),)
$(error no container engine found; install podman or docker)
endif
IS_PODMAN := $(findstring podman,$(notdir $(ENGINE)))

ifeq ($(IS_PODMAN),podman)
  # Rootless podman maps the host account to container uid 0 and every other
  # container uid into the subuid range. A bind mount therefore arrives
  # root-owned, and the `claude` user cannot write to it -- which leaves Claude
  # Code able to read a project but not edit a single file in it. keep-id maps
  # the host account onto uid 1000 instead: /workspace becomes writable, and
  # files created inside land on the host owned by the invoking user.
  #
  # It also settles the build uid. A host uid above the subuid range -- 218189
  # against a 65539-entry range, typical for a directory-backed account --
  # cannot be chown'd to during a rootless build, so USER_UID=$(id -u) fails
  # the non-root-user layer outright. Build at 1000 and let keep-id do the
  # mapping at run time, which is where it belongs.
  BUILD_UID := 1000
  BUILD_GID := 1000
  USERNS    := --userns=keep-id:uid=1000,gid=1000
  # See MASKFLAGS below. podman spells it per-path and leaves /sys/firmware
  # and the read-only paths alone; docker's switch is all-or-nothing.
  MASKFLAGS := --security-opt 'unmask=/proc/*'
  # podman builds OCI format by default, and there the Dockerfile's SHELL
  # directive is ignored with only a warning -- silently dropping `set -e` and
  # `pipefail` from every RUN in the build, which is exactly the masking that
  # SHELL line exists to prevent.
  FORMAT    := --format docker
  # A subdirectory of an image mount (see LEANFLAGS): absolute to podman,
  # relative to docker, and under a different name.
  SUBPATH   := subpath=/

  # Rootless podman networks the container with pasta, which builds the
  # namespace by copying the host's default-route interface: its address, and
  # then a default route through its gateway. On a host sitting on one LAN
  # twice -- wired and wifi on the same subnet, a docked laptop -- only one of
  # the two interfaces gets the on-link route for that subnet, and the other's
  # address is left flagged `noprefixroute`. If the default route happens to be
  # on that second interface, pasta copies the address *with* the flag, so the
  # kernel creates no on-link route in the namespace either, and pasta's
  # `default via <gateway>` is then rejected as unreachable. The container comes
  # up with an IPv4 address and not one IPv4 route.
  #
  # Nothing says so. What the agent reports is that it cannot reach its server,
  # which reads like an outage or a bad login: the container's resolv.conf lists
  # pasta's forwarder and the host's IPv4 resolvers first, glibc only ever tries
  # three nameservers, and so every lookup fails -- while IPv6, which pasta
  # configured correctly, works the whole time.
  #
  # Handing pasta the address explicitly makes it assign that address itself
  # rather than clone the host's, without the inherited flag, and the on-link
  # route and the default route both land. Only a host missing the on-link route
  # is touched; everywhere else this is empty and pasta keeps its own defaults.
  PASTAFIX := $(shell \
    set -- $$(ip -4 route show default 2>/dev/null \
      | awk 'NR==1 { for (i = 1; i < NF; i++) { if ($$i == "via") g = $$(i+1); \
                     if ($$i == "dev") d = $$(i+1) } } END { if (g && d) print d, g }'); \
    [ -n "$$1" ] || exit 0; \
    ip -4 route show dev "$$1" scope link 2>/dev/null | grep -q . && exit 0; \
    a=$$(ip -4 -o addr show dev "$$1" scope global 2>/dev/null | awk 'NR==1 { print $$4 }'); \
    [ -n "$$a" ] || exit 0; \
    echo "--network=pasta:-a,$$a,-g,$$2")
else
  BUILD_UID := $(shell id -u)
  BUILD_GID := $(shell id -g)
  USERNS    :=
  FORMAT    :=
  PASTAFIX  :=
  MASKFLAGS := --security-opt systempaths=unconfined
  SUBPATH   := image-subpath=
endif

# Directory to mount, and where it appears inside the container. Both agents
# key their per-project state on the working directory's path -- Claude Code
# its session history, auto-memory and per-project settings, Codex the sessions
# its `resume` picker offers -- so a fixed /workspace made every project the
# same project: `--resume` listed the sessions of all of them, and memory
# written in one was read back in the next. Mounting at the host path gives each
# directory its own, and nesting that under /workspace keeps it clear of
# anything the image owns: ~/src/foo is /workspace/home/you/src/foo.
#
# The shell normalises the path rather than $(abspath), which splits on spaces:
# a relative WORK, or one with a trailing slash, still lands on the same
# sessions as the plain absolute path.
#
# Sessions from before this are filed under /workspace itself, and
# `claude-box WDIR=/workspace --resume` is how to get back to one.
WORK    ?= $(CURDIR)
WDIR    ?= /workspace$(shell cd -- "$(WORK)" 2>/dev/null && pwd)

# Named volume for /home/claude, so credentials, ~/.claude settings, shell
# history and cargo/uv caches survive `--rm`.
HOMEVOL ?= claude-home

# Extra args appended to the run command, e.g. `make RUNARGS=--network=none`.
RUNARGS ?=

# podman rejects a second --network outright rather than letting the later one
# win, so the pasta repair above has to stand down whenever RUNARGS names a
# network of its own -- `--network=none` for a flight, `--network=host` to reach
# a service on the host. Recursive `=`, so RUNARGS is read when the recipe runs
# and a target that appends to it (bench) is seen too.
NETFLAGS = $(if $(findstring --network,$(RUNARGS)),,$(PASTAFIX))

# Environment forwarded into the container when set on the host. OPENAI_API_KEY
# is Codex's API-key path; `codex login` instead writes ~/.codex/auth.json, which
# is in the home volume and so survives --rm like the Claude Code login does.
ENVPASS := ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL \
           CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX \
           AWS_PROFILE AWS_REGION GH_TOKEN GITHUB_TOKEN OPENAI_API_KEY \
           HF_TOKEN http_proxy https_proxy no_proxy
ENVFLAGS = $(foreach v,$(ENVPASS),$(if $($(v)),-e $(v)))

# Host git identity, read-only. Without it every commit Claude Code makes fails
# on an unset user.email.
GITFLAGS := $(if $(wildcard $(HOME)/.gitconfig),-v $(HOME)/.gitconfig:/home/claude/.gitconfig:ro)

# The Lean image (lean/Dockerfile): a toolchain, Mathlib built on it, the REPL
# and the Lean plugins. Once it exists, every container gets it mounted
# read-only at /opt/lean, and its toolchain a second time where the main image's
# elan looks for one. It is mounted rather than layered in because of the copy
# rootless podman makes of each new image under keep-id: an image mount is
# neither remapped nor copied, while Mathlib as a layer made that copy 29 GB and
# 555,000 files rather than 18 GB, after every Claude Code update.
#
# LEANTC is the toolchain as elan names it, leanprover/lean4:v4.34.0, read off
# the image's label; elan keeps it in leanprover--lean4---v4.34.0. Recursive
# `=`, so the inspect runs only when a recipe that starts a container expands
# it, which is after `lean-image` has built the image it reads. No Lean image,
# no mounts, and everything but Lean works as before. The flags are a function
# of their own because a comma inside $(if ...) splits its arguments, and every
# --mount is full of them.
LEANREF     := $(IMAGE)-lean:$(TAG)
MATHLIB_REV ?=
LEANTC       = $(shell $(ENGINE) image inspect $(LEANREF) \
                 --format '{{index .Config.Labels "org.claude-box.lean-toolchain"}}' 2>/dev/null)
leanmount    = --mount type=image,source=$(LEANREF),target=/opt/lean \
               --mount type=image,source=$(LEANREF),target=/opt/elan/toolchains/$(1),$(SUBPATH)toolchains/$(1)
leanflags    = $(if $(1),$(call leanmount,$(1)))
LEANFLAGS    = $(call leanflags,$(subst :,---,$(subst /,--,$(LEANTC))))

# Start-up update check. The Dockerfile ends with an ADD of the registry's
# `latest` metadata for Claude Code and then for Codex, so each published version
# is its own layer's cache key: re-running the build is a cache hit all the way
# down until a new release appears, and only then do npm layers rebuild -- the
# one that published, plus Codex's below it if Claude Code is what moved.
# Nothing in the toolchain is compiled again. UPDATE=0 skips the check
# for a single run; UPDATE_AGE=N checks at most once every N minutes, remembered
# in a stamp file.
UPDATE     ?= 1
UPDATE_AGE ?= 0
STAMPDIR   ?= $(HOME)/.cache/claude-box
STAMP      := $(STAMPDIR)/updated-$(subst :,_,$(subst /,_,$(REF)))

BUILDARGS ?=

# check-update reads the build's log to show how far along it is (see
# build-progress.sh), and needs it one line per event. podman's always is.
# BuildKit's is too when written into a pipe, but only by default, and a
# BUILDKIT_PROGRESS in the environment would change it, so it is asked for.
PLAIN   := $(if $(IS_PODMAN),,--progress=plain)

BUILD = DOCKER_BUILDKIT=1 $(ENGINE) build $(FORMAT) \
          --build-arg USER_UID=$(BUILD_UID) --build-arg USER_GID=$(BUILD_GID) \
          $(BUILDARGS) -t $(REF) $(CTX)

# Attach a terminal only when there is one. `claude-box -p '...'` from a script
# or a pipe has no tty, and -it there makes the engine warn and Claude Code
# render escape codes into the captured output.
TTYFLAGS := $(shell [ -t 0 ] && echo -it || echo -i)

# --shm-size: the default /dev/shm is 64 MB, which Chromium outgrows the moment
# a page is non-trivial. Cheap to raise, annoying to diagnose.
#
# MASKFLAGS is what makes the agents' own sandboxes work, and it is the one
# flag here that trades away a little hardening. Both agents sandbox through
# bubblewrap, and a bwrap sandbox mounts a fresh /proc; the engine masks
# /proc/acpi, /proc/kcore and the rest with locked mounts that a new procfs
# would hide, so the kernel refuses the mount and every sandboxed command dies
# as `bwrap: Can't mount proc on /proc: Operation not permitted`. Unmasking
# /proc is the only thing that lifts it.
#
# The trade is small in the direction this box is usually run: under rootless
# podman the container user is an unprivileged host account, so an unmasked
# /proc/kcore is still unreadable to it, and `unmask=/proc/*` leaves
# /sys/firmware masked. Under rootful docker `systempaths=unconfined` is the
# broader switch -- it drops the read-only paths too -- but a container handing
# out passwordless sudo was never the thing standing between an agent and the
# host anyway. Drop it with MASKFLAGS= if that is not your trade:
#
#   make MASKFLAGS=        # keep the masks, lose both agents' sandboxes
RUN = $(ENGINE) run --rm $(TTYFLAGS) \
        --shm-size=1g $(USERNS) $(MASKFLAGS) \
        -v "$(WORK)":"$(WDIR)" -w "$(WDIR)" \
        -v $(HOMEVOL):/home/claude \
        $(GITFLAGS) $(ENVFLAGS) $(NETFLAGS) $(LEANFLAGS) $(RUNARGS)

.DEFAULT_GOAL := run
.PHONY: run image home update check-update build slim minimal rebuild shell \
        codex lean lean-image lean-update bench versions size install push pull \
        prune clean help

## run: Claude Code on $(WORK) -- the default target
run: check-update home
	$(RUN) $(REF) $(ARGS)

## codex: Codex on $(WORK), in the same image and the same home volume
# The image's ENTRYPOINT is `claude`, so the second agent is an override of it
# rather than a second image -- same mounts, same forwarded environment, same
# /home/claude, so both agents' logins and history sit in the one volume.
# Codex sandboxes its own command execution and needs nothing here to do it
# beyond the MASKFLAGS every target already gets: unlike `bench` this adds no
# capability and relaxes no seccomp profile.
codex: check-update home
	$(RUN) --entrypoint codex $(REF) $(ARGS)

## lean: Claude Code on $(WORK) with the Lean tools on, after lean-init there
# lean-init makes the directory a Lean project on the Lean image's prebuilt
# Mathlib and enables the Lean plugins for it, in its .claude/settings.local.json.
# So this target is only needed once per directory: plain `make` there keeps
# them from then on, and every other directory never loads them. The first one
# anywhere builds the Lean image.
lean: lean-image check-update home
	$(RUN) --entrypoint bash $(REF) -c 'lean-init && exec claude "$$@"' claude $(ARGS)

# The Lean image, built only when it is absent, as `image` is.
lean-image:
	@$(ENGINE) image inspect $(LEANREF) >/dev/null 2>&1 || { \
	  echo "==> $(LEANREF) not found; building it once (Mathlib: this takes a while)"; \
	  $(MAKE) -f $(THIS) lean-update; }

## lean-update: rebuild the Lean image on the newest Mathlib release, or MATHLIB_REV
# The newest v4.* tag that is not a release candidate, and the toolchain it pins,
# are looked up here rather than in the build because the toolchain has to end
# up in a label (see LEANTC), and a label can only come from a build arg. The
# same rev twice is a cache hit, so this is also the cheap way to ask whether
# there is a newer Mathlib. Nothing runs it for you: check-update leaves the
# Lean image alone, so Mathlib never moves under the projects linked to it.
lean-update:
	@rev='$(MATHLIB_REV)'; \
	 [ -n "$$rev" ] || rev=$$(git ls-remote --tags --refs \
	     https://github.com/leanprover-community/mathlib4 'v4.*' \
	   | sed 's|.*/||' | grep -vE -- '-rc' | sort -V | tail -n1); \
	 tc=$$(curl -fsSL "https://raw.githubusercontent.com/leanprover-community/mathlib4/$$rev/lean-toolchain"); \
	 [ -n "$$rev" ] && [ -n "$$tc" ] || { echo "could not resolve Mathlib $$rev" >&2; exit 1; }; \
	 echo "==> Mathlib $$rev on $$tc"; \
	 DOCKER_BUILDKIT=1 $(ENGINE) build $(FORMAT) \
	   --build-arg MATHLIB_REV="$$rev" --build-arg LEAN_TOOLCHAIN="$$tc" \
	   -t $(LEANREF) $(CTX)/lean

# Build only when the image is absent, so the first `make` is self-contained
# and every later one starts in a second. `make build` forces a rebuild.
image:
	@$(ENGINE) image inspect $(REF) >/dev/null 2>&1 || { \
	  echo "==> $(REF) not found; building it once (this takes a while)"; \
	  $(MAKE) -f $(THIS) build; }

## update: pull newer agents into the image -- no full rebuild
update:
	$(MAKE) -f $(THIS) build

# The same check, quiet and throttled, in front of every session. It must never
# be the reason the container will not start: a flight with no network, or a
# registry hiccup, warns and runs the image that is already here.
#
# Quiet means no build log, not no sign of life. build-progress.sh reads the
# log and keeps one line redrawn in place: the step, and how long it has been.
# Nothing stays on screen unless a step misses the cache, and then what does is
# how many steps are left to rebuild and, at the end, how long it took.
check-update: image
ifneq ($(UPDATE),0)
	@if [ "$(UPDATE_AGE)" -gt 0 ] 2>/dev/null \
	   && [ -n "$$(find '$(STAMP)' -newermt '-$(UPDATE_AGE) minutes' 2>/dev/null)" ]; then :; else \
	  echo "==> checking for newer agents"; \
	  if $(CTX)/build-progress.sh $(MAKE) -s -f $(THIS) build BUILDARGS=$(PLAIN); then \
	    mkdir -p '$(STAMPDIR)' && touch '$(STAMP)'; \
	  else \
	    echo "==> update check failed; starting the image as it is"; \
	  fi; \
	fi
endif

# The named volume holding /home/claude. Under keep-id the container's uid 1000
# is the host account, so the volume's contents must be owned by it. podman
# seeds a *fresh* volume correctly, but one first populated without keep-id is
# owned by a subuid, and then Claude Code cannot read its own credentials: it
# reports "Not logged in" with the file sitting right there. Inside
# `podman unshare` uid 0 is the host account, which is what repairs it.
home:
ifeq ($(IS_PODMAN),podman)
	@$(ENGINE) volume inspect $(HOMEVOL) >/dev/null 2>&1 \
	  || $(ENGINE) volume create $(HOMEVOL) >/dev/null
	@d=$$($(ENGINE) volume inspect $(HOMEVOL) --format '{{.Mountpoint}}'); \
	 if [ "$$(stat -c %u "$$d")" != "$$(id -u)" ]; then \
	   echo "==> repairing $(HOMEVOL) ownership for keep-id"; \
	   $(ENGINE) unshare chown -R 0:0 "$$d"; \
	 fi
endif

## build: (re)build the image, every optional component
build:
	$(BUILD)

## slim: skip the three largest optional layers (LaTeX, Ghidra, browser)
slim: BUILDARGS += --build-arg WITH_LATEX=0 --build-arg WITH_GHIDRA=0 --build-arg WITH_BROWSERS=0
slim: build

## minimal: languages and core CLI only -- no LaTeX, R, browser, Quarto, Ghidra or Lean
minimal: BUILDARGS += --build-arg WITH_LATEX=0 --build-arg WITH_R=0 \
                      --build-arg WITH_BROWSERS=0 --build-arg WITH_QUARTO=0 \
                      --build-arg WITH_GHIDRA=0 --build-arg WITH_LEAN=0
minimal: build

## rebuild: build ignoring the layer cache
rebuild: BUILDARGS += --no-cache --pull
rebuild: build

## shell: bash in the image instead of either agent
shell: check-update home
	$(RUN) --entrypoint bash $(REF) $(ARGS)

## bench: shell with the capabilities perf, bpftrace and heaptrack need
# perf_event_paranoid is a host sysctl and cannot be set per container. If perf
# still reports "Access to performance monitoring is limited", the host needs:
#   sudo sysctl kernel.perf_event_paranoid=1
# Pinning to a fixed core and disabling ASLR makes measurements repeatable:
#   taskset -c 2 setarch -R hyperfine ./target/release/bench
bench: RUNARGS += --cap-add=PERFMON --cap-add=SYS_PTRACE --cap-add=SYS_ADMIN \
                  --security-opt seccomp=unconfined --ulimit memlock=-1:-1
bench: shell

## install: put a `claude-box` launcher in $(BINDIR), for use from any directory
# Generated from claude-box.in with this Makefile's path baked in, so the
# launcher keeps working from any directory and there is still exactly one
# place that knows how to start the container.
BINDIR ?= $(HOME)/.local/bin
install:
	@mkdir -p $(BINDIR)
	@sed 's|@MAKEFILE@|$(THIS)|g' $(CTX)/claude-box.in > $(BINDIR)/claude-box
	@chmod 0755 $(BINDIR)/claude-box
	@sh -n $(BINDIR)/claude-box
	@echo "installed $(BINDIR)/claude-box -- run it from any project directory"
	@case ":$$PATH:" in *":$(BINDIR):"*) ;; \
	  *) echo "note: $(BINDIR) is not on PATH";; esac

## versions: print the versions of the headline tools
# Deliberately `bash -c`, not `bash -lc`: Debian's /etc/profile overwrites PATH.
versions: image
	@$(ENGINE) run --rm $(LEANFLAGS) --entrypoint bash $(REF) -c '\
	  for c in "claude --version" "codex --version" "python3 --version" "rustc --version" \
	           "Rscript --version" "node --version" "quarto --version" \
	           "gh --version" "duckdb --version" "hyperfine --version" \
	           "valgrind --version" "perf --version" "bwrap --version" \
	           "chromium --version" "playwright --version" \
	           "lean --version" "lake --version" "lean-lsp-mcp --version"; do \
	    printf "%-22s %s\n" "$${c%% *}" "$$($$c 2>&1 | head -n1)"; \
	  done'

## size: per-layer size breakdown, largest last
size: image
	@$(ENGINE) history --human --format '{{.Size}}\t{{.CreatedBy}}' $(REF) \
	  | sed 's/#(nop) *//' | cut -c1-140

## push / pull: move the image to and from a registry (set IMAGE=host/name)
push:
	$(ENGINE) push $(REF)
pull:
	$(ENGINE) pull $(REF)

## prune: delete the untagged images earlier builds left behind
# A rebuild that changes one layer leaves the whole previous image behind,
# untagged and complete -- twenty-odd gigabytes of it. Under rootless podman
# there is a second, ID-mapped copy of each image beside it (the chown'd
# duplicate keep-id needs), so a single stale build can be holding 40 GB.
# Nothing collects them on its own.
#
# The first symptom of that filling a disk is not a message about disk. It is an
# `npm install` that half-unpacks a package, or a chown that stops mid-layer, in
# a step with no obvious connection to the real cause. So this is worth running
# after a few rebuilds, and it is the first thing to try when a build fails
# somewhere it has never failed before.
#
# Only untagged images go, and only ones no container is using. $(REF), the home
# volume with its login in it, and the BuildKit cache mounts -- apt, uv, npm and
# the cargo registry, which are why a rebuild re-downloads almost nothing -- are
# all left alone. `make clean` is the one that removes the image itself.
#
# Free disk is what gets reported, not `system df`'s reclaimable column: that
# column counts every image no *running* container is using, so it includes
# $(REF) and barely moves here, which reads like the prune did nothing.
prune:
	@root=$$($(ENGINE) info --format '{{.Store.GraphRoot}}' 2>/dev/null \
	      || $(ENGINE) info --format '{{.DockerRootDir}}' 2>/dev/null); \
	 free() { df -h "$$root" | awk 'NR==2 {print $$4}'; }; \
	 before=$$(free); \
	 $(ENGINE) image prune -f; \
	 echo "==> free on $$root: $$before -> $$(free)"

## clean: remove both images and the persistent home volume
# The home volume holds the container's Claude Code login. Removing it means
# logging in again on the next run.
clean:
	-$(ENGINE) rmi $(REF) $(LEANREF)
	-$(ENGINE) volume rm $(HOMEVOL)

help:
	@echo "Targets:"
	@grep -E '^## ' $(THIS) | sed 's/^## /  /'
	@echo
	@echo "Engine:    $(ENGINE)$(if $(IS_PODMAN), (rootless podman: keep-id + --format docker))"
	@echo "Variables: IMAGE=$(IMAGE) WORK=$(WORK) HOMEVOL=$(HOMEVOL) BINDIR=$(BINDIR)"
	@echo "           WDIR=$(WDIR) (WORK inside the container)"
	@echo "           UPDATE=$(UPDATE) UPDATE_AGE=$(UPDATE_AGE) (start-up update check)"
	@echo
	@echo "Examples:"
	@echo "  make                                  Claude Code on the current directory"
	@echo "  make codex                            Codex on the current directory"
	@echo "  make lean                             Claude Code with the Lean tools on"
	@echo "  make lean-update MATHLIB_REV=v4.33.0  the Lean image on another Mathlib"
	@echo "  make ARGS='--dangerously-skip-permissions'"
	@echo "  make codex ARGS='--dangerously-bypass-approvals-and-sandbox'"
	@echo "  make WORK=~/src/myproject"
	@echo "  make UPDATE=0                         start now, skip the update check"
	@echo "  make UPDATE_AGE=720                   check at most twice a day"
	@echo "  make build BUILDARGS='--build-arg WITH_TORCH=1'"
