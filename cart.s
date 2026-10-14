; ===========================================================================
; cart.s — bank 0 of the ASH cartridge (Williams 32K, CAR type 22).
;
; The cartridge carries the ASH-TN image (the .xex's $2000-$59FF segment) in
; banks 1-2. Bank 0 is this: the OS runs our init vector at cold start, we
; park a copier in page 6 and the run vector jumps to it. The copier pages
; banks 1-2 in at $A000, moves them to $2000-$5FFF, switches the cartridge
; OFF (so $A000-$BFFF is RAM again, for games and for BASIC) and enters
; ASH. Williams 32K: a read of $D500+n selects bank n and enables the
; cart; a read of $D508 disables it. The cart logic is only reset when the
; firmware power-cycles the cartridge (every cold-boot path), so after a
; launched program the RESET key comes back through k_cartreset (kernel.s)
; instead: re-enable, then cold start — the OS finds the cart and we run
; again. GINTLK is the XL OS cartridge interlock: the VBI jams the machine
; if TRIG3 stops matching it, so the switch-off happens with NMIs masked
; and GINTLK updated before they come back.
; ===========================================================================
        .setcpu "6502"
COPIER  = $0600
IMGDST  = $2000
NBANKS  = 2                     ; banks 1..2 hold the image
GINTLK  = $03FA
NMIEN   = $D40E
CARTSEL = $D500                 ; + bank number
CARTOFF = $D508
bank    = $F0                   ; copier variables (zero page, free at boot)
src     = $F1
dst     = $F3

        .segment "BANK0"
        .org $A000
start:  jmp run                 ; (not used by the OS; keeps $A000 sane)

; cold-start init vector: put the copier where it survives bank switching
init:   ldx #copier_end-copier-1
:       lda copier_src,x
        sta COPIER,x
        dex
        bpl :-
        rts

run:    jmp COPIER

; ---- the copier, assembled for $0600 ------------------------------------------
copier_src:
        .org COPIER
copier: sei
        lda #0
        sta NMIEN               ; no VBI while the cartridge comes and goes
        lda #1
        sta bank
        lda #<IMGDST
        sta dst
        lda #>IMGDST
        sta dst+1
@bank:  ldx bank
        lda CARTSEL,x           ; bank X at $A000
        lda #<$A000
        sta src
        lda #>$A000
        sta src+1
        ldx #$20                ; 32 pages
        ldy #0
@cp:    lda (src),y
        sta (dst),y
        iny
        bne @cp
        inc src+1
        inc dst+1
        dex
        bne @cp
        inc bank
        lda bank
        cmp #NBANKS+1
        bcc @bank
        lda CARTOFF             ; cartridge off: $A000-$BFFF is RAM now
        lda #0
        sta GINTLK              ; tell the OS there is no cartridge
        lda #$40
        sta NMIEN
        cli
        jmp IMGDST              ; ASH cold entry
copier_end:
        .reloc

; ---- cartridge vectors ----------------------------------------------------------
        .segment "VECTORS"
        .word run               ; $BFFA run
        .byte 0                 ; $BFFC = 0: a cartridge is present
        .byte $04               ; $BFFD: init the cart, don't boot a disk
        .word init              ; $BFFE init
