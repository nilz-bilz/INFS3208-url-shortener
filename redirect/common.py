"""Shared helpers: MySQL and Redis connections, session auth, JSON errors, health endpoints.
Duplicated in each backend service by design (no shared package).

Author: Nihal Singh Atwal (student ID 49299175, nihalsingh.atwal@student.uq.edu.au)
AI declaration: Written with assistance from Claude Code (Anthropic); reviewed and tested by the author.
"""
import os
import socket

import pymysql
import redis
from flask import jsonify, request

_redis = None


def get_db():
    """Open a new MySQL connection from the DB_* environment variables (dict rows, autocommit)."""
    return pymysql.connect(
        host=os.environ["DB_HOST"], port=int(os.environ["DB_PORT"]),
        user=os.environ["DB_USER"], password=os.environ["DB_PASSWORD"],
        database=os.environ["DB_NAME"], cursorclass=pymysql.cursors.DictCursor,
        autocommit=True, connect_timeout=3)


def get_redis():
    """Return the shared Redis client, creating it on first use."""
    global _redis
    if _redis is None:
        _redis = redis.Redis(
            host=os.environ["REDIS_HOST"], port=int(os.environ["REDIS_PORT"]),
            decode_responses=True, socket_connect_timeout=2, socket_timeout=6)
    return _redis


def bearer_token():
    """Return the token from the 'Authorization: Bearer <token>' header, or None."""
    h = request.headers.get("Authorization", "")
    return h[7:].strip() if h.startswith("Bearer ") else None


def current_user_id():
    """Return the user id for the request's session token (looked up in Redis), or None."""
    token = bearer_token()
    if not token:
        return None
    try:
        uid = get_redis().get("session:" + token)
    except redis.RedisError:
        return None
    return int(uid) if uid else None


def json_error(msg, status):
    """Return a JSON error response {"error": msg} with the given HTTP status."""
    return jsonify({"error": msg}), status


def register_common(app):
    """Headers, JSON errors, /healthz and /readyz."""
    @app.after_request
    def add_headers(resp):
        """Add X-Served-By (pod hostname) and X-App-Version to every response."""
        resp.headers["X-Served-By"] = socket.gethostname()
        resp.headers["X-App-Version"] = os.environ.get("APP_VERSION", "dev")
        return resp

    @app.errorhandler(404)
    def _404(e):
        """Unknown route: JSON 404."""
        return json_error("not found", 404)

    @app.errorhandler(405)
    def _405(e):
        """Wrong method: JSON 405."""
        return json_error("method not allowed", 405)

    @app.errorhandler(pymysql.MySQLError)
    def _db(e):
        """Turn any MySQL failure into a JSON 503 instead of a 500."""
        app.logger.error("database error: %s", e)
        return json_error("database unavailable", 503)

    @app.errorhandler(redis.RedisError)
    def _redis_err(e):
        """Turn any Redis failure into a JSON 503 instead of a 500."""
        app.logger.error("redis error: %s", e)
        return json_error("redis unavailable", 503)

    @app.get("/healthz")
    def healthz():
        """Liveness probe: always 200, checks no dependencies."""
        return jsonify({"status": "ok"})

    @app.get("/readyz")
    def readyz():
        """Readiness probe: 200 only if MySQL (SELECT 1) and Redis (PING) both respond, else 503."""
        try:
            with get_db() as db, db.cursor() as cur:
                cur.execute("SELECT 1")
            get_redis().ping()
        except Exception as e:
            app.logger.error("not ready: %s", e)
            return jsonify({"status": "not ready"}), 503
        return jsonify({"status": "ready"})
