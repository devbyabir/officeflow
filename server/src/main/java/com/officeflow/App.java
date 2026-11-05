package com.officeflow;

import com.google.gson.Gson;
import com.google.gson.JsonObject;
import com.google.gson.JsonParseException;
import com.google.gson.JsonParser;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.SecureRandom;
import java.sql.SQLException;
import java.time.Instant;
import java.util.Base64;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/** Local Java HTTP server; static demo and API use the same frontend. */
public final class App {
  private static final Gson JSON = new Gson();

  private record Session(Accounts.Account account, Instant expires) {}

  private final Map<String, Session> sessions = new ConcurrentHashMap<>();
  private final Service service;
  private final Path site;
  private final HttpServer server;
  private long loginWindow;
  private int failedLogins;

  public App(Service service, Path site, int port) throws IOException {
    this.service = service;
    this.site = site.toRealPath();
    server = HttpServer.create(new InetSocketAddress("127.0.0.1", port), 0);
    server.createContext("/api/", this::api);
    server.createContext("/", this::staticFile);
  }

  public void start() {
    server.start();
  }

  public void stop() {
    server.stop(0);
  }

  public int port() {
    return server.getAddress().getPort();
  }

  private static JsonObject object(String key, String value) {
    JsonObject o = new JsonObject();
    o.addProperty(key, value);
    return o;
  }

  private void json(HttpExchange exchange, int status, Object result) throws IOException {
    byte[] bytes = JSON.toJson(result).getBytes(StandardCharsets.UTF_8);
    exchange.getResponseHeaders().set("Content-Type", "application/json; charset=utf-8");
    exchange.getResponseHeaders().set("Cache-Control", "no-store");
    exchange.getResponseHeaders().set("X-Content-Type-Options", "nosniff");
    exchange.sendResponseHeaders(status, bytes.length);
    exchange.getResponseBody().write(bytes);
    exchange.close();
  }

  private JsonObject body(HttpExchange exchange) throws IOException {
    if (!exchange.getRequestMethod().equals("POST"))
      throw new IllegalArgumentException("POST required.");
    String contentType = exchange.getRequestHeaders().getFirst("Content-Type");
    if (contentType == null
        || !contentType.toLowerCase(java.util.Locale.ROOT).startsWith("application/json"))
      throw new IllegalArgumentException("JSON content type required.");
    byte[] bytes = exchange.getRequestBody().readNBytes(250001);
    if (bytes.length > 250000) throw new IllegalArgumentException("Request body is too large.");
    var parsed = JsonParser.parseString(new String(bytes, StandardCharsets.UTF_8));
    if (!parsed.isJsonObject()) throw new IllegalArgumentException("Expected a JSON object.");
    return parsed.getAsJsonObject();
  }

  private static String value(JsonObject data, String key) {
    return data.has(key) && data.get(key).isJsonPrimitive() ? data.get(key).getAsString() : "";
  }

  private Accounts.Account account(HttpExchange exchange) {
    String header = exchange.getRequestHeaders().getFirst("Authorization");
    Session session =
        header != null && header.startsWith("Bearer ") ? sessions.get(header.substring(7)) : null;
    if (session == null || session.expires().isBefore(Instant.now()))
      throw new SecurityException("Your session has ended. Please sign in.");
    return session.account();
  }

  private synchronized Accounts.Account signIn(JsonObject data) throws SQLException {
    long current = System.currentTimeMillis();
    if (current - loginWindow > 60000) {
      loginWindow = current;
      failedLogins = 0;
    }
    if (failedLogins >= 10)
      throw new SecurityException("Too many attempts. Try again in a minute.");
    String id = value(data, "id"), password = value(data, "password");
    if (id.length() > 30 || password.length() > 200)
      throw new IllegalArgumentException("Credentials are too long.");
    try {
      return service.login(id, password);
    } catch (SecurityException exception) {
      failedLogins++;
      throw exception;
    }
  }

  private void api(HttpExchange exchange) throws IOException {
    try {
      String path = exchange.getRequestURI().getPath();
      if (path.equals("/api/health") && exchange.getRequestMethod().equals("GET")) {
        json(exchange, 200, object("service", "officeflow"));
        return;
      }
      if (path.equals("/api/login")) {
        Accounts.Account account = signIn(body(exchange));
        sessions.entrySet().removeIf(entry -> entry.getValue().expires().isBefore(Instant.now()));
        byte[] bytes = new byte[32];
        new SecureRandom().nextBytes(bytes);
        String token = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
        sessions.put(token, new Session(account, Instant.now().plusSeconds(28800)));
        JsonObject result = object("token", token);
        result.add("actor", actor(account));
        json(exchange, 200, result);
        return;
      }
      Accounts.Account account = account(exchange);
      if (path.equals("/api/logout")) {
        body(exchange);
        sessions.remove(exchange.getRequestHeaders().getFirst("Authorization").substring(7));
        json(exchange, 200, object("message", "Signed out."));
      } else if (path.equals("/api/password/change")) {
        JsonObject data = body(exchange);
        service.changePassword(account, value(data, "currentPassword"), value(data, "newPassword"));
        invalidateSessions(account.id());
        json(exchange, 200, object("message", "Password changed. Sign in again."));
      } else if (path.equals("/api/password/reset")) {
        JsonObject data = body(exchange);
        String id = value(data, "id");
        service.resetPassword(account, id, value(data, "newPassword"));
        invalidateSessions(id);
        json(exchange, 200, object("message", "Password reset. Existing sessions ended."));
      } else if (path.equals("/api/state") && exchange.getRequestMethod().equals("GET"))
        json(exchange, 200, service.state(account));
      else if (path.equals("/api/session") && exchange.getRequestMethod().equals("GET")) {
        service.state(account);
        JsonObject result = new JsonObject();
        result.add("actor", actor(account));
        json(exchange, 200, result);
      } else if (path.equals("/api/command")) {
        JsonObject data = body(exchange);
        if (!data.has("data") || !data.get("data").isJsonObject())
          throw new IllegalArgumentException("Command data is required.");
        JsonObject result =
            service.execute(account, value(data, "action"), data.getAsJsonObject("data"));
        if (value(data, "action").equals("deleteTeacher"))
          invalidateSessions(value(data.getAsJsonObject("data"), "id"));
        json(exchange, 200, result);
      } else if (path.equals("/api/import")) {
        JsonObject data = body(exchange);
        json(exchange, 200, service.importRows(account, value(data, "type"), value(data, "csv")));
      } else json(exchange, 404, object("error", "Endpoint not found."));
    } catch (SecurityException exception) {
      json(exchange, 403, object("error", exception.getMessage()));
    } catch (IllegalArgumentException | JsonParseException | IllegalStateException exception) {
      json(
          exchange,
          400,
          object(
              "error",
              exception.getMessage() == null ? "Invalid request." : exception.getMessage()));
    } catch (SQLException exception) {
      System.err.println("Database operation failed: " + exception.getSQLState());
      json(exchange, 500, object("error", "The database could not complete this operation."));
    } catch (Exception exception) {
      System.err.println("Request failed: " + exception.getClass().getSimpleName());
      json(exchange, 500, object("error", "The request could not be completed."));
    }
  }

  private void invalidateSessions(String id) {
    sessions.entrySet().removeIf(entry -> entry.getValue().account().id().equals(id));
  }

  private static JsonObject actor(Accounts.Account account) {
    JsonObject a = object("id", account.id());
    a.addProperty("role", account.role());
    return a;
  }

  private void staticFile(HttpExchange exchange) throws IOException {
    if (!exchange.getRequestMethod().equals("GET")) {
      exchange.sendResponseHeaders(405, -1);
      exchange.close();
      return;
    }
    String requested = exchange.getRequestURI().getPath();
    Path file =
        site.resolve(requested.equals("/") ? "index.html" : requested.substring(1)).normalize();
    if (!file.startsWith(site)
        || !Files.isRegularFile(file)
        || !file.toRealPath().startsWith(site)) {
      exchange.sendResponseHeaders(404, -1);
      exchange.close();
      return;
    }
    String type =
        file.toString().endsWith(".js")
            ? "text/javascript"
            : file.toString().endsWith(".css")
                ? "text/css"
                : file.toString().endsWith(".svg")
                    ? "image/svg+xml"
                    : file.toString().endsWith(".json")
                        ? "application/json"
                        : file.toString().endsWith(".html")
                            ? "text/html"
                            : "application/octet-stream";
    exchange.getResponseHeaders().set("Content-Type", type + "; charset=utf-8");
    exchange.getResponseHeaders().set("X-Content-Type-Options", "nosniff");
    byte[] bytes = Files.readAllBytes(file);
    exchange.sendResponseHeaders(200, bytes.length);
    exchange.getResponseBody().write(bytes);
    exchange.close();
  }

  public static void main(String[] args) throws Exception {
    Path site = Path.of(System.getProperty("officeflow.site", "docs/site"));
    String url = System.getProperty("officeflow.db", "jdbc:h2:./data/officeflow");
    String password = System.getenv().getOrDefault("OFFICEFLOW_ADMIN_PASSWORD", "001");
    Store store = new Store(url, password);
    if (store.read().getAsJsonArray("supplies").isEmpty()
        && Boolean.getBoolean("officeflow.seed")) {
      store.write(
          JsonParser.parseString(Files.readString(site.resolve("sample-data.json")))
              .getAsJsonObject());
    }
    App app = new App(new Service(store), site, Integer.getInteger("officeflow.port", 8080));
    Runtime.getRuntime()
        .addShutdownHook(
            new Thread(
                () -> {
                  app.stop();
                  try {
                    store.close();
                  } catch (SQLException ignored) {
                  }
                }));
    app.start();
    System.out.println("OfficeFlow: http://127.0.0.1:" + app.port());
    System.out.println(
        "Local Java/JDBC workspace. Set OFFICEFLOW_ADMIN_PASSWORD before first launch to override"
            + " demo admin password.");
  }
}
