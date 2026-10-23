#!/usr/bin/env sh
set -eu

: "${GITHUB_TOKEN:?GITHUB_TOKEN not set}"

# Rewrite both ssh:// and scp-style SSH URLs to HTTPS with token auth.
# Using --add so the second insteadOf doesn't replace the first.
git config --global --add "url.https://x-access-token:${GITHUB_TOKEN}@github.com/.insteadOf" "ssh://git@github.com/"
git config --global --add "url.https://x-access-token:${GITHUB_TOKEN}@github.com/.insteadOf" "git@github.com:"

exec "$@"
