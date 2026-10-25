"""Analytics API: per-link statistics (web vs QR, last 7 days) and top links.

Author: Nihal Singh Atwal (student ID 49299175, nihalsingh.atwal@student.uq.edu.au)
AI declaration: Written with assistance from Claude Code (Anthropic); reviewed and tested by the author.
"""
from datetime import datetime, timedelta, timezone

from flask import Flask, jsonify, request

import common as c

app = Flask(__name__)
c.register_common(app)


@app.get("/api/stats/top")
def top():
    """GET /api/stats/top: the caller's most-clicked links (limit 1-50, default 10)."""
    uid = c.current_user_id()
    if uid is None:
        return c.json_error("unauthorized", 401)
    try:
        limit = min(max(int(request.args.get("limit", 10)), 1), 50)
    except ValueError:
        limit = 10
    with c.get_db() as db, db.cursor() as cur:
        cur.execute("SELECT code, url, click_count FROM links WHERE user_id=%s "
                    "ORDER BY click_count DESC, id LIMIT %s", (uid, limit))
        rows = cur.fetchall()
    return jsonify(rows)


@app.get("/api/stats/<code>")
def stats(code):
    """GET /api/stats/<code>: totals, QR clicks, last click and a zero-filled 7-day breakdown."""
    uid = c.current_user_id()
    if uid is None:
        return c.json_error("unauthorized", 401)
    today = datetime.now(timezone.utc).date()
    start = today - timedelta(days=6)
    with c.get_db() as db, db.cursor() as cur:
        cur.execute("SELECT id, code, url, click_count FROM links "
                    "WHERE code=%s AND user_id=%s", (code, uid))
        link = cur.fetchone()
        if not link:
            return c.json_error("not found", 404)
        cur.execute("SELECT DATE(clicked_at) AS d, COUNT(*) AS n, SUM(source='qr') AS qr FROM clicks "
                    "WHERE link_id=%s AND clicked_at >= %s GROUP BY d", (link["id"], start))
        counts = {r["d"]: (r["n"], int(r["qr"])) for r in cur.fetchall()}
        cur.execute("SELECT COUNT(*) AS n FROM clicks WHERE link_id=%s AND source='qr'", (link["id"],))
        qr_total = cur.fetchone()["n"]
        cur.execute("SELECT MAX(clicked_at) AS last FROM clicks WHERE link_id=%s", (link["id"],))
        last = cur.fetchone()["last"]
    daily = []
    for i in range(7):
        d = start + timedelta(days=i)
        n, qr = counts.get(d, (0, 0))
        daily.append({"date": d.isoformat(), "clicks": n, "qr_clicks": qr})
    return jsonify({"code": link["code"], "url": link["url"],
                    "total_clicks": link["click_count"], "qr_clicks": qr_total,
                    "last_click_at": last.strftime("%Y-%m-%dT%H:%M:%SZ") if last else None,
                    "daily": daily})
