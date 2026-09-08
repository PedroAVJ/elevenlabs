#!/usr/bin/env bash
set -euo pipefail

message="ElevenLabs production update $(git rev-parse --short=12 HEAD)"
if [ "${1:-}" = "--message" ]; then
  if [ -z "${2:-}" ]; then
    echo "Usage: $0 [--message MESSAGE]" >&2
    exit 64
  fi
  message="$2"
  shift 2
fi

if [ "$#" -ne 0 ]; then
  echo "Usage: $0 [--message MESSAGE]" >&2
  exit 64
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
repo_root="$(git -C "$project_root" rev-parse --show-toplevel)"
cd "$project_root"

if [ -n "$(git status --porcelain=v1)" ]; then
  echo "Commit or remove local changes before publishing ElevenLabs." >&2
  exit 1
fi

eas=(npx --yes eas-cli@22.2.0)

echo "==> Checking ElevenLabs update contracts"
npm test --prefix "$repo_root"
npm run export:ios
npx expo-updates configuration:syncnative --platform ios --workflow generic
git diff --exit-code -- ios

echo "==> Publishing the production iOS update"
"${eas[@]}" update \
  --channel production \
  --platform ios \
  --environment production \
  --message "$message" \
  --non-interactive

echo "ElevenLabs production update published. Native compilation was not started."
