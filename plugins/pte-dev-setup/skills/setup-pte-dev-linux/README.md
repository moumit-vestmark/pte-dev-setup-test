# setup-pte-dev-linux (pte-dev-setup plugin)

Sets up — or audits — a Linux/Ubuntu machine for PTE (vestmarkone) development, end to end,
**starting from a machine that has only Claude Code on it**, and proves each piece works. It
detects what is already done and only touches the gaps, one step at a time, waiting for you at
every step you must do yourself.

Because it ships as a plugin rather than living inside the PTE repo, it can create `~/dev`, clone
vestmarkone for you, and configure everything the clone needs — the one thing a repo-resident
skill can never do.

## Install (once)

```bash
claude plugin marketplace add https://github.com/Vestmark/claude-toolkit.git      # or the test marketplace URL
claude plugin install pte-dev-setup@claude-toolkit
cd ~ && claude
```

Then `/setup-pte-dev-linux`. Run it from **anywhere** — there is no repo yet.

### Before that (the bootstrap this plugin cannot do for you)

1. **Claude Code on Bedrock** — IT's *Install Claude Assistant – Linux Ubuntu* automation, or the
   [Setup Claude Code with AWS Bedrock](https://vestmark.atlassian.net/wiki/spaces/ENGINE/pages/671286730)
   page: AWS CLI, `aws configure sso --profile dev-tools`, Claude install, `settings.json`.
2. `aws sso login --profile dev-tools`
3. **GitHub** — Okta → *GitHub Enterprise* tile (create the account with your `@vestmark.com` email
   if you have none), click the tile again to join the Vestmark org, then
   `gh auth login --hostname github.com --git-protocol https --web`. (`gh`: `sudo apt install gh`
   if the image lacks it.)
4. The two `claude plugin` commands above.

## What gets automated, and by whom

| | Runs as | Who runs it | What |
|---|---|---|---|
| `pte-provision.sh` | root | **you**, in your own terminal (Claude prints the exact command) | `/etc/hosts` entries, Zscaler root CA into the system trust store, OpenJDK, Docker CE + `docker` group, git, unzip, `gh` |
| `clone-pte.sh` | you | Claude | git-over-HTTPS credential helper for Bitbucket (uses your `BITBUCKET_TOKEN` as the password), `mkdir -p ~/dev`, unattended `git clone` of vestmarkone |
| `user-setup.sh` | you | Claude | git identity/defaults, `uv`, `~/.profile` build vars (`DEV_HOME`, `JAVA_HOME`, `ANT_HOME`, `VIVIPORT_ANT_PROPERTIES_FILE`), personal deployment properties file, `~/.bashrc` tooling block (certs, service URLs, `MSSQL_*` derived from the clone, token hook) |
| `claude-setup.sh` | you | Claude | aws-cli v2 (user-space) if missing, `settings.json` Bedrock config (merged), GitHub via `gh` (`setup-git`, Vestmark org check), `claude-toolkit` plugin by HTTPS URL (sonarqube + java-lsp MCP servers), Glean MCP registration |
| `check.sh [--reload] [--probe]` | you | Claude | read-only detection; `--probe` authenticates against Jira, Bitbucket (REST + git), GitHub (Vestmark org), Jenkins, SonarQube, AWS SSO |
| `tokens.md` | — | Claude shows one section at a time | click-by-click guide for GitHub, each API token, and AWS SSO |

Claude never runs `sudo` — from Claude Code's Bash tool it hangs behind AdminByRequest. The
privileged script is one fixed, readable file you run yourself; everything else is unattended.

### Order of operations

Privileged half → **Bitbucket token** (it doubles as the git password) → **clone** → user-space
setup → GitHub check → Claude/MCP → remaining tokens → verify → restart Claude **from the new
checkout** (`cd ~/dev/vestmarkone && claude`, then `/setup-java-lsp`, `/mcp` → Glean).

### What stays manual (browser or organizational)

- The bootstrap above (Claude Code, AWS SSO, GitHub) and Glean's OAuth via `/mcp`
- Creating the four API tokens and typing them with `read -rp` — `tokens.md` has the click path for each
- Slack channels, IntelliJ, a SQL client, HR/IT accounts

## Environment variables

`~/.profile` (PTE build):

| Variable | Value written |
|---|---|
| `DEV_HOME` | parent of the checkout, e.g. `~/dev` |
| `JAVA_HOME` | `/usr/lib/jvm/java-1.17.0-openjdk-amd64` (or the JDK 8 path with `--jdk 8`) |
| `ANT_HOME` | `<repo>/utilities/tools/ant-1.9.6` (whatever `ant-*` the branch ships) |
| `VIVIPORT_ANT_PROPERTIES_FILE` | `~/<user>-work-deployment.properties` (created with the two required properties) |

`~/.bashrc` tooling block:

| Variable | Value written | Used by |
|---|---|---|
| `NODE_EXTRA_CA_CERTS`, `UV_SYSTEM_CERTS` | system bundle, `1` | Claude Code and `uv` behind Zscaler |
| `ATLASSIAN_BASE_URL`, `ATLASSIAN_USER` | `https://vestmark.atlassian.net`, your git email | Jira/Confluence skills |
| `BITBUCKET_URL`, `BITBUCKET_PROJECT`, `BITBUCKET_REPO`, `BITBUCKET_USER` | server, `PROD`, `vestmarkone`, your email local-part (always the Bitbucket username) | Bitbucket skills + git over HTTPS |
| `JENKINS_BASE_URL`, `JENKINS_USER` | server, your email local-part | Jenkins skills |
| `SONARQUBE_URL` | server | sonarqube MCP + skills |
| `MSSQL_SERVER/PORT/USER/DATABASE/PASSWORD` | `localhost`, `1433`, `sa`, `vmap`, `startupSaPassword` from `gradle.properties` | `pte-mssql` MCP (local docker SQL Server only) |
| token aliases | `BITBUCKET_TOKEN` ↔ `BITBUCKET_ACCESS_TOKEN`, `JENKINS_TOKEN` ↔ `JENKINS_ACCESS_TOKEN` | old and new skill variable names both work |

Existing values are never overwritten (`${VAR:-default}`); each block is written once behind a
marker comment. Re-running `user-setup.sh --bitbucket-user/--jenkins-user` updates those defaults
in place.

## Tokens

Secrets go in `~/.pte-tokens` (mode 600), sourced by the `~/.bashrc` block. Claude walks you
through the missing ones one at a time from `tokens.md` — where to click, which permissions, then
a single `read -rp` line to run in a real terminal so the value never enters the chat — and
verifies each with `check.sh --probe` before moving on.

| Token | Create it at | Notes |
|---|---|---|
| `BITBUCKET_TOKEN` | https://bitbucket.vestmarkeng.com/plugins/servlet/access-tokens/manage | Project read, Repository read/write. **First** — it is also the git HTTPS password the clone uses |
| `ATLASSIAN_TOKEN` | https://id.atlassian.com/manage-profile/security/api-tokens | with `ATLASSIAN_USER` = your Vestmark email |
| `JENKINS_TOKEN` | https://jenkins.vestmarkeng.com/me/configure → API Token | `JENKINS_USER` = login shown in that page's URL |
| `SONARQUBE_TOKEN` | https://sonarqube.vestmarkeng.com/account/security | type: User token |

## Sources

- [Linux/Ubuntu PTE Setup Guide](https://vestmark.atlassian.net/wiki/spaces/ENGINE/pages/1302233126) — James Wang
- [Setup Claude Code with AWS Bedrock](https://vestmark.atlassian.net/wiki/spaces/ENGINE/pages/671286730) — Joshua Gan
- [How-to Access Glean from Claude Code](https://vestmark.atlassian.net/wiki/spaces/~712020fe4a4673eb1849fe8bb37a2c253e4511/pages/2067005744) — Seth Lenzi
- [PTE Claude Code – Standardization Initiative](https://vestmark.atlassian.net/wiki/spaces/ENGINE/pages/2232778810) §6 — the origin of VEST-114655
- `mcp/pte-mssql/README.md`, [claude-toolkit README](https://github.com/Vestmark/claude-toolkit)
