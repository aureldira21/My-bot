#!/data/data/com.termux/files/usr/bin/bash
# =====================================================================
#  REVIL TMUX MANAGER v7  -  Created by Revil
#  - 1 folder akun = 1 sesi tmux (nama sesi = nama folder), 2 pane:
#        pane 1 "lime"  = program 1 (LimeFaucet)
#        pane 2 "bux"   = program 2 (BuxFaucet: claim + auto withdraw)
#  - Jeda 30 detik antar pembuatan pane/sesi, cek folder baru tiap 1 menit
#  - Restart per sesi tiap 2 jam; restart per pane saat Max failures / cache / script mati
#  - Jam 23:00 tiap hari: BUX stop run -> proses WD semua koin -> balik run
#  - WD diproses -> DONE otomatis setelah 24 jam (ledger), digabung ke total akun
#  - Notif Telegram (HTML): claim lime, claim bux, cooldown (sekali per koin), WD, DONE
#  - Dua jalur kerja PARALEL: jalur lime & jalur bux jalan bersamaan (WD bux tidak menghentikan lime)
#  - Bot Telegram interaktif (proses sendiri, selalu responsif): /menu (tombol) -> status, balance, laporan, WD sekarang, IP, folder, restart
#  - Pantau IP & provider (kotak di header); IP berubah -> hapus file panel_* otomatis
#  - Ringan untuk banyak sesi: stream difilter, pengecekan bergilir, tanpa spawn berlebihan
#  - Laporan 24 jam jam 00:00 per program (lime, bux) + gabungan, uptime, pemulihan error
#  - Semua data laporan/ledger disimpan TERENKRIPSI di folder privat Termux (vault tersembunyi)
#  Perintah:  ./tmux_manager.sh              -> jalan normal
#             ./tmux_manager.sh report [tgl] -> kirim laporan sekarang (tes)
#             ./tmux_manager.sh wdnow        -> paksa proses WD semua akun sekarang (tes)
#             ./tmux_manager.sh vault list   -> daftar data terenkripsi
#             ./tmux_manager.sh vault show report-2026-10-08  -> buka (dekripsi) laporan JSON
# =====================================================================

# ---------------- KONFIGURASI ----------------------------------------
BOT_TOKEN="8874284172:AAFmtBszqpbqykF-fu9k58sy-V4qz4__ZmE"
CHAT_ID="8292649520"

BASE_DIR="/storage/emulated/0/Download/bot/akun"
BASE_DIR_FALLBACK="$HOME/storage/downloads/bot/akun"

LICENSE_KEY="ScriptyXSouu"
MENU_APIKEY="2"            # menu utama -> 2 = APIKEY
MENU_FAUCET="11"           # daftar program -> 11 = LimeFaucet (pane lime)
MENU_BUX="18"              # daftar program -> 18 = BuxFaucet   (pane bux)
API_KEY="8ea7f806170fa5609010c41c31d60b88"
EMAIL_DOMAIN="gmail.com"   # email = <nama folder>@gmail.com

CHECK_INTERVAL=60          # cek folder baru (detik)
MONITOR_INTERVAL=5         # cek stream/layar (detik)
RESTART_INTERVAL=7200      # restart sesi (detik) = 2 jam
STEP_TIMEOUT=60            # maks tunggu tiap prompt (detik)
START_GAP=9               # jeda antar pembuatan pane/sesi (detik)
PANE_RETRY=9              # jeda coba ulang pane yang gagal setup (detik)
NOTIF_CLAIM=1              # 1 = notif tiap claim lime, 0 = matikan
DEFAULT_CURRENCY="USDT"
WD_HOUR=23                 # jam mulai WD (23 = 23:00)
WD_COIN_TIMEOUT=300        # maks tunggu hasil WD tiap koin (detik)
WD_RETRY_DELAY=450         # jeda coba ulang WD otomatis jika gagal (detik)
WD_MAX_TRY=15               # maks percobaan WD otomatis per akun per hari
WD_COINS=8                 # jumlah token di menu WD BUX
WD_MAX_ROUNDS=15            # putaran ulang WD untuk akun/token yang belum 100% (dalam satu gelombang)
WD_ROUND_DELAY=60          # jeda antar putaran ulang (detik)
WD_MAX_MIN=45              # batas total satu gelombang WD (menit) sebelum claim BUX dinyalakan lagi

IP_CHECK_INTERVAL=20       # cek IP publik tiap N detik
IP_CHANGE_RESTART=1        # 1 = IP berubah -> hapus file panel_* lalu restart semua sesi bertahap
IP_PANEL_FILES=(panel_config.json panel_config.sig panel_verified.json)
LIME_IPFAIL_MAX=3          # toleransi "IP changed"; kejadian ke-4 -> hapus file + restart pane lime

MON_BATCH=4                # maks akun diperiksa per putaran (bergilir) -> ringan walau sesi banyak
SCREEN_CHECK_EVERY=15      # cek layar (deteksi error) per akun tiap N detik
BOT_POLL_INTERVAL=6        # cek perintah bot Telegram tiap N detik
HIST_LIMIT=1000            # riwayat scroll tmux per pane (kecil = hemat RAM)

SOURCE_DIR="/data/data/com.termux/files/home/storage/downloads/bot/akun"
SOURCE_MAIN=""             # opsional: path lengkap main.py master

# Keamanan vault: kunci acak dibuat otomatis di ~/.tmux_manager/.keyfile.
# VAULT_PASS opsional = lapisan ekstra (kalau diisi, jangan diubah lagi atau data lama tidak bisa dibuka)
VAULT_PASS=""
# ---------------------------------------------------------------------

declare -A START_TS PANE_L PANE_B IPFLAG IPFAIL LAST_SCR
ACCS=(); ACC_SIG=""; MON_IDX=0
IP_CUR=""; IP_ORG="-"; IP_CITY="-"; IP_SINCE=0; LAST_IPCHK=0; LAST_IPWAVE=0
BOT_LAST=0; WDT=0; WDT_DAY=""; WD_BATCH=0
LANE=""; SUP_PID=0; BOT_PID=0; LAST_IPWAVE_SEEN=0
declare -A LANE_PID
PAT_LIME='Claimed #|All solve attempts failed|Bad challenge|IP changed'
PAT_BUX='Claim Berhasil|Cooldown|Putaran selesai|ROTASI|SUCCESS|Initializing session|Bal:|[Ee]rror|ERROR|Traceback|Exception|[Tt]imed? ?out|[Gg]agal|[Ff]ailed|[Cc]onnection|[Nn]etwork'
NICE_CMD=""; command -v nice >/dev/null 2>&1 && NICE_CMD="nice -n 8 "
STATE_DIR="$HOME/.tmux_manager"
HELP="$STATE_DIR/helpers"
OUTBOX="$STATE_DIR/outbox"
mkdir -p "$STATE_DIR" "$HELP" "$OUTBOX"
chmod 700 "$STATE_DIR" 2>/dev/null
export REVIL_STATE="$STATE_DIR" VAULT_PASS BOT_TOKEN CHAT_ID BASE_DIR DEFAULT_CURRENCY
LOG="$STATE_DIR/manager.log"
PIDFILE="$STATE_DIR/manager.pid"; WDLOCK="$STATE_DIR/wd.lock"; IS_MAIN=0; SELF="${0##*/}"
EVENTS="$STATE_DIR/events.tsv"
touch "$EVENTS" "$LOG"; chmod 600 "$EVENTS" "$LOG" 2>/dev/null
REPORT_DIR="$STATE_DIR/reports"
MASTER_BACKUP="$STATE_DIR/master_main.py"
NET_SECS=0
LAST_START_END=0
CUR_LBL=""
FIXED=false
ROWS=0; COLS=0
MIDNIGHT=0
LAST_LEDGER=0
[ -d "$BASE_DIR" ] || BASE_DIR="$BASE_DIR_FALLBACK"

IS_TTY=false; [ -t 1 ] && IS_TTY=true
SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

# ------------------------------ WARNA --------------------------------
if $IS_TTY; then
  R=$'\033[0m'; B=$'\033[1m'
  fg() { printf '\033[38;5;%sm' "$1"; }
  C_DIM=$(fg 244); C_OK=$(fg 114); C_WARN=$(fg 214); C_ERR=$(fg 203)
  C_GOLD=$(fg 220); C_INFO=$(fg 117); C_PINK=$(fg 213); C_SEP=$(fg 240)
else
  R=""; B=""; C_DIM=""; C_OK=""; C_WARN=""; C_ERR=""; C_GOLD=""; C_INFO=""; C_PINK=""; C_SEP=""
  fg() { :; }
fi

# ------------------------------ UI -----------------------------------
rep() { local o="" i; for ((i = 0; i < $2; i++)); do o+="$1"; done; printf '%s' "$o"; }
center() { local t="$1" w="$2" l r; l=$(((w - ${#t}) / 2)); r=$((w - ${#t} - l)); printf '%*s%s%*s' "$l" '' "$t" "$r" ''; }
fmt_time() { printf '%02d:%02d:%02d' $(($1 / 3600)) $(($1 % 3600 / 60)) $(($1 % 60)); }

set_row() {
  $FIXED || return
  local t="${3:0:$((COLS - 2))}"
  printf '\e7\e[%d;1H\e[2K%s%s%s\e8' "$1" "$2" "$t" "$R"
}
ip_row() { set_row 5 "$C_PINK" " $1"; }
act() { # tiap jalur punya baris sendiri (supervisor tidak menulis aktivitas)
  case "$LANE" in
    lime) set_row 6 "$C_OK" " ◈ [lime] $1" ;;
    bux)  set_row 7 "$C_INFO" " ◈ [bux ] $1" ;;
  esac
}
stat_row() { set_row 8 "$C_GOLD" " ◈ $1"; }

draw_header() {
  local w=44
  local g=(51 45 39 33)
  printf '\033[H'
  printf ' %s╔%s╗%s\033[K\n' "$(fg ${g[0]})" "$(rep '═' $w)" "$R"
  printf ' %s║%s%s%s║%s\033[K\n' "$(fg ${g[1]})" "$B$(fg 159)" "$(center '◆  R E V I L   T M U X   M A N A G E R  ◆' $w)" "$(fg ${g[1]})" "$R"
  printf ' %s║%s%s%s║%s\033[K\n' "$(fg ${g[2]})" "$B$(fg 220)" "$(center 'Created by  R E V I L' $w)" "$(fg ${g[2]})" "$R"
  printf ' %s╚%s╝%s\033[K\n' "$(fg ${g[3]})" "$(rep '═' $w)" "$R"
  printf '\033[2K\n\033[2K\n\033[2K\n\033[2K\n'
  printf ' %s%s%s' "$C_SEP" "$(rep '─' $((COLS - 2)))" "$R"
}

layout() {
  $IS_TTY || return
  ROWS=$(tput lines 2>/dev/null || echo 24); COLS=$(tput cols 2>/dev/null || echo 80)
  if (( ROWS < 18 || COLS < 48 )); then FIXED=false; return; fi
  FIXED=true
  printf '\033[2J'
  draw_header
  printf '\033[10;%dr\033[10;1H' "$ROWS"
}

cleanup() {
  $IS_TTY && printf '\033[r\033[%d;1H\n' "${ROWS:-24}"
  (( WD_BATCH )) && rm -f "$WDLOCK"
  if [ "$IS_MAIN" = 1 ]; then
    kill "${LANE_PID[lime]}" "${LANE_PID[bux]}" "$BOT_PID" 2>/dev/null
    python3 "$HELP/vault.py" rt-stop 2>/dev/null     # catat henti normal
    rm -f "$PIDFILE"
  fi
  return 0
}
trap cleanup EXIT
trap 'exit 0' INT TERM
trap 'layout' WINCH

_log() {
  local col="$1"; shift
  local tag=""; [ -n "$LANE" ] && tag="[${LANE^^}] "
  printf '%s%s%s %s%s%s%s\n' "$C_DIM" "$(date '+%H:%M:%S')" "$R" "$col" "$tag" "$*" "$R"
  echo "[$(date '+%F %T')] ${LANE:+[$LANE] }$*" >> "$LOG"
}
log()      { _log "$C_INFO" "$*"; }
log_ok()   { _log "$C_OK" "$*"; }
log_warn() { _log "$C_WARN" "$*"; }
log_err()  { _log "$C_ERR" "$*"; }
log_gold() { _log "$C_GOLD" "$*"; }

loading_boot() {
  $IS_TTY || return
  local steps=("tmux" "curl" "python3" "folder akun" "koneksi telegram" "helper parser") i k
  for i in "${!steps[@]}"; do
    for k in 0 1 2; do act "${SPIN[(i * 3 + k) % 10]} Memeriksa ${steps[i]}..."; sleep 0.12; done
    printf '%s  ✔ %s%s\n' "$C_OK" "${steps[i]}" "$R"
  done
  local p
  for p in $(seq 1 20); do
    printf '\r  %sMemulai%s [%s%-20s%s] %3d%%' "$C_PINK" "$R" "$(fg 51)" "$(rep '█' $p)" "$R" $((p * 5))
    sleep 0.05
  done
  printf '\n\n'
}

# ------------------------------ UTIL ---------------------------------
tg() {
  curl -s -m 20 "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d "chat_id=${CHAT_ID}" -d "parse_mode=HTML" -d "disable_web_page_preview=true" \
    --data-urlencode "text=$1" >/dev/null 2>&1
}
esc() { printf '%s' "$1" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g'; }
rnd() { local -n a="$1"; printf '%s' "${a[RANDOM % ${#a[@]}]}"; }
LINE="━━━━━━━━━━━━━━━━━━━━"
now_hms() { date '+%H:%M:%S'; }
fsize() { stat -c %s "$1" 2>/dev/null || echo 0; }

FUN_CLAIM=("Cuan mengalir deras 💸" "Receh demi receh jadi bukit ⛰️" "Mesin uang lagi semangat 🔥" "Dompet tersenyum lebar 😎" "Ini baru pemanasan 🚀" "Sultan mode: ON 👑" "Tabungan makin gendut 🐷")
FUN_UP=("Siap tempur, Bos! 🫡" "Mesin sudah panas 🔥" "Gas pol sampai pagi 🏁" "Robot kerja, kamu santai ☕")
FUN_ERR=("Tenang, auto-fix sudah jalan 🔧" "Bot-nya cuma ngambek sebentar 😅" "Dibereskan otomatis, jangan panik 🧯" "Anggap saja istirahat kopi ☕")
FUN_REFRESH=("Segar kembali, siap 2 jam lagi 💪" "Direstart biar tetap kinclong ✨" "Ganti oli dulu, Bos 🛠️")
FUN_WD=("Uang pindah kandang 🏦" "Tarik tunai ala sultan 💳" "Brankas makin berat 🔐")

ev() { printf '%s|%s|%s|%s|%s\n' "$(date +%s)" "$1" "${2:--}" "${3:--}" "${4:--}" >> "$EVENTS"; }

sess_name() { local n="${1//./_}"; printf '%s' "${n//:/_}"; }

list_accounts() {
  [ -d "$BASE_DIR" ] || return
  local d
  for d in "$BASE_DIR"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"; printf '%s\n' "${d##*/}"
  done
}

has_session() { tmux has-session -t "=$1" 2>/dev/null; }
get_panes() { # sesi -> P_L P_B (cache; tanpa spawn kalau sudah ada)
  P_L="${PANE_L[$1]}"; P_B="${PANE_B[$1]}"
  if [ -z "$P_L" ] || [ -z "$P_B" ]; then
    local out; out=$(tmux list-panes -t "=$1" -F '#{pane_id}' 2>/dev/null)
    P_L=$(sed -n 1p <<<"$out"); P_B=$(sed -n 2p <<<"$out")
    PANE_L[$1]="$P_L"; PANE_B[$1]="$P_B"
  fi
}
screen_of() { tmux capture-pane -t "$1" -p -J -S -200 2>/dev/null; }
kstate() { local v=""; [ -f "$STATE_DIR/$1.$2.state" ] && read -r v < "$STATE_DIR/$1.$2.state"; printf '%s' "$v"; }
set_kstate(){ echo "$3" > "$STATE_DIR/$1.$2.state"; }

# tunggu pola (regex) di layar pane, spinner + timer di header
wait_for() {
  local p="$1" pat="$2" t="${3:-$STEP_TIMEOUT}" i k=0 start=$SECONDS lbl
  lbl="${pat%%|*}"
  for ((i = 0; i < t * 2; i++)); do
    if tmux capture-pane -t "$p" -p -J -S -200 2>/dev/null | grep -Eq "$pat"; then
      log_ok "✔ [$CUR_LBL] $lbl ($((SECONDS - start))s)"
      return 0
    fi
    act "${SPIN[k % 10]} [$CUR_LBL] menunggu \"$lbl\"  $((SECONDS - start))s/${t}s"
    k=$((k + 1))
    sleep 0.5
  done
  log_err "✘ [$CUR_LBL] timeout menunggu \"$lbl\" (${t}s)"
  return 1
}

send() {
  tmux send-keys -t "$1" -l "$2"
  sleep 0.4
  tmux send-keys -t "$1" Enter
  sleep 0.8
}

# baca potongan baru dari log pane (tanpa kode ANSI), update offset
read_new() { # logfile offsetfile
  local f="$1" of="$2" off=0 size
  [ -f "$of" ] && read -r off < "$of"
  size=$(fsize "$f")
  (( size < off )) && off=0
  if (( size > off )); then
    tail -c +$((off + 1)) "$f" | head -c 2000000 \
      | sed -E 's/\x1b\[[0-9;?]*[ -\/]*[@-~]//g; s/\x1b\][^\a]*\a//g' | tr '\r' '\n'
  fi
  echo "$size" > "$of"
  if (( size > 8000000 )); then : > "$f"; echo 0 > "$of"; fi
}

dec_pos() { python3 -c 'import sys;from decimal import Decimal as D;sys.exit(0 if D(sys.argv[1])>0 else 1)' "$1" 2>/dev/null; }
dec_cmp() { python3 -c 'import sys;from decimal import Decimal as D;a,b=D(sys.argv[1]),D(sys.argv[2]);print("lt" if a<b else ("eq" if a==b else "gt"))' "$1" "$2" 2>/dev/null; }
dec_sub() { python3 -c 'import sys;from decimal import Decimal as D;print(f"{D(sys.argv[1])-D(sys.argv[2]):f}")' "$1" "$2" 2>/dev/null; }

flush_outbox() {
  local f
  for f in $(ls "$OUTBOX"/*.html 2>/dev/null | sort); do
    tg "$(cat "$f")"; rm -f "$f"; sleep 0.4
  done
}

# ------------------- INTERNET & RESTORE main.py ----------------------
net_ok() { curl -s -m 5 -o /dev/null "https://api.telegram.org" 2>/dev/null; }

wait_internet() {
  net_ok && return 0
  local k=0 start=$SECONDS d
  log_warn "📡 Internet mati, menunggu koneksi..."
  while ! net_ok; do
    act "${SPIN[k % 10]} Menunggu internet... $((SECONDS - start))s"
    k=$((k + 1)); sleep 3
  done
  d=$((SECONDS - start)); NET_SECS=$((NET_SECS + d))
  [ "$LANE" = bux ] || ev net - "$d" -
  log_ok "📡 Internet kembali (mati ${d}s)"
  [ "$LANE" = bux ] || tg "📡 <b>INTERNET KEMBALI</b>
$LINE
⏳ Sempat mati: <b>${d} detik</b>
✅ Melanjutkan sesi...
🕒 $(now_hms)"
}

find_master_main() {
  local c
  for c in "$SOURCE_MAIN" "$SOURCE_DIR/main.py" "$BASE_DIR/main.py" "$MASTER_BACKUP"; do
    [ -n "$c" ] && [ -s "$c" ] && { echo "$c"; return 0; }
  done
  for c in "$BASE_DIR"/*/main.py; do
    [ -s "$c" ] && { echo "$c"; return 0; }
  done
  return 1
}

backup_master() {
  [ -s "$MASTER_BACKUP" ] && return
  [ -s "$BASE_DIR/$1/main.py" ] && cp "$BASE_DIR/$1/main.py" "$MASTER_BACKUP"
}

restore_main() {
  local acc="$1" dir="$BASE_DIR/$1" src
  [ -s "$dir/main.py" ] && return 0
  src=$(find_master_main) || { log_err "❌ [$acc] main.py hilang & master tidak ketemu"; return 1; }
  cp "$src" "$dir/main.py" || return 1
  chmod +x "$dir/main.py" 2>/dev/null
  log_warn "🛠 [$acc] main.py disalin ulang dari $src"
  tg "🛠️ <b>MAIN.PY DISELAMATKAN</b>
$LINE
👤 Akun : <code>$(esc "$acc")</code>
📄 Disalin dari:
<code>$(esc "$src")</code>
🕒 $(now_hms)
🦸 Script hilang? Tenang, ada Revil Manager~"
}

# ------------------------- FLOW PROGRAM ------------------------------
step_fail() { # label, tahap
  tg "⚠️ <b>PANE TERSENDAT</b>
$LINE
👤 Pane  : <code>$(esc "$1")</code>
🧩 Tahap : $(esc "$2")
🔁 Dicoba lagi otomatis dalam ±1 menit
🕒 $(now_hms)
$(rnd FUN_ERR)"
}

flow_license_menu() { # pane -> sampai MENU UTAMA, kirim 2
  local p="$1"
  if wait_for "$p" "License Key|MENU UTAMA" 40; then
    if screen_of "$p" | grep -q "License Key" && ! screen_of "$p" | grep -q "MENU UTAMA"; then
      send "$p" "$LICENSE_KEY"
    fi
  else
    step_fail "$CUR_LBL" "License Key"; return 1
  fi
  wait_for "$p" "MENU UTAMA" || { step_fail "$CUR_LBL" "Menu utama"; return 1; }
  send "$p" "$MENU_APIKEY"
}

flow_lime() { # pane acc
  local p="$1" acc="$2" dir="$BASE_DIR/$2" email="${2}@${EMAIL_DOMAIN}"
  send "$p" "cd '$dir' && ${NICE_CMD}python main.py"
  flow_license_menu "$p" || return 1
  wait_for "$p" "Pitasks|LimeFaucet" || { step_fail "$CUR_LBL" "Daftar program"; return 1; }
  sleep 1
  send "$p" "$MENU_FAUCET"
  wait_for "$p" "Use saved\? \(y/n\)|Email:" || { step_fail "$CUR_LBL" "Prompt email"; return 1; }
  if screen_of "$p" | grep -q "Use saved? (y/n)"; then send "$p" "n"; fi
  wait_for "$p" "Email:" || { step_fail "$CUR_LBL" "Prompt email"; return 1; }
  send "$p" "$email"
  wait_for "$p" "API key:" || { step_fail "$CUR_LBL" "Prompt API key"; return 1; }
  send "$p" "$API_KEY"
  wait_for "$p" "Login OK|Session OK|BOT RUNNING" 90 || { step_fail "$CUR_LBL" "Menunggu lime running"; return 1; }
}

flow_bux_login() { # pane acc -> sampai "Select Menu" (MAIN MENU bux)
  local p="$1" acc="$2" dir="$BASE_DIR/$2" email="${2}@${EMAIL_DOMAIN}"
  send "$p" "cd '$dir' && ${NICE_CMD}python main.py"
  flow_license_menu "$p" || return 1
  wait_for "$p" "Pitasks|BuxFaucet" || { step_fail "$CUR_LBL" "Daftar program"; return 1; }
  sleep 1
  send "$p" "$MENU_BUX"
  wait_for "$p" "API Key +:|Select Menu" 60 || { step_fail "$CUR_LBL" "Prompt API Key/Menu"; return 1; }
  if screen_of "$p" | grep -Eq "API Key +:" && ! screen_of "$p" | grep -q "Select Menu"; then
    send "$p" "$API_KEY"
    wait_for "$p" "Email +:" || { step_fail "$CUR_LBL" "Prompt Email"; return 1; }
    send "$p" "$email"
  fi
  wait_for "$p" "Select Menu" 60 || { step_fail "$CUR_LBL" "Main menu bux"; return 1; }
}

flow_bux_run() { # pane acc
  local p="$1"
  flow_bux_login "$p" "$2" || return 1
  send "$p" "1"
  wait_for "$p" "Select Option|AVAILABLE COINS" 60 || { step_fail "$CUR_LBL" "Pilih opsi koin"; return 1; }
  send "$p" "all"
  wait_for "$p" "ROTASI|Claim|Cooldown" 90 || { step_fail "$CUR_LBL" "Rotasi koin"; return 1; }
}

# jeda START_GAP detik antar pembuatan pane/sesi
gap_wait() {
  (( LAST_START_END == 0 )) && return
  local need=$((LAST_START_END + START_GAP - $(date +%s))) left t0=$SECONDS
  (( need <= 0 )) && return
  for ((left = need; left > 0; left--)); do
    act "⏳ Jeda ${START_GAP}s sebelum langkah berikutnya ($1): ${left}s"
    sleep 1
  done
  ev gap "${1%%/*}" "$((SECONDS - t0))" -
}

# siapkan 1 pane (lime/bux): jeda, flow, catat event, notif
setup_pane() { # acc kind [nogap]
  local acc="$1" kind="$2" s pane t0 n0 rc dur
  s=$(sess_name "$acc")
  get_panes "$s"; pane="$P_B"; [ "$kind" = lime ] && pane="$P_L"
  [ -n "$pane" ] || return 1
  [ "$3" = nogap ] || gap_wait "$acc/$kind"
  wait_internet
  backup_master "$acc"
  if ! restore_main "$acc"; then
    set_kstate "$s" "$kind" fail; date +%s > "$STATE_DIR/$s.$kind.try"
    [ -f "$STATE_DIR/$s.nomain" ] || { touch "$STATE_DIR/$s.nomain"; tg "❌ <b>MAIN.PY TIDAK ADA</b>
$LINE
👤 <code>$(esc "$s")</code>
Taruh main.py master di:
<code>$(esc "$SOURCE_DIR/main.py")</code>"; }
    return 1
  fi
  rm -f "$STATE_DIR/$s.nomain"

  CUR_LBL="$s/$kind"
  t0=$SECONDS; n0=$NET_SECS
  log_gold "▶ Setup pane $CUR_LBL"
  set_kstate "$s" "$kind" setup
  START_TS["$s:$kind"]=$(date +%s)
  if [ "$kind" = lime ]; then flow_lime "$pane" "$acc"; else flow_bux_run "$pane" "$acc"; fi
  rc=$?
  dur=$((SECONDS - t0 - (NET_SECS - n0)))
  ev setup "$acc" "$dur" "$rc:$kind"
  LAST_START_END=$(date +%s)
  date +%s > "$STATE_DIR/$s.$kind.try"
  if (( rc == 0 )); then
    set_kstate "$s" "$kind" ok
    date +%s > "$STATE_DIR/$s.$kind.start"
    log_ok "✅ [$CUR_LBL] RUNNING (setup ${dur}s)"
    tg "🚀 <b>PANE MELUNCUR</b> 🚀
$LINE
👤 Akun  : <code>$(esc "$s")</code>
🧩 Pane  : <b>$kind</b>
⚡ Setup : <b>${dur} detik</b>
🕒 Jam   : $(now_hms)
$(rnd FUN_UP)"
  else
    set_kstate "$s" "$kind" fail
  fi
  act "Siaga"
  return $rc
}

respawn_pane() { # acc kind
  local s dir pane pat
  s=$(sess_name "$1"); dir="$BASE_DIR/$1"
  get_panes "$s"; pane="$P_B"; pat="$PAT_BUX"
  [ "$2" = lime ] && { pane="$P_L"; pat="$PAT_LIME"; }
  [ -n "$pane" ] || return 1
  tmux respawn-pane -k -t "$pane" -c "$dir" 2>/dev/null || tmux respawn-pane -k -t "$pane" 2>/dev/null
  sleep 1
  tmux clear-history -t "$pane" 2>/dev/null
  tmux pipe-pane -o -t "$pane" "grep -a --line-buffered -E '$pat' >> '$STATE_DIR/$s.$2.log'" 2>/dev/null
}

create_session() { # acc
  local acc="$1" s dir p1 p2 k
  s=$(sess_name "$acc"); dir="$BASE_DIR/$acc"
  log_gold "▶ Membuat sesi: $s (pane lime + bux)"
  tmux start-server 2>/dev/null; tmux set-option -g history-limit "$HIST_LIMIT" 2>/dev/null
  p1=$(tmux new-session -d -s "$s" -c "$dir" -P -F '#{pane_id}') || { log_err "Gagal buat sesi $s"; return 1; }
  p2=$(tmux split-window -v -t "$p1" -c "$dir" -P -F '#{pane_id}') || { log_err "Gagal split pane $s"; return 1; }
  PANE_L[$s]="$p1"; PANE_B[$s]="$p2"
  tmux select-pane -t "$p1" -T lime 2>/dev/null
  tmux select-pane -t "$p2" -T bux 2>/dev/null
  tmux set-option -w -t "$p1" pane-border-status top 2>/dev/null
  tmux set-option -w -t "$p1" pane-border-format ' #{pane_title} ' 2>/dev/null
  tmux set-option -w -t "$p1" allow-rename off 2>/dev/null
  for k in lime bux; do
    : > "$STATE_DIR/$s.$k.log"; echo 0 > "$STATE_DIR/$s.$k.off"; rm -f "$STATE_DIR/$s.$k.state" "$STATE_DIR/$s.$k.try"
  done
  rm -f "$STATE_DIR/$s.bux.json" "$STATE_DIR/$s.lime.seen"
  IPFAIL[$s]=0; IPFLAG[$s]=0
  tmux pipe-pane -t "$p1" "grep -a --line-buffered -E '$PAT_LIME' >> '$STATE_DIR/$s.lime.log'"
  tmux pipe-pane -t "$p2" "grep -a --line-buffered -E '$PAT_BUX' >> '$STATE_DIR/$s.bux.log'"
  printf -v START_TS[$s] '%(%s)T' -1
  echo "${START_TS[$s]}" > "$STATE_DIR/$s.start"
}

kill_session() { has_session "$1" && tmux kill-session -t "=$1" && log_warn "✖ Kill sesi $1"; unset 'PANE_L[$1]' 'PANE_B[$1]' 'START_TS[$1]'; return 0; }

# --------------------------- CLAIM LIME ------------------------------
purge_panel_files() { # acc -> cetak jumlah file terhapus
  local f n=0
  for f in "${IP_PANEL_FILES[@]}"; do
    if [ -e "$BASE_DIR/$1/$f" ]; then rm -f "$BASE_DIR/$1/$f" && n=$((n + 1)); fi
  done
  printf '%s' "$n"
}

track_lime() { # acc sesi teks-stream
  local acc="$1" s="$2" txt="$3" line key now n
  local seen="$STATE_DIR/$s.lime.seen" tot="$STATE_DIR/$s.total"
  [ -n "$txt" ] || return
  touch "$seen"
  printf -v now '%(%s)T' -1
  [[ "$txt" == *"IP changed"* ]] && IPFLAG[$s]=$now

  # --- kegagalan solve karena IP berubah: toleransi N kali, ke-(N+1) hapus file + restart pane ---
  while IFS= read -r line; do
    [[ "$line" =~ \[([0-9]{2}:[0-9]{2}:[0-9]{2})\] ]] || continue
    key="F|${BASH_REMATCH[1]}"
    grep -qxF "$key" "$seen" && continue
    echo "$key" >> "$seen"
    (( now - ${IPFLAG[$s]:-0} <= 180 )) || continue
    n=$(( ${IPFAIL[$s]:-0} + 1 )); IPFAIL[$s]=$n
    log_warn "⚠ [$s/lime] 'IP changed' ke-$n (toleransi $LIME_IPFAIL_MAX)"
    if (( n > LIME_IPFAIL_MAX )); then
      IPFAIL[$s]=0
      n=$(purge_panel_files "$acc")
      ev ipfix "$acc" "$n" lime
      restart_pane "$acc" lime ipchanged "🔐 <b>IP BERUBAH — LOGIN ULANG</b> 🔐
$LINE
👤 Akun  : <code>$(esc "$s")</code> (lime)
⚠️ Muncul ${LIME_IPFAIL_MAX}x lalu masih gagal: <i>IP changed, please login again</i>
🗑 File panel dihapus: <b>$n</b> (panel_config.json, panel_config.sig, panel_verified.json)
🔄 Pane lime dibuka ulang &amp; login baru
🕒 $(now_hms)"
      return
    fi
  done < <(grep -a 'All solve attempts failed' <<<"$txt")

  # --- claim berhasil ---
  grep -Eo 'Claimed #[0-9]+ \+[0-9]+(\.[0-9]+)? ?[A-Za-z]*' <<<"$txt" | while read -r _ id amt cur; do
    id="${id#\#}"; amt="${amt#+}"
    [[ "$cur" =~ ^[A-Z]{3,6}$ ]] || cur="$DEFAULT_CURRENCY"
    key="$id|$amt"
    grep -qxF "$key" "$seen" && continue
    echo "$key" >> "$seen"
    tail -n 300 "$seen" > "$seen.tmp" && mv "$seen.tmp" "$seen"

    res=$(python3 - "$tot" "$amt" <<'PY'
import sys
from decimal import Decimal
p, a = sys.argv[1], Decimal(sys.argv[2])
try:
    t, c = open(p).read().split(); t = Decimal(t); c = int(c)
except Exception:
    t, c = Decimal(0), 0
t += a; c += 1
open(p, "w").write(f"{t:f} {c}")
print(f"{t:f} {c}")
PY
)
    total="${res% *}"; count="${res#* }"
    ev claim "$s" "$amt" "$id"
    log_gold "💰 [$s/lime] Claimed #$id +$amt $cur | total +$total ($count klaim)"
    if [ "$NOTIF_CLAIM" = "1" ]; then
      tg "🍋 <b>CLAIM LIME</b> 🍋
$LINE
👤 Akun  : <code>$(esc "$s")</code>
🎫 Claim : <b>#$id</b>
💰 Dapat : <b>+$amt $cur</b>
$LINE
📊 Total : <b>+$total $cur</b>
🧮 Klaim : <b>$count</b>x
🕒 $(now_hms)
$(rnd FUN_CLAIM)"
      sleep 0.5
    fi
  done
  # claim sukses -> reset hitungan kegagalan IP (subshell di atas tak bisa; cek ulang di sini)
  [[ "$txt" == *"Claimed #"* ]] && IPFAIL[$s]=0
}

get_total() {
  local f="$STATE_DIR/$1.total" t c
  if [ -f "$f" ]; then read -r t c < "$f"; echo "+$t ($c klaim)"; else echo "+0 (0 klaim)"; fi
}

# ----------------------------- MONITOR -------------------------------
restart_pane() { # acc kind reason msg
  local acc="$1" kind="$2" reason="$3" msg="$4" s t0=$SECONDS
  s=$(sess_name "$acc")
  log_warn "🔄 [$s/$kind] tutup pane lalu buka ulang di pane yang sama • penyebab: $reason"
  ev restart "$acc" "$reason" "$kind"
  [ -n "$msg" ] && tg "$msg"
  respawn_pane "$acc" "$kind"
  setup_pane "$acc" "$kind"
  ev recover "$acc" "$((SECONDS - t0))" "$kind:$reason"
}

restart_session() { # acc reason msg
  local acc="$1" reason="$2" msg="$3" s t0=$SECONDS
  s=$(sess_name "$acc")
  log_warn "🔄 [$s] restart sesi karena: $reason"
  ev restart "$acc" "$reason" session
  [ -n "$msg" ] && tg "$msg"
  kill_session "$s"
  sleep 2
  create_session "$acc" || return 1
  setup_pane "$acc" lime
  setup_pane "$acc" bux
  ev recover "$acc" "$((SECONDS - t0))" "session:$reason"
}

pane_cmd() { tmux list-panes -t "$1" -F '#{pane_current_command}' 2>/dev/null | head -1; }

wd_done_today() { [ "$(cat "$STATE_DIR/$1.wd_day" 2>/dev/null)" = "$(date +%F)" ]; }

build_msg() { # kind alasan sesi total
  local kind="$1" reason="$2" s="$3" tot="$4"
  case "$reason" in
    maxfail) printf '%s' "🚨 <b>WADUH! MAX FAILURES</b> 🚨
$LINE
👤 Akun  : <code>$(esc "$s")</code> ($kind)
🧯 Pane di-reset &amp; dijalankan ulang
📊 Total : <b>$(esc "$tot")</b>
🕒 $(now_hms)
$(rnd FUN_ERR)" ;;
    cache) printf '%s' "🧹 <b>CACHE SCRIPT DIBERSIHKAN</b> 🧹
$LINE
📁 Konfigurasi tersimpan di folder ini
⏎ Press Enter to continue...
$LINE
👤 Akun  : <code>$(esc "$s")</code> ($kind)
🔄 Pane ditutup &amp; dibuka ulang di pane yang sama
🕒 $(now_hms)" ;;
    nomain) printf '%s' "🛠️ <b>MAIN.PY TERHAPUS</b>
$LINE
👤 Akun  : <code>$(esc "$s")</code> ($kind)
🔄 Disalin ulang dari master &amp; dijalankan ulang
🕒 $(now_hms)" ;;
    mati) printf '%s' "💀 <b>SCRIPT BERHENTI</b>
$LINE
👤 Akun  : <code>$(esc "$s")</code> ($kind)
🔄 Kembali ke shell, dijalankan ulang
🕒 $(now_hms)
$(rnd FUN_ERR)" ;;
  esac
}

monitor_lime() { # acc now
  local acc="$1" now="$2" s lp screen cmd reason st txt
  s=$(sess_name "$acc"); has_session "$s" || return
  get_panes "$s"; lp="$P_L"; [ -n "$lp" ] || return
  txt=$(read_new "$STATE_DIR/$s.lime.log" "$STATE_DIR/$s.lime.off")
  [ -n "$txt" ] && track_lime "$acc" "$s" "$txt"
  [ "$(kstate "$s" lime)" = ok ] || return
  [ -n "${START_TS["$s:lime"]}" ] || START_TS["$s:lime"]=$now
  st=${START_TS["$s:lime"]}
  if (( now - ${LAST_SCR[$s]:-0} >= SCREEN_CHECK_EVERY )); then
    LAST_SCR[$s]=$now
    screen=$(screen_of "$lp"); reason=""
    if [[ "$screen" == *"Max failures reached"* ]]; then reason="maxfail"
    elif [[ "$screen" == *"Cache script dibersihkan"* ]]; then reason="cache"
    elif grep -q "can't open file.*main.py" <<<"$screen"; then reason="nomain"
    elif (( now - st > 120 )); then
      cmd=$(tmux list-panes -t "$lp" -F '#{pane_current_command}' 2>/dev/null | head -1)
      [[ "$cmd" =~ ^(bash|sh|zsh|fish|dash)$ ]] && reason="mati"
    fi
    if [ -n "$reason" ]; then
      restart_pane "$acc" lime "$reason" "$(build_msg lime "$reason" "$s" "$(get_total "$s")")"; return
    fi
  fi
  if (( now - st >= RESTART_INTERVAL )); then
    restart_pane "$acc" lime 2jam "⏱️ <b>WAKTUNYA REFRESH</b> ⏱️
$LINE
👤 Akun  : <code>$(esc "$s")</code> (lime)
🔄 Sudah 2 jam, pane lime dibuka ulang
📊 Total lime : <b>$(esc "$(get_total "$s")")</b>
🕒 $(now_hms)
$(rnd FUN_REFRESH)"
  fi
}

monitor_bux() { # acc now
  local acc="$1" now="$2" s bp screen cmd reason st size off blog
  s=$(sess_name "$acc"); has_session "$s" || return
  get_panes "$s"; bp="$P_B"; [ -n "$bp" ] || return
  blog="$STATE_DIR/$s.bux.log"; size=$(fsize "$blog"); off=0
  [ -f "$STATE_DIR/$s.bux.off" ] && read -r off < "$STATE_DIR/$s.bux.off"
  if (( size != off )); then
    python3 "$HELP/bux_tick.py" "$acc" "$blog" "$STATE_DIR/$s.bux.off" "$STATE_DIR/$s.bux.json" "$EVENTS" "$OUTBOX" 2>>"$LOG"
    flush_outbox
    if (( size > 2000000 )) && ! wd_active; then : > "$blog"; echo 0 > "$STATE_DIR/$s.bux.off"; fi
  fi
  [ "$(kstate "$s" bux)" = ok ] || return
  [ -n "${START_TS["$s:bux"]}" ] || START_TS["$s:bux"]=$now
  st=${START_TS["$s:bux"]}
  if (( now - ${LAST_SCR[$s]:-0} >= SCREEN_CHECK_EVERY )); then
    LAST_SCR[$s]=$now
    screen=$(screen_of "$bp"); reason=""
    if [[ "$screen" == *"Cache script dibersihkan"* ]]; then reason="cache"
    elif grep -q "can't open file.*main.py" <<<"$screen"; then reason="nomain"
    elif (( now - st > 120 )); then
      cmd=$(tmux list-panes -t "$bp" -F '#{pane_current_command}' 2>/dev/null | head -1)
      [[ "$cmd" =~ ^(bash|sh|zsh|fish|dash)$ ]] && reason="mati"
    fi
    if [ -n "$reason" ]; then
      restart_pane "$acc" bux "$reason" "$(build_msg bux "$reason" "$s" "")"; return
    fi
  fi
  if (( now - st >= RESTART_INTERVAL )); then
    if (( 10#$(date +%H) >= WD_HOUR )) && ! wd_done_today "$s"; then :; else
      restart_pane "$acc" bux 2jam "⏱️ <b>WAKTUNYA REFRESH</b> ⏱️
$LINE
👤 Akun  : <code>$(esc "$s")</code> (bux)
🔄 Sudah 2 jam, pane bux dibuka ulang
🕒 $(now_hms)
$(rnd FUN_REFRESH)"
    fi
  fi
}

lane_monitor() { # kind : bergilir, maksimal MON_BATCH akun per putaran
  local kind="$1" n=${#ACCS[@]} i idx cnt=0 now
  (( n == 0 )) && return
  printf -v now '%(%s)T' -1
  for ((i = 0; i < n && cnt < MON_BATCH; i++)); do
    idx=$(( (MON_IDX + i) % n )); cnt=$((cnt + 1))
    "monitor_$kind" "${ACCS[idx]}" "$now"
  done
  MON_IDX=$(( (MON_IDX + cnt) % n ))
}

sync_sessions() { # supervisor: buat sesi + 2 pane (setup program dikerjakan jalur lime & bux)
  local acc s
  for acc in "${ACCS[@]}"; do
    s=$(sess_name "$acc")
    if has_session "$s" && [ "$(tmux list-panes -t "=$s" 2>/dev/null | wc -l)" != 2 ]; then
      log_warn "Sesi $s bukan 2 pane, dibuat ulang"; kill_session "$s"
    fi
    if ! has_session "$s"; then
      log_gold "📂 Membuat sesi untuk folder: $acc"
      create_session "$acc"
    fi
  done
}

lane_sync() { # kind : pane baru disiapkan dulu, pane gagal dicoba ulang maks 1 per siklus
  local kind="$1" acc s st t now oacc="" ot=99999999999
  printf -v now '%(%s)T' -1
  for acc in "${ACCS[@]}"; do
    s=$(sess_name "$acc"); has_session "$s" || continue
    st=$(kstate "$s" "$kind")
    if [ -z "$st" ]; then unset "PANE_L[$s]" "PANE_B[$s]"; setup_pane "$acc" "$kind"; fi
  done
  for acc in "${ACCS[@]}"; do
    s=$(sess_name "$acc"); has_session "$s" || continue
    case "$(kstate "$s" "$kind")" in fail|setup) ;; wd) wd_active && continue ;; *) continue ;; esac
    t=0; [ -f "$STATE_DIR/$s.$kind.try" ] && read -r t < "$STATE_DIR/$s.$kind.try"
    if (( now - t >= PANE_RETRY && t < ot )); then oacc="$acc"; ot=$t; fi
  done
  if [ -n "$oacc" ]; then respawn_pane "$oacc" "$kind"; setup_pane "$oacc" "$kind"; fi
}

# ------------------------------ WD -----------------------------------
mgr_alive() { # ada manager LAIN yang sedang berjalan?
  local p=""
  [ -f "$PIDFILE" ] && read -r p < "$PIDFILE"
  [ -n "$p" ] && [ "$p" != "$$" ] && kill -0 "$p" 2>/dev/null || return 1
  if [ -r "/proc/$p/cmdline" ]; then grep -aq "$SELF" "/proc/$p/cmdline" 2>/dev/null; else return 0; fi
}
wd_tok_file() { printf '%s' "$STATE_DIR/${1//[.:]/_}.wdtok"; }
wd_tok_has() { local f today; f=$(wd_tok_file "$1"); printf -v today '%(%F)T' -1; [ -f "$f" ] && grep -q "^$today $2 " "$f"; }
wd_tok_mark() { # acc koin status(done|skip) : tandai token sudah di-WD hari ini
  local f today; f=$(wd_tok_file "$1"); printf -v today '%(%F)T' -1
  wd_tok_has "$1" "$2" && return 0
  { [ -f "$f" ] && grep "^$today " "$f"; echo "$today $2 $3"; } > "$f.tmp"; mv "$f.tmp" "$f"
}
wd_tok_count() { local f today n=0; f=$(wd_tok_file "$1"); printf -v today '%(%F)T' -1; [ -f "$f" ] && n=$(grep -c "^$today " "$f"); printf '%s' "${n:-0}"; }
wd_tok_list() { local f today; f=$(wd_tok_file "$1"); printf -v today '%(%F)T' -1; [ -f "$f" ] && grep "^$today " "$f" | sed 's/^[^ ]* \([^ ]*\) \(.*\)$/\1:\2/' | tr '\n' ' '; }
wd_active() { # ada proses (manapun) yang sedang menjalankan gelombang WD?
  local p="" ts=""
  [ -f "$WDLOCK" ] && read -r p ts < "$WDLOCK"
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}

wd_poll() { # log off coin timeout -> 0 selesai | 1 timeout | 2 error jaringan (variabel hasil lewat eval)
  local t=$(($4 * 2)) k out errk=0
  for ((k = 0; k < t; k++)); do
    out=$(python3 "$HELP/wd_wait.py" "$1" "$2" "$3")
    if grep -q '^DONE=1' <<<"$out"; then eval "$out"; return 0; fi
    if grep -q '^ERR=1' <<<"$out"; then
      errk=$((errk + 1)); eval "$(grep '^MSG=' <<<"$out")"
      (( errk >= 16 )) && return 2
    fi
    act "⏳ [$CUR_LBL] menunggu hasil WD ${3:-menu} ($((k / 2))s)"
    sleep 0.5
  done
  return 1
}

wd_neterr() { # acc koin pesan
  local s; s=$(sess_name "$1")
  ev wdfail "$1" "$2" error
  log_err "✘ [wd] ERROR $2: $3"
  tg "🚨 <b>WD ERROR</b> 🚨
$LINE
👤 Akun  : <code>$(esc "$s")</code>
🪙 Koin  : <b>$(esc "$2")</b>
❗ Pesan : <code>$(esc "$3")</code>
$LINE
📶 <b>Ping/koneksi internet tidak stabil.</b>
👉 Coba <b>GANTI JARINGAN</b> (data seluler ↔ wifi).
🔄 Pane bux di-kill; program BUX dijalankan ulang setelah gelombang WD selesai.
♻️ Akun ini diulang di putaran WD berikutnya (token yang sudah ditandai tidak diulang).
🕒 $(now_hms)"
  respawn_pane "$1" bux
}

wd_account() { # acc
  local acc="$1" s dir pane lg t0=$SECONDS off i v coin before after amt n_ok=0 prc
  local ok_l="" skip_l="" fail_l="" rest_l="" sig pre_l="" incomplete=0
  s=$(sess_name "$acc"); dir="$BASE_DIR/$acc"; lg="$STATE_DIR/$s.bux.log"
  if (( $(wd_tok_count "$acc") >= WD_COINS )); then log "🏦 [$s] semua token sudah ditandai WD hari ini, dilewati"; return 0; fi
  gap_wait "$acc/wd"
  wait_internet
  get_panes "$s"; pane="$P_B"; [ -n "$pane" ] || return 1
  CUR_LBL="$s/wd"
  log_gold "🏦 WD mulai: $s"
  tg "🏦 <b>WD DIMULAI</b> 🏦
$LINE
👤 Akun : <code>$(esc "$s")</code>
🧩 Giliran WD akun ini (claim BUX semua sesi sedang dihentikan)
🕒 $(now_hms)"
  set_kstate "$s" bux wd
  respawn_pane "$acc" bux
  if ! flow_bux_login "$pane" "$acc"; then
    ev wdfail "$acc" login -
    tg "❌ <b>WD GAGAL</b>
👤 <code>$(esc "$s")</code>
🧩 Tidak bisa masuk menu BUX. Claim BUX dinyalakan lagi setelah gelombang WD selesai."
    respawn_pane "$acc" bux
    return 1
  fi

  off=$(fsize "$lg"); send "$pane" "2"
  wd_poll "$lg" "$off" "" 90; prc=$?
  if (( prc != 0 )); then wd_neterr "$acc" "-" "${MSG:-menu withdraw tidak muncul}"; return 1; fi

  for ((i = 1; i <= ${N:-8}; i++)); do
    v="C$i"; coin="${!v}"; v="B$i"; before="${!v}"
    dec_pos "$before" || continue
    if wd_tok_has "$acc" "$coin"; then pre_l+="$coin "; log "↷ [wd] $coin sudah ditandai WD hari ini, dilewati"; continue; fi
    log "[wd] $coin saldo $before -> proses"
    off=$(fsize "$lg"); send "$pane" "$i"
    wd_poll "$lg" "$off" "$coin" "$WD_COIN_TIMEOUT"; prc=$?
    if (( prc != 0 )); then wd_neterr "$acc" "$coin" "${MSG:-tidak ada respons (timeout)}"; return 1; fi
    after="$AFTER"
    sig=$(dec_cmp "$after" "$before")
    if [ "$sig" = lt ]; then
      amt=$(dec_sub "$before" "$after")
      python3 "$HELP/vault.py" ledger-add "$acc" "$coin" "$amt" 2>>"$LOG"
      ev wd "$acc" "$coin" "$amt"
      wd_tok_mark "$acc" "$coin" done
      ok_l+="• <b>$coin</b> <code>$amt</code>"$'\n'; n_ok=$((n_ok + 1))
      log_ok "✔ [wd] $coin $amt diproses (DONE 24 jam)"
    elif [ "$SUCCESS" = 1 ]; then
      ev wdskip "$acc" "$coin" "$before"
      wd_tok_mark "$acc" "$coin" skip
      skip_l+="$coin "
      log_warn "↷ [wd] $coin balance tetap (sudah wd hari ini), lanjut"
    elif [ "$ERR" = 1 ]; then
      wd_neterr "$acc" "$coin" "${MSG:-error}"; return 1
    else
      ev wdfail "$acc" "$coin" "${MSG:-unknown}"
      fail_l+="• $coin: $(esc "${MSG:-tidak ada respons}")"$'\n'
      log_err "✘ [wd] $coin gagal: ${MSG:-?}"; incomplete=1
    fi
  done

  for ((i = 1; i <= ${N:-8}; i++)); do
    v="C$i"; coin="${!v}"; v="B$i"; before="${!v}"
    dec_pos "$before" && rest_l+="$coin $before • "
  done
  rest_l="${rest_l% • }"; skip_l="${skip_l% }"
  ev wdrun "$acc" "$((SECONDS - t0))" "$n_ok"
  tg "🏦 <b>WD SELESAI</b> 🏦
$LINE
👤 Akun : <code>$(esc "$s")</code>
⏱ Lama : <b>$((SECONDS - t0)) detik</b>
$( [ -n "$ok_l" ] && printf '✅ <b>Diproses (DONE dalam 24 jam):</b>\n%s' "$ok_l" || echo '✅ Tidak ada WD baru')
$( [ -n "$skip_l" ] && echo "↷ Sudah WD hari ini (dilewati): $(esc "$skip_l")" )
$( [ -n "$fail_l" ] && printf '⚠️ <b>Gagal:</b>\n%s' "$fail_l" )
$( [ -n "$rest_l" ] && echo "📌 Sisa balance: $(esc "$rest_l")" || echo '📌 Semua balance sudah 0')
🏷 Ditandai WD hari ini: $(esc "$(wd_tok_list "$acc")") ($(wd_tok_count "$acc")/$WD_COINS)
$( [ -n "$pre_l" ] && echo "↷ Dilewati (sudah ditandai): $(esc "$pre_l")" )
$( (( incomplete )) && echo '⚠️ Akun BELUM 100% — token yang gagal diulang di putaran berikutnya' || echo '✅ Akun 100% WD' )
🕒 $(now_hms)
$(rnd FUN_WD)"
  log_gold "🏦 WD selesai: $s (${n_ok} koin diproses)"

  # tutup program WD; pane dibiarkan idle (claim BUX baru jalan setelah SEMUA akun selesai WD)
  respawn_pane "$acc" bux
  return $incomplete
}

wd_batch() { # akun-target... : matikan claim BUX SEMUA sesi -> WD (putaran ulang sampai 100%) -> claim BUX nyala lagi
  local targets=("$@") need=() pending=() next=() acc s n=0 ok=0 round=1 list="" t0=$SECONDS bad_l=""
  if wd_active; then tg "⏳ WD sedang berjalan, permintaan baru diabaikan."; return 1; fi
  # akun yang semua tokennya sudah ditandai hari ini tidak perlu diproses lagi
  for acc in "${targets[@]}"; do
    s=$(sess_name "$acc"); has_session "$s" || continue
    if (( $(wd_tok_count "$acc") >= WD_COINS )); then date +%F > "$STATE_DIR/$s.wd_day"; continue; fi
    need+=("$acc")
  done
  if (( ${#need[@]} == 0 )); then tg "✅ <b>Semua akun sudah 100% WD hari ini</b> (semua token sudah ditandai). Tidak ada yang diproses."; return 0; fi
  for acc in "${ACCS[@]}"; do s=$(sess_name "$acc"); has_session "$s" && n=$((n + 1)); done
  for acc in "${need[@]}"; do list+=" • <code>$(esc "$acc")</code>"$'\n'; done
  WD_BATCH=1; echo "$BASHPID $(date +%s)" > "$WDLOCK"
  log_gold "🏦 GELOMBANG WD: matikan claim BUX di $n sesi (lime tetap jalan)"
  tg "⛔ <b>WD DIMULAI</b> ⛔
$LINE
🪙 Claim BUX di <b>$n</b> sesi dihentikan dulu agar tidak bertabrakan
🍋 Program lime TETAP berjalan
🏦 Akun yang di-WD (${#need[@]}):
$list🕒 $(now_hms)"
  # Fase A: kill claim bux di semua sesi
  for acc in "${ACCS[@]}"; do
    s=$(sess_name "$acc"); has_session "$s" || continue
    set_kstate "$s" bux wd
    respawn_pane "$acc" bux
  done
  # Fase B: WD per akun; yang belum 100% diulang (hanya token yang belum ditandai)
  pending=("${need[@]}")
  while (( round <= WD_MAX_ROUNDS && ${#pending[@]} > 0 )); do
    next=()
    for acc in "${pending[@]}"; do
      s=$(sess_name "$acc"); has_session "$s" || continue
      if wd_account "$acc"; then
        # tanda "akun selesai WD hari ini" hanya dari jendela WD (>= jam WD); WD manual lebih pagi tidak menghapus jadwal 23:00
        (( 10#$(date +%H) >= WD_HOUR )) && date +%F > "$STATE_DIR/$s.wd_day"
        ok=$((ok + 1))
      else next+=("$acc"); fi
    done
    pending=("${next[@]}")
    (( ${#pending[@]} == 0 )) && break
    (( SECONDS - t0 > WD_MAX_MIN * 60 )) && break
    list=""; for acc in "${pending[@]}"; do list+=" • <code>$(esc "$acc")</code> ($(wd_tok_count "$acc")/$WD_COINS)"$'\n'; done
    tg "🔁 <b>PUTARAN WD $round SELESAI</b>
$LINE
⚠️ Belum 100% (${#pending[@]} akun):
$list⏳ Putaran berikutnya ${WD_ROUND_DELAY} detik lagi. Claim BUX tetap ditahan sampai semua akun 100% WD (maks ${WD_MAX_MIN} menit).
🕒 $(now_hms)"
    sleep "$WD_ROUND_DELAY"; round=$((round + 1))
  done
  for acc in "${pending[@]}"; do bad_l+=" • <code>$(esc "$acc")</code>"$'\n'; done
  # Fase C: semua selesai -> claim BUX kembali jalan (bertahap, jeda ${START_GAP}s)
  log_gold "🏦 WD selesai ($ok akun 100%, ${#pending[@]} belum) -> claim BUX dinyalakan kembali"
  for acc in "${ACCS[@]}"; do
    s=$(sess_name "$acc"); has_session "$s" || continue
    setup_pane "$acc" bux
  done
  WD_BATCH=0; rm -f "$WDLOCK"
  tg "✅ <b>GELOMBANG WD SELESAI</b> ✅
$LINE
🏦 Akun 100% WD : <b>$ok</b> • Belum : <b>${#pending[@]}</b> • Putaran : <b>$round</b>
$( [ -n "$bad_l" ] && printf '⚠️ Belum 100%% (akan dicoba lagi otomatis):\n%s' "$bad_l" )⏱ Total : <b>$((SECONDS - t0)) detik</b>
🔄 Claim BUX dijalankan kembali di semua sesi
🕒 $(now_hms)
$(rnd FUN_WD)"
  (( ${#pending[@]} == 0 ))
}

wd_run_one() { # acc (dipakai bot Telegram)
  local acc="$1" s; s=$(sess_name "$acc")
  if ! has_session "$s"; then tg "❌ Sesi <code>$(esc "$s")</code> belum ada, WD dibatalkan."; return 1; fi
  wd_batch "$acc"
}

check_wd_schedule() { # [force]
  local today acc s d n ts now targets=()
  [ "$1" = force ] || (( 10#$(date +%H) >= WD_HOUR )) || return 0
  today=$(date +%F); printf -v now '%(%s)T' -1
  for acc in "${ACCS[@]}"; do
    s=$(sess_name "$acc")
    has_session "$s" || continue
    if [ "$1" != force ]; then
      wd_done_today "$s" && continue
      d=""; n=0; ts=0
      [ -f "$STATE_DIR/$s.wd_try" ] && read -r d n ts < "$STATE_DIR/$s.wd_try"
      [ "$d" = "$today" ] || { n=0; ts=0; }
      (( n >= WD_MAX_TRY )) && continue
      (( now - ts < WD_RETRY_DELAY )) && continue
      echo "$today $((n + 1)) $now" > "$STATE_DIR/$s.wd_try"
    fi
    targets+=("$acc")
  done
  (( ${#targets[@]} )) || return 0
  wd_batch "${targets[@]}"
  [ "$1" = force ] && return 0
  for acc in "${targets[@]}"; do
    s=$(sess_name "$acc")
    wd_done_today "$s" && continue
    d=""; n=0; read -r d n ts 2>/dev/null < "$STATE_DIR/$s.wd_try"
    if [ "$d" = "$today" ] && (( n >= WD_MAX_TRY )); then
      tg "🛑 <b>WD GAGAL ${WD_MAX_TRY}x</b> untuk <code>$(esc "$s")</code>. Cek jaringan lalu tekan 🏦 WD sekarang di bot (/wd)."
    fi
  done
}

# --------------------------- LAPORAN HARIAN --------------------------
install_helpers() {
cat > "$HELP/vault.py" <<'PYEOF'
# Vault terenkripsi (stdlib saja): zlib + PBKDF2-HMAC-SHA256 + keystream HMAC-CTR + tag HMAC (encrypt-then-MAC)
# Data hanya bisa dibuka lewat skrip ini + keyfile yang tersimpan di folder privat Termux.
import os, sys, json, time, hmac, hashlib, zlib, secrets, fcntl, contextlib

STATE = os.environ.get('REVIL_STATE') or os.path.expanduser('~/.tmux_manager')
VDIR = os.path.join(STATE, '.vault')
KEYF = os.path.join(STATE, '.keyfile')
PASS = os.environ.get('VAULT_PASS', '').encode()
MAGIC = b'RVL1'
ITER = 100000

def _km():
    os.makedirs(STATE, mode=0o700, exist_ok=True)
    try:
        k = open(KEYF, 'rb').read()
    except FileNotFoundError:
        if os.path.isdir(VDIR) and os.listdir(VDIR):
            raise SystemExit('keyfile hilang: vault lama tidak bisa dibuka')
        k = secrets.token_bytes(32)
        fd = os.open(KEYF, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.write(fd, k); os.close(fd)
    return hashlib.sha256(k + b'|' + PASS).digest()

def _derive(km, salt):
    d = hashlib.pbkdf2_hmac('sha256', km, salt, ITER, 64)
    return d[:32], d[32:]

def _stream(key, nonce, n):
    out = bytearray(); c = 0
    while len(out) < n:
        out += hmac.new(key, nonce + c.to_bytes(8, 'big'), 'sha256').digest(); c += 1
    return bytes(out[:n])

def encrypt(obj):
    km = _km()
    salt, nonce = secrets.token_bytes(16), secrets.token_bytes(16)
    ek, mk = _derive(km, salt)
    pt = zlib.compress(json.dumps(obj, ensure_ascii=False, separators=(',', ':')).encode('utf-8'), 9)
    ct = bytes(a ^ b for a, b in zip(pt, _stream(ek, nonce, len(pt))))
    tag = hmac.new(mk, MAGIC + salt + nonce + ct, 'sha256').digest()
    return MAGIC + salt + nonce + tag + ct

def decrypt(blob):
    km = _km()
    if blob[:4] != MAGIC: raise ValueError('format tidak dikenal')
    salt, nonce, tag, ct = blob[4:20], blob[20:36], blob[36:68], blob[68:]
    ek, mk = _derive(km, salt)
    if not hmac.compare_digest(tag, hmac.new(mk, MAGIC + salt + nonce + ct, 'sha256').digest()):
        raise ValueError('kunci salah atau data rusak/diubah')
    pt = bytes(a ^ b for a, b in zip(ct, _stream(ek, nonce, len(ct))))
    return json.loads(zlib.decompress(pt).decode('utf-8'))

def _path(name):
    km = _km()
    return os.path.join(VDIR, '.' + hmac.new(km, b'name:' + name.encode(), 'sha256').hexdigest()[:28])

_held = 0
@contextlib.contextmanager
def lock():
    # kunci antar-proses (jalur lime, jalur bux, bot, manager); re-entrant di proses yang sama
    global _held
    if _held:
        _held += 1
        try: yield
        finally: _held -= 1
        return
    os.makedirs(STATE, mode=0o700, exist_ok=True)
    f = open(os.path.join(STATE, '.vault.lock'), 'a')
    fcntl.flock(f, fcntl.LOCK_EX); _held = 1
    try: yield
    finally:
        _held = 0; fcntl.flock(f, fcntl.LOCK_UN); f.close()

def exists(name): return os.path.exists(_path(name))

def save(name, obj):
    os.makedirs(VDIR, mode=0o700, exist_ok=True)
    p = _path(name); tmp = p + '.tmp'
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'wb') as f: f.write(encrypt(obj))
    os.replace(tmp, p)
    if name != 'index':
        with lock():
            idx = load('index', {}); idx[name] = int(time.time()); save('index', idx)

def load(name, default=None):
    p = _path(name)
    if not os.path.exists(p): return default
    return decrypt(open(p, 'rb').read())

def ledger_add(acc, coin, amt):
    with lock():
        led = load('ledger', [])
        led.append([int(time.time()), acc, coin, amt, 'pending'])
        save('ledger', led)

def archive_events(day, evp):
    """Pindahkan event <= day ke vault. File digeser dulu (rename) supaya event baru dari proses lain tidak hilang."""
    from datetime import datetime
    arch = evp + '.arch'
    try:
        if os.path.exists(arch): lines = open(arch, encoding='utf-8').read().splitlines()
        else: lines = []
        if os.path.exists(evp):
            os.replace(evp, arch + '.new'); lines += open(arch + '.new', encoding='utf-8').read().splitlines(); os.remove(arch + '.new')
    except Exception: return 0
    mine, rest = {}, []
    for ln in lines:
        try: d = datetime.fromtimestamp(int(ln.split('|')[0])).strftime('%Y-%m-%d')
        except Exception: rest.append(ln); continue
        if d <= day: mine.setdefault(d, []).append(ln)
        else: rest.append(ln)
    n = 0
    for d, ls in mine.items():
        save('events-' + d, load('events-' + d, []) + ls); n += len(ls)
    with open(evp, 'a', encoding='utf-8') as f:
        if rest: f.write("\n".join(rest) + "\n")
    try: os.remove(arch)
    except Exception: pass
    return n

def delete(name):
    with lock():
        try: os.remove(_path(name))
        except FileNotFoundError: pass
        idx = load('index', {}); idx.pop(name, None); save('index', idx)

def _agg(lines):
    from decimal import Decimal
    g = {"lime_n": 0, "lime": Decimal(0), "bux_n": 0, "bux": {}, "done": {}, "wd": {}, "restarts": 0, "fails": 0, "cool": 0}
    def add(m, k, a): m[k] = m.get(k, Decimal(0)) + Decimal(a)
    for ln in lines:
        p = ln.split("|")
        if len(p) < 5: continue
        try:
            if p[1] == "claim": g["lime_n"] += 1; g["lime"] += Decimal(p[3])
            elif p[1] == "buxclaim": g["bux_n"] += 1; add(g["bux"], p[3], p[4])
            elif p[1] == "wddone": add(g["done"], p[3], p[4])
            elif p[1] == "wd": add(g["wd"], p[3], p[4])
            elif p[1] == "restart": g["restarts"] += 1
            elif p[1] == "setup" and not p[4].startswith("0"): g["fails"] += 1
            elif p[1] == "cooldown": g["cool"] += 1
        except Exception: pass
    return {"lime_n": g["lime_n"], "lime": str(g["lime"]), "bux_n": g["bux_n"], "bux": {k: str(x) for k, x in g["bux"].items()},
            "done": {k: str(x) for k, x in g["done"].items()}, "wd": {k: str(x) for k, x in g["wd"].items()},
            "restarts": g["restarts"], "fails": g["fails"], "cool": g["cool"]}

def prune(today_str, keep_days=8):
    """Detail event & laporan harian lebih tua dari keep_days dihapus; agregat harian ('days') dan runtime tetap disimpan."""
    from datetime import datetime, timedelta
    lim = (datetime.strptime(today_str, '%Y-%m-%d') - timedelta(days=keep_days)).strftime('%Y-%m-%d')
    n = 0
    with lock():
        days = load('days', {}) or {}
        for k in list(load('index', {}).keys()):
            if k.startswith('events-') and k[7:] < lim and k[7:] not in days:
                days[k[7:]] = _agg(load(k, []))            # simpan agregat harian dulu
                save('days', days)
        for k in list(load('index', {}).keys()):
            for pre in ('events-', 'report-'):
                if k.startswith(pre) and k[len(pre):] < lim:
                    delete(k); n += 1
    return n

# ---- runtime script: [mulai, selesai|None, cara] ----
def rt_load(): return load('runtime', None) or {'first': None, 'runs': []}

def rt_start():
    now = int(time.time()); rt = rt_load()
    hb = 0
    try: hb = int(open(os.path.join(STATE, 'hb')).read().strip() or 0)
    except Exception: pass
    if rt['runs'] and rt['runs'][-1][1] is None:          # proses sebelumnya mati mendadak (baterai habis / kill)
        s = rt['runs'][-1][0]
        rt['runs'][-1][1] = min(max(hb, s), now); rt['runs'][-1][2] = 'mati-mendadak'
    gap, how = 0, '-'
    if rt['runs'] and rt['runs'][-1][1] is not None:
        gap = max(0, now - rt['runs'][-1][1]); how = rt['runs'][-1][2] or '-'
    if rt['first'] is None: rt['first'] = now
    rt['runs'].append([now, None, ''])
    save('runtime', rt)
    return gap, how, len(rt['runs'])

def rt_stop():
    rt = rt_load(); now = int(time.time())
    if rt['runs'] and rt['runs'][-1][1] is None:
        rt['runs'][-1][1] = now; rt['runs'][-1][2] = 'normal'; save('runtime', rt)

if __name__ == '__main__':
    c = sys.argv[1] if len(sys.argv) > 1 else ''
    if c == 'init': _km()
    elif c == 'ledger-add': ledger_add(sys.argv[2], sys.argv[3], sys.argv[4])
    elif c == 'archive-events':
        print(archive_events(sys.argv[2], sys.argv[3]))
        try: prune(sys.argv[2])
        except Exception: pass
    elif c == 'rt-start': print(*rt_start())
    elif c == 'rt-stop': rt_stop()
    elif c == 'list':
        for k, v in sorted(load('index', {}).items()):
            print(time.strftime('%F %T', time.localtime(v)), k)
    elif c == 'show':
        print(json.dumps(load(sys.argv[2], None), indent=2, ensure_ascii=False))
    else:
        print('perintah: init | list | show <nama>'); sys.exit(1)
PYEOF
cat > "$HELP/tgbot.py" <<'PYEOF'
# Bot Telegram interaktif: menu tombol, status, balance, laporan, WD, IP, folder, restart.
# Hanya melayani CHAT_ID pemilik. Aksi yang butuh tmux dititipkan ke antrean (cmdq) untuk dijalankan manager.
import os, sys, json, time, subprocess, urllib.request, urllib.parse, html, threading
from datetime import datetime
from decimal import Decimal
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vault

ST = os.environ.get('REVIL_STATE', os.path.expanduser('~/.tmux_manager'))
TOKEN = os.environ.get('BOT_TOKEN', ''); CHAT = str(os.environ.get('CHAT_ID', ''))
BASE = os.environ.get('BASE_DIR', ''); CUR = os.environ.get('DEFAULT_CURRENCY', 'USDT')
HELP = os.path.dirname(os.path.abspath(__file__))
API = f"https://api.telegram.org/bot{TOKEN}/"
LINE = "━━━━━━━━━━━━━━━━━━━━"
e = lambda x: html.escape(str(x))

def call(method, **params):
    data = urllib.parse.urlencode({k: (json.dumps(v) if isinstance(v, (dict, list)) else v) for k, v in params.items()}).encode()
    try:
        return json.load(urllib.request.urlopen(urllib.request.Request(API + method, data=data), timeout=15))
    except Exception as ex:
        return {'ok': False, 'error': str(ex)}

def send(text, kb=None):
    p = dict(chat_id=CHAT, text=text[:4000], parse_mode='HTML', disable_web_page_preview='true')
    if kb: p['reply_markup'] = kb
    return call('sendMessage', **p)

def btn(t, d): return {'text': t, 'callback_data': d}
MAIN_KB = {'inline_keyboard': [
    [btn('📊 Status', 'st'), btn('💰 Balance', 'bal')],
    [btn('📈 Laporan hari ini', 'rep0'), btn('🗓 Laporan kemarin', 'rep1')],
    [btn('🏦 WD sekarang', 'wd'), btn('🌐 IP & Jaringan', 'ip')],
    [btn('📂 Folder akun', 'fld'), btn('♻️ Restart akun', 'rs')]]}

def rd(p, d=''):
    try: return open(p).read().strip()
    except Exception: return d
def accounts():
    try: return sorted(x for x in os.listdir(BASE) if os.path.isdir(os.path.join(BASE, x)))
    except Exception: return []
def sname(a): return a.replace('.', '_').replace(':', '_')
def has_session(s):
    try: return subprocess.run(['tmux', 'has-session', '-t', '=' + s], capture_output=True, timeout=5).returncode == 0
    except Exception: return False
def age(sec):
    sec = max(0, int(sec)); h, r = divmod(sec, 3600); m = r // 60
    return f"{h}j {m}m" if h else f"{m}m"
def queue(kind, arg):
    # WD hanya dikerjakan jalur bux; restart dikerjakan jalur lime & bux (masing-masing pane-nya)
    for lane in (['bux'] if kind == 'wd' else ['lime', 'bux']):
        with open(os.path.join(ST, f'cmdq.{lane}'), 'a') as f: f.write(f"{kind}|{arg}\n")

def today_events():
    day = datetime.now().strftime('%Y-%m-%d'); out = []
    try:
        for ln in open(os.path.join(ST, 'events.tsv'), encoding='utf-8'):
            p = ln.rstrip('\n').split('|')
            if len(p) >= 5 and datetime.fromtimestamp(int(p[0])).strftime('%Y-%m-%d') == day: out.append(p)
    except Exception: pass
    return out

def cmd_status():
    rows = []
    for a in accounts():
        s = sname(a); live = has_session(s)
        l, b = rd(f'{ST}/{s}.lime.state', '-'), rd(f'{ST}/{s}.bux.state', '-')
        sl = int(rd(f'{ST}/{s}.lime.start', '0') or 0); sb = int(rd(f'{ST}/{s}.bux.start', '0') or 0)
        ico = '🟢' if live and l == 'ok' and b in ('ok', 'wd') else ('🟠' if live else '🔴')
        rows.append(f"{ico} <code>{e(a)}</code>\n    🍋 {e(l)} {age(time.time() - sl) if sl and live else '-'} • 🪙 {e(b)} {age(time.time() - sb) if sb and live else '-'}")
    ipj = {}
    try: ipj = json.load(open(f'{ST}/ip.json'))
    except Exception: pass
    rt = {}
    try: rt = vault.load('runtime', None) or {}
    except Exception: pass
    cur = (rt.get('runs') or [[0]])[-1][0]
    send(f"📊 <b>STATUS SESI</b>\n{LINE}\n" + ("\n".join(rows) or "(belum ada folder akun)") +
         f"\n{LINE}\n⏱ Manager jalan: {age(time.time() - cur) if cur else '-'} • henti total: {len(rt.get('runs', [])) - 1}x" +
         f"\n{LINE}\n🌐 IP <code>{e(ipj.get('ip', '-'))}</code> • {e(ipj.get('org', '-'))}\n🕒 {datetime.now().strftime('%H:%M:%S')}", MAIN_KB)

def cmd_balance():
    ev = today_events(); led = []
    try: led = vault.load('ledger', [])
    except Exception: pass
    blocks = []
    for a in accounts():
        s = sname(a); ln = Decimal(0); nl = 0; bux = {}
        for p in ev:
            if p[2] != a: continue
            if p[1] == 'claim': ln += Decimal(p[3]); nl += 1
            elif p[1] == 'buxclaim': bux[p[3]] = bux.get(p[3], Decimal(0)) + Decimal(p[4])
        t = rd(f'{ST}/{s}.total', '0 0').split()
        pend, done = {}, {}
        for r in led:
            if r[1] == a: (pend if r[4] == 'pending' else done)[r[2]] = (pend if r[4] == 'pending' else done).get(r[2], Decimal(0)) + Decimal(r[3])
        b = f"👤 <b>{e(a)}</b>\n 🍋 hari ini <code>+{ln:.8f}</code> {e(CUR)} ({nl} klaim) • total <code>+{Decimal(t[0]):.8f}</code>"
        b += "\n 🪙 claim hari ini: " + (" • ".join(f"{e(c)} {v:.8f}" for c, v in sorted(bux.items())) or "-")
        tk = []
        for l in rd(f'{ST}/{s}.wdtok', '').splitlines():
            q = l.split()
            if len(q) >= 3 and q[0] == datetime.now().strftime('%Y-%m-%d'): tk.append(f"{q[1]}:{q[2]}")
        b += "\n 🏷 WD hari ini: " + (" ".join(tk) or "-")
        b += "\n ⏳ proses WD: " + (" • ".join(f"{e(c)} {v:.8f}" for c, v in sorted(pend.items())) or "-")
        b += "\n ✅ DONE (total): " + (" • ".join(f"{e(c)} {v:.8f}" for c, v in sorted(done.items())) or "-")
        blocks.append(b)
    send(f"💰 <b>BALANCE</b>\n{LINE}\n" + ("\n\n".join(blocks) or "(belum ada data)") + f"\n{LINE}\n🕒 {datetime.now().strftime('%H:%M:%S')}", MAIN_KB)

def cmd_ip():
    try: j = json.load(open(f'{ST}/ip.json'))
    except Exception: send("🌐 Data IP belum tersedia, coba lagi sebentar lagi.", MAIN_KB); return
    since = j.get('since', 0)
    send(f"🌐 <b>IP & JARINGAN</b>\n{LINE}\n📍 IP : <code>{e(j.get('ip', '-'))}</code>\n📡 Provider : <b>{e(j.get('org', '-'))}</b>\n"
         f"🏙 Lokasi : {e(j.get('city', '-'))}\n⏱ Stabil sejak : {age(time.time() - since) if since else '-'}\n"
         f"🔁 IP sebelumnya : <code>{e(j.get('prev', '-'))}</code>\n🕒 {datetime.now().strftime('%H:%M:%S')}", MAIN_KB)

def cmd_folder():
    rows = []
    for a in accounts():
        s = sname(a); has_main = os.path.exists(os.path.join(BASE, a, 'main.py'))
        rows.append(f"{'🟢' if has_session(s) else '🔴'} <code>{e(a)}</code> {'' if has_main else '(main.py hilang)'}")
    send(f"📂 <b>FOLDER AKUN</b> ({len(rows)})\n{LINE}\n" + ("\n".join(rows) or "(kosong)") + f"\n{LINE}\n📌 {e(BASE)}", MAIN_KB)

def cmd_report(back):
    day = datetime.fromtimestamp(time.time() - 86400 * back).strftime('%Y-%m-%d')
    out = os.path.join(ST, 'reports')
    send(f"⏳ Menyusun laporan {day}...")
    env = dict(os.environ); env['REPORT_SAVE'] = '0'
    subprocess.run([sys.executable, os.path.join(HELP, 'report.py'), os.path.join(ST, 'events.tsv'), day, out, CUR], env=env, capture_output=True, timeout=120)
    n = 0
    for f in sorted(x for x in os.listdir(out) if x.startswith(day + '.part')):
        p = os.path.join(out, f); send(open(p, encoding='utf-8').read()); os.remove(p); n += 1; time.sleep(0.8)
    if not n: send("Laporan kosong.")

def acc_kb(prefix, with_all):
    rows = ([[btn('🏦 SEMUA akun', prefix + ':ALL')]] if with_all else [])
    acc = accounts()
    for i in range(0, len(acc), 2): rows.append([btn(a, prefix + ':' + a) for a in acc[i:i + 2]])
    rows.append([btn('⬅️ Menu', 'menu')])
    return {'inline_keyboard': rows}

def handle(cmd, arg=''):
    if cmd in ('start', 'menu'): send(f"👑 <b>REVIL TMUX MANAGER</b>\n{LINE}\nPilih menu di bawah. Semua data diambil langsung dari bot ini.", MAIN_KB)
    elif cmd in ('st', 'status'): cmd_status()
    elif cmd in ('bal', 'balance'): cmd_balance()
    elif cmd in ('rep0', 'laporan'): cmd_report(0)
    elif cmd in ('rep1', 'kemarin'): cmd_report(1)
    elif cmd == 'ip': cmd_ip()
    elif cmd in ('fld', 'folder'): cmd_folder()
    elif cmd == 'wd':
        if arg:
            queue('wd', arg)
            send(f"🏦 Permintaan WD <b>{e(arg)}</b> diterima. Dijalankan setelah tugas yang sedang berjalan selesai; hasilnya dikirim ke sini.")
        else: send("🏦 <b>WD SEKARANG</b>\nPilih akun (koin diproses satu per satu, run BUX dihentikan sementara):", acc_kb('wd', True))
    elif cmd in ('rs', 'restart'):
        if arg:
            queue('restart', arg)
            send(f"♻️ Restart sesi <b>{e(arg)}</b> (lime + bux) diterima.")
        else: send("♻️ <b>RESTART AKUN</b>\nPilih akun:", acc_kb('rs', False))

def handle_update(u):
    if 'callback_query' in u:
        q = u['callback_query']
        if str(q.get('message', {}).get('chat', {}).get('id')) != CHAT: return
        call('answerCallbackQuery', callback_query_id=q['id'])
        d = q.get('data', ''); cmd, _, arg = d.partition(':')
        handle(cmd, arg)
    elif 'message' in u:
        m = u['message']
        if str(m.get('chat', {}).get('id')) != CHAT: return
        t = (m.get('text') or '').strip()
        if not t.startswith('/'): return
        w = t.split()
        handle(w[0][1:].split('@')[0].lower(), w[1] if len(w) > 1 else '')

def poll():
    offp = os.path.join(ST, 'tg.offset')
    off = rd(offp, '')
    if off == '':   # pertama kali: abaikan pesan lama
        r = call('getUpdates', offset=-1, timeout=0)
        last = max([x['update_id'] for x in r.get('result', [])], default=-1)
        open(offp, 'w').write(str(last + 1)); return
    r = call('getUpdates', offset=int(off), timeout=0, allowed_updates=['message', 'callback_query'])
    for u in r.get('result', []):
        try: handle_update(u)
        except Exception as ex: print('bot error:', ex, file=sys.stderr)
        off = str(u['update_id'] + 1)
    open(offp, 'w').write(off)

def daemon():
    """Proses sendiri (long polling): tetap membalas walau manager sedang sibuk WD/setup."""
    mp = int(os.environ.get('MANAGER_PID', '0') or 0)
    offp = os.path.join(ST, 'tg.offset')
    setup()
    while True:
        if mp:
            try: os.kill(mp, 0)
            except OSError: return
        off = rd(offp, '')
        if off == '':
            r = call('getUpdates', offset=-1, timeout=0)
            last = max([x['update_id'] for x in r.get('result', [])], default=-1)
            open(offp, 'w').write(str(last + 1)); continue
        r = call('getUpdates', offset=int(off), timeout=25, allowed_updates=['message', 'callback_query'])
        if not r.get('ok'): time.sleep(5); continue
        for u in r.get('result', []):
            off = str(u['update_id'] + 1)
            threading.Thread(target=lambda x=u: _safe(x), daemon=True).start()
        open(offp, 'w').write(off)

def _safe(u):
    try: handle_update(u)
    except Exception as ex: print('bot error:', ex, file=sys.stderr)

def setup():
    call('setMyCommands', commands=[
        {'command': 'menu', 'description': 'Menu utama (tombol)'}, {'command': 'status', 'description': 'Status semua sesi'},
        {'command': 'balance', 'description': 'Balance & profit hari ini'}, {'command': 'laporan', 'description': 'Laporan hari ini (live)'},
        {'command': 'kemarin', 'description': 'Laporan kemarin'}, {'command': 'wd', 'description': 'WD sekarang'},
        {'command': 'ip', 'description': 'IP & provider'}, {'command': 'folder', 'description': 'Folder akun terdeteksi'},
        {'command': 'restart', 'description': 'Restart akun'}])

if __name__ == '__main__':
    c = sys.argv[1] if len(sys.argv) > 1 else 'poll'
    if c == 'daemon': daemon()
    elif c == 'poll': poll()
    elif c == 'setup': setup()
PYEOF
cat > "$HELP/common.py" <<'PYEOF'
import re, os, json, time
ANSI = re.compile(r'\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b[()][A-Za-z0-9]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[=>78cM]')
def strip(t): return ANSI.sub('', t)
def jload(p, d):
    try: return json.load(open(p))
    except Exception: return d
def jsave(p, o):
    tmp = p + '.tmp'
    json.dump(o, open(tmp, 'w')); os.replace(tmp, p)
PYEOF
cat > "$HELP/bux_tick.py" <<'PYEOF'
# argumen: acc logfile offsetfile statefile eventsfile outboxdir
import sys, os, re, time, random
from decimal import Decimal
from datetime import datetime
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import strip, jload, jsave
import html

acc, logp, offp, stp, evp, outdir = sys.argv[1:7]
FUN = ["Cuan mengalir deras 💸", "Receh demi receh jadi bukit ⛰️", "Mesin uang lagi semangat 🔥",
       "Dompet tersenyum lebar 😎", "Sultan mode: ON 👑", "Tabungan makin gendut 🐷"]
LINE = "━━━━━━━━━━━━━━━━━━━━"
CLAIM = re.compile(r'\[([A-Z]{2,8})\]\s*Claim Berhasil!?\s*\(\+?([0-9]+(?:\.[0-9]+)?)\)')
COOL = re.compile(r'\[([A-Z]{2,8})\]\s*Cooldown\s*\((\d+:\d+)\)')

try: off = int(open(offp).read().strip() or 0)
except Exception: off = 0
try: size = os.path.getsize(logp)
except Exception: sys.exit(0)
if size < off: off = 0
with open(logp, 'rb') as f:
    f.seek(off); raw = f.read(2_000_000)
open(offp, 'w').write(str(off + len(raw)))

today = datetime.now().strftime('%Y-%m-%d')
st = jload(stp, {})
if st.get('day') != today:
    st['day'] = today; st['tot'] = {}; st['cnt'] = {}
st.setdefault('buf', []); st.setdefault('cool', {}); st.setdefault('carry', ''); st.setdefault('buf_ts', 0)

text = st['carry'] + strip(raw.decode('utf-8', 'replace'))
parts = re.split(r'[\r\n]+', text)
st['carry'] = parts.pop() if parts else ''
if len(st['carry']) > 2000: st['carry'] = ''

def ev(kind, a, b, c='-'):
    with open(evp, 'a') as f: f.write(f"{int(time.time())}|{kind}|{a}|{b}|{c}\n")

def out(msg):
    os.makedirs(outdir, exist_ok=True)
    open(os.path.join(outdir, f"{time.time_ns()}.html"), 'w', encoding='utf-8').write(msg)

def fmt(d): return f"{d:.8f}"

def flush():
    if not st['buf']: return
    rows = "\n".join(f"✅ <b>{html.escape(c)}</b>  <code>+{html.escape(a)}</code>" for c, a in st['buf'])
    cool = ", ".join(html.escape(c) for c in st['cool']) or "-"
    tots = " • ".join(f"{html.escape(c)} {fmt(Decimal(v))}" for c, v in sorted(st['tot'].items()))
    out(f"🪙 <b>BUX CLAIM</b> 🪙\n{LINE}\n👤 Akun : <code>{html.escape(acc)}</code>\n{rows}\n"
        f"⏳ Cooldown : {cool}\n{LINE}\n📅 Hari ini : {tots}\n🕒 {datetime.now().strftime('%H:%M:%S')}\n{random.choice(FUN)}")
    st['buf'] = []

for ln in parts:
    ln = ln.strip()
    if not ln: continue
    m = CLAIM.search(ln)
    if m:
        coin, amt = m.group(1), m.group(2)
        st['buf'].append([coin, amt]); st['buf_ts'] = st['buf_ts'] or time.time()
        st['tot'][coin] = str(Decimal(st['tot'].get(coin, '0')) + Decimal(amt))
        st['cnt'][coin] = st['cnt'].get(coin, 0) + 1
        st['cool'].pop(coin, None)
        ev('buxclaim', acc, coin, amt)
        continue
    m = COOL.search(ln)
    if m:
        coin, left = m.group(1), m.group(2)
        if coin not in st['cool']:
            st['cool'][coin] = time.time()
            ev('cooldown', acc, coin)
            out(f"⏳ <b>BUX COOLDOWN</b> ⏳\n{LINE}\n👤 Akun : <code>{html.escape(acc)}</code>\n"
                f"🪙 Koin : <b>{html.escape(coin)}</b>\n⏱ Sisa : <b>{html.escape(left)}</b>\n"
                f"🕒 {datetime.now().strftime('%H:%M:%S')}\n😴 Santai, nanti klaim lagi otomatis")
        continue
    if 'Putaran selesai' in ln or ('ROTASI' in ln and 'DIMULAI' in ln):
        flush()

if st['buf'] and time.time() - st['buf_ts'] > 180: flush()
if not st['buf']: st['buf_ts'] = 0
jsave(stp, st)
PYEOF
cat > "$HELP/wd_wait.py" <<'PYEOF'
# argumen: logfile offset coin   -> cetak variabel shell (aman via shlex.quote)
import sys, os, re, shlex
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import strip
logp, off, coin = sys.argv[1], int(sys.argv[2]), (sys.argv[3] if len(sys.argv) > 3 else '')
try:
    with open(logp, 'rb') as f:
        f.seek(off); raw = f.read(3_000_000)
except Exception:
    print("DONE=0"); sys.exit(0)
t = strip(raw.decode('utf-8', 'replace')).replace('\r', '\n')
i = t.rfind('Initializing session')
BAL = re.compile(r'\[0?(\d+)\]\s+([A-Z]{2,8})\s+Bal:\s*([0-9]+(?:\.[0-9]+)?)')
ERRX = re.compile(r'error|exception|traceback|timed? ?out|connection|unreachable|network|max retries', re.I)
def first_err(txt):
    for ln in txt.split('\n'):
        ln = ln.strip()
        if ERRX.search(ln) and 'Solving' not in ln and 'Sending' not in ln: return ln[:120]
    return ''
if i == -1:
    e0 = first_err(t)
    print("DONE=0")
    if e0: print("ERR=1"); print(f"MSG={shlex.quote(e0)}")
    sys.exit(0)
after, before = t[i:], t[:i]
rows = {}
for m in BAL.finditer(after):
    rows[int(m.group(1))] = (m.group(2), m.group(3))
if len(rows) < 8:
    e0 = first_err(before)
    print("DONE=0")
    if e0: print("ERR=1"); print(f"MSG={shlex.quote(e0)}")
    sys.exit(0)
success = 1 if re.search(r'\[SUCCESS\]|Berhasil Dikirim', before) else 0
msg = ''
for ln in before.split('\n'):
    ln = ln.strip()
    if re.search(r'error|gagal|fail|limit|sudah|already|cooldown|invalid|wait', ln, re.I) and 'Solving' not in ln and 'Sending' not in ln:
        msg = ln[:120]; break
err = first_err(before) if not success else ''
print("DONE=1"); print(f"SUCCESS={success}"); print(f"MSG={shlex.quote(msg)}"); print(f"ERR={1 if err else 0}")
print(f"N={len(rows)}")
for k, (c, b) in sorted(rows.items()):
    print(f"C{k}={c}"); print(f"B{k}={b}")
afterbal = next((b for k, (c, b) in rows.items() if c == coin), '')
print(f"AFTER={afterbal}")
PYEOF
cat > "$HELP/ledger.py" <<'PYEOF'
# tandai wd pending >24 jam jadi done (data dari vault terenkripsi), kirim notif, catat event
import sys, os, time, html
from datetime import datetime
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vault
evp, outdir = sys.argv[1:3]
LINE = "━━━━━━━━━━━━━━━━━━━━"
if not vault.exists('ledger'): sys.exit(0)
now = int(time.time()); newdone = {}
with vault.lock():                      # baca-ubah-simpan satu kesatuan (aman dari jalur lain)
    rows = vault.load('ledger', [])
    for r in rows:
        if r[4] == 'pending' and now - int(r[0]) >= 86400:
            r[4] = 'done'; newdone.setdefault(r[1], []).append((r[2], r[3]))
    if newdone: vault.save('ledger', rows)
if not newdone: sys.exit(0)
os.makedirs(outdir, exist_ok=True)
for acc, items in newdone.items():
    with open(evp, 'a') as f:
        for c, a in items: f.write(f"{now}|wddone|{acc}|{c}|{a}\n")
    body = "\n".join(f"💵 <b>{html.escape(c)}</b>  <code>+{html.escape(a)}</code>" for c, a in items)
    open(os.path.join(outdir, f"{time.time_ns()}.html"), 'w', encoding='utf-8').write(
        f"🏆 <b>WD SELESAI (24 JAM)</b> 🏆\n{LINE}\n👤 Akun : <code>{html.escape(acc)}</code>\n{body}\n{LINE}\n"
        f"✅ Sudah masuk total gabungan akun\n🕒 {datetime.now().strftime('%H:%M:%S')}\n🎉 Cuan resmi mendarat, Bos!")
PYEOF
cat > "$HELP/report.py" <<'PYEOF'
# argumen: events day out_dir currency   -> bagian pesan HTML di out_dir, JSON lengkap ke vault terenkripsi
import sys, html, os, statistics, time, json, urllib.request
from collections import defaultdict
from datetime import datetime
from decimal import Decimal
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vault

ev_path, day, out_dir, cur = sys.argv[1:5]
LINE = "━━━━━━━━━━━━━━━━━━━━"
Z = Decimal(0)
def e(x): return html.escape(str(x))
def D(x, n=8): return f"{x:.{n}f}"
def mnt(m): return f"{m:.2f} mnt"
def dur(sec):
    sec = int(sec); h, r = divmod(sec, 3600); m, s = divmod(r, 60)
    return (f"{h}j " if h else "") + (f"{m}m " if (m or h) else "") + f"{s}dtk"
def mean(x): return statistics.mean(x) if x else None

lime = defaultdict(list)                         # acc -> [(ts, amt)]
bux = defaultdict(lambda: defaultdict(list))     # acc -> coin -> [(ts, amt)]
cools = defaultdict(lambda: defaultdict(int))
setups = defaultdict(list)                       # kind -> [(acc, secs, rc)]
recov = defaultdict(list)                        # kind -> [(acc, secs, reason)]
rest = defaultdict(lambda: defaultdict(int))     # (acc, kind) -> reason -> n
wds = defaultdict(lambda: defaultdict(Decimal)); wdskip = defaultdict(list); wdfail = defaultdict(list)
wddone = defaultdict(lambda: defaultdict(Decimal)); wdruns = []
pending = defaultdict(lambda: defaultdict(Decimal))
gap_total = gap_n = 0; nets = []; accs = set()

try: lines = open(ev_path, encoding="utf-8").read().splitlines()
except Exception: lines = []
try: lines = list(vault.load("events-" + day, [])) + lines
except Exception: pass
for ln in lines:
    p = ln.split("|")
    if len(p) < 5: continue
    try: ts = int(p[0])
    except ValueError: continue
    if datetime.fromtimestamp(ts).strftime("%Y-%m-%d") != day: continue
    typ, acc, v1, v2 = p[1], p[2], p[3], p[4]
    try:
        if typ == "claim": lime[acc].append((ts, Decimal(v1))); accs.add(acc)
        elif typ == "buxclaim": bux[acc][v1].append((ts, Decimal(v2))); accs.add(acc)
        elif typ == "cooldown": cools[acc][v1] += 1; accs.add(acc)
        elif typ == "setup":
            rc, _, kind = v2.partition(":"); setups[kind or "?"].append((acc, int(v1), int(rc))); accs.add(acc)
        elif typ == "recover":
            kind, _, reason = v2.partition(":"); recov[kind].append((acc, int(v1), reason)); accs.add(acc)
        elif typ == "restart": rest[(acc, v2)][v1] += 1; accs.add(acc)
        elif typ == "gap": gap_total += int(v1); gap_n += 1
        elif typ == "net": nets.append(int(v1))
        elif typ == "wd": wds[acc][v1] += Decimal(v2); accs.add(acc)
        elif typ == "wdskip": wdskip[acc].append(v1); accs.add(acc)
        elif typ == "wdfail": wdfail[acc].append((v1, v2)); accs.add(acc)
        elif typ == "wddone": wddone[acc][v1] += Decimal(v2); accs.add(acc)
        elif typ == "wdrun": wdruns.append((acc, int(v1))); accs.add(acc)
    except Exception: pass

try:
    for r in vault.load("ledger", []):
        if r[4] == "pending": pending[r[1]][r[2]] += Decimal(r[3])
except Exception: pass

IDS = {"DOGE": "dogecoin", "LTC": "litecoin", "DGB": "digibyte", "TRX": "tron", "USDT": "tether",
       "BCH": "bitcoin-cash", "DASH": "dash", "PEPE": "pepe"}
def get_prices():
    cp = os.path.join(out_dir, "prices.json"); c = {}
    try:
        c = json.load(open(cp))
        if time.time() - c.get("ts", 0) < 3600: return c["p"]
    except Exception: pass
    try:
        u = "https://api.coingecko.com/api/v3/simple/price?vs_currencies=usd&ids=" + ",".join(IDS.values())
        d = json.load(urllib.request.urlopen(u, timeout=8))
        p = {k: d[v]["usd"] for k, v in IDS.items() if v in d}
        os.makedirs(out_dir, exist_ok=True); json.dump({"ts": time.time(), "p": p}, open(cp, "w")); return p
    except Exception: return c.get("p", {})
PRICES = get_prices()
def usd(coin, amt):
    if coin == "USDT": return amt
    pr = PRICES.get(coin)
    return Decimal(str(pr)) * amt if pr is not None else None
def usd_sum(items):  # items: {coin: amt} -> (total, lengkap?)
    t, ok = Z, True
    for c, a in items.items():
        u = usd(c, a)
        if u is None: ok = False
        else: t += u
    return t, ok

def ivs(lst):
    ts = sorted(t for t, _ in lst)
    return [(ts[i + 1] - ts[i]) / 60 for i in range(len(ts) - 1)]

names = sorted(accs)
parts = []
def add(t): parts.append(t)
def pre_blocks(title, header, rows, limit=3200):
    cur_rows, size, first = [], len(header), True
    def flush():
        nonlocal cur_rows, first
        if not cur_rows: return
        t = title if first else title + " <i>(lanjutan)</i>"
        add(f"{t}\n<pre>{e(header)}\n" + "\n".join(e(r) for r in cur_rows) + "</pre>"); first = False; cur_rows = []
    for r in rows:
        if size + len(r) + 1 > limit: flush(); size = len(header)
        cur_rows.append(r); size += len(r) + 1
    flush()

J = {"day": day, "generated": int(time.time()), "prices_ok": bool(PRICES), "accounts": {}}

if not names:
    add(f"🌙 <b>LAPORAN 24 JAM</b> • {e(day)}\n{LINE}\n😴 Tidak ada aktivitas tercatat di hari ini.")
else:
    na = len(names)
    # ---------- hitung per akun ----------
    A = {}
    for a in names:
        L = sorted(lime.get(a, [])); l_tot = sum((v for _, v in L), Z); l_iv = ivs(L)
        bc = {c: sorted(v) for c, v in bux.get(a, {}).items()}
        b_all = sorted(x for v in bc.values() for x in v)
        b_n = len(b_all); b_tot_coin = {c: sum((v for _, v in lst), Z) for c, lst in bc.items()}
        b_usd, b_ok = usd_sum(b_tot_coin)
        d_usd, d_ok = usd_sum(dict(wddone.get(a, {})))
        down = {k: sum(s for ac, s, _ in recov.get(k, []) if ac == a) for k in ("lime", "bux")}
        sess_down = sum(s for ac, s, _ in recov.get("session", []) if ac == a)
        A[a] = dict(l_n=len(L), l_tot=l_tot, l_iv=l_iv, bc=bc, b_n=b_n, b_tot_coin=b_tot_coin, b_usd=b_usd, b_ok=b_ok,
                    b_iv=ivs(b_all), d_usd=d_usd, d_ok=d_ok, gab=l_tot + d_usd, pot=l_tot + b_usd,
                    up_lime=max(0.0, 100 * (1 - (down["lime"] + sess_down) / 86400)),
                    up_bux=max(0.0, 100 * (1 - (down["bux"] + sess_down) / 86400)))
    T_l = sum((A[a]["l_tot"] for a in names), Z); N_l = sum(A[a]["l_n"] for a in names)
    N_b = sum(A[a]["b_n"] for a in names); T_bu = sum((A[a]["b_usd"] for a in names), Z)
    T_d = sum((A[a]["d_usd"] for a in names), Z); T_g = T_l + T_d; T_p = T_l + T_bu
    all_ok = all(A[a]["b_ok"] and A[a]["d_ok"] for a in names)
    l_all_iv = [x for a in names for x in A[a]["l_iv"]]; b_all_iv = [x for a in names for x in A[a]["b_iv"]]

    # ---------- 1. ringkasan ----------
    up_l = mean([A[a]["up_lime"] for a in names]); up_b = mean([A[a]["up_bux"] for a in names])
    add(f"🌙 <b>LAPORAN 24 JAM</b> • {e(day)}\n{LINE}\n"
        f"🍋 <b>Lime</b>  : <code>+{D(T_l)}</code> USDT • <b>{N_l}</b> klaim\n"
        f"🪙 <b>Bux claim</b> : <b>{N_b}</b> klaim • ≈ <code>${D(T_bu)}</code>{'' if all_ok or PRICES else ' (tanpa harga)'}\n"
        f"🏦 <b>Bux DONE</b>  : ≈ <code>${D(T_d)}</code>\n{LINE}\n"
        f"💎 <b>Gabungan</b> (lime + bux DONE): <b>+${D(T_g)}</b>\n"
        f"🎯 Potensi (lime + bux claim): <b>+${D(T_p)}</b>\n"
        f"📈 Rata² gabungan per akun: <b>+${D(T_g / na)}</b>\n{LINE}\n"
        f"⏱ Rata² jarak klaim: lime <b>{mnt(mean(l_all_iv)) if l_all_iv else '-'}</b> • bux <b>{mnt(mean(b_all_iv)) if b_all_iv else '-'}</b>\n"
        f"🟢 Uptime: lime <b>{up_l:.1f}%</b> • bux <b>{up_b:.1f}%</b>")

    # ---------- 2. LIME ----------
    hdr = f"{'FOLDER':<17}{'KLAIM':>5} {'PROFIT':>13} {'RATA2/KLAIM':>12}"
    rows = [f"{a[:16]:<17}{A[a]['l_n']:>5} {'+'+D(A[a]['l_tot']):>13} {D(A[a]['l_tot'] / A[a]['l_n'] if A[a]['l_n'] else Z):>12}" for a in names]
    rows += ["-" * len(hdr), f"{'SEMUA':<17}{N_l:>5} {'+'+D(T_l):>13} {D(T_l / N_l if N_l else Z):>12}"]
    pre_blocks("🍋 <b>PROGRAM 1 • LIME</b> — profit per folder (24 jam)", hdr, rows)
    hdr = f"{'FOLDER':<17}{'RATA2':>8}{'MIN':>8}{'MAX':>9}"
    rows = [f"{a[:16]:<17}" + (f"{mean(A[a]['l_iv']):>8.2f}{min(A[a]['l_iv']):>8.2f}{max(A[a]['l_iv']):>9.2f}" if A[a]["l_iv"] else f"{'-':>8}{'-':>8}{'-':>9}") for a in names]
    pre_blocks("⏱ Jarak antar klaim lime (menit)", hdr, rows)

    # ---------- 3. BUX ----------
    hdr = f"{'FOLDER':<17}{'KOIN':<5}{'KLAIM':>5} {'TOTAL':>13} {'INT':>6}"
    rows = []
    for a in names:
        for c in sorted(A[a]["bc"]):
            lst = A[a]["bc"][c]; iv = ivs(lst)
            rows.append(f"{a[:16]:<17}{c:<5}{len(lst):>5} {D(A[a]['b_tot_coin'][c]):>13} {(f'{mean(iv):.1f}' if iv else '-'):>6}")
    pre_blocks("🪙 <b>PROGRAM 2 • BUX</b> — claim per folder & koin (INT = menit)", hdr, rows or ["(belum ada claim)"])
    ct = defaultdict(Decimal)
    for a in names:
        for c, t in A[a]["b_tot_coin"].items(): ct[c] += t
    nb = len([a for a in names if A[a]["b_n"]]) or 1
    ncool = sum(sum(cools[a].values()) for a in names)
    add("📊 <b>Bux per koin</b> (total • rata² per folder)\n" + "\n".join(
        f"• <b>{e(c)}</b> <code>{D(t)}</code> • <code>{D(t / nb)}</code>" for c, t in sorted(ct.items())) +
        f"\n⏳ Cooldown terdeteksi: <b>{ncool}x</b> • Rata² jarak klaim bux/folder: <b>{mnt(mean(b_all_iv)) if b_all_iv else '-'}</b>")

    # ---------- 4. WD ----------
    wrows = []
    for a in names:
        for c in sorted(wds.get(a, {})): wrows.append(f"{a[:16]:<17}{c:<5}{'proses':<7}{D(wds[a][c]):>13}")
        for c in sorted(wddone.get(a, {})): wrows.append(f"{a[:16]:<17}{c:<5}{'DONE':<7}{D(wddone[a][c]):>13}")
        for c in sorted(pending.get(a, {})): wrows.append(f"{a[:16]:<17}{c:<5}{'tunggu':<7}{D(pending[a][c]):>13}")
        for c in wdskip.get(a, []): wrows.append(f"{a[:16]:<17}{c:<5}{'sdhWD':<7}{'-':>13}")
    if wrows or wdruns:
        pre_blocks("🏦 <b>WITHDRAW (WD)</b>", f"{'FOLDER':<17}{'KOIN':<5}{'STATUS':<7}{'JUMLAH':>13}", wrows or ["(tidak ada)"])
        if wdruns:
            tt = sum(x[1] for x in wdruns)
            add(f"⏱ Proses WD: <b>{len(wdruns)}</b> folder • total <b>{dur(tt)}</b> • rata² <b>{dur(tt / len(wdruns))}</b>")

    # ---------- 5. gabungan per folder ----------
    blocks = []
    for a in names:
        x = A[a]; b = f"👤 <b>{e(a)}</b>\n 🍋 lime <code>+{D(x['l_tot'])}</code> USDT  ({x['l_n']} klaim)"
        b += f"\n 🪙 bux claim ≈ <code>${D(x['b_usd'])}</code>  ({x['b_n']} klaim)"
        if wddone.get(a):
            b += f"\n 🏦 bux DONE ≈ <code>${D(x['d_usd'])}</code>" + "".join(f"\n    • {e(c)} <code>+{D(v)}</code>" for c, v in sorted(wddone[a].items()))
        else:
            b += "\n 🏦 bux DONE: belum ada hari ini"
        if pending.get(a): b += "\n ⏳ proses 24 jam: " + ", ".join(f"{e(c)} {D(v)}" for c, v in sorted(pending[a].items()))
        b += f"\n 🧮 gabungan <b>+${D(x['gab'])}</b> • potensi <b>+${D(x['pot'])}</b>"
        blocks.append(b)
    add("🧾 <b>PROFIT PER FOLDER (GABUNGAN)</b>\n" + LINE + "\n" + "\n\n".join(blocks) +
        f"\n{LINE}\n💎 Semua folder: <b>+${D(T_g)}</b> • rata² per folder <b>+${D(T_g / na)}</b>" +
        ("" if PRICES else "\n(harga koin tidak terjangkau: bux claim/DONE non-USDT dihitung 0 di $)"))

    # ---------- 6. waktu & stabilitas ----------
    hdr = f"{'PROGRAM':<8}{'RUN':>4}{'RATA2':>8}{'MIN':>8}{'MAX':>8}{'GAGAL':>6}"
    rows = []
    for k in ("lime", "bux"):
        s = setups.get(k, [])
        if s:
            v = [x[1] / 60 for x in s]; rows.append(f"{k:<8}{len(s):>4}{mean(v):>8.2f}{min(v):>8.2f}{max(v):>8.2f}{len([1 for x in s if x[2]]):>6}")
        else: rows.append(f"{k:<8}{0:>4}{'-':>8}{'-':>8}{'-':>8}{0:>6}")
    pre_blocks("🚀 <b>PROSES RUN PROGRAM</b> (menit, dari buka pane sampai jalan)", hdr, rows)

    hdr = f"{'PROGRAM':<8}{'N':>4}{'RATA2':>8}{'MAX':>8}"
    rows = []
    for k in ("lime", "bux", "session"):
        r = recov.get(k, [])
        if r:
            v = [x[1] / 60 for x in r]; rows.append(f"{k:<8}{len(r):>4}{mean(v):>8.2f}{max(v):>8.2f}")
        else: rows.append(f"{k:<8}{0:>4}{'-':>8}{'-':>8}")
    byr = defaultdict(list)
    for k, lst in recov.items():
        for _, s, rs in lst: byr[rs].append(s / 60)
    add_txt = "\n".join(f"• {e(rs)}: {len(v)}x • rata² {mnt(mean(v))}" for rs, v in sorted(byr.items()))
    pre_blocks("🛠 <b>PEMULIHAN ERROR</b> (menit, dari error terdeteksi sampai jalan lagi)", hdr, rows)
    if add_txt: add("🔎 <b>Pemulihan per penyebab</b>\n" + add_txt)

    reasons = ["2jam", "maxfail", "cache", "nomain", "mati"]
    hdr = f"{'FOLDER/PROGRAM':<24}" + "".join(f"{r[:6]:>7}" for r in reasons)
    rows = []
    for a in names:
        for k in ("lime", "bux", "session"):
            if (a, k) in rest: rows.append(f"{(a[:16] + '/' + k):<24}" + "".join(f"{rest[(a, k)].get(r, 0):>7}" for r in reasons))
    if rows: pre_blocks("🔄 <b>RESTART</b>", hdr, rows)

    hdr = f"{'FOLDER':<17}{'LIME%':>7}{'BUX%':>7}"
    pre_blocks("🟢 <b>UPTIME 24 JAM</b>", hdr, [f"{a[:16]:<17}{A[a]['up_lime']:>7.1f}{A[a]['up_bux']:>7.1f}" for a in names])

    stt = {k: sum(x[1] for x in v) for k, v in setups.items()}
    waste = sum(stt.values()) + gap_total + sum(nets)
    add(f"⏳ <b>WAKTU TERBUANG</b>\n{LINE}\n🛠 Pembuatan pane/sesi: <b>{dur(sum(stt.values()))}</b> "
        f"(lime {dur(stt.get('lime', 0))} • bux {dur(stt.get('bux', 0))})\n"
        f"🕰 Jeda antar start: <b>{gap_n}x</b> = <b>{dur(gap_total)}</b>\n"
        f"📡 Internet mati: <b>{len(nets)}x</b> = <b>{dur(sum(nets))}</b>\n🧮 Total: <b>{dur(waste)}</b>")

    # ---------- 7. diagnosa per program ----------
    dl, db, dg = [], [], []
    for a in names:
        x = A[a]
        if x["l_n"] == 0: dl.append(f"⚠️ <code>{e(a)}</code> tidak ada klaim lime")
        else:
            iv = x["l_iv"]; om = mean(l_all_iv)
            if om and len(iv) >= 5 and abs(mean(iv) - om) > 0.5 * om:
                dl.append(f"⚠️ <code>{e(a)}</code> rata² klaim {mnt(mean(iv))} vs semua {mnt(om)}")
            if len(iv) >= 5 and max(iv) > max(10, 6 * statistics.median(iv)):
                dl.append(f"🕳 <code>{e(a)}</code> jeda lime terpanjang {mnt(max(iv))} (median {mnt(statistics.median(iv))})")
        if x["b_n"] == 0: db.append(f"⚠️ <code>{e(a)}</code> tidak ada claim bux")
        elif len(x["b_iv"]) >= 5 and max(x["b_iv"]) > max(15, 6 * statistics.median(x["b_iv"])):
            db.append(f"🕳 <code>{e(a)}</code> jeda bux terpanjang {mnt(max(x['b_iv']))} (median {mnt(statistics.median(x['b_iv']))})")
        if sum(cools[a].values()) >= 20: db.append(f"⏳ <code>{e(a)}</code> cooldown {sum(cools[a].values())}x")
        if wdfail.get(a): db.append(f"🏦 <code>{e(a)}</code> WD gagal: " + ", ".join(e(c) for c, _ in wdfail[a]))
        for k, tgt in (("lime", dl), ("bux", db)):
            r = rest.get((a, k), {})
            if r.get("maxfail", 0) >= 3: tgt.append(f"🚨 <code>{e(a)}</code> Max failures {r['maxfail']}x — cek API key/akun")
            if r.get("mati", 0) >= 2: tgt.append(f"💀 <code>{e(a)}</code> {k} mati sendiri {r['mati']}x")
            if r.get("nomain", 0) >= 2: tgt.append(f"🛠 <code>{e(a)}</code> main.py hilang {r['nomain']}x ({k})")
        if x["up_lime"] < 95 or x["up_bux"] < 95: dg.append(f"🟠 <code>{e(a)}</code> uptime rendah (lime {x['up_lime']:.1f}% • bux {x['up_bux']:.1f}%)")
    for k, tgt in (("lime", dl), ("bux", db)):
        bad = [s for s in setups.get(k, []) if s[2]]
        if bad: tgt.append(f"⚠️ Setup {k} gagal {len(bad)}x")
        s = setups.get(k, [])
        if s and mean([x[1] for x in s]) > 180: tgt.append(f"🐢 Rata² setup {k} {dur(mean([x[1] for x in s]))} (lambat)")
        r = recov.get(k, [])
        if r and mean([x[1] for x in r]) > 300: tgt.append(f"🐢 Pemulihan {k} rata² {dur(mean([x[1] for x in r]))} (lama)")
    if nets: dg.append(f"📡 Internet sempat mati {len(nets)}x ({dur(sum(nets))})")
    sec = lambda t, l: f"{t}\n" + ("\n".join(l) if l else "✅ normal")
    add("🧪 <b>DIAGNOSA</b>\n" + LINE + "\n" + sec("🍋 <b>Program 1 (lime)</b>", dl) + "\n\n" + sec("🪙 <b>Program 2 (bux)</b>", db) +
        "\n\n" + sec("🌐 <b>Umum</b>", dg) + "\n\n🌅 Selamat pagi! Semoga cuan makin tebal ✨")

    # ---------- JSON lengkap (disimpan terenkripsi) ----------
    for a in names:
        x = A[a]
        J["accounts"][a] = {
            "lime": {"klaim": x["l_n"], "profit_usdt": str(x["l_tot"]), "interval_menit_rata2": mean(x["l_iv"])},
            "bux": {"klaim": x["b_n"], "per_koin": {c: str(v) for c, v in x["b_tot_coin"].items()},
                    "estimasi_usd": str(x["b_usd"]), "interval_menit_rata2": mean(x["b_iv"]),
                    "cooldown": dict(cools.get(a, {}))},
            "wd": {"proses": {c: str(v) for c, v in wds.get(a, {}).items()}, "done": {c: str(v) for c, v in wddone.get(a, {}).items()},
                   "pending": {c: str(v) for c, v in pending.get(a, {}).items()}, "sudah_wd": wdskip.get(a, []),
                   "gagal": wdfail.get(a, [])},
            "gabungan_usd": str(x["gab"]), "potensi_usd": str(x["pot"]),
            "uptime": {"lime": x["up_lime"], "bux": x["up_bux"]}}
    J["total"] = {"lime_usdt": str(T_l), "bux_claim_usd": str(T_bu), "bux_done_usd": str(T_d),
                  "gabungan_usd": str(T_g), "klaim_lime": N_l, "klaim_bux": N_b}
    J["setup"] = {k: [list(x) for x in v] for k, v in setups.items()}
    J["recover"] = {k: [list(x) for x in v] for k, v in recov.items()}
    J["diagnosa"] = {"lime": dl, "bux": db, "umum": dg}


# ===================== RUNTIME SCRIPT + 7 HARI (2 jenis data) =====================
from datetime import timedelta
RT = vault.load("runtime", None) or {"first": None, "runs": []}
NOW = int(time.time())
def day_ts(d): return int(datetime.strptime(d, "%Y-%m-%d").timestamp())
def hj(sec): return f"{sec / 3600:.2f}"

def rt_day(d):
    a = day_ts(d); b = a + 86400; first = RT.get("first")
    if not first or first >= b: return None
    o0 = max(a, first); o1 = min(b, NOW)
    if o1 <= o0: return None
    run = 0; stops = []; runs = RT["runs"]
    for i, rr in enumerate(runs):
        s, en = rr[0], rr[1]; e2 = en if en else NOW
        run += max(0, min(e2, o1) - max(s, o0))
        if en and o0 <= en < o1:
            nxt = runs[i + 1][0] if i + 1 < len(runs) else NOW
            stops.append((en, max(0, nxt - en), rr[2] if len(rr) > 2 else ""))
    obs = o1 - o0
    return {"obs": obs, "run": min(run, obs), "down": max(0, obs - run), "stops": stops}

WIN = [(datetime.strptime(day, "%Y-%m-%d") - timedelta(days=i)).strftime("%Y-%m-%d") for i in range(6, -1, -1)]
by_day = defaultdict(list)
all_lines = list(lines)
for d in WIN:
    if d != day:
        try: all_lines += list(vault.load("events-" + d, []))
        except Exception: pass
for ln in all_lines:
    try: by_day[datetime.fromtimestamp(int(ln.split("|")[0])).strftime("%Y-%m-%d")].append(ln)
    except Exception: pass

def agg_day(lns):
    g = {"lime_n": 0, "lime": Z, "bux_n": 0, "bux": defaultdict(Decimal), "done": defaultdict(Decimal),
         "wd": defaultdict(Decimal), "restarts": 0, "fails": 0, "cool": 0}
    for ln in lns:
        p = ln.split("|")
        if len(p) < 5: continue
        try:
            if p[1] == "claim": g["lime_n"] += 1; g["lime"] += Decimal(p[3])
            elif p[1] == "buxclaim": g["bux_n"] += 1; g["bux"][p[3]] += Decimal(p[4])
            elif p[1] == "wddone": g["done"][p[3]] += Decimal(p[4])
            elif p[1] == "wd": g["wd"][p[3]] += Decimal(p[4])
            elif p[1] == "restart": g["restarts"] += 1
            elif p[1] == "setup" and not p[4].startswith("0"): g["fails"] += 1
            elif p[1] == "cooldown": g["cool"] += 1
        except Exception: pass
    return g
def enc(g): return {"lime_n": g["lime_n"], "lime": str(g["lime"]), "bux_n": g["bux_n"], "bux": {k: str(v) for k, v in g["bux"].items()},
                    "done": {k: str(v) for k, v in g["done"].items()}, "wd": {k: str(v) for k, v in g["wd"].items()},
                    "restarts": g["restarts"], "fails": g["fails"], "cool": g["cool"]}
def dec(j):
    return {"lime_n": j["lime_n"], "lime": Decimal(j["lime"]), "bux_n": j["bux_n"], "bux": defaultdict(Decimal, {k: Decimal(v) for k, v in j["bux"].items()}),
            "done": defaultdict(Decimal, {k: Decimal(v) for k, v in j.get("done", {}).items()}), "wd": defaultdict(Decimal, {k: Decimal(v) for k, v in j.get("wd", {}).items()}),
            "restarts": j.get("restarts", 0), "fails": j.get("fails", 0), "cool": j.get("cool", 0)}
def usd_of(dct):
    t = Z
    for c, a in dct.items():
        u = usd(c, a)
        if u is not None: t += u
    return t

stored = {}
try: stored = vault.load("days", {}) or {}
except Exception: pass
DAYS = {}
for d in WIN:
    if by_day.get(d): DAYS[d] = agg_day(by_day[d])
    elif d in stored: DAYS[d] = dec(stored[d])
ALLD = {k: dec(v) for k, v in stored.items()}
ALLD.update(DAYS)
if os.environ.get("REPORT_SAVE") == "1" and day in DAYS:
    try:
        stored[day] = enc(DAYS[day]); vault.save("days", stored)
    except Exception as ex: print("simpan days gagal:", ex, file=sys.stderr)

wk = []
RTD = {d: rt_day(d) for d in WIN}
# --- tabel 1: per TANGGAL (kalender) ---
hdr = f"{'TGL':<6}{'LIME-N':>7}{'LIME-USDT':>13}{'BUX-N':>7}{'BUX-$':>10}"
rows = []
for d in WIN:
    g = DAYS.get(d); t = d[5:]
    if g is None: rows.append(f"{t:<6}{'-':>7}{'-':>13}{'-':>7}{'-':>10}")
    else: rows.append(f"{t:<6}{g['lime_n']:>7}{D(g['lime']):>13}{g['bux_n']:>7}{D(usd_of(g['bux']), 4):>10}")
wk.append("📅 <b>7 HARI — JENIS 1: PER TANGGAL</b>\n<pre>" + e(hdr) + "\n" + "\n".join(e(x) for x in rows) + "</pre>")
# --- tabel 2: runtime script ---
hdr = f"{'TGL':<6}{'OBS(j)':>8}{'RUN(j)':>8}{'DOWN(j)':>8}{'HENTI':>6}"
rows = []
for d in WIN:
    x = RTD.get(d); t = d[5:]
    rows.append(f"{t:<6}{'-':>8}{'-':>8}{'-':>8}{'-':>6}" if not x else f"{t:<6}{hj(x['obs']):>8}{hj(x['run']):>8}{hj(x['down']):>8}{len(x['stops']):>6}")
wk.append("⏱ <b>RUNTIME SCRIPT PER HARI</b> (OBS = sejak data pertama tersimpan, DOWN = script mati)\n<pre>" + e(hdr) + "\n" + "\n".join(e(x) for x in rows) + "</pre>")
# --- tabel 3: per JAM RUNTIME (bisa dibandingkan antar hari) ---
hdr = f"{'TGL':<6}{'LIME/j':>11}{'KL-L/j':>8}{'KL-B/j':>8}{'POT$/j':>10}"
rows = []
for d in WIN:
    g = DAYS.get(d); x = RTD.get(d); t = d[5:]
    if g is None or not x or x["run"] <= 0: rows.append(f"{t:<6}{'-':>11}{'-':>8}{'-':>8}{'-':>10}"); continue
    h = Decimal(x["run"]) / 3600
    rows.append(f"{t:<6}{D(g['lime'] / h, 6):>11}{float(g['lime_n'] / h):>8.1f}{float(g['bux_n'] / h):>8.1f}{D((g['lime'] + usd_of(g['bux'])) / h, 6):>10}")
wk.append("⚖️ <b>7 HARI — JENIS 2: PER JAM RUNTIME</b> (adil dibanding walau script sempat mati)\n<pre>" + e(hdr) + "\n" + "\n".join(e(x) for x in rows) + "</pre>")
# --- detail henti hari ini/hari laporan ---
xd = RTD.get(day)
if xd and xd["stops"]:
    lst = "\n".join(f"• {datetime.fromtimestamp(s).strftime('%H:%M')} mati {dur(l)} ({e(c) or 'tidak diketahui'})" for s, l, c in xd["stops"][:10])
    wk.append(f"🔌 <b>SCRIPT BERHENTI {day}</b>: {len(xd['stops'])}x • total {dur(sum(l for _, l, _ in xd['stops']))}\n{lst}")
# --- total keseluruhan ---
first = RT.get("first")
if first:
    run_all = sum(max(0, (rr[1] or NOW) - rr[0]) for rr in RT["runs"]); obs_all = max(1, NOW - first); down_all = max(0, obs_all - run_all)
    stops_all = [(rr[1], (RT["runs"][i + 1][0] if i + 1 < len(RT["runs"]) else NOW) - rr[1]) for i, rr in enumerate(RT["runs"]) if rr[1]]
    t_l = sum((g["lime"] for g in ALLD.values()), Z); n_l = sum(g["lime_n"] for g in ALLD.values()); n_b = sum(g["bux_n"] for g in ALLD.values())
    bc = defaultdict(Decimal); dn = defaultdict(Decimal)
    for g in ALLD.values():
        for c, a in g["bux"].items(): bc[c] += a
        for c, a in g["done"].items(): dn[c] += a
    hh = Decimal(max(run_all, 1)) / 3600
    wk.append(f"📦 <b>TOTAL KESELURUHAN</b> sejak {datetime.fromtimestamp(first).strftime('%d %b %Y %H:%M')}\n{LINE}\n"
        f"⏱ Runtime <b>{dur(run_all)}</b> • mati <b>{len(stops_all)}x</b> = <b>{dur(down_all)}</b> • aktif <b>{100 * run_all / obs_all:.1f}%</b>\n"
        f"🍋 Lime <b>+{D(t_l)}</b> USDT • {n_l} klaim\n🪙 Bux {n_b} klaim: " + (" • ".join(f"{e(c)} {D(v, 6)}" for c, v in sorted(bc.items())) or "-") +
        "\n🏦 DONE: " + (" • ".join(f"{e(c)} {D(v, 6)}" for c, v in sorted(dn.items())) or "-") +
        f"\n⚖️ Per jam runtime: lime <b>+{D(t_l / hh, 6)}</b> • klaim lime <b>{float(n_l / hh):.1f}</b> • klaim bux <b>{float(n_b / hh):.1f}</b>")
    J["runtime"] = {"first": first, "run_s": run_all, "down_s": down_all, "stops": len(stops_all)}
J["days_window"] = {d: (enc(DAYS[d]) if d in DAYS else None) for d in WIN}
parts[1:1] = wk

# gabungkan bagian agar pesan sedikit
merged = []
for t in parts:
    if merged and len(merged[-1]) + len(t) + 2 <= 3600: merged[-1] += "\n\n" + t
    else: merged.append(t)
parts = merged

os.makedirs(out_dir, exist_ok=True)
for f in os.listdir(out_dir):
    if f.startswith(day + ".part"): os.remove(os.path.join(out_dir, f))
for i, t in enumerate(parts, 1):
    open(os.path.join(out_dir, f"{day}.part{i:02d}.html"), "w", encoding="utf-8").write(t)
if os.environ.get("REPORT_SAVE") == "1":
    try: vault.save("report-" + day, J)
    except Exception as ex: print("vault gagal:", ex, file=sys.stderr)
print(len(parts))
PYEOF
}

send_daily_report() { # tanggal [archive]
  local day="$1" f n
  log_gold "🌙 Membuat laporan 24 jam $day"
  REPORT_SAVE=$([ "$2" = archive ] && echo 1 || echo 0) python3 "$HELP/report.py" "$EVENTS" "$day" "$REPORT_DIR" "$DEFAULT_CURRENCY" >/dev/null 2>>"$LOG"
  for f in "$REPORT_DIR/$day".part*.html; do
    [ -f "$f" ] || continue
    tg "$(cat "$f")"
    rm -f "$f"           # teks laporan tidak ditinggal di disk; salinan lengkap ada di vault terenkripsi
    sleep 1
  done
  log_ok "📨 Laporan $day terkirim & tersimpan di vault terenkripsi"
  if [ "$2" = archive ]; then
    n=$(python3 "$HELP/vault.py" archive-events "$day" "$EVENTS" 2>>"$LOG")
    log "🗄 ${n:-0} event hari $day diarsipkan terenkripsi"
  fi
}

check_daily_report() {
  local today last
  today=$(date +%F)
  last=$(cat "$STATE_DIR/last_report_day" 2>/dev/null)
  if [ -z "$last" ]; then echo "$today" > "$STATE_DIR/last_report_day"; return; fi
  if [ "$last" != "$today" ]; then
    send_daily_report "$last" archive
    echo "$today" > "$STATE_DIR/last_report_day"
    MIDNIGHT=0
  fi
}

check_ledger() { # cek WD pending >24 jam -> DONE (tiap 60 detik)
  local now; now=$(date +%s)
  (( now - LAST_LEDGER < 60 )) && return
  LAST_LEDGER=$now
  python3 "$HELP/ledger.py" "$EVENTS" "$OUTBOX" 2>>"$LOG"
  flush_outbox
}

# ---------------------- STATUS / COUNTDOWN ---------------------------
ip_row_draw() {
  local now up; printf -v now '%(%s)T' -1
  [ -n "$IP_CUR" ] || { ip_row "[ IP: mengecek... ]"; return; }
  up=$((now - IP_SINCE)); (( up < 0 )) && up=0
  ip_row "[ IP $IP_CUR | ${IP_ORG:0:30} | ${IP_CITY:0:14} | stabil $(fmt_time "$up") ]"
}

status_wait() {
  local j now min n left wdl tleft nl="--:--:--" nb="--:--:--" a b today
  for ((j = 0; j < MONITOR_INTERVAL; j++)); do
    printf -v now '%(%s)T' -1
    a=""; b=""
    [ -f "$STATE_DIR/lane.lime.next" ] && read -r a < "$STATE_DIR/lane.lime.next"
    [ -f "$STATE_DIR/lane.bux.next" ] && read -r b < "$STATE_DIR/lane.bux.next"
    [ -n "$a" ] && nl=$(fmt_time "$a"); [ -n "$b" ] && nb=$(fmt_time "$b")
    (( MIDNIGHT <= now )) && MIDNIGHT=$(date -d "tomorrow 00:00" +%s 2>/dev/null || echo $((now + 86400)))
    printf -v today '%(%F)T' -1
    if [ "$WDT_DAY" != "$today" ]; then WDT=$(date -d "today ${WD_HOUR}:00" +%s 2>/dev/null || echo 0); WDT_DAY="$today"; fi
    tleft=$((MIDNIGHT - now)); (( tleft < 0 )) && tleft=0
    if (( WDT > now )); then wdl="WD $(fmt_time $((WDT - now)))"; else wdl="WD aktif"; fi
    stat_row "Akun:${#ACCS[@]} | RS L $nl B $nb | $wdl | Lap $(fmt_time "$tleft")"
    (( j == 0 )) && ip_row_draw
    sleep 1
  done
}

# ---------- IP & provider ----------
ip_fetch() { curl -s -m 6 https://api.ipify.org 2>/dev/null | grep -Eo '^[0-9a-fA-F:.]{3,45}$' | head -1; }
ip_info() { # ip -> IP_ORG IP_CITY
  local j; j=$(curl -s -m 8 "https://ipinfo.io/$1/json" 2>/dev/null)
  IP_ORG=$(sed -n 's/.*"org": *"\([^"]*\)".*/\1/p' <<<"$j" | head -1)
  IP_CITY=$(sed -n 's/.*"city": *"\([^"]*\)".*/\1/p' <<<"$j" | head -1)
  [ -n "$IP_ORG" ] || IP_ORG="-"; [ -n "$IP_CITY" ] || IP_CITY="-"
}
ip_save() { # ip_sebelumnya
  local o c; o=$(tr -d '"\\' <<<"$IP_ORG"); c=$(tr -d '"\\' <<<"$IP_CITY")
  printf '{"ip":"%s","org":"%s","city":"%s","since":%s,"prev":"%s"}\n' "$IP_CUR" "$o" "$c" "$IP_SINCE" "${1:--}" > "$STATE_DIR/ip.json"
}

ip_changed() { # lama baru mode(restart|norestart)
  local old="$1" new="$2" mode="$3" acc n tot=0 now s old_org="$IP_ORG"
  printf -v now '%(%s)T' -1
  IP_CUR="$new"; ip_info "$new"; IP_SINCE=$now
  echo "$new" > "$STATE_DIR/ip.cur"; ip_save "$old"; ip_row_draw
  for acc in "${ACCS[@]}"; do n=$(purge_panel_files "$acc"); tot=$((tot + n)); done
  ev ipchange - "$old" "$new"
  log_warn "🌐 IP berubah: $old → $new ($IP_ORG) • file panel terhapus: $tot"
  tg "🌐 <b>IP BERUBAH</b> 🌐
$LINE
📍 Lama : <code>$(esc "$old")</code> • $(esc "$old_org")
📍 Baru : <code>$(esc "$new")</code> • <b>$(esc "$IP_ORG")</b> • $(esc "$IP_CITY")
🗑 File panel dihapus: <b>$tot</b> (panel_config.json, panel_config.sig, panel_verified.json)
$( [ "$mode" = restart ] && [ "$IP_CHANGE_RESTART" = 1 ] && echo '🔄 Semua sesi di-restart bertahap agar login baru' || echo '✅ Login baru dilakukan saat program dibuka berikutnya' )
🕒 $(now_hms)"
  if [ "$mode" = restart ] && [ "$IP_CHANGE_RESTART" = 1 ] && (( now - LAST_IPWAVE > 120 )); then
    LAST_IPWAVE=$now; echo "$now" > "$STATE_DIR/ipwave"   # tiap jalur membuka ulang pane-nya bertahap
  fi
}

ip_check() {
  local now new new2 old
  printf -v now '%(%s)T' -1
  (( now - LAST_IPCHK < IP_CHECK_INTERVAL )) && return
  LAST_IPCHK=$now
  new=$(ip_fetch); [ -n "$new" ] || return
  if [ -z "$IP_CUR" ]; then
    old=""; [ -f "$STATE_DIR/ip.cur" ] && read -r old < "$STATE_DIR/ip.cur"
    IP_CUR="$new"; ip_info "$new"; IP_SINCE=$now; echo "$new" > "$STATE_DIR/ip.cur"; ip_save "$old"
    if [ -n "$old" ] && [ "$old" != "$new" ]; then ip_changed "$old" "$new" norestart; fi
    ip_row_draw; return
  fi
  [ "$new" = "$IP_CUR" ] && return
  sleep 3; new2=$(ip_fetch)
  [ "$new2" = "$new" ] || return
  ip_changed "$IP_CUR" "$new" restart
}

# ---------- bot Telegram ----------
process_cmdq() { # kind (lime|bux)
  local lane="$1" f="$STATE_DIR/cmdq.$1" tmp="$STATE_DIR/cmdq.$1.run" k arg s
  [ -s "$f" ] || return
  mv "$f" "$tmp"
  while IFS='|' read -r -u 3 k arg; do
    case "$k" in
      wd) if [ "$arg" = ALL ]; then check_wd_schedule force; else wd_run_one "$arg"; fi ;;
      restart)
        s=$(sess_name "$arg"); has_session "$s" || continue
        restart_pane "$arg" "$lane" manual "♻️ <b>RESTART MANUAL</b>
$LINE
👤 Akun : <code>$(esc "$arg")</code> ($lane)
🔄 Pane $lane dibuka ulang atas permintaanmu
🕒 $(now_hms)" ;;
    esac
  done 3< "$tmp"
  rm -f "$tmp"
}

bot_start() { # bot Telegram = proses sendiri (long polling), tetap responsif walau manager sibuk
  python3 "$HELP/tgbot.py" daemon >>"$LOG" 2>&1 &
  BOT_PID=$!; echo "$BOT_PID" > "$STATE_DIR/bot.pid"
}
bot_supervise() { kill -0 "$BOT_PID" 2>/dev/null || { log_warn "🤖 Bot Telegram berhenti, dijalankan ulang"; bot_start; }; }

lane_status() { # kind
  local kind="$1" acc s min=$RESTART_INTERVAL now left t0
  printf -v now '%(%s)T' -1
  for acc in "${ACCS[@]}"; do
    s="${acc//./_}"; s="${s//:/_}"
    t0=${START_TS["$s:$kind"]}; [ -n "$t0" ] || continue
    left=$((RESTART_INTERVAL - (now - t0))); (( left < min )) && min=$left
  done
  (( min < 0 )) && min=0
  echo "$min" > "$STATE_DIR/lane.$kind.next"
}

lane_ipwave() { # kind : IP berubah -> buka ulang pane jalur ini (login baru), bertahap
  local kind="$1" w=0 acc s
  [ -f "$STATE_DIR/ipwave" ] && read -r w < "$STATE_DIR/ipwave"
  (( w > LAST_IPWAVE_SEEN )) || return 0
  LAST_IPWAVE_SEEN=$w
  log_warn "🌐 IP berubah → pane $kind dibuka ulang (login baru)"
  for acc in "${ACCS[@]}"; do
    s=$(sess_name "$acc"); has_session "$s" || continue
    restart_pane "$acc" "$kind" ipchange ""
  done
  tg "✅ <b>Pane $kind</b> dibuka ulang karena IP berubah (${#ACCS[@]} akun) 🕒 $(now_hms)"
}

lane_main() { # kind : jalur kerja paralel (lime / bux)
  local kind="$1" cnt=0
  LANE="$kind"; MON_IDX=0; LAST_START_END=0
  trap 'lane_cleanup' EXIT; trap 'exit 0' TERM INT
  [ -f "$STATE_DIR/ipwave" ] && read -r LAST_IPWAVE_SEEN < "$STATE_DIR/ipwave"
  while kill -0 "$SUP_PID" 2>/dev/null; do
    mapfile -t ACCS < <(list_accounts)
    "lane_monitor" "$kind"
    lane_ipwave "$kind"
    process_cmdq "$kind"
    if [ "$kind" = bux ]; then check_ledger; check_wd_schedule; fi
    (( cnt % 2 == 0 )) && lane_sync "$kind"
    lane_status "$kind"
    act "siaga"
    cnt=$((cnt + 1)); sleep "$MONITOR_INTERVAL"
  done
}
lane_cleanup() { (( WD_BATCH )) && rm -f "$WDLOCK"; return 0; }

lane_supervise() { # supervisor: jalur mati mendadak -> nyalakan lagi
  local k
  for k in lime bux; do
    kill -0 "${LANE_PID[$k]}" 2>/dev/null && continue
    log_err "⚠ Jalur $k berhenti, dijalankan ulang"
    tg "⚠️ <b>Jalur $k berhenti mendadak</b> — dijalankan ulang otomatis 🕒 $(now_hms)"
    ( lane_main "$k" ) & LANE_PID[$k]=$!
  done
}

refresh_accounts() {
  local sig new a b found
  mapfile -t ACCS < <(list_accounts)
  sig="${ACCS[*]}"
  if [ "$sig" != "$ACC_SIG" ]; then
    if [ -n "$ACC_SIG" ] || [ "$1" = first ]; then
      new=""
      for a in "${ACCS[@]}"; do
        found=0; for b in $ACC_SIG; do [ "$a" = "$b" ] && found=1; done
        (( found )) || new+=" • <code>$(esc "$a")</code>"$'\n'
      done
      if [ "$1" != first ] && [ -n "$new" ]; then
        log_gold "📂 Folder baru terdeteksi: $(tr -d '\n' <<<"${new//<code>/}")"
        tg "📂 <b>FOLDER BARU TERDETEKSI</b>
$LINE
$new⏳ Sesi dibuat sebentar lagi (jeda ${START_GAP}s antar pane)
🕒 $(now_hms)"
        last_sync=0
      fi
    fi
    ACC_SIG="$sig"
  fi
}

# ------------------------------ MAIN ---------------------------------
install_helpers

if [ "$1" = "report" ]; then
  send_daily_report "${2:-$(date +%F)}"
  exit 0
fi
if [ "$1" = "vault" ]; then
  shift; python3 "$HELP/vault.py" "$@"
  exit $?
fi
python3 "$HELP/vault.py" init 2>>"$LOG"

command -v tmux >/dev/null || { echo "tmux belum terinstall: pkg install tmux"; exit 1; }
command -v curl >/dev/null || { echo "curl belum terinstall: pkg install curl"; exit 1; }
command -v python3 >/dev/null || { echo "python belum terinstall: pkg install python"; exit 1; }
command -v termux-wake-lock >/dev/null && termux-wake-lock

if [ ! -d "$BASE_DIR" ]; then
  echo "Folder tidak ketemu: $BASE_DIR"
  echo "Jalankan dulu: termux-setup-storage"
  exit 1
fi

refresh_accounts first

if [ "$1" = "folders" ]; then
  echo "BASE_DIR = $BASE_DIR"; printf ' • %s\n' "${ACCS[@]}"; exit 0
fi
if [ "$1" = "wdnow" ]; then
  if mgr_alive; then
    echo "wd|ALL" >> "$STATE_DIR/cmdq.bux"
    echo "✔ Manager sedang berjalan: permintaan WD semua akun dititipkan ke manager (hasil dikirim ke Telegram)."
    echo "  Semua claim BUX dimatikan dulu, WD diproses, lalu claim jalan lagi setelah selesai."
    exit 0
  fi
  check_wd_schedule force
  flush_outbox
  exit 0
fi

# hanya satu manager utama yang boleh berjalan
if mgr_alive; then
  echo "✘ Manager sudah berjalan (PID $(cat "$PIDFILE")). Hentikan dulu: pkill -f $SELF"
  exit 1
fi
IS_MAIN=1; echo $$ > "$PIDFILE"; SUP_PID=$$

# pencatatan runtime script (tahan mati mendadak: heartbeat dipakai menandai kapan terakhir hidup)
RTINFO=$(python3 "$HELP/vault.py" rt-start 2>>"$LOG")
read -r _gap _how _runno <<<"$RTINFO"
printf '%(%s)T' -1 > "$STATE_DIR/hb"

# ringan: prioritas rendah untuk manager, riwayat tmux kecil
command -v renice >/dev/null && renice -n 5 -p $$ >/dev/null 2>&1
tmux start-server 2>/dev/null; tmux set-option -g history-limit "$HIST_LIMIT" 2>/dev/null
# bersihkan bot lama yang tersisa
[ -f "$STATE_DIR/bot.pid" ] && { read -r _ob < "$STATE_DIR/bot.pid"; kill "$_ob" 2>/dev/null; }

layout
loading_boot
log_gold "👑 Revil Tmux Manager v7 mulai • BASE_DIR=$BASE_DIR • ${#ACCS[@]} folder • run ke-${_runno:-1}"
_names=""
for _a in "${ACCS[@]}"; do _names+=" • <code>$(esc "$_a")</code>"$'\n'; done
_stop=""
if [ "${_gap:-0}" -gt 0 ] 2>/dev/null; then _stop="🔌 Script sebelumnya berhenti <b>$((_gap / 60)) menit $((_gap % 60)) dtk</b> ($(esc "${_how:--}"))
"; fi
tg "👑 <b>REVIL TMUX MANAGER v7</b> 👑
$LINE
✨ Manager online &amp; siap tempur (run ke-${_runno:-1})
${_stop}🧩 Tiap sesi: pane <b>lime</b> + pane <b>bux</b> (jalur paralel)
🏦 WD otomatis jam <b>${WD_HOUR}:00</b> • WD manual: /wd
🤖 Ketik /menu di sini untuk semua kontrol
📂 Akun terdeteksi (<b>${#ACCS[@]}</b>):
$_names🕒 $(now_hms)
$(rnd FUN_UP)"

[ -f "$STATE_DIR/last_report_day" ] || date +%F > "$STATE_DIR/last_report_day"
export MANAGER_PID=$$
bot_start
ip_check                     # baseline IP (file panel dihapus jika IP berubah saat manager mati)
sync_sessions                # buat semua sesi + 2 pane
last_sync=0
( lane_main lime ) & LANE_PID[lime]=$!
( lane_main bux ) & LANE_PID[bux]=$!

while true; do
  status_wait
  printf '%(%s)T' -1 > "$STATE_DIR/hb"
  refresh_accounts
  ip_check
  bot_supervise
  lane_supervise
  check_daily_report
  printf -v _now '%(%s)T' -1
  if (( _now - last_sync >= CHECK_INTERVAL )); then
    sync_sessions
    printf -v last_sync '%(%s)T' -1
  fi
done
