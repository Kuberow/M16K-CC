; m16k/sdk/asm/fs.inc -- M16K SDK: "MUFS" flat filesystem library for kernels.
;
; %include this ONCE, after std.inc (uses std_* helpers and pa/pb).
;
; Disk layout (32 KB disk, 4 KB pages selected with OUT #0x40, 256-byte
; blocks, 128 blocks; blocks live at window 0xE800 + (block%16)*256):
;   0x00      "MUFS" magic
;   0x10      directory: 32 entries x 32 bytes
;             name[16] NUL-padded, start block, length lo, length hi, pad
;   0x410     allocation bitmap: 16 bytes, bit = block used (blocks 0-4 are
;             always set: they hold the header/directory/bitmap)
;   block 5+  file data, contiguous per file
;
; Entry points:
;   fs_mount    -> A = 1 if "MUFS" present, else 0
;   fs_format   -> blank filesystem (dirs zeroed, blocks 0-4 marked used)
;   fs_install  -> first-boot: format if needed + create the sample files
;   fs_find     np=name ptr -> A = entry index 0-31 or 0xFF
;   fs_open     np -> A = 0 ok (reader primed: fr_blk/fr_len), 1 not found
;   fs_getc     -> A = next byte (call while fr_len > 0)
;   fs_read     fd = dest ptr -> copy remaining fr_len bytes there
;   fs_create   np, wc_src=data ptr, wc_len(2) -> A = 0 ok, 1 no space
;   fs_delete   np -> A = 0 ok, 1 not found
;
; Variables: fp(2) entry cursor, np(2) name ptr, fr_blk, fr_len(2), rp(2)
; window reader, fs_pg, fs_idx, fs_cnt, fs_b, fb_*, ws_*, ent(2), wc_src(2),
; wc_len(2), fd(2).

; ---- select the 4KB disk window page for a block (A = block) ---------
fs_setblk:
  STA fs_b
  SHR
  SHR
  SHR
  SHR                ; A = block >> 4 = page (the 4 low bits are in fs_b)
  STA fs_pg          ; remember it: fs_getc needs it to follow the window
  OUT #0x40
  LDA fs_b
  AND #15
  ADD #0xE8          ; window hi byte = 0xE8 + (block & 15)
  STA rp_hi
  LDA #0
  STA rp_lo
  RET

; ---- does the disk have a formatted MUFS? (A = 1 yes / 0 no) ---------
fs_mount:
  LDA #0
  OUT #0x40
  LDA 0xE800
  CMP #'M'
  JNZ fm_no
  LDA 0xE801
  CMP #'U'
  JNZ fm_no
  LDA 0xE802
  CMP #'F'
  JNZ fm_no
  LDA 0xE803
  CMP #'S'
  JNZ fm_no
  LDA #1
  RET
fm_no:
  LDA #0
  RET

; ---- blank filesystem -------------------------------------------------
fs_format:
  LDA #0
  OUT #0x40
  LDA #0
  STA fp_lo
  LDA #0xE8
  STA fp_hi
  LDX #5             ; zero the first 5 pages (header, dir, bitmap)
fz_p:
fz_l:
  LDA #0             ; must be inside the loop: fp_lo/INA below clobbers A
  STA (fp)
  LDA fp_lo
  INA
  STA fp_lo
  JNZ fz_l
  LDA fp_hi
  INA
  STA fp_hi
  DEX
  JNZ fz_p
  LDA #'M'
  STA 0xE800
  LDA #'U'
  STA 0xE801
  LDA #'F'
  STA 0xE802
  LDA #'S'
  STA 0xE803
  LDA #0x1F          ; blocks 0-4 used
  STA 0xEC10
  RET

; ---- bitmap helpers ---------------------------------------------------
; A = block -> X = bitmap byte index, fb_m = bit mask
fs_bitpos:
  STA fb_b
  SHR
  SHR
  SHR                ; A = block >> 3
  TAX
  LDA fb_b
  AND #7
  STA fb_k
  LDA #1
  STA fb_m
bp_l:
  LDA fb_k
  JZ bp_done
  LDA fb_m
  SHL
  STA fb_m
  LDA fb_k
  DEA
  STA fb_k
  JMP bp_l
bp_done:
  RET

fs_testbit:          ; A = block -> A = 1 used / 0 free
  CALL fs_bitpos
  LDA 0xEC10,X
  AND fb_m
  JZ tb_free
  LDA #1
  RET
tb_free:
  LDA #0
  RET

fs_setbit:           ; A = block -> mark used
  CALL fs_bitpos
  LDA 0xEC10,X
  OR fb_m
  STA 0xEC10,X
  RET

fs_clrbit:           ; A = block -> mark free
  CALL fs_bitpos
  LDA fb_m
  XOR #0xFF
  STA fb_t
  LDA 0xEC10,X
  AND fb_t
  STA 0xEC10,X
  RET

; ---- increment fp -----------------------------------------------------
fs_incfp:
  LDA fp_lo
  INA
  STA fp_lo
  JNZ if_1
  LDA fp_hi
  INA
  STA fp_hi
if_1:
  RET

; ---- find: np = NUL-name -> A = entry index 0-31 or 0xFF --------------
fs_find:
  LDA #0
  OUT #0x40
  LDA #0x10
  STA fp_lo
  LDA #0xE8
  STA fp_hi
  LDA #0
  STA fs_idx
ff_l:
  LDA fp_lo
  STA pa
  LDA fp_hi
  STA pa+1
  LDA np
  STA pb
  LDA np+1
  STA pb+1
  CALL std_streq
  JNZ ff_hit
  LDA fp_lo
  ADD #32
  STA fp_lo
  JNC ff_nc
  LDA fp_hi
  INA
  STA fp_hi
ff_nc:
  LDA fs_idx
  INA
  STA fs_idx
  CMP #32
  JNZ ff_l
  LDA #0xFF
  RET
ff_hit:
  LDA fs_idx
  RET

; ---- entry index in A -> fp = 0xE810 + index * 32 ---------------------
fs_ent:
  STA fs_cnt
  LDA #0x10
  STA fp_lo
  LDA #0xE8
  STA fp_hi
  LDA fs_cnt
  JZ fe_done
fe_l:
  LDA fp_lo
  ADD #32
  STA fp_lo
  JNC fe_nc
  LDA fp_hi
  INA
  STA fp_hi
fe_nc:
  LDA fs_cnt
  DEA
  STA fs_cnt
  JNZ fe_l
fe_done:
  RET

; ---- block count from wc_len -> ws_nb (min 1) -------------------------
fs_nb:
  LDA wc_len
  JZ nb_h
  LDA wc_len+1
  INA
  STA ws_nb
  JMP nb_z
nb_h:
  LDA wc_len+1
  STA ws_nb
nb_z:
  LDA ws_nb
  JNZ nb_ok
  LDA #1
  STA ws_nb
nb_ok:
  RET

; ---- open a file: np -> A = 0 ok (fr_blk/fr_len primed) / 1 missing ----
fs_open:
  CALL fs_find
  CMP #0xFF
  JZ fo_no
  CALL fs_ent
  LDA fp_lo
  ADD #16
  STA fp_lo
  JNC fo_1
  LDA fp_hi
  INA
  STA fp_hi
fo_1:
  LDA (fp)
  STA fr_blk
  CALL fs_incfp
  LDA (fp)
  STA fr_len
  CALL fs_incfp
  LDA (fp)
  STA fr_len+1
  LDA fr_blk
  CALL fs_setblk
  LDA #0
  RET
fo_no:
  LDA #1
  RET

; ---- read next file byte (fr_len must be > 0) -------------------------
fs_getc:
  LDA (rp)
  STA fs_b
  LDA rp_lo
  INA
  STA rp_lo
  JNZ fg_1
  LDA rp_hi
  INA
  STA rp_hi
  CMP #0xF8          ; crossed the 4KB window -> next disk page
  JNZ fg_1
  LDA #0xE8
  STA rp_hi
  LDA fs_pg
  INA
  STA fs_pg
  OUT #0x40
fg_1:
  LDA fr_len
  JNZ fg_d
  LDA fr_len+1
  DEA
  STA fr_len+1
fg_d:
  LDA fr_len
  DEA
  STA fr_len
  LDA fs_b
  RET

; ---- copy remaining fr_len bytes to fd --------------------------------
fs_read:
  LDA fd_lo
  STA pb
  LDA fd_hi
  STA pb+1
fr_l:
  LDA fr_len+1
  JNZ fr_go
  LDA fr_len
  JZ fr_done
fr_go:
  CALL fs_getc
  STA (pb)
  CALL std_incpb
  JMP fr_l
fr_done:
  RET

; ---- create: np + wc_src + wc_len -> A = 0 ok / 1 no space ------------
fs_create:
  LDA #0
  OUT #0x40
  CALL fs_nb
  ; scan for ws_nb contiguous free blocks starting at 5
  LDA #5
  STA ws_b
ca_s:
  LDA ws_b
  ADD ws_nb
  CMP #129           ; run must end at block <= 127
  JC ca_fail
  LDA ws_b
  STA ws_i
ca_c:
  LDA ws_i
  CALL fs_testbit
  JNZ ca_next
  LDA ws_i
  INA
  STA ws_i
  SUB ws_b
  CMP ws_nb
  JZ ca_found
  JMP ca_c
ca_next:
  LDA ws_b
  INA
  STA ws_b
  JMP ca_s
ca_fail:
  LDA #1
  RET
ca_found:
  LDA ws_b
  STA ws_start
  ; find a free directory slot (fp walks the dir)
  LDA #0
  OUT #0x40
  LDA #0x10
  STA fp_lo
  LDA #0xE8
  STA fp_hi
  LDA #0
  STA fs_idx
cf_sl:
  LDA (fp)
  JZ cf_got
  LDA fp_lo
  ADD #32
  STA fp_lo
  JNC cf_snc
  LDA fp_hi
  INA
  STA fp_hi
cf_snc:
  LDA fs_idx
  INA
  STA fs_idx
  CMP #32
  JNZ cf_sl
  LDA #1             ; directory full
  RET
cf_got:
  LDA fp_lo
  STA ent
  LDA fp_hi
  STA ent+1
  ; zero the 32-byte entry
  LDA #32
  STA fs_cnt
cf_z:
  LDA #0
  STA (fp)
  CALL fs_incfp
  LDA fs_cnt
  DEA
  STA fs_cnt
  JNZ cf_z
  ; copy the name (max 16 bytes) from np
  LDA np
  STA pa
  LDA np+1
  STA pa+1
  LDA ent
  STA fp_lo
  LDA ent+1
  STA fp_hi
  LDA #0
  STA fs_cnt
cf_nc:
  LDA fs_cnt
  CMP #16
  JZ cf_nd
  LDA (pa)
  JZ cf_nd
  STA (fp)
  CALL std_incpa
  CALL fs_incfp
  LDA fs_cnt
  INA
  STA fs_cnt
  JMP cf_nc
cf_nd:
  ; entry[16] = start block, [17] = len lo, [18] = len hi
  LDA ent
  ADD #16                 ; C = carry out of the low byte
  STA fp_lo               ; STA/LDA preserve C
  LDA ent+1
  ADC                     ; A = ent.hi + C
  STA fp_hi
  LDA ws_start
  STA (fp)
  CALL fs_incfp
  LDA wc_len
  STA (fp)
  CALL fs_incfp
  LDA wc_len+1
  STA (fp)
  ; mark the blocks used
  LDA ws_start
  STA ws_i
cb_l:
  LDA ws_i
  CALL fs_setbit
  LDA ws_i
  INA
  STA ws_i
  SUB ws_start
  CMP ws_nb
  JZ cb_done
  JMP cb_l
cb_done:
  ; stream the data into the window (rp reused as destination)
  LDA ws_start
  CALL fs_setblk
  LDA wc_src
  STA pa
  LDA wc_src+1
  STA pa+1
  LDA wc_len
  STA mc_n
  LDA wc_len+1
  STA mc_n+1
cp_l:
  LDA mc_n+1
  JNZ cp_go
  LDA mc_n
  JZ cp_done
cp_go:
  LDA (pa)
  STA (rp)
  CALL std_incpa
  LDA rp_lo
  INA
  STA rp_lo
  JNZ cp_nc
  LDA rp_hi
  INA
  STA rp_hi
  CMP #0xF8
  JNZ cp_nc
  LDA #0xE8
  STA rp_hi
  LDA fs_pg
  INA
  STA fs_pg
  OUT #0x40
cp_nc:
  LDA mc_n
  JNZ cp_d
  LDA mc_n+1
  DEA
  STA mc_n+1
cp_d:
  LDA mc_n
  DEA
  STA mc_n
  JMP cp_l
cp_done:
  LDA #0
  RET

; ---- delete: np -> A = 0 ok / 1 missing --------------------------------
fs_delete:
  CALL fs_find
  CMP #0xFF
  JZ dl_no
  CALL fs_ent
  LDA fp_lo
  STA ent
  LDA fp_hi
  STA ent+1
  LDA fp_lo
  ADD #16
  STA fp_lo
  JNC dl_1
  LDA fp_hi
  INA
  STA fp_hi
dl_1:
  LDA (fp)
  STA ws_start
  CALL fs_incfp
  LDA (fp)
  STA wc_len
  CALL fs_incfp
  LDA (fp)
  STA wc_len+1
  CALL fs_nb
  ; free the blocks
  LDA ws_start
  STA ws_i
dl_b:
  LDA ws_i
  CALL fs_clrbit
  LDA ws_i
  INA
  STA ws_i
  SUB ws_start
  CMP ws_nb
  JZ dl_z
  JMP dl_b
dl_z:
  ; zero the entry
  LDA ent
  STA fp_lo
  LDA ent+1
  STA fp_hi
  LDA #32
  STA fs_cnt
dl_zl:
  LDA #0
  STA (fp)
  CALL fs_incfp
  LDA fs_cnt
  DEA
  STA fs_cnt
  JNZ dl_zl
  LDA #0
  RET
dl_no:
  LDA #1
  RET

; ---- first boot: format if needed, install the sample files ------------
fs_install:
  CALL fs_mount
  JZ fi_go
  RET                ; already formatted
fi_go:
  CALL fs_format
  ; readme.txt
  LDA #(m_readme % 256)
  STA np
  LDA #(m_readme / 256)
  STA np+1
  LDA #(m_readme_src % 256)
  STA wc_src
  LDA #(m_readme_src / 256)
  STA wc_src+1
  LDA #((m_readme_end - m_readme_src) % 256)
  STA wc_len
  LDA #((m_readme_end - m_readme_src) / 256)
  STA wc_len+1
  CALL fs_create
  ; hello.mx (binary embedded from m16k/build/hello.mx)
  LDA #(m_hello % 256)
  STA np
  LDA #(m_hello / 256)
  STA np+1
  LDA #(m_hello_bin % 256)
  STA wc_src
  LDA #(m_hello_bin / 256)
  STA wc_src+1
  LDA #((m_hello_end - m_hello_bin) % 256)
  STA wc_len
  LDA #((m_hello_end - m_hello_bin) / 256)
  STA wc_len+1
  CALL fs_create
  RET

; ---- syscall gate glue (svc.inc's SYSCALL_GATES JMPs straight here) -----
; The gate is a JMP, so the RET below pops the *application's* return
; address: these read the low-RAM parameter block (svc.inc) and tail-call
; the real routine. The kernel is idle while an app runs, so it is safe for
; an app to hand us pointers into its own memory.
fg_open:
  LDA FS_NAME
  STA np
  LDA FS_NAME+1
  STA np+1
  JMP fs_open
fg_tell:
  LDA fr_len            ; A = bytes left, low
  LDX fr_len+1          ; X = bytes left, high (LDX leaves A alone)
  RET
fg_getc:
  JMP fs_getc
fg_create:
  LDA FS_NAME
  STA np
  LDA FS_NAME+1
  STA np+1
  LDA FS_DATA
  STA wc_src
  LDA FS_DATA+1
  STA wc_src+1
  LDA FS_LEN
  STA wc_len
  LDA FS_LEN+1
  STA wc_len+1
  JMP fs_create
fg_delete:
  LDA FS_NAME
  STA np
  LDA FS_NAME+1
  STA np+1
  JMP fs_delete

; ---- fs data ----------------------------------------------------------
fp:        db 0, 0
np:        db 0, 0
fr_blk:    db 0
fr_len:    db 0, 0
rp:        db 0, 0
fs_pg:     db 0
fs_idx:    db 0
fs_cnt:    db 0
fs_b:      db 0
fb_b:      db 0
fb_k:      db 0
fb_m:      db 0
fb_by:     db 0
fb_t:      db 0
ws_b:      db 0
ws_i:      db 0
ws_nb:     db 0
ws_start:  db 0
ent:       db 0, 0
wc_src:    db 0, 0
wc_len:    db 0, 0
fd:        db 0, 0

; lo/hi aliases for the 16-bit pointers (the code addresses them by byte)
fp_lo = fp
fp_hi = fp + 1
rp_lo = rp
rp_hi = rp + 1
fd_lo = fd
fd_hi = fd + 1
