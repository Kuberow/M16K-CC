; m16k/sdk/asm/shell.inc -- M16K SDK: interactive shell helpers.
;
; %include this ONCE, after std.inc. Provides:
;   sh_readline   read a line into linebuf (max 16 chars), echo + backspace
;                 (guarded at column 0), NUL-terminate, fold A-Z to a-z,
;                 echo the newline. Uses BIOS cursor state at 0xF0/0xF1.
;   sh_split      split linebuf into cmd (linebuf) + arg (argp, points at
;                 the argument or at the NUL if there is none)
;   sh_is         pb = NUL-string -> A = 1 if linebuf equals it
;
; Variables: linebuf(17), argp(2), sh_len, sh_ch, sh_i.

sh_readline:
  LDA #0
  STA sh_len
rl_l:
  IN #1
  JZ rl_l
  IN #2
  STA sh_ch
  LDA sh_ch
  CMP #13
  JZ rl_done
  CMP #8
  JZ rl_bs
  CMP #0x20
  JC rl_hi          ; A >= 0x20: keep checking the printable range
  JMP rl_l          ; A < 0x20 (and not enter/backspace): ignore
rl_hi:
  CMP #0x7F
  JC rl_l            ; A >= 0x7F: ignore
  LDA sh_len
  CMP #16
  JC rl_l            ; buffer full (sh_len >= 16): drop the key
  LDX sh_len
  LDA sh_ch
  STA linebuf,X
  CALL std_putc
  LDA sh_len
  INA
  STA sh_len
  JMP rl_l
rl_bs:
  LDA sh_len
  JZ rl_l
  DEA
  STA sh_len
  LDA 0xF0           ; curX: cannot back up past column 0
  JZ rl_l
  DEA
  TAB                ; B = column - 1
  LDX 0xF1           ; X = row
  CALL std_setcur
  LDA #' '
  CALL std_putc
  ; PUTC always advances, which puts the cursor right back where it
  ; started -- so the next backspace would erase the same cell again and
  ; there would be no room to retype. Step back onto the hole we cleared.
  LDA 0xF0            ; curX
  DEA
  STA 0xF0
  JMP rl_l
rl_done:
  LDX sh_len
  LDA #0
  STA linebuf,X
  LDA #10
  CALL std_putc
  ; fold 'A'..'Z' to 'a'..'z'
  LDA #0
  STA sh_i
ll_l:
  LDA sh_i
  CMP sh_len
  JC ll_done         ; sh_i >= sh_len: consumed the whole line
  LDX sh_i
  LDA linebuf,X
  CMP #'A'
  JC ll_up           ; A >= 'A': check the upper bound
  JMP ll_nx
ll_up:
  CMP #'Z'+1
  JNC ll_fold        ; A < 'Z'+1: inside 'A'..'Z'
  JMP ll_nx
ll_fold:
  ADD #0x20
  STA linebuf,X
ll_nx:
  LDA sh_i
  INA
  STA sh_i
  JMP ll_l
ll_done:
  RET

; ---- split into cmd (linebuf) + arg (argp) ----------------------------
sh_split:
  LDA #0
  STA sh_i
sp_l:
  LDX sh_i
  LDA linebuf,X
  JZ sp_set
  CMP #' '
  JZ sp_cut
  LDA sh_i
  INA
  STA sh_i
  JMP sp_l
sp_cut:
  LDA #0
  STA linebuf,X
  LDA sh_i
  INA
  STA sh_i
sp_sk:
  LDX sh_i
  LDA linebuf,X
  JZ sp_set
  CMP #' '
  JNZ sp_set
  LDA sh_i
  INA
  STA sh_i
  JMP sp_sk
sp_set:
  ; argp = linebuf + sh_i (16-bit; carry propagates via ADC, implied)
  LDA sh_i
  ADD #(linebuf % 256)
  STA argp
  LDA #(linebuf / 256)
  ADC
  STA argp+1
  RET

; ---- pb = literal -> A = 1 if linebuf == literal -----------------------
sh_is:
  LDA #(linebuf % 256)
  STA pa
  LDA #(linebuf / 256)
  STA pa+1
  JMP std_streq

; ---- shell data --------------------------------------------------------
linebuf:   db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
argp:      db 0, 0
sh_len:    db 0
sh_ch:     db 0
sh_i:      db 0
