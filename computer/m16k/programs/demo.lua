-- m16k/programs/demo.lua -- Built-in M16K demo program (assembly source).
--
-- Returns the assembly source for a program that:
--   1. paints the whole 306x171 framebuffer with colour stripes
--      (one stripe colour per scanline, y % 16),
--   2. runs a bouncing ball along the white stripe at row 32,
--   3. any keypress recolours the ball (key code AND 15),
--   4. 'q' halts the machine,
--   5. requests a screen present each frame via OUT 0x10.
--
-- VRAM stores 2 pixels per byte (high nibble = even x, low nibble = odd x),
-- so a whole scanline of one colour is 153 bytes of (colour << 4) | colour.
-- The row-fill loop is generated here so the assembler stays simple: each
-- scanline gets its own unrolled STA addr,X / INX / CPX #153 / JNZ loop,
-- with the packed byte constant baked in by Lua.

local ROW = 153                -- VRAM bytes per pixel row
local BASE = 0x4000
local ROWS = 171
local BALL_ROW = 32
local BALL_BASE = BASE + BALL_ROW * ROW     -- 0x5320
local MAXX = 254               -- the ball stays inside a byte-sized x

local rows = {}
for y = 0, ROWS - 1 do
    local c = y % 16
    local packed = c * 16 + c
    rows[#rows + 1] = string.format([[
  LDA #%d
  LDX #0
row%d:
  STA 0x%04X,X
  INX
  CPX #%d
  JNZ row%d]], packed, y, BASE + y * ROW, ROW, y)
end

return string.format([[
org 0x0200
start:
%s

  ; --- init ball state ---
  LDA #14                ; a colour the white stripe is not
  STA ballcol
  LDA #1
  STA vx
  LDA #48
  STA x

frame:
  ; erase the ball (stripe colour at row 32 is 32 %% 16 = 0)
  LDA #0
  STA pcol
  CALL paint

  ; x = x + vx, bouncing between 0 and %d
  LDA x
  ADD vx
  CMP #255               ; 255 is the only out-of-range value (a wrap)
  JZ bounce
  STA x
  JMP draw
bounce:
  LDA #0
  SUB vx
  STA vx

draw:
  LDA ballcol
  STA pcol
  CALL paint

  ; --- keyboard ---
  IN #1                  ; status
  JZ nokey
  IN #2                  ; code
  CMP #'q'
  JZ die
  AND #15
  JNZ setcol
  LDA #15                ; avoid an invisible white ball on a white stripe
setcol:
  STA ballcol

nokey:
  ; crude delay: 12 x 255 iterations
  LDA #12
  STA d1
outer:
  LDA #0
  DEA                    ; A = 255
  STA d2
inner:
  LDA d2
  DEA
  STA d2
  JNZ inner
  LDA d1
  DEA
  STA d1
  JNZ outer

  OUT #16                ; present frame (port 0x10)
  JMP frame

die:
  HLT

; ---- paint pcol at row %d, column x (nibble read-modify-write) --------
paint:
  LDA x
  AND #1
  JNZ p_odd
  LDA x                  ; even x -> high nibble
  SHR
  TAX
  LDA pcol
  SHL
  SHL
  SHL
  SHL
  STA tmp
  LDA 0x%04X,X
  AND #0x0F
  OR tmp
  STA 0x%04X,X
  RET
p_odd:
  LDA x                  ; odd x -> low nibble
  SHR
  TAX
  LDA 0x%04X,X
  AND #0xF0
  OR pcol
  STA 0x%04X,X
  RET

ballcol: db 14
pcol:    db 0
tmp:     db 0
vx:      db 1
x:       db 48
d1:      db 0
d2:      db 0
]], table.concat(rows, "\n"), MAXX, BALL_ROW,
    BALL_BASE, BALL_BASE, BALL_BASE, BALL_BASE)
