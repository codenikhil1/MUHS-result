# Gunicorn config — runs once when the server starts (--preload mode)
# This ensures DB and background poller are initialized exactly once.

import web_app

def on_starting(server):
    web_app.init_db()
    web_app.start_background_poller()
