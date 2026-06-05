#!/usr/bin/env python3
"""
MUHS Result Notifier — Web App
Students register their PRN + email. When results go live the app
automatically fetches each student's result and emails it to them.

Deploy on Railway / Render as a Web Service.
Set env vars: SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASS, ADMIN_KEY
"""

import os
import re
import sqlite3
import smtplib
import logging
import threading
import time
from datetime import datetime, timedelta
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from contextlib import contextmanager

import requests
from flask import Flask, request, jsonify, redirect, url_for

# ── Config from environment ──────────────────────────────────────────────────
SMTP_HOST  = os.environ.get("SMTP_HOST",  "smtp.gmail.com")
SMTP_PORT  = int(os.environ.get("SMTP_PORT", "587"))
SMTP_USER  = os.environ.get("SMTP_USER",  "")
SMTP_PASS  = os.environ.get("SMTP_PASS",  "")
ADMIN_KEY  = os.environ.get("ADMIN_KEY",  "muhs-admin")   # for /admin page
PORT       = int(os.environ.get("PORT",   "8080"))
DB_PATH    = os.environ.get("DB_PATH",    "registrations.db")

POLL_INTERVAL = 120  # seconds

URLS = [
    "https://centres.muhs.edu.in/Vf$ato/JR/MX1/ug_res/S26/ug_result_S26.aspx",
    "https://centres.muhs.edu.in/Vf$ato/JR/MX1/ug_res/s26/ug_result_s26.aspx",
    "https://centres.muhs.edu.in/Vf$ato/JR/MX1/ug_res/W26/ug_result_W26.aspx",
    "https://centres.muhs.edu.in/Vf$ato/JR/MX1/ug_res/w26/ug_result_w26.aspx",
]

HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/124.0.0.0 Safari/537.36"
    ),
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.5",
}

LIVE_KEYWORDS = [
    "enter roll number", "result", "search", "roll no", "seat no",
    "examination result", "university result", "mark sheet", "submit",
]

# ── Logging ──────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler("muhs_web.log", encoding="utf-8"),
    ],
)
log = logging.getLogger("muhs-web")

# ── Flask app ────────────────────────────────────────────────────────────────
app = Flask(__name__)

# ── Shared state ─────────────────────────────────────────────────────────────
_state = {
    "results_live":  False,
    "live_url":      None,
    "total_checks":  0,
    "last_check":    None,
    "next_check":    datetime.now() + timedelta(seconds=10),
    "start_time":    datetime.now(),
    "lock":          threading.Lock(),
}


# ═══════════════════════════════════════════════════════════════════════════════
#  DATABASE
# ═══════════════════════════════════════════════════════════════════════════════

def init_db() -> None:
    with sqlite3.connect(DB_PATH) as con:
        con.execute("""
            CREATE TABLE IF NOT EXISTS registrations (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                prn         TEXT    NOT NULL,
                email       TEXT    NOT NULL,
                registered_at TEXT  NOT NULL,
                emailed     INTEGER NOT NULL DEFAULT 0,
                email_sent_at TEXT,
                UNIQUE(prn, email)
            )
        """)
        con.commit()


@contextmanager
def get_db():
    con = sqlite3.connect(DB_PATH)
    con.row_factory = sqlite3.Row
    try:
        yield con
    finally:
        con.close()


def add_registration(prn: str, email: str) -> tuple[bool, str]:
    """Insert a new registration. Returns (success, message)."""
    try:
        with get_db() as con:
            con.execute(
                "INSERT INTO registrations (prn, email, registered_at) VALUES (?, ?, ?)",
                (prn.strip().upper(), email.strip().lower(), datetime.now().isoformat())
            )
            con.commit()
        return True, "registered"
    except sqlite3.IntegrityError:
        return False, "already_registered"


def get_pending() -> list[sqlite3.Row]:
    with get_db() as con:
        return con.execute(
            "SELECT * FROM registrations WHERE emailed = 0"
        ).fetchall()


def mark_emailed(reg_id: int) -> None:
    with get_db() as con:
        con.execute(
            "UPDATE registrations SET emailed = 1, email_sent_at = ? WHERE id = ?",
            (datetime.now().isoformat(), reg_id)
        )
        con.commit()


def get_all_registrations() -> list[sqlite3.Row]:
    with get_db() as con:
        return con.execute(
            "SELECT * FROM registrations ORDER BY registered_at DESC"
        ).fetchall()


# ═══════════════════════════════════════════════════════════════════════════════
#  MUHS DETECTION & RESULT FETCH
# ═══════════════════════════════════════════════════════════════════════════════

def check_url(url: str) -> tuple[bool, str]:
    try:
        resp = requests.get(url, headers=HEADERS, timeout=20, allow_redirects=True)
        if resp.status_code == 404:
            return False, "404 Not Found"
        if resp.status_code >= 500:
            return False, f"Server error {resp.status_code}"
        if resp.status_code != 200:
            return False, f"HTTP {resp.status_code}"

        body = resp.text.lower()
        hits = sum(1 for kw in LIVE_KEYWORDS if kw in body)
        if hits >= 2 or ("roll" in body and "result" in body):
            return True, f"LIVE ({hits} keywords matched)"
        return False, "HTTP 200 — no result form"
    except requests.exceptions.RequestException as exc:
        return False, f"Error: {exc}"


def fetch_result_for_prn(base_url: str, prn: str) -> str:
    """Try to submit the result form for a PRN and return extracted text."""
    if not prn:
        return ""
    try:
        session = requests.Session()
        resp = session.get(base_url, headers=HEADERS, timeout=20)
        if resp.status_code != 200:
            return ""
        body = resp.text

        def _extract(name: str) -> str:
            m = re.search(rf'name="{re.escape(name)}"\s+value="([^"]*)"', body, re.I)
            return m.group(1) if m else ""

        viewstate        = _extract("__VIEWSTATE")
        event_validation = _extract("__EVENTVALIDATION")
        viewstate_gen    = _extract("__VIEWSTATEGENERATOR")

        # Detect roll number field name
        roll_field = "txtRollNo"
        for candidate in ["txtRollNo", "txtRollNumber", "RollNo", "rollno",
                          "txtSeatNo", "SeatNo", "txtPRN", "PRN"]:
            if candidate.lower() in body.lower():
                roll_field = candidate
                break

        # Detect submit button
        btn_match = re.search(
            r'<input[^>]+type=["\']submit["\'][^>]+name=["\']([^"\']+)["\']', body, re.I
        )
        btn_name = btn_match.group(1) if btn_match else "btnSubmit"
        btn_val_m = re.search(
            r'name=["\']' + re.escape(btn_name) + r'["\'][^>]+value=["\']([^"\']*)["\']',
            body, re.I
        )
        btn_value = btn_val_m.group(1) if btn_val_m else "Submit"

        post_data = {
            "__VIEWSTATE":          viewstate,
            "__EVENTVALIDATION":    event_validation,
            "__VIEWSTATEGENERATOR": viewstate_gen,
            roll_field:             prn,
            btn_name:               btn_value,
        }

        post_resp = session.post(base_url, data=post_data, headers=HEADERS, timeout=20)
        if post_resp.status_code != 200:
            return ""

        # Strip HTML → clean text
        clean = re.sub(r"<[^>]+>", " ", post_resp.text)
        clean = re.sub(r"&nbsp;", " ", clean)
        clean = re.sub(r"&amp;",  "&", clean)
        clean = re.sub(r"&lt;",   "<", clean)
        clean = re.sub(r"&gt;",   ">", clean)
        clean = re.sub(r"\s{2,}", "\n", clean).strip()

        result_kw = ["marks", "grade", "pass", "fail", "distinction",
                     "atkt", "result", "subject", "total"]
        if sum(1 for k in result_kw if k in clean.lower()) < 2:
            return ""

        lines = [ln.strip() for ln in clean.splitlines() if len(ln.strip()) > 3]
        return "\n".join(lines[:120])

    except Exception as exc:
        log.warning("Result fetch failed for %s: %s", prn, exc)
        return ""


# ═══════════════════════════════════════════════════════════════════════════════
#  EMAIL
# ═══════════════════════════════════════════════════════════════════════════════

def send_result_email(to_email: str, prn: str, live_url: str, result_text: str) -> bool:
    if not SMTP_USER or not SMTP_PASS:
        log.warning("SMTP not configured — cannot send email to %s", to_email)
        return False

    subject = f"🎉 MUHS UG 2026 Result — PRN {prn}"
    direct_url = f"{live_url}?rollno={prn}"

    if result_text:
        result_section_plain = f"\n{'='*60}\nYOUR RESULT\n{'='*60}\n{result_text}\n{'='*60}\n"
        result_section_html  = f"""
        <div style="background:#f8f9fa;border-left:4px solid #2ecc71;
                    padding:16px;margin:16px 0;border-radius:4px">
          <h3 style="margin-top:0;color:#2c3e50">Your Result</h3>
          <pre style="white-space:pre-wrap;font-family:monospace;
                      font-size:13px;color:#2c3e50">{result_text}</pre>
        </div>"""
        note_plain = "\nNote: Always verify on the official MUHS portal."
        note_html  = '<p style="color:#e74c3c;font-size:12px"><b>Note:</b> Always verify on the official MUHS portal.</p>'
    else:
        result_section_plain = (
            "\nWe could not auto-fetch your result details — "
            "please use the link below to view it directly.\n"
        )
        result_section_html  = (
            "<p style='color:#7f8c8d'>We could not automatically fetch your "
            "result details. Please click the link above to view it directly.</p>"
        )
        note_plain = ""
        note_html  = ""

    plain = (
        f"MUHS UG 2026 Results are LIVE!\n\n"
        f"PRN         : {prn}\n"
        f"Result page : {live_url}\n"
        f"Direct link : {direct_url}\n"
        f"{result_section_plain}{note_plain}\n\n"
        f"Best of luck!\n— MUHS Result Notifier"
    )

    html = f"""
    <html>
    <body style="font-family:Arial,sans-serif;max-width:600px;margin:0 auto;padding:20px;color:#2c3e50">
      <div style="background:linear-gradient(135deg,#667eea,#764ba2);
                  padding:24px;border-radius:8px 8px 0 0;text-align:center">
        <h1 style="color:white;margin:0;font-size:24px">🎉 Results are LIVE!</h1>
        <p style="color:rgba(255,255,255,0.9);margin:8px 0 0">MUHS UG 2026</p>
      </div>

      <div style="background:white;border:1px solid #e0e0e0;
                  border-radius:0 0 8px 8px;padding:24px">
        <p><b>PRN:</b> {prn}</p>

        <div style="text-align:center;margin:20px 0">
          <a href="{direct_url}"
             style="background:#2ecc71;color:white;padding:12px 28px;
                    border-radius:6px;text-decoration:none;font-size:16px;
                    font-weight:bold;display:inline-block">
            View Your Result &rarr;
          </a>
        </div>

        <p style="font-size:13px;color:#7f8c8d;text-align:center">
          Or open: <a href="{live_url}">{live_url}</a>
        </p>

        {result_section_html}
        {note_html}

        <hr style="border:none;border-top:1px solid #eee;margin:20px 0">
        <p style="color:#95a5a6;font-size:12px;text-align:center">
          Sent by MUHS Result Notifier &bull; You registered with PRN {prn}
        </p>
      </div>
    </body>
    </html>
    """

    try:
        msg = MIMEMultipart("alternative")
        msg["Subject"] = subject
        msg["From"]    = SMTP_USER
        msg["To"]      = to_email
        msg.attach(MIMEText(plain, "plain"))
        msg.attach(MIMEText(html, "html"))

        with smtplib.SMTP(SMTP_HOST, SMTP_PORT) as server:
            server.starttls()
            server.login(SMTP_USER, SMTP_PASS)
            server.sendmail(SMTP_USER, to_email, msg.as_string())

        log.info("Result email sent → %s (PRN %s)", to_email, prn)
        return True
    except Exception as exc:
        log.error("Email failed for %s: %s", to_email, exc)
        return False


def send_registration_confirmation(to_email: str, prn: str) -> None:
    """Send a 'you are registered' confirmation email."""
    if not SMTP_USER or not SMTP_PASS:
        return
    try:
        subject = "✅ MUHS Result Notifier — You're registered!"
        plain = (
            f"Hi!\n\nYou're registered to receive your MUHS UG 2026 result.\n\n"
            f"PRN   : {prn}\n"
            f"Email : {to_email}\n\n"
            f"We'll email you automatically the moment results are published.\n"
            f"No action needed — just wait!\n\n— MUHS Result Notifier"
        )
        html = f"""
        <html>
        <body style="font-family:Arial,sans-serif;max-width:600px;margin:0 auto;padding:20px;color:#2c3e50">
          <div style="background:linear-gradient(135deg,#667eea,#764ba2);
                      padding:24px;border-radius:8px 8px 0 0;text-align:center">
            <h1 style="color:white;margin:0;font-size:22px">✅ You're Registered!</h1>
            <p style="color:rgba(255,255,255,0.9);margin:8px 0 0">MUHS UG 2026 Result Notifier</p>
          </div>
          <div style="background:white;border:1px solid #e0e0e0;
                      border-radius:0 0 8px 8px;padding:24px">
            <p>Hi! You are now registered to receive your MUHS result automatically.</p>
            <table style="width:100%;border-collapse:collapse;margin:16px 0">
              <tr><td style="padding:8px;color:#7f8c8d;width:80px"><b>PRN</b></td>
                  <td style="padding:8px"><b>{prn}</b></td></tr>
              <tr style="background:#f8f9fa">
                  <td style="padding:8px;color:#7f8c8d"><b>Email</b></td>
                  <td style="padding:8px">{to_email}</td></tr>
            </table>
            <div style="background:#eafaf1;border-left:4px solid #2ecc71;
                        padding:12px 16px;border-radius:4px;margin:16px 0">
              <b>What happens next?</b><br>
              Our server checks MUHS every 2 minutes. The moment your results are
              published, we will automatically fetch and email them to you — even
              if your laptop is off.
            </div>
            <hr style="border:none;border-top:1px solid #eee;margin:20px 0">
            <p style="color:#95a5a6;font-size:12px;text-align:center">
              MUHS Result Notifier &bull; UG 2026
            </p>
          </div>
        </body>
        </html>
        """
        msg = MIMEMultipart("alternative")
        msg["Subject"] = subject
        msg["From"]    = SMTP_USER
        msg["To"]      = to_email
        msg.attach(MIMEText(plain, "plain"))
        msg.attach(MIMEText(html, "html"))

        with smtplib.SMTP(SMTP_HOST, SMTP_PORT) as server:
            server.starttls()
            server.login(SMTP_USER, SMTP_PASS)
            server.sendmail(SMTP_USER, to_email, msg.as_string())

        log.info("Confirmation email sent → %s", to_email)
    except Exception as exc:
        log.warning("Confirmation email failed for %s: %s", to_email, exc)


# ═══════════════════════════════════════════════════════════════════════════════
#  BACKGROUND POLLING THREAD
# ═══════════════════════════════════════════════════════════════════════════════

def _process_pending(live_url: str) -> None:
    """Fetch and email results for all pending registrations."""
    pending = get_pending()
    if not pending:
        log.info("No pending registrations to process.")
        return

    log.info("Processing %d pending registrations …", len(pending))
    for row in pending:
        prn   = row["prn"]
        email = row["email"]
        log.info("Fetching result for PRN %s …", prn)
        result_text = fetch_result_for_prn(live_url, prn)
        success = send_result_email(email, prn, live_url, result_text)
        if success:
            mark_emailed(row["id"])
        time.sleep(2)   # be polite between requests


def _poll_loop() -> None:
    """Background thread: poll MUHS every POLL_INTERVAL seconds."""
    log.info("Background poller started. Interval: %ds", POLL_INTERVAL)

    while True:
        with _state["lock"]:
            _state["next_check"] = datetime.now() + timedelta(seconds=POLL_INTERVAL)

        found_live   = False
        found_url    = None

        for url in URLS:
            is_live, msg = check_url(url)
            log.info("%-72s → %s", url, msg)
            if is_live:
                found_live = True
                found_url  = url
                break

        with _state["lock"]:
            _state["total_checks"] += 1
            _state["last_check"]    = datetime.now()

            if found_live and not _state["results_live"]:
                _state["results_live"] = True
                _state["live_url"]     = found_url
                log.info("RESULTS ARE LIVE → %s", found_url)

        if found_live:
            _process_pending(found_url)

        time.sleep(POLL_INTERVAL)


# ═══════════════════════════════════════════════════════════════════════════════
#  HTML TEMPLATES (inline)
# ═══════════════════════════════════════════════════════════════════════════════

_CSS = """
* { box-sizing: border-box; margin: 0; padding: 0; }
body {
  font-family: 'Segoe UI', Arial, sans-serif;
  background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
  min-height: 100vh;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 20px;
}
.card {
  background: white;
  border-radius: 16px;
  box-shadow: 0 20px 60px rgba(0,0,0,0.3);
  max-width: 480px;
  width: 100%;
  overflow: hidden;
}
.header {
  background: linear-gradient(135deg, #667eea, #764ba2);
  padding: 32px 24px;
  text-align: center;
  color: white;
}
.header h1 { font-size: 22px; margin-bottom: 8px; }
.header p  { font-size: 14px; opacity: 0.85; }
.body      { padding: 32px 28px; }
.form-group { margin-bottom: 20px; }
label {
  display: block;
  font-size: 13px;
  font-weight: 600;
  color: #555;
  margin-bottom: 6px;
  text-transform: uppercase;
  letter-spacing: 0.5px;
}
input[type=text], input[type=email] {
  width: 100%;
  padding: 12px 14px;
  border: 2px solid #e0e0e0;
  border-radius: 8px;
  font-size: 15px;
  outline: none;
  transition: border-color 0.2s;
}
input:focus { border-color: #667eea; }
button {
  width: 100%;
  padding: 14px;
  background: linear-gradient(135deg, #667eea, #764ba2);
  color: white;
  border: none;
  border-radius: 8px;
  font-size: 16px;
  font-weight: 600;
  cursor: pointer;
  transition: opacity 0.2s;
}
button:hover { opacity: 0.9; }
.status-badge {
  display: inline-block;
  padding: 4px 12px;
  border-radius: 20px;
  font-size: 12px;
  font-weight: 600;
  margin-bottom: 16px;
}
.live    { background: #d4edda; color: #155724; }
.waiting { background: #fff3cd; color: #856404; }
.info-box {
  background: #f0f4ff;
  border-left: 4px solid #667eea;
  padding: 12px 16px;
  border-radius: 4px;
  font-size: 13px;
  color: #555;
  margin-bottom: 20px;
}
.success-icon { font-size: 48px; text-align: center; margin-bottom: 12px; }
.alert {
  padding: 12px 16px;
  border-radius: 8px;
  margin-bottom: 16px;
  font-size: 14px;
}
.alert-danger  { background: #f8d7da; color: #721c24; border: 1px solid #f5c6cb; }
.alert-warning { background: #fff3cd; color: #856404; border: 1px solid #ffc107; }
.footer {
  padding: 16px 28px;
  background: #f8f9fa;
  border-top: 1px solid #eee;
  font-size: 12px;
  color: #999;
  text-align: center;
}
a { color: #667eea; text-decoration: none; }
"""

def _page(title: str, body_html: str, footer: str = "") -> str:
    checks = _state["total_checks"]
    last   = _state["last_check"].strftime("%H:%M:%S") if _state["last_check"] else "—"
    is_live = _state["results_live"]
    badge = (
        '<span class="status-badge live">🟢 Results LIVE</span>'
        if is_live else
        '<span class="status-badge waiting">🟡 Checking every 2 min</span>'
    )
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{title}</title>
  <style>{_CSS}</style>
</head>
<body>
  <div class="card">
    <div class="header">
      <h1>🎓 MUHS UG 2026</h1>
      <p>Result Notifier</p>
    </div>
    <div class="body">
      {badge}
      {body_html}
    </div>
    <div class="footer">
      Checks done: <b>{checks}</b> &bull; Last check: <b>{last}</b>
      {(' &bull; ' + footer) if footer else ''}
    </div>
  </div>
</body>
</html>"""


# ═══════════════════════════════════════════════════════════════════════════════
#  ROUTES
# ═══════════════════════════════════════════════════════════════════════════════

@app.route("/", methods=["GET"])
def index():
    is_live = _state["results_live"]
    live_url = _state["live_url"] or ""

    if is_live:
        status_note = f"""
        <div class="info-box">
          ✅ Results are published! Enter your PRN and email —
          we'll fetch and email your result right now.<br>
          <a href="{live_url}" target="_blank">Open result portal →</a>
        </div>"""
    else:
        secs = max(0, int((_state["next_check"] - datetime.now()).total_seconds()))
        mins, sec = divmod(secs, 60)
        status_note = f"""
        <div class="info-box">
          ⏳ Results not published yet. Register below —
          you'll be emailed automatically the moment they go live
          (checking every 2 minutes, next in {mins}m {sec:02d}s).
        </div>"""

    form_html = f"""
    {status_note}
    <form method="POST" action="/register">
      <div class="form-group">
        <label>PRN / Roll Number</label>
        <input type="text" name="prn" placeholder="e.g. 2023XXXXXX"
               required autocomplete="off" pattern="[A-Za-z0-9]+"
               title="Alphanumeric only">
      </div>
      <div class="form-group">
        <label>Email Address</label>
        <input type="email" name="email" placeholder="your@email.com" required>
      </div>
      <button type="submit">🔔 Notify Me When Results Are Live</button>
    </form>
    """
    return _page("MUHS Result Notifier", form_html, footer='<a href="/admin">Admin</a>')


@app.route("/register", methods=["POST"])
def register():
    prn   = (request.form.get("prn",   "") or "").strip().upper()
    email = (request.form.get("email", "") or "").strip().lower()

    # Validate
    errors = []
    if not prn or not re.match(r"^[A-Z0-9]{5,20}$", prn):
        errors.append("Invalid PRN — use alphanumeric characters only (5–20 chars).")
    if not email or not re.match(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", email):
        errors.append("Invalid email address.")

    if errors:
        err_html = "".join(f'<div class="alert alert-danger">{e}</div>' for e in errors)
        back = '<p style="margin-top:16px;text-align:center"><a href="/">← Go back</a></p>'
        return _page("Error — MUHS Notifier", err_html + back), 400

    ok, reason = add_registration(prn, email)

    if not ok and reason == "already_registered":
        warn = f"""
        <div class="alert alert-warning">
          PRN <b>{prn}</b> is already registered with that email.
          You'll be notified when results are live.
        </div>
        <p style="text-align:center"><a href="/">← Register another</a></p>"""
        return _page("Already Registered", warn)

    # Send confirmation email in background
    threading.Thread(
        target=send_registration_confirmation,
        args=(email, prn),
        daemon=True
    ).start()

    # If results already live, fetch & email immediately
    if _state["results_live"] and _state["live_url"]:
        def _immediate(reg_prn: str, reg_email: str, url: str) -> None:
            result_text = fetch_result_for_prn(url, reg_prn)
            with get_db() as con:
                row = con.execute(
                    "SELECT id FROM registrations WHERE prn=? AND email=?",
                    (reg_prn, reg_email)
                ).fetchone()
            if row:
                success = send_result_email(reg_email, reg_prn, url, result_text)
                if success:
                    mark_emailed(row["id"])

        threading.Thread(
            target=_immediate,
            args=(prn, email, _state["live_url"]),
            daemon=True
        ).start()
        extra = " Your result is being fetched and will arrive shortly!"
    else:
        extra = " You'll get an email the moment results are published."

    success_html = f"""
    <div class="success-icon">🎉</div>
    <h2 style="text-align:center;margin-bottom:12px;color:#2c3e50">You're registered!</h2>
    <p style="text-align:center;color:#555;margin-bottom:20px">
      <b>{prn}</b> → <b>{email}</b>
    </p>
    <div class="info-box">{extra.strip()}</div>
    <p style="text-align:center"><a href="/">← Register another student</a></p>
    """
    return _page("Registered! — MUHS Notifier", success_html)


@app.route("/status")
def status():
    """Simple JSON status endpoint."""
    return jsonify({
        "results_live":  _state["results_live"],
        "live_url":      _state["live_url"],
        "total_checks":  _state["total_checks"],
        "last_check":    _state["last_check"].isoformat() if _state["last_check"] else None,
        "start_time":    _state["start_time"].isoformat(),
        "uptime_seconds": int((datetime.now() - _state["start_time"]).total_seconds()),
    })


@app.route("/admin")
def admin():
    key = request.args.get("key", "")
    if key != ADMIN_KEY:
        return _page(
            "Admin — MUHS Notifier",
            '<div class="alert alert-danger">Access denied. Pass ?key=YOUR_ADMIN_KEY</div>'
        ), 403

    rows = get_all_registrations()
    total   = len(rows)
    emailed = sum(1 for r in rows if r["emailed"])
    pending = total - emailed

    rows_html = "".join(
        f"""<tr style="background:{'#eafaf1' if r['emailed'] else 'white'}">
              <td style="padding:8px;border-bottom:1px solid #eee">{r['prn']}</td>
              <td style="padding:8px;border-bottom:1px solid #eee">{r['email']}</td>
              <td style="padding:8px;border-bottom:1px solid #eee;font-size:12px;color:#999">
                {r['registered_at'][:16]}</td>
              <td style="padding:8px;border-bottom:1px solid #eee">
                {'✅ Sent' if r['emailed'] else '⏳ Pending'}</td>
            </tr>"""
        for r in rows
    ) or "<tr><td colspan='4' style='padding:16px;text-align:center;color:#999'>No registrations yet</td></tr>"

    table_html = f"""
    <div style="display:flex;gap:12px;margin-bottom:20px;font-size:14px">
      <div style="flex:1;background:#eafaf1;padding:12px;border-radius:8px;text-align:center">
        <b style="font-size:22px;color:#27ae60">{emailed}</b><br>Emailed
      </div>
      <div style="flex:1;background:#fff3cd;padding:12px;border-radius:8px;text-align:center">
        <b style="font-size:22px;color:#e67e22">{pending}</b><br>Pending
      </div>
      <div style="flex:1;background:#eaf4fb;padding:12px;border-radius:8px;text-align:center">
        <b style="font-size:22px;color:#2980b9">{total}</b><br>Total
      </div>
    </div>
    <div style="overflow-x:auto">
      <table style="width:100%;border-collapse:collapse;font-size:13px">
        <thead>
          <tr style="background:#f8f9fa">
            <th style="padding:8px;text-align:left">PRN</th>
            <th style="padding:8px;text-align:left">Email</th>
            <th style="padding:8px;text-align:left">Registered</th>
            <th style="padding:8px;text-align:left">Status</th>
          </tr>
        </thead>
        <tbody>{rows_html}</tbody>
      </table>
    </div>
    """
    return _page("Admin — MUHS Notifier", table_html)


# ═══════════════════════════════════════════════════════════════════════════════
#  STARTUP
# ═══════════════════════════════════════════════════════════════════════════════

def start_background_poller() -> None:
    t = threading.Thread(target=_poll_loop, daemon=True, name="muhs-poller")
    t.start()
    log.info("Background poller thread started.")


if __name__ == "__main__":
    init_db()
    start_background_poller()
    log.info("Starting MUHS Result Notifier on port %d", PORT)
    app.run(host="0.0.0.0", port=PORT, debug=False, use_reloader=False)
