-- m16k/programs/textdemo.lua -- M16K text example (assembly source generator).
--
-- This is a *guest program only*: it contains no font and no pixel work.
-- All text rendering is done by the BIOS ROM (m16k/rom/bios.asm) mapped at
-- 0xE000 -- the same way a real x86 program would call the video BIOS.
-- The program:
--   1. calls BIOS INIT, clears the screen and sets a colour,
--   2. positions the cursor with SETCUR and prints lines with PUTS,
--   3. then idles: any key repaints in the next palette colour, 'q' halts.
--
-- EDIT THE LINES BELOW to change the displayed text (51 cells per row,
-- 19 rows of 6x9 cells on the 306x171 screen; a-z is drawn as A-Z).

return [[
org 0x0200

; BIOS service entry points (fixed ABI, see m16k/rom/bios.asm)
BIOS_INIT   = 0xE400
BIOS_CLS    = 0xE410
BIOS_SETCOL = 0xE420
BIOS_SETCUR = 0xE430
BIOS_PUTS   = 0xE450

start:
  CALL BIOS_INIT
draw:
  LDA #15                ; background: black
  CALL BIOS_SETCOL
  CALL BIOS_CLS
  LDA color
  CALL BIOS_SETCOL       ; text colour for everything below

  ; line 1 at cell (0,0)
  LDA #0
  TAB                    ; B = column 0
  LDA #0
  TAX                    ; X = row 0
  CALL BIOS_SETCUR
  LDA #msg1 / 256
  TAB                    ; B = high byte of msg1 (works past 0x0300 too)
  LDA #msg1 % 256
  TAX
  CALL BIOS_PUTS

  ; line 2 at cell (0,2)
  LDA #0
  TAB
  LDA #2
  TAX
  CALL BIOS_SETCUR
  LDA #msg2 / 256
  TAB
  LDA #msg2 % 256
  TAX
  CALL BIOS_PUTS

  ; line 3 at cell (0,4)
  LDA #0
  TAB
  LDA #4
  TAX
  CALL BIOS_SETCUR
  LDA #msg3 / 256
  TAB
  LDA #msg3 % 256
  TAX
  CALL BIOS_PUTS

  ; line 4 at cell (0,6)
  LDA #0
  TAB
  LDA #6
  TAX
  CALL BIOS_SETCUR
  LDA #msg4 / 256
  TAB
  LDA #msg4 % 256
  TAX
  CALL BIOS_PUTS

idle:
  IN #1                  ; key waiting?
  JZ nokey
  IN #2                  ; code
  CMP #'q'
  JZ die
  LDA color              ; any other key: next palette colour
  INA
  AND #15
  STA color
  JMP draw               ; repaint: clear + all four lines again
nokey:
  LDA #12                ; delay: 12 x 255 iterations
  STA d1
outer:
  LDA #0
  DEA
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
  OUT #16                ; present
  JMP idle
die:
  HLT

color: db 4
d1:    db 0
d2:    db 0
msg1:  db "M16K DEMO", 0
msg2:  db "HELLO, WORLD", 0
msg3:  db "VIA THE BIOS", 0
msg4:  db "Q EXITS M16K", 0
]]
