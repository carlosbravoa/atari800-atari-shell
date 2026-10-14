; ===========================================================================
; fileops.s — the shell's file-management commands.
;
; Disks go through the resident D: handler (CIO on IOCB #2, names built as
; "Dn:/dir/NAME"); h: talks to the board's SIO file device directly, with
; its write side on firmware handle 0 (the read stream uses handle 1).
; ===========================================================================

; rm NAME...   wildcards on disks; an empty MyDOS directory goes too
cmd_rm: lda argc
        cmp #2
        bcs :+
        jmp usage
:       lda #1
        sta xi
@l:     lda xi
        cmp argc
        bcs @r
        lda xi
        jsr arg_name
        bcs @e
        lda t_drive
        bne @d
        jsr h_lookup
        bcs @e
        lda #33
        jsr h_xio
        jmp @n
@d:     jsr mkfn
        lda #33
        jsr c_xio
        bpl @n
        jsr perr_cio
@n:     inc xi
        bne @l
@r:     rts
@e:     jsr perr
        jmp @n

; mv OLD NEW: a bare NEW renames in place; a path moves (copy, then delete)
cmd_mv: lda argc
        cmp #3
        beq :+
        jmp usage
:       lda #2
        jsr getarg
        ldy #0
@sc:    lda (ap),y
        beq @ren
        cmp #'/'
        beq @move
        cmp #':'
        beq @move
        iny
        bne @sc
@move:  jsr cp_core
        bcs @r
        lda #1
        jsr arg_name
        bcs @e
        lda t_drive
        bne :+
        jsr h_lookup
        bcs @e
        lda #33
        jmp h_xio
:       jsr mkfn
        lda #33
        jsr c_xio
        bpl @r
        jmp perr_cio
@ren:   lda #1
        jsr arg_name
        bcs @e
        lda t_drive
        bne @dren
        jsr h_lookup            ; h: frame = "OLD,NEW"
        bcs @e
        ldx #0
:       lda namebuf,x
        beq :+
        inx
        bne :-
:       lda #<namebuf
        ldy #>namebuf
        jsr app_new
        lda #32
        jmp h_xio
@dren:  jsr mkfn                ; d: "Dn:/dir/OLD,NEW" (X at the EOL)
        lda #<fnbuf
        ldy #>fnbuf
        jsr app_new
        lda #EOL
        sta (ptr),y
        lda #32
        jsr c_xio
        bpl @r
        jmp perr_cio
@e:     jmp perr
@r:     rts

; append ",<argument 2>" to buffer A/Y at index X; Y = index after it
app_new:
        sta ptr
        sty ptr+1
        txa
        tay
        lda #','
        sta (ptr),y
        iny
        sty tmp3
        lda #2
        jsr getarg
        ldx #0
        ldy tmp3
@c:     lda (ap,x)
        sta (ptr),y
        beq @d
        inc ap
        bne :+
        inc ap+1
:       iny
        cpy #62
        bcc @c
        lda #0
        sta (ptr),y
@d:     rts

cmd_mkdir:
        lda #42
        .byte $2C
cmd_lock:
        lda #35
        .byte $2C
cmd_unlock:
        lda #36
        sta xcmd
        lda argc
        cmp #2
        bcs :+
        jmp usage
:       lda #1
        jsr arg_name
        bcs @e
        lda t_drive
        bne :+
        lda #E_ROFS             ; h: is flat and has no locks
        sta err
@e:     jmp perr
:       jsr mkfn
        lda xcmd
        jsr c_xio
        bpl :+
        jmp perr_cio
:       rts

; format dn:  — quick format to an empty DOS 2 disk (asks first)
cmd_format:
        lda argc
        cmp #2
        bcs :+
        jmp usage
:       lda #1
        jsr getarg
        jsr resolve
        bcc :+
        jmp @e
:       lda t_drive
        bne :+
        jmp @ro
:       lda r_kind
        ora t_depth
        beq :+
        jmp @u
:
        jsr iprint
        .byte "erase everything on d",0
        lda t_drive
        ora #'0'
        jsr outc
        jsr iprint
        .byte ":? (y/n) ",0
        jsr getkey
        ora #$20
        pha
        jsr outc
        jsr crlf
        pla
        cmp #'y'
        beq :+
        rts
:
        lda #0
        sta comp
        jsr mkfn
        lda #254
        jsr c_xio
        bmi @cerr
        ldx #127                ; boot sector: a stub that just returns, so
        lda #0                  ; the disk boots to BASIC like a blank DOS disk
:       sta sbuf,x
        dex
        bpl :-
        ldx #7
:       lda bootstub,x
        sta sbuf,x
        dex
        bpl :-
        lda t_drive
        sta s_drv
        lda #1
        sta s_sec
        lda #0
        sta s_sec+1
        lda #<sbuf
        ldy #>sbuf
        jsr wr_any
        bcc @r
        lda #E_IO
        sta err
        jmp perr
@cerr:  jmp perr_cio
@ro:    lda #E_ROFS
        sta err
@e:     jmp perr
@u:     jmp usage
@r:     rts

; cp SRC DST — any disk or h: to any disk or h:; DST may be a directory
cmd_cp: lda argc
        cmp #3
        beq cp_core
        jmp usage

; C=1 if the copy failed (already reported)
cp_core:
        lda #2                  ; destination first: resolving it later
        jsr getarg              ; would disturb an open h: source stream
        jsr resolve
        bcs cp_e1
        lda #0
        sta cbuf                ; cbuf = destination name ("" = source's)
        lda r_kind
        beq cpc_dir
        jsr tdir_load
        bcs cp_e1
        jsr lookup_comp
        bcs cpc_new
        ldy #0
        lda (dp),y
        and #$10
        beq cpc_new
        jsr descend             ; an existing directory: copy into it
        bcc cpc_dir
cp_e1:  jmp cp_err
cpc_new:
        ldx #0
:       lda comp,x
        sta cbuf,x
        beq cpc_dir
        inx
        bne :-
cpc_dir:
        ldx #CWSIZE             ; remember the destination directory
:       lda tcw-1,x
        sta dcw-1,x
        dex
        bne :-
        lda #1                  ; source
        jsr getarg
        jsr open_file
        bcs cp_e1
        lda cbuf
        bne :+
        ldx #0                  ; same name as the source
@cn:    lda nbuf,x
        sta cbuf,x
        beq :+
        inx
        bne @cn
:       ldx #CWSIZE
:       lda dcw-1,x
        sta tcw-1,x
        dex
        bne :-
        ldx #0                  ; comp = destination name
:       lda cbuf,x
        sta comp,x
        beq :+
        inx
        bne :-
:       lda #0
        sta fsz
        sta fsz+1
        sta fsz+2
        sta wquiet
        jsr w_open
        bcc cp_loop
        jsr stream_end
        sec
        rts
cp_err: jsr perr
        sec
        rts

cp_loop:
        jsr k_getbyte
        bcs cp_done
        jsr fgetc
        jsr w_put
        bcc cp_loop
        jmp cp_fin
cp_done:
        jsr w_close
        bcs cp_fin
        lda fsz
        sta num
        lda fsz+1
        sta num+1
        lda fsz+2
        sta num+2
        jsr pdec0
        jsr iprint
        .byte " bytes",EOL,0
        jsr stream_end
        clc
        rts
cp_fin: jsr w_close
        jsr stream_end
        sec
        rts

; ---- writing a file: comp in directory tcw, disk or h: ------------------------
; w_open / w_put (A) / w_close -> C=1 on error; reported unless wquiet.
w_open: lda #0
        sta hwlen
        lda t_drive
        sta wdev
        bne wo_d
        jsr h_name0             ; h: on firmware handle 0
        ldx #0
:       lda comp,x
        sta namebuf,x
        beq :+
        inx
        bne :-
:       lda #8
        jsr hw_open
        bcc w_ok
w_hio:  lda #E_IO
        sta err
        lda wquiet
        bne w_bad
        jsr perr
w_bad:  sec
        rts
wo_d:   jsr mkfn
        lda #8
        jsr c_open
w_cio:  bpl w_ok
        lda wquiet
        bne w_bad
        jsr perr_cio
        sec
        rts
w_ok:   clc
        rts

w_put:  ldx wdev
        bne @d
        jsr hw_put
        bcc w_ok
        bcs w_hio
@d:     jsr c_put
        jmp w_cio

w_close:
        ldx wdev
        bne @d
        jsr hw_close
        bcc w_ok
        bcs w_hio
@d:     jsr c_close
        jmp w_cio

fgetc:  inc fsz                 ; byte counter for cp
        bne :+
        inc fsz+1
        bne :+
        inc fsz+2
:       rts

; argument A -> resolved path that names an entry (comp). C=1 error (err set)
arg_name:
        jsr getarg
        jsr resolve
        bcs @r
        lda r_kind
        bne @ok
        lda #E_ISDIR
        sta err
        sec
        rts
@ok:    clc
@r:     rts

; resolved h: name (comp) -> namebuf, verified to exist
h_lookup:
        jsr tdir_load
        bcs @r
        jsr lookup_comp
        bcs @r
        jsr fmt_name
        jsr h_name0
        ldx #0
:       lda nbuf,x
        sta namebuf,x
        beq :+
        inx
        bne :-
:       clc
@r:     rts

; fnbuf = "Dn:/dir/dir/" + comp + EOL from tcw; X = index of the EOL
mkfn:   lda #'D'
        sta fnbuf
        lda t_drive
        ora #'0'
        sta fnbuf+1
        lda #':'
        sta fnbuf+2
        ldx #3
        lda #1
        sta pl_i
@lv:    lda pl_i
        cmp t_depth
        beq :+
        bcs @nm
:       lda #'/'
        sta fnbuf,x
        inx
        lda pl_i
        asl
        asl
        asl
        asl
        tay
:       lda t_names,y
        beq :+
        sta fnbuf,x
        inx
        iny
        bne :-
:       inc pl_i
        bne @lv
@nm:    lda #'/'
        sta fnbuf,x
        inx
        ldy #0
:       lda comp,y
        beq :+
        sta fnbuf,x
        inx
        iny
        bne :-
:       lda #EOL
        sta fnbuf,x
        rts

; ---- CIO on IOCB #2 -> A = Y = status, N = error -------------------------------
c_open: ldx #$20                ; A = mode, name in fnbuf
        sta ICAX1,x
        lda #3
        bne c_nm
c_xio:  ldx #$20                ; A = XIO command, name in fnbuf
        pha
        lda #0
        sta ICAX1,x
        pla
c_nm:   sta ICCOM,x
        lda #0
        sta ICAX2,x
        lda #<fnbuf
        sta ICBAL,x
        lda #>fnbuf
        sta ICBAH,x
        jsr CIOV
        tya
        rts
c_close:
        ldx #$20
        lda #12
        sta ICCOM,x
        jsr CIOV
        tya
        rts
c_put:  ldx #$20                ; A = byte
        pha
        lda #$0B
        sta ICCOM,x
        lda #0
        sta ICBLL,x
        sta ICBLH,x
        pla
        jsr CIOV
        tya
        rts

; ---- writing to h: (firmware handle 0) ------------------------------------------
hw_cmd: sta DCOMND
        lda #$72
        sta DDEVIC
        lda #1
        sta DUNIT
        lda #0
        sta DAUX2
        lda #7
        sta DTIMLO
        rts
hw_open:                        ; A = mode; name in namebuf. C=1 error
        sta DAUX1
        lda #$4F
        jsr hw_cmd
        lda #<namebuf
        ldy #>namebuf
        ldx #64
hw_send:                        ; write frame A/Y, X bytes. C=1 error
        sta DBUFLO
        sty DBUFHI
        stx DBYTLO
        lda #0
        sta DBYTHI
        lda #$80
        sta DSTATS
        jsr SIOV
        sty k_err
        tya
        bmi :+
        clc
        rts
:       sec
        rts
hw_put: ldx hwlen               ; A = byte; C=1 on error
        sta hwbuf,x
        inc hwlen
        cpx #127
        bcc :+
        jmp hw_flush
:       clc
        rts
hw_flush:
        lda hwlen
        beq @r
        sta DAUX1
        lda #$57
        jsr hw_cmd
        ldx hwlen
        lda #0
        sta hwlen
        lda #<hwbuf
        ldy #>hwbuf
        jmp hw_send
@r:     clc
        rts
hw_close:
        jsr hw_flush
        bcs :+
        lda #$43
        jsr hw_cmd
        lda #0
        sta DSTATS
        sta DBYTLO
        sta DBYTHI
        jsr SIOV
        clc
:       rts

bootstub: .byte 0, 1, $00, $07, $06, $07, $18, $60   ; 1 sector @ $0700: clc, rts

usage:  lda #E_USAGE
        sta err
        jmp perr

; CIO status Y -> "<argv0>: <message>"
perr_cio:
        sty tmp3
        sty cioerr
        lda #0
        jsr getarg
        jsr puts_ap
        jsr iprint
        .byte ": ",0
        ldx #0
@f:     lda ciocodes,x
        beq @num
        cmp tmp3
        beq @m
        inx
        bne @f
@m:     lda ciolo,x
        ldy ciohi,x
        jsr puts
        jmp crlf
@num:   jsr iprint
        .byte "error ",0
        lda tmp3
        jsr num8
        jsr pdec0
        jmp crlf
