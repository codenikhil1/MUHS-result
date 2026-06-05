# MUHS Monitor — Cloud Deployment Guide

Run this monitor 24/7 on a free cloud platform so it works even with your laptop off.

---

## Option A — Railway (Recommended, free tier)

Railway gives you a persistent container that stays running.

### Steps

1. **Create account** at [railway.app](https://railway.app) (free, no credit card needed for hobby plan)

2. **Push your files to GitHub:**
   ```
   git init
   git add muhs_monitor.py requirements.txt Dockerfile .env.example
   git commit -m "MUHS monitor"
   # create a repo on github.com, then:
   git remote add origin https://github.com/YOUR_USERNAME/muhs-monitor.git
   git push -u origin main
   ```

3. **Deploy on Railway:**
   - Click **New Project → Deploy from GitHub repo**
   - Select your `muhs-monitor` repo
   - Railway auto-detects the Dockerfile

4. **Set environment variables** in Railway dashboard → Variables:
   ```
   ROLL_NUMBER   = 2023XXXXXX
   EMAIL_TO      = your@gmail.com
   SMTP_HOST     = smtp.gmail.com
   SMTP_PORT     = 587
   SMTP_USER     = your@gmail.com
   SMTP_PASS     = xxxx xxxx xxxx xxxx   ← Gmail App Password
   ```

5. Click **Deploy** — the monitor starts immediately.

6. Watch logs in the Railway dashboard to confirm it's polling.

---

## Option B — Render (free tier)

1. Sign up at [render.com](https://render.com)
2. New → **Background Worker** → connect your GitHub repo
3. Set **Docker** as environment, add the same env vars above
4. Deploy

> ⚠️ Render free tier may spin down after inactivity. Railway is more reliable for long-running scripts.

---

## Option C — Local (laptop / Mac / PC)

```bash
pip install -r requirements.txt
python muhs_monitor.py
```

The script prompts for roll number and email at startup.

---

## Gmail App Password (required for email alerts)

Gmail requires an **App Password** instead of your regular password when using SMTP:

1. Go to [myaccount.google.com/security](https://myaccount.google.com/security)
2. Enable **2-Step Verification** if not already on
3. Go to **App passwords** → Select app: Mail → Generate
4. Copy the 16-character password → paste as `SMTP_PASS`

---

## How email notifications work

When a result page goes live, the monitor automatically:
- Emails you the live URL
- Includes a direct link with your roll number pre-filled
- Sends a second email with your result page content (if the result is fetchable)

---

## Files

| File | Purpose |
|---|---|
| `muhs_monitor.py` | Main monitor script |
| `requirements.txt` | Python dependencies |
| `Dockerfile` | Container definition for cloud |
| `.env.example` | Template for env variables |
| `muhs_monitor.log` | Auto-created log file |
| `muhs_result_alert.txt` | Auto-created when result goes live |
