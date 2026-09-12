.pragma library
// Pure parsing/formatting helpers for the NordVPN CLI text output. Kept free
// of QML types so it can be unit-reasoned and reused from any component.

function parseBytes(str) {
  // "16.11 KiB received" / "180 B" / "1.2 MiB"
  var m = String(str || "").match(/([\d.]+)\s*(B|KiB|MiB|GiB|TiB|KB|MB|GB|TB)?/i);
  if (!m) return 0;
  var n = parseFloat(m[1]);
  if (!isFinite(n)) return 0;
  var unit = (m[2] || "B").toUpperCase();
  var mult = {
    B: 1,
    KIB: 1024, MIB: 1024 ** 2, GIB: 1024 ** 3, TIB: 1024 ** 4,
    KB: 1000, MB: 1000 ** 2, GB: 1000 ** 3, TB: 1000 ** 4,
  }[unit] || 1;
  return n * mult;
}

function parseUptime(str) {
  // "0 seconds" / "3 minutes 12 seconds" / "1 hour 4 minutes 9 seconds" /
  // "2 days 1 hour ..."
  var s = String(str || "");
  var total = 0;
  var units = [
    [/(\d+)\s*day/i, 86400],
    [/(\d+)\s*hour/i, 3600],
    [/(\d+)\s*minute/i, 60],
    [/(\d+)\s*second/i, 1],
  ];
  for (var i = 0; i < units.length; i++) {
    var mm = s.match(units[i][0]);
    if (mm) total += parseInt(mm[1], 10) * units[i][1];
  }
  return total;
}

// `nordvpn status` -> normalized object.
function parseStatus(text) {
  var out = {
    connected: false, server: "", hostname: "", ip: "",
    country: "", city: "", technology: "", protocol: "",
    transferIn: 0, transferOut: 0, uptimeSec: 0, raw: String(text || ""),
  };
  var lines = String(text || "").split("\n");
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    var idx = line.indexOf(":");
    if (idx < 0) continue;
    var key = line.slice(0, idx).trim().toLowerCase();
    var val = line.slice(idx + 1).trim();
    if (key === "status") out.connected = /connected/i.test(val) && !/disconnected/i.test(val);
    else if (key === "server") out.server = val;
    else if (key === "hostname") out.hostname = val;
    else if (key === "ip") out.ip = val;
    else if (key === "country") out.country = val;
    else if (key === "city") out.city = val;
    else if (key === "current technology") out.technology = val;
    else if (key === "current protocol") out.protocol = val;
    else if (key === "uptime") out.uptimeSec = parseUptime(val);
    else if (key === "transfer") {
      var parts = val.split(",");
      out.transferIn = parseBytes(parts[0] || "");
      out.transferOut = parseBytes(parts[1] || "");
    }
  }
  return out;
}

// `nordvpn settings` -> { key: boolean|string }
function parseSettings(text) {
  var out = {};
  var lines = String(text || "").split("\n");
  for (var i = 0; i < lines.length; i++) {
    var idx = lines[i].indexOf(":");
    if (idx < 0) continue;
    var key = lines[i].slice(0, idx).trim();
    var val = lines[i].slice(idx + 1).trim();
    if (/^(enabled|disabled)$/i.test(val)) out[key] = /enabled/i.test(val);
    else out[key] = val;
  }
  return out;
}

function formatBytes(n) {
  n = Number(n) || 0;
  var u = ["B", "KB", "MB", "GB", "TB"];
  var i = 0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return (i === 0 ? Math.round(n) : n.toFixed(n < 10 ? 2 : 1)) + " " + u[i];
}

function formatRate(bytesPerSec) {
  return formatBytes(bytesPerSec) + "/s";
}

function formatUptime(sec) {
  sec = Math.max(0, Math.floor(sec || 0));
  var d = Math.floor(sec / 86400);
  var h = Math.floor((sec % 86400) / 3600);
  var m = Math.floor((sec % 3600) / 60);
  var s = sec % 60;
  if (d > 0) return d + "d " + h + "h " + m + "m";
  if (h > 0) return h + "h " + m + "m " + s + "s";
  if (m > 0) return m + "m " + s + "s";
  return s + "s";
}

// The CLI connect target for a country/city. Country connects use the ISO
// code (always unambiguous); city connects need "<Country> <City>" with
// spaces turned into underscores.
function connectArgs(code, countryName, cityName) {
  if (cityName && cityName.length > 0)
    return [String(countryName).replace(/\s+/g, "_"), String(cityName).replace(/\s+/g, "_")];
  return [String(code).toLowerCase()];
}
