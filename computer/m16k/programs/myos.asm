; m16k/programs/myos.asm -- "MUNIX": a tiny Unix-like OS built on the M16K SDK.
;
; Run with:   m16k myos
; Shell:      help, ls, cat f, run f, rm f, clear, halt
;             echo t > f     create/overwrite f with the text t
;             echo t >> f    append the text t to f
;             mkhex f HEX    create f from hex digit pairs (spaces ok)
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

; ---- staging buffer for file writes -------------------------------------
; Some writes have to be assembled in RAM before the filesystem will take
; them: an `echo ... >> f` has to read the old file back and put the new
; text right after it, and `mkhex` has to decode digit pairs into bytes.
; 0x0100-0x01FF is free scratch below the kernel, so this costs the
; kernel image no bytes at all.
wbuf     = 0x0100
WBUF_MAX = 250

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
  TRY m_echo
  JNZ cmd_echo
  TRY m_mkhex
  JNZ cmd_mkhex
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
  SAY m_h5
  NL
  SAY m_h6
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

; ---- run f [args]: load and execute a MEX application --------------------
; The first token names the file; everything after the next space is handed
; to the app untouched as a NUL string at APP_ARG (0 when there is none).
; The filename is copied into runbuf so appending ".mx" cannot overwrite
; the argument that still has to sit in linebuf while the app runs.
cmd_run:
  LDA (argp)
  JZ run_use
  LDA #0
  STA APP_ARG             ; assume no argument until a space proves otherwise
  STA APP_ARG+1           ; ...and clear BOTH bytes, or the stale high half
                           ; turns 0 into 0x1200 on the next `run hello`
  LDA argp
  STA pa
  LDA argp+1
  STA pa+1
  LDA #0
  STA sh_i
run_cp:
  LDA (pa)
  JZ run_cpd              ; end of line: no argument
  CMP #' '
  JZ run_cps              ; the rest of the line belongs to the app
  LDX sh_i
  CPX #16
  JZ run_nm               ; a 17th filename character: MUFS names stop at 16
  STA runbuf,X
  LDA sh_i
  INA
  STA sh_i
  CALL std_incpa
  JMP run_cp
run_cps:
  CALL std_incpa          ; step over the space
  LDA (pa)
  JZ run_cpd              ; a trailing space still means "no argument"
  LDA pa
  STA APP_ARG
  LDA pa+1
  STA APP_ARG+1
  JMP run_cpd
run_cpd:
  LDX sh_i
  LDA #0
  STA runbuf,X            ; NUL-terminate the copy (sh_i <= 16, runbuf is 24)
  LDA #(runbuf % 256)
  STA pa
  LDA #(runbuf / 256)
  STA pa+1
run_scan:
  LDA (pa)
  JZ run_add
  CMP #'.'
  JZ run_open
  CALL std_incpa
  JMP run_scan
run_add:
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
  LDA #(runbuf % 256)
  STA np
  LDA #(runbuf / 256)
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

; ---- echo t > f  |  echo t >> f ---------------------------------------------
; Scan the argument for '>' -- everything before it is the text, everything
; after it (past an optional second '>') is the filename. ec_len is the
; index of the last NON-space, so "echo hi   > f" writes just "hi".
cmd_echo:
  LDA argp
  STA pa
  LDA argp+1
  STA pa+1
  LDA #0
  STA ec_i
  STA ec_len
ec_scan:
  LDA (pa)
  JZ ec_noop            ; ran off the end: there was no '>'
  CMP #'>'
  JZ ec_got
  CMP #' '
  JZ ec_sk
  LDA ec_i
  INA
  STA ec_len            ; remember the end of the last non-space
ec_sk:
  LDA ec_i
  INA
  STA ec_i
  CALL std_incpa
  JMP ec_scan
ec_got:
  LDA #0
  STA ec_app            ; pa -> '>'
  CALL std_incpa
  LDA (pa)
  CMP #'>'
  JNZ ec_sp
  LDA #1
  STA ec_app            ; '>>' -> append
  CALL std_incpa
ec_sp:
  LDA (pa)
  JZ ec_uecho           ; '>' but no filename
  CMP #' '
  JNZ ec_nm
  CALL std_incpa
  JMP ec_sp
ec_nm:
  LDA pa
  STA ec_fn
  LDA pa+1
  STA ec_fn+1
ec_go:
  LDA ec_len
  JZ ec_empty           ; "echo > f" has nothing to write
  LDA #0
  STA ec_has
  STA ec_old
  STA ec_old+1
  LDA ec_app
  JZ ec_del             ; overwrite: the old bytes are discarded anyway
  LDA ec_fn
  STA np
  LDA ec_fn+1
  STA np+1
  CALL fs_open          ; an append needs the current content BEFORE deletion
  JZ ec_gotf
  JMP ec_del            ; no such file yet: append degenerates to a create
ec_gotf:
  LDA #1
  STA ec_has
  LDA fr_len+1
  JNZ ec_big
  LDA fr_len
  ADD ec_len
  JC ec_big
  CMP #WBUF_MAX
  JC ec_big             ; old + new would not fit the staging buffer
  LDA fr_len            ; fs_read burns fr_len to 0, so save it first
  STA ec_old
  LDA fr_len+1
  STA ec_old+1
  LDA #(wbuf % 256)
  STA fd_lo
  LDA #(wbuf / 256)
  STA fd_hi
  CALL fs_read
ec_del:
  ; fs_create only ever claims a FREE directory slot, so a file of this
  ; name has to go first or the disk would end up holding two of them.
  LDA ec_fn
  STA np
  LDA ec_fn+1
  STA np+1
  CALL fs_delete        ; A = 1 (absent) is harmless here
  LDA ec_app
  JZ ec_line
  LDA ec_has
  JZ ec_line
  ; append: lay the new text down right behind the bytes just read back
  LDA #(wbuf % 256)
  ADD ec_old
  STA pb
  LDA #(wbuf / 256)
  ADC
  STA pb+1
  LDA argp
  STA pa
  LDA argp+1
  STA pa+1
  LDA ec_len
  STA mc_n
  LDA #0
  STA mc_n+1
  CALL std_memcpy
  LDA #(wbuf % 256)
  STA wc_src
  LDA #(wbuf / 256)
  STA wc_src+1
  LDA ec_old
  ADD ec_len
  STA wc_len
  LDA ec_old+1
  ADC
  STA wc_len+1
  JMP ec_mk
ec_line:                ; overwrite (or a first write): the text already sits
  LDA argp              ; contiguously inside linebuf
  STA wc_src
  LDA argp+1
  STA wc_src+1
  LDA ec_len
  STA wc_len
  LDA #0
  STA wc_len+1
ec_mk:
  LDA ec_fn
  STA np
  LDA ec_fn+1
  STA np+1
  CALL fs_create
  JZ shell_loop         ; A = 0 -> written
ec_nosp:
  SHOUT m_nosp
  CALL m_err
  JMP shell_loop
ec_empty:
  SHOUT m_empty
  CALL m_err
  JMP shell_loop
ec_big:
  SHOUT m_big
  CALL m_err
  JMP shell_loop
ec_noop:
ec_uecho:
  SHOUT m_uecho
  CALL m_err
  JMP shell_loop

; ---- mkhex f HEX -----------------------------------------------------------
; Split the argument at the first space (NUL-terminating the filename), then
; decode hex digit pairs straight into wbuf. Spaces in the hex are ignored,
; so both `mkhex f 4d5801` and `mkhex f 4d 58 01` work.
cmd_mkhex:
  LDA argp
  STA pa
  LDA argp+1
  STA pa+1
mk_sp0:
  LDA (pa)
  JZ mk_use            ; no hex digits at all
  CMP #' '
  JZ mk_cut
  CALL std_incpa
  JMP mk_sp0
mk_cut:
  LDA #0
  STA (pa)             ; terminate the filename
  CALL std_incpa
mk_sk:
  LDA (pa)
  JZ mk_use
  CMP #' '
  JNZ mk_l0
  CALL std_incpa
  JMP mk_sk
mk_l0:
  LDA #0
  STA mh_n             ; bytes produced
  STA mh_hi            ; 0 = waiting for a high nibble
mk_l:
  LDA (pa)
  JZ mk_end
  CMP #' '
  JNZ mk_dg
  CALL std_incpa
  JMP mk_l
mk_dg:
  CALL mh_val          ; A = 0..15, or 0xFF if it is not a hex digit
  CMP #0xFF
  JZ mk_bad
  LDX mh_hi
  JNZ mk_lo
  STA mh_acc           ; high nibble
  LDA #1
  STA mh_hi
  CALL std_incpa
  JMP mk_l
mk_lo:
  STA mh_nib
  LDA mh_acc
  SHL
  SHL
  SHL
  SHL                  ; A = high nibble << 4 (the old high bits drop off)
  OR mh_nib
  STA mh_by
  LDA mh_n
  CMP #WBUF_MAX
  JC mk_big
  TAX                  ; A = mh_n -> X
  LDA mh_by
  STA wbuf,X
  LDA #0
  STA mh_hi
  LDA mh_n
  INA
  STA mh_n
  CALL std_incpa
  JMP mk_l
mk_end:
  LDA mh_hi
  JNZ mk_bad           ; a stray digit: the pairs did not line up
  LDA mh_n
  JZ mk_use
  LDA argp             ; np = the filename (linebuf still holds it)
  STA np
  LDA argp+1
  STA np+1
  CALL fs_delete       ; replace an existing file of the same name
  LDA #(wbuf % 256)
  STA wc_src
  LDA #(wbuf / 256)
  STA wc_src+1
  LDA mh_n
  STA wc_len
  LDA #0
  STA wc_len+1
  CALL fs_create
  JZ shell_loop
  SHOUT m_nosp
  CALL m_err
  JMP shell_loop
mk_use:
  SHOUT m_uhex
  CALL m_err
  JMP shell_loop
mk_bad:
  SHOUT m_hex
  CALL m_err
  JMP shell_loop
mk_big:
  SHOUT m_big
  CALL m_err
  JMP shell_loop

; ---- A = ASCII hex digit -> A = 0..15, or 0xFF if it is not one ------------
; (sh_readline folds A-Z to a-z, so only the lowercase letters can appear.)
mh_val:
  CMP #'0'
  JC mv_d1
  JMP mv_bad
mv_d1:
  CMP #58                ; carry = A >= 58, so BELOW this is still '0'..'9'
  JNC mv_num
  CMP #'a'
  JNC mv_bad             ; 58..96, between the digits and the letters
  CMP #103               ; 'f' + 1
  JC mv_bad              ; 'g' and up
  SUB #'a'
  ADD #10
  RET
mv_num:
  SUB #'0'
  RET
mv_bad:
  LDA #0xFF
  RET

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
m_echo:    db "echo", 0
m_mkhex:   db "mkhex", 0
m_clear:   db "clear", 0
m_halt:    db "halt", 0
m_h0:      db "COMMANDS:", 0
m_h1:      db " HELP  LS", 0
m_h2:      db " CAT F RUN F", 0
m_h3:      db " RM F CLEAR", 0
m_h4:      db " HALT", 0
m_h5:      db " ECHO T > F", 0
m_h6:      db " MKHEX F HEX", 0
m_nofile:  db "NO FILE", 0
m_badmex:  db "BAD MEX", 0
m_ucat:    db "CAT F", 0
m_urun:    db "RUN F", 0
m_urm:     db "RM F", 0
m_uecho:   db "ECHO T > F", 0
m_uhex:    db "MKHEX F HEX", 0
m_empty:   db "EMPTY?", 0
m_big:     db "TOO BIG", 0
m_hex:     db "HEX?", 0
m_nosp:    db "NO SPACE", 0
m_long:    db "NAME?", 0
m_hmm:     db "?", 0
hb:        db 0,0,0,0,0,0,0,0,0,0,0,0
runbuf:    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
ec_i:      db 0
ec_len:    db 0
ec_app:    db 0
ec_has:    db 0
ec_old:    db 0, 0
ec_fn:     db 0, 0
mh_n:      db 0
mh_hi:     db 0
mh_acc:    db 0
mh_nib:    db 0
mh_by:     db 0

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
