---
name: setup-pte-dev-linux
description: Set up (or audit) a Linux/Ubuntu machine for PTE (vestmarkone) development end-to-end, starting from nothing but Claude Code — hosts entries, JDK, Docker, git over HTTPS (Bitbucket and GitHub, no SSH keys), the vestmarkone clone itself, build env vars and deployment properties, corporate certificates, uv, the claude-toolkit plugin, the standard MCP servers (sonarqube, java-lsp, pte-mssql, glean), and the API tokens the PTE skills need — then proves each piece works. Detects what is already done and only fixes the gaps, one step at a time, waiting for the user at every step they must do themselves. Use when the user says "/setup-pte-dev-linux", "set up my dev environment", "new machine setup", "check my PTE setup", "clone PTE for me", "my tokens/MCP servers aren't working", or is a new hire on Linux.
argument-hint: "[check | setup | tokens | claude | verify] [--jdk 17|8] [--ca <path-to-zscaler.crt>] [--repo <path>]"
allowed-tools: [Bash, Read, AskUserQuestion, Skill]
---

# Set up a Linux PTE dev machine (plugin edition)

Turns a machine that has only Claude Code on it into one that can build PTE and run every skill in
the vestmarkone repo. **All deterministic logic lives in the scripts beside this file**; this
document is the interactive wrapper. It runs **strictly in sequence**: one step, then wait for the
user when the step is theirs, then verify, then the next step. Never start a later step while
waiting.

This skill ships as a **plugin**, so it exists before the repo does. Every script path below is
under the plugin's install directory — start each Bash call with:

```bash
S="$CLAUDE_PLUGIN_ROOT/skills/setup-pte-dev-linux"
```

The checkout location is `${DEV_HOME:-~/dev}/vestmarkone` unless the user passes `--repo`; pass the
same `--repo` to every script if they do.

| File | Runs as | Invoked by | Covers |
|---|---|---|---|
| `check.sh [--reload] [--probe] [--repo]` | user | Claude | read-only detection; `--probe` authenticates against every service; `--reload` loads what the scripts wrote into this (older) shell |
| `pte-provision.sh <user> [--jdk] [--ca]` | **root** | **the user, in their own terminal** | `/etc/hosts`, Zscaler CA → system trust, JDK, Docker CE + group, git, unzip, gh |
| `clone-pte.sh [--repo] [--bitbucket-user]` | user | Claude | git-over-HTTPS credential helper for Bitbucket, `mkdir -p ~/dev`, unattended `git clone` of vestmarkone |
| `user-setup.sh --repo … [...]` | user | Claude | git identity/defaults, uv, `~/.profile` build vars, deployment properties, `~/.bashrc` tooling block (`MSSQL_*` derived from the clone) |
| `claude-setup.sh [...]` | user | Claude | aws-cli, SSO profile (detect), Bedrock `settings.json`, GitHub via `gh` (detect + `setup-git`), claude-toolkit plugin over HTTPS, glean MCP |
| `tokens.md` | — | Claude reads, shows one section at a time | click-by-click guides for GitHub, each API token, AWS SSO |

Git is **HTTPS everywhere** — Bitbucket through `BITBUCKET_USER`+`BITBUCKET_TOKEN`, GitHub through
the `gh` CLI. SSH keys are never generated.

## Hard rules

1. **Claude never invokes `sudo`, in any form.** AdminByRequest hangs it without a TTY. Privileged
   and browser-based steps are printed for the user to run in their own terminal.
2. **Never accept a token in the chat.** Tokens go through `read -rp` in the user's terminal
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
S="$CLAUDE_PLUGIN_ROOT/skills/setup-pte-dev-linux"; "$S/check.sh" --reload
```

Read `SUMMARY`, `PRIVILEGED_NEEDED`, `PLATFORM`, `WANT_JDK`, `REPO_ROOT`, `HAVE_REPO`.
`PLATFORM=other` → Rule 6. `HAVE_REPO=no` means the clone step (4c) is needed; `WANT_JDK`
defaults to 17 until the clone exists.

## Step 2 — Report

```
PTE DEV SETUP: <ready | N items missing, M warnings>

Machine      <distro> · JDK <want>: <ok|missing> · Docker: <ok|missing|group pending>
Network      hosts <ok|missing> · Zscaler CA <ok|missing> · cert env vars <ok|missing>
Checkout     <REPO_ROOT: present @ <branch> | not cloned yet>
Git          identity <ok|missing> · Bitbucket https helper <ok|missing> · GitHub (gh) <logged in|missing>
PTE build    DEV_HOME/ANT_HOME/VIVIPORT_ANT_PROPERTIES_FILE <ok|missing>
Claude Code  Bedrock <ok|missing> · aws profile <ok|missing> · toolkit plugin <ok|missing> · glean <ok|missing> · java-lsp <ok|missing>
Tokens       <n> of 4 set (<names missing>)
Privileged   <nothing to do | pte-provision.sh needed for: ...>
```

Two or three sentences of interpretation, then Step 3.

## Step 3 — Collect inputs, then ask the mode

If `git user.name`/`user.email` are unset, **ask for full name and Vestmark email in plain prose
first** — free text is not an `AskUserQuestion`. Wait for the answer. If `HAVE_REPO=no`, also ask
in the same message whether `~/dev/vestmarkone` is fine as the location (default yes).

Then `AskUserQuestion`, header `Setup`, question `What should I set up?` (skip when a mode was
passed as an argument). Recommend `Full setup` when anything is missing.

| Label | Description |
|---|---|
| `Full setup` | Steps 4a–4h in order, pausing at each step you must do yourself |
| `Tokens only` | 4b and 4g only |
| `Claude Code & MCP only` | 4e–4f only |
| `Check only` | Report only; change nothing |

## Step 4 — Execute, in order, with waits

### 4a. Privileged half — print, then WAIT

Only when `PRIVILEGED_NEEDED=yes`. Print exactly this and nothing else about later steps:

```bash
sudo bash "$CLAUDE_PLUGIN_ROOT/skills/setup-pte-dev-linux/pte-provision.sh" "$(whoami)" --jdk <WANT_JDK> [--ca <path>]
```

Substitute the real value of `$CLAUDE_PLUGIN_ROOT` into the printed line (run
`echo "$CLAUDE_PLUGIN_ROOT"` first) — the user's terminal does not have that variable. Add `--ca`
when the Zscaler CA was reported missing. Tell them: run it in a terminal you are sitting at; if
no password prompt appears for ~20s that is the known AdminByRequest flakiness — Ctrl-C and run it
again; it prints `PRIVILEGED PROVISIONING: complete` when done.

**Wait** (Rule 3). On `Done`, run `check.sh --reload` and confirm hosts, JDK package, docker-ce,
docker service, group membership, gh, CA are now `OK`. If docker group membership is `OK` but
`docker ps` still fails, that is expected until they log out/in — note it for the final report.

### 4b. Bitbucket token — first token, WAIT

Print `touch ~/.pte-tokens && chmod 600 ~/.pte-tokens`, then show **only** the `BITBUCKET_TOKEN`
section of `tokens.md` (this token is also the git password, so it comes before the clone).
**Wait.** On `Done`:

```bash
"$S/check.sh" --reload --probe | grep -iE 'bitbucket'
```

`rejected` → re-check permissions/expiry per that section and redo the `read -rp` line;
`no response` → network/VPN. `BITBUCKET_USER` defaults to the email local-part, which is always the Bitbucket username — only pass
`--bitbucket-user` to 4c/4d if they say theirs differs.

### 4c. Clone — Claude runs it (only when `HAVE_REPO=no`)

```bash
"$S/clone-pte.sh" [--repo <path>] [--bitbucket-user <login>]
```

Use a generous timeout (the repo is large; several minutes). It configures the credential
helper, creates `~/dev`, and clones without prompting. On `FAIL: clone rejected`, the token's
Repository permission or `BITBUCKET_USER` is wrong — go back to 4b. Re-run `check.sh --reload`
afterwards: `HAVE_REPO=yes` and `WANT_JDK` now come from the real `build.gradle`; if `WANT_JDK`
differs from what 4a installed, say so (the user re-runs 4a's command with the right `--jdk`).

### 4d. User-space half — Claude runs it

```bash
"$S/user-setup.sh" --repo <REPO_ROOT> --jdk <WANT_JDK> [--name "..." --email ...] [--bitbucket-user <login>] [--jenkins-user <login>]
```

Pass `--name/--email` only if Step 3 collected them. Relay the `note:` about `JENKINS_USER`
defaulting to the email local-part; re-run with `--jenkins-user` if it differs (it updates the block
in place).

### 4e. GitHub — verify, or print the `tokens.md` "GitHub" section and WAIT

In plugin mode GitHub is normally already done (it's how this plugin was installed). Check:

```bash
gh auth token >/dev/null 2>&1 && echo "gh: logged in" || echo "gh: NOT logged in"
```

If not logged in, show the whole "GitHub" section of `tokens.md` (Okta GitHub Enterprise tile —
create the account with the `@vestmark.com` email if needed, click the tile again to join the
org, no IT ticket — then `gh auth login … --web`) and **wait**. On `Done`, `gh auth setup-git`,
then `check.sh --reload --probe` → `[github]` shows logged in + Vestmark org member.

### 4f. Claude Code, plugin, MCP — Claude runs it

```bash
"$S/claude-setup.sh"
```

If it prints the AWS SSO `>>> HUMAN STEP`, show the `tokens.md` "AWS SSO" section and **wait**;
on `Done`, re-run `claude-setup.sh` (idempotent). If the Glean OAuth `HUMAN STEP` appears, note
it for the final report; do not wait for it.

**java-lsp: do not invoke `Skill: setup-java-lsp` if `claude-setup.sh` installed the toolkit in
this run** — a plugin installed mid-session is not loaded until Claude Code restarts. It goes in
the final report's restart block. Only if the toolkit was already installed before this run and
java-lsp is unconfigured, invoke it now: `Skill: setup-java-lsp`.

### 4g. Remaining tokens — one at a time, WAIT after each

For each of Atlassian → Jenkins → SonarQube that `check.sh` reported missing:

1. Show that token's section from `tokens.md` verbatim — nothing about the others.
2. **Wait.**
3. On `Done`: `"$S/check.sh" --reload --probe | grep -iE '<service>'` — `rejected` → redo per
   the section; `no response` → network/VPN, not the token.
4. Next token.

### 4h. Verify

```bash
"$S/check.sh" --reload --probe
bash -lc 'cd <REPO_ROOT> && echo "JAVA_HOME=$JAVA_HOME" && ./gradlew help -q >/dev/null && echo "gradle: build scripts evaluate OK"'
```

`--probe` authenticates every token, git over HTTPS to Bitbucket, the Vestmark GitHub org, and
the AWS SSO session. The second line is the toolchain proof: `bash -lc` is a **login** shell, so it
sees exactly what the user will after logging out/in (`~/.profile` → `JAVA_HOME`), and
`./gradlew help` is the smallest task that evaluates the build scripts — including
`gradle/java-home.gradle`, which fails with `Unable to determine JAVA_HOME location` if the
environment is wrong. (`./gradlew --version` does **not** evaluate build scripts and proves
nothing here.) Do **not** run `assemble`/`compileJava` in this step.

## Step 5 — Final report

```
PTE DEV SETUP: <complete | partial — see below>

Privileged     <ran by user, verified | skipped: ...>
Checkout       <REPO_ROOT @ <branch> (cloned this run | already present)>
User-space     <ok | failed at step: ...>
GitHub         <gh logged in, Vestmark org, toolkit installed | pending: ...>
Claude Code    Bedrock <ok> · plugin <ok> · glean <registered, auth pending | ok> · java-lsp <pending>
Tokens         <4/4 authenticated | missing: ... | rejected: ...>
Toolchain      login-shell JAVA_HOME <path> · ./gradlew help <build scripts evaluate OK | failed>

Tokens skipped: <list, if any> — see tokens.md; then: check.sh --reload --probe

RESTART NOW — the toolkit plugin, docker group membership, and ~/.profile only take effect at your next LOGIN:
  1. /exit                                   (or Ctrl-D) to leave this session
  2. LOG OUT and log back in (or reboot)     a new terminal tab is NOT enough for the docker group or ~/.profile
  3. open a terminal: cd <REPO_ROOT> && claude
                                             first launch from the repo: accept the workspace-trust prompt — it registers the pte-mssql MCP server
  4. /setup-java-lsp                         one-time index of the repo (~2 min) — enables java_* navigation tools
  5. /mcp → glean_default → Authenticate     Okta login in the browser — enables Glean search

Then build and run PTE, from <REPO_ROOT> (Linux/Ubuntu PTE Setup Guide §8 — the colon and --parallel matter):
  ./gradlew :assemble --parallel             build; the colon lets Gradle skip unchanged modules on later runs
  docker compose up -d                       only on newer releases — see the VEST-110795 page linked from §8
  ./gradlew db_setup                         set up the databases
  ./gradlew startWildfly                     start the app server (or use the IntelliJ Wildfly run configuration)
  ./gradlew setupVMAP                        only after http://pte.vm.test:8080/vestmark responds
Also:          join Slack #ptejava #linux-dev-env-users #claude-pte #engineering · install IntelliJ + a SQL client
```

The numbered restart block is mandatory whenever `claude-setup.sh` installed the plugin,
`clone-pte.sh` ran, or `pte-provision.sh` ran this session; print it verbatim.

## Failure handling

If a script exits non-zero, stop — do not retry with different flags or improvise. Report the
exact command, exit code, and the last 20 lines. Every user-space script is idempotent and safe
to re-run once the cause is fixed. A `pte-provision.sh` hang with no password prompt is the ABR
issue in 4a, not a script bug; a real non-zero exit, relay verbatim.

Classify: **environment** (network/VPN/certificate — `--probe` shows `no response` for every
service), **credential** (a single `rejected`, or `clone rejected`), **access** (GitHub org not
joined via the Okta tile yet, or AWS account not granted — a provisioning step, not a bug),
**stale doc** (a Confluence claim the repo contradicts — name it), or **unknown** (say so).

## Provenance

Cross-checked against the vestmarkone repo on 2026-09-22 from:
[Linux/Ubuntu PTE Setup Guide](https://vestmark.atlassian.net/wiki/spaces/ENGINE/pages/1302233126)
(James Wang), [Setup Claude Code with AWS Bedrock](https://vestmark.atlassian.net/wiki/spaces/ENGINE/pages/671286730),
[How-to Access Glean from Claude Code](https://vestmark.atlassian.net/wiki/spaces/~712020fe4a4673eb1849fe8bb37a2c253e4511/pages/2067005744),
[claude-toolkit README](https://github.com/Vestmark/claude-toolkit), `mcp/pte-mssql/README.md`,
Vestmark's [Instructions for Creating a GitHub Account](https://vestmark.atlassian.net/wiki/spaces/CD/pages/1721927459),
and the Okta GitHub Enterprise tile flow verified on the test laptop 2026-09-17. `./gradlew
tasks`, `build.gradle` (`sourceCompatibility`), and `gradle.properties` (`startupSaPassword`) are
authoritative over any of them; when they disagree, say so.
