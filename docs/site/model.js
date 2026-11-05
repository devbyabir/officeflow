export const STORE_KEY = "officeflow-demo-v1";
export const categories = [
  "Stationery",
  "Technology",
  "Paper & print",
  "Desk essentials",
];
const now = () => new Date().toISOString();
const id = (prefix) => `${prefix}-${globalThis.crypto.randomUUID()}`;
const fail = (message) => {
  throw new Error(message);
};
const text = (value, label) => {
  if (typeof value !== "string" || !value.trim() || value.trim().length > 120)
    fail(`${label} is required (up to 120 characters).`);
  return value.trim();
};
const integer = (value, label, min = 0) => {
  const number =
    typeof value === "number"
      ? value
      : /^\d+$/.test(String(value))
        ? Number(value)
        : NaN;
  if (!Number.isSafeInteger(number) || number < min || number > 1_000_000)
    fail(`${label} must be a whole number from ${min} to 1,000,000.`);
  return number;
};
export function seed() {
  const date = new Date();
  const ago = (days) =>
    new Date(date.getTime() - days * 86400000).toISOString();
  return {
    teachers: [
      {
        id: "T001",
        name: "Alex Morgan",
        department: "Computer Science",
        email: "alex@example.com",
      },
      {
        id: "T002",
        name: "Sam Chen",
        department: "Design & Media",
        email: "sam@example.com",
      },
      {
        id: "T003",
        name: "Jordan Lee",
        department: "Administration",
        email: "jordan@example.com",
      },
    ],
    supplies: [
      {
        id: "SUP-001",
        name: "A4 copy paper",
        category: "Paper & print",
        quantity: 84,
        threshold: 20,
        unit: "reams",
      },
      {
        id: "SUP-002",
        name: "Gel pens · black",
        category: "Stationery",
        quantity: 128,
        threshold: 30,
        unit: "pieces",
      },
      {
        id: "SUP-003",
        name: "Wireless mouse",
        category: "Technology",
        quantity: 9,
        threshold: 10,
        unit: "pieces",
      },
      {
        id: "SUP-004",
        name: "Hardcover notebook",
        category: "Stationery",
        quantity: 46,
        threshold: 15,
        unit: "pieces",
      },
      {
        id: "SUP-005",
        name: "USB-C adapter",
        category: "Technology",
        quantity: 6,
        threshold: 8,
        unit: "pieces",
      },
      {
        id: "SUP-006",
        name: "Desk organizer",
        category: "Desk essentials",
        quantity: 24,
        threshold: 5,
        unit: "pieces",
      },
      {
        id: "SUP-007",
        name: "Sticky notes · pastel",
        category: "Stationery",
        quantity: 62,
        threshold: 10,
        unit: "packs",
      },
      {
        id: "SUP-008",
        name: "Printer toner",
        category: "Paper & print",
        quantity: 0,
        threshold: 4,
        unit: "cartridges",
      },
    ],
    requests: [
      {
        id: "REQ-1003",
        teacherId: "T001",
        teacherName: "Alex Morgan",
        supplyId: "SUP-001",
        supplyName: "A4 copy paper",
        quantity: 5,
        status: "Pending",
        note: "Handouts for next week’s lab.",
        createdAt: ago(0),
      },
      {
        id: "REQ-1002",
        teacherId: "T002",
        teacherName: "Sam Chen",
        supplyId: "SUP-003",
        supplyName: "Wireless mouse",
        quantity: 2,
        status: "Pending",
        note: "Media studio workstations.",
        createdAt: ago(1),
      },
      {
        id: "REQ-1001",
        teacherId: "T003",
        teacherName: "Jordan Lee",
        supplyId: "SUP-004",
        supplyName: "Hardcover notebook",
        quantity: 3,
        status: "Issued",
        note: "Department meeting.",
        createdAt: ago(3),
        updatedAt: ago(2),
      },
    ],
  };
}
export function available(state, supply) {
  return (
    supply.quantity -
    (supply.reservedByOthers || 0) -
    state.requests
      .filter((r) => r.supplyId === supply.id && r.status === "Pending")
      .reduce((sum, r) => sum + r.quantity, 0)
  );
}
export function stockStatus(state, supply) {
  const free = available(state, supply);
  return free === 0
    ? "Out of stock"
    : free <= supply.threshold
      ? "Low stock"
      : "In stock";
}
export function command(original, actor, action, data = {}) {
  const state = structuredClone(original);
  if (!actor || !["admin", "teacher"].includes(actor.role))
    fail("Choose a valid workspace identity.");
  if (
    actor.role === "teacher" &&
    !state.teachers.some((t) => t.id === actor.id)
  )
    fail("Teacher account no longer exists.");
  const admin = () => {
    if (actor.role !== "admin") fail("Administrator access required.");
  };
  if (action === "saveSupply") {
    admin();
    const existing = data.id
      ? state.supplies.find((s) => s.id === data.id)
      : null;
    if (data.id && !existing) fail("Supply no longer exists.");
    const item = {
      id: existing?.id || id("SUP"),
      name: text(data.name, "Item name"),
      category: text(data.category, "Category"),
      quantity: integer(data.quantity, "Stock"),
      threshold: integer(data.threshold, "Low-stock threshold"),
      unit: text(data.unit, "Unit"),
    };
    if (!categories.includes(item.category)) fail("Choose a listed category.");
    if (
      state.supplies.some(
        (s) =>
          s.id !== item.id && s.name.toLowerCase() === item.name.toLowerCase(),
      )
    )
      fail("An item with this name already exists.");
    const reserved = existing
      ? existing.quantity - available(state, existing)
      : 0;
    if (item.quantity < reserved)
      fail(`Stock cannot be below ${reserved} reserved units.`);
    if (existing) Object.assign(existing, item);
    else state.supplies.push(item);
  } else if (action === "deleteSupply") {
    admin();
    if (!state.supplies.some((s) => s.id === data.id))
      fail("Supply no longer exists.");
    if (
      state.requests.some(
        (r) => r.supplyId === data.id && r.status === "Pending",
      )
    )
      fail("Resolve pending requests before deleting this item.");
    state.supplies = state.supplies.filter((s) => s.id !== data.id);
  } else if (action === "saveTeacher") {
    admin();
    const teacherId = text(data.id, "Teacher ID");
    if (!/^[a-zA-Z0-9_-]{1,30}$/.test(teacherId) || teacherId === "001")
      fail(
        "Teacher ID must contain 1–30 letters, numbers, underscores or hyphens, and cannot be 001.",
      );
    const existing = state.teachers.find(
      (t) => t.id.toLowerCase() === teacherId.toLowerCase(),
    );
    if (!data.edit && existing) fail("Teacher ID already exists.");
    if (data.edit && (!existing || existing.id !== teacherId))
      fail("Teacher no longer exists.");
    const teacher = {
      id: teacherId,
      name: text(data.name, "Name"),
      department: text(data.department, "Department"),
      email: String(data.email || "").trim(),
    };
    if (
      teacher.email.length > 120 ||
      (teacher.email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(teacher.email))
    )
      fail("Enter a valid email or leave it blank.");
    if (existing) Object.assign(existing, teacher);
    else state.teachers.push(teacher);
  } else if (action === "deleteTeacher") {
    admin();
    if (!state.teachers.some((t) => t.id === data.id))
      fail("Teacher no longer exists.");
    if (
      state.requests.some(
        (r) => r.teacherId === data.id && r.status === "Pending",
      )
    )
      fail("Resolve this teacher’s pending requests first.");
    state.teachers = state.teachers.filter((t) => t.id !== data.id);
  } else if (action === "request") {
    if (actor.role !== "teacher")
      fail("Switch to a teacher to request supplies.");
    const item = state.supplies.find((s) => s.id === data.supplyId);
    if (!item) fail("Supply no longer exists.");
    const quantity = integer(data.quantity, "Quantity", 1);
    if (quantity > available(state, item))
      fail("Requested quantity exceeds available stock.");
    const note = String(data.note || "").trim();
    if (note.length > 240) fail("Notes may contain up to 240 characters.");
    state.requests.unshift({
      id: id("REQ"),
      teacherId: actor.id,
      teacherName: state.teachers.find((t) => t.id === actor.id).name,
      supplyId: item.id,
      supplyName: item.name,
      quantity,
      status: "Pending",
      note,
      createdAt: now(),
    });
  } else if (["issue", "reject", "cancel"].includes(action)) {
    const request = state.requests.find((r) => r.id === data.id);
    if (!request || request.status !== "Pending")
      fail("This request is no longer pending.");
    if (action === "cancel") {
      if (actor.role !== "teacher" || actor.id !== request.teacherId)
        fail("You can only cancel your own pending requests.");
    } else admin();
    if (action === "issue") {
      const supply = state.supplies.find((s) => s.id === request.supplyId);
      if (!supply || supply.quantity < request.quantity)
        fail("Insufficient stock to issue this request.");
      supply.quantity -= request.quantity;
    }
    request.status = {
      issue: "Issued",
      reject: "Rejected",
      cancel: "Cancelled",
    }[action];
    request.updatedAt = now();
  } else fail("Unknown action.");
  return state;
}
export function parseCSV(source) {
  if (source.length > 200_000) fail("CSV must be smaller than 200 KB.");
  const rows = [];
  let row = [],
    field = "",
    quoted = false,
    closed = false;
  source = source.replace(/^\uFEFF/, "");
  for (let i = 0; i <= source.length; i++) {
    const c = source[i];
    if (quoted) {
      if (c === undefined) fail("Unclosed CSV quote.");
      if (c === '"' && source[i + 1] === '"') {
        field += '"';
        i++;
      } else if (c === '"') {
        quoted = false;
        closed = true;
      } else field += c;
    } else if (c === "," || c === "\n" || c === "\r" || c === undefined) {
      row.push(field);
      field = "";
      closed = false;
      if (c !== ",") {
        if (row.some((v) => v.trim())) rows.push(row);
        row = [];
        if (c === "\r" && source[i + 1] === "\n") i++;
      }
    } else if (c === '"') {
      if (field || closed) fail("Unexpected CSV quote.");
      quoted = true;
    } else {
      if (closed) fail("Unexpected text after CSV quote.");
      field += c;
    }
  }
  if (!rows.length) fail("CSV is empty.");
  return rows;
}
export function importCSV(original, actor, type, source) {
  const rows = parseCSV(source),
    header = rows.shift().map((s) => s.trim());
  const expected =
    type === "supplies"
      ? ["name", "category", "quantity", "threshold", "unit"]
      : ["id", "name", "department", "email"];
  if (header.join(",") !== expected.join(","))
    fail(`Expected header: ${expected.join(",")}`);
  if (!rows.length || rows.length > 500) fail("Include 1–500 data rows.");
  let state = original;
  for (const [index, values] of rows.entries()) {
    if (values.length !== header.length)
      fail(`Row ${index + 2}: incorrect number of fields.`);
    try {
      state = command(
        state,
        actor,
        type === "supplies" ? "saveSupply" : "saveTeacher",
        Object.fromEntries(header.map((key, i) => [key, values[i]])),
      );
    } catch (error) {
      fail(`Row ${index + 2}: ${error.message}`);
    }
  }
  return state;
}
export function csv(rows) {
  return rows
    .map((row) =>
      row
        .map((value) => {
          let s = String(value ?? "");
          if (/^[=+\-@\t\r]/.test(s)) s = `'${s}`;
          return `"${s.replaceAll('"', '""')}"`;
        })
        .join(","),
    )
    .join("\r\n");
}
