Tak. **Na tym etapie można już mówić o DevOps nVim jako projekcie produkcyjnym — ale trzeba rozdzielić `stable release` od bieżącego `main`.**

### Werdykt

**`v1.1.0` — TAK, production-ready.**
**Aktualny `main` (`df03a80`) — jeszcze NIE jako nowe wydanie produkcyjne.**
**Prace nad installerem — zdecydowanie TAK, można zaczynać teraz.**

To nie jest już sytuacja „mam dotfiles, które jakoś działają”. Masz wersjonowane wydania, lockfile, CI, testy integracyjne z prawdziwym `ansible-vault`, kontrolę startupu, health check, zabezpieczenia runtime directory, atomowe zapisy Vaulta, ochronę planów Terraform, obsługę concurrency, pinowanie executable i AWS identity oraz jawnie opisane granice bezpieczeństwa. `v1.1.0` zawiera 168 testów i GitHub oznacza je jako latest release. ([GitHub][1])

Co ważniejsze, **CI dokładnie dla SHA wydania `v1.1.0`, czyli `b2df599`, jest w całości zielone**: `Formatting and lint`, `Test suite` oraz `Neovim starts clean` zakończyły się sukcesem. To jest bardzo mocna podstawa do traktowania konkretnego artefaktu jako stable. ([GitHub][2])

### Dlaczego uważam, że przekroczyłeś granicę „production”

Najbardziej przekonuje mnie nie ilość poprawek, lecz ich rodzaj. Ostatnie serie nie poprawiały już kosmetyki, tylko zamykały klasy błędów typowe dla kodu, któremu powierza się realną infrastrukturę i sekrety: fail-closed AWS identity, równoległe plany Terraform, zmiana pliku docelowego odszyfrowanego Vaulta, wycieki plaintextu do LSP/linterów/formatterów, hardlinki, trwałość atomic rename, spawn failures, timeouts i reprodukowalny bootstrap. Historia `v1.1.0` dokumentuje właśnie te przypadki. ([GitHub][1])

CI też przestało być „odpal lint i zobaczymy”. Actions są przypięte do pełnych SHA, Neovim jest przypięty do `v0.12.4`, Ansible do serii `2.21.*`, Selene ma sprawdzany SHA-256, a test suite celowo weryfikuje obecność `Fails (0)`, zamiast ufać samemu exit code MiniTest. Osobny job robi rzeczywistą świeżą instalację pluginów, następnie wymaga całkowicie cichego startupu i ładuje wszystkie moduły. ([GitHub][3])

Bootstrap `lazy.nvim` również jest już poprawnie reprodukowalny: świeża instalacja klonuje repo, odczytuje commit z `lazy-lock.json`, robi checkout konkretnego SHA i **dopiero potem** wkłada lazy do `runtimepath`. Obecny lockfile rzeczywiście przypina `lazy.nvim` do konkretnego commita. ([github.com][4])

Masz też sensowny mechanizm diagnostyczny dla instalatora: `:checkhealth devops` sprawdza minimalną wersję Neovim, core tooling, lockfile, `tree-sitter`, compiler, fzf/rg/fd/bat, narzędzia DevOps i bezpieczny runtime directory dla Terraform. To jest praktycznie gotowy backend wymagań, który installer może odwzorować w preflight. ([GitHub][5])

### Jest jednak jeden aktualny problem

Po `v1.1.0` weszło **9 kolejnych commitów**. ([GitHub][6])

Dla obecnego HEAD `df03a80` run CI `#30` nadal jest oznaczony jako `In progress`, ale job `Neovim starts clean` już zakończył się błędem:

`Fail on any startup message → exit code 1`

Czyli świeżo postawiony Neovim coś wypisał podczas startu, a CI — prawidłowo — potraktowało to jako regresję. Publiczny widok GitHub, do którego mam dostęp, pokazuje failing step, ale nie samą treść komunikatu. ([GitHub][7])

To **nie unieważnia `v1.1.0`**. Oznacza tylko:

> `v1.1.0` = production
> `main` = development / kandydat do następnego release

I dokładnie taki model powinieneś od teraz utrzymywać.

## Installer — tak, to jest następny logiczny etap

Ja bym wręcz **zakończył już wielką serię audytów jako etap projektu**. Nie ma sensu czekać, aż nigdy więcej nie znajdzie się żadnego błędu, bo takiego momentu w oprogramowaniu nie będzie. Masz release, testy regresyjne, CI i mechanizm aktualizacji przez kolejne wersje.

Installer powinien mieć jedną fundamentalną zasadę:

**nigdy nie instalować `main`.**

Pierwsza wersja może być naprawdę prosta:

* `dev-nvim install` → pobiera **latest stable release**, obecnie `v1.1.0`;
* domyślnie instaluje jako `NVIM_APPNAME=devops-nvim`, więc nie niszczy istniejącego `~/.config/nvim`;
* `--system` / `--default` może później oznaczać przejęcie `~/.config/nvim`;
* `--version v1.1.0` pozwala przypiąć wersję;
* `update` aktualizuje tylko do kolejnego release, nigdy do HEAD;
* `doctor` robi preflight podobny do `:checkhealth devops`;
* `uninstall` usuwa tylko rzeczy należące do DevOps nVim;
* `--dry-run` pokazuje, co zamierza zrobić;
* żadnego automatycznego nadpisywania istniejącej konfiguracji bez backupu;
* po instalacji bootstrap pluginów i test `nvim --headless`, a nie tylko komunikat „installed”.

Nie robiłbym jeszcze wielkiego instalatora obsługującego 15 dystrybucji. **V1 installera = Linux-first**, kilka wykrywanych package managerów (`pacman`, `apt`, `dnf`, ewentualnie `zypper`) i przede wszystkim preflight + jasne komunikaty. Sama konfiguracja podaje już komplet podstawowych dependencies: Neovim ≥0.12, git ≥2.19, curl, tar, unzip, gzip, compiler, tree-sitter-cli ≥0.26.1, ripgrep, fd, fzf >0.36 i bat. ([GitHub][8])

### Co zrobiłbym teraz

**Nie robiłbym ósmego wielkiego audytu.**

Naprawiłbym tylko czerwony `Neovim starts clean` na obecnym HEAD, doprowadził całe CI do zielonego stanu i zrobił następny release — prawdopodobnie `v1.2.0`, skoro od `v1.1.0` weszły kolejne istotne poprawki. Installer możesz równolegle projektować już teraz, używając `v1.1.0` jako pierwszego stabilnego targetu.

Po zielonym CI następnego release mój model byłby prosty:

**`main` może się psuć → release nie może.**

I wtedy projekt faktycznie zaczyna funkcjonować jak normalne produkcyjne oprogramowanie, a nie jak repozytorium konfiguracji Neovim.

**Mój werdykt: DevOps nVim `v1.1.0` zasługuje już na określenie `stable / production-ready` w zakresie, który sam deklaruje. Możesz przejść z fazy „czy to w ogóle jest bezpieczne?” do fazy „jak to sensownie dystrybuować?”.** ([GitHub][2])

Następnym sensownym krokiem byłoby zaprojektowanie **architektury installera V1** — jeszcze bez pisania kodu: layout, `install/update/uninstall/doctor`, wersjonowanie, backup/rollback oraz sposób instalowania dependencies.

[1]: https://github.com/ultherego/dev-nvim/tags "Tags · ultherego/dev-nvim · GitHub"
[2]: https://github.com/ultherego/dev-nvim/actions/runs/31265172116 "docs(audit): clear completed audit · ultherego/dev-nvim@b2df599 · GitHub"
[3]: https://github.com/ultherego/dev-nvim/actions/runs/31272762410/workflow "docs(audit): clear completed audit · ultherego/dev-nvim@df03a80 · GitHub"
[4]: https://github.com/ultherego/dev-nvim/blob/main/lua/config/lazy.lua "dev-nvim/lua/config/lazy.lua at main · ultherego/dev-nvim · GitHub"
[5]: https://github.com/ultherego/dev-nvim/blob/main/lua/devops/health.lua "dev-nvim/lua/devops/health.lua at main · ultherego/dev-nvim · GitHub"
[6]: https://github.com/ultherego/dev-nvim/releases/tag/v1.1.0 "Release v1.1.0 — two audits closed · ultherego/dev-nvim · GitHub"
[7]: https://github.com/ultherego/dev-nvim/actions/runs/31272762410 "docs(audit): clear completed audit · ultherego/dev-nvim@df03a80 · GitHub"
[8]: https://github.com/ultherego/dev-nvim "GitHub - ultherego/dev-nvim · GitHub"


Tak — i w Twoim przypadku **TUI ma dużo więcej sensu niż klasyczny `install.sh`**, bo DevOps nVim ma już sporo niezależnych funkcjonalności i zależności.

Kluczowa decyzja architektoniczna: **TUI nie powinno wykonywać instalacji bezpośrednio**. Powinno tylko zbierać wybory użytkownika, a właściwy installer powinien mieć osobny engine. Dzięki temu później dostaniesz zarówno interaktywny TUI, jak i tryb automatyczny.

Widzę to mniej więcej tak:

```text
dev-nvim installer
│
├── TUI
│   ├── Welcome
│   ├── Environment detection
│   ├── Component selection
│   ├── Dependency preview
│   ├── Installation plan
│   ├── Confirmation
│   ├── Progress
│   └── Final health check
│
├── installer engine
│   ├── detect
│   ├── resolve dependencies
│   ├── backup
│   ├── install
│   ├── configure
│   ├── verify
│   └── rollback
│
└── manifests
    ├── core
    ├── terraform
    ├── kubernetes
    ├── helm
    ├── ansible
    ├── aws
    └── vault
```

### TUI

Przykładowo użytkownik odpala:

```fish
dev-nvim install
```

i dostaje:

```text
╭──────────────────────────────────────────────╮
│              DevOps nVim Installer           │
│                    v1.0.0                    │
╰──────────────────────────────────────────────╯

System detected:

  OS              CachyOS / Arch Linux
  Architecture    x86_64
  Neovim          0.12.4
  Git             2.51.0
  Package manager pacman

Select components:

  [x] Core
  [x] Treesitter
  [x] LSP
  [x] Completion

  DevOps:
  [x] Terraform / OpenTofu
  [x] Kubernetes
  [x] Helm
  [ ] Ansible
  [x] AWS
  [ ] Vault

  Tools:
  [x] Telescope / fzf
  [x] Git integration
  [ ] Debugging
```

Po wyborze:

```text
Dependencies required

Core
  ✓ git
  ✓ curl
  ✓ ripgrep
  ✓ fd
  ✓ fzf
  ✓ bat
  ✓ tree-sitter

Terraform
  ✓ terraform
  + terraform-ls

Kubernetes
  ✓ kubectl
  + helm-ls
  + yaml-language-server

AWS
  ✓ aws-cli

──────────────────────────────────────────────

Already installed: 9
Will install:      3
Optional missing:  1
```

I dopiero później:

```text
Installation plan

DevOps nVim:
  ~/.config/devops-nvim

Existing configuration:
  ~/.config/devops-nvim

Action:
  Backup → ~/.local/share/dev-nvim/backups/2026-08-08T2058

Version:
  v1.2.0

Components:
  Core
  Terraform
  Kubernetes
  Helm
  AWS

Proceed?

    Install
    Back
    Cancel
```

## Najważniejsze: komponenty powinny być deklaratywne

Nie robiłbym w kodzie czegoś w rodzaju:

```go
if terraform {
    installTerraform()
}
```

po całym projekcie.

Lepiej mieć definicję komponentu:

```yaml
id: terraform
name: Terraform / OpenTofu

requires:
  - core

tools:
  required:
    - terraform|tofu

  recommended:
    - terraform-ls
    - tflint

nvim:
  modules:
    - devops.terraform
```

Kubernetes:

```yaml
id: kubernetes
name: Kubernetes

requires:
  - core

tools:
  required:
    - kubectl

  recommended:
    - helm
    - kubectl-neat

nvim:
  modules:
    - devops.kubernetes
```

Dzięki temu dodanie za pół roku:

```text
Docker
GitLab
ArgoCD
Flux
Terragrunt
Packer
```

nie oznacza przebudowy installera.

### Dependency resolver

To według mnie jeden z najważniejszych elementów.

Jeżeli użytkownik wybierze:

```text
[x] Terraform
[x] Kubernetes
[ ] Core
```

installer powinien sam stwierdzić:

```text
Terraform requires Core
Kubernetes requires Core

Core has been automatically selected.
```

Analogicznie:

```text
[x] Helm
```

może implikować:

```text
[x] Kubernetes
[x] Core
```

Czyli powstaje prosty dependency graph:

```text
              Core
          ┌────┼─────┐
          │    │     │
     Terraform │   Ansible
               │
          Kubernetes
               │
              Helm
```

To będzie dużo lepsze niż kilkadziesiąt niezależnych checkboxów.

## Profile

Dodałbym też gotowe profile.

Na pierwszym ekranie:

```text
Choose installation type

> Recommended DevOps
  Minimal
  Kubernetes
  Terraform
  Full
  Custom
```

Przykładowo:

```text
Minimal
  Core
  Treesitter
  LSP
  Git
  Search

Terraform
  Minimal
  Terraform
  Vault
  AWS

Kubernetes
  Minimal
  Kubernetes
  Helm
  YAML

Recommended DevOps
  Minimal
  Terraform
  Kubernetes
  Helm
  Ansible
  AWS
  Vault
```

I oczywiście:

```text
Custom
```

otwiera pełną checklistę.

## Nie mieszałbym dwóch rzeczy

Bardzo ważne rozróżnienie:

### 1. Neovim features

```text
Terraform support
Kubernetes support
Ansible support
AWS support
Vault support
```

### 2. System tools

```text
terraform
kubectl
helm
ansible
aws
tflint
shellcheck
yamllint
```

Użytkownik może mieć już:

```text
terraform
kubectl
aws
```

więc absolutnie nie chcemy mu ich reinstalować.

TUI powinno pokazywać:

```text
Terraform support

Neovim configuration
  [x] Install

External tools

  ✓ terraform      1.14.3
  ✓ terraform-ls   0.38.5
  ! tflint         not installed

Install recommended missing tools?

  [x] terraform-ls
  [ ] tflint
```

To jest moim zdaniem dużo bardziej profesjonalne.

## Installer nie powinien być package managerem

Tu również trzymałbym granicę.

Installer może znać:

```text
pacman
apt
dnf
zypper
brew
```

ale powinien rozróżniać:

```text
required
recommended
optional
```

Jeżeli czegoś nie potrafi bezpiecznie zainstalować:

```text
terraform-docs was not found.

Automatic installation is not supported on this platform.

Installation command:

  pacman -S terraform-docs
```

zamiast kombinowania z `curl | sh`.

## Konfiguracja użytkownika

TUI powinno również mieć sekcję:

```text
Configuration

Leader key
  Space

Theme
  Catppuccin Mocha

Default Terraform executable
  ● Auto detect
  ○ terraform
  ○ tofu

AWS strict identity protection
  ● Enabled
  ○ Disabled

Vault support
  ● Enabled
  ○ Disabled
```

Ale tutaj byłbym ostrożny.

**Installer powinien pytać tylko o rzeczy naprawdę potrzebne przy instalacji.**

Nie robiłbym kreatora 40 ustawień Neovim. Resztę użytkownik może później ustawiać w konfiguracji.

## Bardzo ważna funkcja: zapis wyboru

Po instalacji:

```text
~/.config/devops-nvim/.dev-nvim-install.json
```

na przykład:

```json
{
  "version": "1.2.0",
  "profile": "custom",
  "components": [
    "core",
    "terraform",
    "kubernetes",
    "helm",
    "aws"
  ]
}
```

To pozwala później zrobić:

```fish
dev-nvim update
```

bez ponownego pytania użytkownika o wszystko.

A:

```fish
dev-nvim components
```

otwiera TUI:

```text
Installed components

[x] Core
[x] Terraform
[x] Kubernetes
[x] Helm
[ ] Ansible
[x] AWS
[ ] Vault

Save changes
```

To jest już dużo ciekawsze niż jednorazowy installer.

## Wtedy CLI naturalnie wyglądałoby tak

```text
dev-nvim
├── install
├── update
├── uninstall
├── doctor
├── components
├── version
└── rollback
```

Przykładowo:

```fish
dev-nvim install
```

TUI.

Ale również:

```fish
dev-nvim install --profile terraform
```

bez TUI.

Albo:

```fish
dev-nvim install \
    --components core,terraform,kubernetes,aws \
    --non-interactive
```

To później umożliwia używanie go w Ansible, cloud-init czy bootstrapie workstation.

## Technologia

Dla tego projektu wybrałbym **Go**.

Nie robiłbym tego w shellu.

Dostałbyś pojedynczą binarkę:

```text
dev-nvim
```

bez zależności runtime:

```text
Python
Node
npm
pip
dialog
whiptail
```

I architekturę:

```text
cmd/
  dev-nvim/

internal/
  tui/
  installer/
  detector/
  packages/
  components/
  health/
  backup/
  release/
```

TUI:

```text
Bubble Tea
```

plus komponenty typu selectable list / spinner / progress bar.

To dobrze pasowałoby do charakteru projektu.

---

Widzę więc **pseudoinstaller V1 nie jako skrypt instalacyjny**, tylko jako mały osobny program:

```text
                        ┌───────────────┐
                        │      TUI      │
                        └───────┬───────┘
                                │
                         user selection
                                │
                                ▼
                     ┌─────────────────────┐
                     │ Component resolver  │
                     └─────────┬───────────┘
                               │
                         install plan
                               │
            ┌──────────────────┼──────────────────┐
            ▼                  ▼                  ▼
      environment          packages           config
       detection           manager            manager
            │                  │                  │
            └──────────────────┼──────────────────┘
                               ▼
                        transactional
                         installer
                               │
                       ┌───────┴───────┐
                       ▼               ▼
                    verify          rollback
                       │
                       ▼
                 :checkhealth
```

**Tak zaprojektowany installer byłby według mnie odpowiednim kolejnym dużym elementem DevOps nVim.** Szczególnie mocno trzymałbym zasadę: **TUI wybiera → resolver buduje plan → użytkownik widzi plan → engine wykonuje → health check weryfikuje → rollback przy krytycznej porażce.**

