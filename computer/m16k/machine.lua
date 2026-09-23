-- m16k/machine.lua -- M16K machine: memory map, I/O ports, key queue, flush.
--
-- Memory map (16-bit address space):
--   0x0000-0x3FFF  RAM (16 KB)  <- persisted through the storage backend
--   0x4000-0xA6FF  VRAM (306x171 framebuffer, 2 pixels per byte: high
--                    nibble = even x, low nibble = odd x; 26163 B of
--                    picture padded to 0x6700 so CLS is a page loop)
--   0xE800-0xEFFF  disk window (4 KB, page selected with OUT 0x40)
--                  <- backed by the storage backend's "disk" store (32 KB)
--   0xE000-0xE7FF  BIOS ROM (m16k/rom/bios.asm): font + video services,
--                  read-only; guest writes are ignored
--
-- Ports:
--   IN  0x00  random byte 0-255
--   IN  0x01  keyboard status: 1 = a key is waiting
--   IN  0x02  keyboard data: next key code (0 if queue empty)
--   OUT 0x10  request a screen present
--   OUT 0x40  select disk window page (0-7)

local machineMod = {}

local floor = math.floor

local unpack = unpack or table.unpack

-- Convert a Lua string into a byte table of exactly `size` entries.
local function bytesToTable(s, size)
    local t = {}
    if s then
        local i = 1
        while i <= #s do
            local last = math.min(i + 511, #s)
            local chunk = { s:byte(i, last) }
            for k = 1, #chunk do
                local idx = i + k - 1
                if idx > size then break end
                t[idx] = chunk[k]
            end
            i = last + 1
        end
    end
    for i = #t + 1, size do t[i] = 0 end
    return t
end

-- Convert a byte table back into a string (chunked to stay under
-- Lua's unpack/stack limits).
local function tableToBytes(t, size)
    local parts = {}
    local i = 1
    while i <= size do
        local last = math.min(i + 199, size)
        local chunk = {}
        for j = i, last do chunk[#chunk + 1] = t[j] or 0 end
        parts[#parts + 1] = string.char(unpack(chunk))
        i = last + 1
    end
    return table.concat(parts)
end

machineMod.bytesToTable = bytesToTable
machineMod.tableToBytes = tableToBytes

-- opts:
--   cpuModule  : cpu.lua module (for cpu.new())
--   backend    : storage backend (ramRead/ramWrite/diskRead/diskWrite/flush)
--   ramSize    : RAM size in bytes (16384)
--   diskSize   : disk size in bytes (32768)
--   ramData    : initial RAM contents (string)
--   diskData   : initial disk contents (string)
--   romBase    : BIOS ROM base address (default 0xE000)
--   romBytes   : BIOS ROM contents (byte table, read-only)
function machineMod.create(opts)
    local cpuMod = opts.cpuModule
    local backend = opts.backend
    local RAM_SIZE = opts.ramSize
    local DISK_SIZE = opts.diskSize
    local ROM_BASE = opts.romBase or 0xE000
    local romBytes = opts.romBytes

    local self = {
        cpu = cpuMod.new(),
        ram = bytesToTable(opts.ramData, RAM_SIZE),
        disk = bytesToTable(opts.diskData, DISK_SIZE),
        rom = romBytes,
        romBase = ROM_BASE,
        vram = {},
        keyq = {},
        diskPage = 0,
        backend = backend,
        vramDirty = true,
        ramDirty = false,
        diskDirty = false,
        presentReq = false,
    }
    -- 306x171 = 52326 pixels = 26163 packed bytes, rounded to a whole page
    -- (0x6700 = 26368) so the BIOS CLS can fill it with a plain page loop
    -- (0x4000-0xA6FF). Both nibbles start at 15 -> the screen starts black.
    local VRAM_SIZE = 0x6700
    for i = 1, VRAM_SIZE do self.vram[i] = 0xFF end

    local pages = floor(DISK_SIZE / 4096)

    local function read(a)
        a = a % 65536
        if a < 0x4000 then
            return self.ram[a + 1]
        elseif a < 0x4000 + VRAM_SIZE then
            return self.vram[a - 0x4000 + 1]
        elseif romBytes and a >= ROM_BASE and a < ROM_BASE + #romBytes then
            return romBytes[a - ROM_BASE + 1]
        elseif a >= 0xE800 and a < 0xF000 then
            local off = self.diskPage * 4096 + (a - 0xE800)
            return self.disk[off + 1] or 0
        end
        return 0
    end

    local function write(a, v)
        a = a % 65536
        v = v % 256
        if a < 0x4000 then
            self.ram[a + 1] = v
            self.ramDirty = true
        elseif a < 0x4000 + VRAM_SIZE then
            self.vram[a - 0x4000 + 1] = v
            self.vramDirty = true
        elseif a >= 0xE800 and a < 0xF000 then
            local off = self.diskPage * 4096 + (a - 0xE800)
            self.disk[off + 1] = v
            self.diskDirty = true
        end
        -- writes elsewhere (ROM hole, MMIO gap) are ignored
    end

    local function input(port)
        if port == 0x00 then
            return math.random(0, 255)
        elseif port == 0x01 then
            return #self.keyq > 0 and 1 or 0
        elseif port == 0x02 then
            if #self.keyq > 0 then
                return table.remove(self.keyq, 1)
            end
            return 0
        end
        return 0
    end

    local function output(port, v)
        if port == 0x10 then
            self.presentReq = true
        elseif port == 0x40 then
            self.diskPage = v % math.max(1, pages)
        end
    end

    function self:step()
        return self.cpu:step(read, write, input, output)
    end

    function self:pushKey(code)
        if #self.keyq < 64 then
            self.keyq[#self.keyq + 1] = code % 256
        end
    end

    -- Load a program image at `org` and reset the CPU to it.
    function self:loadProgram(org, bytes)
        if org < 0 or org + #bytes > 0x4000 then
            error(string.format("m16k: program at 0x%04X (%d bytes) does not fit in RAM",
                org, #bytes), 0)
        end
        for i = 1, #bytes do
            self.ram[org + i] = bytes[i]
        end
        self.ramDirty = true
        self.cpu.pc = org % 65536
        self.cpu.sp = 0x4000
        self.cpu.halted = false
        self.cpu.a, self.cpu.b, self.cpu.x = 0, 0, 0
        self.cpu.z, self.cpu.c, self.cpu.n = false, false, false
    end

    function self:isDirty()
        return self.ramDirty or self.diskDirty
    end

    -- Persist RAM + disk through the storage backend.
    function self:flush()
        if self.ramDirty and backend and backend.ramWrite then
            backend.ramWrite(0, tableToBytes(self.ram, RAM_SIZE))
            self.ramDirty = false
        end
        if self.diskDirty and backend and backend.diskWrite then
            backend.diskWrite(0, tableToBytes(self.disk, DISK_SIZE))
            self.diskDirty = false
        end
        if backend and backend.flush then
            backend.flush()
        end
    end

    function self:close()
        local ok, err = pcall(self.flush, self)
        if backend and backend.close then
            local ok2, err2 = pcall(backend.close)
            if not ok then error(err, 0) end
            if not ok2 then error(err2, 0) end
        elseif not ok then
            error(err, 0)
        end
    end

    return self
end

return machineMod
