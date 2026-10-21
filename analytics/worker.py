import json
import logging
import pathlib
import signal
import time
from datetime import datetime

import common as c

logging.basicConfig(level=logging.INFO, format="%(asctime)s worker %(message)s")
log = logging.getLogger("worker")
HEARTBEAT = pathlib.Path("/tmp/heartbeat")
running = True


def stop(signum, frame):
    global running
    running = False


def handle(raw):
    ev = json.loads(raw)
    ts = datetime.strptime(ev["ts"], "%Y-%m-%dT%H:%M:%SZ")
    with c.get_db() as db, db.cursor() as cur:
        cur.execute("SELECT id FROM links WHERE code=%s", (ev["code"],))
        link = cur.fetchone()
        if not link:
            return  # link was deleted; drop the event
        cur.execute("INSERT INTO clicks (link_id, clicked_at, referrer, user_agent, source) "
                    "VALUES (%s, %s, %s, %s, %s)",
                    (link["id"], ts, ev.get("referrer") or None, ev.get("user_agent") or None,
                     ev.get("source", "web")))
        cur.execute("UPDATE links SET click_count = click_count + 1 WHERE id=%s", (link["id"],))


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
log.info("started")
while running:
    HEARTBEAT.touch()
    try:
        item = c.get_redis().brpop("clicks", timeout=5)
        if item:
            handle(item[1])
    except Exception as e:  # log and keep going; one bad event must not kill the worker
        log.error("error: %s", e)
        time.sleep(1)
log.info("stopped")
