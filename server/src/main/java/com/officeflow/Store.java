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

  /**
   * Opens or creates a workspace. {@code adminPassword} is used only when the workspace has no
   * administrator yet; it must then meet the password policy. Existing workspaces ignore it.
   */
  public Store(String url, String adminPassword) throws SQLException {
    this(url, adminPassword, false);
  }

  /**
   * With {@code allowSetup}, a workspace without an administrator opens without one when no
   * valid {@code adminPassword} is given; the first administrator is then created once through
   * {@link #createFirstAdministrator}, from the browser's setup screen.
   */
  public Store(String url, String adminPassword, boolean allowSetup) throws SQLException {
    connection = DriverManager.getConnection(url, "sa", "");
    try {
      boolean create = false;
      if (!hasAdministrator()) {
        try {
          Accounts.validatePassword(adminPassword == null ? "" : adminPassword);
          create = true;
        } catch (IllegalArgumentException exception) {
          if (!allowSetup)
            throw new IllegalStateException(
                "A new workspace needs an administrator password of 6-12 characters in"
                    + " OFFICEFLOW_ADMIN_PASSWORD.");
        }
      }
      createSchema();
      if (create && credential("001") == null) addCredential("001", "admin", adminPassword, false);
    } catch (SQLException | RuntimeException exception) {
      connection.close();
      throw exception;
    }
  }

  /**
   * Creates administrator 001 once. Fails if any administrator already exists, so a setup
   * request can never replace an existing account or its password.
   */
  public void createFirstAdministrator(String username, String password, String hint, String code)
      throws SQLException {
    String name = Accounts.normalizeUsername(username);
    Accounts.validatePassword(password == null ? "" : password);
    String reminder = Accounts.validateHint(hint, name, password);
    connection.setAutoCommit(false);
    try {
      if (hasAdministrator()) throw new IllegalStateException("OfficeFlow is already set up.");
      addCredential("001", "admin", password, false);
      setUsername("001", name);
      setRecovery("001", reminder, code);
      connection.commit();
    } catch (SQLException | RuntimeException exception) {
      connection.rollback();
      throw exception;
    } finally {
      connection.setAutoCommit(true);
    }
  }

  /** True once administrator 001 exists. */
  public boolean hasAdministrator() throws SQLException {
    try (Statement statement = connection.createStatement();
        ResultSet tables =
            statement.executeQuery(
                "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = 'PUBLIC'"
                    + " AND TABLE_NAME = 'CREDENTIALS'")) {
      tables.next();
      if (tables.getInt(1) == 0) return false;
    }
    try (PreparedStatement statement =
        connection.prepareStatement("SELECT 1 FROM credentials WHERE id = '001'")) {
      try (ResultSet result = statement.executeQuery()) {
        return result.next();
      }
    }
  }

  private void createSchema() throws SQLException {
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
      // Older workspaces gain the column with FALSE, so existing accounts keep working as before.
      statement.execute(
          "ALTER TABLE credentials ADD COLUMN IF NOT EXISTS must_change BOOLEAN DEFAULT FALSE"
              + " NOT NULL");
      // Usernames arrived later: older accounts have none and keep signing in with their ID.
      statement.execute("ALTER TABLE credentials ADD COLUMN IF NOT EXISTS username VARCHAR(32)");
      statement.execute("ALTER TABLE credentials ADD COLUMN IF NOT EXISTS hint VARCHAR(120)");
      statement.execute(
          "ALTER TABLE credentials ADD COLUMN IF NOT EXISTS recovery_hash VARCHAR(200)");
      statement.execute(
          "CREATE UNIQUE INDEX IF NOT EXISTS credentials_username ON credentials(username)");
    }
  }

  /**
   * The account ID for a sign-in name: a username (any case) or, for accounts created before
   * usernames and as a fallback, the account ID itself. Null when neither matches.
   */
  public String accountFor(String name) throws SQLException {
    if (name == null || name.isBlank()) return null;
    try (PreparedStatement statement =
        connection.prepareStatement("SELECT id FROM credentials WHERE username = ?")) {
      statement.setString(1, name.trim().toLowerCase(java.util.Locale.ROOT));
      try (ResultSet result = statement.executeQuery()) {
        if (result.next()) return result.getString(1);
      }
    }
    return credential(name.trim()) != null ? name.trim() : null;
  }

  /** The account's username, or null if it has not chosen one. */
  public String username(String id) throws SQLException {
    try (PreparedStatement statement =
        connection.prepareStatement("SELECT username FROM credentials WHERE id = ?")) {
      statement.setString(1, id);
      try (ResultSet result = statement.executeQuery()) {
        return result.next() ? result.getString(1) : null;
      }
    }
  }

  /**
   * True if {@code name} is already a username or an account ID (ignoring case) of an account
   * other than {@code except}. Usernames and IDs never overlap, so a sign-in name is unambiguous.
   */
  public boolean nameTaken(String name, String except) throws SQLException {
    try (PreparedStatement statement =
        connection.prepareStatement(
            "SELECT COUNT(*) FROM credentials WHERE (LOWER(id) = ? OR username = ?) AND id <> ?")) {
      String value = name.toLowerCase(java.util.Locale.ROOT);
      statement.setString(1, value);
      statement.setString(2, value);
      statement.setString(3, except == null ? "" : except);
      try (ResultSet result = statement.executeQuery()) {
        result.next();
        return result.getInt(1) > 0;
      }
    }
  }

  /** Sets a unique username for the account; see {@link Accounts#normalizeUsername}. */
  public void setUsername(String id, String username) throws SQLException {
    String name = Accounts.normalizeUsername(username);
    if (nameTaken(name, id))
      throw new IllegalArgumentException("That username is taken. Choose another one.");
    String reminder = hint(id);
    if (reminder != null) Accounts.validateHint(reminder, name, "");
    try (PreparedStatement statement =
        connection.prepareStatement("UPDATE credentials SET username = ? WHERE id = ?")) {
      statement.setString(1, name);
      statement.setString(2, id);
      if (statement.executeUpdate() != 1)
        throw new IllegalArgumentException("Account no longer exists.");
    }
  }

  public String hint(String id) throws SQLException {
    try (PreparedStatement statement =
        connection.prepareStatement("SELECT hint FROM credentials WHERE id = ?")) {
      statement.setString(1, id);
      try (ResultSet result = statement.executeQuery()) {
        return result.next() ? result.getString(1) : null;
      }
    }
  }

  public String recoveryHash(String id) throws SQLException {
    try (PreparedStatement statement =
        connection.prepareStatement("SELECT recovery_hash FROM credentials WHERE id = ?")) {
      statement.setString(1, id);
      try (ResultSet result = statement.executeQuery()) {
        return result.next() ? result.getString(1) : null;
      }
    }
  }

  public void setRecovery(String id, String hint, String code) throws SQLException {
    try (PreparedStatement statement =
        connection.prepareStatement(
            "UPDATE credentials SET hint = ?, recovery_hash = ? WHERE id = ?")) {
      statement.setString(1, hint);
      statement.setString(2, Accounts.hash(code.toCharArray()));
      statement.setString(3, id);
      if (statement.executeUpdate() != 1)
        throw new IllegalArgumentException("Account no longer exists.");
    }
  }

  private void addCredential(String id, String role, String password, boolean mustChange)
      throws SQLException {
    try (PreparedStatement statement =
        connection.prepareStatement(
            "INSERT INTO credentials (id, role, password_hash, must_change) VALUES (?, ?, ?, ?)")) {
      statement.setString(1, id);
      statement.setString(2, role);
      statement.setString(3, Accounts.hash(password.toCharArray()));
      statement.setBoolean(4, mustChange);
      statement.executeUpdate();
    }
  }

  /** Returns {role, password hash, "true"/"false" for a required password change}, or null. */
  public String[] credential(String id) throws SQLException {
    try (PreparedStatement statement =
        connection.prepareStatement(
            "SELECT role, password_hash, must_change FROM credentials WHERE id = ?")) {
      statement.setString(1, id);
      try (ResultSet result = statement.executeQuery()) {
        return result.next()
            ? new String[] {
              result.getString(1), result.getString(2), String.valueOf(result.getBoolean(3))
            }
            : null;
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

  /**
   * Stores a new password. {@code mustChange} marks a temporary password that its owner must
   * replace before using the workspace.
   */
  public void updatePassword(String id, String password, boolean mustChange, String hint, String code)
      throws SQLException {
    try (PreparedStatement statement =
        connection.prepareStatement(
            "UPDATE credentials SET password_hash = ?, must_change = ?, hint = ?, recovery_hash = ?"
                + " WHERE id = ?")) {
      statement.setString(1, Accounts.hash(password.toCharArray()));
      statement.setBoolean(2, mustChange);
      statement.setString(3, hint);
      statement.setString(4, code == null ? null : Accounts.hash(code.toCharArray()));
      statement.setString(5, id);
      if (statement.executeUpdate() != 1)
        throw new IllegalArgumentException("Account no longer exists.");
    }
  }

  /** Persists only changed rows, preserving atomic imports and existing password hashes. */
  public void write(JsonObject before, JsonObject state) throws SQLException {
    write(before, state, Map.of());
  }

  /**
   * Persists only changed rows. Each newly added teacher needs a temporary password in {@code
   * temporaryPasswords}; it is stored as one that must be changed at first sign-in.
   */
  public void write(JsonObject before, JsonObject state, Map<String, String> temporaryPasswords)
      throws SQLException {
    connection.setAutoCommit(false);
    try {
      Map<String, JsonObject> oldTeachers = byId(before.getAsJsonArray("teachers"));
      Map<String, JsonObject> newTeachers = byId(state.getAsJsonArray("teachers"));
      for (String id : newTeachers.keySet())
        if (!oldTeachers.containsKey(id)) {
          String password = temporaryPasswords.get(id);
          if (password == null)
            throw new IllegalStateException("A new teacher needs a temporary password.");
          addCredential(id, "teacher", password, true);
        }
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
