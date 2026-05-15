// U84 — realm toggle (with all Gemini-critique fixes)
//
// Fixes:
//   G1 (Workspace paradox): toggle is [Work | All] — meaningful on every screen,
//       no neutral state.
//   G2 (Cross-tab race): per-page captured realm, set ONCE at load.
//       Fetch reads the captured value, not live localStorage.
//       Background tabs reload via the storage event listener.
//   G2 (Handshake timer): Promise-based registration, not setTimeout fallback.
//
// Public API:
//   HomeAI.getRealm()                          → current captured realm
//   HomeAI.setRealm(next)                      → user-initiated change
//   HomeAI.registerRealmHandshake(async fn)    → page registers a re-fetch
//                                                handler; fn(next, prev) is
//                                                awaited before declaring
//                                                the change "done"
//   HomeAI.dirty = true                        → page sets this to opt into
//                                                discard-confirmation
//
// Events emitted on window:
//   'realm-changed'      detail={ realm }   after handshakes resolve
//
(function () {
  'use strict';

  const STORAGE_KEY = 'homeai.realm';
  const COOKIE_KEY  = 'X-Realm';
  const DEFAULT_REALM = 'work';
  const VALID_REALMS = ['work', 'all'];
  const HANDSHAKE_DEADLINE_MS = 3000;

  // ── Per-tab captured realm — read ONCE at script load (= page boot).
  // The fetch interceptor and any code in this tab uses this value. It only
  // changes when:
  //   (a) HomeAI.setRealm(...) is called explicitly (user clicks toggle)
  //   (b) the page reloads in response to a cross-tab storage event
  let CAPTURED_REALM = readPersistedRealm();
  writeCookie(CAPTURED_REALM);

  function readPersistedRealm() {
    try {
      const v = localStorage.getItem(STORAGE_KEY);
      return VALID_REALMS.includes(v) ? v : DEFAULT_REALM;
    } catch (_) {
      return DEFAULT_REALM;
    }
  }

  function writeCookie(realm) {
    document.cookie = `${COOKIE_KEY}=${realm}; path=/; SameSite=Lax; max-age=2592000`;
  }

  // ── Fetch interceptor (per-tab — uses CAPTURED_REALM, not live storage)
  const origFetch = window.fetch.bind(window);
  window.fetch = function (input, init = {}) {
    const url = typeof input === 'string'
      ? input
      : (input && input.url) || '';
    const isApi = url.startsWith('/api/')
      || url.includes(location.origin + '/api/');
    if (isApi) {
      const headers = new Headers(init.headers || {});
      if (!headers.has('X-Realm')) headers.set('X-Realm', CAPTURED_REALM);
      init = Object.assign({}, init, { headers });
    }
    return origFetch(input, init);
  };

  // ── Cross-tab sync: another tab changed the realm → this tab is stale.
  // We force a graceful reload to re-boot with the new realm baked in.
  // Show a banner first so the user understands why their tab refreshed.
  window.addEventListener('storage', function (e) {
    if (e.key !== STORAGE_KEY) return;
    if (!VALID_REALMS.includes(e.newValue)) return;
    if (e.newValue === CAPTURED_REALM) return;
    showCrossTabBanner(e.newValue);
    setTimeout(function () { location.reload(); }, 800);
  });

  function showCrossTabBanner(next) {
    try {
      const b = document.createElement('div');
      b.setAttribute('role', 'status');
      b.setAttribute('aria-live', 'polite');
      b.style.cssText =
        'position:fixed;top:0;left:0;right:0;z-index:9999;' +
        'background:#0a0a0b;color:#f4f4f5;text-align:center;padding:8px 16px;' +
        'font-family:system-ui,sans-serif;font-size:14px;' +
        'border-bottom:1px solid rgba(251,191,36,0.45);';
      b.textContent = 'Realm changed to "' + next + '" in another tab — refreshing…';
      document.body && document.body.appendChild(b);
    } catch (_) { /* noop — DOM may not be ready */ }
  }

  // ── Handshake registry — pages register an async handler at boot.
  // The toggle awaits ALL of them in parallel with a deadline. If any
  // rejects or the deadline fires, we fall back to location.reload().
  const handshakes = [];
  function registerRealmHandshake(fn) { handshakes.push(fn); }

  // ── Public API namespace
  window.HomeAI = window.HomeAI || {};
  window.HomeAI.getRealm = function () { return CAPTURED_REALM; };
  window.HomeAI.registerRealmHandshake = registerRealmHandshake;
  window.HomeAI.dirty = false;

  window.HomeAI.setRealm = async function (next) {
    if (!VALID_REALMS.includes(next)) return;
    if (next === CAPTURED_REALM) return;

    // Dirty guard — pages with unsaved input set HomeAI.dirty = true
    if (window.HomeAI.dirty === true) {
      const ok = confirm('Discard unsaved changes on this page?');
      if (!ok) return;
    }

    // Persist new realm immediately, BEFORE any handshake work.
    // This guarantees: a hard reload at any moment lands on the new realm.
    try {
      localStorage.setItem(STORAGE_KEY, next);
    } catch (_) { /* private mode etc. */ }
    writeCookie(next);
    const prev = CAPTURED_REALM;
    CAPTURED_REALM = next;

    // If no page-level handshake registered, reload — safest path.
    if (handshakes.length === 0) {
      location.reload();
      return;
    }

    // Parallel handshakes with a deadline. If any rejects or the deadline
    // fires, fall back to a full reload.
    const deadline = new Promise(function (_, rej) {
      setTimeout(function () {
        rej(new Error('realm-handshake-timeout'));
      }, HANDSHAKE_DEADLINE_MS);
    });
    const work = Promise.all(handshakes.map(function (fn) {
      try { return Promise.resolve(fn(next, prev)); }
      catch (e) { return Promise.reject(e); }
    }));
    try {
      await Promise.race([work, deadline]);
      window.dispatchEvent(new CustomEvent('realm-changed', {
        detail: { realm: next, previous: prev }
      }));
    } catch (e) {
      console.warn('[HomeAI.setRealm] handshake failed:', e && e.message);
      location.reload();
    }
  };
})();
