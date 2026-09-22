#!/usr/bin/env bash
# clone-pte.sh — create the dev directory and clone vestmarkone over HTTPS, unattended.
#
# Runs as the normal user (never sudo), from anywhere. Claude Code runs this directly, AFTER
# the user has created their Bitbucket HTTP access token (tokens.md → BITBUCKET_TOKEN), because
# that token is what git uses as the HTTPS password — no prompt, no SSH key.
#
#   $CLAUDE_PLUGIN_ROOT/skills/setup-pte-dev-linux/clone-pte.sh \
#       [--repo <path>] [--branch <name>] [--bitbucket-user <login>]
#
#   --repo             where the checkout goes; default $PTE_REPO, else ${DEV_HOME:-~/dev}/vestmarkone
#   --branch           check out this branch instead of the default (master)
#   --bitbucket-user   Bitbucket login for git; default $BITBUCKET_USER, else the local username
#
# Idempotent: an existing checkout at --repo is left alone. The clone itself takes several
# minutes — the repo is large. Source: Linux/Ubuntu PTE Setup Guide §5 (James Wang).

set -euo pipefail

if [[ $EUID -eq 0 ]]; then
  echo "FAIL: run this as your normal user, not root/sudo" >&2
  exit 1
fi

REPO_ARG=""; BRANCH=""; BB_LOGIN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO_ARG="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --bitbucket-user) BB_LOGIN="$2"; shift 2 ;;
    *) echo "FAIL: unknown argument: $1" >&2; exit 1 ;;
  esac
done

step() { echo "== $* =="; }
skip() { echo "   skip: $*"; }
did()  { echo "   done: $*"; }
note() { echo "   note: $*"; }

# The token lives in ~/.pte-tokens (mode 600, written by the tokens step). Load it here so this
# works from a shell that predates it — Claude Code's — without a new login shell.
# shellcheck disable=SC1091
[[ -f "$HOME/.pte-tokens" ]] && . "$HOME/.pte-tokens"
export BITBUCKET_TOKEN="${BITBUCKET_TOKEN:-${BITBUCKET_ACCESS_TOKEN:-}}"
# Bitbucket usernames are always the local part of the Vestmark email; the Linux login is a last resort.
EMAIL_LOCAL="$(git config --global user.email 2>/dev/null | cut -d@ -f1)"
export BITBUCKET_USER="${BB_LOGIN:-${BITBUCKET_USER:-${EMAIL_LOCAL:-${USER:-$(whoami)}}}}"

REPO_ROOT="${REPO_ARG:-${PTE_REPO:-${DEV_HOME:-$HOME/dev}/vestmarkone}}"
BITBUCKET_HOST="https://bitbucket.vestmarkeng.com"
CLONE_URL="$BITBUCKET_HOST/scm/prod/vestmarkone.git"

# --- 1. git over HTTPS (same helper user-setup.sh installs; idempotent) -------------------------
step "git https credentials for $BITBUCKET_HOST"
HELPER='!f() { [ -n "$BITBUCKET_TOKEN" ] || exit 0; echo "username=${BITBUCKET_USER:-$USER}"; echo "password=$BITBUCKET_TOKEN"; }; f'
if [[ "$(git config --global --get "credential.$BITBUCKET_HOST.helper" 2>/dev/null || true)" == "$HELPER" ]]; then
  skip "credential helper already configured"
else
  git config --global --replace-all "credential.$BITBUCKET_HOST.helper" "$HELPER"
  did "git will authenticate to Bitbucket with BITBUCKET_USER + BITBUCKET_TOKEN"
fi
git config --global credential.helper "cache --timeout=28800"

# --- 2. the checkout ------------------------------------------------------------------------------
step "vestmarkone checkout at $REPO_ROOT"
if [[ -f "$REPO_ROOT/gradlew" ]]; then
  skip "already a vestmarkone checkout ($(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?') @ $(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo '?'))"
elif [[ -e "$REPO_ROOT" ]]; then
  echo "FAIL: $REPO_ROOT exists but is not a vestmarkone checkout — move it aside or pass --repo <other path>" >&2
  exit 1
else
  if [[ -z "$BITBUCKET_TOKEN" ]]; then
    echo "FAIL: BITBUCKET_TOKEN is not set — create the Bitbucket HTTP access token first (tokens.md), then re-run" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$REPO_ROOT")"
  note "cloning as $BITBUCKET_USER — the repo is large, this takes several minutes"
  if ! GIT_TERMINAL_PROMPT=0 git clone ${BRANCH:+--branch "$BRANCH"} "$CLONE_URL" "$REPO_ROOT"; then
    echo "FAIL: clone rejected — check BITBUCKET_USER ('$BITBUCKET_USER') is your Bitbucket login and BITBUCKET_TOKEN has Repository read; a partial directory may need removing: $REPO_ROOT" >&2
    exit 1
  fi
  did "cloned $CLONE_URL → $REPO_ROOT ($(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD))"
fi

echo ""
echo "CLONE: complete"
echo "REPO_ROOT=$REPO_ROOT"
echo "DEV_HOME=$(dirname "$REPO_ROOT")"
