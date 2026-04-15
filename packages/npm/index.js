/**
 * merjs - Next.js-style web framework in Zig
 * 
 * This package provides the `mer` CLI tool. The actual binary is downloaded
 * during post-install. This module exports the path to the binary for programmatic use.
 */

const path = require('path');
const os = require('os');
const fs = require('fs');

function getBinaryPath() {
  const platform = os.platform();
  const arch = os.arch();
  
  const platformMap = {
    'darwin': 'macos',
    'linux': 'linux',
    'win32': 'windows'
  };
  
  const p = platformMap[platform];
  if (!p) {
    throw new Error(`Unsupported platform: ${platform}`);
  }
  
  const binName = p === 'windows' ? 'mer.exe' : 'mer';
  return path.join(__dirname, 'bin', binName);
}

function binaryExists() {
  try {
    return fs.existsSync(getBinaryPath());
  } catch {
    return false;
  }
}

module.exports = {
  getBinaryPath,
  binaryExists,
  version: require('./package.json').version
};
