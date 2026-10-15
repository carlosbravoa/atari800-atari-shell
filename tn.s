; ===========================================================================
; tn.s — ASH-TN: the Tang Nano 20K build (assembled with -D TN).
;
; The PC link can peek/poke Atari RAM, so ASH-TN keeps a mailbox in page 6
; through which a PC program (tools/ashterm.py) drives the shell without
; keystroke injection: it pokes a command line, ASH runs it exactly as if
; typed and mirrors every byte of output into a RAM buffer the PC peeks.
;
;   $0640 MB_MAGIC  "AS" — ASH-TN is running
;   $0642 MB_VER    mailbox protocol version (1)
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
;   $0660 MB_CMD    command line, 0-terminated, up to 79 chars
;   $06B0 MB_PROMPT current path ("d1:/games"), 0-terminated, ≤ 31 chars
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
MB_PROMPT = $06B0
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
        lda #1
        sta MB_VER
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
        cpy #31
        bcc :+
        ldy #31
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
@prm:   ldx obn                 ; prompt: 31 chars
        cpx #31
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
