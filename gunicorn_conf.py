# Gunicorn config — runs once when the server starts
import web_app

def on_starting(server):
    web_app._log_startup_config()
    web_app.init_db()
    web_app.start_background_poller()
