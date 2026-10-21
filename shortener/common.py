import os
import socket

import pymysql
import redis
from flask import jsonify, request

_redis = None


def get_db():
    return pymysql.connect(
        host=os.environ["DB_HOST"], port=int(os.environ["DB_PORT"]),
        user=os.environ["DB_USER"], password=os.environ["DB_PASSWORD"],
        database=os.environ["DB_NAME"], cursorclass=pymysql.cursors.DictCursor,
        autocommit=True, connect_timeout=3)


def get_redis():
    global _redis
    if _redis is None:
        _redis = redis.Redis(
            host=os.environ["REDIS_HOST"], port=int(os.environ["REDIS_PORT"]),
            decode_responses=True, socket_connect_timeout=2, socket_timeout=6)
    return _redis


def bearer_token():
    h = request.headers.get("Authorization", "")
    return h[7:].strip() if h.startswith("Bearer ") else None


def current_user_id():
    token = bearer_token()
    if not token:
        return None
    try:
        uid = get_redis().get("session:" + token)
    except redis.RedisError:
        return None
    return int(uid) if uid else None


def json_error(msg, status):
    return jsonify({"error": msg}), status


def register_common(app):
    """Headers, JSON errors, /healthz and /readyz."""
    @app.after_request
    def add_headers(resp):
        resp.headers["X-Served-By"] = socket.gethostname()
        resp.headers["X-App-Version"] = os.environ.get("APP_VERSION", "dev")
        return resp

    @app.errorhandler(404)
    def _404(e):
        return json_error("not found", 404)

    @app.errorhandler(405)
    def _405(e):
        return json_error("method not allowed", 405)

    @app.errorhandler(pymysql.MySQLError)
    def _db(e):
        app.logger.error("database error: %s", e)
        return json_error("database unavailable", 503)

    @app.errorhandler(redis.RedisError)
    def _redis_err(e):
        app.logger.error("redis error: %s", e)
        return json_error("redis unavailable", 503)

    @app.get("/healthz")
    def healthz():
        return jsonify({"status": "ok"})

    @app.get("/readyz")
    def readyz():
        try:
            with get_db() as db, db.cursor() as cur:
                cur.execute("SELECT 1")
            get_redis().ping()
        except Exception as e:
            app.logger.error("not ready: %s", e)
            return jsonify({"status": "not ready"}), 503
        return jsonify({"status": "ready"})
