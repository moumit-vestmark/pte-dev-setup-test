#!/usr/bin/env bash
# pte-provision.sh — the PRIVILEGED (root) half of PTE Linux dev-machine setup.
#
# Run this yourself, in a terminal you are sitting at — never through Claude
# Code's Bash tool (sudo has no TTY there and hangs behind AdminByRequest):
#
#   sudo bash $CLAUDE_PLUGIN_ROOT/skills/setup-pte-dev-linux/pte-provision.sh "$(whoami)" [--jdk 17|8] [--ca /path/to/ZscalerRoot.crt]
#
# Covers: /etc/hosts, Zscaler CA -> system trust, JDK, Docker CE + group, git, unzip, gh.
# Git access (Bitbucket and GitHub) is over HTTPS, so no openssh setup is needed.
#
# Every step is idempotent: it checks current state first and skips cleanly if
# already satisfied, so re-running after a partial failure is always safe. This
# file is the ONLY place sudo/apt-get/hosts/CA-store edits happen for PTE setup.
#
# Sources:
#   Linux/Ubuntu PTE Setup Guide (James Wang)
#     https://vestmark.atlassian.net/wiki/spaces/ENGINE/pages/1302233126
#   Setup Claude Code with AWS Bedrock — Zscaler CA troubleshooting (Joshua Gan)
#     https://vestmark.atlassian.net/wiki/spaces/ENGINE/pages/671286730

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "FAIL: must run as root (invoke via: sudo bash $0 <target-user>)" >&2
  exit 1
fi

TARGET_USER="${1:-}"
if [[ -z "$TARGET_USER" ]]; then
  echo "FAIL: target user required, e.g. sudo bash $0 $(logname 2>/dev/null || echo '<user>')" >&2
  exit 1
fi
if ! id "$TARGET_USER" >/dev/null 2>&1; then
  echo "FAIL: no such user: $TARGET_USER" >&2
  exit 1
fi

JDK_VERSION=17
CA_FILE=""
shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jdk) JDK_VERSION="$2"; shift 2 ;;
    --ca)  CA_FILE="$2"; shift 2 ;;
    *) echo "FAIL: unknown argument: $1" >&2; exit 1 ;;
  esac
done
if [[ "$JDK_VERSION" != "17" && "$JDK_VERSION" != "8" ]]; then
  echo "FAIL: --jdk must be 17 or 8, got: $JDK_VERSION" >&2
  exit 1
fi

step() { echo "== $* =="; }
skip() { echo "   skip: $*"; }
did()  { echo "   done: $*"; }

# --- 1. /etc/hosts entries -------------------------------------------------
step "hosts entries"
HOSTS_NEEDED=(ui.vm.test api.vm.test auth.vm.test pte.vm.test)
HOSTS_MISSING=()
for h in "${HOSTS_NEEDED[@]}"; do
  getent hosts "$h" >/dev/null 2>&1 || HOSTS_MISSING+=("$h")
done
if [[ ${#HOSTS_MISSING[@]} -eq 0 ]]; then
  skip "all of ${HOSTS_NEEDED[*]} already resolve"
else
  {
    echo ""
    echo "# added by setup-pte-dev-linux/pte-provision.sh on $(date -Iseconds)"
    for h in "${HOSTS_MISSING[@]}"; do
      echo "127.0.0.1 $h"
    done
  } >> /etc/hosts
  did "added ${HOSTS_MISSING[*]} to /etc/hosts"
fi

# --- 2. Zscaler root CA into the system trust store ------------------------
# Needed by Claude Code (NODE_EXTRA_CA_CERTS), uv (UV_SYSTEM_CERTS), aws-cli
# and anything else that fetches over HTTPS from the Vestmark network.
step "zscaler root CA"
if ls /etc/ssl/certs 2>/dev/null | grep -qi zscaler; then
  skip "a Zscaler certificate is already in /etc/ssl/certs"
elif [[ -z "$CA_FILE" ]]; then
  echo "   WARNING: no Zscaler CA in the trust store and no --ca given." >&2
  echo "            Get the root certificate from IT (#ask-it-for-help), then re-run with" >&2
  echo "            --ca /path/to/ZscalerRootCertificate.crt" >&2
elif [[ ! -f "$CA_FILE" ]]; then
  echo "FAIL: --ca file not found: $CA_FILE" >&2
  exit 1
else
  DEST="/usr/local/share/ca-certificates/$(basename "${CA_FILE%.*}").crt"
  if openssl x509 -inform pem -in "$CA_FILE" -noout >/dev/null 2>&1; then
    install -m 0644 "$CA_FILE" "$DEST"
  elif openssl x509 -inform der -in "$CA_FILE" -noout >/dev/null 2>&1; then
    openssl x509 -inform der -in "$CA_FILE" -out "$DEST"
    chmod 0644 "$DEST"
  else
    echo "FAIL: $CA_FILE is neither a PEM nor a DER certificate" >&2
    exit 1
  fi
  update-ca-certificates >/dev/null
  did "installed $DEST and refreshed /etc/ssl/certs/ca-certificates.crt"
fi

# --- 3. JDK -----------------------------------------------------------------
step "openjdk-$JDK_VERSION-jdk"
JDK_PKG="openjdk-${JDK_VERSION}-jdk"
if dpkg -s "$JDK_PKG" >/dev/null 2>&1; then
  skip "$JDK_PKG already installed"
else
  apt-get update -qq
  apt-get install -y "$JDK_PKG"
  did "installed $JDK_PKG"
fi

# --- 4. Docker Engine ---------------------------------------------------
step "docker engine"
if command -v docker >/dev/null 2>&1 && dpkg -s docker-ce >/dev/null 2>&1; then
  skip "docker-ce already installed"
else
  apt-get update -qq
  apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi
  UBUNTU_CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  ARCH="$(dpkg --print-architecture)"
  echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $UBUNTU_CODENAME stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  did "installed docker-ce, docker-ce-cli, containerd.io, docker-compose-plugin"
fi

if ! systemctl is-active --quiet docker; then
  systemctl enable --now docker
  did "started and enabled the docker service"
else
  skip "docker service already active"
fi

# --- 5. docker group membership --------------------------------------------
# Group membership replaces the guide's `chmod 666 /var/run/docker.sock`, which
# is reset on every daemon restart and is world-writable.
step "docker group membership for $TARGET_USER"
if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx docker; then
  skip "$TARGET_USER already in the docker group"
else
  usermod -aG docker "$TARGET_USER"
  did "added $TARGET_USER to the docker group (log out/in, or new shell, to take effect)"
fi

# --- 6. Git ------------------------------------------------------------------
step "git"
if command -v git >/dev/null 2>&1; then
  skip "git already installed ($(git --version))"
else
  apt-get update -qq
  apt-get install -y git
  did "installed git"
fi

# --- 7. unzip (aws-cli installer) + gh (GitHub CLI, for the private claude-toolkit repo over HTTPS)
step "unzip + gh"
PKGS_MISSING=()
command -v unzip >/dev/null 2>&1 || PKGS_MISSING+=(unzip)
command -v gh    >/dev/null 2>&1 || PKGS_MISSING+=(gh)
if [[ ${#PKGS_MISSING[@]} -eq 0 ]]; then
  skip "unzip and gh already installed"
else
  apt-get update -qq
  apt-get install -y "${PKGS_MISSING[@]}"
  did "installed ${PKGS_MISSING[*]}"
fi

echo ""
echo "PRIVILEGED PROVISIONING: complete"
echo "JDK: $JDK_VERSION   docker group: takes effect on next login/shell for $TARGET_USER"
echo "Next: back in Claude Code, let /setup-pte-dev-linux re-run its checks and continue with the user-space half."
