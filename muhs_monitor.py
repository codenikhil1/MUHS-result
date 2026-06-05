#!/usr/bin/env python3
"""
MUHS Result Monitor — UG 2026
Polls MUHS result pages every 2 minutes and alerts when results go live.
Runs locally (rich terminal UI) or on cloud (headless, email-only).
"""

import os
import sys
import time
import logging
import smtplib
import platform
import subprocess
import threading
import webbrowser
from datetime import datetime, timedelta
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart

import requests

# ── Optional imports (graceful fallback) ────────────────────────────────────
try:
    from rich.console import Console
    from rich.panel import Panel
    from rich.live import Live
    from rich.table import Table
    from rich.text import Text
    from rich.align import Align
    from rich import box
    RICH_AVAILABLE = True
except ImportError:
    RICH_AVAILABLE = False

try:
    from plyer import notification as plyer_notify
    PLYER_AVAILABLE = True
except ImportError:
    PLYER_AVAILABLE = False

# ── Constants ────────────────────────────────────────────────────────────────
URLS = [
    "https://centres.muhs.edu.in/Vf$ato/JR/MX1/ug_res/S26/ug_result_S26.aspx",
    "https://centres.muhs.edu.in/Vf$ato/JR/MX1/ug_res/s26/ug_result_s26.aspx",
    "https://centres.muhs.edu.in/Vf$ato/JR/MX1/ug_res/W26/ug_result_W26.aspx",
    "https://centres.muhs.edu.in/Vf$ato/JR/MX1/ug_res/w26/ug_result_w26.aspx",
]

LIVE_KEYWORDS = [
    "enter roll number", "result", "search", "roll no", "seat no",
    "examination result", "university result", "mark sheet",
    "input", "form", "submit",
]

HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/124.0.0.0 Safari/537.36"
    ),
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.5",
    "Connection": "keep-alive",
}

POLL_INTERVAL   = 120   # seconds
REQUEST_TIMEOUT = 20    # seconds
LOG_FILE        = "muhs_monitor.log"
ALERT_FILE      = "muhs_result_alert.txt"

IS_TTY   = sys.stdout.isatty()
IS_CLOUD = (
    os.environ.get("CLOUD_MODE", "").lower() in ("1", "true", "yes")
    or not IS_TTY
    or os.environ.get("RAILWAY_ENVIRONMENT") is not None
    or os.environ.get("RENDER") is not None
)

# ── Logging setup ────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    handlers=[
        logging.FileHandler(LOG_FILE, encoding="utf-8"),
        logging.StreamHandler(sys.stdout) if IS_CLOUD else logging.NullHandler(),
    ],
)
log = logging.getLogger("muhs")

# ── Config (filled at startup) ───────────────────────────────────────────────
config: dict = {
    "roll_number": "",
    "email_to":    "",
    "smtp_host":   "",
    "smtp_port":   587,
    "smtp_user":   "",
    "smtp_pass":   "",
}

# ── State ────────────────────────────────────────────────────────────────────
state: dict = {
    "total_checks": 0,
    "last_check":   None,
    "last_status":  "Starting…",
    "next_check":   datetime.now(),
    "start_time":   datetime.now(),
    "live_url":     None,
    "running":      True,
    "lock":         threading.Lock(),
}

console = Console() if RICH_AVAILABLE and not IS_CLOUD else None


# ═══════════════════════════════════════════════════════════════════════════════
#  STARTUP — collect config from env vars (cloud) or interactive prompts (local)
# ═══════════════════════════════════════════════════════════════════════════════

def load_config() -> None:
    """Read config from env vars first, then fall back to prompts."""

    def _env_or_prompt(env_key: str, prompt: str, secret: bool = False) -> str:
        val = os.environ.get(env_key, "").strip()
        if val:
            return val
        if IS_CLOUD:
            return ""
        if secret:
            import getpass
            return getpass.getpass(prompt).strip()
        return input(prompt).strip()

    if not IS_CLOUD:
        print("\n" + "═" * 52)
        print("   MUHS Result Monitor — UG 2026  |  Setup")
        print("═" * 52)

    config["roll_number"] = _env_or_prompt(
        "ROLL_NUMBER",
        "Enter your Roll Number (auto-open on result): "
    )

    config["email_to"] = _env_or_prompt(
        "EMAIL_TO",
        "Email for alert (leave blank to skip): "
    )

    if config["email_to"]:
        config["smtp_host"] = _env_or_prompt("SMTP_HOST", "SMTP host [smtp.gmail.com]: ") or "smtp.gmail.com"
        port_str            = _env_or_prompt("SMTP_PORT", "SMTP port [587]: ") or "587"
        config["smtp_port"] = int(port_str)
        config["smtp_user"] = _env_or_prompt("SMTP_USER", "SMTP username (your Gmail): ")
        config["smtp_pass"] = _env_or_prompt("SMTP_PASS", "SMTP password / App Password: ", secret=True)

    if not IS_CLOUD:
        print("═" * 52)
        print("  Monitoring started. Press Ctrl+C to stop.\n")


# ═══════════════════════════════════════════════════════════════════════════════
#  DETECTION
# ═══════════════════════════════════════════════════════════════════════════════

def check_url(url: str) -> tuple[bool, str]:
    """
    Returns (is_live, status_message).
    is_live = True  → results page found with a form/keywords
    is_live = False → not yet published or error
    """
    try:
        resp = requests.get(url, headers=HEADERS, timeout=REQUEST_TIMEOUT, allow_redirects=True)
        code = resp.status_code

        if code == 404:
            return False, f"404 Not Found"
        if code >= 500:
            return False, f"Server error {code}"
        if code != 200:
            return False, f"HTTP {code}"

        body_lower = resp.text.lower()

        # Strong signal: an <input> tag for roll number
        if 'type="text"' in body_lower or "roll" in body_lower or "seat" in body_lower:
            for kw in LIVE_KEYWORDS:
                if kw in body_lower:
                    return True, f"LIVE — keyword '{kw}' found"

        # Softer: page loaded with result-related content
        keyword_hits = sum(1 for kw in LIVE_KEYWORDS if kw in body_lower)
        if keyword_hits >= 2:
            return True, f"LIVE — {keyword_hits} keywords matched"

        return False, f"HTTP 200 — no result form detected"

    except requests.exceptions.ConnectionError:
        return False, "Connection error"
    except requests.exceptions.Timeout:
        return False, "Timeout"
    except requests.exceptions.RequestException as exc:
        return False, f"Request error: {exc}"


def poll_all() -> tuple[bool, str | None]:
    """Check all URLs. Returns (any_live, live_url)."""
    with state["lock"]:
        state["last_status"] = "Checking…"

    for url in URLS:
        is_live, msg = check_url(url)
        log.info("%-72s → %s", url, msg)
        if is_live:
            return True, url

    return False, None


# ═══════════════════════════════════════════════════════════════════════════════
#  NOTIFICATIONS
# ═══════════════════════════════════════════════════════════════════════════════

def _beep() -> None:
    system = platform.system()
    try:
        if system == "Windows":
            import winsound
            for _ in range(5):
                winsound.Beep(1000, 500)
        elif system == "Darwin":
            for _ in range(3):
                subprocess.run(["afplay", "/System/Library/Sounds/Glass.aiff"], check=False)
        else:
            # Linux — try paplay, then bell char
            for _ in range(3):
                result = subprocess.run(
                    ["paplay", "/usr/share/sounds/freedesktop/stereo/complete.oga"],
                    check=False, capture_output=True
                )
                if result.returncode != 0:
                    print("\a", end="", flush=True)
    except Exception:
        print("\a\a\a", end="", flush=True)


def _desktop_notify(url: str) -> None:
    if IS_CLOUD:
        return
    if PLYER_AVAILABLE:
        try:
            plyer_notify.notify(
                title="🎉 MUHS Results are LIVE!",
                message=f"Results published!\n{url}",
                app_name="MUHS Monitor",
                timeout=30,
            )
            return
        except Exception:
            pass
    # macOS fallback
    if platform.system() == "Darwin":
        try:
            subprocess.run([
                "osascript", "-e",
                f'display notification "MUHS UG 2026 Results are LIVE!" '
                f'with title "MUHS Monitor" sound name "Glass"'
            ], check=False)
        except Exception:
            pass


def _fetch_result_content(base_url: str, roll: str) -> str:
    """
    Best-effort: try to fetch the actual result for a roll number.
    MUHS uses ASP.NET ViewState forms, so we:
      1. GET the page to grab ViewState/EventValidation tokens
      2. POST the roll number back (like submitting the form)
      3. Return extracted text from the response
    Returns a human-readable string with the result, or empty string on failure.
    """
    if not roll:
        return ""
    try:
        # Step 1: GET the form page
        session = requests.Session()
        resp = session.get(base_url, headers=HEADERS, timeout=REQUEST_TIMEOUT)
        if resp.status_code != 200:
            return ""

        body = resp.text

        # Extract ASP.NET hidden fields (ViewState, EventValidation, etc.)
        def _extract_hidden(name: str) -> str:
            import re
            pattern = rf'name="{re.escape(name)}"\s+value="([^"]*)"'
            m = re.search(pattern, body, re.IGNORECASE)
            return m.group(1) if m else ""

        viewstate       = _extract_hidden("__VIEWSTATE")
        event_validation = _extract_hidden("__EVENTVALIDATION")
        viewstate_gen   = _extract_hidden("__VIEWSTATEGENERATOR")

        # Common field names for roll number on MUHS pages
        roll_field_candidates = [
            "txtRollNo", "txtRollNumber", "RollNo", "rollno",
            "txtSeatNo", "SeatNo", "roll_number",
        ]

        # Find which input name is actually on the page
        import re
        roll_field = "txtRollNo"  # fallback default
        for candidate in roll_field_candidates:
            if candidate.lower() in body.lower():
                roll_field = candidate
                break

        # Find submit button name
        btn_match = re.search(
            r'<input[^>]+type=["\']submit["\'][^>]+name=["\']([^"\']+)["\']',
            body, re.IGNORECASE
        )
        btn_name  = btn_match.group(1) if btn_match else "btnSubmit"
        btn_value_match = re.search(
            r'name=["\']' + re.escape(btn_name) + r'["\'][^>]+value=["\']([^"\']*)["\']',
            body, re.IGNORECASE
        )
        btn_value = btn_value_match.group(1) if btn_value_match else "Submit"

        # Step 2: POST with roll number
        post_data = {
            "__VIEWSTATE":          viewstate,
            "__EVENTVALIDATION":    event_validation,
            "__VIEWSTATEGENERATOR": viewstate_gen,
            roll_field:             roll,
            btn_name:               btn_value,
        }

        post_resp = session.post(
            base_url, data=post_data, headers=HEADERS, timeout=REQUEST_TIMEOUT
        )
        if post_resp.status_code != 200:
            return ""

        # Step 3: Extract readable text
        result_body = post_resp.text
        # Strip HTML tags and collapse whitespace
        clean = re.sub(r"<[^>]+>", " ", result_body)
        clean = re.sub(r"&nbsp;", " ", clean)
        clean = re.sub(r"&amp;", "&", clean)
        clean = re.sub(r"&lt;", "<", clean)
        clean = re.sub(r"&gt;", ">", clean)
        clean = re.sub(r"\s{2,}", "\n", clean).strip()

        # Check if result data is present (look for marks-related keywords)
        result_keywords = ["marks", "grade", "pass", "fail", "distinction",
                           "atkt", "result", "subject", "total"]
        hits = sum(1 for kw in result_keywords if kw in clean.lower())
        if hits < 2:
            return ""  # Looks like an error page, not actual result

        # Return the most relevant lines (skip boilerplate nav text)
        lines = [ln.strip() for ln in clean.splitlines() if len(ln.strip()) > 3]
        return "\n".join(lines[:120])  # cap at 120 lines

    except Exception as exc:
        log.warning("Result fetch attempt failed: %s", exc)
        return ""


def _smtp_send(subject: str, plain: str, html: str) -> None:
    """Low-level helper to send an email via SMTP."""
    msg = MIMEMultipart("alternative")
    msg["Subject"] = subject
    msg["From"]    = config["smtp_user"]
    msg["To"]      = config["email_to"]
    msg.attach(MIMEText(plain, "plain"))
    msg.attach(MIMEText(html, "html"))
    with smtplib.SMTP(config["smtp_host"], config["smtp_port"]) as server:
        server.starttls()
        server.login(config["smtp_user"], config["smtp_pass"])
        server.sendmail(config["smtp_user"], config["email_to"], msg.as_string())


def _send_email(url: str) -> None:
    """Send the 'results are live' alert email, then attempt to fetch & mail actual result."""
    if not config["email_to"] or not config["smtp_user"]:
        return

    roll = config["roll_number"]
    result_url = f"{url}?rollno={roll}" if roll else url
    detected_at = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    # ── Email 1: Alert ──────────────────────────────────────────────────────
    try:
        plain1 = (
            f"MUHS UG 2026 Results are LIVE!\n\n"
            f"Result page : {url}\n"
            f"Your result : {result_url}\n"
            f"Roll Number : {roll or 'not set'}\n"
            f"Detected at : {detected_at}\n\n"
            f"Open the link above to view your result."
        )
        your_result_link = (
            f"<p><b>Your result link:</b> "
            f"<a href='{result_url}' style='font-size:18px;color:#2980b9'>"
            f"Click here to view your result &rarr;</a></p>"
            if roll else ""
        )
        html1 = f"""
        <html><body style="font-family:Arial,sans-serif;padding:20px">
        <h2 style="color:#2ecc71">&#127881; MUHS UG 2026 Results are LIVE!</h2>
        <p><b>Result page:</b> <a href="{url}">{url}</a></p>
        {your_result_link}
        <p><b>Roll Number:</b> {roll or 'not set'}</p>
        <p><b>Detected at:</b> {detected_at}</p>
        <hr>
        <p style="color:#888;font-size:12px">
          Sent by MUHS Monitor. A second email with your fetched result will
          follow shortly if it can be retrieved automatically.
        </p>
        </body></html>
        """
        _smtp_send("🎉 MUHS UG 2026 Results are LIVE!", plain1, html1)
        log.info("Alert email sent to %s", config["email_to"])
    except Exception as exc:
        log.error("Alert email failed: %s", exc)

    # ── Email 2: Fetched result content (best-effort) ───────────────────────
    if not roll:
        return

    log.info("Attempting to fetch result for roll %s …", roll)
    result_text = _fetch_result_content(url, roll)

    if result_text:
        try:
            plain2 = (
                f"MUHS UG 2026 — Result for Roll No: {roll}\n"
                f"Source: {url}\n"
                f"Fetched at: {detected_at}\n"
                f"{'=' * 60}\n\n"
                f"{result_text}\n\n"
                f"{'=' * 60}\n"
                f"Note: Always verify on the official site."
            )
            html2 = f"""
            <html><body style="font-family:Arial,sans-serif;padding:20px">
            <h2 style="color:#2980b9">MUHS UG 2026 — Your Result</h2>
            <p><b>Roll Number:</b> {roll}</p>
            <p><b>Source:</b> <a href="{url}">{url}</a></p>
            <p><b>Fetched at:</b> {detected_at}</p>
            <hr>
            <pre style="background:#f4f4f4;padding:16px;border-radius:6px;
                        white-space:pre-wrap;font-size:14px">{result_text}</pre>
            <hr>
            <p style="color:#e74c3c;font-size:12px">
              <b>Note:</b> This is an automated fetch. Always verify your
              result on the official MUHS portal.
            </p>
            </body></html>
            """
            _smtp_send(
                f"📋 MUHS Result — Roll No {roll}",
                plain2, html2
            )
            log.info("Result content email sent to %s", config["email_to"])
        except Exception as exc:
            log.error("Result content email failed: %s", exc)
    else:
        log.info(
            "Could not auto-fetch result content "
            "(form may need JavaScript or different POST params). "
            "User can open: %s", result_url
        )


def _write_alert_file(url: str) -> None:
    try:
        with open(ALERT_FILE, "w") as f:
            f.write(
                f"MUHS UG 2026 Results are LIVE!\n"
                f"URL: {url}\n"
                f"Detected at: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n"
                f"Roll Number: {config['roll_number'] or 'not set'}\n"
            )
        log.info("Alert written to %s", ALERT_FILE)
    except Exception as exc:
        log.error("Could not write alert file: %s", exc)


def fire_all_alerts(url: str) -> None:
    _write_alert_file(url)
    _send_email(url)

    if not IS_CLOUD:
        _beep()
        _desktop_notify(url)

        # Auto-open browser
        if config["roll_number"]:
            open_url = f"{url}?rollno={config['roll_number']}"
        else:
            open_url = url
        try:
            webbrowser.open(open_url)
        except Exception:
            pass

    # Loud console banner (always)
    banner = f"""
╔══════════════════════════════════════════════════════╗
║          🎉  MUHS RESULTS ARE LIVE!  🎉             ║
╠══════════════════════════════════════════════════════╣
║  URL   : {url:<44} ║
║  Roll# : {config["roll_number"]:<44} ║
║  Time  : {datetime.now().strftime('%Y-%m-%d %H:%M:%S'):<44} ║
╚══════════════════════════════════════════════════════╝
"""
    print(banner)
    log.info("RESULTS LIVE → %s", url)


# ═══════════════════════════════════════════════════════════════════════════════
#  TERMINAL UI (local rich display)
# ═══════════════════════════════════════════════════════════════════════════════

def _make_panel() -> Panel:
    now  = datetime.now()
    secs = max(0, int((state["next_check"] - now).total_seconds()))
    mins, sec = divmod(secs, 60)
    elapsed   = now - state["start_time"]
    hrs, rem  = divmod(int(elapsed.total_seconds()), 3600)
    emins, esec = divmod(rem, 60)

    last = (
        state["last_check"].strftime("%Y-%m-%d %H:%M:%S")
        if state["last_check"] else "—"
    )

    status_color = {
        "Checking…":   "yellow",
        "Waiting":     "cyan",
        "Error":       "red",
    }.get(state["last_status"].split()[0], "green" if "LIVE" in state["last_status"] else "cyan")

    grid = Table.grid(padding=(0, 2))
    grid.add_column(style="bold cyan",   min_width=16)
    grid.add_column(style="white",       min_width=36)
    grid.add_row("Status",        Text(state["last_status"], style=status_color))
    grid.add_row("Last Check",    last)
    grid.add_row("Total Checks",  str(state["total_checks"]))
    grid.add_row("Time Elapsed",  f"{hrs:02d}h {emins:02d}m {esec:02d}s")
    grid.add_row("Next check in", f"[bold yellow]{mins}m {sec:02d}s[/bold yellow]")
    if config["roll_number"]:
        grid.add_row("Roll Number",  config["roll_number"])
    grid.add_row("Log file",      LOG_FILE)

    return Panel(
        Align.center(grid),
        title="[bold white]MUHS Result Monitor — UG 2026[/bold white]",
        subtitle="[dim]Press Ctrl+C to stop[/dim]",
        border_style="bright_blue",
        box=box.DOUBLE_EDGE,
        padding=(1, 4),
    )


# ═══════════════════════════════════════════════════════════════════════════════
#  MAIN LOOP
# ═══════════════════════════════════════════════════════════════════════════════

def monitor_loop() -> None:
    """Core poll loop — runs in main thread."""
    while state["running"]:
        # Poll
        is_live, live_url = poll_all()

        with state["lock"]:
            state["total_checks"] += 1
            state["last_check"]    = datetime.now()
            state["next_check"]    = datetime.now() + timedelta(seconds=POLL_INTERVAL)

            if is_live:
                state["last_status"] = f"LIVE → {live_url}"
                state["live_url"]    = live_url
            else:
                state["last_status"] = "Waiting — not published yet"

        if is_live:
            fire_all_alerts(live_url)
            state["running"] = False
            break

        # Wait POLL_INTERVAL, updating display every second
        deadline = datetime.now() + timedelta(seconds=POLL_INTERVAL)
        while datetime.now() < deadline and state["running"]:
            time.sleep(1)


def run_cloud() -> None:
    """Headless mode for cloud — plain log output."""
    log.info("MUHS Monitor starting (cloud/headless mode)")
    log.info("Roll number : %s", config["roll_number"] or "not set")
    log.info("Email alert : %s", config["email_to"] or "disabled")
    log.info("Polling every %d seconds", POLL_INTERVAL)
    log.info("URLs to check: %d", len(URLS))

    monitor_loop()

    if state["live_url"]:
        log.info("Monitor exiting — results are LIVE at %s", state["live_url"])
    else:
        log.info("Monitor stopped by user.")


def run_local() -> None:
    """Local mode with rich live display."""
    if not RICH_AVAILABLE:
        print("rich not installed — falling back to plain output. Run: pip install rich")
        run_cloud()
        return

    loop_thread = threading.Thread(target=monitor_loop, daemon=True)
    loop_thread.start()

    with Live(console=console, refresh_per_second=2, screen=False) as live:
        while state["running"]:
            live.update(_make_panel())
            time.sleep(0.5)

        # Show final state
        live.update(_make_panel())

    loop_thread.join(timeout=5)


# ═══════════════════════════════════════════════════════════════════════════════
#  ENTRY POINT
# ═══════════════════════════════════════════════════════════════════════════════

def main() -> None:
    load_config()

    try:
        if IS_CLOUD:
            run_cloud()
        else:
            run_local()
    except KeyboardInterrupt:
        state["running"] = False
        print("\n\nStopped by user. Goodbye!")
        log.info("Monitor stopped by user (KeyboardInterrupt).")


if __name__ == "__main__":
    main()
