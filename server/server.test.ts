import { describe, expect, spyOn, test } from "bun:test";
import { handler, openDb, record, stats } from "./server";

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

describe("fetch handler", () => {
  const appcast = (query: string) => new Request(`http://localhost/api/appcast.xml?${query}`);

  test("redirects an update check to the GitHub appcast and records it", () => {
    const db = openDb(":memory:");
    const res = handler(db, new Map())(appcast(`id=${ID}`), "1.2.3.4");
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe("https://github.com/wormadev/Tokei/releases/latest/download/appcast.xml");
    expect(stats(db, new Date().toISOString().slice(0, 10)).today).toBe(1);
  });

  test("still redirects when the database write fails", () => {
    const db = openDb(":memory:");
    db.run("DROP TABLE checkins");
    const error = spyOn(console, "error").mockImplementation(() => {});
    const res = handler(db, new Map())(appcast(`id=${ID}`), "1.2.3.4");
    expect(res.status).toBe(302);
    expect(error).toHaveBeenCalledTimes(1);
    expect(String(error.mock.calls[0])).not.toContain(ID);
    error.mockRestore();
  });

  test("does not record an invalid id", () => {
    const db = openDb(":memory:");
    expect(handler(db, new Map())(appcast("id=not-a-uuid"), "1.2.3.4").status).toBe(302);
    expect(stats(db, new Date().toISOString().slice(0, 10)).last30Days).toBe(0);
  });

  test("rate limits an address after 30 requests a minute", () => {
    const handle = handler(openDb(":memory:"), new Map());
    for (let i = 0; i < 30; i++) expect(handle(appcast(`id=${ID}`), "1.2.3.4").status).toBe(302);
    expect(handle(appcast(`id=${ID}`), "1.2.3.4").status).toBe(429);
    expect(handle(appcast(`id=${ID}`), "5.6.7.8").status).toBe(302);
  });

  test("404s unknown paths", () => {
    expect(handler(openDb(":memory:"), new Map())(new Request("http://localhost/nope"), "1.2.3.4").status).toBe(404);
  });
});
