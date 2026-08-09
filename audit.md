Przeszedłem nowe zmiany od persisted state przez aktywną modularizację, ze szczególnym naciskiem na `99be6af`. To jest już **duża zmiana zachowania**, nie tylko kolejna warstwa metadanych: `contract: 3` steruje LSP, Masonem, linterami, Treesitterem, pluginami i setupem modułów. Sam kierunek jest bardzo dobry, a autor zmian już złapał kolejny przypadek pustego testu w helperze `enabled`, co jest dobrym sygnałem jakości procesu. ([GitHub][1])

Nie przechodziłbym jednak jeszcze do write-path installera. Znalazłem **dwa problemy, które uważam za blokujące release modularności**, oraz kilka mniejszych rzeczy do utwardzenia.

## 1. Najważniejszy: `invalid state` w praktyce fail-open

Reader state słusznie odrzuca np. nieznany komponent i komentarz mówi wręcz `Fail closed`.

Ale runtime robi później:

```lua
local state, found, err = M.load(nil, set)

if err then
  vim.notify(...)
  return components.load_ids(), true
end
```

czyli **dowolny błąd istniejącego `components.json` uruchamia wszystkie komponenty**.

Co gorsza, test jawnie utrwala to zachowanie jako oczekiwane:

```text
an unreadable selection is reported
and falls back to everything
```

To jest moim zdaniem błędna polityka.

Rozróżnienie:

```text
brak components.json
→ legacy
→ wszystko
```

jest świetne i należy je zachować.

Ale:

```text
components.json istnieje
→ jest niepoprawny
→ wszystko
```

jest czymś zupełnie innym.

Jeżeli użytkownik miał:

```json
{
  "schema": 1,
  "selected": []
}
```

czyli świadomie **Core only**, a plik zostanie uszkodzony, Chroma nagle uruchomi Terraform, Vault, AWS, Kubernetes, Ansible itd.

Nie możemy wiedzieć, co było „wczoraj”, więc argument zapisany w DESIGN.md, że uruchomienie mniejszej ilości byłoby gorsze, nie jest prawdziwy po pojawieniu się explicit state. DESIGN rzeczywiście definiuje teraz takie zachowanie.

Ja ustawiłbym:

```text
file absent
    → legacy/all

file valid
    → explicit selection

file present + invalid
    → SAFE MODE / core only
    → głośny ERROR
```

Nie wywalałbym całego Neovim. Core-only pozwoli użytkownikowi naprawić plik, ale niczego opcjonalnego nie uruchomi.

I zmieniłbym API z nieprecyzyjnego:

```lua
ids, legacy
```

na coś w rodzaju:

```text
mode = legacy | selected | safe
```

To jest **blocker przed write-path**, bo dopiero wtedy installer zacznie tworzyć ten plik normalnym użytkownikom.

---

# 2. Modularność nie obejmuje wszystkiego — znalazłem rzeczywistą lukę: formatowanie Terraform

`contract: 3` opisuje:

```text
servers
mason
linters
parsers
plugins
modules
```

([GitHub][1])

Ale nie ma:

```text
formatters
```

I w `plugins/formatting.lua` Terraform jest nadal bezwarunkowo skonfigurowany:

```lua
formatters_by_ft = {
  lua = { "stylua" },

  terraform = terraform_formatter,
  ["terraform-vars"] = terraform_formatter,

  hcl = function(bufnr)
    ...
    return { "terragrunt_hclfmt" }
  end,
}
```

Czyli:

```json
{
  "selected": []
}
```

ma oznaczać:

```text
Core only
```

ale otwarcie `.tf` nadal dostaje Chroma-specific Terraform formatting. Jeśli `terraform` albo `tofu` istnieje, kod może go uruchomić.

To przeczy obecnej deklaracji commita:

> Terraform selected → Core + Terraform i żadnego z pozostałych komponentów

([GitHub][1])

To jest dla mnie **realny bug modularizacji**, nie kosmetyka.

Najczystsze rozwiązanie oznacza prawdopodobnie:

```json
"nvim": {
  "formatters": [...]
}
```

a więc niestety:

```text
contract 3
    ↓
contract 4
```

Nie wciskałbym nowego pola do trójki, bo cały sens strict contractu polega właśnie na tym, że starszy reader odrzuca semantykę, której nie zna.

### Jest podobny problem ze schema support

`yamlls` należy do Core, ale jego override zawsze dodaje m.in. Kubernetes schemas i cały katalog SchemaStore. Kubernetes-specific mapping jest zakładany niezależnie od tego, czy komponent Kubernetes jest włączony.

GitHub Actions jest jeszcze ciekawszy. Komponent nazywa się funkcjonalnie obsługą workflowów, ale jego obecny `nvim` contribution sprowadza się do `actionlint`; SchemaStore pozostaje elementem Core, więc po wyłączeniu `github-actions` schema support nadal istnieje. ([GitHub][1])

Tu nie mówię jeszcze, że koniecznie potrzebujemy pola:

```text
schemas
```

w contract v4.

Najpierw trzeba zdecydować semantycznie:

> Czy „component disabled” oznacza brak wszystkich domain-specific conveniences, czy tylko brak narzędzi/pluginów aktywnie należących do komponentu?

Terraform formatter pokazuje jednak, że przynajmniej **formatters** nie można pominąć.

---

# 3. `nvim.modules` i `nvim.plugins` nie są jeszcze naprawdę single source of truth

To jest subtelniejsze.

Manifest AWS mówi:

```json
"nvim": {
  "modules": [
    "chroma-aws"
  ]
}
```

Vault analogicznie deklaruje `chroma-vault`.

Ale `init.lua` nie pyta contractu:

```lua
for _, module in contributions("modules") do
   ...
end
```

tylko ponownie koduje relację ręcznie:

```lua
if enabled.is_enabled("vault") then
  require("chroma-vault").setup(...)
end

if enabled.is_enabled("terraform") then
  require("chroma-terraform").setup(...)
end

if enabled.is_enabled("aws") then
  require("chroma-aws").setup(...)
end
```

Podobnie pluginy. Manifest mówi, że Kubernetes wnosi `kubectl.nvim`, ale `plugins/devops.lua` ponownie ręcznie wie:

```lua
enabled = function()
  return require("chroma.state").is_enabled("kubernetes")
end
```

Obecnie wynik jest poprawny. Problem jest architektoniczny:

```text
components/kubernetes.json
       mówi:
       kubernetes → kubectl.nvim

plugins/devops.lua
       też mówi:
       kubernetes → kubectl.nvim
```

Czyli relacja nadal istnieje w **dwóch miejscach**.

Dla:

```text
servers
mason
linters
parsers
```

jest już dobrze — kod bierze właściwe contribution z manifestów.

Dla:

```text
plugins
modules
```

jeszcze nie.

To bym poprawił zanim contract zacznie być traktowany jako stabilny interfejs installera.

---

# 4. Są jeszcze dwa testy z tej samej klasy „zielone, ale nie dowodzą deklaracji”

I to szczególnie zaznaczam, bo właśnie takie błędy łapiecie ostatnio regularnie.

Test:

```text
terraform only
→ sets up its module and not the others
```

w rzeczywistości robi tylko:

```lua
eq(state.is_enabled("terraform"), true)
eq(state.is_enabled("vault"), false)
eq(state.is_enabled("aws"), false)
```

**Nie sprawdza `init.lua`.**

Mutacja:

```lua
require("chroma-vault").setup(...)
require("chroma-aws").setup(...)
```

bez żadnych `if` w `init.lua` nie spowodowałaby padnięcia tego testu.

Czyli nazwa testu mówi:

> sprawdzam setup modułów

a test rzeczywiście mówi:

> sprawdzam resolver state.

To jest dokładnie pustawa weryfikacja.

Drugi:

```text
does not register other components' linters
```

robi:

```lua
require("plugins.lint")

local linters =
  components.contributions("linters", state.enabled_ids())
```

i sprawdza contract.

Nie wykonuje:

```lua
plugins.lint.config()
```

i nie sprawdza rzeczywistego:

```lua
lint.linters_by_ft
```

Usunięcie filtrowania z prawdziwego `plugins/lint.lua` mogłoby więc nie zabić tego testu, mimo że sam runtime rzeczywiście filtruje prawidłowo.

To poprawiłbym mutation-testem.

---

# 5. CI sprawdza prawdziwy startup, ale tylko w `legacy/all`

Obecny clean-start bootstrap ustawia świeży `XDG_CONFIG_HOME`, symlinkuje repo i odpala:

```text
Lazy! sync
Treesitter parser installation
silent startup
require wszystkich modułów
```

To jest nadal bardzo dobry test integracyjny. Parsery są sprawdzane po rzeczywistym stanie instalacji, a nie po tasku, więc wcześniejsza poprawka z race condition została zachowana.

Problem polega na tym, że job **nie tworzy**:

```text
$XDG_CONFIG_HOME/chroma/components.json
```

A brak state oznacza:

```text
legacy = true
all components enabled
```

Czyli najważniejsza nowa własność:

```text
fresh install
+
core only
```

albo:

```text
fresh install
+
vault only
```

nie ma jeszcze prawdziwego:

```text
Lazy sync
→ bootstrap
→ Mason
→ Treesitter
→ startup
```

na czystym runnerze.

MiniTest sprawdza specy, ale to nie jest ten sam poziom dowodu.

Po poprawkach powyżej dodałbym do CI profile smoke-test:

```text
legacy/all
core-only
terraform-only
helm-only
vault-only
```

Nie musisz od razu robić dziewięciu ciężkich bootstrapów, ale minimum kilka niezależnych kształtów powinno przejść realny cold start.

---

# 6. Lua i Go nadal nie są równie strict dla component contract

Go korzysta z typed decoding + `DisallowUnknownFields()`.

Lua sprawdza unknown fields, ale przed pełną walidacją struktury robi np.:

```lua
for key, level in pairs(decoded.tools or {}) do
  ...
  for _, tool in ipairs(level) do
```

oraz:

```lua
for key in pairs(decoded.nvim or {}) do
```

Dla malformed shape typu:

```json
"tools": {
  "required": "oops"
}
```

albo:

```json
"nvim": "oops"
```

nie dostajesz kontrolowanego:

```text
component invalid
```

tylko ryzyko błędu podczas `pairs/ipairs`.

`requires` też nie ma przed użyciem równie silnej walidacji strukturalnej; później resolver zakłada, że może wykonać `ipairs(component.requires)`.

To oznacza, że deklaracja:

> oba readery mają te same reguły

nie jest jeszcze całkiem prawdziwa dla błędnych **typów**, mimo że jest już bardzo dobra dla błędnych pól i semantyki wersji.

Dałbym component contractowi taki sam **shared invalid corpus**, jaki bardzo dobrze zrobiliście dla component state.

---

# 7. Go `Decoder` nie sprawdza końca dokumentu

Zarówno component reader:

```go
decoder.Decode(&component)
```

jak i state reader:

```go
decoder.Decode(&state)
```

wykonują tylko jeden `Decode()`.

Standardowa biblioteka Go definiuje `Decode` jako odczyt **następnej** wartości JSON, ponieważ decoder obsługuje strumienie wielu wartości JSON. ([Go Packages][2])

Czyli strict reader powinien po pierwszym obiekcie wymagać EOF. W przeciwnym razie konstrukcja w rodzaju:

```text
{ poprawny component }
{ drugi dokument }
```

może zostać zaakceptowana jako pierwszy poprawny JSON zamiast odrzucona jako cały niepoprawny plik.

Mały fix, ale warto go zrobić teraz, skoro strict parsing stał się częścią kontraktu.

---

# 8. Writer ma trzy rzeczy do poprawienia przed pierwszym użyciem przez CLI

Sam kierunek write path jest dobry:

```text
temp
→ write
→ fsync file
→ close
→ chmod
→ rename
→ fsync directory
```

Ale końcówka robi:

```go
handle, err := os.Open(dir)
if err != nil {
    return nil
}

_ = handle.Sync()
return nil
```

Czyli kod i DESIGN twierdzą „fsync directory”, ale **obie potencjalne porażki durability są ignorowane**. DESIGN opisuje writer jako atomic + fsync parent.

Ponadto `Write()` nie robi przed zapisem:

```go
state.validate(set)
```

więc samo API może wygenerować plik zawierający:

```text
core
unknown component
duplicate
```

który następny startup odrzuci.

Na dziś to nie jest jeszcze exploitowalny problem installera, bo mutujący installer nie istnieje. Ale **przed pierwszym callerem `Write()` należy zamknąć invariants w samym writerze**, nie liczyć na to, że TUI zawsze poda poprawne dane.

Jest też mniejsza rozbieżność ścieżki: jeśli Go nie potrafi ustalić HOME, `Path()` zwraca względne:

```text
.config/chroma/components.json
```

Lua w analogicznej sytuacji próbuje homedir/`~`.

Ja wolałbym, aby Go zwróciło błąd niż kiedykolwiek zapisało state względem przypadkowego `$PWD`.

---

## Dokumentacja też już trochę odjechała

`state.lua` nadal ma na górze:

```text
Nothing reads this yet to decide what to load.
gating comes next
```

mimo że właśnie `99be6af` wprowadził gating.

Znacznie ważniejsze: `DESIGN.md` na SHA `99be6af` nadal pokazuje przykład:

```json
"contract": 1,
...
"nvim": {
  "plugins": ["plugins.devops"],
  "modules": ["chroma-terraform"]
}
```

podczas gdy bieżący kod jest już na **contract 3** z `servers/mason/linters/parsers/plugins/modules`.

To nie jest blocker runtime, ale DESIGN zaczyna pełnić rolę specyfikacji architektury, więc nie pozwalałbym mu zostać dwa kontrakty wstecz.

---

# Co oceniam bardzo dobrze

Nowa architektura zaczyna faktycznie działać tak, jak chcieliśmy. LSP `ensure_installed` i `automatic_enable` są wyliczane z enabled components, Mason tool installer filtruje pakiety po component contributions, linters są filtrowane, Treesitter bierze parsery z contractu, a Kubernetes/Ansible/Helm mają realne `enabled` na plugin specs.

Podoba mi się też, że commit sam dokumentuje znaleziony pusty test helpera. To nie jest kosmetyczne: taka mutacja pokazuje, że test suite jest traktowany jako dowód własności, a nie licznik zielonych przypadków. ([GitHub][1])

## Mój werdykt i kolejność

Teraz zrobiłbym dokładnie:

1. **Naprawić explicit-invalid-state → all**; brak pliku pozostaje legacy/all, błędny istniejący plik przechodzi w core-only safe mode.
2. **Dokończyć modularność**: przede wszystkim Terraform formatting; rozstrzygnąć również semantics schemas i ukryć nieaktywne grupy WhichKey.
3. **Uczynić `plugins/modules` naprawdę contract-driven**, zamiast ręcznie powtarzać mapowanie komponent → contribution.
4. **Zabić dwie pozostałe puste weryfikacje** dla module setup i runtime linter registration.
5. **Utwardzić readery**: Lua structural types + Go EOF po pierwszym JSON.
6. **Utwardzić state writer**: validate-before-write, nie ignorować directory sync, nie używać względnego fallback path.
7. **Dodać selected-profile cold-start CI**.
8. Dopiero po zielonym CI tego zestawu wejść w **pierwszy prawdziwy installer write-path**.

Czyli: **fundament jest dużo mocniejszy niż przed ostatnią serią i component model przestał być atrapą. Ale `99be6af` jeszcze nie domyka obietnicy „selection decides what runs” w 100%.** Najbardziej namacalnym kontrprzykładem jest teraz Terraform formatter; najbardziej niebezpieczną semantyką na przyszłość jest zaś invalid explicit state → enable everything.

Po zamknięciu tych punktów uznam warstwę **taxonomy → contract → persisted state → runtime gating** za gotową i przestałbym ją dalej przebudowywać. Następna granica byłaby wtedy już rzeczywiście po stronie installera.

[1]: https://github.com/ultherego/chroma-nvim/commit/99be6af "feat(components): a selection now decides what runs · ultherego/chroma-nvim@99be6af · GitHub"
[2]: https://pkg.go.dev/encoding/json%40go1.26.2?utm_source=chatgpt.com "json package - encoding/json - Go Packages"
