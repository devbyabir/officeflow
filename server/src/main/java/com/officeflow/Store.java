package com.officeflow;

import com.google.gson.JsonArray;
import com.google.gson.JsonObject;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.HashSet;
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

  /** Replace a validated snapshot atomically; suited to a small course workspace. */
  public void write(JsonObject state) throws SQLException {
    connection.setAutoCommit(false);
    try {
      Set<String> teacherIds = new HashSet<>();
      for (var element : state.getAsJsonArray("teachers"))
        teacherIds.add(element.getAsJsonObject().get("id").getAsString());
      Set<String> existing = new HashSet<>();
      try (Statement s = connection.createStatement();
          ResultSet r = s.executeQuery("SELECT id FROM credentials WHERE role = 'teacher'")) {
        while (r.next()) existing.add(r.getString(1));
      }
      for (String id : teacherIds) if (!existing.contains(id)) addCredential(id, "teacher", id);
      for (String id : existing)
        if (!teacherIds.contains(id)) {
          try (PreparedStatement s =
              connection.prepareStatement(
                  "DELETE FROM credentials WHERE id = ? AND role = 'teacher'")) {
            s.setString(1, id);
            s.executeUpdate();
          }
        }
      try (Statement s = connection.createStatement()) {
        s.executeUpdate("DELETE FROM requisitions");
        s.executeUpdate("DELETE FROM supplies");
        s.executeUpdate("DELETE FROM teachers");
      }
      insert(
          state.getAsJsonArray("teachers"),
          "INSERT INTO teachers VALUES (?, ?, ?, ?)",
          new String[] {"id", "name", "department", "email"});
      insert(
          state.getAsJsonArray("supplies"),
          "INSERT INTO supplies VALUES (?, ?, ?, ?, ?, ?)",
          new String[] {"id", "name", "category", "quantity", "threshold", "unit"});
      insert(
          state.getAsJsonArray("requests"),
          "INSERT INTO requisitions VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
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

  private void insert(JsonArray rows, String sql, String[] fields) throws SQLException {
    try (PreparedStatement statement = connection.prepareStatement(sql)) {
      for (var element : rows) {
        JsonObject row = element.getAsJsonObject();
        for (int i = 0; i < fields.length; i++)
          statement.setString(i + 1, row.has(fields[i]) ? row.get(fields[i]).getAsString() : null);
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
