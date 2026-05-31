// One-shot: insert a "Not Caterbook?" guard IF between "Invoice or Report?"
// (true) and "INSERT invoice.detected", so Caterbook daily report emails
// (handled by the dedicated u28 pipeline) never enter the invoice extractor
// and stop dead-lettering at master-router every morning.
const fs = require('fs');
const p = '/tmp/gi2.json';
const d = JSON.parse(fs.readFileSync(p, 'utf8'));
const wf = Array.isArray(d) ? d[0] : d;
if (wf.nodes.find(n => n.name === 'Not Caterbook?')) { console.log('already present'); process.exit(0); }

wf.nodes.push({
  id: 'ep-020b',
  name: 'Not Caterbook?',
  type: 'n8n-nodes-base.if',
  position: [4290, 360],
  typeVersion: 2,
  parameters: {
    conditions: {
      options: {},
      combinator: 'and',
      conditions: [{
        id: 'not-cb-1',
        operator: { type: 'string', operation: 'notContains' },
        leftValue: "={{ $('Sign Payloads').first().json.from_address }}",
        rightValue: 'caterbook.net'
      }]
    }
  }
});

// Rewire: Invoice or Report? (true) -> Not Caterbook? ; keep false branch as-is
const ior = wf.connections['Invoice or Report?'];
ior.main[0] = [{ node: 'Not Caterbook?', type: 'main', index: 0 }];
// Not Caterbook? true -> INSERT invoice.detected ; false -> Write Audit Log (still audited)
wf.connections['Not Caterbook?'] = {
  main: [
    [{ node: 'INSERT invoice.detected', type: 'main', index: 0 }],
    [{ node: 'Write Audit Log', type: 'main', index: 0 }]
  ]
};

fs.writeFileSync(p, JSON.stringify(wf, null, 2));
console.log('guard inserted. Invoice or Report?(true) ->', ior.main[0].map(x => x.node).join(','),
            '| Not Caterbook? ->', wf.connections['Not Caterbook?'].main.map(b => b.map(x => x.node).join(',')).join(' / '));
