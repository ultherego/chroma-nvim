# Pełny ponowny audyt `dev-nvim`

Przeanalizowałem aktualny `main` od nowa, na dokładnym SHA:

```text
effbcd8726f78a9d6270300f4a6425d53a749d4d
```

Najnowszy commit to `style(tests): cut test comments to one line` z 7 sierpnia 2026 r. Przeglądałem rzeczywiste ścieżki wykonania, a nie deklaracje w komentarzach. Dokumentację porównywałem z kodem dopiero później. ([GitHub][1])

To nadal audyt statyczny: przeanalizowałem aktualny kod i testy, ale **nie uruchamiałem niezależnie Twojego suite ani CI na własnym checkoutcie**.

## Werdykt

Poprzednia seria poprawek jest dobrze widoczna w kodzie i nie znalazłem regresji w większości naprawionych invariantów. Hard-link rekey, superseded plans, serializacja `init`, plaintext→Vault conversion, `cwd`, argument ownership, chmod/hash, `block_at`, tofu fallback i globalny formatting toggle są wdrożone zgodnie z wcześniejszym planem. ([GitHub][1])

Nie powiedziałbym jednak jeszcze, że moduły Vault/Terraform są całkowicie zamknięte. Znalazłem kilka nowych rzeczy:

| Priorytet               | Znalezisko                                                                                                                     |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| **P1**                  | `VaultDecryptFile` i transparent decrypt instalują safe writer **po** pojawieniu się plaintextu                                |
| **P1**                  | staged Vault password nie ma gwarantowanego cleanupu przy wyjątku; dodatkowo `fs_unlink` jest błędnie sprawdzany przez `pcall` |
| **P1/P2**               | hash Terraform planu jest sprawdzany przed STS i promptem, ale nie ponownie tuż przed `apply`                                  |
| **P2**                  | inline `VaultEncrypt` pomija wybór `encrypt_identity`                                                                          |
| **P2 / decyzja modelu** | inline `VaultEncrypt` nie czyści persistent undo ani nie przejmuje standardowego zapisu                                        |
| **P2**                  | kod i dokumentacja zakładają, że `$XDG_RUNTIME_DIR` = tmpfs; XDG tego nie gwarantuje                                           |
| **P2**                  | `VimLeavePre` zna tylko reviewed plans, nie plan będący właśnie tworzony                                                       |
| **P3**                  | Vault tempfile ma tylko PID w nazwie                                                                                           |
| **P3**                  | `file_sha256()` wykonuje jeden `fs_read` o rozmiarze wcześniejszego `fstat`                                                    |
| **P3**                  | `AwsClear` może utracić prawdziwy startup state po ponownym `setup()`                                                          |
| **P3**                  | `binary_for()` zwraca `tofu`, nawet gdy nie ma ani Terraform, ani Tofu                                                         |
| **P3**                  | próg 512 KiB formattera bada stary plik na dysku, nie aktualny bufor                                                           |
| **docs**                | README/help nadal mają kilka rozjazdów po dodaniu `tofu_fmt` i zmianie Vault                                                   |

Najważniejsze są pierwsze trzy.

---

# 1. P1 — plaintext pojawia się przed zainstalowaniem bezpiecznego writera

To jest obecnie najsilniejsze znalezisko w Vault.

## `VaultDecryptFile`

Aktualna kolejność jest:

```lua
local plaintext = cli.decrypt_document(...)

mark_plain_vault_buffer(buf)

vim.api.nvim_buf_set_lines(buf, ..., plaintext)

remember_file_state(buf)
M.attach_writer(buf)
```

Czyli:

```text
decrypt
→ oznaczenie sensitive/plain
→ PLAINTEXT trafia do bufora
→ fingerprint
→ dopiero teraz BufWriteCmd
```

Jeżeli `M.attach_writer(buf)` rzuci wyjątkiem, komenda kończy się z **plaintextem w zwykłym file buffer i bez safe write hooka**. Następne `:w` może wrócić do standardowej ścieżki Neovima. 

Co ważne, w `VaultEncryptFile` ten sam problem został już prawidłowo rozwiązany: instalacja writera jest traktowana jako safety-critical i wykonywana w `pcall` **przed** zmianą zawartości bufora. 

## Transparent decrypt ma ten sam problem

`BufReadPost` robi:

```lua
mark_plain_vault_buffer(ev.buf)

local plaintext = cli.decrypt_document(...)

vim.api.nvim_buf_set_lines(... plaintext ...)
vim.bo[ev.buf].modified = false
remember_file_state(ev.buf)
M.attach_writer(ev.buf)
```

W tym wariancie przypadek jest jeszcze mniej przyjemny, bo po podmianie zawartości:

```lua
modified = false
```

i dopiero potem powstaje writer. Gdyby jego instalacja się nie udała, zostałby plaintextowy bufor oznaczony jako niezmodyfikowany. 

## Poprawna kolejność

Masz już `harden_sensitive_buffer()`, więc rozdzieliłbym hardening od flagi plaintext:

```lua
harden_sensitive_buffer(buf)

local plaintext, decrypt_err = cli.decrypt_document(...)
if not plaintext then
  ...
  return
end

remember_file_state(buf)

local attached, writer_err = pcall(M.attach_writer, buf)
if not attached then
  vim.notify(
    ("Refusing to decrypt: the safe writer could not be installed: %s")
      :format(writer_err),
    vim.log.levels.ERROR
  )
  return
end

vim.api.nvim_buf_set_lines(
  buf,
  0,
  -1,
  false,
  vim.split(plaintext:gsub("\n$", ""), "\n")
)

vim.b[buf].ansible_vault_plain = true
```

W transparent mode dopiero potem:

```lua
vim.bo[buf].modified = false
```

Istotny invariant:

```text
ciphertext buffer
→ hardening
→ decrypt in memory
→ fingerprint
→ SAFE WRITER
→ dopiero plaintext do bufora
```

Jeśli `set_lines()` zawiedzie po zainstalowaniu writera, bufor nadal zawiera ciphertext, a writer przy braku `ansible_vault_plain` zapisuje go przez `persist()`. To jest bezpieczny failure mode. 

### Test

Stub:

```lua
vault.attach_writer = function()
  error("synthetic writer failure")
end
```

i dwa przypadki:

```text
manual VaultDecryptFile
→ bufor nadal ciphertext

transparent BufReadPost
→ bufor nadal ciphertext
```

Plaintext marker nie może pojawić się nigdzie w buforze.

---

# 2. P1 — cleanup pliku z wpisanym ręcznie hasłem nie jest fail-safe

`stage_password()` prawidłowo tworzy:

```text
$XDG_RUNTIME_DIR/ansible-vault.nvim/password.<pid>.<hrtime>
```

z `0600`, robi `fsync` i `close`. To jest dobre. 

Problem jest później.

`run()` robi:

```lua
local result = vim
  .system(...)
  :wait()

if cleanup then
  cleanup()
end
```

Jeżeli cokolwiek pomiędzy stagingiem a `cleanup()` rzuci wyjątkiem — np. sama ścieżka `vim.system(...):wait()` — cleanup nie jest wykonany. 

Do tego sam cleanup to:

```lua
return path, function()
  pcall(vim.uv.fs_unlink, path)
end
```

co prowadzi do drugiego problemu.

## `pcall(fs_unlink)` nie sprawdza wyniku operacji

To występuje szerzej:

```lua
pcall(vim.uv.fs_unlink, path)
```

w:

* staged password cleanup;
* Vault temporary files;
* Terraform `discard_plan`;
* superseded/error/no-changes plans;
* `VimLeavePre`. 

Synchronous libuv APIs raportują zwykłe błędy przez wartości zwrotne, np. `nil, err`; nie muszą rzucać Lua exception. `pcall()` może więc zwrócić `true`, mimo że `unlink` się nie udał. ([Neovim][2])

To dokładnie ta sama klasa błędu, którą wcześniej znalazłeś dla:

```lua
pcall(vim.uv.fs_chmod, ...)
```

## Helper

Zrobiłbym wspólny wzorzec:

```lua
local function unlink_checked(path)
  local ok, err = vim.uv.fs_unlink(path)

  if ok then
    return true
  end

  -- ENOENT / już nie istnieje jest dla cleanupu sukcesem.
  if not vim.uv.fs_stat(path) then
    return true
  end

  return false, err or "unlink failed"
end
```

Dla password cleanup:

```lua
return path, function()
  return unlink_checked(path)
end
```

A `run()` powinno mieć semantykę `finally`:

```lua
local ok, result_or_err = pcall(function()
  return vim.system(cmd, {
    cwd = opts.cwd,
    stdin = opts.stdin,
    text = true,
    env = ...,
  }):wait()
end)

local cleanup_ok, cleanup_err = true, nil

if cleanup then
  cleanup_ok, cleanup_err = cleanup()
end

if not cleanup_ok then
  vim.notify(
    ("SECURITY: staged Vault password could not be removed: %s\n%s")
      :format(password_path, cleanup_err),
    vim.log.levels.ERROR
  )
end

if not ok then
  return nil,
    ("could not run ansible-vault: %s"):format(result_or_err)
end

local result = result_or_err
```

Nie zmieniałbym automatycznie udanej operacji Ansible na „failed” tylko dlatego, że cleanup nie wyszedł — `rekey` mógł już zmienić plik. Ale **błąd usunięcia password file musi zostać pokazany wraz z dokładną ścieżką**.

Test powinien stubować:

```lua
vim.uv.fs_unlink = function()
  return nil, "EPERM"
end
```

a nie `error()`. To jest ważne, bo właśnie ta różnica ujawnia obecny błąd.

---

# 3. P1/P2 — Terraform hash ma TOCTOU między weryfikacją a `apply`

Aktualne `apply()` robi:

```text
hash planu
→ sprawdzenie executable
→ applying[dir] = true
→ await aws sts get-caller-identity
→ prompt użytkownika
→ terraform apply plan.tfplan
```

Hash jest sprawdzany na liniach odpowiadających obecnym 495–512, natomiast proces powstaje dopiero po STS i `vim.fn.input()`. 

To znaczy, że plan może zostać zmieniony:

```text
po hash
     ↓
STS trwa...
     ↓
użytkownik patrzy na prompt przez 30 sekund...
     ↓
plan zostaje podmieniony
     ↓
"yes"
     ↓
apply
```

Aktualny README mówi natomiast, że sprawdzenie hasha czyni gwarancję „bytes applied == bytes reviewed” dokładną. W obecnym wykonaniu to nie jest ścisłe, bo hash nie obejmuje okresu oczekiwania na identity i ludzkie potwierdzenie. 

## Poprawka

**Zostawić obecny wczesny hash.**

Jest dobry jako fail-fast przed zajęciem katalogu i STS.

Ale po:

```lua
if answer ~= want then
  ...
end
```

i bezpośrednio przed `run("apply", ...)` dodać drugi:

```lua
local final_digest, final_err = file_sha256(saved.path)

if not final_digest then
  release()
  discard_plan(dir)

  vim.notify(
    ("Refusing to apply: the reviewed plan could not be read after confirmation (%s).")
      :format(final_err),
    vim.log.levels.ERROR
  )
  return
end

if final_digest ~= saved.sha256 then
  release()
  discard_plan(dir)

  vim.notify(
    "Refusing to apply: the plan changed while identity/confirmation was in progress. Run :TerraformPlan again.",
    vim.log.levels.ERROR
  )
  return
end
```

Czyli:

```text
review digest
→ early apply digest
→ STS
→ HUMAN CONFIRM
→ final digest
→ run
```

Nie przesuwać `applying[dir]` — jego obecna pozycja **przed STS jest poprawna** i zamyka wcześniej znaleziony race dwóch apply. 

### Test

Najczystszy test wykorzystuje już istniejący stub `vim.fn.input`:

```lua
vim.fn.input = function()
  vim.fn.writefile({ "DIFFERENT-PLAN" }, plan_path)
  return "yes"
end
```

Asercja:

```text
fake terraform apply invocation count == 0
```

To dokładnie łapie brakujący bracket.

Nadal nie nazywałbym tego ochroną przed złośliwym procesem tego samego UID — taki proces może próbować ścigać się także po finalnym hashu. To jest przede wszystkim **integralność reviewed artifactu i wykrywanie zmian podczas STS/promptu**.

---

# 4. P2 — inline `VaultEncrypt` nie używa mechanizmu wyboru Vault ID

Masz helper:

```lua
encrypt_identity_for(auth)
```

który:

* używa `vault_encrypt_identity`;
* przy wielu identities pokazuje `inputlist`;
* zwraca wybraną etykietę. 

Whole-file encryption i transparent writer korzystają z niego:

```lua
encrypt_identity = encrypt_identity_for(auth)
```



Ale inline:

```lua
cli.encrypt_string(..., {
  auth = auth,
  cwd = auth.cwd,
  name = key,
})
```

nie przekazuje `encrypt_identity`. 

`cli.encrypt_string()` potrafi obsłużyć:

```lua
--encrypt-vault-id
```

ale tylko gdy `opts.encrypt_identity` faktycznie dostanie. 

Efekt: przy kilku skonfigurowanych identities i bez domyślnego `vault_encrypt_identity`, whole-file workflow pyta użytkownika, a inline workflow tego nie robi.

## Minimum

```lua
local encrypt_identity = encrypt_identity_for(auth)

local out, encrypt_err = cli.encrypt_string(..., {
  auth = auth,
  cwd = auth.cwd,
  name = key,
  encrypt_identity = encrypt_identity,
})
```

Ale poprawiłbym również semantykę anulowania helpera, bo obecnie:

```lua
inputlist → 0
→ nil
```

jest nierozróżnialne od prawidłowego:

```text
nie potrzebujemy --encrypt-vault-id
```

Lepszy kontrakt:

```lua
---@return string|nil identity
---@return string|nil err
local function encrypt_identity_for(auth)
  ...
  if cancelled then
    return nil, "cancelled"
  end
  ...
end
```

i wszystkie call sites obsługują `cancelled` bez uruchamiania Ansible.

Test: dwie configured identities, brak defaultu, fake/real Ansible; inline encryption musi rzeczywiście dostać wybraną identity.

---

# 5. P2 — inline `VaultEncrypt` nie ma tych samych gwarancji persistence co `VaultEncryptFile`

To jest bardziej **decyzja modelu bezpieczeństwa** niż zwykły bug.

`VaultEncryptFile` teraz prawidłowo:

```text
encrypt
→ noundofile / noswapfile / nomodeline
→ usuń persistent undo
→ fingerprint
→ safe writer
→ ciphertext
```



Natomiast `VaultEncrypt` inline robi wyłącznie:

```lua
vim.api.nvim_buf_set_lines(... ciphertext ...)
```

i pozostawia normalny file buffer oraz normalny zapis Neovima. 

Jeżeli plaintext sekretu był wcześniej częścią tego YAML-a, może już znajdować się w jego persistent undo. Przy późniejszym standardowym zapisie mogą również obowiązywać normalne mechanizmy backup/writebackup.

Problemem jest przede wszystkim dokumentacja help, która nadal mówi szeroko:

> plaintext never reaches the undo file

i opisuje Vault files jako zawsze zapisywane przez własny writer. Dla mixed YAML + inline encryption to nie jest ogólnie prawdziwe. 

Nie podłączałbym bez zastanowienia obecnego whole-file writera do zwykłego YAML-a. Ten writer atomowo zastępuje cały plik i normalizuje rezultat do `0600`, co jest świadomą polityką dla Vault files, ale może być zaskakujące dla zwykłego pliku vars zawierającego jeden inline secret. 

Najuczciwsze teraz byłoby dopisać w helpie:

```text
:VaultEncrypt encrypts the selected value in the current buffer.
It does not scrub earlier plaintext from that file's existing undo/backup
history. Use :VaultEncryptFile when converting an entire plaintext secret file.
```

Jeżeli chcesz silną gwarancję również dla inline, to wymaga osobnego projektu „sensitive mixed-file writer”, a nie jednej linijki.

---

# 6. P2 — `$XDG_RUNTIME_DIR` nie znaczy „tmpfs”

Implementacja validatora jest dobra w tym, co faktycznie sprawdza:

```text
absolute
directory
owned by current UID
0700
private 0700 subdirectory
```



Ale nie sprawdza typu filesystemu.

Mimo tego kod i dokumentacja mówią m.in.:

```text
there is no in-memory directory to use
```

oraz health:

```text
(tmpfs, 0700)
```

a help:

```text
That directory is tmpfs, so the staged password file itself never reaches persistent storage.
```



XDG Base Directory Specification **nie wymaga tmpfs**. Wymaga m.in. `0700`, ownership, local filesystem i lifetime związanej z loginem; tekst mówi tylko, że runtime directory *może* znajdować się w runtime memory. ([Freedesktop.org Specifications][3])

Czyli można ustawić poprawnie prywatny:

```text
XDG_RUNTIME_DIR=/some/local/disk/directory
```

i obecny validator go zaakceptuje.

## Poprawka

Kod:

```text
XDG_RUNTIME_DIR is not set, so there is no private runtime directory to use.
```

Health:

```text
Plan files will be written to ... (private, 0700)
```

Help:

```text
The password is staged in the validated private XDG runtime directory.
The XDG specification requires session-scoped lifetime and 0700 permissions,
but does not require the filesystem to be tmpfs.
```

Terraform error również powinien mówić:

```text
will not fall back outside XDG_RUNTIME_DIR
```

zamiast obiecywać, że alternatywą byłaby zawsze „persistent storage”.

Jeśli **tmpfs jest rzeczywistym requirementem projektu**, trzeba dopiero dodać osobną, platform-specific weryfikację mount/filesystem. Obecny validator jej nie robi.

---

# 7. P2 — `VimLeavePre` nie zna planów będących właśnie w toku

Aktualny cleanup:

```lua
for _, saved in pairs(plans) do
  pcall(vim.uv.fs_unlink, saved.path)
end
```

zna wyłącznie `plans`, czyli artefakty, które zostały już zaakceptowane jako reviewed. 

Natomiast plan path jest tworzony wcześniej jako lokalna zmienna:

```lua
local path = plan_path()
```

i podczas `planning` nie trafia do żadnej globalnej struktury cleanupu. 

Jeżeli Neovim kończy się, kiedy plan właśnie powstaje, `VimLeavePre` nie ma nawet informacji, jaki path powinien spróbować usunąć.

To jest dodatkowo istotne w świetle punktu o XDG: katalog jest prywatny, ale nie masz podstaw, żeby zawsze nazywać go tmpfs.

## Poprawka

Przechowuj pending artefacts, np.:

```lua
local pending_plans = {}
```

Po przydzieleniu generacji:

```lua
pending_plans[mine] = path
```

Po każdym terminalnym wyjściu:

```lua
pending_plans[mine] = nil
```

`VimLeavePre`:

```lua
for _, saved in pairs(plans) do
  unlink_checked(saved.path)
end

for _, path in pairs(pending_plans) do
  unlink_checked(path)
end
```

Pełna gwarancja „nie przeżywa sesji” wymaga jeszcze uwzględnienia procesu, który ewentualnie nadal zapisuje plan podczas zamykania edytora. Nie zakładałbym jego semantyki bez osobnego testu `vim.system`/exit.

---

# 8. P3 — Vault atomic tempfile ma tylko PID

Aktualna nazwa:

```lua
local tmp =
  ("%s.ansible-vault.nvim.%d.tmp")
    :format(target, vim.uv.os_getpid())
```



Plik jest prawidłowo otwierany przez `"wx"`, więc istniejący stale tempfile nie zostanie nadpisany — to dobra cecha.

Ale po crashu może zostać:

```text
vault.yml.ansible-vault.nvim.12345.tmp
```

A po przyszłym reuse PID 12345 kolejny zapis tego samego Vaulta dostanie `EEXIST`.

Password staging i Terraform plan paths już używają:

```text
PID + hrtime
```

więc zastosowałbym ten sam model:

```lua
local tmp = ("%s.ansible-vault.nvim.%d.%d.tmp")
  :format(
    target,
    vim.uv.os_getpid(),
    vim.uv.hrtime()
  )
```

---

# 9. P3 — `file_sha256()` zakłada pojedynczy pełny `fs_read`

Aktualnie:

```lua
local stat = vim.uv.fs_fstat(fd)
local data = vim.uv.fs_read(fd, stat.size, 0)
return vim.fn.sha256(data)
```



Nie sprawdzasz:

```lua
#data == stat.size
```

i hashujesz rozmiar ustalony przed odczytem. To jest małe znaczenie dla lokalnego regularnego `.tfplan`, ale dla kodu, którego celem jest integralność artefaktu, lepszy jest read-to-EOF.

Przykładowo:

```lua
local chunks = {}
local offset = 0

while true do
  local chunk, err =
    vim.uv.fs_read(fd, 1024 * 1024, offset)

  if chunk == nil then
    ...
  end

  if #chunk == 0 then
    break
  end

  chunks[#chunks + 1] = chunk
  offset = offset + #chunk
end

return vim.fn.sha256(table.concat(chunks))
```

To dałbym w ten sam commit co finalny hash przed apply, nie jako osobny ważny fix.

---

# 10. P3 — `AwsClear` nie zawsze znaczy „startup environment”

Dokumentowana semantyka:

```text
Restores the environment Neovim started with
```

Kod `clear()` rzeczywiście korzysta z `initial`. 

Ale `setup()` za każdym razem wykonuje:

```lua
for _, name in ipairs(...) do
  initial[name] = vim.env[name]
end
```



Czyli:

```text
start Neovim with profile A
setup()
AwsProfile → B
setup() ponownie
AwsClear
→ B
```

a nie A.

W normalnym startupie `setup()` występuje raz, więc to P3, nie realny codzienny problem.

Fix:

```lua
local initial_captured = false

function M.setup(opts)
  ...

  if not initial_captured then
    for _, name in ipairs({
      "AWS_PROFILE",
      "AWS_REGION",
      "AWS_DEFAULT_REGION",
    }) do
      initial[name] = vim.env[name]
    end

    initial_captured = true
  end
end
```

Przy okazji keymap nadal ma:

```text
Clear AWS profile and region
```

mimo że faktycznie oznacza „Restore starting AWS environment”. 

---

# 11. P3 — `binary_for()` nadal wybiera Tofu, gdy nie ma nic

Aktualne:

```lua
return vim.fn.executable("terraform") == 1
    and "terraform"
  or "tofu"
```



Czyli:

```text
terraform absent
tofu absent
→ "tofu"
```

Potem `exepath()` prawidłowo odmówi, więc nie ma niewłaściwego wykonania. Komunikat będzie jednak sugerował, że Tofu było rzeczywiście wybranym backendem.

Czyściej:

```lua
if vim.fn.executable("terraform") == 1 then
  return "terraform"
end

if vim.fn.executable("tofu") == 1 then
  return "tofu"
end

return nil
```

i komunikat:

```text
Neither terraform nor tofu was found on PATH
```

Terragrunt oczywiście pozostaje sprawdzany wcześniej.

---

# 12. P3 — próg dużego pliku sprawdza stary plik, nie bufor

`format_on_save` robi:

```lua
local stat =
  vim.uv.fs_stat(vim.api.nvim_buf_get_name(bufnr))

if stat and stat.size > max_bytes then
  ...
end
```



To jest `BufWritePre`, więc `stat.size` opisuje **wersję na dysku przed zapisem**.

Przypadek:

```text
disk:    100 KiB
buffer:  900 KiB
:w
```

przejdzie przez limit i spróbuje synchronous formatting, mimo że celem limitu było właśnie unikanie dużych buforów.

Najprościej policzyć rzeczywiste bytes:

```lua
local bytes = 0

for _, line in ipairs(
  vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
) do
  bytes = bytes + #line + 1
end
```

i porównywać `bytes`.

To jest UX/performance, nie correctness.

---

# 13. Dokumentacja — kilka aktualnych rozjazdów

### Terraform formatting

Kod już poprawnie robi:

```text
terraform_fmt
→ tofu_fmt fallback
```



README nadal mówi:

```text
Terraform formatting needs the terraform CLI
```

co po commicie `74183df` nie jest prawdą. 

Powinno być:

```text
Terraform formatting prefers `terraform fmt`; when Terraform is absent,
`tofu fmt` is used instead.
```

Help również nadal opisuje formatting jako tylko `terraform_fmt`. 

### `VaultRekey`

Implementacja oraz główny help prawidłowo mówią, że rekey jest do **skonfigurowanej identity**. 

Ale command description nadal brzmi:

```text
Re-encrypt this file with a new password
```



Powinno być:

```lua
desc = "Re-encrypt this file under another configured vault id"
```

### Runtime dir

Jak wyżej: `tmpfs` oraz „in-memory” trzeba usunąć tam, gdzie kod tego nie weryfikuje. 

---

# 14. `MasonVersions` — nie błąd, ale kruche API

Masz:

```lua
pkg:get_receipt()._value.source.id
```



`_value` wygląda jak wewnętrzna reprezentacja receipt, nie stabilny kontrakt publicznego helpera. Masz to w `pcall`, więc awaria skończy się `?`, a nie złamaniem konfiguracji.

Dlatego:

**nie klasyfikuję jako bug**.

Traktowałbym jedynie jako maintainability debt: po aktualizacji Mason sprawdzić, czy receipt nadal ma taki kształt.

---

# 15. CI wygląda obecnie dobrze

Po ostatnich commitach źródło workflow ma:

* Actions przypięte do pełnych SHA;
* konkretny Neovim;
* checksum Selene;
* `ansible-core==2.21.*` w osobnym venv;
* `$GITHUB_PATH`;
* wymaganie obecności `Fails (0)`;
* `unzip` i `gzip` w startup prerequisites. 

Nie znalazłem tutaj nowego strukturalnego defektu.

Ponownie: **nie uruchamiałem tego workflow**, więc mówię o kodzie workflow, nie o wyniku ostatniego Action run.

---

# Pokrycie testami

Obecny `test_terraform_lifecycle.lua` jest sensownie skonstruowany: fake executables zapisują realne argv, fake AWS ma sterowane odpowiedzi STS, a apply confirmation jest stubowane. 

Nowo znalezione rzeczy, dla których nie widzę odpowiadającego im regression case, to:

| Brakujący przypadek                       | Mutacja/test                                                |
| ----------------------------------------- | ----------------------------------------------------------- |
| plan zmienia się podczas promptu apply    | podmień file w `vim.fn.input`, zwróć `yes`; apply count = 0 |
| writer decrypta nie daje się zainstalować | `attach_writer → error`; ciphertext musi zostać             |
| unlink zwraca `nil, EPERM`                | musi pojawić się cleanup failure                            |
| `vim.system` rzuca po password staging    | password file musi zostać posprzątany                       |
| inline encrypt + 2 Vault IDs              | fake Ansible musi dostać `--encrypt-vault-id`               |
| Neovim kończy się przy pending plan       | artefakt nie powinien zostać                                |
| drugi `aws.setup()`                       | `AwsClear` nadal przywraca pierwszy snapshot                |

To byłby kolejny logiczny batch testów.

---

# Przegląd plik po pliku

| Obszar                      | Stan po obecnym audycie                                                                                 |
| --------------------------- | ------------------------------------------------------------------------------------------------------- |
| `init.lua`                  | **OK**                                                                                                  |
| `lua/config/options.lua`    | **OK**; clipboard/ShaDa są już uczciwie opisane jako poza gwarancją                                     |
| `lua/config/keymaps.lua`    | **OK**                                                                                                  |
| `lua/config/commands.lua`   | **OK**                                                                                                  |
| `lua/config/lazy.lua`       | **OK**, `local_spec=false` nadal obecne                                                                 |
| `after/lsp/*.lua`           | **OK**, nie znalazłem nowej regresji                                                                    |
| `plugins/completion.lua`    | **OK**                                                                                                  |
| `plugins/devops.lua`        | **OK**                                                                                                  |
| `plugins/editing.lua`       | **OK**                                                                                                  |
| `plugins/git.lua`           | **OK**                                                                                                  |
| `plugins/lint.lua`          | **OK**                                                                                                  |
| `plugins/navigation.lua`    | **OK**                                                                                                  |
| `plugins/sessions.lua`      | **OK**                                                                                                  |
| `plugins/treesitter.lua`    | **OK**; wcześniejsza uwaga o osobnym pinowaniu parserów nadal nie ma zastosowania                       |
| `plugins/formatting.lua`    | tofu/global toggle **naprawione**; pozostaje próg oparty o disk size                                    |
| `plugins/lsp.lua`           | **OK funkcjonalnie**; `_value` w `MasonVersions` jest kruche                                            |
| `plugins/ui.lua`            | nie znalazłem nowego błędu wykonawczego                                                                 |
| `lua/aws/init.lua`          | **P3:** snapshot `initial` przy każdym `setup()`                                                        |
| `ansible-vault/config.lua`  | **OK**                                                                                                  |
| `ansible-vault/runtime.lua` | validator **OK**, ale nie dowodzi tmpfs                                                                 |
| `ansible-vault/cli.lua`     | **P1:** cleanup/finally + `pcall(fs_unlink)`                                                            |
| `ansible-vault/init.lua`    | hard links/conversion/block boundary **naprawione**; pozostaje writer ordering + inline ID/persistence  |
| `terraform/runtime.lua`     | validator **OK**, ten sam problem słowa „in-memory”                                                     |
| `terraform/init.lua`        | lifecycle **dużo lepszy**; pozostają final hash, unlink/pending cleanup i kilka P3                      |
| `lua/devops/health.lua`     | logika narzędzi **OK**; `tmpfs` to overclaim                                                            |
| `tests/`                    | silne pokrycie poprzednich audytów; nowe przypadki powyżej jeszcze nie są zamknięte                     |
| `.github/workflows/ci.yml`  | **OK strukturalnie**                                                                                    |
| README/help                 | kilka rozjazdów: tofu, tmpfs, inline persistence, Rekey desc                                            |

---

# Kolejność, którą przyjąłbym teraz

1. **`fix(vault): install the safe writer before exposing plaintext`**
2. **`fix(vault): make staged-password cleanup exception-safe`**
3. **`fix(terraform): recheck the reviewed plan after confirmation`**
4. **`fix(vault): honor encryption identity for inline values`**
5. **`fix(cleanup): stop treating pcall as fs_unlink success`**
6. **`fix(terraform): track pending plan artifacts for session cleanup`**
7. **`docs(runtime): stop equating XDG_RUNTIME_DIR with tmpfs`**
8. **decyzja:** czy inline `VaultEncrypt` ma scrubować undo/writebackup, czy tylko dokumentujemy ograniczenie
9. P3 batch: tempfile uniqueness, robust file hash, AWS initial snapshot, binary message, buffer-size formatter
10. docs cleanup: tofu + rekey description + inline guarantee

Najważniejsze: **nie znalazłem nowej klasy nieodwracalnej destrukcji danych porównywalnej z wcześniejszym hard-link rekey**. Obecne najgroźniejsze miejsce to exception safety podczas odszyfrowania Vaulta: safe writer jest traktowany jako obowiązkowy, ale w dwóch ścieżkach powstaje dopiero po umieszczeniu plaintextu w file buffer. To naprawiłbym jako pierwsze.

[1]: https://github.com/ultherego/dev-nvim/commits/main "Commits · ultherego/dev-nvim · GitHub"
[2]: https://neovim.io/doc/user/luvref.html "https://neovim.io/doc/user/luvref/"
[3]: https://specifications.freedesktop.org/basedir-spec/latest/ "XDG Base Directory Specification"
