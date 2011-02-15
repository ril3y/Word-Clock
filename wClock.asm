;*****************************************************************************
; wClock - main file
;*****************************************************************************
;
;    Filename:	    	wClock.asm
;    Function:		Word Clock firmware
;    Author, Company:	Alden Hart, Luke's Lights
;    Revision:		091211
;
;    Chip Support:	Supports PIC18F4520
;    Board Support:	
;
;    Version Notes:
;	091013 - Started conversion from eFruit board
;
;    Key to Status: [xcstv]
;	x = experimental - might not even assemble correctly
;	c = candidate, coded but not necessarily simulated, tested, or validated
;	s = simulated and presumably somewhat tested
;	t = tested on real hardware
;	v = validated - considered to be stable
;
;    TODO BEFORE INSTALLATION:
;	- Scan for all occurrences of ++++ and follow instructions
;

;*****************************************************************************
;******************************* DIRECTIVES **********************************
;*****************************************************************************

#include <global.inc>			; 1: global defines - must be first
#include <DEV_INCLUDE_FILE>		; 2: Our device include file
#include <LED_INCLUDE_FILE>		; 3: LED subsystem include file
#include <APP_INCLUDE_FILE>		; 4: Application include file

;----- MPLIB settings and include files------
					; lower-level includes
	list	t=OFF			; truncate long listing lines
	ERRORLEVEL -302			; turn off register bank messages
;	ERRORLEVEL -306, -302		; turn off crossing page boundary msgs
	EXPAND				; expand macros in disassembly listing	

;------ Exports (globals) -----

	global	app_flags		; used by led_ckt_XXXX, led_fader
	global	cycle_prescale
	global	temp_tblptrh
	global	temp_tblptrl

    if INIT_T0_EXTERNAL
	global	T0_INIT			; use local timer0 init
	global	T0_STOP			; use local timer0 init
	global	T0_START		; use local timer0 start
    endif

;----- Externals -----

	; from d18F____.asm device module
	extern	MASTER_INIT
	extern	WDT_START

	; from led_ckt____.asm circuit module
	extern	chn_num
	extern	ckt_num	
	extern	ckt_level		
	extern	CKT_INIT
	extern	CKT_ISR
	extern	CKT_WRITE_CHANNEL
	extern	CKT_WRITE_CIRCUIT
	extern	T1_START
	extern	UT_CKT
    if MONOCHROME_MODE
	extern	chn_level
    else
	extern	red_level
	extern	grn_level
	extern	blu_level
	extern	hue_level
	extern	sat_level
	extern	brt_level
    endif

	; from led_fader.asm module
	extern	fdr_level
	extern	FDR_DISPATCH
	extern	UT_CMD

	; from led_cue.asm module

	extern	CUE_CLK_READOUT		; application specific symbols
	extern	cue_clk_min		; application specific symbols
	extern	cue_clk_hour		; application specific symbols

	extern	PLAY_INIT		; led_cue.asm general symbols
	extern	CUE_WATCHER		; led_cue.asm general symbols
	extern	UT_PLAY			; led_cue.asm general symbols

	; from led_hsb.asm module
    if MONOCHROME_MODE == FALSE
	extern	HSB_TO_RGB
	extern	UT_HSB
    endif

;------ RAM definitions -----

;##### BANK 0 #####			; shared by modules, allocated by linker
UDATA_BANK_0_ACS	udata_acs

;----- general use variables ----
app_flags	res	1		; application flags (see app.inc file)
cycle_counter	res	1		; counts cycles to deal with prescale
cycle_counter_hi res	1		; just for yuks
cycle_prescale	res	1		; <b6-b0>: 256, 64, 16, 8, 4, 2, 1

clk_hour	res	1		; hours counter (1-12)
clk_min		res	1		; minutes counter (0-59)
clk_sec		res	1		; seconds counter (0-59)
clk_subsec	res	1		; sub-second counter

sw_state	res	1		; state for reading and debouncing switch
sw_debounce	res	1		; switch debounce counter
sw_proc_state	res	1		; state for switch state machine
sw_held_counter	res	1		; down counter for switch held state

temp_tblptrh	res	1		; used by "switch" macro.
temp_tblptrl	res	1		; no other use is permitted!

;----- lo priority ISR variables ----	; I2C subsystem
isrclk_W	res	1		; W reg save
isrclk_status	res	1		; STATUS reg save

;###############################
;##### BEGIN CODE SECTION ######
;###############################

START_OF_CODE	code

;*****************************************************************************
;************************ RESET & INTERRUPT VECTORS **************************
;*****************************************************************************

	org	0x000000	; reset vector	
	nop			; for ICD
	goto	START

	org	0x000008	; high priority interrupt vector
	goto	CLK_ISR
   
	org	0x000018	; low priority interrupt vector
	goto	CKT_ISR

;*****************************************************************************
;******* Initialization and Unit Tests ***************************************
;*****************************************************************************

;----- Device and Sub-System Starts -----
; Be careful of the ordering of these routines. 
; Also, some unit tests might be better run before the full init is done
	
	org	0x00002A		; start code region
				; order
START	call	MASTER_INIT	; 01	; general purpose inits
	call	CKT_INIT	; 02	; initialize circuit driver routines
	call	PLAY_INIT	; 04	; init playlist table & start first list

	call	UNIT_TESTS	; this is a good spot to run these.

	call	T1_START	; 03	; see ckts module
;	call	WDT_START	; 04	; start watchdog timer
	call	CLK_INIT	; 05	; init and start clock routines
	call	SWITCH_INIT

	bsf	INTCON,GIEH	; last-1 ; enable hi and lo interrupts
	bsf	INTCON,GIEL	; last
	bra	MAIN_LOOP	; start the main loop

    if UNITS_ENABLED			; unit testing "framework"
UNIT_TESTS
;	call	UT_CKT		 	; call circuit unit tests
;	call	UT_HSB			; call hsb/rgb unit tests 
;	call	UT_CMD			; call command and fader unit tests
;	call	UT_PLAY			; call playlist and cue unit tests
;	call	UT_MAIN			; call UT's in this file
	return
    endif

;*****************************************************************************
;******* Main Loop ***********************************************************
;*****************************************************************************

; ***** Main Loop *****

MAIN_LOOP				
OUTER	btfsc	app_flags,CYCLE_START_FLAG
	call	CYCLE_PROCESSING	; do fader cycle processing

	btfsc	app_flags,SWITCH_READ_FLAG
	call	SWITCH_PROCESSING

	btfsc	app_flags,SECOND_FLAG	; called once per second
	call	CLK_PROCESSING		; process clock tick from CLK_ISR)

	goto 	OUTER


;******************************************************************************
; CYCLE_PROCESSING
; Perform this on each cycle start
;
; Processing: 
;	- do start-of-cycle tasks such as loading presets and sequences
;	- process the the extra channels next
;	- then go through every channel - running the commands
;	- then do HSB processing and CKT table load if DIRTY_BIT is set
;	- just for yuks break out after each triple for IO

CYCLE_PROCESSING
	clrwdt					; clear the watchdog timer
	bcf	app_flags,CYCLE_START_FLAG	; clear cycle flag
	bsf	app_flags,SWITCH_READ_FLAG
	call	CYCLE_ADVANCE_PRESCALE		; advance prescale to next value

CYC_01	; start-of-cycle processing (watch, presets, sequences)
;	call	CUE_WATCHER		; test WATCH for cue DONE

CYC_02	; process all command channels
	clrf	chn_num
CYC_03	movf	chn_num,W
	call	CYCLE_RUN_CHANNEL
	incf	chn_num,F		; increment to next channel
	movlw	CHN_NUM_MAX+1
	cpfseq	chn_num
	bra	CYC_03

CYC_x	bcf	app_flags,DIRTY_BIT
	return

;---- CYCLE_RUN_CHANNEL - MONOCHROME VERSION ----
; Run a monochrome channel given the channel number
;
; INPUTS: chn_num	channel number to run
;
; Profile: Takes about 450 cycles when it writes, 150 when it doesn't.
; Budgeted as many as 700 cycles for this. Possibilites for optimization:
;	- Organize triplets in contiguous blocks in banks and eliminate the 
;	  SAT and BRT calls to CMD_SET_CMD_TABLE_PTR by simply advancing 
;	  FSR2 manually. Save 18 x 2 cycles minus pointer aritmetic
;	- Build the entire thing into a macro and eliminate calls to
;	  CMD_SET_CMD_TABLE_PTR altogether - save 18 x 3 cycles.

CYCLE_RUN_CHANNEL
	bcf	app_flags,DIRTY_BIT	; clear dirty bit
	call	FDR_DISPATCH		; process fader and return level...
	movff	fdr_level,chn_level	; move fader level to channel level
	btfsc	app_flags,DIRTY_BIT	; skip ahead if not dirty (bit set)
	call	CKT_WRITE_CHANNEL	; write level to CKT table
	return

;---- CYCLE_ADVANCE_PRESCALE ----
; Advance prescale to next value. Prescale bits only "fire" on transitions
;
; INPUTS
;	- cycle_counter			; counts cycles
;	- cycle_prescale		; <b6-b0>: 256, 64, 16, 8, 4, 2, 1
;					; <b7> should be zero
;
; Profile: takes between 25 and 65 cycles, mostly on the lower end of this.

CYCLE_ADVANCE_PRESCALE
	movlw	0x01
	movwf	cycle_prescale		; always set 1
	incf	cycle_counter,F		; advance cycle counter
	bnz	CAP64
	bsf	cycle_prescale,6	; set 256 on all zeros
	incf	cycle_counter_hi,F	; just to keep track of it
CAP64	movf	cycle_counter,W		; test and set 64
	andlw	0x3F
	bnz	CAP16
	bsf	cycle_prescale,5
CAP16	movf	cycle_counter,W		; test and set 16
	andlw	0x0F
	bnz	CAP8
	bsf	cycle_prescale,4
CAP8	movf	cycle_counter,W		; test and set 8
	andlw	0x07
	bnz	CAP4
	bsf	cycle_prescale,3
CAP4	movf	cycle_counter,W		; test and set 4
	andlw	0x03
	bnz	CAP2
	bsf	cycle_prescale,2
CAP2	btfss	cycle_counter,0		; test and set 2
	bsf	cycle_prescale,1
	return

;******************************************************************************
;**** CLOCK ROUTINES **********************************************************
;******************************************************************************
; Control is transfered from one routine to another. Handoff is:
;   CLK_INIT - one time initialization (on reset)
;   CLK_ISR - reads timer, handles seconds (& sub-seconds). Sets TIME_SECOND
;   CLK_PROCESSING - generates full clock count from seconds, calls READOUT
;   CUE_CLK_READOUT - calls cues to read out time. Part of CUE subsystem
;
; Additional routines are:
;   CLK_INCREMENT - increment clock by W minutes
;   CLK_DECREMENT - decrement clock by W minutes
;   T0_INIT  - local version of init to initialize timer0 for the clock
;   T0_STOP  - local version of stop timer0
;   T0_START - local version of start timer0

;******************************************************************************
; CUE_CLK_READOUT - read out time (See led_cue.asm)
;

;******************************************************************************
; CLK_INIT - Initialize clock sub-system

CLK_INIT
	clrf	clk_subsec
	clrf	clk_sec
	clrf	clk_min
	movlw	.1			; start at 1 (not zero)
	movwf	clk_hour
	bcf	app_flags,SECOND_FLAG
	call	T0_START		; start the timer
	return

;******************************************************************************
; CLK_ISR - Implements clock timing and flags clock transitions
;
; INPUTS: <none> 	it's an ISR
;
; USES:	app_flags	; TIME_SECOND flag
;
; Note: This routine could also make use of a sub-second counter, 
; except we use the timer to count out as close to 1 second as we can.

CLK_ISR	movwf	isrclk_W		; save W reg
	movff	STATUS,isrclk_status	; save STATUS reg
	movlw	LOW CLK_TIMER		; reload the timer
	movwf	TMR0L
	movlw	HIGH CLK_TIMER		; load HI last
	movwf	TMR0H
	bsf	app_flags,SECOND_FLAG	; set TIME_SECOND flag
	bcf	INTCON,TMR0IF		; clear timer INT flag or it will keep IRQ'ing
	movf	isrclk_W,W		; restore W reg
	movff	isrclk_status,STATUS	; do this last
	retfie

;******************************************************************************
; CLK_PROCESSING - process the new second (from CLK_ISR)
; CLK_INCREMENT - increment clock by W minutes
; CLK_DECREMENT - decrement clock by W minutes
;
CLK_PROCESSING
	bcf	app_flags,SECOND_FLAG	; clear the seconds flag
	incf	clk_sec,F		; count seconds and process rollover
	movf	clk_sec,W
	sublw	.60
	bnz	CLP_NOREADOUT		; exit without updating display
	clrf	clk_sec			; reset seconds counter
	movlw	1
	call	CLK_INCREMENT		; increment the clock
	movff	clk_hour,cue_clk_hour
	movff	clk_min,cue_clk_min
	call	CUE_CLK_READOUT		; call the clock display routines
CLP_NOREADOUT
	return

;--- CLK_INCREMENT
; increment clock by number of minutes in W

CLK_INCREMENT
	; increment minutes and process minutes rollover
	addwf	clk_min,F		; no carry in
	movf	clk_min,W
	sublw	.59
	bnn	CLK_IX
	clrf	clk_min

	; process hours and 12 hour rollover
	incf	clk_hour,F
	movf	clk_hour,W
	sublw	.13			; hours run 1 - 12 (no zero)
	bnz	CLK_IX
	clrf	clk_hour		; reset hour to '1'
	incf	clk_hour,F
CLK_IX	return

;--- CLK_DECREMENT
; decrement clock by number of minutes in W

CLK_DECREMENT
	; decrement minutes and process minutes rollunder
	subwf	clk_min,F		; no borrow in
	movf	clk_min,W
	bnn	CLK_DX
	addlw	.60			; adjust for 60 min modulus
	movwf	clk_min

	; process hours and 12 hour rollover
	decf	clk_hour,F
	movf	clk_hour,W
	bn	CLK_DH			; kinda ugly but it works
	bz	CLK_DH
	return	
CLK_DH	movlw	.12
	movwf	clk_hour		; reset hour to '12'
CLK_DX	return


;******************************************************************************
; TIMER0 is used for CLOCK routines
; T0_INIT  - Initialize timer0
; T0_STOP  - Stop timer0
; T0_START - Start timer0

;T0CON_INIT	equ	b'00000000'	; TEST VALUE - NO PRESCALER
T0CON_INIT	equ	b'00000110'	; 7 - TMR0ON = 0 (0FF, see pg 123)
					; 6 - T08BIT = 0 (as 16 bit timer)
					; 5 - T0CS = 0 (internal clock)
					; 4 - TOSC = 0 (lo to hi transition)
					; 3 - PSA = 0 (use the prescaler)
					; 2-0 T0PS = 110 (128 prescale)

T0CON_START	equ	T0CON_INIT | 0x80 ; TMR0ON = 1 (0N)
TMR0L_INIT	equ	LOW CLK_TIMER	; initial LO value
TMR0H_INIT	equ	HIGH CLK_TIMER	; initial HI value

T0_INIT
T0_STOP	movlw	T0CON_INIT
	movwf	T0CON
	bcf	INTCON,TMR0IF		; clear interrupt flag
	bcf	INTCON,TMR0IE 		; disable interrupts
	return

T0_START 
	movlw	T0CON_START
	movwf	T0CON
	movlw	TMR0L_INIT
	movwf	TMR0L
	movlw	TMR0H_INIT
	movwf	TMR0H
	bcf	INTCON,TMR0IF		; clear interrupt flag
	bsf	INTCON,TMR0IE 		; enable interrupts
	bsf	INTCON2,TMR0IP		; 1 = high priority
;	bcf	INTCON2,TMR0IP		; 0 = low priority
	return


;******************************************************************************
;**** SWITCH ROUTINES *********************************************************
;******************************************************************************

SWITCH_INIT
	bcf	app_flags,SWITCH_READ_FLAG
	clrf	sw_state			; reset debounce state
	clrf	sw_proc_state			; reset processing state
	return

;*****************************************************************************
; SWITCH_PROCESSING - executed on each switch read cycle
;
; The switch is read once every LED cycle (6.66 ms). 
; The switch is processed at 2 layers:
;   - switch read and debounce layer - returns clean switch state
;   - processing layer - what to do about it. 
;
; Simple state machine for switch processing:
;
;    SW_NOT_PRESSED - Button is not pushed
; 	Take no action.
;
;    SW_PRESSED - Button just pushed
;	Increment clock by 5 minutes and and read out
;	Start switch_held down-counter
;	Transition to SW_PROC_STATE_HELD
;
;    SW_HELD - Button held down
;	If switch released (READ_STATE_ON = 0), revert to NOT_PRESSED state
;	Count down switch_held counter
;	If counter goes to zero, 
;	   - increment by 5 minutes and read out
;	   - restart counter

SWITCH_PROCESSING
	; determine current switch state and perform debouncing
	bcf	app_flags,SWITCH_READ_FLAG	; clear switch flag
	call	SWITCH_READ			; read switch state

	; dispatch on state bits
	btfss	sw_state,SW_STATE_ON_bp		; test if switch is on
	return					; return if sw is off
	btfsc	sw_state,SW_STATE_RISING_bp	; test if rising edge
	bra	SW_RISING
	; fall through to ON state

SW_ON		; execute this code block if switch is ON and not RISING
	decf	sw_held_counter,F
	btfss	STATUS,Z
	return		
	; falls through to rising which acts like an auto-button push

SW_RISING	; execute this code block on RISING edge	
	movlw	SW_HELD_COUNT			; load hold counter
	movwf	sw_held_counter
	movlw	.05
	call	CLK_INCREMENT			; increment the clock
	movff	clk_hour,cue_clk_hour
	movff	clk_min,cue_clk_min
	call	CUE_CLK_READOUT			; call clock display routines
	return

;*****************************************************************************
; SWITCH_READ ...and debouncing
; 
; A switch has 3 state bits: ON/OFF, RISING, FALLING. 
; These are reported as bits in sw_read_state: 
;
;    SW_STATE_ON_bp	1 = switch is on, 0 = switch is off
;    SW_STATE_RISING_bp	1 = switch has just turned on. Persists for 1 read pass
;    SW_STATE_FALLING_bp 1 = switch has just turned off. Persists for 1 read pass
;
; Debounce interval is controlled via SW_DEBOUNCE_MAX. The debounce counter 
; counts to max to turn on, down to 1 to turn off.

SWITCH_READ
	bcf	sw_state,SW_STATE_RISING_bp	; clear previous rising state
	bcf	sw_state,SW_STATE_FALLING_bp	; clear previous falling state
	btfsc	sw_state,SW_STATE_ON_bp		; branch on current ON/OFF state	
	goto	PS_ON

PS_OFF	btfsc	switch01p,switch01b		; skip if switch is closed (0)
	return					; switch open: exit w/no changes
	incf	sw_debounce,F			; increment debounce counter
	movf	sw_debounce,W
	sublw	SW_DEBOUNCE_MAX			; test against max
	btfss	STATUS,N
	return					; exit - remain in OFF state
	bsf	sw_state,SW_STATE_RISING_bp	; sw closed - set rising edge...
	bsf	sw_state,SW_STATE_ON_bp		;...and ON state
	return

PS_ON	btfss	switch01p,switch01b		; skip if switch is open (1)
	return					; switch closed: exit w/no changes
	decf	sw_debounce,F			; decrement debounce counter
	movf	sw_debounce,W
	btfss	STATUS,Z
	return					; exit - remain in ON state
	bsf	sw_state,SW_STATE_FALLING_bp	; sw opened - sef falling edge...
	bcf	sw_state,SW_STATE_ON_bp		;...and OFF state
	return


;*****************************************************************************
;***** UNIT TESTS ************************************************************
;*****************************************************************************

UT_MAIN
    if UNITS_ENABLED
;	goto	UT_CYCLE_ADVANCE_PRESCALE ; never returns
;	goto	UT_CYCLE_RUN_CHANNEL	  ; never returns
;	call	UT_TEST_CLOCK		; test clock functions
	call	UT_CYCLE_PROCESSING
    endif
	return

    if UNITS_ENABLED

UT_CYCLE_ADVANCE_PRESCALE
	movlw	0xFD
	movwf	cycle_counter
UTCAP	call	CYCLE_ADVANCE_PRESCALE	
	goto	UTCAP

UT_CYCLE_RUN_CHANNEL
	movlw	0x03
UTRCRT	call	CYCLE_ADVANCE_PRESCALE	
	call	CYCLE_RUN_CHANNEL
	goto	UTRCRT

UT_TEST_CLOCK
	call	CLK_INIT
UT_CLKX	movlw	.17
;	call	CLK_DECREMENT
;	call	CLK_INCREMENT
	bra	UT_CLKX

UT_CYCLE_PROCESSING
	call	CYCLE_PROCESSING	
	return
    endif		; end unit tests

    if FALSE
; Switch diagnostics
_SWITCH_READOUT	; load ckt 23 (TEN) with switch state. CLOSED = LIT
	bsf	PORTA,5
	btfss	PORTA,0
	bcf	PORTA,5
	
;	movlw	0xFF	
;	btfss	sw_read_state,SW_STATE_ON
;	movlw	0x00
;	movwf	ckt_level
;	movlw	.23
;	movwf	ckt_num
;	call	CKT_WRITE_CIRCUIT
	return	

_SWITCH_TEN_ON
	bcf	PORTA,5
;	movlw	0xFF	
;	movwf	ckt_level
;	movlw	.23
;	movwf	ckt_num
;	call	CKT_WRITE_CIRCUIT
	return

_SWITCH_TEN_OFF
	bsf	PORTA,5
;	movlw	0x00	
;	movwf	ckt_level
;	movlw	.23
;	movwf	ckt_num
;	call	CKT_WRITE_CIRCUIT
	return
    endif		; end switch diagnostics

	END                       	; directive 'end of program'

