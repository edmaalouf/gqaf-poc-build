import hashlib
import json
import io
import os
import secrets
import sqlite3
import tempfile
import threading
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

from werkzeug.security import generate_password_hash
from PIL import Image

from pair.app import create_app, deliver_registration
from pair.matching import conservative_distance_km, cycle_start, distance_km, score
from pair.questions import CATEGORIES, QUESTIONS
from pair.service import generate_cycle, now_utc
from pair.storage import connect, initialize


PASSWORD = "a secure test password"
PASSWORD_HASH = generate_password_hash(PASSWORD)
HEADERS = {"X-Pair-Request": "1"}
MONDAY = datetime(2026, 11, 23, 9, 0, tzinfo=timezone.utc)


class PairTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = str(Path(self.tmp.name) / "test.sqlite3")
        self.app = create_app({"TESTING": True, "DATABASE": self.path, "SECRET_KEY": "test-key"})
        self.client = self.app.test_client()
        self.deliveries = []
        delivery = patch("pair.app.deliver_registration", side_effect=lambda email, code: self.deliveries.append((email, code)))
        delivery.start()
        self.addCleanup(delivery.stop)

    def tearDown(self):
        self.tmp.cleanup()

    def add_user(self, name, *, complete=True, gender="woman", preferences=None):
        profile = {
            "name": name, "birth_date": "1990-01-01", "city": "Example city",
            "bio": "A complete example profile", "gender": gender, "intention": "serious",
            "interests": ["Books", "Walks"], "lifestyle": {"smoking": "no", "drinking": "sometimes", "children": "no"},
            "latitude": 51.5, "longitude": -0.1,
        }
        pref = preferences or {"min_age": 18, "max_age": 80, "distance": 100, "genders": ["woman", "man", "nonbinary", "other"], "intentions": ["serious"], "dealbreakers": {}}
        with closing(connect(self.path)) as db, db:
            user = db.execute("INSERT INTO users(email,password_hash,verified,created_at) VALUES (?,?,1,?)", (name + "@example.test", PASSWORD_HASH, now_utc())).lastrowid
            db.execute("INSERT INTO profiles VALUES (?,?)", (user, json.dumps(profile)))
            db.execute("INSERT INTO preferences VALUES (?,?)", (user, json.dumps(pref)))
            db.execute("INSERT INTO photos VALUES (?,?,1)", (user, b"photo"))
            if complete:
                db.executemany("INSERT INTO answers VALUES (?,?,?)", [(user, i, 3) for i in range(1, 65)])
        return user

    def sign_in(self, user_id):
        token = secrets.token_urlsafe(32)
        with closing(connect(self.path)) as db, db:
            db.execute(
                "INSERT INTO auth_sessions(token_hash,user_id,created_at,expires_at) VALUES (?,?,?,?)",
                (hashlib.sha256(token.encode("ascii")).hexdigest(), user_id, now_utc(), "2099-01-01T00:00:00+00:00"),
            )
        with self.client.session_transaction() as session:
            session["user_id"] = user_id
            session["auth_token"] = token

    def test_sessions_are_revoked_on_logout_and_are_device_specific(self):
        self.add_user("a")
        login = {"email": "a@example.test", "password": PASSWORD}
        self.assertEqual(self.client.post("/api/v1/auth/login", json=login, headers=HEADERS).status_code, 200)
        stolen = self.app.test_client()
        stolen.set_cookie("session", self.client.get_cookie("session").value)
        other_device = self.app.test_client()
        self.assertEqual(other_device.post("/api/v1/auth/login", json=login, headers=HEADERS).status_code, 200)
        self.assertEqual(self.client.post("/api/v1/auth/logout", headers=HEADERS).status_code, 200)
        self.assertEqual(stolen.get("/api/v1/me").status_code, 401)
        self.assertEqual(other_device.get("/api/v1/me").status_code, 200)
        with other_device.session_transaction() as session:
            token = session["auth_token"]
        with closing(connect(self.path)) as db:
            rows = db.execute("SELECT token_hash FROM auth_sessions").fetchall()
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]["token_hash"], hashlib.sha256(token.encode("ascii")).hexdigest())
            self.assertNotEqual(token, rows[0]["token_hash"])

    def test_expired_legacy_and_suspended_sessions_are_rejected(self):
        user = self.add_user("a")
        with self.client.session_transaction() as session:
            session["user_id"] = user
        self.assertEqual(self.client.get("/api/v1/me").status_code, 401)
        self.sign_in(user)
        with closing(connect(self.path)) as db, db:
            db.execute("UPDATE auth_sessions SET expires_at=? WHERE user_id=?", ("2000-01-01T00:00:00+00:00", user))
        self.assertEqual(self.client.get("/api/v1/me").status_code, 401)
        self.sign_in(user)
        saved = self.client.get_cookie("session").value
        result = self.app.test_cli_runner().invoke(args=["moderate", "suspend", str(user)])
        self.assertEqual(result.exit_code, 0, result.output)
        with closing(connect(self.path)) as db, db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM auth_sessions WHERE user_id=?", (user,)).fetchone()[0], 0)
            db.execute("UPDATE users SET status='active' WHERE id=?", (user,))
        self.client.set_cookie("session", saved)
        self.assertEqual(self.client.get("/api/v1/me").status_code, 401)

    def test_suspension_during_login_cannot_create_a_later_valid_session(self):
        user = self.add_user("a")

        def suspend_during_password_check(_hash, _password):
            result = self.app.test_cli_runner().invoke(args=["moderate", "suspend", str(user)])
            self.assertEqual(result.exit_code, 0, result.output)
            return True

        with patch("pair.app.check_password_hash", side_effect=suspend_during_password_check):
            response = self.client.post("/api/v1/auth/login", json={"email": "a@example.test", "password": PASSWORD}, headers=HEADERS)
        self.assertEqual(response.status_code, 401)
        with closing(connect(self.path)) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM auth_sessions WHERE user_id=?", (user,)).fetchone()[0], 0)

    def test_secure_cookie_mode_requires_explicit_32_byte_secret(self):
        with self.assertRaises(ValueError):
            create_app({"TESTING": True, "DATABASE": self.path, "SESSION_COOKIE_SECURE": True, "SECRET_KEY": "short"})
        secure_app = create_app({
            "TESTING": True, "DATABASE": self.path,
            "SESSION_COOKIE_SECURE": True, "SECRET_KEY": "a" * 40,
        })
        client = secure_app.test_client()
        response = client.post("/api/v1/auth/register", json={"email": "secure@example.test"}, headers=HEADERS)
        self.assertNotIn("Set-Cookie", response.headers)
        code = self.deliveries[-1][1]
        response = client.post("/api/v1/auth/activate", json={"code": code, "password": PASSWORD, "adult": True}, headers=HEADERS)
        self.assertIn("Secure", response.headers["Set-Cookie"])

    def test_existing_database_is_preserved_when_session_table_is_added(self):
        old_path = str(Path(self.tmp.name) / "old.sqlite3")
        with closing(sqlite3.connect(old_path)) as db, db:
            db.execute("""CREATE TABLE users (
                id INTEGER PRIMARY KEY, email TEXT NOT NULL UNIQUE, password_hash TEXT NOT NULL,
                verified INTEGER NOT NULL DEFAULT 0, verification_hash TEXT,
                status TEXT NOT NULL DEFAULT 'active', created_at TEXT NOT NULL
            )""")
            db.execute("INSERT INTO users(email,password_hash,created_at,verified) VALUES (?,?,?,1)", ("old@example.test", PASSWORD_HASH, now_utc()))
        initialize(old_path)
        initialize(old_path)
        with closing(connect(old_path)) as db:
            self.assertEqual(db.execute("SELECT email FROM users").fetchone()["email"], "old@example.test")
            self.assertEqual(db.execute("SELECT verified FROM users").fetchone()["verified"], 0)
            self.assertEqual(db.execute("SELECT COUNT(*) FROM auth_sessions").fetchone()[0], 0)
            self.assertEqual(db.execute("SELECT COUNT(*) FROM auth_attempts").fetchone()[0], 0)

    def test_auth_rate_limits_are_separate_and_return_retry_time(self):
        routes = [("post", "/api/v1/auth/register", 5, 400),
                  ("post", "/api/v1/auth/login", 10, 400),
                  ("post", "/api/v1/auth/activate", 10, 400),
                  ("post", "/api/v1/auth/verify/request", 5, 401),
                  ("post", "/api/v1/auth/verify", 10, 401),
                  ("delete", "/api/v1/account", 10, 401)]
        for method, route, limit, ordinary_status in routes:
            with self.subTest(route=route):
                for _ in range(limit):
                    response = getattr(self.client, method)(route, json={}, headers=HEADERS)
                    self.assertEqual(response.status_code, ordinary_status)
                response = getattr(self.client, method)(route, json={}, headers=HEADERS)
                self.assertEqual(response.status_code, 429)
                self.assertIn("Too many attempts", response.json["error"])
                self.assertGreaterEqual(int(response.headers["Retry-After"]), 1)
                self.assertLessEqual(int(response.headers["Retry-After"]), 900)
        self.assertEqual(self.client.post("/api/v1/auth/logout", headers=HEADERS).status_code, 200)

    def test_auth_rate_limit_ignores_forwarded_headers_and_expires(self):
        response = self.client.post("/api/v1/auth/login", json={}, headers=HEADERS, environ_overrides={"REMOTE_ADDR": ""})
        self.assertEqual(response.status_code, 503)
        for i in range(10):
            response = self.client.post("/api/v1/auth/login", json={}, headers={**HEADERS, "X-Forwarded-For": f"203.0.113.{i}"})
            self.assertEqual(response.status_code, 400)
        self.assertEqual(self.client.post("/api/v1/auth/login", json={}, headers={**HEADERS, "X-Forwarded-For": "203.0.113.99"}).status_code, 429)
        self.assertEqual(self.client.post("/api/v1/auth/login", json={}, headers=HEADERS, environ_base={"REMOTE_ADDR": "192.0.2.2"}).status_code, 400)
        with closing(connect(self.path)) as db, db:
            buckets = db.execute("SELECT DISTINCT bucket FROM auth_attempts").fetchall()
            self.assertEqual(len(buckets), 2)
            self.assertTrue(all(len(row["bucket"]) == 64 and "127.0.0.1" not in row["bucket"] for row in buckets))
            db.execute("UPDATE auth_attempts SET attempted_at=?", (time.time() - 901,))
        self.assertEqual(self.client.post("/api/v1/auth/login", json={}, headers=HEADERS).status_code, 400)
        with closing(connect(self.path)) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM auth_attempts").fetchone()[0], 1)

    def test_auth_rate_limit_counts_successful_login(self):
        self.add_user("a")
        for _ in range(9):
            self.assertEqual(self.client.post("/api/v1/auth/login", json={}, headers=HEADERS).status_code, 400)
        details = {"email": "a@example.test", "password": PASSWORD}
        self.assertEqual(self.client.post("/api/v1/auth/login", json=details, headers=HEADERS).status_code, 200)
        self.assertEqual(self.client.post("/api/v1/auth/login", json=details, headers=HEADERS).status_code, 429)
        self.assertEqual(self.client.get("/api/v1/me").status_code, 200)

    def test_auth_rate_limit_is_atomic_across_app_instances(self):
        other_app = create_app({"TESTING": True, "DATABASE": self.path, "SECRET_KEY": "test-key"})
        barrier = threading.Barrier(12)

        def attempt(index):
            app = self.app if index % 2 else other_app
            client = app.test_client()
            barrier.wait(timeout=10)
            return client.post("/api/v1/auth/login", json={}, headers=HEADERS).status_code

        with ThreadPoolExecutor(max_workers=12) as executor:
            statuses = list(executor.map(attempt, range(12)))
        self.assertEqual(statuses.count(400), 10)
        self.assertEqual(statuses.count(429), 2)
        with closing(connect(self.path)) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM auth_attempts").fetchone()[0], 10)

    def test_questions_and_scoring(self):
        self.assertEqual(len(QUESTIONS), 64)
        self.assertEqual([len(questions) for _, questions in CATEGORIES], [8] * 8)
        self.assertEqual([q["id"] for q in QUESTIONS], list(range(1, 65)))
        a = dict.fromkeys(range(1, 65), 5)
        for value, expected in [(5, 100), (4, 75), (3, 50), (2, 25), (1, 0)]:
            total, categories = score(a, dict.fromkeys(range(1, 65), value))
            self.assertEqual(total, expected)
            self.assertTrue(all(result == expected for result in categories.values()))
        b = dict(a)
        for q in range(1, 9):
            b[q] = 1
        self.assertEqual(score(a, b)[0], 87.5)
        with self.assertRaises(ValueError):
            score(a, {1: 5})

    def test_schedule_timezone_and_dst(self):
        self.assertEqual(cycle_start(datetime(2026, 11, 23, 13, 59, tzinfo=timezone.utc), "America/New_York").isoformat(), "2026-11-16T14:00:00+00:00")
        self.assertEqual(cycle_start(datetime(2026, 11, 23, 14, 0, tzinfo=timezone.utc), "America/New_York").isoformat(), "2026-11-23T14:00:00+00:00")
        self.assertEqual(cycle_start(datetime(2026, 7, 6, 13, 0, tzinfo=timezone.utc), "America/New_York").isoformat(), "2026-07-06T13:00:00+00:00")

    def test_incomplete_conflicts_dealbreakers_and_no_candidates(self):
        a = self.add_user("a")
        self.add_user("incomplete", complete=False)
        self.add_user("conflict", preferences={"min_age": 18, "max_age": 25, "distance": 100, "genders": ["woman"], "intentions": ["serious"], "dealbreakers": {}})
        self.add_user("dealbreaker", preferences={"min_age": 18, "max_age": 80, "distance": 100, "genders": ["woman"], "intentions": ["serious"], "dealbreakers": {"smoking": "yes"}})
        self.assertTrue(generate_cycle(self.path, "UTC", MONDAY))
        with closing(connect(self.path)) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM weekly_matches WHERE user_id=?", (a,)).fetchone()[0], 0)
        self.sign_in(a)
        self.assertEqual(self.client.get("/api/v1/matches").json["matches"], [])

    def test_ties_top_three_idempotency_block_and_no_backfill(self):
        a = self.add_user("a")
        for name in ["b", "c", "d", "e"]:
            self.add_user(name)
        self.assertTrue(generate_cycle(self.path, "UTC", MONDAY))
        with closing(connect(self.path)) as db:
            before = [tuple(row) for row in db.execute("SELECT candidate_id,rank,score FROM weekly_matches WHERE user_id=? ORDER BY rank", (a,))]
        self.assertEqual(len(before), 3)
        self.assertTrue(all(row[2] == 100 for row in before))
        self.assertFalse(generate_cycle(self.path, "UTC", MONDAY))
        self.sign_in(a)
        self.assertEqual(self.client.post(f"/api/v1/safety/{before[0][0]}", json={"kind": "block"}, headers=HEADERS).status_code, 200)
        after = self.client.get("/api/v1/matches").json["matches"]
        self.assertEqual([m["id"] for m in after], [row[0] for row in before[1:]])
        self.assertNotIn("answers", json.dumps(after))
        self.assertNotIn("latitude", json.dumps(after))
        self.assertFalse(generate_cycle(self.path, "UTC", MONDAY))
        self.assertEqual(len(self.client.get("/api/v1/matches").json["matches"]), 2)

    def test_fewer_than_three_and_mutual_interest_required(self):
        a, b = self.add_user("a"), self.add_user("b")
        generate_cycle(self.path, "UTC", MONDAY)
        self.sign_in(a)
        self.assertEqual(len(self.client.get("/api/v1/matches").json["matches"]), 1)
        self.assertEqual(self.client.post("/api/v1/conversations/1/messages", json={"body": "Hello"}, headers=HEADERS).status_code, 404)
        self.assertEqual(self.client.post(f"/api/v1/matches/{b}/reaction", json={"kind": "like"}, headers=HEADERS).status_code, 200)
        self.assertEqual(self.client.get("/api/v1/conversations").json, [])
        self.sign_in(b)
        self.assertEqual(self.client.post(f"/api/v1/matches/{a}/reaction", json={"kind": "like"}, headers=HEADERS).status_code, 200)
        conversation = self.client.get("/api/v1/conversations").json[0]["id"]
        self.assertEqual(self.client.post(f"/api/v1/conversations/{conversation}/messages", json={"body": "Hello"}, headers=HEADERS).status_code, 201)
        self.sign_in(a)
        self.assertEqual(self.client.get("/api/v1/conversations").json[0]["unread"], 1)
        self.assertEqual(self.client.post(f"/api/v1/safety/{b}", json={"kind": "report", "reason": "Safety concern"}, headers=HEADERS).status_code, 200)
        self.sign_in(b)
        self.assertEqual(self.client.get("/api/v1/conversations").json, [])
        self.assertEqual(self.client.post(f"/api/v1/conversations/{conversation}/messages", json={"body": "Blocked"}, headers=HEADERS).status_code, 404)

    def test_pass_is_permanent_and_deletion_cascades(self):
        a, b = self.add_user("a"), self.add_user("b")
        generate_cycle(self.path, "UTC", MONDAY)
        self.sign_in(a)
        self.assertEqual(self.client.post(f"/api/v1/matches/{b}/reaction", json={"kind": "pass"}, headers=HEADERS).status_code, 200)
        generate_cycle(self.path, "UTC", datetime(2026, 11, 30, 9, tzinfo=timezone.utc))
        self.assertEqual(self.client.get("/api/v1/matches").json["matches"], [])
        self.assertEqual(self.client.delete("/api/v1/account", json={"password": PASSWORD}, headers=HEADERS).status_code, 200)
        self.assertEqual(self.client.get("/api/v1/me").status_code, 401)
        with closing(connect(self.path)) as db:
            for table, column in [("users", "id"), ("profiles", "user_id"), ("preferences", "user_id"), ("answers", "user_id"), ("photos", "user_id"), ("weekly_matches", "user_id"), ("reactions", "user_id"), ("auth_sessions", "user_id")]:
                self.assertEqual(db.execute(f"SELECT COUNT(*) FROM {table} WHERE {column}=?", (a,)).fetchone()[0], 0)

    def test_auth_csrf_and_validation(self):
        self.assertEqual(self.client.get("/api/v1/questions").status_code, 401)
        self.assertEqual(self.client.post("/api/v1/auth/register", json={}).status_code, 403)
        user = self.add_user("a")
        self.sign_in(user)
        self.assertEqual(self.client.put("/api/v1/answers/1", json={"value": 6}, headers=HEADERS).status_code, 400)
        self.assertEqual(self.client.put("/api/v1/preferences", json={"min_age": 18, "max_age": 80, "distance": 50, "genders": [{}], "intentions": ["serious"], "dealbreakers": {}}, headers=HEADERS).status_code, 400)
        self.assertEqual(self.client.get("/api/v1/photo/999").status_code, 404)

    def test_onboarding_requires_every_step_and_photo_approval(self):
        response = self.client.post("/api/v1/auth/register", json={"email": "new@example.test"}, headers=HEADERS)
        self.assertEqual(response.status_code, 202)
        code = self.deliveries[-1][1]
        self.assertEqual(self.client.get("/api/v1/me").status_code, 401)
        self.assertEqual(self.client.post("/api/v1/auth/activate", json={"code": code, "password": PASSWORD, "adult": True}, headers=HEADERS).status_code, 201)
        self.assertFalse(self.client.get("/api/v1/me").json["ready"])
        profile = {"name": "New", "birth_date": "1990-01-01", "city": "Example", "bio": "A complete example profile", "gender": "woman", "intention": "serious", "interests": ["Books"], "lifestyle": {"smoking": "no", "drinking": "no", "children": "no"}, "latitude": 51.5, "longitude": -0.1}
        prefs = {"min_age": 18, "max_age": 80, "distance": 100, "genders": ["woman"], "intentions": ["serious"], "dealbreakers": {}}
        self.assertEqual(self.client.put("/api/v1/profile", json=profile, headers=HEADERS).status_code, 200)
        self.assertEqual(self.client.put("/api/v1/preferences", json=prefs, headers=HEADERS).status_code, 200)
        for i in range(1, 65):
            self.assertEqual(self.client.put(f"/api/v1/answers/{i}", json={"value": 3}, headers=HEADERS).status_code, 200)
        image = io.BytesIO()
        Image.new("RGB", (10, 10), "green").save(image, "JPEG")
        image.seek(0)
        self.assertEqual(self.client.post("/api/v1/photo", data={"photo": (image, "test.jpg")}, headers=HEADERS).status_code, 200)
        me = self.client.get("/api/v1/me").json
        self.assertEqual(me["photo"], "pending")
        self.assertFalse(me["ready"])
        result = self.app.test_cli_runner().invoke(args=["moderate", "approve-photo", str(me["id"])])
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertTrue(self.client.get("/api/v1/me").json["ready"])

    def test_top_three_are_independent(self):
        pref = {"min_age": 18, "max_age": 80, "distance": 100, "genders": ["man"], "intentions": ["serious"], "dealbreakers": {}}
        a = self.add_user("a", preferences=pref)
        b = self.add_user("b", gender="man")
        for name in ["c", "d", "e"]:
            self.add_user(name)
        with closing(connect(self.path)) as db, db:
            db.execute("UPDATE answers SET value=1 WHERE user_id=?", (a,))
            db.execute("UPDATE answers SET value=5 WHERE user_id<>?", (a,))
        generate_cycle(self.path, "UTC", MONDAY)
        with closing(connect(self.path)) as db:
            a_candidates = [r[0] for r in db.execute("SELECT candidate_id FROM weekly_matches WHERE user_id=?", (a,))]
            b_candidates = [r[0] for r in db.execute("SELECT candidate_id FROM weekly_matches WHERE user_id=?", (b,))]
        self.assertEqual(a_candidates, [b])
        self.assertEqual(len(b_candidates), 3)
        self.assertNotIn(a, b_candidates)

    def test_asymmetric_like_creates_private_invitation_and_conversation(self):
        pref = {"min_age": 18, "max_age": 80, "distance": 100, "genders": ["man"], "intentions": ["serious"], "dealbreakers": {}}
        a = self.add_user("a", preferences=pref)
        b = self.add_user("b", gender="man")
        for name in ("c", "d", "e"):
            self.add_user(name)
        with closing(connect(self.path)) as db, db:
            db.execute("UPDATE answers SET value=1 WHERE user_id=?", (a,))
            db.execute("UPDATE answers SET value=5 WHERE user_id<>?", (a,))
        generate_cycle(self.path, "UTC", MONDAY)
        self.sign_in(b)
        before = self.client.get("/api/v1/matches").json
        self.assertEqual(len(before["matches"]), 3)
        self.assertEqual(before["invitations"], [])
        self.assertEqual(self.client.post(f"/api/v1/matches/{a}/reaction", json={"kind": "like"}, headers=HEADERS).status_code, 404)
        self.sign_in(a)
        self.assertEqual(self.client.post(f"/api/v1/matches/{b}/reaction", json={"kind": "like"}, headers=HEADERS).status_code, 200)
        self.sign_in(b)
        after = self.client.get("/api/v1/matches").json
        self.assertEqual([m["id"] for m in before["matches"]], [m["id"] for m in after["matches"]])
        self.assertEqual([m["id"] for m in after["invitations"]], [a])
        self.assertNotIn("rank", after["invitations"][0])
        self.assertEqual(self.client.get(f"/api/v1/photo/{a}").status_code, 200)
        self.assertEqual(self.client.post(f"/api/v1/matches/{a}/reaction", json={"kind": "like"}, headers=HEADERS).status_code, 200)
        self.assertEqual(self.client.get("/api/v1/matches").json["invitations"], [])
        self.assertEqual(len(self.client.get("/api/v1/conversations").json), 1)

    def test_private_invitations_obey_safety_and_expire_with_cycle(self):
        pref = {"min_age": 18, "max_age": 80, "distance": 100, "genders": ["man"], "intentions": ["serious"], "dealbreakers": {}}
        a, b = self.add_user("a", preferences=pref), self.add_user("b", gender="man")
        for name in ("c", "d", "e"):
            self.add_user(name)
        with closing(connect(self.path)) as db, db:
            db.execute("UPDATE answers SET value=1 WHERE user_id=?", (a,))
            db.execute("UPDATE answers SET value=5 WHERE user_id<>?", (a,))
        generate_cycle(self.path, "UTC", MONDAY)
        self.sign_in(a)
        self.client.post(f"/api/v1/matches/{b}/reaction", json={"kind": "like"}, headers=HEADERS)
        self.sign_in(b)
        self.assertEqual([m["id"] for m in self.client.get("/api/v1/matches").json["invitations"]], [a])
        self.assertEqual(self.client.post(f"/api/v1/safety/{a}", json={"kind": "block"}, headers=HEADERS).status_code, 200)
        self.assertEqual(self.client.get("/api/v1/matches").json["invitations"], [])
        self.assertEqual(self.client.get(f"/api/v1/photo/{a}").status_code, 404)
        self.assertEqual(self.client.post(f"/api/v1/matches/{a}/reaction", json={"kind": "like"}, headers=HEADERS).status_code, 404)
        with closing(connect(self.path)) as db, db:
            db.execute("DELETE FROM blocks")
            db.execute("UPDATE reactions SET created_at=? WHERE user_id=? AND candidate_id=?", (MONDAY.isoformat(), a, b))
        generate_cycle(self.path, "UTC", MONDAY + timedelta(days=7))
        self.assertEqual(self.client.get("/api/v1/matches").json["invitations"], [])
        self.assertEqual(self.client.post(f"/api/v1/matches/{a}/reaction", json={"kind": "like"}, headers=HEADERS).status_code, 404)

    def test_match_location_does_not_expose_user_entered_address(self):
        a, b = self.add_user("a"), self.add_user("b")
        self.sign_in(b)
        profile = self.client.get("/api/v1/me").json["profile"]
        profile["city"] = "123 Example Street, Example City"
        self.assertEqual(self.client.put("/api/v1/profile", json=profile, headers=HEADERS).status_code, 200)
        generate_cycle(self.path, "UTC", MONDAY)
        self.sign_in(a)
        card = self.client.get("/api/v1/matches").json["matches"][0]
        self.assertNotIn("city", card)
        self.assertNotIn(profile["city"], json.dumps(card))
        self.assertEqual(card["distance_label"], "About 25 km away")
        self.assertNotIn("latitude", card)
        self.assertNotIn("longitude", card)
        self.sign_in(b)
        profile["latitude"] = 51.51
        profile["longitude"] = -0.11
        self.assertEqual(self.client.put("/api/v1/profile", json=profile, headers=HEADERS).status_code, 200)
        self.sign_in(a)
        self.assertEqual(self.client.get("/api/v1/matches").json["matches"][0]["distance_label"], card["distance_label"])

    def test_inactive_users_are_excluded_until_they_sign_in(self):
        now = datetime.now(timezone.utc)
        a, b = self.add_user("a"), self.add_user("b")
        with closing(connect(self.path)) as db, db:
            db.execute("UPDATE users SET last_active_at=? WHERE id=?", ((now - timedelta(days=91)).isoformat(), b))
        generate_cycle(self.path, "UTC", now)
        self.sign_in(a)
        self.assertEqual(self.client.get("/api/v1/matches").json["matches"], [])
        self.assertEqual(self.client.post("/api/v1/auth/login", json={"email": "b@example.test", "password": PASSWORD}, headers=HEADERS).status_code, 200)
        self.sign_in(a)
        self.assertEqual(self.client.get("/api/v1/matches").json["matches"], [])
        generate_cycle(self.path, "UTC", now + timedelta(days=7))
        self.assertEqual([m["id"] for m in self.client.get("/api/v1/matches").json["matches"]], [b])

    def test_pause_hides_introductions_and_conversations_until_resumed(self):
        a, b = self.add_user("a"), self.add_user("b")
        generate_cycle(self.path, "UTC", MONDAY)
        self.sign_in(a)
        self.client.post(f"/api/v1/matches/{b}/reaction", json={"kind": "like"}, headers=HEADERS)
        self.sign_in(b)
        self.client.post(f"/api/v1/matches/{a}/reaction", json={"kind": "like"}, headers=HEADERS)
        conversation = self.client.get("/api/v1/conversations").json[0]["id"]
        self.assertEqual(self.client.put("/api/v1/privacy", json={"matching_paused": "yes"}, headers=HEADERS).status_code, 400)
        self.assertEqual(self.client.put("/api/v1/privacy", json={"matching_paused": True}, headers=HEADERS).status_code, 200)
        me = self.client.get("/api/v1/me").json
        self.assertTrue(me["matching_paused"])
        self.assertTrue(me["ready"])
        self.assertEqual(self.client.get("/api/v1/conversations").json, [])
        self.sign_in(a)
        self.assertEqual(self.client.get("/api/v1/matches").json["matches"], [])
        self.assertEqual(self.client.get("/api/v1/conversations").json, [])
        self.assertEqual(self.client.get(f"/api/v1/photo/{b}").status_code, 404)
        self.assertEqual(self.client.post(f"/api/v1/conversations/{conversation}/messages", json={"body": "Hello"}, headers=HEADERS).status_code, 404)
        generate_cycle(self.path, "UTC", MONDAY + timedelta(days=7))
        self.sign_in(b)
        self.assertEqual(self.client.put("/api/v1/privacy", json={"matching_paused": False}, headers=HEADERS).status_code, 200)
        self.assertFalse(self.client.get("/api/v1/me").json["matching_paused"])
        self.assertEqual(self.client.get("/api/v1/conversations").json[0]["id"], conversation)
        self.sign_in(a)
        self.assertEqual(self.client.get("/api/v1/matches").json["matches"], [])
        self.assertEqual(self.client.post(f"/api/v1/conversations/{conversation}/messages", json={"body": "Welcome back"}, headers=HEADERS).status_code, 201)

    def test_registration_login_and_verification_failures(self):
        self.assertEqual(self.client.post("/api/v1/auth/register", json=[], headers=HEADERS).status_code, 400)
        self.assertEqual(self.client.post("/api/v1/auth/register", json={"email": "invalid"}, headers=HEADERS).status_code, 400)
        details = {"email": "new@example.test"}
        self.assertEqual(self.client.post("/api/v1/auth/register", json=details, headers=HEADERS).status_code, 202)
        code = self.deliveries[-1][1]
        for data in [
            {"code": "wrong", "password": PASSWORD, "adult": True},
            {"code": code, "password": "short", "adult": True},
            {"code": code, "password": PASSWORD, "adult": False},
        ]:
            with self.subTest(data=data):
                self.assertEqual(self.client.post("/api/v1/auth/activate", json=data, headers=HEADERS).status_code, 400)
        activation = {"code": code, "password": PASSWORD, "adult": True}
        self.assertEqual(self.client.post("/api/v1/auth/activate", json=activation, headers=HEADERS).status_code, 201)
        self.assertTrue(self.client.get("/api/v1/me").json["verified"])
        self.assertEqual(self.client.post("/api/v1/auth/activate", json=activation, headers=HEADERS).status_code, 400)
        self.assertEqual(self.client.post("/api/v1/auth/logout", headers=HEADERS).status_code, 200)
        self.assertEqual(self.client.post("/api/v1/auth/login", json={"email": details["email"], "password": "wrong"}, headers=HEADERS).status_code, 401)
        self.assertEqual(self.client.post("/api/v1/auth/login", json={"email": details["email"], "password": PASSWORD}, headers=HEADERS).status_code, 200)
        self.assertEqual(self.client.delete("/api/v1/account", json={"password": "wrong"}, headers=HEADERS).status_code, 403)
        self.assertEqual(self.client.get("/api/v1/me").status_code, 200)

    def test_registration_does_not_disclose_existing_or_pending_accounts(self):
        self.add_user("existing")
        new = self.client.post("/api/v1/auth/register", json={"email": "new@example.test", "password": "attacker password"}, headers=HEADERS)
        code = self.deliveries[-1][1]
        pending = self.client.post("/api/v1/auth/register", json={"email": "new@example.test"}, headers=HEADERS)
        existing = self.client.post("/api/v1/auth/register", json={"email": "existing@example.test"}, headers=HEADERS)
        self.assertEqual([item[1] for item in self.deliveries[1:]], [None, None])
        for response in (new, pending, existing):
            self.assertEqual(response.status_code, 202)
            self.assertEqual(response.json, new.json)
            self.assertNotIn("Set-Cookie", response.headers)
        self.assertEqual(self.client.post("/api/v1/auth/login", json={"email": "new@example.test", "password": "attacker password"}, headers=HEADERS).status_code, 401)
        with closing(connect(self.path)) as db:
            row = db.execute("SELECT token_hash FROM pending_registrations WHERE email=?", ("new@example.test",)).fetchone()
            self.assertEqual(row["token_hash"], "email:" + hashlib.sha256(code.encode()).hexdigest())
            self.assertEqual(db.execute("SELECT COUNT(*) FROM users WHERE email=?", ("new@example.test",)).fetchone()[0], 0)
        self.assertEqual(self.client.post("/api/v1/auth/activate", json={"code": code, "password": PASSWORD, "adult": True}, headers=HEADERS).status_code, 201)
        self.assertEqual(self.client.post("/api/v1/auth/logout", headers=HEADERS).status_code, 200)
        self.assertEqual(self.client.post("/api/v1/auth/login", json={"email": "new@example.test", "password": "attacker password"}, headers=HEADERS).status_code, 401)
        self.assertEqual(self.client.post("/api/v1/auth/login", json={"email": "new@example.test", "password": PASSWORD}, headers=HEADERS).status_code, 200)

    def test_registration_email_uses_authenticated_tls_and_fails_closed(self):
        settings = {"PAIR_SMTP_HOST": "mail.example.test", "PAIR_SMTP_USERNAME": "test", "PAIR_SMTP_PASSWORD": "test-password", "PAIR_SMTP_FROM": "pair@example.test"}
        with patch.dict(os.environ, settings, clear=True), patch("pair.app.smtplib.SMTP_SSL") as smtp:
            deliver_registration("new@example.test", "test-code")
            smtp.assert_called_once()
            self.assertEqual(smtp.call_args.args, ("mail.example.test", 465))
            self.assertTrue(smtp.call_args.kwargs["context"].check_hostname)
            client = smtp.return_value.__enter__.return_value
            client.login.assert_called_once_with("test", "test-password")
            self.assertIn("test-code", client.send_message.call_args.args[0].get_content())
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(ValueError):
                deliver_registration("new@example.test", "test-code")
        with patch("pair.app.deliver_registration", side_effect=OSError("unavailable")), self.assertLogs(self.app.logger, level="ERROR") as logs:
            response = self.client.post("/api/v1/auth/register", json={"email": "new@example.test"}, headers=HEADERS)
        self.assertEqual(response.status_code, 503)
        self.assertNotIn("new@example.test", " ".join(logs.output))
        with closing(connect(self.path)) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM pending_registrations").fetchone()[0], 0)
        self.assertEqual(self.client.post("/api/v1/auth/register", json={"email": "new@example.test"}, headers=HEADERS).status_code, 202)
        self.assertIsNotNone(self.deliveries[-1][1])

    def test_old_console_registration_codes_are_not_accepted(self):
        code = secrets.token_urlsafe(32)
        with closing(connect(self.path)) as db, db:
            db.execute("INSERT INTO pending_registrations VALUES (?,?,?)", ("old@example.test", hashlib.sha256(code.encode()).hexdigest(), "2099-01-01T00:00:00+00:00"))
        response = self.client.post("/api/v1/auth/activate", json={"code": code, "password": PASSWORD, "adult": True}, headers=HEADERS)
        self.assertEqual(response.status_code, 400)

    def test_distance_eligibility_uses_private_conservative_grid(self):
        own = {"latitude": 51.5, "longitude": -0.1}
        first = {"latitude": 51.501, "longitude": -0.101}
        second = {"latitude": 51.52, "longitude": -0.12}
        self.assertEqual(conservative_distance_km(own, first), conservative_distance_km(own, second))
        for left, right in [(own, second), ({"latitude": 89.99, "longitude": 179.99}, {"latitude": 89.98, "longitude": -179.99})]:
            self.assertGreaterEqual(conservative_distance_km(left, right), distance_km(left, right))

    def test_expired_registration_can_be_restarted(self):
        self.client.post("/api/v1/auth/register", json={"email": "new@example.test"}, headers=HEADERS)
        old_code = self.deliveries[-1][1]
        with closing(connect(self.path)) as db, db:
            db.execute("UPDATE pending_registrations SET expires_at='2000-01-01T00:00:00+00:00'")
        self.assertEqual(self.client.post("/api/v1/auth/activate", json={"code": old_code, "password": PASSWORD, "adult": True}, headers=HEADERS).status_code, 400)
        self.client.post("/api/v1/auth/register", json={"email": "new@example.test"}, headers=HEADERS)
        code = self.deliveries[-1][1]
        self.assertNotEqual(old_code, code)
        self.assertEqual(self.client.post("/api/v1/auth/activate", json={"code": code, "password": PASSWORD, "adult": True}, headers=HEADERS).status_code, 201)

    def test_registration_code_can_only_be_used_once_concurrently(self):
        self.client.post("/api/v1/auth/register", json={"email": "new@example.test"}, headers=HEADERS)
        code = self.deliveries[-1][1]
        barrier = threading.Barrier(2)

        def activate():
            client = self.app.test_client()
            barrier.wait(timeout=10)
            return client.post("/api/v1/auth/activate", json={"code": code, "password": PASSWORD, "adult": True}, headers=HEADERS).status_code

        with ThreadPoolExecutor(max_workers=2) as executor:
            statuses = list(executor.map(lambda _: activate(), range(2)))
        self.assertEqual(sorted(statuses), [201, 400])
        with closing(connect(self.path)) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM users WHERE email='new@example.test'").fetchone()[0], 1)

    def test_legacy_accounts_require_a_new_email_verification_code(self):
        user = self.add_user("legacy")
        code = secrets.token_urlsafe(32)
        with closing(connect(self.path)) as db, db:
            db.execute("UPDATE users SET verified=0,verification_hash=? WHERE id=?", (hashlib.sha256(code.encode()).hexdigest(), user))
        self.sign_in(user)
        self.assertEqual(self.client.post("/api/v1/auth/verify", json={"code": code}, headers=HEADERS).status_code, 400)
        self.assertEqual(self.client.post("/api/v1/auth/verify/request", json={}, headers=HEADERS).status_code, 202)
        self.assertEqual(self.deliveries[-1][0], "legacy@example.test")
        code = self.deliveries[-1][1]
        self.assertEqual(self.client.post("/api/v1/auth/verify", json={"code": code}, headers=HEADERS).status_code, 200)
        self.assertTrue(self.client.get("/api/v1/me").json["verified"])
        self.assertEqual(self.client.post("/api/v1/auth/verify", json={"code": code}, headers=HEADERS).status_code, 400)

    def test_invalid_profiles_and_preferences_preserve_saved_data(self):
        user = self.add_user("a")
        self.sign_in(user)
        original = self.client.get("/api/v1/me").json
        profile = original["profile"]
        for key, invalid in [
            ("birth_date", "2000-99-99"), ("birth_date", "2020-01-01"),
            ("gender", []), ("intention", "invalid"), ("interests", []),
            ("lifestyle", {}), ("latitude", 91), ("name", ""),
        ]:
            with self.subTest(field=key, value=invalid):
                self.assertEqual(self.client.put("/api/v1/profile", json={**profile, key: invalid}, headers=HEADERS).status_code, 400)
        pref = original["preferences"]
        for change in [
            {"min_age": 70, "max_age": 20}, {"min_age": 18.5},
            {"distance": 0}, {"genders": []}, {"genders": ["woman", "woman"]},
            {"intentions": ["invalid"]}, {"dealbreakers": {"unknown": "no"}},
        ]:
            with self.subTest(change=change):
                self.assertEqual(self.client.put("/api/v1/preferences", json={**pref, **change}, headers=HEADERS).status_code, 400)
        current = self.client.get("/api/v1/me").json
        self.assertEqual(current["profile"], profile)
        self.assertEqual(current["preferences"], pref)
        self.assertEqual(self.client.put("/api/v1/answers/65", json={"value": 3}, headers=HEADERS).status_code, 400)
        self.assertEqual(self.client.put("/api/v1/answers/1", json={"value": True}, headers=HEADERS).status_code, 400)

    def test_photo_validation_access_and_reapproval(self):
        a, b, outsider = self.add_user("a"), self.add_user("b"), self.add_user("outsider", complete=False)
        generate_cycle(self.path, "UTC", MONDAY)
        self.sign_in(a)
        self.assertEqual(self.client.get(f"/api/v1/photo/{b}").status_code, 200)
        self.assertEqual(self.client.get(f"/api/v1/photo/{outsider}").status_code, 404)
        self.assertEqual(self.client.post("/api/v1/photo", data={}, headers=HEADERS).status_code, 400)
        self.assertEqual(self.client.post("/api/v1/photo", data={"photo": (io.BytesIO(b"not an image"), "bad.png")}, headers=HEADERS).status_code, 400)
        gif = io.BytesIO()
        Image.new("RGB", (10, 10)).save(gif, "GIF")
        gif.seek(0)
        self.assertEqual(self.client.post("/api/v1/photo", data={"photo": (gif, "bad.gif")}, headers=HEADERS).status_code, 400)
        image = io.BytesIO()
        Image.new("RGB", (10, 10)).save(image, "PNG")
        image.seek(0)
        self.assertEqual(self.client.post("/api/v1/photo", data={"photo": (image, "new.png")}, headers=HEADERS).status_code, 200)
        self.assertEqual(self.client.get(f"/api/v1/photo/{a}").status_code, 200)
        self.sign_in(b)
        self.assertEqual(self.client.get(f"/api/v1/photo/{a}").status_code, 404)
        self.assertEqual(self.client.get("/api/v1/matches").json["matches"], [])

    def test_reaction_messaging_read_and_unmatch(self):
        a, b, stranger = self.add_user("a"), self.add_user("b"), self.add_user("stranger", complete=False)
        generate_cycle(self.path, "UTC", MONDAY)
        self.sign_in(a)
        self.assertEqual(self.client.post(f"/api/v1/matches/{b}/reaction", json={"kind": "bad"}, headers=HEADERS).status_code, 400)
        self.assertEqual(self.client.post(f"/api/v1/matches/{stranger}/reaction", json={"kind": "like"}, headers=HEADERS).status_code, 404)
        self.assertEqual(self.client.post(f"/api/v1/matches/{b}/reaction", json={"kind": "like"}, headers=HEADERS).status_code, 200)
        self.assertEqual(self.client.post(f"/api/v1/matches/{b}/reaction", json={"kind": "like"}, headers=HEADERS).status_code, 200)
        self.assertEqual(self.client.post(f"/api/v1/matches/{b}/reaction", json={"kind": "pass"}, headers=HEADERS).status_code, 409)
        self.sign_in(b)
        self.client.post(f"/api/v1/matches/{a}/reaction", json={"kind": "like"}, headers=HEADERS)
        conversation = self.client.get("/api/v1/conversations").json[0]["id"]
        self.assertEqual(self.client.post(f"/api/v1/conversations/{conversation}/messages", json={"body": "Hello"}, headers=HEADERS).status_code, 201)
        self.sign_in(stranger)
        self.assertEqual(self.client.get(f"/api/v1/conversations/{conversation}/messages").status_code, 404)
        self.sign_in(a)
        messages = self.client.get(f"/api/v1/conversations/{conversation}/messages").json
        self.assertEqual([(m["body"], m["mine"]) for m in messages], [("Hello", False)])
        self.assertEqual(self.client.get("/api/v1/conversations").json[0]["unread"], 0)
        self.assertEqual(self.client.post(f"/api/v1/conversations/{conversation}/messages", json={"body": ""}, headers=HEADERS).status_code, 400)
        self.assertEqual(self.client.post(f"/api/v1/conversations/{conversation}/unmatch", headers=HEADERS).status_code, 200)
        self.assertEqual(self.client.get(f"/api/v1/conversations/{conversation}/messages").status_code, 404)
        self.sign_in(b)
        self.assertEqual(self.client.get("/api/v1/conversations").json, [])
        self.assertEqual(self.client.get("/api/v1/matches").json["matches"], [])

    def test_moderation_and_safety_workflows(self):
        a, b = self.add_user("a"), self.add_user("b")
        generate_cycle(self.path, "UTC", MONDAY)
        self.sign_in(a)
        self.assertEqual(self.client.post(f"/api/v1/safety/{a}", json={"kind": "block"}, headers=HEADERS).status_code, 400)
        self.assertEqual(self.client.post("/api/v1/safety/999", json={"kind": "block"}, headers=HEADERS).status_code, 404)
        self.assertEqual(self.client.post(f"/api/v1/safety/{b}", json={"kind": "report", "reason": "bad"}, headers=HEADERS).status_code, 400)
        self.assertEqual(self.client.post(f"/api/v1/safety/{b}", json={"kind": "report", "reason": "Safety concern"}, headers=HEADERS).status_code, 200)
        runner = self.app.test_cli_runner()
        self.assertIn("Safety concern", runner.invoke(args=["moderate", "reports"]).output)
        self.assertNotEqual(runner.invoke(args=["moderate", "resolve-report", "999"]).exit_code, 0)
        self.assertEqual(runner.invoke(args=["moderate", "resolve-report", "1"]).exit_code, 0)
        self.assertEqual(len(self.client.get("/api/v1/matches").json["matches"]), 1)
        with closing(connect(self.path)) as db, db:
            db.execute("UPDATE photos SET approved=0 WHERE user_id=?", (b,))
        self.assertIn(str(b), runner.invoke(args=["moderate", "photos"]).output)
        output = str(Path(self.tmp.name) / "photo.jpg")
        self.assertEqual(runner.invoke(args=["export-photo", str(b), output]).exit_code, 0)
        self.assertNotEqual(runner.invoke(args=["export-photo", str(b), output]).exit_code, 0)
        self.assertEqual(runner.invoke(args=["moderate", "reject-photo", str(b)]).exit_code, 0)
        self.assertNotEqual(runner.invoke(args=["export-photo", str(b), output]).exit_code, 0)
        self.assertNotEqual(runner.invoke(args=["moderate", "approve-photo", "999"]).exit_code, 0)
        self.assertNotEqual(runner.invoke(args=["moderate", "suspend"]).exit_code, 0)
        self.assertEqual(runner.invoke(args=["moderate", "suspend", str(a)]).exit_code, 0)
        self.assertEqual(self.client.get("/api/v1/me").status_code, 401)

    def test_generation_failure_rolls_back_and_worker_retries(self):
        self.add_user("a")
        self.add_user("b")
        with patch("pair.service.score", side_effect=ValueError("test failure")):
            with self.assertRaises(ValueError):
                generate_cycle(self.path, "UTC", MONDAY)
        with closing(connect(self.path)) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM cycles").fetchone()[0], 0)
            self.assertEqual(db.execute("SELECT COUNT(*) FROM weekly_matches").fetchone()[0], 0)
        self.assertTrue(generate_cycle(self.path, "UTC", MONDAY))
        from pair import worker
        with patch.dict("os.environ", {"PAIR_DB": self.path, "PAIR_TIMEZONE": "UTC"}), \
             patch("pair.worker.generate_cycle", side_effect=[RuntimeError("transient"), True]), \
             patch("pair.worker.time.sleep", side_effect=[None, KeyboardInterrupt]):
            with self.assertLogs(level="INFO") as logs, self.assertRaises(KeyboardInterrupt):
                worker.main()
        self.assertIn("retrying", "\n".join(logs.output))
        self.assertIn("Published", "\n".join(logs.output))


if __name__ == "__main__":
    unittest.main()
