Sprawdziłem ponownie aktualny `main`, tym razem przypinając analizę do:

**`3faeb3587da97db5a1795320f60400cfc9fcb006` — `chore: update pinned plugin versions`**. Ten commit zmienia wyłącznie `lazy-lock.json`; kod pochodzi więc z `b2df599`, ale audyt uwzględnia **nowe przypięte wersje pluginów**. ([GitHub][1])

Nie wracam do wcześniej odrzuconych tematów: ShaDa/clipboard, range-write na 0.12, `filetype detect` na złym buforze ani Mason `_value`. Nie znalazłem też regresji poprzednich P1: race równoległych Terraform planów jest faktycznie zamknięty setem aktywnych generacji, a Vault wiąże writer z oryginalnym targetem. 

Po nowym przejściu zostaje **8 findings: 2×P1, 4×P2, 2×P3**.

---

## P1-1 — Gitsigns może zapisać plaintext Vault do Git index

To jest najważniejsze nowe znalezisko.

`gitsigns.nvim` ładuje się na:

```lua
event = { "BufReadPre", "BufNewFile" }
```

i po attach zakłada m.in.:

```lua
<leader>gs -> gs.stage_hunk
<leader>gS -> gs.stage_buffer
```

Nie ma żadnego sprawdzenia:

```lua
vim.b[buf].ansible_vault_plain
```

ani detach Gitsigns podczas odszyfrowania. 

Vault natomiast później zamienia ciphertext w tym samym normalnym file-bufferze na plaintext. 

Przypięty Gitsigns przy stagingu hunków generuje patch i wykonuje:

```text
git apply --cached --unidiff-zero -
```

z patchem przekazanym przez stdin. Pełny staging również może utworzyć Git object z dostarczonych linii i zaktualizować index. 

Czyli realny scenariusz:

```text
Git index:
$ANSIBLE_VAULT;1.1;AES256
...

        ↓ otwarcie Vault

Neovim buffer:
password: SUPERSECRET

        ↓ <leader>gs / <leader>gS

Git index:
password: SUPERSECRET
```

To omija cały bezpieczny Vault writer, bo **nie zapisuje working-tree file — zapisuje `.git/index`**.

### Werdykt

**P1 — realny persistent plaintext leak.**

### Naprawa

Przed pojawieniem się plaintextu trzeba odpiąć Gitsigns od bufora.

Dodatkowo `on_attach` powinien fail-closed:

```lua
on_attach = function(buf)
  if vim.b[buf].ansible_vault_plain then
    require("gitsigns").detach(buf)
    return
  end

  ...
end
```

Ale sam ten guard nie wystarczy, bo Gitsigns może być już podpięty przed decryptem.

Potrzebny jest również detach podczas przejścia:

```text
ciphertext -> sensitive plaintext
```

Najlepiej przestać robić zabezpieczenia per-plugin i wprowadzić wspólne:

```lua
sensitive.mark(buf)
sensitive.is_sensitive(buf)
```

oraz event typu:

```text
User DevopsSensitiveBuffer
```

którego Gitsigns/LSP/Completion mogą słuchać.

### Test regresyjny

Temporary Git repo:

1. commit encrypted Vault,
2. otworzyć transparentnie,
3. plaintext zawiera unikalny `VAULT_GITSIGNS_SENTINEL`,
4. próbować staging,
5. sprawdzić:

```fish
git show :path/to/vault.yml
```

W indexie musi nadal występować:

```text
$ANSIBLE_VAULT
```

i **nie może** występować sentinel.

Mutation: usunięcie detach musi spowodować fail testu.

---

# P1-2 — obecna ochrona LSP sama wysyła plaintext podczas detach

Ten problem jest mocniejszy, niż początkowo wyglądał.

Obecna implementacja robi dla manualnego decrypt:

```lua
vim.api.nvim_buf_set_lines(...)       -- plaintext
vim.b[buf].ansible_vault_plain = true
keep_language_servers_off(buf)
```

Czyli plaintext pojawia się **przed** odpięciem LSP. 

A `keep_language_servers_off()` robi:

```lua
vim.lsp.buf_detach_client(...)
```

dla istniejących klientów. 

Problem tkwi w implementacji Neovima 0.12.4.

Przy zmianie bufora LSP gromadzi pending `didChange`. Podczas detach:

```text
buf_detach_client()
    ↓
Client:_on_detach()
    ↓
changetracking.reset_buf()
    ↓
changetracking.flush()
```

`reset_buf()` **najpierw wykonuje `flush()`**, a dopiero potem usuwa tracking. 

A `flush()` dla Full sync buduje:

```lua
{ text = vim.lsp._buf_get_full_text(bufnr) }
```

i wysyła `textDocument/didChange`, jeżeli klient nadal jest attached. 

Czyli:

```text
ciphertext
   ↓
LSP attached
   ↓
Vault zamienia buffer na plaintext
   ↓
buf_detach_client()
   ↓
Neovim FLUSHES pending didChange
   ↓
plaintext -> language server
   ↓
detach
```

To jest bardzo konkretna luka.

## Jest jeszcze drugi wariant

Transparent mode robi:

```lua
set_lines(plaintext)
ansible_vault_plain = true
filetype detect
keep_language_servers_off()
```



Jeżeli nowy LSP zostanie uruchomiony, obecny `LspAttach` guard też jest za późny.

Neovim `Client:on_attach()` wykonuje kolejno:

```lua
self:_text_document_did_open_handler(bufnr)
...
nvim_exec_autocmds("LspAttach", ...)
```

a `didOpen` zawiera:

```lua
text = lsp._buf_get_full_text(bufnr)
```



Czyli:

```text
LSP attaches
    ↓
didOpen(PLAINTEXT)
    ↓
LspAttach
    ↓
Twój autocmd robi detach
```

Plaintext już został przekazany.

### Werdykt

**P1.**

I to jest źródłowo potwierdzone na dokładnym Neovim **0.12.4**, którego używa projekt.

### Naprawa

Minimalna zasada musi brzmieć:

> **Żaden LSP nie może być attached w chwili, gdy plaintext zostaje umieszczony w buforze.**

Kolejność musi być przynajmniej:

```text
1. oznacz buffer jako sensitive
2. odłącz istniejące LSP — jeszcze przy ciphertext
3. zablokuj przyszłe auto-attach
4. dopiero teraz set_lines(plaintext)
```

Sam `LspAttach` **nie może być mechanizmem bezpieczeństwa**, bo semantycznie jest za późny.

Native LSP 0.12 daje właściwy punkt kontroli: `root_dir(bufnr, on_dir)` może dynamicznie nie wywołać `on_dir()`, a wtedy LSP nie jest aktywowany dla danego bufora. Neovim dokumentuje to dokładnie jako możliwość per-buffer odmowy aktywacji. 

Ten fragment warto naprawić architektonicznie, a nie kolejnym detach po fakcie.

---

# P2-1 — ręczny Conform nadal wysyła Vault do subprocessu

Autoformat jest poprawiony:

```lua
if vim.b[bufnr].ansible_vault_plain then
  return
end
```



Ale ręczny:

```lua
<leader>xf
```

robi bezwarunkowo:

```lua
require("conform").format({
  async = true,
  lsp_format = "fallback",
})
```



A masz external formatters m.in.:

```text
stylua
terraform_fmt
tofu_fmt
shfmt
jq
```



Więc odszyfrowany Vault o odpowiednim filetype może zostać przekazany na stdin zewnętrznego formattera.

### Werdykt

**P2.**

Nie ma automatycznej persistence, ale łamie dokładnie tę samą izolację, którą już wdrożyłeś dla `nvim-lint`.

### Naprawa

Nie duplikować logiki. Jeden helper:

```lua
local function format(buf, opts)
  if vim.b[buf].ansible_vault_plain then
    vim.notify(
      "Formatting decrypted Vault buffers is disabled",
      vim.log.levels.WARN
    )
    return
  end

  require("conform").format(opts)
end
```

I przez niego puścić zarówno auto, jak i manual formatting.

---

# P2-2 — blink.cmp może kopiować słowa z Vault do zwykłego bufora

To wyszło dzięki aktualnemu pinowi `blink.cmp` v1.10.2.

Twoja konfiguracja ma:

```lua
sources = {
  default = { "lsp", "path", "snippets", "buffer" },
}
```



Przypięty Blink domyślnie dla `buffer` source pobiera **bufory ze wszystkich widocznych okien**:

```lua
vim.api.nvim_list_wins()
  -> nvim_win_get_buf()
```

i odrzuca wyłącznie:

```lua
buftype == "nofile"
```



Transparentny Vault jest normalnym file-bufferem. Nie ma `buftype=nofile`. 

Scenariusz:

```text
split 1:
vault.yml
api_token: ULTHER_SUPER_SECRET_TOKEN

split 2:
deployment.yaml
api_token: ULTHER_
```

Blink może zaproponować:

```text
ULTHER_SUPER_SECRET_TOKEN
```

pochodzący z odszyfrowanego Vault.

Po zaakceptowaniu completion sekret znajduje się w zwykłym buforze i może zostać normalnie zapisany.

### Werdykt

**P2.**

To nie jest ShaDa/clipboard i nie wracam tu do zaakceptowanej granicy. Jest to cross-buffer propagation wykonana przez plugin.

### Naprawa

Skonfigurować `buffer.opts.get_bufnrs` tak, aby odrzucał:

```lua
vim.b[buf].ansible_vault_plain
```

Najlepiej na podstawie wspólnego:

```lua
sensitive.is_sensitive(buf)
```

Test powinien mieć **dwa widoczne splity** i unikalny sentinel.

---

# P2-3 — `ansible-vault` i `ansible-config` nadal mają nieograniczone `wait()`

AWS został świadomie zrobiony jako bounded synchronous. Tego nie kwestionuję.

Vault nie ma jeszcze analogicznego zabezpieczenia.

`ansible-vault/cli.lua`:

```lua
vim.system(...):wait()
```

bez timeoutu. 

`ansible-vault/config.lua`:

```lua
vim.system({ "ansible-config", "dump" }, ...):wait()
```

również bez timeoutu. 

W pierwszym przypadku jest dodatkowy problem: jeśli używasz promptowanego hasła, przed subprocess utworzony jest zabezpieczony temporary password file, a cleanup wykonuje się **dopiero po powrocie z `wait()`**. 

Jeżeli np. vault-id/password executable zawiesi się:

```text
Neovim frozen
+
staged password file nadal istnieje
```

### Werdykt

**P2 availability + secret-lifetime.**

### Naprawa

Nie async — zgodnie z przyjętą decyzją projektu.

Po prostu ta sama polityka co AWS:

```lua
local TIMEOUT_MS = 10000
...
:wait(TIMEOUT_MS)
```

i jawna obsługa timeoutu.

To powinno objąć zarówno:

```text
ansible-vault
ansible-config dump
```

oraz test cleanup temporary password przy timeout.

---

# P2-4 — Terraform STS nie ma timeoutu i może permanentnie trzymać claim

Poprzedni race równoległych planów jest naprawiony prawidłowo:

```lua
planning[dir][generation] = true
```

a `apply()` sprawdza `is_planning(dir)`. 

Ale `strict_aws_identity` robi:

```lua
vim.system(
  { "aws", "sts", "get-caller-identity", "--output", "json" },
  { text = true },
  callback
)
```

bez `timeout`. 

Przed tym lookupem `plan()` już ustawia:

```lua
planning[dir][mine] = true
```



a `apply()`:

```lua
applying[dir] = true
```

przed STS. 

Jeżeli AWS CLI zawiesi się np. na credential process/SSO/network:

```text
UI Neovima działa
ale
planning[dir] = true
lub
applying[dir] = true
```

pozostaje bez release aż subprocess kiedyś wróci.

### Werdykt

**P2 lifecycle availability.**

### Naprawa

STS powinien dostać np.:

```lua
{
  text = true,
  timeout = 10000,
}
```

Wtedy istniejąca obsługa:

```lua
result.code ~= 0
```

może doprowadzić do normalnego fail-closed i release claim.

Drobne hardening przy okazji:

obecnie parser wymaga tylko:

```lua
decoded.Account
```

ale później identity obejmuje również:

```lua
decoded.Arn
```



Przy `strict` wymagałbym obu:

```lua
not decoded.Account or not decoded.Arn
```

---

# P3-1 — `:saveas` jest bezpieczne dla dysku, ale psuje stan bufora

To jest ważne rozróżnienie:

**nie potwierdzam starego plaintext leak przez `:saveas`.** Ten został naprawiony.

Writer poprawnie odmawia targetu różnego od:

```lua
vim.b[buf].ansible_vault_path
```



Problem jest inny.

Neovim 0.12.4 dla:

```vim
:saveas! newname
```

**przed wywołaniem writer hook** zamienia nazwy current/alternate buffer:

```c
curbuf->b_fname = ...
curbuf->b_ffname = ...
...
buf_write(...)
```



Dopiero wewnątrz tego `buf_write()` dochodzi do Twojego `BufWriteCmd`, który mówi:

```text
Refusing...
```

Nazwa bufora została jednak już zmieniona.

Obecny test sprawdza:

* komunikat `Refusing`,
* brak plaintextu w target,
* oryginalny Vault nadal ciphertext,

ale **nie sprawdza `nvim_buf_get_name()` po odmowie**. 

W efekcie:

```text
vault.yml
   ↓
:saveas! foo.yml
   ↓
write refused
   ↓
buffer nazywa się foo.yml
ale ansible_vault_path nadal wskazuje vault.yml
   ↓
:w
   ↓
ponowna odmowa
```

Dodatkowo komunikat konfliktu w `persist()` mówi obecnie:

```text
Use :saveas to keep them elsewhere.
```

podczas gdy writer świadomie `:saveas` zabrania. 

### Werdykt

**P3 — state corruption / błędna ścieżka recovery**, nie security leak.

### Naprawa

Blokować zmianę nazwy **przed** name swap, czyli na `BufFilePre`, gdy buffer jest decrypted Vault.

Neovim wywołuje `BufFilePre` przed zamianą nazw i sprawdza `aborting()` zanim jej dokona. 

Test powinien sprawdzać:

```lua
local before = vim.api.nvim_buf_get_name(0)

pcall(vim.cmd, "saveas! ...")

eq(vim.api.nvim_buf_get_name(0), before)
```

a następnie:

```vim
:w
```

musi nadal poprawnie re-encryptować oryginalny Vault.

---

# P3-2 — Helm cold-start poprawiony tylko częściowo

Poprzedni `_helpers.tpl` jest już naprawiony przez:

```lua
vim.filetype.add({
  pattern = {
    [".*/templates/.*%.tpl"] = ...
  },
})
```



Ale przypięty `vim-helm` wykrywa więcej przypadków:

```text
templates/*.yaml
templates/*.yml
templates/*.tpl
templates/*.txt
*.gotmpl
helmfile*.yaml
```



Plugin nadal ładuje się tylko dla:

```lua
ft = { "helm", "yaml" }
```



`.yaml/.yml` nie są problemem, bo YAML sam załaduje plugin.

Ale cold start na:

```text
templates/NOTES.txt
```

dostanie zwykły `text`.

Analogicznie:

```text
something.gotmpl
```

nie ma gwarancji `helm` przed załadowaniem `vim-helm`.

Czyli dokładnie ten sam bootstrap-cycle, który naprawiłeś dla `.tpl`, pozostał dla dwóch pozostałych klas obsługiwanych przez upstream.

### Werdykt

**P3 funkcjonalny.**

### Naprawa

Albo rozszerzyć własne detection tak, aby odpowiadało upstreamowi, albo — najczyściej — przestać lazy-loadować mały ftdetect plugin:

```lua
{
  "towolf/vim-helm",
  lazy = false,
}
```

Wtedy jego pełna detekcja istnieje od początku i nie musisz duplikować jej logiki.

---

# Co z wcześniejszymi problemami?

Tu jest dobra wiadomość: **poprzednie kluczowe poprawki faktycznie są w kodzie.**

Terraform parallel-plan race jest zamknięty poprawnym setem generacji i `is_planning()`. 

`strict_aws_identity` jest teraz rzeczywiście fail-closed przy niedostępnym AWS CLI / błędzie STS — pozostał tylko brak timeoutu. 

Vault writer obejmuje `BufWriteCmd`, `FileWriteCmd` i `FileAppendCmd`, a alternate target jest odrzucany. Nie widzę powrotu poprzedniego P1 z zapisem plaintextu standardowym `:write`. 

Treesitter retry i Helm `.tpl` fix też rzeczywiście weszły; problem Helm, który raportuję teraz, dotyczy **innych rozszerzeń**, których własna implementacja nie objęła. `vim-helm` upstream jednoznacznie pokazuje `.txt` i `.gotmpl`. 

## Priorytet wdrażania

Ja zrobiłbym kolejność:

1. **P1 LSP**
2. **P1 Gitsigns**
3. Blink sensitive-buffer isolation
4. manual Conform guard
5. Vault subprocess timeouts
6. Terraform STS timeout + wymagane `Arn`
7. `BufFilePre` dla `:saveas`
8. pełna Helm detection

Najważniejszy wniosek z tego audytu jest taki, że **sam core Vault jest obecnie znacznie lepszy niż wcześniej**. Nowa powierzchnia ataku to plugin interoperability. Wprowadzanie kolejnych pojedynczych wyjątków (`lint`, `format`, `LSP`, `gitsigns`, `blink`) zaczyna być sygnałem, że projekt potrzebuje jednego centralnego pojęcia **sensitive buffer**. Wtedy każdy plugin, który czyta albo eksportuje treść bufora, ma jeden wspólny warunek zamiast własnej wiedzy o `ansible_vault_plain`.

**P1 z LSP jest szczególnie wart potraktowania natychmiast**, bo obecny detach nie tylko jest „za późny” — na Neovim 0.12.4 sam detach wykonuje flush oczekującego `didChange`, więc mechanizm mający zatrzymać plaintext może być mechanizmem, który go wysyła. 

[1]: https://github.com/ultherego/dev-nvim/commit/3faeb3587da97db5a1795320f60400cfc9fcb006 "chore: update pinned plugin versions · ultherego/dev-nvim@3faeb35 · GitHub"


Tak — i w tym momencie problemem nie jest już „projekt jest pełen błędów”, tylko **audyt nie ma zdefiniowanej granicy zakończenia**.

Pierwsze serie znajdowały błędy w core: integralność planu Terraform, concurrency, bezpieczny zapis Vault, filesystem semantics. To były rzeczy, które realnie blokowały produkcję. Teraz findings są coraz bardziej na styku z innymi komponentami Neovima: Gitsigns, LSP lifecycle, completion, formattery. To jest typowy etap, w którym dalszy audyt może produkować nowe edge-case'y praktycznie bez końca.

Ja ustawiłbym teraz twardy **release gate**:

1. Zamknąć tylko dwa obecne P1:

   * Vault ↔ LSP,
   * Vault ↔ Gitsigns.

2. Z P2 przed release wziąć tylko tanie i jednoznaczne:

   * guard manualnego Conform,
   * timeout STS,
   * timeout `ansible-vault` / `ansible-config`,
   * filtr Blink dla sensitive buffer.

3. `:saveas` i pełne Helm detection mogą wejść, bo są małe, ale nie powinny ponownie otwierać całego audytu.

4. Po tym:

   * pełne testy,
   * mutation test nowych regresji,
   * `:checkhealth`,
   * startup test,
   * CI na **dokładnym SHA**.

5. Jeżeli wszystko jest zielone: **release candidate i koniec security audit tej wersji.**

Nie robiłbym wtedy kolejnego „sprawdź jeszcze raz wszystko linijka po linijce”. Bo znajdziemy np. następny plugin, który potrafi przeczytać buffer, kolejny nietypowy Ex-command, kolejną interakcję Neovima. To nie oznacza, że projekt nie nadaje się do produkcji — oznacza, że osiągasz etap, na którym trzeba zdefiniować **threat model**.

Dla Vault sensowna granica produkcyjna mogłaby być:

> Odszyfrowany Vault nie może być automatycznie przekazywany do zewnętrznych procesów ani zapisywany na persistent storage przez funkcje dostarczane przez konfigurację dev-nvim. Świadome działania użytkownika poza kontrolą projektu, system clipboard oraz ShaDa pozostają poza gwarancją.

To ucina ogromną klasę nieskończonych hipotetycznych przypadków.

Po obecnej serii nie widzę powodu, żeby traktować `dev-nvim` jako projekt „daleki od produkcji”. Wręcz przeciwnie: **185 testów, mutation verification, kilka niezależnych serii audytu, fail-closed Terraform/Vault i CI na przypiętym środowisku** to już poziom znacznie powyżej typowego prywatnego configu Neovima.

Czyli moja rekomendacja jest konkretna: **jeszcze jedna zamknięta seria wyłącznie dla tych 8 punktów, bez rozszerzania scope. Zielone CI → release.** Potem nowe rzeczy traktujemy normalnie jako bugfixy następnych wersji, a nie jako powód do zatrzymywania `v1.x`.

