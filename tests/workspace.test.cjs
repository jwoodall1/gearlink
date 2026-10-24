const assert = require('node:assert/strict');
const { test } = require('node:test');
const { readFileSync } = require('node:fs');
const ts = require('typescript');

// Execute the real server modules with a small in-memory PostgREST adapter.
// This validates selection/count semantics without writing hosted program data.
function loadModule(file, imports = {}) {
  const exports = {};
  const js = ts.transpileModule(readFileSync(file, 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText;
  new Function('require', 'exports', js)(name => {
    if (!(name in imports)) throw new Error(`Unexpected import: ${name}`);
    return imports[name];
  }, exports);
  return exports;
}
const presentation = loadModule('src/lib/presentation.ts');

function clientFor(tables, failure) {
  return {
    auth: { getClaims: async () => ({ data: { claims: { sub: 'current-user', email: 'coach@example.test' } } }) },
    from(table) {
      let rows = [...(tables[table] ?? [])], limit, start = 0, options = {};
      const q = {
        select(_columns, opts = {}) { options = opts; return q; },
        eq(key, value) { rows = rows.filter(r => r[key] === value); return q; },
        neq(key, value) { rows = rows.filter(r => r[key] !== value); return q; },
        is(key, value) { rows = rows.filter(r => r[key] === value); return q; },
        or(filter) { const terms = filter.split(',').map(term => term.split('.')); rows = rows.filter(row => terms.some(([key, operator, value]) => operator === 'eq' && row[key] === value)); return q; },
        order() { return q; },
        limit(n) { limit = n; return q; },
        range(a, b) { start = a; limit = b - a + 1; return q; },
        async maybeSingle() { const result = await q; return { ...result, data: result.data?.[0] ?? null }; },
        then(resolve, reject) {
          const error = failure === table ? new Error('Connection failed') : null;
          return Promise.resolve({ data: error || options.head ? null : rows.slice(start, limit === undefined ? undefined : start + limit), count: options.count ? rows.length : null, error }).then(resolve, reject);
        },
      };
      return q;
    },
  };
}
function appFor(tables, failure) {
  const client = clientFor(tables, failure);
  const workspace = loadModule('src/lib/workspace.ts', {
    react: { cache: fn => fn },
    'next/navigation': { redirect: path => { throw new Error(`Redirect ${path}`); } },
    '@/lib/supabase/server': { createClient: async () => client },
    '@/lib/presentation': presentation,
  });
  return { ...workspace, ...loadModule('src/lib/dashboard.ts', { '@/lib/workspace': workspace }) };
}
const membership = { organization_id: 'own-org', user_id: 'current-user', role: 'coach', organizations: { id: 'own-org', name: 'Our team' } };
const fixture = {
  organization_members: [{ ...membership, user_id: 'colleague', role: 'admin', organization_id: 'other-org', organizations: { id: 'other-org', name: 'Other team' } }, membership],
  equipment: [
    ...Array.from({ length: 18 }, (_, id) => ({ id, organization_id: 'own-org', status: 'available', condition: 'good' })),
    { id: 20, organization_id: 'own-org', status: 'maintenance', condition: 'needs_repair' },
    { id: 21, organization_id: 'own-org', status: 'retired', condition: 'needs_repair' },
    { id: 22, organization_id: 'other-org', status: 'available', condition: 'good' },
  ],
  athletes: [...Array.from({ length: 12 }, (_, id) => ({ id, organization_id: 'own-org', active: true })), { organization_id: 'own-org', active: false }, { organization_id: 'other-org', active: true }],
  equipment_assignments: [...Array.from({ length: 11 }, (_, id) => ({ id, organization_id: 'own-org', returned_at: null })), { organization_id: 'own-org', returned_at: '2026-10-01' }, { organization_id: 'other-org', returned_at: null }],
  equipment_events: [{ organization_id: 'other-org' }, { organization_id: 'own-org' }],
};
test('workspace selects the signed-in membership, not an administrator colleague', async () => {
  const result = await appFor(fixture).getWorkspace();
  assert.equal(result.role, 'coach');
  assert.equal(result.organization.id, 'own-org');
});
test('dashboard counts all records while keeping previews bounded and tenant-scoped', async () => {
  const result = await appFor(fixture).getDashboardData();
  assert.equal(result.equipmentCount, 20);
  assert.equal(result.availableCount, 18);
  assert.equal(result.athleteCount, 12);
  assert.equal(result.assignmentCount, 11);
  assert.equal(result.assignments.length, 8);
  assert.equal(result.attentionCount, 1); // overlapping flags count once; retired excluded
  assert.equal(result.attention.length, 1);
  assert.equal(result.events.length, 1);
});
test('no organization returns complete zero counts and empty lists', async () => {
  const result = await appFor({}).getDashboardData();
  assert.equal(result.organization, null);
  for (const key of ['equipmentCount', 'availableCount', 'athleteCount', 'assignmentCount', 'attentionCount']) assert.equal(result[key], 0);
  assert.deepEqual(result.assignments, []);
});
test('failed counts and failed membership propagate rather than appearing as zero or no organization', async () => {
  await assert.rejects(appFor(fixture, 'equipment').getDashboardData(), /Connection failed/);
  await assert.rejects(appFor(fixture, 'organization_members').getWorkspace(), /Connection failed/);
});
test('related equipment and athletes support object, array, and absent relations', () => {
  assert.equal(presentation.equipmentName({ name: 'Helmet' }), 'Helmet');
  assert.equal(presentation.equipmentName([{ name: 'Helmet' }]), 'Helmet');
  assert.equal(presentation.equipmentName(null), 'Equipment record');
  assert.equal(presentation.athleteName({ first_name: 'Sam', last_name: 'Lee' }), 'Sam Lee');
  assert.equal(presentation.athleteName([{ first_name: 'Sam', last_name: 'Lee' }]), 'Sam Lee');
});
test('pagination rejects invalid offsets and keeps a bounded integer', () => {
  for (const input of [undefined, '0', '-2', 'abc', '1.5', 'Infinity']) assert.equal(presentation.pageNumber(input), 1);
  assert.equal(presentation.pageNumber('2'), 2);
  assert.equal(presentation.pageNumber('100001'), 100000);
});
