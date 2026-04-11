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

const REPO = process.env.MER_INSTALL_REPO || 'justrach/merjs';
const VERSION = process.env.MER_INSTALL_VERSION || require('./package.json').version;

function getPlatform() {
  const platform = os.platform();
  const arch = os.arch();
  
  const platformMap = {
    'darwin': 'macos',
    'linux': 'linux',
    'win32': 'windows'
  };
  
  const archMap = {
    'x64': 'x86_64',
    'arm64': 'aarch64',
    'ia32': 'x86'
  };
  
  const p = platformMap[platform];
  const a = archMap[arch];
  
  if (!p || !a) {
    throw new Error(`Unsupported platform: ${platform} ${arch}. merjs supports macOS/Linux on x64/arm64.`);
  }
  
  return { platform: p, arch: a };
}

function download(url, dest) {
  return new Promise((resolve, reject) => {
    const file = fs.createWriteStream(dest);
    https.get(url, { redirect: 'follow' }, (response) => {
      if (response.statusCode === 301 || response.statusCode === 302) {
        download(response.headers.location, dest).then(resolve).catch(reject);
        return;
      }
      if (response.statusCode !== 200) {
        reject(new Error(`Download failed: HTTP ${response.statusCode}`));
        return;
      }
      response.pipe(file);
      file.on('finish', () => {
        file.close();
        resolve();
      });
    }).on('error', reject);
  });
}

async function verifyChecksum(binPath, checksumsUrl, assetName) {
  try {
    const checksums = await new Promise((resolve, reject) => {
      https.get(checksumsUrl, { redirect: 'follow' }, (res) => {
        if (res.statusCode === 301 || res.statusCode === 302) {
          https.get(res.headers.location, (res2) => {
            let data = '';
            res2.on('data', chunk => data += chunk);
            res2.on('end', () => resolve(data));
          }).on('error', reject);
          return;
        }
        let data = '';
        res.on('data', chunk => data += chunk);
        res.on('end', () => resolve(data));
      }).on('error', reject);
    });
    
    const lines = checksums.split('\n');
    const expectedLine = lines.find(l => l.includes(assetName));
    if (!expectedLine) {
      console.warn('merjs: checksum not found, skipping verification');
      return;
    }
    
    const expectedHash = expectedLine.split(' ')[0];
    const actualHash = crypto.createHash('sha256').update(fs.readFileSync(binPath)).digest('hex');
    
    if (expectedHash !== actualHash) {
      throw new Error(`Checksum mismatch: expected ${expectedHash}, got ${actualHash}`);
    }
    console.log('merjs: checksum verified');
  } catch (err) {
    console.warn('merjs: checksum verification skipped:', err.message);
  }
}

async function main() {
  const { platform, arch } = getPlatform();
  const assetName = `mer-${platform}-${arch}`;
  const binDir = path.join(__dirname, 'bin');
  const binPath = path.join(binDir, platform === 'windows' ? 'mer.exe' : 'mer');
  
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
  
  try {
    await download(downloadUrl, binPath);
    await verifyChecksum(binPath, checksumsUrl, assetName);
    
    // Make executable on Unix
    if (platform !== 'windows') {
      fs.chmodSync(binPath, 0o755);
    }
    
    console.log(`merjs: installed to ${binPath}`);
    console.log('merjs: run `npx mer init my-app` to get started');
  } catch (err) {
    console.error('merjs: install failed:', err.message);
    process.exit(1);
  }
}

main().catch(err => {
  console.error('merjs: unexpected error:', err);
  process.exit(1);
});
