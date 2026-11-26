import hashlib
import hmac
import io
import json
import math
import os
import re
import secrets
import smtplib
import ssl
import time
from datetime import datetime, timedelta, timezone
from email.message import EmailMessage
from functools import wraps
from pathlib import Path

import click
from flask import Flask, abort, g, jsonify, request, send_file, session
from PIL import Image, UnidentifiedImageError
from werkzeug.exceptions import HTTPException
from werkzeug.security import check_password_hash, generate_password_hash

from .questions import QUESTIONS
from .matching import distance_km
from .service import age_on, available, now_utc, restricted, snapshot
from .storage import connect, initialize


GENDERS = {"woman", "man", "nonbinary", "other"}
INTENTIONS = {"serious", "casual", "exploring", "other"}
LIFESTYLE = {"smoking", "drinking", "children"}
DUMMY_PASSWORD_HASH = generate_password_hash("not a real account password")
AUTH_RATE_LIMITS = {"register": 5, "activate": 10, "request_verification": 5, "verify": 10, "login": 10, "delete_account": 10}
AUTH_RATE_WINDOW_SECONDS = 15 * 60


def deliver_registration(email, code):
    host = os.environ.get("PAIR_SMTP_HOST")
    username = os.environ.get("PAIR_SMTP_USERNAME")
    password = os.environ.get("PAIR_SMTP_PASSWORD")
    sender = os.environ.get("PAIR_SMTP_FROM")
    port = os.environ.get("PAIR_SMTP_PORT", "465")
    if not all((host, username, password, sender)) or not port.isdecimal() or not 1 <= int(port) <= 65535:
        raise ValueError("Registration email is not configured.")
    message = EmailMessage()
    message["From"] = sender
    message["To"] = email
    message["Subject"] = "PAIR registration"
    if code:
        message.set_content(f"Your registration code is:\n\n{code}\n\nIt expires in 30 minutes. If you did not request it, ignore this email.")
    else:
        message.set_content("If you already have an account, sign in. Otherwise, wait for the registration code you requested or request another after 30 minutes.")
    with smtplib.SMTP_SSL(host, int(port), timeout=10, context=ssl.create_default_context()) as client:
        client.login(username, password)
        client.send_message(message)


def fail(message, status=400):
    abort(status, description=message)


def body():
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        fail("Expected a JSON object.")
    return data


def text(value, name, maximum, minimum=1):
    if not isinstance(value, str) or not minimum <= len(value.strip()) <= maximum:
        fail(f"{name} must be {minimum}–{maximum} characters.")
    return value.strip()


def number(value, name, minimum, maximum):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not minimum <= value <= maximum:
        fail(f"Invalid {name}.")
    return value


def choices(value, allowed, name):
    if not isinstance(value, list) or not value or any(not isinstance(v, str) or v not in allowed for v in value) or len(value) != len(set(value)):
        fail(f"Choose at least one valid {name}.")
    return value


def validate_profile(data):
    try:
        birth = text(data.get("birth_date"), "Date of birth", 10, 10)
        if age_on(birth) < 18 or age_on(birth) > 120:
            fail("You must be at least 18 years old.")
    except ValueError:
        fail("Enter a valid date of birth.")
    gender = data.get("gender")
    intention = data.get("intention")
    if not isinstance(gender, str) or not isinstance(intention, str) or gender not in GENDERS or intention not in INTENTIONS:
        fail("Choose a valid gender and intention.")
    interests = data.get("interests")
    if not isinstance(interests, list) or not 1 <= len(interests) <= 12:
        fail("Add between 1 and 12 interests.")
    interests = [text(item, "Interest", 40) for item in interests]
    lifestyle = data.get("lifestyle")
    if not isinstance(lifestyle, dict) or set(lifestyle) != LIFESTYLE:
        fail("Complete your lifestyle details.")
    lifestyle = {key: text(value, key, 40) for key, value in lifestyle.items()}
    return {
        "name": text(data.get("name"), "First name", 40),
        "birth_date": birth,
        "city": text(data.get("city"), "General location", 80),
        "bio": text(data.get("bio"), "Bio", 600, 10),
        "gender": gender,
        "intention": intention,
        "interests": interests,
        "lifestyle": lifestyle,
        "latitude": number(data.get("latitude"), "latitude", -90, 90),
        "longitude": number(data.get("longitude"), "longitude", -180, 180),
    }


def validate_preferences(data):
    low = number(data.get("min_age"), "minimum age", 18, 120)
    high = number(data.get("max_age"), "maximum age", 18, 120)
    if type(low) is not int or type(high) is not int or low > high:
        fail("Enter a valid age range.")
    dealbreakers = data.get("dealbreakers")
    if not isinstance(dealbreakers, dict) or not set(dealbreakers).issubset(LIFESTYLE):
        fail("Invalid dealbreakers.")
    return {
        "min_age": low, "max_age": high,
        "distance": number(data.get("distance"), "distance", 1, 20000),
        "genders": choices(data.get("genders"), GENDERS, "gender"),
        "intentions": choices(data.get("intentions"), INTENTIONS, "intention"),
        "dealbreakers": {k: text(v, k, 40) for k, v in dealbreakers.items()},
    }


def create_app(config=None):
    app = Flask(__name__, static_folder="../web", static_url_path="")
    secure_cookie_setting = os.environ.get("PAIR_SECURE_COOKIES", "0")
    if secure_cookie_setting not in ("0", "1"):
        raise ValueError("PAIR_SECURE_COOKIES must be 0 or 1.")
    configured_secret = os.environ.get("PAIR_SECRET")
    app.config.update(
        SECRET_KEY=configured_secret or secrets.token_hex(32),
        DATABASE=os.environ.get("PAIR_DB", "instance/pair.sqlite3"),
        MAX_CONTENT_LENGTH=4 * 1024 * 1024,
        SESSION_COOKIE_HTTPONLY=True, SESSION_COOKIE_SAMESITE="Strict",
        SESSION_COOKIE_SECURE=secure_cookie_setting == "1",
        PERMANENT_SESSION_LIFETIME=timedelta(days=7),
    )
    if config:
        app.config.update(config)
    if app.config["SESSION_COOKIE_SECURE"]:
        explicit_secret = (config or {}).get("SECRET_KEY") or configured_secret
        if not isinstance(explicit_secret, str) or len(explicit_secret.encode("utf-8")) < 32:
            raise ValueError("Secure-cookie mode requires an explicit PAIR_SECRET of at least 32 bytes.")
    initialize(app.config["DATABASE"])

    def db():
        if "db" not in g:
            g.db = connect(app.config["DATABASE"])
        return g.db

    @app.teardown_appcontext
    def close_db(_error):
        connection = g.pop("db", None)
        if connection:
            connection.close()

    @app.errorhandler(HTTPException)
    def error(exc):
        return jsonify(error=exc.description), exc.code

    @app.before_request
    def protect():
        if request.method in ("POST", "PUT", "PATCH", "DELETE") and request.headers.get("X-Pair-Request") != "1":
            fail("Missing request verification header.", 403)
        limit = AUTH_RATE_LIMITS.get(request.endpoint)
        if limit is None:
            return
        if not request.remote_addr:
            fail("Client address unavailable; please try again.", 503)
        secret = app.config["SECRET_KEY"]
        if isinstance(secret, str):
            secret = secret.encode("utf-8")
        bucket = hmac.new(secret, f"{request.endpoint}\0{request.remote_addr}".encode("utf-8"), hashlib.sha256).hexdigest()
        with db():
            db().execute("BEGIN IMMEDIATE")
            now = time.time()
            cutoff = now - AUTH_RATE_WINDOW_SECONDS
            db().execute("DELETE FROM auth_attempts WHERE attempted_at<=?", (cutoff,))
            attempts = db().execute(
                "SELECT COUNT(*) AS count, MIN(attempted_at) AS oldest FROM auth_attempts WHERE bucket=?",
                (bucket,),
            ).fetchone()
            if attempts["count"] < limit:
                db().execute("INSERT INTO auth_attempts(bucket,attempted_at) VALUES (?,?)", (bucket, now))
                return
            retry_after = max(1, math.ceil(attempts["oldest"] + AUTH_RATE_WINDOW_SECONDS - now))
        response = jsonify(error=f"Too many attempts. Please try again in {retry_after} seconds.")
        response.status_code = 429
        response.headers["Retry-After"] = str(retry_after)
        return response

    @app.after_request
    def headers(response):
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["Content-Security-Policy"] = "default-src 'self'; img-src 'self' blob:; style-src 'self' 'unsafe-inline'; script-src 'self'; object-src 'none'; frame-ancestors 'none'"
        return response

    def login_required(fn):
        @wraps(fn)
        def wrapped(*args, **kwargs):
            user_id = session.get("user_id")
            token = session.get("auth_token")
            if type(user_id) is not int or not isinstance(token, str) or not re.fullmatch(r"[A-Za-z0-9_-]{43}", token):
                session.clear()
                fail("Please sign in with an active account.", 401)
            token_hash = hashlib.sha256(token.encode("ascii")).hexdigest()
            user = db().execute(
                """SELECT u.id FROM users u JOIN auth_sessions s ON s.user_id=u.id
                   WHERE u.id=? AND u.status='active' AND s.token_hash=? AND s.expires_at>?""",
                (user_id, token_hash, now_utc()),
            ).fetchone()
            if not user:
                session.clear()
                fail("Please sign in with an active account.", 401)
            g.user_id = user_id
            now = datetime.now(timezone.utc)
            with db():
                db().execute(
                    "UPDATE users SET last_active_at=? WHERE id=? AND status='active'",
                    (now.isoformat(), user_id),
                )
            return fn(*args, **kwargs)
        return wrapped

    def create_session(user_id):
        token = secrets.token_urlsafe(32)
        now = datetime.now(timezone.utc)
        expires = now + app.permanent_session_lifetime
        db().execute("DELETE FROM auth_sessions WHERE user_id=? AND expires_at<=?", (user_id, now.isoformat()))
        db().execute(
            "INSERT INTO auth_sessions(token_hash,user_id,created_at,expires_at) VALUES (?,?,?,?)",
            (hashlib.sha256(token.encode("ascii")).hexdigest(), user_id, now.isoformat(), expires.isoformat()),
        )
        return token

    def establish_session(user_id, token):
        session.clear()
        session["user_id"] = user_id
        session["auth_token"] = token
        session.permanent = True

    @app.get("/")
    def index():
        return app.send_static_file("index.html")

    @app.post("/api/v1/auth/register")
    def register():
        data = body()
        email = text(data.get("email"), "Email", 254).lower()
        if not re.fullmatch(r"[^@\s]+@[^@\s]+\.[^@\s]+", email):
            fail("Enter a valid email address.")
        token = secrets.token_urlsafe(32)
        token_hash = "email:" + hashlib.sha256(token.encode()).hexdigest()
        now = datetime.now(timezone.utc)
        with db():
            db().execute("DELETE FROM pending_registrations WHERE email=? AND expires_at<=?", (email, now.isoformat()))
            cursor = db().execute(
                """INSERT INTO pending_registrations(email,token_hash,expires_at)
                   SELECT ?,?,? WHERE NOT EXISTS (SELECT 1 FROM users WHERE email=?)
                   AND NOT EXISTS (SELECT 1 FROM pending_registrations WHERE email=?)""",
                (email, token_hash,
                 (now + timedelta(minutes=30)).isoformat(), email, email),
            )
        try:
            deliver_registration(email, token if cursor.rowcount else None)
        except (OSError, smtplib.SMTPException, ValueError):
            if cursor.rowcount:
                with db():
                    db().execute("DELETE FROM pending_registrations WHERE token_hash=?", (token_hash,))
            app.logger.error("Registration email delivery failed; check SMTP configuration and connectivity.")
            fail("Registration email is temporarily unavailable. Please try again later.", 503)
        return jsonify(message="If registration is available, a code has been emailed. Otherwise, sign in."), 202

    @app.post("/api/v1/auth/activate")
    def activate():
        data = body()
        token = text(data.get("code"), "Registration code", 100)
        password = text(data.get("password"), "Password", 128, 12)
        if data.get("adult") is not True:
            fail("You must confirm that you are 18 or older.")
        password_hash = generate_password_hash(password)
        token_hash = "email:" + hashlib.sha256(token.encode()).hexdigest()
        with db():
            db().execute("BEGIN IMMEDIATE")
            pending = db().execute(
                "SELECT email FROM pending_registrations WHERE token_hash=? AND expires_at>?",
                (token_hash, now_utc()),
            ).fetchone()
            if not pending or db().execute("SELECT 1 FROM users WHERE email=?", (pending["email"],)).fetchone():
                fail("Invalid or expired registration code.")
            cursor = db().execute(
                "INSERT INTO users(email,password_hash,verified,created_at) VALUES (?,?,1,?)",
                (pending["email"], password_hash, now_utc()),
            )
            db().execute("DELETE FROM pending_registrations WHERE token_hash=?", (token_hash,))
            auth_token = create_session(cursor.lastrowid)
        establish_session(cursor.lastrowid, auth_token)
        return jsonify(message="Account created and verified."), 201

    @app.post("/api/v1/auth/verify/request")
    @login_required
    def request_verification():
        email = db().execute("SELECT email FROM users WHERE id=?", (g.user_id,)).fetchone()["email"]
        token = secrets.token_urlsafe(32)
        token_hash = "verify:" + hashlib.sha256(token.encode()).hexdigest()
        now = datetime.now(timezone.utc)
        with db():
            db().execute("DELETE FROM pending_registrations WHERE email=? AND expires_at<=?", (email, now.isoformat()))
            cursor = db().execute(
                "INSERT OR IGNORE INTO pending_registrations(email,token_hash,expires_at) VALUES (?,?,?)",
                (email, token_hash, (now + timedelta(minutes=30)).isoformat()),
            )
        try:
            deliver_registration(email, token if cursor.rowcount else None)
        except (OSError, smtplib.SMTPException, ValueError):
            if cursor.rowcount:
                with db():
                    db().execute("DELETE FROM pending_registrations WHERE token_hash=?", (token_hash,))
            app.logger.error("Verification email delivery failed; check SMTP configuration and connectivity.")
            fail("Verification email is temporarily unavailable. Please try again later.", 503)
        return jsonify(message="Check your email for a verification code. If a request is pending, wait for it to expire before retrying."), 202

    @app.post("/api/v1/auth/verify")
    @login_required
    def verify():
        token = text(body().get("code"), "Verification code", 100)
        token_hash = "verify:" + hashlib.sha256(token.encode()).hexdigest()
        with db():
            db().execute("BEGIN IMMEDIATE")
            cursor = db().execute(
                """UPDATE users SET verified=1,verification_hash=NULL WHERE id=? AND email IN
                   (SELECT email FROM pending_registrations WHERE token_hash=? AND expires_at>?)""",
                (g.user_id, token_hash, now_utc()),
            )
            if not cursor.rowcount:
                fail("Invalid or expired verification code.")
            db().execute("DELETE FROM pending_registrations WHERE token_hash=?", (token_hash,))
        return jsonify(message="Account verified.")

    @app.post("/api/v1/auth/login")
    def login():
        data = body()
        email = text(data.get("email"), "Email", 254).lower()
        password = text(data.get("password"), "Password", 128)
        user = db().execute("SELECT * FROM users WHERE email=?", (email,)).fetchone()
        valid_password = check_password_hash(user["password_hash"] if user else DUMMY_PASSWORD_HASH, password)
        if not user or user["status"] != "active" or not valid_password:
            fail("Invalid credentials or inactive account.", 401)
        with db():
            db().execute("BEGIN IMMEDIATE")
            current = db().execute("SELECT status,password_hash FROM users WHERE id=?", (user["id"],)).fetchone()
            if not current or current["status"] != "active" or current["password_hash"] != user["password_hash"]:
                fail("Invalid credentials or inactive account.", 401)
            db().execute("UPDATE users SET last_active_at=? WHERE id=?", (now_utc(), user["id"]))
            token = create_session(user["id"])
        establish_session(user["id"], token)
        return jsonify(message="Signed in.")

    @app.post("/api/v1/auth/logout")
    def logout():
        token = session.get("auth_token")
        user_id = session.get("user_id")
        if type(user_id) is int and isinstance(token, str) and re.fullmatch(r"[A-Za-z0-9_-]{43}", token):
            with db():
                db().execute("DELETE FROM auth_sessions WHERE token_hash=? AND user_id=?", (hashlib.sha256(token.encode("ascii")).hexdigest(), user_id))
        session.clear()
        return jsonify(message="Signed out.")

    @app.get("/api/v1/me")
    @login_required
    def me():
        user = db().execute("SELECT email,verified,matching_paused FROM users WHERE id=?", (g.user_id,)).fetchone()
        profile = db().execute("SELECT data FROM profiles WHERE user_id=?", (g.user_id,)).fetchone()
        prefs = db().execute("SELECT data FROM preferences WHERE user_id=?", (g.user_id,)).fetchone()
        photo = db().execute("SELECT approved FROM photos WHERE user_id=?", (g.user_id,)).fetchone()
        answers = {str(r["question_id"]): r["value"] for r in db().execute("SELECT question_id,value FROM answers WHERE user_id=?", (g.user_id,))}
        return jsonify(id=g.user_id, email=user["email"], verified=bool(user["verified"]),
                       profile=json.loads(profile["data"]) if profile else None,
                       preferences=json.loads(prefs["data"]) if prefs else None,
                       photo="approved" if photo and photo["approved"] else "pending" if photo else "missing",
                       answers=answers, ready=bool(snapshot(db(), g.user_id, include_paused=True)),
                       matching_paused=bool(user["matching_paused"]))

    @app.put("/api/v1/privacy")
    @login_required
    def privacy():
        paused = body().get("matching_paused")
        if type(paused) is not bool:
            fail("Choose whether to pause your profile.")
        with db():
            db().execute("UPDATE users SET matching_paused=? WHERE id=?", (int(paused), g.user_id))
        return jsonify(message="Privacy preference saved.")

    @app.put("/api/v1/profile")
    @login_required
    def profile():
        data = validate_profile(body())
        with db():
            db().execute("INSERT INTO profiles VALUES (?,?) ON CONFLICT(user_id) DO UPDATE SET data=excluded.data", (g.user_id, json.dumps(data)))
        return jsonify(message="Profile saved.")

    @app.put("/api/v1/preferences")
    @login_required
    def preferences():
        data = validate_preferences(body())
        with db():
            db().execute("INSERT INTO preferences VALUES (?,?) ON CONFLICT(user_id) DO UPDATE SET data=excluded.data", (g.user_id, json.dumps(data)))
        return jsonify(message="Preferences saved.")

    @app.get("/api/v1/questions")
    @login_required
    def questions():
        return jsonify(QUESTIONS)

    @app.put("/api/v1/answers/<int:question_id>")
    @login_required
    def answer(question_id):
        value = body().get("value")
        if not 1 <= question_id <= 64 or type(value) is not int or not 1 <= value <= 5:
            fail("Invalid answer.")
        with db():
            db().execute("INSERT INTO answers VALUES (?,?,?) ON CONFLICT(user_id,question_id) DO UPDATE SET value=excluded.value", (g.user_id, question_id, value))
        return jsonify(message="Answer saved.")

    @app.post("/api/v1/photo")
    @login_required
    def upload_photo():
        file = request.files.get("photo")
        if not file:
            fail("Choose a photo.")
        try:
            image = Image.open(file.stream)
            if image.format not in ("JPEG", "PNG") or getattr(image, "is_animated", False) or image.width * image.height > 20_000_000:
                fail("Use a JPEG or PNG image under 20 megapixels.")
            image.load()
            image = image.convert("RGB")
            image.thumbnail((1600, 1600))
            output = io.BytesIO()
            image.save(output, "JPEG", quality=85)
        except (UnidentifiedImageError, OSError, Image.DecompressionBombError):
            fail("Could not read the image.")
        with db():
            db().execute("INSERT INTO photos VALUES (?,?,0) ON CONFLICT(user_id) DO UPDATE SET image=excluded.image,approved=0", (g.user_id, output.getvalue()))
        return jsonify(message="Photo submitted for review.")

    def incoming_invitation(sender, recipient):
        return db().execute(
            """SELECT w.* FROM weekly_matches w
               JOIN reactions r ON r.user_id=w.user_id AND r.candidate_id=w.candidate_id
               WHERE w.cycle_id=(SELECT MAX(id) FROM cycles) AND w.user_id=? AND w.candidate_id=?
                 AND r.kind='like' AND r.created_at>=w.cycle_id""",
            (sender, recipient),
        ).fetchone()

    def introduction(row, own, other, reaction, *, include_rank):
        breakdown = json.loads(row["breakdown"])
        grid = [
            {axis: round(user[axis] * 4) / 4 for axis in ("latitude", "longitude")}
            for user in (own, other)
        ]
        distance = max(25, math.ceil(distance_km(grid[0], grid[1]) / 25) * 25)
        result = {
            "id": other["id"], "name": other["name"], "age": other["age"],
            "distance_label": f"About {distance} km away", "intention": other["intention"], "bio": other["bio"],
            "interests": other["interests"],
            "shared_interests": [i for i in other["interests"] if i.casefold() in {x.casefold() for x in own["interests"]}],
            "score": row["score"], "breakdown": breakdown,
            "similarities": [name for name in sorted(breakdown, key=breakdown.get, reverse=True) if breakdown[name] >= 75][:2],
            "reaction": reaction["kind"] if reaction else None,
        }
        if include_rank:
            result["rank"] = row["rank"]
        return result

    @app.get("/api/v1/photo/<int:target>")
    @login_required
    def get_photo(target):
        if target != g.user_id:
            match = db().execute(
                "SELECT 1 FROM weekly_matches WHERE cycle_id=(SELECT MAX(id) FROM cycles) AND user_id=? AND candidate_id=?",
                (g.user_id, target),
            ).fetchone()
            conversation = db().execute("SELECT 1 FROM conversations WHERE user_low=? AND user_high=?", tuple(sorted((g.user_id, target)))).fetchone()
            invitation = incoming_invitation(target, g.user_id)
            if not (match or conversation or invitation) or not available(db(), g.user_id, target):
                fail("Photo unavailable.", 404)
        photo = db().execute("SELECT image,approved FROM photos WHERE user_id=?", (target,)).fetchone()
        if not photo or (target != g.user_id and not photo["approved"]):
            fail("Photo unavailable.", 404)
        return send_file(io.BytesIO(photo["image"]), mimetype="image/jpeg")

    @app.get("/api/v1/matches")
    @login_required
    def matches():
        cycle = db().execute("SELECT id,generated_at FROM cycles ORDER BY id DESC LIMIT 1").fetchone()
        result = []
        invitations = []
        if cycle:
            rows = db().execute("SELECT * FROM weekly_matches WHERE cycle_id=? AND user_id=? ORDER BY rank", (cycle["id"], g.user_id)).fetchall()
            own = snapshot(db(), g.user_id)
            for row in rows:
                target = row["candidate_id"]
                if not available(db(), g.user_id, target):
                    continue
                other = snapshot(db(), target)
                reaction = db().execute("SELECT kind FROM reactions WHERE user_id=? AND candidate_id=?", (g.user_id, target)).fetchone()
                result.append(introduction(row, own, other, reaction, include_rank=True))
            incoming = db().execute(
                """SELECT w.* FROM weekly_matches w
                   JOIN reactions r ON r.user_id=w.user_id AND r.candidate_id=w.candidate_id
                   WHERE w.cycle_id=? AND w.candidate_id=? AND r.kind='like' AND r.created_at>=w.cycle_id
                   AND NOT EXISTS (SELECT 1 FROM weekly_matches mine WHERE mine.cycle_id=w.cycle_id
                                   AND mine.user_id=w.candidate_id AND mine.candidate_id=w.user_id)
                   AND NOT EXISTS (SELECT 1 FROM reactions mine WHERE mine.user_id=w.candidate_id
                                   AND mine.candidate_id=w.user_id)
                   ORDER BY r.created_at, w.user_id""", (cycle["id"], g.user_id),
            ).fetchall()
            for row in incoming:
                target = row["user_id"]
                if available(db(), g.user_id, target):
                    invitations.append(introduction(row, own, snapshot(db(), target), None, include_rank=False))
        return jsonify(cycle=dict(cycle) if cycle else None, matches=result, invitations=invitations)

    @app.post("/api/v1/matches/<int:target>/reaction")
    @login_required
    def reaction(target):
        kind = body().get("kind")
        if not isinstance(kind, str) or kind not in ("like", "pass"):
            fail("Choose like or pass.")
        db().execute("BEGIN IMMEDIATE")
        with db():
            row = db().execute("SELECT 1 FROM weekly_matches WHERE cycle_id=(SELECT MAX(id) FROM cycles) AND user_id=? AND candidate_id=?", (g.user_id, target)).fetchone()
            if not (row or incoming_invitation(target, g.user_id)) or not available(db(), g.user_id, target):
                fail("Match unavailable.", 404)
            existing = db().execute("SELECT kind FROM reactions WHERE user_id=? AND candidate_id=?", (g.user_id, target)).fetchone()
            if existing and existing["kind"] != kind:
                fail("This decision has already been recorded.", 409)
            db().execute("INSERT OR IGNORE INTO reactions VALUES (?,?,?,?)", (g.user_id, target, kind, now_utc()))
            if kind == "like" and db().execute("SELECT 1 FROM reactions WHERE user_id=? AND candidate_id=? AND kind='like'", (target, g.user_id)).fetchone():
                low, high = sorted((g.user_id, target))
                db().execute("INSERT OR IGNORE INTO conversations(user_low,user_high,created_at) VALUES (?,?,?)", (low, high, now_utc()))
        return jsonify(message="Decision saved.")

    @app.post("/api/v1/safety/<int:target>")
    @login_required
    def safety(target):
        data = body()
        kind = data.get("kind")
        if target == g.user_id or not isinstance(kind, str) or kind not in ("block", "report"):
            fail("Invalid safety action.")
        known = db().execute("SELECT 1 FROM weekly_matches WHERE user_id=? AND candidate_id=? UNION SELECT 1 FROM conversations WHERE user_low=? AND user_high=?", (g.user_id, target, *sorted((g.user_id, target)))).fetchone()
        if not known and not incoming_invitation(target, g.user_id):
            fail("User unavailable.", 404)
        with db():
            if kind == "block":
                db().execute("INSERT OR IGNORE INTO blocks VALUES (?,?,?)", (g.user_id, target, now_utc()))
            else:
                reason = text(data.get("reason"), "Reason", 1000, 5)
                db().execute("INSERT INTO reports(reporter_id,target_id,reason,created_at) VALUES (?,?,?,?)", (g.user_id, target, reason, now_utc()))
        return jsonify(message="Safety action recorded. This person is no longer available to you.")

    def conversation_for(conversation_id):
        row = db().execute("SELECT * FROM conversations WHERE id=? AND (user_low=? OR user_high=?)", (conversation_id, g.user_id, g.user_id)).fetchone()
        if not row:
            fail("Conversation unavailable.", 404)
        other = row["user_high"] if row["user_low"] == g.user_id else row["user_low"]
        if not available(db(), g.user_id, other):
            fail("Conversation unavailable.", 404)
        return row, other

    @app.get("/api/v1/conversations")
    @login_required
    def conversations():
        result = []
        rows = db().execute("SELECT * FROM conversations WHERE user_low=? OR user_high=? ORDER BY created_at DESC", (g.user_id, g.user_id)).fetchall()
        for row in rows:
            other = row["user_high"] if row["user_low"] == g.user_id else row["user_low"]
            if not available(db(), g.user_id, other):
                continue
            profile_data = snapshot(db(), other)
            unread = db().execute("SELECT COUNT(*) FROM messages WHERE conversation_id=? AND sender_id<>? AND read_at IS NULL", (row["id"], g.user_id)).fetchone()[0]
            result.append({"id": row["id"], "other_id": other, "name": profile_data["name"], "unread": unread})
        return jsonify(result)

    @app.get("/api/v1/conversations/<int:conversation_id>/messages")
    @login_required
    def messages(conversation_id):
        db().execute("BEGIN IMMEDIATE")
        conversation_for(conversation_id)
        with db():
            db().execute("UPDATE messages SET read_at=? WHERE conversation_id=? AND sender_id<>? AND read_at IS NULL", (now_utc(), conversation_id, g.user_id))
            rows = db().execute("SELECT id,sender_id,body,created_at FROM messages WHERE conversation_id=? ORDER BY id", (conversation_id,)).fetchall()
        return jsonify([{"id": r["id"], "mine": r["sender_id"] == g.user_id, "body": r["body"], "created_at": r["created_at"]} for r in rows])

    @app.post("/api/v1/conversations/<int:conversation_id>/messages")
    @login_required
    def send_message(conversation_id):
        content = text(body().get("body"), "Message", 2000)
        db().execute("BEGIN IMMEDIATE")
        with db():
            conversation_for(conversation_id)
            db().execute("INSERT INTO messages(conversation_id,sender_id,body,created_at) VALUES (?,?,?,?)", (conversation_id, g.user_id, content, now_utc()))
        return jsonify(message="Message sent."), 201

    @app.post("/api/v1/conversations/<int:conversation_id>/unmatch")
    @login_required
    def unmatch(conversation_id):
        db().execute("BEGIN IMMEDIATE")
        with db():
            _, other = conversation_for(conversation_id)
            db().execute("INSERT OR REPLACE INTO reactions VALUES (?,?,?,?)", (g.user_id, other, "pass", now_utc()))
            db().execute("DELETE FROM conversations WHERE id=?", (conversation_id,))
        return jsonify(message="Unmatched.")

    @app.delete("/api/v1/account")
    @login_required
    def delete_account():
        if not check_password_hash(db().execute("SELECT password_hash FROM users WHERE id=?", (g.user_id,)).fetchone()[0], text(body().get("password"), "Password", 128)):
            fail("Invalid password.", 403)
        with db():
            db().execute("DELETE FROM users WHERE id=?", (g.user_id,))
        session.clear()
        return jsonify(message="Account deleted.")

    @app.cli.command("moderate")
    @click.argument("action", type=click.Choice(["photos", "approve-photo", "reject-photo", "suspend", "reports", "resolve-report"]))
    @click.argument("user_id", type=int, required=False)
    def moderate(action, user_id):
        if action == "reports":
            for row in db().execute("SELECT id,reporter_id,target_id,reason,created_at,status FROM reports WHERE status='open'"):
                click.echo(dict(row))
            return
        if action == "photos":
            for row in db().execute("SELECT user_id FROM photos WHERE approved=0"):
                click.echo(f"Pending photo: user {row['user_id']}")
            return
        if user_id is None:
            raise click.UsageError("A user ID, or report ID for resolve-report, is required.")
        with db():
            if action == "approve-photo":
                result = db().execute("UPDATE photos SET approved=1 WHERE user_id=?", (user_id,))
            elif action == "reject-photo":
                result = db().execute("DELETE FROM photos WHERE user_id=?", (user_id,))
            elif action == "suspend":
                result = db().execute("UPDATE users SET status='suspended' WHERE id=?", (user_id,))
                db().execute("DELETE FROM auth_sessions WHERE user_id=?", (user_id,))
            else:
                report = db().execute("SELECT target_id FROM reports WHERE id=? AND status='open'", (user_id,)).fetchone()
                if not report:
                    raise click.ClickException("Open report not found.")
                result = db().execute("UPDATE reports SET status='resolved' WHERE id=?", (user_id,))
                user_id = report["target_id"]
            if not result.rowcount:
                raise click.ClickException("User or photo not found.")
            db().execute("INSERT INTO moderation_actions(target_id,action,created_at) VALUES (?,?,?)", (user_id, action, now_utc()))
        click.echo("Moderation action recorded.")

    @app.cli.command("export-photo")
    @click.argument("user_id", type=int)
    @click.argument("output", type=click.Path(dir_okay=False, path_type=Path))
    def export_photo(user_id, output):
        row = db().execute("SELECT image FROM photos WHERE user_id=? AND approved=0", (user_id,)).fetchone()
        if not row:
            raise click.ClickException("Pending photo not found.")
        if output.exists():
            raise click.ClickException("Output already exists; choose a new path.")
        with output.open("xb") as file:
            file.write(row["image"])
        click.echo("Photo exported locally for review; delete the exported copy afterwards.")

    return app


app = create_app()
