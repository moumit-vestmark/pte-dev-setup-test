---
name: setup-pte-dev-linux
description: Set up (or audit) a Linux/Ubuntu machine for PTE (vestmarkone) development end-to-end — hosts entries, JDK, Docker, git over HTTPS (Bitbucket and GitHub, no SSH keys), build env vars and deployment properties, corporate certificates, uv, Claude Code on AWS Bedrock, the claude-toolkit plugin, the standard MCP servers (sonarqube, java-lsp, pte-mssql, glean), and the API tokens the PTE skills need — then proves each piece works. Detects what is already done and only fixes the gaps, one step at a time, waiting for the user at every step they must do themselves. Use when the user says "/setup-pte-dev-linux", "set up my dev environment", "new machine setup", "check my PTE setup", "my tokens/MCP servers aren't working", or is a new hire on Linux.
argument-hint: "[check | setup | tokens | claude | verify] [--jdk 17|8] [--ca <path-to-zscaler.crt>]"
allowed-tools:
  - "Bash(.claude/skills/setup-pte-dev-linux/check.sh *)"
  - "Bash(.claude/skills/setup-pte-dev-linux/check.sh)"
  - "Bash(.claude/skills/setup-pte-dev-linux/user-setup.sh *)"
  - "Bash(.claude/skills/setup-pte-dev-linux/user-setup.sh)"
  - "Bash(.claude/skills/setup-pte-dev-linux/claude-setup.sh *)"
  - "Bash(.claude/skills/setup-pte-dev-linux/claude-setup.sh)"
  - "Bash(./gradlew --version)"
  - "Bash(gh auth setup-git)"
  - "Bash(uname *)"
  - "Bash(whoami)"
  - "Bash(grep *)"
  - "Bash(ls *)"
  - "Bash(echo *)"
  - Read
  - AskUserQuestion
  - Skill
---

# Set up a Linux PTE dev machine

Turns a fresh (or half-configured) Ubuntu machine into one that can build PTE and run every skill
in this repo. **All deterministic logic lives in the scripts beside this file**; this document is
the interactive wrapper. It runs **strictly in sequence**: one step, then wait for the user when
the step is theirs, then verify, then the next step. Never start a later step while waiting.

| File | Runs as | Invoked by | Covers |
|---|---|---|---|
| `check.sh [--probe]` | user | Claude | read-only detection; `--probe` authenticates against every service |
| `pte-provision.sh <user> [--jdk] [--ca]` | **root** | **the user, in their own terminal** | `/etc/hosts`, Zscaler CA → system trust, JDK, Docker CE + group, git, unzip, gh |
| `user-setup.sh [...]` | user | Claude | git identity/defaults, git-over-HTTPS credential helper for Bitbucket, uv, `~/.profile` build vars, deployment properties, `~/.bashrc` tooling block |
| `claude-setup.sh [...]` | user | Claude | aws-cli, SSO profile (detect), Bedrock `settings.json`, GitHub via `gh` (detect + `setup-git`), claude-toolkit plugin over HTTPS, glean MCP |
| `tokens.md` | — | Claude reads, shows one section at a time | click-by-click guides for GitHub login, each API token, AWS SSO |

Git is **HTTPS everywhere** — Bitbucket through `BITBUCKET_USER`+`BITBUCKET_TOKEN`, GitHub through
the `gh` CLI. SSH keys have been unreliable for new hires and are never generated.

## Hard rules

1. **Claude never invokes `sudo`, in any form.** AdminByRequest hangs it without a TTY (5/5, 2026-09-09).
   Privileged and browser-based steps are printed for the user to run in their own terminal.
2. **Never accept a token in the chat.** Tokens go through `read -rs` in the user's terminal
   (`tokens.md`). If one is pasted here, tell them to revoke and regenerate it.
3. **One step at a time; wait when it's theirs.** After printing a command or a `tokens.md`
   section, stop and ask with `AskUserQuestion` (header `Waiting`, options exactly:
   `Done — continue` / `It failed — I'll paste the output` / `Skip for now`). Do not run other
   steps, research, or background agents while waiting. On `Done`, verify with `check.sh` before
   moving on; on `failed`, read what they paste and fix or report; on `Skip`, note it for the
   final report and continue.
4. **Detect first, change second.** If `check.sh` is all green, say so and stop.
5. **Mode selection is the authorization** — no re-asking before each script; the only pauses are
   the waits in Rule 3.
6. **Linux only.** If `uname -s` is not `Linux`, stop and link
   [Windows PTE Development Environment Setup](https://vestmark.atlassian.net/wiki/spaces/ENGINE/pages/301631053)
   or [Running PTE on Mac](https://vestmark.atlassian.net/wiki/spaces/ENGINE/pages/1124598027).
7. **Report once**, in the template at the end.

## Step 1 — Detect

```bash
.claude/skills/setup-pte-dev-linux/check.sh
```

Read `SUMMARY`, `PRIVILEGED_NEEDED`, `PLATFORM`, `WANT_JDK`. `PLATFORM=other` → Rule 6.

## Step 2 — Report

```
PTE DEV SETUP: <ready | N items missing, M warnings>

Machine      <distro> · JDK <want>: <ok|missing> · Docker: <ok|missing|group pending>
Network      hosts <ok|missing> · Zscaler CA <ok|missing> · cert env vars <ok|missing>
Git          identity <ok|missing> · Bitbucket https helper <ok|missing> · GitHub (gh) <logged in|missing>
PTE build    DEV_HOME/ANT_HOME/VIVIPORT_ANT_PROPERTIES_FILE <ok|missing>
Claude Code  Bedrock <ok|missing> · aws profile <ok|missing> · toolkit plugin <ok|missing> · glean <ok|missing> · java-lsp <ok|missing>
Tokens       <n> of 4 set (<names missing>)
Privileged   <nothing to do | pte-provision.sh needed for: ...>
```

Two or three sentences of interpretation, then Step 3.

## Step 3 — Collect inputs, then ask the mode

If `git user.name`/`user.email` are unset, **ask for full name and Vestmark email in plain
prose first** — free text is not an `AskUserQuestion` (it has no options). Wait for the answer.

Then `AskUserQuestion`, header `Setup`, question `What should I set up?` (skip when a mode was
passed as an argument). Recommend `Full setup` when anything is missing.

| Label | Description |
|---|---|
| `Full setup` | Steps 4a–4g in order, pausing at each step you must do yourself |
| `Tokens only` | 4e only |
| `Claude Code & MCP only` | 4c–4d only |
| `Check only` | Report only; change nothing |

## Step 4 — Execute, in order, with waits

### 4a. Privileged half — print, then WAIT

Only when `PRIVILEGED_NEEDED=yes`. Print exactly this and nothing else about later steps:

```bash
sudo bash .claude/skills/setup-pte-dev-linux/pte-provision.sh "$(whoami)" --jdk <WANT_JDK> [--ca <path>]
```

Add `--ca` when the Zscaler CA was reported missing (use the candidate path `check.sh` found in
`~/Downloads`, else they must get `ZscalerRootCertificate.crt` from IT first). Tell them: run it in
a terminal you are sitting at; if no password prompt appears for ~20s that is the known
AdminByRequest flakiness — Ctrl-C and run it again; it prints `PRIVILEGED PROVISIONING: complete`
when done.

**Wait** (Rule 3). On `Done`, run `check.sh --reload` and confirm hosts, JDK package, docker-ce,
docker service, group membership, gh, CA are now `OK`. If docker group membership is `OK` but `docker ps`
still fails, that is expected until they log out/in — note it for the final report.

### 4b. User-space half — Claude runs it

```bash
.claude/skills/setup-pte-dev-linux/user-setup.sh --jdk <WANT_JDK> [--name "..." --email ...] [--bitbucket-user <login>] [--jenkins-user <login>]
```

Relay the `note:` about `BITBUCKET_USER`/`JENKINS_USER` defaulting to the local username; ask
whether their Bitbucket/Jenkins logins differ, and re-run with the flags if so. No wait otherwise.

### 4c. GitHub — print the `tokens.md` "GitHub" section, then WAIT

Show the whole section: Step 1 (do they already have access?), Step 2 (Okta GitHub Enterprise
tile — create the account with the `@vestmark.com` email if they have none, then click the tile
again to be added to the Vestmark org; no IT ticket), Step 3 (`gh auth login … --web`). Users who
already have access will skip Step 2 on their own. **Wait.** On `Done`, run `gh auth setup-git`,
then `check.sh --reload --probe` and confirm the `[github]` section shows logged in + Vestmark org
member. If the org check fails, the fix is Step 2.3 (click the Okta tile again) followed by
`gh auth refresh -h github.com` — wait again after they confirm.

### 4d. Claude Code, plugin, MCP — Claude runs it

```bash
.claude/skills/setup-pte-dev-linux/claude-setup.sh
```

If it prints the AWS SSO `>>> HUMAN STEP`, show the `tokens.md` "AWS SSO" section and **wait**;
on `Done`, re-run `claude-setup.sh` (idempotent) so the plugin/glean steps complete. If the
Glean OAuth `HUMAN STEP` appears, note it for the final report (it happens in their next session
via `/mcp`); do not wait for it.

**java-lsp: do not invoke `Skill: setup-java-lsp` if `claude-setup.sh` installed the plugin in
this run** — a plugin installed mid-session is not loaded until Claude Code restarts, and the
call fails with `Unknown skill`. Put it in the final report's restart block instead. Only when
the toolkit was *already* installed before this run (check.sh said so in Step 1) and java-lsp is
unconfigured, invoke it now:

```
Skill: setup-java-lsp
```

### 4e. Tokens — one at a time, WAIT after each

First print the `touch ~/.pte-tokens && chmod 600 ~/.pte-tokens` line. Then, for **each token
`check.sh` reported missing**, in the order Bitbucket → Atlassian → Jenkins → SonarQube:

1. Show that token's section from `tokens.md` verbatim — the numbered click path and its single
   `read -rsp … >> ~/.pte-tokens` line. Nothing about the other tokens.
2. **Wait.**
3. On `Done`, verify just that token:
   ```bash
   .claude/skills/setup-pte-dev-linux/check.sh --reload --probe | grep -iE '<service>'
   ```
   `--reload` loads `~/.pte-tokens` and the blocks `user-setup.sh` wrote, because this shell
   predates them (and plain `source ~/.bashrc` is a no-op non-interactively on Ubuntu).
   `bitbucket` also confirms `git ls-remote` works without a prompt. `rejected` → ask them to
   re-check the permissions/expiry in that section and redo the `read -rsp` line; `no response`
   → network/VPN, not the token.
4. Next token.

After the last: tell them to run `source ~/.bashrc`.

### 4f. Verify

```bash
.claude/skills/setup-pte-dev-linux/check.sh --reload --probe
./gradlew --version
```

`--probe` authenticates every token, checks git over HTTPS to Bitbucket and the Vestmark GitHub
org, and the AWS SSO session. `./gradlew --version` proves the wrapper, `JAVA_HOME`, and the
certificate path without running a Gradle task — do **not** run `assemble`/`compileJava` here.

## Step 5 — Final report

```
PTE DEV SETUP: <complete | partial — see below>

Privileged     <ran by user, verified | skipped: hosts, CA, docker group...>
User-space     <ok | failed at step: ...>
GitHub         <gh logged in, Vestmark org, toolkit installed | pending: ...>
Claude Code    Bedrock <ok> · plugin <ok> · glean <registered, auth pending | ok> · java-lsp <indexed | pending>
Tokens         <4/4 authenticated | missing: ... | rejected: ...>
Toolchain      ./gradlew --version <ok: Gradle x, JVM y | failed>

Tokens skipped: <list, if any> — see tokens.md; then: check.sh --reload --probe

RESTART CLAUDE CODE NOW — the toolkit plugin, docker group, and new env vars only take effect in a new session:
  1. /exit                                   (or Ctrl-D) to leave this session
  2. close this terminal and open a NEW one  (docker group membership + ~/.profile + ~/.bashrc)
  3. cd ~/dev/vestmarkone && claude
  4. /setup-java-lsp                         one-time index of the repo (~2 min) — enables java_* navigation tools
  5. /mcp → glean_default → Authenticate     Okta login in the browser — enables Glean search

Then:          ./gradlew assemble   (full build + local deploy — Linux/Ubuntu PTE Setup Guide §8)
Also:          join Slack #ptejava #linux-dev-env-users #claude-pte #engineering · install IntelliJ + a SQL client
```

The numbered restart block is mandatory whenever `claude-setup.sh` installed the plugin or
`pte-provision.sh` ran this session; print it verbatim, do not compress it into a bullet.

## Failure handling

If a script exits non-zero, stop — do not retry with different flags or improvise. Report the
exact command, exit code, and the last 20 lines. All three user-space scripts are idempotent and
safe to re-run once the cause is fixed. A `pte-provision.sh` hang with no password prompt is the
ABR issue in 4a, not a script bug; a real non-zero exit, relay verbatim.

Classify: **environment** (network/VPN/certificate — `--probe` shows `no response` for every
service), **credential** (a single `rejected`), **access** (GitHub org not joined via the Okta
tile yet, or AWS account not granted — a provisioning step, not a bug), **stale doc** (a Confluence claim the repo contradicts — name
it), or **unknown** (say so).

## Provenance

Cross-checked against this repo on 2026-09-17 from:
[Linux/Ubuntu PTE Setup Guide](https://vestmark.atlassian.net/wiki/spaces/ENGINE/pages/1302233126)
(James Wang, updated 2026-09-10),
[Setup Claude Code with AWS Bedrock](https://vestmark.atlassian.net/wiki/spaces/ENGINE/pages/671286730),
[How-to Access Glean from Claude Code](https://vestmark.atlassian.net/wiki/spaces/~712020fe4a4673eb1849fe8bb37a2c253e4511/pages/2067005744),
[claude-toolkit README](https://github.com/Vestmark/claude-toolkit), `mcp/pte-mssql/README.md`,
Vestmark's [Instructions for Creating a GitHub Account](https://vestmark.atlassian.net/wiki/spaces/CD/pages/1721927459),
and the Okta GitHub Enterprise tile flow verified on the test laptop 2026-09-17. `./gradlew tasks`,
`build.gradle` (`sourceCompatibility`), and `gradle.properties` (`startupSaPassword`) are
authoritative over any of them; when they disagree, say so.
