# Tokens and logins — step-by-step

Claude walks the user through these **one at a time**: show one section, wait for "Done", verify,
then show the next. Every secret is typed into the user's own terminal with `read -rs` (nothing is
echoed, nothing lands in shell history or in the chat) and appended to `~/.pte-tokens`, which the
`~/.bashrc` tooling block sources. Run this once before the first token:

```bash
touch ~/.pte-tokens && chmod 600 ~/.pte-tokens
```

Order matters a little: do GitHub first (it unblocks the claude-toolkit plugin), then Bitbucket
(it unblocks `git push`), then the rest.

---

## GitHub — for the `claude-toolkit` plugin (no token to paste)

The toolkit lives in the private `Vestmark/claude-toolkit` GitHub repo. Access goes over HTTPS via
the `gh` CLI — no SSH key, and no IT ticket: the **GitHub Enterprise** tile in Okta provisions you
into the Vestmark organization.

**Step 1 — Do you already have GitHub access?** Open https://github.com/Vestmark in your browser.
If it loads, skip to Step 3. If it 404s or asks you to sign in, continue.

**Step 2 — Get into the Vestmark organization via Okta (~5 minutes)**

1. Open https://vestmark.okta.com and click the **GitHub Enterprise** tile.
2. GitHub opens. **If you already have a GitHub account** that uses your `@vestmark.com` email,
   sign in with it. **If you don't have one**, click **Create an account**:
   - **Email:** your `@vestmark.com` address — not a personal one; this is what links the account
     to your Okta identity
   - **Password:** 15+ characters, or 8+ mixing letters, numbers and symbols
   - **Username:** identifies you publicly on every commit and PR, so keep it professional —
     e.g. `firstname-vestmark` or `flastname-vestmark`
   - complete the "verify you're human" puzzle → **Create account** → enter the launch code GitHub
     emails you (personalization questions can be skipped)
   - if GitHub prompts you to set up **two-factor authentication**, do it — the Okta Verify app you
     already use works as the authenticator
3. **Go back to Okta and click the GitHub Enterprise tile again.** This second click is what adds
   your account to the `Vestmark` organization (single sign-on). If GitHub shows a "You've been
   added to the Vestmark organization" banner or asks you to authorize SSO, click through it.
4. Confirm https://github.com/Vestmark now loads.

No GitHub Enterprise tile in Okta at all? That is the only case that needs IT — ask in
`#ask-it-for-help` for the GitHub Okta app to be assigned to you, then start from 1.

**Step 3 — Log the CLI in** (browser flow, in your terminal):

```bash
gh auth login --hostname github.com --git-protocol https --web
```

1. `? Authenticate Git with your GitHub credentials?` → **Yes**
2. It shows a one-time code and says *Press Enter to open github.com in your browser* → Enter
3. Sign in with the account from Step 2, paste the code, click **Authorize github** /
   **Authorize GitHub CLI**
4. If GitHub shows a **Single sign-on** page listing the `Vestmark` organization, click
   **Authorize** next to it — without this the token can't see the private repo
5. Back in the terminal: `✓ Logged in as <your-github-login>`

Say "done" — Claude then runs `gh auth setup-git` and registers the toolkit marketplace by its
HTTPS URL; nothing else for you to do.

---

## `ATLASSIAN_TOKEN` — Jira and Confluence

Pairs with `ATLASSIAN_USER` = your Vestmark email (set automatically from your git email).

1. Open https://id.atlassian.com/manage-profile/security/api-tokens (sign in with your
   `@vestmark.com` Atlassian account if asked)
2. Click **Create API token** — if it offers "with scopes" vs. plain, choose the **plain** one;
   the skills authenticate with basic auth against the REST API
3. Label: `pte-claude-skills` · Expiry: the longest offered (max 1 year) → **Create**
4. Click **Copy** — the token is shown exactly once
5. In your terminal, paste when prompted (nothing will appear as you paste), then Enter:

```bash
read -rsp 'ATLASSIAN_TOKEN: ' ATLASSIAN_TOKEN; echo; printf 'export ATLASSIAN_TOKEN=%q\n' "$ATLASSIAN_TOKEN" >> ~/.pte-tokens
```

---

## `BITBUCKET_TOKEN` — Bitbucket REST **and** git push/pull

Pairs with `BITBUCKET_USER` = your Bitbucket username (defaults to your Linux login; check it
under **Manage account → Account settings → Username** and tell Claude if it differs).

1. Open https://bitbucket.vestmarkeng.com and sign in
2. Click your avatar (top right) → **Manage account** → left nav **HTTP access tokens**
   (direct link: https://bitbucket.vestmarkeng.com/plugins/servlet/access-tokens/manage)
3. **Create token** · Name: `pte-claude-skills`
4. Permissions: **Projects → Read**, **Repositories → Write** (write includes read; needed for
   `git push` and `/create-pr`)
5. Expiry: the longest offered → **Create**
6. **Copy** — shown exactly once
7. In your terminal:

```bash
read -rsp 'BITBUCKET_TOKEN: ' BITBUCKET_TOKEN; echo; printf 'export BITBUCKET_TOKEN=%q\n' "$BITBUCKET_TOKEN" >> ~/.pte-tokens
```

From now on `git push`/`pull` use this token automatically (the credential helper
`user-setup.sh` installed reads it from the environment).

---

## `JENKINS_TOKEN` — Jenkins pipelines

Pairs with `JENKINS_USER` = your Jenkins login (defaults to your Linux login — step 2 shows the real one).

1. Open https://jenkins.vestmarkeng.com and sign in
2. Click your name (top right) → **Configure** (direct link: https://jenkins.vestmarkeng.com/me/configure).
   The address bar now reads `…/user/<login>/configure` — that `<login>` is your `JENKINS_USER`;
   tell Claude if it is not your Linux username
3. Scroll to **API Token** → **Add new Token** → name `pte-claude-skills` → **Generate**
4. **Copy** — shown exactly once — then click **Save** at the bottom of the page
5. In your terminal:

```bash
read -rsp 'JENKINS_TOKEN: ' JENKINS_TOKEN; echo; printf 'export JENKINS_TOKEN=%q\n' "$JENKINS_TOKEN" >> ~/.pte-tokens
```

---

## `SONARQUBE_TOKEN` — SonarQube (skills **and** the `sonarqube` MCP server)

1. Open https://sonarqube.vestmarkeng.com → **Log in** (top right, SSO)
2. Click your avatar → **My Account** → **Security** tab
   (direct link: https://sonarqube.vestmarkeng.com/account/security)
3. Under **Generate Tokens**: Name `pte-claude-skills` · Type **User Token** · Expires in: the
   longest offered → **Generate**
4. **Copy** — shown exactly once
5. In your terminal:

```bash
read -rsp 'SONARQUBE_TOKEN: ' SONARQUBE_TOKEN; echo; printf 'export SONARQUBE_TOKEN=%q\n' "$SONARQUBE_TOKEN" >> ~/.pte-tokens
```

---

## After the last one

```bash
source ~/.bashrc
```

Then tell Claude — it runs `check.sh --probe`, which authenticates against every service and
reports each token as `OK` or `rejected` (wrong/expired/under-scoped) so a bad one is caught now,
not in the middle of a skill.

---

## AWS SSO — for Claude Code on Bedrock (no token to paste)

Only if `check.sh` reported the `dev-tools` profile missing or the session invalid.

```bash
aws configure sso --profile dev-tools
```

| Prompt | Answer |
|---|---|
| SSO session name | `vestmark` |
| SSO start URL | `https://vestmark-hq.awsapps.com/start#/` |
| SSO region | `us-east-1` |
| SSO registration scopes | Enter (default `sso:account:access`) |
| *(browser opens — sign in with Okta, click Allow)* | |
| AWS account | `eng-dev-tools` (Engineering) · `hq-ai-services` (everyone else) |
| AWS role | `DevTools` (Engineering) · `ClaudeCode` (everyone else) |
| Default client region | `us-east-1` |
| CLI default output format | Enter (blank) |

If the account list is empty, ask IT in `#ask-it-for-help` to add you to `VM_SSO_AWSHQ`. On later
days just `aws sso login --profile dev-tools` — Claude Code's `awsAuthRefresh` runs that for you
when the session expires.
