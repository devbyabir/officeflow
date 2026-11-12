"""Integration checks against a real local Java HTTP/JDBC server.

Run `mvn -f server/pom.xml package dependency:copy-dependencies` first.
JAVA and OFFICEFLOW_CP may select a local JDK and prebuilt classpath.
Every server uses a disposable database in a temporary folder and fictional records.
"""
from pathlib import Path
import json
import os
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
JAVA = os.environ.get("JAVA", "java")
CLASSPATH = os.environ.get("OFFICEFLOW_CP", os.pathsep.join([
    str(ROOT / "server/target/classes"), str(ROOT / "server/target/dependency/*")]))
JAR = ROOT / "server/target/officeflow-1.0.1.jar"
ADMIN_PASSWORD = "test-admin"
SAMPLE_URL = "https://devbyabir.github.io/officeflow/"
READY_LINE = "Press Ctrl+C to stop."  # Printed after the URL, Database and Web files lines.


def clean_env(**extra):
    """The test environment without any real workspace settings from this machine."""
    env = {k: v for k, v in os.environ.items()
           if k not in ("OFFICEFLOW_ADMIN_PASSWORD", "LOCALAPPDATA")}
    env.update(extra)
    return env


class Server:
    """Starts OfficeFlow and waits for its address, or for it to stop with a message."""

    def __init__(self, temp, options, env, cwd=ROOT, use_jar=False, site=True):
        handle, name = tempfile.mkstemp(dir=temp, suffix=".log")
        os.close(handle)
        self.log = Path(name)
        command = [JAVA, "-Dofficeflow.port=0", *options]
        if site:
            command.append("-Dofficeflow.site=" + str(ROOT / "docs/site"))
        command += ["-jar", str(JAR)] if use_jar else ["-cp", CLASSPATH, "com.officeflow.App"]
        self.stream = self.log.open("w", encoding="utf-8")
        self.process = subprocess.Popen(command, stdout=self.stream, stderr=self.stream,
                                        env=env, cwd=cwd)
        self.base = None
        for _ in range(150):
            content = self.output()
            # The URL is printed before the Database and Web files lines that tests read,
            # so wait for the last startup line.
            if READY_LINE in content:
                self.base = content.split("OfficeFlow: ", 1)[1].splitlines()[0]
                return
            if self.process.poll() is not None:
                return
            time.sleep(0.1)
        self.stop()
        raise AssertionError("Server neither started nor stopped:\n" + self.output())

    def output(self):
        return self.log.read_text(encoding="utf-8")

    def stop(self):
        if self.process.poll() is None:
            if self.base:
                try:
                    urllib.request.urlopen(urllib.request.Request(self.base + "/api/quit",
                        data=b"{}", headers={"Content-Type": "application/json"}), timeout=3).close()
                    self.process.wait(timeout=10)
                except (OSError, subprocess.TimeoutExpired):
                    self.process.terminate()
            else:
                self.process.terminate()
        self.process.wait(timeout=20)
        self.stream.close()


def start(temp, options, env, **kwargs):
    server = Server(temp, options, env, **kwargs)
    assert server.base, "Server did not start:\n" + server.output()
    return server


def refused(temp, options, env, *expected, **kwargs):
    """The server must stop before serving, with exit code 2 and every expected phrase."""
    server = Server(temp, options, env, **kwargs)
    server.stop()
    output = server.output()
    assert server.base is None and server.process.returncode == 2, output
    for phrase in expected:
        assert phrase in output, (phrase, output)
    return output


def database(path):
    return "-Dofficeflow.db=jdbc:h2:" + Path(path).as_posix()


def client(base):
    def call(path, data=None, token=None, expected=200):
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + token
        req = urllib.request.Request(base + path,
            data=json.dumps(data).encode() if data is not None else None, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=10) as response:
                assert response.status == expected, (path, response.status)
                raw = response.read()
                if "json" in response.headers.get("Content-Type", ""):
                    return json.loads(raw)
                return raw, response.headers
        except urllib.error.HTTPError as error:
            assert error.code == expected, (path, error.code, error.read())
            return json.loads(error.read())
    return call


def temporary_password(result, teacher):
    passwords = {entry["id"]: entry["password"] for entry in result["temporaryPasswords"]}
    return passwords[teacher]


def pending_request(state):
    """The only pending request. Command results append new requests, so [0] is not newest."""
    pending = [r["id"] for r in state["requests"] if r["status"] == "Pending"]
    assert len(pending) == 1, state["requests"]
    return pending[0]


def workflow(temp):
    """Fresh setup, first-login restriction, roles, stock rules and session revocation."""
    db = Path(temp) / "workspace" / "officeflow"
    # A new workspace is not created without a valid administrator password.
    refused(temp, [database(db)], clean_env(), "OFFICEFLOW_ADMIN_PASSWORD", "Nothing was created")
    refused(temp, [database(db)], clean_env(OFFICEFLOW_ADMIN_PASSWORD="001"),
            "6-12 characters")
    # New passwords are limited to 12 characters.
    refused(temp, [database(db)], clean_env(OFFICEFLOW_ADMIN_PASSWORD="fourteen chars"),
            "6-12 characters")
    assert not db.parent.exists() or not any(db.parent.iterdir())

    server = start(temp, [database(db)], clean_env(OFFICEFLOW_ADMIN_PASSWORD=ADMIN_PASSWORD))
    try:
        assert ("Database: " + str(db) + ".mv.db") in server.output(), server.output()
        call = client(server.base)
        page, headers = call("/")
        assert b'<meta name="officeflow-mode" content="java" />' in page
        assert headers.get("Cache-Control") == "no-store"
        assert call("/api/health")["service"] == "officeflow"
        call("/api/state", expected=403)
        call("/api/login", {"id": "001", "password": "bad"}, expected=403)
        login = call("/api/login", {"id": "001", "password": ADMIN_PASSWORD})
        assert login["actor"]["mustChangePassword"] is False
        admin = login["token"]

        def command(action, data, token=admin, expected=200):
            return call("/api/command", {"action": action, "data": data}, token, expected)

        created = command("saveTeacher", {"id": "T100", "name": "QA Teacher",
                                          "department": "Science", "email": ""})
        temporary = temporary_password(created, "T100")
        assert len(temporary) >= 12
        assert "temporaryPasswords" not in call("/api/state", token=admin)
        call("/api/login", {"id": "T100", "password": "T100"}, expected=403)

        # A temporary password signs in, but only to change itself.
        login = call("/api/login", {"id": "T100", "password": temporary})
        assert login["actor"]["mustChangePassword"] is True
        limited = login["token"]
        for path in ("/api/state",):
            assert call(path, token=limited, expected=403)["code"] == "PASSWORD_CHANGE_REQUIRED"
        assert call("/api/command", {"action": "request", "data": {}}, limited,
                    403)["code"] == "PASSWORD_CHANGE_REQUIRED"
        assert call("/api/import", {"type": "teachers", "csv": ""}, limited,
                    403)["code"] == "PASSWORD_CHANGE_REQUIRED"
        assert call("/api/session", token=limited)["actor"]["mustChangePassword"] is True
        call("/api/password/change", {"currentPassword": temporary, "newPassword": "short", "hint": "school clue"},
             limited, 400)
        call("/api/password/change", {"currentPassword": temporary,
                                      "newPassword": "teacher-own", "hint": "first classroom"}, limited)
        call("/api/session", token=limited, expected=403)
        call("/api/login", {"id": "T100", "password": temporary}, expected=403)
        login = call("/api/login", {"id": "T100", "password": "teacher-own"})
        assert login["actor"]["mustChangePassword"] is False
        teacher = login["token"]

        state = command("saveSupply", {"name": "QA Pens", "category": "Stationery",
                                       "quantity": "12", "threshold": "2", "unit": "pieces"})
        item = state["supplies"][0]["id"]
        command("saveSupply", {"name": "Forbidden"}, teacher, 403)
        state = command("request", {"supplyId": item, "quantity": "4", "note": "For class"},
                        teacher)
        request = pending_request(state)
        command("issue", {"id": request}, teacher, 403)
        state = command("issue", {"id": request})
        assert state["supplies"][0]["quantity"] == 8
        command("issue", {"id": request}, expected=400)
        command("request", {"supplyId": item, "quantity": "9"}, teacher, 400)

        # Rejection and cancellation release the reservation.
        rejected = command("request", {"supplyId": item, "quantity": "8"}, teacher)
        command("request", {"supplyId": item, "quantity": "1"}, teacher, 400)
        command("reject", {"id": pending_request(rejected)})
        cancelled = command("request", {"supplyId": item, "quantity": "8"}, teacher)
        command("cancel", {"id": pending_request(cancelled)}, admin, 403)
        command("cancel", {"id": pending_request(cancelled)}, teacher)
        assert call("/api/state", token=admin)["supplies"][0]["quantity"] == 8

        assert "password" not in json.dumps(call("/api/state", token=admin)).lower()
        call("/api/import", {"type": "teachers", "csv":
             "id,name,department,email\nT200,New,CS,\nT100,Duplicate,CS,"}, admin, 400)
        assert len(call("/api/state", token=admin)["teachers"]) == 1
        second = call("/api/login", {"id": "T100", "password": "teacher-own"})["token"]
        call("/api/password/change", {"currentPassword": "wrong",
                                      "newPassword": "teacher-new", "hint": "second room"}, teacher, 403)
        call("/api/password/reset", {"id": "T100", "newPassword": "teach-reset"},
             teacher, 403)
        call("/api/password/change", {"currentPassword": "teacher-own",
                                      "newPassword": "teacher-new", "hint": "second room"}, teacher)
        call("/api/state", token=teacher, expected=403)
        assert call("/api/state", token=second, expected=403)["code"] == "SESSION_EXPIRED"
        teacher = call("/api/login", {"id": "T100", "password": "teacher-new"})["token"]
        # An ordinary inventory write must preserve the changed credential.
        command("saveSupply", {"name": "QA Clips", "category": "Stationery", "quantity": "2",
                               "threshold": "1", "unit": "boxes"})
        call("/api/login", {"id": "T100", "password": "teacher-new"})
        call("/api/password/reset", {"id": "001", "newPassword": "forbidden-admin-reset"},
             admin, 400)
        # An administrator's reset is temporary: the teacher must choose a new password.
        call("/api/password/reset", {"id": "T100", "newPassword": "teach-reset"},
             admin)
        call("/api/state", token=teacher, expected=403)
        reset = call("/api/login", {"id": "T100", "password": "teach-reset"})
        assert reset["actor"]["mustChangePassword"] is True
        assert call("/api/state", token=reset["token"],
                    expected=403)["code"] == "PASSWORD_CHANGE_REQUIRED"
        call("/api/logout", {}, reset["token"])
        call("/api/state", token=reset["token"], expected=403)
        call("/api/logout", {}, reset["token"], 403)
        teacher = call("/api/login", {"id": "T100", "password": "teach-reset"})["token"]
        call("/api/password/change", {"currentPassword": "teach-reset",
                                      "newPassword": "teach-final", "hint": "final room"}, teacher)
        teacher = call("/api/login", {"id": "T100", "password": "teach-final"})["token"]
        created = command("saveTeacher", {"id": "T300", "name": "Temporary", "department": "Art",
                                          "email": ""})
        command("deleteTeacher", {"id": "T300"})
        call("/api/login", {"id": "T300", "password": temporary_password(created, "T300")},
             expected=403)
        admin2 = call("/api/login", {"id": "001", "password": ADMIN_PASSWORD})["token"]
        call("/api/password/change", {"currentPassword": ADMIN_PASSWORD,
                                      "newPassword": "admin-new", "hint": "admin clue"}, admin)
        call("/api/state", token=admin, expected=403)
        call("/api/state", token=admin2, expected=403)
        admin = call("/api/login", {"id": "001", "password": "admin-new"})["token"]
        before = call("/api/state", token=admin)
    finally:
        server.stop()

    # Restart without OFFICEFLOW_ADMIN_PASSWORD: the workspace reopens unchanged.
    server = start(temp, [database(db)], clean_env())
    try:
        call = client(server.base)
        admin = call("/api/login", {"id": "001", "password": "admin-new"})["token"]
        assert call("/api/state", token=admin) == before
        call("/api/login", {"id": "T100", "password": "teach-final"})
    finally:
        server.stop()
    print("Workflow passed: new-workspace admin password, temporary teacher passwords,"
          " first-login restriction, RBAC, stock reservations, reject/cancel release,"
          " issue-once, CSV rollback, session revocation and restart.")


def seed_flag_and_backup(temp):
    """The old seed flag must not touch a workspace whose inventory happens to be empty."""
    db = Path(temp) / "history" / "officeflow"
    server = start(temp, [database(db)], clean_env(OFFICEFLOW_ADMIN_PASSWORD=ADMIN_PASSWORD))
    try:
        call = client(server.base)
        admin = call("/api/login", {"id": "001", "password": ADMIN_PASSWORD})["token"]

        def command(action, data, token=admin):
            return call("/api/command", {"action": action, "data": data}, token)

        temporary = temporary_password(command("saveTeacher", {
            "id": "T001", "name": "Real Teacher", "department": "Office", "email": ""}), "T001")
        limited = call("/api/login", {"id": "T001", "password": temporary})["token"]
        call("/api/password/change", {"currentPassword": temporary,
                                      "newPassword": "real-teacher", "hint": "school clue"}, limited)
        teacher = call("/api/login", {"id": "T001", "password": "real-teacher"})["token"]
        state = command("saveSupply", {"name": "Ink", "category": "Paper & print",
                                       "quantity": "3", "threshold": "1", "unit": "cartridges"})
        supply = state["supplies"][0]["id"]
        request = command("request", {"supplyId": supply, "quantity": "2"}, teacher)
        command("issue", {"id": pending_request(request)})
        command("deleteSupply", {"id": supply})
        before = call("/api/state", token=admin)
        assert before["supplies"] == [] and len(before["teachers"]) == 1
        assert before["requests"][0]["status"] == "Issued"
    finally:
        server.stop()

    file = Path(str(db) + ".mv.db")
    original = file.read_bytes()
    refused(temp, [database(db), "-Dofficeflow.seed=true"],
            clean_env(OFFICEFLOW_ADMIN_PASSWORD=ADMIN_PASSWORD),
            "no longer loads sample data", SAMPLE_URL, "Nothing was opened or changed")
    assert file.read_bytes() == original, "The database file changed"

    server = start(temp, [database(db)], clean_env())
    try:
        call = client(server.base)
        admin = call("/api/login", {"id": "001", "password": ADMIN_PASSWORD})["token"]
        assert call("/api/state", token=admin) == before
        call("/api/login", {"id": "T001", "password": "real-teacher"})
        state = call("/api/command", {"action": "saveSupply", "data": {
            "name": "Toner", "category": "Paper & print", "quantity": "6", "threshold": "2",
            "unit": "boxes"}}, admin)
        before = call("/api/state", token=admin)
    finally:
        server.stop()

    # Back up with the server stopped, then restore into a separate folder and open the copy.
    restored = Path(temp) / "restored" / "officeflow"
    restored.parent.mkdir()
    shutil.copy2(file, Path(str(restored) + ".mv.db"))
    server = start(temp, [database(restored)], clean_env())
    try:
        call = client(server.base)
        admin = call("/api/login", {"id": "001", "password": ADMIN_PASSWORD})["token"]
        state = call("/api/state", token=admin)
        assert state == before
        assert [s["quantity"] for s in state["supplies"]] == [6]
        assert state["requests"][0]["status"] == "Issued"
        teacher = call("/api/login", {"id": "T001", "password": "real-teacher"})
        assert teacher["actor"]["mustChangePassword"] is False
    finally:
        server.stop()
    print("Old seed flag refused before opening; a supply-free workspace with teachers,"
          " credentials and history is byte-for-byte unchanged; backup restore keeps stock,"
          " credentials and request history.")


def startup_paths(temp):
    """Startup from another working directory, the Windows default and an old ./data file."""
    elsewhere = Path(temp) / "elsewhere"
    elsewhere.mkdir()
    db = Path(temp) / "elsewhere-db" / "officeflow"
    # The web files are found from the code location when started outside the repository.
    server = start(temp, [database(db)], clean_env(OFFICEFLOW_ADMIN_PASSWORD=ADMIN_PASSWORD),
                   cwd=elsewhere, site=False)
    try:
        assert "Web files: " + str(ROOT / "docs/site") in server.output(), server.output()
        page, _ = client(server.base)("/")
        assert b'content="java"' in page
    finally:
        server.stop()
    refused(temp, [database(db), "-Dofficeflow.site=" + str(elsewhere)], clean_env(),
            "could not find its web files", "index.html is missing", site=False)

    if JAR.is_file():
        server = start(temp, [database(db)], clean_env(), cwd=elsewhere, site=False,
                       use_jar=True)
        server.stop()
        print("JAR started from another folder; it still reads docs/site from the checkout.")

    local = Path(temp) / "local-app-data"
    work = Path(temp) / "work"
    work.mkdir()
    default_file = local / "OfficeFlow" / "officeflow.mv.db"
    repository_data = ROOT / "data" / "officeflow.mv.db"
    if repository_data.exists():
        print("Skipped default-location checks: this checkout has data/officeflow.mv.db.")
        return
    server = start(temp, [], clean_env(LOCALAPPDATA=str(local),
                                       OFFICEFLOW_ADMIN_PASSWORD=ADMIN_PASSWORD), cwd=work)
    try:
        assert "Database: " + str(default_file) in server.output(), server.output()
    finally:
        server.stop()
    assert default_file.is_file()

    # An older ./data workspace stops a blank default workspace from being created.
    old = Path(temp) / "old"
    (old / "data").mkdir(parents=True)
    shutil.copy2(default_file, old / "data" / "officeflow.mv.db")
    empty_local = Path(temp) / "empty-local"
    refused(temp, [], clean_env(LOCALAPPDATA=str(empty_local),
                                OFFICEFLOW_ADMIN_PASSWORD=ADMIN_PASSWORD),
            "Found an existing OfficeFlow database", "Move-Item", "-Dofficeflow.db=jdbc:h2:",
            "Nothing was created or moved", cwd=old)
    assert not empty_local.exists()
    assert (old / "data" / "officeflow.mv.db").is_file()
    # Following the "keep using it" instruction opens the old workspace.
    server = start(temp, [database(old / "data" / "officeflow")],
                   clean_env(LOCALAPPDATA=str(empty_local)), cwd=old)
    try:
        client(server.base)("/api/login", {"id": "001", "password": ADMIN_PASSWORD})
    finally:
        server.stop()
    print("Startup paths passed: other working directory, %LOCALAPPDATA% default, old ./data"
          " detection without moving or creating files.")


def browser_setup(temp):
    """First run from OfficeFlow.exe: one-time setup token, localhost only, then sign-in; quit."""
    db = Path(temp) / "browser-setup" / "officeflow"
    token = "T" * 20 + "setup-token-for-tests_0123"
    options = [database(db), "-Dofficeflow.browserSetup=true"]
    server = start(temp, options, clean_env(OFFICEFLOW_SETUP_TOKEN=token))
    try:
        call = client(server.base)
        assert token not in server.output(), "a token chosen by the launcher is never printed"
        assert call("/api/setup") == {"required": True, "status": "ready"}
        call("/api/login", {"id": "001", "password": ADMIN_PASSWORD}, expected=403)
        call("/api/state", expected=403)
        # Another site's name for 127.0.0.1 (DNS rebinding) is refused before anything else.
        port = server.base.rstrip("/").rsplit(":", 1)[1]
        spoofed = urllib.request.Request(server.base + "/api/setup",
                                         headers={"Host": "officeflow.example:" + port})
        try:
            urllib.request.urlopen(spoofed, timeout=10)
            raise AssertionError("a foreign Host header reached setup")
        except urllib.error.HTTPError as error:
            assert error.code == 403, error.code
        # A bad username or a weak or mismatched password is rejected without using the token.
        account = {"token": token, "username": "Office.Admin", "hint": "office clue"}
        call("/api/setup", {**account, "password": "short"}, expected=400)
        call("/api/setup", {**account, "password": "fourteen chars"}, expected=400)
        call("/api/setup", {**account, "username": "1st", "password": ADMIN_PASSWORD}, expected=400)
        call("/api/setup", {**account, "username": "", "password": ADMIN_PASSWORD}, expected=400)
        call("/api/setup", {**account, "password": ADMIN_PASSWORD,
                            "confirmPassword": ADMIN_PASSWORD + "x"}, expected=400)
        wrong = call("/api/setup", {**account, "token": "x" * 43, "password": ADMIN_PASSWORD},
                     expected=403)
        assert wrong["code"] == "SETUP_TOKEN_INVALID", wrong
        assert call("/api/setup")["status"] == "ready"
        done = call("/api/setup", {**account, "password": ADMIN_PASSWORD,
                                   "confirmPassword": ADMIN_PASSWORD})
        # Signed in at once, as the administrator, with the chosen (lower-case) username.
        assert done["actor"] == {"id": "001", "role": "admin", "mustChangePassword": False,
                                 "username": "office.admin"}, done
        assert call("/api/session", token=done["token"])["actor"]["username"] == "office.admin"
        assert call("/api/setup") == {"required": False, "status": "done"}
        # Setup is closed for good: the same token or a new password cannot replace the admin.
        call("/api/setup", {**account, "password": "replacement-password"}, expected=409)
        call("/api/login", {"id": "001", "password": "replacement-password"}, expected=403)
        # Log in with the username (any case) or the account ID; checked against the hash.
        call("/api/login", {"username": "OFFICE.ADMIN", "password": ADMIN_PASSWORD})
        call("/api/login", {"username": "001", "password": ADMIN_PASSWORD})
        call("/api/login", {"id": "001", "password": ADMIN_PASSWORD})
        failed = call("/api/login", {"username": "office.admin", "password": "wrong-password-1"},
                      expected=403)
        assert failed["error"] == "Username or password is incorrect.", failed
        assert call("/api/login", {"username": "nobody", "password": ADMIN_PASSWORD},
                    expected=403)["error"] == failed["error"], "no hint whether a username exists"
        # Usernames are unique, follow the rules, and never equal an account ID.
        admin = call("/api/login", {"username": "office.admin", "password": ADMIN_PASSWORD})["token"]
        created = call("/api/command", {"action": "saveTeacher", "data": {
            "id": "T010", "name": "Robin Lee", "department": "Science", "email": ""}}, admin)
        teacher = call("/api/login", {"id": "T010",
                                      "password": temporary_password(created, "T010")})["token"]
        call("/api/username", {"username": "robin"}, teacher, expected=403)  # must change first
        call("/api/password/change", {"currentPassword": temporary_password(created, "T010"),
                                      "newPassword": "robin-choose", "hint": "robin clue"}, teacher)
        teacher = call("/api/login", {"id": "T010", "password": "robin-choose"})["token"]
        for taken in ("Office.Admin", "001", "x", "9lives"):
            call("/api/username", {"username": taken}, teacher, expected=400)
        # Another account's ID cannot become a username (an account may reuse its own ID).
        call("/api/username", {"username": "t010"}, admin, expected=400)
        saved = call("/api/username", {"username": "Robin_Lee"}, teacher)
        assert saved["actor"]["username"] == "robin_lee", saved
        call("/api/login", {"username": "robin_lee", "password": "robin-choose"})
        call("/api/login", {"id": "T010", "password": "robin-choose"})
        # A new teacher ID may not equal an existing username (ignoring case).
        clash = call("/api/command", {"action": "saveTeacher", "data": {
            "id": "ROBIN_LEE", "name": "Dup", "department": "Art", "email": ""}}, admin,
            expected=400)
        assert "already used as a username" in clash["error"], clash
        # Quit needs a JSON POST from this computer; it stops cleanly with exit code 0.
        call("/api/quit", expected=400)
        assert call("/api/quit", {})["message"] == "OfficeFlow is stopping."
        server.process.wait(timeout=20)
        assert server.process.returncode == 0, server.process.returncode
        assert "OfficeFlow stopped cleanly; the database is closed." in server.output()
    finally:
        server.stop()
    log = (db.parent / "officeflow.log").read_text(encoding="utf-8")
    assert "(first-run setup)" in log, log
    assert log.rstrip().endswith("stopped cleanly; database closed"), log

    # Returning users: the same workspace opens to sign-in, with the account preserved.
    server = start(temp, options, clean_env(OFFICEFLOW_SETUP_TOKEN=token,
                                            OFFICEFLOW_ADMIN_PASSWORD="ignored-password-1"))
    try:
        call = client(server.base)
        assert call("/api/setup") == {"required": False, "status": "done"}
        call("/api/setup", {"token": token, "password": "replacement-password"}, expected=409)
        call("/api/login", {"id": "001", "password": ADMIN_PASSWORD})
        call("/api/login", {"id": "001", "password": "ignored-password-1"}, expected=403)
    finally:
        server.stop()

    # Started by hand without a launcher token: a generated one is printed for this person only.
    fresh = Path(temp) / "browser-setup-manual" / "officeflow"
    server = start(temp, [database(fresh), "-Dofficeflow.browserSetup=true"], clean_env())
    try:
        lines = [line for line in server.output().splitlines() if "/#setup=" in line]
        assert lines and "within 15 minutes" in lines[0], server.output()
        printed = lines[0].split("/#setup=", 1)[1].split()[0]
        manual = client(server.base)
        ready = manual("/api/setup", {"token": printed, "username": "manual",
                       "hint": "first setup clue", "password": ADMIN_PASSWORD})
        code = ready["recoveryCode"]
        assert code.startswith("001.") and len(code) == 36
        assert manual("/api/recovery/hint", {"username": "manual"})["hint"] == "first setup clue"
        assert manual("/api/recovery/hint", {"username": "unknown"})["hint"] == ""
        assert manual("/api/recovery/reset", {"recoveryCode": code,
                      "newPassword": "new-pass", "hint": "new-pass"}, expected=400)["error"]
        changed = manual("/api/recovery/reset", {"recoveryCode": code,
                         "newPassword": "new-pass", "hint": "fresh clue"})
        assert changed["username"] == "manual" and changed["recoveryCode"] != code
        manual("/api/recovery/reset", {"recoveryCode": code,
               "newPassword": "another", "hint": "fresh clue"}, expected=403)
        manual("/api/login", {"username": "manual", "password": ADMIN_PASSWORD}, expected=403)
        manual("/api/login", {"username": "manual", "password": "new-pass"})
    finally:
        server.stop()
    print("Browser setup passed: one-time token, Host check, username and passphrase rules"
          " before the token is used, signed in after setup, login by username or account ID,"
          " unique usernames, setup closed after the first admin, account kept on restart,"
          " clean quit.")


def legacy_upgrade(temp):
    """A copy of a workspace made by the previous release opens unchanged in this one."""
    legacy_jar = os.environ.get("OFFICEFLOW_LEGACY_JAR")
    if not legacy_jar:
        print("Skipped the legacy workspace upgrade: set OFFICEFLOW_LEGACY_JAR to the previous"
              " release's JAR.")
        return
    original = Path(temp) / "legacy-original" / "officeflow"
    # 13 characters: valid in 1.0.0, retained on upgrade but too long for a new password.
    old_admin, old_teacher = "legacy-pass13", "legacy-teach1"
    # The previous release reads the web files of its own checkout (server/target/../../docs).
    legacy_site = Path(legacy_jar).resolve().parents[2] / "docs" / "site"
    command = [JAVA, "-Dofficeflow.port=0", database(original),
               "-Dofficeflow.site=" + str(legacy_site), "-jar", legacy_jar]
    handle, name = tempfile.mkstemp(dir=temp, suffix=".log")
    os.close(handle)
    log = Path(name)
    with log.open("w", encoding="utf-8") as stream:
        process = subprocess.Popen(command, stdout=stream, stderr=stream, cwd=ROOT,
                                   env=clean_env(OFFICEFLOW_ADMIN_PASSWORD=old_admin))
        try:
            for _ in range(150):
                if READY_LINE in log.read_text(encoding="utf-8") or process.poll() is not None:
                    break
                time.sleep(0.1)
            text = log.read_text(encoding="utf-8")
            assert READY_LINE in text, text
            call = client(text.split("OfficeFlow: ", 1)[1].splitlines()[0])
            admin = call("/api/login", {"id": "001", "password": old_admin})["token"]
            created = call("/api/command", {"action": "saveTeacher", "data": {
                "id": "T100", "name": "Legacy Teacher", "department": "Maths", "email": ""}}, admin)
            first = call("/api/login", {"id": "T100", "password":
                                        temporary_password(created, "T100")})["token"]
            call("/api/password/change", {"currentPassword": temporary_password(created, "T100"),
                                          "newPassword": old_teacher, "hint": "legacy clue"}, first)
            call("/api/command", {"action": "saveSupply", "data": {
                "name": "Legacy staplers", "category": "Desk essentials", "quantity": "7",
                "threshold": "2", "unit": "pieces"}}, admin)
            teacher = call("/api/login", {"id": "T100", "password": old_teacher})["token"]
            supply = [s for s in call("/api/state", token=teacher)["supplies"]
                      if s["name"] == "Legacy staplers"][0]
            call("/api/command", {"action": "request", "data": {
                "supplyId": supply["id"], "quantity": "2", "note": "legacy"}}, teacher)
        finally:
            process.terminate()
            process.wait(timeout=20)
    original_file = original.parent / "officeflow.mv.db"
    before = original_file.read_bytes()

    # Upgrade a copy, as installing over an existing workspace would, and open it here.
    copy = Path(temp) / "legacy-copy" / "officeflow"
    copy.parent.mkdir(parents=True)
    shutil.copy2(original_file, copy.parent / "officeflow.mv.db")
    server = start(temp, [database(copy), "-Dofficeflow.browserSetup=true"],
                   clean_env(OFFICEFLOW_SETUP_TOKEN="L" * 43))
    try:
        call = client(server.base)
        assert call("/api/setup") == {"required": False, "status": "done"}, "no setup again"
        login = call("/api/login", {"username": "001", "password": old_admin})
        assert login["actor"].get("username") is None, login  # Gson omits a null username
        admin = login["token"]
        state = call("/api/state", token=admin)
        assert [s["quantity"] for s in state["supplies"] if s["name"] == "Legacy staplers"] == [7]
        assert [r["status"] for r in state["requests"] if r["note"] == "legacy"] == ["Pending"]
        assert [t["name"] for t in state["teachers"]] == ["Legacy Teacher"]
        teacher = call("/api/login", {"id": "T100", "password": old_teacher})["token"]
        # Choosing a username keeps the original password, and the ID keeps working.
        call("/api/username", {"username": "legacy.admin"}, admin)
        call("/api/login", {"username": "legacy.admin", "password": old_admin})
        call("/api/login", {"id": "001", "password": old_admin})
        call("/api/username", {"username": "legacy.teacher"}, teacher)
        call("/api/login", {"username": "legacy.teacher", "password": old_teacher})
        # The old 13-character passwords keep working; a new one needs 6–12.
        call("/api/password/change", {"currentPassword": old_admin,
                                      "newPassword": "short", "hint": "school clue"}, admin, expected=400)
    finally:
        server.stop()
    assert original_file.read_bytes() == before, "the original workspace was not touched"
    print("Legacy workspace upgrade passed: a copy of a workspace made by the previous release"
          " opened without setup; its 13-character admin and teacher passwords still work by"
          " account ID; its supply, teacher and pending request are intact; usernames can be"
          " added; the original file is unchanged.")


def main():
    with tempfile.TemporaryDirectory(prefix="officeflow-http-") as temp:
        workflow(temp)
        seed_flag_and_backup(temp)
        startup_paths(temp)
        browser_setup(temp)
        legacy_upgrade(temp)
    print("HTTP integration passed.")


if __name__ == "__main__":
    try:
        main()
    except BaseException as error:
        # One line the CI summary picks up ("FAILED"), so the cause shows on the run page.
        import traceback
        frames = traceback.extract_tb(error.__traceback__)[-3:]
        where = " <- ".join(f"{f.name}:{f.lineno} {f.line}" for f in reversed(frames))
        print(f"HTTP integration FAILED: {type(error).__name__}: {str(error)[:1500]} at {where}",
              flush=True)
        raise
