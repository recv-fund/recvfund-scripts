const assert = require('node:assert/strict');

async function main() {
  const mode = process.argv[2];
  const origin = 'http://127.0.0.1:3001/api/v1';
  const credentials = {
    email: 'release-smoke@example.test',
    password: 'disposable-release-smoke-password-2026',
  };
  async function request(path, body, token) {
    const response = await fetch(`${origin}${path}`, {
      method: body === undefined ? 'GET' : 'POST',
      headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    assert.equal(response.ok, true, `${path}: HTTP ${response.status}`);
    const result = await response.json();
    assert.equal(result.success, true, `${path}: API rejected request`);
    return result.data;
  }
  if (mode === 'create') {
    await request('/setup/createRoot', { ...credentials, fullName: 'Release smoke owner', projectName: 'Release smoke project' });
  }
  const login = await request('/auth/login', credentials);
  const token = login.tokens.accessToken;
  const me = await request('/user/getMe', undefined, token);
  const projectId = me.projects.find((project) => project.name === 'Release smoke project')?.projectId;
  assert.ok(projectId, 'Owner project survived');
  if (mode === 'create') {
    const customer = await request(`/customer/create/${projectId}`, {
      email: 'release-buyer@example.test', externalCustomerId: 'release-smoke-customer',
    }, token);
    await request(`/payment/createLink/${projectId}`, {
      customerId: customer.customerId, amountUsd: '12.345678', invoiceId: 'RELEASE-SMOKE-001',
    }, token);
  }
  const customers = await request(`/customer/getAll/${projectId}`, undefined, token);
  assert.ok(customers.items.some((customer) => customer.externalCustomerId === 'release-smoke-customer'));
  const payments = await request(`/payment/search/${projectId}`, { query: 'RELEASE-SMOKE-001' }, token);
  assert.equal(payments.total, 1);
  assert.equal(payments.items[0].amountUsd, '12.345678');
  assert.equal(payments.items[0].state, 'open');
  console.log(`Passed: ${mode} owner login, customer and precise invoice through the real API`);
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
