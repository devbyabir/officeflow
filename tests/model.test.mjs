import { test } from "node:test";
import assert from "node:assert/strict";
import {
  seed,
  command,
  available,
  importCSV,
  csv,
  parseCSV,
} from "../docs/site/model.js";
const admin = { role: "admin", id: "admin" },
  alex = { role: "teacher", id: "T001" },
  sam = { role: "teacher", id: "T002" };

test("pending reservations prevent overselling; issue deducts exactly once", () => {
  let s = seed();
  const before = structuredClone(s);
  assert.equal(available(s, s.supplies[0]), 79);
  s = command(s, alex, "request", { supplyId: "SUP-001", quantity: 79 });
  assert.equal(available(s, s.supplies[0]), 0);
  assert.throws(
    () => command(s, sam, "request", { supplyId: "SUP-001", quantity: 1 }),
    /exceeds/,
  );
  const request = s.requests[0];
  s = command(s, admin, "issue", { id: request.id });
  assert.equal(s.supplies[0].quantity, 5);
  assert.equal(available(s, s.supplies[0]), 0);
  assert.throws(
    () => command(s, admin, "issue", { id: request.id }),
    /no longer pending/,
  );
  assert.deepEqual(before.supplies[0], seed().supplies[0]);
});
test("cancellation is owner-only; rejection releases stock", () => {
  let s = seed();
  assert.throws(() => command(s, sam, "cancel", { id: "REQ-1003" }), /own/);
  assert.throws(
    () => command(s, alex, "issue", { id: "REQ-1003" }),
    /Administrator/,
  );
  assert.throws(() => command(s, admin, "cancel", { id: "REQ-1003" }), /own/);
  s = command(s, alex, "cancel", { id: "REQ-1003" });
  assert.equal(available(s, s.supplies[0]), 84);
  s = command(s, admin, "reject", { id: "REQ-1002" });
  assert.equal(available(s, s.supplies[2]), 9);
});
test("CRUD rejects duplicates, stale records, negative/decimal quantities and protected references", () => {
  const s = seed();
  assert.throws(
    () => command(s, admin, "deleteTeacher", { id: "T001" }),
    /pending/,
  );
  assert.throws(
    () => command(s, admin, "deleteSupply", { id: "SUP-001" }),
    /pending/,
  );
  assert.throws(
    () => command(s, admin, "saveSupply", { ...s.supplies[0], quantity: 4 }),
    /reserved/,
  );
  assert.throws(
    () => command(s, admin, "saveSupply", { ...s.supplies[0], quantity: -1 }),
    /whole/,
  );
  assert.throws(
    () => command(s, alex, "request", { supplyId: "SUP-001", quantity: 1.5 }),
    /whole/,
  );
  assert.throws(
    () => command(s, admin, "saveTeacher", { ...s.teachers[0], id: "t001" }),
    /exists/,
  );
  assert.throws(
    () => command(s, admin, "saveTeacher", { ...s.teachers[0], id: "001" }),
    /cannot/,
  );
  const changed = command(s, admin, "saveTeacher", {
    ...s.teachers[0],
    name: "New name",
    edit: true,
  });
  assert.equal(changed.requests[0].teacherName, "Alex Morgan");
});
test("CSV quoting, BOM, multiline cells and rollback", () => {
  assert.deepEqual(parseCSV('\uFEFFid,name\r\n1,"Sam, Lee"\r\n'), [
    ["id", "name"],
    ["1", "Sam, Lee"],
  ]);
  assert.deepEqual(parseCSV('a,b\n"x\ny","say ""hi"""'), [
    ["a", "b"],
    ["x\ny", 'say "hi"'],
  ]);
  assert.throws(() => parseCSV('a\n"unclosed'), /Unclosed/);
  const original = seed(),
    before = JSON.stringify(original);
  assert.throws(
    () =>
      importCSV(
        original,
        admin,
        "teachers",
        "id,name,department,email\nT004,Pat,Design,\nT001,Duplicate,Design,",
      ),
    /Row 3/,
  );
  assert.equal(JSON.stringify(original), before);
  const updated = importCSV(
    original,
    admin,
    "supplies",
    "name,category,quantity,threshold,unit\nMarkers,Stationery,12,2,packs",
  );
  assert.equal(updated.supplies.length, 9);
});
test("CSV export protects spreadsheet formula cells", () => {
  assert.equal(csv([["=1+1", 'a"b', "normal"]]), '"\'=1+1","a""b","normal"');
});
test("Java teacher snapshot includes reservations by other accounts", () => {
  const s = seed();
  s.requests = [];
  s.supplies[0].reservedByOthers = 10;
  assert.equal(available(s, s.supplies[0]), 74);
});
