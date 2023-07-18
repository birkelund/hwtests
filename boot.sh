#!/bin/bash
#
# boot.sh: boot QEMU machines using a pci attached nvme device.
#
# Based on Cédric Le Goater's aspeed-boot.sh script:
#   https://github.com/legoater/qemu-aspeed-boot/blob/master/aspeed-boot.sh
#
# This work is licensed under the terms of the GNU GPL version 2. See
# the COPYING file in the top-level directory.

me=${0##*/}

qemu_bindir="/usr/bin"
basedir="."
quiet=
verbose=
dryrun=
stop_step=
trace=
config="./config.json"
timeout=200
iothread=
ioeventfd=
iterations=1

default_archs="aarch64 mips32 mips32el mips64 mips64el ppc64 ppc64le riscv32 riscv64 sparc64 x86_64"
default_nvme_params="serial=default,drive=d0"

PASSED="[32;1mPASSED[0m"
FAILED="[31;1mFAILED[0m"
WARN="[33;1mWARN[0m"

usage()
{
	cat <<EOF
$me 2.0

Usage: $me [OPTION] <machine> ...

Known values for OPTION are:

    -h|--help                   display this help and exit
    -q|--quiet                  all outputs are redirected to a logfile per machine
    -v|--verbose                enable nvme tracing output
    -p|--qemu-bindir <DIR>      QEMU system binary directory (default: "$qemu_bindir")
    -b|--basedir <DIR>          base directory (default: "$basedir")
    -c|--config <FILE>          configuration file (default: "$config")
    -n|--dry-run                trial run
    -t|--trace                  add pci_nvme* tracing
    -s|--step <STEP>            stop at step (i.e. rootfs, net, ...)
    -o|--option <OPTION>        enable option (iothread,...)
                                may be specified multiple times
    -i|--iterations <N>         number of loops per configuration

Default architectures are:

    $default_archs

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

shortargs="hqvp:b:ns:c:t:o:i:"
longargs="help,quiet,verbose,basedir:,qemu-bindir:,dry-run,step:,config:,trace:,option:,iterations:"

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

		"-v" | "--verbose" )
			verbose=1
			shift 1
			;;

		"-p" | "--qemu-bindir" )
			qemu_builddir="$2"
			shift 2
			;;

		"-b" | "--basedir" )
			basedir="$2"
			shift 2
			;;

		"-n" | "--dry-run" )
			dryrun=1
			shift 1
			;;

		"-s" | "--step" )
			stop_step="$2"
			shift 2
			;;

		"-c" | "--config" )
			config="$2"
			shift 2
			;;

		"-t" | "--trace" )
			trace=1
			shift 1
			;;

		"-i" | "--iterations" )
			iterations="$2"
			shift 2
			;;

		"-o" | "--option" )
			case "$2" in
				"iothread" )
					iothread=1
					;;

				"ioeventfd" )
					ioeventfd=1
					;;

				* )
					echo "$me: unknown boot option '$2'"
					exit 1
					;;
			esac
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

# sanitize
if [ -n "$verbose" ] && [ -n "$quiet" ]; then
	quiet=
fi

spawn_qemu()
{
	qemu_args=()

	# snapshot the rootfs making changes ephemeral
	qemu_args+=("-nodefaults" "-nographic" "-snapshot" "-no-reboot")

	# machine/board
	qemu_args+=("-M" "\"$machine\"")

	# cpu (if set)
	if [ "$cpu" != "null" ]; then
		qemu_args+=("-cpu" "\"$cpu\"")
	fi

	# memory
	if [ "$memory" == "null" ]; then
		memory="512M"
	fi

	# emulator
	emulator="$name"
	if [ "$arch" != "null" ]; then
		emulator="$arch"
	fi

	if [ "$buildroot" == "null" ]; then
		buildroot="$name"
	fi

	qemu_args+=("-m" "$memory")

	# nic
	case "$nic" in
		"virtio" )
			qemu_args+=("-nic" "user,model=virtio")
			;;

		"e1000" )
			qemu_args+=("-nic" "user,model=e1000")
			;;

		"pcnet" )
			qemu_args+=("-nic" "user,model=pcnet")
			;;

		# riscv machines doesnt understand the -nic shortcut
		"virtio-netdev" )
			qemu_args+=("-netdev" "user,id=net0")
			qemu_args+=("-device" "virtio-net-device,netdev=net0")
			;;
	esac

	# boot drive
	if [ "$bootimg" == "null" ]; then
		bootimg="rootfs.ext2"
	fi
	qemu_args+=("-drive" "file=${basedir}/${buildroot}/images/${bootimg},format=raw,if=none,id=d0")

	local nvme_params="$default_nvme_params"
	if [ "$extra_nvme_params" != "null" ]; then
		nvme_params="$nvme_params,$extra_nvme_params"
	fi

	if [ -n "$ioeventfd" ]; then
		nvme_params="$nvme_params,ioeventfd=on"
	fi

	if [ -n "$iothread" ]; then
		qemu_args+=("-object" "iothread,id=nvme")
		nvme_params="$nvme_params,iothread=nvme"
	fi

	qemu_args+=("-device" "nvme,$nvme_params")

	# kernel image
	qemu_args+=("-kernel" "${basedir}/${buildroot}/images/${kernel}")

	# kernel parameters
	if [ "$console" == "null" ]; then
		console="ttyS0"
	fi

	local kernel_params="root=/dev/nvme0n1 console=$console,115200"

	if [ "$extra_kernel_params" != "null" ]; then
		kernel_params="$kernel_params $extra_kernel_params"
	fi

	qemu_args+=("-append" "\"$kernel_params\"")

	if [ -n "$trace" ]; then
		qemu_args+=("-trace" "\"pci_nvme*\"")
	fi

	# serial console on stdout
	qemu_args+=("-serial" "stdio")

	if [ -n "$verbose" ]; then
		qemu_args+=("-trace" "pci_nvme*")
	fi

	if [ -n "$dryrun" ]; then
		echo "${qemu_builddir}/qemu-system-${emulator} ${qemu_args[*]}"
		exit 1
	fi

	expect - <<EOF 2>&3
set timeout $timeout

proc check_step {STEP} {
	if { [ string compare ${stop_step:-"null"} \$STEP ] == 0 } {
		exit 0
	}
}

proc error {MSG} {
	puts -nonewline stderr "\033\[1;31m\$MSG\033\[0m"
}

proc info {MSG} {
	puts -nonewline stderr "\$MSG"
}

proc warn {MSG} {
	puts -nonewline stderr "\033\[01;33m\$MSG\033\[0m"
}

spawn ${qemu_builddir}/qemu-system-${emulator} ${qemu_args[@]}

expect {
	timeout {
		error " TIMEOUT"
		exit 1
	}

	"Kernel panic" {
		error " PANIC"
		exit 2
	}

	"nobody cared" {
		warn " SPURIOUS IRQ"
		exp_continue
	}

	"BUG: soft lockup - CPU" {
		error " STALL"
		exit 3
	}

	"self-detected stall on CPU" {
		error " STALL"
		exit 3
	}

	"illegal instruction" {
		error " SIGILL"
		exit 4
	}

	"Segmentation fault" {
		error " SEGV"
		exit 5
	}

        "timeout, completion polled" {
                error " NVME TIMEOUT"
                exit 6
        }

	"timeout, aborting" {
		error " NVME ABORT"
		exit 7
	}

	"Linux version" {
		info " linux"
		check_step "linux"
		exp_continue
	}

	"(nvme0n1): mounted filesystem" {
		info " rootfs"
		check_step "rootfs"
		exp_continue
	}

	"/init as init" {
		info " init"
		check_step "init"
		exp_continue
	}

	"(nvme0n1): re-mounted" {
		info " remount"
		check_step "remount"
		exp_continue
	}

	"lease of 10.0.2.15" {
		info " net"
		check_step "net"
		exp_continue
	}

	"login:" {
		info " login"
		check_step "login"
	}
}

send "root\r"

expect {
	timeout {
		error " TIMEOUT"
		exit 1
	}

        "timeout, completion polled" {
                error " NVME TIMEOUT"
                exit 6
        }

	"timeout, aborting" {
		error " NVME ABORT"
		exit 7
	}

	"nobody cared" {
		warn " SPURIOUS IRQ"
		exp_continue
	}

	"#" {
		info " shell"
		check_step "shell"
	}
}

send "poweroff\r"

expect {
	timeout {
		error " TIMEOUT"
		exit 1
	}

        "timeout, completion polled" {
                error " NVME TIMEOUT"
                exit 6
        }

	"timeout, aborting" {
		error " NVME ABORT"
		exit 7
	}

	"nobody cared" {
		warn " SPURIOUS IRQ"
		exp_continue
	}

	"reboot: Power down" {
		info " poweroff"
		exit 0
	}

	"reboot: System halted" {
		info " poweroff"
		exit 0
	}
}

expect -i $spawn_id eof
EOF
}

tests_archs=${*:-"$default_archs"}

exec 3>&1

for a in $tests_archs; do
	for i in $(seq -f "%03g" 1 $iterations); do
	logfile="${a}.log"

	rm -f "$logfile"

	jq -c ".[] | select(.name==\"$a\")" "$config" | while read -r entry; do
		for field in name buildroot arch machine cpu memory bootimg kernel nic console extra_nvme_params extra_kernel_params; do
			eval $field=\""$(echo "$entry" | jq -r .$field)"\"
		done

		if [ -n "$quiet" ]; then
			exec 1>>"$logfile" 2>&1
		fi

		printf "boot %s (%s/%03d):" "$a" "$i" "$iterations" >&3

		begin=$(date +%s)
		if spawn_qemu; then
			pass=$PASSED
		else
			pass=$FAILED
			cp $logfile failed.log
		fi
		end=$(date +%s)
		echo " $pass ($((end-begin))s)" >&3
	done
	done
done
