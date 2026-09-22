# setup-pte-dev-linux

Sets up — or audits — a Linux/Ubuntu machine for PTE (vestmarkone) development, end to end,
and proves each piece works. Built for new hires (the manual guide routinely costs 1–2 days)
but equally useful on a machine that is "mostly" configured: it detects what is already done
and only touches the gaps.

## Usage

Inside a Claude Code session, from the repo root:

```
/setup-pte-dev-linux            # detect, report, ask what to do
/setup-pte-dev-linux check      # report only, change nothing
/setup-pte-dev-linux tokens     # just the API-token recipe + verification
/setup-pte-dev-linux claude     # just Claude Code / Bedrock / plugin / MCP servers
/setup-pte-dev-linux --jdk 8    # for a PTE 8.6–2024.1 branch (default: what build.gradle says)
```

**Prerequisites:** Claude Code installed (IT's "Install Claude Assistant – Linux Ubuntu"
automation, or the native installer) and this repo cloned over **HTTPS** — that is the supported
path (SSH has been unreliable for recent hires). The skill then configures git to authenticate
with your Bitbucket token, so pushes and pulls stop prompting.

## What gets automated, and by whom

| | Runs as | Who runs it | What |
|---|---|---|---|
| `pte-provision.sh` | root | **you**, in your own terminal (Claude prints the exact command) | `/etc/hosts` entries, Zscaler root CA into the system trust store, OpenJDK, Docker CE + `docker` group, git, unzip, `gh` |
| `user-setup.sh` | you | Claude | git identity/defaults, git-over-HTTPS credential helper for Bitbucket (uses `BITBUCKET_USER` + `BITBUCKET_TOKEN`; no SSH key), origin → https, `uv`, `~/.profile` build vars (`DEV_HOME`, `JAVA_HOME`, `ANT_HOME`, `VIVIPORT_ANT_PROPERTIES_FILE`), personal deployment properties file, `~/.bashrc` tooling block |
| `claude-setup.sh` | you | Claude | aws-cli v2 (user-space), `~/.claude/settings.json` Bedrock config, GitHub via `gh` (`gh auth setup-git`, Vestmark org check), `claude-toolkit` plugin registered by HTTPS URL (sonarqube + java-lsp MCP servers), Glean MCP registration |
| `check.sh [--probe]` | you | Claude | read-only detection; `--probe` authenticates against Jira, Bitbucket (REST + git), GitHub (Vestmark org), Jenkins, SonarQube, AWS SSO |
| `tokens.md` | — | Claude shows one section at a time | click-by-click guide for the GitHub CLI login, each API token, and AWS SSO |

The skill runs **one step at a time**: when a step is yours (the `sudo` script, a browser login,
a token), Claude prints it, waits for you to say it's done, verifies, and only then continues.

Claude never runs `sudo` — from Claude Code's Bash tool it hangs behind AdminByRequest.
The privileged script is one fixed, readable file you run yourself; everything else is
unattended.

### What stays manual (browser or organizational)

- GitHub: creating the account (Vestmark email) and joining the Vestmark org via the Okta
  **GitHub Enterprise** tile — click it once to sign up/sign in, again to be added to the org; no
  IT ticket — then `gh auth login` (browser). `claude-toolkit` is a private repo
- `aws configure sso` / `aws sso login` (Okta in the browser) and Glean's OAuth via `/mcp`
- Creating the four API tokens and typing them with `read -rs` — `tokens.md` has the click path for each
- Slack channels, IntelliJ, a SQL client, HR/IT accounts

### GitHub without SSH

`claude plugin marketplace add vestmark/claude-toolkit` (the shorthand in the toolkit README) makes
Claude Code clone over SSH, which fails on a machine with no key. The skill instead logs the `gh` CLI
in over HTTPS, runs `gh auth setup-git` so git uses `gh auth git-credential` for `github.com`, and
registers the marketplace by URL: `https://github.com/Vestmark/claude-toolkit.git`. Same token
model as Bitbucket — nothing to generate or register by hand.

## Environment variables

`~/.profile` (PTE build — from the [Linux/Ubuntu PTE Setup Guide](https://vestmark.atlassian.net/wiki/spaces/ENGINE/pages/1302233126)):

| Variable | Value written |
|---|---|
| `DEV_HOME` | parent of the checkout, e.g. `~/dev` |
| `JAVA_HOME` | `/usr/lib/jvm/java-1.17.0-openjdk-amd64` (or the JDK 8 path with `--jdk 8`) |
| `ANT_HOME` | `<repo>/utilities/tools/ant-1.9.6` (whatever `ant-*` the branch ships) |
| `VIVIPORT_ANT_PROPERTIES_FILE` | `~/<user>-work-deployment.properties` (created with the two required properties) |

`~/.bashrc` tooling block (Claude Code, MCP servers, skills):

| Variable | Value written | Used by |
|---|---|---|
| `NODE_EXTRA_CA_CERTS` | `/etc/ssl/certs/ca-certificates.crt` | Claude Code behind Zscaler |
| `UV_SYSTEM_CERTS` | `1` | `uv` (every Vestmark MCP server) behind Zscaler |
| `ATLASSIAN_BASE_URL`, `ATLASSIAN_USER` | `https://vestmark.atlassian.net`, your git email | Jira/Confluence skills |
| `BITBUCKET_URL`, `BITBUCKET_PROJECT`, `BITBUCKET_REPO` | `https://bitbucket.vestmarkeng.com`, `PROD`, `vestmarkone` | Bitbucket skills |
| `BITBUCKET_USER` | your login (`--bitbucket-user` to override) | git over HTTPS (credential helper) |
| `JENKINS_BASE_URL`, `JENKINS_USER` | `https://jenkins.vestmarkeng.com`, your login (`--jenkins-user` to override) | Jenkins skills |
| `SONARQUBE_URL` | `https://sonarqube.vestmarkeng.com` | sonarqube MCP + skills |
| `MSSQL_SERVER/PORT/USER/DATABASE/PASSWORD` | `localhost`, `1433`, `sa`, `vmap`, `startupSaPassword` from `gradle.properties` | `pte-mssql` MCP (local docker SQL Server only) |
| token aliases | `BITBUCKET_TOKEN` ↔ `BITBUCKET_ACCESS_TOKEN`, `JENKINS_TOKEN` ↔ `JENKINS_ACCESS_TOKEN` | skills on `master` still read the `*_ACCESS_TOKEN` names; newer ones read `*_TOKEN` |

Existing values are never overwritten (`${VAR:-default}`), and each block is written once
behind a marker comment — edit it by hand afterwards.

## Tokens

Secrets go in `~/.pte-tokens` (mode 600), sourced by the `~/.bashrc` block. Claude walks you
through the missing ones **one at a time** from `tokens.md` — where to click, what permissions
to pick, then a single `read -rs` line to run in a real terminal so the value never enters the
chat — and verifies each one before moving to the next.

| Token | Create it at | Notes |
|---|---|---|
| `ATLASSIAN_TOKEN` | https://id.atlassian.com/manage-profile/security/api-tokens | with `ATLASSIAN_USER` = your Vestmark email |
| `BITBUCKET_TOKEN` | https://bitbucket.vestmarkeng.com/plugins/servlet/access-tokens/manage | Project read, Repository read/write. Also what git uses as your HTTPS password — once set, `git push`/`pull` never prompt |
| `JENKINS_TOKEN` | https://jenkins.vestmarkeng.com/me/configure → API Token | `JENKINS_USER` = login shown top-right in Jenkins |
| `SONARQUBE_TOKEN` | https://sonarqube.vestmarkeng.com/account/security | type: User token |

`check.sh --probe` then confirms each one actually authenticates — an expired or under-scoped
token fails there instead of in the middle of a skill.

## After setup

Open a new terminal (docker group membership and the profile edits need it), relaunch
`claude`, then build: `./gradlew assemble` — the full build plus local deploy described in
the setup guide §8. `setupVMAP` only after Wildfly is serving.

## Sources

- [Linux/Ubuntu PTE Setup Guide](https://vestmark.atlassian.net/wiki/spaces/ENGINE/pages/1302233126) — James Wang
- [Setup Claude Code with AWS Bedrock](https://vestmark.atlassian.net/wiki/spaces/ENGINE/pages/671286730) — Joshua Gan
- [How-to Access Glean from Claude Code](https://vestmark.atlassian.net/wiki/spaces/~712020fe4a4673eb1849fe8bb37a2c253e4511/pages/2067005744) — Seth Lenzi
- [PTE Claude Code – Standardization Initiative](https://vestmark.atlassian.net/wiki/spaces/ENGINE/pages/2232778810) §6 Dev Environment Setup — the origin of VEST-114655
- `mcp/pte-mssql/README.md`, [claude-toolkit README](https://github.com/Vestmark/claude-toolkit)
