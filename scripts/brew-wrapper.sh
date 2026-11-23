#!/bin/sh
# nanobot: the `brew` entry point the WebUI app runner actually reaches.
#
# nanobot's app runner (nanobot/apps/cli/service.py:_subprocess_env) starts
# installs with only HOME, LANG, TERM, PATH and PYTHONUNBUFFERED, so none of the
# image's HOMEBREW_* variables arrive here. Most of them brew can derive from
# /data/brew/bin/brew itself, but one it cannot: without HOMEBREW_NO_AUTO_UPDATE
# every `brew install` first runs `brew update`, a git fetch that rewrites the
# repository in /data/brew. Measured on Windows + Docker Desktop, that write
# burst repeatedly killed the Docker engine (docker exec -> HTTP 500, then the
# WSL bootstrap failing with 0xc00000fd). This wrapper restores the image's
# intent for the stripped-env path and then execs the real binary. An explicit
# value in the environment always wins.
: "${HOMEBREW_PREFIX:=/data/brew}"
: "${HOMEBREW_CELLAR:=/data/brew/Cellar}"
: "${HOMEBREW_REPOSITORY:=/data/brew/Homebrew}"
: "${HOMEBREW_CACHE:=/data/cache/brew}"
: "${HOMEBREW_NO_AUTO_UPDATE:=1}"
: "${HOMEBREW_NO_ANALYTICS:=1}"
: "${HOMEBREW_NO_ENV_HINTS:=1}"
export HOMEBREW_PREFIX HOMEBREW_CELLAR HOMEBREW_REPOSITORY HOMEBREW_CACHE
export HOMEBREW_NO_AUTO_UPDATE HOMEBREW_NO_ANALYTICS HOMEBREW_NO_ENV_HINTS

exec /data/brew/bin/brew "$@"
