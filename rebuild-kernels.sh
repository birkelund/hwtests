#!/bin/bash

set -euo pipefail

source common/rc

me=${0##*/}

spawn_id=

DONE="[32;1mDONE[0m"
FAILED="[31;1mFAILED[0m"

targetdir="$(pwd)"
quiet=
override_linux=

usage()
{
	cat <<EOF
$me

Usage: $me [OPTION] TARGET ...

Known values for OPTION are:

    -h|--help                   display this help and exit
    -q|--quiet                  all outputs are redirected to a logfile per machine
    -t|--targetdir <DIR>        target directory (default: "$targetdir")
       --override-linux <DIR>	linux sources

Default targets are:

    ${TARGETS[@]}

EOF
exit 1
}

# runtime dependencies
for cmd in jq expect; do
	if ! command -v $cmd &> /dev/null; then
		echo "$me: please install '$cmd' command"
		exit 1
	fi
done

shortargs="hqt:c:"
longargs="help,quiet,targetdir:,override-linux:"

if ! tmp=$(getopt -o "$shortargs" -l "$longargs" -- "$@"); then
	usage
fi

eval set -- "$tmp"
unset tmp

while true; do
	case "$1" in
		"-h" | "--help" )
			usage
			;;

		"-q" | "--quiet" )
			quiet=1
			shift 1
			;;

		"-t" | "--targetdir" )
			targetdir="$2"
			shift 2
			;;

		"--override-linux" )
			override_linux="$2"
			shift 2
			;;

		"--" )
			shift 1
			break
			;;

		* )
			break
			;;
	esac
done

linux_reconfigure()
{
	expect - <<EOF 2>&3

set timeout -1

proc error {MSG} {
	puts -nonewline stderr " \$MSG"
}

proc info {MSG} {
	puts -nonewline stderr " \$MSG"
}

spawn -noecho make linux-reconfigure

expect {
	"make: \*\*\* * Error" {
		error "MAKE"
		exit 1
	}

	">>> linux-headers*Syncing from source dir" {
		info "headers"
		exp_continue
	}

	">>> linux-headers" {
		exp_continue
	}

	">>> linux*Syncing from source dir" {
		info "sync"
		exp_continue
	}

	">>> linux*Configuring" {
		info "configure"
		exp_continue
	}

	">>> linux*Building" {
		info "build"
		exp_continue
	}

	">>> linux*Installing to target" {
		info "target"
		exp_continue
	}

	">>> linux*Installing to images directory" {
		info "image"
		exp_continue
	}

	eof
}

spawn -noecho make all

expect {
	"make: \*\*\* * Error" {
		error "MAKE"
		exit 1
	}

	">>>   Generation filesystem image" {
		info "rootfs"
		exp_continue
	}

	">>>   Executing post-image script" {
		info "postimage"
		exp_continue
	}

	eof
}

EOF
}

exec 3>&1

targets=(${*:-"${TARGETS[@]}"})

for target in "${targets[@]}"; do
	logfile="linux-reconfigure.${target}.log"

	rm -f "$logfile"

	if [ -n "$quiet" ]; then
		exec 1>>"$logfile" 2>&1
	fi

	echo -n "linux-reconfigure $target:" >&3

	pushd "${targetdir}/${target}" >/dev/null

	rm -f "local.mk"

	if [ -n "$override_linux" ]; then
		echo "LINUX_OVERRIDE_SRCDIR = $override_linux" >"local.mk"
	fi

	begin=$(date +%s)
	linux_reconfigure && pass=$DONE || pass=$FAILED
	end=$(date +%s)
	echo " $pass $((end - begin))s" >&3

	popd >/dev/null
done
