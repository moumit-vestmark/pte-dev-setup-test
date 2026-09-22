#!/usr/bin/env bash
# user-setup.sh — the NON-PRIVILEGED half of PTE Linux dev-machine setup.
#
# Runs as the normal user (never sudo) from anywhere; the vestmarkone checkout must
# already exist (clone-pte.sh) at --repo / $PTE_REPO / ${DEV_HOME:-~/dev}/vestmarkone.
# Claude Code runs this directly.
#
#   $CLAUDE_PLUGIN_ROOT/skills/setup-pte-dev-linux/user-setup.sh \
#       [--repo <path>] [--name "Full Name"] [--email you@vestmark.com] [--jdk 17|8] \
#       [--bitbucket-user <login>] [--jenkins-user <login>] [--no-mssql-password]
#
# What it does (each step idempotent, skips cleanly when already satisfied):
#   1. git identity + the guide's git defaults
#   2. git over HTTPS: a credential helper that answers Bitbucket prompts with
#      BITBUCKET_USER + BITBUCKET_TOKEN from the environment (no SSH key, nothing
#      to register in Bitbucket); falls through to a normal prompt until the token exists
#   3. uv (user-space, ~/.local/bin) — runner for every Vestmark MCP server
#   4. ~/.profile block: DEV_HOME, JAVA_HOME, ANT_HOME, VIVIPORT_ANT_PROPERTIES_FILE, PATH
#   5. personal deployment properties file
#   6. ~/.bashrc block: certificate env vars, non-secret service URLs/usernames,
#      MSSQL_* for the pte-mssql MCP (password derived from the repo), and the
#      ~/.pte-tokens hook + old/new token-name aliases
#
# Tokens are NEVER handled here — see SKILL.md "Tokens" for the read -rs recipe
# that writes them to ~/.pte-tokens (mode 600) from a real terminal.
#
# Sources: Linux/Ubuntu PTE Setup Guide (James Wang), mcp/pte-mssql/README.md,
# claude-toolkit README (env vars), Setup Claude Code with AWS Bedrock (certs).

set -euo pipefail

if [[ $EUID -eq 0 ]]; then
  echo "FAIL: run this as your normal user, not root/sudo" >&2
  exit 1
fi

REPO_ARG=""
NAME=""
EMAIL=""
JDK_VERSION=17
BITBUCKET_LOGIN=""
JENKINS_LOGIN=""
MSSQL_PW=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO_ARG="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --email) EMAIL="$2"; shift 2 ;;
    --jdk) JDK_VERSION="$2"; shift 2 ;;
    --bitbucket-user) BITBUCKET_LOGIN="$2"; shift 2 ;;
    --jenkins-user) JENKINS_LOGIN="$2"; shift 2 ;;
    --no-mssql-password) MSSQL_PW=0; shift ;;
    *) echo "FAIL: unknown argument: $1" >&2; exit 1 ;;
  esac
done

step() { echo "== $* =="; }
skip() { echo "   skip: $*"; }
did()  { echo "   done: $*"; }
note() { echo "   note: $*"; }

REPO_ROOT="${REPO_ARG:-${PTE_REPO:-${DEV_HOME:-$HOME/dev}/vestmarkone}}"
if [[ ! -f "$REPO_ROOT/gradlew" ]]; then
  echo "FAIL: no vestmarkone checkout at $REPO_ROOT — run clone-pte.sh first, or pass --repo <path>" >&2
  exit 1
fi

USER_NAME="${USER:-$(whoami)}"
BITBUCKET_HOST="https://bitbucket.vestmarkeng.com"

# --- 1. Git identity and defaults --------------------------------------------
step "git identity"
CURRENT_NAME="$(git config --global user.name 2>/dev/null || true)"
CURRENT_EMAIL="$(git config --global user.email 2>/dev/null || true)"
if [[ -n "$CURRENT_NAME" && -n "$CURRENT_EMAIL" ]]; then
  skip "user.name=$CURRENT_NAME user.email=$CURRENT_EMAIL already set"
else
  if [[ -z "$NAME" || -z "$EMAIL" ]]; then
    echo "FAIL: git user.name/user.email not set and --name/--email not provided" >&2
    exit 1
  fi
  git config --global user.name "$NAME"
  git config --global user.email "$EMAIL"
  CURRENT_NAME="$NAME"; CURRENT_EMAIL="$EMAIL"
  did "set user.name=$NAME user.email=$EMAIL"
fi

step "git defaults"
git config --global core.editor "vi"
git config --global merge.renameLimit 999999
git config --global diff.renameLimit 999999
did "core.editor, merge/diff.renameLimit"

# --- 2. Git over HTTPS -----------------------------------------------------------
# The Bitbucket HTTP access token the skill has the user create doubles as the git
# password. This helper hands it to git from the environment; when the token is not
# set yet it prints nothing, so git falls through to the cache helper / a prompt.
step "git https credentials for $BITBUCKET_HOST"
HELPER='!f() { [ -n "$BITBUCKET_TOKEN" ] || exit 0; echo "username=${BITBUCKET_USER:-$USER}"; echo "password=$BITBUCKET_TOKEN"; }; f'
if [[ "$(git config --global --get "credential.$BITBUCKET_HOST.helper" 2>/dev/null || true)" == "$HELPER" ]]; then
  skip "credential helper already configured"
else
  git config --global --replace-all "credential.$BITBUCKET_HOST.helper" "$HELPER"
  did "git will authenticate to Bitbucket with BITBUCKET_USER + BITBUCKET_TOKEN"
fi
git config --global credential.helper "cache --timeout=28800"
did "fallback: typed passwords cached for 8h"
REMOTE="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
case "$REMOTE" in
  https://*) skip "origin already uses https" ;;
  ssh://*)   git -C "$REPO_ROOT" remote set-url origin "$BITBUCKET_HOST/scm/prod/vestmarkone.git"
             did "origin switched from ssh to https (SSH has been unreliable for new hires)" ;;
  *)         note "could not read origin remote" ;;
esac

# --- 3. uv -------------------------------------------------------------------
step "uv"
if command -v uv >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/uv" ]]; then
  skip "uv already installed ($(uv --version 2>/dev/null || "$HOME/.local/bin/uv" --version))"
else
  curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null
  did "installed uv into ~/.local/bin"
fi

# --- 4. ~/.profile PTE build variables ---------------------------------------------
step "~/.profile PTE build variables"
PROFILE="$HOME/.profile"
P_BEGIN="# >>> pte-provision >>>"
P_END="# <<< pte-provision <<<"
JAVA_HOME_PATH="/usr/lib/jvm/java-1.${JDK_VERSION}.0-openjdk-amd64"
[[ "$JDK_VERSION" == "8" ]] && JAVA_HOME_PATH="/usr/lib/jvm/java-8-openjdk-amd64"
if [[ ! -d "$JAVA_HOME_PATH" ]]; then
  FOUND="$(ls -d /usr/lib/jvm/java-*-openjdk* 2>/dev/null | head -1 || true)"
  [[ -n "$FOUND" ]] && JAVA_HOME_PATH="$FOUND"
fi
ANT_DIR="$(ls -d "$REPO_ROOT"/utilities/tools/ant-[0-9]* 2>/dev/null | head -1 || echo "$REPO_ROOT/utilities/tools/ant-1.9.6")"
PROPS_FILE="$HOME/${USER_NAME}-work-deployment.properties"

if grep -qF "$P_BEGIN" "$PROFILE" 2>/dev/null; then
  skip "$PROFILE already has a pte-provision block (edit it by hand if paths changed)"
else
  {
    echo ""
    echo "$P_BEGIN"
    echo "export DEV_HOME=$(dirname "$REPO_ROOT")"
    echo "export JAVA_HOME=$JAVA_HOME_PATH"
    echo "export ANT_HOME=$ANT_DIR"
    echo "export VIVIPORT_ANT_PROPERTIES_FILE=$PROPS_FILE"
    echo 'if [ -d "$ANT_HOME/bin" ] ; then'
    echo '    PATH="$ANT_HOME/bin:$PATH"'
    echo 'fi'
    echo "$P_END"
  } >> "$PROFILE"
  did "appended DEV_HOME/JAVA_HOME/ANT_HOME/VIVIPORT_ANT_PROPERTIES_FILE/PATH to $PROFILE"
fi

# --- 5. Deployment properties file -------------------------------------------
step "deployment properties file"
if [[ -f "$PROPS_FILE" ]]; then
  skip "$PROPS_FILE already exists"
else
  cat > "$PROPS_FILE" <<EOF
build-enable-sql-service=false
file-relay-consignment-area-path=$REPO_ROOT/temp/deploy/filerelay
EOF
  did "created $PROPS_FILE"
fi

# --- 6. ~/.bashrc tooling block ----------------------------------------------------
step "~/.bashrc tooling block (certs, service URLs, MSSQL, token hook)"
BASHRC="$HOME/.bashrc"
B_BEGIN="# >>> pte-dev-tooling >>>"
B_END="# <<< pte-dev-tooling <<<"
if grep -qF "$B_BEGIN" "$BASHRC" 2>/dev/null; then
  skip "$BASHRC already has a pte-dev-tooling block"
  # Re-running with explicit logins updates the defaults inside the existing block in place.
  if [[ -n "$BITBUCKET_LOGIN" ]]; then
    sed -i -E "s|^(export BITBUCKET_USER=\"\\\$\{BITBUCKET_USER:-)[^}]*(\}.*)$|\1${BITBUCKET_LOGIN}\2|" "$BASHRC"
    did "BITBUCKET_USER default set to '$BITBUCKET_LOGIN' in the existing block"
  fi
  if [[ -n "$JENKINS_LOGIN" ]]; then
    sed -i -E "s|^(export JENKINS_USER=\"\\\$\{JENKINS_USER:-)[^}]*(\}.*)$|\1${JENKINS_LOGIN}\2|" "$BASHRC"
    did "JENKINS_USER default set to '$JENKINS_LOGIN' in the existing block"
  fi
  [[ -z "$BITBUCKET_LOGIN$JENKINS_LOGIN" ]] && note "pass --bitbucket-user / --jenkins-user to change the login defaults; edit other values by hand"
else
  SA_PASSWORD="$(grep -oP '^startupSaPassword=\K.*' "$REPO_ROOT/gradle.properties" 2>/dev/null | head -1 || true)"
  ATL_USER=""
  [[ "$CURRENT_EMAIL" == *@vestmark.com ]] && ATL_USER="$CURRENT_EMAIL"
  BITBUCKET_LOGIN="${BITBUCKET_LOGIN:-$USER_NAME}"
  JENKINS_LOGIN="${JENKINS_LOGIN:-$USER_NAME}"
  {
    echo ""
    echo "$B_BEGIN"
    echo "# written by the pte-dev-setup plugin (setup-pte-dev-linux/user-setup.sh) on $(date -I)"
    echo 'export PATH="$HOME/.local/bin:$PATH"'
    echo '# corporate TLS: make node (Claude Code) and uv trust the system store, which pte-provision.sh seeds with the Zscaler root'
    echo 'export NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt'
    echo 'export UV_SYSTEM_CERTS=1'
    echo '# non-secret service coordinates used by the PTE skills'
    echo 'export ATLASSIAN_BASE_URL="${ATLASSIAN_BASE_URL:-https://vestmark.atlassian.net}"'
    [[ -n "$ATL_USER" ]] && echo "export ATLASSIAN_USER=\"\${ATLASSIAN_USER:-$ATL_USER}\""
    echo "export BITBUCKET_URL=\"\${BITBUCKET_URL:-$BITBUCKET_HOST}\""
    echo 'export BITBUCKET_PROJECT="${BITBUCKET_PROJECT:-PROD}"'
    echo 'export BITBUCKET_REPO="${BITBUCKET_REPO:-vestmarkone}"'
    echo "export BITBUCKET_USER=\"\${BITBUCKET_USER:-$BITBUCKET_LOGIN}\"   # also the git-over-https username"
    echo 'export JENKINS_BASE_URL="${JENKINS_BASE_URL:-https://jenkins.vestmarkeng.com}"'
    echo "export JENKINS_USER=\"\${JENKINS_USER:-$JENKINS_LOGIN}\""
    echo 'export SONARQUBE_URL="${SONARQUBE_URL:-https://sonarqube.vestmarkeng.com}"'
    echo '# pte-mssql MCP server -> the local docker SQL Server (see mcp/pte-mssql/README.md)'
    echo 'export MSSQL_SERVER="${MSSQL_SERVER:-localhost}"'
    echo 'export MSSQL_PORT="${MSSQL_PORT:-1433}"'
    echo 'export MSSQL_USER="${MSSQL_USER:-sa}"'
    echo 'export MSSQL_DATABASE="${MSSQL_DATABASE:-vmap}"'
    if [[ $MSSQL_PW -eq 1 && -n "$SA_PASSWORD" ]]; then
      printf 'export MSSQL_PASSWORD="${MSSQL_PASSWORD:-%s}"   # startupSaPassword from gradle.properties (local dev container only)\n' "$SA_PASSWORD"
    fi
    echo '# personal API tokens live in ~/.pte-tokens (mode 600) — see /setup-pte-dev-linux. BITBUCKET_TOKEN also authenticates git.'
    echo '[ -f "$HOME/.pte-tokens" ] && . "$HOME/.pte-tokens"'
    echo '# old <-> new token names: skills on master still read *_ACCESS_TOKEN, newer ones read *_TOKEN'
    echo 'export BITBUCKET_TOKEN="${BITBUCKET_TOKEN:-${BITBUCKET_ACCESS_TOKEN:-}}"'
    echo 'export BITBUCKET_ACCESS_TOKEN="${BITBUCKET_ACCESS_TOKEN:-${BITBUCKET_TOKEN:-}}"'
    echo 'export JENKINS_TOKEN="${JENKINS_TOKEN:-${JENKINS_ACCESS_TOKEN:-}}"'
    echo 'export JENKINS_ACCESS_TOKEN="${JENKINS_ACCESS_TOKEN:-${JENKINS_TOKEN:-}}"'
    echo "$B_END"
  } >> "$BASHRC"
  did "appended tooling block to $BASHRC"
  [[ -z "$SA_PASSWORD" && $MSSQL_PW -eq 1 ]] && note "startupSaPassword not found in gradle.properties — set MSSQL_PASSWORD by hand"
  note "BITBUCKET_USER and JENKINS_USER assumed to be '$USER_NAME' — pass --bitbucket-user / --jenkins-user if your logins differ"
fi

echo ""
echo "USER SETUP: complete"
echo ""
echo "Still manual (cannot be automated from here):"
echo "  - open a NEW terminal (or: source ~/.profile && source ~/.bashrc) before building or relaunching claude"
echo "  - if pte-provision.sh just added you to the docker group, log out/in for it to take effect"
echo "  - personal API tokens: see the 'Tokens' step in /setup-pte-dev-linux — once BITBUCKET_TOKEN is set, git push/pull need no password"
