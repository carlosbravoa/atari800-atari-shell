; ===========================================================================
; ASH boot sector. The OS loads these two sectors to $0700 and calls +6; we
; pull the raw shell image (stored in sectors 4.. by tools/mkatr.py, outside
; any file) to $2000 and jump in. Never returns: ASH sets up the machine.
; ===========================================================================
        .setcpu "6502"
SIOV    = $E459
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
SHELL   = $2000

        .segment "BOOT"
        .byte 0                 ; flags
        .byte 2                 ; sectors to boot
        .word $0700             ; load address
        .word brts              ; DOSINI
        jmp go                  ; +6: OS entry
nsec:   .byte 0                 ; +9:  image sectors   (patched by mkatr.py)
ssz:    .byte $80               ; +10: $80 = 128-byte sectors, $00 = 256

go:     lda #<SHELL
        sta ptr
        lda #>SHELL
        sta ptr+1
        lda #4
        sta secn
        lda #0
        sta secn+1
@l:     lda #$31
        sta DDEVIC
        lda #1
        sta DUNIT
        lda #$52
        sta DCOMND
        lda #$40
        sta DSTATS
        lda #7
        sta DTIMLO
        lda ptr
        sta DBUFLO
        lda ptr+1
        sta DBUFHI
        lda secn
        sta DAUX1
        lda secn+1
        sta DAUX2
        lda ssz
        sta DBYTLO
        cmp #1
        lda #0
        rol
        eor #1
        sta DBYTHI
        jsr SIOV
        bmi @err
        lda ssz
        bne :+
        inc ptr+1               ; 256-byte sector
        bne @nx
:       clc
        adc ptr
        sta ptr
        bcc @nx
        inc ptr+1
@nx:    inc secn
        bne :+
        inc secn+1
:       dec nsec
        bne @l
        jmp SHELL
@err:   sec                     ; BOOT ERROR: the OS retries
        rts
brts:   clc
        rts
ptr:    .word 0
secn:   .word 0
