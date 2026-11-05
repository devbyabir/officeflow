package com.officeflow;

import com.google.gson.JsonArray;
import com.google.gson.JsonObject;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.HashMap;
import java.util.Map;
import java.util.Set;

/** A single-workspace JDBC repository. Service serializes write transactions. */
public final class Store implements AutoCloseable {
  private final Connection connection;

  public Store(String url, String adminPassword) throws SQLException {
    connection = DriverManager.getConnection(url, "sa", "");
    try (Statement statement = connection.createStatement()) {
      statement.execute(
          "CREATE TABLE IF NOT EXISTS teachers (id VARCHAR(30) PRIMARY KEY, name VARCHAR(120) NOT"
              + " NULL, department VARCHAR(120) NOT NULL, email VARCHAR(120) NOT NULL)");
      statement.execute(
          "CREATE TABLE IF NOT EXISTS supplies (id VARCHAR(60) PRIMARY KEY, name VARCHAR(120) NOT"
              + " NULL, category VARCHAR(120) NOT NULL, quantity INT CHECK(quantity >= 0),"
              + " threshold INT CHECK(threshold >= 0), unit VARCHAR(120) NOT NULL)");
      statement.execute(
          "CREATE TABLE IF NOT EXISTS requisitions (id VARCHAR(60) PRIMARY KEY, teacher_id"
              + " VARCHAR(30) NOT NULL, teacher_name VARCHAR(120) NOT NULL, supply_id VARCHAR(60)"
              + " NOT NULL, supply_name VARCHAR(120) NOT NULL, quantity INT CHECK(quantity > 0),"
              + " status VARCHAR(20) NOT NULL, note VARCHAR(240) NOT NULL, created_at VARCHAR(40)"
              + " NOT NULL, updated_at VARCHAR(40))");
      statement.execute(
          "CREATE TABLE IF NOT EXISTS credentials (id VARCHAR(30) PRIMARY KEY, role VARCHAR(10) NOT"
              + " NULL, password_hash VARCHAR(200) NOT NULL)");
    }
    if (credential("001") == null) addCredential("001", "admin", adminPassword);
  }

  private void addCredential(String id, String role, String password) throws SQLException {
    try (PreparedStatement statement =
        connection.prepareStatement("INSERT INTO credentials VALUES (?, ?, ?)")) {
      statement.setString(1, id);
      statement.setString(2, role);
      statement.setString(3, Accounts.hash(password.toCharArray()));
      statement.executeUpdate();
    }
  }

  public String[] credential(String id) throws SQLException {
    try (PreparedStatement statement =
        connection.prepareStatement("SELECT role, password_hash FROM credentials WHERE id = ?")) {
      statement.setString(1, id);
      try (ResultSet result = statement.executeQuery()) {
        return result.next() ? new String[] {result.getString(1), result.getString(2)} : null;
      }
    }
  }

  public JsonObject read() throws SQLException {
    JsonObject state = new JsonObject();
    state.add(
        "teachers",
        rows(
            "SELECT * FROM teachers ORDER BY id",
            new String[] {"id", "name", "department", "email"},
            Set.of()));
    state.add(
        "supplies",
        rows(
            "SELECT * FROM supplies ORDER BY id",
            new String[] {"id", "name", "category", "quantity", "threshold", "unit"},
            Set.of("quantity", "threshold")));
    JsonArray requests = new JsonArray();
    try (Statement statement = connection.createStatement();
        ResultSet results =
            statement.executeQuery("SELECT * FROM requisitions ORDER BY created_at DESC, id")) {
      while (results.next()) {
        JsonObject r = new JsonObject();
        String[][] fields = {
          {"id", "id"},
          {"teacher_id", "teacherId"},
          {"teacher_name", "teacherName"},
          {"supply_id", "supplyId"},
          {"supply_name", "supplyName"},
          {"status", "status"},
          {"note", "note"},
          {"created_at", "createdAt"},
          {"updated_at", "updatedAt"}
        };
        for (String[] field : fields)
          if (results.getString(field[0]) != null)
            r.addProperty(field[1], results.getString(field[0]));
        r.addProperty("quantity", results.getInt("quantity"));
        requests.add(r);
      }
    }
    state.add("requests", requests);
    return state;
  }

  private JsonArray rows(String sql, String[] fields, Set<String> numbers) throws SQLException {
    JsonArray rows = new JsonArray();
    try (Statement statement = connection.createStatement();
        ResultSet results = statement.executeQuery(sql)) {
      while (results.next()) {
        JsonObject row = new JsonObject();
        for (String field : fields) {
          if (numbers.contains(field)) row.addProperty(field, results.getInt(field));
          else row.addProperty(field, results.getString(field));
        }
        rows.add(row);
      }
    }
    return rows;
  }

  public void updatePassword(String id, String password) throws SQLException {
    try (PreparedStatement statement =
        connection.prepareStatement("UPDATE credentials SET password_hash = ? WHERE id = ?")) {
      statement.setString(1, Accounts.hash(password.toCharArray()));
      statement.setString(2, id);
      if (statement.executeUpdate() != 1)
        throw new IllegalArgumentException("Account no longer exists.");
    }
  }

  /** Used for initial seeding; normal commands already have the original snapshot. */
  public void write(JsonObject state) throws SQLException {
    write(read(), state);
  }

  /** Persist only changed rows, preserving atomic imports and existing password hashes. */
  public void write(JsonObject before, JsonObject state) throws SQLException {
    connection.setAutoCommit(false);
    try {
      Map<String, JsonObject> oldTeachers = byId(before.getAsJsonArray("teachers"));
      Map<String, JsonObject> newTeachers = byId(state.getAsJsonArray("teachers"));
      for (String id : newTeachers.keySet())
        if (!oldTeachers.containsKey(id)) addCredential(id, "teacher", id);
      try (PreparedStatement statement =
          connection.prepareStatement(
              "DELETE FROM credentials WHERE id = ? AND role = 'teacher'")) {
        for (String id : oldTeachers.keySet())
          if (!newTeachers.containsKey(id)) {
            statement.setString(1, id);
            statement.addBatch();
          }
        statement.executeBatch();
      }
      sync(
          before.getAsJsonArray("teachers"),
          state.getAsJsonArray("teachers"),
          "teachers",
          new String[] {"id", "name", "department", "email"},
          new String[] {"id", "name", "department", "email"});
      sync(
          before.getAsJsonArray("supplies"),
          state.getAsJsonArray("supplies"),
          "supplies",
          new String[] {"id", "name", "category", "quantity", "threshold", "unit"},
          new String[] {"id", "name", "category", "quantity", "threshold", "unit"});
      sync(
          before.getAsJsonArray("requests"),
          state.getAsJsonArray("requests"),
          "requisitions",
          new String[] {
            "id",
            "teacher_id",
            "teacher_name",
            "supply_id",
            "supply_name",
            "quantity",
            "status",
            "note",
            "created_at",
            "updated_at"
          },
          new String[] {
            "id",
            "teacherId",
            "teacherName",
            "supplyId",
            "supplyName",
            "quantity",
            "status",
            "note",
            "createdAt",
            "updatedAt"
          });
      connection.commit();
    } catch (SQLException | RuntimeException exception) {
      connection.rollback();
      throw exception;
    } finally {
      connection.setAutoCommit(true);
    }
  }

  private static Map<String, JsonObject> byId(JsonArray rows) {
    Map<String, JsonObject> result = new HashMap<>();
    for (var element : rows) {
      JsonObject row = element.getAsJsonObject();
      result.put(row.get("id").getAsString(), row);
    }
    return result;
  }

  private void sync(
      JsonArray before, JsonArray after, String table, String[] columns, String[] fields)
      throws SQLException {
    Map<String, JsonObject> previous = byId(before), current = byId(after);
    try (PreparedStatement delete =
        connection.prepareStatement("DELETE FROM " + table + " WHERE id = ?")) {
      for (String id : previous.keySet())
        if (!current.containsKey(id)) {
          delete.setString(1, id);
          delete.addBatch();
        }
      delete.executeBatch();
    }
    String placeholders = String.join(",", java.util.Collections.nCopies(fields.length, "?"));
    try (PreparedStatement statement =
        connection.prepareStatement(
            "MERGE INTO "
                + table
                + " ("
                + String.join(",", columns)
                + ") KEY(id) VALUES ("
                + placeholders
                + ")")) {
      for (var entry : current.entrySet()) {
        JsonObject row = entry.getValue();
        if (row.equals(previous.get(entry.getKey()))) continue;
        for (int i = 0; i < fields.length; i++)
          statement.setString(
              i + 1,
              row.has(fields[i]) && !row.get(fields[i]).isJsonNull()
                  ? row.get(fields[i]).getAsString()
                  : null);
        statement.addBatch();
      }
      statement.executeBatch();
    }
  }

  @Override
  public void close() throws SQLException {
    connection.close();
  }
}
