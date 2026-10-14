; ===========================================================================
; sd.s — ASH-TN: the SD card as a device (`sd:`), through the firmware's
; H: control XIOs (device $72, command $58, aux1 = function; see
; specs/ash-tn-proposal.md "Byte-level table"):
;
;   40 LIST path (+start)   the handle becomes a text listing:
;                           "<t> <size8> <name>"EOL ... "END"EOL | "MORE"EOL
;   41 MOUNT "<n>path"      deferred: the firmware mounts in its main loop
;   42 UNMOUNT "<n>"        deferred
;   43 CART path            deferred: load + cold boot
;   44 BOOT 'C'|'W'         deferred: cold / warm boot
;   45 STATUS               listing: "d1: name" .. "cart: name" "xex: n" ..
;   47 OPENR path           open any SD file read-only on the handle
;
; Paths are absolute from the SD root; `sdcwd` is the shell's current SD
; directory (`cd sd:/games`), `sdpath` the resolved target of a command.
; Writing to sd: (cp into it, rm, mkdir...) is not offered: the card is
; the firmware's, the shell only reads, mounts and boots from it.
; ===========================================================================
SD_LIST   = 40
SD_MOUNT  = 41
SD_UMOUNT = 42
SD_CART   = 43
SD_BOOT   = 44
SD_STATUS = 45
SD_OPENR  = 47
SDPLEN    = 62                  ; longest path we build (frame = 64)

; ---- XIO on our handle; namebuf is the frame. C=1 on error (not reported)
sd_xio: sta DAUX1
        lda #$58
        jsr k_hcmd
        lda #<namebuf
        sta DBUFLO
        lda #>namebuf
        sta DBUFHI
        lda #64
        sta DBYTLO
        lda #0
        sta DBYTHI
        lda #$80
        sta DSTATS
        lda #7
        sta DTIMLO
        jsr SIOV
        sty k_err
        tya
        bmi :+
        clc
        rts
:       sec
        rts

; namebuf = sdpath (0-terminated), rest zero
sd_frame:
        jsr h_name0
        ldx #0
:       lda sdpath,x
        sta namebuf,x
        beq :+
        inx
        cpx #SDPLEN
        bcc :-
:       rts

; ---- paths ------------------------------------------------------------------
; (ap) = "sd:..." or a relative name while the cwd is sd: -> sdpath absolute,
; normalised ("." ".." collapsed). r_kind = 0 if it names a directory by
; form (trailing '/' or empty), else 1. C=1 (err) if too long.
sd_abs: ldy #0
        lda (ap),y
        jsr tolower
        cmp #'s'
        bne @rel
        iny
        lda (ap),y
        jsr tolower
        cmp #'d'
        bne @rel
        iny
        lda (ap),y
        cmp #':'
        bne @rel
        iny                     ; past "sd:"
        bne @start
@rel:   ldy #0
@start: sty ypos
        lda (ap),y
        cmp #'/'
        beq @root
        ldx #0                  ; relative: start from sdcwd
:       lda sdcwd,x
        sta sdpath,x
        beq :+
        inx
        bne :-
:       cpx #1                  ; a cwd of "/" is the root: build from ""
        bne :+
        ldx #0
        stx sdpath
:       stx sx
        jmp @comp
@root:  ldx #0
        stx sdpath
        stx sx                  ; sdpath = "" (root), components add "/x"
        iny
        sty ypos
@comp:  ldy ypos
        lda (ap),y
        cmp #'/'
        bne :+
        iny
        sty ypos
        lda #0                  ; a trailing '/' names a directory
        sta r_kind
        lda (ap),y
:       cmp #0
        bne @c1
        jmp @done
@c1:    lda #1
        sta r_kind
        ldx #0                  ; comp = component (≤ 27 chars)
@cc:    lda (ap),y
        beq @ce
        cmp #'/'
        beq @ce
        cpx #27
        bcs :+
        sta comp,x
        inx
:       iny
        bne @cc
@ce:    sty ypos
        lda #0
        sta comp,x
        lda comp
        cmp #'.'
        bne @add
        lda comp+1
        beq @isdir              ; "."
        cmp #'.'
        bne @add
        lda comp+2
        bne @add
@isdir: lda #0                  ; "." and "..": still a directory
        sta r_kind
        ldx sx                  ; "..": drop the last component
@up:    lda comp+1
        beq @comp               ; (".": nothing to drop)
        cpx #0
        beq @comp
        dex
        lda sdpath,x
        cmp #'/'
        bne @up
        stx sx
        lda #0
        sta sdpath,x
        jmp @comp
@add:   ldx sx
        lda #'/'
        sta sdpath,x
        inx
        ldy #0
:       lda comp,y
        beq :+
        cpx #SDPLEN
        bcs @long
        sta sdpath,x
        inx
        iny
        bne :-
:       stx sx
        lda #0
        sta sdpath,x
        jmp @comp
@done:  ldx sx                  ; "" means the root: show it as "/"
        bne :+
        lda #'/'
        sta sdpath
        lda #0
        sta sdpath+1
:       clc
        rts
@long:  lda #E_DEEP
        sta err
        sec
        rts

; the last component of sdpath -> nbuf (for messages), ≤ 15 chars
sd_lastname:
        ldx #0
        ldy #0
@f:     lda sdpath,x
        beq @cp
        cmp #'/'
        bne :+
        txa
        tay
        iny
:       inx
        bne @f
@cp:    ldx #0
:       lda sdpath,y
        sta nbuf,x
        beq :+
        iny
        inx
        cpx #15
        bcc :-
        lda #0
        sta nbuf,x
:       clc
        rts

; ---- open an SD file as the stream (OPENR). C=1 + err
sd_open:
        jsr sd_frame
        lda #SD_OPENR
        jsr sd_xio
        bcs @no
        lda #0
        sta k_dev
        jsr st_reset
        jmp sd_lastname
@no:    lda #E_NOENT
        sta err
        sec
        rts

; ---- listings ---------------------------------------------------------------
; one line from the stream into lbuf (0-terminated, EOL dropped). C=1 at end
sd_line:
        ldx #0
@l:     jsr k_getbyte
        bcs @eof
        cmp #EOL
        beq @end
        cpx #47
        bcs @l
        sta lbuf,x
        inx
        bne @l
@end:   lda #0
        sta lbuf,x
        clc
        rts
@eof:   sec
        rts

; ls of sdpath (lflag = long). C=1 + err on failure
sd_ls:  lda #0
        sta sdstart
        sta sdstart+1
@page:  jsr sd_frame
        lda sdstart
        sta namebuf+62
        lda sdstart+1
        sta namebuf+63
        lda #SD_LIST
        jsr sd_xio
        bcs @nodir
@l:     jsr sd_line
        bcs @close
        lda lbuf
        cmp #'E'                ; END
        beq @close
        cmp #'M'                ; MORE: ask again from where we are
        beq @more
        inc sdstart
        bne :+
        inc sdstart+1
:       lda lflag
        beq @short
        lda lbuf
        cmp #'d'
        bne :+
        lda #'d'
        .byte $2C
:       lda #'-'
        jsr outc
        jsr iprint
        .byte "r- ",0
        ldx #2
:       lda lbuf,x
        jsr outc
        inx
        cpx #10
        bne :-
        lda #' '
        jsr outc
@short: ldx #11
:       lda lbuf,x
        beq :+
        jsr outc
        inx
        bne :-
:       lda lbuf
        cmp #'d'
        bne :+
        lda #'/'
        jsr outc
:       jsr crlf
        jsr chk_break
        lda abort
        beq @l
@close: jsr stream_end
        clc
        rts
@more:  jsr stream_end
        jmp @page
@nodir: lda #E_NOENT
        sta err
        sec
        rts

; print the firmware's STATUS listing (mount with no arguments)
sd_status:
        jsr sd_frame
        lda #SD_STATUS
        jsr sd_xio
        bcs @e
@l:     jsr sd_line
        bcs @d
        lda lbuf
        cmp #'E'
        beq @d
        lda #<lbuf
        ldy #>lbuf
        jsr puts
        jsr crlf
        jmp @l
@d:     jmp stream_end
@e:     lda #E_IO
        sta err
        jmp perr

; ---- commands -------------------------------------------------------------------
; cd into sdpath (validated with a LIST), making sd: the current drive
sd_cd:  jsr sd_frame
        lda #0
        sta namebuf+62
        sta namebuf+63
        lda #SD_LIST
        jsr sd_xio
        bcs @no
        jsr stream_end
        ldx #0
:       lda sdpath,x
        sta sdcwd,x
        beq :+
        inx
        bne :-
:       lda #5
        sta cwd_drive
        lda #0
        sta cwd_depth
        clc
        rts
@no:    lda #E_NOTDIR
        sta err
        sec
        rts

; mount [dn: sd:/path]  |  umount dn:
cmd_mount:
        lda argc
        cmp #2
        bcs @args
        jmp sd_status
@args:  cmp #3
        bcs :+
        jmp usage
:       lda #1
        jsr drive_arg
        bcs @u
        sta tmp2
        lda #2
        jsr getarg
        jsr sd_abs
        bcs @e
        jsr sd_frame
        ldx #SDPLEN
:       lda namebuf-1,x         ; frame = "<n>" + path
        sta namebuf,x
        dex
        bne :-
        lda tmp2
        sta namebuf
        lda #SD_MOUNT
        jsr sd_xio
        bcs @io
        jsr iprint
        .byte "mounting",EOL,0
        jsr sd_settle
        jmp sd_status
@u:     jmp usage
@io:    lda #E_IO
        sta err
@e:     jmp perr

cmd_umount:
        lda argc
        cmp #2
        bcs :+
        jmp usage
:       lda #1
        jsr drive_arg
        bcs @u
        pha
        jsr h_name0
        pla
        sta namebuf
        lda #SD_UMOUNT
        jsr sd_xio
        bcs @io
        jsr sd_settle
        jmp sd_status
@u:     jmp usage
@io:    lda #E_IO
        sta err
        jmp perr

; argument A = "dN:" -> A = 'N'. C=1 if not a drive
drive_arg:
        jsr getarg
        ldy #0
        lda (ap),y
        jsr tolower
        cmp #'d'
        bne @no
        iny
        lda (ap),y
        cmp #'1'
        bcc @no
        cmp #'5'
        bcs @no
        pha
        iny
        lda (ap),y
        cmp #':'
        bne @no1
        pla
        clc
        rts
@no1:   pla
@no:    sec
        rts

; give the firmware's main loop a moment for a deferred action
sd_settle:
        lda RTCLOK+2
        sta tmp3
:       lda RTCLOK+2
        sec
        sbc tmp3
        cmp #30
        bcc :-
        rts

; cart sd:/path  — load a cartridge and cold boot (the machine goes away)
cmd_cart:
        lda argc
        cmp #2
        bcs :+
        jmp usage
:       lda #1
        jsr getarg
        jsr sd_abs
        bcs @e
        jsr sd_frame
        lda #SD_CART
        jsr sd_xio
        bcs @io
        jsr iprint
        .byte "booting the cartridge",EOL,0
.ifdef TN
        lda #3
        sta MB_STATUS
        lda #0
        sta MB_CMDREQ
.endif
        rts
@io:    lda #E_IO
        sta err
@e:     jmp perr

; reboot: a firmware cold boot (ROMs reloaded, cartridge power-cycled);
; falls back to the OS cold start if the firmware doesn't answer
cmd_reboot_tn:
        jsr h_name0
        lda #'C'
        sta namebuf
        lda #SD_BOOT
        jsr sd_xio
        bcs @os
.ifdef TN
        lda #3
        sta MB_STATUS
        lda #0
        sta MB_CMDREQ
.endif
        rts
@os:    jmp COLDSV
