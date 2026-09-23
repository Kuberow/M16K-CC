; m16k/programs/myos.asm -- "MUNIX": a tiny Unix-like OS built on the M16K SDK.
;
; Run with:   m16k myos
; Shell:      help, ls, cat f, run f, rm f, clear, halt
;             any other name is executed as an MEX app (".mx" is appended
;             when the name has no dot).
;
; First boot formats the 32 KB disk as MUFS and installs readme.txt and
; hello.mx (the binary is %incbin'd from m16k/build/hello.mx -- build it
; first with:  mkmx hello.asm).
;
; Layout: kernel 0x0200-0x1FFF (gates at 0x1F00, see SYSCALL_GATES),
;         MEX apps at 0x2000, source buffer 0x3000-0x3BFF, stack below 0x4000.

org 0x0200
%include "svc.inc"

; ---- tiny display macros ----------------------------------------------
%macro SAY lbl
  LDA #(%1 / 256)
  TAB
  LDA #(%1 % 256)
  TAX
  CALL std_puts
%endmacro

%macro NL
  LDA #10
  CALL std_putc
%endmacro

%macro SHOUT lbl
  LDA #(%1 % 256)
  STA pb
  LDA #(%1 / 256)
  STA pb+1
%endmacro

%macro TRY lbl
  SHOUT %1
  CALL sh_is
%endmacro

; ---- boot --------------------------------------------------------------
start:
  CALL std_init
  LDA #5                    ; banner in lime
  CALL std_setcol
  SAY m_banner
  NL
  CALL fs_install           ; first boot: format + install samples
  LDA #0                    ; body text in white
  CALL std_setcol
  SAY m_th
  NL

; ---- shell -------------------------------------------------------------
shell_loop:
  LDA #0
  CALL std_setcol
  SAY m_prompt
  CALL sh_readline
  CALL sh_split
  LDA linebuf
  JZ shell_loop             ; empty line
  TRY m_help
  JNZ cmd_help
  TRY m_ls
  JNZ cmd_ls
  TRY m_cat
  JNZ cmd_cat
  TRY m_run
  JNZ cmd_run
  TRY m_rm
  JNZ cmd_rm
  TRY m_clear
  JNZ cmd_clear
  TRY m_halt
  JNZ cmd_halt
  JMP cmd_unk

cmd_help:
  SAY m_h0
  NL
  SAY m_h1
  NL
  SAY m_h2
  NL
  SAY m_h3
  NL
  SAY m_h4
  NL
  JMP shell_loop

cmd_clear:
  LDA #15
  CALL std_setcol
  CALL std_cls
  LDA #0
  TAB
  LDA #0
  TAX
  CALL std_setcur
  JMP shell_loop

cmd_halt:
  HLT

cmd_unk:
  SHOUT m_hmm
  CALL m_err
  JMP shell_loop

; ---- ls: print every live directory entry ------------------------------
cmd_ls:
  LDA #0
  OUT #0x40                 ; directory lives in disk page 0
  LDA #0x10
  STA fp_lo
  LDA #0xE8
  STA fp_hi
  LDA #0
  STA fs_idx
ls_l:
  LDA (fp)
  JZ ls_nx
  LDA fp_hi
  TAB
  LDA fp_lo
  TAX
  CALL std_puts             ; print the NUL-padded name
  NL
ls_nx:
  LDA fp_lo
  ADD #32
  STA fp_lo
  JNC ls_nc
  LDA fp_hi
  INA
  STA fp_hi
ls_nc:
  LDA fs_idx
  INA
  STA fs_idx
  CMP #32
  JNZ ls_l
  JMP shell_loop

; ---- cat f: stream a text file to the screen ---------------------------
cmd_cat:
  LDA (argp)
  JZ cat_use
  LDA argp
  STA np
  LDA argp+1
  STA np+1
  CALL fs_open
  JZ cat_lp
  SHOUT m_nofile
  CALL m_err
  JMP shell_loop
cat_lp:
  LDA fr_len+1
  JNZ cat_go
  LDA fr_len
  JZ cat_end
cat_go:
  CALL fs_getc
  CALL std_putc
  JMP cat_lp
cat_end:
  NL
  JMP shell_loop
cat_use:
  SHOUT m_ucat
  CALL m_err
  JMP shell_loop

; ---- run f: load and execute a MEX application --------------------------
cmd_run:
  LDA (argp)
  JZ run_use
  ; append ".mx" when the name has no dot (pa scans the argument)
  LDA argp
  STA pa
  LDA argp+1
  STA pa+1
run_scan:
  LDA (pa)
  JZ run_add
  CMP #'.'
  JZ run_open
  CALL std_incpa
  JMP run_scan
run_add:
  LDA pa
  SUB argp                  ; A = length (mod 256; always < 256 here)
  CMP #14                   ; need len + ".mx" <= 16 chars
  JC run_nm
  LDA #'.'
  STA (pa)
  CALL std_incpa
  LDA #'m'
  STA (pa)
  CALL std_incpa
  LDA #'x'
  STA (pa)
  CALL std_incpa
  LDA #0
  STA (pa)
run_open:
  LDA argp
  STA np
  LDA argp+1
  STA np+1
  CALL fs_open
  JZ run_hdr
  SHOUT m_nofile
  CALL m_err
  JMP shell_loop
run_hdr:
  LDA #0
  STA sh_i
run_hl:
  LDA sh_i
  CMP #12
  JZ run_hok
  LDA fr_len+1
  JNZ run_hg
  LDA fr_len
  JZ run_bad                ; file too short for a header
run_hg:
  CALL fs_getc
  LDX sh_i
  STA hb,X
  LDA sh_i
  INA
  STA sh_i
  JMP run_hl
run_hok:
  LDA hb
  CMP #'M'
  JNZ run_bad
  LDA hb+1
  CMP #'X'
  JNZ run_bad
  LDA hb+2
  CMP #1
  JNZ run_bad
  LDA hb+4                  ; load address must be 0x2000
  JNZ run_bad
  LDA hb+5
  CMP #0x20
  JNZ run_bad
  ; stream the body (header already consumed) to 0x2000
  LDA #0x00
  STA fd_lo
  LDA #0x20
  STA fd_hi
  CALL fs_read
  ; patch the self-modifying CALL to load + entry offset
  LDA hb+6
  STA exop+1
  LDA hb+7
  ADD #0x20
  STA exop+2
  ; a SINGLE CALL: the app's RET must fall through to the next line here.
  ; (an exop trampoline would push a second return address and the app
  ;  would return into the data section instead)
exop:
  CALL 0x0000
  ; The app owns its output: only break the line if it did not already end
  ; with a newline. A redundant NL here can push curY past the bottom row,
  ; and the BIOS now wipes the screen when it wraps -- so the app's whole
  ; output would vanish right before the prompt.
  LDA 0xF0                ; curX
  JZ run_nnl
  NL
run_nnl:
  JMP shell_loop
run_bad:
  SHOUT m_badmex
  CALL m_err
  JMP shell_loop
run_use:
  SHOUT m_urun
  CALL m_err
  JMP shell_loop
run_nm:
  SHOUT m_long
  CALL m_err
  JMP shell_loop

; ---- rm f: delete a file -------------------------------------------------
cmd_rm:
  LDA (argp)
  JZ rm_use
  LDA argp
  STA np
  LDA argp+1
  STA np+1
  CALL fs_delete
  JZ shell_loop
  SHOUT m_nofile
  CALL m_err
  JMP shell_loop
rm_use:
  SHOUT m_urm
  CALL m_err
  JMP shell_loop

; ---- print the red error message at (pb) --------------------------------
m_err:
  LDA #14
  CALL std_setcol
  LDA pb+1
  TAB
  LDA pb
  TAX
  CALL std_puts
  NL
  LDA #0
  CALL std_setcol
  RET

; ---- data ----------------------------------------------------------------
m_banner:  db "MUNIX 0.1", 0
m_th:      db "TYPE HELP", 0
m_prompt:  db "$ ", 0
m_help:    db "help", 0
m_ls:      db "ls", 0
m_cat:     db "cat", 0
m_run:     db "run", 0
m_rm:      db "rm", 0
m_clear:   db "clear", 0
m_halt:    db "halt", 0
m_h0:      db "COMMANDS:", 0
m_h1:      db " HELP  LS", 0
m_h2:      db " CAT F RUN F", 0
m_h3:      db " RM F CLEAR", 0
m_h4:      db " HALT", 0
m_nofile:  db "NO FILE", 0
m_badmex:  db "BAD MEX", 0
m_ucat:    db "CAT F", 0
m_urun:    db "RUN F", 0
m_urm:     db "RM F", 0
m_long:    db "NAME?", 0
m_hmm:     db "?", 0
hb:        db 0,0,0,0,0,0,0,0,0,0,0,0

m_readme:      db "readme.txt", 0
m_readme_src:  db "MUNIX SDK DEMO", 10, "BUILT WITH THE", 10, "M16K SDK", 10
m_readme_end:
m_hello:       db "hello.mx", 0
m_hello_bin:
%incbin "m16k/build/hello.mx"
m_hello_end:

; ---- SDK library ---------------------------------------------------------
%include "std.inc"
%include "fs.inc"
%include "shell.inc"

; ---- fixed syscall gates for MEX apps -------------------------------------
SYSCALL_GATES

org 0x2000                   ; kernel must fit below 0x2000 (assembler checks)
