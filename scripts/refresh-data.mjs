#!/usr/bin/env node
// Regenerates data/world-paths.json and data/countries.json.
//
//   node scripts/refresh-data.mjs
//
// Sources:
//   - NordVPN public API   -> per-country server counts + city lists
//   - amCharts world geodata (GeoJSON, ISO-A2 feature ids) -> country outlines
//
// The outlines are projected with a plain equirectangular projection into a
// 1000x500 viewBox so the plugin can draw them on a QtQuick Canvas without any
// runtime SVG or GeoJSON parsing. Both output files are committed so the plugin
// works offline; rerun this only to pick up new servers/countries.

import { writeFileSync, readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const DATA = join(ROOT, "data");

const NORD_URL = "https://api.nordvpn.com/v1/servers/countries";
const GEO_URL = "https://cdn.amcharts.com/lib/4/geodata/json/worldLow.json";

// Allow a local cache (scripts/*.json) so the script runs without network.
async function load(url, cacheName) {
  const cache = join(dirname(fileURLToPath(import.meta.url)), cacheName);
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(30000) });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return await res.json();
  } catch (err) {
    if (existsSync(cache)) {
      console.warn(`! ${url} failed (${err.message}); using ${cacheName}`);
      return JSON.parse(readFileSync(cache, "utf8"));
    }
    throw err;
  }
}

const W = 1000;
const H = 500;
const project = ([lon, lat]) => [
  ((lon + 180) / 360) * W,
  ((90 - lat) / 180) * H,
];

function ringToPath(ring) {
  let d = "";
  for (let i = 0; i < ring.length; i++) {
    const [x, y] = project(ring[i]);
    d += (i === 0 ? "M" : "L") + x.toFixed(1) + " " + y.toFixed(1);
  }
  return d + "Z";
}

function geometryToPath(geom) {
  if (!geom) return "";
  const polys =
    geom.type === "Polygon"
      ? [geom.coordinates]
      : geom.type === "MultiPolygon"
        ? geom.coordinates
        : [];
  return polys.map((poly) => poly.map(ringToPath).join("")).join("");
}

const nord = await load(NORD_URL, "nordcountries.json");
const geo = await load(GEO_URL, "world.json");

// --- countries.json -------------------------------------------------------
const countries = {};
for (const c of nord) {
  const code = String(c.code || "").toUpperCase();
  if (!code) continue;
  countries[code] = {
    name: c.name,
    code,
    // NordVPN CLI accepts the ISO code directly for country connects.
    serverCount: c.serverCount ?? 0,
    cities: (c.cities || [])
      .map((city) => ({ name: city.name, serverCount: city.serverCount ?? 0 }))
      .sort((a, b) => b.serverCount - a.serverCount),
  };
}

// --- world-paths.json ----------------------------------------------------
const paths = {};
let matched = 0;
for (const f of geo.features) {
  const code = String(f.id || "").toUpperCase();
  if (!/^[A-Z]{2}$/.test(code)) continue;
  const d = geometryToPath(f.geometry);
  if (!d) continue;
  paths[code] = { d, name: f.properties?.name || code, hasServers: !!countries[code] };
  if (countries[code]) matched++;
}

writeFileSync(
  join(DATA, "countries.json"),
  JSON.stringify(countries, null, 0) + "\n",
);
writeFileSync(
  join(DATA, "world-paths.json"),
  JSON.stringify({ viewBox: [0, 0, W, H], paths }, null, 0) + "\n",
);

console.log(
  `wrote data/countries.json (${Object.keys(countries).length} NordVPN countries)`,
);
console.log(
  `wrote data/world-paths.json (${Object.keys(paths).length} outlines, ${matched} with servers)`,
);
