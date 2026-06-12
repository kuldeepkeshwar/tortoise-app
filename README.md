# tortoise — simulate a bad network for one site

Make Prophecy run on a **hostile network** (packet loss, latency, low bandwidth) so you can
see what your audience sees on conference wifi — **before** you're on stage. It slows down
traffic to **one domain only**; the rest of your machine (Slack, Zoom, downloads) stays fast.

Works for everyone — SE / demo or engineer — against **local dev or a deployed env**. You
just give it the URL you're using in the browser.

**Two ways to use it, same engine:**
- 🖥️ **Menu-bar app — "Tortoise"** — for Mac users / demo team. A top-bar 🐢 icon shows when a site
  is being slowed, lists which sites, and sets them back to normal — with the native password
  prompt. See [Menu-bar app](#menu-bar-app).
- ⌨️ **CLI** (`tortoise.sh`) — for devs. Scriptable, same presets, same state.

The CLI is the brain; the app is a thin front-end that calls it. Either one drives the same state.

> macOS only. Nothing to install — it uses macOS's built-in traffic shaper (`dnctl`/`pfctl`).
> It needs admin rights because it changes the system packet filter (CLI via `sudo`; app via the
> standard macOS password dialog).

**Why not just Chrome DevTools throttling?** It can't do packet loss — the thing that actually
breaks long-lived connections — and only affects one tab. See
[Tortoise vs. Chrome DevTools](docs/vs-chrome-devtools.md).

---

## Quick start (CLI)

```bash
# from the repo root

# 1. Turn on a bad network for your demo site
sudo ./tortoise.sh on conference-wifi app.prophecy.io

# 2. Use Prophecy in your browser as normal — watch it struggle

# 3. Turn it back off when you're done
sudo ./tortoise.sh off all
```

**What's the domain?** It's whatever is in your browser's address bar — e.g. `app.prophecy.io`,
or your demo/dev env like `my-env.cloud.databricks.com`. You can paste the whole URL; tortoise
strips the `https://` and path for you. Running local dev? Pass the **backend** domain you
pointed the app at (the `domainUrl` in localStorage), not `localhost` (see caveats).

---

## Presets

```bash
./tortoise.sh presets
```

| Preset | Bandwidth | Latency (RTT) | Packet loss | Use it for |
|---|---|---|---|---|
| `perfect` | 1 Gbit/s | ~0 ms | 0% | Baseline / sanity check |
| `office-wifi` | 50 Mbit/s | ~40 ms | 0% | Strong office/home wifi |
| `home` | 25 Mbit/s | ~60 ms | ~0.1% | Typical home broadband |
| `coffee-shop` | 5 Mbit/s | ~200 ms | ~2% | Busy public wifi |
| `conference-wifi` | 4 Mbit/s | ~240 ms | ~5% | **Crowded venue — the headline case** |
| `flaky` | 8 Mbit/s | ~120 ms | **~10%** | Fast but drops packets — kills websockets |
| `slow-4g` | 1.5 Mbit/s | ~300 ms | ~2% | Weak 4G |
| `slow-3g` | 780 Kbit/s | ~300 ms | ~1% | 3G |
| `very-slow` | 240 Kbit/s | ~800 ms | ~5% | 2.5G / hotel basement |
| `super-slow` | 50 Kbit/s | ~1600 ms | **~10%** | 2G dead zone — brutal |

Start with **`conference-wifi`**. To find the breaking points, use **`flaky`** (high packet loss,
which kills long-lived connections — the one condition Chrome DevTools throttling can't reproduce)
or **`super-slow`** for the worst case.

---

## What to look for (the things worth reporting)

When something misbehaves, note **which flow** and **which preset**. The known soft spots:

- **Copilot / agent chat** — does a half-streamed answer just stop? Does it recover, or sit
  dead until reload? (The chat/metadata socket doesn't auto-reconnect today.)
- **Project browser / metadata / git** — do panels silently stop responding with no error?
- **Pipeline editor** — this one *should* survive brief drops (it auto-reconnects and replays).
  If it throws a "Prophecy was disconnected — Reconnect" modal on a *short* blip, note it.
- **Other IDEs (SQL / Job / unit tests)** — do they pop the "Reconnect" modal on every little
  hiccup instead of healing on their own?
- **Anything that spins forever** — a loader that never resolves and never errors.
- **Big data views** (interim/sample data, lineage) — do they stall the whole UI on `very-slow`/`super-slow`?
- **Login / project load** — does a cold start hang with no feedback?

A good bug report = *preset + flow + what you expected + what happened* (a screen recording helps).

---

## Local development

Local dev is split across two hosts, and that's fine — you shape the **backend**, not the frontend:

- **Frontend** runs on `https://localhost:3000` (loopback). tortoise **can't and won't** touch it —
  macOS doesn't shape loopback. You're not testing how fast local JS loads, so this doesn't matter.
- **Backend** is a separate **remote** domain that your app's REST + websocket calls go to directly.
  That's the traffic that matters, and it's a real remote host — so tortoise shapes it normally.

```bash
# 1. find the backend domain — in the browser devtools console:
#       localStorage.getItem('domainUrl')
#    (if null, it's just the host in your address bar)

# 2. shape THAT domain, then use your local frontend as usual
sudo ./tortoise.sh on lossy dev-myenv.cloud.example.com
```

**Fidelity note:** this faithfully degrades all *runtime* behavior (API calls, websocket
reconnects, Copilot streaming, interim data) — which is the resilience surface you care about.
It does **not** slow the initial page/asset load, because those come from fast local loopback.
To rehearse a realistic **cold start**, point tortoise at the **deployed env** instead (where the
app and the API share one domain), and shape that.

**Gotcha — backend on `127.0.0.1`:** if your backend runs fully locally, or a hostname maps to
`127.0.0.1` via `/etc/hosts` (e.g. `local.prophecy.io`), it's loopback and **cannot be shaped**
by tortoise (or Network Link Conditioner, or any OS shaper). tortoise detects this and tells you.
Options: (a) point your local frontend at a **remote** backend env and shape that (the usual FE
workflow), or (b) run a proxy like [toxiproxy](https://github.com/Shopify/toxiproxy) in front of
the local backend and point the frontend at the proxy — the proxy injects loss/latency at the app
layer, sidestepping loopback entirely.

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

### Custom presets

A preset is just a **set of conditions** (bandwidth / delay / loss) — it has **no domain**. You
define it once and apply it to any domain(s).

**Define once** (no sudo) — it then works in the CLI *and* appears in the app's preset menus:
```bash
./tortoise.sh define office 20Mbit/s 40 0.5      # name  bandwidth  delayMs  loss%
```

**Apply to one or many domains** — same preset, multiple domains in a single command:
```bash
sudo ./tortoise.sh on office app.prophecy.io api.prophecy.io demo.prophecy.io
```

Defined presets live in `~/.config/tortoise/presets.conf` (override with `TORTOISE_PRESETS`), one per
line: `name  bandwidth  delayMs  loss%`. Edit it directly if you like. `loss%` is a percentage
(`5` = 5%).

**True one-off** (don't want to name it) — pass the params inline where the preset name goes; this
too applies to as many domains as you list:
```bash
sudo ./tortoise.sh on custom:2Mbit/s:250:5 app.prophecy.io api.prophecy.io
```

**"It's not slowing anything down!"** Run `sudo ./tortoise.sh doctor`. Usual causes:
- **HTTP/3 (QUIC)** — now shaped (rules cover UDP/443), so retry if you were on an older build.
- **CDN edge IPs rotated** — `app.prophecy.io` is behind CloudFront; the IPs Chrome uses can
  differ from the ones shaped. `doctor` flags this; re-run `on` to re-resolve. Backend/demo envs
  (not CDN-fronted) are far more reliable to shape.
- **Warm connections** — already-open sockets aren't affected; hard-reload or open a new tab.

Each domain is controlled **independently**, and only **one preset can be active per domain** —
re-running `on` for a domain replaces its preset (it never stacks/double-shapes).

```bash
# different conditions on different domains at the same time:
sudo ./tortoise.sh on lossy app.prophecy.io
sudo ./tortoise.sh on edge  api.prophecy.io

./tortoise.sh list
#   ID  PRESET   DOMAIN            SHAPING
#   1   lossy    app.prophecy.io   8Mbit/s, 200ms RTT, 10% loss
#   2   edge     api.prophecy.io   240Kbit/s, 800ms RTT, 5% loss

sudo ./tortoise.sh off app.prophecy.io   # or:  sudo ./tortoise.sh off 1
sudo ./tortoise.sh off all               # everything, restore network
```

---

## Menu-bar app — Tortoise

A tiny self-contained macOS app (`Tortoise.app`) that lives in the top bar — no Terminal needed.

**Install (just the .dmg):**

1. Open **`Tortoise.dmg`** and drag **Tortoise** into **Applications**.
2. Launch it (Spotlight → "Tortoise"). The 🐢 icon appears in the menu bar.
3. First launch: it's ad-hoc signed (not notarized), so macOS may block it once —
   right-click **Tortoise → Open**, or **System Settings → Privacy & Security → Open Anyway**.

The app is **universal** (Apple Silicon + Intel) and self-contained — it embeds its own copy of
`tortoise.sh`, so nothing else is needed.

**Building the .dmg yourself** (only if you change the code):

```bash
cd app
./package-dmg.sh     # → Tortoise.dmg   (compiles universal, wraps in a drag-to-install DMG)
# or, app only:
./build.sh /Applications
```

It compiles from `TortoiseBar.swift` with the Xcode Command Line Tools — no Xcode project, no
dependencies.

**What you get:**
- A 🐢 icon in the menu bar: **subtle when idle**, **red with a count when a site is being slowed**
  — your at-a-glance "is a bad network active?" hint.
- Click it to see every site being slowed and its speed.
- **Slow down a site…** → pick a speed → type the site. **Back to normal: `<site>`** or **Back to normal (all sites)**.
- **Switch speeds fast:** hover a slowed site → its submenu lists every speed with a ✓ on the active
  one. Click another (e.g. `slow-3g` → `flaky`) to swap it instantly — no retyping the site, and
  silent after the one-time password.
- **Custom speeds:** **New custom speed…** saves a reusable speed (`name bandwidth delayMs loss%`,
  no site). It then appears in every menu, so you apply it to any site — and reuse it across as many
  as you want, same as a built-in. (Anything you `define` on the CLI shows up here too.)
- **Asks for your password once.** The first time you slow/restore a site, macOS shows the standard
  admin prompt; the app uses that to install a passwordless helper, so **every later action is
  silent**. Remove it anytime with `sudo ./tortoise.sh uninstall`.

**Notes:**
- The slowdown lives in the packet filter, not the app — so **Quit warns you** if a site is still
  slowed and offers **Restore & Quit** (vs. Quit anyway). You can also `sudo ./tortoise.sh off all`.
- Want it always available? Add `Tortoise.app` to **System Settings → General → Login Items**.
- First launch of a locally-built, ad-hoc-signed app may need a right-click → **Open** to clear
  Gatekeeper.

---

## Safety & caveats

- **Always run `sudo ./tortoise.sh off all` when you finish.** If you forget, run it later — or just
  reboot; shaping does not persist across restarts. `list` tells you what's still on.
- **It targets the domain's current IPs.** If the site is behind a CDN/load-balancer whose IPs
  rotate, re-run `on` to pick up new IPs. CDN IPs can be shared with other sites, so a few
  unrelated sites on the same CDN may also slow down while it's active — harmless, and it stops
  the moment you run `off`.
- **It won't shape `localhost` / a backend running on your own machine** — macOS doesn't run
  loopback traffic through the shaper. Point it at a remote/LAN host (which is the normal demo
  and dev case, since the app talks to a remote backend).
- **On a VPN**, shape the domain you actually connect to; split-tunnel setups may bypass it.
- It only touches web ports (80/443) for the target IPs, so SSH and other traffic to that host
  are untouched.

---

## How it works (for the curious)

`dnctl` (dummynet) creates two shaped "pipes" — one for upload, one for download — configured
with the profile's bandwidth / delay / loss. `pfctl` routes only TCP traffic to the target
domain's IPs (ports 80/443) through those pipes, via a dedicated `tortoise` anchor layered on top
of your existing packet-filter rules. `off` flushes that anchor, deletes the pipes, and restores
`/etc/pf.conf` — and only disables `pf` if tortoise was the one that enabled it.
