// U45 shared dashboard components — date-window picker + site filter.
// Standalone Alpine.js components used by invoices.html, workforce.html, caterbook.html.

(function () {

  /**
   * dateWindow — 5 preset buttons + custom range picker.
   * Presets: today / 7d / mtd / 30d / 90d. Plus a range picker (from/to dates).
   * Persists last selection to localStorage under `homeai-dw-<scope>`.
   *
   * Usage in Alpine:
   *   x-data="dateWindow('invoices')"
   *   x-init="boot()"
   *   <button @click="setPreset('7d')" :class="{active: preset==='7d'}">7d</button>
   *   <input type="date" x-model="customFrom" @change="setCustom()">
   *   <input type="date" x-model="customTo"   @change="setCustom()">
   *
   * Emits via this.fromIso / this.toIso (ISO date strings YYYY-MM-DD)
   * and this.label (e.g. "Last 7 days").
   */
  window.dateWindow = function (scope) {
    return {
      scope: scope,
      preset: '7d',        // default
      customFrom: '',
      customTo: '',
      fromIso: '',
      toIso: '',
      label: '',

      boot() {
        // Restore from localStorage if present
        const saved = localStorage.getItem(`homeai-dw-${this.scope}`);
        if (saved) {
          try {
            const s = JSON.parse(saved);
            if (s.preset === 'custom') {
              this.preset = 'custom'; this.customFrom = s.from; this.customTo = s.to;
              this.setCustom();
              return;
            }
            this.preset = s.preset;
          } catch {}
        }
        this.setPreset(this.preset);
      },

      setPreset(p) {
        this.preset = p;
        const today = new Date();
        const fmt = (d) => d.toISOString().slice(0, 10);
        let from, to;
        const tIso = fmt(today);
        switch (p) {
          case 'today':
            from = tIso; to = tIso; this.label = 'Today'; break;
          case '7d':
            from = fmt(new Date(today.getTime() - 7 * 86400000)); to = tIso; this.label = 'Last 7 days'; break;
          case 'mtd':
            from = `${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, '0')}-01`; to = tIso; this.label = 'Month to date'; break;
          case '30d':
            from = fmt(new Date(today.getTime() - 30 * 86400000)); to = tIso; this.label = 'Last 30 days'; break;
          case '90d':
            from = fmt(new Date(today.getTime() - 90 * 86400000)); to = tIso; this.label = 'Last 90 days'; break;
          default:
            from = fmt(new Date(today.getTime() - 7 * 86400000)); to = tIso; this.label = 'Last 7 days'; this.preset = '7d';
        }
        this.fromIso = from; this.toIso = to;
        this.customFrom = from; this.customTo = to;
        localStorage.setItem(`homeai-dw-${this.scope}`, JSON.stringify({ preset: this.preset }));
        this.$dispatch && this.$dispatch('date-window-changed', { from, to, label: this.label, preset: this.preset });
      },

      setCustom() {
        if (!this.customFrom || !this.customTo) return;
        this.preset = 'custom';
        this.fromIso = this.customFrom; this.toIso = this.customTo;
        this.label = `${this.customFrom} → ${this.customTo}`;
        localStorage.setItem(`homeai-dw-${this.scope}`, JSON.stringify({
          preset: 'custom', from: this.customFrom, to: this.customTo
        }));
        this.$dispatch && this.$dispatch('date-window-changed', {
          from: this.customFrom, to: this.customTo, label: this.label, preset: 'custom'
        });
      },
    };
  };

  /**
   * siteFilter — top-of-page chip strip All / Pub / Café.
   * Persists to localStorage under `homeai-site-<scope>`.
   *
   *   x-data="siteFilter('invoices')"
   *   x-init="boot()"
   *   <button @click="setSite('all')"  :class="{active: site==='all'}">All</button>
   */
  window.siteFilter = function (scope) {
    return {
      scope: scope,
      site: 'all',

      boot() {
        const saved = localStorage.getItem(`homeai-site-${this.scope}`);
        if (saved && ['all', 'pub', 'cafe'].includes(saved)) {
          this.site = saved;
        }
      },

      setSite(s) {
        if (!['all', 'pub', 'cafe'].includes(s)) return;
        this.site = s;
        localStorage.setItem(`homeai-site-${this.scope}`, s);
        this.$dispatch && this.$dispatch('site-changed', { site: s });
      },
    };
  };

})();
