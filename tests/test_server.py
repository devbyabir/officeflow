"""Integration checks against a real local Java HTTP/JDBC server.

Run `mvn -f server/pom.xml package dependency:copy-dependencies` first.
JAVA and OFFICEFLOW_CP may select a local JDK and prebuilt classpath.
"""
from pathlib import Path
import json
import os
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
JAVA = os.environ.get("JAVA", "java")
CLASSPATH = os.environ.get("OFFICEFLOW_CP", os.pathsep.join([
    str(ROOT / "server/target/classes"), str(ROOT / "server/target/dependency/*")]))


def main():
    with tempfile.TemporaryDirectory(prefix="officeflow-http-") as temp:
        log = Path(temp) / "server.log"
        env = dict(os.environ, OFFICEFLOW_ADMIN_PASSWORD="test-admin-password")
        with log.open("w", encoding="utf-8") as stream:
            process = subprocess.Popen([JAVA, "-Dofficeflow.port=0",
                "-Dofficeflow.db=jdbc:h2:" + (Path(temp) / "database").as_posix(),
                "-Dofficeflow.site=" + str(ROOT / "docs/site"), "-cp", CLASSPATH,
                "com.officeflow.App"], stdout=stream, stderr=stream, env=env, cwd=ROOT)
            try:
                for _ in range(100):
                    content = log.read_text(encoding="utf-8")
                    if "OfficeFlow: http://" in content:
                        base = content.split("OfficeFlow: ", 1)[1].splitlines()[0]
                        break
                    if process.poll() is not None:
                        raise AssertionError(content)
                    time.sleep(0.1)
                else:
                    raise AssertionError("Server did not start")

                def call(path, data=None, token=None, expected=200):
                    headers = {"Content-Type": "application/json"}
                    if token:
                        headers["Authorization"] = "Bearer " + token
                    req = urllib.request.Request(base + path,
                        data=json.dumps(data).encode() if data is not None else None,
                        headers=headers)
                    try:
                        with urllib.request.urlopen(req, timeout=10) as response:
                            assert response.status == expected
                            raw = response.read()
                            return json.loads(raw) if "json" in response.headers.get("Content-Type", "") else raw
                    except urllib.error.HTTPError as error:
                        assert error.code == expected, (error.code, error.read())
                        return json.loads(error.read())

                assert b"OfficeFlow" in call("/")
                assert call("/api/health")["service"] == "officeflow"
                call("/api/state", expected=403)
                call("/api/login", {"id": "001", "password": "bad"}, expected=403)
                admin = call("/api/login", {"id": "001", "password": "test-admin-password"})["token"]

                def command(action, data, token=admin, expected=200):
                    return call("/api/command", {"action": action, "data": data}, token, expected)

                command("saveTeacher", {"id":"T100", "name":"QA Teacher", "department":"Science", "email":""})
                teacher = call("/api/login", {"id":"T100", "password":"T100"})["token"]
                state = command("saveSupply", {"name":"QA Pens", "category":"Stationery", "quantity":"12", "threshold":"2", "unit":"pieces"})
                item = state["supplies"][0]["id"]
                command("saveSupply", {"name":"Forbidden"}, teacher, 403)
                state = command("request", {"supplyId":item, "quantity":"4", "note":"For class"}, teacher)
                request = state["requests"][0]["id"]
                command("issue", {"id":request}, teacher, 403)
                state = command("issue", {"id":request})
                assert state["supplies"][0]["quantity"] == 8
                command("issue", {"id":request}, expected=400)
                command("request", {"supplyId":item, "quantity":"9"}, teacher, 400)
                assert "password" not in json.dumps(call("/api/state", token=admin)).lower()
                call("/api/import", {"type":"teachers", "csv":"id,name,department,email\nT200,New,CS,\nT100,Duplicate,CS,"}, admin, 400)
                assert len(call("/api/state", token=admin)["teachers"]) == 1
                second = call("/api/login", {"id":"T100", "password":"T100"})["token"]
                call("/api/password/change", {"currentPassword":"wrong", "newPassword":"teacher-new-password"}, teacher, 403)
                call("/api/password/change", {"currentPassword":"T100", "newPassword":"short"}, teacher, 400)
                call("/api/password/reset", {"id":"T100", "newPassword":"teacher-reset-password"}, teacher, 403)
                call("/api/password/change", {"currentPassword":"T100", "newPassword":"teacher-new-password"}, teacher)
                call("/api/state", token=teacher, expected=403)
                assert call("/api/state", token=second, expected=403)["code"] == "SESSION_EXPIRED"
                call("/api/login", {"id":"T100", "password":"T100"}, expected=403)
                teacher = call("/api/login", {"id":"T100", "password":"teacher-new-password"})["token"]
                # An ordinary inventory write must preserve the changed credential.
                command("saveSupply", {"name":"QA Clips", "category":"Stationery", "quantity":"2", "threshold":"1", "unit":"boxes"})
                call("/api/login", {"id":"T100", "password":"teacher-new-password"})
                call("/api/password/reset", {"id":"001", "newPassword":"forbidden-admin-reset"}, admin, 400)
                call("/api/password/reset", {"id":"T100", "newPassword":"teacher-reset-password"}, admin)
                call("/api/state", token=teacher, expected=403)
                teacher = call("/api/login", {"id":"T100", "password":"teacher-reset-password"})["token"]
                call("/api/logout", {}, teacher)
                call("/api/state", token=teacher, expected=403)
                call("/api/logout", {}, teacher, 403)
                teacher = call("/api/login", {"id":"T100", "password":"teacher-reset-password"})["token"]
                command("deleteTeacher", {"id":"T100"})
                call("/api/state", token=teacher, expected=403)
                # Recreating an ID must not reactivate an old session.
                command("saveTeacher", {"id":"T100", "name":"New Teacher", "department":"Science", "email":""})
                call("/api/state", token=teacher, expected=403)
                admin2 = call("/api/login", {"id":"001", "password":"test-admin-password"})["token"]
                call("/api/password/change", {"currentPassword":"test-admin-password", "newPassword":"updated-admin-password"}, admin)
                call("/api/state", token=admin, expected=403)
                call("/api/state", token=admin2, expected=403)
                call("/api/login", {"id":"001", "password":"updated-admin-password"})
                print("HTTP integration passed: password change/reset/logout and session revocation; static serving, login, RBAC, stock, replay prevention, CSV rollback and deleted-account sessions.")
            finally:
                process.terminate()
                process.wait(timeout=10)


if __name__ == "__main__":
    main()
