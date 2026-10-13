#!/bin/sh
# sync: both without a Job VM: a fake ssh plays the guest.

set -euf

root=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'chmod -R u+rwX "$T"; rm -rf "$T"' EXIT
nl='
'
cr=$(printf '\r')
failed=0

mkdir "$T/bin"
cat >"$T/bin/ssh" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do
	case $1 in
	-F) shift 2 ;;
	-*) shift ;;
	*) break ;;
	esac
done
shift
cd "$FAKE_GUEST" || exit 255
HOME=$FAKE_GUEST
export HOME
case $1 in
'cat >.chroot-step') exec cat >.chroot-step ;;
'sh -e -o pipefail .chroot-step') exec sh -e .chroot-step ;;
'cd work && tar cf - .')
	[ -z "${FAKE_PULL:-}" ] || exec cat "$FAKE_PULL"
	cd work && exec tar cf - .
	;;
openrsync)
	shift
	exec rsync "$@"
	;;
esac
echo "fake ssh: unexpected command: $*" >&2
exit 255
EOF
chmod +x "$T/bin/ssh"
PATH=$T/bin:$PATH

fresh() {
	c=$T/$1
	mkdir -p "$c/ws" "$c/rt/chroot-action" "$c/guest/work" "$c/out" "$c/s"
	: >"$c/rt/chroot-action/ssh_config"
	echo both >"$c/rt/chroot-action/sync"
	: >"$c/rt/chroot-action/env"
	echo true >"$c/script"
	why=
}

step() {
	rc=0
	FAKE_GUEST=$c/guest FAKE_PULL=${1:-} RUNNER_TEMP=$c/rt \
		GITHUB_WORKSPACE=$c/ws "$root/bin/chroot" "$c/script" \
		>"$c/log" 2>&1 || rc=$?
}

outside() {
	(
		cd "$c"
		find . \( -path ./ws -o -path ./guest -o -path ./s -o -name '*.tar' \
			-o -path ./log -o -path ./script -o -path ./rt/chroot-action/step \) \
			-prune -o -print | LC_ALL=C sort
		find out rt -type f ! -path rt/chroot-action/step -exec cksum {} +
	)
}

expect() {
	text=$1
	shift
	"$@" || why=${why:-$text}
}

warnings() {
	grep '^::warning::' "$c/log" | LC_ALL=C sort || true
}

done_case() {
	if [ -z "$why" ]; then
		echo "ok $1 - $2"
	else
		echo "FAIL $1 - $2: $why"
		sed 's/^/	| /' "$c/log"
		failed=1
	fi
}

case1() {
	fresh 1
	ln -s "$c/out" "$c/s/x"
	tar cf "$c/1.tar" -C "$c/s" .
	rm "$c/s/x"
	mkdir "$c/s/x"
	echo pulled >"$c/s/x/FILE"
	tar cf "$c/2.tar" -C "$c/s" --no-recursion ./x/FILE
	before=$(outside)
	step "$c/1.tar"
	step "$c/2.tar"
	expect 'something written outside the Workspace' test "$before" = "$(outside)"
	expect 'x/FILE not in the Workspace' test -f "$c/ws/x/FILE"
	done_case 1 'symlink in one Pull, a member under it in the next'
}

case2() {
	fresh 2
	ln -s "$c/out" "$c/ws/x"
	mkdir "$c/s/x"
	echo pulled >"$c/s/x/FILE"
	tar cf "$c/2.tar" -C "$c/s" --no-recursion ./x/FILE
	before=$(outside)
	step "$c/2.tar"
	expect 'something written outside the Workspace' test "$before" = "$(outside)"
	done_case 2 'Workspace symlink from the checkout, a member under it'
}

gitstate() {
	(
		cd "$c/ws"
		find .git -exec ls -ld {} + | awk '{ print $1, $NF }'
		find .git -type f -exec cksum {} +
	)
}

case3() {
	fresh 3
	mkdir -p "$c/ws/.git/hooks"
	printf '[core]\n\tbare = false\n' >"$c/ws/.git/config"
	echo 'ref: refs/heads/main' >"$c/ws/.git/HEAD"
	mkdir -p "$c/s/.git/hooks" "$c/s/sub" "$c/s/dir/.git"
	printf '[core]\n\tfsmonitor = touch %s/pwned\n' "$c/out" >"$c/s/.git/config"
	printf '#!/bin/sh\ntouch %s/pwned\n' "$c/out" >"$c/s/.git/hooks/post-checkout"
	chmod +x "$c/s/.git/hooks/post-checkout"
	echo 'gitdir: /tmp' >"$c/s/sub/.git"
	printf '[core]\n\thooksPath = /tmp\n' >"$c/s/dir/.git/config"
	echo kept >"$c/s/keep"
	tar cf "$c/1.tar" -C "$c/s" .
	before=$(gitstate)
	step "$c/1.tar"
	expect 'the Workspace .git changed' test "$before" = "$(gitstate)"
	expect 'sub/.git added' test ! -e "$c/ws/sub/.git"
	expect 'dir/.git added' test ! -e "$c/ws/dir/.git"
	expect 'keep not pulled' test -f "$c/ws/keep"
	expect 'step failed' test "$rc" = 0
	done_case 3 '.git at any depth is not pulled'
}

case4() {
	fresh 4
	chmod 751 "$c/ws"
	mkdir -p "$c/s/sub" "$c/s/ro"
	chmod 700 "$c/s"
	echo pulled >"$c/s/f"
	echo target >"$c/s/sub/target"
	ln -s sub/target "$c/s/l"
	ln -s ../f "$c/s/sub/up"
	echo ro >"$c/s/ro/file"
	chmod 555 "$c/s/ro"
	tar cf "$c/1.tar" -C "$c/s" .
	before=$(outside)
	step "$c/1.tar"
	expect 'regular file not pulled' test "$(cat "$c/ws/f")" = pulled
	expect 'l not kept' test "$(readlink "$c/ws/l")" = sub/target
	expect 'sub/up not kept' test "$(readlink "$c/ws/sub/up")" = ../f
	expect 'ro/file not pulled' test -f "$c/ws/ro/file"
	expect 'Workspace root mode changed' test "$(stat -c %a "$c/ws")" = 751
	expect 'something left outside the Workspace' test "$before" = "$(outside)"
	expect 'step failed' test "$rc" = 0
	done_case 4 'files and relative symlinks inside come back'
}

case5() {
	fresh 5
	echo 'exit 3' >"$c/script"
	step
	expect "exit 3 gave $rc" test "$rc" = 3
	echo 'exit 0' >"$c/script"
	step
	expect "exit 0 gave $rc" test "$rc" = 0
	echo 'exit 3' >"$c/script"
	step "$c/missing.tar"
	expect "exit 3 with a failed Pull gave $rc" test "$rc" = 3
	done_case 5 'the exit status of the step is kept'
}

case6() {
	fresh 6
	mkdir "$c/s/sub"
	ln -s "$c/out" "$c/s/abs"
	ln -s ../../out "$c/s/sub/up"
	ln -s . "$c/s/d"
	ln -s d/.. "$c/s/e"
	ln -s / "$c/s/n${nl}l%"
	ln -s / "$c/s/c${cr}r"
	ln -s / "$c/s/b\\nx"
	mkdir -p "$c/s/sub/sub2" "$c/s/.git"
	ln -s ../.. "$c/s/sub/sub2/top"
	ln -s / "$c/s/.git/abs"
	ln -s / "$c/s/sub/.git"
	tar cf "$c/1.tar" -C "$c/s" .
	before=$(outside)
	step "$c/1.tar"
	for name in abs sub/up e 'b\nx' sub/sub2/top .git/abs sub/.git; do
		expect "unsafe symlink $name left" test ! -L "$c/ws/$name"
	done
	expect 'unsafe symlink n\nl% left' test ! -L "$c/ws/n${nl}l%"
	expect 'unsafe symlink c\rr left' test ! -L "$c/ws/c${cr}r"
	expect 'safe symlink d not kept' test "$(readlink "$c/ws/d")" = .
	expect 'wrong warnings' test "$(warnings)" = "$(
		for name in abs 'b\nx' c%0Dr e n%0Al%25 sub/sub2/top sub/up; do
			printf '::warning::pull: dropped unsafe symlink %s\n' "$name"
		done
	)"
	expect 'step failed' test "$rc" = 0
	expect 'something written outside the Workspace' test "$before" = "$(outside)"
	done_case 6 'unsafe symlinks are dropped, one warning each'
}

fails() {
	expect "$1: step passed" test "$rc" -ne 0
	expect "$1: no ::error::" grep -q '^::error::' "$c/log"
	expect "$1: something written outside the Workspace" test "$before" = "$(outside)"
}

case7() {
	fresh 7
	echo secret >"$c/out/secret"
	echo f >"$c/s/f"
	ln "$c/s/f" "$c/s/hl"
	tar cf "$c/dotdot.tar" -P -C "$c/s" --transform 's,^,../,' f
	tar cf "$c/abs.tar" -P -C "$c/s" --transform "s,^,$c/out/," f
	tar cf "$c/hlabs.tar" -P -C "$c/s" --transform "s,^f\$,$c/out/secret,rh" f hl
	tar --delete -P -f "$c/hlabs.tar" "$c/out/secret"
	tar cf "$c/hldot.tar" -P -C "$c/s" --transform 's,^f$,../out/secret,rh' f hl
	tar --delete -P -f "$c/hldot.tar" ../out/secret
	before=$(outside)

	step "$c/dotdot.tar"
	fails '../f'
	# GNU tar strips the leading / and extracts the member inside.
	step "$c/abs.tar"
	expect 'absolute member: step failed' test "$rc" = 0
	expect 'absolute member: not under the Workspace' \
		test -f "$c/ws/${c#/}/out/f"
	expect 'absolute member: something written outside the Workspace' \
		test "$before" = "$(outside)"
	step "$c/hlabs.tar"
	fails 'hard link to an absolute path'
	expect 'hard link to an absolute path: pulled' test ! -e "$c/ws/hl"
	step "$c/hldot.tar"
	fails 'hard link to ../'
	expect 'hard link to ../: pulled' test ! -e "$c/ws/hl"
	done_case 7 '../ members fail the step, absolute ones land inside'
}

case8() {
	fresh 8
	echo u >"$c/s/setuid"
	echo g >"$c/s/setgid"
	chmod 4755 "$c/s/setuid"
	chmod 2755 "$c/s/setgid"
	tar cf "$c/1.tar" -C "$c/s" .
	step "$c/1.tar"
	expect 'setuid file not pulled' test -f "$c/ws/setuid"
	expect 'setgid file not pulled' test -f "$c/ws/setgid"
	expect 's bit kept' test "$(find "$c/ws" -perm /6000)" = ''
	done_case 8 'setuid and setgid bits are stripped'
}

case9() {
	fresh 9
	files='GITHUB_ENV GITHUB_PATH GITHUB_OUTPUT GITHUB_STATE GITHUB_STEP_SUMMARY'
	for name in $files; do
		eval "$name=\$c/rt/\$name"
		export "${name?}"
	done
	GITHUB_REPOSITORY=chroot-dev/chroot-action GREETING=hi
	export GITHUB_REPOSITORY GREETING
	for env in GREETING "$files GREETING" 'RUNNER_TEMP GREETING'; do
		printf '%s\n' "$env" >"$c/rt/chroot-action/env"
		step
		got=" $(sed -n 's/^export \([A-Za-z0-9_]*\)=.*/\1/p' \
			"$c/guest/.chroot-step" | tr '\n' ' ')"
		yes='GITHUB_WORKSPACE GITHUB_REPOSITORY GREETING'
		no=$files
		case $env in
		RUNNER_TEMP*) yes="$yes RUNNER_TEMP" ;;
		*) no="$no RUNNER_TEMP" ;;
		esac
		for name in $yes; do
			case $got in
			*" $name "*) ;;
			*) why=${why:-"$name not exported with env: $env"} ;;
			esac
		done
		for name in $no; do
			case $got in
			*" $name "*) why=${why:-"$name exported with env: $env"} ;;
			esac
		done
	done
	# shellcheck disable=SC2086
	unset $files GITHUB_REPOSITORY GREETING
	done_case 9 'the file-command paths are not exported to the Job VM'
}

case1
case2
case3
case4
case5
case6
case7
case8
case9
exit "$failed"
