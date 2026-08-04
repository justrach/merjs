#!/usr/bin/env node
/**
 * Post-install script for merjs npm package
 * Downloads the appropriate mer binary for the current platform
 */

const https = require('https');
const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');
const { pipeline } = require('stream/promises');

const REPO = process.env.MER_INSTALL_REPO || 'justrach/merjs';
const VERSION = process.env.MER_INSTALL_VERSION || require('./package.json').version;

function getPlatform() {
  const platform = os.platform();
  const arch = os.arch();
  
  const platformMap = {
    'darwin': 'macos',
    'linux': 'linux'
  };
  
  const archMap = {
    'x64': 'x86_64',
    'arm64': 'aarch64'
  };
  
  const p = platformMap[platform];
  const a = archMap[arch];
  
  if (!p || !a) {
    throw new Error(`Unsupported platform: ${platform} ${arch}. merjs supports macOS/Linux on x64/arm64.`);
  }
  
  return { platform: p, arch: a };
}

function getResponse(url, redirects = 5) {
  return new Promise((resolve, reject) => {
    https.get(url, (response) => {
      if (response.statusCode === 301 || response.statusCode === 302 || response.statusCode === 307 || response.statusCode === 308) {
        response.resume();
        if (!response.headers.location || redirects === 0) {
          reject(new Error('Download failed: invalid redirect'));
          return;
        }
        getResponse(new URL(response.headers.location, url).toString(), redirects - 1).then(resolve, reject);
        return;
      }
      if (response.statusCode !== 200) {
        response.resume();
        reject(new Error(`Download failed: HTTP ${response.statusCode}`));
        return;
      }
      resolve(response);
    }).on('error', reject);
  });
}

async function download(url, dest) {
  const response = await getResponse(url);
  await pipeline(response, fs.createWriteStream(dest));
}

async function getText(url) {
  const response = await getResponse(url);
  const chunks = [];
  for await (const chunk of response) {
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString('utf8');
}

function checksumForAsset(checksums, assetName) {
  for (const line of checksums.split('\n')) {
    if (!line.trim()) continue;
    const fields = line.trim().split(/\s+/);
    if (fields.length !== 2) {
      throw new Error(`Invalid checksum entry: ${line}`);
    }
    const [hash, name] = fields;
    if (name === assetName) {
      if (!/^[a-fA-F0-9]{64}$/.test(hash)) {
        throw new Error(`Invalid checksum for ${assetName}`);
      }
      return hash.toLowerCase();
    }
  }
  throw new Error(`Checksum not found for ${assetName}`);
}

async function verifyChecksum(binPath, checksumsUrl, assetName, fetchChecksums = getText) {
  const checksums = await fetchChecksums(checksumsUrl);
  const expectedHash = checksumForAsset(checksums, assetName);
  const actualHash = crypto.createHash('sha256').update(fs.readFileSync(binPath)).digest('hex');

  if (expectedHash !== actualHash) {
    throw new Error(`Checksum mismatch: expected ${expectedHash}, got ${actualHash}`);
  }
  console.log('merjs: checksum verified');
}

async function installBinary(binPath, tempPath, downloadUrl, checksumsUrl, assetName, downloader = download, verifier = verifyChecksum) {
  try {
    fs.rmSync(tempPath, { force: true });
    await downloader(downloadUrl, tempPath);
    await verifier(tempPath, checksumsUrl, assetName);
    fs.chmodSync(tempPath, 0o755);
    fs.renameSync(tempPath, binPath);
  } catch (err) {
    fs.rmSync(tempPath, { force: true });
    throw err;
  }
}

async function main() {
  const { platform, arch } = getPlatform();
  const assetName = `mer-${platform}-${arch}`;
  const binDir = path.join(__dirname, 'bin');
  const binPath = path.join(binDir, 'mer-bin');
  const tempPath = `${binPath}.download`;
  
  // Check if already installed
  if (fs.existsSync(binPath)) {
    console.log('merjs: binary already exists, skipping download');
    return;
  }
  
  fs.mkdirSync(binDir, { recursive: true });
  
  const baseUrl = `https://github.com/${REPO}/releases`;
  const downloadUrl = VERSION === 'latest' || !VERSION.match(/^\d/)
    ? `${baseUrl}/latest/download/${assetName}`
    : `${baseUrl}/download/v${VERSION}/${assetName}`;
  const checksumsUrl = VERSION === 'latest' || !VERSION.match(/^\d/)
    ? `${baseUrl}/latest/download/checksums.txt`
    : `${baseUrl}/download/v${VERSION}/checksums.txt`;
  
  console.log(`merjs: downloading ${assetName}...`);
  await installBinary(binPath, tempPath, downloadUrl, checksumsUrl, assetName);
  
  console.log(`merjs: installed to ${binPath}`);
  console.log('merjs: run `npx mer init my-app` to get started');
}

if (require.main === module) {
  main().catch(err => {
    console.error('merjs: install failed:', err.message);
    process.exit(1);
  });
}

module.exports = { checksumForAsset, download, installBinary, main, verifyChecksum };
