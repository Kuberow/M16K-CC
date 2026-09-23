-- m16k/cpu.lua -- M16K CPU core.
--
-- step(rd, wr, inp, outp) executes one instruction.
--   rd(addr) -> byte        wr(addr, byte)
--   inp(port) -> byte       outp(port, byte)
-- Returns "halt" when the CPU is halted, otherwise nil.
-- Control-flow handlers set self.pc themselves and return true;
-- all other handlers return nil and step() commits the advanced pc.
--
-- Flags: Z = result is zero, C = carry (ADD) / no-borrow (SUB, CMP),
--        N = bit 7 of result.
-- Bit ops are written in portable Lua (no 5.3 operators) so this runs
-- on CraftOS-PC's Lua 5.1/5.2 as well as on CC: Tweaked.

local cpu = {}
cpu.__index = cpu

function cpu.new()
    return setmetatable({
        a = 0, b = 0, x = 0,
        pc = 0, sp = 0x4000,
        z = false, c = false, n = false,
        halted = false,
    }, cpu)
end

local floor = math.floor

local function u8(v) return v % 256 end

local function setNZ(self, v)
    self.z = (v == 0)
    self.n = (v >= 128)
end

local function bit_and(a, b)
    local r, m = 0, 1
    for _ = 1, 8 do
        if a % 2 == 1 and b % 2 == 1 then r = r + m end
        a, b, m = floor(a / 2), floor(b / 2), m * 2
    end
    return r
end

local function bit_or(a, b)
    local r, m = 0, 1
    for _ = 1, 8 do
        if a % 2 == 1 or b % 2 == 1 then r = r + m end
        a, b, m = floor(a / 2), floor(b / 2), m * 2
    end
    return r
end

local function bit_xor(a, b)
    local r, m = 0, 1
    for _ = 1, 8 do
        if (a % 2) ~= (b % 2) then r = r + m end
        a, b, m = floor(a / 2), floor(b / 2), m * 2
    end
    return r
end

-- A = A + v with carry
local function doAdd(self, v)
    local r = self.a + v
    self.c = (r > 255)
    self.a = u8(r)
    setNZ(self, self.a)
end

-- A = A - v, C set when no borrow (A >= v)
local function doSub(self, v)
    local r = self.a - v
    self.c = (r >= 0)
    self.a = u8(r)
    setNZ(self, self.a)
end

-- flags from A - v (A unchanged)
local function doCmpA(self, v)
    local r = self.a - v
    self.z = (r == 0)
    self.c = (r >= 0)
    self.n = (u8(r) >= 128)
end

-- flags from X - v
local function doCmpX(self, v)
    local r = self.x - v
    self.z = (r == 0)
    self.c = (r >= 0)
    self.n = (u8(r) >= 128)
end

local H = {}

H[0x00] = function() end                                                -- NOP

H[0x01] = function(c, f8) c.a = f8(); setNZ(c, c.a) end                 -- LDA #imm
H[0x02] = function(c, f8, f16, rd) c.a = rd(f16()); setNZ(c, c.a) end   -- LDA abs
H[0x03] = function(c, f8, f16, rd, wr) wr(f16(), c.a) end               -- STA abs
H[0x04] = function(c, f8) c.b = f8(); setNZ(c, c.b) end                 -- LDB #imm
H[0x05] = function(c, f8, f16, rd) c.b = rd(f16()); setNZ(c, c.b) end   -- LDB abs
H[0x06] = function(c, f8, f16, rd, wr) wr(f16(), c.b) end               -- STB abs
H[0x07] = function(c, f8) c.x = f8(); setNZ(c, c.x) end                 -- LDX #imm
H[0x08] = function(c, f8, f16, rd) c.x = rd(f16()); setNZ(c, c.x) end   -- LDX abs
H[0x09] = function(c, f8, f16, rd, wr) wr(f16(), c.x) end               -- STX abs
H[0x0A] = function(c) c.a = c.x; setNZ(c, c.a) end                      -- TXA
H[0x0B] = function(c) c.x = c.a; setNZ(c, c.x) end                      -- TAX
H[0x0C] = function(c) c.a = c.b; setNZ(c, c.a) end                      -- TBA
H[0x0D] = function(c) c.b = c.a; setNZ(c, c.b) end                      -- TAB

H[0x10] = function(c, f8) doAdd(c, f8()) end                            -- ADD #imm
H[0x11] = function(c, f8, f16, rd) doAdd(c, rd(f16())) end              -- ADD abs
H[0x12] = function(c) doAdd(c, c.b) end                                 -- ADB
H[0x13] = function(c) doAdd(c, c.x) end                                 -- ADX
H[0x14] = function(c, f8) doSub(c, f8()) end                            -- SUB #imm
H[0x15] = function(c, f8, f16, rd) doSub(c, rd(f16())) end              -- SUB abs
H[0x16] = function(c) doSub(c, c.b) end                                 -- SBB
H[0x17] = function(c) doSub(c, c.x) end                                 -- SBX
H[0x18] = function(c, f8) c.a = bit_and(c.a, f8()); setNZ(c, c.a) end   -- AND #imm
H[0x19] = function(c, f8, f16, rd) c.a = bit_and(c.a, rd(f16())); setNZ(c, c.a) end -- AND abs
H[0x1A] = function(c, f8) c.a = bit_or(c.a, f8()); setNZ(c, c.a) end    -- OR #imm
H[0x1B] = function(c, f8, f16, rd) c.a = bit_or(c.a, rd(f16())); setNZ(c, c.a) end -- OR abs
H[0x1C] = function(c, f8) c.a = bit_xor(c.a, f8()); setNZ(c, c.a) end   -- XOR #imm
H[0x1D] = function(c, f8, f16, rd) c.a = bit_xor(c.a, rd(f16())); setNZ(c, c.a) end -- XOR abs

H[0x1E] = function(c) c.c = (c.a >= 128); c.a = (c.a * 2) % 256; setNZ(c, c.a) end -- SHL
H[0x1F] = function(c) c.c = (c.a % 2 == 1); c.a = floor(c.a / 2); setNZ(c, c.a) end -- SHR

H[0x20] = function(c) c.a = u8(c.a + 1); setNZ(c, c.a) end              -- INA
H[0x21] = function(c) c.a = u8(c.a - 1); setNZ(c, c.a) end              -- DEA
H[0x22] = function(c) c.x = u8(c.x + 1); setNZ(c, c.x) end              -- INX
H[0x23] = function(c) c.x = u8(c.x - 1); setNZ(c, c.x) end              -- DEX
H[0x24] = function(c, f8) doCmpA(c, f8()) end                           -- CMP #imm
H[0x25] = function(c, f8, f16, rd) doCmpA(c, rd(f16())) end             -- CMP abs
H[0x26] = function(c) doCmpA(c, c.b) end                                -- CPB
H[0x27] = function(c, f8) doCmpX(c, f8()) end                           -- CPX #imm
H[0x28] = function(c)                                                   -- ADC
    local r = c.a + (c.c and 1 or 0)
    c.c = (r > 255)
    c.a = u8(r)
    setNZ(c, c.a)
end

H[0x30] = function(c, f8, f16) c.pc = f16(); return true end            -- JMP
H[0x31] = function(c, f8, f16) local t = f16(); if c.z then c.pc = t; return true end end -- JZ
H[0x32] = function(c, f8, f16) local t = f16(); if not c.z then c.pc = t; return true end end -- JNZ
H[0x33] = function(c, f8, f16) local t = f16(); if c.c then c.pc = t; return true end end -- JC
H[0x34] = function(c, f8, f16) local t = f16(); if c.n then c.pc = t; return true end end -- JN
H[0x35] = function(c, f8, f16) local t = f16(); if not c.c then c.pc = t; return true end end -- JNC

H[0x40] = function(c, f8, f16)                                          -- CALL
    local target = f16()
    local hi = floor(c.pc / 256)
    local lo = c.pc % 256
    c.sp = (c.sp - 1) % 65536
    c._wr(c.sp, hi)
    c.sp = (c.sp - 1) % 65536
    c._wr(c.sp, lo)
    c.pc = target
    return true
end
H[0x41] = function(c)                                                   -- RET
    local lo = c._rd(c.sp)              -- CALL pushed lo at sp, hi at sp+1
    c.sp = (c.sp + 1) % 65536
    local hi = c._rd(c.sp)
    c.sp = (c.sp + 1) % 65536
    c.pc = hi * 256 + lo
    return true
end
H[0x42] = function(c) c.sp = (c.sp - 1) % 65536; c._wr(c.sp, c.a) end   -- PUSHA
H[0x43] = function(c) c.a = c._rd(c.sp); c.sp = (c.sp + 1) % 65536; setNZ(c, c.a) end -- POPA
H[0x44] = function(c) c.sp = (c.sp - 1) % 65536; c._wr(c.sp, c.x) end   -- PUSHX
H[0x45] = function(c) c.x = c._rd(c.sp); c.sp = (c.sp + 1) % 65536; setNZ(c, c.x) end -- POPX

H[0x50] = function(c, f8, f16, rd) c.a = rd((f16() + c.x) % 65536); setNZ(c, c.a) end -- LDA addr,X
H[0x51] = function(c, f8, f16, rd, wr) wr((f16() + c.x) % 65536, c.a) end              -- STA addr,X
H[0x52] = function(c, f8, f16, rd) c.a = rd((f16() + c.b) % 65536); setNZ(c, c.a) end -- LDA addr,B
H[0x53] = function(c, f8, f16, rd, wr) wr((f16() + c.b) % 65536, c.a) end              -- STA addr,B
H[0x54] = function(c, f8, f16, rd)                                       -- LDA (addr)
    local p = f16()
    local ptr = rd(p) + 256 * rd((p + 1) % 65536)
    c.a = rd(ptr)
    setNZ(c, c.a)
end
H[0x55] = function(c, f8, f16, rd, wr)                                   -- STA (addr)
    local p = f16()
    local ptr = rd(p) + 256 * rd((p + 1) % 65536)
    wr(ptr, c.a)
end

H[0x60] = function(c, f8) c.a = u8(c.inp(f8())); setNZ(c, c.a) end      -- IN #port
H[0x61] = function(c, f8) c.outp(f8(), c.a) end                         -- OUT #port

H[0x70] = function(c) c.halted = true end                               -- HLT

-- Executes one instruction. Returns "halt" if the CPU stopped.
function cpu:step(rd, wr, inp, outp)
    if self.halted then return "halt" end
    -- expose for handlers that need memory/IO outside the normal args
    self._rd, self._wr, self.inp, self.outp = rd, wr, inp, outp

    local startPC = self.pc
    local function f8()
        local v = rd(self.pc)
        self.pc = (self.pc + 1) % 65536
        return v
    end
    local function f16()
        local lo = f8()
        local hi = f8()
        return lo + hi * 256
    end

    local op = rd(startPC)
    self.pc = (startPC + 1) % 65536   -- consume the opcode byte

    local h = H[op]
    if not h then
        error(string.format("m16k: invalid opcode 0x%02X at 0x%04X", op, startPC), 0)
    end

    -- f8/f16 advance self.pc in place; jump handlers overwrite self.pc
    -- with their target after consuming the operand.
    h(self, f8, f16, rd, wr, inp, outp)
    if self.halted then return "halt" end
    return nil
end

return cpu
