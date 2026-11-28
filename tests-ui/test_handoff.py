import tempfile
import unittest
from pathlib import Path

from pair.app import create_app


class MobileHandoffTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        app = create_app(
            {
                "TESTING": True,
                "DATABASE": str(Path(self.tmp.name) / "handoff.sqlite3"),
                "SECRET_KEY": "handoff-test",
            }
        )
        self.client = app.test_client()

    def test_homepage_only_offers_native_app_handoff(self):
        response = self.client.get("/")
        self.addCleanup(response.close)

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.mimetype, "text/html")
        page = response.get_data(as_text=True)
        self.assertIn("<title>PAIR — made for meeting</title>", page)
        self.assertIn('href="pair://open/"', page)
        self.assertIn("PAIR is a mobile app", page)
        self.assertNotIn("/app.js", page)
        self.assertNotIn("/styles.css", page)
        self.assertEqual(self.client.get("/app.js").status_code, 404)
        self.assertEqual(self.client.get("/styles.css").status_code, 404)
