#!/bin/sh
# POSIX sh (no bashisms).

set -u

if [ "$#" -lt 1 ]; then
  echo "usage: linux.sh <data>" >&2
  exit 1
fi

DATA=$1
if [ ! -d "$DATA" ]; then
  echo "data directory does not exist: $DATA" >&2
  exit 1
fi
mkdir -p "$DATA/cmd" 2>/dev/null || true

cr=$(printf '\r')
tab=$(printf '\t')
nl='
'
US=$(printf '\037')

log() {
  _lg="$DATA/helper.log"
  if [ -f "$_lg" ]; then
    _sz=$(wc -c < "$_lg" 2>/dev/null || echo 0)
    case "$_sz" in ''|*[!0-9]*) _sz=0 ;; esac
    if [ "$_sz" -gt 65536 ]; then : > "$_lg"; fi
  fi
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)" "$1" >> "$_lg" 2>/dev/null
}

LOCK="$DATA/helper.lock"
OWN_LOCK=0

cleanup() {
  if [ "$OWN_LOCK" = 1 ]; then
    rm -rf "$LOCK" 2>/dev/null
  fi
}
trap cleanup EXIT
trap 'exit 0' INT TERM HUP

acquire_lock() {
  if mkdir "$LOCK" 2>/dev/null; then
    OWN_LOCK=1
    return 0
  fi
  _stale=0
  _statefile="$DATA/state.txt"
  if [ ! -f "$_statefile" ]; then
    _stale=1
  else
    _beat=""
    while IFS= read -r _line; do
      case "$_line" in
        beat=*) _beat=${_line#beat=}; break ;;
      esac
    done < "$_statefile"
    case "$_beat" in
      ''|*[!0-9]*) _stale=1 ;;
      *)
        _n=$(date +%s)
        if [ $((_n - _beat)) -gt 10 ]; then _stale=1; fi
        ;;
    esac
  fi
  if [ "$_stale" = 1 ]; then
    rm -rf "$LOCK" 2>/dev/null
    if mkdir "$LOCK" 2>/dev/null; then
      OWN_LOCK=1
      return 0
    fi
  fi
  exit 0
}
acquire_lock

START=$(date +%s)

HAS_PGREP=0
command -v pgrep >/dev/null 2>&1 && HAS_PGREP=1

PLAYERCTL_OK=0
command -v playerctl >/dev/null 2>&1 && PLAYERCTL_OK=1

if [ "$PLAYERCTL_OK" = 1 ] && command -v timeout >/dev/null 2>&1; then
  playerctl() { timeout 2 playerctl "$@"; }
fi

PROBLEM=""
if [ "$PLAYERCTL_OK" = 0 ]; then
  PROBLEM="playerctl is not installed (needed to control Spotify on Linux)"
fi

esc() {
  _v=$1
  case "$_v" in
    *"$nl"*|*"$cr"*) _v=$(printf '%s' "$_v" | tr '\r\n' '  ') ;;
  esac
}

trim() {
  _t=$1
  while :; do
    case "$_t" in
      *"$cr"|*"$nl"|*"$tab"|*' ') _t=${_t%?} ;;
      *) break ;;
    esac
  done
  while :; do
    case "$_t" in
      "$cr"*|"$nl"*|"$tab"*|' '*) _t=${_t#?} ;;
      *) break ;;
    esac
  done
  printf '%s' "$_t"
}

strip_leading_zeros() {
  _z=$1
  while :; do
    case "$_z" in
      0?*) _z=${_z#0} ;;
      *) break ;;
    esac
  done
}

sec_to_ms() {
  _s=$1
  case "$_s" in
    ''|*[!0-9.]*) _ms=""; return ;;
  esac
  case "$_s" in
    *.*) _ip=${_s%%.*}; _fr=${_s#*.} ;;
    *)   _ip=$_s;       _fr="" ;;
  esac
  case "$_fr" in
    *[!0-9]*) _ms=""; return ;;
  esac
  [ -n "$_ip" ] || _ip=0
  strip_leading_zeros "$_ip"; _ip=$_z
  _fr=$(printf '%.3s' "${_fr}000")
  strip_leading_zeros "$_fr"; _fr=$_z
  _ms=$((_ip * 1000 + _fr))
}

vol_to_pct() {
  _v=$1
  case "$_v" in
    ''|*[!0-9.]*) _pct=""; return ;;
  esac
  case "$_v" in
    *.*) _ip=${_v%%.*}; _fr=${_v#*.} ;;
    *)   _ip=$_v;       _fr="" ;;
  esac
  case "$_fr" in
    *[!0-9]*) _pct=""; return ;;
  esac
  [ -n "$_ip" ] || _ip=0
  strip_leading_zeros "$_ip"; _ip=$_z
  _fr=$(printf '%.2s' "${_fr}00")
  strip_leading_zeros "$_fr"; _fr=$_z
  _pct=$((_ip * 100 + _fr))
}

pct_to_arg() {
  _p=$1
  strip_leading_zeros "$_p"; _p=$_z
  [ -n "$_p" ] || _p=0
  [ "$_p" -gt 100 ] 2>/dev/null && _p=100
  _va=$(printf '%d.%02d' "$((_p / 100))" "$((_p % 100))")
}

ms_to_arg() {
  _m=$1
  strip_leading_zeros "$_m"; _m=$_z
  [ -n "$_m" ] || _m=0
  _ma=$(printf '%d.%03d' "$((_m / 1000))" "$((_m % 1000))")
}

FMT="{{xesam:title}}${US}{{xesam:artist}}${US}{{xesam:album}}${US}{{mpris:length}}${US}{{mpris:trackid}}${US}{{mpris:artUrl}}"

seq=0
pos_seq=0
ack=""
cmd_error=""
last_sig="__init__"
last_write=0

prev_pos=""
prev_status=""
prev_track=""
prev_time=0

now=0
running=0
status=""; title=""; artist=""; album=""; track_id=""; duration_ms=""
position_ms=""; shuffle=""; repeat=""; volume=""; muted=""
art_url=""; art_key=""
problem="$PROBLEM"
can_play=0; can_next=0; can_prev=0; can_seek=0
can_shuffle=0; can_repeat=0; can_volume=0; can_mute=0
_proc=0; _st=""; _md=""; _pr=""; _vr=""; _sr=""; _lr=""
_mlen=""; _mtid=""; _mart=""; _oldifs=""
_can_shuffle=0; _can_repeat=0
did_cmd=0

read_state() {
  now=$(date +%s)

  if [ "$HAS_PGREP" = 1 ]; then
    if pgrep -x spotify >/dev/null 2>&1; then _proc=1; else _proc=0; fi
  else
    _proc=2
  fi

  running=0
  status=""; title=""; artist=""; album=""; track_id=""; duration_ms=""
  position_ms=""; shuffle=""; repeat=""; volume=""; muted=""
  art_url=""; art_key=""
  problem="$PROBLEM"

  if [ "$PLAYERCTL_OK" = 1 ]; then
    if [ "$_proc" != 0 ]; then
      _st=$(playerctl -p spotify status 2>/dev/null) || _st=""
      if [ -n "$_st" ]; then running=1; else running=0; fi
      if [ "$running" = 1 ]; then
        case "$_st" in
          Playing) status=playing ;;
          Paused)  status=paused ;;
          Stopped) status=stopped ;;
          "")      status="" ;;
          *)       status=$(printf '%s' "$_st" | tr 'A-Z' 'a-z') ;;
        esac

        _md=$(playerctl -p spotify metadata --format "$FMT" 2>/dev/null) || _md=""
        _oldifs=$IFS
        IFS=$US
        set -f
        set -- $_md
        set +f
        IFS=$_oldifs
        title=${1-}; artist=${2-}; album=${3-}
        _mlen=${4-}; _mtid=${5-}; _mart=${6-}

        case "$_mart" in
          https://open.spotify.com/image/*)
            _mart="https://i.scdn.co/image/${_mart#https://open.spotify.com/image/}"
            ;;
        esac
        art_url=$_mart
        art_key=$_mart

        case "$_mlen" in
          ''|*[!0-9]*) ;;
          *) strip_leading_zeros "$_mlen"; _mlen=$_z; duration_ms=$((_mlen / 1000)) ;;
        esac

        if [ -n "$_mtid" ]; then
          track_id=$_mtid
        elif [ -n "$title$artist$album" ]; then
          track_id="$title|$artist|$album"
        fi

        _pr=$(playerctl -p spotify position 2>/dev/null) || _pr=""
        sec_to_ms "$_pr"; position_ms=$_ms

        _vr=$(playerctl -p spotify volume 2>/dev/null) || _vr=""
        vol_to_pct "$_vr"; volume=$_pct

        _sr=$(playerctl -p spotify shuffle 2>/dev/null) || _sr=""
        case "$_sr" in
          On|on|1)  shuffle=1 ;;
          Off|off|0) shuffle=0 ;;
          *) shuffle="" ;;
        esac
        if [ -z "$_sr" ]; then _can_shuffle=0; else _can_shuffle=1; fi

        _lr=$(playerctl -p spotify loop 2>/dev/null) || _lr=""
        case "$_lr" in
          None|none)         repeat=off ;;
          Track|track)       repeat=track ;;
          Playlist|playlist) repeat=context ;;
          *) repeat="" ;;
        esac
        if [ -z "$_lr" ]; then _can_repeat=0; else _can_repeat=1; fi
      fi
    fi
  else
    if [ "$_proc" = 1 ]; then running=1; fi
  fi

  esc "$title";    title=$_v
  esc "$artist";   artist=$_v
  esc "$album";    album=$_v
  esc "$track_id"; track_id=$_v
  esc "$art_url";  art_url=$_v
  esc "$art_key";  art_key=$_v

  if [ "$running" = 1 ]; then
    if [ -f "$DATA/premute" ]; then muted=1; else muted=0; fi
  fi

  if [ "$running" = 1 ] && [ "$PLAYERCTL_OK" = 1 ]; then
    can_play=1; can_next=1; can_prev=1
    if [ -n "$duration_ms" ]; then can_seek=1; else can_seek=0; fi
    can_shuffle=$_can_shuffle
    can_repeat=$_can_repeat
    if [ -n "$volume" ]; then can_volume=1; else can_volume=0; fi
    can_mute=$can_volume
  else
    can_play=0; can_next=0; can_prev=0; can_seek=0
    can_shuffle=0; can_repeat=0; can_volume=0; can_mute=0
  fi

  _bump=0
  if [ "$status" != "$prev_status" ]; then _bump=1; fi
  if [ "$track_id" != "$prev_track" ]; then _bump=1; fi
  if [ "$_bump" = 0 ] && [ -n "$position_ms" ] && [ -n "$prev_pos" ]; then
    _elapsed=$((now - prev_time))
    [ "$_elapsed" -ge 0 ] || _elapsed=0
    _expected=$prev_pos
    _limit=1500
    if [ "$prev_status" = playing ]; then
      _expected=$((prev_pos + _elapsed * 1000))
      _limit=2500
    fi
    _diff=$((position_ms - _expected))
    if [ "$_diff" -lt 0 ]; then _diff=$((-_diff)); fi
    if [ "$_diff" -gt "$_limit" ]; then _bump=1; fi
  fi
  pos_seq=$((pos_seq + _bump))

  prev_pos=$position_ms
  prev_status=$status
  prev_track=$track_id
  prev_time=$now

  sig="v=1
backend=linux
pid=$$
running=$running
status=$status
title=$title
artist=$artist
album=$album
track_id=$track_id
duration_ms=$duration_ms
pos_seq=$pos_seq
shuffle=$shuffle
repeat=$repeat
volume=$volume
muted=$muted
can_play=$can_play
can_next=$can_next
can_prev=$can_prev
can_seek=$can_seek
can_shuffle=$can_shuffle
can_repeat=$can_repeat
can_volume=$can_volume
can_mute=$can_mute
art_file=
art_url=$art_url
art_key=$art_key
ack=$ack
error=$cmd_error
problem=$problem"
}

emit_state() {
  _tmp="$DATA/state.txt.tmp"
  if {
    printf 'v=1\n'
    printf 'backend=linux\n'
    printf 'beat=%s\n' "$now"
    printf 'pid=%s\n' "$$"
    printf 'seq=%s\n' "$seq"
    printf 'running=%s\n' "$running"
    printf 'status=%s\n' "$status"
    printf 'title=%s\n' "$title"
    printf 'artist=%s\n' "$artist"
    printf 'album=%s\n' "$album"
    printf 'track_id=%s\n' "$track_id"
    printf 'duration_ms=%s\n' "$duration_ms"
    printf 'position_ms=%s\n' "$position_ms"
    printf 'pos_seq=%s\n' "$pos_seq"
    printf 'shuffle=%s\n' "$shuffle"
    printf 'repeat=%s\n' "$repeat"
    printf 'volume=%s\n' "$volume"
    printf 'muted=%s\n' "$muted"
    printf 'can_play=%s\n' "$can_play"
    printf 'can_next=%s\n' "$can_next"
    printf 'can_prev=%s\n' "$can_prev"
    printf 'can_seek=%s\n' "$can_seek"
    printf 'can_shuffle=%s\n' "$can_shuffle"
    printf 'can_repeat=%s\n' "$can_repeat"
    printf 'can_volume=%s\n' "$can_volume"
    printf 'can_mute=%s\n' "$can_mute"
    printf 'art_file=\n'
    printf 'art_url=%s\n' "$art_url"
    printf 'art_key=%s\n' "$art_key"
    printf 'ack=%s\n' "$ack"
    printf 'error=%s\n' "$cmd_error"
    printf 'problem=%s\n' "$problem"
  } > "$_tmp" 2>/dev/null; then
    mv -f "$_tmp" "$DATA/state.txt" 2>/dev/null || log "failed to rename state.txt.tmp"
  else
    log "failed to write state.txt.tmp"
  fi
}

process_commands() {
  did_cmd=0
  for _f in "$DATA/cmd"/*.cmd; do
    [ -e "$_f" ] || continue
    _work="$_f.work"
    mv "$_f" "$_work" 2>/dev/null || continue
    did_cmd=1

    _base=${_f##*/}
    _id=${_base%.cmd}

    _secs=${_id%%-*}
    _stale=0
    case "$_secs" in
      ''|*[!0-9]*) _stale=1 ;;
      *) if [ $((now - _secs)) -gt 15 ]; then _stale=1; fi ;;
    esac
    if [ "$_stale" = 1 ]; then
      rm -f "$_work" 2>/dev/null
      continue
    fi

    _cmd=""; _arg=""
    # `|| :` keeps a last line that has no newline (read fails at EOF but sets it).
    { IFS= read -r _cmd || :; IFS= read -r _arg || :; } < "$_work" 2>/dev/null
    _cmd=$(trim "$_cmd")
    _arg=$(trim "$_arg")
    if [ -z "$_cmd" ] && [ $((now - _secs)) -lt 3 ]; then
      mv "$_work" "$_f" 2>/dev/null || rm -f "$_work" 2>/dev/null
      continue
    fi

    _err=""
    case "$_cmd" in
      toggle|play|pause|next|previous|seek|shuffle|repeat|volume|mute)
        if [ "$PLAYERCTL_OK" = 0 ]; then
          _err="$PROBLEM"
        elif [ "$running" != 1 ]; then
          _err="Spotify isn't running"
        else
          case "$_cmd" in
            toggle)
              playerctl -p spotify play-pause >/dev/null 2>&1 || _err="Couldn't toggle playback"
              ;;
            play)
              playerctl -p spotify play >/dev/null 2>&1 || _err="Couldn't play"
              ;;
            pause)
              playerctl -p spotify pause >/dev/null 2>&1 || _err="Couldn't pause"
              ;;
            next)
              playerctl -p spotify next >/dev/null 2>&1 || _err="Couldn't skip"
              ;;
            previous)
              playerctl -p spotify previous >/dev/null 2>&1 || _err="Couldn't go back"
              ;;
            seek)
              case "$_arg" in
                ''|*[!0-9]*) _err="Invalid seek position" ;;
                *)
                  ms_to_arg "$_arg"
                  playerctl -p spotify position "$_ma" >/dev/null 2>&1 || _err="Couldn't seek"
                  ;;
              esac
              ;;
            shuffle)
              case "$_arg" in
                1) playerctl -p spotify shuffle On >/dev/null 2>&1 || _err="Couldn't set shuffle" ;;
                0) playerctl -p spotify shuffle Off >/dev/null 2>&1 || _err="Couldn't set shuffle" ;;
                *) _err="Invalid shuffle value" ;;
              esac
              ;;
            repeat)
              _val=""
              case "$_arg" in
                off)     _val=None ;;
                track)   _val=Track ;;
                context) _val=Playlist ;;
                *) _err="Invalid repeat value" ;;
              esac
              if [ -z "$_err" ]; then
                playerctl -p spotify loop "$_val" >/dev/null 2>&1 || _err="Couldn't set repeat"
              fi
              ;;
            volume)
              case "$_arg" in
                ''|*[!0-9]*) _err="Invalid volume" ;;
                *)
                  pct_to_arg "$_arg"
                  playerctl -p spotify volume "$_va" >/dev/null 2>&1 || _err="Couldn't set volume"
                  ;;
              esac
              ;;
            mute)
              case "$_arg" in
                1)
                  if [ ! -f "$DATA/premute" ]; then
                    _cur=$(playerctl -p spotify volume 2>/dev/null) || _cur=""
                    vol_to_pct "$_cur"; _save=$_pct
                    [ -n "$_save" ] || _save=50
                    printf '%s\n' "$_save" > "$DATA/premute" 2>/dev/null
                  fi
                  playerctl -p spotify volume 0.00 >/dev/null 2>&1 || _err="Couldn't mute"
                  ;;
                0)
                  _save=50
                  if [ -f "$DATA/premute" ]; then
                    IFS= read -r _save < "$DATA/premute" 2>/dev/null || :
                    rm -f "$DATA/premute" 2>/dev/null
                  fi
                  case "$_save" in ''|*[!0-9]*) _save=50 ;; esac
                  pct_to_arg "$_save"
                  playerctl -p spotify volume "$_va" >/dev/null 2>&1 || _err="Couldn't unmute"
                  ;;
                *) _err="Invalid mute value" ;;
              esac
              ;;
          esac
        fi
        ;;
      open)
        if [ "$running" = 1 ]; then
          if command -v wmctrl >/dev/null 2>&1; then
            wmctrl -a Spotify >/dev/null 2>&1 || true
          fi
        else
          if command -v spotify >/dev/null 2>&1; then
            if command -v setsid >/dev/null 2>&1; then
              setsid spotify >/dev/null 2>&1 </dev/null &
            else
              nohup spotify >/dev/null 2>&1 </dev/null &
            fi
          else
            _err="Spotify executable not found"
          fi
        fi
        ;;
      "")
        _err="Empty command"
        ;;
      *)
        _err="Unknown command: $_cmd"
        ;;
    esac

    esc "$_err"; _err=$_v
    ack=$_id
    cmd_error=$_err
    rm -f "$_work" 2>/dev/null
  done
}

if sleep 0.5 2>/dev/null; then
  SL=0.5
else
  SL=1
fi

while :; do
  read_state
  process_commands
  if [ "$did_cmd" = 1 ]; then
    read_state
  fi

  if [ "$sig" != "$last_sig" ]; then
    seq=$((seq + 1))
  fi

  _hb=2
  if [ "$status" = playing ]; then _hb=1; fi

  if [ "$sig" != "$last_sig" ] || [ $((now - last_write)) -ge "$_hb" ]; then
    emit_state
    last_sig=$sig
    last_write=$now
  fi

  _lease=""
  if [ -f "$DATA/lease" ]; then
    IFS= read -r _lease < "$DATA/lease" 2>/dev/null || :
    _lease=${_lease%"$cr"}
  fi
  case "$_lease" in ''|*[!0-9]*) _lease=0 ;; esac
  if [ $((now - _lease)) -gt 45 ] && [ $((now - START)) -gt 45 ]; then
    exit 0
  fi

  sleep "$SL"
done
