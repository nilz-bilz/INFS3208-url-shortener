"""Seed demo data: user demo/demo1234, 50 links, ~20,000 clicks over 30 days.
Reads DB_* env vars. Re-runnable: it replaces the existing demo user (clicks/links cascade)."""
import os
import random
import secrets
import string
from collections import Counter
from datetime import datetime, timedelta

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
links = []  # (id, code)
for i in range(N_LINKS):
    code = "".join(secrets.choice(alphabet) for _ in range(6))
    cur.execute("INSERT INTO links (code, url, user_id) VALUES (%s, %s, %s)",
                (code, f"https://example.com/page/{i}?ref=demo", uid))
    links.append((cur.lastrowid, code))

# Skewed popularity so the top list looks realistic
weights = [1 / (i + 1) for i in range(N_LINKS)]
now = datetime.utcnow()
rows, counts = [], Counter()
for lid in random.choices([l[0] for l in links], weights, k=N_CLICKS):
    ts = now - timedelta(seconds=random.randint(0, 30 * 86400))
    rows.append((lid, ts, "https://news.example.org/", "seed-script/1.0"))
    counts[lid] += 1
cur.executemany("INSERT INTO clicks (link_id, clicked_at, referrer, user_agent) "
                "VALUES (%s, %s, %s, %s)", rows)
cur.executemany("UPDATE links SET click_count=%s WHERE id=%s",
                [(n, lid) for lid, n in counts.items()])
db.commit()
print(f"seeded user demo, {N_LINKS} links, {N_CLICKS} clicks")
