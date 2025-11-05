# Multiple GitHub Accounts Setup

Этот гайд описывает, как настроить несколько GitHub‑аккаунтов на одной машине с помощью скриптов автоматизации.

## Что делает скрипт
- Генерирует новый SSH‑ключ под выбранный алиас и добавляет его в агент (предыдущие ключи, созданные скриптом для этого алиаса, удаляются автоматически).
- Прописывает алиас в `~/.ssh/config`, чтобы git использовал нужный ключ.
- Добавляет `includeIf` в `~/.gitconfig`, настраивая имя/почту для выбранного workspace.
- Создаёт правило `insteadOf`, чтобы `git@github.com:` автоматически подменялся на алиас и не приходилось править URL вручную.
- Благодаря `insteadOf` можно использовать привычные команды (`git clone git@github.com:…`, `gh repo clone owner/repo`) внутри настроенного workspace — они автоматически пойдут через алиас. Вне указанного в includeIf каталога переписывание не сработает, поэтому такие команды стоит запускать именно оттуда.
- Генерирует отдельный GPG‑ключ (с `Name-Comment: github-<user>-<alias>`), включает подпись коммитов и загружает ключ в GitHub при наличии необходимых прав.
- Авторизует GitHub CLI через PAT и загружает публичный ключ в аккаунт (токен должен включать `write:public_key` или `admin:public_key`, а также `write:gpg_key`; при отсутствии прав скрипт выводит нужную команду `gh auth refresh`).
- Выполняет проверку `ssh -T git@<alias>`.
- Записывает manifest в `~/.config/github-<username>/<alias>.json`, чтобы можно было откатить изменения через очистку.

## Скрипт (автоматическая настройка)

### Запуск без клонирования (через curl)

Быстрый способ запустить скрипт напрямую с GitHub без скачивания репозитория:

```bash
curl -fsSL https://raw.githubusercontent.com/karle0wne/github-multi-account/master/setup_github_account.sh | bash
```

**Рекомендации:**
- Замените `master` на конкретную ветку или commit SHA для воспроизводимости
- Перед запуском можно просмотреть скрипт: `curl -fsSL <url> | less`
- Для проверки без выполнения: `curl -fsSL <url> | bash -n` (проверит синтаксис)

### Автоматическая установка зависимостей

Скрипт автоматически проверяет наличие необходимых утилит и предлагает установить недостающие:
- **openssh** (ssh-keygen, ssh-add)
- **gh** (GitHub CLI)
- **python3**
- **gnupg** (если выбрана GPG-подпись)

Поддерживаемые системы:
- **macOS**: через Homebrew
- **Debian/Ubuntu**: через apt
- **RHEL/CentOS/Fedora**: через yum
- **Arch Linux**: через pacman

Отключить автоустановку:
```bash
GH_ACCOUNTS_AUTO_INSTALL=0 ./setup_github_account.sh
```

### Из локальной копии
```sh
./setup_github_account.sh
```

Скрипт задаёт вопросы:
1. **GitHub username** — ник настраиваемого аккаунта (например, `username`).
2. **Commit email** — адрес для подписи коммитов (скрытый email у GitHub имеет вид `12345678+username@users.noreply.github.com`; цифры берутся из Settings → Emails → *Keep my email addresses private*).
3. **Workspace path** — директория с проектами этого аккаунта (по умолчанию текущий `pwd`).
4. **PAT** — вставь токен, если хочется, чтобы скрипт сам авторизовал CLI и загрузил SSH/GPG ключи (нужны права `write:public_key` или `admin:public_key`, а также `write:gpg_key`).

Остальное выполняется автоматически: алиас выставляется как `github.com-<username>`, ключи сохраняются в `~/.ssh/id_ed25519_githubcom-<username>`, свежие SSH/GPG ключи генерируются и загружаются через `gh api`, после чего сразу запускается `ssh -T git@<alias>`.

GPG-управление ограничено ключами, созданными скриптом: удаляются только те, у которых `Name-Comment` совпадает с `github-<user>-<alias>`, остальные ключи для той же почты остаются нетронутыми.

### Cleanup через curl

Удаление конфигурации без клонирования репозитория:

```bash
# Обычное удаление (регистр не важен)
curl -fsSL https://raw.githubusercontent.com/karle0wne/github-multi-account/master/cleanup_github_account.sh | bash -s -- --alias github.com-<username>

# Dry-run (просмотр без удаления)
curl -fsSL https://raw.githubusercontent.com/karle0wne/github-multi-account/master/cleanup_github_account.sh | bash -s -- --alias github.com-<username> --dry-run

# С автоподтверждением (без вопросов)
curl -fsSL https://raw.githubusercontent.com/karle0wne/github-multi-account/master/cleanup_github_account.sh | bash -s -- --alias github.com-<username> --yes
```

**Примечание:** Alias case-insensitive — `github.com-MyUser` и `github.com-myuser` работают одинаково.

## Как повторить шаги вручную
1. **Сгенерируй SSH‑ключ для нужного аккаунта** (цифровой префикс можно посмотреть в GitHub → Settings → Emails → раздел *Keep my email addresses private*, например `237792185`):
   ```sh
   ssh-keygen -t ed25519 -C "12345678+username@users.noreply.github.com" -f ~/.ssh/id_ed25519_githubcom-username
   ```
   Добавь ключ в агент:
   - macOS: `ssh-add --apple-use-keychain ~/.ssh/id_ed25519_githubcom-username`
   - Linux: `ssh-add ~/.ssh/id_ed25519_githubcom-username`
2. **Создай алиас в `~/.ssh/config`**:
   ```text
   Host github.com-username
     HostName github.com
     User git
     IdentityFile ~/.ssh/id_ed25519_githubcom-username
     IdentitiesOnly yes
   ```
   Общий блок `Host *` с `AddKeysToAgent yes` можно оставить вверху файла.
3. **Настрой git-профиль для нужного каталога.**
   В `~/.gitconfig` добавь:
   ```text
   [includeIf "gitdir:/Users/you/workspace/**"]
     path = .gitconfig-github.com-username
   ```
   Создай `~/.gitconfig-github.com-username` с данными аккаунта (замени `12345678` на свой цифровой идентификатор из Settings → Emails → *Keep my email addresses private*):
   ```text
   [user]
     name = username
     email = 12345678+username@users.noreply.github.com
   ```
4. **Загрузи публичный ключ в GitHub.**
   - Через веб: Settings → SSH and GPG keys → New SSH key, вставь содержимое `~/.ssh/id_ed25519_githubcom-username.pub`.
   - Через CLI: выполни `gh auth login --hostname github.com --with-token`, затем  
     `gh ssh-key add ~/.ssh/id_ed25519_githubcom-username.pub --title "$(hostname)-github.com-username"`.
5. **Проверь подключение:**
   ```sh
   ssh -T git@github.com-username
   ```
   Сообщение “Hi username! You've successfully authenticated…” означает, что ключ подхватился.
6. **Используй alias для репозиториев:**
   ```sh
   git clone git@github.com-username:ORG/REPO.git
   git remote set-url origin git@github.com-username:ORG/REPO.git
   ```
   Чтобы не переписывать URL вручную, добавь в `~/.gitconfig-github.com-username` блок:
   ```text
   [url "git@github.com-username:"]
     insteadOf = git@github.com:
   ```
   Скрипт настраивает это автоматически.
7. **(Опционально) авторизуй GitHub CLI.**
   С PAT со scope `repo`, `admin:public_key`, `read:org`:
   ```sh
   printf '%s\n' "$PAT" | gh auth login --hostname github.com --git-protocol ssh --with-token --skip-ssh-key
   ```
   Переключение между аккаунтами:
   ```sh
   gh auth switch --hostname github.com --user username
   ```
8. **(Опционально) настрой подпись коммитов через GPG.**
   ```sh
   gpg --full-generate-key
   gpg --list-secret-keys --keyid-format LONG "12345678+username@users.noreply.github.com"
   ```
   Скопируй отпечаток (fingerprint), укажи его в git-конфиге выбранного workspace:
   ```sh
   git config --file ~/.gitconfig-github.com-username user.signingkey FINGERPRINT
   git config --file ~/.gitconfig-github.com-username commit.gpgsign true
   git config --file ~/.gitconfig-github.com-username gpg.program gpg
   ```
   При желании загрузи ключ на GitHub:
   ```sh
   gpg --armor --export FINGERPRINT | gh gpg-key add - --title "$(hostname)-github.com-username"
   ```
   Обрати внимание: при ручной настройке manifest не создаётся автоматически. Если захочешь использовать автоматический cleanup позже, запусти setup-скрипт или сохрани данные по ключам и конфигам вручную.

## Требования

### Обязательные
- **macOS или Linux** (поддерживаются: macOS, Debian/Ubuntu, RHEL/CentOS/Fedora, Arch Linux)
- **git** (обычно предустановлен)

### Устанавливаются автоматически (если отсутствуют)
Скрипт проверит и предложит установить:
- **openssh** (ssh-keygen, ssh-add)
- **GitHub CLI** ([gh](https://cli.github.com/))
- **python3**
- **gnupg** (только если выбрана GPG-подпись)

**На macOS**: требуется [Homebrew](https://brew.sh)

### Для полной функциональности
- Токен PAT выбранного аккаунта (classic) с правами: `repo`, `write:public_key` (или `admin:public_key`), `write:gpg_key`, `read:org`
- Возможность добавить SSH‑ключ на github.com (нужно быть залогиненным под этим аккаунтом)

## Подготовка
1. Выпусти PAT на нужном аккаунте → Settings → Developer settings → Personal access tokens → **Generate new token (classic)**.  
   Рекомендуемый набор scope: `repo`, `write:public_key` (или `admin:public_key`), `write:gpg_key`, `read:org`; при желании можно добавить остальные (например, `workflow`, `gist`).
2. Определи каталог, в котором лежат проекты этого аккаунта, например `/Users/you/workspace`.

## После запуска
- Ключи лежат в `~/.ssh/id_ed25519_<alias>` и `<alias>.pub`.
- В `~/.ssh/config` появится блок вида:
  ```text
  Host github.com-username
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519_githubcom-username
    IdentitiesOnly yes
  ```
- В `~/.gitconfig` добавится:
  ```text
  [includeIf "gitdir:/Users/you/workspace/**"]
    path = .gitconfig-github.com-username
  ```
  а в `~/.gitconfig-github.com-username` — имя/почта выбранного аккаунта, блок
  ```text
  [url "git@github.com-username:"]
    insteadOf = git@github.com:
  ```
- Если была включена подпись коммитов, файл `~/.gitconfig-github.com-username` дополнится строками:
  ```text
  [user]
    signingkey = <fingerprint>

  [commit]
    gpgsign = true

  [gpg]
    program = gpg
  ```
  а в `gpg --list-secret-keys` появится ключ с комментарием `github-<username>-<alias>` (например, `github-alice-github.com-alice`). Его можно удалить/загрузить заново через `gh` или скрипт очистки.
- Создаётся manifest `~/.config/github-<username>/<alias>.json` — там перечислены все изменения, отпечатки ключей, названия блоков конфигураций. Он нужен для обратного скрипта.
- GitHub CLI будет авторизован под новым пользователем (и сохранит токен в keychain). При необходимости переключайся:
  ```sh
  gh auth switch --hostname github.com --user <username>
  ```

## Работа с репозиториями
- Клонирование:
  ```sh
  git clone git@github.com-<username>:ORG/REPO.git
  ```
  В каталоге workspace можно смело использовать и стандартный вариант:
  ```sh
  gh repo clone ORG/REPO
  ``` 
  благодаря `insteadOf` git автоматически подставит `git@github.com-<username>:`. Если запускать команду вне каталога, на который сработал `includeIf`, переписывание не применится.
- Для уже существующего репозитория измени `origin`:
  ```sh
  git remote set-url origin git@github.com-<username>:ORG/REPO.git
  ```
- Коммиты в workspace будут автоматически подписаны данными выбранного аккаунта благодаря `includeIf`.

## Очистка
- Посмотреть, что будет удалено, без реальных изменений:
  ```sh
  ./cleanup_github_account.sh --alias <alias> --dry-run
  ```
- Полный откат:
  ```sh
  ./cleanup_github_account.sh --alias <alias>
  ```
- Если manifest переехал, передай путь явно через `--manifest /path/to/file`. Флаг `--yes` отключает подтверждения (используй его только в CI/скриптах).
- Скрипт удаляет конфиги, ключи и записи на GitHub, которые создал setup-скрипт. Шаги без артефактов/доступа пропускаются с предупреждением.

## Проверка и отладка
- Проверить активный ключ:
  ```sh
  ssh -T git@github.com-<username>
  ```
- Статус авторизации CLI:
  ```sh
  gh auth status --hostname github.com
  ```
- Убедиться, что GPG-ключ на месте:
  ```sh
  gpg --list-secret-keys --keyid-format LONG "12345678+username@users.noreply.github.com"
  ```
- Посмотреть manifest, который используется скриптом очистки:
  ```sh
  cat ~/.config/github-<username>/github.com-<username>.json
  ```
- Если нужна повторная настройка, перед запуском скрипта удалите:
  - соответствующий SSH‑ключ (файлы в `~/.ssh`, запись в `~/.ssh/config`);
  - include-блок и `~/.gitconfig-<alias>`;
  - запись в `gh auth logout --hostname github.com --user <username>`;
  - GPG-ключи, созданные для этого аккаунта (`gpg --delete-secret-key`, `gpg --delete-key`);
  - ключи на github.com (Settings → SSH and GPG keys / GPG keys).
Используй `./cleanup_github_account.sh --alias <alias>`, если хочешь убрать всё одним действием.

## Тестирование цикла Install → Cleanup → Install

Скрипты поддерживают полный цикл установки, удаления и повторной установки:

```bash
# 1. Установка
./setup_github_account.sh
# Создаст все конфигурации, ключи, manifest

# 2. Проверка работы
cd /path/to/workspace
git clone git@github.com-username:org/repo.git
# Должно клонироваться с правильным аккаунтом

# 3. Полное удаление
./cleanup_github_account.sh --alias github.com-username
# Удалит всё: конфиги, ключи, manifest

# 4. Повторная установка
./setup_github_account.sh
# Снова создаст всё с нуля - работает корректно!
```

**Важно:** Очистка удаляет только ресурсы, созданные скриптом (файлы по управляемому алиасу и GPG-ключи с соответствующим комментарием). Если вручную привязать эти пути к общим ключам, при cleanup они тоже будут удалены.

## Частые вопросы
- **Нет `gh`** — установи [GitHub CLI](https://cli.github.com/) (например, `brew install gh` или `apt install gh`). Скрипт проверяет наличие и завершится с ошибкой, если команды нет.
- **PAT не сохранился** — если скрипт сообщает о неверном токене, проверь scopes или сгенерируй новый. После успешного входа токен хранится в macOS Keychain (или системном секрет‑хранилище).
- **Нужно другой алиас** — допустимо задать свой (`github.alt`, `gh-extra` и т.д.), главное — использовать его при клонировании и в `ssh -T`.

Скрипт проверен локально: он успешно восстановил настройку тестового аккаунта, загрузил ключ и прошёл тестовое подключение к GitHub. Если появятся edge-case’ы, дополняй гайд и/или скрипт.
- **Можно ли установить 3+ аккаунта?** — Да! Просто запускай setup столько раз, сколько нужно. Каждый аккаунт получит свою директорию (`~/.config/github-alice/`, `~/.config/github-bob/`, и т.д.).
