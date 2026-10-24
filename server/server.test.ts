import { expect, test } from "bun:test";
import { openDb, record, stats } from "./server";

const ID = "3f1c2a9e-5b7d-4e8f-9a10-2b3c4d5e6f70";
const q = (s: string) => new URLSearchParams(s);

test("counts one install per day however often it checks", () => {
  const db = openDb(":memory:");
  record(db, q(`id=${ID}`), "2026-10-24");
  record(db, q(`id=${ID}&appVersion=18&osVersion=26.1&cputype=16777228`), "2026-10-24");
  record(db, q(`id=${ID}`), "2026-10-25");
  const s = stats(db, "2026-10-25");
  expect(s.today).toBe(1);
  expect(s.last7Days).toBe(1);
  expect(s.daily).toEqual([{ day: "2026-10-24", installs: 1 }, { day: "2026-10-25", installs: 1 }]);
  expect(s.builds).toEqual([{ value: "18", installs: 1 }]);
  expect(s.arch).toEqual([{ value: "arm64", installs: 1 }]);
});

test("ignores checks without a valid id", () => {
  const db = openDb(":memory:");
  expect(record(db, q(""), "2026-10-24")).toBe(false);
  expect(record(db, q("id=not-a-uuid"), "2026-10-24")).toBe(false);
  expect(record(db, q(`id=${ID}&appVersion=<script>`), "2026-10-24")).toBe(false);
  expect(stats(db, "2026-10-24").last30Days).toBe(0);
});

test("a later profile-less check keeps the stored build", () => {
  const db = openDb(":memory:");
  record(db, q(`id=${ID}&appVersion=18`), "2026-10-24");
  record(db, q(`id=${ID}`), "2026-10-24");
  expect(stats(db, "2026-10-24").builds).toEqual([{ value: "18", installs: 1 }]);
});
