; DmaDelay - Test that DMA can be interrupted by CTC timer interrupts
; in hardware IM2 mode (core 3.1.8+).
;
; Expected visual result: YELLOW screen (DMA) with GREEN flashes (CTC ISR),
; brief BLUE before RETI. Any unexpected interrupt -> RED.
;
; Visual output uses only the Fallback Colour Register (NextReg $4A)
; with all graphical layers disabled.

    DEFINE SNA_FILENAME "DmaDelay.snx"
    device  zxspectrum48

    org     $8000

    INCLUDE "../../Constants.asm"
    INCLUDE "../../Macros.asm"
    INCLUDE "../../TestFunctions.asm"

; ---- Colour constants (RRRGGGBB) ----
COL_GREEN           equ $1C   ; %00011100
COL_YELLOW          equ $FC   ; %11111100
COL_BLUE            equ $03   ; %00000011
COL_RED             equ $E0   ; %11100000

; ---- Interrupt vector addresses ----
VECTOR_TABLE        equ $D000
CTC_HANDLER_ADR     equ $D200
DEFAULT_HANDLER_ADR equ $D2D2

; ---- CTC channel 0 ----
CTC_PORT            equ $183B
CTC_CH0_VECTOR      equ $86   ; hw IM2 vector for CTC channel 0
; Control: D7=1 int, D6=0 timer, D5=0 prescaler/16, D4=1 rising edge,
;           D3=0 auto-start, D2=1 TC follows, D1=0, D0=1 control word
CTC_TIMER_CTRL      equ %10010101   ; = $95

; ============================================================================

Start:
    di

    ; ---- CPU speed: 28 MHz ----
    NEXTREG_nn  TURBO_CONTROL_NR_07, 3

    ; ---- Disable all graphical layers ----
    NEXTREG_nn  ULA_CONTROL_NR_68, %10000000  ; ULA disabled (bit 7 = 1)
    NEXTREG_nn  LAYER2_CONTROL_NR_70, 0         ; Layer 2 off
    NEXTREG_nn  SPRITE_CONTROL_NR_15, 0         ; Sprites off
    NEXTREG_nn  COPPER_CONTROL_LO_NR_61, 0      ; Copper off
    NEXTREG_nn  COPPER_CONTROL_HI_NR_62, 0      ; Copper off

    ; ---- Initial fallback colour (visible when all layers off) ----
    NEXTREG_nn  TRANSPARENCY_FALLBACK_COL_NR_4A, COL_GREEN

    ; ---- Interrupt configuration ----
    ; NextReg $C0 = $81: hw IM2 mode, vector base bits 7:5 = %100
    NEXTREG_nn  $C0, $81
    ; Disable ULA frame interrupt (bit 2 of $22)
    NEXTREG_nn  VIDEO_INTERUPT_CONTROL_NR_22, %00000100

    ; ---- Build IM2 vector table at $D000 ----
    ; Fill 257 bytes with $D2 -> all vectors default to $D2D2
    ld      a, $D2
    ld      hl, VECTOR_TABLE
    ld      de, VECTOR_TABLE + 1
    ld      bc, 256
    ld      (hl), a
    ldir
    ; Patch CTC ch0 vector ($86) -> CTC_Handler ($D200)
    ld      hl, CTC_HANDLER_ADR
    ld      (VECTOR_TABLE + CTC_CH0_VECTOR), hl

    ; Set I register for vector table at $D000
    ld      a, $D0
    ld      i, a

    ; ---- CTC Channel 0: timer, one int per scanline (312/frame) at 28 MHz ----
    ld      bc, CTC_PORT
    ; Soft reset twice (per ZX Next CTC docs for unknown-state channels)
    ld      a, $03              ; D1=1 reset, D0=1 ctrl, D2=0 no TC
    out     (c), a
    out     (c), a
    ; Control word: timer, int enabled, prescaler /16, auto-start, TC follows
    ld      a, CTC_TIMER_CTRL   ; $95
    out     (c), a
    ; (TC written after VBLANK sync for line-locked X position)

    ; ---- DMA delay registers (core 3.1.8+) ----
    NEXTREG_nn  $CC, $FF        ; ULA / Line / NMI won't delay DMA (all disabled)
    NEXTREG_nn  $CD, $FF        ; CTC ch0 can interrupt DMA

    ; ---- Pre-select NextReg $4A at port $243B ----
    ; DMA port B writes will go to $253B = NextReg data port for register $4A
    ld      bc, TBBLUE_REGISTER_SELECT_P_243B
    ld      a, TRANSPARENCY_FALLBACK_COL_NR_4A
    out     (c), a

    ; ---- DMA setup (zxnDMA mode, port $6B) ----
    ld      bc, ZXN_DMA_P_6B

    ; 6x DMA_RESET to clear any prior state
    ld      a, DMA_RESET
    out     (c), a
    out     (c), a
    out     (c), a
    out     (c), a
    out     (c), a
    out     (c), a

    ; WR0 ($7D): A->B transfer, port A address + block length follow
    ;   D6=1 port A addr follows, D5=1 block len follows, D3=1 A->B
    ld      a, $7D
    out     (c), a
    ; Port A address = DmaSourceByte
    ld      hl, DmaSourceByte
    out     (c), l               ; low byte
    out     (c), h               ; high byte
    ; Block length = $FFFF (must be >1 so DMA stays in transfer loop
    ; where dma_delay_i is checked after each byte; with len=1 the DMA
    ; goes to FINISH_DMA bypassing the delay check entirely)
    ld      a, $FF
    out     (c), a               ; length low = $FF
    out     (c), a               ; length high = $FF

    ; WR1 ($64): Port A = memory, fixed address, 2T timing follows
    ;   D6=1 timing follows, D5:D4=10 fixed, D3=0 memory
    ld      a, $64
    out     (c), a
    ld      a, $02               ; 2T cycle timing
    out     (c), a

    ; WR2 ($68): Port B = I/O, fixed address, 2T timing follows
    ;   D6=1 timing follows, D5:D4=10 fixed, D3=1 I/O
    ld      a, $68
    out     (c), a
    ld      a, $02               ; 2T cycle timing, no prescalar
    out     (c), a

    ; WR4 ($AD): Continuous mode, port B address follows
    ;   D6:D5=01 continuous, D3:D2=11 port B address follows
    ld      a, $AD
    out     (c), a
    ; Port B address = $253B (NextReg data port)
    ld      a, $3B
    out     (c), a
    ld      a, $25
    out     (c), a

    ; WR5 ($A2): Auto-restart on end of block, /CE only
    ;   D5=1 auto-restart, D1=1 /CE only
    ld      a, $A2
    out     (c), a

    ; DMA_LOAD -> copy programmed addresses into internal pointers
    ld      a, DMA_LOAD
    out     (c), a

    ; ---- VBLANK sync: wait for line 0 for deterministic CTC phase ----
    ld      bc, TBBLUE_REGISTER_SELECT_P_243B
    ld      a, VIDEO_LINE_LSB_NR_1F
    out     (c), a
    inc     b                   ; bc = TBBLUE_REGISTER_ACCESS_P_253B
.waitNotZero:
    in      a, (c)             ; read current video line LSB
    and     a                   ; Z if line == 0
    jr      z, .waitNotZero    ; spin until past line 0
.waitLineZero:
    in      a, (c)
    and     a
    jr      nz, .waitLineZero  ; spin until line wraps to 0

    ; ---- Start CTC: TC=112, period = 112*16 = 1792 clks = one scanline ----
    ld      bc, CTC_PORT
    ld      a, 112
    out     (c), a              ; timer starts, locked to video timing

    ; ---- Re-select NextReg $4A for DMA port B writes ----
    ld      bc, TBBLUE_REGISTER_SELECT_P_243B
    ld      a, TRANSPARENCY_FALLBACK_COL_NR_4A
    out     (c), a

    ; ---- Enable IM2, interrupts, and DMA ----
    im      2
    ld      bc, ZXN_DMA_P_6B
    ld      a, DMA_ENABLE
    ei                          ; interrupts enabled after next instruction
    out     (c), a             ; DMA starts; interrupts now active
    jr      $                  ; infinite loop -- DMA runs, CTC interrupts it
; ============================================================================
; ---- CTC interrupt handler (vector $86) -----------------------------------
; ============================================================================
    org     CTC_HANDLER_ADR

CTC_Handler:
    NEXTREG_nn  TRANSPARENCY_FALLBACK_COL_NR_4A, COL_GREEN
    NEXTREG_nn  TRANSPARENCY_FALLBACK_COL_NR_4A, COL_GREEN
    NEXTREG_nn  TRANSPARENCY_FALLBACK_COL_NR_4A, COL_GREEN
    NEXTREG_nn  TRANSPARENCY_FALLBACK_COL_NR_4A, COL_GREEN
    NEXTREG_nn  TRANSPARENCY_FALLBACK_COL_NR_4A, COL_GREEN
    NEXTREG_nn  TRANSPARENCY_FALLBACK_COL_NR_4A, COL_BLUE
    ei
    reti                        ; DMA resumes -> writes YELLOW again

; ============================================================================
; ---- Default handler for unexpected interrupt vectors ---------------------
; ============================================================================
    org     DEFAULT_HANDLER_ADR

Default_Handler:
    NEXTREG_nn  TRANSPARENCY_FALLBACK_COL_NR_4A, COL_RED
    NEXTREG_nn  TRANSPARENCY_FALLBACK_COL_NR_4A, COL_RED
    NEXTREG_nn  TRANSPARENCY_FALLBACK_COL_NR_4A, COL_RED
    NEXTREG_nn  TRANSPARENCY_FALLBACK_COL_NR_4A, COL_RED
    NEXTREG_nn  TRANSPARENCY_FALLBACK_COL_NR_4A, COL_RED
    ei
    reti

; ============================================================================
; ---- DMA source data ------------------------------------------------------
; ============================================================================
    org     $D300
    ALIGN   256
DmaSourceByte:
    db      COL_YELLOW

; ============================================================================
    savesna SNA_FILENAME, Start
