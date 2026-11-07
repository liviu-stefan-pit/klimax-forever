-- Writes docs/CLASS_BEATS.md (phase 24). Run from the repo root: lua tests/lua/tools/gen_class_beats.lua
package.path = "tests/lua/tools/?.lua;" .. package.path
local M = require("class_beats")
local f = assert(io.open("docs/CLASS_BEATS.md", "wb"))
f:write(M.Render(M.Load()))
f:close()
print("wrote docs/CLASS_BEATS.md")
