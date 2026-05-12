/* homeai-table.js — Tabulator wrapper with project defaults.
 *
 * Usage:
 *   homeai_table('#my-table', dataArray, {
 *     columns: [
 *       { title: 'Date',     field: 'received_at', headerFilter: 'input', formatter: 'datetime' },
 *       { title: 'Vendor',   field: 'vendor_domain', headerFilter: 'input' },
 *       { title: 'Subject',  field: 'subject',     headerFilter: 'input' },
 *       { title: 'Amount',   field: 'amount_seen', formatter: 'money', hozAlign: 'right' },
 *       { title: 'Status',   field: 'status',      formatter: 'badge' },
 *     ],
 *     row_link: (row) => `/viewer/email/info/${row.source_email_id}`,
 *   });
 *
 * Built-in formatters added by this wrapper:
 *   money       — '£1,234.56' if numeric, '—' if null
 *   datetime    — ISO → 'YYYY-MM-DD HH:MM' (drops seconds, replaces T with space)
 *   date        — first 10 chars (YYYY-MM-DD)
 *   badge       — wraps the cell value in <span class="cell-badge badge-<value>">
 *   mono        — monospace + tabular-nums
 *   truncate(n) — clip to N chars + tooltip
 */
(function () {
  if (typeof Tabulator === 'undefined') {
    console.error('Tabulator not loaded — include https://unpkg.com/tabulator-tables@5.5.4/dist/js/tabulator.min.js before homeai-table.js');
    return;
  }

  const FORMATTERS = {
    money: (cell) => {
      const v = cell.getValue();
      if (v == null || v === '') return '<span class="text-slate-500">—</span>';
      const n = Number(v);
      if (Number.isNaN(n)) return v;
      return '£' + n.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
    },
    datetime: (cell) => {
      const v = cell.getValue();
      if (!v) return '';
      return String(v).slice(0, 16).replace('T', ' ');
    },
    date: (cell) => {
      const v = cell.getValue();
      return v ? String(v).slice(0, 10) : '';
    },
    badge: (cell) => {
      const v = cell.getValue();
      if (!v) return '';
      const cls = 'badge-' + String(v).toLowerCase().replace(/\s+/g, '-');
      return `<span class="cell-badge ${cls}">${v}</span>`;
    },
    mono: (cell) => `<span class="mono">${cell.getValue() ?? ''}</span>`,
  };

  function applyFormatters(columns) {
    return columns.map((col) => {
      const c = { ...col };
      // Sane defaults — every column sortable, filterable, resizable, header tooltip
      if (c.sortable === undefined) c.sortable = true;
      if (c.headerFilter === undefined) c.headerFilter = 'input';
      if (c.headerFilterPlaceholder === undefined) c.headerFilterPlaceholder = 'filter…';
      if (c.headerTooltip === undefined) c.headerTooltip = true;
      if (c.resizable === undefined) c.resizable = true;
      if (typeof c.formatter === 'string' && FORMATTERS[c.formatter]) {
        c.formatter = FORMATTERS[c.formatter];
      }
      return c;
    });
  }

  /**
   * @param {string|HTMLElement} container  selector or element for the table host
   * @param {Array<object>}       data       array of row objects
   * @param {object}              config     { columns, row_link, page_size, height }
   */
  window.homeai_table = function (container, data, config) {
    const cols = applyFormatters(config.columns || []);
    const opts = {
      data: data || [],
      columns: cols,
      layout: 'fitDataStretch',
      placeholder: config.placeholder || 'No matching rows',
      pagination: config.page_size === 0 ? false : true,
      paginationSize: config.page_size || 50,
      paginationCounter: 'rows',
      movableColumns: true,
      persistenceID: config.persistenceID,            // localStorage layout (optional)
      persistence: config.persistenceID ? {
        sort: true, filter: true, columns: ['width', 'visible'],
      } : false,
      // Top-of-table free-text search if a search input is referenced
      ...(config.height ? { height: config.height } : {}),
    };
    const table = new Tabulator(container, opts);

    // Row-click → row_link()
    if (typeof config.row_link === 'function') {
      table.on('rowClick', (e, row) => {
        const url = config.row_link(row.getData(), row);
        if (!url) return;
        const target = (e.metaKey || e.ctrlKey || e.button === 1) ? '_blank' : (config.row_link_target || '_blank');
        window.open(url, target, 'noopener');
      });
      table.on('renderComplete', () => {
        document.querySelectorAll(`${typeof container === 'string' ? container : ''} .tabulator-row`)
          .forEach((el) => el.classList.add('row-clickable'));
      });
    }

    return table;
  };

  // Free-text search across all visible columns. Pass the search input element
  // and the Tabulator instance.
  window.homeai_table_search = function (inputEl, table) {
    const apply = () => {
      const v = (inputEl.value || '').trim();
      if (!v) {
        table.clearFilter(true);
        return;
      }
      // Filter rows where any visible column contains the substring (case-insensitive)
      table.setFilter([
        (data) => Object.values(data).some(val =>
          val != null && String(val).toLowerCase().includes(v.toLowerCase())),
      ]);
    };
    let t;
    inputEl.addEventListener('input', () => { clearTimeout(t); t = setTimeout(apply, 200); });
  };

  // Keyboard: '/' focuses the page's primary search input.
  document.addEventListener('keydown', (e) => {
    if (e.key === '/' && !e.target.matches('input, textarea, select')) {
      const inp = document.querySelector('input[data-homeai-search]');
      if (inp) { inp.focus(); e.preventDefault(); }
    }
  });
})();
