; m16k/sdk/asm/std.inc -- M16K SDK: libc-style routines for kernels.
;
; %include this ONCE, after svc.inc. Provides:
;   std_init/cls/setcol/setcur/putc/puts/newln  thin BIOS wrappers
;   std_getc      A = next key (blocks until one arrives)
;   std_printn    print A as decimal (no newline; 0-255)
;   std_mul       A = A * B            (low byte)
;   std_div       A = A / B            (0 if B = 0)
;   std_mod       A = A % B            (0 if B = 0)
;   std_rnd       A = random 0-255
;   std_delay     burn A * 65536-ish instructions (pass >= 1)
;   std_streq     NUL-strings at (pa) vs (pb) -> A = 1 equal / 0 not
;   std_incpa / std_incpb   16-bit increment of pointer var pa / pb
;   std_memcpy    copy mc_n bytes from (pa) to (pb)
;
; Variables used (2-4 bytes each, in your image): pa, pb, sr_t, sm_*, sd_*,
; sn_*, mc_*.

std_init:
  JMP BIOS_INIT
std_cls:
  JMP BIOS_CLS
std_setcol:
  JMP BIOS_SETCOL
std_setcur:
  JMP BIOS_SETCUR
std_putc:
  JMP BIOS_PUTC
std_puts:
  JMP BIOS_PUTS
std_newln:
  JMP BIOS_NEWLN

std_rnd:
  IN #0
  RET

std_getc:
  IN #1
  JZ std_getc
  IN #2
  RET

; ---- print A as decimal (no newline) --------------------------------
std_printn:
  STA sn_v
  LDA #0
  STA sn_h
  STA sn_t
  STA sn_started
sn_hl:
  LDA sn_v
  CMP #100
  JC sn_hsub
  JMP sn_tl
sn_hsub:
  SUB #100
  STA sn_v
  LDA sn_h
  INA
  STA sn_h
  JMP sn_hl
sn_tl:
  LDA sn_v
  CMP #10
  JC sn_tsub
  JMP sn_out
sn_tsub:
  SUB #10
  STA sn_v
  LDA sn_t
  INA
  STA sn_t
  JMP sn_tl
sn_out:
  LDA sn_h
  JZ sn_th
  ADD #'0'
  CALL std_putc
  LDA #1
  STA sn_started
sn_th:
  LDA sn_t
  JZ sn_tt
  JMP sn_pt
sn_tt:
  LDA sn_started
  JZ sn_ones
sn_pt:
  LDA sn_t
  ADD #'0'
  CALL std_putc
sn_ones:
  LDA sn_v
  ADD #'0'
  CALL std_putc
  RET

; ---- A = A * B (low byte) -------------------------------------------
std_mul:
  STA sm_a
  TBA
  STA sm_b
  LDA #0
  STA sm_r
  LDX #8
sm_l:
  LDA sm_b
  AND #1
  JZ sm_no
  LDA sm_r
  ADD sm_a
  STA sm_r
sm_no:
  LDA sm_a
  SHL
  STA sm_a
  LDA sm_b
  SHR
  STA sm_b
  DEX
  JNZ sm_l
  LDA sm_r
  RET

; ---- division core: sd_q = n / d, sd_r = n % d -----------------------
std_div:
  CALL sd_core
  LDA sd_q
  RET
std_mod:
  CALL sd_core
  LDA sd_r
  RET
sd_core:
  STA sd_n
  TBA
  STA sd_d
  JZ sd_zero
  LDA #0
  STA sd_q
sd_l:
  LDA sd_n
  CPB
  JNC sd_done
  LDA sd_n
  SBB
  STA sd_n
  LDA sd_q
  INA
  STA sd_q
  JMP sd_l
sd_done:
  LDA sd_n
  STA sd_r
  RET
sd_zero:
  LDA #0
  STA sd_q
  STA sd_r
  RET

; ---- delay -----------------------------------------------------------
std_delay:
  STA sd1
sd_o:
  LDA #0
  DEA
  STA sd2
sd_i:
  LDA sd2
  DEA
  STA sd2
  JNZ sd_i
  LDA sd1
  DEA
  STA sd1
  JNZ sd_o
  RET

; ---- 16-bit pointer increments ---------------------------------------
std_incpa:
  LDA pa
  INA
  STA pa
  JNZ ic_a
  LDA pa+1
  INA
  STA pa+1
ic_a:
  RET
std_incpb:
  LDA pb
  INA
  STA pb
  JNZ ic_b
  LDA pb+1
  INA
  STA pb+1
ic_b:
  RET

; ---- NUL-string compare: (pa) vs (pb) -> A = 1 / 0 -------------------
std_streq:
sr_l:
  LDA (pa)
  STA sr_t
  LDA (pb)
  JZ sr_b0
  CMP sr_t
  JNZ sr_no
  CALL std_incpa
  CALL std_incpb
  JMP sr_l
sr_b0:
  LDA sr_t
  JZ sr_yes
sr_no:
  LDA #0
  RET
sr_yes:
  LDA #1
  RET

; ---- memcpy: mc_n bytes from (pa) to (pb) ----------------------------
std_memcpy:
mc_l:
  LDA mc_n+1
  JNZ mc_go
  LDA mc_n
  JZ mc_done
mc_go:
  LDA (pa)
  STA (pb)
  CALL std_incpa
  CALL std_incpb
  LDA mc_n
  JNZ mc_dec
  LDA mc_n+1
  DEA
  STA mc_n+1
mc_dec:
  LDA mc_n
  DEA
  STA mc_n
  JMP mc_l
mc_done:
  RET

; ---- std data --------------------------------------------------------
pa:        db 0, 0
pb:        db 0, 0
sr_t:      db 0
sm_a:      db 0
sm_b:      db 0
sm_r:      db 0
sd_n:      db 0
sd_d:      db 0
sd_q:      db 0
sd_r:      db 0
sd1:       db 0
sd2:       db 0
sn_v:      db 0
sn_h:      db 0
sn_t:      db 0
sn_started: db 0
mc_n:      db 0, 0
