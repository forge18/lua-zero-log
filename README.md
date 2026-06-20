# lua-zero-log

A **zero-allocation, deferred-formatting ring logger for LuaJIT**.

The hot path never touches the GC. A log call writes a level, a pre-registered message id, and a few
numeric args into a preallocated `ffi` ring buffer; the expensive part — `string.format` — is
deferred until the ring is drained (on flush, on crash, periodically). This is the "binary / deferred
logging" technique (NanoLog, spdlog's backtrace) done in pure LuaJIT FFI: no native build, no
cross-platform binary matrix.

Requires **LuaJIT** (uses `ffi`). Not thread-safe — use one logger per thread.

## Two tiers

```lua
local zerolog = require("zerolog")
local L = zerolog.LEVELS

local log = zerolog.new({
  capacity = 4096,                 -- ring size in records; oldest are overwritten
  clock    = function() return game.minutes end,  -- timestamp source (your sim clock)
  sink     = function(level, ts, message, seq)    -- where flush() sends entries
    io.write(zerolog.line(level, ts, message), "\n")
  end,
  level    = L.DEBUG,              -- minimum level to record
})

-- Cold / ergonomic: formats eagerly, takes any args. The ~99% path (lifecycle, errors).
log:info("loaded zone %s in %d ms", zoneName, ms)
log:error("save failed: %s", err)

-- Hot / zero-alloc: register once, then call with exactly that many *numeric* args. No string work,
-- no varargs, no garbage. Use inside per-frame / per-entity loops.
local scored = log:def(L.TRACE, "ai scored %.2f for unit %d")  -- arity inferred = 2
for _, u in ipairs(units) do
  scored(u.score, u.id)
end

-- Later — drain the buffer.
log:flush()                       -- to the sink, then clears
log:drain(function(level, ts, message, seq) ... end)  -- non-destructive
```

## API

| Call | Description |
|------|-------------|
| `zerolog.new(opts)` | Create a logger. `opts`: `capacity`, `clock`, `sink`, `level`, `name`. |
| `log:def(level, fmt [, argc])` | Register a deferred message; returns a fixed-arity, alloc-free emitter. Arity is inferred from `fmt` unless given. |
| `log:log(level, fmt, ...)` | Eager, any-args log. |
| `log:trace/debug/info/warn/error/fatal(fmt, ...)` | Level shorthands for `:log`. |
| `log:drain(visit)` | Visit live entries oldest→newest as `visit(level, ts, message, seq)`. Non-destructive. Returns count. |
| `log:flush()` | Drain to the sink, then `reset`. Returns count (0 with no sink). |
| `log:reset()` | Forget all buffered entries. |
| `log:count()` | Entries currently held (saturates at `capacity`). |
| `log:setSink(fn)` · `log:setLevel(lvl)` | Mutators. |
| `zerolog.LEVELS` · `zerolog.LEVEL_NAMES` | `TRACE…FATAL` = 1…6, and the reverse map. |
| `zerolog.line(level, ts, message)` | Convenience one-line formatter for sinks. |

## Notes & limits

- **Deferred args are numeric** (stored as doubles → integers exact to 2^53). Strings only via the
  cold path or by pre-registering them in the format string. The hot emitter is *strict*: wrong arity
  or a non-number raises.
- **Up to `zerolog.MAXARGS` (8)** numeric args per deferred message.
- **For a genuinely alloc-free hot loop, inject a JIT-compilable `clock`** (a plain Lua function
  returning a number). The default `os.clock` is for convenience and can abort the trace.
- **Timestamps and output are injected.** The library owns the ring and formatting, nothing else —
  wiring a clock, a file sink, and a crash-time drain is the caller's job.

## Test

```sh
luajit spec/run.lua     # or: lx test
```
