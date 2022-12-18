local matcher = {}

---@type function
matcher.debug = function(...)
  return ...
end

matcher.match = require('cmp.fuzzy_matcher').match
return matcher
