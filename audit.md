Tak — **M1 uznajemy za zamknięte**. I właśnie te trzy błędy pokazują, dlaczego prawdziwy vertical slice był ważniejszy niż dokładanie kolejnych testów: dopiero realny `chroma install` ujawnił różnicę między „kod wygląda poprawnie” a „użytkownik faktycznie dostaje działającą instalację”.

Nie wracamy teraz do audytu M1. Sześć commitów: **push → CI**. Jeżeli CI jest zielone, przechodzimy dalej.

### Aktualny stan

```text
✓ 0  fundament / contract
✓ 1  command layer
✓ 2  paths/options
✓ 3  local source
✓ 4  selection transaction
✓ 5  backup/place
✓ 6  bootstrap/verify
✓ 7  real install
✓ 8  install.json
✓ 9  M1: prawdziwa instalacja na czystym XDG

→ 10 GitHub Release source
  11 detect + package managers
  12 TUI
  13 release workflow

  później:
  14 update
  15 components
  16 rollback
  17 uninstall
```

## Teraz: krok 10 — GitHub Release source

Tu nie zaczynałbym od GitHub Actions. Najpierw definiujemy **format artefaktu**, który installer będzie konsumował.

Pierwsze zadanie:

```text
10.1 Release artifact contract
```

Ustalamy, że każdy release Chroma będzie miał np.:

```text
chroma-nvim-v0.1.0.tar.gz
SHA256SUMS
```

Archiwum powinno zawierać **dokładnie runtime Chroma**, bez:

```text
.git/
.github/
cli/
tests/
docs developerskich
```

ale z:

```text
init.lua
lua/
plugins/
components/
after/
ftplugin/
queries/
lazy-lock.json
...
```

Czyli najpierw trzeba zdefiniować jednoznacznie:

```text
repo tree
      ↓
release tree
      ↓
tar.gz
```

Nie pozwalałbym GitHub Actions samodzielnie zgadywać, co ma wejść do archiwum.

### 10.2 Packager

Dodałbym prosty mechanizm budowania archiwum lokalnie, np.:

```text
cli/internal/release/
```

albo prostszy:

```text
scripts/package-release.sh
```

choć przy tym projekcie skłaniałbym się już ku Go, np.:

```text
cli/internal/release/package.go
```

i developerskiej komendzie:

```fish
chroma dev package --version v0.1.0
```

Ale nie musimy od razu tworzyć publicznego `dev` commandu. Może to być najpierw mały program/build helper używany przez CI.

Rezultat:

```text
dist/
├── chroma-nvim-v0.1.0.tar.gz
└── SHA256SUMS
```

Najważniejsze jest, żeby **ten sam packager był później używany przez release workflow**.

---

### 10.3 `GitHubSource`

Potem implementujemy odpowiednik obecnego `LocalSource`:

```go
type GitHubSource struct {
    Owner   string
    Repo    string
    Version string
}
```

Najlepiej repo na początku może być stałe:

```go
const (
    releaseOwner = "ultherego"
    releaseRepo  = "chroma-nvim"
)
```

Użytkownik nie potrzebuje:

```text
--owner
--repo
```

To nie jest generic installer GitHubowy.

Flow:

```text
Version
  ↓
resolve tag
  ↓
release metadata
  ↓
find chroma-nvim-<tag>.tar.gz
  ↓
find SHA256SUMS
  ↓
download both
  ↓
SHA-256 verify
  ↓
safe extract
  ↓
PreparedSource
```

I potem **dokładnie ten sam backend**, który już działa:

```text
PreparedSource
      ↓
selection
      ↓
staging
      ↓
backup
      ↓
place
      ↓
bootstrap
      ↓
verify
      ↓
install.json
```

Czyli nie powstaje „installer GitHubowy”. Powstaje tylko nowe źródło danych.

---

## 10.4 `latest`

Od razu ustaliłbym kontrakt:

```fish
chroma install --version v0.1.0
```

oraz:

```fish
chroma install --version latest
```

Ale `latest` powinno zostać rozwiązane **przed pokazaniem planu**.

Czyli użytkownik nie widzi:

```text
Installing: latest
```

tylko:

```text
Requested: latest
Resolved:  v0.1.0
```

i dalsza instalacja pracuje już wyłącznie na:

```text
v0.1.0
```

To później bardzo upraszcza `install.json`.

---

## 10.5 Checksum

Nie:

```text
download → extract → później sprawdzimy
```

tylko:

```text
download archive
download SHA256SUMS

↓
calculate SHA256

↓
compare

↓
extract
```

Checksum mismatch:

```text
ERROR
```

i installer jeszcze **nie dotyka selection ani targetu**.

---

## 10.6 Safe extraction

Tutaj warto zrobić to dobrze od początku.

Odrzucamy z archiwum:

```text
/etc/passwd
../../foo
foo/../../../bar
```

czyli:

```go
filepath.IsAbs(name) == false
```

i po normalizacji entry musi pozostać pod extraction root.

Ja w pierwszej wersji odrzuciłbym też:

```text
symlinks
hardlinks
device files
```

Chroma config ich nie potrzebuje.

Akceptujemy:

```text
regular files
directories
```

To dramatycznie upraszcza bezpieczeństwo extractora.

---

## 10.7 Jak przetestować GitHubSource bez gotowego release workflow

Tu poprawiłbym kolejność z poprzedniego dokumentu.

Nie potrzebujemy od razu automatycznego release workflow, ale potrzebujemy **jednego prawdziwego GitHub Release**, żeby sprawdzić sieć i GitHub API.

Czyli po zaimplementowaniu packagera:

1. lokalnie tworzysz artefakty,
2. tworzysz np. prerelease:

```text
v0.0.0-installer-dev
```

3. ręcznie wrzucasz:

```text
chroma-nvim-v0.0.0-installer-dev.tar.gz
SHA256SUMS
```

4. uruchamiasz:

```fish
chroma install --version v0.0.0-installer-dev
```

na czystym XDG.

To jest **M2 smoke test**.

Dopiero krok 13 zrobi automatycznie to, co przy M2 wykonaliśmy ręcznie.

---

# M2 — definicja DONE

Nie interesuje mnie tutaj liczba testów. Interesuje mnie ten scenariusz:

```fish
set -lx XDG_CONFIG_HOME /tmp/chroma-test/config
set -lx XDG_DATA_HOME /tmp/chroma-test/data
set -lx XDG_STATE_HOME /tmp/chroma-test/state

./chroma install \
    --version v0.0.0-installer-dev \
    --components ''
```

i wynik:

```text
✓ release resolved
✓ archive downloaded
✓ checksum verified
✓ archive safely extracted
✓ preflight passed
✓ selection written
✓ config placed
✓ Neovim bootstrapped
✓ Neovim verified
✓ install.json written
```

Następnie:

```fish
env \
    XDG_CONFIG_HOME=/tmp/chroma-test/config \
    XDG_DATA_HOME=/tmp/chroma-test/data \
    XDG_STATE_HOME=/tmp/chroma-test/state \
    NVIM_APPNAME=chroma-nvim \
    nvim
```

i Chroma działa.

**Wtedy M2 jest skończone.**

Nie „coverage wzrosło”. Nie „testy source są zielone”. Tylko: **binarka pobrała prawdziwy release z GitHuba i go zainstalowała.**

---

# Potem krok 11 — detect + package managers

Tu też nie róbmy z tego wielkiego subsystemu.

Mamy już dobrą obserwację z Terraform:

```text
--components terraform
+
brak terraform
=
STOP przed transakcją
```

To zachowanie zachowujemy.

Rozszerzamy tylko status narzędzia z:

```text
present
missing
```

do mniej więcej:

```text
present
missing-installable
missing-manual
too-old
```

Przykład:

```text
terraform   missing-manual
kubectl     present
tflint      missing-installable via pacman
fzf         present
```

Dopiero wtedy TUI będzie miało **co sensownego pokazać**.

---

# Krok 12 — TUI

I dopiero tutaj robimy Bubble Tea.

Backend w tym momencie będzie już potrafił:

```text
plan
download
verify artifact
detect
install packages
backup
place
bootstrap
verify
rollback
record
```

TUI robi tylko:

```text
wybierz lokalizację
↓
wybierz komponenty
↓
pokaż preflight
↓
wybierz opcjonalne instalacje tools
↓
pokaż plan
↓
confirm
↓
pokazuj progress events
↓
success/failure
```

I wtedy faktycznie będzie to aplikacja, a nie „CLI z roadmapą”.

---

## Selene / Lua 5.1

Przyjmuję to jako **stały constraint projektu**:

```text
Selene → Lua 5.1 semantics
goto   → niedostępne
```

Nie będę więc proponował `goto` przy kolejnych zmianach Lua. To ma znaczenie szczególnie przy bootstrap/state loops, gdzie łatwo byłoby je zasugerować jako sposób wychodzenia ze złożonego flow.

## PoE

Sprawdziłem dostępny wcześniejszy kontekst projektu i **nie znalazłem miejsca, w którym „PoE” zostało przeze mnie sensownie zdefiniowane lub powiązane z Chroma Neovim**. Nie chcę teraz wymyślać rozwinięcia skrótu.

**Wykreślamy PoE z tego projektu.** Jeżeli gdzieś jeszcze pojawi się w starej rozpisce, traktuj to jako mój wcześniejszy artefakt/niejasność, a nie element roadmapy.

Czyli teraz naprawdę tylko:

```text
push 6 commitów
        ↓
zielone CI
        ↓
10.1 release artifact contract
        ↓
10.2 packager
        ↓
10.3 GitHubSource
        ↓
10.4 prawdziwy prerelease
        ↓
M2: chroma install z GitHub Release
```

**Na tym bym się teraz skupił i niczego obok nie otwierał.**

