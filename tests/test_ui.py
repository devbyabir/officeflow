"""Real-browser regression tests. Starts a private static server automatically.

Install test-only tools from tests/requirements-ui.txt; no npm dependencies/build.
"""
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import os
import threading
import subprocess
import tempfile
import time
import unittest
import urllib.request
from playwright.sync_api import sync_playwright, expect

ROOT = Path(__file__).resolve().parents[1]


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *_args):
        pass


class BrowserTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0),
            partial(QuietHandler, directory=str(ROOT / "docs/site")))
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f"http://127.0.0.1:{cls.server.server_port}"
        cls.playwright = sync_playwright().start()
        try:
            cls.browser = cls.playwright.chromium.launch()
        except Exception:
            cls.playwright.stop()
            cls.server.shutdown()
            cls.server.server_close()
            raise

    @classmethod
    def tearDownClass(cls):
        cls.browser.close()
        cls.playwright.stop()
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def setUp(self):
        self.context = self.browser.new_context(viewport={"width": 1440, "height": 1000},
            color_scheme="light", reduced_motion="reduce")
        self.page = self.context.new_page()
        self.errors = []
        self.page.on("pageerror", lambda error: self.errors.append(str(error)))
        self.page.goto(self.base)
        expect(self.page.locator("#main h1")).to_be_visible()

    def tearDown(self):
        try:
            self.assertEqual(self.errors, [], "Uncaught browser errors")
        finally:
            self.context.close()

    def test_sample_workspace_label_and_windows_link(self):
        expect(self.page.locator("#mode-badge")).to_have_text("Sample workspace")
        link = self.page.get_by_role("link", name="Run on Windows", exact=True)
        expect(link).to_be_visible()
        expect(link).to_have_attribute(
            "href", "https://github.com/devbyabir/officeflow#run-officeflow-on-windows")

    def test_theme_toggle_persists_and_updates_accessible_label(self):
        page = self.page
        expect(page.locator("html")).to_have_attribute("data-theme", "light")
        page.get_by_role("button", name="Switch to dark mode", exact=True).click()
        expect(page.locator("html")).to_have_attribute("data-theme", "dark")
        expect(page.locator("#theme-toggle")).to_have_attribute("aria-pressed", "true")
        page.reload()
        expect(page.locator("html")).to_have_attribute("data-theme", "dark")
        page.get_by_role("button", name="Switch to light mode", exact=True).click()
        page.reload()
        expect(page.locator("html")).to_have_attribute("data-theme", "light")

    def test_system_theme_and_reduced_motion(self):
        self.page.emulate_media(color_scheme="dark", reduced_motion="reduce")
        expect(self.page.locator("html")).to_have_attribute("data-theme", "dark")
        self.page.get_by_role("button", name="Add supply", exact=True).click()
        expect(self.page.get_by_role("dialog")).to_be_visible()
        self.assertLessEqual(self.page.locator("#dialog").evaluate(
            "el => parseFloat(getComputedStyle(el).animationDuration)"), 0.001)

    def test_navigation_in_both_themes_and_browser_history(self):
        for theme in ("light", "dark"):
            if theme == "dark":
                self.page.get_by_role("button", name="Switch to dark mode", exact=True).click()
            for label, route in (("Supply inventory", "inventory"), ("Requisitions", "requests"),
                    ("Teachers", "teachers"), ("Activity & history", "history"), ("Overview", "overview")):
                self.page.locator("#navigation").get_by_role("link", name=label).click()
                expect(self.page).to_have_url(self.base + "/#" + route)
                expect(self.page.locator("#main h1")).to_be_visible()
                expect(self.page.locator(f'#navigation a[href="#{route}"]')).to_have_attribute("aria-current", "page")
            self.page.go_back()
            expect(self.page.locator("#breadcrumb")).to_have_text("Activity & history")

    def test_supply_dialog_validation_save_and_escape(self):
        for theme in ("light", "dark"):
            if theme == "dark":
                self.page.get_by_role("button", name="Switch to dark mode", exact=True).click()
            opener = self.page.get_by_role("button", name="Add supply", exact=True)
            opener.click()
            dialog = self.page.get_by_role("dialog")
            expect(dialog).to_be_visible()
            self.assertTrue(dialog.evaluate("el => el.contains(document.activeElement)"))
            self.page.keyboard.press("Escape")
            expect(dialog).not_to_be_visible()
            expect(opener).to_be_focused()
        opener.click()
        dialog.get_by_role("button", name="Add supply", exact=True).click()
        expect(dialog).to_be_visible()  # Required field validation must block save.
        dialog.get_by_label("Item name", exact=True).fill("QA browser markers")
        dialog.get_by_label("Quantity on hand", exact=True).fill("12")
        dialog.get_by_role("button", name="Add supply", exact=True).click()
        expect(dialog).not_to_be_visible()
        self.page.locator("#navigation").get_by_role("link", name="Supply inventory").click()
        expect(self.page.locator("#breadcrumb")).to_have_text("Supply inventory")
        self.page.locator("#search").fill("QA browser markers")
        expect(self.page.locator("#inventory-results")).to_contain_text("QA browser markers")
        self.page.reload()
        self.page.locator("#search").fill("QA browser markers")
        expect(self.page.locator("#inventory-results")).to_contain_text("QA browser markers")

    def test_mobile_navigation_and_table_scroll(self):
        self.page.set_viewport_size({"width": 390, "height": 844})
        self.assertLessEqual(self.page.evaluate("document.documentElement.scrollWidth"), 390)
        self.page.get_by_role("button", name="Toggle navigation", exact=True).click()
        expect(self.page.locator("#sidebar")).to_have_class("sidebar open")
        self.page.locator("#navigation").get_by_role("link", name="Supply inventory").click()
        expect(self.page.locator("#sidebar")).to_have_class("sidebar")
        expect(self.page.locator("#inventory-results table")).to_be_visible()
        self.assertLessEqual(self.page.evaluate("document.documentElement.scrollWidth"), 390)

    def test_teacher_navigation_and_request_dialog(self):
        self.page.locator("#switch-role").click()
        self.page.get_by_role("button", name="Alex Morgan", exact=False).click()
        expect(self.page.locator('#navigation a[href="#teachers"]')).to_have_count(0)
        self.page.goto(self.base + "/#teachers")
        expect(self.page.locator("#breadcrumb")).to_have_text("Overview")
        self.page.locator("#navigation").get_by_role("link", name="Requisitions").click()
        self.page.locator('[data-action="new-request"]').click()
        expect(self.page.get_by_role("dialog")).to_be_visible()
        expect(self.page.get_by_label("Supply item", exact=True)).to_be_visible()
        self.page.get_by_role("button", name="Close dialog", exact=True).click()
        expect(self.page.get_by_role("dialog")).not_to_be_visible()


def java_api(base, path, data=None, token=None):
    """Creates fictional fixture records through the real API (no sample seeding)."""
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    request = urllib.request.Request(base + path, headers=headers,
        data=json.dumps(data).encode() if data is not None else None)
    with urllib.request.urlopen(request, timeout=10) as response:
        return json.loads(response.read())


@unittest.skipUnless(os.environ.get("OFFICEFLOW_UI_JAVA") == "1", "Set OFFICEFLOW_UI_JAVA=1 after building Java")
class JavaAccountBrowserTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="officeflow-ui-java-")
        cls.log = Path(cls.temp.name) / "server.log"
        cls.stream = cls.log.open("w", encoding="utf-8")
        classpath = os.environ.get("OFFICEFLOW_CP", os.pathsep.join([
            str(ROOT / "server/target/classes"), str(ROOT / "server/target/dependency/*")]))
        cls.process = subprocess.Popen([os.environ.get("JAVA", "java"),
            "-Dofficeflow.port=0",
            "-Dofficeflow.db=jdbc:h2:" + (Path(cls.temp.name) / "db").as_posix(),
            "-Dofficeflow.site=" + str(ROOT / "docs/site"), "-cp", classpath, "com.officeflow.App"],
            stdout=cls.stream, stderr=cls.stream,
            env=dict(os.environ, OFFICEFLOW_ADMIN_PASSWORD="test-admin-password"), cwd=ROOT)
        cls.addClassCleanup(cls.cleanup_server)
        for _ in range(100):
            content = cls.log.read_text(encoding="utf-8")
            if "OfficeFlow: http://" in content:
                cls.base = content.split("OfficeFlow: ", 1)[1].splitlines()[0]
                break
            if cls.process.poll() is not None:
                raise AssertionError(content)
            time.sleep(0.1)
        else:
            raise AssertionError("Java server did not start")
        # Fictional fixture: T001 keeps a temporary password, T002 has chosen their own.
        admin = java_api(cls.base, "/api/login",
                         {"id": "001", "password": "test-admin-password"})["token"]
        for teacher, name in (("T001", "Alex Morgan"), ("T002", "Sam Chen")):
            created = java_api(cls.base, "/api/command", {"action": "saveTeacher", "data": {
                "id": teacher, "name": name, "department": "Science", "email": ""}}, admin)
            password = created["temporaryPasswords"][0]["password"]
            if teacher == "T002":
                token = java_api(cls.base, "/api/login",
                                 {"id": teacher, "password": password})["token"]
                java_api(cls.base, "/api/password/change", {"currentPassword": password,
                    "newPassword": "ui-teacher-password"}, token)
        java_api(cls.base, "/api/command", {"action": "saveSupply", "data": {
            "name": "Fixture pencils", "category": "Stationery", "quantity": "9",
            "threshold": "2", "unit": "boxes"}}, admin)
        cls.playwright = sync_playwright().start()
        cls.addClassCleanup(cls.playwright.stop)
        cls.browser = cls.playwright.chromium.launch()
        cls.addClassCleanup(cls.browser.close)

    @classmethod
    def cleanup_server(cls):
        cls.process.terminate()
        cls.process.wait(timeout=10)
        cls.stream.close()
        cls.temp.cleanup()

    def new_page(self):
        context = self.browser.new_context(reduced_motion="reduce")
        self.addCleanup(context.close)
        page = context.new_page()
        errors = []
        page.on("pageerror", lambda error: errors.append(str(error)))
        self.addCleanup(lambda: self.assertEqual(errors, [], "Uncaught browser errors"))
        return page

    def assert_no_sample_workspace(self, page):
        self.assertIsNone(page.evaluate("localStorage.getItem('officeflow-demo-v1')"))
        expect(page.locator("#reset-demo")).to_be_hidden()
        expect(page.locator("#run-on-windows")).to_be_hidden()
        expect(page.locator("#mode-badge")).to_contain_text("Java workspace")

    def sign_in(self, page, account, password):
        dialog = page.get_by_role("dialog")
        expect(dialog.get_by_role("heading", name="Welcome to OfficeFlow")).to_be_visible()
        dialog.get_by_label("Account ID", exact=True).fill(account)
        dialog.get_by_label("Password", exact=True).fill(password)
        dialog.get_by_role("button", name="Sign in", exact=True).click()

    def account_action(self, page, name):
        page.locator("#switch-role").click()
        page.get_by_role("button", name=name, exact=True).click()

    def test_connecting_error_and_retry_never_show_the_sample_workspace(self):
        page = self.new_page()
        # Simulate the server not answering the health check.
        page.route("**/api/health", lambda route: route.abort())
        page.goto(self.base)
        expect(page.get_by_role("alert")).to_contain_text("can't reach its server")
        expect(page.locator("#main h1")).to_have_count(0)
        self.assert_no_sample_workspace(page)
        page.locator("#switch-role").click()
        expect(page.get_by_role("dialog")).to_be_hidden()
        page.unroute("**/api/health")
        page.get_by_role("button", name="Retry", exact=True).click()
        self.sign_in(page, "T002", "ui-teacher-password")
        expect(page.get_by_role("dialog")).not_to_be_visible()
        expect(page.locator("#main h1")).to_be_visible()
        self.assert_no_sample_workspace(page)

    def test_temporary_password_shown_once_and_first_login_requires_a_change(self):
        page = self.new_page()
        page.goto(self.base)
        self.sign_in(page, "001", "test-admin-password")
        dialog = page.get_by_role("dialog")
        expect(dialog).not_to_be_visible()
        page.locator("#navigation").get_by_role("link", name="Teachers").click()
        page.locator('[data-action="new-teacher"]').click()
        dialog.get_by_label("Teacher ID", exact=True).fill("T050")
        dialog.get_by_label("Full name", exact=True).fill("Riley Park")
        dialog.get_by_label("Department", exact=True).fill("Library")
        dialog.get_by_role("button", name="Add teacher", exact=True).click()
        expect(dialog.get_by_role("heading",
                                  name="Give this teacher their temporary password")).to_be_visible()
        temporary = dialog.locator(".temporary-passwords code").inner_text()
        self.assertGreaterEqual(len(temporary), 12)
        dialog.get_by_role("button", name="Done", exact=True).click()
        self.account_action(page, "Sign out")
        self.sign_in(page, "T050", temporary)
        expect(dialog.get_by_role("heading", name="Choose your own password")).to_be_visible()
        expect(page.locator("#main")).not_to_contain_text("Fixture pencils")
        dialog.get_by_label("Temporary password", exact=True).fill(temporary)
        dialog.get_by_label("New password", exact=True).fill("riley-own-password")
        dialog.get_by_label("Confirm new password", exact=True).fill("riley-own-password")
        dialog.get_by_role("button", name="Change password", exact=True).click()
        self.sign_in(page, "T050", "riley-own-password")
        expect(dialog).not_to_be_visible()
        page.locator("#navigation").get_by_role("link", name="Supply inventory").click()
        expect(page.locator("#inventory-results")).to_contain_text("Fixture pencils")
        self.assert_no_sample_workspace(page)

    def test_password_change_reset_and_logout_in_real_java_ui(self):
        page = self.new_page()
        page.goto(self.base)
        self.sign_in(page, "001", "test-admin-password")
        dialog = page.get_by_role("dialog")
        expect(dialog).not_to_be_visible()
        self.account_action(page, "Reset teacher password")
        page.get_by_label("Teacher", exact=True).select_option("T001")
        page.get_by_label("New password", exact=True).fill("ui-reset-password")
        page.get_by_label("Confirm new password", exact=True).fill("ui-reset-password")
        dialog.get_by_role("button", name="Reset password", exact=True).click()
        expect(dialog).not_to_be_visible()
        self.account_action(page, "Sign out")
        expect(page.locator("#main")).not_to_contain_text("Alex Morgan")
        # A reset is temporary: the teacher must choose their own password before anything else.
        self.sign_in(page, "T001", "ui-reset-password")
        expect(dialog.get_by_role("heading", name="Choose your own password")).to_be_visible()
        dialog.get_by_label("Temporary password", exact=True).fill("ui-reset-password")
        dialog.get_by_label("New password", exact=True).fill("ui-changed-password")
        dialog.get_by_label("Confirm new password", exact=True).fill("mismatched-password")
        dialog.get_by_role("button", name="Change password", exact=True).click()
        expect(page.locator(".form-error")).to_contain_text("do not match")
        dialog.get_by_label("Confirm new password", exact=True).fill("ui-changed-password")
        dialog.get_by_role("button", name="Change password", exact=True).click()
        self.sign_in(page, "T001", "ui-changed-password")
        expect(dialog).not_to_be_visible()
        page.locator("#switch-role").click()
        expect(page.get_by_role("button", name="Reset teacher password", exact=True)).to_have_count(0)
        page.get_by_role("button", name="Sign out", exact=True).click()
        page.reload()
        expect(dialog.get_by_role("heading", name="Welcome to OfficeFlow")).to_be_visible()
        self.assert_no_sample_workspace(page)

    def test_revoked_session_clears_cached_view_on_next_request(self):
        page = self.new_page()
        page.goto(self.base)
        dialog = page.get_by_role("dialog")
        self.sign_in(page, "T002", "ui-teacher-password")
        expect(dialog).not_to_be_visible()
        # Reset from a separate administrator session while this tab stays open.
        response = page.context.request.post(self.base + "/api/login",
            data={"id": "001", "password": "test-admin-password"})
        self.assertTrue(response.ok)
        token = response.json()["token"]
        response = page.context.request.post(self.base + "/api/password/reset",
            headers={"Authorization": "Bearer " + token},
            data={"id": "T002", "newPassword": "revoked-teacher-password"})
        self.assertTrue(response.ok)
        page.locator("#switch-role").click()
        page.get_by_role("button", name="Sign out", exact=True).click()
        expect(dialog.get_by_role("heading", name="Welcome to OfficeFlow")).to_be_visible()
        expect(page.locator("#main")).not_to_contain_text("Sam Chen")
        self.assertIsNone(page.evaluate("sessionStorage.getItem('officeflow-token')"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
