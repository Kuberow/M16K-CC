; m16k/rom/bios.asm -- M16K BIOS ROM (a small "VGABIOS"-style video BIOS).
;
; Mapped read-only at 0xE000. Layout:
;   0xE000  font: 64 glyphs for ASCII 0x20..0x5F, 8 bytes per glyph
;           (5 artwork rows + 3 unused; stride stays 8 so the font
;           address is simply (ch-0x20)*8). Each byte is one glyph row,
;           MSB = leftmost pixel. The art is 3 wide and sits in cell
;           columns 1..3 (bits 6..4); cell columns 0, 4 and 5 are blank,
;           giving 3 px between letters, and cell rows 5..8 are blank
;           (4 px between lines). Lower-case input is folded to
;           upper-case by the BIOS; anything else renders as '?'.
;   0xE400  service entry points (JMP stubs; addresses are fixed ABI):
;             0xE400 INIT    - reset cursor (0,0), row base, colour = black
;             0xE410 CLS     - fill the screen with the current colour
;             0xE420 SETCOL  - A = colour (0-15)
;             0xE430 SETCUR  - B = cell column (0-50), X = cell row (0-18)
;             0xE440 PUTC    - draw character A at the cursor, advance it
;                              (0x0A = newline; wraps at column 51/row 19).
;                              The entire cell is repainted every time:
;                              foreground for the glyph's lit pixels,
;                              background for the rest -- so a space really
;                              erases, and no stale glyph survives.
;             0xE450 PUTS    - print NUL-terminated string at B (hi):X (lo)
;             0xE460 NEWLINE - cursor to start of next row
;
; Register clobbering: all services use A/flags only (PUTS also consumes B
; and X as its pointer); B and X are otherwise preserved.
;
; The BIOS keeps its state in a BIOS data area (BDA) reserved in RAM at
; 0x00F0-0x00FF -- guest programs must not use those 16 bytes:
;   F0 curX   F1 curY  F2 colour  F3/F4 row base (lo/hi)
;   F5/F6 font ptr     F7/F8 pixel ptr     F9 char   FA font byte
;   FB gx     FC gy    FD temp     FE/FF PUTS string ptr
; plus 0x00E0 = background colour (SETCOL only ever sets the foreground).
; It lives just below the BDA, in the SDK's low-RAM variable band:
; 0x00E0-0x00E3 are free, and the BIOS claims 0x00E0.
;
; Video: the screen is 306x171 pixels stored 2 per byte (0x4000-0xA632),
;        exactly one default CraftOS-PC terminal (51 x 19 CC chars at 6x9
;        px each), so presentation is a straight 1:1 copy with no scaler
;        and no scaling artefacts. Cells are 6x9 pixels -> 51 x 19 cells
;        tiling it exactly (51*6 = 306, 19*9 = 171). A cell is 3 whole
;        bytes wide and cell columns are always even, so a cell never
;        straddles a byte: pixels 0..5 of a cell are bytes 0/0, 1/1, 2/2.
;        One pixel row = 153 bytes; one cell row = 9 * 153 = 1377 (0x0561).

; ---- BIOS data area addresses --------------------------------------
curX  = 0x00F0
curY  = 0x00F1
colr  = 0x00F2
rowLo = 0x00F3
rowHi = 0x00F4
fLo   = 0x00F5
fHi   = 0x00F6
pLo   = 0x00F7
pHi   = 0x00F8
ch    = 0x00F9
fb    = 0x00FA
gx    = 0x00FB
gy    = 0x00FC
tmp   = 0x00FD
psLo  = 0x00FE
psHi  = 0x00FF
bg    = 0x00E0          ; background colour (the one CLS last filled with)

; ---- font ----------------------------------------------------------
org 0xE000
font:
  db 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00 ; 0x20 ' '
  db 0x20,0x20,0x20,0x00,0x20,0x00,0x00,0x00 ; 0x21 '!'
  db 0x50,0x50,0x00,0x00,0x00,0x00,0x00,0x00 ; 0x22 '"'
  db 0x20,0x70,0x20,0x70,0x20,0x00,0x00,0x00 ; 0x23 '#'
  db 0x30,0x60,0x70,0x10,0x60,0x00,0x00,0x00 ; 0x24 '$'
  db 0x50,0x10,0x20,0x40,0x50,0x00,0x00,0x00 ; 0x25 '%'
  db 0x60,0x50,0x60,0x50,0x30,0x00,0x00,0x00 ; 0x26 '&'
  db 0x20,0x20,0x00,0x00,0x00,0x00,0x00,0x00 ; 0x27 '''
  db 0x20,0x40,0x40,0x40,0x20,0x00,0x00,0x00 ; 0x28 '('
  db 0x20,0x10,0x10,0x10,0x20,0x00,0x00,0x00 ; 0x29 ')'
  db 0x00,0x50,0x20,0x50,0x00,0x00,0x00,0x00 ; 0x2A '*'
  db 0x00,0x20,0x70,0x20,0x00,0x00,0x00,0x00 ; 0x2B '+'
  db 0x00,0x00,0x00,0x20,0x40,0x00,0x00,0x00 ; 0x2C ','
  db 0x00,0x00,0x70,0x00,0x00,0x00,0x00,0x00 ; 0x2D '-'
  db 0x00,0x00,0x00,0x00,0x20,0x00,0x00,0x00 ; 0x2E '.'
  db 0x10,0x10,0x20,0x40,0x40,0x00,0x00,0x00 ; 0x2F '/'
  db 0x70,0x50,0x50,0x50,0x70,0x00,0x00,0x00 ; 0x30 '0'
  db 0x20,0x60,0x20,0x20,0x70,0x00,0x00,0x00 ; 0x31 '1'
  db 0x60,0x10,0x20,0x40,0x70,0x00,0x00,0x00 ; 0x32 '2'
  db 0x60,0x10,0x20,0x10,0x60,0x00,0x00,0x00 ; 0x33 '3'
  db 0x50,0x50,0x70,0x10,0x10,0x00,0x00,0x00 ; 0x34 '4'
  db 0x70,0x40,0x60,0x10,0x60,0x00,0x00,0x00 ; 0x35 '5'
  db 0x30,0x40,0x70,0x50,0x70,0x00,0x00,0x00 ; 0x36 '6'
  db 0x70,0x10,0x20,0x20,0x20,0x00,0x00,0x00 ; 0x37 '7'
  db 0x70,0x50,0x70,0x50,0x70,0x00,0x00,0x00 ; 0x38 '8'
  db 0x70,0x50,0x70,0x10,0x60,0x00,0x00,0x00 ; 0x39 '9'
  db 0x00,0x20,0x00,0x20,0x00,0x00,0x00,0x00 ; 0x3A ':'
  db 0x00,0x20,0x00,0x20,0x40,0x00,0x00,0x00 ; 0x3B ';'
  db 0x10,0x20,0x40,0x20,0x10,0x00,0x00,0x00 ; 0x3C '<'
  db 0x00,0x70,0x00,0x70,0x00,0x00,0x00,0x00 ; 0x3D '='
  db 0x40,0x20,0x10,0x20,0x40,0x00,0x00,0x00 ; 0x3E '>'
  db 0x60,0x10,0x20,0x00,0x20,0x00,0x00,0x00 ; 0x3F '?'
  db 0x20,0x50,0x70,0x50,0x30,0x00,0x00,0x00 ; 0x40 '@'
  db 0x70,0x50,0x70,0x50,0x50,0x00,0x00,0x00 ; 0x41 'A'
  db 0x60,0x50,0x60,0x50,0x60,0x00,0x00,0x00 ; 0x42 'B'
  db 0x70,0x40,0x40,0x40,0x70,0x00,0x00,0x00 ; 0x43 'C'
  db 0x60,0x50,0x50,0x50,0x60,0x00,0x00,0x00 ; 0x44 'D'
  db 0x70,0x40,0x60,0x40,0x70,0x00,0x00,0x00 ; 0x45 'E'
  db 0x70,0x40,0x60,0x40,0x40,0x00,0x00,0x00 ; 0x46 'F'
  db 0x70,0x40,0x50,0x50,0x70,0x00,0x00,0x00 ; 0x47 'G'
  db 0x50,0x50,0x70,0x50,0x50,0x00,0x00,0x00 ; 0x48 'H'
  db 0x70,0x20,0x20,0x20,0x70,0x00,0x00,0x00 ; 0x49 'I'
  db 0x10,0x10,0x10,0x50,0x70,0x00,0x00,0x00 ; 0x4A 'J'
  db 0x50,0x60,0x40,0x60,0x50,0x00,0x00,0x00 ; 0x4B 'K'
  db 0x40,0x40,0x40,0x40,0x70,0x00,0x00,0x00 ; 0x4C 'L'
  db 0x50,0x70,0x50,0x50,0x50,0x00,0x00,0x00 ; 0x4D 'M'
  db 0x50,0x70,0x70,0x50,0x50,0x00,0x00,0x00 ; 0x4E 'N'
  db 0x70,0x50,0x50,0x50,0x70,0x00,0x00,0x00 ; 0x4F 'O'
  db 0x60,0x50,0x60,0x40,0x40,0x00,0x00,0x00 ; 0x50 'P'
  db 0x70,0x50,0x50,0x70,0x10,0x00,0x00,0x00 ; 0x51 'Q'
  db 0x60,0x50,0x60,0x60,0x50,0x00,0x00,0x00 ; 0x52 'R'
  db 0x70,0x40,0x70,0x10,0x70,0x00,0x00,0x00 ; 0x53 'S'
  db 0x70,0x20,0x20,0x20,0x20,0x00,0x00,0x00 ; 0x54 'T'
  db 0x50,0x50,0x50,0x50,0x70,0x00,0x00,0x00 ; 0x55 'U'
  db 0x50,0x50,0x50,0x50,0x20,0x00,0x00,0x00 ; 0x56 'V'
  db 0x50,0x50,0x50,0x70,0x50,0x00,0x00,0x00 ; 0x57 'W'
  db 0x50,0x50,0x20,0x50,0x50,0x00,0x00,0x00 ; 0x58 'X'
  db 0x50,0x50,0x20,0x20,0x20,0x00,0x00,0x00 ; 0x59 'Y'
  db 0x70,0x10,0x20,0x40,0x70,0x00,0x00,0x00 ; 0x5A 'Z'
  db 0x70,0x40,0x40,0x40,0x70,0x00,0x00,0x00 ; 0x5B '['
  db 0x40,0x40,0x20,0x10,0x10,0x00,0x00,0x00 ; 0x5C '\'
  db 0x70,0x10,0x10,0x10,0x70,0x00,0x00,0x00 ; 0x5D ']'
  db 0x20,0x50,0x00,0x00,0x00,0x00,0x00,0x00 ; 0x5E '^'
  db 0x00,0x00,0x00,0x00,0x70,0x00,0x00,0x00 ; 0x5F '_'

; ---- fixed service entry points (JMP stubs) ------------------------
org 0xE400
  JMP init_impl           ; 0xE400 INIT
org 0xE410
  JMP cls_impl            ; 0xE410 CLS
org 0xE420
  JMP setcol_impl         ; 0xE420 SETCOL
org 0xE430
  JMP setcur_impl         ; 0xE430 SETCUR
org 0xE440
  JMP putc_impl           ; 0xE440 PUTC
org 0xE450
  JMP puts_impl           ; 0xE450 PUTS
org 0xE460
  JMP newln_impl          ; 0xE460 NEWLINE

; ---- INIT: cursor (0,0), row base 0x4000, colour black -------------
init_impl:
  LDA #0
  STA curX
  STA curY
  LDA #0x40
  STA rowHi
  LDA #0
  STA rowLo
  LDA #15
  STA colr
  STA bg                 ; the screen starts black, so the background is too
  RET

; ---- SETCOL: A = colour -------------------------------------------
setcol_impl:
  STA colr
  RET

; ---- NEWLINE: cursor to start of next row --------------------------
newln_impl:
  LDA #0
  STA curX
nl_body:
  LDA curY
  INA
  STA curY
  CMP #19
  JNZ nl_add
  ; Scrolled past the bottom. PUTC only ever *lights* pixels, it never
  ; clears them, so writing into the reused top row would blend the new
  ; glyphs into whatever was already on screen. Wipe the whole screen
  ; first, then start again at the top.
  LDA colr
  PUSHA                   ; CLS fills with the *current* colour, but during
  LDA bg                  ; output that is the text colour -- switch to the
  STA colr                ; background, clear, then restore the text colour
  CALL cls_impl
  POPA
  STA colr
  LDA #0
  STA curY
  LDA #0x40
  STA rowHi
  LDA #0
  STA rowLo
  RET
nl_add:
  LDA rowLo
  ADD #0x61              ; +0x0561 = one CELL row (9 pixel rows * 153 bytes);
  STA rowLo              ; C = low-byte carry (survives LDA/INA)
  LDA rowHi
  INA
  INA
  INA
  INA
  INA                    ; +0x0500
  JC nl_c
  STA rowHi
nl_done:
  RET
nl_c:
  INA                    ; +1 for the carry out of rowLo
  STA rowHi
  RET

; ---- SETCUR: B = cell column, X = cell row -------------------------
setcur_impl:
  TBA                     ; A = column
sc_mod:                   ; reduce the column modulo 51
  CMP #51
  JC sc_sub               ; carry = column >= 51 -> subtract again
  JMP sc_store
sc_sub:
  SUB #51
  JMP sc_mod
sc_store:
  STA curX
  TXA                     ; A = row
sc_rmod:                  ; reduce the row modulo 19
  CMP #19
  JC sc_rsub
  JMP sc_rdone
sc_rsub:
  SUB #19
  JMP sc_rmod
sc_rdone:
  STA curY
  ; row base = 0x4000 + curY * 1377 (one CELL row = 9 pixel rows * 153 bytes;
  ; 1377 = 0x0561 -> rowLo += 0x61, rowHi += 5 per iteration, plus 1 more
  ; when the low add carries out)
  LDA curY
  STA tmp
  LDA #0x40
  STA rowHi
  LDA #0
  STA rowLo
sc_row:
  LDA tmp
  JZ sc_ret
  LDA rowLo
  ADD #0x61
  STA rowLo               ; C = low-byte carry (survives LDA/INA)
  LDA rowHi
  INA
  INA
  INA
  INA
  INA                     ; +0x0500
  JC sc_rc
  JMP sc_rn
sc_rc:
  INA                     ; +1 for the carry out of rowLo
  STA rowHi
  JMP sc_rd
sc_rn:
  STA rowHi
sc_rd:
  LDA tmp
  DEA
  STA tmp
  JMP sc_row
sc_ret:
  RET

; ---- CLS: fill 306x171 VRAM with the current colour ------------------
cls_impl:
  LDA colr
  STA bg                 ; whatever we just cleared to *is* the background
  SHL
  SHL
  SHL
  SHL                    ; A = colour << 4
  OR bg                  ; A = colour * 17: both nibbles (2 pixels/byte)
  STA tmp                ; VRAM stores 2 pixels per byte, so fill in bytes
  LDA #0x40
  STA pHi
  LDA #0
  STA pLo
cls_loop:
  LDA tmp
  STA (pLo)
  LDA pLo
  INA
  STA pLo
  JNZ cls_loop            ; low byte not wrapped yet
  LDA pHi
  INA
  STA pHi
  CMP #0xA7               ; filled through 0xA6FF? (0x6700 = 306x171 + pad)
  JNZ cls_loop
  RET

; ---- PUTC: draw character A at the cursor --------------------------
putc_impl:
  STA ch
  CMP #0x0A
  JZ newln_impl           ; newline: tail call (returns to our caller)

  ; fold 'a'..'z' to 'A'..'Z'
  LDA ch
  CMP #'a'
  JC maybe_fold
  JMP range_chk
maybe_fold:
  LDA ch
  CMP #0x7B               ; past 'z'?
  JC range_chk            ; carry = ch >= '{' -> not a lower-case letter
  LDA ch
  SUB #0x20
  STA ch
range_chk:
  LDA ch
  CMP #0x20
  JC chk_high
  LDA #'?'
  STA ch
  JMP calc_fp
chk_high:
  LDA ch
  CMP #0x60               ; font covers 0x20..0x5F only
  JC toobig
  JMP calc_fp
toobig:
  LDA #'?'
  STA ch

calc_fp:                  ; font addr = 0xE000 + (ch - 0x20) * 8
  LDA ch
  SUB #0x20
  SHR
  SHR
  SHR
  SHR
  SHR                     ; A = (ch-0x20) >> 5  (0 or 1)
  ADD #0xE0
  STA fHi
  LDA ch
  SUB #0x20
  SHL
  SHL
  SHL                     ; A = low byte of (ch-0x20) * 8
  STA fLo

  ; byte pointer = row base + curX * 3  (a cell is 3 whole bytes wide)
  LDA curX
  STA tmp
  SHL
  ADD tmp                 ; A = 3 * curX (max 150)
  STA tmp
  LDA rowLo
  ADD tmp
  STA pLo
  LDA rowHi
  JNC nohc
  INA
nohc:
  STA pHi

  LDA #0
  STA gy
putrow:                   ; one glyph row = 6 cell pixels -> 3 packed bytes
  LDA (fLo)               ; font byte through the pointer at fLo/fHi
  STA fb
  LDA #0
  STA gx
pxpair:                   ; 3 iterations of (2 pixels) = one row of 6 px.
  ; --- even-x pixel: high nibble. Repainting the whole cell is what
  ;     makes a space actually erase, so both pixels are always written.
  LDA fb
  SHL
  STA fb                  ; C = next pixel (MSB out)
  JC lit1
  LDA bg
  JMP acc1
lit1:
  LDA colr
acc1:
  SHL
  SHL
  SHL
  SHL                     ; A = colour << 4 (colours are 4-bit)
  STA tmp
  ; --- odd-x pixel: low nibble ---
  LDA fb
  SHL
  STA fb
  JC lit2
  LDA bg
  JMP acc2
lit2:
  LDA colr
acc2:
  OR tmp                  ; A = (even pixel << 4) | odd pixel
  STA (pLo)               ; one byte = two screen pixels
  LDA pLo
  INA
  STA pLo
  JNZ gxdone
  LDA pHi
  INA
  STA pHi
gxdone:
  LDA gx
  INA
  STA gx
  CMP #3
  JNZ pxpair

  LDA fLo                 ; font ptr += 1 (next glyph row); INA carries no
  ADD #1                  ; flag, so use ADD to get a real carry out
  STA fLo
  JNC fok
  LDA fHi
  INA
  STA fHi
fok:
  LDA pLo                 ; byte ptr += 150 (3 used, a pixel row is 153)
  ADD #150
  STA pLo
  JNC pok
  LDA pHi
  INA
  STA pHi
pok:
  LDA gy
  INA
  STA gy
  CMP #5
  JNZ putrow

  ; advance the cursor one cell
  LDA curX
  INA
  STA curX
  CMP #51
  JNZ putc_ret
  LDA #0
  STA curX
  JMP nl_body             ; wrap: shared newline tail (returns to caller)
putc_ret:
  RET

; ---- PUTS: print NUL-terminated string at B (hi):X (lo) ------------
puts_impl:
  TBA
  STA psHi
  TXA
  STA psLo
puts_loop:
  LDA (psLo)
  JZ puts_ret
  CALL putc_impl
  LDA psLo
  INA
  STA psLo
  JNZ puts_loop
  LDA psHi
  INA
  STA psHi
  JMP puts_loop
puts_ret:
  RET
