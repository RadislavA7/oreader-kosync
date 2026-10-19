#!/system/bin/sh
# OReader (AlReader) <-> KoSync
#   kosync.sh push [книга]   - отправить позиции (все книги или одну)
#   kosync.sh pull [книга]   - принять позиции с X4
#   kosync.sh status [книга] - показать, ничего не меняя

SERVER=""
AUTH_USER=""
AUTH_KEY=""

# settings may be overridden from the SD card by the app
CONF="/sdcard/oreader-kosync/kosync.conf"
if [ -f "$CONF" ]; then . "$CONF"; fi

STATE_DIR="/sdcard/oreader-kosync"
SQLITE="/data/local/tmp/sqlite3"
DB="/data/data/com.neverland.oreader/databases/alreader.db"
CAL="/data/local/tmp/kosync-cal.txt"
BOOKPOS="/data/local/tmp/bookpos"
DEVICE_NAME="OReader"
DEVICE_ID="onyx-i63ml"
KEEP_BACKUPS=10
TIMEOUT=20
HOLD=2

# Gingerbread ships awk/sed/... only inside busybox: build a PATH shim
BIN="/data/local/tmp/bin"
if [ ! -x "$BIN/awk" ]; then
  busybox mkdir -p "$BIN"
  for a in awk sed tr tail cut wc md5sum pidof head date mkdir rm cat ls nc printf sleep; do
    busybox ln -sf /system/bin/busybox "$BIN/$a" 2>/dev/null
  done
fi
PATH="$BIN:/system/bin:/system/xbin:/data/local/tmp"
export PATH

# sqlite3 reads ~/.sqliterc on startup; without HOME it prints a warning
HOME=/data/local/tmp
export HOME

HOST=$(echo "$SERVER" | sed -e 's#^http://##' -e 's#/.*##' -e 's#:.*##')
PORT=$(echo "$SERVER" | sed -e 's#^http://##' -e 's#/.*##')
case "$PORT" in
  *:*) PORT=${PORT##*:} ;;
  *) PORT=80 ;;
esac
IP=""

MODE="$1"
BOOK="$2"
ROWS="$STATE_DIR/rows.txt"

die() { echo "ОШИБКА: $*" >&2; exit 1; }

[ -n "$SERVER" ] || die "не настроен сервер: заполните $CONF (см. kosync.conf.example)"
[ -n "$AUTH_USER" ] || die "не настроен пользователь: заполните $CONF"
[ -n "$AUTH_KEY" ] || die "не настроен пароль/ключ: заполните $CONF"

[ -x "$SQLITE" ] || die "не найден sqlite3 ($SQLITE)"
[ -f "$DB" ] || die "не найдена база OReader ($DB)"
busybox mkdir -p "$STATE_DIR"

# ---------- helpers ----------
ensure_net() {
  if ifconfig wlan0 2>/dev/null | busybox grep -qE "inet addr|wlan0: ip "; then return 0; fi
  echo "Включаю Wi-Fi..."
  svc wifi enable >/dev/null 2>&1
  i=0
  while [ "$i" -lt 20 ]; do
    sleep 1
    if ifconfig wlan0 2>/dev/null | busybox grep -qE "inet addr|wlan0: ip "; then return 0; fi
    i=$((i+1))
  done
  return 1
}

# busybox cannot resolve names on this ROM, but the system resolver can:
# ping fills in the IP, then we talk to the IP with the right Host header
resolve_host() {
  [ -n "$IP" ] && return 0
  case "$HOST" in
    [0-9]*.[0-9]*.[0-9]*.[0-9]*) IP="$HOST"; return 0 ;;
  esac
  i=0
  while [ "$i" -lt 10 ]; do
    IP=$(ping -c 1 -W 3 "$HOST" 2>/dev/null | awk -F'[()]' 'NR==1{print $2}')
    case "$IP" in
      [0-9]*.[0-9]*.[0-9]*.[0-9]*) return 0 ;;
    esac
    IP=""
    sleep 2
    i=$((i+1))
  done
  die "не удалось определить адрес $HOST (нет интернета?)"
}

release_reader() {
  if ! pidof com.neverland.oreader > /dev/null; then return 0; fi
  if dumpsys activity activities 2>/dev/null | busybox grep -i "mFocusedActivity" | busybox grep -q "com.neverland.oreader"; then
    die "книга открыта на экране. Закройте её и нажмите кнопку ещё раз"
  fi
  busybox kill -9 $(pidof com.neverland.oreader) 2>/dev/null
  sleep 1
  return 0
}

# busybox nc drops the connection as soon as stdin ends, so the request is
# followed by a short sleep: otherwise the response body is lost
http_req() { # method path body
  m="$1"; p="$2"; b="$3"
  resolve_host
  len=$(printf '%s' "$b" | wc -c | tr -d ' ')
  {
    printf '%s %s HTTP/1.0\r\n' "$m" "$p"
    printf 'Host: %s\r\n' "$HOST"
    printf 'x-auth-user: %s\r\n' "$AUTH_USER"
    printf 'x-auth-key: %s\r\n' "$AUTH_KEY"
    printf 'Accept: application/vnd.koreader.v1+json\r\n'
    if [ "$m" = "PUT" ] || [ "$m" = "POST" ]; then
      printf 'Content-Type: application/json\r\n'
      printf 'Content-Length: %s\r\n' "$len"
    fi
    printf 'Connection: close\r\n\r\n'
    [ -n "$b" ] && printf '%s' "$b"
    sleep "$HOLD"
  } | nc -w "$TIMEOUT" "$IP" "$PORT"
}

book_file() { echo "${1%%:*}"; }
book_name() { f=$(book_file "$1"); echo "${f##*/}"; }
md5_of()    { printf '%s' "$1" | md5sum | awk '{print $1}'; }
pct_of()    { awk "BEGIN{printf \"%.1f\", 100*$1/$2}"; }

# per-book calibration lines: "<document> <oreader_pct> <crosspoint_pct>",
# used to translate our percentage into CrossPoint's percentage so that
# its percentage-display and fallback positioning stay close to XPath
cal_pairs() { busybox grep "^$1 " "$CAL" 2>/dev/null | awk '{print $2, $3}'; }

cal_to_x4() { # doc oreader_pct -> crosspoint_pct (piecewise linear)
  d=$1; x=$2
  pairs=$(cal_pairs "$d")
  if [ -z "$pairs" ]; then awk "BEGIN{printf \"%.4f\", $x}"; return; fi
  echo "$pairs" | awk -v x="$x" '
    { n++; X[n]=$1; Y[n]=$2 }
    END {
      for (i=2;i<=n;i++){ kx=X[i]; ky=Y[i]; j=i-1
        while (j>=1 && X[j]>kx){ X[j+1]=X[j]; Y[j+1]=Y[j]; j-- }
        X[j+1]=kx; Y[j+1]=ky }
      if (n==1) { y=Y[1]+(x-X[1]) }
      else if (x<=X[1]) { a=(Y[2]-Y[1])/(X[2]-X[1]); y=Y[1]+a*(x-X[1]) }
      else if (x>=X[n]) { a=(Y[n]-Y[n-1])/(X[n]-X[n-1]); y=Y[n]+a*(x-X[n]) }
      else { for(i=1;i<n;i++){ if (x>=X[i] && x<=X[i+1]) { a=(Y[i+1]-Y[i])/(X[i+1]-X[i]); y=Y[i]+a*(x-X[i]); break } } }
      if (y<0) y=0; if (y>100) y=100
      printf "%.4f", y
    }'
}

cal_from_x4() { # doc crosspoint_pct -> oreader_pct (inverse)
  d=$1; y0=$2
  pairs=$(cal_pairs "$d")
  if [ -z "$pairs" ]; then awk "BEGIN{printf \"%.4f\", $y0}"; return; fi
  echo "$pairs" | awk -v y="$y0" '
    { n++; X[n]=$1; Y[n]=$2 }
    END {
      for (i=2;i<=n;i++){ kx=X[i]; ky=Y[i]; j=i-1
        while (j>=1 && X[j]>kx){ X[j+1]=X[j]; Y[j+1]=Y[j]; j-- }
        X[j+1]=kx; Y[j+1]=ky }
      if (n==1) { x=X[1]+(y-Y[1]) }
      else if (y<=Y[1]) { a=(X[2]-X[1])/(Y[2]-Y[1]); x=X[1]+a*(y-Y[1]) }
      else if (y>=Y[n]) { a=(X[n]-X[n-1])/(Y[n]-Y[n-1]); x=X[n]+a*(y-Y[n]) }
      else { for(i=1;i<n;i++){ if (y>=Y[i] && y<=Y[i+1]) { a=(X[i+1]-X[i])/(Y[i+1]-Y[i]); x=X[i]+a*(y-Y[i]); break } } }
      if (x<0) x=0; if (x>100) x=100
      printf "%.4f", x
    }'
}

load_rows() {
  if [ "$BOOK" = "all" ]; then
    $SQLITE "$DB" "select _ID, POS, SZ, FNAME, DF from RLIST order by DF desc;" > "$ROWS"
  elif [ -n "$BOOK" ]; then
    $SQLITE "$DB" "select _ID, POS, SZ, FNAME, DF from RLIST where FNAME like '%$BOOK' or FNAME like '%$BOOK:%' order by DF desc limit 1;" > "$ROWS"
  else
    $SQLITE "$DB" "select _ID, POS, SZ, FNAME, DF from RLIST order by DF desc limit 1;" > "$ROWS"
  fi
  [ -s "$ROWS" ] || die "не нашёл книгу «${BOOK}»"
}

book_total() { # file -> total_c of our model (empty if bookpos fails)
  if [ -x "$BOOKPOS" ] && [ -f "$1" ]; then
    "$BOOKPOS" info "$1" 2>/dev/null | awk '/^total_c/ {print $2}'
  fi
}

bookpos_xp() { # file pos -> xpath (empty on failure)
  if [ -x "$BOOKPOS" ] && [ -f "$1" ] && [ -n "$2" ]; then
    "$BOOKPOS" p2x "$1" "$2" 2>/dev/null
  fi
}

bookpos_pos() { # file xpath -> pos in our model (empty on failure)
  if [ -x "$BOOKPOS" ] && [ -f "$1" ] && [ -n "$2" ]; then
    "$BOOKPOS" x2p "$1" "$2" 2>/dev/null
  fi
}

# ---------- push ----------
push_one() {
  id=$1; pos=$2; sz=$3; fname=$4
  base=$(book_name "$fname")
  file=$(book_file "$fname")
  if [ ! -f "$file" ]; then
    SKIP=$((SKIP+1)); SKIP_LIST="$SKIP_LIST $base (файла нет)"; return
  fi
  case "$pos" in ''|0) SKIP=$((SKIP+1)); SKIP_LIST="$SKIP_LIST $base (не открывалась)"; return ;; esac
  doc=$(md5_of "$base")
  case " $SEEN " in *" $doc "*) return ;; esac
  SEEN="$SEEN $doc"

  pct=$(awk "BEGIN{printf \"%.4f\", 100*$pos/$sz}")
  cp=$(cal_to_x4 "$doc" "$pct")
  frac=$(awk "BEGIN{printf \"%.6f\", $cp/100}")
  total=$(book_total "$file")
  xp=""
  if [ -n "$total" ] && [ "$total" -gt 0 ]; then
    ourpos=$(awk "BEGIN{printf \"%d\", $pos*$total/$sz+0.5}")
    xp=$(bookpos_xp "$file" "$ourpos")
  fi
  if [ -n "$xp" ]; then
    body=$(printf '{"document":"%s","progress":"%s","percentage":%s,"device":"%s","device_id":"%s"}' \
      "$doc" "$xp" "$frac" "$DEVICE_NAME" "$DEVICE_ID")
  else
    body=$(printf '{"document":"%s","progress":"%.6f","percentage":%s,"device":"%s","device_id":"%s"}' \
      "$doc" "$frac" "$frac" "$DEVICE_NAME" "$DEVICE_ID")
  fi
  resp=$(http_req PUT /syncs/progress "$body")
  case "$resp" in
    *'"document"'*)
      if [ -n "$xp" ]; then echo "  $base — $pct%  →  XPath"; else echo "  $base — $pct%  →  на X4 будет $cp%"; fi
      SENT=$((SENT+1)) ;;
    *)
      FAIL=$((FAIL+1)); FAIL_LIST="$FAIL_LIST $base" ;;
  esac
}

# ---------- pull ----------
pull_one() {
  id=$1; pos=$2; sz=$3; fname=$4; df=$5
  base=$(book_name "$fname")
  file=$(book_file "$fname")
  [ -f "$file" ] || return
  doc=$(md5_of "$base")
  case " $SEEN " in *" $doc "*) return ;; esac
  SEEN="$SEEN $doc"

  resp=$(http_req GET "/syncs/progress/$doc" "")
  prog=$(echo "$resp" | sed -n 's/.*"progress":"\([^"]*\)".*/\1/p' | tail -n 1)
  [ -n "$prog" ] || { NONE=$((NONE+1)); return; }
  ts=$(echo "$resp" | sed -n 's/.*"timestamp":[ ]*\([0-9]*\).*/\1/p' | tail -n 1)
  src=$(echo "$resp" | sed -n 's/.*"device":"\([^"]*\)".*/\1/p' | tail -n 1)

  frac=$(echo "$resp" | sed -n 's/.*"percentage":[ ]*\([0-9.eE+-]*\).*/\1/p' | tail -n 1)

  newpos=""; newpct=""; how=""
  case "$prog" in
    /body/*)
      total=$(book_total "$file")
      ourpos=$(bookpos_pos "$file" "$prog")
      if [ -n "$total" ] && [ -n "$ourpos" ] && [ "$total" -gt 0 ]; then
        newpos=$(awk "BEGIN{printf \"%d\", $ourpos*$sz/$total+0.5}")
        newpct=$(awk "BEGIN{printf \"%.4f\", 100*$newpos/$sz}")
        how="XPath"
      fi ;;
  esac
  if [ -z "$newpos" ]; then
    [ -n "$frac" ] || { NONE=$((NONE+1)); return; }
    fracpct=$(awk "BEGIN{printf \"%.4f\", $frac*100}")
    pct=$(cal_from_x4 "$doc" "$fracpct")
    newpos=$(awk "BEGIN{printf \"%d\", $pct/100*$sz}")
    newpct=$(awk "BEGIN{printf \"%.4f\", $pct}")
    how="процент"
  fi

  if [ "$newpos" = "$pos" ]; then SAME=$((SAME+1)); return; fi

  $SQLITE "$DB" "update RLIST set POS=$newpos where _ID=$id;"
  got=$($SQLITE "$DB" "select POS from RLIST where _ID=$id;")
  if [ "$got" = "$newpos" ]; then
    echo "  $base — переставлено на $newpct%"
    UPD=$((UPD+1))
  else
    FAIL=$((FAIL+1)); FAIL_LIST="$FAIL_LIST $base"
  fi
}

backup_db() {
  cat "$DB" > "$STATE_DIR/db-$(date +%s).db"
  ls -t "$STATE_DIR"/db-*.db 2>/dev/null | tail -n +$((KEEP_BACKUPS+1)) | while read -r f; do rm -f "$f"; done
}

# ---------- main ----------
case "$MODE" in
  status)
    ensure_net || die "не удалось поднять Wi-Fi"
    load_rows
    while IFS='|' read -r id pos sz fname df; do
      [ -n "$id" ] || continue
      base=$(book_name "$fname")
      doc=$(md5_of "$base")
      echo "книга: $base"
      echo "позиция: $pos из $sz ($(pct_of "$pos" "$sz")%)"
      echo "на сервере: $(http_req GET "/syncs/progress/$doc" "" | awk 'NF' | tail -n 1)"
    done < "$ROWS"
    ;;

  server)
    ensure_net || die "не удалось поднять Wi-Fi"
    load_rows
    while IFS='|' read -r id pos sz fname df; do
      [ -n "$id" ] || continue
      base=$(book_name "$fname")
      file=$(book_file "$fname")
      doc=$(md5_of "$base")
      lpct=$(awk "BEGIN{printf \"%.2f\", 100*$pos/$sz}")
      resp=$(http_req GET "/syncs/progress/$doc" "")
      prog=$(echo "$resp" | sed -n 's/.*"progress":"\([^"]*\)".*/\1/p' | tail -n 1)
      frac=$(echo "$resp" | sed -n 's/.*"percentage":[ ]*\([0-9.eE+-]*\).*/\1/p' | tail -n 1)
      dev=$(echo "$resp" | sed -n 's/.*"device":"\([^"]*\)".*/\1/p' | tail -n 1)
      ts=$(echo "$resp" | sed -n 's/.*"timestamp":[ ]*\([0-9]*\).*/\1/p' | tail -n 1)
      spct=""
      case "$prog" in
        /body/*)
          total=$(book_total "$file")
          ourpos=$(bookpos_pos "$file" "$prog")
          if [ -n "$total" ] && [ -n "$ourpos" ] && [ "$total" -gt 0 ]; then
            spct=$(awk "BEGIN{printf \"%.2f\", 100*$ourpos/$total}")
          fi ;;
      esac
      if [ -z "$spct" ] && [ -n "$frac" ]; then
        spct=$(cal_from_x4 "$doc" "$(awk "BEGIN{printf \"%.4f\", $frac*100}")")
        spct=$(awk "BEGIN{printf \"%.2f\", $spct}")
      fi
      echo "book=$base"
      echo "local=$lpct"
      echo "server=$spct"
      echo "device=$dev"
      echo "time=$ts"
      break
    done < "$ROWS"
    ;;

  push)
    ensure_net || die "не удалось поднять Wi-Fi"
    resolve_host
    load_rows
    if [ -z "$BOOK" ]; then
      echo "Отправляю последнюю открытую книгу на Xteink X4 (через $HOST)"
    else
      echo "Отправляю позиции на Xteink X4 (через $HOST)"
    fi
    SENT=0; SKIP=0; FAIL=0; SKIP_LIST=""; FAIL_LIST=""; SEEN=""
    while IFS='|' read -r id pos sz fname df; do
      [ -n "$id" ] || continue
      push_one "$id" "$pos" "$sz" "$fname"
    done < "$ROWS"
    echo ""
    if [ "$FAIL" -gt 0 ]; then
      echo "НЕ ВСЁ ПОЛУЧИЛОСЬ: сервер не принял —$FAIL_LIST"
    else
      echo "ГОТОВО: позиции на сервере обновлены"
    fi
    echo "Отправлено книг: $SENT."
    [ "$SKIP" -gt 0 ] && echo "Пропущено: $SKIP —$SKIP_LIST"
    ;;

  pull)
    ensure_net || die "не удалось поднять Wi-Fi"
    resolve_host
    release_reader
    load_rows
    if [ -z "$BOOK" ]; then
      echo "Загружаю последнюю открытую книгу с Xteink X4 (через $HOST)"
    else
      echo "Загружаю позиции с Xteink X4 (через $HOST)"
    fi
    backup_db
    UPD=0; SAME=0; NONE=0; FAIL=0; FAIL_LIST=""; SEEN=""
    while IFS='|' read -r id pos sz fname df; do
      [ -n "$id" ] || continue
      pull_one "$id" "$pos" "$sz" "$fname" "$df"
    done < "$ROWS"
    echo ""
    if [ "$FAIL" -gt 0 ]; then
      echo "НЕ ВСЁ ПОЛУЧИЛОСЬ: не записалось —$FAIL_LIST"
    else
      echo "ГОТОВО: база OReader обновлена"
    fi
    echo "Переставлено книг: $UPD. Без изменений: $SAME."
    ;;

  *)
    echo "Как пользоваться:"
    echo "  kosync.sh push  - отправить свои позиции"
    echo "  kosync.sh pull  - забрать позиции с X4"
    exit 2
    ;;
esac
