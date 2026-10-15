; ===========================================================================
; net.s — ASH-TN: URLs (http://, https://, tnfs://) as mailbox requests the
; PC program (ashterm) serves; delivery through the board's file transfer.
; Fields and rules: specs/ash-tn-proposal.md §3b. The Atari never talks to
; the network: it writes the URL and a destination, raises MB_NETREQ, and
; waits (BREAK aborts). Files arrive on the card (sd: path) or in /HDD;
; listings arrive as text in RAM and go through the sd: listing parser.
; ===========================================================================
MB_NETREQ  = $06D0
MB_NETST   = $06D1
MB_NETLEN  = $06D2
MB_NETDEST = $06D5
MB_NETNAME = $06D6
NET_URL    = $8000
NET_DST    = $8100
NET_TEXT   = $8200

; C=1 if (ap) starts with http://, https:// or tnfs://
is_url: ldy #0
@l:     lda (ap),y
        beq @no
        jsr tolower
        cmp #':'
        beq @col
        iny
        cpy #6
        bcc @l
@no:    clc
        rts
@col:   iny
        lda (ap),y
        cmp #'/'
        bne @no
        iny
        lda (ap),y
        cmp #'/'
        bne @no
        sec
        rts

; (ap) -> NET_URL; the last path component -> nbuf (≤ 15 chars, for names)
net_url:
        ldy #0
:       lda (ap),y
        sta NET_URL,y
        beq :+
        iny
        bne :-
:       ldy #0                  ; last component
        ldx #0
@f:     lda NET_URL,y
        beq @cp
        cmp #'/'
        bne :+
        tya
        tax
        inx
:       iny
        bne @f
@cp:    ldy #0
:       lda NET_URL,x
        beq :+
        cmp #'?'
        beq :+
        sta nbuf,y
        inx
        iny
        cpy #15
        bcc :-
:       lda #0
        sta nbuf,y
        cpy #0
        bne :+
        ldx #0                  ; no name in the URL: "index"
:       lda s_index,x
        sta nbuf,x
        beq :+
        inx
        bne :-
:       rts
s_index: .byte "index",0

; raise request A and wait for the PC. C=1 + err / message on failure
net_wait:
        pha
        jsr pc_ping             ; is anyone there at all?
        bcs :+
        pla
        jsr pc_fail
        lda #E_NET
        sta err
        sec
        rts
:       pla
        ldx #0
        stx MB_NETST
        sta MB_NETREQ
        jsr iprint
        .byte "fetching...",EOL,0
@w:     lda MB_NETREQ
        beq @done
        lda BRKKEY
        bne @w
        lda #$FF
        sta BRKKEY
        lda #0
        sta MB_NETREQ
        jsr iprint
        .byte "aborted",EOL,0
        lda #E_NET
        sta err
        sec
        rts
@done:  lda MB_NETST
        cmp #1
        beq @ok
        jsr iprint
        .byte "wget: ",0
        ldx MB_NETST
        lda netmlo-2,x
        ldy netmhi-2,x
        jsr puts
        jsr crlf
        lda #E_NET
        sta err
        sec
        rts
@ok:    clc
        rts
netmlo: .lobytes n_2,n_3,n_4,n_5,n_6
netmhi: .hibytes n_2,n_3,n_4,n_5,n_6
n_2:    .byte "network or server error",0
n_3:    .byte "file too big",0
n_4:    .byte "not a file / not a directory",0
n_5:    .byte "refused by the firmware (in use?)",0
n_6:    .byte "unsupported url, or the pc is busy",0

; NET_DST from the destination argument (ap) or, if none, the current
; drive. C=1 + err if it can't be written to. Uses nbuf as the name.
net_dest:
        lda argc
        cmp #3
        bcs @arg
        lda cwd_drive           ; default: current drive + URL name
        bne :+
        jmp @h                  ; "h:" alone: the PC picks an 8.3 name
:       cmp #5
        bne @dn
        ldx #0                  ; "sd:" + sdcwd + "/" + name
:       lda s_sd,x
        sta NET_DST,x
        inx
        cpx #3
        bne :-
        ldy #0
:       lda sdcwd,y
        beq :+
        sta NET_DST,x
        inx
        iny
        bne :-
:       cpx #4                  ; sdcwd "/" or "": one slash only
        bne :+
        lda NET_DST+3
        cmp #'/'
        bne :+
        dex
:       lda #'/'
        sta NET_DST,x
        inx
        jmp @nm1
@dn:    sta t_drive             ; (no argument was resolved: use the cwd)
        jsr @d
        jmp @nm
@arg:   lda #2
        jsr getarg
        ldy #0
        lda (ap),y
        cmp #'-'
        bne :+
        iny
        lda (ap),y
        bne :+
        lda #'-'                ; "-": print it
        sta NET_DST
        lda #0
        sta NET_DST+1
        clc
        rts
:       jsr resolve
        bcs @r
        lda t_drive
        cmp #5
        bne @notsd
        jsr sd_need_rw
        bcs @r
        jsr sd_dest             ; sdappend = named a directory
        ldx #0
:       lda s_sd,x
        sta NET_DST,x
        inx
        cpx #3
        bne :-
        ldy #0
:       lda sddst,y
        beq :+
        sta NET_DST,x
        inx
        iny
        bne :-
:       lda sdappend
        beq @end
        cpx #4
        bne :+
        dex                     ; root: "sd:/" already ends with '/'
:       lda #'/'
        sta NET_DST,x
        inx
        jmp @nm1
@notsd: cmp #0
        bne :+
        jsr @h
        jmp @nmc
:       jsr @d
@nmc:   lda r_kind              ; a named entry -> its name, else the URL's
        beq @nm
        ldy #0
:       lda comp,y
        beq @end
        sta NET_DST,x
        inx
        iny
        bne :-
@nm:    ldx #0
@nmx:   lda NET_DST,x
        beq @nm1
        inx
        bne @nmx
@nm1:   ldy #0
:       lda nbuf,y
        sta NET_DST,x
        beq @end
        inx
        iny
        bne :-
@end:   lda #0
        sta NET_DST,x
        clc
@r:     rts
@h:     lda #'h'
        sta NET_DST
        lda #':'
        sta NET_DST+1
        lda #0
        sta NET_DST+2
        ldx #2
        rts
@d:     lda #'d'
        sta NET_DST
        lda t_drive
        ora #'0'
        sta NET_DST+1
        lda #':'
        sta NET_DST+2
        lda #0
        sta NET_DST+3
        ldx #3
        clc
        rts
s_sd:   .byte "sd:"

; after a successful fetch delivered to /HDD (MB_NETDEST = 1): copy it to
; NET_DST unless that is h:, print it for "-", then remove it from /HDD.
; Done by synthesising a command line and reusing cp / cat / rm.
net_finish:
        lda MB_NETDEST
        cmp #1
        bne @count
        lda NET_DST
        cmp #'h'
        beq @count
        cmp #'-'
        beq @cat
        jsr @args               ; argbuf = "cp" 0 "h:NAME" 0 NET_DST 0
        jsr cp_core             ; (prints the byte count itself)
        jsr @args
        lda #1
        jsr getarg
        jsr resolve
        jsr h_lookup
        bcs :+
        lda #33
        jsr h_xio
:       rts
@cat:   jsr @args
        lda #<argbuf
        clc
        adc argv+1
        sta ap
        lda #>argbuf
        adc #0
        sta ap+1
        jsr open_file
        bcs @rm
        jsr cat_stream
@rm:    jsr @args
        lda #1
        jsr getarg
        jsr resolve
        jsr h_lookup
        bcs @count
        lda #33
        jsr h_xio
@count: lda MB_NETLEN
        sta num
        lda MB_NETLEN+1
        sta num+1
        lda MB_NETLEN+2
        sta num+2
        jsr pdec0
        jsr iprint
        .byte " bytes",EOL,0
        rts
@args:  ldx #0                  ; argv: 0 "x" 1 "h:NAME" 2 NET_DST
        lda #'x'
        sta argbuf
        lda #0
        sta argbuf+1
        sta argv
        lda #2
        sta argv+1
        lda #'h'
        sta argbuf+2
        lda #':'
        sta argbuf+3
        ldx #4
        ldy #0
:       lda MB_NETNAME,y
        sta argbuf,x
        beq :+
        inx
        iny
        bne :-
:       inx
        stx argv+2
        ldy #0
:       lda NET_DST,y
        sta argbuf,x
        beq :+
        inx
        iny
        bne :-
:       lda #3
        sta argc
        rts

; ---- commands -------------------------------------------------------------------
; wget URL [dest|-]
cmd_wget:
        lda argc
        cmp #2
        bcs :+
        jmp usage
:       lda #1
        jsr getarg
        jsr is_url
        bcs :+
        jmp usage
:       jsr net_url
        jsr net_dest
        bcs @e
        lda #1
        jsr net_wait
        bcs @r
        jmp net_finish
@e:     jmp perr
@r:     rts

; URL as the source of cat/run/cp: fetch into /HDD, then (ap) = "h:NAME"
; for the normal path. C=1 on failure (reported).
net_fetch_h:
        jsr net_url
        lda #'h'                ; "h:" alone: the PC picks an 8.3 name
        sta NET_DST
        lda #':'
        sta NET_DST+1
        lda #0
        sta NET_DST+2
        lda #1
        jsr net_wait
        bcs @r
        lda #'h'                ; the file is h:<MB_NETNAME> now
        sta pathbuf
        lda #':'
        sta pathbuf+1
        ldx #0
:       lda MB_NETNAME,x
        sta pathbuf+2,x
        beq :+
        inx
        bne :-
:       lda #<pathbuf
        sta ap
        lda #>pathbuf
        sta ap+1
        clc
@r:     rts

; remove the file a URL fetch left in /HDD (h:<MB_NETNAME>)
net_rm_tmp:
        jsr h_name0
        ldx #0
:       lda MB_NETNAME,x
        sta namebuf,x
        beq :+
        inx
        bne :-
:       lda #33
        jmp h_xio

; ls URL: a directory listing from the PC, as text in RAM
net_ls: jsr net_url
        lda #2
        jsr net_wait
        bcs @r
        lda MB_NETDEST
        cmp #2
        bne @bad
        lda #<NET_TEXT
        sta k_rptr
        lda #>NET_TEXT
        sta k_rptr+1
        lda MB_NETLEN
        sta k_rrem
        lda MB_NETLEN+1
        sta k_rrem+1
        lda #$FF
        sta k_dev
        jsr st_reset
        jmp sd_list_lines
@bad:   lda #E_NET
        sta err
        sec
@r:     rts
