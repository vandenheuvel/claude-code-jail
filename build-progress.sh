#!/usr/bin/env bash
# build-progress.sh -- run an image build and show where it is, on one line.
#
#   build-progress.sh make -s build      what the start-up update check runs
#
# The update check used to run the build with --quiet and its output thrown
# away. That is right for the usual case, every step a cache hit and over in
# seconds, and wrong for the one it exists for: when a release has landed the
# agent layers rebuild, and the terminal sat on "checking for newer agents" for
# minutes with nothing to say whether it was working or hung.
#
# So the output comes here and is read rather than shown. Both engines announce
# every step and say which ones the cache answered, and since cache invalidation
# runs downwards, the first step the cache did *not* answer settles how much is
# left: that one and every one after it. From there one line is redrawn in
# place, once a second whether the build says anything or not -- npm is silent
# for most of an install, and so is committing a layer:
#
#   ==> update found; rebuilding the last 8 of 64 steps
#       [#####---------------] 2/8  0:41  RUN npm install -g @openai/codex ...
#
# When it is done the line gives way to how long it took, and a build that had
# nothing to do leaves no trace at all. If stderr is not a terminal nothing is
# redrawn, and only the two ==> lines are printed. If the build fails, what it
# printed since its last step began is printed, since that is the part saying
# why; everything before it is cache hits.
#
# The two formats read are podman's (buildah's) and BuildKit's --progress=plain,
# which the Makefile asks docker for:
#
#   STEP 57/64: ADD https://...           #12 [57/64] ADD https://...
#   --> Using cache 3a4b...               #12 CACHED
#   --> 3a4b...  (ran, or fetched)        #12 DONE 0.3s
#   COMMIT claude-code:latest             #20 exporting to image
#
# bash rather than sh for `read -t`: redrawing while the build is silent needs a
# read that gives up after a second, and POSIX sh has none.

set -u

[ $# -gt 0 ] || { echo "usage: $0 COMMAND [ARG...]" >&2; exit 2; }

follow() {
	local tty=0 cols=80
	local fmt=''        # podman or buildkit, from the first step header
	local total=0       # steps in the build
	local cur=0         # the step under way
	local what=''       # its instruction, tidied for the status line
	local run=0         # 1 if it is a RUN, whose output is the build's own
	local settled=0     # podman: the cache has said which way that step went
	local first=0       # first step the cache did not answer; 0 while none
	local writing=0     # past the last step, writing the image
	local rc=''         # the build's exit status, sent down after its output
	local -a cached=() from=() vstep=() log=()
	local line held='' s k

	# stty reads the size of the terminal on stdin, so point it at stderr,
	# which is where the line goes.
	winsize() {
		s=$(stty size <&2 2>/dev/null) && cols=${s#* }
		[ "$cols" -gt 20 ] 2>/dev/null || cols=80
	}

	# Clear the status line, so the next thing printed starts at column 0.
	wipe() { [ $tty = 0 ] || printf '\r\033[K' >&2; }

	# A line that stays, printed above the one being redrawn.
	say() { wipe; printf '%s\n' "$*" >&2; draw; }

	draw() {
		[ $tty = 1 ] || return 0
		local t bar rest n i fill
		printf -v t '%d:%02d' $((SECONDS / 60)) $((SECONDS % 60))
		if [ $first -gt 0 ]; then
			n=$((total - first + 1)) i=$((cur - first + 1))
			fill=$(((i - 1) * 20 / n))
			[ $writing = 0 ] || { i=$n fill=20; }
			printf -v bar '%*s' $fill ''
			printf -v rest '%*s' $((20 - fill)) ''
			s="    [${bar// /#}${rest// /-}] $i/$n  $t  $what"
		elif [ $total -gt 0 ]; then
			s="    step $cur/$total  $t  $what"
		else
			s="    $t"
		fi
		[ ${#s} -lt $cols ] || s="${s:0:cols-4}..."
		printf '\r\033[K%s' "$s" >&2
	}

	# Step $1 did not come from the cache. The first such step is where the
	# rebuild starts; FROM is never it, since both engines report pulling or
	# resolving the base image as work done.
	rebuilt() {
		[ "$1" -gt 0 ] && [ $first = 0 ] || return 0
		[ -z "${from[$1]-}" ] && [ -z "${cached[$1]-}" ] || return 0
		first=$1
		say "==> update found; rebuilding the last $((total - first + 1)) of $total steps"
	}

	step() {
		local k=$1 text=$3
		[ "$k" != "$cur" ] || return 0     # BuildKit re-announces a step
		# A podman step that ends with neither verdict is one it ran: the
		# last before COMMIT prints no --> line of its own.
		[ "$fmt" != podman ] || [ $settled = 1 ] || rebuilt $cur
		cur=$k total=$2 settled=0 run=0 log=()
		case $text in
		FROM\ *) from[k]=1 ;;
		RUN\ *) run=1 ;;
		esac
		# RUN --mount=... --network=... npm install -> RUN npm install
		while [[ $text =~ $re_flag ]]; do
			text=${BASH_REMATCH[1]}${BASH_REMATCH[2]}
		done
		while [[ $text == *'  '* ]]; do text=${text//  / }; done
		what=$text
	}

	local re_flag='^([A-Z]+ )--[a-z-]+=[^ ]* +(.*)$'
	local re_podman='^STEP ([0-9]+)/([0-9]+): (.*)$'
	local re_bk_step='^#([0-9]+) \[([^]]* )?([0-9]+)/([0-9]+)\] (.*)$'
	local re_bk='^#([0-9]+) (.*)$'

	take() {
		line=$1
		case $line in
		'@@rc '*) rc=${line#@@rc }; return ;;
		esac
		if [[ $line =~ $re_podman ]]; then
			fmt=podman
			step "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
		elif [ "$fmt" = podman ]; then
			case $line in
			'--> Using cache '*) cached[cur]=1 settled=1 ;;
			'--> '*) rebuilt $cur; settled=1 ;;
			COMMIT*) [ $settled = 1 ] || rebuilt $cur; settled=1 writing=1 what='writing the image' ;;
			# Output while a RUN is undecided is the command running. Only
			# a RUN: an ADD that cannot reach the registry prints an error
			# here too, and that is not an update.
			?*) [ $run = 0 ] || [ $settled = 1 ] || rebuilt $cur ;;
			esac
		elif [[ $line =~ $re_bk_step ]]; then
			fmt=buildkit
			vstep[BASH_REMATCH[1]]=${BASH_REMATCH[3]}
			step "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}"
		elif [[ $line =~ $re_bk ]]; then
			k=${vstep[BASH_REMATCH[1]]-0}
			case ${BASH_REMATCH[2]} in
			CACHED) cached[k]=1 ;;
			ERROR*|CANCELED) ;;
			'exporting to image'*) writing=1 what='writing the image' ;;
			*) rebuilt "$k" ;;          # DONE, or a line of its output
			esac
		fi
		if [ -n "$line" ]; then
			log+=("$line")
			[ ${#log[@]} -le 40 ] || log=("${log[@]:1}")
		fi
		draw
	}

	if [ -t 2 ]; then
		tty=1
		winsize
		trap winsize WINCH
		trap 'wipe; exit 130' INT
		trap 'wipe; exit 143' TERM
	fi

	# A read that times out keeps what it had of a line; that is held until
	# the rest of the line arrives, and the status line is redrawn meanwhile.
	while :; do
		if IFS= read -r -t 1 line; then
			take "$held$line"
			held=''
		elif [ $? -gt 128 ]; then
			held=$held$line
			draw
		else
			[ -z "$held$line" ] || take "$held$line"
			break
		fi
	done

	wipe
	[ -n "$rc" ] || rc=1
	if [ "$rc" = 0 ]; then
		[ $first = 0 ] || printf '==> image updated in %d:%02d\n' \
			$((SECONDS / 60)) $((SECONDS % 60)) >&2
	elif [ ${#log[@]} -gt 0 ]; then
		printf '%s\n' "${log[@]}" >&2
	fi
	return "$rc"
}

# The build's exit status goes down the pipe after its output, so the reader
# knows whether to print the failure and can exit with it. The newline ends a
# last line the build left unterminated.
{ "$@" 2>&1; printf '\n@@rc %d\n' $?; } | follow
