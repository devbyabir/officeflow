import { test } from "node:test";
import assert from "node:assert/strict";
import { paginate, statusCounts, stockParts } from "../docs/site/view-utils.js";

test("pagination clamps pages after deletion and handles empty results", () => {
  const records = Array.from({ length: 12 }, (_, index) => index);
  assert.deepEqual(paginate(records, 2, 5).items, [5, 6, 7, 8, 9]);
  assert.equal(paginate(records, 99, 5).page, 3);
  assert.equal(paginate(records, -1, 5).page, 1);
  assert.equal(paginate([], 4, 5).start, 0);
  assert.equal(paginate([], 4, 5).pages, 1);
  assert.equal(paginate(records, 1, 500).items.length, 5);
  assert.equal(paginate(records.slice(0, 4), 3, 5).page, 1);
});
test("status chart counts real records including zero and empty states", () => {
  assert.deepEqual(
    statusCounts([
      { status: "Issued" },
      { status: "Pending" },
      { status: "Pending" },
    ]).map((x) => x.count),
    [2, 1, 0, 0],
  );
  assert.ok(statusCounts([]).every((x) => x.count === 0));
});
test("stock breakdown avoids division by zero and clamps invalid display ranges", () => {
  assert.deepEqual(stockParts(10, 7), {
    onHand: 10,
    available: 7,
    reserved: 3,
    percent: 70,
  });
  assert.equal(stockParts(0, 0).percent, 0);
  assert.equal(stockParts(10, 12).available, 10);
  assert.equal(stockParts(10, -1).available, 0);
});
