-- m16k.lua -- M16K emulator for CraftOS-PC.
--
-- Usage (from the CraftOS shell, with this file at the computer root):
--   m16k                          run the built-in demo (default storage)
--   m16k textdemo                 run the built-in text example
--   m16k -p drives                run with the "drives" storage plugin
--                                 (top drive = RAM, right drive = disk)
--   m16k myprog.asm               assemble + run an M16K program
--   m16k myprog.lua               Lua source generator returning asm text
--   m16k myprog.m16k              run a raw binary (loaded at 0x0200)
--   m16k --list-plugins           show installed storage plugins
--   m16k -h                       help
--
-- A bare name like "textdemo" or "demo" is looked up in
-- m16k/programs/<name>.lua (generator) or m16k/programs/<name>.asm.
--
-- Storage: with no -p plugin, the machine keeps BOTH its 16 KB RAM image
-- and its 32 KB disk image on the computer's own disk (fs API, under
-- m16k/data/). Plugins can redirect those stores elsewhere (see
-- m16k/storage.lua and m16k/plugins/drives.lua).
--
-- A BIOS ROM (m16k/rom/bios.asm) is mapped read-only at 0xE000: it holds
-- the text font and video services (INIT/CLS/SETCOL/SETCUR/PUTC/PUTS),
-- which guest programs CALL. RAM 0x00F0-0x00FF is reserved as the BIOS
-- data area.

local args = { ... }

--------------------------------------------------------------------
-- locate ourselves (works from the root or a subdirectory)
--------------------------------------------------------------------
local progPath = shell.getRunningProgram()
local dir = fs.getDir(progPath)
local base
if dir == "" or dir == "." then
    base = ""
elseif dir == "/" then
    base = "/"
else
    base = dir .. "/"
end

local function loadMod(rel)
    local path = base .. rel
    local fn, lerr = loadfile(path)
    if not fn then
        error("m16k: cannot load " .. rel .. ": " .. tostring(lerr), 0)
    end
    local ok, mod = pcall(fn, base)
    if not ok then
        error("m16k: error loading " .. rel .. ": " .. tostring(mod), 0)
    end
    return mod
end

local asm = loadMod("m16k/asm.lua")
local pp = loadMod("m16k/sdk/pp.lua")
local cpuModule = loadMod("m16k/cpu.lua")
local machineMod = loadMod("m16k/machine.lua")
local display = loadMod("m16k/display.lua")
local storage = loadMod("m16k/storage.lua")
local mufs = loadMod("m16k/mufs.lua")

--------------------------------------------------------------------
-- arguments
--------------------------------------------------------------------
local pluginName, programFile, strict
local i = 1
while i <= #args do
    local a = args[i]
    if a == "-p" or a == "--plugin" then
        i = i + 1
        pluginName = args[i]
        if not pluginName then
            print("m16k: -p requires a plugin name")
            return
        end
    elseif a == "--strict" then
        strict = true
    elseif a == "--list-plugins" then
        local names = storage.listPlugins(base)
        if #names == 0 then
            print("No plugins installed in " .. base .. "m16k/plugins/")
        else
            print("Installed plugins:")
            for _, n in ipairs(names) do print("  " .. n) end
        end
        return
    elseif a == "-h" or a == "--help" then
        print("usage: m16k [-p plugin] [--strict] [program]")
        print("  program: .asm/.s source, .lua source generator, .m16k raw")
        print("           or a bare name (m16k/programs/<name>.lua|.asm)")
        print("  built-ins: demo (default), textdemo")
        print("       m16k --list-plugins")
        return
    elseif a:sub(1, 1) == "-" then
        print("m16k: unknown option " .. a .. " (try -h)")
        return
    else
        programFile = a
    end
    i = i + 1
end

--------------------------------------------------------------------
-- storage backend (plugin, or default = the computer's disk)
--------------------------------------------------------------------
local backend, storageLabel = storage.open(pluginName, base, {}, strict)

--------------------------------------------------------------------
-- program
--------------------------------------------------------------------
local function readFile(path)
    local h, err = fs.open(path, "rb")
    if not h then
        error("cannot open " .. path .. ": " .. tostring(err), 0)
    end
    local data = h.readAll()
    h.close()
    return data
end

--------------------------------------------------------------------
-- prebuilt MEX artifacts
--
-- myos.asm does `%incbin "m16k/build/hello.mx"` -- that is a *build*
-- artifact, not source. A fresh checkout, a partial upload, or a copy that
-- skipped m16k/build/ would otherwise die inside the preprocessor with
-- "%incbin file not found". Build it here, on demand, from
-- m16k/sdk/examples/hello.asm, so the SDK is self-contained: nobody has to
-- remember to ship (or rebuild) a .mx file.
--
-- asm.mx is built here too, but it is NOT %incbin'd: ~5 KB will not fit
-- in the kernel under the gates at 0x1F00. The run loop further down
-- writes it straight onto the MUFS disk once the disk is formatted.
--------------------------------------------------------------------
local MX_ARTIFACTS = { "hello", "asm" }   -- MEX artifacts built on demand

local function ensureMx(name)
    local outPath = base .. "m16k/build/" .. name .. ".mx"
    if fs.exists(outPath) then return end          -- already built

    local srcPath = base .. "m16k/sdk/examples/" .. name .. ".asm"
    if not fs.exists(srcPath) then
        error("m16k: " .. outPath .. " is missing and there is no source at "
            .. srcPath .. " (build it with: mkmx " .. name .. ".asm)", 0)
    end

    local src, perr = pp.process(readFile(srcPath), fs.getDir(srcPath))
    if not src then
        error("m16k: cannot build " .. name .. ".mx: " .. tostring(perr), 0)
    end
    local o, b = asm.assemble(src)
    if not o then
        error("m16k: cannot build " .. name .. ".mx: " .. tostring(b), 0)
    end
    if o ~= 0x2000 then
        error(("m16k: %s.asm must start at org 0x2000 to be a MEX (got 0x%04X)")
            :format(name, o), 0)
    end

    -- 12-byte MEX header: 'M','X',1,0 | load LE | entry-off LE | len LE | cksum
    local u = unpack or table.unpack
    local n = #b
    local hdr = { 0x4D, 0x58, 1, 0, 0x00, 0x20, 16, 0, n % 256,
        math.floor(n / 256) % 256, 0, 0 }
    local sum = 0
    for i = 1, 10 do sum = sum + hdr[i] end
    hdr[11] = sum % 256

    local parts, t = {}, {}
    parts[#parts + 1] = string.char(u(hdr))
    for _, v in ipairs(b) do
        t[#t + 1] = v
        if #t == 64 then parts[#parts + 1] = string.char(u(t)); t = {} end
    end
    if #t > 0 then parts[#parts + 1] = string.char(u(t)) end

    pcall(fs.makeDir, base .. "m16k/build")
    local h, werr = fs.open(outPath, "wb")
    if not werr and not h then werr = "cannot open for writing" end
    if not h then
        error("m16k: cannot write " .. outPath .. ": " .. tostring(werr), 0)
    end
    h.write(table.concat(parts))
    h.close()
end

local function ensureMxArtifacts()
    for _, name in ipairs(MX_ARTIFACTS) do ensureMx(name) end
end

-- asm.mx for the disk (see the MX_ARTIFACTS note above). Best effort: a
-- broken assembler source must not stop the machine from booting -- a
-- failure here only means `run asm` will be missing.
local asmImg
do
    local ok, res = pcall(function()
        ensureMx("asm")
        return readFile(base .. "m16k/build/asm.mx")
    end)
    if ok then
        asmImg = res
    else
        print("m16k: asm.mx unavailable: " .. tostring(res))
    end
end
local asmPlaced = false

-- run a Lua source generator: must return a string of assembly source
local function loadSourceGenerator(path)
    local fn, lerr = loadfile(path)
    if not fn then
        error("m16k: cannot load " .. path .. ": " .. tostring(lerr), 0)
    end
    local ok, src = pcall(fn, base)
    if not ok then
        error("m16k: error in " .. path .. ": " .. tostring(src), 0)
    end
    if type(src) ~= "string" then
        error("m16k: " .. path .. " did not return assembly source", 0)
    end
    return src
end

local org, programLabel, bytes

-- run the SDK preprocessor (%include/%define/%macro/...) on assembly source
local function preprocess(src, dir, label)
    ensureMxArtifacts()     -- %incbin'd .mx files must exist first
    local out, perr = pp.process(src, dir)
    if not out then
        error("m16k: preprocess failed (" .. label .. "): " .. tostring(perr), 0)
    end
    return out
end

local function assembleSource(src, label)
    local o, b = asm.assemble(src)
    if not o then
        error("m16k: assembly failed (" .. label .. "): " .. tostring(b), 0)
    end
    org, bytes = o, b
    programLabel = label .. string.format(" (0x%04X, %d bytes)", o, #b)
end

local function loadRaw(path)
    local data = readFile(path)
    org = 0x0200
    bytes = machineMod.bytesToTable(data, #data)
    programLabel = path .. string.format(" (raw, 0x%04X, %d bytes)", org, #bytes)
end

if not programFile then
    assembleSource(loadSourceGenerator(base .. "m16k/programs/demo.lua"),
        "built-in demo")
else
    local lower = programFile:lower()
    local builtinLua = base .. "m16k/programs/" .. programFile .. ".lua"
    local builtinAsm = base .. "m16k/programs/" .. programFile .. ".asm"

    if lower:match("%.asm$") or lower:match("%.s$") then
        assembleSource(preprocess(readFile(programFile),
            fs.getDir(programFile), programFile), programFile)
    elseif lower:match("%.lua$") then
        assembleSource(loadSourceGenerator(programFile), programFile)
    elseif fs.exists(programFile) then
        loadRaw(programFile)
    elseif fs.exists(builtinLua) then
        assembleSource(loadSourceGenerator(builtinLua),
            "m16k/programs/" .. programFile .. ".lua")
    elseif fs.exists(builtinAsm) then
        assembleSource(preprocess(readFile(builtinAsm),
            base .. "m16k/programs",
            "m16k/programs/" .. programFile .. ".asm"),
            "m16k/programs/" .. programFile .. ".asm")
    else
        error("m16k: program not found: " .. programFile
            .. " (tried as file, then m16k/programs/"
            .. programFile .. ".lua/.asm)", 0)
    end
end

--------------------------------------------------------------------
-- BIOS ROM (assembled fresh each boot; failures are fatal -- programs
-- like "textdemo" depend on it)
--------------------------------------------------------------------
local BIOS_BASE = 0xE000
local biosPath = base .. "m16k/rom/bios.asm"
local biosOrg, biosBytes = asm.assemble(readFile(biosPath))
if not biosOrg then
    error("m16k: BIOS failed to assemble (" .. biosPath .. "): "
        .. tostring(biosBytes), 0)
end
if biosOrg ~= BIOS_BASE then
    error(string.format("m16k: BIOS must start at 0x%04X (got 0x%04X)",
        BIOS_BASE, biosOrg), 0)
end

--------------------------------------------------------------------
-- build the machine
--------------------------------------------------------------------
local RAM_SIZE = storage.RAM_SIZE
local DISK_SIZE = storage.DISK_SIZE

local ramData = backend.ramRead and backend.ramRead(0, RAM_SIZE) or nil
local diskData = backend.diskRead and backend.diskRead(0, DISK_SIZE) or nil

local machine = machineMod.create({
    cpuModule = cpuModule,
    backend = backend,
    ramSize = RAM_SIZE,
    diskSize = DISK_SIZE,
    ramData = ramData,
    diskData = diskData,
    romBase = BIOS_BASE,
    romBytes = biosBytes,
})

machine:loadProgram(org, bytes)

--------------------------------------------------------------------
-- boot banner (before we switch to graphics mode)
--------------------------------------------------------------------
print("M16K emulator -- 16K RAM, 306x171 graphics")
print("storage: " .. storageLabel)
print("bios:    m16k/rom/bios.asm (" .. #biosBytes .. " bytes @ 0xE000)")
print("program: " .. programLabel)
if not programFile then
    print("controls: any key = recolour ball, q = halt, Ctrl+T = quit")
elseif programFile == "textdemo"
    or programFile:lower():match("%.lua$") then
    print("controls: any key = repaint in next colour, q = halt, Ctrl+T = quit")
end
print("")

local gfx = display.init()
if not gfx then
    print("(no graphics mode -- rendering text fallback)")
end

--------------------------------------------------------------------
-- main loop
--------------------------------------------------------------------
local SLICE = 40000          -- instructions per time slice
local TICK = 0.05            -- seconds per slice
local FLUSH_EVERY = 40       -- ticks between flushes (2 s)

local running = true
local runErr
local tick = 0

local function present()
    machine.vramDirty = false
    machine.presentReq = false
    local ok, err = pcall(display.present, machine.vram)
    if not ok then
        print("m16k: present error: " .. tostring(err))
    end
end

local function flushNow()
    if machine:isDirty() then
        local ok, err = pcall(machine.flush, machine)
        if not ok then
            print("m16k: flush failed (drive ejected?): " .. tostring(err))
        end
    end
end

-- map non-character keys to M16K key codes (skip any the host lacks)
local KEYMAP
local function mapKey(k)
    if not KEYMAP then
        KEYMAP = {}
        local function bind(name, code)
            if keys[name] ~= nil then KEYMAP[keys[name]] = code end
        end
        bind("enter", 13)
        bind("backspace", 8)
        bind("tab", 9)
        bind("escape", 27)
        bind("up", 19)
        bind("down", 20)
        bind("left", 17)
        bind("right", 18)
        bind("home", 2)
        bind("end", 3)
        bind("delete", 127)
    end
    return KEYMAP[k]
end

local timer = os.startTimer(TICK)

while running do
    local ok, err = pcall(function()
        for _ = 1, SLICE do
            if machine:step() == "halt" then
                running = false
                return
            end
        end
    end)
    if not ok then
        runErr = err
        running = false
        break
    end

    -- asm.mx lives on the disk, not in the kernel image (~5 KB: it will
    -- not fit under the gates). Drop it on the instant the disk shows a
    -- formatted MUFS -- before this machine can act on a keystroke,
    -- whether the disk was already formatted or myos has just formatted
    -- a blank one this very slice.
    if asmImg and not asmPlaced and mufs.formatted(machine.disk) then
        asmPlaced = true
        if not mufs.exists(machine.disk, "asm.mx") then
            local okI, resI, whyI =
                pcall(mufs.install, machine.disk, "asm.mx", asmImg)
            if okI and resI then
                machine.diskDirty = true
            else
                print("m16k: asm.mx not placed on disk: "
                    .. tostring(okI and whyI or resI))
            end
        end
    end

    if machine.vramDirty or machine.presentReq then
        present()
    end

    -- os.pullEvent() THROWS "Terminated" on Ctrl+T in CraftOS-PC/CC: Tweaked
    -- instead of returning a "terminate" event -- and this call used to sit
    -- outside the pcall above, so Ctrl+T leaked the error straight out of the
    -- emulator and skipped the cleanup below (final frame, RAM/disk flush,
    -- terminal restore). Pull it through pcall so quitting still saves.
    local okEv, ev1, ev2 = pcall(os.pullEvent)
    if not okEv then
        if tostring(ev1) ~= "Terminated" then runErr = ev1 end
        running = false
        break
    end
    if ev1 == "timer" and ev2 == timer then
        timer = os.startTimer(TICK)
        tick = tick + 1
        if tick % FLUSH_EVERY == 0 then
            flushNow()
        end
    elseif ev1 == "char" then
        machine:pushKey((ev2 or ""):byte() or 0)
    elseif ev1 == "key" then
        local code = mapKey(ev2)
        if code then machine:pushKey(code) end
    elseif ev1 == "terminate" then
        running = false
    end
end

-- final frame + persistence + terminal restore
if machine.vramDirty or machine.presentReq then present() end
flushNow()
local okClose, errClose = pcall(machine.close, machine)
display.shutdown()

print("")
if runErr then
    print("M16K error: " .. tostring(runErr))
    print("(RAM/disk may not have been saved)")
elseif not okClose then
    print("M16K halted (save failed: " .. tostring(errClose) .. ")")
else
    print("M16K halted.")
end
