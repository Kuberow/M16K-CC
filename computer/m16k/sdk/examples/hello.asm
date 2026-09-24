; m16k/sdk/examples/hello.asm -- MUNIX MEX application example.
;
; Build:   mkmx hello.asm        (writes m16k/build/hello.mx)
; Run:     run hello             (from the MUNIX shell; the OS installs a
;                                 copy as hello.mx on first boot)
;
; Prints a greeting, counts 1-5 in decimal, then returns to the shell.

%include "mex.inc"
MEX_BEGIN

v_i = 0x2000                  ; first MEX variable byte

start:
  LDA #(msg / 256)
  TAB
  LDA #(msg % 256)
  TAX
  CALL SVC_PUTS               ; "HELLO FROM MEX"
  LDA #1
  STA v_i
  ; The screen is 19 rows tall and output past the bottom wipes it, so
  ; from a fresh boot (cursor already on row 2) an app has ~17 rows.
  ; Keep the whole demo inside that: 1..5 on ONE line, not one per line.
loop:
  LDA v_i
  CALL SVC_PRINTN             ; print 1..5, space separated
  LDA v_i
  INA
  STA v_i
  CMP #6
  JZ ln_end
  LDA #' '
  CALL SVC_PUTC
  JMP loop
ln_end:
  LDA #10
  CALL SVC_PUTC
  LDA #'?'
  CALL SVC_PUTC
  LDA #10
  CALL SVC_PUTC
  ; `run hello whatever` -> one more line, "ARG:WHATEVER". APP_ARG is 0
  ; when the command carried no argument, so a plain `run hello` is
  ; byte-for-byte the demo above.
  LDA APP_ARG+1
  JNZ arg_go
  LDA APP_ARG
  JZ no_arg
arg_go:
  LDA #(argmsg % 256)
  TAX
  LDA #(argmsg / 256)
  TAB
  CALL SVC_PUTS               ; "ARG:"
  LDA APP_ARG+1               ; then the argument itself
  TAB
  LDA APP_ARG
  TAX
  CALL SVC_PUTS
no_arg:
  MEX_END

msg:    db "HELLO FROM MEX", 10, 0
argmsg: db "ARG:", 0
