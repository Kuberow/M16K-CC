; m16k/sdk/examples/asm.asm -- the m16k assembler, as a MUNIX MEX app.
;
;   run asm FILE        assemble FILE into FILE's base name + ".mx"
;                       (run asm hello.asm -> hello.mx), then `run hello`.
;
; The syntax is asm.lua's: labels (`name:`), constants (`name = expr`),
; org, db, dw, all the same mnemonics and operand forms (#expr, expr,
; (expr), expr,X , expr,B), ; comments, 123 / 0x1F / 0b101 / 'c'
; literals and + - * / % with parentheses.  What it does NOT have is the
; preprocessor: %include and %macro are host-side, so write plain source.
;
; Limits: source <= 1535 bytes, image body <= 1512 bytes, <= 25 symbols
; with names <= 8 characters.  org defaults to 0x2010 (the 16 MEX variable
; bytes at 0x2000 are implied, so `org 0x2000` means the same thing) and
; may not be below it.  The MEX header always loads at 0x2000 with entry
; +16 -- that is where execution starts, so put code there first.
;
; The source text is read into 0x1300-0x18FF (free RAM between the
; kernel image and the syscall gates), NOT 0x3000: this app's own ~5 KB
; body spills to 0x34xx and would collide with a buffer up there. The
; kernel never runs while a MEX does, so the gap is safe scratch.
;
; Prints `OK <file bytes>` on success, `E<line> <reason>` on failure.

%include "mex.inc"
MEX_BEGIN

; ---- fixed addresses ---------------------------------------------------
SRC    = 0x1300      ; source text (<= 1535 bytes, lines NUL-terminated)
HDR    = 0x3600      ; 12-byte MEX header
VARB   = 0x360C      ; body starts here: 16 MEX variable bytes...
IMG    = 0x361C      ; ...then the image
OUTEND = 0x3C00      ; output must stop here (the stack grows down from 0x4000)
SYM    = 0x0100      ; symbol table, 10-byte entries (name[8] + value)
NSYM   = 0x01FA      ; symbol count (byte; entries live at 0x0100-0x01F9)
NMAX   = 25
DEFORG = 0x2010      ; default (and minimum) org

; ---- error codes (see errs, below) --------------------------------------
E_NOFILE = 1
E_BIG    = 2
E_MN     = 3
E_OPND   = 4
E_UNDEF  = 5
E_DUP    = 6
E_ORG    = 7
E_JUNK   = 8
E_OUT    = 9
E_NOSPC  = 10
E_FULL   = 11
E_LONG   = 12
E_DIV0   = 13
E_EMPTY  = 14
E_RANGE  = 15

; ========================================================================
; start: read the argument, load the source, run both passes, write the .mx
; ========================================================================
start:
  ; ---- usage ---------------------------------------------------------
  LDA APP_ARG+1
  JNZ go
  LDA APP_ARG
  JZ usage
go:
  ; ---- filename: first token of the argument -------------------------
  LDA APP_ARG
  STA p
  LDA APP_ARG+1
  STA p+1
  LDX #0
cf:
  LDA (p)
  JZ cfd
  CMP #' '
  JZ cfd
  CPX #16
  JZ cfd
  STA namebuf,X
  CALL inc_p
  INX
  JMP cf
cfd:
  LDA #0
  STA namebuf,X

  ; ---- open it -------------------------------------------------------
  LDA #(namebuf%256)
  STA FS_NAME
  LDA #(namebuf/256)
  STA FS_NAME+1
  CALL SVC_FS_OPEN
  CMP #0
  JZ ropen
  LDB #E_NOFILE
  CALL fail
  JMP failnow
ropen:
  CALL SVC_FS_TELL          ; A = length lo, X = length hi
  STA sl
  STX sh
  TXA
  CMP #6                    ; >= 6*256 = 1536 bytes is too big (C: hi >= 6)
  JC rbig
  JMP rsetup
rbig:
  LDB #E_BIG
  CALL fail
  JMP failnow

  ; ---- read the bytes ------------------------------------------------
  ; '\n' becomes the line terminator as it lands; a ';' ends its line
  ; too and the rest of that line (including its newline) is dropped --
  ; exactly what asm.lua's per-line comment strip does, so line numbers
  ; match.
rsetup:
  LDA #(SRC%256)
  STA p
  LDA #(SRC/256)
  STA p+1
  LDA #0
  STA mode
rl:
  LDA sl
  OR sh
  JZ rdone
  CALL SVC_FS_GETC
  STA tb
  LDA mode
  JNZ cdrop
  LDA tb
  CMP #10                  ; newline -> terminator
  JZ crnl
  CMP #0x3B                ; ';' -> terminator, drop the rest
  JZ crcom
  LDA tb
  STA (p)
  CALL inc_p
  JMP rnext
crnl:
  LDA #0
  STA (p)
  CALL inc_p
  JMP rnext
crcom:
  LDA #0
  STA (p)
  CALL inc_p
  LDA #1
  STA mode
  JMP rnext
cdrop:
  LDA tb
  CMP #10
  JNZ rnext
  LDA #0                   ; newline inside a comment: already terminated
  STA mode
rnext:
  LDA sl
  JNZ rn1
  LDA sh
  DEA
  STA sh
rn1:
  LDA sl
  DEA
  STA sl
  JMP rl
rdone:
  LDA mode                 ; comment ran to EOF: its terminator exists
  JNZ rterm
  LDA #0
  STA (p)                  ; terminate a file that has no final newline
  CALL inc_p
rterm:
  LDA p                    ; pend = one past the final NUL
  STA pend
  LDA p+1
  STA pend+1
  LDA #0
  STA NSYM                 ; empty symbol table
  STA pass
  STA abrt
  STA errc
  STA lineno
  STA lineno+1
  JMP psetup

; ---- per-pass setup ----------------------------------------------------
psetup:
  LDA #(SRC%256)
  STA p
  LDA #(SRC/256)
  STA p+1
  LDA pass
  JNZ p2
  LDA #DEFORG%256          ; pass 1 starts at the default org
  STA pc
  STA orgv
  LDA #DEFORG/256
  STA pc+1
  STA orgv+1
  LDA #0
  STA firstset
  JMP walk
p2:
  LDA orgv                 ; pass 2 starts where pass 1 decided
  STA pc
  LDA orgv+1
  STA pc+1
  ; imgp = VARB + orgv - 0x2000  (== 0x360C + (orgv - 0x2000))
  LDA orgv
  ADD #(VARB%256)
  STA imgp
  LDA #0
  ADC
  STA ci
  LDA orgv+1
  ADD #((VARB-0x2000)/256)
  STA imgp+1
  LDA imgp+1
  ADD ci
  STA imgp+1
  LDA imgp                 ; remember it: E_EMPTY if nothing is emitted
  STA img0
  LDA imgp+1
  STA img0+1
  ; gap = orgv - 0x2000 zero bytes between 0x2000 and the first code
  ; (orgv >= 0x2010 always, so this cannot borrow: >= 16 = the MEX
  ; variable bytes, which get zeroed here)
  LDA orgv
  STA gap
  LDA orgv+1
  SUB #0x20
  STA gap+1
  LDA #(VARB%256)
  STA q
  LDA #(VARB/256)
  STA q+1
fl:
  LDA gap
  OR gap+1
  JZ walk
  LDA #0
  STA (q)
  CALL inc_q
  LDA gap
  JNZ fl1
  LDA gap+1
  DEA
  STA gap+1
fl1:
  LDA gap
  DEA
  STA gap
  JMP fl

; ========================================================================
; walk: one NUL-terminated segment per source line, per pass
; ========================================================================
walk:
  LDA p+1                  ; p >= pend -> end of this pass
  CMP pend+1
  JNZ w_hi
  LDA p
  CMP pend
  JC w_end
  JMP w_body
w_hi:
  JC w_end
w_body:
  LDA lineno               ; line number (counts blanks, like asm.lua)
  INA
  STA lineno
  JNZ wl1
  LDA lineno+1
  INA
  STA lineno+1
wl1:
  LDA p
  STA ls
  LDA p+1
  STA ls+1
  LDA p
  STA q
  LDA p+1
  STA q+1
wscan:
  LDA (q)
  JZ wsdone
  CALL inc_q
  JMP wscan
wsdone:
  LDA q
  STA le                   ; line = [ls, le), *le == 0
  LDA q+1
  STA le+1
  LDA ls
  STA p
  LDA ls+1
  STA p+1
  CALL stmt
  LDA abrt
  JNZ failnow
  LDA le                   ; statement may have stopped at a planted NUL
  STA p                    ; deep inside the line -- resume at its end
  LDA le+1
  STA p+1
  CALL inc_p
  JMP walk
w_end:
  LDA pass
  JNZ assembled
  LDA #1
  STA pass
  LDA #0                   ; pass 2 re-numbers from 1
  STA lineno
  STA lineno+1
  JMP psetup

; ========================================================================
; stmt: labels / constants / org / db / dw / one instruction
; ========================================================================
stmt:
  LDA abrt
  JNZ st_ret
  CALL skipws
  LDA (p)
  JZ st_ret                ; blank line
  CALL rdident             ; A=1: tok holds an identifier, X = its length
  JZ notid
  LDA abrt                 ; an over-long name fails right here
  JNZ st_ret
  LDA (p)
  CMP #':'                 ; asm.lua wants the colon attached, no space
  JZ dolabel
  CMP #'='
  JZ doconst
  CMP #' '
  JZ idws
  CMP #9
  JZ idws
  CMP #13
  JZ idws
  JMP extl                 ; letters run into junk: it is one bad mnemonic
idws:
  CALL skipws
  LDA (p)
  CMP #'='
  JZ doconst
  JMP st_mn                ; identifier ended at a space -> mnemonic
notid:
  JMP extl                 ; no identifier: tok is empty, fill the token
extl:                      ; consume the whole non-space run into tok
  LDA (p)
  JZ extd
  CMP #' '
  JZ extd
  CMP #9
  JZ extd
  CMP #13
  JZ extd
  CPX #8                   ; tok keeps 8 chars + NUL
  JC extno
  STA tok,X
extno:
  INX
  CALL inc_p
  JMP extl
extd:
  CPX #9                   ; clamp so the NUL always fits
  JC extc
  JMP extz
extc:
  LDX #8
extz:
  LDA #0
  STA tok,X

; ---- mnemonic dispatch -------------------------------------------------
st_mn:
  CALL skipws              ; operand starts here (or at the end of line)
  CALL tokupper
  LDA tok                  ; ORG
  CMP #'O'
  JNZ md1
  LDA tok+1
  CMP #'R'
  JNZ md1
  LDA tok+2
  CMP #'G'
  JNZ md1
  LDA tok+3
  JNZ md1
  JMP doorg
md1:
  LDA tok                  ; DB
  CMP #'D'
  JNZ md2
  LDA tok+1
  CMP #'B'
  JZ dob
  CMP #'W'
  JZ dow
md2:
  JMP realmn
dob:
  LDA tok+2
  JNZ md2
  JMP db_h
dow:
  LDA tok+2
  JNZ md2
  JMP dw_h

realmn:
  CALL findmn              ; A = 1 -> moff names the opcode record
  JZ emn
  CALL classify            ; -> kind, expr at p, bnd (0 = run to the NUL)
  CALL opaddr              ; q = mn_ops + moff + kind
  LDA q
  ADD kind
  STA q
  LDA q+1
  ADC
  STA q+1
  LDA (q)
  CMP #0xFF                ; 0xFF marks a form the instruction has not got
  JNZ rm_val
  LDB #E_OPND
  CALL fail
  RET
emn:
  LDB #E_MN
  CALL fail
  RET
rm_val:
  STA opcode
  LDA pass
  JNZ rm_p2
  CALL inc_pc              ; pass 1: size = 1 / 2 / 3 by kind
  LDA kind
  JZ rm_done
  CALL inc_pc
  LDA kind
  CMP #2
  JNC rm_done
  CALL inc_pc
rm_done:
  RET
rm_p2:
  LDA opcode               ; pass 2: emit opcode, then the operand
  CALL emit
  LDA kind
  JZ st_ret
  LDA bnd+1                ; ind/ix/ib end before a boundary, not the NUL
  OR bnd
  JZ rm_np
  LDA #0
  STA (bnd)
rm_np:
  CALL ev
  LDA abrt
  JNZ st_ret
  LDA kind
  CMP #1
  JZ rm_imm
  LDA ev_v                 ; abs/ind/ix/ib: 16-bit little-endian
  CALL emit
  LDA ev_v+1
  CALL emit
  JMP st_ret
rm_imm:
  LDA ev_v+1               ; range: 0..255 or -128..-1 stored as FFXx
  JZ rm_iok
  CMP #0xFF
  JNZ rm_bad
  LDA ev_v
  CMP #0x80
  JNC rm_bad
rm_iok:
  LDA ev_v
  CALL emit
  JMP st_ret
rm_bad:
  LDB #E_RANGE
  CALL fail
  JMP st_ret

; ---- name: -------------------------------------------------------------
dolabel:
  CALL inc_p               ; over the ':'
  LDA pass
  JNZ stmt                 ; pass 2: labels were defined in pass 1
  CALL tok2stok
  LDA pc                   ; value = current pc
  STA ev_l
  LDA pc+1
  STA ev_l+1
  CALL symadd              ; duplicate / full -> fail inside
  JMP stmt

; ---- name = expr --------------------------------------------------------
doconst:
  CALL inc_p               ; over the '='
  LDA pass
  JNZ st_ret               ; pass 2: consumed in pass 1, emits nothing
  CALL ev                  ; evaluated immediately: defined symbols only
  LDA abrt
  JNZ st_ret
  CALL tok2stok
  LDA ev_v
  STA ev_l
  LDA ev_v+1
  STA ev_l+1
  CALL symadd
st_ret:
  RET

; ---- org ---------------------------------------------------------------
doorg:
  CALL skipws
  CALL ev
  LDA abrt
  JNZ st_ret
  LDA ev_v                 ; 0x2000 means the same thing as 0x2010 here:
  STA tgt                  ; the 16 variable bytes are implied
  LDA ev_v+1
  STA tgt+1
  CMP #0x20
  JNZ orgck
  LDA tgt
  JNZ orgck
  LDA #DEFORG%256
  STA tgt
  LDA #DEFORG/256
  STA tgt+1
orgck:                     ; org must not be below 0x2010
  LDA tgt+1
  CMP #0x20
  JNZ orghi
  LDA tgt
  CMP #DEFORG%256
  JC org1
  JMP orgerr
orghi:
  JC org1                  ; hi > 0x20 -> fine
  JMP orgerr
orgerr:
  LDB #E_ORG
  CALL fail
  RET
org1:
  LDA tgt+1                ; ...and not above 0x25F4: the gap it implies
  CMP #0x26                ; plus the image must fit 0x360C..0x3BFF, or
  JC orgerr                ; the unguarded gap fill would reach the stack
  CMP #0x25
  JNZ orgup                ; <= 0x25xx is fine whatever the low byte is
  LDA tgt
  CMP #0xF5
  JC orgerr                ; 0x25F5..0x25FF leaves no room at all
orgup:
  LDA firstset             ; first org also decides where pass 2 starts
  JNZ org2
  LDA tgt
  STA orgv
  LDA tgt+1
  STA orgv+1
  LDA #1
  STA firstset
org2:
  LDA pass                 ; pass 1: just move pc
  JNZ orgp2
  LDA tgt
  STA pc
  LDA tgt+1
  STA pc+1
  RET
orgp2:
  LDA tgt+1                ; backwards -> error, as asm.lua does
  CMP pc+1
  JNZ op2h
  LDA tgt
  CMP pc
  JC opd
  JMP orgerr
op2h:
  JC opd
  JMP orgerr
opd:                       ; pad with zeros from pc up to the target
  LDA abrt                 ; emit hit TOOBIG: stop, walk will report it
  JNZ pddone
  LDA pc+1
  CMP tgt+1
  JNZ pdh
  LDA pc
  CMP tgt
  JC pddone
  JMP pdbyte
pdh:
  JC pddone
pdbyte:
  LDA #0
  CALL emit
  JMP opd
pddone:
  RET

; ---- db ----------------------------------------------------------------
db_h:
dloop:
  LDA abrt
  JNZ db_exit
  CALL split               ; -> ce, cec, tlen (trimmed), lastc
  LDA tlen
  JNZ db_item              ; something non-blank in the item
  LDA tlen+1
  JNZ db_item
  LDA cec
  JZ db_exit               ; nothing and no comma: end of the list
db_item:
  LDA (p)
  CMP #'"'
  JZ db_str
  LDA pass
  JNZ db_ev
  CALL inc_pc              ; pass 1: one byte per expression item
  JMP db_adv
db_ev:
  LDA cec                  ; pass 2: bound the item at its comma
  JZ db_ev1
  LDA #0
  STA (ce)
db_ev1:
  CALL ev
  LDA abrt
  JNZ db_exit
  LDA ev_v                 ; db emits the low byte, like asm.lua's b%256
  CALL emit
  JMP db_adv
db_str:
  LDA lastc                ; the trimmed item must end in a quote...
  CMP #'"'
  JZ dbs1
  LDB #E_JUNK
  CALL fail
  JMP dloop
dbs1:
  LDA tlen+1               ; ...and be at least two bytes long
  JNZ dbs2
  LDA tlen
  CMP #2
  JC dbs2
  LDB #E_JUNK
  CALL fail
  JMP dloop
dbs2:
  LDA tlen                 ; byte count = trimmed length - 2
  SUB #2
  STA tlen
  JC dbsc                  ; no borrow: the high half stands (borrow: -1)
  LDA tlen+1
  DEA
  STA tlen+1
dbsc:
  LDA pass
  JNZ dbsout
  LDA pc                   ; pass 1: count them -- pc += content length
  ADD tlen
  STA pc
  LDA #0
  ADC
  STA ci
  LDA pc+1
  ADD tlen+1
  ADD ci
  STA pc+1
  JMP db_adv
dbsout:                    ; emit exactly that many bytes from p+1
  LDA p
  STA q
  LDA p+1
  STA q+1
  CALL inc_q
dbsem:
  LDA tlen
  OR tlen+1
  JZ db_adv
  LDA (q)
  CALL emit
  CALL inc_q
  LDA tlen
  JNZ dbsn
  LDA tlen+1
  DEA
  STA tlen+1
dbsn:
  LDA tlen
  DEA
  STA tlen
  JMP dbsem
db_adv:
  LDA cec                  ; comma boundary -> next item, else finished
  JZ db_exit
  LDA ce
  STA p
  LDA ce+1
  STA p+1
  CALL inc_p
  JMP dloop
db_exit:
  RET

; ---- dw ----------------------------------------------------------------
dw_h:
dwloop:
  LDA abrt
  JNZ dw_exit
  CALL split
  LDA tlen
  JNZ dw_item
  LDA tlen+1
  JNZ dw_item
  LDA cec
  JZ dw_exit
dw_item:
  LDA pass
  JNZ dw_ev
  CALL inc_pc              ; pass 1: two bytes per item
  CALL inc_pc
  JMP dw_adv
dw_ev:
  LDA cec
  JZ dw_ev1
  LDA #0
  STA (ce)
dw_ev1:
  CALL ev                  ; strings land here too: " is a bad token
  LDA abrt
  JNZ dw_exit
  LDA ev_v
  CALL emit
  LDA ev_v+1
  CALL emit
dw_adv:
  LDA cec
  JZ dw_exit
  LDA ce
  STA p
  LDA ce+1
  STA p+1
  CALL inc_p
  JMP dwloop
dw_exit:
  RET

; ========================================================================
; classify: operand at p -> kind, expr start, boundary to plant (0 = none)
; kind: 0 imp, 1 imm, 2 abs, 3 ind, 4 ix, 5 ib
; ========================================================================
classify:
  LDA #0
  STA bnd
  STA bnd+1
  LDA (p)
  JNZ cl1
  LDA #0                   ; empty operand -> implied
  STA kind
  RET
cl1:
  CMP #'#'
  JNZ cl2
  LDA #1
  STA kind
  CALL inc_p
  RET
cl2:                       ; one forward scan finds the last non-blank
  LDA p                    ; char and the last comma at once
  STA q
  LDA p+1
  STA q+1
  LDA #0
  STA last
  STA last+1
  STA cma
  STA cma+1
cls:
  LDA (q)
  JZ cld
  CMP #' '
  JZ cladv
  CMP #9
  JZ cladv
  CMP #13
  JZ cladv
  LDA (q)
  CMP #','
  JNZ clsl
  LDA q
  STA cma
  LDA q+1
  STA cma+1
  LDA (q)
clsl:
  LDA q                    ; last non-blank position
  STA last
  LDA q+1
  STA last+1
cladv:
  CALL inc_q
  JMP cls
cld:
  LDA (p)
  CMP #'('
  JNZ cl_ix
  LDA last                 ; ind: starts with '(' and ends with ')'
  STA q
  LDA last+1
  STA q+1
  LDA (q)
  CMP #')'
  JNZ cl_ix
  LDA #3
  STA kind
  CALL inc_p
  LDA last                 ; the expression stops before that ')'
  STA bnd
  LDA last+1
  STA bnd+1
  RET
cl_ix:
  LDA last                 ; indexed: last char is X or B (any case)
  STA q
  LDA last+1
  STA q+1
  LDA (q)
  CMP #'X'
  JZ cl_i1
  CMP #'x'
  JZ cl_i1
  CMP #'B'
  JZ cl_i1
  CMP #'b'
  JZ cl_i1
  LDA #2                   ; otherwise: absolute
  STA kind
  RET
cl_i1:
  LDA cma+1                ; and there must be a comma before it
  JNZ cif
  LDA cma
  JNZ cif
  LDA #2                   ; "a X" with no comma is just abs (and will
  STA kind                 ; die as trailing junk, like asm.lua)
  RET
cif:
  LDA cma                  ; gap between that comma and the last char
  STA q                    ; must be blanks only
  LDA cma+1
  STA q+1
  CALL inc_q
cig:
  LDA q+1
  CMP last+1
  JNZ cigh
  LDA q
  CMP last
  JC cig_ok
  JMP cig_ch
cigh:
  JC cig_ok
cig_ch:
  LDA (q)
  CMP #' '
  JZ cign
  CMP #9
  JZ cign
  CMP #13
  JZ cign
  LDA #2                   ; "a,b X": comma is not the separator -> abs
  STA kind
  RET
cign:
  CALL inc_q
  JMP cig
cig_ok:
  LDA last                 ; X/x -> kind 4, B/b -> kind 5
  STA q
  LDA last+1
  STA q+1
  LDA (q)
  CMP #'B'
  JZ cib
  CMP #'b'
  JZ cib
  LDA #4
  STA kind
  JMP ciset
cib:
  LDA #5
  STA kind
ciset:
  LDA cma                  ; the base expression stops at the comma
  STA bnd
  LDA cma+1
  STA bnd+1
  RET

; ========================================================================
; split: item boundary scan for db/dw.  p at the item's first non-blank.
; out: ce (boundary), cec (1 if a top-level comma sits there), tlen
; (trimmed length in bytes), lastc (last non-blank char).  Read-only.
; ========================================================================
split:
  CALL skipws
  LDA p
  STA q
  LDA p+1
  STA q+1
  LDA #0
  STA cec
  STA tlen
  STA tlen+1
  STA cnt
  STA cnt+1
  STA lastc
  STA inq
  STA depth
spl:
  LDA (q)
  JZ spend
  LDA inq
  JNZ spinq
  LDA (q)
  CMP #'"'
  JZ spq
  CMP #'('
  JZ spo
  CMP #')'
  JZ spc
  CMP #','
  JZ spcm
  JMP spcmon
spinq:                     ; inside a quote only '"' closes it
  LDA (q)
  CMP #'"'
  JNZ spcmon
  LDA #0
  STA inq
  JMP spcmon
spq:
  LDA #1
  STA inq
  JMP spcmon
spo:
  LDA depth
  INA
  STA depth
  JMP spcmon
spc:
  LDA depth
  DEA
  STA depth
  JMP spcmon
spcm:
  LDA depth                ; a top-level comma is the boundary itself
  JNZ spcmon
  LDA q
  STA ce
  LDA q+1
  STA ce+1
  LDA #1
  STA cec
  RET
spcmon:                    ; count everything, remember the last non-blank
  LDA cnt
  INA
  STA cnt
  JNZ spcn
  LDA cnt+1
  INA
  STA cnt+1
spcn:
  LDA (q)
  CMP #' '
  JZ spadv
  CMP #9
  JZ spadv
  CMP #13
  JZ spadv
  LDA cnt                  ; trimmed length runs through this char
  STA tlen
  LDA cnt+1
  STA tlen+1
  LDA (q)
  STA lastc
spadv:
  CALL inc_q
  JMP spl
spend:
  LDA q
  STA ce
  LDA q+1
  STA ce+1
  RET

; ========================================================================
; symbol table (entries at SYM: name[8] NUL-padded, value lo/hi)
; key is always stok
; ========================================================================
symfind:                   ; A = 1 -> value in syv, 0 -> not found
  LDA NSYM
  JZ sfnx
  STA sct
  LDA #(SYM%256)
  STA sq
  LDA #(SYM/256)
  STA sq+1
sfl:
  LDA sq
  STA sq0
  LDA sq+1
  STA sq0+1
  LDX #0
sfc:
  LDA stok,X
  STA tb
  LDA (sq)
  CMP tb
  JNZ sfn
  CMP #0                   ; both NUL: exact match
  JZ sfm
  CALL inc_sq              ; advance the entry byte cursor (sq)
  INX
  CPX #8
  JC sfm                   ; 8 identical bytes and no NUL: also a match
  JMP sfc
sfn:                       ; next entry: +10 bytes
  LDA sq0
  ADD #10
  STA sq
  LDA sq0+1
  ADC
  STA sq+1
  LDA sct
  DEA
  STA sct
  JNZ sfl
sfnx:
  LDA #0
  RET
sfm:
  LDA sq0                  ; value sits at entry + 8
  ADD #8
  STA tq
  LDA sq0+1
  ADC
  STA tq+1
  LDA (tq)
  STA syv
  LDA tq
  INA
  STA tq
  JNZ sfmv
  LDA tq+1
  INA
  STA tq+1
sfmv:
  LDA (tq)
  STA syv+1
  LDA #1
  RET

symadd:                    ; stok + ev_l -> append (duplicate/full fail)
  CALL symfind
  JZ sanew
  LDB #E_DUP
  CALL fail
  RET
sanew:
  LDA NSYM
  CMP #NMAX
  JC safull                 ; C: count >= NMAX -> table is full
  ; entry = SYM + NSYM*10 (NMAX <= 25, so NSYM*10 <= 240: 8-bit is safe)
  LDA NSYM
  SHL
  SHL
  SHL                       ; x8
  STA tb
  LDA NSYM
  SHL                       ; x2
  ADD tb                    ; x10
  STA tb
  LDA #(SYM%256)
  ADD tb
  STA sq
  LDA #(SYM/256)
  ADC
  STA sq+1
  LDX #0
sal:
  LDA stok,X                ; 8 name bytes (anything past the NUL is
  STA tb                    ; unreachable: lookups stop at the terminator)
  LDA tb
  STA (sq)
  CALL inc_sq
  INX
  CPX #8
  JNZ sal
  LDA ev_l
  STA (sq)
  CALL inc_sq
  LDA ev_l+1
  STA (sq)
  LDA NSYM
  INA
  STA NSYM
  RET
safull:
  LDB #E_FULL
  CALL fail
  RET

; ========================================================================
; mnemonic table: NUL-separated names, then one 6-byte record per name
; (imp, imm, abs, ind, ix, ib) with 0xFF for forms that do not exist
; ========================================================================
findmn:                    ; tok -> moff, A = 1 found / 0 unknown
  LDA #0
  STA moff
  STA moff+1
  LDA #(mn_names%256)
  STA q
  LDA #(mn_names/256)
  STA q+1
fml:
  LDX #0
fmc:
  LDA (q)
  STA tb
  LDA tok,X
  CMP tb
  JNZ fmn
  LDA tb                   ; equal and NUL: the whole name matched
  JZ fmf
  CALL inc_q
  INX
  JMP fmc
fmn:
fmsk:                      ; skip to the next name in the blob
  LDA (q)
  JZ fms1
  CALL inc_q
  JMP fmsk
fms1:
  CALL inc_q
  LDA moff                 ; records are 6 bytes apart
  ADD #6
  STA moff
  LDA moff+1
  ADC
  STA moff+1
  LDA (q)
  JZ fmno                  ; empty name: end marker
  JMP fml
fmf:
  LDA #1
  RET
fmno:
  LDA #0
  RET

opaddr:                    ; q = mn_ops + moff
  LDA #(mn_ops%256)
  ADD moff
  STA q
  LDA #0
  ADC
  STA ci
  LDA #(mn_ops/256)
  ADD moff+1
  STA q+1
  LDA q+1
  ADD ci
  STA q+1
  RET

; ========================================================================
; expression evaluator: sum -> term -> unary -> primary, bounded by the
; first NUL at or after p.  Result in ev_v.  Failures set abrt and unwind
; through the PUSHA'd frames by popping exactly what each level pushed.
; ========================================================================
ev:
  LDA abrt                 ; never start on a failed line
  JNZ evq
  CALL ev_sum
  LDA abrt
  JNZ evq
  CALL skipws
  LDA (p)
  JZ evq                   ; consumed cleanly to the boundary
  LDB #E_JUNK
  CALL fail
evq:
  RET

ev_sum:
  CALL ev_term
  LDA abrt
  JNZ esd
esl:
  CALL skipws
  LDA (p)
  CMP #'+'
  JZ esgo
  CMP #'-'
  JNZ esd
esgo:
  STA ev_op
  CALL inc_p
  LDA ev_v                 ; save the left side and the operator
  PUSHA
  LDA ev_v+1
  PUSHA
  LDA ev_op
  PUSHA
  CALL ev_term
  LDA abrt
  JNZ esun
  POPA
  STA ev_op
  POPA
  STA ev_l+1
  POPA
  STA ev_l
  LDA ev_op
  CMP #'-'
  JZ essub
  LDA ev_l                 ; ev_v = ev_l + ev_v
  ADD ev_v
  STA ev_v
  LDA #0
  ADC
  STA ci
  LDA ev_l+1
  ADD ev_v+1
  STA ev_v+1
  LDA ev_v+1
  ADD ci
  STA ev_v+1
  JMP esl
essub:
  LDA ev_l                 ; ev_v = ev_l - ev_v (borrow into the high half)
  SUB ev_v
  STA ev_v
  JNC esbr
  LDA ev_l+1
  SUB ev_v+1
  STA ev_v+1
  JMP esl
esbr:
  LDA ev_l+1
  SUB ev_v+1
  STA ev_v+1
  DEA
  STA ev_v+1
  JMP esl
esun:
  POPA
  POPA
  POPA
esd:
  RET

ev_term:
  CALL ev_un
  LDA abrt
  JNZ etd
etl:
  CALL skipws
  LDA (p)
  CMP #'*'
  JZ etgo
  CMP #'/'
  JZ etgo
  CMP #'%'
  JNZ etd
etgo:
  STA ev_op
  CALL inc_p
  LDA ev_v
  PUSHA
  LDA ev_v+1
  PUSHA
  LDA ev_op
  PUSHA
  CALL ev_un
  LDA abrt
  JNZ etun
  POPA
  STA ev_op
  POPA
  STA ev_l+1
  POPA
  STA ev_l
  LDA ev_op
  CMP #'*'
  JZ etmul
  LDA ev_l                 ; / and % share the division
  STA dva
  LDA ev_l+1
  STA dva+1
  LDA ev_v
  STA dvb
  LDA ev_v+1
  STA dvb+1
  LDA dvb
  OR dvb+1
  JNZ etgo2
  LDB #E_DIV0
  CALL fail
  JMP etd
etgo2:
  CALL div16
  LDA ev_op
  CMP #'/'
  JZ etq
  LDA dva                  ; % -> the remainder left in dva
  STA ev_v
  LDA dva+1
  STA ev_v+1
  JMP etl
etq:
  LDA quot                 ; / -> the quotient
  STA ev_v
  LDA quot+1
  STA ev_v+1
  JMP etl
etmul:
  LDA ev_l                 ; * -> mul16
  STA dva
  LDA ev_l+1
  STA dva+1
  LDA ev_v
  STA dvb
  LDA ev_v+1
  STA dvb+1
  CALL mul16
  LDA dvr
  STA ev_v
  LDA dvr+1
  STA ev_v+1
  JMP etl
etun:
  POPA
  POPA
  POPA
etd:
  RET

ev_un:
  CALL skipws
  LDA (p)
  CMP #'-'
  JNZ evpr
  CALL inc_p
  CALL ev_un
  LDA abrt
  JNZ eur
  LDA #0                   ; two's complement negation
  SUB ev_v
  STA ev_v
  JNC eunb                 ; C = no borrow: the low half was 0
  LDA #0                   ; borrowed from the high half: it takes the -1
  SUB ev_v+1
  STA ev_v+1
  DEA
  STA ev_v+1
  RET
eunb:
  LDA #0
  SUB ev_v+1
  STA ev_v+1
eur:
  RET

evpr:
  LDA (p)
  JNZ ep1
  LDB #E_JUNK              ; expression ended before it should have
  CALL fail
  RET
ep1:
  CMP #'('
  JZ eppar
  CMP #0x27                ; 'c'
  JZ epchr
  CMP #'0'
  JNC epltr                ; below '0': never a number
  CMP #'9'+1
  JC epltr                 ; at or past ':': not a digit
  JMP epnum                ; '0'..'9': maybe 0x / 0b / decimal
epltr:
  CALL idch                ; a letter or '_' -> symbol, anything else junk
  JZ epsym
  LDB #E_JUNK
  CALL fail
  RET
epnum:
  LDA p                    ; look past the '0' for an x or a b
  STA q
  LDA p+1
  STA q+1
  CALL inc_q
  LDA (q)
  CMP #'x'
  JZ ephx
  CMP #'X'
  JZ ephx
  CMP #'b'
  JZ epbn
  CMP #'B'
  JZ epbn
  JMP epdec
ephx:
  CALL inc_p               ; over '0'
  CALL inc_p               ; over 'x'
  LDA #0
  STA acc
  STA acc+1
  LDA #16
  STA bmul
  LDA #0
  STA dcnt
ehl:
  LDA (p)
  CALL nib
  CMP #16
  JC ehdone                ; not a hex digit: the number ends here
  STA dgt
  CALL accmul
  CALL inc_p
  LDA dcnt
  INA
  STA dcnt
  JMP ehl
ehdone:
  LDA dcnt                 ; "0x" with no digits is junk, like asm.lua
  JNZ epxfer
  LDB #E_JUNK
  CALL fail
  RET
epbn:
  CALL inc_p
  CALL inc_p
  LDA #0
  STA acc
  STA acc+1
  LDA #2
  STA bmul
  LDA #0
  STA dcnt
ebnl:
  LDA (p)
  CALL nib
  CMP #2
  JC ebndone               ; not 0 or 1: the number ends here
  STA dgt
  CALL accmul
  CALL inc_p
  LDA dcnt
  INA
  STA dcnt
  JMP ebnl
ebndone:
  LDA dcnt
  JNZ epxfer
  LDB #E_JUNK
  CALL fail
  RET
epdec:
  LDA #0
  STA acc
  STA acc+1
  LDA #10
  STA bmul
edl:
  LDA (p)
  CALL nib
  CMP #10
  JC eddone                ; not a decimal digit: the number ends here
  STA dgt
  CALL accmul
  CALL inc_p
  JMP edl
eddone:
  JMP epxfer
epxfer:
  LDA acc
  STA ev_v
  LDA acc+1
  STA ev_v+1
  RET
epchr:
  CALL inc_p               ; over the opening quote
  LDA (p)
  STA ev_v
  LDA #0
  STA ev_v+1
  CALL inc_p               ; the closing quote must be there
  LDA (p)
  CMP #0x27
  JZ epchrok
  LDB #E_JUNK
  CALL fail
  RET
epchrok:
  CALL inc_p
  RET
eppar:
  CALL inc_p
  CALL ev_sum
  LDA abrt
  JNZ epr
  CALL skipws
  LDA (p)
  CMP #')'
  JZ eppc
  LDB #E_JUNK
  CALL fail
  RET
eppc:
  CALL inc_p
epr:
  RET
epsym:                     ; identifier -> symbol lookup
  LDX #0
epsrl:
  LDA (p)
  CALL idch
  JNZ epsrd
  LDA (p)
  CPX #8                   ; keep 8 chars + NUL
  JC epsno
  STA stok,X
epsno:
  INX
  CALL inc_p
  JMP epsrl
epsrd:
  CPX #9
  JC epsrc
  JMP epsr2
epsrc:
  LDX #8
epsr2:
  LDA #0
  STA stok,X
  CALL symfind
  JZ epsmiss
  LDA syv
  STA ev_v
  LDA syv+1
  STA ev_v+1
  RET
epsmiss:
  LDB #E_UNDEF
  CALL fail
  RET

; ---- digit helpers ------------------------------------------------------
nib:                       ; A = char -> A = 0..15 if a hex digit, else >= 16
  CMP #'a'
  JNC nba                  ; below 'a': try 'A', then the digits
  SUB #'a'                 ; 'a'..'z' -> 10..35 ('g'..'z' land >= 16)
  ADD #10
  RET
nba:
  CMP #'A'
  JNC nbd                  ; below 'A': must be a digit
  SUB #'A'                 ; 'A'..'Z' -> 10..35 ('G'..'Z' land >= 16)
  ADD #10
  RET
nbd:
  CMP #'9'+1
  JC nibad                 ; ':'..'@' are not digits
  SUB #'0'                 ; '0'..'9' -> 0..9 (below '0' underflows >= 16)
  RET
nibad:
  LDA #16
  RET

accmul:                    ; acc = acc * bmul + dgt
  LDA acc
  STA dva
  LDA acc+1
  STA dva+1
  LDA bmul
  STA dvb
  LDA #0
  STA dvb+1
  CALL mul16
  LDA dvr
  ADD dgt
  STA acc
  LDA #0
  ADC
  STA ci
  LDA dvr+1
  ADD ci
  STA acc+1
  RET

idch:                      ; A = char -> Z set iff [A-Za-z_0-9]
  CMP #'_'
  JZ idv
  CMP #'0'
  JNC idno                 ; below '0': only '_' can be valid
  CMP #'9'+1
  JC idltr                 ; at or past ':': not a digit
  JMP idv                  ; '0'..'9'
idltr:
  CMP #'A'
  JNC idno                 ; ':', ';', '<', '=', '>', '?', '@'
  CMP #'Z'+1
  JC idup                  ; at or past 0x5B: not A-Z
  JMP idv                  ; 'A'..'Z'
idup:
  CMP #'a'
  JNC idno                 ; '[', '\', ']', '^', '`'
  CMP #'z'+1
  JC idno                  ; at or past '{'
  JMP idv                  ; 'a'..'z'
idv:
  LDA #0
  RET
idno:
  LDA #1
  RET

; ---- 16-bit multiply and divide ----------------------------------------
mul16:                     ; dvr = dva * dvb (low 16 bits)
  LDA #0
  STA dvr
  STA dvr+1
  LDA dvb
  STA mc
  LDA dvb+1
  STA mc+1
mv1:
  LDA mc
  OR mc+1
  JZ mvd
  LDA mc
  AND #1
  JZ mv2
  LDA dvr
  ADD dva
  STA dvr
  LDA #0
  ADC
  STA ci
  LDA dvr+1
  ADD dva+1
  STA dvr+1
  LDA dvr+1
  ADD ci
  STA dvr+1
mv2:
  LDA mc+1                 ; mc >>= 1, low half gains the high bit
  SHR
  STA mc+1
  JNC mv3
  LDA mc
  SHR
  STA mc
  LDA mc
  OR #0x80
  STA mc
  JMP mv1
mv3:
  LDA mc
  SHR
  STA mc
  JMP mv1
mvd:
  RET

div16:                     ; repeated subtract: quot = dva/dvb,
  LDA #0                   ; remainder left in dva
  STA quot
  STA quot+1
dv1:
  LDA dva+1                ; dva >= dvb ?
  CMP dvb+1
  JNZ dvhi
  LDA dva
  CMP dvb
  JC dvsub
  JMP dvd
dvhi:
  JC dvsub
  JMP dvd
dvsub:
  LDA dva                  ; dva -= dvb, propagating the borrow
  SUB dvb
  STA dva
  JNC dvbr
  LDA dva+1
  SUB dvb+1
  STA dva+1
  JMP dvq
dvbr:
  LDA dva+1
  SUB dvb+1
  STA dva+1
  DEA
  STA dva+1
dvq:
  LDA quot
  INA
  STA quot
  JNZ dv1
  LDA quot+1
  INA
  STA quot+1
  JMP dv1
dvd:
  RET

; ========================================================================
; small helpers
; ========================================================================
inc_p:
  LDA p
  INA
  STA p
  JNZ incpd
  LDA p+1
  INA
  STA p+1
incpd:
  RET

inc_q:
  LDA q
  INA
  STA q
  JNZ incqd
  LDA q+1
  INA
  STA q+1
incqd:
  RET

inc_sq:                      ; symbol-table byte cursor (sq, not q!)
  LDA sq
  INA
  STA sq
  JNZ incsqd
  LDA sq+1
  INA
  STA sq+1
incsqd:
  RET

inc_pc:
  LDA pc
  INA
  STA pc
  JNZ incpcd
  LDA pc+1
  INA
  STA pc+1
incpcd:
  RET

inc_imgp:
  LDA imgp
  INA
  STA imgp
  JNZ incigd
  LDA imgp+1
  INA
  STA imgp+1
incigd:
  RET

skipws:                    ; step over blanks, tabs and CR
  LDA (p)
  CMP #' '
  JZ sw1
  CMP #9
  JZ sw1
  CMP #13
  JNZ swd
sw1:
  CALL inc_p
  JMP skipws
swd:
  RET

rdident:                   ; read [A-Za-z_][A-Za-z0-9_]* into tok
  LDA (p)                  ; A = 1: found (X = length, p moved past it);
  CALL idch                ; A = 0: nothing (X = 0, tok empty)
  JZ rid1                  ; (idch answers 0/1 in A -- Z says which)
  JMP ridno
rid1:
  LDA (p)                  ; the character itself: idch left 0 in A, so
  CMP #'A'                 ; without this reload every name would compare
  JC rdyes                 ; as a digit.  '_' (0x5F) and both letter
  JMP ridno                ; cases land at >= 'A'; digits do not.
rdyes:
  LDX #0
rdl:
  LDA (p)
  CALL idch
  JNZ rdd                  ; not an identifier character: done
  LDA (p)                  ; reload: idch returned 0/1, not the character
  CPX #8
  JC rdfull                ; room only for tok[0..7]
  STA tok,X
  INX
  CALL inc_p
  JMP rdl
rdfull:                    ; a ninth character: names stop at eight
  LDB #E_LONG              ; (first error wins, so repeats are harmless)
  CALL fail
  INX
  CALL inc_p
  JMP rdl
rdd:
  CPX #9
  JNC rdterm               ; X <= 8: terminate right there
  LDX #8                   ; longer: put the NUL at the clamp
rdterm:
  LDA #0
  STA tok,X
  LDA #1
  RET
ridno:
  LDA #0
  STA tok
  LDX #0
  RET

tokupper:
  LDX #0
tul:
  LDA tok,X
  JZ tu2
  CMP #'a'
  JNC tun                  ; below 'a': already upper (or not a letter)
  CMP #'z'+1
  JC tun                   ; at or past '{': not a lowercase letter
  SUB #0x20
  STA tok,X
tun:
  INX
  JMP tul
tu2:
  RET

tok2stok:
  LDX #0
tkl:
  LDA tok,X
  STA stok,X
  INX
  CPX #9
  JNZ tkl
  RET

emit:                      ; A = byte -> image, image end guards itself
  STA tb
  LDA imgp+1
  CMP #(OUTEND/256)
  JC emf                   ; at or past 0x3C00: the output is full
  LDA tb
  STA (imgp)
  CALL inc_imgp
  CALL inc_pc
  RET
emf:
  LDB #E_OUT
  CALL fail
  RET

; ========================================================================
; reporting
; ========================================================================
print16:                   ; n -> decimal on the screen
  LDA n
  OR n+1
  JNZ p16g
  LDA #'0'
  CALL SVC_PUTC
  RET
p16g:
  LDX #0
p16l:
  LDA n
  OR n+1
  JZ p16p
  LDA n
  STA dva
  LDA n+1
  STA dva+1
  LDA #10
  STA dvb
  LDA #0
  STA dvb+1
  CALL div16
  LDA dva                  ; remainder 0..9 is the next digit
  ADD #'0'
  STA pbuf,X
  INX
  LDA quot
  STA n
  LDA quot+1
  STA n+1
  JMP p16l
p16p:
  CPX #0
  JZ p16d
  DEX
  LDA pbuf,X
  CALL SVC_PUTC
  JMP p16p
p16d:
  RET

fail:                      ; B = error code; the first one wins
  LDA abrt
  JNZ fr
  STB errc
  LDA #1
  STA abrt
fr:
  RET

failnow:
  LDA #'E'
  CALL SVC_PUTC
  LDA lineno
  STA n
  LDA lineno+1
  STA n+1
  CALL print16
  LDA #' '
  CALL SVC_PUTC
  LDA #(errs%256)          ; walk to the reason string
  STA q
  LDA #(errs/256)
  STA q+1
  LDA errc
  STA sct
ew1:
  LDA sct
  JZ ew2
ewsk:
  LDA (q)
  JZ ewsk1
  CALL inc_q
  JMP ewsk
ewsk1:
  CALL inc_q
  LDA sct
  DEA
  STA sct
  JMP ew1
ew2:
  LDA q+1
  TAB
  LDA q
  TAX
  CALL SVC_PUTS
  LDA #10
  CALL SVC_PUTC
  MEX_END

usage:
  LDA #(usage_s/256)
  TAB
  LDA #(usage_s%256)
  TAX
  CALL SVC_PUTS
  MEX_END

; ========================================================================
; assembled: build the MEX header, rename FILE to FILE.mx, write it out
; ========================================================================
assembled:
  LDA imgp                 ; nothing was ever emitted
  CMP img0
  JNZ asok1
  LDA imgp+1
  CMP img0+1
  JNZ asok1
  LDB #E_EMPTY
  CALL fail
  JMP failnow
asok1:
  LDA #'M'
  STA HDR
  LDA #'X'
  STA HDR+1
  LDA #1
  STA HDR+2
  LDA #0                   ; load address: always 0x2000 for MEX
  STA HDR+3
  STA HDR+4
  LDA #0x20
  STA HDR+5
  LDA #16                  ; entry: 0x2010
  STA HDR+6
  LDA #0
  STA HDR+7
  ; body length = imgp - VARB (little-endian into HDR+8)
  LDA imgp
  SUB #(VARB%256)
  STA HDR+8
  JC asb1
  LDA imgp+1
  SUB #(VARB/256)
  STA HDR+9
  DEA
  STA HDR+9
  JMP asck
asb1:
  LDA imgp+1
  SUB #(VARB/256)
  STA HDR+9
asck:
  LDA #0                   ; checksum = sum of the first ten bytes
  STA ci
  LDX #0
ckl:
  LDA HDR,X
  ADD ci
  STA ci
  INX
  CPX #10
  JNZ ckl
  LDA ci
  STA HDR+10
  LDA #0
  STA HDR+11

  ; FILE -> FILE.mx, in place (the source is long since read)
  LDX #0
dtl:
  LDA namebuf,X
  JZ dtnone
  CMP #'.'
  JZ dtyes
  INX
  JMP dtl
dtyes:
  INX
  LDA #'m'
  STA namebuf,X
  INX
  LDA #'x'
  STA namebuf,X
  INX
  LDA #0
  STA namebuf,X
  JMP dtc
dtnone:
  LDA #'.'
  STA namebuf,X
  INX
  LDA #'m'
  STA namebuf,X
  INX
  LDA #'x'
  STA namebuf,X
  INX
  LDA #0
  STA namebuf,X
dtc:
  LDA #(namebuf%256)
  STA FS_NAME
  LDA #(namebuf/256)
  STA FS_NAME+1
  CALL SVC_FS_DELETE       ; replacing an older build is fine
  LDA #(HDR%256)
  STA FS_DATA
  LDA #(HDR/256)
  STA FS_DATA+1
  LDA imgp                 ; file length = imgp - HDR (HDR's low byte is 0,
  STA FS_LEN                ; so only the high half needs adjusting)
  LDA imgp+1
  SUB #(HDR/256)
  STA FS_LEN+1
  CALL SVC_FS_CREATE
  CMP #0
  JZ wrok
  LDB #E_NOSPC
  CALL fail
  JMP failnow
wrok:
  LDA #(ok_s/256)
  TAB
  LDA #(ok_s%256)
  TAX
  CALL SVC_PUTS
  LDA FS_LEN               ; print the size we wrote
  STA n
  LDA FS_LEN+1
  STA n+1
  CALL print16
  LDA #10
  CALL SVC_PUTC
  MEX_END

; ========================================================================
; data
; ========================================================================
p:        db 0,0            ; primary cursor (statement, eval, read)
q:        db 0,0            ; secondary scan cursor
ls:       db 0,0            ; line start
le:       db 0,0            ; line end (a NUL)
ce:       db 0,0            ; split boundary
tq:       db 0,0            ; temp pointer
pc:       db 0,0            ; virtual address while assembling
orgv:     db 0,0            ; first org decides where pass 2 starts
tgt:      db 0,0
gap:      db 0,0
imgp:     db 0,0            ; next image byte
img0:     db 0,0            ; image start, for the empty-image check
bnd:      db 0,0            ; planted boundary for an operand (0 = none)
cma:      db 0,0            ; last comma seen
last:     db 0,0            ; last non-blank char position
moff:     db 0,0            ; opcode record offset
ev_v:     db 0,0            ; expression result
ev_l:     db 0,0            ; saved left-hand side
acc:      db 0,0            ; number accumulator
dva:      db 0,0
dvb:      db 0,0
quot:     db 0,0
dvr:      db 0,0
mc:       db 0,0            ; multiplier being shifted
sq:       db 0,0            ; symbol entry cursor
sq0:      db 0,0
syv:      db 0,0            ; symbol value found
tlen:     db 0,0            ; trimmed item length
cnt:      db 0,0            ; raw item length
sl:       db 0              ; source bytes left while reading (16-bit:
sh:       db 0              ; sl is the low half, sh the high half)
pend:     db 0,0            ; one past the final source NUL
lineno:   db 0,0
n:        db 0,0            ; value for print16
ev_op:    db 0
kind:     db 0
opcode:   db 0
bmul:     db 0
dgt:      db 0
dcnt:     db 0
sct:      db 0
pass:     db 0
abrt:     db 0
errc:     db 0
mode:     db 0             ; 1 = dropping a comment
firstset: db 0
inq:      db 0
depth:    db 0
lastc:    db 0
cec:      db 0
ci:       db 0
tb:       db 0
tok:      db 0,0,0,0,0,0,0,0,0
stok:     db 0,0,0,0,0,0,0,0,0
namebuf:  db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
pbuf:     db 0,0,0,0,0,0,0
usage_s:  db "USAGE: ASM FILE",10,0
ok_s:     db "OK ",0

mn_names:
  db "NOP",0,"LDA",0,"STA",0,"LDB",0,"STB",0,"LDX",0,"STX",0
  db "TXA",0,"TAX",0,"TBA",0,"TAB",0,"ADD",0,"ADB",0,"ADX",0
  db "SUB",0,"SBB",0,"SBX",0,"AND",0,"OR",0,"XOR",0,"SHL",0
  db "SHR",0,"INA",0,"DEA",0,"INX",0,"DEX",0,"CMP",0,"CPB",0
  db "CPX",0,"ADC",0,"JMP",0,"JZ",0,"JNZ",0,"JC",0,"JN",0
  db "JNC",0,"CALL",0,"RET",0,"PUSHA",0,"POPA",0,"PUSHX",0
  db "POPX",0,"IN",0,"OUT",0,"HLT",0,0

mn_ops:                    ; imp, imm, abs, ind, ix, ib (0xFF = no form)
  db 0x00,0xFF,0xFF,0xFF,0xFF,0xFF   ; NOP
  db 0xFF,0x01,0x02,0x54,0x50,0x52   ; LDA
  db 0xFF,0xFF,0x03,0x55,0x51,0x53   ; STA
  db 0xFF,0x04,0x05,0xFF,0xFF,0xFF   ; LDB
  db 0xFF,0xFF,0x06,0xFF,0xFF,0xFF   ; STB
  db 0xFF,0x07,0x08,0xFF,0xFF,0xFF   ; LDX
  db 0xFF,0xFF,0x09,0xFF,0xFF,0xFF   ; STX
  db 0x0A,0xFF,0xFF,0xFF,0xFF,0xFF   ; TXA
  db 0x0B,0xFF,0xFF,0xFF,0xFF,0xFF   ; TAX
  db 0x0C,0xFF,0xFF,0xFF,0xFF,0xFF   ; TBA
  db 0x0D,0xFF,0xFF,0xFF,0xFF,0xFF   ; TAB
  db 0xFF,0x10,0x11,0xFF,0xFF,0xFF   ; ADD
  db 0x12,0xFF,0xFF,0xFF,0xFF,0xFF   ; ADB
  db 0x13,0xFF,0xFF,0xFF,0xFF,0xFF   ; ADX
  db 0xFF,0x14,0x15,0xFF,0xFF,0xFF   ; SUB
  db 0x16,0xFF,0xFF,0xFF,0xFF,0xFF   ; SBB
  db 0x17,0xFF,0xFF,0xFF,0xFF,0xFF   ; SBX
  db 0xFF,0x18,0x19,0xFF,0xFF,0xFF   ; AND
  db 0xFF,0x1A,0x1B,0xFF,0xFF,0xFF   ; OR
  db 0xFF,0x1C,0x1D,0xFF,0xFF,0xFF   ; XOR
  db 0x1E,0xFF,0xFF,0xFF,0xFF,0xFF   ; SHL
  db 0x1F,0xFF,0xFF,0xFF,0xFF,0xFF   ; SHR
  db 0x20,0xFF,0xFF,0xFF,0xFF,0xFF   ; INA
  db 0x21,0xFF,0xFF,0xFF,0xFF,0xFF   ; DEA
  db 0x22,0xFF,0xFF,0xFF,0xFF,0xFF   ; INX
  db 0x23,0xFF,0xFF,0xFF,0xFF,0xFF   ; DEX
  db 0xFF,0x24,0x25,0xFF,0xFF,0xFF   ; CMP
  db 0x26,0xFF,0xFF,0xFF,0xFF,0xFF   ; CPB
  db 0xFF,0x27,0xFF,0xFF,0xFF,0xFF   ; CPX
  db 0x28,0xFF,0xFF,0xFF,0xFF,0xFF   ; ADC
  db 0xFF,0xFF,0x30,0xFF,0xFF,0xFF   ; JMP
  db 0xFF,0xFF,0x31,0xFF,0xFF,0xFF   ; JZ
  db 0xFF,0xFF,0x32,0xFF,0xFF,0xFF   ; JNZ
  db 0xFF,0xFF,0x33,0xFF,0xFF,0xFF   ; JC
  db 0xFF,0xFF,0x34,0xFF,0xFF,0xFF   ; JN
  db 0xFF,0xFF,0x35,0xFF,0xFF,0xFF   ; JNC
  db 0xFF,0xFF,0x40,0xFF,0xFF,0xFF   ; CALL
  db 0x41,0xFF,0xFF,0xFF,0xFF,0xFF   ; RET
  db 0x42,0xFF,0xFF,0xFF,0xFF,0xFF   ; PUSHA
  db 0x43,0xFF,0xFF,0xFF,0xFF,0xFF   ; POPA
  db 0x44,0xFF,0xFF,0xFF,0xFF,0xFF   ; PUSHX
  db 0x45,0xFF,0xFF,0xFF,0xFF,0xFF   ; POPX
  db 0xFF,0x60,0xFF,0xFF,0xFF,0xFF   ; IN
  db 0xFF,0x61,0xFF,0xFF,0xFF,0xFF   ; OUT
  db 0x70,0xFF,0xFF,0xFF,0xFF,0xFF   ; HLT

errs:
  db 0
  db "NOFILE",0            ; 1  the named source does not exist
  db "BIG",0               ; 2  source longer than 1535 bytes
  db "BADMN",0             ; 3  unknown mnemonic
  db "OPND",0              ; 4  that operand form does not exist
  db "UNDEF",0             ; 5  undefined symbol
  db "DUP",0               ; 6  symbol already defined
  db "ORG",0               ; 7  org outside 0x2010..0x25F4, or backwards
  db "JUNK",0              ; 8  trailing junk / malformed line
  db "TOOBIG",0            ; 9  image ran into the stack
  db "NOSPACE",0           ; 10 create failed: no room on disk
  db "FULL",0              ; 11 more than 25 symbols
  db "LONG",0              ; 12 a symbol name longer than 8 characters
  db "DIV0",0              ; 13 division or modulo by zero
  db "EMPTY",0             ; 14 nothing assembled
  db "RANGE",0             ; 15 immediate outside -128..255
