#!/usr/bin/env bash
# claude-setup.sh — Claude Code on AWS Bedrock, the claude-toolkit plugin, and
# the standard MCP servers. Detect-and-fill: every step checks first and only
# changes what is missing. Non-privileged; safe to run from inside a Claude
# Code session (settings are read at the NEXT launch).
#
#   $CLAUDE_PLUGIN_ROOT/skills/setup-pte-dev-linux/claude-setup.sh [--profile dev-tools] [--force-models]
#
# Steps:
#   1. aws-cli v2       — user-space install to ~/.local/aws-cli if missing (no sudo)
#   2. aws sso profile  — DETECT ONLY. `aws configure sso` is interactive + browser,
#                         so the exact command and answers are printed for the human.
#   3. ~/.claude/settings.json — merge the Engineering Bedrock config (existing keys kept)
#   4. GitHub access           — gh CLI over HTTPS (no SSH): `gh auth setup-git`, Vestmark org check;
#                                `gh auth login` itself is a browser flow, printed for the human
#   5. claude-toolkit plugin   — marketplace registered by HTTPS URL + install (sonarqube, java-lsp MCP)
#   6. glean_default MCP       — register at user scope (OAuth happens later via /mcp)
#   7. java-lsp / pte-mssql    — DETECT ONLY; /setup-java-lsp and user-setup.sh own these
#
# Sources:
#   Setup Claude Code with AWS Bedrock (Joshua Gan)
#     https://vestmark.atlassian.net/wiki/spaces/ENGINE/pages/671286730
#   How-to Access Glean from Claude Code (Seth Lenzi)
#     https://vestmark.atlassian.net/wiki/spaces/~712020fe4a4673eb1849fe8bb37a2c253e4511/pages/2067005744
#   claude-toolkit README — https://github.com/Vestmark/claude-toolkit

set -euo pipefail

if [[ $EUID -eq 0 ]]; then
  echo "FAIL: run this as your normal user, not root/sudo" >&2
  exit 1
fi

AWS_PROFILE_NAME="dev-tools"
FORCE_MODELS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) AWS_PROFILE_NAME="$2"; shift 2 ;;
    --force-models) FORCE_MODELS=1; shift ;;
    *) echo "FAIL: unknown argument: $1" >&2; exit 1 ;;
  esac
done

step() { echo "== $* =="; }
skip() { echo "   skip: $*"; }
did()  { echo "   done: $*"; }
human(){ echo "   >>> HUMAN STEP: $*"; }
warn() { echo "   WARN: $*"; }

export PATH="$HOME/.local/bin:$PATH"

# --- 1. aws-cli v2 -------------------------------------------------------------
step "aws-cli v2"
if command -v aws >/dev/null 2>&1 && aws --version 2>&1 | grep -q '^aws-cli/2'; then
  skip "$(aws --version 2>&1)"
else
  if ! command -v unzip >/dev/null 2>&1; then
    echo "FAIL: unzip is required to install aws-cli; pte-provision.sh installs it" >&2
    exit 1
  fi
  TMP="$(mktemp -d)"
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "$TMP/awscliv2.zip"
  unzip -q "$TMP/awscliv2.zip" -d "$TMP"
  "$TMP/aws/install" -i "$HOME/.local/aws-cli" -b "$HOME/.local/bin" >/dev/null
  rm -rf "$TMP"
  did "installed $(aws --version 2>&1) into ~/.local/aws-cli (no sudo)"
fi

# --- 2. aws sso profile ---------------------------------------------------------
step "aws sso profile '$AWS_PROFILE_NAME'"
if grep -q "^\[profile ${AWS_PROFILE_NAME}\]" "$HOME/.aws/config" 2>/dev/null; then
  skip "profile exists in ~/.aws/config"
  if ! aws sts get-caller-identity --profile "$AWS_PROFILE_NAME" >/dev/null 2>&1; then
    human "session expired or never logged in — run in your terminal:  aws sso login --profile $AWS_PROFILE_NAME"
  fi
else
  human "run in your terminal (opens a browser for Okta SSO):"
  echo ""
  echo "       aws configure sso --profile $AWS_PROFILE_NAME"
  echo ""
  echo "       SSO session name : vestmark"
  echo "       SSO start URL    : https://vestmark-hq.awsapps.com/start#/"
  echo "       SSO region       : us-east-1"
  echo "       Scopes           : (accept default: sso:account:access)"
  echo "       AWS account      : eng-dev-tools     (Engineering)   | hq-ai-services (outside Engineering)"
  echo "       AWS role         : DevTools          (Engineering)   | ClaudeCode     (outside Engineering)"
  echo "       Default region   : us-east-1"
  echo "       Output format    : (leave blank)"
  echo ""
  echo "       If the account list is empty, ask IT (#ask-it-for-help) to add you to the VM_SSO_AWSHQ AD group."
fi

# --- 3. ~/.claude/settings.json -------------------------------------------------------
step "~/.claude/settings.json (Bedrock)"
mkdir -p "$HOME/.claude"
SETTINGS="$HOME/.claude/settings.json"
[[ -f "$SETTINGS" ]] && cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d-%H%M%S)"
RESULT="$(python3 - "$SETTINGS" "$AWS_PROFILE_NAME" "$FORCE_MODELS" <<'PY'
import json, os, sys
path, profile, force = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
try:
    with open(path) as f:
        cfg = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    cfg = {}
changed = []
def put(d, key, value, force_key=False):
    if key not in d or (force_key and d[key] != value):
        d[key] = value
        changed.append(key)
put(cfg, "awsAuthRefresh", f"aws sso login --profile {profile}")
put(cfg, "autoUpdatesChannel", "stable")
env = cfg.setdefault("env", {})
put(env, "CLAUDE_CODE_USE_BEDROCK", "1")
put(env, "AWS_REGION", "us-east-1")
put(env, "AWS_PROFILE", profile)
put(env, "ANTHROPIC_MODEL", "opusplan")
models = {
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "us.anthropic.claude-sonnet-5",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "us.anthropic.claude-opus-5",
}
for k, v in models.items():
    put(env, k, v, force_key=force)
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
print(",".join(changed) if changed else "")
PY
)"
if [[ -n "$RESULT" ]]; then
  did "added/updated: $RESULT (previous file backed up alongside)"
  echo "   note: takes effect at the next 'claude' launch"
else
  skip "already has the Engineering Bedrock config"
  find "$HOME/.claude" -maxdepth 1 -name 'settings.json.bak.*' -newermt '-1 minute' -delete 2>/dev/null || true
fi

# --- 4. GitHub access for the private claude-toolkit repo (HTTPS via gh, no SSH) -----------------
step "github access (gh cli)"
TOOLKIT_URL="https://github.com/Vestmark/claude-toolkit.git"
GH_READY=0
if ! command -v gh >/dev/null 2>&1; then
  human "'gh' (GitHub CLI) is not installed — it comes from pte-provision.sh (apt). Run that first, then re-run this script."
elif ! gh auth token >/dev/null 2>&1; then
  human "log the GitHub CLI in, in your terminal (browser/Okta flow — see tokens.md 'GitHub'):"
  echo ""
  echo "       gh auth login --hostname github.com --git-protocol https --web"
  echo ""
  echo "       No Vestmark GitHub access yet (https://github.com/Vestmark 404s)? In Okta click the GitHub Enterprise tile — sign up with your @vestmark.com email if you have no account — then click the tile AGAIN to be added to the Vestmark org. No IT ticket needed."
else
  if git config --global --get credential.https://github.com.helper 2>/dev/null | grep -q 'gh auth git-credential'; then
    skip "git already uses 'gh auth git-credential' for github.com"
  elif OUT="$(gh auth setup-git 2>&1)"; then
    did "git uses 'gh auth git-credential' for github.com (https)"
  else
    warn "gh auth setup-git failed: $(tail -1 <<<"$OUT")"
  fi
  if gh api user/orgs --jq '.[].login' 2>/dev/null | grep -qx Vestmark; then
    did "GitHub account is a member of the Vestmark organization"; GH_READY=1
  else
    human "your GitHub login is not (yet) in the Vestmark organization, or the CLI token is not SSO-authorized for it. In Okta click the GitHub Enterprise tile (again) so SSO adds you to the org, then: gh auth refresh -h github.com  and click Authorize next to Vestmark on the SSO page."
  fi
fi

# --- 5. claude-toolkit plugin ----------------------------------------------------------
step "claude-toolkit plugin"
if ! command -v claude >/dev/null 2>&1; then
  echo "FAIL: 'claude' CLI not on PATH — install via IT's 'Install Claude Assistant' automation, or: curl -fsSL https://claude.ai/install.sh | bash" >&2
  exit 1
fi
if python3 -c "import json,sys;d=json.load(open('$SETTINGS'));sys.exit(0 if any(k.startswith('claude-toolkit@') and v for k,v in d.get('enabledPlugins',{}).items()) else 1)" 2>/dev/null; then
  skip "claude-toolkit already enabled"
elif [[ $GH_READY -ne 1 ]]; then
  skip "claude-toolkit — waiting on GitHub access above; re-run this script once 'gh auth token' works"
else
  if claude plugin marketplace list 2>/dev/null | grep -q 'claude-toolkit'; then
    skip "marketplace already registered"
  else
    # Register by HTTPS URL. The 'vestmark/claude-toolkit' shorthand makes Claude Code try SSH,
    # which this setup deliberately does not configure.
    if ! OUT="$(claude plugin marketplace add "$TOOLKIT_URL" 2>&1)"; then
      echo "FAIL: could not register the claude-toolkit marketplace:" >&2; echo "$OUT" | tail -5 >&2; exit 1
    fi
    did "registered marketplace $TOOLKIT_URL"
  fi
  if ! OUT="$(claude plugin install claude-toolkit 2>&1)"; then
    echo "FAIL: plugin install failed:" >&2; echo "$OUT" | tail -5 >&2; exit 1
  fi
  did "installed claude-toolkit (sonarqube + java-lsp MCP servers, /create-pr, /setup-java-lsp, ...)"
fi

# --- 6. glean_default MCP -------------------------------------------------------------
step "glean_default MCP (user scope)"
if python3 -c "import json,sys;d=json.load(open('$HOME/.claude.json'));sys.exit(0 if 'glean_default' in d.get('mcpServers',{}) else 1)" 2>/dev/null; then
  skip "already registered"
else
  claude mcp add glean_default https://vestmark-be.glean.com/mcp/default --transport http --scope user
  did "registered glean_default"
  human "in your next claude session run /mcp, select glean_default > Authenticate, and complete the Okta login in the browser"
fi

# --- 7. detect-only: java-lsp, pte-mssql -----------------------------------------------
step "java-lsp"
if [[ -S "${JAVA_LSP_SOCKET:-/tmp/jdtls-vestmarkone.sock}" ]]; then
  skip "daemon socket present"
else
  human "run /setup-java-lsp in Claude Code — it installs uv + a portable JDK 21, indexes the repo (~2 min), and persists JAVA_LSP_* to ~/.bashrc"
fi
step "pte-mssql"
if [[ -n "${MSSQL_PASSWORD:-}" ]]; then
  skip "MSSQL_* present in this shell"
else
  echo "   note: MSSQL_* come from the ~/.bashrc block written by user-setup.sh; open a new terminal and relaunch claude to pick them up"
fi

echo ""
echo "CLAUDE SETUP: complete"
echo "Open a new terminal and relaunch 'claude' so settings.json, the plugin, and the new env vars are all picked up."
