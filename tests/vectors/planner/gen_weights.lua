-- Writes tests/vectors/planner/weights.json from Klimax/Plan/Weights.lua (phase 21).
-- Run from the repo root: lua tests/vectors/planner/gen_weights.lua > tests/vectors/planner/weights.json
local K = {}
local chunk = assert(loadfile("Klimax/Plan/Weights.lua"))
chunk("Klimax", K)
local Wt = K.Plan.Weights
local function enc(v, ind)
  ind = ind or ""
  if type(v) == "table" then
    if #v > 0 then
      local parts = {}
      for _, x in ipairs(v) do parts[#parts+1] = enc(x) end
      return "[" .. table.concat(parts, ", ") .. "]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys+1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts+1] = ind .. "  \"" .. k .. "\": " .. enc(v[k], ind .. "  ") end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. ind .. "}"
  elseif type(v) == "number" then
    if v == math.floor(v) then return string.format("%d", v) end
    local s = string.format("%.15g", v)
    if tonumber(s) ~= v then s = string.format("%.17g", v) end
    return s
  else
    return string.format("%q", v)
  end
end
io.write(enc({ default = Wt.DEFAULT, levelXp = Wt.LEVEL_XP, profile = Wt.PROFILE, order = Wt.ORDER, _note = "Generated from Klimax/Plan/Weights.lua (planner_spec checks it). Read by pipeline/sim/planner.py." }), "\n")
