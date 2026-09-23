-- m16k/smoketest.lua -- headless self-test for the M16K emulator.
-- Run with:  CraftOS-PC.exe --headless --script <abs path to this file>
-- Writes a log to m16k/testresult.txt and exits with code 0/1
-- (CraftOS-PC's os.shutdown accepts a return code in headless mode).

local W = 306

-- VRAM packs 2 pixels per byte: high nibble = even x, low nibble = odd x
local function px(vram, x, y)
    local i = y * W + x
    local b = vram[math.floor(i / 2) + 1] or 0
    if i % 2 == 0 then return math.floor(b / 16) end
    return b % 16
end

local logfile = nil
local function log(s)
    print(s)
    if logfile then
        logfile.write(s .. "\n")
        logfile.flush()
    end
end

local function main()
    logfile = fs.open("m16k/testresult.txt", "wb")

    -- 1. assemble the built-in demo -------------------------------------
    local asm = loadfile("m16k/asm.lua")("")
    local cpuModule = dofile("m16k/cpu.lua")
    local machineMod = dofile("m16k/machine.lua")
    local storage = dofile("m16k/storage.lua")

    -- 0. BIOS ROM: font + video services --------------------------------
    local bh = fs.open("m16k/rom/bios.asm", "rb")
    assert(bh, "m16k/rom/bios.asm is missing")
    local biosSrc = bh.readAll()
    bh.close()
    local borg, bbytes = asm.assemble(biosSrc)
    assert(borg, "BIOS assemble failed: " .. tostring(bbytes))
    assert(borg == 0xE000, "BIOS org is 0x" .. string.format("%04X", borg))
    assert(#bbytes <= 0x800, "BIOS too big for its ROM hole: " .. #bbytes)
    for _, e in ipairs({ 0xE400, 0xE410, 0xE420, 0xE430, 0xE440, 0xE450, 0xE460 }) do
        local op = bbytes[e - 0xE000 + 1]
        assert(op == 0x30,
            string.format("BIOS entry 0x%04X is not a JMP (got %s)", e, tostring(op)))
    end
    assert(bbytes[1] == 0x00 and bbytes[8] == 0x00, "space glyph is not blank")
    local aoff = (0x41 - 0x20) * 8 + 1
    assert(bbytes[aoff] == 0x70,
        string.format("'A' glyph row 0 = %s, want 0x70", tostring(bbytes[aoff])))
    log(("BIOS ROM OK: %d bytes @ 0xE000 (font + services)"):format(#bbytes))

    local src = dofile("m16k/programs/demo.lua")
    assert(type(src) == "string", "demo did not return source")
    local org, bytes = asm.assemble(src)
    assert(org, "assemble failed: " .. tostring(bytes))
    assert(org == 0x0200, "bad org: " .. tostring(org))
    log(("assemble OK: %d bytes at 0x%04X"):format(#bytes, org))

    -- assembler rejects junk
    local o2, e2 = asm.assemble("FOO #1")
    assert(o2 == nil and e2, "bad mnemonic was not caught")

    -- 2. default storage backend = the computer's own disk --------------
    local backend = storage.open(nil, "", {}, true)
    assert(backend.name == "default (computer disk)", "bad default label")

    local machine = machineMod.create({
        cpuModule = cpuModule,
        backend = backend,
        ramSize = storage.RAM_SIZE,
        diskSize = storage.DISK_SIZE,
        ramData = backend.ramRead(0, storage.RAM_SIZE),
        diskData = backend.diskRead(0, storage.DISK_SIZE),
        romBase = 0xE000,
        romBytes = bbytes,
    })
    machine:loadProgram(org, bytes)
    assert(machine.cpu.pc == 0x0200, "pc not set")

    -- 3. run: stripes must paint VRAM ----------------------------------
    local halted = false
    for _ = 1, 300000 do
        if machine:step() == "halt" then halted = true break end
    end
    assert(not halted, "demo halted during startup")
    log("boot run OK")

    for _, y in ipairs({ 0, 1, 15, 31, 170 }) do
        local want = y % 16
        for x = 0, 63 do
            local got = px(machine.vram, x, y)
            assert(got == want,
                ("row %d px %d = %d, want %d"):format(y, x, got, want))
        end
    end
    log("stripes OK")

    -- 4. run long enough for the ball to cross and bounce; it must stay
    --    inside row 32 (0x5320..0x53B8) and never spill into rows 31/33
    for _ = 1, 700000 do
        if machine:step() == "halt" then halted = true break end
    end
    assert(not halted, "demo halted during ball run")

    local function rowIs(y, colour)
        for x = 0, W - 1 do
            local v = px(machine.vram, x, y)
            if v ~= colour then
                return false, x, v
            end
        end
        return true
    end

    -- row 31 is colour 15 (black), row 33 is colour 1; the ball only ever
    -- writes row 32 (its packed byte offset stays inside that row)
    local ok31, x31, v31 = rowIs(31, 15)
    assert(ok31, ("row 31 polluted at x=%s: %s"):format(tostring(x31), tostring(v31)))
    local ok33, x33, v33 = rowIs(33, 1)
    assert(ok33, ("row 33 polluted at x=%s: %s"):format(tostring(x33), tostring(v33)))

    -- row 32: all stripe colour 0 except at most one ball pixel
    local ballPixels = 0
    for x = 0, W - 1 do
        local v = px(machine.vram, x, 32)
        if v ~= 0 then ballPixels = ballPixels + 1 end
    end
    assert(ballPixels <= 1, "ball left " .. ballPixels .. " pixels in row 32")
    log("ball bounce OK")

    -- 5. 'q' key must halt the machine ---------------------------------
    machine:pushKey(113)
    for _ = 1, 300000 do
        if machine:step() == "halt" then halted = true break end
    end
    assert(halted, "'q' did not halt the machine")
    log("halt on 'q' OK")

    -- 6. flush persists RAM to the computer's disk ----------------------
    machine:flush()
    assert(fs.exists("m16k/data/ram.bin"), "ram.bin was not written")
    assert(fs.getSize("m16k/data/ram.bin") == storage.RAM_SIZE,
        "ram.bin size is " .. tostring(fs.getSize("m16k/data/ram.bin")))
    assert(fs.exists("m16k/data/disk.bin"), "disk.bin was not written")
    assert(fs.getSize("m16k/data/disk.bin") == storage.DISK_SIZE,
        "disk.bin size is " .. tostring(fs.getSize("m16k/data/disk.bin")))

    local h = fs.open("m16k/data/ram.bin", "rb")
    local data = h.readAll()
    h.close()
    assert(data:byte(0x0201) == bytes[1],
        "persisted RAM does not contain the program")
    log("default backend flush OK (m16k/data/ram.bin + disk.bin)")

    -- 7. drives plugin: strict mode must fail without drives attached,
    --    non-strict mode must revert to the computer's disk -------------
    local okp, errp = pcall(storage.open, "drives", "", {}, true)
    assert(not okp, "drives plugin strict-open should fail with no drives")
    assert(tostring(errp):find("peripheral") or tostring(errp):find("drive"),
        "unexpected strict error: " .. tostring(errp))
    local b2, l2 = storage.open("drives", "", {}, false)
    assert(b2 and l2 == "default (computer disk)",
        "non-strict drives open should revert, got: " .. tostring(l2))
    log("plugin fallback OK (drives -> computer disk)")

    -- 7b. the BIOS ROM is read-only for guest programs ------------------
    local worg, wbytes = asm.assemble(
        "org 0x0200\n LDA #0xAA\n STA 0xE000\n HLT")
    assert(worg, "rom-test assemble failed: " .. tostring(wbytes))
    local wmach = machineMod.create({
        cpuModule = cpuModule,
        backend = backend,
        ramSize = storage.RAM_SIZE,
        diskSize = storage.DISK_SIZE,
        ramData = backend.ramRead(0, storage.RAM_SIZE),
        diskData = backend.diskRead(0, storage.DISK_SIZE),
        romBase = 0xE000,
        romBytes = bbytes,
    })
    wmach:loadProgram(worg, wbytes)
    local whalted = false
    for _ = 1, 100 do
        if wmach:step() == "halt" then whalted = true break end
    end
    assert(whalted, "rom-test did not halt")
    assert(wmach.rom[1] == 0x00,
        "guest write modified the BIOS ROM: " .. tostring(wmach.rom[1]))
    log("BIOS ROM write-protect OK")

    -- 7c. CALL/RET round-trip + PUSHA/POPA (BIOS services depend on it) --
    local corg, cbytes = asm.assemble([[
org 0x0200
  LDA #0x11
  PUSHA
  CALL sub        ; sub sets A = 0x77 and returns
  POPA            ; must restore A = 0x11
  HLT
sub:
  LDA #0x77
  RET
]])
    assert(corg, "stack-test assemble failed: " .. tostring(cbytes))
    local cmach = machineMod.create({
        cpuModule = cpuModule,
        backend = backend,
        ramSize = storage.RAM_SIZE,
        diskSize = storage.DISK_SIZE,
        ramData = backend.ramRead(0, storage.RAM_SIZE),
        diskData = backend.diskRead(0, storage.DISK_SIZE),
        romBase = 0xE000,
        romBytes = bbytes,
    })
    cmach:loadProgram(corg, cbytes)
    local chalted = false
    for _ = 1, 200 do
        if cmach:step() == "halt" then chalted = true break end
    end
    assert(chalted, "stack-test did not halt (bad RET)")
    assert(cmach.cpu.a == 0x11,
        string.format("stack-test A = %02X, want 11 (POPA after CALL)",
            cmach.cpu.a))
    assert(cmach.cpu.sp == 0x4000,
        string.format("stack-test SP = %04X, want 4000", cmach.cpu.sp))
    log("CALL/RET + PUSHA/POPA round-trip OK")

    -- 8. textdemo: a real guest program (no font, no VRAM pokes) that
    --    renders text through the BIOS ----------------------------------
    local tsrc = dofile("m16k/programs/textdemo.lua")
    assert(type(tsrc) == "string", "textdemo did not return source")
    assert(not tsrc:find("STA 0x4", 1, true),
        "textdemo pokes VRAM directly instead of using the BIOS")
    local torg, tbytes = asm.assemble(tsrc)
    assert(torg, "textdemo assemble failed: " .. tostring(tbytes))
    assert(torg == 0x0200, "textdemo bad org: " .. tostring(torg))
    assert(torg + #tbytes <= 0x4000,
        ("textdemo overflows RAM: %d bytes"):format(#tbytes))
    assert(#tbytes < 1024,
        ("textdemo is %d bytes -- too big for a pure BIOS client"):format(#tbytes))
    log(("textdemo assembles OK: %d bytes (BIOS does the drawing)")
        :format(#tbytes))

    local tmachine = machineMod.create({
        cpuModule = cpuModule,
        backend = backend,
        ramSize = storage.RAM_SIZE,
        diskSize = storage.DISK_SIZE,
        ramData = backend.ramRead(0, storage.RAM_SIZE),
        diskData = backend.diskRead(0, storage.DISK_SIZE),
        romBase = 0xE000,
        romBytes = bbytes,
    })
    tmachine:loadProgram(torg, tbytes)
    local thalted = false
    for _ = 1, 300000 do
        if tmachine:step() == "halt" then thalted = true break end
    end
    assert(not thalted, "textdemo halted too early")

    -- line 1 is "M16K DEMO"; font row 0 of 'M' (0x50) has ink at cell
    -- offset 1, so pixel (1,0) must carry the text colour
    assert(px(tmachine.vram, 1, 0) == 4,
        "pixel (1,0) = " .. tostring(px(tmachine.vram, 1, 0))
            .. ", want text colour 4")

    -- top text band (rows 0..6 = line 1 "M16K DEMO"): yellow on black
    local lit = 0
    for y = 0, 6 do
        for x = 0, W - 1 do
            if px(tmachine.vram, x, y) == 4 then lit = lit + 1 end
        end
    end
    assert(lit > 50, "textdemo drew too few text pixels: " .. lit)

    -- row 7 is a blank row of the top text cells: pure background
    for x = 0, W - 1 do
        local v = px(tmachine.vram, x, 7)
        assert(v == 15,
            ("textdemo background row 7 px %d = %d, want 15"):format(x, v))
    end

    tmachine:pushKey(113)
    for _ = 1, 300000 do
        if tmachine:step() == "halt" then thalted = true break end
    end
    assert(thalted, "textdemo did not halt on 'q'")
    log("textdemo BIOS text + halt OK")

    log("ALL SMOKE TESTS PASSED")
    if logfile then logfile.close() end
    os.shutdown(0)
end

local ok, err = pcall(main)
if not ok then
    if logfile then pcall(function() logfile.close() end) end
    local f = fs.open("m16k/testresult.txt", "a")
    local msg = "SMOKE TEST FAILED: " .. tostring(err)
    print(msg)
    if f then f.write(msg) f.close() end
    os.shutdown(1)
end
