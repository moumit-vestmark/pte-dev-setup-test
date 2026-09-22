#!/usr/bin/env bash
# check.sh — read-only detection for the PTE Linux dev environment.
#
# Prints one line per check, never changes anything, never uses sudo, and always
# exits 0 so the caller can read the whole report. The last lines are a summary:
#
#   SUMMARY missing=<n> warn=<n>
#   PRIVILEGED_NEEDED=yes|no      (does pte-provision.sh need to run?)
#   PLATFORM=linux|other
#
# Usage:
#   check.sh                     offline checks only (fast)
#   check.sh --probe             also hit each service with the configured credentials
#                                (Jira, Bitbucket REST + git, GitHub org, Jenkins, SonarQube,
#                                AWS SSO). Needs network + VPN/Zscaler.
#   check.sh --reload [--probe]  first load what user-setup.sh wrote — the pte-provision block
#                                of ~/.profile, the pte-dev-tooling block of ~/.bashrc, and
#                                ~/.pte-tokens — so a shell that predates them (Claude Code's)
#                                still sees the new variables. Sourcing ~/.bashrc itself would
#                                not work: Ubuntu's default returns early when non-interactive.
#
# Token VALUES are never printed — only whether they are set and whether they work.

set -uo pipefail

PROBE=0; RELOAD=0; REPO_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --probe) PROBE=1; shift ;;
    --reload) RELOAD=1; shift ;;
    --repo) REPO_ARG="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ $RELOAD -eq 1 ]]; then
  load_block() { # file, begin-marker, end-marker
    [[ -f "$1" ]] || return 0
    local tmp; tmp="$(mktemp)"
    sed -n "/^$2\$/,/^$3\$/p" "$1" > "$tmp"
    # shellcheck disable=SC1090
    . "$tmp"; rm -f "$tmp"
  }
  load_block "$HOME/.profile" '# >>> pte-provision >>>' '# <<< pte-provision <<<'
  load_block "$HOME/.bashrc"  '# >>> pte-dev-tooling >>>' '# <<< pte-dev-tooling <<<'
  export PATH="$HOME/.local/bin:$PATH"
fi

MISSING=0
WARN=0
PRIV=0

ok()   { printf '  OK      %s\n' "$*"; }
miss() { printf '  MISSING %s\n' "$*"; MISSING=$((MISSING+1)); }
warn() { printf '  WARN    %s\n' "$*"; WARN=$((WARN+1)); }
skip() { printf '  SKIP    %s\n' "$*"; }
sect() { printf '\n[%s]\n' "$*"; }
priv() { PRIV=1; }

# Plugin mode: this script lives in the plugin cache, not in the repo. The checkout is wherever
# --repo / PTE_REPO / DEV_HOME say — and may not exist yet (clone-pte.sh creates it).
REPO_ROOT="${REPO_ARG:-${PTE_REPO:-${DEV_HOME:-$HOME/dev}/vestmarkone}}"
HAVE_REPO=0; [[ -f "$REPO_ROOT/gradlew" ]] && HAVE_REPO=1

# --- platform ---------------------------------------------------------------
sect platform
KERNEL="$(uname -s)"
if [[ "$KERNEL" == "Linux" ]]; then
  DISTRO="$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")"
  ok "Linux ($DISTRO)"
  PLATFORM=linux
else
  miss "not Linux ($KERNEL) — this skill is Linux-only"
  PLATFORM=other
fi

# --- /etc/hosts -------------------------------------------------------------
sect hosts
HOSTS_MISSING=()
for h in ui.vm.test api.vm.test auth.vm.test pte.vm.test; do
  getent hosts "$h" >/dev/null 2>&1 || HOSTS_MISSING+=("$h")
done
if [[ ${#HOSTS_MISSING[@]} -eq 0 ]]; then
  ok "ui/api/auth/pte.vm.test all resolve"
else
  miss "not in /etc/hosts: ${HOSTS_MISSING[*]}"; priv
fi

# --- JDK --------------------------------------------------------------------
sect jdk
WANT_JDK="$(grep -oP 'sourceCompatibility\s*=\s*JavaVersion\.VERSION_\K\d+' "$REPO_ROOT/build.gradle" 2>/dev/null | head -1)"
WANT_JDK="${WANT_JDK:-17}"
if dpkg -s "openjdk-${WANT_JDK}-jdk" >/dev/null 2>&1; then
  ok "openjdk-${WANT_JDK}-jdk installed (build.gradle wants ${WANT_JDK})"
else
  miss "openjdk-${WANT_JDK}-jdk package not installed (build.gradle wants ${WANT_JDK})"; priv
fi
JAVA_LINE="$(java -version 2>&1 | head -1)"
if [[ "$JAVA_LINE" == *"\"${WANT_JDK}."* ]]; then
  ok "java on PATH is ${WANT_JDK}: $JAVA_LINE"
elif command -v java >/dev/null 2>&1; then
  warn "java on PATH is not ${WANT_JDK}: $JAVA_LINE (update-java-alternatives -s <name>, needs sudo)"
else
  miss "no java on PATH"
fi
if [[ -n "${JAVA_HOME:-}" && -d "${JAVA_HOME:-}" ]]; then
  ok "JAVA_HOME=$JAVA_HOME"
elif [[ -n "${JAVA_HOME:-}" ]]; then
  miss "JAVA_HOME=$JAVA_HOME is set but the directory does not exist"
else
  miss "JAVA_HOME unset"
fi

# --- Docker -----------------------------------------------------------------
sect docker
if dpkg -s docker-ce >/dev/null 2>&1; then
  ok "docker-ce installed ($(docker --version 2>/dev/null))"
elif command -v docker >/dev/null 2>&1; then
  warn "docker present but not the docker-ce package ($(docker --version 2>/dev/null)) — snap/docker.io builds have caused compose issues"
else
  miss "docker not installed"; priv
fi
if systemctl is-active --quiet docker 2>/dev/null; then
  ok "docker service active"
else
  miss "docker service not active"; priv
fi
if id -nG "$USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
  ok "$USER is in the docker group"
else
  miss "$USER not in the docker group"; priv
fi
if docker ps >/dev/null 2>&1; then
  ok "docker daemon reachable without sudo"
elif command -v docker >/dev/null 2>&1; then
  warn "docker ps fails — if the group was just added, log out/in (or open a new terminal)"
fi

# --- git --------------------------------------------------------------------
sect git
if command -v git >/dev/null 2>&1; then
  ok "$(git --version)"
else
  miss "git not installed"; priv
fi
GIT_NAME="$(git config --global user.name 2>/dev/null || true)"
GIT_EMAIL="$(git config --global user.email 2>/dev/null || true)"
[[ -n "$GIT_NAME" ]]  && ok "user.name=$GIT_NAME"   || miss "git user.name unset"
[[ -n "$GIT_EMAIL" ]] && ok "user.email=$GIT_EMAIL" || miss "git user.email unset"
if [[ "$(git config --global merge.renameLimit 2>/dev/null)" == "999999" ]]; then
  ok "merge/diff.renameLimit, core.editor, credential.helper defaults present"
else
  warn "git defaults from the setup guide not applied (renameLimit/editor/credential.helper)"
fi

# --- repo / git over HTTPS -----------------------------------------------------------
sect repo
if [[ $HAVE_REPO -eq 1 ]]; then
  ok "vestmarkone checkout at $REPO_ROOT"
  REMOTE="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
  if [[ "$REMOTE" == https://* ]]; then
    ok "origin uses https"
  elif [[ "$REMOTE" == ssh://* ]]; then
    warn "origin uses ssh ($REMOTE) — SSH has been unreliable for new hires; user-setup.sh switches it to https"
  else
    warn "origin remote unreadable"
  fi
else
  miss "no vestmarkone checkout at $REPO_ROOT — clone-pte.sh creates it (needs BITBUCKET_TOKEN first)"
fi
if git config --global --get credential.https://bitbucket.vestmarkeng.com.helper 2>/dev/null | grep -q BITBUCKET_TOKEN; then
  ok "git credential helper feeds BITBUCKET_USER + BITBUCKET_TOKEN to Bitbucket over https"
else
  miss "git credential helper for bitbucket.vestmarkeng.com not configured — every push/pull will prompt"
fi
if [[ $PROBE -eq 1 ]]; then
  if [[ -z "${BITBUCKET_TOKEN:-${BITBUCKET_ACCESS_TOKEN:-}}" ]]; then
    skip "git https auth (BITBUCKET_TOKEN unset)"
  elif GIT_TERMINAL_PROMPT=0 git ls-remote --exit-code -q https://bitbucket.vestmarkeng.com/scm/prod/vestmarkone.git HEAD >/dev/null 2>&1; then
    ok "git over https authenticates to Bitbucket (ls-remote succeeded without a prompt)"
  else
    miss "git over https rejected — check BITBUCKET_USER is your Bitbucket login and BITBUCKET_TOKEN has Repository read/write"
  fi
else
  skip "git https auth (run with --probe)"
fi

# --- certificates (Zscaler) ------------------------------------------------------
sect certs
if ls /etc/ssl/certs 2>/dev/null | grep -qi zscaler; then
  ok "Zscaler root CA is in the system trust store"
else
  CAND="$(ls "$HOME"/Downloads/*[Zz]scaler*.{crt,cer,pem} 2>/dev/null | head -1 || true)"
  miss "Zscaler root CA not in /etc/ssl/certs${CAND:+ — candidate file: $CAND}"; priv
fi
if [[ "${NODE_EXTRA_CA_CERTS:-}" == /etc/ssl/certs/ca-certificates.crt ]]; then
  ok "NODE_EXTRA_CA_CERTS points at the system bundle (Claude Code trusts Zscaler)"
else
  warn "NODE_EXTRA_CA_CERTS unset — Claude Code may fail with UNABLE_TO_GET_ISSUER_CERT_LOCALLY on the Vestmark network"
fi
if [[ "${UV_SYSTEM_CERTS:-}" == "1" ]]; then
  ok "UV_SYSTEM_CERTS=1 (uv trusts the corporate certificate)"
else
  warn "UV_SYSTEM_CERTS unset — uv run/sync fail with 'invalid peer certificate' behind Zscaler"
fi

# --- PTE build environment -------------------------------------------------------
sect pte-env
[[ -n "${DEV_HOME:-}" && -d "${DEV_HOME:-}" ]] && ok "DEV_HOME=$DEV_HOME" || miss "DEV_HOME unset or missing directory"
if [[ -n "${ANT_HOME:-}" && -d "${ANT_HOME:-}" ]]; then ok "ANT_HOME=$ANT_HOME"; else miss "ANT_HOME unset or missing directory (repo has: $(ls -d "$REPO_ROOT"/utilities/tools/ant-* 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ' '))"; fi
if [[ -n "${VIVIPORT_ANT_PROPERTIES_FILE:-}" && -f "${VIVIPORT_ANT_PROPERTIES_FILE:-}" ]]; then
  ok "VIVIPORT_ANT_PROPERTIES_FILE=$VIVIPORT_ANT_PROPERTIES_FILE"
else
  miss "VIVIPORT_ANT_PROPERTIES_FILE unset or file missing"
fi

# --- tooling ------------------------------------------------------------------
sect tooling
for c in uv aws claude python3; do
  if command -v "$c" >/dev/null 2>&1; then ok "$c: $(command -v "$c")"; else miss "$c not on PATH"; fi
done
if command -v gh >/dev/null 2>&1; then ok "gh: $(command -v gh)"; else miss "gh (GitHub CLI) not installed — pte-provision.sh installs it"; priv; fi
command -v node >/dev/null 2>&1 && ok "node: $(node --version 2>/dev/null) (optional — Playwright MCP)" || skip "node not present (only needed for the Playwright MCP / UI work)"

# --- GitHub (private claude-toolkit repo, HTTPS via gh) --------------------------------------
sect github
if ! command -v gh >/dev/null 2>&1; then
  skip "gh checks (not installed)"
elif gh auth token >/dev/null 2>&1; then
  ok "gh is logged in to github.com"
  if git config --global --get credential.https://github.com.helper 2>/dev/null | grep -q 'gh auth git-credential'; then
    ok "git uses gh as the credential helper for github.com"
  else
    warn "git credential helper for github.com not set — claude-setup.sh runs 'gh auth setup-git'"
  fi
  if [[ $PROBE -eq 1 ]]; then
    if gh api user/orgs --jq '.[].login' 2>/dev/null | grep -qx Vestmark; then ok "GitHub account is in the Vestmark organization"
    else miss "GitHub account not in the Vestmark org (or token not SSO-authorized) — see tokens.md 'GitHub'"; fi
  else
    skip "Vestmark org membership (run with --probe)"
  fi
else
  miss "gh not logged in — see tokens.md 'GitHub' (gh auth login --hostname github.com --git-protocol https --web)"
fi
[[ -d "$HOME/.claude/plugins/marketplaces/claude-toolkit" ]] && ok "claude-toolkit marketplace registered" || miss "claude-toolkit marketplace not registered (needs GitHub access above)"

# --- Claude Code + Bedrock ---------------------------------------------------------
sect claude-code
SETTINGS="$HOME/.claude/settings.json"
if [[ -f "$SETTINGS" ]]; then
  BEDROCK="$(python3 -c "import json,sys;d=json.load(open('$SETTINGS'));e=d.get('env',{});print(e.get('CLAUDE_CODE_USE_BEDROCK',''),e.get('AWS_PROFILE',''),d.get('awsAuthRefresh',''))" 2>/dev/null || true)"
  read -r USE_BEDROCK AWS_PROF _ <<<"$BEDROCK"
  if [[ "$USE_BEDROCK" == "1" && -n "$AWS_PROF" ]]; then
    ok "~/.claude/settings.json: Bedrock enabled, AWS_PROFILE=$AWS_PROF"
  else
    miss "~/.claude/settings.json exists but Bedrock is not configured (CLAUDE_CODE_USE_BEDROCK/AWS_PROFILE)"
  fi
  MODELS_OK="$(python3 -c "import json;d=json.load(open('$SETTINGS'));e=d.get('env',{});print('yes' if all(k in e for k in ('ANTHROPIC_DEFAULT_SONNET_MODEL','ANTHROPIC_DEFAULT_OPUS_MODEL','ANTHROPIC_DEFAULT_HAIKU_MODEL')) else 'no')" 2>/dev/null || echo no)"
  [[ "$MODELS_OK" == yes ]] && ok "Bedrock model IDs pinned in settings.json" || warn "ANTHROPIC_DEFAULT_*_MODEL not all set in settings.json"
else
  miss "~/.claude/settings.json missing"
  AWS_PROF=""
fi
AWS_PROF="${AWS_PROF:-dev-tools}"
if grep -q "^\[profile ${AWS_PROF}\]" "$HOME/.aws/config" 2>/dev/null; then
  ok "aws profile '$AWS_PROF' configured in ~/.aws/config"
else
  miss "aws profile '$AWS_PROF' not in ~/.aws/config (aws configure sso --profile $AWS_PROF — interactive, human step)"
fi
if [[ $PROBE -eq 1 ]] && command -v aws >/dev/null 2>&1; then
  if aws sts get-caller-identity --profile "$AWS_PROF" >/dev/null 2>&1; then
    ok "aws sso session valid for '$AWS_PROF'"
  else
    warn "aws sso session for '$AWS_PROF' not valid — run: aws sso login --profile $AWS_PROF"
  fi
else
  skip "aws sso session validity (run with --probe)"
fi

# --- plugins & MCP servers --------------------------------------------------------
sect mcp
if python3 -c "import json,sys;d=json.load(open('$SETTINGS'));sys.exit(0 if any(k.startswith('claude-toolkit@') and v for k,v in d.get('enabledPlugins',{}).items()) else 1)" 2>/dev/null; then
  ok "claude-toolkit plugin enabled (sonarqube + java-lsp MCP servers)"
else
  miss "claude-toolkit plugin not installed/enabled"
fi
if python3 -c "import json,sys;d=json.load(open('$HOME/.claude.json'));sys.exit(0 if 'glean_default' in d.get('mcpServers',{}) else 1)" 2>/dev/null; then
  ok "glean_default MCP registered (user scope)"
else
  miss "glean_default MCP not registered"
fi
[[ -f "$REPO_ROOT/.mcp.json" ]] && ok "pte-mssql MCP auto-registered via repo .mcp.json" || warn "repo .mcp.json missing — pte-mssql MCP unavailable on this branch"
if [[ -n "${JAVA_LSP_JAVA_HOME:-}" && -n "${JAVA_LSP_PROJECT_ROOT:-}" ]]; then
  if [[ -S "${JAVA_LSP_SOCKET:-/tmp/jdtls-vestmarkone.sock}" ]]; then
    ok "java-lsp configured and daemon socket present"
  else
    warn "java-lsp env set but no daemon socket — run /setup-java-lsp"
  fi
else
  miss "java-lsp not configured (JAVA_LSP_JAVA_HOME / JAVA_LSP_PROJECT_ROOT) — run /setup-java-lsp"
fi

# --- environment variables for skills & MCP --------------------------------------------
sect env-vars
set_or_miss() { local n="$1" what="$2"; if [[ -n "${!n:-}" ]]; then ok "$n set"; else miss "$n unset — $what"; fi; }
set_or_warn() { local n="$1" what="$2"; if [[ -n "${!n:-}" ]]; then ok "$n set"; else warn "$n unset — $what"; fi; }
set_or_miss ATLASSIAN_USER      "your Vestmark email (Jira/Confluence skills)"
set_or_miss ATLASSIAN_TOKEN     "Atlassian API token"
set_or_warn ATLASSIAN_BASE_URL  "defaults to https://vestmark.atlassian.net in most skills"
set_or_warn BITBUCKET_URL       "https://bitbucket.vestmarkeng.com"
set_or_warn BITBUCKET_PROJECT   "PROD"
set_or_warn BITBUCKET_REPO      "vestmarkone"
set_or_miss BITBUCKET_USER      "your Bitbucket login (also the git-over-https username)"
if [[ -n "${BITBUCKET_TOKEN:-}" ]]; then ok "BITBUCKET_TOKEN set (also authenticates git push/pull)"
elif [[ -n "${BITBUCKET_ACCESS_TOKEN:-}" ]]; then warn "only BITBUCKET_ACCESS_TOKEN (old name) set — the tooling block aliases it to BITBUCKET_TOKEN"
else miss "BITBUCKET_TOKEN unset — Bitbucket personal access token"; fi
set_or_miss JENKINS_USER        "your Jenkins username"
if [[ -n "${JENKINS_TOKEN:-}" ]]; then ok "JENKINS_TOKEN set"
elif [[ -n "${JENKINS_ACCESS_TOKEN:-}" ]]; then warn "only JENKINS_ACCESS_TOKEN (old name) set — the tooling block aliases it to JENKINS_TOKEN"
else miss "JENKINS_TOKEN unset — Jenkins API token"; fi
set_or_warn JENKINS_BASE_URL    "https://jenkins.vestmarkeng.com"
set_or_warn SONARQUBE_URL       "https://sonarqube.vestmarkeng.com"
set_or_miss SONARQUBE_TOKEN     "SonarQube user token (also feeds the sonarqube MCP server)"
for v in MSSQL_SERVER MSSQL_PORT MSSQL_USER MSSQL_PASSWORD MSSQL_DATABASE; do
  set_or_miss "$v" "pte-mssql MCP connection (user-setup.sh derives these from the repo)"
done

# --- credential probes ----------------------------------------------------------------
sect probes
if [[ $PROBE -eq 1 ]]; then
  probe_http() { # name url [curl args...]
    local name="$1" url="$2"; shift 2
    local code
    code="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' "$@" "$url" 2>/dev/null || echo 000)"
    case "$code" in
      200) ok "$name: authenticated (200)" ;;
      401|403) miss "$name: rejected ($code) — token wrong, expired, or under-scoped" ;;
      000) warn "$name: no response — network/VPN/certificate problem, not a token problem" ;;
      *) warn "$name: unexpected HTTP $code" ;;
    esac
  }
  if [[ -n "${ATLASSIAN_USER:-}" && -n "${ATLASSIAN_TOKEN:-}" ]]; then
    probe_http "jira/confluence" "${ATLASSIAN_BASE_URL:-https://vestmark.atlassian.net}/rest/api/3/myself" -u "$ATLASSIAN_USER:$ATLASSIAN_TOKEN"
  else skip "jira/confluence probe (credentials unset)"; fi
  BB_TOKEN="${BITBUCKET_TOKEN:-${BITBUCKET_ACCESS_TOKEN:-}}"
  if [[ -n "$BB_TOKEN" ]]; then
    probe_http "bitbucket" "${BITBUCKET_URL:-https://bitbucket.vestmarkeng.com}/rest/api/1.0/projects/${BITBUCKET_PROJECT:-PROD}/repos/${BITBUCKET_REPO:-vestmarkone}" -H "Authorization: Bearer $BB_TOKEN"
  else skip "bitbucket probe (token unset)"; fi
  JK_TOKEN="${JENKINS_TOKEN:-${JENKINS_ACCESS_TOKEN:-}}"
  if [[ -n "${JENKINS_USER:-}" && -n "$JK_TOKEN" ]]; then
    JK_BASE="${JENKINS_BASE_URL:-https://jenkins.vestmarkeng.com}"; JK_BASE="${JK_BASE%%/job/*}"
    probe_http "jenkins" "$JK_BASE/api/json?tree=mode" -u "$JENKINS_USER:$JK_TOKEN"
  else skip "jenkins probe (credentials unset)"; fi
  if [[ -n "${SONARQUBE_TOKEN:-}" ]]; then
    SQ_VALID="$(curl -sS -m 15 -H "Authorization: Bearer $SONARQUBE_TOKEN" "${SONARQUBE_URL:-https://sonarqube.vestmarkeng.com}/api/authentication/validate" 2>/dev/null || true)"
    if [[ "$SQ_VALID" == *'"valid":true'* ]]; then ok "sonarqube: token valid"
    elif [[ "$SQ_VALID" == *'"valid":false'* ]]; then miss "sonarqube: token invalid"
    else warn "sonarqube: no usable response — network/VPN/certificate problem"; fi
  else skip "sonarqube probe (token unset)"; fi
else
  skip "service probes (run with --probe after tokens are set)"
fi

# --- summary ---------------------------------------------------------------------
echo
echo "SUMMARY missing=$MISSING warn=$WARN"
echo "PRIVILEGED_NEEDED=$([[ $PRIV -eq 1 ]] && echo yes || echo no)"
echo "PLATFORM=$PLATFORM"
echo "WANT_JDK=$WANT_JDK"
echo "REPO_ROOT=$REPO_ROOT"
echo "HAVE_REPO=$([[ $HAVE_REPO -eq 1 ]] && echo yes || echo no)"
exit 0
