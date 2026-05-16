// U85 Phase D1 — Desktop chrome glue.
//
// Exposes 3 Alpine factories:
//   window.desktopShell()   — top-level page state (rail open, active section)
//   window.desktopSection() — per-section state (loading, error, lastRefresh)
//   window.desktopBreadcrumbs() — breadcrumbs that follow the active section
//
// All sections register themselves with the shell on init so the rail and
// breadcrumbs know what's on the page. The shell uses IntersectionObserver
// to track which section is in view and highlights it in the rail.

(function () {
  'use strict';

  // ── desktopShell — top-level page controller
  window.desktopShell = function (opts) {
    opts = opts || {};
    return {
      // Rail state
      railOpen: window.innerWidth >= 1280,
      isWide: window.innerWidth >= 1280,

      // Section registry
      sections: [], // [{code, name, page}]
      activeCode: null,

      // Breadcrumb crumbs
      bucket: opts.bucket || 'work',      // work | private | build | all
      page:   opts.page   || 'today',     // today | actions | docs | …
      pageName: opts.pageName || 'Today',

      init() {
        // Track viewport changes
        window.addEventListener('resize', () => {
          this.isWide = window.innerWidth >= 1280;
          if (this.isWide) this.railOpen = true;
        });
        // Realm handshake — when toggle changes, every section reloads
        if (window.HomeAI?.registerRealmHandshake) {
          window.HomeAI.registerRealmHandshake(async () => {
            // Each section has its own handshake — this is the umbrella
            // event for the breadcrumb's reactive label.
          });
        }
        // IntersectionObserver: highlight in-view section
        this.$nextTick(() => this.armObserver());
      },

      toggleRail() { this.railOpen = !this.railOpen; },
      closeRail()  { if (!this.isWide) this.railOpen = false; },

      registerSection(code, name) {
        // Called from each desktopSection's init()
        if (!this.sections.some(s => s.code === code)) {
          this.sections.push({ code, name });
        }
      },

      isActive(code) { return this.activeCode === code; },

      scrollTo(code) {
        const el = document.getElementById(code);
        if (!el) return;
        el.scrollIntoView({ behavior: 'smooth', block: 'start' });
        this.activeCode = code;
        history.replaceState(null, '', `#${code}`);
        this.closeRail();
      },

      armObserver() {
        const seen = new Map();
        const opts = { rootMargin: '-80px 0px -60% 0px', threshold: 0 };
        const cb = (entries) => {
          for (const e of entries) {
            seen.set(e.target.id, e.isIntersecting);
          }
          // Pick the highest visible section in document order
          const ids = [...document.querySelectorAll('section[data-section-code]')]
            .map(s => s.id);
          for (const id of ids) {
            if (seen.get(id)) { this.activeCode = id; break; }
          }
        };
        const obs = new IntersectionObserver(cb, opts);
        document.querySelectorAll('section[data-section-code]').forEach(s => obs.observe(s));
        // Initialise from hash
        if (location.hash) {
          const code = location.hash.slice(1);
          if (document.getElementById(code)) this.activeCode = code;
        } else if (this.sections.length) {
          this.activeCode = this.sections[0].code;
        }
      }
    };
  };

  // ── desktopSection — per-section state
  window.desktopSection = function (opts) {
    opts = opts || {};
    return {
      code: opts.code || '???',
      name: opts.name || 'Untitled',
      loading: true,
      error: null,
      lastRefresh: '',
      data: null,            // populated by load()
      sourceSlug: opts.slug, // optional: section auto-loads this slug
      transformRows: opts.transformRows,  // optional: data shape transformer

      init() {
        // Register with the shell so the rail/breadcrumbs know about us.
        const shell = this.$root?._x_dataStack?.find?.(s => s.sections);
        if (shell) shell.registerSection(this.code, this.name);
        // Listen to the unified date-window picker
        window.addEventListener('date-window-changed', (e) => {
          // Re-load with the new window. Pass detail.from/to to the loader.
          this.load(e.detail);
        });
        // Hook into the realm handshake
        if (window.HomeAI?.registerRealmHandshake) {
          window.HomeAI.registerRealmHandshake(async () => { await this.load(); });
        }
        // First load
        this.load();
      },

      async load(window_) {
        if (!this.sourceSlug) {
          this.loading = false;
          return;
        }
        this.loading = true;
        this.error = null;
        try {
          let url = `/api/finance/slug/${this.sourceSlug}`;
          if (window_ && window_.from && window_.to) {
            url += `?date_from=${window_.from}&date_to=${window_.to}`;
          }
          const r = await fetch(url);
          if (!r.ok) throw new Error(`${r.status}`);
          const d = await r.json();
          this.data = this.transformRows ? this.transformRows(d) : d;
          this.lastRefresh = new Date().toLocaleTimeString('en-GB',
            { hour: '2-digit', minute: '2-digit' });
        } catch (e) {
          this.error = e.message || String(e);
        } finally {
          this.loading = false;
        }
      }
    };
  };

  // ── desktopBreadcrumbs — reactive crumbs
  window.desktopBreadcrumbs = function () {
    return {
      bucket: 'work', page: 'today', pageName: 'Today', activeCode: null,
      sectionName: null,

      init() {
        // Pull bucket/page/activeCode from parent shell
        const shell = this.$root?._x_dataStack?.find?.(s => s.sections);
        if (shell) {
          this.bucket = shell.bucket;
          this.page = shell.page;
          this.pageName = shell.pageName;
          // Reactive: when shell.activeCode changes, our crumbs update.
          // Alpine watches this via $watch in the partial; we expose helpers.
          this.shell = shell;
        }
      },

      get activeSectionLabel() {
        if (!this.shell) return null;
        const code = this.shell.activeCode;
        if (!code) return null;
        const s = this.shell.sections.find(x => x.code === code);
        return s ? `§${code} ${s.name}` : `§${code}`;
      },

      bucketUrl() { return `/desktop/${this.bucket}/today`; },
      pageUrl()   { return `/desktop/${this.bucket}/${this.page}`; }
    };
  };
})();
