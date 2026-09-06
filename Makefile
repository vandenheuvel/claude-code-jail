# Build and run the Claude Code workstation image.
#
#   make              Claude Code on the current directory (builds first if needed)
#   make install      put a `claude-box` launcher on PATH, for use from anywhere
#   make shell        bash in the image instead of Claude Code
#   make bench        shell with the capabilities perf and bpftrace need
#   make update       refresh Claude Code (also checked before every run)
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
  # podman builds OCI format by default, and there the Dockerfile's SHELL
  # directive is ignored with only a warning -- silently dropping `set -e` and
  # `pipefail` from every RUN in the build, which is exactly the masking that
  # SHELL line exists to prevent.
  FORMAT    := --format docker
else
  BUILD_UID := $(shell id -u)
  BUILD_GID := $(shell id -g)
  USERNS    :=
  FORMAT    :=
endif

# Directory to mount at /workspace.
WORK    ?= $(CURDIR)

# Named volume for /home/claude, so credentials, ~/.claude settings, shell
# history and cargo/uv caches survive `--rm`.
HOMEVOL ?= claude-home

# Extra args appended to the run command, e.g. `make RUNARGS=--network=none`.
RUNARGS ?=

# Environment forwarded into the container when set on the host.
ENVPASS := ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL \
           CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX \
           AWS_PROFILE AWS_REGION GH_TOKEN GITHUB_TOKEN OPENAI_API_KEY \
           HF_TOKEN http_proxy https_proxy no_proxy
ENVFLAGS = $(foreach v,$(ENVPASS),$(if $($(v)),-e $(v)))

# Host git identity, read-only. Without it every commit Claude Code makes fails
# on an unset user.email.
GITFLAGS := $(if $(wildcard $(HOME)/.gitconfig),-v $(HOME)/.gitconfig:/home/claude/.gitconfig:ro)

# Start-up update check. The Dockerfile ends with an ADD of the registry's
# `latest` metadata for Claude Code, so the published version is that layer's
# cache key: re-running the build is a cache hit all the way down until a new
# release appears, and only then does one npm layer rebuild. Nothing in the
# toolchain is compiled again. UPDATE=0 skips the check for a single run;
# UPDATE_AGE=N checks at most once every N minutes, remembered in a stamp file.
UPDATE     ?= 1
UPDATE_AGE ?= 0
STAMPDIR   ?= $(HOME)/.cache/claude-box
STAMP      := $(STAMPDIR)/updated-$(subst :,_,$(subst /,_,$(REF)))

BUILDARGS ?=
BUILD = DOCKER_BUILDKIT=1 $(ENGINE) build $(FORMAT) \
          --build-arg USER_UID=$(BUILD_UID) --build-arg USER_GID=$(BUILD_GID) \
          $(BUILDARGS) -t $(REF) $(CTX)

# Attach a terminal only when there is one. `claude-box -p '...'` from a script
# or a pipe has no tty, and -it there makes the engine warn and Claude Code
# render escape codes into the captured output.
TTYFLAGS := $(shell [ -t 0 ] && echo -it || echo -i)

# --shm-size: the default /dev/shm is 64 MB, which Chromium outgrows the moment
# a page is non-trivial. Cheap to raise, annoying to diagnose.
RUN = $(ENGINE) run --rm $(TTYFLAGS) \
        --shm-size=1g $(USERNS) \
        -v "$(WORK)":/workspace \
        -v $(HOMEVOL):/home/claude \
        $(GITFLAGS) $(ENVFLAGS) $(RUNARGS)

.DEFAULT_GOAL := run
.PHONY: run image home update check-update build slim minimal rebuild shell \
        bench versions size install push pull clean help

## run: Claude Code on $(WORK) -- the default target
run: check-update home
	$(RUN) $(REF) $(ARGS)

# Build only when the image is absent, so the first `make` is self-contained
# and every later one starts in a second. `make build` forces a rebuild.
image:
	@$(ENGINE) image inspect $(REF) >/dev/null 2>&1 || { \
	  echo "==> $(REF) not found; building it once (this takes a while)"; \
	  $(MAKE) -f $(THIS) build; }

## update: pull a newer Claude Code into the image -- no full rebuild
update:
	$(MAKE) -f $(THIS) build

# The same check, quiet and throttled, in front of every session. It must never
# be the reason the container will not start: a flight with no network, or a
# registry hiccup, warns and runs the image that is already here.
check-update: image
ifneq ($(UPDATE),0)
	@if [ "$(UPDATE_AGE)" -gt 0 ] 2>/dev/null \
	   && [ -n "$$(find '$(STAMP)' -newermt '-$(UPDATE_AGE) minutes' 2>/dev/null)" ]; then :; else \
	  echo "==> checking for a newer Claude Code (a moment, longer if there is one)"; \
	  if $(MAKE) -s -f $(THIS) build BUILDARGS=--quiet >/dev/null; then \
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

## minimal: languages and core CLI only -- no LaTeX, R, browser, Quarto or Ghidra
minimal: BUILDARGS += --build-arg WITH_LATEX=0 --build-arg WITH_R=0 \
                      --build-arg WITH_BROWSERS=0 --build-arg WITH_QUARTO=0 \
                      --build-arg WITH_GHIDRA=0
minimal: build

## rebuild: build ignoring the layer cache
rebuild: BUILDARGS += --no-cache --pull
rebuild: build

## shell: bash in the image instead of Claude Code
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
	@$(ENGINE) run --rm --entrypoint bash $(REF) -c '\
	  for c in "claude --version" "python3 --version" "rustc --version" \
	           "Rscript --version" "node --version" "quarto --version" \
	           "gh --version" "duckdb --version" "hyperfine --version" \
	           "valgrind --version" "perf --version" \
	           "chromium --version" "playwright --version"; do \
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

## clean: remove the image and the persistent home volume
# The home volume holds the container's Claude Code login. Removing it means
# logging in again on the next run.
clean:
	-$(ENGINE) rmi $(REF)
	-$(ENGINE) volume rm $(HOMEVOL)

help:
	@echo "Targets:"
	@grep -E '^## ' $(THIS) | sed 's/^## /  /'
	@echo
	@echo "Engine:    $(ENGINE)$(if $(IS_PODMAN), (rootless podman: keep-id + --format docker))"
	@echo "Variables: IMAGE=$(IMAGE) WORK=$(WORK) HOMEVOL=$(HOMEVOL) BINDIR=$(BINDIR)"
	@echo "           UPDATE=$(UPDATE) UPDATE_AGE=$(UPDATE_AGE) (start-up update check)"
	@echo
	@echo "Examples:"
	@echo "  make                                  Claude Code on the current directory"
	@echo "  make ARGS='--dangerously-skip-permissions'"
	@echo "  make WORK=~/src/myproject"
	@echo "  make UPDATE=0                         start now, skip the update check"
	@echo "  make UPDATE_AGE=720                   check at most twice a day"
	@echo "  make build BUILDARGS='--build-arg WITH_TORCH=1'"
