// U84 unified date-window picker (per §24 / Jo directive J2).
//
// Canonical date-range filter used on every page that filters by time.
// Replaces ad-hoc inline inputs, u45-components.js usage, and Tabulator
// built-in filters.
//
// Presets: today / yesterday / 7d / 30d / 90d / ytd / custom
// Per-page persistence: localStorage key `homeai.datewindow:<pageKey>`
// Event emitted: `date-window-changed` on window (backwards compat with
//   existing consumers of u45-components.js)
//
// Page integration:
//   {% include "_components/date-window.html" %}
//   window.addEventListener('date-window-changed', (e) => {
//     if (e.detail.pageKey !== location.pathname) return;
//     /* use e.detail.from, e.detail.to */
//   });

window.dateWindow = function (opts) {
  opts = opts || {};
  return {
    pageKey: opts.pageKey || location.pathname,
    preset: opts.defaultPreset || '7d',
    customFrom: null,
    customTo: null,
    showCustom: false,

    presets: [
      { id: 'today',     label: 'Today'     },
      { id: 'yesterday', label: 'Yesterday' },
      { id: '7d',        label: '7d'        },
      { id: '30d',       label: '30d'       },
      { id: '90d',       label: '90d'       },
      { id: 'ytd',       label: 'YTD'       },
    ],

    init() {
      // Restore persisted state for this pageKey
      try {
        const raw = localStorage.getItem(this.lsKey());
        if (raw) {
          const persisted = JSON.parse(raw);
          if (persisted.preset) this.preset = persisted.preset;
          if (persisted.from)   this.customFrom = persisted.from;
          if (persisted.to)     this.customTo = persisted.to;
          if (this.preset === 'custom') this.showCustom = true;
        }
      } catch (_) { /* ignore */ }
      this.emit();
    },

    lsKey() {
      return `homeai.datewindow:${this.pageKey}`;
    },

    // Date helpers — UTC-anchored to avoid TZ drift on day boundaries
    todayISO() {
      const d = new Date();
      return d.toISOString().slice(0, 10);
    },
    daysAgoISO(n) {
      const d = new Date();
      d.setUTCDate(d.getUTCDate() - n);
      return d.toISOString().slice(0, 10);
    },
    yearStartISO() {
      const d = new Date();
      return `${d.getUTCFullYear()}-01-01`;
    },

    range() {
      switch (this.preset) {
        case 'today':     return [this.todayISO(), this.todayISO()];
        case 'yesterday': return [this.daysAgoISO(1), this.daysAgoISO(1)];
        case '7d':        return [this.daysAgoISO(7), this.todayISO()];
        case '30d':       return [this.daysAgoISO(30), this.todayISO()];
        case '90d':       return [this.daysAgoISO(90), this.todayISO()];
        case 'ytd':       return [this.yearStartISO(), this.todayISO()];
        case 'custom':    return [this.customFrom, this.customTo];
        default:          return [this.daysAgoISO(7), this.todayISO()];
      }
    },

    setPreset(id) {
      this.preset = id;
      this.showCustom = false;
      this.persist();
      this.emit();
    },

    toggleCustom() {
      this.showCustom = !this.showCustom;
      if (this.showCustom) {
        // Seed custom range from current preset if not set yet
        if (!this.customFrom || !this.customTo) {
          const [f, t] = this.range();
          this.customFrom = f;
          this.customTo = t;
        }
      }
    },

    applyCustom() {
      if (!this.customFrom || !this.customTo) return;
      if (this.customFrom > this.customTo) {
        // Swap if user entered them backwards
        const tmp = this.customFrom;
        this.customFrom = this.customTo;
        this.customTo = tmp;
      }
      this.preset = 'custom';
      this.persist();
      this.emit();
    },

    persist() {
      try {
        const [from, to] = this.range();
        localStorage.setItem(this.lsKey(), JSON.stringify({
          preset: this.preset, from, to
        }));
      } catch (_) { /* ignore */ }
    },

    emit() {
      const [from, to] = this.range();
      window.dispatchEvent(new CustomEvent('date-window-changed', {
        detail: { pageKey: this.pageKey, from, to, preset: this.preset }
      }));
    },

    // For display
    labelFor(id) {
      const p = this.presets.find(x => x.id === id);
      return p ? p.label : id;
    },
    isActive(id) {
      return this.preset === id;
    }
  };
};
