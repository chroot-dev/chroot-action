#!/bin/sh
# setup.sh inputs and cleanup.sh state without chroot.dev: a fake ssh
# records each call.

set -euf

root=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
nl='
'
cr=$(printf '\r')
tab=$(printf '\t')
esc=$(printf '\033')
del=$(printf '\177')
eacute=$(printf '\303\251')
key='-----BEGIN OPENSSH PRIVATE KEY-----'
failed=0
n=0

mkdir "$T/bin"
cat >"$T/bin/ssh" <<'EOF'
#!/bin/sh
printf '<%s>' "$@" >>"$FAKE_LOG/calls"
echo >>"$FAKE_LOG/calls"
for arg; do
	[ "$arg" != /dev/stdin ] || exec cat >"$FAKE_LOG/stdin"
	[ "$arg" != 'cat >.chroot-step' ] || exec cat >"$FAKE_LOG/chroot-step"
done
exit 0
EOF
chmod +x "$T/bin/ssh"
PATH=$T/bin:$PATH

next() {
	n=$((n + 1))
	r=$T/$n
	cfg=$r/rt/chroot-action/ssh_config
	mkdir -p "$r/rt" "$r/ssh"
	: >"$r/state"
	: >"$r/output"
	: >"$r/path"
}

run() {
	file=$1
	shift
	rc=0
	env INPUT_SSH_KEY="$key" INPUT_IMAGE=base INPUT_FROM= INPUT_SETUP= \
		INPUT_CPUS= INPUT_MEMORY= INPUT_DISK= INPUT_SYNC=in INPUT_ENV= \
		GITHUB_RUN_ID=123 GITHUB_RUN_ATTEMPT=1 "$@" \
		FAKE_LOG="$r/ssh" RUNNER_TEMP="$r/rt" GITHUB_STATE="$r/state" \
		GITHUB_OUTPUT="$r/output" GITHUB_PATH="$r/path" \
		sh "$root/src/$file" >"$r/log" 2>&1 || rc=$?
}

setup() {
	next
	run setup.sh "$@"
}

cleanup() {
	next
	mkdir "$r/rt/chroot-action"
	: >"$cfg"
	run cleanup.sh STATE_vm="$1"
}

expect() {
	text=$1
	shift
	"$@" || fail "$text"
}

fail() {
	[ -n "$why" ] || cp "$r/log" "$T/why.log"
	why=${why:-$1}
}

# shellcheck disable=SC2317,SC2329 # called through expect
is() {
	printf '%s\n' "$2" | cmp -s - "$1"
}

# shellcheck disable=SC2317,SC2329 # called through expect
matches() {
	case $1 in
	*"$nl"*) return 1 ;;
	esac
	printf '%s\n' "$1" | grep -Eqx "$2"
}

commands() {
	grep '^::' "$r/log" || true
}

refused() {
	expect "$1: step passed" test "$rc" -ne 0
	expect "$1: output is not the one error line" is "$r/log" "$2"
	expect "$1: ssh called" test ! -e "$r/ssh/calls"
	expect "$1: GITHUB_STATE written" test ! -s "$r/state"
	expect "$1: GITHUB_OUTPUT written" test ! -s "$r/output"
}

accepted() {
	expect "$1: step failed" test "$rc" = 0
	vm=$(sed -n 's/^vm=//p' "$r/state")
	expect "$1: no generated name in GITHUB_STATE" \
		matches "$vm" 'gh-123-1-[0-9a-f]{6}'
	expect "$1: no vm-name in GITHUB_OUTPUT" is "$r/output" "vm-name=$vm"
}

control_error() {
	printf '::error::%s: invalid value: it holds a control or non-ASCII character\n' "$1"
}

done_case() {
	if [ -z "$why" ]; then
		printf 'ok %s - %s\n' "$1" "$2"
	else
		printf 'FAIL %s - %s: %s\n' "$1" "$2" "$why"
		sed 's/^/	| /' "$T/why.log"
		failed=1
	fi
}

case1() {
	why=
	for input in image from cpus memory disk sync; do
		case $input in
		image) good=base ;;
		from) good=tmpl ;;
		cpus) good=2 ;;
		memory) good=2G ;;
		disk) good=1T ;;
		sync) good=in ;;
		esac
		var=INPUT_$(printf '%s' "$input" | tr '[:lower:]' '[:upper:]')
		for spoil in 'a newline and words' 'a final newline' CR tab ESC DEL \
			'a UTF-8 letter'; do
			case $spoil in
			'a newline and words') value="$good$nl--integration x" ;;
			'a final newline') value=$good$nl ;;
			CR) value=$good$cr ;;
			tab) value=$tab$good ;;
			ESC) value="$good${esc}[0m" ;;
			DEL) value=$good$del ;;
			'a UTF-8 letter') value=$good$eacute ;;
			esac
			setup "$var=$value"
			refused "$input with $spoil" "$(control_error "$input")"
		done
	done
	done_case 1 'a value with a control or non-ASCII byte fails the step'
}

case2() {
	why=
	value='1\n::save-state name=vm::OTHER'
	setup "INPUT_MEMORY=$value"
	expect "memory $value: step passed" test "$rc" -ne 0
	expect "memory $value: wrong workflow commands" \
		test "$(commands)" = "::error::memory: invalid value '$value'"
	setup "INPUT_ENV=CC\\n::save-state name=vm::OTHER"
	expect "env CC\\n::save-state: step passed" test "$rc" -ne 0
	expect "env CC\\n::save-state: wrong workflow commands" \
		test "$(commands)" = "::error::env: invalid value 'CC\\n::save-state'"
	setup "INPUT_MEMORY=x$nl::warning::x"
	expect 'memory with a newline: step passed' test "$rc" -ne 0
	expect 'memory with a newline: wrong workflow commands' \
		test "$(commands)" = "$(control_error memory)"
	done_case 2 'a refused value prints no workflow command but its error'
}

case3() {
	why=
	for spoil in CR ESC 'a UTF-8 letter'; do
		case $spoil in
		CR) value="CC CFLAGS$cr" ;;
		ESC) value="CC C${esc}FLAGS" ;;
		'a UTF-8 letter') value="CC C$eacute" ;;
		esac
		setup "INPUT_ENV=$value"
		refused "env with $spoil" "$(control_error env)"
	done
	for sep in newline tab 'blank lines'; do
		case $sep in
		newline) value="CC${nl}CFLAGS" ;;
		tab) value="CC${tab}CFLAGS" ;;
		'blank lines') value="${nl}CC${nl}${nl}CFLAGS$nl" ;;
		esac
		label="env split by $sep"
		setup INPUT_SYNC=none "INPUT_ENV=$value"
		accepted "$label"
		expect "$label: env file" is "$r/rt/chroot-action/env" 'CC CFLAGS'
		mkdir "$r/ws"
		echo true >"$r/script"
		CC=cc CFLAGS='-O2 -g' FAKE_LOG=$r/ssh RUNNER_TEMP=$r/rt \
			GITHUB_WORKSPACE=$r/ws "$root/bin/chroot" "$r/script" \
			>"$r/chroot.log" 2>&1 || fail "$label: bin/chroot failed"
		step=$r/ssh/chroot-step
		expect "$label: CC not exported" grep -qx "export CC='cc'" "$step"
		expect "$label: CFLAGS not exported" \
			grep -qx "export CFLAGS='-O2 -g'" "$step"
	done
	done_case 3 'env names split on any whitespace, and only there'
}

case4() {
	why=
	setup INPUT_CPUS=2 INPUT_MEMORY=2G INPUT_DISK=1T INPUT_IMAGE=openbsd-78
	accepted new
	expect 'new: wrong ssh calls' is "$r/ssh/calls" \
		"<-F><$cfg><chroot.dev><new><-w><-c><2><-m><2G><-d><1T><-i><openbsd-78><-n><$vm>
<-F><$cfg><vm><mkdir><-p><work>"
	expect 'new: no bin in GITHUB_PATH' is "$r/path" "$root/bin"

	setup INPUT_FROM=tmpl INPUT_CPUS=1
	accepted cp
	expect 'cp: wrong ssh calls' is "$r/ssh/calls" \
		"<-F><$cfg><chroot.dev><cp><-w><-c><1><tmpl><$vm>
<-F><$cfg><vm><mkdir><-p><work>"

	script="pkg_add -I git
printf '%s\\n' 'a${tab}b${cr}' \"\$HOME\"

exit 0
"
	setup "INPUT_SETUP=$script"
	accepted setup
	expect 'setup: wrong ssh calls' is "$r/ssh/calls" \
		"<-F><$cfg><chroot.dev><new><-w><-i><base><-n><$vm><-s></dev/stdin>
<-F><$cfg><vm><mkdir><-p><work>"
	expect 'setup: script changed on stdin' is "$r/ssh/stdin" "$script"

	setup "INPUT_SSH_KEY=$key$cr${nl}b3BlbnNzaC1rZXktdjE=$cr$nl-----END OPENSSH PRIVATE KEY-----$cr$nl"
	accepted ssh-key
	expect 'ssh-key: key file' is "$r/rt/chroot-action/key" \
		"$key${nl}b3BlbnNzaC1rZXktdjE=$nl-----END OPENSSH PRIVATE KEY-----$nl"
	done_case 4 'valid inputs reach chroot.dev unchanged'
}

case5() {
	why=
	vm=gh-123-1-0a1b2c
	cleanup "$vm"
	expect 'generated name: step failed' test "$rc" = 0
	expect 'generated name: wrong ssh calls' is "$r/ssh/calls" \
		"<-F><$cfg><chroot.dev><rm><$vm>
<-F><$cfg><-O><exit><vm>
<-F><$cfg><-O><exit><chroot.dev>"
	expect 'generated name: Runner dir left' test ! -e "$r/rt/chroot-action"

	for vm in OTHER gh-123-1-0a1b2 gh-123-1-0a1b2c3 gh-123-1-0A1B2C \
		gh-124-1-0a1b2c gh-123-2-0a1b2c gh-123-1-0a1b2c-x x-gh-123-1-0a1b2c \
		'gh-123-1-[0-9a-f]*' 'gh-123-1-0a1b2c\n'; do
		label=$vm
		[ "$vm" != 'gh-123-1-0a1b2c\n' ] || vm=gh-123-1-0a1b2c$nl
		cleanup "$vm"
		expect "$label: step passed" test "$rc" -ne 0
		expect "$label: no ::error::" grep -q '^::error::' "$r/log"
		expect "$label: wrong ssh calls" is "$r/ssh/calls" \
			"<-F><$cfg><-O><exit><vm>
<-F><$cfg><-O><exit><chroot.dev>"
		expect "$label: Runner dir left" test ! -e "$r/rt/chroot-action"
	done

	cleanup ''
	expect 'no name: step failed' test "$rc" = 0
	expect 'no name: rm called' test "$(grep -c '<rm>' "$r/ssh/calls")" = 0
	expect 'no name: Runner dir left' test ! -e "$r/rt/chroot-action"
	done_case 5 'the post step removes only the name this job generated'
}

case1
case2
case3
case4
case5
exit "$failed"
