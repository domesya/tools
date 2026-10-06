#!/bin/sh
# appimage-integrate - extract .desktop entries and icons from AppImages using
# pkgforge's squishy, rewrite Exec/TryExec/Icon to point at the AppImage, and
# install the results into XDG-compliant directories.

set -u

PROG=${0##*/}
SQUISHY=squishy
SQUISHY_EXPLICIT=0
SYSTEM=0
QUIET=0
MOVE_DIR=
SQUISHY_REPO=pkgforge/squishy
SQUISHY_CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/appimage-integrate
BIN_DIR=${XDG_BIN_HOME:-$HOME/.local/bin}

msg()  { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }
warn() { printf '%s: %s\n' "$PROG" "$*" >&2; }
die()  { warn "$*"; exit 1; }

squishy_arch() {
	case $(uname -m) in
	x86_64) printf 'x86_64\n' ;;
	aarch64 | arm64) printf 'aarch64\n' ;;
	*)
		warn "unsupported architecture for squishy auto-download: $(uname -m)"
		return 1
		;;
	esac
}

looks_like_elf() {
	[ "$(dd if="$1" bs=4 count=1 2>/dev/null | od -A n -t x1 | tr -d ' \n')" = "7f454c46" ]
}

sniff_icon_ext() {
	sig=$(dd if="$1" bs=4 count=1 2>/dev/null | od -A n -t x1 | tr -d ' \n')
	case $sig in
	89504e47)
		printf 'png\n'
		return 0
		;;
	esac
	if dd if="$1" bs=1024 count=1 2>/dev/null | grep -qi '<svg'; then
		printf 'svg\n'
		return 0
	fi
	return 1
}

download_squishy() {
	arch=$(squishy_arch) || return 1
	dest=$SQUISHY_CACHE/squishy-$arch
	if [ -z "${SQUISHY_FORCE_DOWNLOAD:-}" ] &&
		[ -x "$dest" ] && looks_like_elf "$dest"; then
		printf '%s\n' "$dest"
		return 0
	fi
	mkdir -p -- "$SQUISHY_CACHE" || { warn "cannot create $SQUISHY_CACHE"; return 1; }
	tmp=$dest.tmp.$$
	url="https://github.com/$SQUISHY_REPO/releases/latest/download/squishy-$arch-linux"
	msg "downloading squishy ($arch): $url" >&2
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --retry 3 -o "$tmp" "$url" ||
			{ rm -f -- "$tmp"; warn "curl download failed"; return 1; }
	elif command -v wget >/dev/null 2>&1; then
		wget -q -O "$tmp" "$url" ||
			{ rm -f -- "$tmp"; warn "wget download failed"; return 1; }
	else
		rm -f -- "$tmp"
		warn "neither curl nor wget available to download squishy"
		return 1
	fi
	chmod 0755 -- "$tmp"
	if ! looks_like_elf "$tmp"; then
		rm -f -- "$tmp"
		warn "downloaded file is not an ELF binary (bad redirect or mirror?)"
		return 1
	fi
	mv -f -- "$tmp" "$dest" || { rm -f -- "$tmp"; warn "cannot install to $dest"; return 1; }
	printf '%s\n' "$dest"
}

ensure_squishy() {
	command -v "$SQUISHY" >/dev/null 2>&1 && return 0
	if [ "$SQUISHY_EXPLICIT" -eq 1 ]; then
		warn "squishy binary not found: $SQUISHY"
		return 1
	fi
	downloaded=$(download_squishy) || return 1
	SQUISHY=$downloaded
	return 0
}

usage() {
	cat <<EOF
Usage: $PROG [options] APPIMAGE...

Extract the .desktop entry and icon from each AppImage with squishy,
rewrite Exec/TryExec/Icon so they launch the AppImage itself, install the
icon into the hicolor icon theme, the entry into the XDG applications
directory, and a launcher symlink into $BIN_DIR,
then refresh desktop/icon caches.

Options:
  -b DIR   move each AppImage into DIR (created if missing) before integrating
  -s       install system-wide into /usr/local/share (default: per-user,
           honoring XDG_DATA_HOME)
  -x PATH  squishy binary to use (default: $SQUISHY)
  -q       suppress informational output
  -h       show this help

If squishy is not found in PATH, the latest release is downloaded
automatically from github.com/$SQUISHY_REPO into
$SQUISHY_CACHE (override with XDG_CACHE_HOME). The cached
binary is reused on later runs; set SQUISHY_FORCE_DOWNLOAD=1 to fetch the
newest release again.
EOF
}

while getopts ":hb:sqx:" opt; do
	case $opt in
	b) MOVE_DIR=$OPTARG ;;
	s) SYSTEM=1 ;;
	q) QUIET=1 ;;
	x) SQUISHY=$OPTARG; SQUISHY_EXPLICIT=1 ;;
	h) usage; exit 0 ;;
	\?) warn "unknown option: -$OPTARG"; usage; exit 1 ;;
	:)  warn "option -$OPTARG requires an argument"; exit 1 ;;
	esac
done
shift $((OPTIND - 1))

[ $# -ge 1 ] || { usage >&2; exit 1; }
ensure_squishy ||
	die "could not locate or download squishy (install it or pass -x /path/to/squishy)"

if [ "$SYSTEM" -eq 1 ]; then
	DATAROOT=/usr/local/share
else
	DATAROOT=${XDG_DATA_HOME:-$HOME/.local/share}
fi
APPDIR=$DATAROOT/applications
ICONROOT=$DATAROOT/icons/hicolor

WORKROOT=$(mktemp -d "${TMPDIR:-/tmp}/${PROG}.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$WORKROOT"' EXIT INT TERM

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

resolve_path() {
	d=${1%/*}
	b=${1##*/}
	if [ -n "$d" ] && [ -d "$d" ]; then
		printf '%s/%s\n' "$(cd -- "$d" && pwd -P)" "$b"
		return 0
	fi
	case $1 in
	/*) printf '%s\n' "$1" ;;
	*)  printf '%s/%s\n' "$(pwd -P)" "$1" ;;
	esac
}

sed_escape_rhs() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

be32() { printf '%s\n' $((($1 * 16777216) + ($2 * 65536) + ($3 * 256) + $4)); }

png_dims() {
	bytes=$(dd if="$1" bs=1 skip=16 count=8 2>/dev/null | od -A n -t u1 2>/dev/null) || return 0
	set -- $bytes
	[ $# -eq 8 ] || return 0
	printf '%sx%s\n' "$(be32 "$1" "$2" "$3" "$4")" "$(be32 "$5" "$6" "$7" "$8")"
}

process() {
	idx=$1
	img=$2

	if [ ! -f "$img" ]; then
		warn "skipping, not a regular file: $img"
		return 2
	fi
	img=$(resolve_path "$img")

	base=${img##*/}
	stem=$base
	case $stem in
	*.AppImage | *.appimage | *.APPIMAGE) stem=${stem%.*} ;;
	esac
	id=$(printf '%s' "$stem" | tr -c '[:alnum:]._-' '_')
	case $id in
	[A-Za-z0-9]*) ;;
	*) id="_$id" ;;
	esac
	if [ -z "$id" ]; then
		warn "skipping, cannot derive identifier from: $base"
		return 2
	fi

	if [ -n "$MOVE_DIR" ]; then
		mkdir -p -- "$MOVE_DIR" || { warn "cannot create $MOVE_DIR"; return 2; }
		mdir=$(resolve_path "$MOVE_DIR")
		mtgt=$mdir/$base
		if [ "$mtgt" != "$img" ]; then
			mv -f -- "$img" "$mtgt" || { warn "cannot move into $mdir: $base"; return 2; }
			img=$mtgt
		fi
	fi
	chmod +x -- "$img" 2>/dev/null || true

	wdir=$WORKROOT/$idx
	mkdir -p "$wdir"

	if ! errtxt=$("$SQUISHY" appimage "$img" --icon --desktop --original-name --write "$wdir" 2>&1); then
		warn "squishy failed for $base: $(printf '%s' "$errtxt" | tr '\n' ' ')"
		return 2
	fi

	find "$wdir" -type f -name '*.desktop' >"$wdir/desktop.list"
	dcount=$(wc -l <"$wdir/desktop.list")
	if [ "$dcount" -lt 1 ]; then
		warn "no .desktop entry found inside $base"
		return 2
	fi
	dsrc=
	while IFS= read -r dcand; do
		[ -n "$dcand" ] || continue
		if grep -qi '^NoDisplay=true' "$dcand"; then
			[ -n "$dsrc" ] || dsrc=$dcand
			continue
		fi
		dsrc=$dcand
		break
	done <"$wdir/desktop.list"
	[ "$dcount" -gt 1 ] && warn "multiple .desktop entries in $base, using: ${dsrc#"$wdir"/}"

	find "$wdir" -type f \( -name '*.png' -o -name '*.svg' -o -name '.DirIcon' \) >"$wdir/icons.list"
	icon_src=
	icon_ext=
	best_png=
	best_png_bytes=0
	diricon_src=
	while IFS= read -r cand; do
		[ -n "$cand" ] || continue
		lext=$(lower "${cand##*.}")
		if [ "$lext" = "svg" ]; then
			icon_src=$cand
			icon_ext=svg
			break
		fi
		if [ "$lext" = "png" ]; then
			nbytes=$(wc -c <"$cand")
			if [ "$nbytes" -gt "$best_png_bytes" ]; then
				best_png_bytes=$nbytes
				best_png=$cand
			fi
		fi
		if [ "$lext" = "diricon" ] && [ -z "$diricon_src" ]; then
			diricon_src=$cand
		fi
	done <"$wdir/icons.list"
	if [ -z "$icon_src" ] && [ -n "$best_png" ]; then
		icon_src=$best_png
		icon_ext=png
	fi
	if [ -z "$icon_src" ] && [ -n "$diricon_src" ]; then
		sext=$(sniff_icon_ext "$diricon_src") || sext=
		if [ -n "$sext" ]; then
			icon_src=$diricon_src
			icon_ext=$sext
		fi
	fi

	idir=
	icon_ref=
	if [ -n "$icon_src" ]; then
		case $icon_ext in
		svg) idir=$ICONROOT/scalable/apps ;;
		png)
			dims=$(png_dims "$icon_src")
			case $dims in
			'' | *[!0-9x]*) dims=256x256 ;;
			esac
			idir=$ICONROOT/$dims/apps
			;;
		esac
		mkdir -p -- "$idir" || { warn "cannot create $idir"; return 2; }
		cp -f -- "$icon_src" "$idir/$id.$icon_ext" ||
			{ warn "cannot install icon for $base"; return 2; }
		chmod 0644 "$idir/$id.$icon_ext"
		icon_ref=$id
	else
		warn "no usable icon in $base, keeping its original Icon= line"
	fi

	mkdir -p -- "$APPDIR" || { warn "cannot create $APPDIR"; return 2; }
	ddst=$APPDIR/$id.desktop
	tmpd=$WORKROOT/entry.desktop
	exec_esc=$(sed_escape_rhs "\"$img\" %U")
	try_exec_esc=$(sed_escape_rhs "$img")
	prog="/^\[Desktop Entry\]/,/^\[/ { s|^Exec=.*|Exec=$exec_esc|; s|^TryExec=.*|TryExec=$try_exec_esc|;"
	prog="$prog /^NoDisplay=true\$/d; /^Hidden=true\$/d; /^OnlyShowIn=/d; /^NotShowIn=/d;"
	if [ -n "$icon_ref" ]; then
		prog="$prog s|^Icon=.*|Icon=$icon_ref|;"
	fi
	prog="$prog }"

	sed -e "$prog" "$dsrc" >"$tmpd" || { warn "cannot rewrite entry for $base"; return 2; }
	if ! grep -q '^\[Desktop Entry\]' "$tmpd"; then
		warn "extracted entry for $base has no [Desktop Entry] section"
		return 2
	fi
	grep -q '^Exec=' "$tmpd" ||
		warn "entry for $base had no Exec= key to rewrite"
	main_section() { sed -n '/^\[Desktop Entry\]/,/^\[/p' "$tmpd"; }
	if ! main_section | grep -q '^Type='; then
		if ! { sed -e '/^\[Desktop Entry\]/a\Type=Application' "$tmpd" >"$tmpd.fix" &&
			mv -f -- "$tmpd.fix" "$tmpd"; }; then
			warn "cannot add Type= for $base"
			return 2
		fi
	fi
	if ! main_section | grep -q '^Name='; then
		name_esc=$(sed_escape_rhs "$stem")
		if ! { sed -e "/^\[Desktop Entry\]/a\\Name=$name_esc" "$tmpd" >"$tmpd.fix" &&
			mv -f -- "$tmpd.fix" "$tmpd"; }; then
			warn "cannot add Name= for $base"
			return 2
		fi
	fi
	[ -n "$(tail -c 1 "$tmpd")" ] && printf '\n' >>"$tmpd"

	mv -f -- "$tmpd" "$ddst" || { warn "cannot install $ddst"; return 2; }
	chmod 0644 "$ddst"

	mkdir -p -- "$BIN_DIR" || warn "cannot create $BIN_DIR"
	link=$BIN_DIR/$id
	if [ -e "$link" ] && [ ! -L "$link" ]; then
		warn "not replacing non-symlink: $link"
	else
		rm -f -- "$link" 2>/dev/null || true
		if ln -s -- "$img" "$link"; then
			msg "  bin:   $link -> $img"
		else
			warn "cannot create symlink $link"
		fi
	fi

	msg "integrated: $base"
	msg "  entry: $ddst"
	[ -n "$icon_ref" ] && msg "  icon:  $idir/$id.$icon_ext"
	msg "  exec:  \"$img\" %U"
	return 0
}

ok=0
fail=0
i=0
for img in "$@"; do
	i=$((i + 1))
	if process "$i" "$img"; then
		ok=$((ok + 1))
	else
		fail=$((fail + 1))
	fi
done

if [ "$ok" -gt 0 ]; then
	command -v update-desktop-database >/dev/null 2>&1 &&
		update-desktop-database "$APPDIR" >/dev/null 2>&1 || true
	command -v gtk-update-icon-cache >/dev/null 2>&1 &&
		gtk-update-icon-cache -q -f -t "$ICONROOT" >/dev/null 2>&1 || true
	for kc in kbuildsycoca6 kbuildsycoca5; do
		if command -v "$kc" >/dev/null 2>&1; then
			"$kc" >/dev/null 2>&1 || true
			break
		fi
	done
	command -v xdg-desktop-menu >/dev/null 2>&1 &&
		xdg-desktop-menu forceupdate >/dev/null 2>&1 || true
fi

msg "done: $ok integrated, $fail failed"
[ "$fail" -eq 0 ]
