; ===========================================================================
; kernel.s — ASH's resident half, from $0700 (copied down at startup).
;
;   * SIO helpers and per-drive density
;   * the file stream (DOS 2 / MyDOS sector chain or an H: file) and the
;     XEX executor that runs launched programs
;   * FMS: a compact DOS 2-format file manager behind a CIO "D:" handler,
;     so the shell, BASIC and launched programs all get a read/write D:
;
; Everything here stays below DOS 2.5's own MEMLO ($1CFC): a program that
; loads under DOS loads under ASH. Zero page: only DOS's FMS bytes $43-$49.
;
; Disk format written: DOS 2.0 (VTOC at 360, directory 361-368, 64 entries,
; file-numbered sector links), single or double density, 720 sectors, plus
; MyDOS subdirectories (an 8-sector directory, entry flag $10). Disks whose
; VTOC isn't the plain DOS 2 kind (big MyDOS, SpartaDOS) are read-only.
; ===========================================================================
        .segment "KERNEL"

fz_p    = $43                   ; general pointer
fz_n    = $45                   ; name pointer
fz_b    = $47                   ; current handle's buffer
ICDNOZ  = $21                   ; CIO's zero-page IOCB copy
ICCOMZ  = $22
ICBALZ  = $24
ICAX1Z  = $2A
ICIDNO  = $2E                   ; IOCB number * 16
HATABS  = $031A
NH      = 3                     ; D: files open at once

ST_OK   = 1
ST_NOTOPEN = 133
ST_RONLY = 135                  ; write to a read-only file
ST_WONLY = 131                  ; read from a write-only file
ST_EOF  = 136
ST_NOTIMP = 146
ST_DRIVE = 160
ST_MANY = 161
ST_FULL = 162
ST_NAME = 165
ST_LOCKED = 167
ST_DIRFULL = 169
ST_NOTFOUND = 170
ST_FORMAT = 175                 ; not a DOS 2 disk: read-only

; ---- SIO -------------------------------------------------------------------
; read A bytes (0 = 256) into sbuf; DDEVIC/DUNIT/DCOMND/DAUX already set.
; -> Y = status, N = 1 on error
k_sio:  sta DBYTLO
        cmp #1
        lda #0
        rol
        eor #1
        sta DBYTHI
        lda #<sbuf
        sta DBUFLO
        lda #>sbuf
        sta DBUFHI
        lda #$40
        sta DSTATS
k_go:   lda #7
        sta DTIMLO
        jsr SIOV
        sty k_err
        tya
        rts

; sector s_sec of drive s_drv <-> buffer s_buf; s_cmd = $52 read / $57 write
s_io:   lda #$31
        sta DDEVIC
        ldx s_drv
        stx DUNIT
        lda s_cmd
        sta DCOMND
        ldy #$40
        cmp #$52
        beq :+
        ldy #$80
:       sty DSTATS
        lda s_sec
        sta DAUX1
        lda s_sec+1
        sta DAUX2
        lda s_buf
        sta DBUFLO
        lda s_buf+1
        sta DBUFHI
        lda ss_tab,x
        ldy s_sec+1
        bne :+
        ldy s_sec
        cpy #4
        bcs :+
        lda #$80                ; boot sectors are always 128 bytes
:       sta DBYTLO
        cmp #1
        lda #0
        rol
        eor #1
        sta DBYTHI
        jmp k_go

; drive X: status -> ss_tab[X] ($80 = 128-byte sectors, $00 = 256). C=1 error
k_dstat:
        stx DUNIT
        lda #$31
        sta DDEVIC
        lda #$53
        sta DCOMND
        lda #0
        sta DAUX1
        sta DAUX2
        lda #4
        jsr k_sio
        bmi @e
        ldx DUNIT
        lda sbuf
        and #$20
        beq :+
        lda #$00
        .byte $2C
:       lda #$80
        sta ss_tab,x
        clc
        rts
@e:     sec
        rts

; drive X, sector A/Y -> dbuf. C=1 error (status in k_err)
k_rdsec:
        sta s_sec
        sty s_sec+1
        stx s_drv
        lda #0
        sta dbuf_ok             ; dbuf no longer holds a cached dir sector
        lda #<dbuf
        ldy #>dbuf
rd_any: ldx #$52                 ; buffer A/Y <- sector s_sec of s_drv
        .byte $2C
wr_any: ldx #$57                 ; buffer A/Y -> sector
        sta s_buf
        sty s_buf+1
        stx s_cmd
        jsr s_io                ; Y = status
        bmi :+
        clc
        rts
:       sec
        rts

; ---- the stream ---------------------------------------------------------------
; k_dev = 1-4: sector chain from k_next (k_l16 bit 7 = 16-bit links);
; k_dev = 0: H: file open on HHANDLE.
k_getbyte:                      ; -> C=0 A=byte; C=1 end (k_err bit 7 = error)
        stx k_sx
        sty k_sy
@again: ldx k_pos
        cpx k_len
        bcc @have
        jsr k_refill
        bcc @again
        bcs @out
@have:  lda sbuf,x
        inx
        stx k_pos
        clc
@out:   ldx k_sx
        ldy k_sy
        rts

k_refill:
        lda #0
        sta k_pos
        sta k_len
        lda k_dev
        beq @h
        lda k_next
        ora k_next+1
        beq @end
        lda k_dev
        sta s_drv
        lda k_next
        ldy k_next+1
        sta s_sec
        sty s_sec+1
        lda #<sbuf
        ldy #>sbuf
        jsr rd_any
        bcs @end
        ldx k_dev
        lda ss_tab,x
        tax
        dex
        lda sbuf,x              ; byte count
        sta k_len
        dex
        lda sbuf,x              ; next sector lo
        sta k_next
        dex
        lda sbuf,x              ; file number<<2 | next hi (DOS 2)
        bit k_l16
        bmi :+
        and #$03
:       sta k_next+1
        clc
        rts
@h:     lda #$53                ; H: how much is left?
        jsr k_hcmd
        lda #4
        jsr k_sio
        bmi @end
        lda sbuf+3
        bne @n128
        lda sbuf+2
        beq @end
        bpl @n
@n128:  lda #128
@n:     sta DAUX1
        sta k_len
        lda #$52
        jsr k_hcmd
        lda k_len
        jsr k_sio
        bmi @bad
        clc
        rts
@bad:   lda #0
        sta k_len
@end:   sec
        rts

k_hcmd: sta DCOMND              ; H: (SIO $72) command A on our handle
        lda #$72
        sta DDEVIC
        lda #1
        sta DUNIT
        lda #HHANDLE
        sta DAUX2
        rts

; ---- XEX executor ---------------------------------------------------------------
k_exec: ldx #$FF
        txs
        lda #0
        sta RUNAD
        sta RUNAD+1
        sta k_def+1
kx_seg: jsr k_getbyte
        bcs kx_eof
        sta kx_st+1
        jsr k_getbyte
        bcs k_bad
        sta kx_st+2
        and kx_st+1
        cmp #$FF
        beq kx_seg              ; $FFFF marker
        lda k_def+1
        bne :+
        lda kx_st+1             ; default entry: first segment
        sta k_def
        lda kx_st+2
        sta k_def+1
:       jsr k_getbyte
        bcs k_bad
        sta k_end
        jsr k_getbyte
        bcs k_bad
        sta k_end+1
        lda #<k_rts
        sta INITAD
        lda #>k_rts
        sta INITAD+1
kx_cp:  jsr k_getbyte
        bcs k_bad
kx_st:  sta $FFFF
        lda kx_st+1
        cmp k_end
        bne kx_inc
        lda kx_st+2
        cmp k_end+1
        beq kx_sd
kx_inc: inc kx_st+1
        bne kx_cp
        inc kx_st+2
        jmp kx_cp
k_bad:  jmp COLDSV
kx_sd:  lda INITAD
        cmp #<k_rts
        bne :+
        lda INITAD+1
        cmp #>k_rts
        beq kx_seg
:       jsr kx_init
        jmp kx_seg
kx_init:
        jmp (INITAD)
kx_eof: lda k_err
        bmi k_bad
        lda RUNAD+1
        bne :+
        lda k_def
        sta RUNAD
        lda k_def+1
        sta RUNAD+1
:       jmp (RUNAD)

; ===========================================================================
; FMS
; ===========================================================================
; CIO handler table
d_tab:  .word d_open-1, d_close-1, d_get-1, d_put-1, d_stat-1, d_spec-1
        jmp k_rts

; Put D: in HATABS, close every file, set MEMLO. This is DOSINI: RESET
; keeps D: alive in BASIC and in launched programs.
fms_init:
        ldx #0
@l:     lda HATABS,x
        beq @put
        cmp #'D'
        beq @put
        inx
        inx
        inx
        cpx #36
        bcc @l
        bcs @mem
@put:   lda #'D'
        sta HATABS,x
        lda #<d_tab
        sta HATABS+1,x
        lda #>d_tab
        sta HATABS+2,x
@mem:   lda k_memlo
        sta MEMLO
        lda k_memlo+1
        sta MEMLO+1
        lda #$FF
        ldx #7
:       sta iomap,x
        dex
        bpl :-
        lda #0
        ldx #NH-1
:       sta h_mode,x
        dex
        bpl :-
        sta dbuf_ok
k_rts:  rts

; ---- CIO entry points (X = IOCB*16, name/aux in ZIOCB) ---------------------
d_open: jsr op_begin
        bcs d_ret
        ldx #NH-1               ; a free handle
:       lda h_mode,x
        beq o_got
        dex
        bpl :-
        ldy #ST_MANY
d_ret:  rts
o_got:  stx hh
        jsr h_buf
        lda f_drv
        sta h_drv,x
        lda ICAX1Z
        and #$0F
        cmp #4
        beq o_read
        cmp #6
        beq o_dir
        cmp #8
        bne :+
        jmp o_write
:       cmp #9
        bne :+
        jmp o_app
:       ldy #ST_NOTIMP
        rts

o_dir:  lda f_dir               ; directory listing: remember pattern & place
        sta h_dl,x
        lda f_dir+1
        sta h_dh,x
        lda #0
        sta h_pos,x
        sta h_cnt,x
        sta h_ix,x
        txa                     ; pattern -> h_pat[hh*11]
        asl
        sta f_t
        asl
        asl
        clc
        adc f_t
        adc hh                  ; *11
        tay
        ldx #0
:       lda f_pat,x
        sta h_pat,y
        iny
        inx
        cpx #11
        bne :-
        lda #6
        jmp o_done

o_read: lda #0
        sta f_ix
        jsr f_find
        bcs d_ret
        ldy #0
        lda (fz_p),y
        and #$10
        beq :+
        ldy #ST_NOTFOUND        ; a directory, not a file
        rts
:       ldx hh
        lda (fz_p),y
        and #$04
        sta h_l16,x
        ldy #3
        lda (fz_p),y
        sta h_nl,x
        iny
        lda (fz_p),y
        sta h_nh,x
        lda #0
        sta h_pos,x
        sta h_cnt,x
        lda #4
        jmp o_done

o_write:
        jsr v_load
        bcs ow_r
        lda f_wild
        beq :+
        ldy #ST_NAME
        sec
ow_r:   rts
:       lda #0
        sta f_ix
        jsr f_find              ; replace an existing file
        bcs @new
        ldy #0
        lda (fz_p),y
        and #$30
        beq :+
        ldy #ST_LOCKED          ; locked (or a directory)
        rts
:       jsr f_kill              ; free its sectors; slot stays at f_ix
        bcs ow_r
        jmp @slot
@new:   cpy #ST_NOTFOUND
        bne d_ret2
        jsr f_slot
        bcs d_ret2
@slot:  jsr v_alloc
        bcs d_ret2
        sta f_s
        sty f_s+1
        jsr f_dsec              ; entry: open-for-write, empty
        bcs d_ret2
        jsr f_entp
        lda #$43
        jsr f_mkent
        jsr wr_dbuf
        bcs d_ret2
        jsr v_save
        bcs d_ret2
        ldx hh
        lda f_s
        sta h_sl,x
        lda f_s+1
        sta h_sh,x
        lda #0
        sta h_pos,x
        sta h_nl,x              ; sectors written so far
        sta h_nh,x
o_ent:  lda f_ix                ; remember the entry (= file number)
        sta h_ix,x
        lda f_dir
        sta h_dl,x
        lda f_dir+1
        sta h_dh,x
        lda #8
o_done: ldx hh
        sta h_mode,x
        lda ICIDNO              ; IOCB -> handle
        lsr
        lsr
        lsr
        lsr
        tay
        txa
        sta iomap,y
        ldy #ST_OK
d_ret2: rts

o_app:  jsr v_load
        bcs d_ret2
        lda #0
        sta f_ix
        jsr f_find
        bcs d_ret2
        ldy #0
        lda (fz_p),y
        and #$30
        beq :+
        ldy #ST_LOCKED
        rts
:       lda (fz_p),y
        ora #$01                ; open for write
        sta (fz_p),y
        ldy #1
        lda (fz_p),y
        sta f_c
        iny
        lda (fz_p),y
        sta f_c+1
        iny
        lda (fz_p),y
        sta f_s
        iny
        lda (fz_p),y
        sta f_s+1
        jsr wr_dbuf
        bcs d_ret2
        ldx hh                  ; walk to the last sector, keep it in the buffer
@walk:  lda f_s
        sta h_sl,x
        lda f_s+1
        sta h_sh,x
        jsr h_rd
        bcs d_ret2
        ldy f_tr
        lda (fz_b),y            ; link hi
        and #$03
        sta f_s+1
        iny
        lda (fz_b),y
        sta f_s
        ora f_s+1
        bne @walk
        iny
        lda (fz_b),y            ; count in the last sector
        sta h_pos,x
        lda f_c                 ; sectors before the last one
        sec
        sbc #1
        sta h_nl,x
        lda f_c+1
        sbc #0
        sta h_nh,x
        jmp o_ent

d_close:
        jsr h_find
        bcs @ok
        lda h_mode,x
        cmp #8
        bne @free
        lda #0                  ; last sector: no next
        sta f_s
        sta f_s+1
        jsr h_flush
        bcs @r
        ldx hh
        lda h_drv,x
        sta f_drv
        lda h_dl,x
        sta f_dir
        lda h_dh,x
        sta f_dir+1
        lda h_ix,x
        sta f_ix
        lda #0
        sta dbuf_ok
        jsr f_dsec              ; entry: closed, final size
        bcs @r
        jsr f_entp
        ldx hh
        ldy #0
        lda (fz_p),y
        and #$FE
        sta (fz_p),y
        iny
        lda h_nl,x
        sta (fz_p),y
        iny
        lda h_nh,x
        sta (fz_p),y
        jsr wr_dbuf
        bcs @r
        jsr v_save
        bcs @r
@free:  ldx hh
        lda #0
        sta h_mode,x
        lda ICIDNO
        lsr
        lsr
        lsr
        lsr
        tay
        lda #$FF
        sta iomap,y
@ok:    ldy #ST_OK
@r:     rts

d_put:  sta f_a
        jsr h_find
        bcs @r
        lda h_mode,x
        cmp #8
        beq :+
        ldy #ST_RONLY
@r:     rts
:       lda h_pos,x
        cmp f_dpb               ; data bytes per sector
        bcc @st
        jsr v_need              ; sector full: chain on a new one
        bcs @r
        jsr v_alloc
        bcs @r
        sta f_s
        sty f_s+1
        jsr h_flush
        bcs @r
        ldx hh
        lda f_s
        sta h_sl,x
        lda f_s+1
        sta h_sh,x
        lda #0
        sta h_pos,x
@st:    ldy h_pos,x
        lda f_a
        sta (fz_b),y
        inc h_pos,x
        ldy #ST_OK
        rts

d_get:  jsr h_find
        bcs @r
        lda h_mode,x
        cmp #4
        beq @rd
        cmp #6
        beq @dir
        ldy #ST_WONLY
@r:     rts
@rd:    lda h_pos,x
        cmp h_cnt,x
        bcc @have
        lda h_nl,x
        ora h_nh,x
        bne :+
        ldy #ST_EOF
        rts
:       lda h_nl,x
        sta h_sl,x
        lda h_nh,x
        sta h_sh,x
        jsr h_rd
        bcs @r
        ldx hh
        ldy f_tr
        lda (fz_b),y
        pha
        lda h_l16,x             ; 16-bit links keep all 8 bits
        bne :+
        pla
        and #$03                ; DOS 2: file number<<2 | next hi
        pha
:       pla
        sta h_nh,x
        iny
        lda (fz_b),y
        sta h_nl,x
        iny
        lda (fz_b),y
        sta h_cnt,x
        lda #0
        sta h_pos,x
        jmp @rd
@have:  tay
        inc h_pos,x
        lda (fz_b),y
        ldy #ST_OK
        rts
@dir:   lda h_pos,x
        cmp h_cnt,x
        bcc @have
        lda h_ix,x
        cmp #$FF
        bne :+
        ldy #ST_EOF
        rts
:       jsr dir_line
        bcs @r
        ldx hh
        jmp @dir

d_stat: ldy #ST_OK
        rts

; XIO: 32 rename, 33 delete, 35 lock, 36 unlock, 42 mkdir, 254 format
d_spec: jsr op_begin
        bcs @r
        lda ICCOMZ
        cmp #33
        bne :+
        jmp x_del
:       cmp #32
        bne :+
        jmp x_ren
:       cmp #35
        beq x_lock
        cmp #36
        beq x_lock
        cmp #42
        bne :+
        jmp x_mkdir
:       cmp #254
        bne :+
        jmp x_fmt
:       ldy #ST_NOTIMP
@r:     rts

x_lock: jsr v_load              ; (writability check)
        bcs @r
        lda #0
        sta f_ix
        sta f_any
@l:     jsr f_find
        bcs @e
        ldy #0
        lda (fz_p),y
        ora #$20
        ldx ICCOMZ
        cpx #35
        beq :+
        and #$DF
:       sta (fz_p),y
        jsr wr_dbuf
        bcs @r
        inc f_any
        inc f_ix
        bne @l
@e:     jmp f_endall
@r:     rts

; ---- shared helpers ---------------------------------------------------------
; CIO entry: drive from ZIOCB, name pointer, density. C=1 + Y on error.
op_begin:
        lda #0
        sta dbuf_ok
        lda ICDNOZ
        beq :+
        cmp #5
        bcc :++
:       ldy #ST_DRIVE
        sec
        rts
:       sta f_drv
        tax
        jsr k_dstat             ; (Y = SIO status on error)
        bcc :+
        rts
:       ldx f_drv
        lda ss_tab,x
        sec
        sbc #3
        sta f_dpb               ; 125 or 253 data bytes per sector
        sta f_tr                ; trailer offset
        lda ICBALZ
        sta fz_n
        lda ICBALZ+1
        sta fz_n+1
        jmp f_parse

; handle for this IOCB -> X = hh, fz_b = its buffer, f_dpb/f_tr for its
; drive. C=1 + Y if the IOCB has no D: file.
h_find: lda ICIDNO
        lsr
        lsr
        lsr
        lsr
        tax
        lda iomap,x
        bpl :+
        ldy #ST_NOTOPEN
        sec
        rts
:       tax
        stx hh
        lda h_drv,x
        sta f_drv
        tay
        lda ss_tab,y
        sec
        sbc #3
        sta f_dpb
        sta f_tr
h_buf:  lda #0
        sta fz_b
        txa
        clc
        adc #>hbufs
        sta fz_b+1
        clc
        rts

; read sector h_sl/h_sh into the handle buffer
h_rd:   ldx hh
        lda h_drv,x
        sta s_drv
        lda h_sl,x
        sta s_sec
        lda h_sh,x
        sta s_sec+1
        lda #$52
h_io:   sta s_cmd
        lda fz_b
        sta s_buf
        lda fz_b+1
        sta s_buf+1
        jsr s_io
        bmi :+
        ldx hh
        clc
        rts
:       sec
        rts

; write the handle's current sector with link -> f_s, count = h_pos
h_flush:
        ldx hh
        ldy f_tr
        lda h_ix,x              ; file number
        asl
        asl
        ora f_s+1
        sta (fz_b),y
        iny
        lda f_s
        sta (fz_b),y
        iny
        lda h_pos,x
        sta (fz_b),y
        inc h_nl,x
        bne :+
        inc h_nh,x
:       lda h_drv,x
        sta s_drv
        lda h_sl,x
        sta s_sec
        lda h_sh,x
        sta s_sec+1
        lda #$57
        jmp h_io

; ---- names ----------------------------------------------------------------
; fz_n -> f_dir (directory to search), f_pat (11-char pattern), f_wild.
; "Dn:" prefix optional; directories separated by '/' or '>' from the root.
f_parse:
        ldy #0
:       lda (fz_n),y
        cmp #':'
        beq @col
        iny
        cpy #3
        bcc :-
        ldy #$FF
@col:   iny
        lda #<361
        sta f_dir
        lda #>361
        sta f_dir+1
@comp:  lda (fz_n),y
        cmp #'/'
        beq @sep
        cmp #'>'
        bne @get
@sep:   iny
        bne @comp
@get:   jsr f_patget
        bcs @bad
        cmp #'/'
        beq @dir
        cmp #'>'
        beq @dir
        sty f_y2                ; rename finds its ',' here
        clc
        rts
@dir:   sty f_y
        lda f_wild
        bne @bad
        lda #0
        sta f_ix
        jsr f_find
        bcs @r
        ldy #0
        lda (fz_p),y
        and #$10
        beq @nf
        ldy #3
        lda (fz_p),y
        sta f_dir
        iny
        lda (fz_p),y
        sta f_dir+1
        ldy f_y
        iny
        jmp @comp
@nf:    ldy #ST_NOTFOUND
        sec
@r:     rts
@bad:   ldy #ST_NAME
        sec
        rts

; one name component at (fz_n),y -> f_pat. A = terminator, Y on it.
; An empty component means "everything" (all '?').
f_patget:
        lda #' '
        ldx #10
:       sta f_pat,x
        dex
        bpl :-
        lda #0
        sta f_wild
        sta f_dot
        ldx #0
        lda #8
        sta f_lim
@l:     lda (fz_n),y
        cmp #'.'
        beq @dot
        jsr f_term
        bcs @end
        cmp #'*'
        beq @star
        cmp #'?'
        beq @q
        cmp #'a'
        bcc :+
        cmp #'z'+1
        bcs @bad
        and #$DF                ; upper case
:       cmp #'_'
        beq @st
        cmp #'0'
        bcc @bad
        cmp #'9'+1
        bcc @st
        cmp #'A'
        bcc @bad
        cmp #'Z'+1
        bcs @bad
@st:    cpx f_lim
        bcs :+
        sta f_pat,x
        inx
:       iny
        bne @l
@q:     inc f_wild
        lda #'?'
        bne @st
@star:  inc f_wild
        lda #'?'
:       cpx f_lim
        bcs :+
        sta f_pat,x
        inx
        bne :-
:       iny
        bne @l
@dot:   lda f_dot
        bne @bad
        inc f_dot
        ldx #8
        lda #11
        sta f_lim
        iny
        bne @l
@end:   pha
        txa
        ora f_dot
        bne :+
        lda #'?'                ; empty: match all
        ldx #10
@all:   sta f_pat,x
        dex
        bpl @all
        inc f_wild
:       pla
        clc
        rts
@bad:   sec
        rts

f_term: cmp #0                  ; C=1 if A ends a name
        beq @y
        cmp #EOL
        beq @y
        cmp #'/'
        beq @y
        cmp #'>'
        beq @y
        cmp #','
        beq @y
        cmp #' '
        beq @y
        clc
        rts
@y:     sec
        rts

; ---- directory ------------------------------------------------------------
; from entry f_ix of f_dir, the next one matching f_pat -> f_ix, fz_p.
; C=1, Y = ST_NOTFOUND (or the SIO error) when there is none.
f_find: lda f_ix
        cmp #64
        bcs @nf
        jsr f_dsec
        bcs @r
        jsr f_entp
        ldy #0
        lda (fz_p),y
        beq @nf                 ; never used: end of directory
        bmi @nx                 ; deleted
        and #$50
        beq @nx
        ldx #0
        ldy #5
@m:     lda f_pat,x
        cmp #'?'
        beq :+
        cmp (fz_p),y
        bne @nx
:       iny
        inx
        cpx #11
        bne @m
        clc
        rts
@nx:    inc f_ix
        bne f_find
@nf:    ldy #ST_NOTFOUND
        sec
@r:     rts

; first free directory slot -> f_ix (dbuf holds its sector). C=1 if full.
f_slot: lda #0
        sta f_ix
@l:     jsr f_dsec
        bcs @r
        jsr f_entp
        ldy #0
        lda (fz_p),y
        beq @y
        bmi @y
        inc f_ix
        lda f_ix
        cmp #64
        bcc @l
        ldy #ST_DIRFULL
        sec
@r:     rts
@y:     clc
        rts

; directory sector holding entry f_ix -> dbuf (cached)
f_dsec: lda f_ix
        lsr
        lsr
        lsr
        clc
        adc f_dir
        sta s_sec
        lda f_dir+1
        adc #0
        sta s_sec+1
        lda dbuf_ok
        beq @rd
        lda s_sec
        cmp db_sec
        bne @rd
        lda s_sec+1
        cmp db_sec+1
        bne @rd
        lda f_drv
        cmp db_drv
        bne @rd
        clc
        rts
@rd:    lda s_sec
        sta db_sec
        lda s_sec+1
        sta db_sec+1
        lda f_drv
        sta db_drv
        sta s_drv
        lda #<dbuf
        ldy #>dbuf
        jsr rd_any
        bcs :+
        lda #1
        sta dbuf_ok
        rts
:       lda #0
        sta dbuf_ok
        sec
        rts

f_entp: lda f_ix                ; fz_p -> entry f_ix inside dbuf
        and #7
        asl
        asl
        asl
        asl
        sta fz_p
        lda #>dbuf
        sta fz_p+1
        rts

wr_dbuf:                        ; write the cached directory sector back
        lda db_drv
        sta s_drv
        lda db_sec
        sta s_sec
        lda db_sec+1
        sta s_sec+1
        lda #<dbuf
        ldy #>dbuf
        jmp wr_any

; fill entry fz_p: flag A, count 0 (8 for a directory), start f_s, name f_pat
f_mkent:
        ldy #0
        sta (fz_p),y
        and #$10
        beq :+
        lda #8
:       iny
        sta (fz_p),y
        iny
        lda #0
        sta (fz_p),y
        iny
        lda f_s
        sta (fz_p),y
        iny
        lda f_s+1
        sta (fz_p),y
        ldx #0
:       iny
        lda f_pat,x
        sta (fz_p),y
        inx
        cpx #11
        bne :-
        rts

; ---- VTOC -------------------------------------------------------------------
v_load: lda v_dirty             ; unsaved allocations go out first
        beq :+
        jsr v_save
        bcs @io
:       lda f_drv
        sta s_drv
        sta v_drv
        lda #<360
        sta s_sec
        lda #>360
        sta s_sec+1
        lda #<vtbuf
        ldy #>vtbuf
        jsr rd_any
        bcs @io
        lda vtbuf
        cmp #2
        bne @ro
        lda vtbuf+2             ; only 720-sector disks are written: 768+
        cmp #3                  ; (ED's 1010, big MyDOS) stay read-only
        bcs @ro
        clc
        rts
@ro:    ldy #ST_FORMAT
        sec
        rts
@io:    rts

v_need: lda v_drv               ; VTOC of the current handle's drive loaded?
        cmp f_drv
        beq :+
        jmp v_load
:       clc
        rts

v_save: lda #0
        sta v_dirty
        lda v_drv
        sta s_drv
        lda #<360
        sta s_sec
        lda #>360
        sta s_sec+1
        lda #<vtbuf
        ldy #>vtbuf
        jmp wr_any

; take the lowest free sector -> A/Y. C=1 + Y=162 if the disk is full.
v_alloc:
        ldx #10
@l:     lda vtbuf,x
        bne @f
        inx
        cpx #100
        bcc @l
        ldy #ST_FULL
        sec
        rts
@f:     ldy #0
:       asl
        bcs :+
        iny
        bne :-
:       stx f_t                 ; sector = (X-10)*8 + Y
        lda #0
        sta f_t+1
        lda f_t
        sec
        sbc #10
        asl
        rol f_t+1
        asl
        rol f_t+1
        asl
        rol f_t+1
        sty f_t
        ora f_t
        sta f_t
v_take: jsr v_bit               ; clear bit f_t; free count - 1
        inc v_dirty
        eor #$FF
        and vtbuf,x
        sta vtbuf,x
        lda vtbuf+3
        bne :+
        dec vtbuf+4
:       dec vtbuf+3
        lda f_t
        ldy f_t+1
        clc
        rts

; sector A/Y back to the free pool
v_free: sta f_t
        sty f_t+1
        jsr v_bit
        bcs :+
        inc v_dirty
        ora vtbuf,x
        sta vtbuf,x
        inc vtbuf+3
        bne :+
        inc vtbuf+4
:       rts

; f_t -> X = VTOC byte, A = bit mask. C=1 if beyond the bitmap.
v_bit:  lda f_t+1
        sta f_u
        lda f_t
        lsr f_u
        ror
        lsr f_u
        ror
        lsr f_u
        ror
        clc
        adc #10
        tax
        cmp #100
        bcs :+
        lda f_t
        and #7
        tay
        lda bitmask,y
        clc
:       rts

; is f_t free? C=1 yes
v_isfree:
        jsr v_bit
        bcs @n
        and vtbuf,x
        beq @n
        sec
        rts
@n:     clc
        rts

; ---- deleting ---------------------------------------------------------------
; free the chain of entry fz_p (file) or its 8 sectors (empty directory).
; The entry itself is left to the caller.
f_kill: ldy #0
        lda (fz_p),y
        and #$04
        sta f_l16
        lda (fz_p),y
        and #$10
        bne @dir
        ldy #3
        lda (fz_p),y
        sta f_s
        iny
        lda (fz_p),y
        sta f_s+1
        lda #0                  ; runaway guard: 4096 sectors
        sta f_c
        lda #$10
        sta f_c+1
@l:     lda f_s
        ora f_s+1
        beq @ok
        lda f_s
        sta s_sec
        lda f_s+1
        sta s_sec+1
        lda f_drv
        sta s_drv
        lda #<tbuf
        ldy #>tbuf
        jsr rd_any
        bcs @io
        lda f_s
        ldy f_s+1
        jsr v_free
        ldy f_tr
        lda tbuf,y
        ldx f_l16
        bne :+
        and #$03
:       sta f_s+1
        lda tbuf+1,y
        sta f_s
        dec f_c
        bne @l
        dec f_c+1
        bne @l
@ok:    clc
        rts
@io:    rts
@dir:   jsr f_dsave             ; directory: must be empty
        ldy #3
        lda (fz_p),y
        sta f_dir
        iny
        lda (fz_p),y
        sta f_dir+1
        lda #'?'
        ldx #10
:       sta f_pat,x
        dex
        bpl :-
        lda #0
        sta f_ix
        jsr f_find
        php
        jsr f_drest
        plp
        bcs :+
        ldy #ST_LOCKED          ; not empty
        sec
        rts
:       jsr f_dsec              ; reload our entry
        jsr f_entp
        ldy #3
        lda (fz_p),y
        sta f_t
        iny
        lda (fz_p),y
        sta f_t+1
        lda #8
        sta f_c
:       lda f_t
        ldy f_t+1
        jsr v_free
        inc f_t
        bne :+
        inc f_t+1
:       dec f_c
        bne :--
        clc
        rts

f_dsave:                        ; save/restore the search state
        ldx #14
:       lda f_dir,x
        sta f_save,x
        dex
        bpl :-
        rts
f_drest:
        ldx #14
:       lda f_save,x
        sta f_dir,x
        dex
        bpl :-
        rts

x_del:  jsr v_load
        bcs @r
        lda #0
        sta f_ix
        sta f_any
@l:     jsr f_find
        bcs @e
        ldy #0
        lda (fz_p),y
        and #$20
        beq :+
        ldy #ST_LOCKED
        rts
:       jsr f_kill
        bcs @r
        ldy #0
        lda #$80
        sta (fz_p),y
        jsr wr_dbuf
        bcs @r
        inc f_any
        inc f_ix
        bne @l
@e:     cpy #ST_NOTFOUND
        bne @r2
        lda f_any
        beq @r2
        jsr v_save
        bcs @r
        ldy #ST_OK
@r:     rts
@r2:    sec
        rts

; end of a match-all loop: Y = NOTFOUND -> ok if anything matched
f_endall:
        cpy #ST_NOTFOUND
        bne :+
        lda f_any
        beq :+
        ldy #ST_OK
        clc
:       rts

; "OLD,NEW": '?' in NEW keeps the old character
x_ren:  jsr v_load
        bcs @r
        ldy f_y2
        lda (fz_n),y
        cmp #','
        bne @bad
        ldx #10
:       lda f_pat,x
        sta f_old,x
        dex
        bpl :-
        iny
        jsr f_patget
        bcs @bad
        ldx #10
:       lda f_pat,x
        sta f_new,x
        lda f_old,x
        sta f_pat,x
        dex
        bpl :-
        lda #0
        sta f_ix
        sta f_any
@l:     jsr f_find
        bcs @e
        ldy #0
        lda (fz_p),y
        and #$20
        beq :+
        ldy #ST_LOCKED
        rts
:       ldx #0
        ldy #5
@c:     lda f_new,x
        cmp #'?'
        beq :+
        sta (fz_p),y
:       iny
        inx
        cpx #11
        bne @c
        jsr wr_dbuf
        bcs @r
        inc f_any
        inc f_ix
        bne @l
@e:     jmp f_endall
@bad:   ldy #ST_NAME
@r:     rts

; MyDOS directory: 8 contiguous sectors, entry flag $10
x_mkdir:
        jsr v_load
        bcs mk_r
        lda f_wild
        beq x_mk1
mk_bad: ldy #ST_NAME
        sec
mk_r:   rts
x_mk1:  lda #0
        sta f_ix
        jsr f_find
        bcs :+
        ldy #ST_NAME            ; exists
        sec
        rts
:       jsr f_slot
        bcs mk_r
        lda #4                  ; first run of 8 free sectors
        sta f_s
        lda #0
        sta f_s+1
mk_try:   lda #0
        sta f_c
mk_chk:   lda f_s
        clc
        adc f_c
        sta f_t
        lda f_s+1
        adc #0
        sta f_t+1
        jsr v_isfree
        bcc mk_next
        inc f_c
        lda f_c
        cmp #8
        bcc mk_chk
        lda #0                  ; found: take them, zero them
        sta f_c
        ldx #0
        txa
:       sta tbuf,x
        inx
        bne :-
mk_take:  lda f_s
        clc
        adc f_c
        sta f_t
        sta s_sec
        lda f_s+1
        adc #0
        sta f_t+1
        sta s_sec+1
        jsr v_take
        lda f_drv
        sta s_drv
        lda #<tbuf
        ldy #>tbuf
        jsr wr_any
        bcs mk_io
        inc f_c
        lda f_c
        cmp #8
        bcc mk_take
        jsr f_dsec
        bcs mk_r2
        jsr f_entp
        lda #$10
        jsr f_mkent
        jsr wr_dbuf
        bcs mk_r2
        jmp v_save
mk_r2:  rts
mk_next:  inc f_s
        bne :+
        inc f_s+1
:       lda f_s+1               ; up to sector 712
        cmp #>712
        bcs :+
        jmp mk_try
:       lda f_s
        cmp #<712
        bcs :+
        jmp mk_try
:
        ldy #ST_FULL
        sec
        rts
mk_io:  rts

; quick format: fresh DOS 2 VTOC (720 sectors) and an empty directory.
; Refuses disks that hold a non-DOS 2 VTOC (only blank or DOS 2 ones).
x_fmt:  jsr v_load
        bcc @go
        cpy #ST_FORMAT
        bne @r
        lda vtbuf               ; blank disk is fine
        bne @r2
@go:    ldx #0
        txa
:       sta vtbuf,x
        sta tbuf,x
        inx
        bne :-
        lda #2
        sta vtbuf
        lda #<707
        sta vtbuf+1
        sta vtbuf+3
        lda #>707
        sta vtbuf+2
        sta vtbuf+4
        lda #$FF
        ldx #10
:       sta vtbuf,x
        inx
        cpx #100
        bcc :-
        lda #$0F                ; 0-3 used
        sta vtbuf+10
        lda #0                  ; 360-367
        sta vtbuf+55
        lda #$7F                ; 368
        sta vtbuf+56
        jsr v_save
        bcs @r
        lda #<361
        sta s_sec
        lda #>361
        sta s_sec+1
@w:     lda #<tbuf
        ldy #>tbuf
        jsr wr_any
        bcs @io
        inc s_sec
        lda s_sec
        cmp #<369
        bne @w
        lda #0
        sta dbuf_ok
        ldy #ST_OK
        clc
@r:     rts
@r2:    ldy #ST_FORMAT
        sec
        rts
@io:    rts

; ---- directory listing (OPEN mode 6) ----------------------------------------
; next "  NAME    EXT 012" line (or "NNN FREE SECTORS") into the buffer
dir_line:
        lda h_drv,x
        sta f_drv
        lda h_dl,x
        sta f_dir
        lda h_dh,x
        sta f_dir+1
        lda h_ix,x
        sta f_ix
        txa                     ; pattern
        asl
        sta f_t
        asl
        asl
        clc
        adc f_t
        adc hh
        tay
        ldx #0
:       lda h_pat,y
        sta f_pat,x
        iny
        inx
        cpx #11
        bne :-
        jsr f_find
        bcc @ent
        cpy #ST_NOTFOUND
        beq @free
        sec
        rts
@ent:   ldx hh
        lda f_ix
        clc
        adc #1
        sta h_ix,x
        ldy #0
        lda (fz_p),y
        and #$20
        beq :+
        lda #'*'-' '
:       clc
        adc #' '
        jsr @put0               ; Y = 0 -> buffer[0]
        lda (fz_p),y            ; ':' marks a directory (MyDOS style)
        and #$10
        beq :+
        lda #':'-' '
:       clc
        adc #' '
        ldy #1
        sta (fz_b),y
        ldx #5                  ; name + ext at 2..12
@n:     txa
        tay
        lda (fz_p),y
        pha
        txa
        sec
        sbc #3
        tay
        pla
        sta (fz_b),y
        inx
        cpx #16
        bne @n
        ldy #13
        lda #' '
        sta (fz_b),y
        ldy #1
        lda (fz_p),y
        sta f_t
        iny
        lda (fz_p),y
        sta f_t+1
        ldy #14
        jsr dec3
        lda #EOL
        sta (fz_b),y
        iny
        jmp @len
@free:  ldx hh
        lda #$FF
        sta h_ix,x
        jsr v_load
        lda vtbuf+3
        sta f_t
        lda vtbuf+4
        sta f_t+1
        ldy #0
        jsr dec3
        ldx #0
:       lda s_free,x
        sta (fz_b),y
        iny
        inx
        cpx #14
        bne :-
@len:   ldx hh
        tya
        sta h_cnt,x
        lda #0
        sta h_pos,x
        clc
        rts
@put0:  ldy #0
        sta (fz_b),y
        rts

; f_t (< 1000) as 3 digits at (fz_b),y; Y advances
dec3:   lda #<100
        jsr @dig
        lda #10
        jsr @dig
        lda #1
@dig:   sta f_u
        ldx #'0'
@l:     lda f_t+1
        bne :+
        lda f_t
        cmp f_u
        bcc @o
:       lda f_t
        sec
        sbc f_u
        sta f_t
        bcs :+
        dec f_t+1
:       inx
        cpx #'9'+1
        bcc @l
        dex
@o:     txa
        sta (fz_b),y
        iny
        rts

s_free: .byte " FREE SECTORS",EOL
bitmask:.byte $80,$40,$20,$10,$08,$04,$02,$01

.ifdef CART
; RESET after a launched program (cartridge build): the OS warm start calls
; DOSINI -> here. Re-enable the cartridge and cold start, so the OS finds
; it and the copier runs ASH again.
k_cartreset:
        lda #0
        sta $D40E               ; NMIEN off around the switch (GINTLK)
        lda $D500               ; Williams: bank 0, cart on
        lda #1
        sta $03FA               ; GINTLK: cartridge present
        jmp COLDSV
.endif

; ---- kernel data (copied with the code) ----------------------------------------
k_memlo:.word fms_end
k_dev:  .res 1
k_next: .res 2
k_l16:  .res 1
k_pos:  .res 1
k_len:  .res 1
k_err:  .res 1
k_sx:   .res 1
k_sy:   .res 1
k_end:  .res 2
k_def:  .res 2
ss_tab: .res 5
s_drv:  .res 1
s_cmd:  .res 1
s_sec:  .res 2
s_buf:  .res 2
dbuf_ok:.res 1
db_drv: .res 1
db_sec: .res 2
v_drv:  .res 1
v_dirty:.res 1
iomap:  .res 8
hh:     .res 1
h_mode: .res NH
h_drv:  .res NH
h_sl:   .res NH                 ; sector in the buffer (write)
h_sh:   .res NH
h_nl:   .res NH                 ; next sector (read) / sectors written
h_nh:   .res NH
h_pos:  .res NH
h_cnt:  .res NH
h_ix:   .res NH                 ; entry index (file number) / listing position
h_dl:   .res NH                 ; directory holding the entry
h_dh:   .res NH
h_l16:  .res NH
h_pat:  .res NH*11
; search state (f_dir..f_wild saved/restored as a block by f_dsave)
f_dir:  .res 2
f_ix:   .res 1
f_pat:  .res 11
f_wild: .res 1
f_save: .res 15
f_drv:  .res 1
f_dpb:  .res 1
f_tr:   .res 1
f_dot:  .res 1
f_lim:  .res 1
f_y:    .res 1
f_y2:   .res 1
f_any:  .res 1
f_a:    .res 1
f_l16:  .res 1
f_s:    .res 2
f_c:    .res 2
f_t:    .res 2
f_u:    .res 1
f_old:  .res 11
f_new:  .res 11

        .segment "KBSS"
hbufs:  .res NH*256             ; page-aligned (KBSS starts on a page)
dbuf:   .res 256                ; directory sectors / shell scratch
vtbuf:  .res 256
sbuf:   .res 256                ; the stream; also FMS scratch (tbuf)
tbuf    = sbuf
fms_end:
