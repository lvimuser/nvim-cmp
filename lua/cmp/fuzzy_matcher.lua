-- https://github.com/forrestthewoods/lib_fts/blob/master/code/fts_fuzzy_match.js

local function copy(t)
  local t2 = {}
  for k, v in ipairs(t) do
    t2[k] = v
  end
  return t2
end

local M = {}

---@type function
M.debug = function(...)
  return ...
end

local cache = require('cmp.utils.cache').new()

local function smart_case(input, word)
  -- if input:match('[A-Z]') then
  --   return input, word
  -- end

  return string.lower(input), string.lower(word)
end

local function fuzzy_match(prefix, word)
  prefix, word = smart_case(prefix, word)
  local score = require('cmp.utils.fuzzy_score').fuzzy_score(prefix, word)
  return score < 1
end

local fill_matches = function(start, _end, fuzzy)
  return {
    fuzzy = fuzzy or false,
    input_match_start = start + 1,
    input_match_end = _end + 1,

    word_match_start = start + 1,
    word_match_end = _end + 1,
  }
end

local function substring_match(prefix, word)
  prefix, word = smart_case(prefix, word)
  local i, j = string.find(word, prefix, 1, true)
  local matches = (i and j) and fill_matches(i, j)
  if matches then
    return true, nil, matches
  else
    return false
  end
end

local function exact_match(prefix, word)
  prefix, word = smart_case(prefix, word)
  if vim.startswith(word, prefix) then
    return true, nil, fill_matches(1, #prefix)
  else
    return false
  end
end

local matching_strategy = {
  fuzzy = fuzzy_match,
  substring = substring_match,
  exact = exact_match,
}

M.matching = function(input, word)
  local matcher_list = { 'exact', 'substring', 'fuzzy' }
  local matching_priority = 2

  if #input == 0 then
    return 1, {}
  end

  local r = cache:ensure('matching' .. input .. word, function()
    for i, method in ipairs(matcher_list) do
      local is_match, score, matches = matching_strategy[method](input, word)
      if is_match then
        score = ((score or 1) + 20) + 20 * (matching_priority - i)

        return { score, matches or {} }
      end
    end

    return { 0, {} }
  end)

  return unpack(r)
end

M.amatch = function(input, word)
  return unpack(cache:ensure('matchfuzzypos' .. input .. word, function()
    -- for manual completion
    if #input == 0 then
      return { 1, {} }
    end

    -- do not attempt to fully match long words
    if #input <= 40 and #word > 72 then
      word = word:sub(1, 72)
    end

    -- input does not contain a single alphanumeric char
    if not input:match('%w') then
      if not word:match('%W') then
        -- word contains only alphanumeric chars
        return { 0, {} }
      end
    end

    input, word = smart_case(input, word)

    -- input with repeating chars may lag with whenever we also have a long
    -- repeating word (mostly tabnine). If the first n suggestion chars are
    -- equal, attempt to match only these chars
    local l = 4
    if #word >= l then
      local repeating = true
      for i = 2, l do
        if word:sub(i, i) ~= word:sub(i - 1, i - 1) then
          repeating = false
          break
        end
      end

      if repeating then
        word = word:sub(1, l)
      end
    end

    local _, matches, score = unpack(vim.fn.matchfuzzypos({ word }, input))
    score = math.max(score[1] or 0, 0)
    matches = matches and matches[1]

    local tmp = {}
    local cmp_matches = {}
    if score > 0 and matches then
      for i, v in ipairs(matches) do
        table.insert(tmp, v)

        local _next = matches[i + 1]
        if _next ~= v + 1 then
          local s, e = tmp[1] + 1, tmp[#tmp] + 1
          table.insert(cmp_matches, {
            input_match_start = s,
            input_match_end = e,
            word_match_start = s,
            word_match_end = e,
          })

          tmp = {}
        end
      end
    end

    return { score, cmp_matches }
  end))
end

M.match = M.amatch

return M
