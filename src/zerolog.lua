-- lua-zero-log — a zero-allocation, deferred-formatting ring logger for LuaJIT.
--
-- The hot path never touches the GC. A log call writes a level, a pre-registered message id, and a
-- handful of numeric args into a preallocated `ffi` ring buffer; the expensive part — `string.format`
-- — is deferred until the ring is drained (on flush, on crash, periodically). This is the standard
-- "binary / deferred logging" technique (NanoLog, spdlog's backtrace), done in pure LuaJIT FFI so it
-- needs no native build and no cross-platform binary matrix.
--
-- Two tiers, by design:
--   * Cold / ergonomic — `log:info("took %d damage from %s", dmg, who)`. Formats eagerly, takes any
--     args (strings, numbers). Allocates a string; fine for lifecycle/error logging (~99% of calls).
--   * Hot / zero-alloc — `local M = log:def(INFO, "ai scored %.2f for unit %d"); M(score, id)`. The
--     emitter is a fixed-arity closure (codegen'd once, cold) that writes numeric args straight into
--     the ring. No varargs, no string work, no table churn. Use it inside per-frame / per-entity loops.
--
-- The library is deliberately game-agnostic: it owns the ring and the formatting, nothing else.
--   * Timestamps come from an injected `clock` (your sim clock), not `os.time` — so logs order by
--     game time and tests are deterministic. For a *truly* alloc-free hot loop, inject a clock that
--     the JIT can compile (a plain Lua function reading a number); `os.clock` is only the convenience
--     default and can abort the trace.
--   * Output goes to an injected `sink(level, ts, message, seq)`. Wiring it to a VFS file, and
--     draining the ring from `love.errorhandler`, is the caller's job.
--
-- Requires LuaJIT (uses `ffi`). Not thread-safe — use one logger per thread.

local ffi = require("ffi")

local zerolog = {}

-- Severity levels. Higher = more severe; the logger drops anything below its `level`.
local LEVELS = { TRACE = 1, DEBUG = 2, INFO = 3, WARN = 4, ERROR = 5, FATAL = 6 }
local LEVEL_NAMES = {}
for name, n in pairs(LEVELS) do LEVEL_NAMES[n] = name end
zerolog.LEVELS = LEVELS
zerolog.LEVEL_NAMES = LEVEL_NAMES

-- Max numeric args a deferred message may carry. Most log lines have 0–3; 8 is generous. Fixed at
-- load time so the record struct can be a flat, alignment-friendly C type.
local MAXARGS = 8
zerolog.MAXARGS = MAXARGS

-- One ring slot. `msg_id == 0` is the sentinel for a *cold* (pre-formatted) entry — its text lives in
-- the parallel `cold` table at the same slot index. `msg_id > 0` indexes the format registry and the
-- first `argc` doubles in `args` are its substitution values. Numeric args are stored as doubles, so
-- integers are exact up to 2^53 (ample for game ids/counters).
ffi.cdef([[
typedef struct {
  double   ts;
  double   seq;
  uint32_t msg_id;
  uint32_t level;
  uint32_t argc;
  uint32_t _pad;
  double   args[8];
} zerolog_rec;
]])

local loadstring = loadstring or load

-- Count the conversion specifiers in a format string (each `%x`, ignoring escaped `%%`). Used to
-- infer a deferred message's arity at registration time. Cold path — runs once per `def`.
local function count_specs(fmt)
  local n = 0
  for _ in fmt:gsub("%%%%", ""):gmatch("%%") do n = n + 1 end
  return n
end

-- Build (and cache) a fixed-arity emitter *factory* for a given arg count. The factory closes over
-- `(id, level, self)` and returns the actual hot-path function. Generating specialized code per arity
-- is what keeps the hot path free of varargs and nil-checks — the single most important thing for the
-- JIT to compile it down to plain field stores. Compilation happens once per distinct arity, cold.
local emitter_factories = {}
local function emitter_factory(argc)
  local cached = emitter_factories[argc]
  if cached then return cached end

  local params = {}
  for i = 1, argc do params[i] = "a" .. i end
  params = table.concat(params, ", ")

  local body = {
    "local id, level, self = ...",
    "local ring, cap = self.ring, self.cap", -- immutable per logger; safe to capture
    "return function(" .. params .. ")",
    "  if level < self.level then return false end",
    "  local h = self.head",
    "  local r = ring[h]",
    "  r.ts = self.clock()",
    "  r.seq = self.seq",
    "  r.msg_id = id",
    "  r.level = level",
    "  r.argc = " .. argc,
  }
  for i = 1, argc do
    body[#body + 1] = ("  r.args[%d] = a%d"):format(i - 1, i)
  end
  body[#body + 1] = "  self.seq = self.seq + 1"
  body[#body + 1] = "  h = h + 1"
  body[#body + 1] = "  self.head = h >= cap and 0 or h" -- wrap without modulo
  body[#body + 1] = "  return true"
  body[#body + 1] = "end"

  local factory = assert(loadstring(table.concat(body, "\n"), "=zerolog.emit/" .. argc))
  emitter_factories[argc] = factory
  return factory
end

-- Format one record into its final string. Cold path (drain only), so allocation is fine; the
-- explicit dispatch up to MAXARGS avoids building an intermediate table to `unpack`.
local function format_rec(self, r, slot)
  local mid = r.msg_id
  if mid == 0 then return self.cold[slot] end
  local f = self.formats[mid]
  local fmt, a = f.fmt, r.args
  local argc = r.argc
  if argc == 0 then return fmt end
  if argc == 1 then return fmt:format(a[0]) end
  if argc == 2 then return fmt:format(a[0], a[1]) end
  if argc == 3 then return fmt:format(a[0], a[1], a[2]) end
  if argc == 4 then return fmt:format(a[0], a[1], a[2], a[3]) end
  if argc == 5 then return fmt:format(a[0], a[1], a[2], a[3], a[4]) end
  if argc == 6 then return fmt:format(a[0], a[1], a[2], a[3], a[4], a[5]) end
  if argc == 7 then return fmt:format(a[0], a[1], a[2], a[3], a[4], a[5], a[6]) end
  return fmt:format(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7])
end

local Logger = {}
Logger.__index = Logger

-- Create a logger.
--   opts.capacity : ring size in records (default 4096). Oldest entries are overwritten.
--   opts.clock    : () -> number, the timestamp source (default os.clock). Inject your sim clock.
--   opts.sink     : (level, ts, message, seq) -> nil, where `flush` sends entries (optional).
--   opts.level    : minimum level to record (default TRACE).
--   opts.name     : optional label, for the caller's convenience.
function zerolog.new(opts)
  opts = opts or {}
  local cap = opts.capacity or 4096
  assert(cap >= 1, "capacity must be >= 1")
  local self = setmetatable({}, Logger)
  self.cap = cap
  self.ring = ffi.new("zerolog_rec[?]", cap)
  self.cold = {} -- slot -> preformatted string (cold entries only)
  self.formats = {} -- msg_id -> { fmt, level, argc }
  self.head = 0 -- next write index, in [0, cap)
  self.seq = 0 -- monotonic write count; also each entry's global order id
  self.clock = opts.clock or os.clock
  self.sink = opts.sink
  self.level = opts.level or LEVELS.TRACE
  self.name = opts.name
  return self
end

-- Register a deferred message and return its hot-path emitter. `argc` is inferred from the format
-- string but may be given explicitly. The returned function takes exactly `argc` numeric args and is
-- allocation-free on the JIT-compiled path. Passing the wrong arity, or a non-number, raises.
function Logger:def(level, fmt, argc)
  assert(type(fmt) == "string", "fmt must be a string")
  level = level or LEVELS.INFO
  argc = argc or count_specs(fmt)
  assert(argc >= 0 and argc <= MAXARGS, "argc out of range (0.." .. MAXARGS .. "): " .. tostring(argc))
  local id = #self.formats + 1
  self.formats[id] = { fmt = fmt, level = level, argc = argc }
  return emitter_factory(argc)(id, level, self)
end

-- Cold write: stash an already-formatted string at the current slot. Shared by all eager helpers.
function Logger:_cold(level, message)
  if level < self.level then return false end
  local h = self.head
  local r = self.ring[h]
  r.ts = self.clock()
  r.seq = self.seq
  r.msg_id = 0
  r.level = level
  r.argc = 0
  self.cold[h] = message
  self.seq = self.seq + 1
  h = h + 1
  self.head = h >= self.cap and 0 or h
  return true
end

-- Eager, any-args log. Formats now (allocates), then records. The ergonomic 99% path.
function Logger:log(level, fmt, ...)
  if level < self.level then return false end
  local message = select("#", ...) > 0 and string.format(fmt, ...) or fmt
  return self:_cold(level, message)
end

for name, lvl in pairs(LEVELS) do
  Logger[name:lower()] = function(self, fmt, ...) return self:log(lvl, fmt, ...) end
end

-- Number of entries currently held (saturates at capacity once the ring has wrapped).
function Logger:count()
  return self.seq < self.cap and self.seq or self.cap
end

-- Visit live entries oldest -> newest, calling `visit(level, ts, message, seq)` for each. Does not
-- mutate the ring. Returns the number visited.
function Logger:drain(visit)
  local cap, seq = self.cap, self.seq
  local n = seq < cap and seq or cap
  local start = seq <= cap and 0 or self.head -- once wrapped, the oldest live entry sits at `head`
  local ring = self.ring
  for k = 0, n - 1 do
    local slot = (start + k) % cap
    local r = ring[slot]
    visit(tonumber(r.level), tonumber(r.ts), format_rec(self, r, slot), tonumber(r.seq))
  end
  return n
end

-- Drain every live entry to the sink, then clear the ring. No-op (returns 0) if no sink is set.
function Logger:flush()
  local sink = self.sink
  if not sink then return 0 end
  local n = self:drain(sink)
  self:reset()
  return n
end

-- Forget all buffered entries.
function Logger:reset()
  self.head = 0
  self.seq = 0
  self.cold = {} -- release retained cold strings to the GC
  return self
end

function Logger:setSink(fn) self.sink = fn; return self end
function Logger:setLevel(level) self.level = level; return self end

-- Convenience one-line formatter for sinks: "  12.345 [INFO ] message".
function zerolog.line(level, ts, message)
  return string.format("%10.3f [%-5s] %s", ts, LEVEL_NAMES[level] or "?", message)
end

return zerolog
