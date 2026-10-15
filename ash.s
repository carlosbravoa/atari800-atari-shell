; ===========================================================================
; ASH — the Atari SHell.
;
; A Unix-flavoured command line for the Atari 8-bit, replacing the DOS menu:
; browse DOS 2.x / MyDOS disks on D1:-D4: and the SD card's /HDD folder (H:,
; the Tang Nano board's SIO file device) and launch .xex programs directly.
; No DOS is loaded — directories and files are read sector by sector over
; SIO, and a 256-byte resident kernel at $0700 streams the executable in.
;
; Memory: see ash.cfg. ZP $80-$BF is ours (BASIC is switched off for good).
; ===========================================================================
        .setcpu "6502"
        .import __KERNEL_LOAD__, __KERNEL_RUN__, __KERNEL_SIZE__
        .import __MAIN_START__, __MAIN_LAST__

; ---- OS -------------------------------------------------------------------
CIOV    = $E456
SIOV    = $E459
COLDSV  = $E477
BOOTQ   = $09
DOSVEC  = $0A
DOSINI  = $0C
BRKKEY  = $11
RTCLOK  = $12
LMARGN  = $52
RAMTOP  = $6A
COLDST  = $0244
INVFLG  = $02B6
SHFLOK  = $02BE
COLOR0  = $02C4
COLOR1  = $02C5
COLOR2  = $02C6
COLOR3  = $02C7
COLOR4  = $02C8
RUNAD   = $02E0
INITAD  = $02E2
MEMLO   = $02E7
BASICF  = $03F8
PORTB   = $D301
DDEVIC  = $0300
DUNIT   = $0301
DCOMND  = $0302
DSTATS  = $0303
DBUFLO  = $0304
DBUFHI  = $0305
DTIMLO  = $0306
DBYTLO  = $0308
DBYTHI  = $0309
DAUX1   = $030A
DAUX2   = $030B
ICCOM   = $0342
ICBAL   = $0344
ICBAH   = $0345
ICBLL   = $0348
ICBLH   = $0349
ICAX1   = $034A
ICAX2   = $034B
BASICLO = $7800                 ; MEMLO for the `basic` command (above us)

.define VERSION "1.2"           ; one number for both editions (release tag v1.2.0)
.ifdef TN
.define EDITION " TN"
.else
.define EDITION ""
.endif
EOL     = $9B
MAXLEN  = 76                    ; input line (just under two screen rows)
MAXARGS = 8
MAXDIR  = 64
HHANDLE = 1                     ; our H: handle (0 is left to the H: handler)

E_NOENT = 1
E_NOTDIR= 2
E_IO    = 3
E_ISDIR = 4
E_NOEXEC= 5
E_DEEP  = 6
E_USAGE = 7
E_NUM   = 8
E_ROFS  = 9
E_NODEV = 10
E_SDRO  = 11
E_SDREF = 12
E_LONG  = 13

; ---- zero page --------------------------------------------------------------
        .zeropage
ptr:    .res 2
ap:     .res 2                  ; current argument / path string
dp:     .res 2                  ; current directory entry
spt:    .res 2                  ; string printer
mptr:   .res 2                  ; memory source for peek
num:    .res 3                  ; number in/out (24-bit)
scr:    .res 2                  ; editor: screen row
tp:     .res 2                  ; editor: text pointer
cnt:    .res 2
obp:    .res 2                  ; TN: output mirror pointer
cur:    .res 2                  ; editor: cursor, window top, text end
top:    .res 2
eend:   .res 2
cls:    .res 2
emsg:   .res 2

; ---- buffers -----------------------------------------------------------------
        .bss
dirtab: .res MAXDIR*16          ; loaded directory: raw 16-byte DOS entries
hist:   .res 8*80
linebuf:.res 80
argbuf: .res 80
pathbuf:.res 80
namebuf:.res 64                 ; H: name frame
argv:   .res MAXARGS
comp:   .res 28                 ; current path component (lowercase; sd: names up to 27)
nbuf:   .res 16                 ; formatted name "name.ext"
cbuf:   .res 28                 ; tab-completion candidate / cp destination name
hbuf:   .res 8
fnbuf:  .res 96                 ; "Dn:/path/NAME" for CIO
hwbuf:  .res 128                ; h: write frame
dcw:    .res 2+16+128           ; cp: destination directory (CWSIZE)
hwlen:  .res 1
xcmd:   .res 1
cioerr: .res 1
mirror: .res 1                  ; TN: 0 off, 1 command output, 2 prompt sink
mbrun:  .res 1
obn:    .res 2
hpresent: .res 1              ; the board's h: answered at boot
sdcwd:  .res 64                 ; TN: current sd: directory ("" = root)
sdpath: .res 64                 ; TN: resolved sd: path
lbuf:   .res 48                 ; TN: one listing line
sdstart: .res 2
sddst:  .res 64                 ; TN: cp/mv destination on the card
sdrw:   .res 1                  ; TN: the session write gate, as we last set it
sdappend: .res 1
wdev:   .res 1
wquiet: .res 1
ename:  .res 16                 ; editor state
emod:   .res 1
eunix:  .res 1
xoff:   .res 1
eask:   .res 1
erow:   .res 1
ecol:   .res 1
; working directory: drive (0 = H:, 1-4 = Dn:), depth, dir sector per level,
; name per level (16 bytes each, level 0 unused). `tcw` is the resolver's copy.
CWSIZE  = 2 + 16 + 128
cwd:    .res CWSIZE
tcw:    .res CWSIZE
cwd_drive = cwd
cwd_depth = cwd+1
cwd_dirs  = cwd+2
cwd_names = cwd+18
t_drive   = tcw
t_depth   = tcw+1
t_dirs    = tcw+2
t_names   = tcw+18
argc:   .res 1
len:    .res 1
hsel:   .res 1
hist_n: .res 1
hist_head: .res 1
err:    .res 1
term:   .res 1
ypos:   .res 1
r_kind: .res 1                  ; resolve: 0 = names a dir, 1 = names an entry
ndir:   .res 1
dc_valid: .res 1
dc_drive: .res 1
dc_sec: .res 2
ldrv:   .res 1
lsec:   .res 2
csec:   .res 2
dsec_n: .res 1
mcol:   .res 1
mlines: .res 1
abort:  .res 1
lflag:  .res 1
lcol:   .res 1
lcnt:   .res 1
lpath:  .res 2
fplen:  .res 1
fmatch: .res 1
clen:   .res 1
wstart: .res 1
pend:   .res 1
theme:  .res 1
tmp:    .res 1
tmp2:   .res 1
tmp3:   .res 1
pw:     .res 1
pn:     .res 1
fx:     .res 1
eb:     .res 1
sx:     .res 1
sy:     .res 1
sa:     .res 1
ox:     .res 1
oy:     .res 1
pl_i:   .res 1
hn:     .res 1
hoff:   .res 2
hsrc:   .res 1
hrem:   .res 2
df_d:   .res 1
fb0:    .res 1
ftext:  .res 1
fseg:   .res 1
fflag:  .res 1
fsz:    .res 3
fs:     .res 2
fe:     .res 2
fa:     .res 2
fr:     .res 2
fi:     .res 2
xi:     .res 1

; ===========================================================================
        .code
entry:  jmp start               ; $2000 cold entry (boot sector, deploy)
        jmp warm                ; $2003 warm entry (RESET, BASIC's DOS)

start:  cld
        ldx #$FF
        txs
        jsr machine_setup
        lda #<warm
        sta DOSVEC
        lda #>warm
        sta DOSVEC+1
        lda #<fms_init          ; RESET keeps D: alive
        sta DOSINI
        lda #>fms_init
        sta DOSINI+1
        lda BOOTQ
        ora #1                  ; "booted from disk": RESET comes back warm
        sta BOOTQ
        lda #0
        sta COLDST
        sta theme
        sta hpresent
        sta sdrw
        sta hist_n
        sta hist_head
        lda #<361
        sta cwd_dirs
        lda #>361
        sta cwd_dirs+1
        jsr screen_setup
.ifdef TN
        jsr mb_init
.endif
        jsr iprint
        .byte "ASH ", VERSION, EDITION, " - the Atari SHell", EOL
        .byte "Type help for commands or basic to exit", EOL, 0
        jsr pick_drive
        jmp mainloop

warm:   cld
        ldx #$FF
        txs
        jsr machine_setup
        jsr screen_setup
        ; fall through

mainloop:
        ldx #$FF
        txs
.ifdef TN
        jsr mb_done
        jsr mb_prompt
.endif
        lda #0
        sta dc_valid            ; disks may be swapped between commands
        sta err
        sta cioerr
        lda #$FF
        sta BRKKEY
        jsr more_reset
        jsr prompt
        jsr readline
        lda len
        beq mainloop
        lda mbrun               ; mailbox commands stay out of the history
        bne :+
        jsr hist_add
:       jsr tokenize
        lda argc
        beq mainloop
        jsr more_reset
        jsr dispatch
        lda mcol                ; never leave the prompt mid-line
        beq mainloop
        jsr crlf
        jmp mainloop

; BASIC off, RAM to $BFFF, resident kernel copied down to $0700.
machine_setup:
        lda PORTB
        ora #$02
        sta PORTB
        lda #1
        sta BASICF
        lda #$C0
        sta RAMTOP
        lda #<__KERNEL_LOAD__
        sta ptr
        lda #>__KERNEL_LOAD__
        sta ptr+1
        lda #<__KERNEL_RUN__
        sta ap
        lda #>__KERNEL_RUN__
        sta ap+1
        ldx #>(__KERNEL_SIZE__+255)
        ldy #0
:       lda (ptr),y
        sta (ap),y
        iny
        bne :-
        inc ptr+1
        inc ap+1
        dex
        bne :-
        lda #<fms_end
        sta k_memlo
        lda #>fms_end
        sta k_memlo+1
        lda #0
        sta v_dirty
        sta v_drv
        jmp fms_init

screen_setup:
        jsr close_all
        jsr open_screen
        lda #0
        sta LMARGN              ; full 40 columns
        sta INVFLG
        sta SHFLOK              ; lowercase, like a Unix terminal
        lda #$7D
        jsr putc                ; clear + home to the new margin
        jsr open_kbd
        jmp apply_theme

; first drive that answers: D1:, then D4: (the board's HDD.ATR), else H:
pick_drive:
        lda #$53                ; is the board's h: device there at all?
        jsr k_hcmd
        lda #4
        jsr k_sio
        bmi :+
        inc hpresent
:       ldx #1
        jsr dstat
        ldx #1
        bcc @ok
        ldx #4
        jsr dstat
        ldx #4
        bcc @ok
        ldx #0
        lda hpresent
        bne @ok
        ldx #1                  ; a real Atari with no disk in: d1: anyway
@ok:    stx cwd_drive
        lda #0
        sta cwd_depth
        rts

; ---- CIO ------------------------------------------------------------------
close_all:                      ; IOCB 1-7
        lda #$10
        sta tmp
@l:     ldx tmp
        lda #12
        sta ICCOM,x
        jsr CIOV
        lda tmp
        clc
        adc #$10
        sta tmp
        cmp #$80
        bcc @l
        rts

open_screen:
        ldx #$00
        lda #12
        sta ICCOM,x
        jsr CIOV
        ldx #$00
        lda #12                 ; E: read+write
        sta ICAX1,x
        lda #<s_edev
        ldy #>s_edev
        jmp open_x
open_kbd:
        ldx #$10
        lda #12
        sta ICCOM,x
        jsr CIOV
        ldx #$10
        lda #4                  ; K: read
        sta ICAX1,x
        lda #<s_kdev
        ldy #>s_kdev
open_x: sta ICBAL,x
        tya
        sta ICBAH,x
        lda #3
        sta ICCOM,x
        lda #0
        sta ICAX2,x
        jmp CIOV

; A = char to E:. Preserves A, X, Y.
putc:   sta sa
        stx sx
        sty sy
        ldx #0
        stx ICBLL
        stx ICBLH
        ldy #$0B
        sty ICCOM
        jsr CIOV
        lda sa
        ldx sx
        ldy sy
        rts

; -> A = key, Y = status (128 = BREAK)
getkey: ldx #$10
        lda #7
        sta ICCOM,x
        lda #0
        sta ICBLL,x
        sta ICBLH,x
        jmp CIOV

; ---- paged output -----------------------------------------------------------
more_reset:
        lda #0
        sta mcol
        sta mlines
        sta abort
        rts

crlf:   lda #EOL
; A = char, counted for the pager. Preserves A, X, Y.
outc:   stx ox
        sty oy
.ifdef TN
        sta tmp
        ldx mirror
        beq @scr
        jsr mb_out
        lda mirror
        cmp #2                  ; sink mode: no screen output at all
        beq @r
        lda tmp
.endif
@scr:   jsr putc
        cmp #EOL
        beq @nl
        inc mcol
        ldx mcol
        cpx #40
        bcc @r
@nl:    ldx #0
        stx mcol
        inc mlines
        ldx mlines
        cpx #23
        bcc @r
.ifdef TN
        ldx mbrun               ; the PC reads it all: never page
        bne @r
.endif
        pha
        jsr more_wait
        pla
@r:     ldx ox
        ldy oy
        rts

more_wait:
        ldx #0
@p:     lda s_more,x
        jsr putc
        inx
        cpx #10
        bne @p
        jsr getkey
        pha
        lda #$9C                ; delete the prompt line
        jsr putc
        pla
        cpy #128
        beq @q
        ora #$20
        cmp #'q'
        beq @q
        ldx #0
        cmp #$9B|$20            ; RETURN: one more line
        bne @pg
        ldx #22
@pg:    stx mlines
        rts
@q:     lda #1
        sta abort
        lda #0
        sta mlines
        rts

chk_break:                      ; BREAK during long output -> abort
.ifdef TN
        lda MB_ABORT            ; (or the PC's kill switch)
        beq :+
        lda #1
        sta abort
:
.endif
        lda BRKKEY
        bne :+
        lda #$FF
        sta BRKKEY
        lda #1
        sta abort
:       rts

; print the zero-terminated string that follows the JSR
iprint: pla
        sta spt
        pla
        sta spt+1
        ldy #0
@l:     inc spt
        bne :+
        inc spt+1
:       lda (spt),y
        beq @d
        jsr outc
        jmp @l
@d:     lda spt+1
        pha
        lda spt
        pha
        rts

puts:   sta spt                 ; A/Y = string (any length)
        sty spt+1
        ldy #0
@l:     lda (spt),y
        beq @d
        jsr outc
        lda abort
        bne @d
        inc spt
        bne @l
        inc spt+1
        bne @l
@d:     rts

puts_ap:
        lda ap
        ldy ap+1
        jmp puts

phex8:  pha
        lsr
        lsr
        lsr
        lsr
        jsr @n
        pla
        and #$0F
@n:     cmp #10
        bcc :+
        adc #'a'-'0'-10-1
:       adc #'0'
        jmp outc

phex16: lda num+1               ; "$hhhh" of num
        pha
        lda #'$'
        jsr outc
        pla
        jsr phex8
        lda num
        jmp phex8

; num (24-bit) in decimal, right-aligned in A columns
pdec0:  lda #0
pdec:   sta pw
        lda #0
        sta pn
@dv:    jsr div10
        pha
        inc pn
        lda num
        ora num+1
        ora num+2
        bne @dv
        ldx pn
@pad:   cpx pw
        bcs @out
        lda #' '
        jsr outc
        inx
        bne @pad
@out:   ldx pn
@o:     pla
        ora #'0'
        jsr outc
        dex
        bne @o
        rts

div10:  lda #0                  ; num /= 10, A = remainder
        ldy #24
@l:     asl num
        rol num+1
        rol num+2
        rol a
        cmp #10
        bcc :+
        sbc #10
        inc num
:       dey
        bne @l
        rts

mul10:  lda num                 ; num *= 10 (24-bit)
        ldx num+1
        ldy num+2
        asl num
        rol num+1
        rol num+2
        asl num
        rol num+1
        rol num+2               ; *4
        clc
        adc num
        sta num
        txa
        adc num+1
        sta num+1
        tya
        adc num+2
        sta num+2               ; *5
        asl num
        rol num+1
        rol num+2               ; *10
        rts

tolower:
        cmp #'A'
        bcc :+
        cmp #'Z'+1
        bcs :+
        ora #$20
:       rts

; ---- errors -----------------------------------------------------------------
; "<argv0>: <message>"
perr:   lda #0
        jsr getarg
        jsr puts_ap
        jsr iprint
        .byte ": ",0
        ldx err
        lda errlo-1,x
        ldy errhi-1,x
        jsr puts
        lda err
        cmp #E_IO
        bne :+
        lda #' '
        jsr outc
        lda k_err
        jsr num8
        jsr pdec0
:       jmp crlf

num8:   sta num
        lda #0
        sta num+1
        sta num+2
        rts

; ---- prompt & line editor ---------------------------------------------------
prompt: jsr print_path
        jsr iprint
        .byte "$ ",0
        rts

print_path:
        lda cwd_drive
        bne @d
        lda #'h'
        jsr outc
        jmp @c
@d:
.ifdef TN
        cmp #5
        bne @dn
        jsr iprint
        .byte "sd:",0
        ldx #0
        lda sdcwd
        bne :+
        lda #'/'
        jmp outc
:       lda sdcwd,x
        beq @e
        jsr outc
        inx
        bne :-
@dn:
.endif
        lda #'d'
        jsr outc
        lda cwd_drive
        ora #'0'
        jsr outc
@c:     lda #':'
        jsr outc
        lda #'/'
        jsr outc
        lda #1
        sta pl_i
@lv:    lda pl_i
        cmp cwd_depth
        beq :+
        bcs @e
:       asl
        asl
        asl
        asl
        tax
@ch:    lda cwd_names,x
        beq @sep
        jsr outc
        inx
        bne @ch
@sep:   lda pl_i
        cmp cwd_depth
        beq @e
        lda #'/'
        jsr outc
        inc pl_i
        bne @lv
@e:     rts

readline:
        lda #0
        sta len
        lda #$FF
        sta hsel
rl_key:
.ifdef TN
        jsr mb_getkey
.else
        jsr getkey
.endif
        cpy #128
        beq rl_brk
        cmp #EOL
        beq rl_eol
        cmp #$7E
        beq rl_bs
        cmp #$7F
        bne :+
        jmp rl_tab
:       cmp #$1C
        beq rl_up
        cmp #$1D
        bne :+
        jmp rl_down
:       cmp #$7D
        beq rl_clr
        cmp #$0C                ; ^L
        beq rl_clr
        cmp #$15                ; ^U
        beq rl_kill
        cmp #$03                ; ^C
        beq rl_brk
        cmp #$7C                ; '|'
        beq @put
        cmp #$20
        bcc rl_key              ; graphics / cursor glyphs: ignored
        cmp #$7B
        bcs rl_key              ; $7B+ incl. inverse: ignored
@put:   ldx len
        cpx #MAXLEN
        bcs rl_key
        sta linebuf,x
        inc len
        jsr putc
        jmp rl_key
rl_eol: ldx len
        lda #0
        sta linebuf,x
        lda #EOL
        jmp putc
rl_brk: jsr iprint
        .byte "^C",EOL,0
        lda #0
        sta len
        sta linebuf
        rts
rl_bs:  lda len
        beq rl_key
        dec len
        lda #$7E
        jsr putc
        jmp rl_key
rl_kill:
        jsr erase_line
        jmp rl_key
rl_clr: lda #$7D
        jsr putc
        jsr more_reset
        jsr prompt
        jsr print_line
        jmp rl_key
rl_k:   jmp rl_key
rl_up:  lda hsel
        clc
        adc #1
        cmp hist_n
        bcs rl_k
        sta hsel
        jsr hist_load
        jmp rl_key
rl_down:
        lda hsel
        bmi rl_k
        dec hsel
        bmi :+
        jsr hist_load
        jmp rl_key
:       jsr erase_line
        jmp rl_key

erase_line:
        ldx len
        beq @d
        lda #$7E
@l:     jsr putc
        dex
        bne @l
        stx len
@d:     rts

print_line:
        ldx #0
@l:     cpx len
        bcs @d
        lda linebuf,x
        jsr putc
        inx
        bne @l
@d:     rts

; ---- history: 8 lines, ring ------------------------------------------------
hist_ptr:                       ; A = slot -> ptr
        tax
        lda histlo,x
        sta ptr
        lda histhi,x
        sta ptr+1
        rts

hist_load:                      ; recall entry hsel (0 = newest)
        jsr erase_line
        lda hist_head
        clc
        sbc hsel                ; head - 1 - hsel
        and #7
        jsr hist_ptr
        ldy #0
@l:     lda (ptr),y
        sta linebuf,y
        beq @d
        iny
        bne @l
@d:     sty len
        jmp print_line

hist_add:
        lda hist_n
        beq @add
        lda hist_head           ; skip a repeat of the newest entry
        sec
        sbc #1
        and #7
        jsr hist_ptr
        ldy #0
@c:     lda (ptr),y
        cmp linebuf,y
        bne @add
        cmp #0
        beq @r
        iny
        bne @c
@add:   lda hist_head
        jsr hist_ptr
        ldy #0
@cp:    lda linebuf,y
        sta (ptr),y
        beq :+
        iny
        bne @cp
:       lda hist_head
        clc
        adc #1
        and #7
        sta hist_head
        lda hist_n
        cmp #8
        bcs @r
        inc hist_n
@r:     rts

; ---- tab completion ---------------------------------------------------------
rl_tab: ldx len                 ; word start
@b:     cpx #0
        beq @ws
        lda linebuf-1,x
        cmp #' '
        beq @ws
        dex
        bne @b
@ws:    stx wstart
        stx pend                ; dir part ends after the last '/' or ':'
        ldx len
@s:     cpx wstart
        beq @sd
        lda linebuf-1,x
        cmp #'/'
        beq @se
        cmp #':'
        beq @se
        dex
        bne @s
@se:    stx pend
@sd:    ldx wstart              ; pathbuf = dir part
        ldy #0
@cp:    cpx pend
        beq @cz
        lda linebuf,x
        sta pathbuf,y
        inx
        iny
        bne @cp
@cz:    lda #0
        sta pathbuf,y
        lda #<pathbuf
        sta ap
        lda #>pathbuf
        sta ap+1
        jsr resolve
        bcs @beep
        jsr tdir_load
        bcs @beep
        lda len                 ; prefix = linebuf[pend..len)
        sec
        sbc pend
        sta fplen
        jsr match_scan
        lda fmatch
        beq @beep
        ldy fplen               ; append candidate[fplen..clen)
@ap:    cpy clen
        bcs @apd
        ldx len
        cpx #MAXLEN
        bcs @apd
        lda cbuf,y
        sta linebuf,x
        inc len
        jsr putc
        iny
        bne @ap
@apd:   lda fmatch
        cmp #1
        bne @many
        lda tmp3                ; unique: '/' after a dir, ' ' after a file
        ldx len
        cpx #MAXLEN
        bcs @done
        sta linebuf,x
        inc len
        jsr putc
@done:  jmp rl_key
@many:  lda clen                ; ambiguous and nothing to add: show them
        cmp fplen
        bne @done
        lda #EOL
        jsr putc
        jsr more_reset
        lda #0
        sta lflag
        jsr list_entries
        jsr more_reset
        jsr prompt
        jsr print_line
        jmp rl_key
@beep:  lda #$FD
        jsr putc
        jmp rl_key

; Does nbuf start with linebuf[pend..pend+fplen)? C=1 yes
prefix_ok:
        ldx pend
        ldy #0
@l:     cpy fplen
        bcs @y
        lda linebuf,x
        jsr tolower
        cmp nbuf,y
        bne @n
        inx
        iny
        bne @l
@y:     sec
        rts
@n:     clc
        rts

; count matches in dirtab -> fmatch; cbuf/clen = longest common prefix;
; tmp3 = '/' or ' ' for the (last) match
match_scan:
        lda #0
        sta fmatch
        jsr dp_first
        lda ndir
        sta lcnt
        beq @r
@e:     jsr fmt_name
        jsr prefix_ok
        bcc @nx
        lda fmatch
        bne @common
        ldy #0                  ; first match: candidate = name
@c:     lda nbuf,y
        sta cbuf,y
        beq :+
        iny
        bne @c
:       sty clen
        jmp @kind
@common:
        ldy #0
@cl:    cpy clen
        bcs @kind
        lda nbuf,y
        cmp cbuf,y
        bne :+
        iny
        bne @cl
:       sty clen
@kind:  inc fmatch
        ldy #0
        lda (dp),y
        and #$10
        beq :+
        lda #'/'
        .byte $2C
:       lda #' '
        sta tmp3
@nx:    jsr dp_next
        dec lcnt
        bne @e
@r:     rts

; ---- tokenizer & dispatch ---------------------------------------------------
tokenize:                       ; linebuf -> argv[]/argbuf (words, 0-terminated;
        ldx #0                  ; "quoted words" keep their spaces)
        ldy #0
        lda #0
        sta tmp2                ; write index into argbuf
@sk:    lda linebuf,x
        beq @d
        cmp #' '
        bne @w
        inx
        bne @sk
@w:     cpy #MAXARGS
        bcs @d
        lda tmp2
        sta argv,y
        iny
        lda #0
        sta tmp                 ; inside quotes?
@wl:    lda linebuf,x
        beq @end
        cmp #'"'
        bne :+
        lda tmp
        eor #1
        sta tmp
        inx
        bne @wl
:       cmp #' '
        bne @st
        lda tmp
        beq @end
        lda #' '
@st:    stx sx
        ldx tmp2
        sta argbuf,x
        inc tmp2
        ldx sx
        inx
        bne @wl
@end:   stx sx
        ldx tmp2
        lda #0
        sta argbuf,x
        inc tmp2
        ldx sx
        lda linebuf,x
        beq @d
        inx
        bne @sk
@d:     ldx tmp2
        lda #0
        sta argbuf,x
        sty argc
        rts

getarg: tax                     ; A = index -> ap
        lda argv,x
        clc
        adc #<argbuf
        sta ap
        lda #>argbuf
        adc #0
        sta ap+1
        rts

dispatch:
        lda #0
        jsr getarg
        ldy #0                  ; "d2:" / "h:" alone = change drive
@ln:    lda (ap),y
        beq :+
        iny
        bne @ln
:       dey
        lda (ap),y
        cmp #':'
        bne :+
        jmp cd_ap
:       lda #<cmdnames
        sta ptr
        lda #>cmdnames
        sta ptr+1
        ldx #0
@cmp:   ldy #0
        lda (ptr),y
        beq @nf
@cl:    lda (ap),y
        jsr tolower
        cmp (ptr),y
        bne @skip
        cmp #0
        beq @found
        iny
        bne @cl
@skip:  ldy #0
@sk:    lda (ptr),y
        iny
        cmp #0
        bne @sk
        tya
        clc
        adc ptr
        sta ptr
        bcc :+
        inc ptr+1
:       inx
        bne @cmp
@found: lda cmdlo,x
        sta ptr
        lda cmdhi,x
        sta ptr+1
        jmp (ptr)
@nf:    jmp try_exec

; ---- path resolution --------------------------------------------------------
; ap = path. Builds tcw (t_*) = the directory, and r_kind = 1 with comp = the
; final name when the path ends in a name. C=1 on error (err set).
resolve:
        ldx #CWSIZE
@cw:    lda cwd-1,x
        sta tcw-1,x
        dex
        bne @cw
        lda #0
        sta r_kind
        ldy #0
        lda (ap),y
        jsr tolower
        sta tmp
        iny
        lda (ap),y
        sta tmp2
        lda tmp
.ifdef TN
        cmp #'s'                ; "sd:..." -> the SD card
        bne :+
        lda tmp2
        jsr tolower
        cmp #'d'
        bne :+
        ldy #2
        lda (ap),y
        cmp #':'
        beq @sd
:       lda tmp
.endif
        cmp #'h'
        bne @dd
        lda tmp2
        cmp #':'
        bne @nod
        lda hpresent
        bne :+
        lda #E_NODEV
        sta err
        sec
        rts
:       lda #0
        ldy #2
        bne @drv
@dd:    cmp #'d'
        bne @nod
        lda tmp2
        cmp #':'
        bne @dn
        lda #1                  ; "d:" = d1:
        ldy #2
        bne @drv
@dn:    sec
        sbc #'1'
        cmp #4
        bcs @nod
        adc #1
        sta tmp3
        ldy #2
        lda (ap),y
        cmp #':'
        bne @nod
        lda tmp3
        ldy #3
@drv:   sta t_drive
        lda #0
        sta t_depth
        beq @sl
@nod:
.ifdef TN
        lda cwd_drive           ; relative names on sd: stay on sd:
        cmp #5
        bne :+
@sd:    lda #5
        sta t_drive
        jmp sd_abs
:
.endif
        ldy #0
@sl:    lda (ap),y
        cmp #'/'
        bne @comp
        lda #0
        sta t_depth
        iny
@comp:  ldx #0
@cc:    lda (ap),y
        beq @ce
        cmp #'/'
        beq @ce
        jsr tolower
        cpx #12
        bcs :+
        sta comp,x
        inx
:       iny
        bne @cc
@ce:    sta term
        lda #0
        sta comp,x
        sty ypos
        cpx #0
        beq @next
        lda comp
        cmp #'.'
        bne @name
        lda comp+1
        beq @next               ; "."
        cmp #'.'
        bne @name
        lda comp+2
        bne @name
        lda t_depth             ; ".."
        beq @next
        dec t_depth
        jmp @next
@name:  lda term
        bne @desc
        lda #1                  ; last component names an entry
        sta r_kind
        clc
        rts
@desc:  jsr descend
        bcs @r
@next:  ldy ypos
        lda term
        beq @ok
        iny
        jmp @comp
@ok:    clc
@r:     rts

; enter subdirectory `comp` of tcw
descend:
        lda t_drive
        beq @noent              ; H: is flat
        lda t_depth
        cmp #7
        bcs @deep
        jsr tdir_load
        bcs @r
        jsr lookup_comp
        bcs @r
        ldy #0
        lda (dp),y
        and #$10
        beq @nodir
        inc t_depth
        lda t_depth
        asl
        tax
        ldy #3
        lda (dp),y
        sta t_dirs,x
        iny
        lda (dp),y
        sta t_dirs+1,x
        lda t_depth
        asl
        asl
        asl
        asl
        tax
        ldy #0
@n:     lda comp,y
        sta t_names,x
        beq @ok
        inx
        iny
        bne @n
@ok:    clc
@r:     rts
@noent: lda #E_NOENT
        .byte $2C
@nodir: lda #E_NOTDIR
        .byte $2C
@deep:  lda #E_DEEP
        sta err
        sec
        rts

; find comp in dirtab -> dp. C=1 not found.
lookup_comp:
        jsr dp_first
        lda ndir
        sta lcnt
        beq @nf
@e:     jsr fmt_name
        ldy #0
@c:     lda nbuf,y
        cmp comp,y
        bne @no
        cmp #0
        beq @y
        iny
        bne @c
@no:    jsr dp_next
        dec lcnt
        bne @e
@nf:    lda #E_NOENT
        sta err
        sec
        rts
@y:     clc
        rts

dp_first:
        lda #<dirtab
        sta dp
        lda #>dirtab
        sta dp+1
        rts
dp_next:
        lda dp
        clc
        adc #16
        sta dp
        bcc :+
        inc dp+1
:       rts

; (dp) -> nbuf = "name.ext", lowercase; Y = length. Preserves X.
fmt_name:
        stx fx
        ldx #0
        ldy #5
@n:     lda (dp),y
        cmp #' '
        beq @x
        jsr tolower
        sta nbuf,x
        inx
        iny
        cpy #13
        bne @n
@x:     ldy #13
        lda (dp),y
        cmp #' '
        beq @z
        lda #'.'
        sta nbuf,x
        inx
@e:     lda (dp),y
        cmp #' '
        beq @z
        jsr tolower
        sta nbuf,x
        inx
        iny
        cpy #16
        bne @e
@z:     lda #0
        sta nbuf,x
        txa
        tay
        ldx fx
        rts

; C=1 if (dp) has an executable extension
is_exec:
        lda #0
        sta eb
@t:     ldx eb
        ldy #13
@c:     lda (dp),y
        cmp exts,x
        bne @nx
        inx
        iny
        cpy #16
        bne @c
        sec
        rts
@nx:    lda eb
        clc
        adc #3
        sta eb
        cmp #15
        bcc @t
        clc
        rts

; ---- directories ------------------------------------------------------------
; load the directory tcw names into dirtab (cached per command)
tdir_load:
.ifdef TN
        lda t_drive
        cmp #5
        bne :+
        lda #E_ROFS             ; no directory cache for sd: (read/mount/boot only)
        sta err
        sec
        rts
:
.endif
        lda t_depth
        asl
        tax
        lda t_dirs,x
        sta lsec
        lda t_dirs+1,x
        sta lsec+1
        lda t_drive
        sta ldrv
        lda dc_valid
        beq @ld
        lda ldrv
        cmp dc_drive
        bne @ld
        lda lsec
        cmp dc_sec
        bne @ld
        lda lsec+1
        cmp dc_sec+1
        bne @ld
        clc
        rts
@ld:    lda #0
        sta dc_valid
        lda ldrv
        beq @h
        jsr disk_dir
        jmp @f
@h:     jsr h_dir
@f:     bcs @r
        lda ldrv
        sta dc_drive
        lda lsec
        sta dc_sec
        lda lsec+1
        sta dc_sec+1
        lda #1
        sta dc_valid
        clc
@r:     rts

; DOS 2 / MyDOS: 8 directory sectors from lsec, 8 entries in each
disk_dir:
        lda #0
        sta ndir
        ldx ldrv
        jsr dstat
        bcs @r
        jsr dp_first
        lda lsec
        sta csec
        lda lsec+1
        sta csec+1
        lda #8
        sta dsec_n
@sec:   ldx ldrv
        lda csec
        ldy csec+1
        jsr rdsec
        bcs @r
        ldx #0
@ent:   lda dbuf,x
        beq @end                ; never-used slot: end of directory
        bmi @skip               ; deleted
        and #$50                ; in use, or a MyDOS directory
        beq @skip
        lda ndir
        cmp #MAXDIR
        bcs @end
        ldy #0
@cp:    lda dbuf,x
        sta (dp),y
        inx
        iny
        cpy #16
        bne @cp
        jsr dp_next
        inc ndir
        jmp @nx
@skip:  txa
        clc
        adc #16
        tax
@nx:    cpx #128
        bcc @ent
        inc csec
        bne :+
        inc csec+1
:       dec dsec_n
        bne @sec
@end:   clc
@r:     rts

; H: listing ("NAME.EXT      SIZE" lines) parsed into dirtab entries;
; size goes in bytes 1-3 (24-bit)
h_dir:  lda #0
        sta ndir
        jsr h_name0
        lda #6
        jsr h_open
        bcc :+
        rts
:       jsr dp_first
@line:  ldy #15                 ; blank entry: $42, size 0, name spaces
        lda #' '
:       sta (dp),y
        dey
        cpy #4
        bne :-
        lda #0
:       sta (dp),y
        dey
        bne :-
        lda #$42
        sta (dp),y
        ldy #5
@nm:    jsr hget
        cmp #EOL
        beq @line
        cmp #' '
        beq @sp
        cmp #'.'
        bne @ch
        ldy #13
        bne @nm
@ch:    cpy #16
        bcs @nm
        sta (dp),y
        iny
        bne @nm
@sp:    lda #0
        sta num
        sta num+1
        sta num+2
        sta tmp
@sk:    jsr hget
        cmp #' '
        beq @sk
@dg:    cmp #'0'
        bcc @tl
        cmp #'9'+1
        bcs @tl
        and #$0F
        pha
        jsr mul10
        pla
        clc
        adc num
        sta num
        bcc :+
        inc num+1
        bne :+
        inc num+2
:       inc tmp
        jsr hget
        jmp @dg
@tl:    cmp #EOL
        beq @eol
        jsr hget
        jmp @tl
@eol:   lda tmp
        bne :+
        jmp @line               ; no size: "END OF DIRECTORY"
:
        ldy #1
        lda num
        sta (dp),y
        iny
        lda num+1
        sta (dp),y
        iny
        lda num+2
        sta (dp),y
        jsr dp_next
        inc ndir
        lda ndir
        cmp #MAXDIR
        bcs h_eof
        jmp @line
; k_getbyte for h_dir; at the end it returns from h_dir itself
hget:   jsr k_getbyte
        bcc :+
        pla
        pla
h_eof:  jsr h_close
        clc
:       rts

; ---- SIO helpers --------------------------------------------------------------
dstat:  jsr k_dstat              ; drive X -> density; C=1 error
        bcs ioerr
        rts

rdsec:  jsr k_rdsec              ; drive X, sector A/Y -> dbuf
        bcs ioerr
        rts
ioerr:  lda #E_IO
        sta err
        sec
        rts

h_name0:                        ; namebuf = zeros
        lda #0
        ldx #63
:       sta namebuf,x
        dex
        bpl :-
        rts

; open H: file namebuf in mode A (4 read, 6 directory) as the kernel stream
h_open: sta DAUX1
        lda #$4F
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
        bmi ioerr
        lda #0
        sta k_dev
        beq st_reset

h_close:
        lda #$43
        jsr k_hcmd
        lda #0
        sta DSTATS
        sta DBYTLO
        sta DBYTHI
        jmp SIOV

st_reset:
        lda #0
        sta k_pos
        sta k_len
        lda #1
        sta k_err
        clc
        rts

stream_end:
        lda k_dev
        bne :+
        jsr h_close
:       lda k_err
        bpl :+
        lda #E_IO
        sta err
        jmp perr
:       rts

; ap = path -> kernel stream open on that file; dp/nbuf = its entry.
; C=1 on error (err set).
open_file:
        jsr resolve
        bcs @r
        lda r_kind
        beq @isdir
.ifdef TN
        lda t_drive
        cmp #5
        bne :+
        jmp sd_open
:
.endif
        jsr tdir_load
        bcs @r
        jsr lookup_comp
        bcs @r
        ldy #0
        lda (dp),y
        and #$10
        bne @isdir
        jsr fmt_name
        lda t_drive
        beq @h
        sta k_dev
        tax
        ldy #3
        lda (dp),y
        sta k_next
        iny
        lda (dp),y
        sta k_next+1
        ldy #0
        lda (dp),y
        and #$04                ; MyDOS: 16-bit sector links
        beq :+
        lda #$80
:       sta k_l16
        jmp st_reset
@h:     jsr h_name0
        ldx #0
:       lda nbuf,x
        sta namebuf,x
        beq :+
        inx
        bne :-
:       lda #4
        jmp h_open
@isdir: lda #E_ISDIR
        sta err
        sec
@r:     rts

; open argument 1 as a file, or print the error. C=1 failed (already reported)
open_arg1:
        lda argc
        cmp #2
        bcs :+
        lda #E_USAGE
        sta err
        bne @e
:       lda #1
        jsr getarg
        jsr open_file
        bcc @r
@e:     jsr perr
        sec
@r:     rts

; ---- listing ----------------------------------------------------------------
; print dirtab (filtered by the tab prefix when fplen > 0), short or long
list_entries:
        lda #0
        sta lcol
        jsr dp_first
        lda ndir
        sta lcnt
        bne @e
        rts
@e:     jsr fmt_name
        jsr prefix_ok
        bcs :+
        jmp @nx
:       lda lflag
        bne @long
        jsr put_name
        inc lcol
        lda lcol
        cmp #3
        bcc @pad
        lda #0
        sta lcol
        jsr crlf
        jmp @nx
@pad:   cpy #13
        bcs @nx
        lda #' '
        jsr outc
        iny
        bne @pad
@long:  ldy #0                  ; mode: drwx-ish
        lda (dp),y
        and #$10
        beq :+
        lda #'d'
        .byte $2C
:       lda #'-'
        jsr outc
        lda #'r'
        jsr outc
        ldy #0
        lda (dp),y
        and #$20                ; locked
        beq :+
        lda #'-'
        .byte $2C
:       lda #'w'
        jsr outc
        jsr is_exec
        lda #'-'
        bcc :+
        lda #'x'
:       jsr outc
        ldy #1
        lda (dp),y
        sta num
        iny
        lda (dp),y
        sta num+1
        lda #0
        sta num+2
        lda ldrv
        bne :+
        iny                     ; H: sizes are 24-bit bytes
        lda (dp),y
        sta num+2
:       lda #8
        jsr pdec
        lda #' '
        jsr outc
        jsr put_name
        jsr crlf
@nx:    lda abort
        bne @d
        jsr dp_next
        dec lcnt
        beq @d
        jmp @e
@d:     lda lcol
        beq :+
        jsr crlf
:       rts

; nbuf plus '/' (dir) or '*' (executable); Y = printed length
put_name:
        ldy #0
@l:     lda nbuf,y
        beq @s
        cmp #'~'                ; ATASCII backspace: show it, don't do it
        bne :+
        lda #$1B
        jsr outc
        lda #'~'
:       jsr outc
        iny
        bne @l
@s:     sty pw
        ldy #0
        lda (dp),y
        and #$10
        beq :+
        lda #'/'
        bne @o
:       jsr is_exec
        bcc @n
        lda #'*'
@o:     jsr outc
        inc pw
@n:     ldy pw
        rts

; ---- commands ---------------------------------------------------------------
cmd_ls: lda #0
        sta lflag
        sta fplen
        sta lpath+1
        ldx #1
@a:     cpx argc
        bcs @go
        stx xi
        txa
        jsr getarg
        ldx xi
        ldy #0
        lda (ap),y
        cmp #'-'
        bne @p
        lda #1
        sta lflag
        bne @n
@p:     lda ap
        sta lpath
        lda ap+1
        sta lpath+1
@n:     inx
        bne @a
@go:    lda lpath+1
        bne :+
        lda #<s_empty
        sta ap
        lda #>s_empty
        sta ap+1
        bne @rs
:       lda lpath
        sta ap
        lda lpath+1
        sta ap+1
@rs:    jsr resolve
        bcc :+
        jmp @err
:
.ifdef TN
        lda t_drive
        cmp #5
        bne :+
        jsr sd_ls
        bcc @r2
        jmp @err
@r2:    rts
:
.endif
        lda r_kind
        beq @dir
        jsr tdir_load
        bcs @err
        jsr lookup_comp
        bcs @err
        ldy #0
        lda (dp),y
        and #$10
        beq @one
        jsr descend
        bcs @err
@dir:   jsr tdir_load
        bcs @err
        jsr list_entries
        lda lflag
        beq @r
        lda ldrv                ; footer: free sectors from the VTOC
        beq @r
        tax
        lda #<360
        ldy #>360
        jsr rdsec
        bcs @r
        lda dbuf+3
        sta num
        lda dbuf+4
        sta num+1
        lda #0
        sta num+2
        jsr pdec0
        jsr iprint
        .byte " free sectors",EOL,0
@r:     rts
@one:   lda #1                  ; a single file: list just that one
        sta ndir
        lda #0
        sta dc_valid
        ldy #15
:       lda (dp),y
        sta dirtab,y
        dey
        bpl :-
        jmp list_entries
@err:   jmp perr

cmd_cd: lda argc
        cmp #2
        bcs :+
        lda #<s_slash
        sta ap
        lda #>s_slash
        sta ap+1
        bne cd_ap
:       lda #1
        jsr getarg
cd_ap:  jsr resolve
        bcs @err
.ifdef TN
        lda t_drive
        cmp #5
        bne :+
        jsr sd_cd
        bcs @err
        rts
:
.endif
        lda r_kind
        beq :+
        jsr descend
        bcs @err
:       jsr tdir_load           ; proves the drive/dir is readable
        bcs @err
        ldx #CWSIZE
:       lda tcw-1,x
        sta cwd-1,x
        dex
        bne :-
        rts
@err:   jmp perr

cmd_pwd:
        jsr print_path
        jmp crlf

cmd_cat:
        jsr open_arg1
        bcs @r
@l:     jsr k_getbyte
        bcs @e
        cmp #$0D
        beq @l
        cmp #$0A
        bne :+
        lda #EOL
:       cmp #$09
        bne :+
        lda #' '
:       jsr is_ctl
        bcc :+
        pha
        lda #$1B                ; ESC: show control codes as glyphs
        jsr putc
        pla
:       jsr outc
        lda abort
        bne @e
        jsr chk_break
        jmp @l
@e:     jmp stream_end
@r:     rts

; C=1 if A is a screen-editor control code (other than EOL)
is_ctl: cmp #$1B
        bcc @n
        cmp #$20
        bcc @y
        cmp #$7D
        bcc @n
        cmp #$80
        bcc @y
        cmp #$9C
        bcc @n
        cmp #$A0
        bcc @y
        cmp #$FD
        bcs @y
@n:     clc
        rts
@y:     sec
        rts

cmd_xxd:
        jsr open_arg1
        bcs @r
        lda #0
        sta hsrc
        sta hoff
        sta hoff+1
        jsr hexdump
        jmp stream_end
@r:     rts

cmd_peek:
        lda argc
        cmp #2
        bcc @u
        lda #1
        jsr getarg
        jsr parse_hex
        bcs @e
        lda num
        sta mptr
        sta hoff
        lda num+1
        sta mptr+1
        sta hoff+1
        lda #64
        sta hrem
        lda #0
        sta hrem+1
        lda argc
        cmp #3
        bcc @go
        lda #2
        jsr getarg
        jsr parse_hex
        bcs @e
        lda num
        sta hrem
        lda num+1
        sta hrem+1
@go:    lda #1
        sta hsrc
        jmp hexdump
@u:     lda #E_USAGE
        sta err
@e:     jmp perr

cmd_poke:
        lda argc
        cmp #3
        bcc @u
        lda #1
        jsr getarg
        jsr parse_hex
        bcs @e
        lda num
        sta mptr
        lda num+1
        sta mptr+1
        lda #2
        sta xi
@l:     lda xi
        cmp argc
        bcs @r
        jsr getarg
        jsr parse_hex
        bcs @e
        ldy #0
        lda num
        sta (mptr),y
        inc mptr
        bne :+
        inc mptr+1
:       inc xi
        bne @l
@r:     rts
@u:     lda #E_USAGE
        sta err
@e:     jmp perr

; next byte for the hex dumper: file stream or memory. C=1 at end.
hd_get: lda hsrc
        bne :+
        jmp k_getbyte
:       lda hrem
        ora hrem+1
        bne :+
        sec
        rts
:       lda hrem
        bne :+
        dec hrem+1
:       dec hrem
        ldy #0
        lda (mptr),y
        inc mptr
        bne :+
        inc mptr+1
:       clc
        rts

hexdump:
@line:  ldx #0
@f:     stx hn
        jsr hd_get
        ldx hn
        bcs @got
        sta hbuf,x
        inx
        cpx #8
        bne @f
@got:   stx hn
        cpx #0
        beq @d
        lda hoff+1
        jsr phex8
        lda hoff
        jsr phex8
        lda #':'
        jsr outc
        ldx #0
@h:     lda #' '
        jsr outc
        cpx hn
        bcs @sp
        lda hbuf,x
        jsr phex8
        jmp @hn
@sp:    jsr outc
        jsr outc
@hn:    inx
        cpx #8
        bne @h
        lda #' '
        jsr outc
        ldx #0
@as:    cpx hn
        bcs @eol
        lda hbuf,x
        cmp #$20
        bcc @dot
        cmp #$7B
        bcc @pc
@dot:   lda #'.'
@pc:    jsr outc
        inx
        bne @as
@eol:   jsr crlf
        lda hoff
        clc
        adc #8
        sta hoff
        bcc :+
        inc hoff+1
:       jsr chk_break
        lda abort
        bne @d
        lda hn
        cmp #8
        bne @d
        jmp @line
@d:     rts

; ap -> num (16-bit hex, optional $ or 0x). C=1 bad.
parse_hex:
        ldy #0
        sty num
        sty num+1
        lda (ap),y
        cmp #'$'
        beq @skip1
        cmp #'0'
        bne @go
        iny
        lda (ap),y
        jsr tolower
        cmp #'x'
        beq @skip1
        dey
        jmp @go
@skip1: iny
@go:    ldx #0
@l:     lda (ap),y
        beq @end
        jsr hexval
        bcs @bad
        asl num
        rol num+1
        asl num
        rol num+1
        asl num
        rol num+1
        asl num
        rol num+1
        ora num
        sta num
        inx
        iny
        bne @l
@end:   cpx #1
        bcc @bad
        clc
        rts
@bad:   lda #E_NUM
        sta err
        sec
        rts

hexval: jsr tolower
        cmp #'0'
        bcc @b
        cmp #'9'+1
        bcc @d
        cmp #'a'
        bcc @b
        cmp #'f'+1
        bcs @b
        sbc #'a'-11
        clc
        rts
@d:     and #$0F
        clc
        rts
@b:     sec
        rts

; byte from the stream, counted into fsz
fgetb:  jsr k_getbyte
        bcs @r
        inc fsz
        bne @r
        inc fsz+1
        bne @r
        inc fsz+2
@r:     rts

; fgetb inside a segment: running out = truncated file (leaves cmd_file)
fgetx:  jsr fgetb
        bcc :+
        pla
        pla
        jmp file_tr
:       rts

; text-ish byte? clears ftext otherwise
txtchk: cmp #EOL
        beq @r
        cmp #$0A
        beq @r
        cmp #$0D
        beq @r
        cmp #$09
        beq @r
        cmp #$7C
        beq @r
        cmp #$20
        bcc @no
        cmp #$7B
        bcc @r
@no:    lda #0
        sta ftext
@r:     rts

cmd_file:
        jsr open_arg1
        bcc :+
        rts
:       lda #0
        sta fsz
        sta fsz+1
        sta fsz+2
        sta fseg
        lda #1
        sta ftext
        jsr put_nbuf_colon
        jsr fgetb
        bcs cf_empty
        sta fb0
        jsr fgetb
        bcs cf_one
        pha
        and fb0
        cmp #$FF
        beq cf_xex
        pla
        ora fb0
        beq cf_bas              ; $0000: tokenized BASIC (SAVE)
        pha
        lda fb0
        jsr txtchk
        pla
        jsr txtchk
cf_pl:    jsr fgetb
        bcs cf_pend
        jsr txtchk
        jmp cf_pl
cf_bas:   jsr iprint
        .byte "atari basic program (tokenized), ",0
:       jsr fgetb
        bcc :-
        jmp cf_sz
cf_one:   lda fb0
        jsr txtchk
cf_pend:  lda ftext
        beq :+
        jsr iprint
        .byte "text, ",0
        jmp cf_sz
:       jsr iprint
        .byte "data, ",0
        jmp cf_sz
cf_empty: jsr iprint
        .byte "empty",EOL,0
        jmp stream_end
cf_xex:   pla
        jsr iprint
        .byte "atari executable",EOL,0
cf_seg:   jsr fgetb
        bcc :+
        jmp file_end
:       sta fs
        jsr fgetx
        sta fs+1
        and fs
        cmp #$FF
        beq cf_seg
        jsr fgetx
        sta fe
        jsr fgetx
        sta fe+1
        inc fseg
        lda #' '
        jsr outc
        jsr outc
        lda fs
        sta num
        sta fa
        lda fs+1
        sta num+1
        sta fa+1
        jsr phex16
        lda #'-'
        jsr outc
        lda fe
        sta num
        lda fe+1
        sta num+1
        jsr phex16
        lda #0
        sta fflag
cf_d:     jsr fgetb
        bcs file_tr
        ldx fa+1                ; catch RUNAD / INITAD as they stream by
        cpx #$02
        bne cf_nc
        ldx fa
        cpx #$E0
        bne :+
        sta fr
:       cpx #$E1
        bne :+
        sta fr+1
        pha
        lda fflag
        ora #1
        sta fflag
        pla
:       cpx #$E2
        bne :+
        sta fi
:       cpx #$E3
        bne cf_nc
        sta fi+1
        lda fflag
        ora #2
        sta fflag
cf_nc:    lda fa
        cmp fe
        bne :+
        lda fa+1
        cmp fe+1
        beq cf_sd
:       inc fa
        bne cf_d
        inc fa+1
        jmp cf_d
file_tr:
        jsr iprint
        .byte " (truncated)",EOL,0
        jmp file_end
cf_sd:    lda fflag
        lsr
        bcc :+
        jsr iprint
        .byte " run ",0
        lda fr
        sta num
        lda fr+1
        sta num+1
        jsr phex16
:       lda fflag
        and #2
        beq :+
        jsr iprint
        .byte " init ",0
        lda fi
        sta num
        lda fi+1
        sta num+1
        jsr phex16
:       jsr crlf
        lda abort
        bne file_end
        jmp cf_seg
file_end:  lda fseg
        jsr num8
        jsr pdec0
        jsr iprint
        .byte " segment(s), ",0
cf_sz:    lda fsz
        sta num
        lda fsz+1
        sta num+1
        lda fsz+2
        sta num+2
        jsr pdec0
        jsr iprint
        .byte " bytes",EOL,0
        jmp stream_end

put_nbuf_colon:
        lda #<nbuf
        ldy #>nbuf
        jsr puts
        jsr iprint
        .byte ": ",0
        rts

; run FILE / bare names
cmd_run:
        jsr open_arg1
        bcs @r
        jmp launch_chk
@r:     rts

; unknown command: maybe a program. Tries NAME, then NAME.xex/.com/.exe.
try_exec:
        lda #0
        jsr getarg
        jsr open_file
        bcs :+
        jmp launch_chk
:       lda err
        cmp #E_NOENT
        bne @err
        ldx #0                  ; a dot in the name: no guessing
:       lda comp,x
        beq :+
        cmp #'.'
        beq @nf
        inx
        bne :-
:       lda #0
        sta xi
@ext:   lda #0                  ; pathbuf = argv0 + ext
        jsr getarg
        ldy #0
:       lda (ap),y
        sta pathbuf,y
        beq :+
        iny
        bne :-
:       ldx xi
:       lda dotexts,x
        sta pathbuf,y
        beq :+
        inx
        iny
        bne :-
:       lda #<pathbuf
        sta ap
        lda #>pathbuf
        sta ap+1
        jsr open_file
        bcs :+
        jmp launch_chk
:       lda xi
        clc
        adc #5
        sta xi
        cmp #15
        bcc @ext
@nf:    jsr iprint
        .byte "ash: ",0
        lda #0
        jsr getarg
        jsr puts_ap
        jsr iprint
        .byte ": command not found",EOL,0
        rts
@err:   jmp perr

; stream is open on a file: it must start with $FFFF
launch_chk:
        jsr k_getbyte
        bcs @no
        cmp #$FF
        bne @no
        jsr k_getbyte
        bcs @no
        cmp #$FF
        beq launch
@no:    lda k_dev
        bne :+
        jsr h_close
:       jsr put_nbuf_colon
        jsr iprint
        .byte "not an executable",EOL,0
        rts

; hand the machine over: stock screen and colours, RESET = cold boot
launch: jsr close_all
        lda #2
        sta LMARGN
        jsr stock_colors
        lda #$40
        sta SHFLOK
        jsr open_screen
        jsr iprint
        .byte "loading ",0
        lda #<nbuf
        ldy #>nbuf
        jsr puts
        jsr crlf
.ifdef CART
        lda #0                  ; RESET = warm start -> DOSINI -> k_cartreset
        sta COLDST
        lda #<k_cartreset
        sta DOSINI
        lda #>k_cartreset
        sta DOSINI+1
.else
        lda #1
        sta COLDST
.endif
.ifdef TN
        lda #3                  ; tell the PC the shell is gone
        sta MB_STATUS
        lda #0
        sta MB_CMDREQ           ; (the request that launched us is served)
.endif
        lda #<COLDSV
        sta DOSVEC
        lda #>COLDSV
        sta DOSVEC+1
        lda #<fms_end           ; programs get MEMLO just above the FMS
        sta MEMLO
        sta k_memlo
        lda #>fms_end
        sta MEMLO+1
        sta k_memlo+1
        jmp k_exec

stock_colors:
        ldx #4
:       lda stockc,x
        sta COLOR0,x
        dex
        bpl :-
        rts

cmd_df: ldx #1
@l:     stx df_d
        jsr dstat
        bcs @nx
        lda #'d'
        jsr outc
        lda df_d
        ora #'0'
        jsr outc
        jsr iprint
        .byte ": ",0
        ldx df_d
        lda ss_tab,x
        bne :+
        jsr iprint
        .byte "dd",0
        jmp @v
:       jsr iprint
        .byte "sd",0
@v:     ldx df_d
        lda #<360
        ldy #>360
        jsr rdsec
        bcs @ce
        lda dbuf+3
        sta num
        lda dbuf+4
        sta num+1
        lda #0
        sta num+2
        lda #6
        jsr pdec
        jsr iprint
        .byte " free of",0
        lda dbuf+1
        sta num
        lda dbuf+2
        sta num+1
        lda #0
        sta num+2
        lda #6
        jsr pdec
        jsr iprint
        .byte " sectors",0
@ce:    jsr crlf
@nx:    ldx df_d
        inx
        cpx #5
        bcs :+
        jmp @l
:
        lda hpresent
        beq @r
        lda #0
        sta dc_valid
        jsr h_dir
        bcs @r
        jsr iprint
        .byte "h:  sd card /HDD,",0
        lda ndir
        jsr num8
        lda #4
        jsr pdec
        jsr iprint
        .byte " files",EOL,0
@r:     lda #0                  ; probing empty drives is not an error
        sta err
        rts

cmd_clear:
        lda #$7D
        jmp putc

cmd_help:
        lda #<s_help
        ldy #>s_help
        jmp puts

cmd_ver:
        jsr iprint
        .byte "ASH ", VERSION, EDITION, " (Atari SHell) 6502 XL/XE",EOL,0
        rts

cmd_echo:
        ldx #1
@l:     cpx argc
        bcs @d
        stx xi
        txa
        jsr getarg
        jsr puts_ap
        lda #' '
        jsr outc
        ldx xi
        inx
        bne @l
@d:     jmp crlf

cmd_history:
        lda hist_n
        sta xi
@l:     lda xi
        beq @d
        lda hist_n              ; number = hist_n - xi + 1
        sec
        sbc xi
        clc
        adc #1
        jsr num8
        lda #3
        jsr pdec
        lda #' '
        jsr outc
        jsr outc
        lda hist_head           ; slot = head - xi
        sec
        sbc xi
        and #7
        jsr hist_ptr
        lda ptr
        ldy ptr+1
        jsr puts
        jsr crlf
        dec xi
        bne @l
@d:     rts

cmd_reboot:
.ifdef TN
        jmp cmd_reboot_tn
.else
        jmp COLDSV
.endif

; lp FILE — copy a file to the printer (P:) line by line
cmd_lp: jsr open_arg1
        bcs @r
        lda #'P'
        sta fnbuf
        lda #':'
        sta fnbuf+1
        lda #EOL
        sta fnbuf+2
        lda #8
        jsr c_open
        bpl @l
        jsr perr_cio
        jmp stream_end
@l:     jsr k_getbyte
        bcs @done
        cmp #$0A
        bne :+
        lda #EOL
:       cmp #$0D
        beq @l
        jsr c_put
        bpl @l
        jsr perr_cio
@done:  jsr c_close
        jmp stream_end
@r:     rts

cmd_about:                      ; (not listed in help)
        jsr iprint
        .byte "(c) 2026 Carlos Bravo",EOL,"Made with ",0
        lda #0                  ; ATASCII heart
        jsr outc
        jsr iprint
        .byte " from Chile",EOL,0
        rts

        .include "fileops.s"
        .include "editor.s"
.ifdef TN
        .include "tn.s"
        .include "sd.s"
.endif

h_xio:  sta DAUX1               ; XIO A on namebuf
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
        bpl :+
        lda #E_IO
        sta err
        jmp perr
:       rts

cmd_theme:
        lda argc
        cmp #2
        bcc @u
        lda #1
        jsr getarg
        ldx #0                  ; match the first letter: g a b w
        ldy #0
        lda (ap),y
        jsr tolower
:       cmp themekey,x
        beq @set
        inx
        cpx #5
        bne :-
@u:     jsr iprint
        .byte "theme blue|green|amber|classic|white",EOL,0
        rts
@set:   stx theme
apply_theme:
        lda theme
        asl
        adc theme
        tax
        lda themes,x
        sta COLOR2
        lda themes+1,x
        sta COLOR1
        lda themes+2,x
        sta COLOR4
        rts

; Atari BASIC on top of the shell; BASIC's DOS command comes back here.
cmd_basic:
        jsr close_all
        lda PORTB
        and #$FD
        sta PORTB
        lda $BFFC
        beq :+
        lda PORTB               ; nothing there: back off
        ora #$02
        sta PORTB
        jsr open_kbd
        jsr iprint
        .byte "basic: no BASIC ROM",EOL,0
        rts
:       lda #0
        sta BASICF
        lda #$A0
        sta RAMTOP
        lda #<BASICLO
        sta MEMLO
        sta k_memlo
        lda #>BASICLO
        sta MEMLO+1
        sta k_memlo+1
        lda #2
        sta LMARGN
        jsr stock_colors
        lda #$40
        sta SHFLOK
        jsr open_screen
        jsr @init
        jmp ($BFFA)
@init:  jmp ($BFFE)

; ===========================================================================
        .rodata
s_edev: .byte "E:",EOL
s_kdev: .byte "K:",EOL
s_empty:.byte 0
s_slash:.byte "/",0
s_more: .byte $AD,$AD,$A0,$ED,$EF,$F2,$E5,$A0,$AD,$AD   ; inverse "-- more --"
exts:   .byte "XEXCOMEXEOBJBIN"
dotexts:.byte ".xex",0,".com",0,".exe",0
themekey: .byte "bgacw"
themes: .byte $82,$0E,$82       ; deep blue (default)
        .byte $C0,$0E,$C0       ; green phosphor
        .byte $20,$0E,$20       ; amber
        .byte $94,$CA,$00       ; classic Atari blue
        .byte $00,$0C,$00       ; white on black
stockc: .byte $28,$CA,$94,$46,$00

histlo: .repeat 8, I
        .byte <(hist+I*80)
        .endrepeat
histhi: .repeat 8, I
        .byte >(hist+I*80)
        .endrepeat

cmdnames:
        .byte "ls",0,"dir",0,"cd",0,"pwd",0,"cat",0,"type",0,"more",0
        .byte "xxd",0,"hexdump",0,"file",0,"run",0,"df",0,"drives",0
        .byte "clear",0,"cls",0,"help",0,"theme",0,"peek",0,"poke",0
        .byte "echo",0,"history",0,"reboot",0,"basic",0,"ver",0,"uname",0
        .byte "rm",0,"mv",0,"cp",0,"mkdir",0,"rmdir",0,"lock",0,"unlock",0
        .byte "format",0,"edit",0,"about",0,"lp",0,"exit",0
.ifdef TN
        .byte "pc",0,"getw",0,"mount",0,"umount",0,"cart",0,"sd",0
.endif
        .byte 0
.define CMDS cmd_ls,cmd_ls,cmd_cd,cmd_pwd,cmd_cat,cmd_cat,cmd_cat,cmd_xxd,cmd_xxd,cmd_file,cmd_run,cmd_df,cmd_df,cmd_clear,cmd_clear,cmd_help,cmd_theme,cmd_peek,cmd_poke,cmd_echo,cmd_history,cmd_reboot,cmd_basic,cmd_ver,cmd_ver,cmd_rm,cmd_mv,cmd_cp,cmd_mkdir,cmd_rm,cmd_lock,cmd_unlock,cmd_format,cmd_edit,cmd_about,cmd_lp,cmd_basic
.ifdef TN
.define CMDS_TN cmd_pc,cmd_getw,cmd_mount,cmd_umount,cmd_cart,cmd_sd
cmdlo:  .lobytes CMDS, CMDS_TN
cmdhi:  .hibytes CMDS, CMDS_TN
.else
cmdlo:  .lobytes CMDS
cmdhi:  .hibytes CMDS
.endif

ciocodes: .byte 136,138,139,144,146,160,161,162,165,167,169,170,175,0
ciolo:  .lobytes c_136,c_138,c_139,c_144,c_146,c_160,c_161,c_162,c_165,c_167,c_169,c_170,c_175
ciohi:  .hibytes c_136,c_138,c_139,c_144,c_146,c_160,c_161,c_162,c_165,c_167,c_169,c_170,c_175
c_136:  .byte "end of file",0
c_138:  .byte "drive not responding",0
c_139:  .byte "drive refused (NAK)",0
c_144:  .byte "device error (write protected?)",0
c_146:  .byte "not supported",0
c_160:  .byte "no such drive",0
c_161:  .byte "too many open files",0
c_162:  .byte "disk full",0
c_165:  .byte "bad file name",0
c_167:  .byte "locked, or directory not empty",0
c_169:  .byte "directory full",0
c_170:  .byte "no such file",0
c_175:  .byte "not a DOS 2 disk (read-only)",0
errlo:  .lobytes e_noent,e_notdir,e_io,e_isdir,e_noexec,e_deep,e_usage,e_num,e_rofs,e_nodev,e_sdro,e_sdref,e_long
errhi:  .hibytes e_noent,e_notdir,e_io,e_isdir,e_noexec,e_deep,e_usage,e_num,e_rofs,e_nodev,e_sdro,e_sdref,e_long
e_noent:  .byte "no such file or directory",0
e_notdir: .byte "not a directory",0
e_io:     .byte "i/o error",0
e_isdir:  .byte "is a directory",0
e_noexec: .byte "not an executable",0
e_deep:   .byte "too many levels",0
e_usage:  .byte "missing operand",0
e_num:    .byte "bad number",0
e_rofs:   .byte "not supported here",0
e_nodev:  .byte "no h: device on this machine",0
e_sdro:   .byte "sd: is read-only - 'sd rw' enables it",0
e_sdref:  .byte "refused (protected, in use, missing)",0
e_long:   .byte "path too long",0

s_help:
        .byte "ls [-l] [path]   list a directory",EOL
        .byte "cd [path]        d1: h: .. / games/x",EOL
        .byte "pwd              where am i",EOL
        .byte "cat file         show a text file",EOL
        .byte "xxd file         hex dump a file",EOL
        .byte "file name        identify, xex segments",EOL
        .byte "run file         load and run a .xex",EOL
        .byte "name             runs name(.xex/.com)",EOL
        .byte "df               drives and free space",EOL
        .byte "peek adr [len]   dump memory (hex)",EOL
        .byte "poke adr byte..  write memory (hex)",EOL
        .byte "theme name       colours (theme = list)",EOL
        .byte "cp src dst       copy (disks and h:)",EOL
        .byte "rm mv            delete, rename / move",EOL
        .byte "mkdir rmdir      directories (MyDOS)",EOL
        .byte "lock unlock      protect files",EOL
        .byte "format dn:       erase a disk (DOS 2)",EOL
        .byte "edit file        full-screen editor",EOL
        .byte "lp file          print to P:",EOL
.ifdef TN
        .byte "pc               is ashterm on the pc?",EOL
        .byte "sd:/path         the sd card: ls cd cat run",EOL
        .byte "mount [dn: path] show / mount a disk",EOL
        .byte "umount dn:  cart path  reboot",EOL
        .byte "sd rw            allow cp/rm/mv/mkdir on sd:",EOL
.endif
        .byte "history  clear  echo  reboot",EOL
        .byte "basic / exit     leave ASH for BASIC",EOL
        .byte EOL
        .byte "tab completes names, arrows recall",EOL
        .byte "history, ctrl-u kills the line,",EOL
        .byte "break cancels, reset comes back here",EOL
        .byte 0

        .include "kernel.s"

; ===========================================================================
        .segment "XEXHDR"
        .word $FFFF
        .word __MAIN_START__
        .word __MAIN_LAST__-1

        .segment "XEXTRL"
        .word RUNAD, RUNAD+1
        .word entry
