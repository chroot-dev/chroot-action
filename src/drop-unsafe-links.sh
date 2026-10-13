#!/bin/sh
# drop-unsafe-links.sh ROOT LINK...: removes, with a warning, each LINK
# that may point outside ROOT. A superset of what rsync --safe-links
# drops, so no link goes silently.

set -euf

root=$1
shift
nl='
'
cr=$(printf '\r')

unsafe() {
	target=$2
	case $target in
	'' | /*) return 0 ;;
	esac
	ifs=$IFS
	IFS=/
	# shellcheck disable=SC2086
	set -- $1
	depth=$(($# - 1))
	# shellcheck disable=SC2086
	set -- $target
	IFS=$ifs
	parts=0 named='' last=''
	for part; do
		case $part in
		'') continue ;;
		..)
			[ -z "$named" ] || return 0
			depth=$((depth - 1))
			[ "$depth" -ge 0 ] || return 0
			;;
		.)
			[ "$parts" -eq 0 ] || return 0
			named=1
			;;
		*) named=1 ;;
		esac
		parts=$((parts + 1)) last=$part
	done
	[ "$parts" -gt 1 ] && [ "$last" = .. ]
}

encode() {
	rest=$1 out=
	while [ -n "$rest" ]; do
		char=${rest%"${rest#?}"}
		rest=${rest#?}
		case $char in
		%) char=%25 ;;
		"$cr") char=%0D ;;
		"$nl") char=%0A ;;
		esac
		out=$out$char
	done
	printf '%s' "$out"
}

for link; do
	name=${link#"$root"/}
	# Keep a final newline of the target, if any.
	target=$(readlink -- "$link" && echo .)
	target=${target%?.}
	if unsafe "$name" "$target"; then
		rm -f -- "$link"
		printf '::warning::pull: dropped unsafe symlink %s\n' "$(encode "$name")"
	fi
done
