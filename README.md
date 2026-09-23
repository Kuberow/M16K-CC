# m16k — an 8-bit emulator that runs *inside* CraftOS-PC

The M16K is a tiny fictional computer: an 8-bit CPU, 16 KB of RAM, a 96×64
16-colour screen and a 32 KB disk. This project emulates it as a plain Lua
program **on a CraftOS-PC computer**, drawing through the
[CraftOS-PC graphics API](https://www.craftos-pc.cc/docs/gfxmode) and storing
its memory through the [CC: Tweaked `fs` API](https://tweaked.cc/module/fs.html) —
optionally redirected onto real floppy disks via a **storage plugin** system.

```
+---------------------------------------------------------------+
| CraftOS-PC computer (CC: Tweaked shell)                       |
|                                                               |
|  m16k.lua ── asm ── cpu ── machine ── display ── storage      |
|                              │                    │           |
|                   term.drawPixels          default: fs files  |
|                                           plugin: disk drives  |
+---------------------------------------------------------------+
| M16K guest program (assembled .asm / .lua generator / .m16k)   |
+---------------------------------------------------------------+
```

## Quick start

Copy `computer/m16k.lua` and `computer/m16k/` into the root of a
CraftOS-PC computer (the folder of computer `0` under your
[save data location](https://www.craftos-pc.cc/docs/saves)), start
CraftOS-PC, then in the shell:

```text
m16k                 -- built-in graphics demo: stripes + bouncing ball
m16k textdemo        -- built-in text example: rendered lines of text
m16k --list-plugins  -- list installed storage plugins
m16k -h              -- help
```

**Controls (both demos):** any key repaints the picture in the next palette
colour, `q` halts the machine, `Ctrl+T` quits the emulator.

* `m16k` demo — full-screen colour stripes (row *y* = colour *y* mod 16) with
  a ball bouncing across row 32 (`0x4C00`).
* `m16k textdemo` — clears the screen and prints four lines of text **through
  the BIOS** (it contains no font and touches no pixels itself), then idles:
  any key repaints the text in the next palette colour, `q` halts.

## Storage: default disk, or plugins

The machine has two persistent stores:

| store  | size   | what it is                                   |
|--------|--------|----------------------------------------------|
| `ram`  | 16 KB  | the machine's RAM image (flushed every ~2 s and on exit) |
| `disk` | 32 KB  | the 32 KB disk image (windowed into memory at `0x8000`) |

**With no plugin (`m16k`)** both stores live on the computer's own disk via
the `fs` API: `m16k/data/ram.bin` and `m16k/data/disk.bin`.

**With a plugin (`m16k -p drives`)** a plugin decides where they live.
Plugins are single Lua files in `m16k/plugins/<name>.lua` that return:

```lua
local plugin = {}
function plugin.open(config, helpers)
    return {
        name      = "my-backend",                    -- label shown at boot
        ramRead   = function(offset, length) ... end, -- -> string, 0-based
        ramWrite  = function(offset, chunk) ... end,  -- chunk is a string
        diskRead  = function(offset, length) ... end,
        diskWrite = function(offset, chunk) ... end,
        flush     = function() ... end,               -- persist dirty state
        close     = function() ... end,               -- final flush on exit
    }
end
return plugin
```

`helpers` (2nd argument of `open`) provides `readFile(path)`,
`writeFile(path, data)` (creates dirs, binary) and `pad(s, size)`.

If a plugin fails to load or open, `m16k` prints the reason and **falls back
to the computer's disk** (add `--strict` to abort instead).

### The `drives` example plugin

`m16k/plugins/drives.lua` stores the machine on real floppies:

* **RAM image → disk in the drive on the `top` side**
* **disk image → disk in the drive on the `right` side**

```text
attach top drive        -- CC: Tweaked / CraftOS-PC peripheral attach
attach right drive      -- insert a disk in each drive
m16k -p drives          -- boot with floppy-backed RAM and disk
```

(Or from Lua: `periphemu.create("top", "drive")`.) The images are written to
the drives' mounts as `m16k-ram.bin` / `m16k-disk.bin`, so the machine's
memory really sits on the floppies. The plugin validates at boot that both
drives exist, contain disks (`disk.hasData`) and have enough free space
(`fs.getFreeSpace`), with a clear error for each failure. Sides can be
overridden when opening it from Lua:
`storage.open("drives", "", { ramSide = "left", diskSide = "bottom" })`.

## Writing M16K programs

`m16k` accepts several program formats:

| argument                   | meaning                                        |
|----------------------------|------------------------------------------------|
| *(none)*                   | built-in `demo`                                |
| `textdemo` / `demo`        | bare name → `m16k/programs/<name>.lua` (or `.asm`) |
| `myprog.asm` (or `.s`)     | assembly source file                           |
| `myprog.lua`               | Lua generator that **returns** assembly source  |
| `myprog.m16k`              | raw binary, loaded at `0x0200`                 |

The built-ins (`m16k/programs/demo.lua`, `m16k/programs/textdemo.lua`) are
Lua generators: they return assembly text, which lets them compute repetitive
stuff (stripe rows) at build time. `textdemo.lua` is a pure *client of the
BIOS*: its only data is four `db "..."` message strings — edit those strings
and re-run to change the screen; the font and all pixel work live in the
BIOS ROM, exactly like a real program calling a video BIOS.

### Assembler syntax

```asm
; comment (semicolon, to end of line)
BIOS_PUTS = 0xE450      ; constant symbol (evaluated immediately)
        org  0x0200            ; load/run address (default 0x0200);
                               ; moving forward pads with zero bytes
start:  LDA  #15               ; immediate '#'
        STA  0x4000            ; absolute
        STA  0x4000,X          ; indexed by X (also ,B)
        LDA  (ptr)             ; indirect through 16-bit pointer
loop:   INX
        CPX  #96
        JNZ  loop
        db   1, 0b1010, "TEXT" ; bytes: numbers (0x / 0b / 'c'), expressions, strings
        dw   start, 0x1234     ; 16-bit little-endian words
msg:    db   "HELLO", 0
        LDA  #msg / 256        ; high byte;  msg % 256 = low byte
```

Two passes: forward label references are fine (in operands and `db`/`dw`
items), but a `name = expr` constant must be defined *before* use. Expressions
support `+ - * / %` and parentheses. Assembler errors are reported with line
numbers.

### CPU / instruction set

Registers `A`, `B`, `X` (8-bit), `PC` and `SP` (16-bit, stack grows down from
`0x4000`). Flags: `Z`, `C`, `N`.

| group      | instructions |
|------------|--------------|
| load/store | `LDA #v / LDA a / LDA (a) / LDA a,X / LDA a,B`, `STA a / (a) / a,X / a,B`, `LDB #v / LDB a`, `STB a`, `LDX #v / LDX a`, `STX a` |
| transfer   | `TXA TAX TBA TAB` |
| arithmetic | `ADD #v/abs`, `ADB`, `ADX`, `SUB #v/abs`, `SBB`, `SBX`, `ADC`, `INA`, `DEA`, `INX`, `DEX` |
| logic      | `AND #v/abs`, `OR #v/abs`, `XOR #v/abs`, `SHL`, `SHR` |
| compare    | `CMP #v/abs`, `CPB`, `CPX #v` — `JC` if A ≥ operand, `JNC` if A < operand |
| branch     | `JMP JZ JNZ JC JN JNC` (all absolute) |
| stack/sub  | `CALL a`, `RET`, `PUSHA POPA PUSHX POPX` |
| I/O        | `IN #port` (→ A), `OUT #port` (A → port) |
| system     | `NOP`, `HLT` |

### Memory map

| range          | contents |
|----------------|----------|
| `0x0000–0x3FFF`| 16 KB RAM (program + data; persisted by the storage backend) |
| `0x00F0–0x00FF`| **reserved**: BIOS data area (cursor/colour/font pointers) |
| `0x4000–0x57FF`| VRAM — 96×64 bytes, one palette index (0–15) per pixel |
| `0x8000–0x8FFF`| 4 KB disk window into the 32 KB disk image (page via `OUT 0x40`) |
| `0xE000–0xE622`| **BIOS ROM** (read-only; guest writes are ignored) — see below |

### I/O ports

| port  | direction | function |
|-------|-----------|----------|
| `0x00`| `IN`      | random byte 0–255 |
| `0x01`| `IN`      | keyboard status: 1 = key waiting |
| `0x02`| `IN`      | keyboard data: next key code (0 if empty) |
| `0x10`| `OUT`     | request a screen present |
| `0x40`| `OUT`     | select disk window page 0–7 |

Palette: 0 = white, 1 = orange … 15 = black (standard CC colour order).

Flag gotchas: `CMP` sets `C` when A ≥ operand (so `JC` = jump if ≥); `SHL`/`SHR`
and `ADD`/`SUB` set `C`, but `INA`/`DEA`/`INX`/`DEX` and loads touch **only**
`Z`/`N` — never rely on carry across them.

## The BIOS ROM (`m16k/rom/bios.asm`)

Like a real machine's video BIOS, the font and all text rendering live in a
**read-only ROM mapped at `0xE000`**, assembled fresh at every boot:

* `0xE000–0xE1FF` — font: 64 glyphs (ASCII `0x20`–`0x5F`), 8 bytes each,
  one byte per row, MSB = leftmost pixel. Lower-case input is folded to
  upper-case; anything outside the font renders as `?`.
* `0xE400+` — fixed service entry points (each a `JMP` stub). Cells are
  8×8 pixels → **12 columns × 8 rows** of text on the 96×64 screen.

| entry  | service | inputs / behaviour |
|--------|---------|--------------------|
| `0xE400` | `INIT`   | reset cursor (0,0), row base, colour = black. Call once at start. |
| `0xE410` | `CLS`    | fill the screen with the current colour |
| `0xE420` | `SETCOL` | `A` = colour (0–15) |
| `0xE430` | `SETCUR` | `B` = cell column (0–11), `X` = cell row (0–7) |
| `0xE440` | `PUTC`   | draw character `A` at the cursor and advance it (`0x0A` = newline; wraps at column 12 / row 8) |
| `0xE450` | `PUTS`   | print NUL-terminated string at `B` (high byte) : `X` (low byte) |
| `0xE460` | `NEWLINE`| cursor to the start of the next row |

Calling convention: all services clobber `A`/flags only (`PUTS` also consumes
`B`/`X` as its pointer); everything else is preserved. The BIOS keeps its
state in RAM `0x00F0–0x00FF` (documented at the top of `bios.asm`) — guest
programs must not use those 16 bytes.

```asm
  CALL 0xE400                ; INIT
  LDA #4
  CALL 0xE420                ; colour = yellow
  LDA #2 / TAB               ; B = cell column 2
  LDA #3 / TAX               ; X = cell row 3
  CALL 0xE430                ; SETCUR
  LDA #msg / 256 / TAB       ; B:X = message address
  LDA #msg % 256 / TAX
  CALL 0xE450                ; PUTS
msg: db "HELLO FROM M16K", 0
```

## Display

`m16k/display.lua` uses CraftOS-PC's
[graphics mode](https://www.craftos-pc.cc/docs/gfxmode)
(`term.setGraphicsMode(1)` + `term.drawPixels`, scaled to the terminal) and
transparently falls back to a text-mode blit renderer when graphics mode is
unavailable, so it still shows something on plain CC: Tweaked or the CLI
renderer.

## Testing

`m16k/smoketest.lua` is a headless self-test: it verifies the BIOS ROM
(assembles, entry stubs, font data, write-protection), assembles both
built-ins, runs the ball demo through a stripe/bounce/halt sequence,
round-trips `CALL`/`RET`/`PUSHA`/`POPA`, renders the text demo **through the
BIOS** and checks its pixels, and checks the default backend's persistence
files plus the drives plugin's fallback behaviour, then exits with code 0/1.

```powershell
CraftOS-PC.exe --headless --script <abs path>\m16k\smoketest.lua
```

It writes results to `m16k/testresult.txt` (`ALL SMOKE TESTS PASSED` on
success). Use `--directory <dir>` to test against an isolated save folder.

## File layout

```
m16k.lua                  entry point: args, BIOS load, main loop, key handling
m16k/isa.lua              instruction set table (shared by cpu + assembler)
m16k/cpu.lua              CPU core
m16k/asm.lua              two-pass assembler
m16k/machine.lua          memory map (incl. ROM), I/O ports, key queue, flush
m16k/display.lua          CraftOS-PC graphics present + text fallback
m16k/storage.lua          storage plugin loader + default (fs) backend
m16k/plugins/drives.lua   example plugin: drives for RAM + disk
m16k/rom/bios.asm         BIOS ROM: font + video services (mapped at 0xE000)
m16k/programs/demo.lua    built-in graphics demo (generator)
m16k/programs/textdemo.lua built-in text example: prints via the BIOS
m16k/smoketest.lua        headless self-test
```

## Documentation sources

* CraftOS-PC: [graphics mode](https://www.craftos-pc.cc/docs/gfxmode),
  [raw mode](https://www.craftos-pc.cc/docs/rawmode),
  [plugin system](https://www.craftos-pc.cc/docs/plugins),
  [renderers](https://www.craftos-pc.cc/docs/renderers),
  [CLI flags](https://www.craftos-pc.cc/docs/cli),
  [save data location](https://www.craftos-pc.cc/docs/saves)
* CC: Tweaked: [`term`](https://tweaked.cc/module/term.html),
  [`fs`](https://tweaked.cc/module/fs.html),
  [`disk`](https://tweaked.cc/module/disk.html),
  [`drive` peripheral](https://tweaked.cc/peripheral/drive.html)

Note for CraftOS file handles: call methods with a dot — `h.write(data)`,
`h.close()` — not `h:write(data)`.
