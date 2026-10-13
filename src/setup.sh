#!/bin/sh

set -euf
LC_ALL=C
export LC_ALL

# printf: dash's echo turns a \n in a value into a new workflow command.
die() {
	printf '::error::%s\n' "$*"
	exit 1
}

check() {
	value=$1 pattern=$2 input=$3
	[ -z "$value" ] && return
	case $value in
	*[![:print:]]*)
		die "$input: invalid value: it holds a control or non-ASCII character"
		;;
	esac
	printf '%s\n' "$value" | grep -Eqx "$pattern" ||
		die "$input: invalid value '$value'"
}

src=$(cd "$(dirname "$0")" && pwd)
dir=${RUNNER_TEMP:?}/chroot-action

[ -n "${INPUT_SSH_KEY:-}" ] ||
	die "ssh-key is empty: set it from a secret; secrets are not available to pull requests from forks"

check "$INPUT_IMAGE" '[a-z0-9][a-z0-9-]*' image
check "$INPUT_FROM" '[a-z0-9][a-z0-9-]*' from
check "$INPUT_CPUS" '[0-9]+' cpus
check "$INPUT_MEMORY" '[0-9]+[MG]?' memory
check "$INPUT_DISK" '[0-9]+[GT]?' disk
check "$INPUT_SYNC" 'in|both|none' sync
names=
for name in $INPUT_ENV; do
	check "$name" '[A-Za-z_][A-Za-z0-9_]*' env
	names=${names:+$names }$name
done
if [ -n "$INPUT_FROM" ] && [ -n "$INPUT_SETUP" ]; then
	die "setup does not apply with from: the template is already set up"
fi

[ -d "$dir" ] && die "chroot-action already ran in this job"
mkdir -m 700 "$dir"
printf '%s\n' "$INPUT_SYNC" >"$dir/sync"
printf '%s\n' "$names" >"$dir/env"

# ssh refuses a key that lost its final newline or kept CRLFs from a paste.
umask 077
printf '%s\n' "$INPUT_SSH_KEY" | tr -d '\r' >"$dir/key"

vm=gh-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')

cat >"$dir/ssh_config" <<EOF
Host vm
	HostName chroot.run
	User vm+$vm

Host *
	IdentityFile $dir/key
	IdentitiesOnly yes
	UserKnownHostsFile $src/known_hosts
	StrictHostKeyChecking yes
	BatchMode yes
	ControlMaster auto
	ControlPath $dir/cm-%C
	ControlPersist 10m
	ServerAliveInterval 30
	LogLevel ERROR
EOF

# Save the name before asking for the VM: new and cp keep a VM that
# fails to come up, and the post step must still remove it.
echo "vm=$vm" >>"$GITHUB_STATE"
echo "vm-name=$vm" >>"$GITHUB_OUTPUT"

set -- -w
[ -n "$INPUT_CPUS" ] && set -- "$@" -c "$INPUT_CPUS"
[ -n "$INPUT_MEMORY" ] && set -- "$@" -m "$INPUT_MEMORY"
[ -n "$INPUT_DISK" ] && set -- "$@" -d "$INPUT_DISK"

if [ -n "$INPUT_FROM" ]; then
	echo "Copying $INPUT_FROM to $vm"
	ssh -F "$dir/ssh_config" chroot.dev cp "$@" "$INPUT_FROM" "$vm" </dev/null
elif [ -n "$INPUT_SETUP" ]; then
	echo "Creating $vm"
	printf '%s\n' "$INPUT_SETUP" |
		ssh -F "$dir/ssh_config" chroot.dev new "$@" -i "$INPUT_IMAGE" -n "$vm" -s /dev/stdin
else
	echo "Creating $vm"
	ssh -F "$dir/ssh_config" chroot.dev new "$@" -i "$INPUT_IMAGE" -n "$vm" </dev/null
fi

ssh -F "$dir/ssh_config" vm mkdir -p work </dev/null
echo "$(cd "$src/.." && pwd)/bin" >>"$GITHUB_PATH"
