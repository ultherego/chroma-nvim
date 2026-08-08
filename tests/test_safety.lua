-- Tests for the logic that decides whether a secret leaks or an apply runs
-- against the wrong account.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local T = new_set()

-- ---------------------------------------------------------------------------
-- ansible-config output parsing

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

T["context_dir"] = new_set()

T["context_dir"]["returns a string for a buffer"] = function()
  -- The regression this guards against: a buffer number reached vim.system as its
  -- cwd, and the failure read like an ansible problem.
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

-- Regression: the scan's exception for the cursor's own line also let the first
-- line after a block resolve to the block above it.
local bounded = {
  "secret: !vault |", -- 1
  "  $ANSIBLE_VAULT;1.2;AES256", -- 2
  "  123456", -- 3
  "normal: hello", -- 4
  "another: value", -- 5
}

T["block_at"]["finds the block from its marker line"] = function()
  local b = block_at(bounded, 1)
  eq(b.first, 1)
  eq(b.last, 3)
end

T["block_at"]["finds the block from the first ciphertext line"] = function()
  eq(block_at(bounded, 2).first, 1)
end

T["block_at"]["finds the block from the last ciphertext line"] = function()
  eq(block_at(bounded, 3).first, 1)
end

T["block_at"]["returns nothing on the first line after a block"] = function()
  eq(block_at(bounded, 4), nil)
end

T["block_at"]["returns nothing on the second line after a block"] = function()
  eq(block_at(bounded, 5), nil)
end

-- With a block on either side, a plain line between them belongs to neither.
T["block_at"]["returns nothing between two blocks"] = function()
  local between = {
    "first: !vault |", -- 1
    "  $ANSIBLE_VAULT;1.2;AES256", -- 2
    "  aaa", -- 3
    "plain: value", -- 4
    "second: !vault |", -- 5
    "  $ANSIBLE_VAULT;1.2;AES256", -- 6
    "  bbb", -- 7
  }

  eq(block_at(between, 4), nil)
  eq(block_at(between, 1).key, "first")
  eq(block_at(between, 5).key, "second")
  eq(block_at(between, 7).key, "second")
end

-- ---------------------------------------------------------------------------
-- Exactly one write hook per buffer

T["attach_writer"] = new_set()

local writers_for = function(buf)
  local ok, cmds = pcall(vim.api.nvim_get_autocmds, {
    group = "ansible_vault_writer",
    event = "BufWriteCmd",
    buffer = buf,
  })
  return ok and #cmds or 0
end

T["attach_writer"]["attaches one"] = function()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, vim.fn.tempname())

  require("ansible-vault").attach_writer(buf)
  local n = writers_for(buf)

  vim.api.nvim_buf_delete(buf, { force = true })
  eq(n, 1)
end

T["attach_writer"]["stays at one across repeated attaches"] = function()
  -- A buffer is decrypted again on every `:edit!`, and each decrypt attaches.
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, vim.fn.tempname())

  for _ = 1, 3 do
    require("ansible-vault").attach_writer(buf)
  end
  local n = writers_for(buf)

  vim.api.nvim_buf_delete(buf, { force = true })
  eq(n, 1)
end

-- ---------------------------------------------------------------------------
-- Noticing that the file changed underneath us

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
  -- Vault buffers carry 'noswapfile' and a BufWriteCmd, which between them remove
  -- both of Neovim's protections against two editors clobbering each other.
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

-- "There was no file" is a baseline, not the absence of one. Storing nil for it
-- made it indistinguishable from a buffer this plugin never touched, so a file
-- that appeared in between was written over rather than refused.
T["file_changed_since_read"]["notices a file that appeared where there was none"] = function()
  local r = with_file("one", function(buf, path)
    os.remove(path)
    vault().remember_file_state(buf)
    vim.fn.writefile({ "written by somebody else" }, path)
    return vault().file_changed_since_read(buf)
  end)
  eq(r, "a file has appeared on disk since this buffer was converted")
end

T["file_changed_since_read"]["says nothing when the file is still absent"] = function()
  local r = with_file("one", function(buf, path)
    os.remove(path)
    vault().remember_file_state(buf)
    return vault().file_changed_since_read(buf)
  end)
  eq(r, nil)
end

T["file_changed_since_read"]["says nothing when no state was remembered"] = function()
  -- Buffers this plugin never decrypted must write normally.
  local r = with_file("one", function(buf)
    return vault().file_changed_since_read(buf)
  end)
  eq(r, nil)
end

-- The fingerprint was whole seconds and size, and this is what that missed: a
-- second writer landing inside the same second with a file of the same length.
T["file_changed_since_read"]["notices a same-second change of the same size"] = function()
  local r = with_file("aaaa", function(buf, path)
    vault().remember_file_state(buf)
    local before = vim.uv.fs_stat(path)
    vim.fn.writefile({ "bbbb" }, path)
    local after = vim.uv.fs_stat(path)

    -- If the filesystem did not actually reproduce the conditions, the case
    -- proves nothing and says so rather than passing for the wrong reason.
    if before.mtime.sec ~= after.mtime.sec or before.size ~= after.size then
      MiniTest.skip("the filesystem separated two immediate writes by second or size")
    end

    return vault().file_changed_since_read(buf)
  end)
  eq(type(r), "string")
end

-- A careful writer replaces a file rather than rewriting it: a new inode, carrying
-- any timestamp it likes, which nanoseconds alone would miss.
T["file_changed_since_read"]["notices an atomic replacement with the timestamp restored"] = function()
  local r = with_file("one", function(buf, path)
    vault().remember_file_state(buf)
    local before = vim.uv.fs_stat(path)

    vim.fn.writefile({ "one" }, path .. ".new")
    vim.uv.fs_rename(path .. ".new", path)
    vim.uv.fs_utime(path, before.atime.sec, before.mtime.sec)

    return vault().file_changed_since_read(buf)
  end)
  eq(r, "the file has been replaced on disk since it was read")
end

-- ---------------------------------------------------------------------------
-- Atomic replacement refuses to break hard links

T["write_atomically"] = new_set()

T["write_atomically"]["writes a file with one link"] = function()
  local path = vim.fn.tempname()
  vim.fn.writefile({ "before" }, path)

  local ok, err = vault().write_atomically(path, "after\n")

  eq(ok, true)
  eq(err, nil)
  eq(vim.fn.readfile(path)[1], "after")
  os.remove(path)
end

-- rename() replaces one name. Every other name for that inode keeps the old
-- contents, so saving through one of them leaves the others quietly stale.
T["write_atomically"]["refuses a file with more than one link"] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local first, second = dir .. "/a", dir .. "/b"
  vim.fn.writefile({ "shared" }, first)
  vim.uv.fs_link(first, second)

  local ok, err = vault().write_atomically(first, "replaced\n")

  eq(ok, false)
  eq(err:match("2 hard links") ~= nil, true)
  eq(err:match("saveas") ~= nil, true)
  -- Neither name may have moved.
  eq(vim.fn.readfile(first)[1], "shared")
  eq(vim.fn.readfile(second)[1], "shared")
  vim.fn.delete(dir, "rf")
end

T["write_atomically"]["leaves no temporary file behind when it refuses"] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({ "shared" }, dir .. "/a")
  vim.uv.fs_link(dir .. "/a", dir .. "/b")

  vault().write_atomically(dir .. "/a", "replaced\n")

  eq(#vim.fn.glob(dir .. "/*.tmp", false, true), 0)
  vim.fn.delete(dir, "rf")
end

-- ---------------------------------------------------------------------------
-- Encrypting a range, not whatever was selected last

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
  -- It used to read the '< and '> marks, which outlive their selection, so from
  -- normal mode it encrypted whatever had last been selected.
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
  -- The bug this guards against: only the enabling branch touched the augroup, so
  -- `transparent = false` left the earlier autocmds in place.
  require("ansible-vault").setup({ transparent = true })
  require("ansible-vault").setup({ transparent = false })
  eq(transparent_autocmds(), 0)
end

-- ---------------------------------------------------------------------------
-- Credential drift between plan and apply

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

-- ---------------------------------------------------------------------------
-- What :AwsClear puts back

local saved = {}

T["starting environment"] = new_set({
  hooks = {
    pre_case = function()
      saved.profile = vim.env.AWS_PROFILE
      saved.region = vim.env.AWS_REGION
      saved.default_region = vim.env.AWS_DEFAULT_REGION
      saved.notify = vim.notify
      vim.notify = function() end
      -- A module that has never been set up, so this case decides what starting means.
      require("aws")._test.forget_initial_environment()
    end,
    post_case = function()
      vim.env.AWS_PROFILE = saved.profile
      vim.env.AWS_REGION = saved.region
      vim.env.AWS_DEFAULT_REGION = saved.default_region
      vim.notify = saved.notify
      require("aws")._test.forget_initial_environment()
    end,
  },
})

-- Regression: setup recaptured the environment every time it ran. A second call —
-- a re-sourced config, a lazy reload — happens after profiles have been switched,
-- so "restore what Neovim started with" restored the profile switched to instead.
T["starting environment"]["survives a second setup"] = function()
  local aws = require("aws")

  vim.env.AWS_PROFILE = "started-as"
  vim.env.AWS_REGION = "eu-central-1"
  vim.env.AWS_DEFAULT_REGION = "eu-central-1"
  aws.setup({})

  -- What :AwsProfile and :AwsRegion do.
  vim.env.AWS_PROFILE = "switched-to"
  vim.env.AWS_REGION = "us-east-1"
  vim.env.AWS_DEFAULT_REGION = "us-east-1"

  aws.setup({})
  aws.clear()

  eq(vim.env.AWS_PROFILE, "started-as")
  eq(vim.env.AWS_REGION, "eu-central-1")
  eq(vim.env.AWS_DEFAULT_REGION, "eu-central-1")
end

-- Starting with nothing exported is a starting environment too, and restoring it
-- means unsetting rather than leaving the last choice in place.
T["starting environment"]["restores an environment that was empty"] = function()
  local aws = require("aws")

  vim.env.AWS_PROFILE = nil
  vim.env.AWS_REGION = nil
  vim.env.AWS_DEFAULT_REGION = nil
  aws.setup({})

  vim.env.AWS_PROFILE = "switched-to"
  vim.env.AWS_REGION = "us-east-1"
  aws.setup({})
  aws.clear()

  eq(vim.env.AWS_PROFILE, nil)
  eq(vim.env.AWS_REGION, nil)
end

return T
