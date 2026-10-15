; ===========================================================================
; tn.s — ASH-TN: the Tang Nano 20K build (assembled with -D TN).
;
; The PC link can peek/poke Atari RAM, so ASH-TN keeps a mailbox in page 6
; through which a PC program (tools/ashterm.py) drives the shell without
; keystroke injection: it pokes a command line, ASH runs it exactly as if
; typed and mirrors every byte of output into a RAM buffer the PC peeks.
;
;   $0640 MB_MAGIC  "AS" — ASH-TN is running
;   $0642 MB_VER    mailbox protocol version (2: 111-char commands, prompt at $06E8)
;   $0643 MB_CMDREQ PC sets 1 after writing MB_CMD; ASH clears it when done
;   $0644 MB_STATUS 0 running, 1 done, 2 done with error, 3 program launched
;   $0645 MB_ERR    ASH error code (E_*), 0 = none
;   $0646 MB_CIOERR CIO status of the last D: error, 0 = none
;   $0647 MB_OUTLO/HI  output buffer address      ($7800)
;   $0649 MB_CAPLO/HI  its size                   ($0800)
;   $064B MB_LENLO/HI  bytes of output so far (ASH updates as it prints)
;   $064D MB_SEQ    incremented when a command finishes
;   $064E MB_PING   ASH increments to ask "is the PC there?"
;   $064F MB_PONG   the PC copies MB_PING here
;   $0650 MB_ABORT  PC sets 1 to cancel the running command (like BREAK)
;   $0651 MB_RAMLO/HI  getw: bytes in the RAM window ($8000, 16 KB)
;   $0653 MB_MORE   getw: 1 = the file continues (call `getw` again)
;   $0660 MB_CMD    command line, 0-terminated, up to 111 chars ($0660-$06CF)
;   $06D0 MB_NET*   network request/result (net.s)
;   $06E8 MB_PROMPT current path ("D1:/games"), 0-terminated, ≤ 23 chars
; The mailbox is only serviced while ASH waits for a key at its prompt.
; ===========================================================================
MB_MAGIC  = $0640
MB_VER    = $0642
MB_CMDREQ = $0643
MB_STATUS = $0644
MB_ERR    = $0645
MB_CIOERR = $0646
MB_OUT    = $0647
MB_CAP    = $0649
MB_LEN    = $064B
MB_SEQ    = $064D
MB_PING   = $064E
MB_PONG   = $064F
MB_ABORT  = $0650
MB_RAM    = $0651
MB_MORE   = $0653
MB_CMD    = $0660
MB_PROMPT = $06E8
OBUF      = $7800               ; command output mirror (TN: below the getw window)
OBCAP     = $0800
RAMWIN    = $8000               ; getw window
RAMWSIZE  = $4000
CH        = $02FC

; power-on: announce ourselves, idle state
mb_init:
        lda #'A'
        sta MB_MAGIC
        lda #'S'
        sta MB_MAGIC+1
        lda #2
        sta MB_VER
        lda #1
        sta MB_STATUS
        lda #0
        sta MB_CMDREQ
        sta MB_ERR
        sta MB_CIOERR
        sta MB_ABORT
        sta MB_PING
        sta MB_PONG
        sta MB_SEQ
        sta MB_LEN
        sta MB_LEN+1
        sta mirror
        sta mbrun
        lda #<OBUF
        sta MB_OUT
        lda #>OBUF
        sta MB_OUT+1
        lda #<OBCAP
        sta MB_CAP
        lda #>OBCAP
        sta MB_CAP+1
        rts

; top of the main loop: finish a mailbox command (status, sequence)
mb_done:
        lda mbrun
        beq @r
        lda #0
        sta mbrun
        sta mirror
        sta MB_CMDREQ
        lda err
        sta MB_ERR
        lda cioerr
        sta MB_CIOERR
        ldx #1
        ora err
        beq :+
        ldx #2
:       stx MB_STATUS
        inc MB_SEQ
@r:     rts

; before the prompt: current path -> MB_PROMPT (sink mode: no screen output)
mb_prompt:
        lda #<MB_PROMPT
        sta obp
        lda #>MB_PROMPT
        sta obp+1
        lda #0
        sta obn
        sta obn+1
        lda #2
        sta mirror
        jsr print_path
        lda #0
        sta mirror
        ldy obn
        cpy #23
        bcc :+
        ldy #23
:       sta MB_PROMPT,y
        rts

; waiting for a key at the prompt: service the mailbox meanwhile.
; -> like getkey: A = key, Y = status (128 = BREAK); or a whole line
; taken from the mailbox, returned as RETURN.
mb_getkey:
@w:     lda MB_CMDREQ
        bne @mb
        lda BRKKEY
        beq @brk
        lda CH
        cmp #$FF
        beq @w
        jmp getkey
@brk:   lda #$FF
        sta BRKKEY
        ldy #128
        rts
@mb:    jsr erase_line          ; anything half-typed goes
        ldx #0
@cp:    lda MB_CMD,x
        beq @end
        cpx #MAXLEN
        bcs @end
        sta linebuf,x
        jsr putc                ; echo on the TV
        inx
        bne @cp
@end:   stx len
        lda #1
        sta mbrun
        lda #0
        sta MB_STATUS           ; running
        sta MB_LEN
        sta MB_LEN+1
        sta MB_ABORT
        sta obn
        sta obn+1
        lda MB_OUT
        sta obp
        lda MB_OUT+1
        sta obp+1
        lda #1
        sta mirror
        lda #EOL
        ldy #1
        rts

; output mirror: called by outc with the byte in A (X/Y free)
mb_out: ldx mirror
        cpx #1
        bne @prm
        ldx obn                 ; command output: bounded by MB_CAP
        cpx MB_CAP
        lda obn+1
        sbc MB_CAP+1
        bcs @r
        bcc @st
@prm:   ldx obn                 ; prompt: 23 chars
        cpx #23
        bcs @r
@st:    ldy #0
        lda tmp
        sta (obp),y
        inc obp
        bne :+
        inc obp+1
:       inc obn
        bne :+
        inc obn+1
:       lda mirror
        cmp #1
        bne @r
        lda obn
        sta MB_LEN
        lda obn+1
        sta MB_LEN+1
@r:     rts

; ---- pc: is the PC program there? --------------------------------------------
; C=1 if the PC answered the ping within ~2 s (also prints nothing).
pc_ping:
        inc MB_PING
        lda RTCLOK+1
        sta tmp3
@w:     lda MB_PONG
        cmp MB_PING
        beq @yes
        lda RTCLOK+1
        sec
        sbc tmp3
        cmp #1                  ; 256 jiffies ≈ 4 s worst case, 2 s typical
        bcc @w
        clc
        rts
@yes:   sec
        rts

cmd_pc: jsr pc_ping
        bcs pc_ok
pc_fail:
        jsr iprint
        .byte "pc link: no answer from the pc.",EOL
        .byte "connect the board to the pc with the",EOL
        .byte "usb cable and run ashterm there.",EOL,0
        clc
        rts
pc_ok:  jsr iprint
        .byte "pc link: ashterm is connected",EOL,0
        sec
        rts

; ---- getw [FILE]: next 16 KB of a file -> RAM window, for ashterm get ----------
cmd_getw:
        lda argc
        cmp #2
        bcc @cont
        jsr open_arg1
        bcs @r
@cont:  lda #<RAMWIN
        sta ptr
        lda #>RAMWIN
        sta ptr+1
        lda #0
        sta MB_RAM
        sta MB_RAM+1
        sta MB_MORE
@l:     jsr k_getbyte
        bcs @eof
        ldy #0
        sta (ptr),y
        inc ptr
        bne :+
        inc ptr+1
:       inc MB_RAM
        bne :+
        inc MB_RAM+1
:       lda ptr+1
        cmp #>(RAMWIN+RAMWSIZE)
        bcc @l
        lda #1                  ; window full, file continues
        sta MB_MORE
        bne @rep
@eof:   jsr stream_end
@rep:   lda MB_RAM
        sta num
        lda MB_RAM+1
        sta num+1
        lda #0
        sta num+2
        jsr pdec0
        jsr iprint
        .byte " bytes in window",EOL,0
@r:     rts

; ---- date [sync]: the PC's clock, then RTCLOK keeps it running ------------------
MB_TIMEREQ = $0654
MB_TIME    = $0655              ; yy mm dd hh mm ss (binary, local, yy = year-2000)

cmd_date:
        lda argc
        cmp #2
        bcc :+
        lda #0                  ; any argument ("sync"): ask again
        sta tsynced
:       lda tsynced
        bne @show
        lda #1
        sta MB_TIMEREQ
        lda RTCLOK+1
        sta tmp3
@w:     lda MB_TIMEREQ
        beq @got
        lda RTCLOK+1
        sec
        sbc tmp3
        cmp #1                  ; ~2-4 s
        bcc @w
        lda #0
        sta MB_TIMEREQ
        jmp pc_fail
@got:   ldx #5
:       lda MB_TIME,x
        sta tbase,x
        dex
        bpl :-
        lda RTCLOK
        sta tjif
        lda RTCLOK+1
        sta tjif+1
        lda RTCLOK+2
        sta tjif+2
        lda #1
        sta tsynced
@show:  jsr t_advance
        jsr iprint
        .byte "20",0
        lda tbase
        jsr t_2d
        lda #'-'
        jsr outc
        lda tbase+1
        jsr t_2d
        lda #'-'
        jsr outc
        lda tbase+2
        jsr t_2d
        lda #' '
        jsr outc
        lda tbase+3
        jsr t_2d
        lda #':'
        jsr outc
        lda tbase+4
        jsr t_2d
        lda #':'
        jsr outc
        lda tbase+5
        jsr t_2d
        jmp crlf

t_2d:   cmp #10                 ; two decimal digits, zero-padded
        bcs :+
        pha
        lda #'0'
        jsr outc
        pla
:       jsr num8
        jmp pdec0

; fold the jiffies since the sync into tbase, 60 at a time (NTSC)
t_advance:
@l:     lda RTCLOK+2            ; elapsed = RTCLOK - tjif (24-bit, hi..lo = $12..$14)
        sec
        sbc tjif+2
        sta cnt
        lda RTCLOK+1
        sbc tjif+1
        sta cnt+1
        lda RTCLOK
        sbc tjif
        bne @tick               ; ≥ 65536 jiffies: certainly ≥ 60
        lda cnt+1
        bne @tick
        lda cnt
        cmp #60
        bcs @tick
        rts
@tick:  lda tjif+2              ; tjif += 60
        clc
        adc #60
        sta tjif+2
        bcc :+
        inc tjif+1
        bne :+
        inc tjif
:       inc tbase+5             ; seconds
        lda tbase+5
        cmp #60
        bcs :+
        jmp @l
:
        lda #0
        sta tbase+5
        inc tbase+4
        lda tbase+4
        cmp #60
        bcs :+
        jmp @l
:
        lda #0
        sta tbase+4
        inc tbase+3
        lda tbase+3
        cmp #24
        bcs :+
        jmp @l
:
        lda #0
        sta tbase+3
        inc tbase+2             ; day
        ldx tbase+1             ; days in this month (Feb 29 in leap years)
        lda mdays-1,x
        cpx #2
        bne :+
        ldy tbase
        tya
        and #3
        bne :+
        lda #29
:       cmp tbase+2
        bcc :+
        jmp @l
:
        lda #1
        sta tbase+2
        inc tbase+1
        lda tbase+1
        cmp #13
        bcs :+
        jmp @l
:
        lda #1
        sta tbase+1
        inc tbase
        jmp @l

mdays:  .byte 31,28,31,30,31,30,31,31,30,31,30,31
