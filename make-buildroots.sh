#!/bin/bash

set -euo pipefail

source common/rc

me=${0##*/}

spawn_id=

basedir=
targetdir="./targets"
quiet=

usage()
{
	cat <<EOF
$me

Usage: $me [OPTION] TARGET ...

Known values for OPTION are:

    -h|--help                   display this help and exit
    -q|--quiet                  all outputs are redirected to a logfile per machine
    -b|--basedir <DIR>          buildroot base directory
    -t|--targetdir <DIR>        target directory (default: "$targetdir")

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

shortargs="hqb:t:"
longargs="help,quiet,basedir:,targetdir:"

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

		"-b" | "--basedir" )
			basedir="$2"
			shift 2
			;;

		"-t" | "--targetdir" )
			targetdir="$2"
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

if [ -z "$basedir" ]; then
	>2 echo "$me: missing buildroot base directory"
	exit 1
fi

export PATH="${basedir}/utils:${PATH}"
export BR2_EXTERNAL="$(pwd)/br2-external"

pushd "${basedir}" >/dev/null

targets=(${*:-"${TARGETS[@]}"})

for target in "${targets[@]}"; do
	defconfig="$(jq -rc ".[] | select(.name == \"$target\") | .defconfig" config.json)"

	make O="${targetdir}/${target}" "$defconfig"

	echo "building $target using $defconfig"
	pushd "${targetdir}/${target}" >/dev/null

	brmake

	popd >/dev/null
done

popd >/dev/null
