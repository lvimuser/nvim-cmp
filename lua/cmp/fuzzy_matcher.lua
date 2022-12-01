-- https://github.com/forrestthewoods/lib_fts/blob/master/code/fts_fuzzy_match.js

local function copy(t)
  local t2 = {}
  for k, v in ipairs(t) do
    t2[k] = v
  end
  return t2
end

local function put(...)
  local objects = {}
  for i = 1, select('#', ...) do
    local v = select(i, ...)
    table.insert(objects, vim.inspect(v))
  end

  print(table.concat(objects, '\n'))
  return ...
end

local M = {}

---@type function
M.debug = function(...)
  return ...
end

local trim = function(s)
  return s:match('^%s*(.*)') or ''
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
  if score < 1 then
    return true, 1
  else
    return false
  end
end

local function substring_match(prefix, word)
  prefix, word = smart_case(prefix, word)
  local matches = { string.find(word, prefix, 1, true) }
  if matches and #matches > 0 then
    return true, nil, matches
  else
    return false
  end
end

local fill_matches = function(len)
  return cache:ensure({ 'fill_matchees', len }, function()
    local t = {}
    for i = 1, len do
      t[i] = i
    end
    return t
  end)
end

local function exact_match(prefix, word)
  prefix, word = smart_case(prefix, word)
  if vim.startswith(word, prefix) then
    return true, nil, fill_matches(#prefix)
  else
    return false
  end
end

local function all_match()
  return true
end

local matching_strategy = {
  fuzzy = fuzzy_match,
  substring = substring_match,
  exact = exact_match,
  all = all_match,
}

M.matching = function(input, word)
  local matcher_list = { 'exact', 'substring', 'fuzzy' }
  local matching_priority = 2

  return cache:ensure({ 'matching', input, word }, function()
    for i, method in ipairs(matcher_list) do
      local is_match, score, matches = matching_strategy[method](input, word)
      if is_match then
        score = (score or 1) + 20 * (matching_priority - i + 1)
        return score, matches or {}
      end
    end

    return 0, {}
  end)
end

M.amatch = function(input, word)
  return cache:ensure({ 'matchfuzzypos', input, word }, function()
    -- for manual completion
    if #input == 0 then
      return 1, {}
    end

    -- -- Ignore if input is long than word
    -- if #input > #word then
    --   return 1, {}
    -- end

    -- input does not contain a single alphanumeric char
    if not input:match('%w') then
      if not word:match('%W') then
        -- word contains only alphanumeric chars
        return 0, {}
      end

      return 1, {}
      -- elseif not word:match('%w') then
      --   -- word doesn't contain a single alphanumeric char but our input does
      --   return 0, {}
    end

    input, word = smart_case(input, word)

    -- word = word:gsub('%A', '')
    -- input = input:gsub('%A', '')

    -- input with repeating chars may lag with whenever we have a long repeating string (mostly tabnine)
    -- if the first n suggestion chars are equal, attempt to match only these chars
    local n = 4
    if #word >= n then
      local repeating = true
      for i = 2, n do
        if word:sub(i, i) ~= word:sub(i - 1, i - 1) then
          repeating = false
          break
        end
      end

      if repeating then
        -- word = word:sub(1, 4)
        return 1, {}
      end
    end

    -- do not attempt to fully match large words
    if #word > 60 then
      word = word:sub(1, 60)
    end

    -- remove (), from the end of the word
    -- useful for lsp which returns a word such as function()
    -- word:gsub('%(%)$', '')

    -- TODO handle this only for specific sources like lsp and not copilot/tabnine
    -- fun(string a, string b) on the completion
    -- pattern also covers the substution above
    -- word:gsub("%(.*%)$", "")

    -- ignore non alphanumeric chars
    -- word = word:gsub('%W', '')

    local _, matches, score = unpack(vim.fn.matchfuzzypos({ word }, input))
    score = math.max(score[1] or 0, 0)

    if #word > 10 then
      score = math.ceil(score - (score * 1 / 10) * (#word - #input))
    end

    return score, matches[1] or {}
  end)
end

local SEQUENTIAL_BONUS = 15 --[[ bonus for adjacent matches ]]
local SEPARATOR_BONUS = 30 --[[ bonus if match occurs after a separator ]]
local CAMEL_BONUS = 30 --[[ bonus if match is uppercase and prev is lower ]]
local FIRST_LETTER_BONUS = 15 --[[ bonus if the first letter is matched ]]

local LEADING_LETTER_PENALTY = -5 --[[ penalty applied for every letter in str before the first match ]]
local MAX_LEADING_LETTER_PENALTY = -15 --[[ maximum penalty for leading letters ]]
local UNMATCHED_LETTER_PENALTY = -1

M.match_fuzzy_rec = function(input, word)
  return cache:ensure({ 'fuzzy_match', input, word }, function()
    input = vim.trim(input)

    -- for manual completion
    if #input == 0 then
      return 1, {}
    end

    -- do not attempt to match on large words
    if #word > 48 then
      word = word:sub(1, 48)
    end

    -- input does not contain a single alphanumeric char
    if #input > 1 and not input:match('%w') then
      return 0, {}
    end

    -- input with repeating chars may lag with whenever we have a long repeating string (mostly tabnine)
    -- if the first n suggestion chars are equal, attempt to match only these chars
    local n = 4
    if #word > n then
      local repeating = true
      for i = 2, n do
        if word:sub(i, i) ~= word:sub(i - 1, i - 1) then
          repeating = false
          break
        end
      end

      if repeating then
        return 1, { 1 }
      end
    end

    local _, score, matches = M.fuzzy_match(input, word)
    matches = matches or {}
    score = math.max(score or 0, 0)

    return score, matches
  end)
end

local function fuzzyMatchRecursive(pattern, str, patternCurrIndex, strCurrIndex, srcMatches, matches, maxMatches, nextMatch, recursionCount, recursionLimit)
  local outScore = 0

  -- Return if recursion limit is reached.
  recursionCount = recursionCount + 1
  if recursionCount >= recursionLimit then
    return false, outScore
  end

  -- Return if we reached ends of strings.
  if patternCurrIndex == #pattern or strCurrIndex == #str then
    return false, outScore
  end

  -- Recursion params
  local recursiveMatch = false
  local bestRecursiveMatches = {}
  local bestRecursiveScore = 0

  -- Loop through pattern and str looking for a match.
  local firstMatch = true

  while patternCurrIndex < #pattern and strCurrIndex < #str do
    local patternChar = pattern:sub(patternCurrIndex + 1, patternCurrIndex + 1)
    local strChar = str:sub(strCurrIndex + 1, strCurrIndex + 1)

    -- Match found.
    if patternChar:lower() == strChar:lower() then
      if nextMatch >= maxMatches then
        return false, outScore
      end

      if firstMatch and srcMatches then
        matches = copy(srcMatches)
        firstMatch = false
      end

      local recursiveMatches = {}
      local matched, recursiveScore = fuzzyMatchRecursive(pattern, str, patternCurrIndex, strCurrIndex + 1, matches, recursiveMatches, maxMatches, nextMatch, recursionCount, recursionLimit)

      if matched then
        -- Pick best recursive score.
        if not recursiveMatch or recursiveScore > bestRecursiveScore then
          bestRecursiveMatches = copy(recursiveMatches)
          bestRecursiveScore = recursiveScore
        end
        recursiveMatch = true
      end

      table.insert(matches, strCurrIndex)

      nextMatch = nextMatch + 1
      patternCurrIndex = patternCurrIndex + 1
    end
    strCurrIndex = strCurrIndex + 1
  end

  local matched = patternCurrIndex == #pattern
  if matched then
    outScore = 100

    -- Apply leading letter penalty
    local penalty = LEADING_LETTER_PENALTY * matches[1]
    penalty = math.max(MAX_LEADING_LETTER_PENALTY, penalty)

    outScore = outScore + penalty

    -- Apply unmatched penalty
    local unmatched = #str - nextMatch
    outScore = outScore + UNMATCHED_LETTER_PENALTY * unmatched

    -- Apply ordering bonuses
    for i = 1, nextMatch, 1 do
      local currIdx = matches[i]

      if i > 1 then
        local prevIdx = matches[i - 1]
        if prevIdx and currIdx == (prevIdx + 1) then
          outScore = outScore + SEQUENTIAL_BONUS
        end
      end

      -- Check for bonuses based on neighbor character value.
      if currIdx > 0 then
        -- Camel case
        local neighbor = str:sub(currIdx - 1, currIdx - 1)
        local curr = str:sub(currIdx, currIdx)
        if neighbor ~= neighbor:upper() and curr ~= curr:lower() then
          outScore = outScore + CAMEL_BONUS
        end

        local isNeighbourSeparator = neighbor == '_' or neighbor == ' '
        if isNeighbourSeparator then
          outScore = outScore + SEPARATOR_BONUS
        end
      else
        -- First letter
        outScore = outScore + FIRST_LETTER_BONUS
      end
    end

    -- Return best result
    if recursiveMatch and (not matched or bestRecursiveScore > outScore) then
      -- Recursive score is better than "this"
      matches = copy(bestRecursiveMatches)
      outScore = bestRecursiveScore
      return true, outScore, matches
    elseif matched then -- "this" score is better than recursive
      return true, outScore, matches
    else
      return false, outScore
    end
  end

  return false, outScore
end

-- Does a fuzzy search to find pattern inside a string.
-- @param   pattern string          pattern to search for
-- @param   str     string          string which is being searched
-- @returns [boolean, number]       a boolean which tells if pattern was
--                                  found or not and a search score
function M.fuzzy_match(pattern, str)
  local recursionCount = 0
  local recursionLimit = 5
  local matches = {}
  local maxMatches = 32

  return fuzzyMatchRecursive(
    pattern,
    str,
    0, --[[ patternCurrIndex ]]
    0, --[[ strCurrIndex ]]
    nil, --[[ srcMatches ]]
    matches,
    maxMatches,
    0, --[[ nextMatch ]]
    recursionCount,
    recursionLimit
  )
end

M.match = M.matching

return M

-- https://s3-us-west-2.amazonaws.com/forrestthewoods.staticweb/lib_fts/tests/fuzzy_match/fts_fuzzy_match_test.html
-- console.time('t')
-- fuzzy_match('await', "fuzzyMatch('await', 'await')")
-- console.timeEnd('t')

-- console.time('t')
-- fuzzyMatch('await', "fuzzyMatch('await', 'await')")
-- console.timeEnd('t')

-- console.time('t')
-- fuzzyMatch('await', "fuzzyMatch('await', 'await')")
-- console.timeEnd('t')

-- const SEQUENTIAL_BONUS = 15; // bonus for adjacent matches
-- const SEPARATOR_BONUS = 30; // bonus if match occurs after a separator
-- const CAMEL_BONUS = 30; // bonus if match is uppercase and prev is lower
-- const FIRST_LETTER_BONUS = 15; // bonus if the first letter is matched

-- const LEADING_LETTER_PENALTY = -5; // penalty applied for every letter in str before the first match
-- const MAX_LEADING_LETTER_PENALTY = -15; // maximum penalty for leading letters
-- const UNMATCHED_LETTER_PENALTY = -1;

-- /**
--  * Does a fuzzy search to find pattern inside a string.
--  * @param {*} pattern string        pattern to search for
--  * @param {*} str     string        string which is being searched
--  * @returns [boolean, number]       a boolean which tells if pattern was
--  *                                  found or not and a search score
--  */
-- function fuzzyMatch(pattern, str) {
--   const recursionCount = 0;
--   const recursionLimit = 10;
--   const matches = [];
--   const maxMatches = 256;

--   return fuzzyMatchRecursive(
--     pattern,
--     str,
--     0 /* patternCurIndex */,
--     0 /* strCurrIndex */,
--     null /* srcMatces */,
--     matches,
--     maxMatches,
--     0 /* nextMatch */,
--     recursionCount,
--     recursionLimit
--   );
-- }

-- function fuzzyMatchRecursive(
--   pattern,
--   str,
--   patternCurIndex,
--   strCurrIndex,
--   srcMatces,
--   matches,
--   maxMatches,
--   nextMatch,
--   recursionCount,
--   recursionLimit
-- ) {
--   let outScore = 0;

--   // Return if recursion limit is reached.
--   if (++recursionCount >= recursionLimit) {
--     return [false, outScore];
--   }

--   // Return if we reached ends of strings.
--   if (patternCurIndex === pattern.length || strCurrIndex === str.length) {
--     return [false, outScore];
--   }

--   // Recursion params
--   let recursiveMatch = false;
--   let bestRecursiveMatches = [];
--   let bestRecursiveScore = 0;

--   // Loop through pattern and str looking for a match.
--   let firstMatch = true;
--   while (patternCurIndex < pattern.length && strCurrIndex < str.length) {
--     // Match found.
--     if (
--       pattern[patternCurIndex].toLowerCase() === str[strCurrIndex].toLowerCase()
--     ) {
--       if (nextMatch >= maxMatches) {
--         return [false, outScore];
--       }

--       if (firstMatch && srcMatces) {
--         matches = [...srcMatces];
--         firstMatch = false;
--       }

--       const recursiveMatches = [];
--       const [matched, recursiveScore] = fuzzyMatchRecursive(
--         pattern,
--         str,
--         patternCurIndex,
--         strCurrIndex + 1,
--         matches,
--         recursiveMatches,
--         maxMatches,
--         nextMatch,
--         recursionCount,
--         recursionLimit
--       );

--       if (matched) {
--         // Pick best recursive score.
--         if (!recursiveMatch || recursiveScore > bestRecursiveScore) {
--           bestRecursiveMatches = [...recursiveMatches];
--           bestRecursiveScore = recursiveScore;
--         }
--         recursiveMatch = true;
--       }

--       matches[nextMatch++] = strCurrIndex;
--       ++patternCurIndex;
--     }
--     ++strCurrIndex;
--   }

--   const matched = patternCurIndex === pattern.length;

--   if (matched) {
--     outScore = 100;

--     // Apply leading letter penalty
--     let penalty = LEADING_LETTER_PENALTY * matches[0];
--     penalty =
--       penalty < MAX_LEADING_LETTER_PENALTY
--         ? MAX_LEADING_LETTER_PENALTY
--         : penalty;
--     outScore += penalty;

--     //Apply unmatched penalty
--     const unmatched = str.length - nextMatch;
--     outScore += UNMATCHED_LETTER_PENALTY * unmatched;

--     // Apply ordering bonuses
--     for (let i = 0; i < nextMatch; i++) {
--       const currIdx = matches[i];

--       if (i > 0) {
--         const prevIdx = matches[i - 1];
--         if (currIdx == prevIdx + 1) {
--           outScore += SEQUENTIAL_BONUS;
--         }
--       }

--       // Check for bonuses based on neighbor character value.
--       if (currIdx > 0) {
--         // Camel case
--         const neighbor = str[currIdx - 1];
--         const curr = str[currIdx];
--         if (
--           neighbor !== neighbor.toUpperCase() &&
--           curr !== curr.toLowerCase()
--         ) {
--           outScore += CAMEL_BONUS;
--         }
--         const isNeighbourSeparator = neighbor == "_" || neighbor == " ";
--         if (isNeighbourSeparator) {
--           outScore += SEPARATOR_BONUS;
--         }
--       } else {
--         // First letter
--         outScore += FIRST_LETTER_BONUS;
--       }
--     }

--     // Return best result
--     if (recursiveMatch && (!matched || bestRecursiveScore > outScore)) {
--       // Recursive score is better than "this"
--       matches = [...bestRecursiveMatches];
--       outScore = bestRecursiveScore;
--       return [true, outScore];
--     } else if (matched) {
--       // "this" score is better than recursive
--       return [true, outScore];
--     } else {
--       return [false, outScore];
--     }
--   }
--   return [false, outScore];
-- }
