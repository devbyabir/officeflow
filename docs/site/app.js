import { paginate, statusCounts, stockParts } from "./view-utils.js";
import {
  seed,
  command,
  available,
  stockStatus,
  importCSV,
  csv,
  categories,
  STORE_KEY,
} from "./model.js";

const $ = (selector) => document.querySelector(selector);
const escape = (value) =>
  String(value ?? "").replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ],
  );
const initials = (name) =>
  name
    .split(/\s+/)
    .map((x) => x[0])
    .slice(0, 2)
    .join("")
    .toUpperCase();
const icons = {
  overview:
    '<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/>',
  inventory:
    '<path d="m3 7 9-4 9 4v10l-9 4-9-4Z"/><path d="m3 7 9 4 9-4M12 11v10M7.5 5l9 4"/>',
  requests:
    '<rect x="5" y="4" width="14" height="17" rx="2"/><path d="M9 3h6v4H9zM9 12h6M9 16h4"/>',
  teachers:
    '<circle cx="9" cy="8" r="3"/><path d="M3 21v-3a6 6 0 0 1 12 0v3M17 5a3 3 0 0 1 0 6M18 15a5 5 0 0 1 3 5"/>',
  history: '<path d="M3 11a9 9 0 1 1 2.6 7M3 4v7h7M12 7v5l3 2"/>',
  search: '<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 5 5"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  export: '<path d="M12 3v12m-4-4 4 4 4-4M4 16v5h16v-5"/>',
  import: '<path d="M12 16V4m-4 4 4-4 4 4M4 16v5h16v-5"/>',
  arrow: '<path d="M4 12h16m-5-5 5 5-5 5"/>',
  alert: '<path d="m12 3 10 18H2Z M12 9v5M12 17v1"/>',
  paper: '<path d="M6 3h8l4 4v14H6zM14 3v5h4M9 12h6M9 16h6"/>',
  tech: '<rect x="3" y="4" width="18" height="13" rx="2"/><path d="M8 21h8M12 17v4"/>',
  pen: '<path d="m15 3 6 6L8 22H2v-6ZM12 6l6 6M3 16l5 5"/>',
  desk: '<rect x="3" y="6" width="18" height="11" rx="2"/><path d="M7 6v11M3 12h18M6 17v4M18 17v4"/>',
};
const icon = (name) =>
  `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${icons[name] || icons.inventory}</svg>`;
const badge = (status) =>
  `<span class="badge ${{ "Low stock": "low", "Out of stock": "out", Pending: "pending", Issued: "issued", Rejected: "rejected", Cancelled: "cancelled" }[status] || ""}">${escape(status)}</span>`;
// The Java server marks the page it serves; GitHub Pages and other static copies stay "sample".
// Java mode never reads or writes the browser's sample workspace.
const JAVA_MODE =
  document.querySelector('meta[name="officeflow-mode"]')?.content === "java";
let state,
  actor = JAVA_MODE ? { role: "teacher", id: "" } : { role: "admin", id: "admin" },
  api = JAVA_MODE,
  connection = JAVA_MODE ? "connecting" : "ready",
  token = sessionStorage.getItem("officeflow-token") || "";
let query = "",
  category = "",
  sort = "name",
  requestFilter = "",
  page = "overview";
let loadWarning = "";
let tablePage = 1,
  pageSize = 5,
  stockFilter = "";
let lastRenderedPage = "";
const animatedWorkspaces = new Set();
let closingAnimation;
// Set while the setup or sign-in screen is shown: it cannot be dismissed, only completed or
// quit. resumeAuth reopens that screen after "Keep working" in the quit confirmation.
let authLocked = false,
  resumeAuth = null,
  justSaved = "";
// OfficeFlow.exe opens the first run as /#setup=<token>. A URL fragment never reaches the
// server or its logs; the token is kept only in this tab and removed from the address bar.
let setupToken = "";
if (JAVA_MODE) {
  const offered = location.hash.match(/^#setup=([A-Za-z0-9_-]{32,128})$/)?.[1];
  try {
    if (offered) sessionStorage.setItem("officeflow-setup", offered);
    setupToken = sessionStorage.getItem("officeflow-setup") || "";
  } catch {
    setupToken = offered || "";
  }
  if (location.hash.startsWith("#setup="))
    history.replaceState(null, "", location.pathname + location.search);
}
function forgetSetupToken() {
  setupToken = "";
  try {
    sessionStorage.removeItem("officeflow-setup");
  } catch {}
}
if (JAVA_MODE) state = { supplies: [], teachers: [], requests: [] };
else
  try {
    const saved = JSON.parse(localStorage.getItem(STORE_KEY));
    state = saved || seed();
    if (
      !Array.isArray(state.supplies) ||
      !Array.isArray(state.teachers) ||
      !Array.isArray(state.requests)
    )
      throw Error();
  } catch {
    state = seed();
    loadWarning =
      "Saved demo data could not be loaded. A fresh workspace has been opened.";
  }

async function apiCall(path, body) {
  const finish = networkLoading(path);
  try {
    let response;
    try {
      response = await fetch(`./api/${path}`, {
        method: body ? "POST" : "GET",
        headers: {
          "Content-Type": "application/json",
          ...(token ? { Authorization: `Bearer ${token}` } : {}),
        },
        body: body ? JSON.stringify(body) : undefined,
      });
    } catch {
      throw Object.assign(
        new Error(
          "OfficeFlow is not answering. It may have been closed: open OfficeFlow from the Start menu, then try again.",
        ),
        { offline: true },
      );
    }
    const result = await response.json();
    if (!response.ok && result.code === "SESSION_EXPIRED") {
      clearSession();
      loginDialog();
      toast("Your session has ended. Please log in again.");
    }
    if (!response.ok && result.code === "PASSWORD_CHANGE_REQUIRED")
      passwordDialog(false, true);
    if (!response.ok)
      throw Object.assign(
        new Error(result.error || "The server could not complete this request."),
        { code: result.code },
      );
    return result;
  } finally {
    finish();
  }
}
// Returns any temporary passwords the server created for new teachers (shown once).
async function save(action, data) {
  let updated;
  if (api) updated = await apiCall("command", { action, data });
  else {
    updated = command(state, actor, action, data);
    // Persist before committing UI state so a quota failure does not look successful.
    localStorage.setItem(STORE_KEY, JSON.stringify(updated));
  }
  return commit(updated);
}
function commit(updated) {
  const passwords = updated.temporaryPasswords || [];
  delete updated.temporaryPasswords;
  state = updated;
  return passwords;
}
function temporaryPasswordsDialog(passwords) {
  modal(
    passwords.length === 1
      ? "Give this teacher their temporary password"
      : "Give these teachers their temporary passwords",
    "Shown only now. Each teacher signs in with it once and must then choose their own password.",
    `<div class="help-copy"><ul class="temporary-passwords">${passwords.map((p) => `<li><strong>${escape(p.id)}</strong> <code>${escape(p.password)}</code></li>`).join("")}</ul><p>Share each password privately. If one is lost, use <strong>Account → Reset teacher password</strong>.</p></div><div class="dialog-actions"><button class="button primary" data-action="close">Done</button></div>`,
  );
}
function toast(message, kind = "") {
  $("#toast").textContent = message;
  $("#toast").className = kind;
  void $("#toast").offsetWidth;
  $("#toast").classList.add("show");
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => $("#toast").classList.remove("show"), 4000);
}
function date(value) {
  return new Date(value).toLocaleDateString("en-GB", {
    day: "numeric",
    month: "short",
  });
}
function itemIcon(item) {
  const type =
    { Technology: "tech", "Paper & print": "paper", Stationery: "pen" }[
      item.category
    ] || "desk";
  return `<span class="item-icon ${type}">${icon(type)}</span>`;
}
const pending = () =>
  state.requests.filter(
    (r) =>
      r.status === "Pending" &&
      (actor.role === "admin" || r.teacherId === actor.id),
  );
const mine = () =>
  state.requests.filter(
    (r) => actor.role === "admin" || r.teacherId === actor.id,
  );
function navigation() {
  const items = [
    ["overview", "Overview"],
    ["inventory", "Supply inventory"],
    ["requests", "Requisitions"],
    ...(actor.role === "admin" ? [["teachers", "Teachers"]] : []),
    ["history", "Activity & history"],
  ];
  $("#navigation").innerHTML = items
    .map(
      ([key, name]) =>
        `<a href="#${key}" class="nav-item ${page === key ? "active" : ""}" ${page === key ? 'aria-current="page"' : ""}>${icon(key)}${name}${key === "requests" && pending().length ? `<span class="nav-count">${pending().length}</span>` : ""}</a>`,
    )
    .join("");
  const person =
    actor.role === "admin"
      ? { name: "Workspace admin" }
      : state.teachers.find((t) => t.id === actor.id);
  $("#profile-name").textContent = person?.name || "Teacher";
  $("#profile-role").textContent =
    actor.role === "admin" ? "Administrator" : "Teacher";
  $(".profile .avatar").textContent = initials(person?.name || "Teacher");
  $("#top-avatar").textContent =
    actor.role === "admin" ? "AD" : initials(person?.name || "Teacher");
}
function heading(eyebrow, title, subtitle, buttons = "") {
  return `<div class="page-heading"><div><div class="eyebrow">${eyebrow}</div><h1>${title}</h1><p class="subtitle">${subtitle}</p></div><div class="heading-actions">${buttons}</div></div>`;
}
const actionButton = (action, label, glyph, primary = false, extra = "") =>
  `<button class="button ${primary ? "primary" : ""}" data-action="${action}" ${extra}>${icon(glyph)}${label}</button>`;
function metrics() {
  const low = state.supplies.filter(
    (s) => stockStatus(state, s) !== "In stock",
  ).length;
  return `<section class="metrics" aria-label="Workspace statistics">${[
    [
      "Total supply items",
      state.supplies.length,
      "inventory",
      "Across " +
        new Set(state.supplies.map((s) => s.category)).size +
        " categories",
      "",
    ],
    [
      "Pending requisitions",
      pending().length,
      "requests",
      "<strong>Awaiting " +
        (actor.role === "admin" ? "your review" : "approval") +
        "</strong>",
      "",
    ],
    [
      "Low & out of stock",
      low,
      "alert",
      "Items that need a little attention",
      "warning",
    ],
    [
      actor.role === "admin" ? "Registered teachers" : "My issued requests",
      actor.role === "admin"
        ? state.teachers.length
        : mine().filter((r) => r.status === "Issued").length,
      "teachers",
      actor.role === "admin"
        ? "Connected to this workspace"
        : "Ready for your next task",
      "",
    ],
  ]
    .map(
      ([name, value, glyph, foot, cls], index) =>
        `<a class="metric ${cls}" href="${["#inventory", "#requests?status=Pending", "#inventory?stock=low", actor.role === "admin" ? "#teachers" : "#history?status=Issued"][index]}" title="Open ${escape(name.toLowerCase())}"><div class="metric-head">${name}<span class="metric-icon">${icon(glyph)}</span></div><div class="metric-value" data-count="${value}">${value.toString().padStart(2, "0")}</div><div class="metric-foot">${foot}</div><span class="metric-link" aria-hidden="true">↗</span></a>`,
    )
    .join("")}</section>`;
}
function toolbar(type = "inventory") {
  return `<div class="toolbar"><label class="search">${icon("search")}<span class="screen-reader">Search ${type}</span><input id="search" type="search" placeholder="Search ${type === "inventory" ? "supplies by name or ID" : type === "teachers" ? "teachers by name or department" : "requests by name or item"}…" value="${escape(query)}"></label>${type === "inventory" ? `<label><span class="screen-reader">Category</span><select id="category"><option value="">All categories</option>${categories.map((c) => `<option ${category === c ? "selected" : ""}>${escape(c)}</option>`).join("")}</select></label><label><span class="screen-reader">Sort inventory</span><select id="sort"><option value="name" ${sort === "name" ? "selected" : ""}>Name A–Z</option><option value="asc" ${sort === "asc" ? "selected" : ""}>Stock: low to high</option><option value="desc" ${sort === "desc" ? "selected" : ""}>Stock: high to low</option></select></label>` : type === "requests" ? `<label><span class="screen-reader">Status</span><select id="request-filter"><option value="">All statuses</option>${["Pending", "Issued", "Rejected", "Cancelled"].map((s) => `<option ${requestFilter === s ? "selected" : ""}>${s}</option>`).join("")}</select></label>` : ""}</div>`;
}
function filteredSupplies() {
  return state.supplies
    .filter(
      (s) =>
        (!category || s.category === category) &&
        (!stockFilter || stockStatus(state, s) !== "In stock") &&
        `${s.name} ${s.id}`.toLowerCase().includes(query.toLowerCase()),
    )
    .sort(
      (a, b) =>
        (sort === "name"
          ? 0
          : sort === "asc"
            ? a.quantity - b.quantity
            : b.quantity - a.quantity) || a.name.localeCompare(b.name),
    );
}
function inventoryTable(compact = false) {
  const list = filteredSupplies();
  const result = paginate(list, tablePage, pageSize);
  tablePage = result.page;
  const visible = compact ? list.slice(0, 5) : result.items;
  return `${compact ? "" : `<div class="filter-summary" role="status"><span>${list.length} matching item${list.length === 1 ? "" : "s"}${stockFilter ? " · Low or out of stock" : ""}<span class="stock-note">Available = on hand minus units reserved for pending requests</span></span><button class="text-button" data-action="clear-filters">Clear filters</button></div>`}
  <div class="table-wrap"><table class="inventory-table"><caption class="screen-reader">Supply inventory. Available is on hand minus units reserved for pending requests.</caption><thead><tr><th scope="col">Item</th><th scope="col">Category</th><th scope="col" class="num" title="Ready to request: on hand minus units reserved for pending requests">Available</th><th scope="col" class="num" title="Physically in the cupboard, including reserved units">On hand</th><th scope="col">Status</th><th scope="col"><span class="screen-reader">Actions</span></th></tr></thead><tbody>${visible
    .map((item) => {
      const parts = stockParts(item.quantity, available(state, item));
      const status = stockStatus(state, item);
      const tone = { "Low stock": "low", "Out of stock": "out" }[status] || "ok";
      return `<tr data-supply="${escape(item.id)}"${justSaved && justSaved === item.name ? ' class="just-saved"' : ""}><td><div class="item-cell">${itemIcon(item)}<div class="item-text"><button class="item-detail-link" data-action="supply-details" data-id="${escape(item.id)}">${escape(item.name)}</button><span class="item-id">${escape(item.id.length > 15 ? "SUP-" + item.id.slice(-6).toUpperCase() : item.id)}</span></div></div></td><td class="category-text">${escape(item.category)}</td><td class="num"><span class="qty-available ${tone}">${parts.available}</span><span class="qty-unit">${escape(item.unit)}</span></td><td class="num"><span class="qty-onhand">${parts.onHand}</span>${parts.reserved ? `<span class="qty-reserved">${parts.reserved} reserved</span>` : ""}</td><td>${badge(status)}</td><td><button class="row-action" data-action="${actor.role === "admin" ? "edit-supply" : "request-item"}" data-id="${escape(item.id)}" title="${actor.role === "admin" ? "Edit inventory" : "Request supplies"}" aria-label="${actor.role === "admin" ? "Edit" : "Request"} ${escape(item.name)}">${actor.role === "admin" ? "↗" : "＋"}</button></td></tr>`;
    })
    .join(
      "",
    )}</tbody></table>${!visible.length ? empty("No supplies found", "Try another search or clear your filters.") : ""}</div>
  <div class="table-bottom"><span>${compact ? `Showing ${visible.length} of ${list.length}` : `${result.start}–${result.end} of ${result.total}`} items</span>${compact ? '<a class="text-button" href="#inventory">Open inventory ↗</a>' : `<div class="pagination"><label>Rows <select id="page-size" aria-label="Rows per page">${[5, 10, 25].map((size) => `<option ${size === pageSize ? "selected" : ""}>${size}</option>`).join("")}</select></label><button class="button" data-action="page-prev" aria-label="Previous inventory page" ${result.page <= 1 ? "disabled" : ""}>←</button><span>Page ${result.page} / ${result.pages}</span><button class="button" data-action="page-next" aria-label="Next inventory page" ${result.page >= result.pages ? "disabled" : ""}>→</button></div>`}</div>`;
}
function empty(title, copy) {
  return `<div class="empty">${icon("inventory")}<strong>${title}</strong><p>${copy}</p></div>`;
}
function requestRow(r, short = false) {
  return `<article class="request-card"><span class="activity-avatar">${initials(r.teacherName)}</span><div class="request-details"><strong>${escape(r.supplyName)} <span style="color:#94a18e;font-weight:400">× ${r.quantity}</span></strong><small>${escape(r.teacherName)} <span style="margin:0 5px">·</span> ${date(r.createdAt)}</small>${!short && r.note ? `<div class="request-note">${escape(r.note)}</div>` : ""}</div>${badge(r.status)}<div class="request-actions">${r.status === "Pending" ? (actor.role === "admin" ? `<button class="button" data-action="reject" data-id="${r.id}">Reject</button><button class="button primary" data-action="issue" data-id="${r.id}">Issue ${icon("arrow")}</button>` : `<button class="button" data-action="cancel" data-id="${r.id}">Cancel request</button>`) : ""}</div></article>${short ? "" : timeline(r)}`;
}
function overview() {
  const low = state.supplies
    .filter((s) => stockStatus(state, s) !== "In stock")
    .sort((a, b) => available(state, a) - available(state, b));
  const activity = [...mine()]
    .sort((a, b) =>
      (b.updatedAt || b.createdAt).localeCompare(a.updatedAt || a.createdAt),
    )
    .slice(0, 3);
  const person = state.teachers.find((t) => t.id === actor.id);
  return (
    heading(
      "YOUR WORKSPACE, AT A GLANCE",
      actor.role === "admin"
        ? "Office supplies, <span>in order.</span>"
        : `Welcome back, <span>${escape(person?.name.split(" ")[0])}.</span>`,
      "A clear view of your inventory. A smoother day for your team.",
      actionButton("export", "Export report", "export") +
        actionButton(
          actor.role === "admin" ? "new-supply" : "new-request",
          actor.role === "admin" ? "Add supply" : "New request",
          "plus",
          true,
        ),
    ) +
    metrics() +
    `<div class="content-grid"><div><section class="panel"><div class="panel-heading"><div><h2>Supply inventory</h2><p>The essentials that keep your office running.</p></div><a class="text-button" href="#inventory">View all ${icon("arrow")}</a></div><div id="inventory-results">${inventoryTable(true)}</div></section><section class="panel section-spacer"><div class="panel-heading"><div><h2>${actor.role === "admin" ? "Needs your approval" : "Your pending requests"}</h2><p>${pending().length} pending requisition${pending().length === 1 ? "" : "s"} in the queue.</p></div><a class="text-button" href="#requests">View all ${icon("arrow")}</a></div>${
      pending()
        .slice(0, 3)
        .map((r) => requestRow(r, true))
        .join("") ||
      empty("All caught up", "There are no pending requests right now.")
    }</section></div><aside class="right-column">${statusChart()}<section class="panel restock"><div class="panel-heading"><div class="restock-title">${icon("alert")}<h2>Time to restock</h2></div><span class="stock-mini">${low.length}</span></div><div class="restock-body">${
      low
        .slice(0, 3)
        .map(
          (s) =>
            `<div class="restock-item"><div><strong>${escape(s.name)}</strong><small>${escape(s.category)}</small></div><span class="stock-mini">${available(state, s)} left</span></div>`,
        )
        .join("") ||
      '<div class="restock-item"><strong>Everything is well stocked.</strong></div>'
    }</div><a href="#inventory" class="restock-footer">A little planning goes a long way. ${icon("arrow")}</a></section><section class="panel"><div class="panel-heading"><h2>Recent activity</h2><span style="color:#9aaa96">↗</span></div><div class="activity">${activity.map((r) => `<div class="activity-entry"><span class="activity-avatar">${initials(r.teacherName)}</span><div><p><strong>${escape(r.teacherName.split(" ")[0])}</strong> ${r.status === "Pending" ? "requested" : r.status.toLowerCase()} <strong>${r.quantity} ${escape(r.supplyName)}</strong></p><time>${date(r.updatedAt || r.createdAt)}</time></div></div>`).join("") || '<p class="subtitle">Your next action starts the story.</p>'}</div><a class="text-button activity-more" href="#history">See all activity ${icon("arrow")}</a></section></aside></div>`
  );
}
function inventory() {
  return (
    heading(
      "THE EVERYDAY ESSENTIALS",
      "Supply inventory",
      "Keep track of what’s available, what’s reserved, and what needs a top-up.",
      actionButton("export", "Export", "export") +
        (actor.role === "admin"
          ? actionButton("import-supplies", "Import CSV", "import") +
            actionButton("new-supply", "Add supply", "plus", true)
          : actionButton("new-request", "New request", "plus", true)),
    ) +
    `<section class="panel inventory-panel" aria-label="All supplies (${state.supplies.length})">${toolbar()}<div id="inventory-results">${inventoryTable()}</div></section>`
  );
}
function requests(history = false) {
  const rows = mine()
    .filter(
      (r) =>
        (!requestFilter || r.status === requestFilter) &&
        `${r.teacherName} ${r.supplyName}`
          .toLowerCase()
          .includes(query.toLowerCase()),
    )
    .sort((a, b) => b.createdAt.localeCompare(a.createdAt));
  return (
    heading(
      history ? "EVERY REQUEST HAS A STORY" : "KEEP THINGS MOVING",
      history ? "Activity & history" : "Requisitions",
      actor.role === "admin"
        ? "Review requests, issue supplies, and keep your team moving."
        : "Request the essentials and follow their progress.",
      (actor.role === "teacher"
        ? actionButton("new-request", "New request", "plus", true)
        : "") + actionButton("export", "Export history", "export"),
    ) +
    `<section class="panel"><div class="panel-heading"><div><h2>${history ? "Request history" : "Supply requests"}</h2><p>Pending → issued, rejected or cancelled. Every change is recorded.</p></div><span class="badge pending">${pending().length} pending</span></div>${toolbar("requests")}<div id="request-results">${rows.map((r) => requestRow(r)).join("") || empty("Nothing here yet", "Try a different filter, or create a new requisition.")}</div><div class="table-bottom">${rows.length} request${rows.length === 1 ? "" : "s"}<span>${actor.role === "teacher" ? "Only your requests are shown." : "All teachers · this workspace"}</span></div></section>`
  );
}
function teachers() {
  const rows = state.teachers.filter((t) =>
    `${t.name} ${t.id} ${t.department}`
      .toLowerCase()
      .includes(query.toLowerCase()),
  );
  return (
    heading(
      "THE PEOPLE BEHIND THE WORK",
      "Teachers",
      "A connected team starts with a well-organized directory.",
      actionButton("import-teachers", "Import CSV", "import") +
        actionButton("new-teacher", "Add teacher", "plus", true),
    ) +
    `<section class="panel"><div class="panel-heading"><div><h2>Teacher directory</h2><p>${state.teachers.length} people in this workspace.</p></div></div>${toolbar("teachers")}<div class="teacher-grid">${rows.map((t) => `<article class="teacher-card"><span class="avatar">${initials(t.name)}</span><h3>${escape(t.name)}</h3><p>${escape(t.department)}</p><p>${escape(t.email || "No email added")}</p><div class="card-actions"><small>${escape(t.id)}</small><button class="text-button" data-action="edit-teacher" data-id="${escape(t.id)}">Edit profile ↗</button></div></article>`).join("")}</div>${!rows.length ? empty("No teachers found", "Try a different search or add a teacher.") : ""}</section>`
  );
}
// After an older account logs in with its ID: a gentle offer to choose a username. "Later"
// hides it for this browser tab only.
function usernamePrompt() {
  if (!api || !token || actor.username || actor.mustChangePassword || !actor.id) return "";
  try {
    if (sessionStorage.getItem("officeflow-username-later") === actor.id) return "";
  } catch {}
  return `<div class="username-prompt" role="status"><div><strong>Choose a username</strong><span>You logged in with account ID ${escape(actor.id)}. A username is easier to remember; your password stays the same and the ID keeps working.</span></div><div class="username-prompt-actions"><button class="button" data-action="dismiss-username">Later</button><button class="button primary" data-action="choose-username">Choose username</button></div></div>`;
}
function connectionView() {
  if (connection === "connecting")
    return `<section class="panel" aria-busy="true"><div class="empty" role="status"><span class="spinner" aria-hidden="true"></span><strong>Connecting to OfficeFlow…</strong><p>Checking the OfficeFlow server on this computer.</p></div></section>`;
  if (connection === "stopped")
    return `<section class="stopped-view" role="status"><img src="./officeflow-icon.svg" alt="" width="56" height="56"><h1>OfficeFlow has stopped</h1><p>Your workspace is saved on this computer. You can close this tab.</p><p>To use OfficeFlow again, open it from the Start menu.</p></section>`;
  return `<section class="panel"><div class="empty" role="alert">${icon("alert")}<strong>OfficeFlow can't reach its server</strong><p>This page was opened from OfficeFlow at ${escape(location.origin)}, but OfficeFlow is not answering. It may have been closed: open OfficeFlow from the Start menu, then select Retry. Nothing was saved in this browser.</p><button class="button primary" data-action="retry-connection">Retry</button></div></section>`;
}
function render() {
  page = location.hash.slice(1).split("?")[0] || "overview";
  document.body.classList.toggle("is-stopped", connection === "stopped");
  if (connection !== "ready") {
    navigation();
    $("#breadcrumb").textContent =
      connection === "stopped" ? "Stopped" : "Connecting";
    $("#main").innerHTML = connectionView();
    lastRenderedPage = "";
    return;
  }
  if (
    !["overview", "inventory", "requests", "teachers", "history"].includes(
      page,
    ) ||
    (page === "teachers" && actor.role !== "admin")
  )
    page = "overview";
  navigation();
  $("#breadcrumb").textContent = {
    overview: "Overview",
    inventory: "Supply inventory",
    requests: "Requisitions",
    teachers: "Teachers",
    history: "Activity & history",
  }[page];
  $("#main").innerHTML =
    usernamePrompt() +
    {
      overview,
      inventory,
      requests,
      teachers,
      history: () => requests(true),
    }[page]();
  if (lastRenderedPage !== page) {
    $("#main").classList.remove("fade-in");
    void $("#main").offsetWidth;
    $("#main").classList.add("fade-in");
  } else $("#main").classList.remove("fade-in");
  lastRenderedPage = page;
  animateDashboard();
  $("#sidebar").classList.remove("open");
}
// locked: the setup and sign-in screens, which cannot be dismissed without signing in or quitting.
function modal(title, subtitle, body, locked = false) {
  closingAnimation?.cancel();
  closingAnimation = null;
  authLocked = locked;
  if (!locked) resumeAuth = null;
  document.body.classList.toggle("auth-screen", locked);
  $("#dialog").classList.toggle("auth-dialog", locked);
  $("#dialog-content").innerHTML =
    `<div class="dialog-heading">${locked ? '<img class="dialog-logo" src="./officeflow-icon.svg" alt="" width="40" height="40">' : ""}<div><h2 id="dialog-title">${title}</h2><p>${subtitle}</p></div>${locked ? "" : '<button class="icon-button" data-action="close" aria-label="Close dialog">×</button>'}</div><div class="dialog-body">${body}</div>`;
  if (!$("#dialog").open) $("#dialog").showModal();
}
const field = (name, label, value = "", type = "text", extra = "") =>
  `<div class="field ${extra.includes("full") ? "full" : ""}"><label for="field-${name}">${label}</label><input id="field-${name}" name="${name}" type="${type}" value="${escape(value)}" ${type === "number" ? 'min="0" max="1000000" step="1"' : 'maxlength="120"'} ${name === "email" ? "" : "required"} ${extra.replace("full", "")}></div>`;
const formEnd = (label, deleteAction = "", id = "") =>
  `<div class="form-error" role="alert"></div><div class="dialog-actions">${deleteAction ? `<button type="button" class="button danger" style="margin-right:auto" data-action="${deleteAction}" data-id="${escape(id)}">Delete</button>` : ""}<button class="button" type="button" data-action="close">Cancel</button><button class="button primary" type="submit">${label}</button></div></form>`;
function supplyDialog(id) {
  const item = state.supplies.find((s) => s.id === id);
  modal(
    item ? "Edit supply" : "A new office essential",
    item
      ? "Update stock and item details. Reserved quantities stay protected."
      : "Add an item to your workspace inventory.",
    `<form data-form="saveSupply"><input type="hidden" name="id" value="${escape(item?.id || "")}"><div class="form-grid">${field("name", "Item name", item?.name || "", "text", "full")}<div class="field"><label for="field-category">Category</label><select name="category" id="field-category">${categories.map((c) => `<option ${item?.category === c ? "selected" : ""}>${escape(c)}</option>`).join("")}</select></div>${field("unit", "Unit", item?.unit || "pieces")}${field("quantity", "Quantity on hand", item?.quantity ?? 0, "number")}${field("threshold", "Low-stock threshold", item?.threshold ?? 5, "number")}</div>${formEnd(item ? "Save changes" : "Add supply", item ? "delete-supply" : "", item?.id)}`,
  );
}
function teacherDialog(id) {
  const teacher = state.teachers.find((t) => t.id === id);
  modal(
    teacher ? "Edit teacher" : "Welcome someone new",
    api
      ? teacher
        ? "Changes keep this teacher's password."
        : "OfficeFlow creates a temporary password for this teacher and shows it once after saving."
      : "Demo profiles contain no private credentials.",
    `<form data-form="saveTeacher"><input type="hidden" name="edit" value="${teacher ? "true" : ""}"><div class="form-grid">${field("id", "Teacher ID", teacher?.id || "", "text", teacher ? "readonly" : "")}${field("name", "Full name", teacher?.name || "")}${field("department", "Department", teacher?.department || "")}${field("email", "Email (optional)", teacher?.email || "", "email")}</div>${formEnd(teacher ? "Save changes" : "Add teacher", teacher ? "delete-teacher" : "", teacher?.id)}`,
  );
}
function requestDialog(id) {
  const list = state.supplies.filter((s) => available(state, s) > 0);
  if (id && !list.some((item) => item.id === id)) {
    toast(
      "This item has no available stock. Choose another item or ask your administrator to restock.",
    );
    return;
  }
  if (!list.length) {
    toast("There are no available supplies to request.");
    return;
  }
  modal(
    "Make room for good work",
    "Choose what you need. Stock is reserved while your request is reviewed.",
    `<form data-form="request"><div class="form-grid"><div class="field full"><label for="field-supplyId">Supply item</label><select id="field-supplyId" name="supplyId">${list.map((s) => `<option value="${escape(s.id)}" ${s.id === id ? "selected" : ""}>${escape(s.name)} · ${available(state, s)} ${escape(s.unit)} available</option>`).join("")}</select></div>${field("quantity", "Quantity", 1, "number")}<div class="field full"><label for="field-note">A note for your admin (optional)</label><textarea id="field-note" name="note" maxlength="240" placeholder="What will these supplies help you do?"></textarea></div></div>${formEnd("Submit request")}`,
  );
}
function identities() {
  if (api) {
    if (connection !== "ready") toast("OfficeFlow is not connected yet.");
    else if (token) accountDialog();
    else loginDialog();
    return;
  }
  modal(
    "Take a different seat",
    "Explore both sides of the workflow. All profiles below are fictional.",
    `<div class="identity-grid"><button class="identity-option" data-action="identity" data-id="admin"><span class="avatar">AD</span><span><strong>Workspace administrator</strong><small>Manage inventory, teachers and approvals</small></span></button>${state.teachers.map((t) => `<button class="identity-option" data-action="identity" data-id="${escape(t.id)}"><span class="avatar">${initials(t.name)}</span><span><strong>${escape(t.name)}</strong><small>${escape(t.department)} · teacher</small></span></button>`).join("")}</div>`,
  );
}
function importDialog(type) {
  modal(
    `Import ${type}`,
    "Add several records in one step. The entire file is checked before anything changes.",
    `<form data-form="import" data-type="${type}"><div class="import-guide">UTF-8 CSV · up to 500 rows · 200 KB maximum.<br>Use this exact header:<code>${type === "supplies" ? "name,category,quantity,threshold,unit" : "id,name,department,email"}</code></div><div class="field full" style="margin-top:18px"><label for="csv-file">CSV file</label><input id="csv-file" name="file" type="file" accept=".csv,text/csv" required><small>Existing IDs or names are rejected. Import creates new records.</small></div>${formEnd("Import records")}`,
  );
}
function help() {
  modal(
    "A place for everything.",
    "Meet OfficeFlow — your office inventory workspace.",
    `<div class="help-copy"><p><strong>Inventory without the guesswork.</strong> Available stock excludes units reserved for pending requests. Issuing a request deducts stock once; rejecting or cancelling releases the reservation.</p><p><strong>Two sides of one workflow.</strong> Administrators manage supplies and teachers. Teachers request supplies and see their own history.</p><p>${api ? "You are connected to the Java/JDBC service. Access and stock rules are checked on the server." : "This GitHub Pages demo uses fictional sample records saved in this browser. Role switching demonstrates workflows; it is not secure authentication. No data is sent to a Java server."}</p><p>Originally Java coursework, January 2025. Rebuilt as a web application in 2026.</p></div>`,
  );
}
function accountDialog() {
  modal(
    "Your account",
    actor.username
      ? `Logged in as ${escape(actor.username)} (account ID ${escape(actor.id)}).`
      : `Logged in with account ID ${escape(actor.id)}. Choose a username to log in with next time.`,
    `<div class="identity-grid"><button class="button${actor.username ? "" : " primary"}" data-action="choose-username">${actor.username ? "Change username" : "Choose a username"}</button><button class="button" data-action="change-password">Change password</button>${actor.role === "admin" ? '<button class="button" data-action="reset-password">Reset teacher password</button>' : ""}<button class="button" data-action="logout">Log out</button><button class="button" data-action="quit">Quit OfficeFlow</button></div>`,
  );
}
const SETUP_PROBLEMS = {
  expired:
    "This setup screen has expired. For your security it works for 15 minutes after OfficeFlow starts.",
  used: "This setup screen was already used.",
  locked: "This setup screen was locked after too many attempts.",
  unavailable: "This setup screen is no longer available.",
  missing: "This page was opened without OfficeFlow's setup link.",
};
// First run: the browser creates the administrator password with OfficeFlow.exe's one-time token.
function setupScreen(status) {
  const problem = !setupToken ? "missing" : status === "ready" ? "" : status;
  resumeAuth = () => setupScreen(status);
  if (problem) {
    modal(
      "Set up OfficeFlow",
      "OfficeFlow needs an administrator before anyone can log in.",
      `<div class="setup-problem" role="alert"><strong>${escape(SETUP_PROBLEMS[problem] || SETUP_PROBLEMS.unavailable)}</strong><p>Quit OfficeFlow, then open it again from the Start menu to get a new setup screen. Nothing has been created yet.</p></div><div class="dialog-actions"><button class="button primary" data-action="quit">Quit OfficeFlow</button></div>`,
      true,
    );
    return;
  }
  modal(
    "Create account",
    "Create the administrator account for this computer’s OfficeFlow workspace.",
    `<form data-form="setup"><div class="form-grid">${field("username", "Username", "", "text", 'full autocomplete="username" autocapitalize="none" spellcheck="false" minlength="3" maxlength="32" aria-describedby="username-hint"')}<p class="field-hint full" id="username-hint">3–32 characters: start with a letter, then letters, numbers, dots, dashes or underscores.</p>${field("password", "Password", "", "password", 'full autocomplete="new-password" minlength="15" maxlength="120" aria-describedby="password-hint"')}${field("confirmPassword", "Confirm password", "", "password", 'full autocomplete="new-password" minlength="15" maxlength="120"')}<p class="field-hint full" id="password-hint">Use a passphrase of 15–120 characters, such as a few unrelated words. Spaces are fine. Let your browser save it: OfficeFlow cannot show or recover it.</p></div><div class="form-error" role="alert"></div><div class="dialog-actions"><button type="button" class="button quiet" data-action="quit">Quit OfficeFlow</button><button class="button primary" type="submit">Create account</button></div></form>`,
    true,
  );
  $("#field-username").focus();
}
async function setupStatus() {
  try {
    const response = await fetch("./api/setup", {
      headers: { Accept: "application/json" },
      cache: "no-store",
    });
    return response.ok ? await response.json() : null;
  } catch {
    return null;
  }
}
function quitDialog() {
  const back = resumeAuth;
  modal(
    "Quit OfficeFlow?",
    "OfficeFlow stops on this computer and your workspace is saved. To use it again, open OfficeFlow from the Start menu.",
    `<div class="dialog-actions"><button class="button" data-action="keep-working">Keep working</button><button class="button primary" data-action="confirm-quit">Quit OfficeFlow</button></div>`,
  );
  resumeAuth = back;
}
async function quit() {
  await apiCall("quit", {});
  forgetSetupToken();
  token = "";
  try {
    sessionStorage.removeItem("officeflow-token");
  } catch {}
  connection = "stopped";
  closingAnimation?.cancel();
  await closeModal();
  if ($("#dialog").open) $("#dialog").close();
  render();
}
function passwordDialog(reset = false, forced = false) {
  if (reset && !state.teachers.length) {
    toast("Add a teacher before resetting a password.");
    return;
  }
  // forced: signed in with a temporary password; the server allows nothing else until it changes.
  const end = forced
    ? `<div class="form-error" role="alert"></div><div class="dialog-actions"><button class="button" type="button" data-action="logout">Log out</button><button class="button primary" type="submit">Change password</button></div></form>`
    : formEnd(reset ? "Reset password" : "Change password");
  modal(
    forced
      ? "Choose your own password"
      : reset
        ? "Reset teacher password"
        : "Change password",
    forced
      ? "You logged in with a temporary password. Choose your own passphrase of 15–120 characters to continue."
      : reset
        ? "Use 15–120 characters. This is a temporary password: the teacher must choose their own at their next login. Their sessions end now."
        : "Use a passphrase of 15–120 characters; spaces are fine. All sessions for this account end after saving.",
    `<form data-form="${reset ? "reset-password" : "change-password"}"><div class="form-grid">${reset ? `<div class="field full"><label for="field-id">Teacher</label><select id="field-id" name="id">${state.teachers.map((t) => `<option value="${escape(t.id)}">${escape(t.name)} (${escape(t.id)})</option>`).join("")}</select></div>` : field("currentPassword", forced ? "Temporary password" : "Current password", "", "password", 'full autocomplete="current-password"')}${field("newPassword", "New password", "", "password", 'full minlength="15" autocomplete="new-password"')}${field("confirmPassword", "Confirm new password", "", "password", 'full minlength="15" autocomplete="new-password"')}</div>${end}`,
  );
}
function clearSession() {
  token = "";
  sessionStorage.removeItem("officeflow-token");
  state = { supplies: [], teachers: [], requests: [] };
  actor = { role: "teacher", id: "" };
  query = category = requestFilter = stockFilter = "";
  tablePage = 1;
  render();
}
function loginDialog(name = "") {
  resumeAuth = () => loginDialog(name);
  modal(
    "Log in",
    "Log in to OfficeFlow on this computer.",
    `<form data-form="login"><div class="form-grid">${field("username", "Username", name, "text", 'full autocomplete="username" autocapitalize="none" spellcheck="false" aria-describedby="login-hint"')}<p class="field-hint full" id="login-hint">Accounts created before usernames can use their account ID, such as 001.</p>${field("password", "Password", "", "password", 'full autocomplete="current-password"')}</div><div class="form-error" role="alert"></div><button type="button" class="text-button forgot-link" data-action="forgot-login">Forgot your login?</button><div class="dialog-actions"><button type="button" class="button quiet" data-action="quit">Quit OfficeFlow</button><button class="button primary" type="submit">Log in</button></div></form>`,
    true,
  );
  $(name ? "#field-password" : "#field-username").focus();
}
// General reminders only: nothing here depends on, or reveals, any particular account.
function forgotLoginDialog() {
  modal(
    "Forgot your login?",
    "A few reminders that usually help.",
    `<ul class="login-reminders"><li><strong>Username.</strong> Use the username you chose when the account was created, or later under Account. Usernames are not case-sensitive.</li><li><strong>Account ID.</strong> Accounts from before usernames can still log in with their account ID. The first administrator’s ID is <code>001</code>; teachers use the ID their administrator gave them.</li><li><strong>Saved passwords.</strong> Your browser or password manager may have saved the password for 127.0.0.1. Look there under OfficeFlow or 127.0.0.1.</li><li><strong>Teachers.</strong> Your administrator can set a temporary password for you.</li></ul><div class="dialog-actions"><button class="button primary" data-action="back-to-login">Back to log in</button></div>`,
    true,
  );
}
function usernameDialog() {
  modal(
    actor.username ? "Change username" : "Choose a username",
    actor.username
      ? "Your username is how you log in. Your password stays the same."
      : `You log in with account ID ${escape(actor.id)} today. A username is easier to remember; the ID keeps working too.`,
    `<form data-form="username"><div class="form-grid">${field("username", "Username", actor.username || "", "text", 'full autocomplete="username" autocapitalize="none" spellcheck="false" minlength="3" maxlength="32"')}<p class="field-hint full">3–32 characters: start with a letter, then letters, numbers, dots, dashes or underscores. It must not be in use.</p></div>${formEnd("Save username")}`,
  );
}
function download() {
  let rows, name;
  if (page === "inventory" || page === "overview") {
    name = "inventory";
    rows = [
      [
        "id",
        "name",
        "category",
        "on_hand",
        "reserved",
        "available",
        "unit",
        "status",
      ],
      ...filteredSupplies().map((s) => [
        s.id,
        s.name,
        s.category,
        s.quantity,
        s.quantity - available(state, s),
        available(state, s),
        s.unit,
        stockStatus(state, s),
      ]),
    ];
  } else {
    name = "requisitions";
    rows = [
      ["id", "teacher", "supply", "quantity", "status", "created_at", "note"],
      ...mine().map((r) => [
        r.id,
        r.teacherName,
        r.supplyName,
        r.quantity,
        r.status,
        r.createdAt,
        r.note,
      ]),
    ];
  }
  const url = URL.createObjectURL(
    new Blob(["\uFEFF" + csv(rows)], { type: "text/csv;charset=utf-8" }),
  );
  const link = document.createElement("a");
  link.href = url;
  link.download = `officeflow-${name}.csv`;
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
  toast("Your report is ready.");
}
document.addEventListener("click", async (event) => {
  const button = event.target.closest("[data-action]");
  if (!button) return;
  const { action, id } = button.dataset;
  try {
    if (action === "supply-details") {
      supplyDetails(id);
      return;
    }
    if (action === "clear-filters") {
      query = "";
      category = "";
      stockFilter = "";
      sort = "name";
      tablePage = 1;
      if (location.hash.includes("?stock=")) location.hash = "inventory";
      else render();
      return;
    }
    if (action === "page-prev" || action === "page-next") {
      tablePage += action === "page-next" ? 1 : -1;
      $("#inventory-results").innerHTML = inventoryTable();
      $(".pagination").setAttribute("tabindex", "-1");
      $(".pagination").focus();
      return;
    }
    if (action === "quit") {
      quitDialog();
      return;
    }
    if (action === "forgot-login") {
      forgotLoginDialog();
      return;
    }
    if (action === "back-to-login") {
      loginDialog();
      return;
    }
    if (action === "choose-username") {
      usernameDialog();
      return;
    }
    if (action === "dismiss-username") {
      try {
        sessionStorage.setItem("officeflow-username-later", actor.id);
      } catch {}
      render();
      return;
    }
    if (action === "keep-working") {
      if (resumeAuth) resumeAuth();
      else closeModal();
      return;
    }
    if (action === "confirm-quit") {
      button.disabled = true;
      button.innerHTML = '<span class="spinner" aria-hidden="true"></span> Stopping…';
      try {
        await quit();
      } finally {
        button.disabled = false;
      }
      return;
    }
    if (action === "retry-connection") connect();
    else if (action === "change-password") passwordDialog();
    else if (action === "reset-password") passwordDialog(true);
    else if (action === "logout") {
      await apiCall("logout", {});
      clearSession();
      loginDialog();
      toast("Logged out. Your session has ended.");
    } else if (action === "close") closeModal();
    else if (action === "new-supply" || action === "edit-supply")
      supplyDialog(id);
    else if (action === "new-teacher" || action === "edit-teacher")
      teacherDialog(id);
    else if (action === "new-request" || action === "request-item")
      requestDialog(id);
    else if (action === "help") help();
    else if (action === "export") download();
    else if (action.startsWith("import-")) importDialog(action.split("-")[1]);
    else if (action === "identity") {
      actor = { role: id === "admin" ? "admin" : "teacher", id };
      closeModal();
      query = "";
      location.hash = "overview";
      render();
      toast("Workspace switched.");
    } else if (
      ["issue", "reject", "cancel", "delete-supply", "delete-teacher"].includes(
        action,
      )
    ) {
      const mapped =
        { "delete-supply": "deleteSupply", "delete-teacher": "deleteTeacher" }[
          action
        ] || action;
      modal(
        action.startsWith("delete")
          ? "Delete this record?"
          : `${action === "issue" ? "Issue supplies" : action === "reject" ? "Reject request" : "Cancel request"}?`,
        action === "issue"
          ? "This deducts the requested quantity and marks it as issued."
          : action.startsWith("delete")
            ? "Historical request records will be kept. This cannot be undone."
            : "Reserved stock will become available again.",
        `<form data-form="confirm" data-command="${mapped}" data-id="${escape(id)}">${formEnd("Confirm")}</form>`,
      );
    }
  } catch (error) {
    toast(error.message);
  }
});
document.addEventListener("submit", async (event) => {
  const form = event.target.closest("form[data-form]");
  if (!form) return;
  event.preventDefault();
  const errorBox = form.querySelector(".form-error");
  errorBox.textContent = "";
  const submit = form.querySelector("[type=submit]");
  submit.disabled = true;
  const submitLabel = submit.innerHTML;
  submit.innerHTML = '<span class="spinner" aria-hidden="true"></span> Saving…';
  form.setAttribute("aria-busy", "true");
  let passwords = [];
  try {
    const data = Object.fromEntries(new FormData(form));
    if (form.dataset.form === "setup") {
      if (data.password !== data.confirmPassword)
        throw Error("The passwords do not match.");
      let response;
      try {
        response = await apiCall("setup", {
          token: setupToken,
          username: data.username,
          password: data.password,
          confirmPassword: data.confirmPassword,
        });
      } catch (error) {
        if (error.code !== "SETUP_TOKEN_INVALID") throw error;
        setupScreen((await setupStatus())?.status || "unavailable");
        return;
      }
      forgetSetupToken();
      token = response.token;
      sessionStorage.setItem("officeflow-token", token);
      actor = response.actor;
      state = await apiCall("state");
      closeModal();
      render();
      toast(
        `Your account is ready. You’re logged in as ${actor.username}.`,
        "success",
      );
      return;
    }
    if (form.dataset.form === "username") {
      const response = await apiCall("username", { username: data.username });
      actor = { ...actor, username: response.actor.username };
      closeModal();
      render();
      toast(`Username saved. Log in as ${actor.username} next time.`, "success");
      return;
    }
    if (form.dataset.form === "login") {
      const response = await apiCall("login", data);
      token = response.token;
      sessionStorage.setItem("officeflow-token", token);
      actor = response.actor;
      if (actor.mustChangePassword) {
        passwordDialog(false, true);
        return;
      }
      state = await apiCall("state");
    } else if (
      ["change-password", "reset-password"].includes(form.dataset.form)
    ) {
      if (data.newPassword !== data.confirmPassword)
        throw Error("The new passwords do not match.");
      const reset = form.dataset.form === "reset-password";
      await apiCall(reset ? "password/reset" : "password/change", data);
      if (!reset) {
        clearSession();
        loginDialog();
        toast("Password changed. Log in with your new password.");
        return;
      }
      closeModal();
      toast(
        "Temporary password set. Share it privately; the teacher chooses their own at sign-in.",
      );
      return;
    } else if (form.dataset.form === "confirm")
      passwords = await save(form.dataset.command, { id: form.dataset.id });
    else if (form.dataset.form === "import") {
      const file = data.file;
      if (file.size > 200000) throw Error("CSV must be smaller than 200 KB.");
      const source = await file.text();
      if (api)
        passwords = commit(
          await apiCall("import", {
            type: form.dataset.type,
            csv: source,
          }),
        );
      else {
        const updated = importCSV(state, actor, form.dataset.type, source);
        localStorage.setItem(STORE_KEY, JSON.stringify(updated));
        state = updated;
      }
    } else {
      if ("edit" in data) data.edit = data.edit === "true";
      passwords = await save(form.dataset.form, data);
      // Briefly highlights the saved row once the table is drawn again.
      if (form.dataset.form === "saveSupply") justSaved = data.name;
    }
    closeModal();
    render();
    justSaved = "";
    toast(
      form.dataset.form === "saveSupply"
        ? `Saved “${data.name}”. Your inventory is up to date.`
        : "All set. Your workspace is up to date.",
      "success",
    );
    if (passwords.length) temporaryPasswordsDialog(passwords);
  } catch (error) {
    errorBox.textContent = error.message;
  } finally {
    submit.disabled = false;
    submit.innerHTML = submitLabel;
    form.removeAttribute("aria-busy");
  }
});
document.addEventListener("input", (event) => {
  if (event.target.id === "search") {
    query = event.target.value;
    tablePage = 1;
    if (page === "inventory" || page === "overview")
      $("#inventory-results").innerHTML = inventoryTable(page === "overview");
    else {
      const start = event.target.selectionStart;
      render();
      $("#search").focus();
      $("#search").setSelectionRange(start, start);
    }
  }
});
document.addEventListener("change", (event) => {
  if (event.target.id === "page-size") {
    pageSize = Number(event.target.value);
    tablePage = 1;
    $("#inventory-results").innerHTML = inventoryTable();
  }
  if (event.target.id === "category") {
    category = event.target.value;
    tablePage = 1;
    $("#inventory-results").innerHTML = inventoryTable(page === "overview");
  }
  if (event.target.id === "sort") {
    sort = event.target.value;
    tablePage = 1;
    $("#inventory-results").innerHTML = inventoryTable(page === "overview");
  }
  if (event.target.id === "request-filter") {
    requestFilter = event.target.value;
    render();
  }
});
function readRoute() {
  const route = location.hash.slice(1).split("?");
  const filters = new URLSearchParams(route[1] || "");
  stockFilter = filters.get("stock") === "low" ? "low" : "";
  requestFilter = ["Pending", "Issued", "Rejected", "Cancelled"].includes(
    filters.get("status"),
  )
    ? filters.get("status")
    : "";
}
window.addEventListener("hashchange", () => {
  query = "";
  category = "";
  tablePage = 1;
  readRoute();
  render();
  window.scrollTo(0, 0);
});
readRoute();
$("#identity").onclick = identities;
$("#switch-role").onclick = identities;
$("#help").onclick = help;
$("#menu-toggle").onclick = () => $("#sidebar").classList.toggle("open");
$("#dialog").addEventListener("click", (e) => {
  if (e.target === $("#dialog") && !authLocked) {
    const r = $("#dialog").getBoundingClientRect();
    if (
      e.clientX < r.left ||
      e.clientX > r.right ||
      e.clientY < r.top ||
      e.clientY > r.bottom
    )
      closeModal();
  }
});
$("#reset-demo").onclick = () =>
  modal(
    "Start with a clean desk?",
    "This replaces changes in this browser with the original sample records.",
    `<div class="dialog-actions"><button class="button" data-action="close">Keep my changes</button><button class="button primary" id="confirm-reset">Reset demo</button></div>`,
  );
document.addEventListener("click", (event) => {
  if (event.target.id === "confirm-reset" && !JAVA_MODE) {
    try {
      const fresh = seed();
      localStorage.setItem(STORE_KEY, JSON.stringify(fresh));
      state = fresh;
      actor = { role: "admin", id: "admin" };
      closeModal();
      render();
      toast("A fresh workspace is ready.");
    } catch {
      toast("Browser storage is unavailable.");
    }
  }
});
// Java mode: show "Connecting…" until the server answers, then sign-in or the real workspace.
// It never falls back to the browser sample workspace; a failure shows an error with Retry.
async function connect() {
  connection = "connecting";
  render();
  let healthy = false;
  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 8000);
    const response = await fetch("./api/health", {
      headers: { Accept: "application/json" },
      cache: "no-store",
      signal: controller.signal,
    });
    clearTimeout(timer);
    healthy =
      response.ok &&
      Boolean(response.headers.get("content-type")?.includes("application/json")) &&
      (await response.json()).service === "officeflow";
  } catch {
    healthy = false;
  }
  if (!healthy) {
    connection = "error";
    render();
    return;
  }
  connection = "ready";
  if (!token) {
    clearSession();
    // A new workspace shows "Set up OfficeFlow"; returning users land on sign-in.
    const setup = await setupStatus();
    if (setup?.required) setupScreen(setup.status);
    else {
      forgetSetupToken();
      loginDialog();
    }
    return;
  }
  try {
    const session = await apiCall("session");
    actor = session.actor;
    if (actor.mustChangePassword) {
      render();
      passwordDialog(false, true);
      return;
    }
    state = await apiCall("state");
    render();
  } catch (error) {
    if (error.offline) {
      connection = "error";
      render();
      return;
    }
    clearSession();
    loginDialog();
  }
}
if (JAVA_MODE) {
  $("#mode-badge").innerHTML = "<i></i> Java workspace";
  $("#demo-banner").querySelector("span").textContent =
    "Your OfficeFlow workspace · saved on this computer · server-checked access";
  $("#switch-role").textContent = "Account";
  $("#reset-demo").hidden = true;
  $("#quit-officeflow").hidden = false;
  $("#quit-officeflow").onclick = quitDialog;
  document.documentElement.dataset.javaReady = "";
  connect();
} else {
  render();
  if (loadWarning) toast(loadWarning);
}

function timeline(request) {
  const timestamp = (value) =>
    new Date(value).toLocaleString("en-GB", {
      dateStyle: "medium",
      timeStyle: "short",
    });
  return `<details class="request-timeline"><summary>Request timeline</summary><ol><li><strong>Requested by ${escape(request.teacherName)}</strong><time>${timestamp(request.createdAt)}</time></li>${request.status === "Pending" ? '<li class="timeline-pending"><strong>Awaiting administrator review</strong><span>Stock is reserved.</span></li>' : `<li><strong>${escape(request.status)}</strong><time>${request.updatedAt ? timestamp(request.updatedAt) : "Completion time not recorded"}</time></li>`}</ol></details>`;
}
function statusChart() {
  const counts = statusCounts(mine()),
    total = mine().length;
  let offset = 0;
  const colors = [
    "var(--chart-pending)",
    "var(--chart-issued)",
    "var(--chart-rejected)",
    "var(--chart-cancelled)",
  ];
  const segments = counts.map((entry, index) => {
    const start = offset;
    offset += total ? (entry.count / total) * 100 : 0;
    return `${colors[index]} ${start}% ${offset}%`;
  });
  return `<section class="panel status-panel"><div class="panel-heading"><div><h2>Request snapshot</h2><p>Current status · ${actor.role === "admin" ? "all teachers" : "your requests"}</p></div></div><div class="status-content"><div class="status-donut" role="img" aria-label="${counts.map((x) => x.count + " " + x.status).join(", ")}" style="background:${total ? "conic-gradient(" + segments.join(",") + ")" : "var(--line)"}"><div><strong>${total}</strong><span>requests</span></div></div><div class="chart-legend">${counts.map((entry, i) => `<a href="#requests?status=${entry.status}"><i style="background:${colors[i]}"></i>${entry.status}<strong>${entry.count}</strong></a>`).join("")}</div></div>${total ? "" : '<p class="chart-empty">Your first request starts the picture.</p>'}</section>`;
}
function supplyDetails(id) {
  const item = state.supplies.find((item) => item.id === id);
  if (!item) {
    toast("This supply is no longer available.");
    return;
  }
  const parts = stockParts(item.quantity, available(state, item));
  const related = mine()
    .filter((request) => request.supplyId === id)
    .sort((a, b) => b.createdAt.localeCompare(a.createdAt));
  modal(
    escape(item.name),
    escape(item.category) + " · " + escape(item.unit),
    `<section class="supply-detail"><div class="detail-stock"><div><strong>${parts.available}</strong><span>Available</span></div><div><strong>${parts.reserved}</strong><span>Reserved</span></div><div><strong>${parts.onHand}</strong><span>On hand</span></div></div><div class="stock-track detail-track"><span style="width:${parts.percent}%"></span></div><p class="detail-description">${badge(stockStatus(state, item))} Low-stock threshold: ${item.threshold}</p><h3>${actor.role === "admin" ? "Requisition history" : "Your requisition history"}</h3>${
      related
        .slice(0, 6)
        .map(
          (request) =>
            `<div class="detail-request"><div><strong>${escape(request.teacherName)} · ${request.quantity} ${escape(item.unit)}</strong><small>${date(request.createdAt)}</small></div>${badge(request.status)}</div>`,
        )
        .join("") ||
      '<p class="detail-description">No requests for this item yet.</p>'
    }<div class="dialog-actions"><button class="button" data-action="close">Close</button><button class="button primary" data-action="${actor.role === "admin" ? "edit-supply" : "request-item"}" data-id="${escape(item.id)}">${actor.role === "admin" ? "Edit supply" : "Request supply"}</button></div></section>`,
  );
}
function animateDashboard() {
  const key = actor.role + actor.id;
  if (page !== "overview" || animatedWorkspaces.has(key)) return;
  animatedWorkspaces.add(key);
  if (matchMedia("(prefers-reduced-motion: reduce)").matches) return;
  $(".metrics")?.classList.add("metrics-enter");
  document.querySelectorAll("[data-count]").forEach((element) => {
    const target = Number(element.dataset.count),
      start = performance.now();
    const tick = (time) => {
      if (
        !element.isConnected ||
        matchMedia("(prefers-reduced-motion: reduce)").matches
      ) {
        element.textContent = String(target).padStart(2, "0");
        return;
      }
      const fraction = Math.min(1, (time - start) / 550);
      element.textContent = String(
        Math.round(target * (1 - Math.pow(1 - fraction, 3))),
      ).padStart(2, "0");
      if (fraction < 1) requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  });
}
function networkLoading(path) {
  const main = $("#main");
  let skeleton;
  if (path === "state") {
    skeleton = document.createElement("div");
    skeleton.className = "loading-overlay";
    skeleton.setAttribute("role", "status");
    skeleton.innerHTML =
      '<span class="screen-reader">Loading workspace</span><div class="skeleton-line"></div><div class="skeleton-cards"><i></i><i></i><i></i><i></i></div><div class="skeleton-table"></div>';
    main.append(skeleton);
    main.setAttribute("aria-busy", "true");
  }
  const progress = document.createElement("div");
  progress.className = "network-progress";
  progress.setAttribute("aria-label", "Working");
  document.body.append(progress);
  return () => {
    progress.remove();
    skeleton?.remove();
    if (skeleton) main.removeAttribute("aria-busy");
  };
}

async function closeModal() {
  const dialog = $("#dialog");
  authLocked = false;
  resumeAuth = null;
  document.body.classList.remove("auth-screen");
  dialog.classList.remove("auth-dialog");
  if (!dialog.open) return;
  if (matchMedia("(prefers-reduced-motion: reduce)").matches) {
    dialog.close();
    return;
  }
  closingAnimation?.cancel();
  const animation = dialog.animate(
    [
      { opacity: 1, transform: "translateY(0)" },
      { opacity: 0, transform: "translateY(5px)" },
    ],
    { duration: 130, easing: "ease-in" },
  );
  closingAnimation = animation;
  try {
    // A page that is not being painted may never finish the animation; close anyway.
    await Promise.race([
      animation.finished,
      new Promise((resolve) => setTimeout(resolve, 400)),
    ]);
  } catch {
    return;
  }
  if (closingAnimation === animation) {
    dialog.close();
    closingAnimation = null;
  }
}
$("#dialog").addEventListener("cancel", (event) => {
  event.preventDefault();
  if (!authLocked) closeModal();
});
