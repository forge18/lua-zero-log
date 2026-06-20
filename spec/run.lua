-- Self-contained test runner for lua-zero-log. Runs under LuaJIT (the library needs ffi):
--   luajit spec/run.lua      — or — lx test
-- No external test framework, so there's nothing to resolve and the interpreter is guaranteed to be
-- the one with ffi. Exits non-zero on any failure.

package.path = "src/?.lua;src/?/init.lua;" .. package.path

local zerolog = require("zerolog")
local L = zerolog.LEVELS

local total, failed = 0, 0
local group = ""

local function section(name) group = name end
local function check(cond, msg)
  total = total + 1
  if not cond then
    failed = failed + 1
    io.write(string.format("  FAIL [%s] %s\n", group, msg or "assertion"))
  end
end
local function eq(got, want, msg)
  check(got == want, string.format("%s — got %s, want %s", msg or "eq", tostring(got), tostring(want)))
end

-- Collect everything a drain produces, in order.
local function collect(log)
  local out = {}
  log:drain(function(level, ts, message, seq)
    out[#out + 1] = { level = level, ts = ts, message = message, seq = seq }
  end)
  return out
end

----------------------------------------------------------------------------------------------------
section("levels")
do
  eq(L.TRACE, 1, "TRACE=1")
  eq(L.FATAL, 6, "FATAL=6")
  eq(zerolog.LEVEL_NAMES[L.WARN], "WARN", "name lookup")
end

section("cold: eager format + order")
do
  local log = zerolog.new({ clock = function() return 0 end })
  log:info("hello %s", "world")
  log:warn("n=%d", 42)
  local e = collect(log)
  eq(#e, 2, "two entries")
  eq(e[1].message, "hello world", "formatted string arg")
  eq(e[1].level, L.INFO, "level recorded")
  eq(e[2].message, "n=42", "formatted number arg")
  eq(e[2].seq, 1, "seq increments")
end

section("deferred: numeric args formatted at drain")
do
  local log = zerolog.new({ clock = function() return 0 end })
  local hit = log:def(L.INFO, "unit %d took %d") -- argc inferred = 2
  hit(7, 25)
  hit(9, 3)
  local e = collect(log)
  eq(#e, 2, "two deferred entries")
  eq(e[1].message, "unit 7 took 25", "deferred format")
  eq(e[2].message, "unit 9 took 3", "deferred format 2")
end

section("argc inference + float formatting")
do
  local log = zerolog.new({ clock = function() return 0 end })
  local score = log:def(L.DEBUG, "score %.2f")
  score(0.5)
  eq(collect(log)[1].message, "score 0.50", "%.2f with one arg")
end

section("level filtering")
do
  local log = zerolog.new({ level = L.WARN, clock = function() return 0 end })
  eq(log:info("dropped"), false, "info below threshold returns false")
  eq(log:error("kept"), true, "error at/above threshold returns true")
  local hot = log:def(L.DEBUG, "x=%d")
  eq(hot(1), false, "deferred below threshold dropped")
  eq(log:count(), 1, "only the error recorded")
end

section("ring overwrite keeps newest, oldest-first")
do
  local log = zerolog.new({ capacity = 3, clock = function() return 0 end })
  for i = 1, 5 do log:info("%d", i) end -- writes 1..5 into a 3-slot ring
  local e = collect(log)
  eq(#e, 3, "saturates at capacity")
  eq(e[1].message, "3", "oldest live is 3")
  eq(e[2].message, "4", "then 4")
  eq(e[3].message, "5", "then 5 (newest)")
  eq(e[1].seq, 2, "seq preserved across wrap")
end

section("mixed cold + deferred interleave by seq")
do
  local log = zerolog.new({ clock = function() return 0 end })
  local hot = log:def(L.INFO, "hot %d")
  log:info("cold A")
  hot(1)
  log:info("cold B")
  local e = collect(log)
  eq(e[1].message, "cold A", "1st")
  eq(e[2].message, "hot 1", "2nd (deferred)")
  eq(e[3].message, "cold B", "3rd")
end

section("flush drains to sink then resets")
do
  local got = {}
  local log = zerolog.new({ clock = function() return 0 end, sink = function(_, _, m) got[#got + 1] = m end })
  log:info("a")
  log:info("b")
  local n = log:flush()
  eq(n, 2, "flush returns count")
  eq(#got, 2, "sink saw both")
  eq(got[2], "b", "in order")
  eq(log:count(), 0, "ring reset after flush")
end

section("clock injection records timestamps")
do
  local t = 0
  local log = zerolog.new({ clock = function() t = t + 10; return t end })
  log:info("a")
  log:info("b")
  local e = collect(log)
  eq(e[1].ts, 10, "first ts")
  eq(e[2].ts, 20, "second ts")
end

section("strict arity: wrong type / arity raises")
do
  local log = zerolog.new()
  local hot = log:def(L.INFO, "x=%d") -- argc 1
  check(not pcall(hot, "not a number"), "string arg into numeric slot raises")
  check(not pcall(hot), "missing arg (nil) raises")
  check(not pcall(function() log:def(L.INFO, "%d %d %d %d %d %d %d %d %d") end), "argc > MAXARGS raises")
end

section("zero-alloc hot path (JIT-compiled)")
do
  local tick = 0
  local log = zerolog.new({ capacity = 256, clock = function() tick = tick + 1; return tick end })
  local hot = log:def(L.INFO, "x=%d y=%d") -- argc 2
  for i = 1, 5000 do hot(i, i * 2) end -- warm up so the trace compiles
  collectgarbage()
  collectgarbage()
  local before = collectgarbage("count")
  for i = 1, 200000 do hot(i, i + 1) end
  local delta = collectgarbage("count") - before
  -- A non-zero-alloc implementation would allocate per call (hundreds of KB–MB over 200k iters).
  -- The JIT sinks the cdata reference, so the real figure is ~0; allow generous slack for noise.
  check(delta < 64, string.format("hot path stays flat (delta = %.1f KB over 200k calls)", delta))
end

----------------------------------------------------------------------------------------------------
io.write(string.format("\n%d checks, %d passed, %d failed\n", total, total - failed, failed))
os.exit(failed == 0 and 0 or 1)
