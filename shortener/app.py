import os
import re
import secrets
import string
from urllib.parse import urlparse

import pymysql
import redis
from flask import Flask, request, jsonify
from werkzeug.security import check_password_hash, generate_password_hash

import common as c

app = Flask(__name__)
c.register_common(app)

BASE_URL = os.environ.get("BASE_URL", "http://localhost:8080").rstrip("/")
SESSION_TTL = int(os.environ.get("SESSION_TTL_SECONDS", "86400"))
CACHE_TTL = int(os.environ.get("CACHE_TTL_SECONDS", "3600"))
RESERVED = {"ui", "api", "healthz", "readyz"}
ALPHABET = string.ascii_letters + string.digits
UNAME_RE = re.compile(r"^[A-Za-z0-9_]{3,50}$")


def body():
    data = request.get_json(silent=True)
    return data if isinstance(data, dict) else {}


def link_json(row):
    return {"code": row["code"], "url": row["url"],
            "short_url": f"{BASE_URL}/{row['code']}",
            "click_count": row["click_count"],
            "created_at": row["created_at"].strftime("%Y-%m-%dT%H:%M:%SZ")}


@app.post("/api/auth/register")
def register():
    d = body()
    username, password = d.get("username"), d.get("password")
    if not isinstance(username, str) or not UNAME_RE.match(username):
        return c.json_error("username must be 3-50 chars of A-Z a-z 0-9 _", 400)
    if not isinstance(password, str) or len(password) < 8:
        return c.json_error("password must be at least 8 characters", 400)
    try:
        with c.get_db() as db, db.cursor() as cur:
            cur.execute("INSERT INTO users (username, password_hash) VALUES (%s, %s)",
                        (username, generate_password_hash(password)))
            uid = cur.lastrowid
    except pymysql.err.IntegrityError:
        return c.json_error("username taken", 409)
    return jsonify({"id": uid, "username": username}), 201


@app.post("/api/auth/login")
def login():
    d = body()
    username, password = d.get("username"), d.get("password")
    if not isinstance(username, str) or not isinstance(password, str):
        return c.json_error("username and password required", 400)
    with c.get_db() as db, db.cursor() as cur:
        cur.execute("SELECT id, password_hash FROM users WHERE username=%s", (username,))
        user = cur.fetchone()
    if not user or not check_password_hash(user["password_hash"], password):
        return c.json_error("invalid credentials", 401)
    token = secrets.token_urlsafe(32)
    c.get_redis().set("session:" + token, user["id"], ex=SESSION_TTL)
    return jsonify({"token": token, "username": username})


@app.post("/api/auth/logout")
def logout():
    if c.current_user_id() is None:
        return c.json_error("unauthorized", 401)
    c.get_redis().delete("session:" + c.bearer_token())
    return "", 204


@app.get("/api/auth/me")
def me():
    uid = c.current_user_id()
    if uid is None:
        return c.json_error("unauthorized", 401)
    with c.get_db() as db, db.cursor() as cur:
        cur.execute("SELECT id, username FROM users WHERE id=%s", (uid,))
        user = cur.fetchone()
    if not user:
        return c.json_error("unauthorized", 401)
    return jsonify(user)


@app.post("/api/links")
def create_link():
    uid = c.current_user_id()
    if uid is None:
        return c.json_error("unauthorized", 401)
    url = body().get("url")
    if not isinstance(url, str) or len(url) > 2048:
        return c.json_error("invalid url", 400)
    try:
        parsed = urlparse(url)
        valid = parsed.scheme in ("http", "https") and bool(parsed.hostname)
    except ValueError:
        valid = False
    if not valid:
        return c.json_error("url must be http(s) with a host", 400)
    with c.get_db() as db, db.cursor() as cur:
        for _ in range(5):
            code = "".join(secrets.choice(ALPHABET) for _ in range(6))
            if code.lower() in RESERVED:
                continue
            try:
                cur.execute("INSERT INTO links (code, url, user_id) VALUES (%s, %s, %s)",
                            (code, url, uid))
                break
            except pymysql.err.IntegrityError:
                continue
        else:
            return c.json_error("could not generate a unique code", 500)
        cur.execute("SELECT code, url, click_count, created_at FROM links WHERE id=%s",
                    (cur.lastrowid,))
        row = cur.fetchone()
    try:
        c.get_redis().set("link:" + code, url, ex=CACHE_TTL)
    except redis.RedisError as e:
        app.logger.warning("cache warm failed: %s", e)
    return jsonify(link_json(row)), 201


@app.get("/api/links")
def list_links():
    uid = c.current_user_id()
    if uid is None:
        return c.json_error("unauthorized", 401)
    with c.get_db() as db, db.cursor() as cur:
        cur.execute("SELECT code, url, click_count, created_at FROM links "
                    "WHERE user_id=%s ORDER BY created_at DESC, id DESC", (uid,))
        rows = cur.fetchall()
    return jsonify([link_json(r) for r in rows])


@app.delete("/api/links/<code>")
def delete_link(code):
    uid = c.current_user_id()
    if uid is None:
        return c.json_error("unauthorized", 401)
    with c.get_db() as db, db.cursor() as cur:
        cur.execute("DELETE FROM links WHERE code=%s AND user_id=%s", (code, uid))
        deleted = cur.rowcount
    if not deleted:
        return c.json_error("not found", 404)
    try:
        c.get_redis().delete("link:" + code)
    except redis.RedisError as e:
        app.logger.warning("cache delete failed: %s", e)
    return "", 204
