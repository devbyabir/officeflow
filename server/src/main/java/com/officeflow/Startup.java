package com.officeflow;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * Resolves the site folder and database before anything is opened, so a wrong folder, an old
 * command or a missing password stops with instructions instead of creating a blank workspace.
 */
final class Startup {
  /** Thrown with a message meant for the person starting OfficeFlow; nothing has been opened. */
  static final class Problem extends Exception {
    private static final long serialVersionUID = 1L;

    Problem(String message) {
      super(message);
    }
  }

  static final String SAMPLE_URL = "https://devbyabir.github.io/officeflow/";
  static final String MODE_MARKER = "<meta name=\"officeflow-mode\" content=\"sample\" />";
  private static final List<String> SITE_FILES =
      List.of(
          "index.html",
          "app.js",
          "model.js",
          "view-utils.js",
          "theme.js",
          "style.css",
          "theme.css",
          "polish.css",
          "favicon.svg");

  private final Map<String, String> environment;
  private final Path workingDirectory;
  private final Path repository;

  Startup(Map<String, String> environment, Path workingDirectory, Path repository) {
    this.environment = environment;
    this.workingDirectory = workingDirectory.toAbsolutePath().normalize();
    this.repository = repository;
  }

  /** The repository root when running from server/target/classes or server/target/*.jar. */
  static Path repositoryFromCode() {
    try {
      Path code = Path.of(App.class.getProtectionDomain().getCodeSource().getLocation().toURI());
      Path target = code.getParent(), server = target == null ? null : target.getParent();
      return server == null ? null : server.getParent();
    } catch (Exception exception) {
      return null;
    }
  }

  /** The folder holding officeflow.jar when running from a JAR file (the release ZIP), else null. */
  static Path jarFolder() {
    try {
      Path code = Path.of(App.class.getProtectionDomain().getCodeSource().getLocation().toURI());
      return Files.isRegularFile(code) ? code.getParent() : null;
    } catch (Exception exception) {
      return null;
    }
  }

  static void rejectSeedFlag(String seedProperty) throws Problem {
    if (seedProperty == null) return;
    throw new Problem(
        "OfficeFlow no longer loads sample data into the local workspace (-Dofficeflow.seed was"
            + " given).\n"
            + "Nothing was opened or changed.\n"
            + "To try OfficeFlow with sample data, open "
            + SAMPLE_URL
            + "\n"
            + "To open your workspace, run the same command without -Dofficeflow.seed.");
  }

  /**
   * The explicit site folder, or the first valid one of: "site" next to officeflow.jar (the
   * release ZIP), docs/site in the working directory, docs/site in the repository.
   */
  Path site(String siteProperty) throws Problem {
    List<Path> candidates = new ArrayList<>();
    if (siteProperty != null) candidates.add(workingDirectory.resolve(siteProperty));
    else {
      Path jarFolder = jarFolder();
      if (jarFolder != null) candidates.add(jarFolder.resolve("site"));
      candidates.add(workingDirectory.resolve("docs/site"));
      if (repository != null) candidates.add(repository.resolve("docs/site"));
    }
    List<String> problems = new ArrayList<>();
    for (Path candidate : candidates) {
      String problem = siteProblem(candidate.normalize());
      if (problem == null) return candidate.normalize();
      problems.add("  " + candidate.normalize() + ": " + problem);
    }
    throw new Problem(
        "OfficeFlow could not find its web files (docs/site). Checked:\n"
            + String.join("\n", problems)
            + "\nRun OfficeFlow from the repository folder, or pass the folder explicitly:\n"
            + "  java \"-Dofficeflow.site=C:\\path\\to\\officeflow\\docs\\site\" -jar "
            + jarHint()
            + "\nNothing was opened or created.");
  }

  private static String siteProblem(Path folder) {
    if (!Files.isDirectory(folder)) return "folder not found";
    for (String file : SITE_FILES)
      if (!Files.isRegularFile(folder.resolve(file))) return file + " is missing";
    try {
      if (!Files.readString(folder.resolve("index.html")).contains(MODE_MARKER))
        return "index.html is not an OfficeFlow page";
    } catch (IOException exception) {
      return "index.html could not be read";
    }
    return null;
  }

  /** The default database: %LOCALAPPDATA%\OfficeFlow on Windows, ./data elsewhere. */
  String defaultDatabase() {
    String local = environment.get("LOCALAPPDATA");
    Path base =
        local != null && !local.isBlank()
            ? Path.of(local).resolve("OfficeFlow")
            : workingDirectory.resolve("data");
    return "jdbc:h2:" + slashes(base.resolve("officeflow").toAbsolutePath().normalize());
  }

  /** The JDBC URL to open, after checking for an older workspace left in ./data. */
  String database(String databaseProperty) throws Problem {
    if (databaseProperty != null) return databaseProperty;
    String url = defaultDatabase();
    Path file = databaseFile(url);
    if (file != null && !Files.exists(file)) {
      for (Path legacy : legacyDatabases()) {
        if (legacy.equals(file) || !Files.isRegularFile(legacy)) continue;
        String oldPath = legacy.toString().replaceFirst("\\.mv\\.db$", "");
        throw new Problem(
            "Found an existing OfficeFlow database:\n  "
                + legacy
                + "\nThe new default location is empty:\n  "
                + file
                + "\nNothing was created or moved. Choose one:\n"
                + "  Keep using the existing database where it is:\n"
                + "    java \"-Dofficeflow.db=jdbc:h2:"
                + slashes(Path.of(oldPath))
                + "\" -jar "
                + jarHint()
                + "\n  Or move it to the new default location (with OfficeFlow stopped):\n"
                + "    New-Item -ItemType Directory -Force \""
                + file.getParent()
                + "\" | Out-Null\n"
                + "    Move-Item \""
                + legacy
                + "\" \""
                + file
                + "\"\n"
                + "  Or start a new, empty workspace and leave the old file alone:\n"
                + "    java \"-Dofficeflow.db="
                + url
                + "\" -jar "
                + jarHint());
      }
    }
    return url;
  }

  private List<Path> legacyDatabases() {
    List<Path> result = new ArrayList<>();
    result.add(workingDirectory.resolve("data/officeflow.mv.db").normalize());
    if (repository != null) {
      Path fromRepository = repository.resolve("data/officeflow.mv.db").toAbsolutePath().normalize();
      if (!result.contains(fromRepository)) result.add(fromRepository);
    }
    return result;
  }

  /** Stops before a new workspace would be created without a valid administrator password. */
  void requireAdminPasswordForNewWorkspace(String url) throws Problem {
    Path file = databaseFile(url);
    if (file == null || Files.exists(file)) return;
    String password = environment.getOrDefault("OFFICEFLOW_ADMIN_PASSWORD", "");
    try {
      Accounts.validatePassword(password);
    } catch (IllegalArgumentException exception) {
      throw new Problem(newWorkspaceMessage(file));
    }
  }

  static String newWorkspaceMessage(Object location) {
    return "This starts a new OfficeFlow workspace at:\n  "
        + location
        + "\nSet an administrator password of 12-120 characters first. In PowerShell:\n"
        + "  $env:OFFICEFLOW_ADMIN_PASSWORD = Read-Host \"New OfficeFlow admin password\"\n"
        + "Then start OfficeFlow again in the same window. The administrator account ID is 001.\n"
        + "Nothing was created.";
  }

  /** The .mv.db file behind an H2 file URL, or null for in-memory and server URLs. */
  Path databaseFile(String url) {
    if (!url.startsWith("jdbc:h2:")) return null;
    String rest = url.substring("jdbc:h2:".length());
    int options = rest.indexOf(';');
    if (options >= 0) rest = rest.substring(0, options);
    if (rest.startsWith("file:")) rest = rest.substring("file:".length());
    // mem:, tcp:, ssl:, zip: and similar are not plain files. A drive letter (C:) has one letter.
    else if (rest.matches("^[a-z]{2,}:.*")) return null;
    if (rest.startsWith("~")) rest = System.getProperty("user.home") + rest.substring(1);
    Path path = workingDirectory.resolve(rest).normalize();
    return path.resolveSibling(path.getFileName() + ".mv.db");
  }

  private String jarHint() {
    if (repository != null) {
      Path jar = repository.resolve("server/target/officeflow-1.0.0.jar");
      if (Files.isRegularFile(jar)) return "\"" + jar + "\"";
    }
    return "server\\target\\officeflow-1.0.0.jar";
  }

  private static String slashes(Path path) {
    return path.toString().replace('\\', '/');
  }
}
