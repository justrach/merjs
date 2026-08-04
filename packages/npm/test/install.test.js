const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const { installBinary, verifyChecksum } = require('../install');

function paths() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'merjs-npm-test-'));
  return {
    bin: path.join(dir, 'mer'),
    temp: path.join(dir, 'mer.download')
  };
}

async function writesBinary(_url, dest) {
  fs.writeFileSync(dest, 'binary');
}

async function expectCleanFailure(checksums) {
  const { bin, temp } = paths();
  const verifier = (binPath, url, asset) =>
    verifyChecksum(binPath, url, asset, async () => checksums);

  await assert.rejects(
    installBinary(bin, temp, 'binary-url', 'checksums-url', 'mer-linux-x86_64', writesBinary, verifier)
  );
  assert.equal(fs.existsSync(temp), false);
  assert.equal(fs.existsSync(bin), false);
}

test('checksum mismatch fails and deletes the temporary binary', async () => {
  await expectCleanFailure(`${'0'.repeat(64)}  mer-linux-x86_64\n`);
});

test('missing checksum entry fails and deletes the temporary binary', async () => {
  const hash = crypto.createHash('sha256').update('binary').digest('hex');
  await expectCleanFailure(`${hash}  mer-linux-aarch64\n`);
});

test('checksum download failure deletes the temporary binary', async () => {
  const { bin, temp } = paths();
  const verifier = (binPath, url, asset) =>
    verifyChecksum(binPath, url, asset, async () => {
      throw new Error('checksum network failure');
    });

  await assert.rejects(
    installBinary(bin, temp, 'binary-url', 'checksums-url', 'mer-linux-x86_64', writesBinary, verifier),
    /checksum network failure/
  );
  assert.equal(fs.existsSync(temp), false);
  assert.equal(fs.existsSync(bin), false);
});

test('download failure deletes a partial temporary binary', async () => {
  const { bin, temp } = paths();
  const failingDownload = async (_url, dest) => {
    fs.writeFileSync(dest, 'partial');
    throw new Error('network failure');
  };

  await assert.rejects(
    installBinary(bin, temp, 'binary-url', 'checksums-url', 'mer-linux-x86_64', failingDownload),
    /network failure/
  );
  assert.equal(fs.existsSync(temp), false);
  assert.equal(fs.existsSync(bin), false);
});

test('malformed checksum entry fails closed', async () => {
  await expectCleanFailure('not-a-checksum mer-linux-x86_64\n');
});
