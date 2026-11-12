package com.officeflow;

import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import java.sql.SQLException;
import java.time.Instant;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

public final class Service {
  private final Store store;
  public static final List<String> CATEGORIES =
      List.of("Stationery", "Technology", "Paper & print", "Desk essentials");

  public Service(Store store) {
    this.store = store;
  }

  /** Signs in with a username or, for older accounts such as admin 001, an account ID. */
  public synchronized Accounts.Account login(String name, String password) throws SQLException {
    String id = store.accountFor(name);
    String[] credential = id == null ? null : store.credential(id);
    if (credential == null || !Accounts.matches(password.toCharArray(), credential[1]))
      throw new SecurityException("Username or password is incorrect.");
    return credential[0].equals("admin")
        ? new Accounts.Administrator(id)
        : new Accounts.Teacher(id);
  }

  /** True until the first administrator has been created. */
  public synchronized boolean setupRequired() throws SQLException {
    return !store.hasAdministrator();
  }

  /** Creates administrator 001 once; refused when an administrator already exists. */
  public synchronized String createFirstAdministrator(String username, String password, String hint)
      throws SQLException {
    String code = Accounts.recoveryCode("001");
    store.createFirstAdministrator(username, password, hint, code);
    return code;
  }

  /** A reminder is only shown for an exact username or account ID, never as proof of ownership. */
  public synchronized String recoveryHint(String name) throws SQLException {
    if (name == null || name.length() > 40) return "";
    String id = store.accountFor(name);
    String hint = id == null ? null : store.hint(id);
    return hint == null ? "" : hint;
  }

  /** A one-time code can recover an account even when its username has been forgotten. */
  public synchronized String[] recover(String code, String next, String hint) throws SQLException {
    if (code == null || code.length() > 80 || !code.matches("[A-Za-z0-9_-]{1,30}\\.[A-Za-z0-9_-]{32}"))
      throw new SecurityException("Recovery code is incorrect.");
    String id = code.substring(0, code.indexOf('.'));
    String[] credential = store.credential(id);
    String stored = store.recoveryHash(id);
    if (credential == null || stored == null || !Accounts.matches(code.toCharArray(), stored))
      throw new SecurityException("Recovery code is incorrect.");
    Accounts.Account account =
        credential[0].equals("admin") ? new Accounts.Administrator(id) : new Accounts.Teacher(id);
    requireAccount(store.read(), account);
    Accounts.validatePassword(next);
    String reminder = Accounts.validateHint(hint, store.username(id), next);
    String replacement = Accounts.recoveryCode(id);
    store.updatePassword(id, next, false, reminder, replacement);
    return new String[] {store.username(id) == null ? id : store.username(id), replacement, id};
  }

  /** The account's username, or null for an older account that has not chosen one. */
  public synchronized String username(String id) throws SQLException {
    return store.username(id);
  }

  /** Lets a signed-in account choose or change its unique username. */
  public synchronized String setUsername(Accounts.Account account, String username)
      throws SQLException {
    requireAccount(store.read(), account);
    store.setUsername(account.id(), username);
    return store.username(account.id());
  }

  /** True while the account still has a temporary password that its owner must replace. */
  public synchronized boolean passwordChangeRequired(String id) throws SQLException {
    String[] credential = store.credential(id);
    return credential != null && Boolean.parseBoolean(credential[2]);
  }

  /** Gives each teacher added by this change a temporary password, returned once to the admin. */
  private static Map<String, String> temporaryPasswords(JsonObject before, JsonObject after) {
    Map<String, String> passwords = new java.util.LinkedHashMap<>();
    for (JsonElement element : after.getAsJsonArray("teachers")) {
      String id = string(element.getAsJsonObject(), "id");
      if (find(before.getAsJsonArray("teachers"), id) == null)
        passwords.put(id, Accounts.temporaryPassword());
    }
    return passwords;
  }

  /** A new teacher ID may not equal someone's username, so every sign-in name is unambiguous. */
  private void requireFreeIds(Map<String, String> newTeachers) throws SQLException {
    for (String id : newTeachers.keySet())
      if (store.nameTaken(id, null))
        throw new IllegalArgumentException("Teacher ID " + id + " is already used as a username.");
  }

  private static JsonObject withTemporaryPasswords(JsonObject state, Map<String, String> passwords) {
    if (passwords.isEmpty()) return state;
    JsonArray list = new JsonArray();
    passwords.forEach(
        (id, password) -> {
          JsonObject entry = new JsonObject();
          entry.addProperty("id", id);
          entry.addProperty("password", password);
          list.add(entry);
        });
    state.add("temporaryPasswords", list);
    return state;
  }

  public synchronized JsonObject state(Accounts.Account account) throws SQLException {
    JsonObject state = store.read();
    return visibleState(state, account);
  }

  private JsonObject visibleState(JsonObject snapshot, Accounts.Account account) {
    requireAccount(snapshot, account);
    JsonObject state = snapshot.deepCopy();
    if (!account.isAdmin()) {
      Map<String, Integer> otherReservations = new HashMap<>();
      for (JsonElement element : snapshot.getAsJsonArray("requests")) {
        JsonObject request = element.getAsJsonObject();
        if (string(request, "status").equals("Pending")
            && !string(request, "teacherId").equals(account.id()))
          otherReservations.merge(
              string(request, "supplyId"), request.get("quantity").getAsInt(), Integer::sum);
      }
      JsonArray own = new JsonArray();
      for (JsonElement element : state.getAsJsonArray("requests"))
        if (string(element.getAsJsonObject(), "teacherId").equals(account.id())) own.add(element);
      state.add("requests", own);
      // Availability depends on all reservations, not only the teacher's own.
      for (JsonElement element : state.getAsJsonArray("supplies")) {
        JsonObject supply = element.getAsJsonObject();
        supply.addProperty(
            "reservedByOthers", otherReservations.getOrDefault(string(supply, "id"), 0));
      }
      JsonArray profile = new JsonArray();
      profile.add(find(state.getAsJsonArray("teachers"), account.id()));
      state.add("teachers", profile);
    }
    return state;
  }

  public synchronized JsonObject execute(Accounts.Account account, String action, JsonObject data)
      throws SQLException {
    JsonObject before = store.read(), snapshot = before.deepCopy();
    requireAccount(snapshot, account);
    apply(snapshot, account, action, data);
    Map<String, String> passwords = temporaryPasswords(before, snapshot);
    requireFreeIds(passwords);
    store.write(before, snapshot, passwords);
    return withTemporaryPasswords(visibleState(snapshot, account), passwords);
  }

  public synchronized JsonObject importRows(Accounts.Account account, String type, String source)
      throws SQLException {
    requireAdmin(account);
    List<List<String>> rows = Csv.parse(source);
    List<String> expected =
        type.equals("supplies")
            ? List.of("name", "category", "quantity", "threshold", "unit")
            : type.equals("teachers") ? List.of("id", "name", "department", "email") : List.of();
    if (expected.isEmpty()
        || rows.isEmpty()
        || !rows.get(0).stream().map(String::trim).toList().equals(expected))
      throw new IllegalArgumentException("CSV header does not match the import template.");
    if (rows.size() < 2 || rows.size() > 501)
      throw new IllegalArgumentException("Include 1–500 records.");
    JsonObject before = store.read(), state = before.deepCopy();
    for (int i = 1; i < rows.size(); i++) {
      if (rows.get(i).size() != expected.size())
        throw new IllegalArgumentException("Wrong number of fields at row " + (i + 1));
      JsonObject data = new JsonObject();
      for (int j = 0; j < expected.size(); j++)
        data.addProperty(expected.get(j), rows.get(i).get(j));
      try {
        apply(state, account, type.equals("supplies") ? "saveSupply" : "saveTeacher", data);
      } catch (IllegalArgumentException exception) {
        throw new IllegalArgumentException("Row " + (i + 1) + ": " + exception.getMessage());
      }
    }
    Map<String, String> passwords = temporaryPasswords(before, state);
    requireFreeIds(passwords);
    store.write(before, state, passwords);
    return withTemporaryPasswords(visibleState(state, account), passwords);
  }

  public synchronized String changePassword(
      Accounts.Account account, String current, String next, String hint)
      throws SQLException {
    requireAccount(store.read(), account);
    login(account.id(), current);
    Accounts.validatePassword(next);
    if (current.equals(next)) throw new IllegalArgumentException("Choose a different password.");
    String reminder = Accounts.validateHint(hint, store.username(account.id()), next);
    String code = Accounts.recoveryCode(account.id());
    store.updatePassword(account.id(), next, false, reminder, code);
    return code;
  }

  /** Refreshes the hint and recovery code after verifying the account's current password. */
  public synchronized String updateRecovery(Accounts.Account account, String current, String hint)
      throws SQLException {
    requireAccount(store.read(), account);
    login(account.id(), current);
    String reminder = Accounts.validateHint(hint, store.username(account.id()), current);
    String code = Accounts.recoveryCode(account.id());
    store.setRecovery(account.id(), reminder, code);
    return code;
  }

  /** An administrator's reset is a temporary password; the teacher must change it at sign-in. */
  public synchronized void resetPassword(Accounts.Account account, String id, String next)
      throws SQLException {
    requireAdmin(account);
    if (find(store.read().getAsJsonArray("teachers"), id) == null)
      throw new IllegalArgumentException("Choose an active teacher account.");
    Accounts.validatePassword(next);
    store.updatePassword(id, next, true, null, null);
  }

  private static void requireAccount(JsonObject state, Accounts.Account account) {
    if (account == null
        || (!account.isAdmin() && find(state.getAsJsonArray("teachers"), account.id()) == null))
      throw new SecurityException("Sign in with an active account.");
  }

  private static void requireAdmin(Accounts.Account account) {
    if (account == null || !account.isAdmin())
      throw new SecurityException("Administrator access required.");
  }

  private static String string(JsonObject object, String key) {
    JsonElement value = object.get(key);
    return value != null && value.isJsonPrimitive() ? value.getAsString() : "";
  }

  private static String text(JsonObject object, String key) {
    String result = string(object, key).trim();
    if (result.isEmpty() || result.length() > 120)
      throw new IllegalArgumentException(key + " is required (up to 120 characters).");
    return result;
  }

  private static int number(JsonObject object, String key, int minimum) {
    String value = string(object, key);
    if (!value.matches("[0-9]{1,7}"))
      throw new IllegalArgumentException(key + " must be a whole number.");
    int result = Integer.parseInt(value);
    if (result < minimum || result > 1_000_000)
      throw new IllegalArgumentException(key + " is outside the allowed range.");
    return result;
  }

  private static JsonObject find(JsonArray rows, String id) {
    for (JsonElement row : rows)
      if (string(row.getAsJsonObject(), "id").equals(id)) return row.getAsJsonObject();
    return null;
  }

  private static int reserved(JsonObject state, String id, String excludeTeacher) {
    int quantity = 0;
    for (JsonElement element : state.getAsJsonArray("requests")) {
      JsonObject request = element.getAsJsonObject();
      if (string(request, "supplyId").equals(id)
          && string(request, "status").equals("Pending")
          && !string(request, "teacherId").equals(excludeTeacher))
        quantity += request.get("quantity").getAsInt();
    }
    return quantity;
  }

  private static boolean pending(JsonObject state, String field, String id) {
    for (JsonElement element : state.getAsJsonArray("requests")) {
      JsonObject request = element.getAsJsonObject();
      if (string(request, field).equals(id) && string(request, "status").equals("Pending"))
        return true;
    }
    return false;
  }

  private static void apply(
      JsonObject state, Accounts.Account account, String action, JsonObject data) {
    JsonArray supplies = state.getAsJsonArray("supplies"),
        teachers = state.getAsJsonArray("teachers"),
        requests = state.getAsJsonArray("requests");
    String id = string(data, "id");
    switch (action) {
      case "saveSupply" -> {
        requireAdmin(account);
        JsonObject old = find(supplies, id);
        if (!id.isEmpty() && old == null)
          throw new IllegalArgumentException("Supply no longer exists.");
        String name = text(data, "name"), category = text(data, "category");
        if (!CATEGORIES.contains(category))
          throw new IllegalArgumentException("Choose a listed category.");
        for (JsonElement e : supplies)
          if (e != old && string(e.getAsJsonObject(), "name").equalsIgnoreCase(name))
            throw new IllegalArgumentException("Item name already exists.");
        int quantity = number(data, "quantity", 0);
        if (old != null && quantity < reserved(state, id, ""))
          throw new IllegalArgumentException("Stock cannot be below reserved quantities.");
        JsonObject item = new JsonObject();
        item.addProperty("id", old == null ? "SUP-" + UUID.randomUUID() : id);
        item.addProperty("name", name);
        item.addProperty("category", category);
        item.addProperty("quantity", quantity);
        item.addProperty("threshold", number(data, "threshold", 0));
        item.addProperty("unit", text(data, "unit"));
        if (old != null) supplies.remove(old);
        supplies.add(item);
      }
      case "deleteSupply", "deleteTeacher" -> {
        requireAdmin(account);
        boolean supply = action.equals("deleteSupply");
        JsonArray rows = supply ? supplies : teachers;
        JsonObject old = find(rows, id);
        if (old == null) throw new IllegalArgumentException("Record no longer exists.");
        if (pending(state, supply ? "supplyId" : "teacherId", id))
          throw new IllegalArgumentException("Resolve pending requests first.");
        rows.remove(old);
      }
      case "saveTeacher" -> {
        requireAdmin(account);
        id = text(data, "id");
        if (!id.matches("[a-zA-Z0-9_-]{1,30}") || id.equals("001"))
          throw new IllegalArgumentException(
              "Use a unique teacher ID (1–30 letters, numbers, _ or -; not 001).");
        JsonObject old = null;
        for (JsonElement e : teachers)
          if (string(e.getAsJsonObject(), "id").equalsIgnoreCase(id)) old = e.getAsJsonObject();
        boolean edit = string(data, "edit").equals("true");
        if (!edit && old != null) throw new IllegalArgumentException("Teacher ID already exists.");
        if (edit && (old == null || !string(old, "id").equals(id)))
          throw new IllegalArgumentException("Teacher no longer exists.");
        String email = string(data, "email").trim();
        if (email.length() > 120
            || (!email.isEmpty() && !email.matches("[^\\s@]+@[^\\s@]+\\.[^\\s@]+")))
          throw new IllegalArgumentException("Enter a valid email or leave it blank.");
        JsonObject t = new JsonObject();
        t.addProperty("id", id);
        t.addProperty("name", text(data, "name"));
        t.addProperty("department", text(data, "department"));
        t.addProperty("email", email);
        if (old != null) teachers.remove(old);
        teachers.add(t);
      }
      case "request" -> {
        if (account.isAdmin()) throw new SecurityException("Teachers create requisitions.");
        JsonObject supply = find(supplies, string(data, "supplyId"));
        if (supply == null) throw new IllegalArgumentException("Supply no longer exists.");
        int quantity = number(data, "quantity", 1);
        if (quantity
            > supply.get("quantity").getAsInt() - reserved(state, string(supply, "id"), ""))
          throw new IllegalArgumentException("Requested quantity exceeds available stock.");
        String note = string(data, "note").trim();
        if (note.length() > 240)
          throw new IllegalArgumentException("Notes may contain up to 240 characters.");
        JsonObject request = new JsonObject();
        request.addProperty("id", "REQ-" + UUID.randomUUID());
        request.addProperty("teacherId", account.id());
        request.addProperty("teacherName", string(find(teachers, account.id()), "name"));
        request.addProperty("supplyId", string(supply, "id"));
        request.addProperty("supplyName", string(supply, "name"));
        request.addProperty("quantity", quantity);
        request.addProperty("status", "Pending");
        request.addProperty("note", note);
        request.addProperty("createdAt", Instant.now().toString());
        requests.add(request);
      }
      case "issue", "reject", "cancel" -> {
        JsonObject request = find(requests, id);
        if (request == null || !string(request, "status").equals("Pending"))
          throw new IllegalArgumentException("This request is no longer pending.");
        if (action.equals("cancel")) {
          if (account.isAdmin() || !account.id().equals(string(request, "teacherId")))
            throw new SecurityException("You can only cancel your own pending requests.");
        } else requireAdmin(account);
        if (action.equals("issue")) {
          JsonObject supply = find(supplies, string(request, "supplyId"));
          int quantity = request.get("quantity").getAsInt();
          if (supply == null || supply.get("quantity").getAsInt() < quantity)
            throw new IllegalArgumentException("Insufficient stock.");
          supply.addProperty("quantity", supply.get("quantity").getAsInt() - quantity);
        }
        request.addProperty(
            "status",
            action.equals("issue") ? "Issued" : action.equals("reject") ? "Rejected" : "Cancelled");
        request.addProperty("updatedAt", Instant.now().toString());
      }
      default -> throw new IllegalArgumentException("Unknown action.");
    }
  }
}
