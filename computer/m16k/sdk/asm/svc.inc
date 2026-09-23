; m16k/sdk/asm/svc.inc -- M16K SDK: fixed ABI equates (BIOS + syscall gates).
;
; Include this (directly or via std.inc/mex.inc) BEFORE any code that uses
; these names. It emits no code -- only `name = expr` constants, so it is
; safe to %include at the very top of an OS or application.
;
; BIOS video services (m16k/rom/bios.asm, read-only ROM at 0xE000):
BIOS_INIT   = 0xE400    ; reset cursor (0,0), row base, colour = black
BIOS_CLS    = 0xE410    ; fill the screen with the current colour
BIOS_SETCOL = 0xE420    ; A = colour (0-15)
BIOS_SETCUR = 0xE430    ; B = cell column (0-50), X = cell row (0-18)
BIOS_PUTC   = 0xE440    ; draw char A at the cursor, advance (0x0A = newline)
BIOS_PUTS   = 0xE450    ; print NUL-terminated string at B (hi):X (lo)
BIOS_NEWLN  = 0xE460    ; cursor to start of next row
;
; MUNIX syscall gates: every OS built on the SDK places eight 3-byte JMP
; stubs at these FIXED addresses (see the SYSCALL_GATES macro below), so
; MEX applications can CALL them no matter how the kernel itself is laid
; out. Applications include mex.inc, which pulls in these equates.
;
;   gate          A in      A out
;   SVC_PUTC      char      clobbered (tail-jumps BIOS_PUTC)
;   SVC_PUTS      B:hi/X:lo ptr string print (B,X consumed)
;   SVC_PRINTN    value     clobbered (prints decimal, no newline)
;   SVC_GETC      --        next key code (blocks until a key arrives)
;   SVC_MUL       A * B     low byte of the product
;   SVC_DIV       A / B     quotient (0 if B = 0)
;   SVC_MOD       A % B     remainder (0 if B = 0)
;   SVC_RND       --        random byte 0-255
SVC_PUTC   = 0x1F00
SVC_PUTS   = 0x1F03
SVC_PRINTN = 0x1F06
SVC_GETC   = 0x1F09
SVC_MUL    = 0x1F0C
SVC_DIV    = 0x1F0F
SVC_MOD    = 0x1F12
SVC_RND    = 0x1F15
SVC_GATES_END = 0x1F18   ; first byte past the gate stubs
;
; The kernel emits the gate stubs with this macro (place it near the END of
; the kernel, after all code and data; requires std.inc for the std_* targets):
%macro SYSCALL_GATES
org 0x1F00
  JMP std_putc          ; 0x1F00 SVC_PUTC
  JMP std_puts          ; 0x1F03 SVC_PUTS
  JMP std_printn        ; 0x1F06 SVC_PRINTN
  JMP std_getc          ; 0x1F09 SVC_GETC
  JMP std_mul           ; 0x1F0C SVC_MUL
  JMP std_div           ; 0x1F0F SVC_DIV
  JMP std_mod           ; 0x1F12 SVC_MOD
  JMP std_rnd           ; 0x1F15 SVC_RND
%endmacro
