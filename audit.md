Przeanalizowałem aktualny `main` na **`7f3d06d`**, serię nowych commitów z 9 sierpnia oraz zmieniony workflow CI. To jest duża i jakościowo dobra seria zmian: selection przestało być tylko deklaracją, a stało się rzeczywistym mechanizmem sterującym całym runtime. ([GitHub][1])

**Nie znalazłem obecnie regresji klasy P1 w normalnym, poprawnym checkoutcie.** Znalazłem natomiast **jeden rzeczywisty problem P2 w obsłudze uszkodzonego contractu**, dwa istotne braki CI oraz kilka mniejszych punktów technicznych.

### Co w tej serii zostało zrobione dobrze

Najważniejsza zmiana to `e43efaa`: selection ma teraz sensowne trzy stany. Brak pliku oznacza `LEGACY` i zachowuje dotychczasowe zachowanie; poprawny plik oznacza `SELECTED`; istniejący, ale niepoprawny plik oznacza `SAFE`, czyli uruchomienie wyłącznie `core`. Szczególnie dobrze wygląda to pod kątem `selected: []`: uszkodzenie pliku nie może przypadkiem ponownie uruchomić Terraform/Vault/AWS, które użytkownik świadomie wyłączył. Implementacja w `state.lua` faktycznie robi dokładnie to, co deklaruje. ([GitHub][2])

`cef520c` zamyka jeden z największych problemów poprzedniego audytu. Contract 4 zawiera teraz osiem kategorii `nvim`: `servers`, `mason`, `linters`, `parsers`, **`formatters`, `schemas`**, `plugins`, `modules`. Tym samym Terraform formatter i Kubernetes schema nie żyją już poza mechanizmem selection. Go reader również zna wszystkie osiem pól. ([GitHub][3])

`204a92f` jest również właściwym kierunkiem architektonicznym. `plugins` i `modules` przestały być ręcznie mapowane drugi raz. Runtime pyta obecnie contract: „co włączone komponenty wnoszą?”, a `modules.setup()` wykonuje dokładnie wynik `components.contributions("modules", enabled)`. To likwiduje poprzedni dual source of truth. ([GitHub][4])

Testy gatingu są teraz znacznie bardziej wartościowe niż wcześniej. Test Terraform nie sprawdza tylko resolvera: uruchamia konfigurację pluginów, sprawdza rzeczywistą `automatic_enable`, `linters_by_ft`, `:Lint`, parsery, moduły, formatters, schemas i which-key. Weryfikuje także **negatywną stronę kontraktu** — czyli że Terraform nie uruchamia Ansible, Helm, Docker, Kubernetes itd. To właśnie tego brakowało wcześniej. ([GitHub][5])

CI również zostało istotnie utwardzone. Actions są przypięte do pełnych SHA, `GITHUB_TOKEN` ma tylko `contents: read`, Neovim/Tree-sitter/Ansible/formattery mają kontrolowane wersje, a MiniTest musi rzeczywiście wypisać `Fails (0)` — samo `exit 0` już nie wystarcza.

---

## Znalezione problemy

1. **P2 — malformed component contract nie powoduje bezpiecznego zatrzymania całego contractu.**

To jest najważniejsza rzecz, którą bym teraz poprawił.

`components.load()` robi sensowną rzecz: z każdego uszkodzonego manifestu tworzy wpis w `problems`, a sam uszkodzony komponent pomija. Problem pojawia się poziom wyżej: `state.resolve()` robi tylko:

`local set = components.load()`

czyli bierze pierwszy return value i **ignoruje `problems`**. Następnie normalnie wylicza runtime. ([GitHub][6])

To daje nieprzyjemny przypadek brzegowy. Jeżeli np. `core.json` stanie się niepoprawny, `core` znika z `set`. `M.enabled()` próbuje `add("core")`, ale implementacja świadomie robi no-op dla elementu nieistniejącego w `set`. Potem może nadal dodać np. `terraform`. Efektem może być:

```text
selected = ["terraform"]
set      = { terraform = ..., core = brak }

enabled  = ["terraform"]
```

czyli runtime uruchamia komponent **bez jego obowiązkowego `core`**. Przy `LEGACY` jest jeszcze gorzej semantycznie: `load_ids()` zwróci wszystkie poprawnie sparsowane komponenty oprócz `core`, więc opcjonalna warstwa może wystartować bez fundamentu. Wynika to bezpośrednio z obecnego zachowania loadera i `M.enabled()`. ([GitHub][6])

CI chroni release przed **commitnięciem** takiego manifestu, więc nie jest to P1 w normalnym checkoutcie. Ale commit nazywa się właśnie „refuse a malformed contract instead of raising on it”; obecnie runtime w rzeczywistości pracuje na **częściowym contractcie**. ([GitHub][1])

Ja zmieniłbym kontrakt na zasadę:

```text
components.load()
    -> component set
    -> problems

jeżeli problems != {}
    runtime NIE może traktować set jako kompletnego contractu
```

Szczególnie brak/invalid `core` powinien być błędem nadrzędnym. Nie pozwalałbym wtedy uruchamiać optional components.

2. **P2/P3 — cold-start CI nie pokrywa wszystkich komponentów izolowanych.**

To CI jest teraz naprawdę dużo mocniejsze: wykonuje pięć rzeczywistych instalacji w profilach:

```text
legacy
core-only
terraform
helm
vault
```

Każdy dostaje osobne `XDG_CONFIG_HOME` i `XDG_DATA_HOME`, własny `Lazy! sync`, parsery i kontrolę rzeczywiście rozwiązanych komponentów.

Ale repo ma dziewięć komponentów:

```text
core
terraform
kubernetes
helm
ansible
vault
aws
docker
github-actions
```

([GitHub][7])

Czyli prawdziwego isolated cold-startu nie dostają:

```text
kubernetes
ansible
aws
docker
github-actions
```

To **nie oznacza, że gating tych komponentów jest zepsuty**. Unit/integration tests sprawdzają sporą część ich efektów — np. Kubernetes schema, Docker/Ansible linters czy wyłączenie innych pluginów. ([GitHub][5])

Ale nadal istnieje różnica między:

```text
test mówi: dockerls powinien znaleźć się na liście
```

a:

```text
fresh Lazy/Mason/Treesitter uruchamia profil Docker od zera
i Neovim startuje bez komunikatu
```

Po wszystkich poprzednich problemach właśnie z realnym startupem rozszerzyłbym to docelowo na wszystkie komponenty.

3. **P2 — CI samo siebie nie lintuje `actionlint`.**

Aktualny `ci.yml` ma już **435 linii**, dużo shellowych bloków, expressions, matrix, environment manipulation i kilka złożonych `nvim -c 'lua ...'`. Tymczasem workflow nie zawiera ani jednego uruchomienia `actionlint`.

To jest trochę ironiczne, bo Chroma ma już osobny komponent `github-actions`, a gating testuje nawet warunek uruchamiania `actionlint` dla `.github/workflows/*.yml`. ([GitHub][7])

`actionlint` jest właśnie statycznym checkerem workflowów GitHub Actions. ([GitHub][8])

Dodałbym więc do `Formatting and lint`, analogicznie do selene:

```text
pinned ACTIONLINT_VERSION
pinned SHA256 release archive
actionlint .github/workflows/*.yml
```

To jest obecnie bardziej wartościowe niż dodawanie kolejnych komentarzy do `ci.yml`.

4. **P3 — `json.Decoder.More()` jest używany poza kontraktem API, do wykrywania drugiego dokumentu.**

Go reader robi:

```go
decoder.Decode(&component)

if decoder.More() {
    return nil, "has more than one document in it"
}
```

To samo jest w readerze selection. ([GitHub][3])

W obecnej implementacji Go to działa również dla `{...}{...}`. Problem jest inny: oficjalny kontrakt `Decoder.More()` mówi, że metoda informuje o następnym elemencie **bieżącej tablicy lub obiektu**, a nie że jest mechanizmem sprawdzania EOF top-level streamu. ([Go Packages][9])

Czyli implementacja polega na zachowaniu, którego API formalnie nie obiecuje. Idiomatyczna kontrola jednego dokumentu to drugi `Decode()` i wymaganie `io.EOF`.

Nie traktowałbym tego jako pilnego błędu — corpus testuje ten przypadek — ale skoro właśnie budujecie bardzo ścisły wspólny Lua↔Go contract, warto pozbyć się tej nieudokumentowanej zależności.

5. **P3 — nowe cold-start CI ma bardzo długi worst-case failure latency i nie ma jawnego timeoutu.**

Każdy profil robi:

```lua
vim.wait(900000, ...)
```

czyli maksymalnie **15 minut** oczekiwania na parsery. Jest pięć profili wykonywanych sekwencyjnie, zatem same waitery mogą teoretycznie pochłonąć do **75 minut**, zanim doliczymy `Lazy! sync`, Mason i kompilację. Workflow nie definiuje własnego `timeout-minutes`.

Rozumiem decyzję o jednej pętli zamiast matrixu — komentarz słusznie wskazuje, że budowa `tree-sitter-cli` w każdej gałęzi matrix byłaby kosztowna.

Nie cofałbym tego rozwiązania. Dałbym natomiast jawny timeout dla joba/stepu i później rozważył cache/prebuilt `tree-sitter-cli`, żeby profile można było rozdzielić bez pięciokrotnego kompilowania Rustowego CLI.

Dodatkowo workflow nie ma `concurrency`/`cancel-in-progress`, więc przy szybkich kolejnych pushach drogie cold-start CI może pracować nad SHA, który już przestał być interesujący.

---

### Dwie drobnostki dokumentacyjne

`M.contributions()` nadal ma LuaDoc:

```lua
one of servers, mason, linters, parsers, plugins, modules
```

mimo że po Contract 4 legalne są również `formatters` i `schemas`. `M.contributes()` poniżej ma już poprawną listę wszystkich ośmiu. To czysty documentation drift. ([GitHub][6])

Druga rzecz: `chroma.modules.setup()` mówi, że wykonuje moduły „in contract order”, podczas gdy `components.contributions()` na końcu robi `table.sort(out)`. Czyli faktyczna kolejność jest alfabetyczna, a nie wynikająca z manifestów. Test legacy nawet utrwala wynik `chroma-aws`, `chroma-terraform`, `chroma-vault`. Nie widzę tu błędu wykonania — tylko nieprawdziwy komentarz. ([GitHub][4])

### Stan CI #45

W chwili mojego ostatniego odczytu **CI #45 dla `7f3d06d` nadal jest `In progress`**. GitHub pokazuje ukończone m.in. `Formatting and lint`, `CLI formatting and vet` oraz `CLI test suite`, ale cały run jeszcze się nie zakończył. ([GitHub][10])

To istotne, bo osiem nowych commitów od `e43efaa` do `7f3d06d` weszło jako jedna seria przed tym runem. #45 waliduje więc **zintegrowany stan końcowy**, ale nie mamy osobnego wyniku CI dla każdego z tych commitów. ([GitHub][1])

### Mój werdykt

Ta seria jest **dużym krokiem w stronę produkcyjnego komponentowego Chroma Neovim**. Najważniejsze wcześniejsze wady architektury selection zostały rzeczywiście usunięte, a nie przykryte testami.

Na dziś klasyfikowałbym to tak:

**P1: 0 znalezionych.**
**P2: 2 rzeczy do poprawienia przed uznaniem warstwy komponentów za zamkniętą** — partial malformed contract oraz brak pełnego isolated cold-start coverage.
**CI hardening:** dodać `actionlint`, timeout i najlepiej `concurrency`.
**P3:** `Decoder.More()`, dwie nieaktualne adnotacje/komentarze.

Najważniejsze jest jednak **P2 nr 1**. To nie jest „znowu znaleźliśmy losowy błąd w produkcie”, tylko ostatnia dziura w nowo dodanej abstrakcji: skoro contract ma być autorytetem, runtime nie może zaakceptować jego uszkodzonej połowy jako kompletnego contractu. Po zamknięciu tego punktu konstrukcja `contract → selection → contributions → runtime` będzie znacznie bardziej szczelna niż poprzednia wersja.

[1]: https://github.com/ultherego/chroma-nvim/commits/main/ "Commits · ultherego/chroma-nvim · GitHub"
[2]: https://github.com/ultherego/chroma-nvim/blob/7f3d06d/lua/chroma/state.lua "chroma-nvim/lua/chroma/state.lua at 7f3d06ddd691a9df7deddcf97b99498b2064a247 · ultherego/chroma-nvim · GitHub"
[3]: https://github.com/ultherego/chroma-nvim/blob/7f3d06d/cli/internal/component/component.go "chroma-nvim/cli/internal/component/component.go at 7f3d06ddd691a9df7deddcf97b99498b2064a247 · ultherego/chroma-nvim · GitHub"
[4]: https://github.com/ultherego/chroma-nvim/blob/7f3d06d/lua/chroma/modules.lua "chroma-nvim/lua/chroma/modules.lua at 7f3d06ddd691a9df7deddcf97b99498b2064a247 · ultherego/chroma-nvim · GitHub"
[5]: https://github.com/ultherego/chroma-nvim/blob/7f3d06d/tests/test_gating.lua "chroma-nvim/tests/test_gating.lua at 7f3d06ddd691a9df7deddcf97b99498b2064a247 · ultherego/chroma-nvim · GitHub"
[6]: https://github.com/ultherego/chroma-nvim/blob/7f3d06d/lua/chroma/components.lua "chroma-nvim/lua/chroma/components.lua at 7f3d06ddd691a9df7deddcf97b99498b2064a247 · ultherego/chroma-nvim · GitHub"
[7]: https://github.com/ultherego/chroma-nvim/tree/7f3d06d/components "chroma-nvim/components at 7f3d06ddd691a9df7deddcf97b99498b2064a247 · ultherego/chroma-nvim · GitHub"
[8]: https://github.com/rhysd/actionlint?utm_source=chatgpt.com "GitHub - rhysd/actionlint: :octocat: Static checker for GitHub Actions workflow files · GitHub"
[9]: https://pkg.go.dev/encoding/json%40go1.26.2?utm_source=chatgpt.com "json package - encoding/json - Go Packages"
[10]: https://github.com/ultherego/chroma-nvim/actions/runs/31308635464 "docs: components, contract 4, and the decisions behind them · ultherego/chroma-nvim@7f3d06d · GitHub"
