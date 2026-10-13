#!/bin/sh

set -euf
LC_ALL=C
export LC_ALL

dir=${RUNNER_TEMP:?}/chroot-action
vm=${STATE_vm:-}
rc=0

# A ::save-state line in the step output can also set the state.
case $vm in
'') ;;
gh-"${GITHUB_RUN_ID:-}-${GITHUB_RUN_ATTEMPT:-}"-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
	echo "Removing $vm"
	# FIX: fcm has no TTL for VMs; a runner that dies before this line
	# leaves the Job VM running, counted against the account's limits.
	if ! ssh -F "$dir/ssh_config" chroot.dev rm "$vm" </dev/null; then
		echo "::error::could not remove $vm; remove it with: ssh chroot.dev rm $vm"
		rc=1
	fi
	;;
*)
	echo "::error::not removing the VM in the post state: it is not the name this job generated"
	rc=1
	;;
esac

if [ -f "$dir/ssh_config" ]; then
	ssh -F "$dir/ssh_config" -O exit vm 2>/dev/null || true
	ssh -F "$dir/ssh_config" -O exit chroot.dev 2>/dev/null || true
fi
rm -rf "$dir"
exit "$rc"
