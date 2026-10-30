#!/usr/bin/env bash
set -Eeuo pipefail
sudo -v

sudo pacman -S --needed ollama-vulkan vulkan-radeon vulkan-tools
echo "\n\n"
vulkaninfo --summary
echo "\n\n"
lspci -k | grep -A 3 -E 'VGA|Display|3D'

echo "\n\n"
sudo usermod -aG render,video ollama
id ollama
getent group render
getent group video

echo "\n\n"
sudo systemctl enable --now ollama.service
systemctl status ollama.service
ollama --version

echo "\n\n"
curl http://localhost:11434/api/version
