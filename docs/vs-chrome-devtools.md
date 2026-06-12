# Tortoise vs. Chrome DevTools throttling

Chrome DevTools' network throttling and Tortoise look similar (both add latency and cap
bandwidth), but they differ in ways that decide whether you actually reproduce real-world
("conference wifi") failures.

| | **Chrome DevTools throttling** | **Tortoise** |
|---|---|---|
| **Packet loss** | ❌ None — there is no such setting | ✅ 1–10% real loss — *the* websocket killer |
| **Where it acts** | Inside the browser renderer, at the request layer | Real OS packets (`pfctl`/`dnctl` dummynet) |
| **What's affected** | Only that one tab, only while DevTools is open | Every connection to the domain — all tabs, other browsers, native apps |
| **Protocols** | Browser HTTP stack; weak/none for QUIC, no true packet behavior | TCP **and** UDP — so HTTP/3 (QUIC) + websockets get real latency/loss |
| **Failure realism** | Coarse: delays/limits resource fetches | Real TCP/QUIC effects: retransmits, stalls, dropped connections, reconnect storms |
| **Demo use** | Must keep DevTools open on the tab | Menu-bar toggle; works during a live demo with DevTools closed, across navigations |
| **Scope** | Whole tab, but only that tab | One domain system-wide; the rest of your machine stays fast |

## The one that matters most: packet loss

DevTools can only make things **slow**, never **lossy**. But on conference wifi the thing that
breaks an app usually isn't slowness — it's **lost packets** killing long-lived websockets and
streaming responses, triggering reconnects and stalls. With respect to loss, DevTools throttling
is still a *perfect network* — which is exactly the gap that motivated this tool: testing on fast,
lossless office/CI networks never reproduces what users hit in the wild.

## Where DevTools is actually better

- Built-in, zero setup, no password, cross-platform.
- Scopes to a single **tab** (Tortoise scopes to a **domain**, so all tabs on that domain slow down).

For a quick "does this page feel slow while I'm coding" check, DevTools is fine. For rehearsing a
real demo on a realistically hostile network, Tortoise is the only one that reproduces it.

## Bottom line

Tortoise is a **superset for realism**: the same bandwidth/latency knobs, **plus** packet loss,
**plus** it degrades the real network path (websockets, QUIC, everything), **plus** it works in a
live demo. DevTools is the convenient dev-time subset that can't produce the loss-driven failures
you're actually trying to catch.
