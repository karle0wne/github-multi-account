# Multiple GitHub Accounts Setup

This guide describes how to set up multiple GitHub accounts on a single machine using automation scripts.

## What the Script Does
- Generates a fresh dedicated SSH key and adds it to the agent (previous script-managed keys with the same alias are removed automatically).
- Configures an alias in `~/.ssh/config` so git uses the correct key.
- Adds `includeIf` to `~/.gitconfig`, setting up name/email for the chosen workspace.
- Creates an `insteadOf` rule so `git@github.com:` is automatically replaced with the alias, eliminating manual URL editing.
- Thanks to `insteadOf`, you can use familiar commands (`git clone git@github.com:…`, `gh repo clone owner/repo`) inside the configured workspace — they automatically use the alias. Outside the directory specified in includeIf, the rewriting won't work, so run these commands from within that directory.
- Generates a dedicated GPG key (marked with `Name-Comment: github-<user>-<alias>`), enables commit signing, and uploads the key to GitHub when the required scopes are available.
- Authenticates GitHub CLI via PAT and uploads the public key to the account (token must include `admin:public_key` and `write:gpg_key`; if scopes are missing the script prints the exact `gh auth refresh` command to run manually).
- Performs an `ssh -T git@<alias>` connectivity test.
- Creates a manifest at `~/.config/github-<username>/<alias>.json` to enable cleanup rollback.

## Script (Automated Setup)

### Run Without Cloning (via curl)

Quick way to run the script directly from GitHub without downloading the repository:

```bash
curl -fsSL https://raw.githubusercontent.com/karle0wne/github-multi-account/master/setup_github_account.sh | bash
```

**Recommendations:**
- Replace `master` with a specific branch or commit SHA for reproducibility
- Review the script before running: `curl -fsSL <url> | less`
- Syntax check without execution: `curl -fsSL <url> | bash -n`

### Automatic Dependency Installation

The script automatically checks for required utilities and offers to install missing ones:
- **openssh** (ssh-keygen, ssh-add)
- **gh** (GitHub CLI)
- **python3**
- **gnupg** (if GPG signing is selected)

Supported systems:
- **macOS**: via Homebrew
- **Debian/Ubuntu**: via apt
- **RHEL/CentOS/Fedora**: via yum
- **Arch Linux**: via pacman

Disable auto-installation:
```bash
GH_ACCOUNTS_AUTO_INSTALL=0 ./setup_github_account.sh
```

### From Local Copy
```sh
./setup_github_account.sh
```

The script prompts for:
1. **GitHub username** — username of the target account (e.g., `username`).
2. **Commit email** — address for commit signatures (GitHub's private email format is `12345678+username@users.noreply.github.com`; find the numbers in Settings → Emails → *Keep my email addresses private*).
3. **Workspace path** — directory for projects of this account (defaults to current `pwd`).
4. **PAT** — paste a token if you want the script to authenticate CLI and upload SSH/GPG keys automatically (token must include `admin:public_key` и `write:gpg_key`).

Everything else is automatic: the script sets the SSH alias to `github.com-<username>`, writes keys to `~/.ssh/id_ed25519_githubcom-<username>`, generates fresh SSH/GPG keys, uploads them via `gh api`, and finally runs `ssh -T git@<alias>` for verification.

GPG management is scoped to the keys created by the script: it deletes prior keys whose `Name-Comment` matches `github-<user>-<alias>` but leaves any other GPG material for the same email untouched.

### Cleanup via curl

Remove configuration without cloning the repository:

```bash
# Standard removal (case-insensitive)
curl -fsSL https://raw.githubusercontent.com/karle0wne/github-multi-account/master/cleanup_github_account.sh | bash -s -- --alias github.com-<username>

# Dry-run (preview without deleting)
curl -fsSL https://raw.githubusercontent.com/karle0wne/github-multi-account/master/cleanup_github_account.sh | bash -s -- --alias github.com-<username> --dry-run

# With auto-confirmation (no prompts)
curl -fsSL https://raw.githubusercontent.com/karle0wne/github-multi-account/master/cleanup_github_account.sh | bash -s -- --alias github.com-<username> --yes
```

**Note:** Alias is case-insensitive — `github.com-MyUser` and `github.com-myuser` work identically.

## Manual Setup Steps
1. **Generate SSH key for the additional account** (find your numeric prefix in GitHub → Settings → Emails → *Keep my email addresses private*, e.g., `237792185`):
   ```sh
   ssh-keygen -t ed25519 -C "12345678+username@users.noreply.github.com" -f ~/.ssh/id_ed25519_githubcom-username
   ```
   Add key to agent:
   - macOS: `ssh-add --apple-use-keychain ~/.ssh/id_ed25519_githubcom-username`
   - Linux: `ssh-add ~/.ssh/id_ed25519_githubcom-username`
2. **Create alias in `~/.ssh/config`**:
   ```text
   Host github.com-username
     HostName github.com
     User git
     IdentityFile ~/.ssh/id_ed25519_githubcom-username
     IdentitiesOnly yes
   ```
   The general `Host *` block with `AddKeysToAgent yes` can stay at the top of the file.
3. **Configure git profile for the target directory.**
   Add to `~/.gitconfig`:
   ```text
   [includeIf "gitdir:/Users/you/workspace/**"]
     path = .gitconfig-github.com-username
   ```
   Create `~/.gitconfig-github.com-username` with account details (replace `12345678` with your numeric ID from Settings → Emails → *Keep my email addresses private*):
   ```text
   [user]
     name = username
     email = 12345678+username@users.noreply.github.com
   ```
4. **Upload public key to GitHub.**
   - Via web: Settings → SSH and GPG keys → New SSH key, paste contents of `~/.ssh/id_ed25519_githubcom-username.pub`.
   - Via CLI: run `gh auth login --hostname github.com --with-token`, then  
     `gh ssh-key add ~/.ssh/id_ed25519_githubcom-username.pub --title "$(hostname)-github.com-username"`.
5. **Test connection:**
   ```sh
   ssh -T git@github.com-username
   ```
   Message "Hi username! You've successfully authenticated…" confirms the key works.
6. **Use alias for repositories:**
   ```sh
   git clone git@github.com-username:ORG/REPO.git
   git remote set-url origin git@github.com-username:ORG/REPO.git
   ```
   To avoid manual URL rewriting, add to `~/.gitconfig-github.com-username`:
   ```text
   [url "git@github.com-username:"]
     insteadOf = git@github.com:
   ```
   The script configures this automatically.
7. **(Optional) Authenticate GitHub CLI.**
   With a PAT having scopes `repo`, `admin:public_key`, `read:org`:
   ```sh
   printf '%s\n' "$PAT" | gh auth login --hostname github.com --git-protocol ssh --with-token --skip-ssh-key
   ```
   Switch between accounts:
   ```sh
   gh auth switch --hostname github.com --user username
   ```
8. **(Optional) Set up commit signing via GPG.**
   ```sh
   gpg --full-generate-key
   gpg --list-secret-keys --keyid-format LONG "12345678+username@users.noreply.github.com"
   ```
   Copy the fingerprint and add it to the workspace git config:
   ```sh
   git config --file ~/.gitconfig-github.com-username user.signingkey FINGERPRINT
   git config --file ~/.gitconfig-github.com-username commit.gpgsign true
   git config --file ~/.gitconfig-github.com-username gpg.program gpg
   ```
   Optionally upload the key to GitHub:
   ```sh
   gpg --armor --export FINGERPRINT | gh gpg-key add - --title "$(hostname)-github.com-username"
   ```
   Note: Manual setup doesn't create a manifest automatically. If you want to use automatic cleanup later, run the setup script or save key/config data manually.

## Requirements

### Required
- **macOS or Linux** (supported: macOS, Debian/Ubuntu, RHEL/CentOS/Fedora, Arch Linux)
- **git** (usually pre-installed)

### Auto-installed (if missing)
The script will check and offer to install:
- **openssh** (ssh-keygen, ssh-add)
- **GitHub CLI** ([gh](https://cli.github.com/))
- **python3**
- **gnupg** (only if GPG signing is selected)

**On macOS**: [Homebrew](https://brew.sh) is required

### For Full Functionality
- PAT token for the account (classic) with scopes at least: `repo`, `admin:public_key`, `write:gpg_key`, `read:org`
- Ability to add SSH key on github.com (must be logged in under the additional account)

## Preparation
1. Generate PAT on the account → Settings → Developer settings → Personal access tokens → **Generate new token (classic)**.  
   Recommended scopes: `repo`, `admin:public_key`, `write:gpg_key`, `read:org`; optionally add others (e.g., `workflow`, `gist`).
2. Determine the directory where projects for this account will be stored, e.g., `/Users/you/workspace`.

## After Running
- Keys are stored in `~/.ssh/id_ed25519_<alias>` and `<alias>.pub`.
- `~/.ssh/config` will contain a block like:
  ```text
  Host github.com-username
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519_githubcom-username
    IdentitiesOnly yes
  ```
- `~/.gitconfig` will have:
  ```text
  [includeIf "gitdir:/Users/you/workspace/**"]
    path = .gitconfig-github.com-username
  ```
  and `~/.gitconfig-github.com-username` will contain the additional account's name/email and:
  ```text
  [url "git@github.com-username:"]
    insteadOf = git@github.com:
  ```
- If commit signing was enabled, `~/.gitconfig-github.com-username` will also have:
  ```text
  [user]
    signingkey = <fingerprint>

  [commit]
    gpgsign = true

  [gpg]
    program = gpg
  ```
  and `gpg --list-secret-keys` will show a key with comment `github-<username>-<alias>` (e.g., `github-alice-github.com-alice`). It can be deleted/re-uploaded via `gh` or the cleanup script.
- A manifest is created at `~/.config/github-<username>/<alias>.json` — it lists all changes, key fingerprints, and configuration block names. Needed for the cleanup script.
- GitHub CLI will be authenticated under the new user (token saved in keychain). Switch when needed:
  ```sh
  gh auth switch --hostname github.com --user <username>
  ```

## Working with Repositories
- Cloning:
  ```sh
  git clone git@github.com-<username>:ORG/REPO.git
  ```
  Inside the workspace directory, you can safely use the standard variant:
  ```sh
  gh repo clone ORG/REPO
  ``` 
  thanks to `insteadOf`, git automatically substitutes `git@github.com-<username>:`. If run outside the directory where `includeIf` applies, rewriting won't happen.
- For existing repositories, change `origin`:
  ```sh
  git remote set-url origin git@github.com-<username>:ORG/REPO.git
  ```
- Commits in the workspace will automatically be signed with the additional account's details thanks to `includeIf`.

## Cleanup
- Preview what will be deleted without making changes:
  ```sh
  ./cleanup_github_account.sh --alias <alias> --dry-run
  ```
- Full rollback:
  ```sh
  ./cleanup_github_account.sh --alias <alias>
  ```
- If the manifest was moved, pass the path explicitly via `--manifest /path/to/file`. The `--yes` flag skips confirmations (use only in CI/scripts).
- The script removes configs, keys, and GitHub entries created by the setup script. Steps without artifacts/access are skipped with warnings.

## Verification and Debugging
- Check active key:
  ```sh
  ssh -T git@github.com-<username>
  ```
- CLI authentication status:
  ```sh
  gh auth status --hostname github.com
  ```
- Verify GPG key:
  ```sh
  gpg --list-secret-keys --keyid-format LONG "12345678+username@users.noreply.github.com"
  ```
- View manifest used by cleanup script:
  ```sh
  cat ~/.config/github-<username>/github.com-<username>.json
  ```
- If re-setup is needed, before running the script delete:
  - corresponding SSH key (files in `~/.ssh`, entry in `~/.ssh/config`);
  - include block and `~/.gitconfig-<alias>`;
  - entry via `gh auth logout --hostname github.com --user <username>`;
  - GPG keys created for the additional account (`gpg --delete-secret-key`, `gpg --delete-key`);
  - keys on github.com (Settings → SSH and GPG keys / GPG keys).
Use `./cleanup_github_account.sh --alias <alias>` to remove everything in one action.

## Testing Install → Cleanup → Install Cycle

The scripts support a full cycle of installation, removal, and reinstallation:

```bash
# 1. Installation
./setup_github_account.sh
# Creates all configurations, keys, manifest

# 2. Verify functionality
cd /path/to/workspace
git clone git@github.com-username:org/repo.git
# Should clone with the correct account

# 3. Complete removal
./cleanup_github_account.sh --alias github.com-username
# Removes everything: configs, keys, manifest

# 4. Reinstallation
./setup_github_account.sh
# Creates everything from scratch again - works correctly!
```

**Important:** Cleanup removes only the resources created by the script (files under the managed alias and GPG keys tagged with its comment). If you manually repoint those paths to shared keys, the cleanup step will remove them as well.

## FAQ
- **No `gh`** — Install [GitHub CLI](https://cli.github.com/) (e.g., `brew install gh` or `apt install gh`). The script checks availability and exits with an error if the command is missing.
- **PAT not saved** — If the script reports an invalid token, check scopes or generate a new one. After successful login, the token is stored in macOS Keychain (or system secret storage).
- **Need a different alias** — You can use your own (`github.alt`, `gh-extra`, etc.), just use it consistently when cloning and in `ssh -T`.
- **Can I install 3+ accounts?** — Yes! Just run setup as many times as needed. Each account gets its own directory (`~/.config/github-alice/`, `~/.config/github-bob/`, etc.).

The script has been tested locally: it successfully restored the test account setup, uploaded keys, and passed GitHub connectivity tests. If edge cases arise, update the guide and/or script accordingly.
