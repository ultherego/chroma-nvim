-- Tests for the logic that decides whether a secret leaks or an apply runs
-- against the wrong account.
--
-- Deliberately narrow. There is no value in testing that conform formats Lua —
-- conform has its own tests. What is worth testing is the code written here,
-- and specifically the parts where being wrong is expensive:
--
--   * parsing another tool's output, which changes without warning
--   * recognising an encrypted block, which decides whether plaintext is
--     written to disk
--   * detecting that credentials changed between planning and applying
--   * detecting credentials that silently override the selected profile
--
-- Run with:  nvim --headless --noplugin -u tests/minimal_init.lua \
--                 -c "lua MiniTest.run()"

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local T = new_set()

-- ---------------------------------------------------------------------------
-- ansible-config output parsing
-- ---------------------------------------------------------------------------

T["parse_dump"] = new_set()

local parse = function(lines)
  return require("ansible-vault.config").parse_dump(lines)
end

T["parse_dump"]["reads a password file and its source"] = function()
  local r = parse({ "DEFAULT_VAULT_PASSWORD_FILE(/etc/ansible.cfg) = /run/pass" })
  eq(r.password_file, "/run/pass")
  eq(r.source, "/etc/ansible.cfg")
end

T["parse_dump"]["treats None as absent"] = function()
  -- The literal string "None" is what ansible prints for an unset value. Taking
  -- it as a path would make every command look for a file called None.
  local r = parse({ "DEFAULT_VAULT_PASSWORD_FILE(default) = None" })
  eq(r.password_file, nil)
end

T["parse_dump"]["reads an identity list"] = function()
  local r = parse({ "DEFAULT_VAULT_IDENTITY_LIST(/p/ansible.cfg) = ['dev@~/.dev', 'prod@prompt']" })
  eq(r.identities, { "dev@~/.dev", "prod@prompt" })
end

T["parse_dump"]["treats an empty list as no identities"] = function()
  local r = parse({ "DEFAULT_VAULT_IDENTITY_LIST(default) = []" })
  eq(r.identities, {})
end

T["parse_dump"]["reads the encrypt identity"] = function()
  local r = parse({ "DEFAULT_VAULT_ENCRYPT_IDENTITY(/p/ansible.cfg) = dev" })
  eq(r.encrypt_identity, "dev")
end

T["parse_dump"]["ignores unrelated settings"] = function()
  local r = parse({
    "DEFAULT_HOST_LIST(default) = ['/etc/ansible/hosts']",
    "DEFAULT_VAULT_PASSWORD_FILE(default) = None",
    "DEFAULT_TIMEOUT(default) = 10",
  })
  eq(r.password_file, nil)
  eq(r.identities, {})
end

-- ---------------------------------------------------------------------------
-- Recognising an encrypted buffer
-- ---------------------------------------------------------------------------

T["is_encrypted"] = new_set()

local with_lines = function(lines, fn)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local ok, result = pcall(fn, buf)
  vim.api.nvim_buf_delete(buf, { force = true })
  assert(ok, result)
  return result
end

T["is_encrypted"]["recognises a vault header"] = function()
  local r = with_lines({ "$ANSIBLE_VAULT;1.1;AES256", "3363..." }, function(buf)
    return require("ansible-vault")._test.is_encrypted(buf)
  end)
  eq(r, true)
end

T["is_encrypted"]["recognises a labelled 1.2 header"] = function()
  -- Multiple vault ids produce format 1.2 with the label appended. Missing
  -- this would mean transparent editing silently skipped those files.
  local r = with_lines({ "$ANSIBLE_VAULT;1.2;AES256;dev" }, function(buf)
    return require("ansible-vault")._test.is_encrypted(buf)
  end)
  eq(r, true)
end

T["is_encrypted"]["says no for plain YAML"] = function()
  local r = with_lines({ "---", "key: value" }, function(buf)
    return require("ansible-vault")._test.is_encrypted(buf)
  end)
  eq(r, false)
end

T["is_encrypted"]["says no for an empty buffer"] = function()
  local r = with_lines({}, function(buf)
    return require("ansible-vault")._test.is_encrypted(buf)
  end)
  eq(r, false)
end

-- ---------------------------------------------------------------------------
-- Where ansible.cfg is looked for
-- ---------------------------------------------------------------------------

T["context_dir"] = new_set()

T["context_dir"]["returns a string for a buffer"] = function()
  -- The regression this guards against: callers were changed to pass a buffer
  -- while the function they called still took a directory, so a buffer number
  -- reached vim.system as its cwd. It failed as a notification about ansible
  -- rather than as a type error, which hid it completely.
  local r = with_lines({ "---" }, function(buf)
    return require("ansible-vault")._test.context_dir(buf)
  end)
  eq(type(r), "string")
end

T["context_dir"]["falls back to the working directory for an unnamed buffer"] = function()
  local r = with_lines({}, function(buf)
    return require("ansible-vault")._test.context_dir(buf)
  end)
  eq(r, vim.fn.getcwd())
end

T["context_dir"]["rejects a non-string cwd at the process boundary"] = function()
  -- The other half of the same guard: even if a caller gets it wrong again,
  -- the failure should look like a contract violation, not like ansible.
  local cli = require("ansible-vault.cli")
  MiniTest.expect.error(function()
    cli.decrypt_string("$ANSIBLE_VAULT;1.1;AES256", { cwd = 7 })
  end, "cwd must be a string")
end

-- ---------------------------------------------------------------------------
-- Finding the inline !vault block under the cursor
-- ---------------------------------------------------------------------------

T["block_at"] = new_set()

local block_at = function(lines, lnum)
  return with_lines(lines, function(buf)
    return require("ansible-vault")._test.block_at(buf, lnum)
  end)
end

local inline = {
  "---",
  "db_user: admin",
  "db_password: !vault |",
  "          $ANSIBLE_VAULT;1.1;AES256",
  "          3536653363",
  "          6462376364",
  "other: value",
}

T["block_at"]["finds the block from its key line"] = function()
  local b = block_at(inline, 3)
  eq(b.key, "db_password")
  eq(b.first, 3)
  eq(b.last, 6)
end

T["block_at"]["finds the block from inside the ciphertext"] = function()
  local b = block_at(inline, 5)
  eq(b.key, "db_password")
  eq(b.first, 3)
end

T["block_at"]["strips the indentation from the ciphertext"] = function()
  -- ansible-vault will not decrypt a block that still carries its YAML
  -- indentation, so this is the difference between working and not.
  local b = block_at(inline, 4)
  eq(b.ciphertext:sub(1, 14), "$ANSIBLE_VAULT")
  eq(b.ciphertext:find("\n          "), nil)
end

T["block_at"]["stops at the next key"] = function()
  local b = block_at(inline, 3)
  eq(b.last, 6)
end

T["block_at"]["returns nothing away from a block"] = function()
  eq(block_at(inline, 2), nil)
end

T["block_at"]["returns nothing for a !vault tag with no ciphertext"] = function()
  eq(block_at({ "key: !vault |", "next: value" }, 1), nil)
end

-- ---------------------------------------------------------------------------
-- Noticing that the file changed underneath us
-- ---------------------------------------------------------------------------

T["file_changed_since_read"] = new_set()

local with_file = function(contents, fn)
  local path = vim.fn.tempname()
  vim.fn.writefile(vim.split(contents, "\n"), path)

  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, path)

  local ok, result = pcall(fn, buf, path)

  vim.api.nvim_buf_delete(buf, { force = true })
  os.remove(path)
  assert(ok, result)
  return result
end

local vault = function()
  return require("ansible-vault")._test
end

T["file_changed_since_read"]["says nothing when the file is untouched"] = function()
  local r = with_file("one\ntwo", function(buf)
    vault().remember_file_state(buf)
    return vault().file_changed_since_read(buf)
  end)
  eq(r, nil)
end

T["file_changed_since_read"]["notices a changed size"] = function()
  -- Vault buffers carry 'noswapfile' and a BufWriteCmd, which between them
  -- remove both of Neovim's protections against two editors clobbering each
  -- other. This is the replacement, so it has to actually fire.
  local r = with_file("one\ntwo", function(buf, path)
    vault().remember_file_state(buf)
    vim.fn.writefile({ "one", "two", "three", "four" }, path)
    return vault().file_changed_since_read(buf)
  end)
  eq(type(r), "string")
end

T["file_changed_since_read"]["notices a removed file"] = function()
  local r = with_file("one", function(buf, path)
    vault().remember_file_state(buf)
    os.remove(path)
    return vault().file_changed_since_read(buf)
  end)
  eq(r, "the file has been removed")
end

T["file_changed_since_read"]["says nothing when no state was remembered"] = function()
  -- Buffers this plugin never decrypted must write normally.
  local r = with_file("one", function(buf)
    return vault().file_changed_since_read(buf)
  end)
  eq(r, nil)
end

-- ---------------------------------------------------------------------------
-- Encrypting a range, not whatever was selected last
-- ---------------------------------------------------------------------------

T["encrypt_selection"] = new_set()

local capture_notify = function(fn)
  local notified
  local original = vim.notify
  vim.notify = function(msg)
    notified = msg
  end
  pcall(fn)
  vim.notify = original
  return notified
end

T["encrypt_selection"]["refuses without a range"] = function()
  -- It used to read the '< and '> marks, which outlive the selection that set
  -- them. Invoking it from normal mode then encrypted whatever had last been
  -- selected, wherever the cursor was — leaving the value you meant to protect
  -- in the clear and encrypting an unrelated one instead.
  local notified = capture_notify(require("ansible-vault").encrypt_selection)
  eq(type(notified), "string")
  eq(notified:find("needs a range") ~= nil, true)
end

T["encrypt_selection"]["refuses when the range is empty"] = function()
  local notified = capture_notify(function()
    require("ansible-vault").encrypt_selection({ range = 0, line1 = 1, line2 = 1 })
  end)
  eq(notified:find("needs a range") ~= nil, true)
end

-- ---------------------------------------------------------------------------
-- setup() options actually take effect
-- ---------------------------------------------------------------------------

T["setup"] = new_set({
  hooks = {
    -- Leave the suite in the state the configuration expects.
    post_once = function()
      require("ansible-vault").setup({ transparent = true })
    end,
  },
})

local transparent_autocmds = function()
  local ok, cmds = pcall(vim.api.nvim_get_autocmds, { group = "ansible_vault_transparent" })
  return ok and #cmds or 0
end

T["setup"]["registers transparent editing when asked"] = function()
  require("ansible-vault").setup({ transparent = true })
  eq(transparent_autocmds() > 0, true)
end

T["setup"]["removes it when asked, even after enabling"] = function()
  -- The bug this guards against: only the enabling branch touched the augroup,
  -- so a later setup with transparent = false left the earlier autocmds in
  -- place. The option looked respected and was not — which quietly invalidated
  -- every test that thought it had transparent editing switched off.
  require("ansible-vault").setup({ transparent = true })
  require("ansible-vault").setup({ transparent = false })
  eq(transparent_autocmds(), 0)
end

-- ---------------------------------------------------------------------------
-- Credential drift between plan and apply
-- ---------------------------------------------------------------------------

T["context_differs"] = new_set()

local differs = function(a, b)
  return require("terraform")._test.context_differs(a, b)
end

T["context_differs"]["accepts an unchanged context"] = function()
  eq(differs({ profile = "prod", region = "eu-west-1" }, { profile = "prod", region = "eu-west-1" }), nil)
end

T["context_differs"]["rejects a changed profile"] = function()
  local d = differs({ profile = "prod", region = "eu-west-1" }, { profile = "dev", region = "eu-west-1" })
  eq(type(d), "string")
  eq(d:find("prod") ~= nil, true)
  eq(d:find("dev") ~= nil, true)
end

T["context_differs"]["rejects a changed region"] = function()
  local d = differs({ profile = "prod", region = "eu-west-1" }, { profile = "prod", region = "us-east-1" })
  eq(type(d), "string")
  eq(d:find("region") ~= nil, true)
end

T["context_differs"]["rejects a profile that appeared"] = function()
  -- Planning with no profile and applying with one is the same hazard in the
  -- other direction, and nil comparisons are easy to get wrong.
  eq(type(differs({}, { profile = "prod" })), "string")
end

T["context_differs"]["rejects a profile that disappeared"] = function()
  eq(type(differs({ profile = "prod" }, {})), "string")
end

T["context_differs"]["accepts two empty contexts"] = function()
  eq(differs({}, {}), nil)
end

-- ---------------------------------------------------------------------------
-- Credentials that override the selected AWS profile
-- ---------------------------------------------------------------------------

T["overriding_credentials"] = new_set({
  hooks = {
    pre_case = function()
      for _, name in ipairs({ "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN" }) do
        vim.env[name] = nil
      end
    end,
    post_case = function()
      for _, name in ipairs({ "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN" }) do
        vim.env[name] = nil
      end
    end,
  },
})

local overriding = function()
  return require("aws")._test.overriding_credentials()
end

T["overriding_credentials"]["finds nothing in a clean environment"] = function()
  eq(overriding(), {})
end

T["overriding_credentials"]["finds static keys"] = function()
  vim.env.AWS_ACCESS_KEY_ID = "AKIAEXAMPLE"
  eq(overriding(), { "AWS_ACCESS_KEY_ID" })
end

T["overriding_credentials"]["finds several at once"] = function()
  vim.env.AWS_ACCESS_KEY_ID = "AKIAEXAMPLE"
  vim.env.AWS_SESSION_TOKEN = "token"
  eq(#overriding(), 2)
end

T["overriding_credentials"]["ignores an empty value"] = function()
  -- An exported-but-empty variable does not override anything, and reporting
  -- it would train the user to ignore the warning.
  vim.env.AWS_ACCESS_KEY_ID = ""
  eq(overriding(), {})
end

return T
