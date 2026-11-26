import json
import secrets
from datetime import date, datetime, timedelta, timezone

from .matching import cycle_start, mutually_eligible, score, tie_key
from .storage import connect


def now_utc():
    return datetime.now(timezone.utc).isoformat()


def age_on(birth_date):
    born = date.fromisoformat(birth_date)
    today = datetime.now(timezone.utc).date()
    return today.year - born.year - ((today.month, today.day) < (born.month, born.day))


INACTIVITY_DAYS = 90


def snapshot(db, user_id, now=None, *, include_paused=False):
    row = db.execute(
        """SELECT u.id, u.verified, u.status, u.created_at, u.last_active_at, u.matching_paused,
                  p.data AS profile, pref.data AS preferences,
                  ph.approved
           FROM users u LEFT JOIN profiles p ON p.user_id=u.id
           LEFT JOIN preferences pref ON pref.user_id=u.id
           LEFT JOIN photos ph ON ph.user_id=u.id WHERE u.id=?""", (user_id,)
    ).fetchone()
    if not row or not row["verified"] or row["status"] != "active" or not row["approved"] or not row["profile"] or not row["preferences"]:
        return None
    if row["matching_paused"] and not include_paused:
        return None
    active_at = datetime.fromisoformat(row["last_active_at"] or row["created_at"])
    if active_at.tzinfo is None:
        raise ValueError("Account activity timestamp must include a timezone.")
    if active_at <= (now or datetime.now(timezone.utc)) - timedelta(days=INACTIVITY_DAYS):
        return None
    profile, preferences = json.loads(row["profile"]), json.loads(row["preferences"])
    answers = {r["question_id"]: r["value"] for r in db.execute(
        "SELECT question_id,value FROM answers WHERE user_id=?", (user_id,)
    )}
    if len(answers) != 64 or age_on(profile["birth_date"]) < 18:
        return None
    return dict(profile, id=user_id, age=age_on(profile["birth_date"]), preferences=preferences, answers=answers)


def restricted(db, a, b):
    return bool(db.execute(
        """SELECT 1 FROM blocks WHERE (user_id=? AND target_id=?) OR (user_id=? AND target_id=?)
           UNION ALL SELECT 1 FROM reports WHERE status='open' AND
           ((reporter_id=? AND target_id=?) OR (reporter_id=? AND target_id=?)) LIMIT 1""",
        (a, b, b, a, a, b, b, a),
    ).fetchone())


def passed(db, a, b):
    return bool(db.execute(
        "SELECT 1 FROM reactions WHERE kind='pass' AND ((user_id=? AND candidate_id=?) OR (user_id=? AND candidate_id=?))",
        (a, b, b, a),
    ).fetchone())


def available(db, a, b):
    if restricted(db, a, b) or passed(db, a, b):
        return False
    left, right = snapshot(db, a), snapshot(db, b)
    return bool(left and right and mutually_eligible(left, right))


def generate_cycle(path, timezone_name, now=None):
    now = now or datetime.now(timezone.utc)
    cycle = cycle_start(now, timezone_name).isoformat()
    db = connect(path)
    try:
        db.execute("BEGIN IMMEDIATE")
        if db.execute("SELECT 1 FROM cycles WHERE id=?", (cycle,)).fetchone():
            db.rollback()
            return False
        db.execute("INSERT INTO cycles(id,generated_at) VALUES (?,?)", (cycle, now.astimezone(timezone.utc).isoformat()))
        users = [snapshot(db, row["id"], now) for row in db.execute("SELECT id FROM users ORDER BY id")]
        users = [user for user in users if user]
        salt = secrets.token_hex(32)
        candidates = {user["id"]: [] for user in users}
        for i, a in enumerate(users):
            for b in users[i + 1:]:
                if restricted(db, a["id"], b["id"]) or passed(db, a["id"], b["id"]) or not mutually_eligible(a, b):
                    continue
                overall, breakdown = score(a["answers"], b["answers"])
                for left, right in ((a, b), (b, a)):
                    candidates[left["id"]].append((overall, tie_key(salt, cycle, left["id"], right["id"]), right["id"], breakdown))
        for user_id, options in candidates.items():
            options.sort(key=lambda item: (-item[0], item[1]))
            for rank, (overall, _, candidate_id, breakdown) in enumerate(options[:3], 1):
                db.execute(
                    "INSERT INTO weekly_matches VALUES (?,?,?,?,?,?)",
                    (cycle, user_id, candidate_id, rank, overall, json.dumps(breakdown)),
                )
        db.commit()
        return True
    except Exception:
        db.rollback()
        raise
    finally:
        db.close()
