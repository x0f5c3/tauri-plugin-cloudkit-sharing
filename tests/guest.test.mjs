import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import test from 'node:test';

test('ESM and CommonJS package entry points expose the same API', async () => {
  const esm = await import('../dist-js/index.js');
  const require = createRequire(import.meta.url);
  const cjs = require('../dist-js/index.cjs');

  assert.equal(typeof esm.unwrap, 'function');
  assert.equal(typeof cjs.unwrap, 'function');
  assert.equal(typeof esm.commands, 'object');
  assert.equal(typeof cjs.commands, 'object');
  assert.deepEqual(esm.unwrap({ status: 'ok', data: 42 }), 42);
  assert.deepEqual(cjs.unwrap({ status: 'ok', data: 42 }), 42);
  assert.throws(
    () => esm.unwrap({ status: 'error', error: { code: 'test', message: 'boom' } }),
    (error) => error?.code === 'test' && error?.message === 'boom',
  );
});
