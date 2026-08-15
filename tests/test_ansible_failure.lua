-- What a failed inspection shows, with real windows — and the one thing that
-- must never happen again: a subprocess's output travelling through a picker.
--
-- The defect this suite was written against passed every test there was. The
-- planner handed Ansible's output to `vim.ui.select` as the prompt of the menu
-- offering the way onwards, and a test asserted that the output was in a
-- prompt — which it was. What the operator saw was `Tag inspection failed` and
-- four choices, because the `vim.ui.select` Chroma ships is fzf-lua's and a
-- prompt there is one line of an fzf command line.
--
-- So the assertions here are in two halves, and the second half is the one that
-- kills it: every line on the screen §16 promises, and **none of them** in the
-- question that follows.
--
-- `doc/chroma-ansible-design.md` §16, and §7.4 for why a prompt is the wrong
-- place regardless of how many lines it can hold.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local ansible = require("chroma-ansible")
local failure = require("chroma-ansible.failure")
local inspect = require("chroma-ansible.inspect")
local planner = require("chroma-ansible.planner")

--- Four lines, one of which is the whole point: it is the sort of thing Ansible
--- puts in a diagnostic, and it must reach the operator without reaching
--- another process's argument vector.
local SENTINEL = table.concat({
  "ERROR-FIRST",
  "detail second line",
  "SECRET-SENTINEL-THAT-MUST-NOT-REACH-FZF",
  "ERROR-LAST",
}, "\n")

local HEADLINE = "Tag inspection failed"

---The floating windows, which in this suite are this module's.
---@return integer[]
local function floats()
  local found = {}
  for _, window in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(window).relative ~= "" then
      table.insert(found, window)
    end
  end
  return found
end

---The buffer-local normal-mode mapping for `key`, or nil.
---@param buffer integer
---@param key string
---@return table|nil
local function mapping(buffer, key)
  local want = vim.api.nvim_replace_termcodes(key, true, true, true)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buffer, "n")) do
    if vim.api.nvim_replace_termcodes(map.lhs, true, true, true) == want then
      return map
    end
  end
  return nil
end

---Opens one view and counts each answer it reports.
---@param detail string|nil
---@return { close: fun() }, { proceeded: integer, cancelled: integer }
local function opened(detail)
  local answers = { proceeded = 0, cancelled = 0 }
  local handle = failure.open(HEADLINE, detail or SENTINEL, function()
    answers.proceeded = answers.proceeded + 1
  end, function()
    answers.cancelled = answers.cancelled + 1
  end)
  return handle, answers
end

---What the view is showing.
---@return string[]
local function on_screen()
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(floats()[1]), 0, -1, false)
end

local T = new_set({
  hooks = {
    post_case = function()
      for _, window in ipairs(floats()) do
        pcall(vim.api.nvim_win_close, window, true)
      end
    end,
  },
})

-- ---------------------------------------------------------------------------
-- What is on it

T["the view"] = new_set()

T["the view"]["holds every line Ansible said, in the order it said them"] = function()
  opened()

  -- Whole: the headline, a blank, and then the four lines exactly as they came.
  eq(on_screen(), {
    HEADLINE,
    "",
    "ERROR-FIRST",
    "detail second line",
    "SECRET-SENTINEL-THAT-MUST-NOT-REACH-FZF",
    "ERROR-LAST",
  })
end

T["the view"]["is taller than the window when the output is"] = function()
  -- §16 forbids truncating, not scrolling. A hundred lines are a hundred lines
  -- in the buffer however few of them fit on the screen at once.
  local many = {}
  for index = 1, 100 do
    table.insert(many, ("line %d"):format(index))
  end
  opened(table.concat(many, "\n"))

  local lines = on_screen()
  eq(#lines, 102)
  eq(lines[102], "line 100")
  eq(vim.api.nvim_win_get_height(floats()[1]) < 102, true)
end

T["the view"]["is a scratch buffer that leaves nothing behind"] = function()
  opened()
  local buffer = vim.api.nvim_win_get_buf(floats()[1])

  eq({
    buftype = vim.bo[buffer].buftype,
    bufhidden = vim.bo[buffer].bufhidden,
    swapfile = vim.bo[buffer].swapfile,
    listed = vim.bo[buffer].buflisted,
    modifiable = vim.bo[buffer].modifiable,
  }, {
    buftype = "nofile",
    bufhidden = "wipe",
    swapfile = false,
    listed = false,
    modifiable = false,
  })
end

T["the view"]["is entered, because it is asking rather than reporting"] = function()
  -- The opposite of the progress window on purpose: this one is a question,
  -- and the keys that answer it have to be reachable without hunting for the
  -- window they belong to.
  opened()

  eq(vim.api.nvim_get_current_win(), floats()[1])
end

-- ---------------------------------------------------------------------------
-- The two doors, as everywhere else in this module

T["closing"] = new_set()

T["closing"]["takes the view away without answering for anybody"] = function()
  -- The run was superseded. Nothing was chosen and nothing was refused.
  local handle, answers = opened()

  handle.close()

  eq(#floats(), 0)
  eq(answers, { proceeded = 0, cancelled = 0 })
end

T["closing"]["twice is not two events"] = function()
  local handle, answers = opened()

  handle.close()
  handle.close()

  eq(answers, { proceeded = 0, cancelled = 0 })
end

T["answering"] = new_set()

T["answering"]["with Enter leads on and takes the view away"] = function()
  local _, answers = opened()

  mapping(vim.api.nvim_win_get_buf(floats()[1]), "<CR>").callback()

  eq(answers, { proceeded = 1, cancelled = 0 })
  eq(#floats(), 0)
end

T["answering"]["with a refusal ends the run"] = new_set({
  parametrize = { { "<Esc>" }, { "q" } },
})

T["answering"]["with a refusal ends the run"][""] = function(key)
  local _, answers = opened()

  local bound = mapping(vim.api.nvim_win_get_buf(floats()[1]), key)
  eq({ key, bound ~= nil }, { key, true })

  bound.callback()

  eq(answers, { proceeded = 0, cancelled = 1 })
end

T["answering"]["is what the view going away any other way means"] = new_set({
  parametrize = { { "window" }, { "buffer" } },
})

T["answering"]["is what the view going away any other way means"][""] = function(how)
  local _, answers = opened()
  local window = floats()[1]
  local buffer = vim.api.nvim_win_get_buf(window)

  if how == "window" then
    vim.api.nvim_win_close(window, true)
  else
    vim.api.nvim_buf_delete(buffer, { force = true })
  end

  eq(answers, { proceeded = 0, cancelled = 1 })
end

T["answering"]["once is once, however many ways it then unwinds"] = function()
  -- Every answer closes the window, and the window closing is itself one of the
  -- ways an answer is reported.
  local _, answers = opened()

  mapping(vim.api.nvim_win_get_buf(floats()[1]), "<CR>").callback()

  eq(answers, { proceeded = 1, cancelled = 0 })
end

-- ---------------------------------------------------------------------------
-- Through the planner, which is where the defect lived

local WORKING, PLAYBOOK = (function()
  local path = vim.fn.tempname()
  vim.fn.mkdir(path, "p")
  vim.fn.writefile({ "[defaults]" }, vim.fs.joinpath(path, "ansible.cfg"))
  local playbook = vim.fs.joinpath(path, "site_upgrade.yml")
  vim.fn.writefile({ "- hosts: all" }, playbook)
  return vim.uv.fs_realpath(path), playbook
end)()

local saved, prompts, script

--- The answers that get the planner as far as the tag inspection, which fails:
--- the playbook, the path to it, the working directory, and no `-i` at all.
local TO_THE_FAILURE = { "Choose another", PLAYBOOK, WORKING, "Use Ansible configuration" }

T["a failed inspection"] = new_set({
  hooks = {
    pre_case = function()
      planner.forget()
      prompts, script = {}, vim.deepcopy(TO_THE_FAILURE)
      saved = {
        select = vim.ui.select,
        input = vim.ui.input,
        tool = inspect.tool,
        tags = inspect.tags,
        notify = vim.notify,
        open = failure.open,
      }

      vim.ui.select = function(items, opts, on_choice)
        table.insert(prompts, opts.prompt)
        local want = table.remove(script, 1)
        for _, item in ipairs(items) do
          if want and item.label:find(want, 1, true) then
            return on_choice(item)
          end
        end
        on_choice(nil)
      end
      vim.ui.input = function(opts, on_confirm)
        table.insert(prompts, opts.prompt)
        on_confirm(table.remove(script, 1))
      end

      inspect.tool = function()
        return vim.fn.exepath("sh")
      end
      inspect.tags = function(_, on_done)
        on_done({ problem = SENTINEL })
      end
      vim.notify = function() end
    end,
    post_case = function()
      vim.ui.select, vim.ui.input = saved.select, saved.input
      inspect.tool, inspect.tags = saved.tool, saved.tags
      vim.notify, failure.open = saved.notify, saved.open
      for _, window in ipairs(floats()) do
        pcall(vim.api.nvim_win_close, window, true)
      end
      planner.forget()
    end,
  },
})

---Whether any prompt held this text.
---@param text string
---@return boolean
local function asked(text)
  for _, prompt in ipairs(prompts) do
    if prompt and prompt:find(text, 1, true) then
      return true
    end
  end
  return false
end

T["a failed inspection"]["stops at the view before it asks anything"] = function()
  local before = #prompts

  ansible.plan()

  -- The view is up and no menu has been offered yet: the operator reads first
  -- and chooses second.
  eq(#floats(), 1)
  eq(#prompts, before + 4)
  eq(asked(HEADLINE), false)
end

T["a failed inspection"]["shows every line Ansible said"] = function()
  ansible.plan()

  eq(on_screen(), {
    HEADLINE,
    "",
    "ERROR-FIRST",
    "detail second line",
    "SECRET-SENTINEL-THAT-MUST-NOT-REACH-FZF",
    "ERROR-LAST",
  })
end

T["a failed inspection"]["asks its question with none of that output in it"] = function()
  ansible.plan()
  table.insert(script, "Cancel")

  mapping(vim.api.nvim_win_get_buf(floats()[1]), "<CR>").callback()

  -- The whole finding, as an assertion: the menu is asked, and what Ansible
  -- said is not in it. A prompt reaches another process's argument vector
  -- (§7.4); the view reaches nothing outside this editor.
  eq(asked(HEADLINE), true)
  for _, line in ipairs(vim.split(SENTINEL, "\n", { plain = true })) do
    eq({ line, asked(line) }, { line, false })
  end
end

T["a failed inspection"]["ends the run when the view is refused"] = function()
  ansible.plan()
  local asked_before = #prompts

  mapping(vim.api.nvim_win_get_buf(floats()[1]), "q").callback()

  -- No menu after it, and nothing left on the screen.
  eq(#prompts, asked_before)
  eq(#floats(), 0)
end

T["a failed inspection"]["opens nothing once the operator has moved on"] = function()
  -- The view can outlive its run: superseding closes it, and an answer that was
  -- already on its way must not walk a run nobody is in as far as a menu.
  local proceed
  failure.open = function(_, _, on_proceed)
    proceed = on_proceed
    return { close = function() end }
  end
  ansible.plan()
  local asked_before = #prompts

  planner.supersede()
  proceed()

  eq(#prompts, asked_before)
end

T["a failed inspection"]["takes its view down when the run is superseded"] = function()
  ansible.plan()

  planner.supersede()

  -- Closed by the run ending, and not counted as an answer: no menu followed.
  eq(#floats(), 0)
  eq(asked(HEADLINE), false)
end

return T
