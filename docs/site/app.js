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
          "OfficeFlow's server is not answering. Check that the OfficeFlow window is still open, then try again.",
        ),
        { offline: true },
      );
    }
    const result = await response.json();
    if (!response.ok && result.code === "SESSION_EXPIRED") {
      clearSession();
      loginDialog();
      toast("Your session has ended. Please sign in again.");
    }
    if (!response.ok && result.code === "PASSWORD_CHANGE_REQUIRED")
      passwordDialog(false, true);
    if (!response.ok)
      throw new Error(
        result.error || "The server could not complete this request.",
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
function toast(message) {
  $("#toast").textContent = message;
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
  return `<div class="filter-summary" role="status">${list.length} matching item${list.length === 1 ? "" : "s"}${stockFilter ? " · Low or out of stock" : ""}<button class="text-button" data-action="clear-filters">Clear filters</button></div>
  <div class="table-wrap"><table><caption class="screen-reader">Supply inventory with available quantities</caption><thead><tr><th>SUPPLY ITEM</th><th>CATEGORY</th><th>AVAILABLE / ON HAND</th><th>STATUS</th><th><span class="screen-reader">Actions</span></th></tr></thead><tbody>${visible
    .map((item) => {
      const parts = stockParts(item.quantity, available(state, item));
      return `<tr><td><div class="item-cell">${itemIcon(item)}<div><button class="item-detail-link" data-action="supply-details" data-id="${escape(item.id)}">${escape(item.name)}</button><div class="item-id">${escape(item.id.length > 15 ? "SUP-" + item.id.slice(-6).toUpperCase() : item.id)}</div></div></div></td><td class="category-text">${escape(item.category)}</td><td><span class="qty">${parts.available}<small>/ ${parts.onHand} ${escape(item.unit)}</small></span><div class="stock-track" role="img" aria-label="${parts.available} available, ${parts.reserved} reserved, ${parts.onHand} on hand"><span style="width:${parts.percent}%"></span></div><div class="item-id">${parts.reserved} reserved</div></td><td>${badge(stockStatus(state, item))}</td><td><button class="row-action" data-action="${actor.role === "admin" ? "edit-supply" : "request-item"}" data-id="${escape(item.id)}" title="${actor.role === "admin" ? "Edit inventory" : "Request supplies"}" aria-label="${actor.role === "admin" ? "Edit" : "Request"} ${escape(item.name)}">${actor.role === "admin" ? "↗" : "＋"}</button></td></tr>`;
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
    `<div class="content-grid"><div><section class="panel"><div class="panel-heading"><div><h2>Supply inventory</h2><p>The essentials that keep your office running.</p></div><a class="text-button" href="#inventory">View all ${icon("arrow")}</a></div>${toolbar()}<div id="inventory-results">${inventoryTable(true)}</div></section><section class="panel section-spacer"><div class="panel-heading"><div><h2>${actor.role === "admin" ? "Needs your approval" : "Your pending requests"}</h2><p>${pending().length} pending requisition${pending().length === 1 ? "" : "s"} in the queue.</p></div><a class="text-button" href="#requests">View all ${icon("arrow")}</a></div>${
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
    }</div><a href="#inventory" class="restock-footer">A little planning goes a long way. ${icon("arrow")}</a></section><section class="panel"><div class="panel-heading"><h2>Recent activity</h2><span style="color:#9aaa96">↗</span></div><div class="activity">${activity.map((r) => `<div class="activity-entry"><span class="activity-avatar">${initials(r.teacherName)}</span><div><p><strong>${escape(r.teacherName.split(" ")[0])}</strong> ${r.status === "Pending" ? "requested" : r.status.toLowerCase()} <strong>${r.quantity} ${escape(r.supplyName)}</strong></p><time>${date(r.updatedAt || r.createdAt)}</time></div></div>`).join("") || '<p class="subtitle">Your next action starts the story.</p>'}</div><a class="text-button" href="#history" style="margin:16px 22px 20px">See all activity ${icon("arrow")}</a></section><section class="welcome-card"><div class="eyebrow">SMALL THINGS. BIG DIFFERENCE.</div><h3>A well-stocked office.<br>A well-supported team.</h3><p>Less time managing supplies.<br>More time doing what matters.</p><button class="text-button" data-action="help">Meet your workspace ${icon("arrow")}</button><span class="welcome-decoration"></span></section></aside></div>`
  );
}
function inventory() {
  return (
    heading(
      "THE EVERYDAY ESSENTIALS",
      "Supply inventory",
      "Keep track of what’s available, what’s reserved, and what needs a top-up.",
      actor.role === "admin"
        ? actionButton("import-supplies", "Import CSV", "import") +
            actionButton("new-supply", "Add supply", "plus", true)
        : actionButton("new-request", "New request", "plus", true),
    ) +
    `<section class="panel"><div class="panel-heading"><div><h2>All supplies <span style="font-weight:400;color:#9baa95">(${state.supplies.length})</span></h2><p>Available stock excludes quantities reserved for pending requests.</p></div>${actionButton("export", "Export", "export")}</div>${toolbar()}<div id="inventory-results">${inventoryTable()}</div></section>`
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
function connectionView() {
  if (connection === "connecting")
    return `<section class="panel" aria-busy="true"><div class="empty" role="status"><span class="spinner" aria-hidden="true"></span><strong>Connecting to OfficeFlow…</strong><p>Checking the OfficeFlow server on this computer.</p></div></section>`;
  return `<section class="panel"><div class="empty" role="alert">${icon("alert")}<strong>OfficeFlow can't reach its server</strong><p>This page was opened from the OfficeFlow server at ${escape(location.origin)}, but the server is not answering. Check that the OfficeFlow window is still open, or start OfficeFlow again, then retry. Nothing was saved in this browser.</p><button class="button primary" data-action="retry-connection">Retry</button></div></section>`;
}
function render() {
  page = location.hash.slice(1).split("?")[0] || "overview";
  if (connection !== "ready") {
    navigation();
    $("#breadcrumb").textContent = "Connecting";
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
  $("#main").innerHTML = {
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
function modal(title, subtitle, body) {
  closingAnimation?.cancel();
  closingAnimation = null;
  $("#dialog-content").innerHTML =
    `<div class="dialog-heading"><div><h2 id="dialog-title">${title}</h2><p>${subtitle}</p></div><button class="icon-button" data-action="close" aria-label="Close dialog">×</button></div><div class="dialog-body">${body}</div>`;
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
    `Signed in as ${escape(actor.id)}.`,
    `<div class="identity-grid"><button class="button" data-action="change-password">Change password</button>${actor.role === "admin" ? '<button class="button" data-action="reset-password">Reset teacher password</button>' : ""}<button class="button" data-action="logout">Sign out</button></div>`,
  );
}
function passwordDialog(reset = false, forced = false) {
  if (reset && !state.teachers.length) {
    toast("Add a teacher before resetting a password.");
    return;
  }
  // forced: signed in with a temporary password; the server allows nothing else until it changes.
  const end = forced
    ? `<div class="form-error" role="alert"></div><div class="dialog-actions"><button class="button" type="button" data-action="logout">Sign out</button><button class="button primary" type="submit">Change password</button></div></form>`
    : formEnd(reset ? "Reset password" : "Change password");
  modal(
    forced
      ? "Choose your own password"
      : reset
        ? "Reset teacher password"
        : "Change password",
    forced
      ? "You signed in with a temporary password. Choose a new one of 12-120 characters to continue."
      : reset
        ? "Use 12-120 characters. This is a temporary password: the teacher must choose their own at next sign-in. Their sessions end now."
        : "Use 12-120 characters. All sessions for this account will end after saving.",
    `<form data-form="${reset ? "reset-password" : "change-password"}"><div class="form-grid">${reset ? `<div class="field full"><label for="field-id">Teacher</label><select id="field-id" name="id">${state.teachers.map((t) => `<option value="${escape(t.id)}">${escape(t.name)} (${escape(t.id)})</option>`).join("")}</select></div>` : field("currentPassword", forced ? "Temporary password" : "Current password", "", "password", 'full autocomplete="current-password"')}${field("newPassword", "New password", "", "password", 'full minlength="12" autocomplete="new-password"')}${field("confirmPassword", "Confirm new password", "", "password", 'full minlength="12" autocomplete="new-password"')}</div>${end}`,
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
function loginDialog() {
  modal(
    "Welcome to OfficeFlow",
    "Sign in to your Java workspace.",
    `<form data-form="login"><div class="form-grid">${field("id", "Account ID", "", "text", "full")}${field("password", "Password", "", "password", "full")}</div>${formEnd("Sign in")}`,
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
    if (action === "retry-connection") connect();
    else if (action === "change-password") passwordDialog();
    else if (action === "reset-password") passwordDialog(true);
    else if (action === "logout") {
      await apiCall("logout", {});
      clearSession();
      loginDialog();
      toast("Signed out. Your session has ended.");
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
        toast("Password changed. Sign in with your new password.");
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
    }
    closeModal();
    render();
    toast("All set. Your workspace is up to date.");
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
  if (e.target === $("#dialog")) {
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
    loginDialog();
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
    await animation.finished;
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
  closeModal();
});
