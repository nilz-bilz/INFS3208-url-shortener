"""Seed demo data: user demo/demo1234, 50 links, ~20,000 clicks over 30 days.
Includes expiry cases (links 30-34 expire in 2 hours, 35-39 in 7 days, 45-49 already expired)
and QR scans (about 15% of clicks, 60% on links 5-9).
Reads DB_* env vars. Re-runnable: it replaces the existing demo user (clicks/links cascade)."""
import os
import random
import secrets
import string
from collections import Counter
from datetime import datetime, timedelta, timezone

import pymysql
from werkzeug.security import generate_password_hash

N_LINKS, N_CLICKS = 50, 20000
db = pymysql.connect(host=os.environ["DB_HOST"], port=int(os.environ["DB_PORT"]),
                     user=os.environ["DB_USER"], password=os.environ["DB_PASSWORD"],
                     database=os.environ["DB_NAME"], autocommit=False)
cur = db.cursor()
cur.execute("DELETE FROM users WHERE username=%s", ("demo",))
cur.execute("INSERT INTO users (username, password_hash) VALUES (%s, %s)",
            ("demo", generate_password_hash("demo1234")))
uid = cur.lastrowid

alphabet = string.ascii_letters + string.digits
now = datetime.now(timezone.utc).replace(tzinfo=None)


def expiry(i):
    """None = never; links 30-34 expire soon, 35-39 in a week, 45-49 expired 2 days ago."""
    if 30 <= i < 35:
        return now + timedelta(hours=2)
    if 35 <= i < 40:
        return now + timedelta(days=7)
    if 45 <= i < 50:
        return now - timedelta(days=2)
    return None


links = []  # (id, expires_at)
for i in range(N_LINKS):
    code = "".join(secrets.choice(alphabet) for _ in range(6))
    exp = expiry(i)
    cur.execute("INSERT INTO links (code, url, user_id, created_at, expires_at) VALUES (%s, %s, %s, %s, %s)",
                (code, f"https://example.com/page/{i}?ref=demo", uid, now - timedelta(days=30), exp))
    links.append((cur.lastrowid, exp))

# Skewed popularity so the top list looks realistic
weights = [1 / (i + 1) for i in range(N_LINKS)]
rows, counts = [], Counter()
for idx in random.choices(range(N_LINKS), weights, k=N_CLICKS):
    lid, exp = links[idx]
    # expired links only have clicks from before they expired
    newest = (now - exp).total_seconds() if exp and exp < now else 0
    ts = now - timedelta(seconds=random.uniform(newest, 30 * 86400))
    qr_share = 0.6 if 5 <= idx < 10 else 0.15
    rows.append((lid, ts.replace(microsecond=0), "https://news.example.org/", "seed-script/1.0",
                 "qr" if random.random() < qr_share else "web"))
    counts[lid] += 1
cur.executemany("INSERT INTO clicks (link_id, clicked_at, referrer, user_agent, source) "
                "VALUES (%s, %s, %s, %s, %s)", rows)
cur.executemany("UPDATE links SET click_count=%s WHERE id=%s",
                [(n, lid) for lid, n in counts.items()])
db.commit()
print(f"seeded user demo, {N_LINKS} links, {N_CLICKS} clicks")
