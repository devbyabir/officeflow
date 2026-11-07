package com.officeflow;

import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;

/**
 * Dependency-free integration test, run by CI after the Maven build. Every workspace is a
 * disposable H2 database under a temporary folder, filled with fictional records.
 */
public final class ServiceTest {
  private static final String ADMIN_PASSWORD = "test-admin-password";

  public static final class WriteCounter implements org.h2.api.Trigger {
    static int writes;

    @Override
    public void fire(java.sql.Connection connection, Object[] before, Object[] after) {
      writes++;
    }
  }

  private static JsonObject data(String json) {
    return JsonParser.parseString(json).getAsJsonObject();
  }

  private static void check(boolean condition) {
    if (!condition) throw new AssertionError("Invariant failed");
  }

  private static void denied(RunnableWithSql action) {
    try {
      action.run();
      throw new AssertionError("Expected rejection");
    } catch (IllegalArgumentException
        | SecurityException
        | IllegalStateException
        | Startup.Problem expected) {
    } catch (Exception e) {
      throw new RuntimeException(e);
    }
  }

  @FunctionalInterface
  private interface RunnableWithSql {
    void run() throws Exception;
  }

  /** The one temporary password returned for a newly created teacher. */
  private static String temporaryPassword(JsonObject result, String id) {
    for (JsonElement element : result.getAsJsonArray("temporaryPasswords")) {
      JsonObject entry = element.getAsJsonObject();
      if (entry.get("id").getAsString().equals(id)) return entry.get("password").getAsString();
    }
    throw new AssertionError("No temporary password for " + id);
  }

  private static JsonObject byId(String id) {
    JsonObject result = new JsonObject();
    result.addProperty("id", id);
    return result;
  }

  private static JsonObject request(String supplyId, int quantity) {
    JsonObject result = new JsonObject();
    result.addProperty("supplyId", supplyId);
    result.addProperty("quantity", String.valueOf(quantity));
    return result;
  }

  /**
   * The only pending request in a visible state. A command's result lists requests in stored
   * order with new ones appended, so the first entry is not necessarily the newest.
   */
  private static String newestRequest(JsonObject state) {
    String found = null;
    for (JsonElement element : state.getAsJsonArray("requests")) {
      JsonObject request = element.getAsJsonObject();
      if (!request.get("status").getAsString().equals("Pending")) continue;
      if (found != null) throw new AssertionError("Expected one pending request");
      found = request.get("id").getAsString();
    }
    if (found == null) throw new AssertionError("Expected a pending request");
    return found;
  }

  private static JsonObject supply(JsonObject state, String name) {
    for (JsonElement element : state.getAsJsonArray("supplies"))
      if (element.getAsJsonObject().get("name").getAsString().equals(name))
        return element.getAsJsonObject();
    throw new AssertionError("No supply " + name);
  }

  private static String status(JsonObject state, String requestId) {
    for (JsonElement element : state.getAsJsonArray("requests"))
      if (element.getAsJsonObject().get("id").getAsString().equals(requestId))
        return element.getAsJsonObject().get("status").getAsString();
    throw new AssertionError("No request " + requestId);
  }

  public static void main(String[] args) throws Exception {
    Path temp = Files.createTempDirectory("officeflow-test");
    String url = "jdbc:h2:" + temp.resolve("workspace").toAbsolutePath();

    // A new workspace needs an explicit administrator password that meets the policy.
    denied(() -> new Store("jdbc:h2:" + temp.resolve("weak").toAbsolutePath(), "001"));
    denied(() -> new Store("jdbc:h2:" + temp.resolve("missing").toAbsolutePath(), null));

    String rejectedId, cancelledId, issuedId;
    try (Store store = new Store(url, ADMIN_PASSWORD)) {
      Service service = new Service(store);
      Accounts.Account admin = service.login("001", ADMIN_PASSWORD);
      check(!service.passwordChangeRequired("001"));
      denied(() -> service.login("001", "wrong"));

      // New teachers get a random temporary password, never their ID.
      JsonObject created =
          service.execute(
              admin,
              "saveTeacher",
              data("{\"id\":\"T1\",\"name\":\"Alex\",\"department\":\"CS\",\"email\":\"\"}"));
      String t1Temporary = temporaryPassword(created, "T1");
      Accounts.validatePassword(t1Temporary);
      created =
          service.execute(
              admin,
              "saveTeacher",
              data("{\"id\":\"T2\",\"name\":\"Sam\",\"department\":\"CS\",\"email\":\"\"}"));
      String t2Temporary = temporaryPassword(created, "T2");
      check(!t1Temporary.equals(t2Temporary));
      denied(() -> service.login("T1", "T1"));
      check(!Accounts.matches("T1".toCharArray(), store.credential("T1")[1]));
      Accounts.Account teacher = service.login("T1", t1Temporary);
      Accounts.Account other = service.login("T2", t2Temporary);
      check(service.passwordChangeRequired("T1") && service.passwordChangeRequired("T2"));
      // Editing a teacher does not issue a new password.
      JsonObject edited =
          service.execute(
              admin,
              "saveTeacher",
              data(
                  "{\"id\":\"T2\",\"name\":\"Sam Lee\",\"department\":\"CS\",\"email\":\"\","
                      + "\"edit\":\"true\"}"));
      check(!edited.has("temporaryPasswords"));
      service.login("T2", t2Temporary);

      denied(() -> service.changePassword(teacher, "wrong", "new-teacher-password"));
      denied(() -> service.changePassword(teacher, t1Temporary, "short"));
      denied(() -> service.resetPassword(teacher, "T2", "new-teacher-password"));
      service.changePassword(teacher, t1Temporary, "new-teacher-password");
      check(!service.passwordChangeRequired("T1"));
      service.login("T1", "new-teacher-password");

      JsonObject state =
          service.execute(
              admin,
              "saveSupply",
              data(
                  "{\"name\":\"Paper\",\"category\":\"Paper &"
                      + " print\",\"quantity\":10,\"threshold\":2,\"unit\":\"reams\"}"));
      try (var connection = java.sql.DriverManager.getConnection(url, "sa", "");
          var statement = connection.createStatement()) {
        for (String table : new String[] {"teachers", "supplies", "requisitions", "credentials"})
          statement.execute(
              "CREATE TRIGGER count_"
                  + table
                  + " AFTER INSERT, UPDATE, DELETE ON "
                  + table
                  + " FOR EACH ROW CALL 'com.officeflow.ServiceTest$WriteCounter'");
        WriteCounter.writes = 0;
        JsonObject changed = supply(state, "Paper").deepCopy();
        changed.addProperty("unit", "packs");
        state = service.execute(admin, "saveSupply", changed);
        check(WriteCounter.writes == 1); // No writes to untouched rows/tables.
        WriteCounter.writes = 0;
        service.execute(admin, "saveSupply", changed);
        check(WriteCounter.writes == 0); // Identical submissions do not rewrite a row.
        for (String table : new String[] {"teachers", "supplies", "requisitions", "credentials"})
          statement.execute("DROP TRIGGER count_" + table);
      }
      String paper = supply(state, "Paper").get("id").getAsString();
      state = service.execute(teacher, "request", request(paper, 7));
      issuedId = newestRequest(state);
      check(service.state(other).getAsJsonArray("requests").isEmpty());
      check(supply(service.state(other), "Paper").get("reservedByOthers").getAsInt() == 7);
      denied(() -> service.execute(other, "cancel", byId(issuedId)));
      denied(() -> service.execute(teacher, "issue", byId(issuedId)));
      denied(() -> service.execute(other, "request", request(paper, 4)));
      service.execute(admin, "issue", byId(issuedId));
      denied(() -> service.execute(admin, "issue", byId(issuedId)));
      check(supply(service.state(admin), "Paper").get("quantity").getAsInt() == 3);

      // Rejection and cancellation release reserved stock without deducting it.
      state =
          service.execute(
              admin,
              "saveSupply",
              data(
                  "{\"name\":\"Folders\",\"category\":\"Stationery\",\"quantity\":5,"
                      + "\"threshold\":1,\"unit\":\"packs\"}"));
      String folders = supply(state, "Folders").get("id").getAsString();
      rejectedId = newestRequest(service.execute(teacher, "request", request(folders, 5)));
      denied(() -> service.execute(other, "request", request(folders, 1)));
      JsonObject folderEdit = supply(service.state(admin), "Folders").deepCopy();
      folderEdit.addProperty("quantity", "4");
      denied(() -> service.execute(admin, "saveSupply", folderEdit)); // Below the reservation.
      service.execute(admin, "reject", byId(rejectedId));
      check(supply(service.state(other), "Folders").get("reservedByOthers").getAsInt() == 0);
      cancelledId = newestRequest(service.execute(other, "request", request(folders, 5)));
      denied(() -> service.execute(teacher, "request", request(folders, 1)));
      denied(() -> service.execute(admin, "cancel", byId(cancelledId)));
      service.execute(other, "cancel", byId(cancelledId));
      denied(() -> service.execute(other, "cancel", byId(cancelledId)));
      String last = newestRequest(service.execute(teacher, "request", request(folders, 5)));
      service.execute(teacher, "cancel", byId(last));
      check(supply(service.state(admin), "Folders").get("quantity").getAsInt() == 5);

      denied(
          () ->
              service.importRows(
                  admin, "teachers", "id,name,department,email\nT3,New,CS,\nT1,Duplicate,CS,"));
      check(service.state(admin).getAsJsonArray("teachers").size() == 2);
      denied(() -> service.login("T3", "T3"));
      JsonObject imported =
          service.importRows(admin, "teachers", "id,name,department,email\nT3,New,CS,");
      service.login("T3", temporaryPassword(imported, "T3"));
      check(service.passwordChangeRequired("T3"));
      check(!service.state(admin).has("temporaryPasswords")); // Shown once, never stored.
      check(Csv.parse("a,b\n\"x,y\",\"line\nnext\"").get(1).get(1).equals("line\nnext"));

      // An administrator's reset is temporary again.
      service.resetPassword(admin, "T1", "admin-reset-password");
      check(service.passwordChangeRequired("T1"));
      service.login("T1", "admin-reset-password");

      JsonObject before = store.read(), broken = before.deepCopy();
      broken.getAsJsonArray("supplies").get(0).getAsJsonObject().addProperty("quantity", -1);
      try {
        store.write(before, broken);
        throw new AssertionError("Invalid database write accepted");
      } catch (java.sql.SQLException expected) {
        check(store.read().equals(before));
      }
      denied(() -> store.write(before, data("{\"teachers\":[{\"id\":\"T9\",\"name\":\"X\","
          + "\"department\":\"Y\",\"email\":\"\"}],\"supplies\":[],\"requests\":[]}")));
      check(store.read().equals(before)); // A new teacher without a password is never stored.
    }

    // Restart: no administrator password is needed, and nothing is reset.
    try (Store reopened = new Store(url, null)) {
      Service service = new Service(reopened);
      Accounts.Account admin = service.login("001", ADMIN_PASSWORD);
      denied(() -> service.login("001", "different-admin-password"));
      // Temporary passwords stay temporary across a restart until their owners change them.
      check(service.passwordChangeRequired("T1") && service.passwordChangeRequired("T2"));
      check(service.passwordChangeRequired("T3"));
      service.login("T1", "admin-reset-password");
      JsonObject state = service.state(admin);
      check(status(state, issuedId).equals("Issued"));
      check(status(state, rejectedId).equals("Rejected"));
      check(status(state, cancelledId).equals("Cancelled"));
      check(supply(state, "Paper").get("quantity").getAsInt() == 3);
      check(supply(state, "Folders").get("quantity").getAsInt() == 5);
    }

    // A workspace created before temporary passwords existed reopens with its accounts intact.
    String legacy = "jdbc:h2:" + temp.resolve("legacy").toAbsolutePath();
    try (var connection = java.sql.DriverManager.getConnection(legacy, "sa", "");
        var statement = connection.createStatement()) {
      statement.execute(
          "CREATE TABLE credentials (id VARCHAR(30) PRIMARY KEY, role VARCHAR(10) NOT NULL,"
              + " password_hash VARCHAR(200) NOT NULL)");
      statement.execute(
          "CREATE TABLE teachers (id VARCHAR(30) PRIMARY KEY, name VARCHAR(120) NOT NULL,"
              + " department VARCHAR(120) NOT NULL, email VARCHAR(120) NOT NULL)");
      statement.execute("INSERT INTO teachers VALUES ('T1', 'Alex', 'CS', '')");
      try (var insert = connection.prepareStatement("INSERT INTO credentials VALUES (?, ?, ?)")) {
        for (String[] row : new String[][] {{"001", "admin", "001"}, {"T1", "teacher", "T1"}}) {
          insert.setString(1, row[0]);
          insert.setString(2, row[1]);
          insert.setString(3, Accounts.hash(row[2].toCharArray()));
          insert.executeUpdate();
        }
      }
    }
    try (Store reopened = new Store(legacy, null)) {
      Service service = new Service(reopened);
      service.login("001", "001");
      service.login("T1", "T1");
      check(!service.passwordChangeRequired("T1")); // Old accounts are not locked out.
      check(service.state(service.login("001", "001")).getAsJsonArray("teachers").size() == 1);
    }

    checkStartup(temp);

    try (var paths = Files.walk(temp)) {
      for (Path p : paths.sorted(java.util.Comparator.reverseOrder()).toList()) Files.delete(p);
    }
    System.out.println(
        "Java JDBC service checks passed: admin password policy, temporary passwords, roles,"
            + " reservations released by reject/cancel, issue-once, CSV rollback, restart and"
            + " legacy workspaces, startup path checks.");
  }

  /** Path decisions made before H2 is opened. */
  private static void checkStartup(Path temp) throws Exception {
    denied(() -> Startup.rejectSeedFlag("true"));
    Startup.rejectSeedFlag(null);

    Path work = Files.createDirectories(temp.resolve("work"));
    Path local = temp.resolve("local");
    Startup windows = new Startup(Map.of("LOCALAPPDATA", local.toString()), work, null);
    String url = windows.defaultDatabase();
    check(url.equals("jdbc:h2:" + local.resolve("OfficeFlow/officeflow").toString()
        .replace('\\', '/')));
    check(windows.databaseFile(url).equals(local.resolve("OfficeFlow/officeflow.mv.db")));
    check(windows.databaseFile("jdbc:h2:mem:test") == null);
    check(windows.databaseFile("jdbc:h2:tcp://localhost/x") == null);
    check(windows.databaseFile("jdbc:h2:./data/officeflow;MODE=MySQL")
        .equals(work.resolve("data/officeflow.mv.db")));
    check(windows.database(null).equals(url)); // Nothing old to warn about.
    check(windows.database("jdbc:h2:mem:explicit").equals("jdbc:h2:mem:explicit"));

    // An old ./data workspace stops a blank default from being created, with instructions.
    Files.createDirectories(work.resolve("data"));
    Files.writeString(work.resolve("data/officeflow.mv.db"), "");
    try {
      windows.database(null);
      throw new AssertionError("Expected a legacy-database message");
    } catch (Startup.Problem problem) {
      check(problem.getMessage().contains("-Dofficeflow.db=jdbc:h2:"));
      check(problem.getMessage().contains("Move-Item"));
    }
    check(!Files.exists(local.resolve("OfficeFlow")));
    check(windows.database(url).equals(url)); // An explicit choice is respected.

    denied(() -> windows.site(null));
    try {
      windows.requireAdminPasswordForNewWorkspace(url);
      throw new AssertionError("Expected an admin-password message");
    } catch (Startup.Problem problem) {
      check(problem.getMessage().contains("OFFICEFLOW_ADMIN_PASSWORD"));
    }
    new Startup(Map.of("OFFICEFLOW_ADMIN_PASSWORD", ADMIN_PASSWORD), work, null)
        .requireAdminPasswordForNewWorkspace(url);
  }
}
