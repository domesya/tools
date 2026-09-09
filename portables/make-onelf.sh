#!/bin/sh
#
#
#

set -eu

ARCH="$(uname -m)"
TMPDIR="${TMPDIR:-/tmp}"
TEMPDIR="${PWD}/tempdir"
DST_BIN_DIR="${TEMPDIR}/bin"

ONELF_LINK="${ONELF_LINK:-https://github.com/QaidVoid/onelf/releases/latest/download/onelf-$ARCH-linux}"

_echo() {
	printf '\033[1;92m%s\033[0m\n' " $*"
}

_err_msg(){
	>&2 printf '\033[1;31m%s\033[0m\n' " $*"
}

_is_cmd() {
	for cmd do
		command -v "$cmd" 1>/dev/null || return 1
	done
	return 0
}

_download() {
	if _is_cmd wget; then
		DOWNLOAD_CMD="wget"
		set -- -qO "$@"
	elif _is_cmd curl; then
		DOWNLOAD_CMD="curl"
		set -- -Lso "$@"
	else
		_err_msg "ERROR: we need wget or curl to download $1"
		exit 1
	fi
	COUNT=0
	while [ "$COUNT" -lt 5 ]; do
		if "$DOWNLOAD_CMD" "$@"; then
			return 0
		else
			status=$?
			_err_msg "'$DOWNLOAD_CMD $*' exited with $status"
			_err_msg "Trying again..."
		fi
		COUNT=$((COUNT + 1))
		sleep 5
	done
	_err_msg "ERROR: Failed to download 5 times!"
	return 1
}

_make_onelf() {
	ONELF=$TMPDIR/onelf
	if [ ! -x "$ONELF" ]; then
		_echo "Downloading onelf..."
		_download "$ONELF" "$ONELF_LINK"
		chmod +x "$ONELF"
	fi

	mkdir -p "$DST_BIN_DIR"
	_echo "------------------------------------------------------------"
	for bin do
		b=${bin##*/}
		_echo "Packing $bin as a static binary with onelf..."

		_tmpdir=$TMPDIR/.onelf_build_$$_$b
		rm -rf "$_tmpdir"
		mkdir -p "$_tmpdir"

		"$ONELF" bundle-libs "$_tmpdir" --from-binary "$bin" --strip --scan-dlopen
		"$ONELF" pack "$_tmpdir" -o "$DST_BIN_DIR"/"$b" --command bin/"$b"
		rm -rf "$_tmpdir"
	done
	_echo "------------------------------------------------------------"
}

_make_onelf "$@"