import io
import json
import os
import re
import tempfile
import threading
import unittest
from contextlib import closing
from pathlib import Path
from unittest.mock import patch

from PIL import Image
from playwright.sync_api import expect, sync_playwright
from werkzeug.security import generate_password_hash
from werkzeug.serving import make_server

from pair.app import create_app
from pair.service import generate_cycle, now_utc
from pair.storage import connect


class BrowserTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.playwright = sync_playwright().start()
        executable = os.environ.get("PAIR_BROWSER_EXECUTABLE")
        try:
            cls.browser = cls.playwright.chromium.launch(headless=True, executable_path=executable)
        except Exception:
            cls.playwright.stop()
            raise

    @classmethod
    def tearDownClass(cls):
        cls.browser.close()
        cls.playwright.stop()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = str(Path(self.tmp.name) / "ui.sqlite3")
        self.app = create_app({"TESTING": True, "DATABASE": self.path, "SECRET_KEY": "ui-test"})
        self.deliveries = []
        delivery = patch("pair.app.deliver_registration", side_effect=lambda email, code: self.deliveries.append((email, code)))
        delivery.start()
        self.addCleanup(delivery.stop)
        self.server = make_server("127.0.0.1", 0, self.app, threaded=True)
        self.thread = threading.Thread(target=self.server.serve_forever)
        self.thread.start()
        self.context = self.browser.new_context(viewport={"width": 390, "height": 844})
        self.page = self.context.new_page()
        self.url = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self):
        self.context.close()
        self.server.shutdown()
        self.thread.join()
        self.server.server_close()
        self.tmp.cleanup()

    def register(self):
        self.page.goto(self.url)
        self.page.get_by_label("Email address").fill("person@example.test")
        self.page.get_by_role("button", name="Continue", exact=True).click()
        self.page.get_by_role("heading", name="Complete registration").wait_for()
        code = self.deliveries[-1][1]
        self.page.get_by_label("Registration code").fill(code)
        self.page.get_by_label("Password", exact=True).fill("a secure test password")
        self.page.get_by_label("I confirm I am 18 or older").check()
        self.page.get_by_role("button", name="Create your account").click()
        self.page.get_by_role("heading", name="Complete your profile").wait_for()

    def seed_matches(self):
        image = io.BytesIO()
        Image.new("RGB", (20, 20), "green").save(image, "JPEG")
        preferences = {"min_age": 18, "max_age": 80, "distance": 100, "genders": ["woman"], "intentions": ["serious"], "dealbreakers": {}}
        with closing(connect(self.path)) as db, db:
            for name in ("Alex", "Blair"):
                profile = {"name": name, "birth_date": "1990-01-01", "city": "Example", "bio": "A complete example profile", "gender": "woman", "intention": "serious", "interests": ["Books"], "lifestyle": {"smoking": "no", "drinking": "no", "children": "no"}, "latitude": 51.5, "longitude": -0.1}
                user = db.execute("INSERT INTO users(email,password_hash,verified,created_at) VALUES (?,?,1,?)", (name.lower() + "@example.test", generate_password_hash("a secure test password"), now_utc())).lastrowid
                db.execute("INSERT INTO profiles VALUES (?,?)", (user, json.dumps(profile)))
                db.execute("INSERT INTO preferences VALUES (?,?)", (user, json.dumps(preferences)))
                db.execute("INSERT INTO photos VALUES (?,?,1)", (user, image.getvalue()))
                db.executemany("INSERT INTO answers VALUES (?,?,?)", [(user, i, 3) for i in range(1, 65)])
        generate_cycle(self.path, "UTC")

    def login(self, page, name):
        page.goto(self.url)
        page.get_by_role("button", name="Already have an account? Sign in").click()
        page.get_by_label("Email address").fill(name.lower() + "@example.test")
        page.get_by_label("Password", exact=True).fill("a secure test password")
        page.get_by_role("button", name="Sign in", exact=True).click()
        page.get_by_role("heading", name="Your introductions").wait_for()

    def test_onboarding_questionnaire_and_keyboard_focus(self):
        self.register()
        self.assertEqual(self.page.get_by_role("progressbar", name="Onboarding progress").get_attribute("aria-valuenow"), "1")
        self.page.get_by_role("button", name="Your answers").click()
        self.assertEqual(self.page.locator(":focus").get_attribute("id"), "content")
        self.page.get_by_role("group", name="I prefer to discuss problems as soon as they arise.").get_by_role("button", name="Agree", exact=True).click()
        answer = self.page.get_by_role("group", name="I prefer to discuss problems as soon as they arise.").get_by_role("button", name="Agree", exact=True)
        expect(answer).to_have_attribute("aria-pressed", "true")
        self.assertEqual(self.page.locator(":focus").get_attribute("data-answer"), "1")
        self.assertEqual(self.page.get_by_role("progressbar", name="Questionnaire progress").get_attribute("aria-valuenow"), "1")
        self.page.get_by_role("button", name="2. Emotional needs").click()
        self.assertEqual(self.page.locator(":focus").get_attribute("data-category"), "1")
        self.page.reload()
        self.page.get_by_role("button", name="Your answers").click()
        self.assertEqual(self.page.get_by_role("group", name="I prefer to discuss problems as soon as they arise.").get_by_role("button", name="Agree", exact=True).get_attribute("aria-pressed"), "true")
        self.assertFalse(self.page.evaluate("document.documentElement.scrollWidth > window.innerWidth"))

    def test_validation_retains_inputs_and_warns_before_discard(self):
        self.register()
        self.page.get_by_role("button", name="Profile", exact=True).click()
        self.page.get_by_label("First name").fill("Alex")
        self.page.once("dialog", lambda dialog: dialog.dismiss())
        self.page.get_by_role("button", name="Matches").click()
        self.assertEqual(self.page.get_by_label("First name").input_value(), "Alex")
        self.page.once("dialog", lambda dialog: dialog.accept())
        self.page.get_by_role("button", name="Matches").click()
        self.page.get_by_role("button", name="Continue: Dating preferences").click()
        self.page.get_by_label("Maximum distance (km)").fill("25")
        self.page.get_by_role("button", name="Save preferences").click()
        self.page.get_by_role("alert").wait_for()
        self.assertIn("Choose at least one valid gender", self.page.get_by_role("alert").inner_text())
        self.assertEqual(self.page.get_by_label("Maximum distance (km)").input_value(), "25")
        self.assertTrue(self.page.get_by_role("button", name="Save preferences").is_enabled())
        self.page.get_by_role("button", name="Dismiss").click()
        expect(self.page.get_by_role("alert")).to_have_count(0)
        self.page.get_by_label("Woman", exact=True).check()
        self.page.get_by_label("Long-term relationship", exact=True).check()
        self.page.get_by_role("button", name="Save preferences").click()
        self.page.get_by_text("Preferences saved.").wait_for()
        self.page.get_by_role("button", name="Matches").click()
        self.assertIn("2 of 5 complete", self.page.locator("main").inner_text())

    def test_privacy_pause_persists_until_resumed(self):
        self.register()
        self.page.get_by_role("button", name="Settings").click()
        pause = self.page.get_by_label("Pause my profile")
        pause.check()
        self.page.get_by_role("button", name="Save privacy").click()
        self.page.get_by_text("Privacy preference saved.").wait_for()
        self.page.reload()
        self.page.get_by_role("button", name="Settings").click()
        expect(self.page.get_by_label("Pause my profile")).to_be_checked()
        self.page.get_by_label("Pause my profile").uncheck()
        self.page.get_by_role("button", name="Save privacy").click()
        self.page.get_by_text("Privacy preference saved.").wait_for()
        expect(self.page.get_by_label("Pause my profile")).not_to_be_checked()

    def test_existing_account_can_verify_via_email(self):
        self.register()
        with closing(connect(self.path)) as db, db:
            db.execute("UPDATE users SET verified=0 WHERE email=?", ("person@example.test",))
        self.page.reload()
        self.page.get_by_role("button", name="Settings").click()
        self.page.get_by_role("button", name="Email a verification code").click()
        self.page.get_by_text("Check your email for a verification code.").wait_for()
        self.page.get_by_label("Verification code from email").fill(self.deliveries[-1][1])
        self.page.get_by_role("button", name="Verify account").click()
        self.page.get_by_text("Account verified.").wait_for()
        self.page.get_by_text("Email status: verified", exact=False).wait_for()

    def test_connection_error_has_retry_instead_of_fake_signed_out_state(self):
        self.page.route("**/api/v1/me", lambda route: route.abort())
        self.page.goto(self.url)
        self.page.get_by_role("heading", name="Unable to connect").wait_for()
        self.assertEqual(self.page.get_by_role("button", name="Continue", exact=True).count(), 0)
        self.page.unroute("**/api/v1/me")
        self.page.get_by_role("button", name="Try again").click()
        self.page.get_by_role("heading", name="Create your account").wait_for()

    def test_mobile_navigation_targets_and_key_text_contrast(self):
        self.page.goto(self.url)
        self.page.get_by_role("heading", name="Create your account").wait_for()
        colors = self.page.evaluate("""() => {
            const color = (selector, property) => getComputedStyle(document.querySelector(selector))[property];
            return [
                [color('.hero-copy', 'color'), color('.hero', 'backgroundColor')],
                [color('#auth-form .btn', 'color'), color('#auth-form .btn', 'backgroundColor')]
            ];
        }""")

        def luminance(rgb):
            channels = [int(value) / 255 for value in re.findall(r"\d+", rgb)[:3]]
            linear = [value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4 for value in channels]
            return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]

        for foreground, background in colors:
            light, dark = sorted((luminance(foreground), luminance(background)), reverse=True)
            self.assertGreaterEqual((light + 0.05) / (dark + 0.05), 4.5)
        self.register()
        for item in self.page.locator(".nav button").all():
            self.assertGreaterEqual(item.bounding_box()["height"], 44)
        navigation = self.page.get_by_role("button", name="Your answers")
        navigation.focus()
        self.page.keyboard.press("Enter")
        self.page.get_by_role("heading", name="Your answers").wait_for()
        self.assertEqual(self.page.locator(":focus").get_attribute("id"), "content")

    def test_mutual_likes_messages_and_unmatch(self):
        self.seed_matches()
        self.login(self.page, "Alex")
        self.page.get_by_role("button", name="Like Blair").click()
        expect(self.page.get_by_role("button", name="Liked Blair")).to_be_disabled()
        second = self.browser.new_context(viewport={"width": 1200, "height": 900})
        try:
            blair = second.new_page()
            self.login(blair, "Blair")
            blair.get_by_role("button", name="Like Alex").click()
            expect(blair.get_by_role("button", name="Liked Alex")).to_be_disabled()
            blair.get_by_role("button", name="Messages", exact=True).click()
            blair.get_by_role("button", name="Alex Open conversation").click()
            blair.get_by_label("Your message").fill("Hello, Alex!")
            blair.get_by_role("button", name="Send message").click()
            blair.get_by_text("Hello, Alex!").wait_for()
            self.page.get_by_role("button", name="Messages", exact=True).click()
            self.page.get_by_role("button", name="Blair 1 unread").click()
            self.page.get_by_text("Hello, Alex!").wait_for()
            self.page.once("dialog", lambda dialog: dialog.accept())
            self.page.get_by_role("button", name="Unmatch").click()
            self.page.get_by_role("heading", name="No conversations yet").wait_for()
        finally:
            second.close()

    def test_asymmetric_like_is_a_private_invitation(self):
        image = io.BytesIO()
        Image.new("RGB", (20, 20), "green").save(image, "JPEG")
        base_preferences = {"min_age": 18, "max_age": 80, "distance": 100, "genders": ["woman", "man"], "intentions": ["serious"], "dealbreakers": {}}
        with closing(connect(self.path)) as db, db:
            for name in ("Alex", "Blair", "Casey", "Drew", "Ellis"):
                profile = {"name": name, "birth_date": "1990-01-01", "city": "Example", "bio": "A complete example profile", "gender": "man" if name == "Blair" else "woman", "intention": "serious", "interests": ["Books"], "lifestyle": {"smoking": "no", "drinking": "no", "children": "no"}, "latitude": 51.5, "longitude": -0.1}
                preferences = {**base_preferences, "genders": ["man"]} if name == "Alex" else base_preferences
                user = db.execute("INSERT INTO users(email,password_hash,verified,created_at) VALUES (?,?,1,?)", (name.lower() + "@example.test", generate_password_hash("a secure test password"), now_utc())).lastrowid
                db.execute("INSERT INTO profiles VALUES (?,?)", (user, json.dumps(profile)))
                db.execute("INSERT INTO preferences VALUES (?,?)", (user, json.dumps(preferences)))
                db.execute("INSERT INTO photos VALUES (?,?,1)", (user, image.getvalue()))
                db.executemany("INSERT INTO answers VALUES (?,?,?)", [(user, i, 1 if name == "Alex" else 5) for i in range(1, 65)])
        generate_cycle(self.path, "UTC")
        self.login(self.page, "Alex")
        self.page.get_by_role("button", name="Like Blair").click()
        second = self.browser.new_context(viewport={"width": 1200, "height": 900})
        try:
            blair = second.new_page()
            self.login(blair, "Blair")
            blair.get_by_role("heading", name="Private invitations").wait_for()
            blair.get_by_role("button", name="Like Alex").click()
            blair.get_by_role("button", name="Messages", exact=True).click()
            blair.get_by_role("button", name="Alex Open conversation").wait_for()
        finally:
            second.close()

    def test_report_immediately_removes_introduction(self):
        self.seed_matches()
        self.login(self.page, "Alex")
        self.page.once("dialog", lambda dialog: dialog.accept("Safety concern"))
        self.page.get_by_role("button", name="Report Blair").click()
        self.page.get_by_role("heading", name="No introductions this week").wait_for()
        self.assertEqual(self.page.get_by_role("button", name="Like Blair").count(), 0)

    def test_onboarding_reflows_without_horizontal_scroll(self):
        self.register()
        for width in (320, 390, 768, 1024, 1440):
            with self.subTest(width=width):
                self.page.set_viewport_size({"width": width, "height": 900})
                self.assertFalse(self.page.evaluate("document.documentElement.scrollWidth > window.innerWidth"))
                for item in self.page.locator(".nav button").all():
                    self.assertGreaterEqual(item.bounding_box()["height"], 44)


if __name__ == "__main__":
    unittest.main()
