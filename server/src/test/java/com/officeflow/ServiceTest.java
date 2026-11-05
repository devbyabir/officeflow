package com.officeflow;

import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import java.nio.file.Files;
import java.nio.file.Path;

/** Dependency-free integration test, invoked by scripts/test-server.py. */
public final class ServiceTest {
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
    } catch (IllegalArgumentException | SecurityException expected) {
    } catch (Exception e) {
      throw new RuntimeException(e);
    }
  }

  @FunctionalInterface
  private interface RunnableWithSql {
    void run() throws Exception;
  }

  public static void main(String[] args) throws Exception {
    Path temp = Files.createTempDirectory("officeflow-test");
    String url = "jdbc:h2:" + temp.resolve("workspace").toAbsolutePath();
    try (Store store = new Store(url, "test-admin")) {
      Service service = new Service(store);
      Accounts.Account admin = service.login("001", "test-admin");
      denied(() -> service.login("001", "wrong"));
      service.execute(
          admin,
          "saveTeacher",
          data("{\"id\":\"T1\",\"name\":\"Alex\",\"department\":\"CS\",\"email\":\"\"}"));
      service.execute(
          admin,
          "saveTeacher",
          data("{\"id\":\"T2\",\"name\":\"Sam\",\"department\":\"CS\",\"email\":\"\"}"));
      Accounts.Account teacher = service.login("T1", "T1"), other = service.login("T2", "T2");
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
        JsonObject edited = state.getAsJsonArray("supplies").get(0).getAsJsonObject().deepCopy();
        edited.addProperty("unit", "packs");
        state = service.execute(admin, "saveSupply", edited);
        check(WriteCounter.writes == 1); // No writes to untouched rows/tables.
        WriteCounter.writes = 0;
        service.execute(admin, "saveSupply", edited);
        check(WriteCounter.writes == 0); // Identical submissions do not rewrite a row.
      }
      String item =
          state.getAsJsonArray("supplies").get(0).getAsJsonObject().get("id").getAsString();
      JsonObject request = data("{\"quantity\":7}");
      request.addProperty("supplyId", item);
      state = service.execute(teacher, "request", request);
      String requestId =
          state.getAsJsonArray("requests").get(0).getAsJsonObject().get("id").getAsString();
      JsonObject byId = new JsonObject();
      byId.addProperty("id", requestId);
      check(service.state(other).getAsJsonArray("requests").isEmpty());
      check(
          service
                  .state(other)
                  .getAsJsonArray("supplies")
                  .get(0)
                  .getAsJsonObject()
                  .get("reservedByOthers")
                  .getAsInt()
              == 7);
      denied(() -> service.execute(other, "cancel", byId));
      denied(() -> service.execute(teacher, "issue", byId));
      denied(() -> service.execute(other, "request", request));
      service.execute(admin, "issue", byId);
      denied(() -> service.execute(admin, "issue", byId));
      check(
          service
                  .state(admin)
                  .getAsJsonArray("supplies")
                  .get(0)
                  .getAsJsonObject()
                  .get("quantity")
                  .getAsInt()
              == 3);
      denied(
          () ->
              service.importRows(
                  admin, "teachers", "id,name,department,email\nT3,New,CS,\nT1,Duplicate,CS,"));
      check(service.state(admin).getAsJsonArray("teachers").size() == 2);
      check(Csv.parse("a,b\n\"x,y\",\"line\nnext\"").get(1).get(1).equals("line\nnext"));
      check(Accounts.matches("T1".toCharArray(), store.credential("T1")[1]));
      check(!Accounts.matches("wrong".toCharArray(), store.credential("T1")[1]));
      denied(() -> service.changePassword(teacher, "wrong", "new-teacher-password"));
      denied(() -> service.changePassword(teacher, "T1", "short"));
      denied(() -> service.resetPassword(teacher, "T2", "new-teacher-password"));
      service.changePassword(teacher, "T1", "new-teacher-password");
      service.login("T1", "new-teacher-password");
      JsonObject before = store.read(), broken = before.deepCopy();
      broken.getAsJsonArray("supplies").get(0).getAsJsonObject().addProperty("quantity", -1);
      try {
        store.write(before, broken);
        throw new AssertionError("Invalid database write accepted");
      } catch (java.sql.SQLException expected) {
        check(store.read().equals(before));
      }
    }
    try (Store reopened = new Store(url, "different")) {
      Service service = new Service(reopened);
      Accounts.Account admin = service.login("001", "test-admin");
      service.login("T1", "new-teacher-password");
      check(
          service
              .state(admin)
              .getAsJsonArray("requests")
              .get(0)
              .getAsJsonObject()
              .get("status")
              .getAsString()
              .equals("Issued"));
    }
    try (var paths = Files.walk(temp)) {
      for (Path p : paths.sorted(java.util.Comparator.reverseOrder()).toList()) Files.delete(p);
    }
    System.out.println(
        "Java JDBC service checks passed: authentication, roles, reservations, issue-once, CSV"
            + " rollback and restart persistence.");
  }
}
