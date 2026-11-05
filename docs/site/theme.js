(() => {
  const key = "officeflow-theme";
  let saved;
  try {
    saved = localStorage.getItem(key);
  } catch {}
  const system = matchMedia("(prefers-color-scheme: dark)");
  function apply(theme) {
    document.documentElement.dataset.theme = theme;
    const button = document.getElementById("theme-toggle");
    if (button) {
      const dark = theme === "dark";
      button.innerHTML = dark ? "☀ <span>Light</span>" : "☾ <span>Dark</span>";
      button.setAttribute("aria-pressed", String(dark));
      button.setAttribute(
        "aria-label",
        `Switch to ${dark ? "light" : "dark"} mode`,
      );
    }
    document.querySelector('meta[name="theme-color"]').content =
      getComputedStyle(document.documentElement)
        .getPropertyValue("--bg")
        .trim();
  }
  apply(
    ["light", "dark"].includes(saved)
      ? saved
      : system.matches
        ? "dark"
        : "light",
  );
  document.addEventListener("DOMContentLoaded", () => {
    apply(document.documentElement.dataset.theme);
    document.getElementById("theme-toggle").addEventListener("click", () => {
      saved =
        document.documentElement.dataset.theme === "dark" ? "light" : "dark";
      apply(saved);
      try {
        localStorage.setItem(key, saved);
      } catch {}
    });
  });
  system.addEventListener("change", (event) => {
    if (!["light", "dark"].includes(saved))
      apply(event.matches ? "dark" : "light");
  });
})();
