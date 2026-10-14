#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
PANDA MANAGER v2  -  tmux manager untuk Pandapucet.php (Termux)

Butuh   : pkg install python tmux php   (tanpa pip)
Jalankan: tmux new -s pandamgr 'python pandamgr.py'
Cek     : python pandamgr.py --cek
Stop    : python pandamgr.py --stop      (tutup semua sesi akun)
"""
import os, re, sys, time, json, zlib, base64, shlex, shutil, hashlib, threading, queue, subprocess
import urllib.request, urllib.parse
from collections import deque
from datetime import datetime, timedelta
from pathlib import Path

# ════════════════════════ CONFIG ════════════════════════
TG_TOKEN   = "8874284172:AAFmtBszqpbqykF-fu9k58sy-V4qz4__ZmE"
TG_CHAT    = "8292649520"
SOLVER_KEY = "8ea7f806170fa5609010c41c31d60b88"
DEFAULT_PASS = "revil1234"                  # password sama semua akun
MAX_LOGIN_TRY = 3                           # "User not found": hapus config_panda.json + run ulang, maks 3x
CONFIG_FILE  = "config_panda.json"
NOTE_COOLDOWN = 300                         # detik, jeda notif sama per pane

_home = Path.home()
BASE = next((p for p in (_home / "storage/downloads/bot/akun",
                         Path("/storage/emulated/0/Download/bot/akun")) if p.is_dir()),
            Path("/storage/emulated/0/Download/bot/akun"))
SCRIPT      = "Pandapucet.php"
EXTRA_FILES = ["vie.js"]                    # ikut disalin ke folder akun kalau belum ada
COINS = ["doge", "usdt", "eth", "ltc", "bch", "dash", "trx", "bnb", "sol", "xrp", "ada", "ton"]
PER_SESSION   = 4                           # 12 koin = 3 sesi x 4 pane
RESTART_HOURS = 2                           # kill semua sesi lalu buat ulang
POLL          = 8                           # detik, cek isi pane
SCAN          = 60                          # detik, cek folder akun baru / sesi hilang
START_GAP     = 0                           # tanpa jeda antar pane / sesi
GRACE         = 30                          # detik abaikan aturan setelah pane di-reset
KEEP_DAYS     = 8                           # detail harian disimpan, total keseluruhan tetap
STORE = _home / ".pm2v2" / ".d"             # di dalam home Termux (tidak terlihat file manager)
_SECRET = b"pm2v2::panda::" + hashlib.sha256(str(_home).encode()).digest()

# ════════════════════════ UTIL ════════════════════════
def tmux(*a):
    try:
        r = subprocess.run(["tmux", *a], capture_output=True, text=True, timeout=15)
        return r.returncode, r.stdout, r.stderr
    except Exception as e:
        return 1, "", str(e)

def safe(name):
    return re.sub(r"[.:\s]", "-", name)

def today(off=0):
    return (datetime.now() + timedelta(days=off)).strftime("%Y-%m-%d")

def dur(sec):
    sec = int(max(0, sec)); h, r = divmod(sec, 3600); m, s = divmod(r, 60)
    return f"{h}j {m:02d}m" if h else (f"{m}m {s:02d}s" if m else f"{s}s")

def clock(sec):
    sec = int(max(0, sec)); h, r = divmod(sec, 3600); m, s = divmod(r, 60)
    return f"{h:02d}:{m:02d}:{s:02d}"

def amt(x):
    return (f"{x:.8f}".rstrip("0").rstrip(".")) or "0"

def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

def launch_cmd(d, delay=0):
    pre = f"sleep {delay}; " if delay else ""
    return f"{pre}clear; cd {shlex.quote(str(d))} && exec php {SCRIPT}"

# ════════════════════════ DATA (terenkripsi) ════════════════════════
def _ks(n):
    out, c = bytearray(), 0
    while len(out) < n:
        out += hashlib.sha256(_SECRET + c.to_bytes(4, "big")).digest(); c += 1
    return bytes(out[:n])

def _enc(obj):
    raw = zlib.compress(json.dumps(obj, separators=(",", ":")).encode())
    return base64.b85encode(bytes(a ^ b for a, b in zip(raw, _ks(len(raw)))))

def _dec(b):
    raw = base64.b85decode(b)
    return json.loads(zlib.decompress(bytes(a ^ b for a, b in zip(raw, _ks(len(raw))))))

class Store:
    def __init__(s):
        s.lock = threading.RLock()
        s.d = {"first": time.time(), "days": {}, "blocked": {}, "stops": 0, "down": 0.0,
               "beat": 0.0, "rep_day": "",
               "total": {"ok": 0, "bad": 0, "amt": {}, "resets": 0}}
        try:
            s.d.update(_dec(STORE.read_bytes()))
        except Exception:
            pass

    def save(s):
        with s.lock:
            try:
                STORE.parent.mkdir(parents=True, exist_ok=True)
                tmp = STORE.with_suffix(".t"); tmp.write_bytes(_enc(s.d)); os.replace(tmp, STORE)
            except Exception:
                pass

    def day(s, key=None):
        key = key or today()
        with s.lock:
            dd = s.d["days"].setdefault(key, {"acc": {}, "resets": 0, "rec_n": 0, "rec_sum": 0.0,
                                              "rec_max": 0.0, "why": {}, "up": 0.0, "notes": {}})
            for k in sorted(s.d["days"])[:-KEEP_DAYS]:
                del s.d["days"][k]
            return dd

    def claims(s, folder, coin, ok, bad, amount):
        with s.lock:
            row = s.day()["acc"].setdefault(folder, {}).setdefault(coin, [0, 0, 0.0])
            row[0] += ok; row[1] += bad; row[2] += amount
            t = s.d["total"]; t["ok"] += ok; t["bad"] += bad
            t["amt"][coin] = t["amt"].get(coin, 0.0) + amount

    def reset(s, why):
        with s.lock:
            dd = s.day(); dd["resets"] += 1; dd["why"][why] = dd["why"].get(why, 0) + 1
            s.d["total"]["resets"] += 1

    def note(s, kind):
        with s.lock:
            n = s.day().setdefault("notes", {}); n[kind] = n.get(kind, 0) + 1

    def recovery(s, sec):
        with s.lock:
            dd = s.day(); dd["rec_n"] += 1; dd["rec_sum"] += sec; dd["rec_max"] = max(dd["rec_max"], sec)

    def beat(s):
        with s.lock:
            now = time.time(); lb = s.d["beat"]
            if lb:
                gap = now - lb
                if gap > POLL * 4:
                    s.d["stops"] += 1; s.d["down"] += gap
                else:
                    s.day()["up"] += gap
            s.d["beat"] = now

    def runtime(s):
        return time.time() - s.d["first"] - s.d["down"]

    # ── agregat ──
    def sums(s, key):
        dd = s.d["days"].get(key)
        ok = bad = 0; coins = {}; per = {}
        if dd:
            for f, cs in dd["acc"].items():
                for c, (o, b, a) in cs.items():
                    ok += o; bad += b; coins[c] = coins.get(c, 0.0) + a
                    p = per.setdefault(f, [0, 0]); p[0] += o; p[1] += b
        return ok, bad, coins, per, dd

# ════════════════════════ CREDS ════════════════════════
def load_creds():
    creds = {}
    try:
        txt = (BASE / "data.txt").read_text(errors="ignore")
    except Exception:
        return creds
    for line in txt.splitlines():
        line = line.strip()
        if "@" not in line:
            continue
        parts = [x.strip() for x in re.split(r"\s*[|,;\t]\s*", line, maxsplit=2)]
        if len(parts) < 2 or "@" not in parts[0]:
            parts = line.split(None, 2)
        if len(parts) >= 2 and "@" in parts[0]:
            creds[parts[0].split("@")[0].lower()] = (parts[0], parts[1])
    return creds

def email_for(folder):
    """Nama folder tanpa domain -> @gmail.com; kalau sudah ada domain (ada @) pakai apa adanya."""
    return folder if "@" in folder else folder + "@gmail.com"

# ════════════════════════ ATURAN LAYAR ════════════════════════
RX_BLOCK  = re.compile(r"login\s+gagal\W{0,4}\s*user\s+not\s+found", re.I)
RX_SEC    = re.compile(r"(?:(\d\d:\d\d:\d\d)\s+)?(\w+)\s+start:\s*security check failed or expired", re.I)
RX_UNK    = re.compile(r"(?:(\d\d:\d\d:\d\d)\s+)?(\w+)\s+claim:\s*unknown", re.I)
RX_TOKEN  = re.compile(r"paste token manual", re.I)
RX_UNSOLV = re.compile(r"(?:\[(\d\d:\d\d:\d\d)\]\s*)?\S?\s*turnstile gagal.{0,80}?error_captcha_unsolvable", re.I)
RX_CLAIMS = re.compile(r"Claims\s*:\s*\S?\s*(\d+)\s+\S?\s*(\d+)")
RX_REWARD = re.compile(r"Reward\s*:\s*([0-9]+\.?[0-9]*)")
RX_LAST   = re.compile(r"Last\s*:\s*([0-9]+\.[0-9]+)")
BOXCH     = re.compile(r"[│║┃╎┆]")

PROMPTS = [
    ("email",     re.compile(r"email\s*:", re.I)),
    ("password",  re.compile(r"password\s*:", re.I)),
    ("solver",    re.compile(r"solver\s*key\s*:", re.I)),
    ("coin",      re.compile(r"pilih\s+coin\s*\[[^\]]*\]\s*:", re.I)),
    ("faucetpay", re.compile(r"faucetpay\s*\[[^\]]*\]\s*:", re.I)),
]

class Pane:
    def __init__(s, pid, folder, sess, coin, baseline=0):
        s.pid, s.folder, s.sess, s.coin = pid, folder, sess, coin
        s.num = COINS.index(coin) + 1
        s.ok = baseline; s.bad = baseline          # None = ambil baseline dari layar
        s.grace = 0.0; s.last_reset = 0.0; s.reset_at = None
        s.crashes = 0; s.epoch = 0; s.seen = set(); s.sent = {}
        s.warned = set(); s.dead = False; s.started = time.time()

# ════════════════════════ TELEGRAM ════════════════════════
class TG:
    def __init__(s):
        s.on = TG_TOKEN and not TG_TOKEN.startswith("ISI_")
        s.q = queue.Queue(); s.handler = None

    def api(s, method, params, timeout=35):
        url = f"https://api.telegram.org/bot{TG_TOKEN}/{method}"
        req = urllib.request.Request(url, urllib.parse.urlencode(params).encode())
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode())

    def send(s, text):
        if s.on:
            s.q.put(text)

    def _sender(s):
        while True:
            text = s.q.get()
            for i in range(0, len(text), 3800):
                for _ in range(3):
                    try:
                        s.api("sendMessage", {"chat_id": TG_CHAT, "text": text[i:i + 3800],
                                              "parse_mode": "HTML", "disable_web_page_preview": "true"}, 15)
                        break
                    except Exception:
                        time.sleep(3)

    def _poller(s):
        off = 0
        while True:
            try:
                r = s.api("getUpdates", {"offset": off, "timeout": 25})
                for u in r.get("result", []):
                    off = u["update_id"] + 1
                    m = u.get("message") or {}
                    if str((m.get("chat") or {}).get("id")) != str(TG_CHAT):
                        continue
                    t = (m.get("text") or "").strip()
                    if t.startswith("/"):
                        cmd, *args = t.split()
                        rep = s.handler(cmd.split("@")[0].lower(), args)
                        if rep:
                            s.send(rep)
            except Exception:
                time.sleep(5)

    def start(s):
        if s.on:
            threading.Thread(target=s._sender, daemon=True).start()
            threading.Thread(target=s._poller, daemon=True).start()

# ════════════════════════ MANAGER ════════════════════════
class Manager:
    def __init__(s):
        s.st = Store(); s.tg = TG(); s.tg.handler = s.on_cmd
        s.panes = {}; s.events = deque(maxlen=40); s.actions = queue.Queue()
        s.creds = {}; s.last_restart = time.time(); s.t0 = time.time(); s.cycle = 0
        s.skipped = set(); s.attempts = {}; s.notified_block = set(); s.notes_at = {}

    # ── log & notif ──
    def ev(s, msg):
        s.events.append(f"{datetime.now():%H:%M:%S} {msg}")

    # ── folder & sesi ──
    def folders(s):
        try:
            return sorted(d.name for d in BASE.iterdir() if d.is_dir() and not d.name.startswith("."))
        except Exception:
            return []

    def active_folders(s):
        return [f for f in s.folders() if f not in s.st.d["blocked"]]

    def sessions(s):
        rc, out, _ = tmux("list-sessions", "-F", "#{session_name}")
        return set(out.split()) if rc == 0 else set()

    def ensure_files(s, folder):
        d = BASE / folder
        for fn in [SCRIPT] + EXTRA_FILES:
            if not (d / fn).exists() and (BASE / fn).exists():
                try: shutil.copy2(BASE / fn, d / fn)
                except Exception: pass
        return (d / SCRIPT).exists()

    def style(s, sess):
        for k, v in (("mouse", "on"), ("status-style", "bg=colour234,fg=colour45"),
                     ("status-left", " #[fg=colour213,bold]#S #[default]"),
                     ("status-right", "#[fg=colour245]%H:%M ")):
            tmux("set-option", "-t", sess, k, v)
        for k, v in (("remain-on-exit", "on"), ("pane-border-status", "top"),
                     ("pane-border-format", " #[fg=colour213,bold]#{pane_title}#[default] "),
                     ("pane-border-style", "fg=colour238"), ("pane-active-border-style", "fg=colour45")):
            tmux("set-option", "-w", "-t", sess, k, v)

    def create_session(s, folder, n, delay0=0):
        sess = f"{safe(folder)}_{n}"; d = BASE / folder
        coins = COINS[(n - 1) * PER_SESSION: n * PER_SESSION]
        pids = []
        for i, coin in enumerate(coins):
            cmd = launch_cmd(d, delay0 + i * START_GAP)
            if i == 0:
                rc, out, err = tmux("new-session", "-d", "-s", sess, "-x", "100", "-y", "48",
                                    "-P", "-F", "#{pane_id}", cmd)
            else:
                rc, out, err = tmux("split-window", "-t", sess, "-P", "-F", "#{pane_id}", cmd)
                tmux("select-layout", "-t", sess, "tiled")
            if rc != 0:
                s.ev(f"gagal buat {sess}: {err.strip()[:30]}"); return
            pid = out.strip(); pids.append(pid)
            tmux("select-pane", "-t", pid, "-T", coin)
            s.panes[pid] = Pane(pid, folder, sess, coin)
        tmux("select-layout", "-t", sess, "tiled")
        s.style(sess)

    def launch_missing(s):
        have = s.sessions(); idx = 0; made = 0
        for f in s.active_folders():
            if not s.ensure_files(f):
                if f not in s.skipped:
                    s.skipped.add(f); s.ev(f"skip {f}: {SCRIPT} tidak ada")
                continue
            for n in range(1, len(COINS) // PER_SESSION + 1):
                if f"{safe(f)}_{n}" not in have:
                    s.create_session(f, n, idx * PER_SESSION * START_GAP); idx += 1; made += 1
        if made:
            s.ev(f"buat {made} sesi")
        return made

    def kill_folder(s, folder):
        for n in range(1, len(COINS) // PER_SESSION + 1):
            tmux("kill-session", "-t", f"={safe(folder)}_{n}")
        for pid in [k for k, p in s.panes.items() if p.folder == folder]:
            del s.panes[pid]

    def kill_all(s):
        for f in s.folders():
            s.kill_folder(f)
        s.panes.clear()

    def adopt(s):
        rc, out, _ = tmux("list-panes", "-a", "-F", "#{session_name}\t#{pane_id}\t#{pane_title}")
        if rc != 0:
            s.panes.clear(); return
        fmap = {safe(f): f for f in s.folders()}; live = set()
        for line in out.splitlines():
            try: sess, pid, title = line.split("\t")
            except ValueError: continue
            m = re.fullmatch(r"(.+)_(\d)", sess)
            if not m or m.group(1) not in fmap or title.lower() not in COINS:
                continue
            live.add(pid)
            if pid not in s.panes:
                s.panes[pid] = Pane(pid, fmap[m.group(1)], sess, title.lower(), baseline=None)
        for pid in list(s.panes):
            if pid not in live:
                del s.panes[pid]

    def unblock_all(s):
        with s.st.lock:
            s.st.d["blocked"].clear()
        s.attempts.clear(); s.st.save()

    def restart_all(s, why="jadwal"):
        s.unblock_all()
        s.kill_all(); time.sleep(1); s.launch_missing()
        s.last_restart = time.time(); s.ev(f"restart ({why})")
        s.tg.send(f"♻️ <b>Restart {esc(why)}</b> — sesi dibuat ulang")

    # ── aksi dari pane ──
    def login_fail(s, folder):
        n = s.attempts.get(folder, 0) + 1
        s.attempts[folder] = n
        if n > MAX_LOGIN_TRY:
            s.block_folder(folder, f"User not found {MAX_LOGIN_TRY}x"); return
        s.kill_folder(folder)
        try:
            (BASE / folder / CONFIG_FILE).unlink()
        except Exception:
            pass
        s.ev(f"{folder[:12]} login gagal, ulang {n}/{MAX_LOGIN_TRY}")
        s.launch_missing()

    def block_folder(s, folder, why):
        with s.st.lock:
            s.st.d["blocked"][folder] = {"at": time.time(), "why": why}
        s.kill_folder(folder); s.st.save(); s.ev(f"BLOCK {folder}")
        if folder not in s.notified_block:
            s.notified_block.add(folder)
            s.tg.send(f"🚫 <b>{esc(folder)}</b> belum terdaftar (<i>User not found</i>, sudah dicoba "
                      f"{MAX_LOGIN_TRY}x dengan hapus {CONFIG_FILE}).\nSesi ditutup. "
                      f"Dicoba lagi otomatis saat run ulang, atau /unblock {esc(folder)}")

    def reset_pane(s, p, why):
        now = time.time()
        gap = min(20 * (2 ** p.crashes), 600) if why == "mati" else 20
        if now - p.last_reset < gap:
            return
        if why == "mati":
            p.crashes += 1
        tmux("respawn-pane", "-k", "-t", p.pid, launch_cmd(BASE / p.folder))
        tmux("clear-history", "-t", p.pid)
        p.last_reset = now; p.grace = now + GRACE; p.reset_at = now
        p.epoch += 1; p.sent = {}; p.ok = 0; p.bad = 0
        s.st.reset(why); s.ev(f"reset {p.folder[:10]}/{p.coin} ({why})")

    def value_for(s, kind, p):
        c = s.creds.get(p.folder.lower())      # data.txt (opsional) menimpa default
        return {"email": lambda: email_for(p.folder),
                "password": lambda: c[1] if c else DEFAULT_PASS,
                "solver": lambda: SOLVER_KEY, "coin": lambda: str(p.num),
                "faucetpay": lambda: ""}[kind]()

    def handle_prompt(s, p, last):
        for kind, rx in PROMPTS:
            if not rx.fullmatch(last):
                continue
            now = time.time()
            hist = [t for t in p.sent.get(kind, []) if now - t < 120]
            if hist and now - hist[-1] < 4:
                return True
            if len(hist) >= 4:
                if kind not in p.warned:
                    p.warned.add(kind)
                    s.tg.send(f"⚠️ <b>{esc(p.folder)}/{p.coin}</b> prompt “{kind}” berulang, dihentikan.")
                return True
            val = s.value_for(kind, p)
            if val is None:
                if kind not in p.warned:
                    p.warned.add(kind)
                    s.tg.send(f"⚠️ <b>{esc(p.folder)}</b> tidak ada di data.txt (butuh {kind}).")
                return True
            if val:
                tmux("send-keys", "-t", p.pid, "-l", "--", val)
            tmux("send-keys", "-t", p.pid, "Enter")
            hist.append(now); p.sent[kind] = hist
            return True
        return False

    def dedupe(s, p, sig, has_ts):
        key = sig if has_ts else (p.epoch, sig)
        if key in p.seen:
            return False
        if len(p.seen) > 200:
            p.seen.clear()
        p.seen.add(key); return True

    def evaluate(s, p, raw):
        lines = [l.rstrip() for l in raw.split("\n")]
        ne = [l for l in lines if l.strip()]
        last = ne[-1].strip() if ne else ""
        flat = re.sub(r"\s+", " ", " ".join(BOXCH.sub(" ", l) for l in lines))
        now = time.time()

        # 2. folder belum terdaftar
        if RX_BLOCK.search(flat):
            s.login_fail(p.folder); return
        # prompt interaktif
        if s.handle_prompt(p, last):
            return
        # reset
        if now >= p.grace:
            if RX_TOKEN.search("\n".join(ne[-3:])):
                s.reset_pane(p, "captcha"); return
            m = RX_UNSOLV.search(flat)
            if m and s.dedupe(p, m.group(0), bool(m.group(1))):
                s.reset_pane(p, "captcha"); return
            # sisanya: hanya notifikasi, tanpa reset
            for rx, kind, label in ((RX_SEC, "security", "Security check failed or expired"),
                                    (RX_UNK, "unknown", "claim: unknown")):
                m = rx.search(flat)
                if m and s.dedupe(p, m.group(0), bool(m.group(1))):
                    s.st.note(kind)
                    key = (p.pid, kind)
                    if now - s.notes_at.get(key, 0) >= NOTE_COOLDOWN:
                        s.notes_at[key] = now
                        s.tg.send(f"⚠️ <b>{esc(p.folder)}</b> / {p.coin.upper()}: {label}")
                    s.ev(f"{p.folder[:10]}/{p.coin} {kind}")
        # statistik claim
        m = RX_CLAIMS.search(flat)
        if m:
            ok, bad = int(m.group(1)), int(m.group(2))
            if p.ok is None:
                p.ok, p.bad = ok, bad; return
            d_ok = ok - p.ok if ok >= p.ok else ok
            d_bad = bad - p.bad if bad >= p.bad else bad
            p.ok, p.bad = ok, bad
            if d_ok or d_bad:
                r = RX_REWARD.search(flat) or RX_LAST.search(flat)
                s.st.claims(p.folder, p.coin, d_ok, d_bad, d_ok * (float(r.group(1)) if r else 0.0))
            if d_ok:
                s.attempts.pop(p.folder, None)
                p.crashes = 0
                if p.reset_at:
                    s.st.recovery(now - p.reset_at); p.reset_at = None

    def poll(s):
        rc, out, _ = tmux("list-panes", "-a", "-F", "#{pane_id} #{pane_dead}")
        if rc != 0:
            return
        state = dict(l.split() for l in out.splitlines() if len(l.split()) == 2)
        for p in list(s.panes.values()):
            if p.pid not in s.panes:
                continue
            if p.pid not in state:
                del s.panes[p.pid]; continue
            p.dead = state[p.pid] == "1"
            rc, txt, _ = tmux("capture-pane", "-p", "-J", "-t", p.pid, "-S", "-30")
            if rc == 0:
                s.evaluate(p, txt)
            if p.pid in s.panes and state[p.pid] == "1":
                s.reset_pane(p, "mati")

    # ── perintah Telegram ──
    def on_cmd(s, cmd, args):
        arg = args[0] if args else ""
        if cmd in ("/start", "/help"):
            return ("<b>Panda Manager v2</b>\n/status  /laporan  /kemarin  /rekap\n/balance  /blocked\n"
                    "/unblock &lt;folder&gt;  /reset &lt;folder&gt;  /restart")
        if cmd == "/status":   return s.status_text()
        if cmd == "/laporan":  return s.report(today(), "HARI INI")
        if cmd == "/kemarin":  return s.report(today(-1), "KEMARIN")
        if cmd == "/rekap":    return s.recap()
        if cmd == "/balance":  return s.balance()
        if cmd == "/blocked":
            b = s.st.d["blocked"]
            return "🚫 " + ", ".join(esc(x) for x in b) if b else "Tidak ada folder yang diblokir."
        if cmd in ("/unblock", "/reset") and arg:
            s.actions.put((cmd[1:], arg)); return f"OK: {cmd[1:]} {esc(arg)}"
        if cmd == "/restart":
            s.actions.put(("restart", "")); return "OK: restart semua sesi"
        return None

    def do_actions(s):
        while not s.actions.empty():
            act, arg = s.actions.get()
            if act == "unblock":
                with s.st.lock: s.st.d["blocked"].pop(arg, None)
                s.attempts.pop(arg, None)
                s.st.save(); s.launch_missing()
            elif act == "reset" and arg in s.folders():
                s.kill_folder(arg); time.sleep(1); s.launch_missing()
            elif act == "restart":
                s.restart_all("manual")

    def alive_counts(s):
        per = {}
        for p in s.panes.values():
            per.setdefault(p.folder, [0, 0])[1] += 1
            if not p.dead: per[p.folder][0] += 1
        return per

    def status_text(s):
        ok, bad, _, _, dd = s.st.sums(today())
        return (f"<b>Status</b>\nAkun aktif: {len(s.active_folders())}  Pane: {len(s.panes)}\n"
                f"Blocked: {len(s.st.d['blocked'])}\nClaim hari ini: ✓ {ok}  ✗ {bad}\n"
                f"Reset hari ini: {dd['resets'] if dd else 0}\n"
                f"Restart berikutnya: {clock(s.last_restart + RESTART_HOURS * 3600 - time.time())}\n"
                f"Runtime: {dur(s.st.runtime())}")

    def report(s, key, title):
        ok, bad, coins, per, dd = s.st.sums(key)
        if not dd:
            return f"Belum ada data untuk {key}."
        pct = f"{ok * 100 / (ok + bad):.1f}%" if ok + bad else "-"
        L = [f"📊 <b>LAPORAN {title}</b> ({key})", f"✓ {ok}   ✗ {bad}   ({pct})", ""]
        L += [f"{c.upper():<5} {amt(v)}" for c, v in sorted(coins.items()) if v] or ["(belum ada reward)"]
        L += ["", "— per akun —"]
        L += [f"{esc(f)[:16]:<16} ✓{o} ✗{b}" for f, (o, b) in sorted(per.items())]
        avg = dd["rec_sum"] / dd["rec_n"] if dd["rec_n"] else 0
        why = ", ".join(f"{k} {v}" for k, v in dd["why"].items()) or "-"
        notes = ", ".join(f"{k} {v}" for k, v in dd.get("notes", {}).items()) or "-"
        L += ["", f"♻️ reset {dd['resets']}  ({why})", f"⚠️ notif: {notes}",
              f"pulih rata² {int(avg)}s, maks {int(dd['rec_max'])}s",
              f"⏱ runtime {dur(dd['up'])}",
              f"total runtime {dur(s.st.runtime())}, berhenti {s.st.d['stops']}x ({dur(s.st.d['down'])})"]
        bl = s.st.d["blocked"]
        if bl: L.append("🚫 blocked: " + ", ".join(esc(x) for x in bl))
        return "<pre>" + "\n".join(L) + "</pre>"

    def recap(s):
        L = ["📅 <b>REKAP 7 HARI</b>"]
        for i in range(6, -1, -1):
            k = today(-i); ok, bad, _, _, dd = s.st.sums(k)
            if dd: L.append(f"{k[5:]}  ✓{ok:<6} ✗{bad:<4} {dur(dd['up'])}")
        t = s.st.d["total"]
        L.append(f"TOTAL ✓{t['ok']} ✗{t['bad']} reset {t['resets']}")
        return "<pre>" + "\n".join(L) + "</pre>"

    def balance(s):
        _, _, today_c, _, _ = s.st.sums(today())
        tot = s.st.d["total"]["amt"]
        L = ["💰 <b>BALANCE</b>   hari ini | total"]
        for c in COINS:
            if tot.get(c) or today_c.get(c):
                L.append(f"{c.upper():<5} {amt(today_c.get(c, 0))} | {amt(tot.get(c, 0))}")
        return "<pre>" + "\n".join(L) + "</pre>" if len(L) > 1 else "Belum ada reward tercatat."

    # ── dashboard ──
    W = 44
    @staticmethod
    def _vl(x): return len(re.sub(r"\033\[[0-9;]*m", "", x))

    def box(s, title, rows):
        cy, rs, b = "\033[36m", "\033[0m", "\033[1m"
        out = [f"{cy}╭─ {b}{title}{rs}{cy} " + "─" * (s.W - 5 - len(title)) + f"╮{rs}"]
        for r in rows:
            out.append(f"{cy}│{rs} {r}" + " " * max(0, s.W - 3 - s._vl(r)) + f"{cy}│{rs}")
        out.append(f"{cy}╰" + "─" * (s.W - 2) + f"╯{rs}")
        return out

    def render(s):
        g, rd, yl, mg, dm, rs, b = ("\033[32m", "\033[31m", "\033[33m", "\033[35m",
                                    "\033[2m", "\033[0m", "\033[1m")
        ok, bad, coins, per, dd = s.st.sums(today())
        al = s.alive_counts()
        head = f"{mg}◆{rs} {b}PANDA MANAGER{rs} {mg}v2{rs}"
        head += " " * max(1, s.W - 4 - s._vl(head) - 8) + datetime.now().strftime("%H:%M:%S")
        L = [head, ""]
        L += s.box("STATUS", [
            f"Akun {len(s.active_folders())}  Pane {len(s.panes)}  Blocked {len(s.st.d['blocked'])}",
            f"Restart  {clock(s.last_restart + RESTART_HOURS * 3600 - time.time())}",
            f"Runtime  {dur(s.st.runtime())}"])
        L.append("")
        pct = f"{ok * 100 / (ok + bad):.0f}%" if ok + bad else "-"
        rows = [f"Claim {g}✓ {ok}{rs} {rd}✗ {bad}{rs}  ({pct})"]
        cs = [f"{c.upper()} {amt(v)[:9]}" for c, v in sorted(coins.items()) if v]
        for i in range(0, len(cs), 2):
            rows.append("  ".join(f"{x:<19}" for x in cs[i:i + 2]).rstrip())
        avg = int(dd["rec_sum"] / dd["rec_n"]) if dd and dd["rec_n"] else 0
        rows.append(f"Reset {dd['resets'] if dd else 0}   Pulih {avg}s")
        L += s.box("HARI INI", rows); L.append("")
        rows = []
        for f in s.folders():
            if f in s.st.d["blocked"]:
                rows.append(f"{rd}●{rs} {f[:15]:<15} {rd}blocked{rs}"); continue
            a, t = al.get(f, [0, 0]); o, bd = per.get(f, [0, 0])
            dot = g if t and a == t else (yl if t else rd)
            rows.append(f"{dot}●{rs} {f[:15]:<15} {a:>2}/{t:<2} {g}✓{o}{rs} {rd}✗{bd}{rs}")
        L += s.box("AKUN", rows or ["(kosong)"]); L.append("")
        L += s.box("LOG", [f"{dm}{e[:s.W - 4]}{rs}" for e in list(s.events)[-6:]] or ["-"])
        sys.stdout.write("\033[H" + "\n".join(x + "\033[K" for x in L) + "\n\033[J")
        sys.stdout.flush()

    # ── main loop ──
    def run(s):
        s.creds = load_creds(); s.adopt(); s.unblock_all()
        s.tg.start()
        if s.launch_missing() or s.panes:
            s.tg.send(f"🐼 <b>Panda Manager v2</b> aktif — {len(s.active_folders())} akun, {len(s.panes)} pane")
        last_scan = time.time()
        try:
            while True:
                t0 = time.time(); s.cycle += 1
                s.st.beat(); s.do_actions()
                if t0 - last_scan >= SCAN:
                    s.creds = load_creds(); s.adopt(); s.launch_missing(); last_scan = t0
                if t0 - s.last_restart >= RESTART_HOURS * 3600:
                    s.restart_all()
                s.poll()
                rep = s.st.d["rep_day"]
                if rep != today():
                    if rep: s.tg.send(s.report(rep, "HARIAN"))
                    s.st.d["rep_day"] = today()
                if s.cycle % 2 == 0:
                    s.st.save()
                s.render()
                time.sleep(max(0.5, POLL - (time.time() - t0)))
        except KeyboardInterrupt:
            s.st.save()
            print("\nManager berhenti. Sesi tmux akun tetap jalan (python pandamgr.py --stop untuk menutup).")

# ════════════════════════ CLI ════════════════════════
def cek():
    m = Manager(); cr = load_creds()
    print(f"BASE   : {BASE}  ({'ada' if BASE.is_dir() else 'TIDAK ADA'})")
    for t in ("tmux", "php", "python3"):
        print(f"{t:<7}: {shutil.which(t) or 'TIDAK ADA'}")
    print(f"Telegram: {'aktif' if m.tg.on else 'belum diisi'}   data.txt: {len(cr)} akun")
    for f in m.folders():
        c = cr.get(f.lower())
        st = "BLOCKED" if f in m.st.d["blocked"] else "ok"
        print(f"  {f:<20} {st:<8} data.txt:{'ada' if c else 'default'}  "
              f"{SCRIPT}:{'ada' if (BASE / f / SCRIPT).exists() or (BASE / SCRIPT).exists() else 'TIDAK ADA'}"
              + f"  ketik:{email_for(f)}")

if __name__ == "__main__":
    if "--cek" in sys.argv:
        cek(); sys.exit()
    if not shutil.which("tmux") or not shutil.which("php"):
        sys.exit("tmux/php belum terpasang: pkg install tmux php python")
    if "--stop" in sys.argv:
        m = Manager(); m.kill_all(); print("Semua sesi akun ditutup."); sys.exit()
    tmux("set-option", "-g", "history-limit", "1500")
    os.system("clear")
    Manager().run()
