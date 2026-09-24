-- m16k/sdktest.lua -- SDK end-to-end test (smoketest-style, headless).
--
-- Verifies the preprocessor, the SDK includes, a MEX build (mkmx-style),
-- the myos kernel, first-boot MUFS format + sample install, and the shell
-- (help / ls / cat / run / rm / echo / mkhex / clear / backspace / unknown
-- command).
--
-- Every phase starts with `clear` to give it a known cursor position.
-- Reaching the bottom of the 19-row screen wipes it (by design), so without
-- a clear each phase's starting row would depend on the previous one.
--
-- Writes a log to m16k/sdktest.txt and exits with code 0/1.

local W, H = 306, 171
local logfile

-- VRAM packs 2 pixels per byte: high nibble = even x, low nibble = odd x
local function px(vram, x, y)
    local i = y * W + x
    local b = vram[math.floor(i / 2) + 1] or 0
    if i % 2 == 0 then return math.floor(b / 16) end
    return b % 16
end

local function log(s)
    if logfile then logfile.write(s .. "\n") end
end

local function readAll(path)
    local h = fs.open(path, "rb")
    if not h then return nil end
    local d = h.readAll()
    h.close()
    return d
end

-- glyph byte bits 7..3 = cell columns 0..4 (putrow shifts MSB first),
-- so a row's 5-bit pattern is (g >> 3) & 0x1F. Cell column 5 is blank.
local function buildFontMap(bbytes)
    local map = {}
    for ch = 0x20, 0x5F do
        local key = 0
        for r = 0, 4 do
            local g = bbytes[(ch - 0x20) * 8 + r + 1]
            key = key * 32 + math.floor(g / 8) % 32
        end
        if map[key] == nil then map[key] = string.char(ch) end
    end
    return map
end

local function cellKey(machine, r, c)
    local key = 0
    for a = 0, 4 do
        local bits = 0
        for k = 0, 4 do
            -- cells are 6x9: artwork row a of cell (r,c) lives at pixel
            -- (c*6 + k, r*9 + a), columns 0..4 of the 6-wide cell
            if px(machine.vram, c * 6 + k, r * 9 + a) ~= 15 then
                bits = bits + 2 ^ (4 - k)
            end
        end
        key = key * 32 + bits
    end
    return key
end

-- decode all 19 physical rows; returns rows[] (physical order) and curY
local function readScreen(machine, fontMap)
    local phys = {}
    for r = 0, 18 do
        local out = {}
        for c = 0, 50 do
            out[#out + 1] = fontMap[cellKey(machine, r, c)] or "?"
        end
        phys[r] = table.concat(out)
    end
    return phys, machine.ram[0xF1 + 1] or 0
end

local function count(hay, needle)
    local n, i = 0, 1
    while true do
        local p = hay:find(needle, i, true)
        if not p then return n end
        n = n + 1
        i = p + #needle
    end
end

-- The font draws '0' and 'O' with the same glyph (both 70 50 50 50 70), so
-- they cannot be told apart on screen. Fold O -> 0 on both sides before
-- comparing, otherwise any assertion containing an O would be a coin flip.
local function norm(t)
    return (t:gsub("O", "0"))
end

local function has(s, needle)
    return norm(s):find(norm(needle), 1, true) ~= nil
end

local function main()
    logfile = fs.open("m16k/sdktest.txt", "wb")

    local asm = loadfile("m16k/asm.lua")("")
    local pp = loadfile("m16k/sdk/pp.lua")("")
    local cpuModule = dofile("m16k/cpu.lua")
    local machineMod = dofile("m16k/machine.lua")
    local storage = dofile("m16k/storage.lua")
    local mufs = dofile("m16k/mufs.lua")

    ------------------------------------------------------------------
    -- 1. preprocessor
    ------------------------------------------------------------------
    local t1 = pp.process('%define GREET "HI"\nSAY GREET\n', "")
    assert(t1 and t1:find('SAY "HI"', 1, true), "pp %define failed: " .. tostring(t1))
    local t2 = pp.process("%macro ONE\nNOP\n%endmacro\nONE\n", "")
    assert(t2 and t2:find("NOP", 1, true) and not t2:find("ONE", 1, true),
        "pp %macro failed: " .. tostring(t2))
    local t3, e3 = pp.process('%include "no/such/file.inc"\n', "")
    assert(t3 == nil and e3, "pp %include error not reported")
    log("preprocessor OK")

    ------------------------------------------------------------------
    -- 2. BIOS ROM (font + services)
    ------------------------------------------------------------------
    local biosSrc = readAll("m16k/rom/bios.asm")
    assert(biosSrc, "m16k/rom/bios.asm is missing")
    local borg, bbytes = asm.assemble(biosSrc)
    assert(borg == 0xE000, "BIOS assemble failed: " .. tostring(bbytes))
    assert(#bbytes <= 0x800, "BIOS too big for its ROM hole")
    local fontMap = buildFontMap(bbytes)

    ------------------------------------------------------------------
    -- 3. build the MEX apps (exactly what mkmx does)
    ------------------------------------------------------------------
    -- myos %incbin's both of these, so they must exist before step 4.
    local function buildMx(name)
        local src = readAll("m16k/sdk/examples/" .. name .. ".asm")
        assert(src, "m16k/sdk/examples/" .. name .. ".asm is missing")
        local ppd, perr = pp.process(src, "m16k/sdk/examples")
        assert(ppd, name .. " preprocess failed: " .. tostring(perr))
        local org, bytes = asm.assemble(ppd)
        assert(org == 0x2000, name .. " org is " .. tostring(org or bytes))
        -- 0x3600: a big body may legitimately spill past 0x3000 -- nothing
        -- in the kernel uses 0x3000-0x3BFF (asm.asm ends well before this).
        assert(0x2000 + #bytes <= 0x3600, name .. " app too big")

        local n = #bytes
        local hdr = { 0x4D, 0x58, 1, 0, 0x00, 0x20, 16, 0, n % 256,
            math.floor(n / 256) % 256, 0, 0 }
        local sum = 0
        for i = 1, 10 do sum = sum + hdr[i] end
        hdr[11] = sum % 256

        local unpackf = unpack or table.unpack
        local parts, t = {}, {}
        parts[#parts + 1] = string.char(unpackf(hdr))
        for _, b in ipairs(bytes) do
            t[#t + 1] = b
            if #t == 64 then parts[#parts + 1] = string.char(unpackf(t)); t = {} end
        end
        if #t > 0 then parts[#parts + 1] = string.char(unpackf(t)) end
        local mx = table.concat(parts)
        assert(mx:byte(1) == 0x4D and mx:byte(2) == 0x58, "MEX magic missing")

        pcall(fs.makeDir, "m16k/build")
        local bh = fs.open("m16k/build/" .. name .. ".mx", "wb")
        assert(bh, "cannot write m16k/build/" .. name .. ".mx")
        bh.write(mx)
        bh.close()
        return mx
    end

    local mx = buildMx("hello")
    log(("mex build OK: hello.mx = %d bytes"):format(#mx))
    local amx = buildMx("asm")
    log(("mex build OK: asm.mx = %d bytes"):format(#amx))

    ------------------------------------------------------------------
    -- 4. assemble myos on top of the SDK
    ------------------------------------------------------------------
    local osrc = readAll("m16k/programs/myos.asm")
    assert(osrc, "m16k/programs/myos.asm is missing")
    local opp, oerr = pp.process(osrc, "m16k/programs")
    assert(opp, "myos preprocess failed: " .. tostring(oerr))
    local oorg, obytes = asm.assemble(opp)
    assert(oorg, "myos assemble failed: " .. tostring(obytes))
    assert(oorg == 0x0200, "myos org is 0x" .. string.format("%04X", oorg))
    assert(#obytes == 0x1E00, "myos must fill to org 0x2000, got " .. #obytes)
    for _, a in ipairs({ 0x1F00, 0x1F03, 0x1F06, 0x1F09, 0x1F0C, 0x1F0F,
        0x1F12, 0x1F15, 0x1F18, 0x1F1B, 0x1F1E, 0x1F21, 0x1F24 }) do
        assert(obytes[a - 0x0200 + 1] == 0x30,
            string.format("gate 0x%04X is not a JMP", a))
    end
    -- nothing may live past the gate block; the rest is padding to 0x2000
    for a = 0x1F27, 0x1FFF do
        assert(obytes[a - 0x0200 + 1] == 0,
            string.format("kernel data leaked past the gates at 0x%04X", a))
    end
    log(("myos OK: %d bytes, 13 gates verified at 0x1F00"):format(#obytes))

    ------------------------------------------------------------------
    -- 5. boot on a blank disk (first-boot format path)
    ------------------------------------------------------------------
    local backend = storage.open(nil, "", {}, true)
    local machine = machineMod.create({
        cpuModule = cpuModule,
        backend = backend,
        ramSize = storage.RAM_SIZE,
        diskSize = storage.DISK_SIZE,
        ramData = string.rep("\0", storage.RAM_SIZE),
        diskData = string.rep("\0", storage.DISK_SIZE),
        romBase = 0xE000,
        romBytes = bbytes,
    })
    machine:loadProgram(oorg, obytes)
    assert(machine.cpu.pc == 0x0200, "pc not set")

    local function typeKeys(s)
        for i = 1, #s do machine:pushKey(s:byte(i)) end
    end

    -- run a fixed number of steps; returns "halt" if the CPU stopped
    local function runSteps(n)
        for _ = 1, n do
            if machine:step() == "halt" then return "halt" end
        end
        return nil
    end

    -- step until the queue drains (at least minSteps first), up to a budget
    local function drain(budget, minSteps)
        minSteps = minSteps or 0
        for i = 1, budget do
            if machine:step() == "halt" then return "halt" end
            if i >= minSteps and #machine.keyq == 0 then return nil end
        end
        return "budget"
    end

    local function dump(label, phys, curY)
        log(("--- %s (curY=%d pc=0x%04X) ---")
            :format(label, curY, machine.cpu.pc))
        for r = 0, 18 do log(("%d: [%s]"):format(r, phys[r])) end
    end

    -- debug: the live directory entries on disk (MUFS dir starts at 0x10)
    local function dumpDir(tag)
        local live, hex = {}, {}
        for i = 0, 31 do
            local base = 0x10 + i * 32
            if (machine.disk[base + 1] or 0) ~= 0 then
                local name = {}
                for k = 0, 15 do
                    local c = machine.disk[base + k + 1] or 0
                    name[#name + 1] = (c >= 32 and c < 127) and string.char(c) or "."
                end
                live[#live + 1] = string.format("[%d] %s", i, table.concat(name))
            end
        end
        for i = 0, 23 do
            hex[#hex + 1] = string.format("%02X", machine.disk[0x11 + i] or 0)
        end
        log(("%s: %d live dir entries; bytes@0x10: %s")
            :format(tag, #live, table.concat(hex, " ")))
        for _, l in ipairs(live) do log("    " .. l) end
    end

    -- table.concat starts at index 1, but our rows are 0-based
    local function joinRows(phys)
        local t = {}
        for r = 0, 18 do t[#t + 1] = phys[r] end
        return table.concat(t, "\n")
    end

    -- run one command: clear the screen first so the output is on fresh rows
    local function phase(label, cmd, budget, settle)
        typeKeys("clear\r" .. cmd .. "\r")
        local why = drain(budget or 400000, 30000)
        assert(why == nil,
            ("%s: machine did not go idle (%s), %d keys left")
                :format(label, tostring(why), #machine.keyq))
        -- `clear` runs a full-screen CLS, and drain() returns the instant the
        -- key queue empties (which is *before* the command is dispatched), so
        -- give the machine a generous fixed budget to finish the output
        for _ = 1, settle or 400000 do machine:step() end
        local phys, curY = readScreen(machine, fontMap)
        dump(label, phys, curY)
        return joinRows(phys)
    end

    local why = runSteps(1500000)
    assert(why == nil, "machine halted during boot")
    do
        local phys, curY = readScreen(machine, fontMap)
        dump("boot", phys, curY)
        local s = joinRows(phys)
        assert(s:find("MUNIX", 1, true), "boot banner missing")
        assert(s:find("TYPE HELP", 1, true), "boot hint missing")
    end
    log("boot OK (banner + first-boot format)")

    -- asm.mx is not baked into the kernel (~5 KB); m16k.lua writes it onto
    -- the disk at runtime, so do exactly that here before any `run asm`.
    assert(mufs.formatted(machine.disk), "disk not formatted after boot")
    assert(mufs.install(machine.disk, "asm.mx", amx), "cannot place asm.mx")
    machine.diskDirty = true
    log(("disk OK: asm.mx placed (%d bytes)"):format(#amx))
    dumpDir("boot")

    -- REPRO: what a user actually sees. No `clear` first -- boot leaves
    -- curY=2, so an app must fit the 17 rows below before the wrap wipes
    -- the screen.
    do
        typeKeys("run hello\r")
        assert(drain(400000, 30000) == nil, "repro: machine did not go idle")
        for _ = 1, 400000 do machine:step() end
        local phys, curY = readScreen(machine, fontMap)
        dump("REPRO: run hello straight from boot", phys, curY)
        local s = joinRows(phys)
        assert(has(s, "MUNIX"), "run hello wiped the screen (banner gone)")
        assert(has(s, "$ RUN HELLO"), "run echo missing")
        assert(has(s, "HELLO FROM MEX"), "MEX app output lost to the wrap")
        assert(has(s, "1 2 3 4 5"), "MEX app counter lost to the wrap")
        log("check: run hello fits from a cold boot")
    end

    ------------------------------------------------------------------
    -- 6. shell commands
    ------------------------------------------------------------------
    local s

    s = phase("help", "help")
    assert(has(s, "COMMANDS:"), "help output missing")
    assert(has(s, "CAT F RUN F"), "help line 3 missing")
    assert(has(s, "HALT"), "help output truncated")
    log("check: help")

    -- backspace rewrites the buffer *and* must erase the cell on screen
    -- (PUTC repaints a whole cell: background for the dark pixels, so a
    -- space clears whatever glyph was there)
    s = phase("ls (typed 'lsx' + backspace)", "lsx\b")
    dumpDir("after ls")
    assert(not has(s, "$ LSX"), "backspace did not erase the 'X' on screen")
    assert(has(s, "$ LS"), "prompt/echo missing after backspace")
    assert(has(s, "HELLO.MX"), "ls output missing (backspace broken?)")
    assert(has(s, "README.TXT"), "ls did not list readme.txt")
    assert(count(norm(s), norm("HELLO.MX")) == 1, "expected exactly one HELLO.MX line")
    log("check: ls + backspace")

    -- The cursor must actually walk left: without the step-back after
    -- PUTC, curX never changes, all 4 backspaces erase the same cell and
    -- the retype lands one cell too far right ("$ HELP ELP").
    s = phase("backspace walks the cursor", "helpx\b\b\b\belp")
    assert(has(s, "$ HELP"), "retype after backspace missing")
    assert(not has(s, "$ HELP ELP"), "cursor did not move back on backspace")
    assert(has(s, "C0MMANDS:"), "help did not run after the retype")
    log("check: backspace moves the cursor")

    s = phase("cat", "cat readme.txt")
    assert(has(s, "MUNIX SDK DEMO"), "cat did not show readme.txt")
    assert(has(s, "M16K SDK"), "readme.txt truncated")
    log("check: cat")

    s = phase("run", "run hello")
    assert(has(s, "HELLO FROM MEX"), "MEX app output missing")
    assert(has(s, "$ RUN HELLO"), "run command not echoed")
    assert(has(s, "5"), "MEX app counter never reached 5")
    log("check: run (MEX app via syscall gates)")

    -- `run f args` must split the filename from the rest of the line and
    -- hand the rest to the app at APP_ARG (uppercase, because PUTC folds)
    s = phase("run with arg", "run hello zzz")
    assert(has(s, "HELLO FROM MEX"), "MEX app lost its output when given an argument")
    assert(has(s, "ARG:ZZZ"), "run did not pass its argument to the app")
    log("check: run passes arguments")

    -- with no argument the app must see APP_ARG = 0 and print no ARG line
    s = phase("run without arg", "run hello")
    assert(has(s, "HELLO FROM MEX"), "MEX app output missing")
    assert(not has(s, "ARG:"), "run handed the app a stale argument")
    log("check: run with no argument")

    s = phase("rm", "rm readme.txt")
    log("check: rm")

    s = phase("ls after rm", "ls")
    assert(has(s, "HELLO.MX"), "hello.mx vanished after rm")
    assert(not has(s, "README.TXT"), "readme.txt still listed after rm")
    log("check: ls after rm")

    s = phase("cat after rm", "cat readme.txt")
    assert(has(s, "NO FILE"), "cat after rm should report NO FILE")
    log("check: cat after rm")

    ------------------------------------------------------------------
    -- 6b. writing files: echo t > f, echo t >> f, mkhex f HEX
    ------------------------------------------------------------------
    s = phase("echo create", "echo hi > note.txt")
    s = phase("cat note.txt", "cat note.txt")
    assert(has(s, "HI"), "echo t > f did not create note.txt")
    log("check: echo > (create)")

    -- the append has to read the old bytes back before fs_delete, then lay
    -- the new text down right behind them in the staging buffer
    s = phase("echo append", "echo yo >> note.txt")
    s = phase("cat after append", "cat note.txt")
    assert(has(s, "HIYO"), "echo t >> f did not append")
    log("check: echo >> (append)")

    s = phase("echo overwrite", "echo ab > note.txt")
    s = phase("cat after overwrite", "cat note.txt")
    assert(has(s, "AB"), "echo t > f did not overwrite")
    assert(not has(s, "HIYO"), "echo t > f left the old contents behind")
    log("check: echo > (overwrite)")

    s = phase("echo usage", "echo hi")
    assert(has(s, "ECHO T > F"), "echo without '>' should print its usage")
    log("check: echo usage error")

    s = phase("echo empty", "echo    > note2.txt")
    assert(has(s, "EMPTY?"), "echo with no text should report EMPTY?")
    log("check: echo empty error")

    s = phase("mkhex create", "mkhex t.txt 48 49")
    s = phase("cat mkhex", "cat t.txt")
    assert(has(s, "HI"), "mkhex did not decode '48 49' into HI")
    log("check: mkhex (spaced hex)")

    s = phase("mkhex joined", "mkhex u.txt 594553")
    s = phase("cat mkhex joined", "cat u.txt")
    assert(has(s, "YES"), "mkhex did not decode '594553' into YES")
    log("check: mkhex (joined hex)")

    -- an unmatched digit must fail before anything is written to disk
    s = phase("mkhex odd", "mkhex v.txt 484")
    assert(has(s, "HEX?"), "an odd hex digit count should report HEX?")
    log("check: mkhex odd-digit error")

    s = phase("ls after writes", "ls")
    assert(has(s, "NOTE.TXT"), "ls missed note.txt")
    assert(not has(s, "NOTE2"), "mkhex/echo wrote a file they should not have")
    assert(has(s, "T.TXT"), "ls missed t.txt")
    assert(has(s, "U.TXT"), "ls missed u.txt")
    assert(not has(s, "V.TXT"), "v.txt was written despite the hex error")
    log("check: ls after writes")

    s = phase("unknown", "xyz")
    assert(has(s, "$ XYZ"), "unknown command not echoed")
    assert(not has(s, "COMMANDS:"), "unknown command should not print help")
    log("check: unknown command")

    -- The in-OS assembler (`run asm FILE`).  The source is built with mkhex:
    --   JMP m / db "pp" / m: RET
    -- If pass 1 failed to count the db "..." string, m lands inside it, the
    -- 'p's execute as opcode 0x70 (HLT), and the machine freezes instead of
    -- the app returning to the shell.
    s = phase("asm usage", "run asm", 800000, 400000)
    assert(has(s, "USAGE: ASM FILE"), "run asm without a file did not print the usage")
    log("check: asm usage")

    s = phase("mkhex asm source",
        "mkhex a.asm 4A4D50206D0A646220227070220A6D3A205245540A")
    log("check: mkhex a.asm (assembler input)")

    s = phase("run asm a.asm", "run asm a.asm", 2000000, 600000)
    if not has(s, "OK 34") then
        -- failure diagnostics: disk truth, reader output, walk state
        dumpDir("FAIL run asm")
        local function hexDump(store, base, n, label)
            local hx, asc = {}, {}
            for k = 0, n - 1 do
                local b = store[base + k] or 0
                hx[#hx + 1] = string.format("%02X", b)
                asc[#asc + 1] = (b >= 32 and b < 127) and string.char(b)
                    or (b == 0 and "|" or ".")
            end
            log(("%s: %s"):format(label, table.concat(hx, " ")))
            log(("%s: %s"):format(label, table.concat(asc)))
        end
        for i = 0, 31 do
            local e = 0x10 + i * 32
            local nm = {}
            for k = 0, 15 do
                local c = machine.disk[e + k + 1] or 0
                if c == 0 then break end
                nm[#nm + 1] = string.char(c)
            end
            if table.concat(nm) == "a.asm" then
                local st = machine.disk[e + 16 + 1]
                local len = machine.disk[e + 17 + 1]
                    + machine.disk[e + 18 + 1] * 256
                log(("a.asm start=%d len=%d"):format(st, len))
                hexDump(machine.disk, st * 256 + 1, len, "a.asm disk")
            end
        end
        hexDump(machine.ram, 0x1300 + 1, 48, "SRC")
        for a = 0x2000, 0x3410 do
            local r = {}
            for j = 0, 5 do r[#r + 1] = machine.ram[a + j + 1] or 0 end
            if r[1] == 0 and r[2] == 0 and r[4] == 0x13 then
                log(("walk state at 0x%04X: pend=0x%02X13 lineno=%d")
                    :format(a, r[3], r[5]))
            end
        end
        assert(false, "assembler did not print OK 34")
    end
    log("check: run asm a.asm -> OK 34")

    s = phase("run assembled app", "run a", 800000, 400000)
    do
        local phys, curY = readScreen(machine, fontMap)
        local promptRow = phys[curY]:gsub("%s+$", "")
        assert(promptRow == "$",
            "assembled app did not return to the shell, cursor row is <"
                .. promptRow .. ">")
    end
    log("check: run a returns to the shell")

    s = phase("mkhex bad source", "mkhex b.asm 4C4441206E6F70650A")
    s = phase("run asm error", "run asm b.asm", 1200000, 400000)
    assert(has(s, "E1 UNDEF"), "undefined symbol not reported as E1 UNDEF")
    log("check: assembler error (E1 UNDEF)")

    -- Wrapping past row 19 must wipe the screen: PUTC never clears dark
    -- pixels, so a reused row would blend the new glyphs into the old ones
    -- and every affected cell would decode to '?' (not a font glyph).
    -- Each "help" costs 8 rows (echo + 7 output), so four of them run past
    -- the bottom row of the 19-row screen.
    -- the 7-line help means four of them cross the bottom twice: budget for
    -- `clear`'s CLS plus the wrap's CLS (each ~160k steps)
    s = phase("wrap (help x4)", "help\rhelp\rhelp\rhelp", 4000000, 800000)
    assert(not s:find("?", 1, true),
        "blended glyphs after screen wrap -- top row was not cleared")
    assert(has(s, "HALT"), "help output missing after wrap")
    assert(has(s, "CAT F RUN F"), "post-wrap lines missing")
    log("check: wrap clears the screen")

    -- the prompt must be the newest line (cursor row)
    do
        local phys, curY = readScreen(machine, fontMap)
        local promptRow = phys[curY]:gsub("%s+$", "")
        assert(promptRow == "$",
            "cursor row should be the bare prompt, got <" .. promptRow .. ">")
        log("check: prompt returned")
    end

    log("ALL SDK TESTS PASSED")
    if logfile then logfile.close() end
    os.shutdown(0)
end

local ok, err = pcall(main)
if not ok then
    if logfile then pcall(function() logfile.close() end) end
    local f = fs.open("m16k/sdktest.txt", "a")
    local msg = "SDK TEST FAILED: " .. tostring(err)
    print(msg)
    if f then f.write(msg) f.close() end
    os.shutdown(1)
end
