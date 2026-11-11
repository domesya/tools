#!/bin/sh
#
#	A program made for creating wrapper scripts for executables
#	to sort of give them a portable directory to store their data
#
#

set -eu

if [ "${MPD_DEBUG:-}" = 1 ]; then
	set -x
fi

_prog="${0##*/}"

_help() {
cat <<EOF
[Info]:	$_prog  --  A program made for giving appimages their portable directories

[Usage]: $_prog </path/to/executable> </path/to/portable/dir> </output/script/path>

[Options]:
	
	--help, -h, -H		Show this message.

EOF
[ -n "${1:-}" ]
exit $?
}

_err_msg() {
	>&2 printf '(\033[31mERR\033[0m)%s\n' " $*"
}

_inf_msg() {
	printf '(\033[34mINF\033[0m)%s\n' " $*"
}

_suc_msg() {
	printf '(\033[32mSUC\033[0m)%s\n' " $*"
}

# https://github.com/dylanaraps/pure-sh-bible
dirname() {
    # Usage: dirname "path"
    dir="${1:-.}"
    dir="${dir%%"${dir##*[!/]}"}"
    [ "${dir##*/*}" ] && dir=.
    dir="${dir%/*}"
    dir="${dir%%"${dir##*[!/]}"}"
    printf '%s\n' "${dir:-/}"
}

basename() {
    # Usage: basename "path" ["suffix"]
    dir="${1%"${1##*[!/]}"}"
    dir="${dir##*/}"
    dir="${dir%"${2:-}"}"
    printf '%s\n' "${dir:-/}"
}

_readlink() (	
	if [ "${1:-}" = '-f' ] && [ -n "${2:-}" ]; then
		_target="$2"
	else
		_target="${1:-}"
	fi
	
	if [ -e "$_target" ]; then
		if [ -d "$_target" ]; then
			cd -P "$_target" && pwd -P
		else
			_dir="$(dirname "$_target")"
			_base="$(basename "$_target")"
			cd -P "$_dir" && printf '%s/%s\n' "$(pwd -P)" "$_base"
		fi
		return 0;
	fi 
	
	command readlink "$@"
)

# https://github.com/Samueru-sama/simple-appimage-sandbox
_is_spooky() {
	_to_check="${1:-}"
	if [ -z "$_to_check" ]; then
		_err_msg "_is_spooky: Please provide an argument"
		return 1
	fi
	case "$_to_check" in
		"" 					|\
		"/" 				|\
		*//*				|\
		*./*				|\
		*..*				|\
		"/var/home"			|\
		"/home"				|\
		"$HOME"				|\
		"/run"				|\
		"/media"			|\
		"/dev"				|\
		"/proc"				|\
		"/mnt"				|\
		*.local      		|\
		*.firefox    		|\
		*.firedragon 		|\
		*.librewolf  		|\
		*.mullvad*   		|\
		*.zen        		|\
		*.gnupg      		|\
		*.thunderbird		|\
		*.mozilla    		|\
		*.ssh        		|\
		*.vim*       		|\
		*.profile    		|\
		*.bash*      		|\
		*.zsh*       		|\
		*fish        		|\
		"$ZDOTDIR"			\
		) _err_msg "The provided directory is spooky, won't touch."; return 1;
			;;
		/*) return 0;
			;;
		*) return 1;
			;;
	esac
}

_process_input_file() {
	_full="${1:-}"
	
	if [ ! -x "$_full" ] || [ ! -f "$_full" ]; then
		_err_msg "The argument doesn't appear to be an executable."
		return 1
	fi
	
	_dest="${2:-}"
	
	if [ -z "$_dest" ]; then
		_err_msg "Please provide a directory to be used."
		return 1
	fi

	_is_spooky "$_dest"
	
	if [ ! -d "$_dest" ]; then
		_inf_msg "No such directory, will attempt to create." 
		mkdir -p "$_dest"
	fi
		
	_script_path="${3:-}"
	if [ -z "$_script_path" ]; then
		_err_msg "Please provide output script path."
		return 1
	fi
	
	if [ -e "$_script_path" ]; then
		_err_msg "Target file exists. Refusing to overwrite."
		return 1
	fi
	
	APP_DIR="$(dirname "$(_readlink -f "$_full")")"
	APP_NAME="$(basename "$_full")"
	DEST="$(_readlink -f "$_dest")"
	SCRIPT_PATH="$_script_path"
	_inf_msg "\"$APP_NAME\" at \"$APP_DIR\" with \"$DEST\""		
	
	_inf_msg "Creating associated directories."
	mkdir -p "$DEST/.local/share" \
         	 "$DEST/.config" \
         	 "$DEST/.cache" \
         	 "$DEST/.local/state"
	
	_write_script;
	_suc_msg "All done!"
		
}

# needs $APP_DIR, $APP_NAME, $DEST and $SCRIPT_PATH
_write_script() {

	if [ -z "${SCRIPT_PATH:-}" ]; then
		_err_msg "_write_script: We need \$SCRIPT_PATH to be set." 
		return 1
	elif [ -z "${APP_NAME:-}" ]; then 
		_err_msg "_write_script: We need \$APP_NAME to be set." 
		return 1
	elif [ -z "${APP_DIR:-}" ]; then 
		_err_msg "_write_script: We need \$APP_DIR to be set." 
		return 1
	elif [ -z "${DEST:-}" ]; then 
		_err_msg "_write_script: We need \$DEST to be set." 
		return 1
	fi

cat > "$SCRIPT_PATH" <<EOF
#!/bin/sh
APP_DIR="$APP_DIR"
APP_NAME="$APP_NAME"
DEST="$DEST"
_H="\$DEST"
HOME="\$_H" \\
XDG_DATA_HOME="\$_H/.local/share" \\
XDG_CONFIG_HOME="\$_H/.config" \\
XDG_CACHE_HOME="\$_H/.cache" \\
XDG_STATE_HOME="\$_H/.local/state" \\
exec "\$APP_DIR/\$APP_NAME" "\$@"
EOF
chmod +x "$SCRIPT_PATH"
}

_parse_arguments() {
	case "${1:-}" in
		''|--help|-H|-h) _help "$@";
			;;
		*) _process_input_file "$@";
			;;
	esac
}

_parse_arguments "$@";