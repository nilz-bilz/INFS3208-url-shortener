"""Redirect service: the hot read-only path. Cache-first lookup, queues a click event, answers 302.

Author: Nihal Singh Atwal (student ID 49299175, nihalsingh.atwal@student.uq.edu.au)
AI declaration: Written with assistance from Claude Code (Anthropic); reviewed and tested by the author.
"""
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
    """Plain-text 404 page for unknown or expired short links."""
    return Response("Short link not found", status=404, mimetype="text/plain")


@app.get("/")
def index():
    """GET /: send visitors to the UI."""
    return redirect("/ui/", code=302)


@app.get("/<code>")
def follow(code):
    """GET /<code>: look up the target (Redis, then MySQL), queue a click event, answer 302."""
    r = c.get_redis()
    url = None
    try:
        url = r.get("link:" + code)
    except redis.RedisError as e:
        app.logger.warning("cache read failed: %s", e)
    if url is None:
        with c.get_db() as db, db.cursor() as cur:
            cur.execute("SELECT url, TIMESTAMPDIFF(SECOND, UTC_TIMESTAMP(), expires_at) AS ttl "
                        "FROM links WHERE code=%s "
                        "AND (expires_at IS NULL OR expires_at > UTC_TIMESTAMP())", (code,))
            row = cur.fetchone()
        if not row:
            return not_found(None)
        url = row["url"]
        try:
            # cache no longer than the link has left to live
            r.set("link:" + code, url, ex=min(CACHE_TTL, max(1, row["ttl"])) if row["ttl"] is not None else CACHE_TTL)
        except redis.RedisError as e:
            app.logger.warning("cache write failed: %s", e)
    event = {"code": code,
             "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
             "referrer": request.headers.get("Referer", "")[:255],
             "user_agent": request.headers.get("User-Agent", "")[:255],
             "source": "qr" if request.args.get("src") == "qr" else "web"}
    try:
        r.lpush("clicks", json.dumps(event))
    except redis.RedisError as e:
        app.logger.warning("click enqueue failed: %s", e)
    resp = redirect(url, code=302)
    resp.headers["Cache-Control"] = "no-store"
    return resp
