#!/bin/sh

set -e
ver=v29.0.0.0

cd "$(dirname "$0")/.."
curl -sL -o /tmp/wgpu.zip "https://github.com/gfx-rs/wgpu-native/releases/dow
  nload/$ver/wgpu-macos-aarch64-release.zip"
unzip -oq /tmp/wgpu.zip -d vendor/wgpu
echo "wgpu-native $ver -> vendor/wgpu/"
