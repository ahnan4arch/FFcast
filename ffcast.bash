#!/bin/bash
#
# FFcast @VERSION@
# Copyright (C) 2011-2014  lolilolicon <lolilolicon@gmail.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

if (( ${BASH_VERSINFO[0]} == 4 && ${BASH_VERSINFO[1]} < 3 )) ||
   (( ${BASH_VERSINFO[0]} < 4 )); then
    printf 'fatal: requires bash 4.3+ but this is bash %s\n' "$BASH_VERSION"
    exit 43
fi >&2

set -e +m -o pipefail
shopt -s extglob lastpipe
trap -- 'trap_err $LINENO' ERR

readonly -a \
    srcdirs=({/usr/lib,/etc,"${XDG_CONFIG_HOME:-$HOME/.config}"}/'@PRGNAME@')
readonly -a logl=(error warn msg verbose debug)
declare -A 'logp=([warn]="warning" [msg]=":")'
declare -i verbosity=2
declare -A sub_commands=() sub_cmdfuncs=()
declare -a head_ids=() geospecs=() window_ids=()
declare -- region_select_action=
declare -i borders=0 frame=0 intersection=0

#---
# Functions

msg_colors_on() {
    logp[error]=$'\e[1;31m''error'$'\e[m'
    logp[warn]=$'\e[1;33m''warning'$'\e[m'
    logp[msg]=$'\e[34m'':'$'\e[m'
    logp[verbose]=$'\e[32m''verbose'$'\e[m'
    logp[debug]=$'\e[36m''debug'$'\e[m'
}

trap_err() {
    set -- "$1" "${PIPESTATUS[@]}"
    printf '%s:%d: ERR:' "${BASH_SOURCE[0]}" "$1"; shift
    printf ' PIPESTATUS:'
    printf ' %d' "$@"
    printf '  BASH_COMMAND: %s\n' "$BASH_COMMAND"
} >&2

_msg() {
    local prefix=$1
    shift || return 0
    local fmt=$1
    shift || return 0
    printf '%s' "$prefix"
    printf -- "$fmt\n" "$@"
}

_quote_cmd_line() {
    local prefix=$1
    shift || return 0
    local cmd=$1
    shift || return 0
    printf '%s' "$prefix"
    printf '%q' "$cmd"
    (( $# )) && printf ' %q' "$@"
    printf '\n'
}

_report_array_by_key() {
    local varname=$1
    local -n ref_array=$1
    local key=$2
    printf "%q[%q]=%q\n" "$varname" "$key" "${ref_array[$key]}"
}

debug_array_by_key() {
    (( verbosity >= 4 )) || return 0
    printf "${logp[debug]}: "
    _report_array_by_key "$@"
} >&2

for ((i=0; i<${#logl[@]}; ++i)) ; do
    eval "${logl[i]}() {
        (( verbosity >= $i )) || return 0
        _msg \"\${logp[${logl[i]}]-${logl[i]}}: \" \"\$@\"
    } >&2"
done

for ((i=3; i<${#logl[@]}; ++i)) ; do
    eval "${logl[i]}_dryrun() {
        (( verbosity >= $i )) || return 0
        _quote_cmd_line \"\${logp[${logl[i]}]-${logl[i]}}: cmdline: \" \"\$@\"
    } >&2
    ${logl[i]}_run() {
        ${logl[i]}_dryrun \"\$@\" &&  \"\$@\"
    }"
done

format_to_string() {
    local fmt=$1 str c
    printf %s "$fmt" |
    while IFS= read -r -n 1 -d '' c; do
        if [[ $c == '%' ]]; then
            IFS= read -r -n 1 -d '' c || :
            case $c in
                '%') str+=%;;
                'd') str+=$DISPLAY;;
                'h') str+=$h;;
                'w') str+=$w;;
                'x') str+=$_x;;
                'y') str+=$_y;;
                'X') str+=$x_;;
                'Y') str+=$y_;;
                'c') str+=$_x,$_y;;
                'C') str+=$x_,$y_;;
                'g') str+=${w}x$h+$_x+$_y;;
                's') str+=${w}x$h;;
                *) str+=%$c;;
            esac
        else
            str+=$c
        fi
    done
    printf %s "$str";
}

# $1: array variable of heads, e.g. =([0]=1440x900+0+124 [1]=1280x1024+1440+0)
# $2: array variable of head IDs, e.g. =(0 1 2)
# $3: array variable to assign corners list to, i.e. =([id]=corners ...)
# $4: array variable to assign bad head IDs to, e.g. =(2)
heads_get_corners_list_by_ref() {
    local -n ref_heads=$1
    local -n ref_head_ids=$2
    local -- i w h _x _y x_ y_
    for i in "${ref_head_ids[@]}"; do
        if [[ -n ${ref_heads[i]} ]]; then
            IFS='x+' read w h _x _y <<< "${ref_heads[i]}"
            (( x_ = rootw - _x - w )) || :
            (( y_ = rooth - _y - h )) || :
            printf -v "$3[$i]" "%d,%d %d,%d" $_x $_y $x_ $y_
        else
            printf -v "$4[$i]" %d $i
        fi
    done
}

parse_geospec_get_corners() {
    local geospec=$1
    local _x _y x_ y_ w h
    local n='?([-+])+([0-9])'
    local m='?(-)+([0-9])'
    local N='+([0-9])'
    local s='@(*([ \t]),*([ \t])|+([ \t]))'
    # strip whitespaces
    IFS=$' \t' read -r geospec <<< "$geospec"
    case $geospec in
        $n$s$n$s$n$s$n)  # x1,y1 x2,y2
            IFS=$', \t' read _x _y x_ y_ <<< "$geospec"
            ;;
        ${N}x${N}\+${m}\+${m})  # wxh+x+y
            IFS='x+' read w h _x _y <<< "$geospec"
            (( x_ = rootw - _x - w )) || :
            (( y_ = rooth - _y - h )) || :
            ;;
        *)
            return 1
            ;;
    esac
    printf '%d,%d %d,%d\n' $_x $_y $x_ $y_
}

# Note: without knowlege of the size of the root window, it's not possible to
# determine whether the resulting corner offsets define a valid region.
# The resulting geometry must be checked in the context of the root window.
region_intersect_corners() {
    local corners
    local _x _y x_ y_
    local _X _Y X_ Y_
    # Initialize variable- otherwise bash will fallback to 0
    IFS=' ,' read _X _Y X_ Y_ <<< "$1"
    shift || return 1
    for corners in "$@"; do
        IFS=' ,' read _x _y x_ y_ <<< "$corners"
        (( _X = _x > _X ? _x : _X )) || :
        (( _Y = _y > _Y ? _y : _Y )) || :
        (( X_ = x_ > X_ ? x_ : X_ )) || :
        (( Y_ = y_ > Y_ ? y_ : Y_ )) || :
    done
    printf '%d,%d %d,%d\n' $_X $_Y $X_ $Y_
}

region_union_corners() {
    local corners
    local _x _y x_ y_
    local _X _Y X_ Y_
    # Initialize variable- otherwise bash will fallback to 0
    IFS=' ,' read _X _Y X_ Y_ <<< "$1"
    shift || return 1
    for corners in "$@"; do
        IFS=' ,' read _x _y x_ y_ <<< "$corners"
        (( _X = _x < _X ? _x : _X )) || :
        (( _Y = _y < _Y ? _y : _Y )) || :
        (( X_ = x_ < X_ ? x_ : X_ )) || :
        (( Y_ = y_ < Y_ ? y_ : Y_ )) || :
    done
    printf '%d,%d %d,%d\n' $_X $_Y $X_ $Y_
}

select_region_get_corners() {
    msg "%s" "please select a region using mouse"
    xrectsel_get_corners
}

select_window_get_corners() {
    msg "%s" "please click once in target window"
    LC_ALL=C xwininfo | xwininfo_get_corners
}

window_id_get_corners() {
    msg "get corners by window ID %x" "$1"
    LC_ALL=C xwininfo -id "$1" | xwininfo_get_corners
}

# stdin: xdpyinfo -ext XINERAMA (preferably sanitized)
# $1: array variable to assign heads to, i.e. =([id]=geometry ...)
xdpyinfo_get_heads_by_ref() {
    local line
    local i w h x y
    local n='+([0-9])'
    # See print_xinerama_info() in xdpyinfo.c
    local head="head #$n: ${n}x$n @ $n,$n"
    while IFS=' ' read -r line; do
        if [[ $line == $head ]]; then
            IFS=' :x@,' read i w h x y <<< "${line#head #}"
            printf -v "$1[$i]" "%dx%d+%d+%d" $w $h $x $y
        fi
    done
    [[ -n $i ]]
}

xdpyinfo_list_heads() {
    xdpyinfo -ext XINERAMA | grep '^  head #' | sed 's/^ *//'
}

# stdout: left, right, top, bottom
# $1: window ID
xprop_get_frame_extents() {
    xprop -id "$1" -notype _NET_FRAME_EXTENTS |
    grep '^_NET_FRAME_EXTENTS = ' | sed 's/.*= //'
}

# stdout: x1,y1 x2,y2
xrectsel_get_corners() {
    # Note: requires xrectsel 0.3
    xrectsel "%x,%y %X,%Y"$'\n'
}

# stdin: xwininfo output (locale: C)
# stdout: ${width}x${height}
xwininfo_get_dimensions() {
    local line
    local w h
    while IFS=$' \t' read -r line; do
        if [[ $line == 'Width: '+([0-9]) ]]; then
            w=${line#'Width: '}
        elif [[ $line == 'Height: '+([0-9]) ]]; then
            h=${line#'Height: '}
        else
            continue
        fi
        if (( w && h )); then
            printf '%dx%d\n' $w $h
            return
        fi
    done
    return 1
}

# stdin: xwininfo output (locale: C)
# stdout: x1,y1 x2,y2
xwininfo_get_corners() {
    local line
    local _x _y x_ y_ b
    local fl fr ft fb id
    local n='-?[0-9]+'
    local corners="^Corners: *\\+($n)\\+($n) *-$n\\+$n *-($n)-($n) *\\+$n-$n\$"
    local window_id="^xwininfo: Window id: (0x[[:xdigit:]]+)"
    # Note: explicitly set IFS to ensure stripping of whitespaces
    while IFS=$' \t' read -r line && [[ -z $id || -z $_x || -z $b ]]; do
        if [[ $line =~ $window_id ]]; then
            id=${BASH_REMATCH[1]}
        elif [[ $line == 'Border width: '+([0-9]) ]]; then
            b=${line#'Border width: '}
        elif [[ $line =~ $corners ]]; then
            _x=${BASH_REMATCH[1]}
            _y=${BASH_REMATCH[2]}
            x_=${BASH_REMATCH[3]}
            y_=${BASH_REMATCH[4]}
        fi
    done
    [[ -n $id && -n $_x && -n $b ]] || return 1
    if (( frame )); then
        if ! xprop_get_frame_extents "$id" | IFS=' ,' read fl fr ft fb; then
            warn "unable to determine frame extents for window %s" "$id"
        else
            (( _x -= fl )) || :
            (( _y -= ft )) || :
            (( x_ -= fr )) || :
            (( y_ -= fb )) || :
        fi
    elif (( ! borders )); then
            (( _x += b )) || :
            (( _y += b )) || :
            (( x_ += b )) || :
            (( y_ += b )) || :
    fi
    printf '%d,%d %d,%d\n' $_x $_y $x_ $y_
}

run_default_command() {
    printf "%dx%d+%d+%d\n" $w $h $_x $_y
}

run_external_command() {
    local -- cmd=$1
    shift || return 0
    local -a args=()
    # always substitute format strings for external commands
    while (( $# )); do
        args+=("$(format_to_string "$1")")
        shift
    done
    verbose_run command "$cmd" "${args[@]}"
}

run_subcmd_or_print() {
    local sub_cmd=$1
    if [[ -z $sub_cmd ]]; then
        run_default_command
        exit
    fi
    if [[ -v sub_commands[$sub_cmd] ]]; then
        shift
        local sub_cmd_func=${sub_cmdfuncs[$sub_cmd]:-$sub_cmd}
        if [[ $(type -t "$sub_cmd_func") == function ]]; then
            verbose_run "$sub_cmd_func" "$@"
        else
            error "sub-command '%s' function '%s' not found" "$sub_cmd" \
                "$sub_cmd_func"
            exit 1
        fi
    else
        run_external_command "$@"
    fi
}

set_region_vars_by_corners() {
    if [[ ! -v corners ]]; then
        "${logl[${1:- 0}]}" '$corners is unset'
        return 1
    fi
    if ! printf '%s\n' "$corners" | IFS=' ,' read _x _y x_ y_; then
        "${logl[${1:- 0}]}" 'bad corners: %s' "$corners"
        return 1
    fi
    ((w = rootw - _x - x_)) || :
    ((h = rooth - _y - y_)) || :
    if ! ((  w > 0 && h > 0 )); then
        "${logl[${1:- 0}]}" 'invalid region size: %sx%s' "$w" "$h"
        debug '%s' "$(declare -p {root,}{w,h} _{x,y} {x,y}_)"
        return 1
    fi
}

#---
# Process arguments passed to ffcast

[[ ! -t 2 ]] || msg_colors_on

usage() {
    cat <<EOF
@PRGNAME@ @VERSION@
Usage:
  ${0##*/} [options] [sub-command [args]] [command [args]]

  Options:
    -g <geospec> specify a region in numeric geometry
    -s           select a rectangular region by mouse
    -w           select a window by mouse click
    -# <n>       select a window by window ID
    -x <n|list>  select the Xinerama head of ID n
    -b           include window borders hereafter
    -f           include window frame hereafter
    -i           combine regions by intersection
    -q           be less verbose
    -v           be more verbose
    -h           print this help and exit

  All the options can be repeated, and are processed in order.
  Selections are combined by union, unless -i is specified.
  If no region-selecting options are given, select fullscreen.
EOF
  exit $1
}

OPTIND=1
while getopts ':#:bfg:hiqsvwx:' opt; do
    case $opt in
        h) usage 0;;
        g) geospecs+=("$OPTARG");;
        s) region_select_action+='s';;
        w) region_select_action+='w';;
       \#) region_select_action+='#'; window_ids+=("$OPTARG");;
        x)
            if [[ $OPTARG == l?(ist) ]]; then
                xdpyinfo_list_heads
                exit
            fi
            IFS=' ,' read -a ids <<< "$OPTARG"
            for i in "${ids[@]}"; do
                if [[ $i != +([0-9]) ]]; then
                    error "invalid head IDs: \'%s'" "$OPTARG"
                    exit 1
                fi
                (( i = 10#$i )) || :
                # Note: use i as key to discard duplicates
                head_ids[i]=$i
            done
            ;;
        b) region_select_action+='b';;
        f) region_select_action+='f';;
        i) intersection=1;;
        q) (( (verbosity > 0) && verbosity-- )) || :;;
        v) (( (verbosity < ${#logl[@]}-1) && verbosity++ )) || :;;
        '?') error "invalid option: \`%s'" "$OPTARG"; exit 1;;
        ':') error "option requires an argument: \`%s'" "$OPTARG"; exit 1;;
    esac
done
shift $(( OPTIND -1 ))

#---
# Process region geometry

declare rootw=0 rooth=0 _x=0 _y=0 x_=0 y_=0 w=0 h=0
LC_ALL=C xwininfo -root | xwininfo_get_dimensions | IFS=x read rootw rooth

# Note: this is safe because xwininfo_get_dimensions ensures that its output is
# either {int}x{int} or null, a random string like "rootw" is impossible.
if ! (( rootw && rooth )); then
    error 'invalid root window dimensions: %dx%d' "$rootw" "$rooth"
    exit 1
fi

declare -- i=0 wid=0 corners geospec
declare -a corners_list=() heads=() head_ids_bad=()

if (( ${#head_ids[@]} )); then
    if ! xdpyinfo_list_heads | xdpyinfo_get_heads_by_ref heads; then
        error 'failed to get head list'
        exit 1
    fi
    debug '%s' "$(declare -p heads)"
    heads_get_corners_list_by_ref heads head_ids corners_list head_ids_bad
    debug '%s' "$(declare -p corners_list)"
    if (( ! ${#corners_list[@]} )); then
        error 'none of the specified head IDs exists'
        exit 1
    fi
    if (( ${#head_ids_bad[@]} )); then
        warn "ignored non-existent head IDs: %s" "${head_ids_bad[*]}"
    fi
    corners_list=("${corners_list[@]}")  # indexing
    i=${#corners_list[@]}
fi

for geospec in "${geospecs[@]}"; do
    if ! corners=$(parse_geospec_get_corners "$geospec"); then
        warn "ignored invalid geometry specification: \`%s'" "$geospec"
    else
        corners_list[i++]=$corners
        debug_array_by_key corners_list $(( i - 1 ))
    fi
done

printf %s "$region_select_action" |
while read -n 1; do
    case $REPLY in
        's')
            corners_list[i++]=$(select_region_get_corners)
            debug_array_by_key corners_list $(( i - 1 ))
            ;;
        'w')
            corners_list[i++]=$(select_window_get_corners)
            debug_array_by_key corners_list $(( i - 1 ))
            ;;
        '#')
            corners_list[i++]=$(window_id_get_corners "${window_ids[wid]}")
            (( ++wid ))
            debug_array_by_key corners_list $(( i - 1 ))
            ;;
        'b')
            borders=1
            verbose "windows: now including borders"
            ;;
        'f')
            frame=1
            verbose "windows: now including window manager frame"
            ;;
    esac
done

if (( i )); then
    if (( intersection )); then
        corners=$(region_intersect_corners "${corners_list[@]}")
        debug "intersection(corners_list[@]) -> corners=%q" "${corners}"
    else
        corners=$(region_union_corners "${corners_list[@]}")
        debug "union(corners_list[@]) -> corners=%q" "${corners}"
    fi
    corners=$(region_intersect_corners "$corners" '0,0 0,0')
    debug "corners.intersection('0,0 0,0') -> corners=%q" "${corners}"
else
    corners='0,0 0,0'
    verbose 'no valid user selection, falling back to fullscreen'
    corners_list=("$corners")
    debug '%s' "$(declare -p corners_list)"
fi

set_region_vars_by_corners || exit 1

#---
# Import predefined sub-commands

# a little optimization
(( $# )) || { run_default_command; exit; }

for srcdir in "${srcdirs[@]}"; do
    subcmdsrc=$srcdir/subcmd
    if [[ -r $subcmdsrc ]]; then
        verbose "importing sub-commands from file %s" "$subcmdsrc"
        . "$subcmdsrc"
    fi
done
unset -v srcdir subcmdsrc

# make sure these are not defined as sub-commands
for cmd in builtin command; do
    unset -f $cmd
    if [[ -v sub_commands[$cmd] ]]; then
        unset -v sub_commands[$cmd]
        warn 'unset sub-command %s' "$cmd"
    fi
done
unset -v cmd

#---
# Execute

run_subcmd_or_print "$@"

# vim:ts=4:sw=4:et:cc=80:
