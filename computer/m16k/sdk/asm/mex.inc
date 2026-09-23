; m16k/sdk/asm/mex.inc -- M16K SDK: write MEX applications in plain assembly.
;
; A MEX file is: 12-byte header + body.
;   header: 'M','X',1,0, load(0x2000) LE, entry-off(16) LE, body-len LE,
;           checksum (sum of bytes 0-9 & 0xFF), 0
;   body:   16 program variable bytes (0x2000-0x200F, start as 0),
;           code from 0x2010; the program ends with RET (MEX_END).
;
; The OS streams the body to 0x2000 and CALLs 0x2010; your RET returns to
; the shell. Build the file with:  mkmx myapp.asm  ->  m16k/build/myapp.mx
; then `run myapp` from the MUNIX shell.
;
; Memory map for applications:
;   0x0000-0x00DF  free scratch
;   0x00E0         BIOS background colour -- DO NOT TOUCH
;   0x00E1-0x00EF  free scratch / SDK low-RAM variables (std.inc, shell.inc)
;   0x00F0-0x00FF  BIOS data area -- DO NOT TOUCH
;   0x0100-0x01FF  free scratch (256 bytes, good for app variables)
;   0x0200-0x1FFF  kernel (the OS) -- DO NOT TOUCH
;   0x2000-0x200F  your 16 MEX variable bytes
;   0x2010-0x2FFF  your code and data
;   0x3000-0x3BFF  kernel source buffer -- DO NOT TOUCH
;   0x3C00-0x4000  stack (CALL/RET, PUSHA/POPA) -- leave the top levels free
;
; Example app:
;   %include "mex.inc"
;   MEX_BEGIN
;   v_i = 0x2000
;   start:
;     LDA #(msg % 256)
;     TAX
;     LDA #(msg / 256)
;     TAB
;     CALL SVC_PUTS
;     LDA v_i
;     CALL SVC_PRINTN
;     MEX_END
;   msg: db "HI", 10, 0

%include "svc.inc"

%macro MEX_BEGIN
org 0x2000
db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
%endmacro

%macro MEX_END
RET
%endmacro
