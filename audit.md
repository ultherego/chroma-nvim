# Pełny audyt `dev-nvim`

## Zakres

Audyt dotyczy aktualnie przeanalizowanego commita:

```text
6f3ca37d24aa6a0013cc5ff0ffcead4216f188ae
```

Przejrzałem:

* konfigurację Neovim i lazy.nvim;
* LSP, Mason, completion, Tree-sitter;
* formatting i linting;
* navigation, UI, Git, sessions;
* Kubernetes i Ansible;
* własne moduły `ansible-vault.nvim`, `terraform.nvim`, `aws`;
* health check;
* testy;
* GitHub Actions;
* README, help i `CONTRACT.md`.

Jest to audyt statyczny. Nie potwierdzam wyniku rzeczywistego uruchomienia testów ani operacji na prawdziwym Vault, Terraform state czy koncie AWS.

## Ocena końcowa

**Aktualny stan: 8/10.**

Konfiguracja Neovim jest dojrzała i dobrze zorganizowana. Największe ryzyko znajduje się już nie w pluginach, lecz we własnym kodzie wykonującym operacje na sekretach i infrastrukturze.

Najważniejsze problemy:

| Priorytet | Problem                                                                    |
| --------- | -------------------------------------------------------------------------- |
| P1        | `VaultRekey` nie działa poprawnie w transparent mode                       |
| P1        | alternatywna ścieżka zapisu Vaulta omija atomic write i conflict detection |
| P1        | można utworzyć wiele `BufWriteCmd` dla tego samego bufora                  |
| P1        | Terraform nie używa przy apply programu zapisanego podczas plan            |
| P1        | ten sam plan można zastosować równolegle kilka razy                        |
| P1        | plan nie jest związany z rzeczywistym kontem AWS                           |
| P2        | `XDG_RUNTIME_DIR` nie jest walidowany jako bezpieczny katalog              |
| P2        | wykrywanie zmiany Vaulta ma tylko sekundową dokładność                     |
| P2        | błąd `chmod 0600` planu Terraform jest ignorowany                          |
| P2        | wspólne `args` są doklejane do wszystkich poleceń Terraform                |
| P2        | `TerraformDiscard` usuwa plany dla wszystkich katalogów                    |
| P3        | testy Terraform są niewystarczające                                        |
| P3        | CI nie przypina wersji Ansible i nie weryfikuje checksum Selene            |
| P3        | kilka fragmentów dokumentacji nie odpowiada implementacji                  |

---

# 1. Co jest obecnie zrobione dobrze

## Rdzeń Neovim

Architektura:

```text
init.lua
lua/config/
lua/plugins/
after/lsp/
lua/ansible-vault/
lua/terraform/
lua/aws/
lua/devops/
```

jest logiczna. Core settings, komendy, plugin specs i własne moduły są rozdzielone. README prawidłowo opisuje 10 aktywowanych LSP oraz nowe własne moduły. 

Dobrze rozwiązano między innymi:

* `local_spec=false` w lazy.nvim;
* lockfile pluginów;
* native `vim.lsp.config()` i `vim.lsp.enable()`;
* jawny allow-list LSP;
* przypinanie wersji pakietów Mason;
* poprawny toggle formatowania globalnego i buforowego;
* wspólną logikę manualnego i automatycznego lintowania;
* osobne traktowanie szybkich i wolnych linterów;
* ograniczenie `terragrunt_hclfmt` do plików Terragrunt;
* obsługę `.yaml` i `.yml`;
* nowy model Tree-sitter;
* brak nadpisywania standardowych `{` oraz `}`;
* widoczne deleted signs w Gitsigns.

## Standardowy zapis Ansible Vault

Główna ścieżka transparentnego zapisu:

1. sprawdza zmianę pliku na dysku;
2. szyfruje plaintext przez `ansible-vault`;
3. zapisuje ciphertext do pliku tymczasowego;
4. wykonuje `fsync`;
5. zamyka plik;
6. atomowo wykonuje `rename`;
7. dopiero wtedy oznacza bufor jako zapisany.

To jest dobry model bezpieczeństwa. Kod chroni również symlinki przez rozwiązanie rzeczywistego targetu przed `rename`. 

## AWS

Moduł AWS prawidłowo:

* zapamiętuje środowisko istniejące przy uruchomieniu Neovim;
* przy `AwsClear` przywraca stan początkowy zamiast bezwarunkowo usuwać zmienne;
* czyści stary region przy zmianie profilu;
* ostrzega o zmiennych credentials mających pierwszeństwo przed `AWS_PROFILE`;
* ma osobne `AwsWhoami`.

To jest duża poprawa względem wcześniejszej wersji. 

## CI

Workflow ma:

* Actions przypięte do pełnych SHA;
* ustaloną wersję Neovim;
* ustalone wersje StyLua, Selene i Tree-sitter CLI;
* testy MiniTest;
* smoke test startupu;
* sprawdzanie wszystkich modułów;
* walidację `doc/tags`;
* walidację JSON lockfile.

GitHub zaleca pełny commit SHA jako niezmienną metodę przypięcia Action, więc ten element został zrealizowany prawidłowo. 

---

# 2. `ansible-vault.nvim`

## P1: `VaultRekey` nie działa w transparent mode

Domyślnie zaszyfrowany plik jest automatycznie zamieniany w buforze na plaintext. `rekey_file()` sprawdza jednak:

```lua
if path == "" or not is_encrypted(buf) then
```

`is_encrypted(buf)` analizuje zawartość bufora, a nie plik na dysku. W standardowym transparent workflow zawartością bufora jest plaintext, więc `VaultRekey` odmówi działania. 

Dodatkowo po rekey wykonywane jest:

```lua
vim.cmd.edit({ bang = true })
```

Nowe hasło istniało jednak tylko w tymczasowym pliku, który został już usunięty. Jeżeli `ansible.cfg` nadal wskazuje stare credentials, automatyczne odszyfrowanie po reloadzie nie zadziała. 

### Jak poprawić

Nie należy sprawdzać ciphertextu w buforze. Trzeba sprawdzać plik na dysku:

```lua
local function file_is_vault(path)
  local lines = vim.fn.readfile(path, "", 1)
  return lines[1] ~= nil and lines[1]:match("^%$ANSIBLE_VAULT") ~= nil
end
```

Następnie:

```lua
if path == "" or not file_is_vault(path) then
  vim.notify(
    "Current file on disk is not vault-encrypted",
    vim.log.levels.WARN
  )
  return
end
```

Pozostaje problem nowego źródła hasła. Najbezpieczniejszy projekt to:

1. nie pytać wyłącznie o jednorazowe nowe hasło;
2. wymagać trwałego password file albo skonfigurowanego nowego Vault ID;
3. wykonać rekey do tego źródła;
4. dopiero wtedy przeładować bufor.

Przykładowy workflow:

```text
vault_identity_list = old@/secure/old.pass,new@/secure/new.pass
```

Plugin powinien pozwolić wybrać `new`, a następnie wywołać rekey z nowym Vault ID. Dzięki temu po `:edit!` Ansible nadal zna źródło nowego hasła.

### Minimalna poprawka fail-closed

Dopóki wybór trwałego źródła nie zostanie zaimplementowany, bezpieczniej odmówić rekey dla transparentnego bufora:

```lua
if vim.b[buf].ansible_vault_plain then
  vim.notify(
    "Rekey requires a persistent new password source. "
      .. "Configure the new vault identity first.",
    vim.log.levels.ERROR
  )
  return
end
```

To ogranicza funkcjonalność, ale nie pozostawia bufora w stanie, którego plugin nie potrafi później poprawnie odszyfrować ani zapisać.

---

## P1: alternatywna ścieżka zapisu Vaulta jest niebezpieczna

`attach_writer()` ma dwie ścieżki.

Dla plaintextu używa bezpiecznego `write_atomically()`. Dla bufora, który nie ma już flagi `ansible_vault_plain`, wykonuje:

```lua
vim.fn.writefile(
  vim.api.nvim_buf_get_lines(ev.buf, 0, -1, false),
  path
)
vim.bo[ev.buf].modified = false
```

Ta ścieżka:

* nie sprawdza zmiany pliku na dysku;
* nie sprawdza wyniku `writefile()`;
* nie zapisuje atomowo;
* bezwarunkowo ustawia `modified=false`;
* nie aktualizuje remembered file state.

Jest uruchamiana między innymi po `VaultEncryptFile`, ponieważ ta komenda usuwa flagę plaintextu. 

### Jak poprawić

Wszystkie zapisy należące do pluginu powinny przechodzić przez jeden helper:

```lua
local function persist_ciphertext(buf, ciphertext)
  local changed = file_changed_since_read(buf)
  if changed then
    return false, changed
  end

  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" then
    return false, "buffer has no file name"
  end

  local ok, err = write_atomically(path, ciphertext)
  if not ok then
    return false, err
  end

  vim.bo[buf].modified = false
  remember_file_state(buf)
  return true
end
```

Writer:

```lua
function M.attach_writer(buf)
  vim.api.nvim_clear_autocmds({
    group = writer_group,
    event = "BufWriteCmd",
    buffer = buf,
  })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = writer_group,
    buffer = buf,
    callback = function(ev)
      if not vim.b[ev.buf].ansible_vault_plain then
        local ok, err = persist_ciphertext(
          ev.buf,
          buffer_text(ev.buf)
        )

        if not ok then
          vim.notify(
            ("Could not write Vault: %s"):format(err),
            vim.log.levels.ERROR
          )
        end

        return
      end

      -- obecna ścieżka encrypt_document()
      -- zakończona przez persist_ciphertext()
    end,
  })
end
```

W ścieżce plaintext:

```lua
local ciphertext, encrypt_err = cli.encrypt_document(...)

if not ciphertext then
  vim.notify(encrypt_err, vim.log.levels.ERROR)
  return
end

local ok, write_err = persist_ciphertext(ev.buf, ciphertext)
if not ok then
  vim.notify(write_err, vim.log.levels.ERROR)
end
```

---

## P1: duplikowanie `BufWriteCmd`

Każde wywołanie `M.attach_writer(buf)` tworzy nowy autocmd, ale nie usuwa starego. Transparentny `BufReadPost`, w tym kolejne `:edit!`, ponownie wywołuje `M.attach_writer()`. 

Po kilku reloadach jeden `:write` może uruchomić kilka writerów.

### Poprawka

Przed `nvim_create_autocmd()`:

```lua
vim.api.nvim_clear_autocmds({
  group = writer_group,
  event = "BufWriteCmd",
  buffer = buf,
})
```

Neovim oficjalnie pozwala czyścić autocmdy według grupy, eventu i bufora. ([Neovim][1])

### Test regresji

```lua
T["writer"]["only one writer survives reloads"] = function()
  local buf = vim.api.nvim_get_current_buf()

  vault.attach_writer(buf)
  vault.attach_writer(buf)
  vault.attach_writer(buf)

  local autocmds = vim.api.nvim_get_autocmds({
    group = "ansible_vault_writer",
    event = "BufWriteCmd",
    buffer = buf,
  })

  eq(#autocmds, 1)
end
```

---

## P2: wykrywanie zmiany pliku ma zbyt małą dokładność

Zapamiętywane są tylko:

```lua
{
  mtime = stat.mtime.sec,
  size = stat.size,
}
```

Zmiana wykonana w tej samej sekundzie, zachowująca identyczny rozmiar, może pozostać niewykryta. 

### Poprawka

```lua
local function file_fingerprint(path)
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return nil
  end

  return {
    mtime_sec = stat.mtime.sec,
    mtime_nsec = stat.mtime.nsec,
    size = stat.size,
    ino = stat.ino,
    dev = stat.dev,
  }
end
```

Porównanie:

```lua
local function same_fingerprint(a, b)
  return a
    and b
    and a.mtime_sec == b.mtime_sec
    and a.mtime_nsec == b.mtime_nsec
    and a.size == b.size
    and a.ino == b.ino
    and a.dev == b.dev
end
```

Dla maksymalnej ochrony można dodatkowo przechowywać hash ciphertextu, ale stat z nanosekundami, inode i device jest wystarczającą poprawą dla typowego lokalnego filesystemu.

---

## P2: hard links nie są obsługiwane

Kod poprawnie zachowuje symlinki, ale sam komentarz przyznaje, że atomowy `rename()` rozrywa hard links. 

### Poprawka

Najbezpieczniej odmówić zapisu, jeśli target ma więcej niż jeden hard link:

```lua
local stat = vim.uv.fs_stat(target)
if stat and stat.nlink and stat.nlink > 1 then
  return false,
    ("refusing atomic replacement: %s has %d hard links")
      :format(target, stat.nlink)
end
```

Nie należy automatycznie przechodzić na zapis in-place, ponieważ utraciłbyś ochronę przed truncate i częściowym zapisem.

---

## P2: staging hasła nie sprawdza `fsync` i `fs_close`

`stage_password()` sprawdza short write, ale wynik `fs_close()` jest ignorowany. Nie wykonuje również `fsync`. 

### Poprawka

```lua
local written, write_err = vim.uv.fs_write(fd, payload)

if not written or written < #payload then
  vim.uv.fs_close(fd)
  vim.uv.fs_unlink(path)
  return nil, nil, write_err or "short write"
end

local synced, sync_err = vim.uv.fs_fsync(fd)
if synced == nil then
  vim.uv.fs_close(fd)
  vim.uv.fs_unlink(path)
  return nil, nil, sync_err or "fsync failed"
end

local closed, close_err = vim.uv.fs_close(fd)
if not closed then
  vim.uv.fs_unlink(path)
  return nil, nil, close_err or "close failed"
end
```

---

# 3. `terraform.nvim`

## P1: apply nie używa programu zapisanego przy planowaniu

Plan zapisuje:

```lua
{
  path = path,
  destroy = destroy,
  context = context,
  binary = binary,
}
```

Ale `run()` przy każdym wywołaniu ponownie wykonuje:

```lua
local bin = binary_for(dir)
```

`TerraformApply` nie przekazuje `saved.binary`. 

Możliwy scenariusz:

1. plan utworzony przez `terraform`;
2. zmienia się `PATH` albo dostępność executable;
3. apply wybiera `tofu`;
4. albo pojawia się `terragrunt.hcl` i apply wybiera `terragrunt`.

### Poprawka

Zmień `run()`:

```lua
---@param args string[]
---@param dir string
---@param on_done fun(code: integer, lines: string[])
---@param binary? string
local function run(args, dir, on_done, binary)
  local bin = binary or binary_for(dir)
  local executable = vim.fn.exepath(bin)

  if executable == "" then
    vim.notify(("`%s` not found on PATH"):format(bin), vim.log.levels.ERROR)
    return nil
  end

  local cmd = { executable }
  vim.list_extend(cmd, args)

  return vim.system(cmd, {
    cwd = dir,
    text = true,
  }, function(result)
    -- callback
  end)
end
```

Podczas plan:

```lua
local binary_name = binary_for(dir)
local binary_path = vim.fn.exepath(binary_name)

if binary_path == "" then
  -- odmowa
end
```

Zapisz pełną ścieżkę:

```lua
plans[dir] = {
  path = path,
  destroy = destroy,
  context = context,
  binary = binary_path,
}
```

Apply:

```lua
if vim.fn.executable(saved.binary) ~= 1 then
  vim.notify(
    "The executable used to create this plan is no longer available. "
      .. "Create a new plan.",
    vim.log.levels.ERROR
  )
  return
end

run(
  { "apply", "-no-color", "-input=false", saved.path },
  dir,
  on_apply_done,
  saved.binary
)
```

---

## P1: podwójny równoległy apply

Plan pozostaje w `plans[dir]` aż do zakończenia callbacku apply. Przed zakończeniem użytkownik może ponownie wykonać `TerraformApply`. Oba procesy otrzymają ten sam plan. 

### Minimalna poprawka

```lua
local applying = {}
```

Przed promptem:

```lua
if applying[dir] then
  vim.notify(
    "An apply is already running for this directory",
    vim.log.levels.WARN
  )
  return
end
```

Po potwierdzeniu:

```lua
applying[dir] = true

local process = run(
  { "apply", "-no-color", "-input=false", saved.path },
  dir,
  function(code, lines)
    applying[dir] = nil
    discard_plan(dir)

    -- wynik
  end,
  saved.binary
)

if not process then
  applying[dir] = nil
end
```

Lepsze rozwiązanie to pełny automat stanów:

```lua
local operations = {
  -- [dir] = {
  --   state = "planning" | "reviewed" | "applying",
  --   generation = 1,
  --   process = vim.SystemObj,
  --   plan = table,
  -- }
}
```

Dozwolone przejścia:

```text
idle → planning
planning → reviewed
planning → idle       błąd/brak zmian
reviewed → applying
reviewed → idle       discard
applying → idle
```

Podczas `applying` należy odrzucać:

* nowy plan;
* drugi apply;
* discard;
* init;
* validate, jeżeli może kolidować z backendem.

---

## P1: plan nie jest związany z rzeczywistą tożsamością AWS

Zapisujesz tylko:

```lua
{
  profile = vim.env.AWS_PROFILE,
  region = vim.env.AWS_REGION or vim.env.AWS_DEFAULT_REGION,
}
```

Kod świadomie nie pyta STS o faktyczne konto. 

To nie wykryje:

* zmiany static credentials;
* zmiany `AWS_SESSION_TOKEN`;
* odświeżenia SSO do innego konta;
* zmiany zawartości `~/.aws/credentials`;
* zmiany roli pod tą samą nazwą profilu;
* web identity override.

Zmienne środowiskowe credentials mają pierwszeństwo przed profilem, co sam moduł AWS prawidłowo sygnalizuje. 

### Poprawka

Dodaj asynchroniczne pobieranie tożsamości:

```lua
local function aws_identity(callback)
  if vim.fn.executable("aws") ~= 1 then
    callback(nil)
    return
  end

  vim.system({
    "aws",
    "sts",
    "get-caller-identity",
    "--output",
    "json",
  }, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(nil, result.stderr)
        return
      end

      local ok, decoded = pcall(
        vim.json.decode,
        result.stdout or ""
      )

      if not ok then
        callback(nil, "invalid STS response")
        return
      end

      callback({
        account_id = decoded.Account,
        arn = decoded.Arn,
      })
    end)
  end)
end
```

Podczas plan zapisz:

```lua
context = {
  profile = vim.env.AWS_PROFILE,
  region = vim.env.AWS_REGION or vim.env.AWS_DEFAULT_REGION,
  account_id = identity and identity.account_id,
  arn = identity and identity.arn,
}
```

Przed apply ponownie pobierz STS.

Zasada:

* zmiana `account_id` — twarda odmowa;
* zmiana ARN/principal — twarda odmowa albo przynajmniej bardzo wyraźny prompt;
* brak możliwości sprawdzenia STS po wcześniejszym udanym sprawdzeniu — odmowa;
* projekt bez AWS — pominięcie kontroli.

Nie przechowuj secret key ani session tokenu.

---

## P2: jeden `args` dla każdego polecenia

Domyślna konfiguracja ma:

```lua
args = {}
```

`run()` dokleja te argumenty do każdego polecenia:

```lua
vim.list_extend(cmd, M.options.args)
```

Dotyczy to `plan`, `apply`, `init` i `validate`. 

Argumenty takie jak:

```text
-var-file
-target
-refresh-only
```

mają sens dla plan, ale nie dla `init`.

Z kolei globalne `-chdir` musi znaleźć się przed subcommandem, więc obecny model również go nie obsługuje poprawnie.

### Poprawka

```lua
local defaults = {
  keymaps = false,

  global_args = {},
  init_args = {},
  validate_args = {},
  plan_args = {},
  apply_args = {},
}
```

Builder:

```lua
local function command(binary, subcommand, subcommand_args)
  local cmd = { binary }

  vim.list_extend(cmd, M.options.global_args)
  table.insert(cmd, subcommand)
  vim.list_extend(cmd, subcommand_args or {})

  return cmd
end
```

Przykład:

```lua
local args = {
  "-no-color",
  "-input=false",
  "-detailed-exitcode",
  "-out=" .. path,
}

vim.list_extend(args, M.options.plan_args)
```

---

## P2: ignorowany błąd `chmod 0600`

Po utworzeniu planu wykonywane jest:

```lua
pcall(vim.uv.fs_chmod, path, tonumber("600", 8))
```

Niezależnie od wyniku plan zostaje zapisany w `plans`. 

### Poprawka

```lua
local chmod_ok, chmod_err = vim.uv.fs_chmod(
  path,
  tonumber("600", 8)
)

if not chmod_ok then
  pcall(vim.uv.fs_unlink, path)

  vim.notify(
    ("Could not protect Terraform plan: %s")
      :format(chmod_err or "chmod failed"),
    vim.log.levels.ERROR
  )

  return
end
```

Najlepiej umieścić plany w dedykowanym katalogu `0700`, dzięki czemu nawet krótki okres przed `chmod` nie udostępni pliku innym użytkownikom.

---

## P2: `TerraformDiscard` usuwa wszystkie plany

Implementacja iteruje po całym `plans`:

```lua
for dir, _ in pairs(vim.deepcopy(plans)) do
  discard_plan(dir)
end
```

Nazwa polecenia i typowy kontekst wskazują raczej na plan aktualnego projektu. 

### Poprawka

```lua
function M.discard()
  local dir = root_dir()
  if not dir then
    vim.notify("No Terraform project found", vim.log.levels.WARN)
    return
  end

  if not plans[dir] then
    vim.notify(
      "No saved plan for this directory",
      vim.log.levels.INFO
    )
    return
  end

  discard_plan(dir)
  vim.notify("Discarded the saved plan", vim.log.levels.INFO)
end
```

Osobno:

```lua
function M.discard_all()
  for dir in pairs(vim.deepcopy(plans)) do
    discard_plan(dir)
  end
end
```

Komendy:

```text
:TerraformDiscard
:TerraformDiscardAll
```

---

## P2: zbyt mocna gwarancja w komentarzu

Dokumentacja mówi:

```text
Drift between reading and applying is impossible.
```

Saved plan ustala zestaw zaplanowanych działań, ale nie unieruchamia:

* środowiska credentials;
* rzeczywistego konta;
* executable;
* zewnętrznej infrastruktury;
* backendu;
* uprawnień;
* dostępności providerów.

Plan rzeczywiście służy do późniejszego wykonania zapisanych działań, ale sam nie gwarantuje niezmienności całego execution context. 

Lepszy komentarz:

```text
The saved plan fixes the planned action set. The runner additionally verifies
the selected executable and execution identity before apply. Remote
infrastructure and external credentials may still change between the two
operations.
```

---

# 4. Wspólne bezpieczeństwo `$XDG_RUNTIME_DIR`

Vault i Terraform sprawdzają głównie, czy zmienna istnieje i czy ścieżka jest dostępna. 

Specyfikacja XDG wymaga, aby runtime directory:

* należał do użytkownika;
* miał uprawnienia `0700`;
* był dostępny tylko w czasie sesji użytkownika;
* nie przetrwał pełnego wylogowania ani restartu. ([Freedesktop.org Specifications][2])

## Poprawka: wspólny moduł

Utwórz:

```text
lua/devops/runtime.lua
```

```lua
local bit = require("bit")

local M = {}

function M.secure_dir()
  local dir = vim.env.XDG_RUNTIME_DIR
  if not dir or dir == "" then
    return nil, "XDG_RUNTIME_DIR is not set"
  end

  if not vim.fs.is_absolute(dir) then
    return nil, "XDG_RUNTIME_DIR is not an absolute path"
  end

  local stat = vim.uv.fs_stat(dir)
  if not stat or stat.type ~= "directory" then
    return nil, "XDG_RUNTIME_DIR is not a directory"
  end

  if vim.uv.getuid and stat.uid ~= vim.uv.getuid() then
    return nil, "XDG_RUNTIME_DIR is not owned by the current user"
  end

  local permissions = bit.band(stat.mode, tonumber("777", 8))
  if permissions ~= tonumber("700", 8) then
    return nil,
      ("XDG_RUNTIME_DIR has mode %o, expected 700")
        :format(permissions)
  end

  local app_dir = vim.fs.joinpath(dir, "dev-nvim")
  local app_stat = vim.uv.fs_stat(app_dir)

  if not app_stat then
    local ok, err = vim.uv.fs_mkdir(
      app_dir,
      tonumber("700", 8)
    )

    if not ok then
      return nil, err or "could not create runtime directory"
    end
  end

  return app_dir
end

return M
```

Następnie zarówno Terraform, jak i Vault powinny używać:

```lua
local runtime_dir, err =
  require("devops.runtime").secure_dir()
```

Health check powinien również wywoływać tę samą funkcję.

---

# 5. Formatting i health check

## OpenTofu jest wykrywany, ale nie używany do formatowania

Health check uznaje:

```text
terraform or tofu found — .tf files can be formatted
```

Konfiguracja Conform używa jednak wyłącznie:

```lua
terraform = { "terraform_fmt" }
["terraform-vars"] = { "terraform_fmt" }
```

`terraform_fmt` i `tofu_fmt` są osobnymi formatterami Conform. 

### Poprawka

```lua
local function terraform_formatter(bufnr)
  local conform = require("conform")

  if conform.get_formatter_info(
    "terraform_fmt",
    bufnr
  ).available then
    return { "terraform_fmt" }
  end

  if conform.get_formatter_info(
    "tofu_fmt",
    bufnr
  ).available then
    return { "tofu_fmt" }
  end

  return {}
end
```

W konfiguracji:

```lua
terraform = terraform_formatter,
["terraform-vars"] = terraform_formatter,
```

Health:

```lua
if vim.fn.executable("terraform") == 1 then
  health.ok("`terraform` found — .tf files use terraform fmt")
elseif vim.fn.executable("tofu") == 1 then
  health.ok("`tofu` found — .tf files use tofu fmt")
else
  health.warn("Neither `terraform` nor `tofu` found")
end
```

## Brakujące wymagania Mason

Health i README sprawdzają/wymieniają `git`, `curl`, `tar`, ale pomijają `unzip` oraz `gzip`. Mason wymienia oba w rekomendowanych wymaganiach dla systemów Unix. 

Dodaj:

```lua
{ cmd = "unzip", what = "unpacking Mason packages" },
{ cmd = "gzip", what = "unpacking Mason packages" },
```

README:

```text
git >= 2.19, curl or wget, tar, unzip, gzip, a C compiler
```

Na CachyOS:

```fish
sudo pacman -S --needed git curl tar unzip gzip base-devel
```

---

# 6. CI i testy

## Brak przypiętej wersji Ansible

Komentarze kodu odnoszą się do konkretnego zachowania Ansible, ale CI instaluje:

```sh
apt-get install ansible
```

Wersja zależy od aktualnego `ubuntu-latest` i repozytoriów APT. 

### Poprawka

```yaml
env:
  ANSIBLE_CORE_VERSION: "2.21.*"
```

```yaml
- name: Install ansible-core
  run: |
    set -euo pipefail
    python3 -m venv .venv
    .venv/bin/pip install "ansible-core==${ANSIBLE_CORE_VERSION}"
    echo "$GITHUB_WORKSPACE/.venv/bin" >> "$GITHUB_PATH"
```

Lepszy wariant to matrix:

```yaml
strategy:
  matrix:
    ansible-core:
      - "2.20.*"
      - "2.21.*"
```

## Selene bez checksum

Archiwum Selene ma ustaloną wersję, ale pobrany ZIP nie jest weryfikowany checksumą. 

### Poprawka

```yaml
env:
  SELENE_VERSION: 0.31.0
  SELENE_SHA256: "<oficjalna-suma-release-archive>"
```

```yaml
- name: Install selene
  run: |
    set -euo pipefail

    curl -fsSL -o selene.zip \
      "https://github.com/Kampfkarren/selene/releases/download/${SELENE_VERSION}/selene-${SELENE_VERSION}-linux.zip"

    echo "${SELENE_SHA256}  selene.zip" | sha256sum -c -

    unzip -q selene.zip
    chmod +x selene
    sudo mv selene /usr/local/bin/
```

Nie należy wpisywać przypadkowej sumy — trzeba pobrać ją z oficjalnego release albo obliczyć i świadomie przypiąć podczas aktualizacji wersji.

## Testy Terraform są za płytkie

Aktualne testy Terraform sprawdzają zasadniczo tylko `context_differs()`. Nie uruchamiają całego cyklu `plan → review → apply`. 

Brakuje testów:

* plan utworzony przez `terraform`, apply próbuje użyć `tofu`;
* dwa równoległe apply;
* drugi plan kończy się wcześniej niż pierwszy;
* plan podczas trwającego apply;
* discard podczas apply;
* błąd `chmod`;
* executable znika z `PATH`;
* zmiana Account ID;
* zmiana AWS access key przy tym samym profilu;
* niebezpieczny `XDG_RUNTIME_DIR`;
* `TerraformDiscard` dla kilku projektów;
* osobne `plan_args`, `apply_args`, `init_args`.

## Brakujące testy Vault

Testy obecnie obejmują między innymi rozpoznawanie Vaulta, context directory, wykrycie zmiany rozmiaru, parsing inline blocks i konfigurację transparent mode. To wartościowy fundament. 

Należy dodać:

```text
transparent open → VaultRekey
VaultEncryptFile → write → decrypt
trzykrotny :edit! → dokładnie jeden BufWriteCmd
zmiana pliku o tym samym rozmiarze w tej samej sekundzie
błąd fsync
błąd fs_close
błąd rename
hard link
symlink po kolejnym zapisie
niebezpieczny XDG_RUNTIME_DIR
```

### Przykład fake Terraform executable

W teście utwórz plik wykonywalny:

```lua
local fake = vim.fs.joinpath(tmpdir, "terraform")

vim.fn.writefile({
  "#!/bin/sh",
  'printf "%s\n" "$@" >> "$TF_LOG"',
  'case "$1" in',
  "  plan)",
  '    out="${5#-out=}"',
  '    printf "fake-plan" > "$out"',
  "    exit 2",
  "    ;;",
  "  apply)",
  "    sleep 1",
  "    exit 0",
  "    ;;",
  "esac",
}, fake)

vim.uv.fs_chmod(fake, tonumber("700", 8))
```

Dzięki temu można testować lifecycle bez prawdziwej infrastruktury.

---

# 7. Dokumentacja

## `CONTRACT.md`: `tflint` nie zastępuje `terraform validate`

Contract podaje:

```text
validate → tflint running as a language server
```

Jednocześnie kod ma prawdziwe:

```vim
:TerraformValidate
```

wywołujące `terraform validate`. Są to inne kontrole. 

Popraw tabelę:

| Funkcja                | Implementacja                  |
| ---------------------- | ------------------------------ |
| formatowanie           | `terraform_fmt` lub `tofu_fmt` |
| statyczny lint         | `tflint` jako LSP              |
| walidacja konfiguracji | `:TerraformValidate`           |
| inicjalizacja          | `:TerraformInit`               |
| plan/review/apply      | `terraform.nvim`               |

## `AwsClear`

Kod przywraca środowisko początkowe, ale keymap description mówi:

```text
Clear AWS profile and region
```

Powinno być:

```lua
vim.keymap.set(
  "n",
  "<leader>Ac",
  M.clear,
  { desc = "Restore starting AWS environment" }
)
```



## Status własnych modułów

README oznacza Vault i Terraform jako `done`. Ze względu na nierozwiązany rekey oraz lifecycle apply bezpieczniejsze byłoby tymczasowo:

```text
ansible-vault.nvim — beta
terraform.nvim — beta
```

do momentu wdrożenia poprawek P1 i testów integracyjnych.

---

# 8. Warstwa po warstwie

| Warstwa              |  Ocena | Działanie                                                  |
| -------------------- | -----: | ---------------------------------------------------------- |
| Bootstrap/lazy.nvim  |   9/10 | bez zmian                                                  |
| Core options/keymaps |   9/10 | bez zmian                                                  |
| LSP/Mason            |   9/10 | utrzymywać przypięte wersje                                |
| Completion           |   9/10 | bez zmian                                                  |
| Tree-sitter          |   9/10 | rozważyć przypinanie parserów dla pełnej reprodukowalności |
| Formatting           |   8/10 | dodać dynamiczne `tofu_fmt`                                |
| Linting              |   9/10 | bez zmian                                                  |
| Navigation           |   9/10 | bez zmian                                                  |
| UI                   | 8,5/10 | ewentualnie rozdzielić priority Catppuccin/Snacks          |
| Git                  |   9/10 | bez zmian                                                  |
| Kubernetes           | 8,5/10 | rozważyć vendorowanie/pinning schema content               |
| Sessions             | 8,5/10 | bez zmian                                                  |
| AWS                  |   8/10 | udostępnić identity helper dla Terraform                   |
| Vault                |   7/10 | poprawić rekey i zunifikować write path                    |
| Terraform            | 6,5/10 | binary pinning, state machine, AWS identity                |
| Health               |   8/10 | XDG validation, unzip/gzip, OpenTofu                       |
| Testy                |   7/10 | rozszerzyć głównie Terraform                               |
| CI                   |   8/10 | przypiąć Ansible i checksum Selene                         |
| Dokumentacja         |   8/10 | poprawić gwarancje i tabelę validate                       |

---

# 9. Zalecana kolejność wdrożenia

## Commit 1

```text
fix(vault): unify safe write paths and deduplicate writer
```

Zakres:

* `persist_ciphertext()`;
* usunięcie bezpośredniego `writefile()`;
* `nvim_clear_autocmds()`;
* test jednego writera;
* test `VaultEncryptFile → write`.

## Commit 2

```text
fix(vault): redesign rekey credential lifecycle
```

Zakres:

* sprawdzanie pliku na dysku;
* trwałe źródło nowego hasła/Vault ID;
* bezpieczny reload;
* test transparent rekey.

## Commit 3

```text
fix(terraform): pin executable and serialize operations
```

Zakres:

* pełna ścieżka executable w saved plan;
* `run(..., saved.binary)`;
* stan `planning/reviewed/applying`;
* blokada drugiego apply;
* current-project discard.

## Commit 4

```text
fix(terraform): bind plans to AWS caller identity
```

Zakres:

* asynchroniczne STS;
* Account ID i ARN w context;
* ponowne sprawdzenie przed apply;
* test identity drift.

## Commit 5

```text
hardening: validate XDG runtime storage
```

Zakres:

* wspólny `devops.runtime`;
* owner i `0700`;
* osobny katalog aplikacji;
* health check.

## Commit 6

```text
fix(formatting): support OpenTofu formatter
```

Zakres:

* dynamiczne `terraform_fmt`/`tofu_fmt`;
* poprawiony health;
* README: `unzip`, `gzip`.

## Commit 7

```text
test(ci): expand infrastructure safety coverage
```

Zakres:

* fake Terraform;
* concurrency;
* filesystem failures;
* przypięty `ansible-core`;
* checksum Selene.

## Commit 8

```text
docs: align safety guarantees with implementation
```

Zakres:

* Contract;
* README;
* help;
* `AwsClear`;
* `TerraformDiscard`;
* opis saved plan;
* status beta do zakończenia hardeningu.

---

# Podsumowanie

Projekt ma bardzo dobrą warstwę edytorową. Nie wymaga już większego przepisywania pluginów ani reorganizacji katalogów.

Przed uznaniem własnych modułów za stabilne konieczne są cztery rzeczy:

1. jedna, bezpieczna ścieżka zapisu każdego Vaulta;
2. poprawnie zaprojektowany rekey z trwałym źródłem nowego hasła;
3. zserializowany lifecycle Terraform z przypiętym executable;
4. sprawdzenie rzeczywistego konta AWS przed apply.

Po wdrożeniu tych zmian oraz dodaniu testów asynchronicznego cyklu Terraform ocena projektu wzrośnie do około **9/10** i będzie można rozsądnie traktować go jako konfigurację gotową do codziennej pracy z produkcyjną infrastrukturą.

[1]: https://neovim.io/doc/user/api/?utm_source=chatgpt.com "Api - Neovim docs"
[2]: https://specifications.freedesktop.org/basedir/?utm_source=chatgpt.com "XDG Base Directory Specification"
