-- m16k/sdktest.lua -- SDK end-to-end test (smoketest-style, headless).
--
-- Verifies the preprocessor, the SDK includes, a MEX build (mkmx-style),
-- the myos kernel, first-boot MUFS format + sample install, and the shell
-- (help / ls / cat / run / rm / clear / backspace / unknown command).
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
    -- 3. build the MEX app (exactly what mkmx does)
    ------------------------------------------------------------------
    local hsrc = readAll("m16k/sdk/examples/hello.asm")
    assert(hsrc, "m16k/sdk/examples/hello.asm is missing")
    local hpp, herr = pp.process(hsrc, "m16k/sdk/examples")
    assert(hpp, "hello preprocess failed: " .. tostring(herr))
    local horg, hbytes = asm.assemble(hpp)
    assert(horg == 0x2000, "hello org is " .. tostring(horg or hbytes))
    assert(0x2000 + #hbytes <= 0x3000, "hello app too big")

    local n = #hbytes
    local hdr = { 0x4D, 0x58, 1, 0, 0x00, 0x20, 16, 0, n % 256,
        math.floor(n / 256) % 256, 0, 0 }
    local sum = 0
    for i = 1, 10 do sum = sum + hdr[i] end
    hdr[11] = sum % 256

    local unpackf = unpack or table.unpack
    local parts, t = {}, {}
    parts[#parts + 1] = string.char(unpackf(hdr))
    for _, b in ipairs(hbytes) do
        t[#t + 1] = b
        if #t == 64 then parts[#parts + 1] = string.char(unpackf(t)); t = {} end
    end
    if #t > 0 then parts[#parts + 1] = string.char(unpackf(t)) end
    local mx = table.concat(parts)
    assert(mx:byte(1) == 0x4D and mx:byte(2) == 0x58, "MEX magic missing")

    pcall(fs.makeDir, "m16k/build")
    local bhx = fs.open("m16k/build/hello.mx", "wb")
    assert(bhx, "cannot write m16k/build/hello.mx")
    bhx.write(mx)
    bhx.close()
    log(("mex build OK: hello.mx = %d bytes"):format(#mx))

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
        0x1F12, 0x1F15 }) do
        assert(obytes[a - 0x0200 + 1] == 0x30,
            string.format("gate 0x%04X is not a JMP", a))
    end
    log(("myos OK: %d bytes, gates verified at 0x1F00"):format(#obytes))

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
    local function phase(label, cmd, budget)
        typeKeys("clear\r" .. cmd .. "\r")
        local why = drain(budget or 400000, 30000)
        assert(why == nil,
            ("%s: machine did not go idle (%s), %d keys left")
                :format(label, tostring(why), #machine.keyq))
        -- `clear` runs a full-screen CLS, and drain() returns the instant the
        -- key queue empties (which is *before* the command is dispatched), so
        -- give the machine a generous fixed budget to finish the output
        for _ = 1, 400000 do machine:step() end
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

    s = phase("rm", "rm readme.txt")
    log("check: rm")

    s = phase("ls after rm", "ls")
    assert(has(s, "HELLO.MX"), "hello.mx vanished after rm")
    assert(not has(s, "README.TXT"), "readme.txt still listed after rm")
    log("check: ls after rm")

    s = phase("cat after rm", "cat readme.txt")
    assert(has(s, "NO FILE"), "cat after rm should report NO FILE")
    log("check: cat after rm")

    s = phase("unknown", "xyz")
    assert(has(s, "$ XYZ"), "unknown command not echoed")
    assert(not has(s, "COMMANDS:"), "unknown command should not print help")
    log("check: unknown command")

    -- Wrapping past row 19 must wipe the screen: PUTC never clears dark
    -- pixels, so a reused row would blend the new glyphs into the old ones
    -- and every affected cell would decode to '?' (not a font glyph).
    -- Each "help" costs 6 rows (echo + 5 output), so four of them run past
    -- the bottom row of the 19-row screen.
    s = phase("wrap (help x4)", "help\rhelp\rhelp\rhelp")
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
