import json
import os
from datetime import datetime, timezone

import redis
from flask import Flask, redirect, request, Response

import common as c

app = Flask(__name__)
c.register_common(app)

CACHE_TTL = int(os.environ.get("CACHE_TTL_SECONDS", "3600"))


@app.errorhandler(404)
def not_found(e):
    return Response("Short link not found", status=404, mimetype="text/plain")


@app.get("/")
def index():
    return redirect("/ui/", code=302)


@app.get("/<code>")
def follow(code):
    r = c.get_redis()
    url = None
    try:
        url = r.get("link:" + code)
    except redis.RedisError as e:
        app.logger.warning("cache read failed: %s", e)
    if url is None:
        with c.get_db() as db, db.cursor() as cur:
            cur.execute("SELECT url FROM links WHERE code=%s", (code,))
            row = cur.fetchone()
        if not row:
            return not_found(None)
        url = row["url"]
        try:
            r.set("link:" + code, url, ex=CACHE_TTL)
        except redis.RedisError as e:
            app.logger.warning("cache write failed: %s", e)
    event = {"code": code,
             "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
             "referrer": request.headers.get("Referer", "")[:255],
             "user_agent": request.headers.get("User-Agent", "")[:255]}
    try:
        r.lpush("clicks", json.dumps(event))
    except redis.RedisError as e:
        app.logger.warning("click enqueue failed: %s", e)
    resp = redirect(url, code=302)
    resp.headers["Cache-Control"] = "no-store"
    return resp
