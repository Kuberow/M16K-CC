-- m16k/isa.lua -- M16K instruction set definition (shared by cpu.lua and asm.lua)
--
-- Registers: A, B, X (8-bit), PC (16-bit), SP (16-bit, stack grows down from 0x4000)
-- Flags: Z (zero), C (carry/borrow), N (bit 7 of result)
--
-- Operand kinds:
--   imp  : implied, no operand
--   imm  : 8-bit immediate        (written as  #expr)
--   abs  : 16-bit absolute address (written as  expr)
--   ind  : 16-bit pointer address  (written as  (expr) )
--   ix   : absolute indexed by X   (written as  expr,X )
--   ib   : absolute indexed by B   (written as  expr,B )
local isa = {}

isa.ops = {
    NOP   = { imp = 0x00 },
    LDA   = { imm = 0x01, abs = 0x02, ind = 0x54, ix = 0x50, ib = 0x52 },
    STA   = { abs = 0x03, ind = 0x55, ix = 0x51, ib = 0x53 },
    LDB   = { imm = 0x04, abs = 0x05 },
    STB   = { abs = 0x06 },
    LDX   = { imm = 0x07, abs = 0x08 },
    STX   = { abs = 0x09 },
    TXA   = { imp = 0x0A },
    TAX   = { imp = 0x0B },
    TBA   = { imp = 0x0C },
    TAB   = { imp = 0x0D },
    ADD   = { imm = 0x10, abs = 0x11 },   -- A = A + operand
    ADB   = { imp = 0x12 },               -- A = A + B
    ADX   = { imp = 0x13 },               -- A = A + X
    SUB   = { imm = 0x14, abs = 0x15 },   -- A = A - operand
    SBB   = { imp = 0x16 },               -- A = A - B
    SBX   = { imp = 0x17 },               -- A = A - X
    AND   = { imm = 0x18, abs = 0x19 },
    ["OR"]= { imm = 0x1A, abs = 0x1B },
    XOR   = { imm = 0x1C, abs = 0x1D },
    SHL   = { imp = 0x1E },
    SHR   = { imp = 0x1F },
    INA   = { imp = 0x20 },
    DEA   = { imp = 0x21 },
    INX   = { imp = 0x22 },
    DEX   = { imp = 0x23 },
    CMP   = { imm = 0x24, abs = 0x25 },   -- flags from A - operand
    CPB   = { imp = 0x26 },               -- flags from A - B
    CPX   = { imm = 0x27 },               -- flags from X - operand
    ADC   = { imp = 0x28 },               -- A = A + carry
    JMP   = { abs = 0x30 },
    JZ    = { abs = 0x31 },
    JNZ   = { abs = 0x32 },
    JC    = { abs = 0x33 },               -- jump if carry set (A >= v after CMP)
    JN    = { abs = 0x34 },
    JNC   = { abs = 0x35 },
    CALL  = { abs = 0x40 },
    RET   = { imp = 0x41 },
    PUSHA = { imp = 0x42 },
    POPA  = { imp = 0x43 },
    PUSHX = { imp = 0x44 },
    POPX  = { imp = 0x45 },
    IN    = { imm = 0x60 },               -- A = input(port)
    OUT   = { imm = 0x61 },               -- output(port, A)
    HLT   = { imp = 0x70 },
}

return isa
