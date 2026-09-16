import test from "node:test";
import assert from "node:assert/strict";
import {
  monthCells,
  packageUsage,
  isOverdue,
  validateRange,
  escapeHtml,
} from "../src/domain.js";
test("calendar starts on Monday and spans the month", () => {
  const cells = monthCells(new Date(2026, 8, 1));
  assert.equal(cells.length, 42);
  assert.equal(cells[0].getDay(), 1);
  assert.equal(cells[0].getMonth(), 7);
});
test("package excludes cancelled, free demos, other clients and out-of-period sessions", () => {
  const p = {
    client_id: "a",
    start_date: "2026-09-01",
    expiry_date: "2026-09-30",
  };
  const base = {
    client_id: "a",
    starts_at: "2026-09-12T12:00:00",
    counts_against_package: true,
    status: "completed",
  };
  assert.equal(
    packageUsage(p, [
      base,
      { ...base, status: "no_show" },
      { ...base, status: "cancelled" },
      { ...base, counts_against_package: false },
      { ...base, client_id: "b" },
      { ...base, starts_at: "2026-08-01T12:00:00" },
    ]),
    2,
  );
});
test("results become overdue only after session end and only while planned", () => {
  const s = {
    starts_at: "2026-09-01T12:00Z",
    ends_at: "2026-09-01T13:00Z",
    status: "planned",
  };
  assert.equal(isOverdue(s, Date.parse("2026-09-01T12:30Z")), false);
  assert.equal(isOverdue(s, Date.parse("2026-09-01T13:01Z")), true);
  assert.equal(
    isOverdue({ ...s, status: "completed" }, Date.parse("2026-09-01T13:01Z")),
    false,
  );
});
test("past entries are allowed but invalid time ranges are rejected", () => {
  assert.doesNotThrow(() =>
    validateRange("2020-01-01T10:00", "2020-01-01T11:00"),
  );
  assert.throws(() => validateRange("2020-01-01T11:00", "2020-01-01T10:00"));
  assert.throws(() => validateRange("bad", "bad"));
});
test("untrusted display content is escaped", () =>
  assert.equal(
    escapeHtml('<img src=x onerror="alert(1)">'),
    "&lt;img src=x onerror=&quot;alert(1)&quot;&gt;",
  ));
