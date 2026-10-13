; ===========================================================================
; editor.s — `edit FILE`: a small full-screen text editor.
;
; The text lives at ETEXT as one byte stream with EOL ($9B) between lines
; (16 KB max). Every variable is an absolute pointer into it: cur (cursor),
; top (first line shown), eend (one past the last byte). The screen is
; redrawn from scratch after every key: row 0 = status, rows 1-23 = text,
; with horizontal scrolling (xoff) for long lines.
;
;   arrows move, typing inserts, Backspace / Ctrl-Delete delete a char,
;   Shift-Delete or Ctrl-K kill the line, Tab indents, Ctrl-A / Ctrl-E
;   go to start / end of line, Ctrl-S saves, Ctrl-Q quits.
; ===========================================================================
ETEXT   = $6700
EMAX    = $4000
EROWS   = 23
SAVMSC  = $58

; zero-page 16-bit inc/dec without labels (labels would end a cheap-label scope)
.macro  inc16 p
        inc p
        bne *+4
        inc p+1
.endmacro
.macro  dec16 p
        lda p
        bne *+4
        dec p+1
        dec p
.endmacro

cmd_edit:
        lda argc
        cmp #2
        bcs :+
        jmp usage
:       lda #1
        jsr getarg
        jsr resolve
        bcs @perr
        lda r_kind
        bne :+
        lda #E_ISDIR
        sta err
@perr:  jmp perr
:       ldx #CWSIZE             ; remember where the file lives (dcw + ename)
:       lda tcw-1,x
        sta dcw-1,x
        dex
        bne :-
        ldx #0
:       lda comp,x
        sta ename,x
        beq :+
        inx
        cpx #15
        bcc :-
:       lda #0
        sta ename+15
        sta emod
        sta eunix
        sta xoff
        sta eask
        sta emsg+1
        lda #<ETEXT
        sta eend
        sta cur
        sta top
        lda #>ETEXT
        sta eend+1
        sta cur+1
        sta top+1
        jsr open_file
        bcc @load
        lda err
        cmp #E_NOENT            ; a new file
        beq e_main
        jmp perr
@load:  jsr k_getbyte
        bcs @ldone
        cmp #$0D
        beq @load
        cmp #$09
        bne :+
        lda #' '
:       cmp #$0A
        bne :+
        sta eunix               ; keep Unix line endings on save
        lda #EOL
:       ldy #0
        sta (eend),y
        inc16 eend
        lda eend+1
        cmp #>(ETEXT+EMAX)
        bcc @load
@ldone: jsr stream_end
        lda #0
        sta mcol

e_main: jsr e_draw
e_key:  jsr getkey
        cpy #128
        beq e_quit
        ldx eask                ; after the unsaved warning only ^Q quits
        beq :+
        cmp #$11
        beq e_quit
        ldx #0
        stx eask
:       ldx #0
        stx emsg+1
        sta tmp
        ldx #0
@f:     lda ekeys,x
        beq @chr
        cmp tmp
        beq @go
        inx
        bne @f
@go:    lda eklo,x
        sta ptr
        lda ekhi,x
        sta ptr+1
        jmp (ptr)
@chr:   lda tmp
        and #$7F                ; inverse-video key: plain text anyway
        cmp #$20
        bcc e_key
        cmp #$7D
        bcs e_key
e_insert:
        lda tmp
        jsr e_ins
        jmp e_main
e_saveq:
        jsr e_save
        jmp e_main
e_quitq:
        lda emod
        beq e_quit
        lda #1
        sta eask
        lda #<s_unsaved
        sta emsg
        lda #>s_unsaved
        sta emsg+1
        jmp e_main
e_quit: lda #$7D
        jsr putc
        jmp more_reset

e_left: jsr e_atstart
        beq e_nop
        dec16 cur
e_nop:  jmp e_main
e_right:
        jsr e_atend
        beq e_nop
        inc16 cur
        jmp e_main
e_bs:   jsr e_atstart
        beq e_nop
        dec16 cur
e_delc: jsr e_atend
        beq e_nop
        jsr e_del
        jmp e_main
e_home: jsr e_lstart
        lda tp
        sta cur
        lda tp+1
        sta cur+1
        jmp e_main
e_eol:  jsr e_lend
        lda tp
        sta cur
        lda tp+1
        sta cur+1
        jmp e_main
e_kill: jsr e_lstart            ; delete from line start through its EOL
        lda tp
        sta cur
        lda tp+1
        sta cur+1
@l:     jsr e_atend
        beq e_nop
        ldy #0
        lda (cur),y
        pha
        jsr e_del
        pla
        cmp #EOL
        bne @l
        jmp e_main
e_tab:  lda #' '                ; spaces to the next multiple of 4
        jsr e_ins
        jsr e_col
        and #3
        bne e_tab
        jmp e_main

e_up:   jsr e_col
        sta tmp                 ; column to keep
        jsr e_lstart
        lda tp
        cmp #<ETEXT
        bne :+
        lda tp+1
        cmp #>ETEXT
        bne :+
e_nop2: jmp e_main              ; first line
:       dec16 tp                ; onto the previous line's EOL
        lda tp
        sta tmp2                ; (its end)
        lda tp+1
        sta tmp3
        jsr e_lstart_tp
        jmp e_tocol
e_down: jsr e_col
        sta tmp
        jsr e_lend
        jsr e_tpend
        beq e_nop2              ; last line
        inc16 tp
        lda tp
        pha
        lda tp+1
        pha
        jsr e_lend_tp
        lda tp
        sta tmp2
        lda tp+1
        sta tmp3
        pla
        sta tp+1
        pla
        sta tp
; tp = line start, tmp2/3 = its end, tmp = wanted column -> cur
e_tocol:
        lda tmp2
        sec
        sbc tp
        tax
        lda tmp3
        sbc tp+1
        beq :+
        ldx #$FF                ; (lines over 255 chars: clamp)
:       cpx tmp
        bcs :+
        stx tmp
:       lda tp
        clc
        adc tmp
        sta cur
        lda tp+1
        adc #0
        sta cur+1
        jmp e_main

; ---- buffer primitives -------------------------------------------------------
e_atstart:                      ; Z=1 if cur is at the start of the text
        lda cur
        cmp #<ETEXT
        bne :+
        lda cur+1
        cmp #>ETEXT
:       rts
e_atend:                        ; Z=1 if cur == eend
        lda cur
        cmp eend
        bne :+
        lda cur+1
        cmp eend+1
:       rts
e_tpend:                        ; Z=1 if tp == eend
        lda tp
        cmp eend
        bne :+
        lda tp+1
        cmp eend+1
:       rts
e_tplt:                         ; C=0 if tp < eend
        lda tp+1
        cmp eend+1
        bcc :+
        bne :+
        lda tp
        cmp eend
:       rts

; tp = start of the line holding cur
e_lstart:
        lda cur
        sta tp
        lda cur+1
        sta tp+1
e_lstart_tp:
@l:     lda tp
        cmp #<ETEXT
        bne :+
        lda tp+1
        cmp #>ETEXT
        beq @d
:       dec16 tp
        ldy #0
        lda (tp),y
        cmp #EOL
        bne @l
        inc16 tp
@d:     rts

; tp = end of the line holding cur (its EOL, or eend)
e_lend: lda cur
        sta tp
        lda cur+1
        sta tp+1
e_lend_tp:
@l:     jsr e_tpend
        beq @d
        ldy #0
        lda (tp),y
        cmp #EOL
        beq @d
        inc16 tp
        bne @l
@d:     rts

; tp = start of the line after the one at tp (or eend)
e_next: jsr e_lend_tp
        jsr e_tpend
        beq :+
        inc16 tp
:       rts

; A = column of cur within its line (clamped to 255)
e_col:  jsr e_lstart
        lda cur
        sec
        sbc tp
        tax
        lda cur+1
        sbc tp+1
        beq :+
        ldx #$FF
:       txa
        rts

; insert A at cur
e_ins:  ldx eend+1
        cpx #>(ETEXT+EMAX)
        bcc :+
        lda #$FD                ; full: bell
        jmp putc
:       pha
        lda eend                ; cnt = eend - cur
        sec
        sbc cur
        sta cnt
        lda eend+1
        sbc cur+1
        sta cnt+1
        lda eend
        sta tp
        lda eend+1
        sta tp+1
@m:     lda cnt
        ora cnt+1
        beq @put
        dec16 tp
        ldy #0
        lda (tp),y
        iny
        sta (tp),y
        lda cnt
        bne :+
        dec cnt+1
:       dec cnt
        jmp @m
@put:   pla
        ldy #0
        sta (cur),y
        inc16 cur
        inc16 eend
        lda #1
        sta emod
        rts

; delete the byte at cur (cur < eend)
e_del:  lda eend                ; cnt = eend - cur - 1
        sec
        sbc cur
        sta cnt
        lda eend+1
        sbc cur+1
        sta cnt+1
        dec16 cnt
        lda cur
        sta tp
        lda cur+1
        sta tp+1
@m:     lda cnt
        ora cnt+1
        beq @d
        ldy #1
        lda (tp),y
        dey
        sta (tp),y
        inc16 tp
        lda cnt
        bne :+
        dec cnt+1
:       dec cnt
        jmp @m
@d:     dec16 eend
        lda #1
        sta emod
        rts

; ---- drawing ----------------------------------------------------------------
e_draw: lda SAVMSC
        sta scr
        lda SAVMSC+1
        sta scr+1
        jsr e_lstart            ; cls = cursor line start
        lda tp
        sta cls
        lda tp+1
        sta cls+1
        lda cur+1               ; cursor above the window? window = its line
        cmp top+1
        bcc @settop
        bne @rows
        lda cur
        cmp top
        bcs @rows
@settop:
        lda cls
        sta top
        lda cls+1
        sta top+1
@rows:  lda #0                  ; row = lines from top to cls, scrolling top
        sta erow                ; down so the cursor stays inside
        lda top
        sta tp
        lda top+1
        sta tp+1
@rl:    lda tp+1
        cmp cls+1
        bcc @adv
        bne @rdone
        lda tp
        cmp cls
        bcs @rdone
@adv:   jsr e_next
        lda erow
        cmp #EROWS-1
        bcc @inc
        lda tp                  ; window full: slide top one line
        pha
        lda tp+1
        pha
        lda top
        sta tp
        lda top+1
        sta tp+1
        jsr e_next
        lda tp
        sta top
        lda tp+1
        sta top+1
        pla
        sta tp+1
        pla
        sta tp
        jmp @rl
@inc:   inc erow
        bne @rl
@rdone: jsr e_col
        sta ecol
        cmp xoff
        bcs :+
        sta xoff
:       sec
        sbc xoff
        cmp #40
        bcc :+
        lda ecol
        sec
        sbc #39
        sta xoff
:       jsr e_status
        lda top
        sta tp
        lda top+1
        sta tp+1
        lda #EROWS
        sta tmp2
@dr:    lda scr                 ; next screen row
        clc
        adc #40
        sta scr
        bcc :+
        inc scr+1
:       jsr e_row
        dec tmp2
        bne @dr
        lda SAVMSC              ; cursor cell = row+1, col-xoff
        sta scr
        lda SAVMSC+1
        sta scr+1
        ldx erow
        inx
:       lda scr
        clc
        adc #40
        sta scr
        bcc :+
        inc scr+1
:       dex
        bne :--
        lda ecol
        sec
        sbc xoff
        tay
        lda (scr),y
        eor #$80
        sta (scr),y
        rts

; draw the line at tp on screen row (scr), then tp = next line start
e_row:  ldx xoff
@skip:  beq @draw
        jsr e_tpend
        beq @draw
        ldy #0
        lda (tp),y
        cmp #EOL
        beq @draw
        inc16 tp
        dex
        bne @skip
@draw:  ldy #0
@c:     jsr e_tpend
        beq @sp
        sty tmp3
        ldy #0
        lda (tp),y
        ldy tmp3
        cmp #EOL
        beq @sp
        jsr a2s
        sta (scr),y
        inc16 tp
        jmp @n
@sp:    lda #0
        sta (scr),y
@n:     iny
        cpy #40
        bne @c
        jmp e_next

; ATASCII -> screen code (inverse bit kept)
a2s:    pha
        and #$7F
        cmp #$20
        bcc @ctl
        cmp #$60
        bcs @k
        sec
        sbc #$20
        jmp @k
@ctl:   clc
        adc #$40
@k:     sta tmp
        pla
        and #$80
        ora tmp
        rts

; row 0: " name*          message / help", inverse
e_status:
        ldy #39
        lda #$80
:       sta (scr),y
        dey
        bpl :-
        ldy #1
        ldx #0
@n:     lda ename,x
        beq @m
        jsr a2s
        ora #$80
        sta (scr),y
        iny
        inx
        bne @n
@m:     lda emod
        beq :+
        lda #'*'-$20+$80
        sta (scr),y
:       lda emsg+1
        bne @msg
        lda #<s_ehelp
        sta emsg
        lda #>s_ehelp
        sta emsg+1
@msg:   ldy #0                  ; right-aligned: start at 40 - length
:       lda (emsg),y
        beq :+
        iny
        bne :-
:       tya
        eor #$FF
        clc
        adc #41
        sta tmp2
        lda scr
        pha
        clc
        adc tmp2
        sta scr
        bcc :+
        inc scr+1
:       ldy #0
@cp:    lda (emsg),y
        beq @done
        jsr a2s
        ora #$80
        sta (scr),y
        iny
        bne @cp
@done:  pla
        sta scr
        lda SAVMSC+1
        sta scr+1
        rts

e_setmsg:
        sta emsg
        sty emsg+1
        rts

e_save: ldx #CWSIZE
:       lda dcw-1,x
        sta tcw-1,x
        dex
        bne :-
        ldx #0
:       lda ename,x
        sta comp,x
        beq :+
        inx
        bne :-
:       lda #1
        sta wquiet
        jsr w_open
        bcs @fail
        lda #<ETEXT
        sta tp
        lda #>ETEXT
        sta tp+1
@l:     jsr e_tpend
        beq @close
        ldy #0
        lda (tp),y
        cmp #EOL
        bne :+
        ldx eunix
        beq :+
        lda #$0A
:       jsr w_put
        bcs @fail
        inc16 tp
        bne @l
@close: jsr w_close
        bcs @fail
        lda #0
        sta emod
        lda #<s_saved
        ldy #>s_saved
        jmp e_setmsg
@fail:  jsr w_close
        lda #<s_sfail
        ldy #>s_sfail
        jmp e_setmsg

ekeys:  .byte $9B,$1C,$1D,$1E,$1F,$7E,$FE,$9C,$0B,$13,$11,$01,$05,$7F,0
.define EKH e_insert,e_up,e_down,e_left,e_right,e_bs,e_delc,e_kill,e_kill,e_saveq,e_quitq,e_home,e_eol,e_tab
eklo:   .lobytes EKH
ekhi:   .hibytes EKH
s_ehelp:  .byte "^S save ^Q quit",0
s_saved:  .byte "saved",0
s_sfail:  .byte "save failed",0
s_unsaved:.byte "unsaved! ^Q quits",0
