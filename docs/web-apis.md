# Web APIs in the JS runtime (surveyed 2026-10-04)

Source: lib/browser/js/dom.ex (DOM, events, URL, storage, history, matchMedia, rAF), lib/browser/js/webapi.ex (JS prelude: fetch, XHR, observers, etc.), typed_arrays.ex.

| Area | Status |
|---|---|
| DOM tree, querySelector(All), classList, dataset, innerHTML, attributes, getBoundingClientRect | real |
| Events: dispatchEvent, createEvent, Event subclasses (Pointer, Touch, Hash/PopState, Message, Error, PromiseRejection) | real |
| Timers, queueMicrotask, requestAnimationFrame, requestIdleCallback | real |
| fetch, Headers, Request, Response, XMLHttpRequest | real but buffered: status, headers, methods, bodies, credentials and abort work; no streaming. `fetch` and an async XHR go out in a process of their own (`__fetchAsync`): the page goes on while the server is slow, and the answer runs as a task. A sync XHR waits (`__fetch`) |
| URL, URLSearchParams | real |
| localStorage, sessionStorage | present (in memory, per page; not persisted) |
| location, history (pushState/replaceState/popstate), navigator, screen | real or mostly static values |
| matchMedia, getComputedStyle | present (check depth against real sites) |
| Custom elements, Shadow DOM (attachShadow), template | present |
| TextEncoder/TextDecoder, typed arrays, ArrayBuffer, DataView | real |
| atob/btoa, structuredClone, Blob/File/FileReader, FormData, DOMParser, XMLSerializer | prelude (JS) versions |
| AbortController/AbortSignal, DOMException | prelude |
| MutationObserver | prelude |
| IntersectionObserver | fires once from getBoundingClientRect |
| ResizeObserver, PerformanceObserver | stubs, never fire |
| Range, Selection | prelude, partial |
| Streams (ReadableStream etc.) | declared, shallow |
| crypto.getRandomValues, randomUUID | real-ish (Math.random, not secure); crypto.subtle is an empty object |
| Intl | fake: toISOString / String(n) / simple compare |
| WeakRef, FinalizationRegistry | fake (strong ref) |
| BigInt | fake (truncated Number) — test262 thread owns this |
| CSS.supports | always false |

## Missing entirely
(WebSocket and dedicated Worker exist since PR 228; scheduler.postTask too.)
EventSource, SharedWorker, BroadcastChannel, MessageChannel, Notification, Clipboard API, canvas getContext (element exists), Audio playback, Web Crypto subtle, performance.mark/measure depth, CustomEvent check, document.cookie (TASKS.md), Geolocation, Cache/Service Worker, TextDecoderStream/CompressionStream.

## Candidates, by value for real sites
1. document.cookie (jar ready; already in TASKS.md)
2. fetch fidelity: real status, statusText, response headers, `ok`, redirected, credentials, POST bodies/Content-Type, and a working abort. Biggest breakage source for SPAs.
3. localStorage/sessionStorage: persist to disk, `storage` event, quota.
4. Real Intl (DateTimeFormat, NumberFormat, PluralRules) for en-US basics; many sites format dates/prices with it.
5. crypto.subtle digest (SHA-1/256/384/512 via :crypto) and secure getRandomValues via :crypto.
6. MessageChannel + BroadcastChannel (cheap, in-process).
7. WebSocket via :gun/:mint? (needs a dependency decision), or EventSource over the existing HTTP layer.
8. ResizeObserver firing on layout, IntersectionObserver on scroll.
9. CSS.supports backed by the real CSS parser; CSS.escape correctness.
10. Canvas 2D (large; needs the painter).
