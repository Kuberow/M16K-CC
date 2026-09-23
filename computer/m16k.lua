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

    if machine.vramDirty or machine.presentReq then
        present()
    end

    local ev = { os.pullEvent() }
    local evname = ev[1]
    if evname == "timer" and ev[2] == timer then
        timer = os.startTimer(TICK)
        tick = tick + 1
        if tick % FLUSH_EVERY == 0 then
            flushNow()
        end
    elseif evname == "char" then
        machine:pushKey((ev[2] or ""):byte() or 0)
    elseif evname == "key" then
        local code = mapKey(ev[2])
        if code then machine:pushKey(code) end
    elseif evname == "terminate" then
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
