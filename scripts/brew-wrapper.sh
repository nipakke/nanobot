#!/bin/sh
# nanobot: the `brew` entry point the WebUI app runner actually reaches.
#
# nanobot's app runner (nanobot/apps/cli/service.py:_subprocess_env) starts
# installs with only HOME, LANG, TERM, PATH and PYTHONUNBUFFERED, so none of the
# image's HOMEBREW_* variables arrive here. Most of them brew can derive from
# /data/brew/bin/brew itself, but one it cannot: without HOMEBREW_NO_AUTO_UPDATE
# every `brew install` first runs `brew update`, a git fetch that rewrites the
# repository in /data/brew. On Windows + Docker Desktop, that write burst can
# destabilise the Docker engine (docker exec -> HTTP 500, WSL bootstrap
# 0xc00000fd). This wrapper restores the image's intent for the stripped-env
# path and then execs the real binary. An explicit value in the environment
# always wins.
: "${HOMEBREW_PREFIX:=/data/brew}"
: "${HOMEBREW_CELLAR:=$HOMEBREW_PREFIX/Cellar}"
: "${HOMEBREW_REPOSITORY:=$HOMEBREW_PREFIX/Homebrew}"
: "${HOMEBREW_CACHE:=/data/cache/brew}"
# Use `=` (not `:=`) for Homebrew boolean flags so an explicit empty value
# (e.g. `HOMEBREW_NO_AUTO_UPDATE=`) clears the default instead of being
# rewritten back to 1. Homebrew treats any non-empty value (including `0`) as set.
: "${HOMEBREW_NO_AUTO_UPDATE=1}"
: "${HOMEBREW_NO_ANALYTICS=1}"
: "${HOMEBREW_NO_ENV_HINTS=1}"
export HOMEBREW_PREFIX HOMEBREW_CELLAR HOMEBREW_REPOSITORY HOMEBREW_CACHE
export HOMEBREW_NO_AUTO_UPDATE HOMEBREW_NO_ANALYTICS HOMEBREW_NO_ENV_HINTS

exec "${HOMEBREW_PREFIX}/bin/brew" "$@"
