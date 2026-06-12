# 🐢 Tortoise — make one website slow, on purpose

Tortoise simulates a **hostile network** — packet loss, high latency, low bandwidth — for a
**single domain**, so you can see how your web app behaves on a real-world bad connection
(crowded conference wifi, weak mobile, a flaky hotel network) **before** your users do. The rest
of your machine (Slack, Zoom, downloads) stays at full speed.

Point it at whatever URL is in your browser's address bar — it works against a deployed site or a
local dev frontend talking to a remote backend.

**Two ways to use it, one engine:**
- 🖥️ **Menu-bar app** — a top-bar 🐢 icon shows when a site is being slowed, lists which sites, and
  sets them back to normal, all behind the standard macOS password prompt. No Terminal needed.
- ⌨️ **CLI** (`tortoise.sh`) — scriptable, same presets, same state.

The CLI is the brain; the app is a thin front-end that calls it. Either one drives the same state.

**Why not just Chrome DevTools throttling?** It can't inject **packet loss** — the thing that
actually breaks long-lived connections (websockets, SSE, streaming) — and it only affects a single
tab. See [Tortoise vs. Chrome DevTools](docs/vs-chrome-devtools.md).

> **macOS only.** Tortoise uses the OS's built-in traffic shaper (`pfctl` + `dnctl`/dummynet) —
> nothing to install. It needs admin rights because it edits the system packet filter (CLI via
> `sudo`; the app via the standard macOS password dialog, asked once).

---

## Requirements

- **macOS** (uses the built-in `pfctl` / `dnctl` dummynet shaper).
- Admin (sudo) access.
- **Xcode Command Line Tools** — only if you want to build the menu-bar app (`xcode-select --install`).

## Install

```bash
git clone git@github.com:kuldeepkeshwar/tortoise-app.git
cd tortoise-app
```

- **CLI:** run `./tortoise.sh` directly (see below).
- **App:** `cd app && ./package-dmg.sh`, then open `Tortoise.dmg` and drag **Tortoise** into Applications.

---

## Quick start (CLI)

```bash
# 1. Slow down a site
sudo ./tortoise.sh on conference-wifi example.com

# 2. Use the site in your browser as normal — watch it struggle

# 3. Restore normal speed when you're done
sudo ./tortoise.sh off all
```

**What's the domain?** Whatever is in your browser's address bar — e.g. `example.com`. You can paste
the whole URL (`https://example.com/path`); Tortoise strips the scheme and path for you.

---

## Presets

```bash
./tortoise.sh presets
```

| Preset | Bandwidth | Latency (RTT) | Packet loss | Feels like |
|---|---|---|---|---|
| `perfect` | 1 Gbit/s | ~0 ms | 0% | Baseline / sanity check |
| `office-wifi` | 50 Mbit/s | ~40 ms | 0% | Strong office/home wifi |
| `home` | 25 Mbit/s | ~60 ms | ~0.1% | Typical home broadband |
| `coffee-shop` | 5 Mbit/s | ~200 ms | ~2% | Busy public wifi |
| `conference-wifi` | 4 Mbit/s | ~240 ms | ~5% | **Crowded venue — a great default** |
| `flaky` | 8 Mbit/s | ~120 ms | **~10%** | Fast but drops packets — kills websockets |
| `slow-4g` | 1.5 Mbit/s | ~300 ms | ~2% | Weak 4G |
| `slow-3g` | 780 Kbit/s | ~300 ms | ~1% | 3G |
| `very-slow` | 240 Kbit/s | ~800 ms | ~5% | 2.5G / hotel basement |
| `super-slow` | 50 Kbit/s | ~1600 ms | **~10%** | 2G dead zone — brutal |

Start with **`conference-wifi`**. To find breaking points, use **`flaky`** (high packet loss — the
one condition Chrome DevTools can't reproduce) or **`super-slow`** for the worst case.

### Custom presets

A preset is just a **set of conditions** (bandwidth / delay / loss) — it has **no domain**. Define
it once, apply it to any domain(s).

```bash
# define once (no sudo) — also appears in the app's menus
./tortoise.sh define office 20Mbit/s 40 0.5      # name  bandwidth  delayMs  loss%

# apply to one or many domains in a single command
sudo ./tortoise.sh on office example.com api.example.com
```

Defined presets live in `~/.config/tortoise/presets.conf` (override with `TORTOISE_PRESETS`), one
per line: `name  bandwidth  delayMs  loss%`. `loss%` is a percentage (`5` = 5%).

For a true one-off without naming it, pass the params inline where the preset name goes:

```bash
sudo ./tortoise.sh on custom:2Mbit/s:250:5 example.com
```

---

## Commands

```bash
sudo ./tortoise.sh on <preset> <url-or-domain> [more-domains...]   # start / replace
sudo ./tortoise.sh off <domain|id>                                 # stop ONE domain
sudo ./tortoise.sh off all                                         # stop everything + restore
     ./tortoise.sh list                                            # domains under control + preset
     ./tortoise.sh presets                                         # available presets (built-in + yours)
     ./tortoise.sh define <name> <bw> <delayMs> <loss%>            # save a custom named preset
sudo ./tortoise.sh doctor                                          # diagnose: is it actually shaping?
sudo ./tortoise.sh uninstall                                       # remove the passwordless helper
```

Each domain is controlled **independently**, and only **one preset can be active per domain** —
re-running `on` replaces it (never stacks):

```bash
sudo ./tortoise.sh on flaky     example.com
sudo ./tortoise.sh on very-slow api.example.com

./tortoise.sh list
#   ID  PRESET     DOMAIN            SHAPING
#   1   flaky      example.com       8Mbit/s, 120ms RTT, 10% loss
#   2   very-slow  api.example.com   240Kbit/s, 800ms RTT, 5% loss

sudo ./tortoise.sh off example.com   # or:  sudo ./tortoise.sh off 1
sudo ./tortoise.sh off all           # everything, restore network
```

---

## Menu-bar app

A tiny self-contained macOS app (`Tortoise.app`) that lives in the top bar.

**Build & install:**

```bash
cd app
./package-dmg.sh          # → Tortoise.dmg (universal, drag-to-install)
# or build the .app directly:  ./build.sh /Applications
```

Open `Tortoise.dmg`, drag **Tortoise** into Applications, launch it. It's ad-hoc signed (not
notarized), so the first open may need a right-click → **Open** (or **System Settings → Privacy &
Security → Open Anyway**). It compiles from `TortoiseBar.swift` with the Command Line Tools — no
Xcode project, no dependencies — and embeds its own copy of `tortoise.sh`, so the `.app` is portable.

**What you get:**
- A 🐢 icon: **subtle when idle**, **red with a count when a site is being slowed**.
- **Slow down a site…** → pick a speed → type the site. **Back to normal** per-site or for all.
- **Switch speeds fast:** hover a slowed site → pick another speed (✓ marks the current one) to swap
  instantly — no retyping the site.
- **New custom speed…** saves a reusable speed (name + bandwidth + delay + loss), usable on any site.
- **Asks for your password once:** the first action installs a passwordless helper, so every later
  action is silent. Remove it with `sudo ./tortoise.sh uninstall`.
- **Quit warns you** if a site is still slowed and offers **Restore & Quit** (the slowdown lives in
  the packet filter, not the app, so it would otherwise persist).

---

## Local development

A local dev setup is usually split across two hosts — shape the **backend**, not the frontend:

- The **frontend** dev server (e.g. `https://localhost:3000`) is loopback — macOS can't shape
  loopback, and Tortoise won't try. You're not testing how fast local assets load anyway.
- The **backend** your app talks to (its API + websockets) is typically a **remote** host — that's
  the traffic that matters, and Tortoise shapes it normally. Point Tortoise at that backend domain.

**Fidelity note:** this faithfully degrades all *runtime* behavior (API calls, websocket reconnects,
streaming) — the resilience surface you care about. It does **not** slow the initial page/asset load,
since those come from fast local loopback. To rehearse a realistic **cold start**, point Tortoise at
a **deployed** site where the app and API share one domain.

**Backend on `127.0.0.1`?** If your backend runs fully locally (or a hostname maps to `127.0.0.1`
via `/etc/hosts`), it's loopback and **cannot be shaped** by Tortoise (or any OS shaper). Tortoise
detects this and tells you. Either shape a **remote** backend env instead, or front the local backend
with a proxy such as [toxiproxy](https://github.com/Shopify/toxiproxy) and point your frontend at the
proxy (it injects loss/latency at the app layer, sidestepping loopback).

---

## What to watch for

When something misbehaves, note **which flow** and **which preset**. Common bad-network failure
modes in web apps:

- **Streaming / live responses** — does a half-streamed response just stop? Does it recover, or sit
  dead until reload?
- **Websockets / live updates** — do panels silently stop updating with no error? Does the app
  reconnect on a brief drop, or throw a "disconnected" modal on every little hiccup?
- **Infinite spinners** — a loader that never resolves *and* never errors.
- **Large data views** — do big tables/graphs stall the whole UI on `very-slow` / `super-slow`?
- **Cold start** — does first load hang with no feedback on `flaky` / `super-slow`?

> Tip: with the browser DevTools **Network** panel open and **"Disable cache"** ticked, you'll see
> request timings balloon — proof the shaping is hitting the page (a cached app shell will otherwise
> feel fast no matter what).

---

## Safety & caveats

- **Always run `sudo ./tortoise.sh off all` when you finish** (or reboot — shaping doesn't persist
  across restarts). `tortoise.sh list` shows what's still active.
- **It targets the domain's current IPs.** If the site is behind a CDN whose edge IPs rotate, re-run
  `on` to re-resolve. CDN IPs can be shared, so a few unrelated sites on the same CDN may also slow
  while active — harmless, and it stops the moment you turn it off. `tortoise.sh doctor` flags drift.
- **Can't shape loopback** (`localhost` / `127.0.0.1`) — see *Local development*.
- **On a VPN**, shape the domain you actually connect to; split-tunnel setups may bypass it.
- Only TCP/UDP on ports **80/443** to the target IPs are touched — SSH and other traffic are untouched.

---

## How it works

`dnctl` (dummynet) creates two shaped pipes per domain — one each direction — configured with the
preset's bandwidth / delay / loss. `pfctl` routes only TCP **and** UDP traffic (so HTTP/3 / QUIC is
covered too) to the target domain's IPs on ports 80/443 through those pipes, via a dedicated
`tortoise` anchor layered on top of your existing rules. `off` flushes the anchor, deletes the pipes,
restores `/etc/pf.conf`, and only disables `pf` if Tortoise was the one that enabled it.

---

## License

[MIT](LICENSE) © Kuldeep Keshwar
