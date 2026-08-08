Zakończyłem audyt repozytorium przypięty do konkretnego stanu:

**commit `effbcd8726f78a9d6270300f4a6425d53a749d4d`** z `main`. ([github.com][1])

Nie traktowałem `README.md`, `CONTRACT.md`, komentarzy ani deklarowanego zachowania jako źródła prawdy. Przechodziłem przez wykonywalny kod Lua, konfigurację, autocommandy, subprocessy, LSP, testy, CI oraz — tam gdzie zachowanie zależy od Neovima/pluginu — przez rzeczywiste API lub kod upstream.

Po odrzuceniu false positives zostaje **10 rzeczywistych problemów: 3 HIGH, 4 MEDIUM i 3 LOW**.

## Wyniki audytu

1. **HIGH / P1 — race condition między równoległymi `TerraformPlan`**

   `terraform.nvim` rozdziela pojęcie „aktualnej generacji planu” od `planning[dir]`, ale `planning[dir]` zachowuje się jak boolean, a nie licznik aktywnych procesów.

   Możliwa kolejność:

   ```text
   Plan A / generation 1 ─────────────── still running
       Plan B / generation 2 ─── finishes
                               ↓
                        planning[dir] = nil
                               ↓
                       TerraformApply
                       albo TerraformInit
                               ↓
   Plan A nadal fizycznie działa
   ```

   Generacje prawidłowo zabezpieczają przed tym, żeby callback starego A nadpisał wynik B. **Nie zabezpieczają jednak lifecycle przed tym, że A wciąż działa.**

   `finish_planning()` może wyczyścić `planning[dir]` po zakończeniu nowszej generacji, mimo że starszy subprocess nadal istnieje. `apply()` i `init()` sprawdzają właśnie `planning[dir]`, więc w tym oknie dopuszczą operację. ([GitHub][2])

   Testy dotyczą stale callbacków i pojedynczego aktywnego planu, ale nie odwzorowują dokładnie interleavingu „A wolny → B szybki → B kończy → A nadal działa”. ([GitHub][3])

   **Naprawa:** osobny licznik/set:

   ```lua
   active_plans[dir][generation] = true
   ```

   i blokowanie `init/apply` dopóki istnieje **jakikolwiek** aktywny proces planowania. `current_generation` powinien dalej decydować tylko o tym, który wynik może stać się reviewed plan.

2. **HIGH / P1 — Vault można zapisać na dysk jako plaintext przez standardowe warianty `:write`**

   Odszyfrowany Vault przechwytuje `BufWriteCmd`. To zabezpiecza zapis **całego bufora**. ([GitHub][4])

   Neovim ma jednak oddzielne ścieżki:

   * `BufWriteCmd` — cały buffer,
   * `FileWriteCmd` — zapis części bufora,
   * `FileAppendCmd` — append.

   Dla jednego write command używany jest tylko jeden z tych zestawów eventów. ([Neovim][5])

   Czyli z odszyfrowanego Vault:

   ```vim
   :1,10write /tmp/secret.yml
   ```

   jest `FileWriteCmd`, a nie `BufWriteCmd`.

   Podobnie:

   ```vim
   :1,10write >> /tmp/secret.log
   ```

   korzysta z `FileAppendCmd`. Semantyka tych poleceń jest bezpośrednio zdefiniowana przez Neovima. ([Neovim][6])

   W obecnym module nie ma ochrony tych ścieżek. Rezultat: **standardowym poleceniem Neovima można wyprowadzić odszyfrowany fragment Vault na persistent storage jako plaintext.**

   To jest najważniejszy problem w `ansible-vault`.

   **Naprawa:** buffer-local `FileWriteCmd` i `FileAppendCmd` dla `ansible_vault_plain`, najlepiej fail-closed:

   ```text
   Refusing partial/append write from decrypted Vault buffer
   ```

   Osobno trzeba jednoznacznie obsłużyć i przetestować `:write {other-file}` oraz `:saveas`.

3. **HIGH / P1 — `swapfile=false` i `undofile=false` nie zapobiegają persistence plaintextu przez ShaDa**

   Vault po decrypt ustawia m.in.:

   ```lua
   swapfile = false
   undofile = false
   modeline = false
   ```

   co jest poprawnym hardeningiem. ([GitHub][4])

   Problem: **ShaDa jest niezależnym mechanizmem persistence.**

   Neovim domyślnie zapisuje do ShaDa m.in.:

   * command-line history,
   * search history,
   * input history,
   * zawartość niepustych registerów,
   * marks i buffer list.

   Domyślna lokalizacja na Unix to:

   ```text
   $XDG_STATE_HOME/nvim/shada/main.shada
   ```

   ([Neovim][7])

   Normalne operacje:

   ```vim
   yy
   y{motion}
   dd
   d{motion}
   c{motion}
   ```

   umieszczają tekst w registerach; ShaDa zapisuje ich zawartość. ([Neovim][8])

   W konfiguracji dodatkowo masz globalne:

   ```lua
   clipboard = "unnamedplus"
   ```

   więc operacje, które normalnie używają unnamed register, korzystają również z systemowego `+` clipboard. ([GitHub][9])

   Są tu więc dwa różne problemy:

   **ShaDa:** plaintext może rzeczywiście trafić do pliku na dysku.

   **System clipboard:** plaintext opuszcza Neovima i trafia do clipboard providera; jeśli środowisko ma clipboard manager z historią, może zostać przez niego utrwalony. Sam Neovim nie gwarantuje persistence clipboardu. ([Neovim][10])

   Jeśli modelem bezpieczeństwa jest „odszyfrowana treść nie może znaleźć się na persistent storage”, obecna implementacja tego **nie gwarantuje**.

   Najmocniejsze rozwiązanie to secure editing context z:

   ```text
   nvim -i NONE
   ```

   oraz wyłączonym `clipboard`. `-i NONE` oficjalnie wyłącza czytanie i zapisywanie ShaDa. ([Neovim][11])

   Próba dynamicznego przełączania globalnego ShaDa/clipboard tylko podczas istnienia Vault buffer jest możliwa, ale dużo bardziej skomplikowana ze względu na wiele jednoczesnych buforów.

4. **MEDIUM / P2 — plaintext Vault jest automatycznie przekazywany do zewnętrznych subprocessów**

   Po decrypt moduł wykonuje ponowne `filetype detect`, przez co typowy `.yaml/.yml` staje się normalnym buforem YAML. ([GitHub][4])

   Konfiguracja automatycznie uruchamia `yamlls`. ([GitHub][12])

   Neovim przy `textDocument/didOpen` przekazuje language serverowi **pełny tekst bufora**, nie tylko filename. ([GitHub][13])

   Czyli:

   ```text
   ansible-vault
        ↓ decrypt
   plaintext w bufferze
        ↓
   yaml-language-server
   ```

   Dodatkowo `nvim-lint` ma dla YAML `yamllint`, a przypięta konfiguracja `yamllint` wykorzystuje `stdin=true`. ([GitHub][14])

   W szczególności późniejszy `InsertLeave` może więc wysłać odszyfrowany YAML do `yamllint`.

   To **nie jest network exfiltration**. Są to lokalne subprocessy. Ale rozszerza to security boundary poza pamięć Neovima i proces `ansible-vault`.

   **Naprawa:** gdy:

   ```lua
   vim.b.ansible_vault_plain == true
   ```

   nie uruchamiać LSP, linterów ani formatterów przekazujących treść procesu zewnętrznemu.

   Samo odpinanie klienta w `LspAttach` jest za późne jako pełne zabezpieczenie initial payload — `didOpen` jest wysyłane w lifecycle klienta przed późniejszym attach handlingiem. ([GitHub][13])

5. **MEDIUM / P2 — `strict_aws_identity=true` zachowuje się fail-open**

   Nazwa sugeruje rygorystyczną kontrolę identity. Implementacja jest jednak best-effort.

   Jeżeli:

   ```text
   aws sts get-caller-identity
   ```

   nie zadziała przy `plan`, zapisany context może mieć:

   ```lua
   account = nil
   arn = nil
   ```

   i pojawia się tylko warning.

   Jeśli STS ponownie nie zadziała przy `apply`, ponownie otrzymujesz `nil/nil`. Jeżeli profile/region się nie zmieniły, comparison nie wykryje identity drift i apply może być kontynuowany. ([GitHub][2])

   Czyli przy:

   ```lua
   strict_aws_identity = true
   ```

   stan:

   ```text
   identity unverifiable
   ```

   nie jest traktowany jako:

   ```text
   apply forbidden
   ```

   **Naprawa:** w trybie strict:

   ```text
   PLAN: STS failure -> abort
   APPLY: STS failure -> abort
   ```

   Jeżeli obecne zachowanie jest pożądane, lepszy byłby model:

   ```lua
   aws_identity = "off"
   aws_identity = "best_effort"
   aws_identity = "required"
   ```

6. **MEDIUM / P2 — Helm `*.tpl` ma cold-start lazy-loading cycle**

   `vim-helm` jest ładowany dla:

   ```lua
   ft = { "helm", "yaml" }
   ```

   ([GitHub][12])

   Ale w Neovim 0.12.4 builtin filetype detection przypisuje zwykłe `*.tpl` do `smarty`. ([GitHub][15])

   Sam `vim-helm` posiada logikę, która rozpoznaje `templates/*.tpl` jako Helm na podstawie struktury Chart i `Chart.yaml`, lecz ta logika jest instalowana przez autocommand pluginu. ([GitHub][16])

   Powstaje cykl przy cold startup:

   ```text
   otwierasz templates/_helpers.tpl
            ↓
   Neovim: ft=smarty
            ↓
   lazy.nvim: vim-helm nie ładuje się
            ↓
   autocommand vim-helm nie istnieje
            ↓
   ft pozostaje smarty
   ```

   Jeżeli wcześniej otworzysz YAML chartu i plugin zostanie załadowany, problem może zniknąć. Problem dotyczy więc przede wszystkim sytuacji, gdy `.tpl` jest pierwszym otwartym plikiem chartu.

   **Naprawa:** załadować `vim-helm` wcześniej dla pattern `*.tpl`, ewentualnie zastąpić detection własnym `vim.filetype.add()`.

7. **MEDIUM / P2 — AWS UI może zawiesić Neovima na nieograniczony czas**

   `lua/aws/init.lua` wykonuje:

   ```lua
   vim.system(...):wait()
   ```

   bez timeoutu. ([GitHub][17])

   Według API Neovima `SystemObj:wait()` bez timeoutu czeka bezterminowo, jeśli subprocess nie zakończy się sam lub nie podano timeoutu przy jego uruchomieniu. ([Neovim][18])

   AWS CLI może czekać m.in. na wolny credential process, SSO, DNS czy połączenie do AWS. Efektem jest blokowanie wykonania Lua/UI.

   **Docelowa naprawa:** przejście na asynchronous:

   ```lua
   vim.system(cmd, opts, function(result)
       vim.schedule(function()
           ...
       end)
   end)
   ```

   i timeout.

   Sam `:wait(5000)` ogranicza katastrofę, ale przez te 5 sekund nadal jest synchroniczny.

8. **LOW / P3 — race przy pierwszej instalacji parserów Treesitter**

   Brakujące parsery są instalowane asynchronicznie, a istniejący `FileType` próbuje od razu:

   ```lua
   vim.treesitter.start(buf)
   ```

   ([GitHub][19])

   Jeśli parser jeszcze nie zdąży się zainstalować, start się nie powiedzie. Nie ma późniejszego retry dla już otwartego bufora.

   Efekt ogranicza się głównie do pierwszego bootstrapu: parser się zainstaluje, kolejne bufory będą poprawne, ale aktualny może wymagać ponownego otwarcia/filetype trigger.

   Upstream `nvim-treesitter` również opisuje instalację jako asynchronous. ([GitHub][20])

   **Naprawa:** po zakończeniu installation odpalić `vim.treesitter.start()` dla kwalifikujących się załadowanych buforów.

9. **LOW / P3 — bootstrap `lazy.nvim` nie jest w pełni reproducible**

   Przy braku plugin managera wykonywany jest clone:

   ```text
   --branch=stable
   ```

   następnie ścieżka zostaje natychmiast dodana do runtimepath i wykonywane jest `require("lazy")`. ([GitHub][21])

   `lazy-lock.json` ma przypięty konkretny commit `lazy.nvim`, ale lockfile zaczyna mieć znaczenie dopiero **po uruchomieniu samego lazy.nvim**. ([GitHub][22])

   Na zupełnie świeżej maszynie pierwszy wykonywany kod lazy jest więc tym, na co aktualnie wskazuje mutable branch `stable`, a nie koniecznie SHA z lockfile.

   **Naprawa:** przed dodaniem do RTP:

   ```text
   git clone …
   git checkout <commit-z-lazy-lock.json>
   ```

   dopiero potem `require("lazy")`.

10. **LOW / P3 — runtime directory nie gwarantuje `tmpfs`, mimo że health tak komunikuje**

Runtime validation rzeczywiście sprawdza ważne rzeczy:

```text
XDG_RUNTIME_DIR istnieje
jest directory
właścicielem jest bieżący UID
permissions = 0700
```

i analogicznie zabezpiecza własny subdirectory. ([GitHub][23])

Nie ma jednak sprawdzenia filesystem/mount type.

Czyli kod gwarantuje:

```text
private runtime directory + 0700
```

ale **nie gwarantuje**:

```text
tmpfs
```

Health output nie powinien więc przedstawiać `tmpfs` jako zweryfikowanej właściwości, chyba że dodasz kontrolę typu filesystemu. 

## Co oceniam dobrze

Ścieżka Terraform jest generalnie zaprojektowana znacznie lepiej niż typowa wrapperowa integracja z `terraform`: subprocessy dostają argumenty jako argv zamiast budowania shell-stringów, plan jest przechowywany w prywatnym runtime directory, wykonywany plik Terraform jest przypinany, a plan jest ponownie weryfikowany przed `apply`. Mechanizm hash/review/apply faktycznie broni przed użyciem innego/starego artefaktu — problem #1 dotyczy lifecycle concurrency, a nie integralności zwycięskiego planu. ([GitHub][2])

Podobnie Vault ma dużo prawidłowych zabezpieczeń na poziomie filesystemu: wyłączenie swap/undo, prywatne password staging, atomic write, kontrolę zmian pliku i ochronę przed niektórymi niebezpiecznymi wariantami inode/linków. Nie znalazłem klasycznego błędu typu „password przekazany jako jawny argument CLI”. ([GitHub][4])

Test suite również nie jest atrapą. Testuje realne przypadki związane z plan lifecycle, credential drift, runtime dir, inode/hardlink i Vault filesystem semantics. Problem polega bardziej na kilku **brakujących klasach testów** niż na niskiej jakości obecnych testów.

### Kolejność, w której poprawiałbym repo

Najpierw **#2 i #3**. Oba łamią izolację plaintext Vault i mogą doprowadzić do trwałego zapisania sekretu poza zaszyfrowanym plikiem.

Następnie **#1** — to rzeczywisty concurrency bug w Terraform lifecycle.

Potem razem **#4 i #5** ze względu na security semantics, następnie **#6 i #7** jako błędy funkcjonalne/runtime.

`#8–#10` nie blokowałyby mi wydania.

Po poprawkach szczególnie dodałbym testy dla `:range write`, append, alternate write/saveas, ShaDa/register handling, Vault+LSP/lint, scenariusza **slow plan A / fast plan B / apply before A exits** oraz cold-start `templates/_helpers.tpl`.

**Najważniejszy wniosek:** warstwa Terraform jest obecnie mocna, poza jednym konkretnym race condition. Największa luka projektu leży w modelu bezpieczeństwa edycji Vault: implementacja bardzo dobrze chroni *docelowy plik*, ale jeszcze nie izoluje wszystkich sposobów, którymi odszyfrowany tekst może opuścić buffer Neovima.

[1]: https://github.com/ultherego/dev-nvim/commit/effbcd8726f78a9d6270300f4a6425d53a749d4d "style(tests): cut test comments to one line · ultherego/dev-nvim@effbcd8 · GitHub"
[2]: https://raw.githubusercontent.com/ultherego/dev-nvim/effbcd8726f78a9d6270300f4a6425d53a749d4d/lua/terraform/init.lua "https://raw.githubusercontent.com/ultherego/dev-nvim/effbcd8726f78a9d6270300f4a6425d53a749d4d/lua/terraform/init.lua"
[3]: https://raw.githubusercontent.com/ultherego/dev-nvim/effbcd8726f78a9d6270300f4a6425d53a749d4d/tests/test_terraform_lifecycle.lua "https://raw.githubusercontent.com/ultherego/dev-nvim/effbcd8726f78a9d6270300f4a6425d53a749d4d/tests/test_terraform_lifecycle.lua"
[4]: https://raw.githubusercontent.com/ultherego/dev-nvim/effbcd8726f78a9d6270300f4a6425d53a749d4d/lua/ansible-vault/init.lua "https://raw.githubusercontent.com/ultherego/dev-nvim/effbcd8726f78a9d6270300f4a6425d53a749d4d/lua/ansible-vault/init.lua"
[5]: https://neovim.io/doc/user/autocmd/ "https://neovim.io/doc/user/autocmd/"
[6]: https://neovim.io/doc/user/editing/ "https://neovim.io/doc/user/editing/"
[7]: https://neovim.io/doc/user/options/ "https://neovim.io/doc/user/options/"
[8]: https://neovim.io/doc/user/change/ "https://neovim.io/doc/user/change/"
[9]: https://raw.githubusercontent.com/ultherego/dev-nvim/effbcd8726f78a9d6270300f4a6425d53a749d4d/lua/config/options.lua "https://raw.githubusercontent.com/ultherego/dev-nvim/effbcd8726f78a9d6270300f4a6425d53a749d4d/lua/config/options.lua"
[10]: https://neovim.io/doc/user/provider.html "https://neovim.io/doc/user/provider.html"
[11]: https://neovim.io/doc/user/starting/ "https://neovim.io/doc/user/starting/"
[12]: https://raw.githubusercontent.com/ultherego/dev-nvim/effbcd8726f78a9d6270300f4a6425d53a749d4d/lua/plugins/lsp.lua "https://raw.githubusercontent.com/ultherego/dev-nvim/effbcd8726f78a9d6270300f4a6425d53a749d4d/lua/plugins/lsp.lua"
[13]: https://raw.githubusercontent.com/neovim/neovim/v0.12.4/runtime/lua/vim/lsp/client.lua "https://raw.githubusercontent.com/neovim/neovim/v0.12.4/runtime/lua/vim/lsp/client.lua"
[14]: https://raw.githubusercontent.com/ultherego/dev-nvim/effbcd8726f78a9d6270300f4a6425d53a749d4d/lua/plugins/lint.lua "https://raw.githubusercontent.com/ultherego/dev-nvim/effbcd8726f78a9d6270300f4a6425d53a749d4d/lua/plugins/lint.lua"
[15]: https://raw.githubusercontent.com/neovim/neovim/v0.12.4/runtime/lua/vim/filetype.lua "https://raw.githubusercontent.com/neovim/neovim/v0.12.4/runtime/lua/vim/filetype.lua"
[16]: https://raw.githubusercontent.com/towolf/vim-helm/2c8525fd98e57472769d137317bca83e477858ce/ftdetect/helm.vim "https://raw.githubusercontent.com/towolf/vim-helm/2c8525fd98e57472769d137317bca83e477858ce/ftdetect/helm.vim"
[17]: https://raw.githubusercontent.com/ultherego/dev-nvim/effbcd8726f78a9d6270300f4a6425d53a749d4d/lua/aws/init.lua "https://raw.githubusercontent.com/ultherego/dev-nvim/effbcd8726f78a9d6270300f4a6425d53a749d4d/lua/aws/init.lua"
[18]: https://neovim.io/doc/user/lua "https://neovim.io/doc/user/lua"
[19]: https://raw.githubusercontent.com/ultherego/dev-nvim/effbcd8726f78a9d6270300f4a6425d53a749d4d/lua/plugins/treesitter.lua "https://raw.githubusercontent.com/ultherego/dev-nvim/effbcd8726f78a9d6270300f4a6425d53a749d4d/lua/plugins/treesitter.lua"
[20]: https://github.com/nvim-treesitter/nvim-treesitter "https://github.com/nvim-treesitter/nvim-treesitter"
[21]: https://raw.githubusercontent.com/ultherego/dev-nvim/effbcd8726f78a9d6270300f4a6425d53a749d4d/lua/config/lazy.lua "https://raw.githubusercontent.com/ultherego/dev-nvim/effbcd8726f78a9d6270300f4a6425d53a749d4d/lua/config/lazy.lua"
[22]: https://raw.githubusercontent.com/ultherego/dev-nvim/effbcd8726f78a9d6270300f4a6425d53a749d4d/lazy-lock.json "https://raw.githubusercontent.com/ultherego/dev-nvim/effbcd8726f78a9d6270300f4a6425d53a749d4d/lazy-lock.json"
[23]: https://raw.githubusercontent.com/ultherego/dev-nvim/effbcd8726f78a9d6270300f4a6425d53a749d4d/lua/terraform/runtime.lua "https://raw.githubusercontent.com/ultherego/dev-nvim/effbcd8726f78a9d6270300f4a6425d53a749d4d/lua/terraform/runtime.lua"



Tak. Nie robiłbym jednego dużego patcha. Rozdzieliłbym to na **8 logicznych commitów**, żeby każdy problem dało się osobno przetestować i ewentualnie cofnąć. Poniższe rozwiązania odnoszą się do audytowanego SHA `effbcd8726f78a9d6270300f4a6425d53a749d4d`.

## 1. Terraform — naprawa race condition równoległych `plan`

Obecnie `planning[dir]` przechowuje tylko generację ostatniego planu. Nowszy plan może więc wyczyścić stan, mimo że starszy subprocess jeszcze działa. 

Zostawiłbym `generation` do określania, **który plan jest aktualny**, ale `planning` zmienił na set aktywnych procesów:

```lua
---@type table<string, table<integer, boolean>>
local planning = {}

local function begin_planning(dir)
  generation[dir] = (generation[dir] or 0) + 1
  local mine = generation[dir]

  planning[dir] = planning[dir] or {}
  planning[dir][mine] = true

  return mine
end

local function finish_planning(dir, mine)
  local active = planning[dir]
  if not active then
    return
  end

  active[mine] = nil

  if next(active) == nil then
    planning[dir] = nil
  end
end
```

I zamiast:

```lua
generation[dir] = (generation[dir] or 0) + 1
local mine = generation[dir]
planning[dir] = mine
```

dać:

```lua
local mine = begin_planning(dir)
```

Warunki:

```lua
if planning[dir] then
```

w `apply()` i `init()` zostają bez zmian.

Efekt:

```text
Plan A ───────────────────────────────┐
Plan B ───────────────┐               │
                      └─ finished     │
planning = { A }                       │
                                      │
apply BLOCKED                         │
                                      └─ finished

planning = nil
apply ALLOWED
```

### Test konieczny

Dodać przypadek:

```text
start plan A
start plan B
finish B
attempt apply -> refused
attempt init  -> refused
finish A
attempt apply -> allowed
```

To jest **P1 i zrobiłbym jako pierwszy commit**.

---

# 2. Vault — przejąć wszystkie write paths

Aktualnie `attach_writer()` przejmuje wyłącznie `BufWriteCmd`. 

Neovim ma osobne `FileWriteCmd` i `FileAppendCmd`, a tylko jeden zestaw write events jest używany dla pojedynczego zapisu. ([Neovim][1])

Dodałbym fail-closed.

### Helper

```lua
local function refuse_unsafe_write(ev, operation)
  vim.notify(
    ("Refusing %s from a protected Ansible Vault buffer"):format(operation),
    vim.log.levels.ERROR
  )
end
```

### `attach_writer()`

Przed tworzeniem autocmdów czyścić wszystkie trzy:

```lua
for _, event in ipairs({
  "BufWriteCmd",
  "FileWriteCmd",
  "FileAppendCmd",
}) do
  pcall(vim.api.nvim_clear_autocmds, {
    group = writer_group,
    event = event,
    buffer = buf,
  })
end
```

Następnie:

```lua
vim.api.nvim_create_autocmd("FileWriteCmd", {
  group = writer_group,
  buffer = buf,
  callback = function(ev)
    refuse_unsafe_write(ev, "partial write")
  end,
})

vim.api.nvim_create_autocmd("FileAppendCmd", {
  group = writer_group,
  buffer = buf,
  callback = function(ev)
    refuse_unsafe_write(ev, "append")
  end,
})
```

Wtedy:

```vim
:1,10write /tmp/foo
```

i:

```vim
:1,10write >> /tmp/foo
```

nie zapiszą plaintextu.

## Dodatkowo: nie pozwalać zwykłemu writerowi zmieniać destination

Dodałbym do bufora chronioną ścieżkę:

```lua
local function remember_file_state(buf)
  local path = vim.api.nvim_buf_get_name(buf)

  vim.b[buf].ansible_vault_path = vim.fs.normalize(
    vim.fn.fnamemodify(path, ":p")
  )

  vim.b[buf].ansible_vault_stat = file_fingerprint(path)
end
```

I przed zapisem w `BufWriteCmd`:

```lua
local current = vim.fs.normalize(
  vim.fn.fnamemodify(vim.api.nvim_buf_get_name(ev.buf), ":p")
)

local protected = vim.b[ev.buf].ansible_vault_path

if protected and current ~= protected then
  vim.notify(
    "Refusing to write decrypted Vault buffer under another path",
    vim.log.levels.ERROR
  )
  return
end
```

Czyli zwykłe:

```vim
:w
```

działa.

Natomiast alternatywne ścieżki nie omijają zabezpieczeń.

Jeśli chcesz obsługiwać save-as, zrobiłbym później **osobną komendę `:VaultSaveAs`**, która zawsze szyfruje przed utworzeniem targetu.

---

# 3. Vault — ShaDa + `unnamedplus`

Tu polecałbym rozwiązanie bardziej rygorystyczne, zamiast próbować „sprzątać” po sekretach.

Neovim zapisuje przez ShaDa m.in. registers, histories i inne dane sesji; `shadafile=NONE` oznacza, że ShaDa nie jest czytane ani zapisywane. ([Neovim][2])

Po **pierwszym odszyfrowaniu Vault** przełączyłbym cały Neovim w secure-session:

```lua
local secure_session = false

local function enter_secure_session()
  if secure_session then
    return
  end

  secure_session = true

  -- Never persist registers/history from this process anymore.
  vim.o.shadafile = "NONE"

  -- Do not implicitly mirror unnamed register to system clipboard.
  vim.o.clipboard = ""
end
```

Nie przywracałbym tych opcji po zamknięciu Vault.

To jest celowe.

Problem z przywróceniem polega na tym, że np.:

```vim
yy
```

może pozostawić plaintext w registerze również **po zamknięciu Vault**. Przy ponownym włączeniu ShaDa sekret mógłby później zostać zapisany.

Dlatego:

```text
Vault odszyfrowany raz
       ↓
secure-session aktywny do wyjścia z Neovima
```

### Gdzie wywołać

Przed pojawieniem się plaintext:

```lua
enter_secure_session()
mark_plain_vault_buffer(buf)
vim.api.nvim_buf_set_lines(...)
```

Analogicznie w transparent `BufReadPost`.

Masz już wyłączone `swapfile`, `undofile` i `modeline`, więc ta zmiana zamyka główną lukę persistence poza tym mechanizmem. 

---

# 4. Vault — blokada LSP, lint i formatterów

Obecnie po odszyfrowaniu wykonujesz:

```lua
vim.cmd("filetype detect")
```

na plaintext. 

Jednocześnie konfiguracja automatycznie aktywuje m.in. `yamlls`, a lint layer uruchamia `yamllint` również na `InsertLeave`. 

Tu zastosowałbym **defense in depth**.

### A. Detach LSP zanim plaintext trafi do bufora

```lua
local function detach_lsp(buf)
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
    pcall(vim.lsp.buf_detach_client, buf, client.id)
  end
end
```

Przed:

```lua
vim.api.nvim_buf_set_lines(...)
```

wykonać:

```lua
detach_lsp(buf)
```

### B. Nie wykonywać `filetype detect` po decrypt

Usunąć:

```lua
vim.cmd("filetype detect")
```

z transparentnego decrypt.

To mogłoby ponownie wywołać `FileType` i ponownie uruchomić automatyczne LSP.

### C. `nvim-lint`

Na początku `try_lint()`:

```lua
local function try_lint(buf, only_fast)
  if vim.b[buf].ansible_vault_plain then
    return
  end

  local names = linters_for(buf, only_fast)

  if #names > 0 then
    lint.try_lint(names)
  end
end
```

### D. Conform

W `format_on_save`:

```lua
if vim.b[bufnr].ansible_vault_plain then
  return
end
```

A manual formatting:

```lua
function()
  local buf = vim.api.nvim_get_current_buf()

  if vim.b[buf].ansible_vault_plain then
    vim.notify(
      "Formatting decrypted Vault buffers is disabled",
      vim.log.levels.WARN
    )
    return
  end

  require("conform").format({
    async = true,
    lsp_format = "fallback",
  })
end
```

Obecny Conform używa `lsp_format = "fallback"`, więc taka kontrola ma znaczenie również dla ręcznego formatowania. 

### Docelowo

Warto zrobić wspólny helper:

```text
lua/config/sensitive.lua
```

np.:

```lua
function M.is_sensitive(buf)
  return vim.b[buf].ansible_vault_plain == true
end
```

żeby LSP/lint/format nie implementowały własnych różnych definicji „sensitive buffer”.

---

# 5. `strict_aws_identity` naprawdę fail-closed

Obecnie przy nieudanym STS dostajesz `identity_err`, ale plan jest mimo tego wykonywany. 

Przy:

```lua
strict_aws_identity = true
```

powinien obowiązywać:

```text
nie znam identity
=
nie wykonuję operacji
```

### Brak AWS CLI

Zmienić:

```lua
if vim.fn.executable("aws") ~= 1 then
  callback(nil)
  return
end
```

na:

```lua
if vim.fn.executable("aws") ~= 1 then
  callback(nil, "`aws` not found on PATH")
  return
end
```

### Walidacja response

Z:

```lua
if not ok or type(decoded) ~= "table" or not decoded.Account then
```

na:

```lua
if
  not ok
  or type(decoded) ~= "table"
  or not decoded.Account
  or not decoded.Arn
then
```

### `plan()`

Zamiast warning:

```lua
if identity_err then
  finish_planning(dir, mine)
  pcall(vim.uv.fs_unlink, path)

  vim.notify(
    ("Refusing to plan: strict AWS identity verification failed:\n%s")
      :format(identity_err),
    vim.log.levels.ERROR
  )

  return
end
```

### `apply()`

```lua
if identity_err or not identity then
  release()

  vim.notify(
    ("Refusing to apply: strict AWS identity verification failed:\n%s")
      :format(identity_err or "identity unavailable"),
    vim.log.levels.ERROR
  )

  return
end
```

**Tutaj nie usuwałbym reviewed planu.**

Jeżeli chwilowo padnie STS/DNS, użytkownik może ponowić `TerraformApply` później. Nie ma potrzeby jeszcze raz wykonywać całego `plan`.

---

# 6. Helm `*.tpl`

Obecny plugin:

```lua
{
  "towolf/vim-helm",
  ft = { "helm", "yaml" },
}
```

ma problem bootstrapowy właśnie dlatego, że sam plugin odpowiada za późniejsze rozpoznanie części Helm templates. 

Najprostsze i najbardziej odporne rozwiązanie:

```lua
{
  "towolf/vim-helm",
  lazy = false,
}
```

I tyle.

Nie kombinowałbym tutaj z własną implementacją Helm detection dla oszczędności kilku milisekund.

Plugin musi zarejestrować swoje `ftdetect` **zanim pierwszy `.tpl` zostanie otwarty**.

---

# 7. AWS — usunąć wszystkie synchroniczne `:wait()`

Obecny `capture()` wykonuje:

```lua
vim.system(...):wait()
```

a korzystają z tego `AwsProfile`, `AwsRegion` i `AwsWhoami`. 

Przerobiłbym cały helper na callback.

```lua
---@param cmd string[]
---@param callback fun(lines: string[]|nil, err: string|nil)
local function capture(cmd, callback)
  if vim.fn.executable("aws") ~= 1 then
    callback(nil, "`aws` not found on PATH")
    return
  end

  local ok, err = pcall(vim.system, cmd, {
    text = true,
    timeout = 10000,
  }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(
          nil,
          ((result.stderr or "") .. (result.stdout or "")):gsub("%s+$", "")
        )
        return
      end

      callback(
        vim.split(
          (result.stdout or ""):gsub("%s+$", ""),
          "\n",
          { trimempty = true }
        ),
        nil
      )
    end)
  end)

  if not ok then
    callback(nil, tostring(err))
  end
end
```

Ważny jest również `pcall(vim.system, ...)`, żeby invalid cwd/spawn failure nie wywalił callback lifecycle.

Przykładowo `whoami()`:

```lua
function M.whoami()
  capture(
    { "aws", "sts", "get-caller-identity", "--output", "text" },
    function(out, err)
      if not out then
        vim.notify(
          ("Not authenticated: %s"):format(err),
          vim.log.levels.ERROR
        )
        return
      end

      vim.notify(
        ("Caller identity: %s"):format(table.concat(out, " ")),
        vim.log.levels.INFO
      )
    end
  )
end
```

`pick_region()` i `pick_profile()` analogicznie.

---

# 8. Treesitter bootstrap

Obecnie:

```lua
require("nvim-treesitter").install(missing)
```

jest asynchronous, a chwilę później `FileType` próbuje:

```lua
vim.treesitter.start()
```



Upstream dla bootstrapowania explicite przewiduje:

```lua
install(...):wait(...)
```

([GitHub][3])

Tutaj właśnie użyłbym synchronicznego wait, bo wystąpi tylko, gdy brakuje parserów:

```lua
if #missing > 0 then
  local ok, err = pcall(function()
    require("nvim-treesitter")
      .install(missing)
      :wait(300000)
  end)

  if not ok then
    vim.notify(
      ("Treesitter parser installation failed: %s"):format(err),
      vim.log.levels.ERROR
    )
  end
end
```

Normalny startup z już zainstalowanymi parserami nie czeka.

To jest znacznie prostsze i pewniejsze niż własne callback/retry.

---

# 9. `lazy.nvim` — bootstrap dokładnie z `lazy-lock.json`

Aktualnie bootstrap robi clone ruchomego `stable`, mimo że lockfile posiada konkretny SHA:

```text
306a05526ada86a7b30af95c5cc81ffba93fef97
```



Nie hardcodowałbym SHA drugi raz.

Odczytałbym go bezpośrednio z `lazy-lock.json` **przed uruchomieniem lazy.nvim**:

```lua
local function locked_lazy_commit()
  local path = vim.fn.stdpath("config") .. "/lazy-lock.json"

  local ok_read, lines = pcall(vim.fn.readfile, path)
  if not ok_read then
    return nil, "could not read lazy-lock.json"
  end

  local ok_json, lock = pcall(
    vim.json.decode,
    table.concat(lines, "\n")
  )

  if not ok_json or type(lock) ~= "table" then
    return nil, "invalid lazy-lock.json"
  end

  local entry = lock["lazy.nvim"]

  if type(entry) ~= "table" or type(entry.commit) ~= "string" then
    return nil, "lazy.nvim is not pinned in lazy-lock.json"
  end

  return entry.commit
end
```

Potem:

```lua
if not vim.uv.fs_stat(lazypath) then
  local commit, err = locked_lazy_commit()

  if not commit then
    error(err)
  end

  local clone = vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    lazyrepo,
    lazypath,
  })

  if vim.v.shell_error ~= 0 then
    error(("Failed to clone lazy.nvim:\n%s"):format(clone))
  end

  local checkout = vim.fn.system({
    "git",
    "-C",
    lazypath,
    "checkout",
    "--detach",
    commit,
  })

  if vim.v.shell_error ~= 0 then
    error(
      ("Failed to checkout lazy.nvim %s:\n%s")
        :format(commit, checkout)
    )
  end
end
```

Dopiero potem:

```lua
vim.opt.rtp:prepend(lazypath)
require("lazy").setup(...)
```

Czyli nawet **pierwszy wykonywany kod lazy.nvim pochodzi z lockfile**.

---

# 10. `tmpfs` w healthcheck

Tu **nie dodawałbym sprawdzania tmpfs**.

Zmieniłbym komunikat.

`terraform.runtime` rzeczywiście sprawdza bezpieczeństwo katalogu i permissions, ale nie typ mountu. 

Jeżeli health obecnie mówi:

```text
XDG_RUNTIME_DIR: OK (tmpfs, 0700)
```

zmienić np. na:

```text
XDG_RUNTIME_DIR: OK (owner=current user, mode=0700)
```

albo:

```text
XDG_RUNTIME_DIR: private and usable (0700)
```

To jest lepsze niż dodanie Linux-specific `findmnt`, szczególnie że bezpieczeństwo tego modułu wynika przede wszystkim z właściwego `XDG_RUNTIME_DIR`, ownera i `0700`, a nie z literalnej nazwy filesystemu.

---

# Jak bym to podzielił na commity

1. **`fix(terraform): track all in-flight plan generations`**
2. **`fix(vault): close alternate write paths`**
3. **`security(vault): disable persistent session and implicit clipboard`**
4. **`security(vault): isolate plaintext from LSP lint and formatting`**
5. **`fix(terraform): make strict AWS identity fail closed`**
6. **`fix(helm): load filetype detection before tpl buffers`**
7. **`fix(aws): make AWS CLI operations asynchronous`**
8. **`fix(runtime): make bootstrap and health claims deterministic`** — Treesitter + lazy bootstrap + health wording.

Najważniejsze są **1–5**. Szczególnie w Vault nie próbowałbym „łatać” pojedynczych komend — zrobiłbym zasadę: **plaintext Vault jest specjalnym sensitive-bufferem i każda ścieżka wychodząca poza pamięć Neovima jest domyślnie blokowana**. To jest dużo łatwiejsze do utrzymania przy kolejnych funkcjach.

[1]: https://neovim.io/doc/user/autocmd/?utm_source=chatgpt.com "Autocmd - Neovim docs"
[2]: https://neovim.io/doc/user/starting/?utm_source=chatgpt.com "Starting - Neovim docs"
[3]: https://github.com/nvim-treesitter/nvim-treesitter/blob/main/README.md?utm_source=chatgpt.com "nvim-treesitter/README.md at main · nvim-treesitter/nvim-treesitter · GitHub"

