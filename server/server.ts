import { Database } from "bun:sqlite";
import { z } from "zod";

// Sparkle checks this feed; opted-in installs add a random `id`. We count distinct ids per day,
// then send Sparkle on to the real appcast on GitHub. No IP addresses are stored.
const UPSTREAM = "https://github.com/wormadev/Tokei/releases/latest/download/appcast.xml";

const Checkin = z.object({
  id: z.uuid(),
  // Sparkle sends CFBundleVersion here: the build number (main's commit count).
  appVersion: z.string().regex(/^[0-9A-Za-z.+-]{1,32}$/).optional(),
  osVersion: z.string().regex(/^[0-9.]{1,16}$/).optional(),
  cputype: z.string().regex(/^[0-9]{1,12}$/).optional(),
});

export function openDb(path: string) {
  const db = new Database(path, { create: true });
  db.run(`CREATE TABLE IF NOT EXISTS checkins (
    day TEXT NOT NULL, id TEXT NOT NULL, build TEXT, os TEXT, arch TEXT,
    PRIMARY KEY (day, id))`);
  return db;
}

// Mach cputype: 16777228 is arm64, 16777223 x86_64.
const ARCH: Record<string, string> = { "16777228": "arm64", "16777223": "x86_64" };

export function record(db: Database, params: URLSearchParams, day: string) {
  const parsed = Checkin.safeParse(Object.fromEntries(params));
  if (!parsed.success) return false;
  const { id, appVersion, osVersion, cputype } = parsed.data;
  db.run(
    `INSERT INTO checkins (day, id, build, os, arch) VALUES (?, ?, ?, ?, ?)
     ON CONFLICT (day, id) DO UPDATE SET
       build = coalesce(excluded.build, build), os = coalesce(excluded.os, os), arch = coalesce(excluded.arch, arch)`,
    [day, id.toLowerCase(), appVersion ?? null, osVersion ?? null, cputype ? (ARCH[cputype] ?? "other") : null],
  );
  return true;
}

export function stats(db: Database, today: string) {
  const since = (days: number) => new Date(Date.parse(today) - days * 86_400_000).toISOString().slice(0, 10);
  const distinct = (days: number) =>
    (db.query("SELECT count(DISTINCT id) AS n FROM checkins WHERE day > ?").get(since(days)) as { n: number }).n;
  const breakdown = (column: "build" | "os" | "arch") =>
    db.query(`SELECT ${column} AS value, count(DISTINCT id) AS installs FROM checkins
              WHERE day > ? AND ${column} IS NOT NULL GROUP BY ${column} ORDER BY installs DESC`).all(since(7));
  return {
    today: distinct(1),
    last7Days: distinct(7),
    last30Days: distinct(30),
    builds: breakdown("build"),
    macOS: breakdown("os"),
    arch: breakdown("arch"),
    daily: db.query("SELECT day, count(*) AS installs FROM checkins WHERE day > ? GROUP BY day ORDER BY day").all(since(30)),
  };
}

// A few requests per minute per address is plenty for an update check; addresses live only in memory.
const hits = new Map<string, number>();
function limited(ip: string) {
  const n = (hits.get(ip) ?? 0) + 1;
  hits.set(ip, n);
  return n > 30;
}

if (import.meta.main) {
  const db = openDb(process.env.DB_PATH ?? "/data/tokei.db");
  setInterval(() => hits.clear(), 60_000);
  Bun.serve({
    port: Number(process.env.PORT ?? 3000),
    fetch(req, server) {
      const url = new URL(req.url);
      const ip = req.headers.get("cf-connecting-ip") ?? server.requestIP(req)?.address ?? "";
      if (limited(ip)) return new Response("Too many requests", { status: 429 });
      const today = new Date().toISOString().slice(0, 10);
      if (url.pathname === "/api/appcast.xml") {
        record(db, url.searchParams, today);
        return new Response(null, { status: 302, headers: { location: UPSTREAM, "cache-control": "no-store" } });
      }
      if (url.pathname === "/api/stats") {
        return Response.json(stats(db, today), { headers: { "cache-control": "no-store" } });
      }
      return new Response("Not found", { status: 404 });
    },
  });
}
