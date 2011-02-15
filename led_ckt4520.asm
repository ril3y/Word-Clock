;*****************************************************************************
; led_ckt2520.asm - ports and circuit drivers (dimmers) for 18F2420 / 2520
;*****************************************************************************
;
;    Filename:	    	led_ckt4520.asm
;    Author:		Alden Hartf
;    Company: 		Luke's Lights
;    Copyright:		Alden Hart (c) 2009
;    Board Support:	Supports PIC18F4520 on Board 127, monochrome
;    Revision:		091016
;
;    Description: This module provides the following low-level support:
;	- port initialization
;	- all circuit table functions, including circuit table load and readout
;	- control of timer1 setup and ISR for readout functions
;	- port/bit mapping to specific circuit boards and board revisions
;	- isolation of port bit assignment and dependencies
;

;****************************************************************************
; PORT MAP
;
; 	   Bit:	7	6	5	4	3	2	1	0
;	     ---------------------------------------------------------------
; PORTA:	TWO	IT'S	SIX	TEN	SEVEN'L	ELEV'L	ELEV'R	SWITCH
; PORTB:	PLUS1	PLUS2	PLUS3	PLUS4	OCLK'R	OCLK'L	TWEL'L	TWEL'R
; PORTC:	THREE'R	MIN'R	MIN'L	TO	HALF	PAST	TWEN'R	TWEN'L	
; PORTD:	SEVEN'R	EIGHT	FOUR	THREE'L	QUAR'R	QUAR'L	TEN_	FIVE_
; PORTE:	--	--	--	--	--	ONE	FIVE	NINE
;
; KEY:	'_' suffix denotes FIVE to, TEN past... "prefix" copies of FIVE and TEN
;	'L' suffix denotes left LED on paired LEDs
;	'R' suffix denites right LED on paired LEDs
;	'SWITCH' is the time-set switch port
;
; Notes: If you change the arrangement of LEDs you will (or may) need to change:
;	- Port Definitions
;	- CKT_CHANNEL_MAP
;	- CKT_WRITE_B0_OFFSET
;	- CKT_WRITE_BITMASK
;	- if you don't use all 5 ports you have to change a lot (removing LATE)
;	- May need to change the format of the circuit table and all that 
;	  implies (WRITE routines, ISR readouts, CKT_TABLE_LEN value, 
;	  CKT_TABLE_INCREMENT, etc.)
;
; 	We will need to get RA6 and RA7 back for the oscillator. Steal the right 
; 	LEDs from THREE and SEVEN. So only make the circuit table run 32 lights
;	over 5 ports. Many things will need to be remapped.

;******************************************************************************
;***** Circuit Table Routines - Background ************************************
;******************************************************************************
;
; Routines exist for the following:
;
;   - CKT_INIT		  Initialize circuit values, ports and table
;   - CKT_ISR		  ISR to work the time and read out next row
;   - CKT_WRITE_CIRCUIT	  Write a single mono, R, G, or B byte value into table
;   - CKT_WRITE_CHANNEL	  Write a mono or RGB triplet into the circuit table
;   - PORT_INIT		  Local routine overrides port init in main device file
;   - T1_INIT		  Local routine overrides timer1 init in main device file
;
;***** Circuit Table Modified Bit Angle Modulation (MBAM) ISR Handler *****
;
; In standard bit angle modulation the LEDs are turned on for a time interval 
; proportional to the bit value, as so:
;
;	b0 = 1/256 of a cycle
;	b1 = 1/128 of a cycle
;	b2 = 1/64 of a cycle
;	b3 = 1/32 of a cycle
;	b4 = 1/16 of a cycle
;	b5 = 1/8 of a cycle
;	b6 = 1/4 of a cycle
;	b7 = 1/2 of a cycle
;
; This would require timing out 8 intervals, bit 0 - bit 7. This is a huge 
; savings over the 256 intervals required to perform software PWM (yes, I know, 
; there are ways to get this down, but they are never less than the number of
; unique brightnesses at any given time, which is usually close to the number 
; of distinct circuits, and this type of optimized PWM is very complicated).
;
; This ISR uses a modified BAM scheme in order to smooth out the fade 
; transitions (glitches) when crossing over between high-order bits. The bit6 
; and bit7 intervals are broken into 2 and 4 intervals (respectively) of bit5 
; timing. The following pattern is actually executed:
;
;	b0, b1, b2, b3, b4, b7a, b5, b7b, b6a, b7c, b6b, b7d
;
; ...making for a total of 12 bit timing intervals per cycle.
;
; Further, each bit is split into 2 phases - an ON phase and an OFF phase. 
; This is to duty-cycle the LEDS to get rid of the resistors. A typical duty 
; cycle is about 25% - 33% ON time of the available bit width.
;
; ...so the final total is 24 intervals that must be timed. The cycles run at 
; 150 Hz, so these 24 ISRs execute per each 6.667 mSec cycle.
;
;
;***** Monochrome versus Color Operation *****
;
; The LED subsystem can be run in either monochrome or color mode. In 
; monochrome mode each LED is a single color, and channels generally correspond
; directly to circuits. There are exceptions for parallel circuits which are 
; discussed later. In color mode each channel consists of a triplet that is 
; computed and manipulated in HSB, converted to RGB, then output to the three 
; RGB circuits that make up that channel. An attempt has been made to generalize
; the code to work in either mode - within practical limitations. The switch 
; 'MONOCHROME_MODE' in led.inc is set TRUE if monochrome mode is enabled; 
; otherwise color mode is operative.
;
; There are two WRITE routines that write data to the circuit table. 
; 
; CKT_WRITE_CIRCUIT works at the circuit level - writing a level (byte) to 
; the designated circuit. This routine writes the raw level provided into the 
; table, abstracting the table layout from the caller. No level conversion or
; conditioning is performed on the raw level value.
;
; CKT_WRITE_CHANNEL works at the channel level and works differently depending 
; on the mode. In monochrome mode it writes a single level to the circuit table. 
; It performs level conditioning (non-linear transformation to smooth out the 
; low level fades). Is some applications (like this one) it may also "parallel"
; a channel to be written to multiple circuits.
; 
; In color mode WRITE_CHANNEL accepts and HSB triple as input, converts it to
; RGB, with level conditioning, element matching, and white balance; then 
; writes the results into the correct circuits. WRITE_CHANNEL usually calls 
; WRITE_CIRCUIT to write the circuit table, but may bypass WRITE_CIRCUIT 
; and implement its own table write functions directly. This rule violation 
; is sometimes necessary to achieve the write speeds (it's easy to optimize 
; three writes by saving table setup time)
; 

;----- MPLIB settings and include files ------

#include <global.inc>			; 1: global defines - must be first
#include <DEV_INCLUDE_FILE>		; 2: Our device include file
#include <LED_INCLUDE_FILE>		; 3: LED subsystem include file
#include <APP_INCLUDE_FILE>		; 4: Application include file

;------ Exports (globals) -----

	global	chn_num			; channel number
	global	ckt_num			; circuit number
	global	ckt_level		; circuit level
	global	CKT_INIT		; circuit sub-system inits
	global	CKT_ISR			; ISR to read out next row
	global	CKT_WRITE_CIRCUIT	; write a mono or R,G, or B byte into ckt table
	global	CKT_WRITE_CHANNEL	; write a mono value or RGB triplet to ckt table

    if INIT_PORTS_EXTERNAL
	global	PORT_INIT		; use local port initializations
    endif
    if INIT_T1_EXTERNAL
	global	T1_INIT			; use local timer1 init
	global	T1_STOP			; use local timer1 init
	global	T1_START		; use local timer1 start
    endif

    if MONOCHROME_MODE
	global	chn_level		; channel level
    else
	global 	red_level		; need all these level for color mode
	global 	grn_level
	global 	blu_level
	global 	hue_level
	global 	sat_level
	global 	brt_level
    endif

	global	UT_CKT			; circuit unit tests

;----- External variables -----

	extern	app_flags

;---- Port Definitions ----		; from portmap, above
; LED driver bits...
; If we were doing bit operations to test, set and clear bits (btfss, bsf, bcf)
; we would need the following forms:
;    CKT_00p	equ	LATA		; PORT A
;    CKT_00b	equ	.6		; BIT 6
;
; But we are doing port register loads and bitmasking so we need the following:
baseA	equ	0x00			; offset into ckt_table for port A bits
baseB	equ	0x01
baseC	equ	0x02
baseD	equ	0x03
baseE	equ	0x04

mask0	equ	0x01			; bitmask mask definitions
mask1	equ	0x02
mask2	equ	0x04
mask3	equ	0x08
mask4	equ	0x10
mask5	equ	0x20
mask6	equ	0x40
mask7	equ	0x80

; To convert between them run search and replace on:
;	LAT ---> base
;	'.' ---> mask 	(and vice versa)

CKT_00p		equ	baseC		; D1 (IT'S)
CKT_00b		equ	mask1

CKT_01p		equ	baseD		; D2 (HALF)
CKT_01b		equ	mask0
CKT_02p		equ	baseD		; D3 (TEN)
CKT_02b		equ	mask2
CKT_03p		equ	baseD		; D4 (QUARTER left)
CKT_03b		equ	mask3
CKT_04p		equ	baseC		; D5 (QUARTER right)
CKT_04b		equ	mask5

CKT_05p		equ	baseC		; D6 (TWENTY left)
CKT_05b		equ	mask0
CKT_06p		equ	baseC		; D7 (TWENTY right)
CKT_06b		equ	mask3
CKT_07p		equ	baseD		; D8 (FIVE)
CKT_07b		equ	mask1
CKT_08p		equ	baseC		; D9 (MINUTES left)
CKT_08b		equ	mask6
CKT_09p		equ	baseD		; D10 (MINUTES right)
CKT_09b		equ	mask5

CKT_10p		equ	baseC		; D11 (PAST)
CKT_10b		equ	mask2
CKT_11p		equ	baseC		; D12 (TO)
CKT_11b		equ	mask4

CKT_12p		equ	baseE		; D13 (ONE)
CKT_12b		equ	mask2
CKT_13p		equ	baseB		; D14 (TWO)
CKT_13b		equ	mask1
CKT_14p		equ	baseD		; D15 (THREE left)
CKT_14b		equ	mask4
CKT_15p		equ	baseC		; D16 (THREE right)
CKT_15b		equ	mask7
CKT_16p		equ	baseD		; D17 (FOUR)
CKT_16b		equ	mask6

CKT_17p		equ	baseE		; D18 (FIVE)
CKT_17b		equ	mask1
CKT_18p		equ	baseA		; D19 (SIX)
CKT_18b		equ	mask5
CKT_19p		equ	baseA		; D20 (SEVEN left)
CKT_19b		equ	mask3
CKT_20p		equ	baseD		; D21 (SEVEN right)
CKT_20b		equ	mask7
CKT_21p		equ	baseB		; D22 (EIGHT)
CKT_21b		equ	mask0

CKT_22p		equ	baseE		; D23 (NINE)
CKT_22b		equ	mask0
CKT_23p		equ	baseA		; D24 (TEN)
CKT_23b		equ	mask4
CKT_24p		equ	baseA		; D25 (ELEVEN left)
CKT_24b		equ	mask2
CKT_25p		equ	baseA		; D26 (ELEVEN right)
CKT_25b		equ	mask1
CKT_26p		equ	baseB		; D27 (TWELVE left)
CKT_26b		equ	mask5
CKT_27p		equ	baseB		; D28 (TWELVE right)
CKT_27b		equ	mask4

CKT_28p		equ	baseB		; D29 (O'CLOCK left)
CKT_28b		equ	mask2
CKT_29p		equ	baseB		; D30 (O'CLOCK right)
CKT_29b		equ	mask3
;CKT_30p		equ	base		; D31 (PLUS 1)
;CKT_30b		equ	mask
;CKT_31p		equ	base		; D32 (PLUS 2)
;CKT_31b		equ	mask
;CKT_32p		equ	base		; D33 (PLUS 3)
;CKT_32b		equ	mask
;CKT_33p		equ	base		; D34 (PLUS 4)
;CKT_33b		equ	mask

;---- Circuit timer settings, 150 Hz ----
; See "Ballasting" tab in spreadsheet for timing computation
; Note: B0_ON cannot be so narrow that the timer expires before the ISR exits.

CKT_TMR_B0_ON	equ	0xFFBF			; bit 0 ON timing
CKT_TMR_B0_OFF	equ	0xFF71			; bit 0 OFF timing

CKT_TMR_B1_ON	equ	0xFF71
CKT_TMR_B1_OFF	equ	0xFED4

CKT_TMR_B2_ON	equ	0xFED4
CKT_TMR_B2_OFF	equ	0xFD9A

CKT_TMR_B3_ON	equ	0xFD9A
CKT_TMR_B3_OFF	equ	0xFB27

CKT_TMR_B4_ON	equ	0xFB27
CKT_TMR_B4_OFF	equ	0xF640

CKT_TMR_B5_ON	equ	0xF640
CKT_TMR_B5_OFF	equ	0xEC72

; Bit6 and bit7 timings are actually not used but are here for completeness
CKT_TMR_B6_ON	equ	0xEC72			
CKT_TMR_B6_OFF	equ	0xD8D6
CKT_TMR_B7_ON	equ	0xD8D6
CKT_TMR_B7_OFF	equ	0xB19E


;*****************************************************************************
;**************************** RAM DEFINITIONS ********************************
;*****************************************************************************

;##### BANK 0 #####
UDATA_BANK_0_ACS	udata_acs	; linker allocates space in bank 0

;----- BAM ISR variables ----		; regs for use only by BAM timer ISR
isrckt_W	res	1		; W reg save
isrckt_status	res	1		; STATUS reg save
isrckt_index	res	1		; index for dispatcher

;----- shared circuit variables ----
; In MONOCHROME MODE circuit number is simple. In COLOR MODE its encoded thusly:
; ckt_num - encoded as:
;     <b4-b2> 	channel 0 - channel 7
;     <b1-b0> 	00 = HUE
;		01 = SAT
;		01 = BRT
;		11 = EXTRA - extra command channels: <none> are valid

ckt_num		res	1		; encoded circuit number as above
ckt_temp	res	1		; temp for circuit routines
ckt_level	res	1		; level to set
ckt_offset	res	1		; offset into circuit table
ckt_ormask	res	1		; OR bitmask
ckt_andmask	res	1		; AND bitmask
ckt_table res	CKT_TABLE_LEN+1		; LED readout table
#define ct ckt_table			; shorthand

;----- variables used for channels and levels

chn_num		res	1		; active channel number

    if MONOCHROME_MODE
chn_level	res	1
    else
red_level	res	1
grn_level	res	1
blu_level	res	1
hue_level	res	1
sat_level	res	1
brt_level	res	1
    endif

;----- variables used for unit testing

    if UNITS_ENABLED
ut_delay_hi	res	1
ut_delay_lo	res	1
ut_loop		res	1
    endif

;###############################
;##### BEGIN CODE SECTION ######
;###############################

CODE_LED_CIRCUIT_DRIVERS	code

;******************************************************************************
; CKT_INIT
; Initialize circuit sub-system

CKT_INIT
	; set all active port bits to OFF
	movlw	~TRISA_INIT		
	movwf	LATA
	movlw	~TRISB_INIT
	movwf	LATB
	movlw	~TRISC_INIT
	movwf	LATC
	movlw	~TRISD_INIT
	movwf	LATD
	movlw	~TRISE_INIT
	movwf	LATE

	; initialize ISR dispatcher index
	clrf	isrckt_index

	; set circuit table to 0xFF (turn all circuits OFF)
	lfsr	FSR0,ckt_table+CKT_TABLE_LEN ; clear down from top table address
CKT_IN0	movlw	0xFF
	movwf	POSTDEC0
	movlw	ckt_table
	cpfslt	FSR0L
	bra	CKT_IN0
	return

;******************************************************************************
; CKT_ISR - Bit Angle Modulation (BAM) Handler
;
; Implements BAM dimming and sofwtare ballasting. See spreadsheet for details.
;
; INPUTS: <none> 	it's an ISR
;
; NOTE: THIS ISR HAD TO BE RE_WRITTEN TO USE A DISPATCH TABLE AS USING THE 
; TBLPTR ACROSS ISR AND MAIN CODE SEEMS TO HAVE A BUG IN IT (EVEN WHEN BEING 
; VERY CAREFUL TO PRESERVE THE TABLE POINTER BETWEEN THE REGIONS.
;
; An alternative that's more robust to the page crossing issue is to keep a 
; vector of the next state and dispatch through the vector. This actually uses 
; a few more cycles than the jump table approach, and one more register variable.
;
; Notes on functions: The dispatcher uses an index counter that starts at 0 
; (for _b0on) and increments each time the ISR is called. It resets to zero 
; when the last interval is run. The dispatcher calls a diffferent macro for each 
; pass through the ISR, with the last pass ('X') reseting the index counter to 0.
; 
; Profile: XX instruction cycles, Y.Y uSec at 32 MHz

CKT_ISR	
	movwf	isrckt_W		; save W reg
	movff	STATUS,isrckt_status	; save STATUS reg

	;#### THIS CODE SEGMENT CANNOT CROSS A 0x100 PROGRAM MEMORY BOUNDARY
	movlw	HIGH CKI_JMP
	movwf	PCLATH
	rlncf	isrckt_index,W		; get index x2 into W...
	addlw	LOW CKI_JMP		;...this only works with BRAs 
	movwf	PCL			;...GOTOs require x4

CKI_JMP	bra	_b0on			; dispatch to bit 0, ON phase
	bra	_b0off
	bra	_b1on			; bit 1
	bra	_b1off
	bra	_b2on			; bit 2
	bra	_b2off
	bra	_b3on			; bit 3
	bra	_b3off
	bra	_b4on			; bit 4
	bra	_b4off	; this dispatch sequence performs the b6/b7 scramble
	bra	_b7on			; bit 7a  
	bra	_b7off		
	bra	_b5on			; bit 5
	bra	_b5off
	bra	_b7on			; bit 7b
	bra	_b7off
	bra	_b6on			; bit 6a
	bra	_b6off
	bra	_b7on			; bit 7c
	bra	_b7off
	bra	_b6on			; bit 6b
	bra	_b6off
	bra	_b7on			; bit 7d
	bra	_b7offX	; <--- needs to be this one to reset isr_index
	; #### TO HERE

	; return point for BRA table routines
CKI_RET	movf	isrckt_W,W		; restore state and return
	bcf	PIR1,TMR1IF		; clear timer INT flag or it will keep IRQ'ing
	movff	isrckt_status,STATUS	; do this last
	retfie

;---- CKT_ISR bit/phase handlers -----
; The macro call arguments are really brute force and ugly becuase I can't get 
; MPASM to behave when interpreting more complex expressions. Bueller?

; _bp_on macro parameters:
;   - timer		16 bit time value for timing out rest of this interval
;   - portA - portE	offsets for the port/bit being set

_bp_on	macro	tmr, portA, portB, portC, portD, portE 
	movlw	HIGH tmr		; load timer for this ON interval
	movwf	TMR1H
	movlw	LOW tmr
	movwf	TMR1L
	incf	isrckt_index,F		; increment dispatch index
	movff	portA,LATA		; dump table bits to ports
	movff	portB,LATB
	movff	portC,LATC
	movff	portD,LATD
	movff	portE,LATE
	bra	CKI_RET			; return to main ISR
	endm

; _bp_off macro parameters:
;   - timer		16 bit time value for timing out rest of this interval
;   - cycle_start	set TRUE to set new cycle flag (FALSE to ignore)

_bp_off	macro	tmr, cycle_start
	movlw	HIGH tmr		; load timer for this OFF interval
	movwf	TMR1H
	movlw	LOW tmr
	movwf	TMR1L
	incf	isrckt_index,F		; increment dispatch index
	movlw	~TRISA_INIT		; set all active bits to OFF
	movwf	LATA
	movlw	~TRISB_INIT
	movwf	LATB
	movlw	~TRISC_INIT
	movwf	LATC
	movlw	~TRISD_INIT
	movwf	LATD
	movlw	~TRISE_INIT
	movwf	LATE
    if cycle_start				; conditional assembly
	bsf	app_flags,CYCLE_START_FLAG	; start a new cycle
    endif
	bra	CKI_RET			; return to main ISR
	endm

; Last off cycle: same as _bp_off except resets dispatcher index as well
_bp_offX  macro  timer
	movlw	HIGH timer		; reset timer
	movwf	TMR1H
	movlw	LOW timer
	movwf	TMR1L
	clrf	isrckt_index		; reset dispatch index
	movlw	~TRISA_INIT		; set all active bits to OFF
	movwf	LATA
	movlw	~TRISB_INIT
	movwf	LATB
	movlw	~TRISC_INIT
	movwf	LATC
	movlw	~TRISD_INIT
	movwf	LATD
	movlw	~TRISE_INIT
	movwf	LATE
	bra	CKI_RET			; return to main ISR
	endm

; Actual dispatched macro lines. Each line is a complete macro that returns
; to the ISR. They do not execute in sequence like instructions.

_b0on	_bp_on	CKT_TMR_B0_ON, ct+.0, ct+.1, ct+.2, ct+.3, ct+.4
_b0off	_bp_off	CKT_TMR_B0_OFF, FALSE
_b1on	_bp_on	CKT_TMR_B1_ON, ct+.5, ct+.6, ct+.7, ct+.8, ct+.9
_b1off	_bp_off	CKT_TMR_B1_OFF, FALSE
_b2on	_bp_on	CKT_TMR_B2_ON, ct+.10, ct+.11, ct+.12, ct+.13, ct+.14
_b2off	_bp_off	CKT_TMR_B2_OFF, FALSE
_b3on	_bp_on	CKT_TMR_B3_ON, ct+.15, ct+.16, ct+.17, ct+.18, ct+.19
_b3off	_bp_off	CKT_TMR_B3_OFF, FALSE
_b4on	_bp_on	CKT_TMR_B4_ON, ct+.20, ct+.21, ct+.22, ct+.23, ct+.24
_b4off	_bp_off	CKT_TMR_B4_OFF, FALSE
_b5on	_bp_on	CKT_TMR_B5_ON, ct+.25, ct+.26, ct+.27, ct+.28, ct+.29
_b5off	_bp_off	CKT_TMR_B5_OFF, TRUE	; START CYCLE ON THIS SLICE
_b6on	_bp_on	CKT_TMR_B5_ON, ct+.30, ct+.31, ct+.32, ct+.33, ct+.34
_b6off	_bp_off	CKT_TMR_B5_OFF, FALSE
_b7on	_bp_on	CKT_TMR_B5_ON, ct+.35, ct+.36, ct+.37, ct+.38, ct+.39
_b7off	_bp_off	CKT_TMR_B5_OFF, FALSE
_b7offX _bp_offX CKT_TMR_B5_OFF

; test versions of bit 0 - no macros
    if FALSE
_b0on	movlw	HIGH CKT_TMR_B0_ON	; load timer for this ON interval
	movwf	TMR1H
	movlw	LOW CKT_TMR_B0_ON
	movwf	TMR1L
	incf	isrckt_index,F		; increment dispatch index
	movff	ct+.0,LATA		; dump table bits to ports
	movff	ct+.1,LATB
	movff	ct+.2,LATC
	movff	ct+.3,LATD
	movff	ct+.4,LATE
	bra	CKI_RET			; return to main ISR

_b0off	movlw	HIGH CKT_TMR_B0_OFF	; load timer for this OFF interval
	movwf	TMR1H
	movlw	LOW CKT_TMR_B0_OFF
	movwf	TMR1L
	incf	isrckt_index,F		; increment dispatch index
	movlw	~TRISA_INIT		; set all active bits to OFF
	movwf	LATA
	movlw	~TRISB_INIT
	movwf	LATB
	movlw	~TRISC_INIT
	movwf	LATC
	movlw	~TRISD_INIT
	movwf	LATD
	movlw	~TRISE_INIT
	movwf	LATE
	bra	CKI_RET			; return to main ISR
    endif

;******************************************************************************
; CKT_WRITE_CHANNEL
;
; Write a channel. This is either a mono channel or an RGB channel. 
; In RGB versions it may either use the write_circuit routine three times, 
; or may implement a more efficient write to the circuit tables (bypassing 
; the write_circuit routine).
;
; This monochrome version abstracts the channel number to one or two LEDs, 
; as some clock display cells have one LED while others have two.
;
; INPUTS:
;	- chn_num	channel number to write to table
;	- chn_level	value to write to table
;
; RETURNS:
;	<none> - except for writing into the circuit table
;
; PROFILE: XXX instructions, YYY uSeconds at 32 MHz.
;
; NOTE: Channel mapping tables follow CKT_WRITE_CIRCUIT

CKT_WRITE_CHANNEL
	movf	chn_num,W
	call	CKT_CHECK_CHNNUM
	bnz	CWC_x			; skip the write if bad channel num

	; get circuit number(s) and write circuits
	; (doing it this way because CKT_WRITE_CIRCUIT also uses tables) 
	tblindx	CKT_CHANNEL_MAP,chn_num
	tblrd*+				; get first circuit number
	movff	TABLAT,ckt_num
	tblrd*				; get optional second circuit number
	movff	TABLAT,ckt_temp
	movff	chn_level,ckt_level	; set circuit level
	call	CKT_WRITE_CIRCUIT	; write first circuit
	movf	ckt_temp,W		; recover second circuit number
	movwf	ckt_num			; can't use movff here, no status bits
	bn	CWC_x			; no ckt = 0xFF, which is negative
	call	CKT_WRITE_CIRCUIT	; write (optional) second circuit
CWC_x	return

;******************************************************************************
; CKT_WRITE_CIRCUIT
;
; Write a single level value to the circuit table. This is the lower level 
; routine to write_channel.
;
; This version has the following parameters:
;	- Number of circuits = 34
;	- Works in monochrome (not RGB)
;	- Byte pattern in circuit table is transposed for readout efficiency
;	- Bit sense is inverted: 1=off, 0=on (and init sets to all 0xFF)
;
; This particular version writes monochrome levels (bytes) into the ckt table
; in transposed, inverted bit form over five ports as per the following pattern:
;
; 	Table entry 00 (0x00):	Bit 0 - Port A
;		    01 (0x01):	Bit 0 - Port B
;		    02 (0x02):	Bit 0 - Port C
;		    03 (0x03):	Bit 0 - Port D
;		    04 (0x04):	Bit 0 - Port E
;		    05 (0x05):	Bit 1 - Port A
;		    ....
;		    39 (0x27):	Bit 7 - Port E
;
; INPUTS:
;	- ckt_num	encoded circuit number (see ckt_num declaration)
;	- ckt_level	value to write to table
;
; RETURNS:
;	<none> - except for writing into the circuit table
;
; PROFILE: 116 instructions, 14.5 uSeconds at 32 MHz.

CKT_WRITE_CIRCUIT
	movf	ckt_num,W
	call	CKT_CHECK_CKTNUM
	bnz	CWK_x			; skip the write if bad circuit num

	; retrieve b0 offset and bitmasks from the table
	tblindx	CKT_WRITE_PARAMETERS,ckt_num
	tblrd*+				; get b0 offset
	movff	TABLAT,ckt_offset
	tblrd*				; get bitmasks
	movf	TABLAT,W
	movwf	ckt_ormask
	xorlw	0xFF
	movwf	ckt_andmask
	
	; set FSR1 to base of ckt_table b0
	clrf	FSR1H			; assumes ckt_table is in page zero...
	movlw	ckt_table
	addwf	ckt_offset,W
	movwf	FSR1L			; ...and does not span memory pages

	; macro to test and set a table bit (actually test and clear)
cws_bit macro	bit
	movf	ckt_ormask,W		; get the OR mask
	iorwf	INDF1,F			; always set the bit in table (turn OFF)
	movf	ckt_andmask,W		; get the AND mask
	btfsc	ckt_level,bit		; test if bit is set in level (ON)
	andwf	INDF1,F			; clear the bit in the table (turn ON)
	movlw	CKT_TABLE_INCREMENT	; increment FSR1 to next byte position
	addwf	FSR1L
	endm

	; scan the table and set or clear bits from b0 to b7
	cws_bit 0			; do bit 0
	cws_bit 1
	cws_bit 2
	cws_bit 3
	cws_bit 4
	cws_bit 5
	cws_bit 6
					; do bit 7, finish up
	movf	ckt_ormask,W		; get the OR mask
	iorwf	INDF1,F			; always set the bit in table (turn OFF)
	movf	ckt_andmask,W		; get the AND mask
	btfsc	ckt_level,7		; test if bit is set in level (ON)
	andwf	INDF1,F			; clear the bit in the table (turn ON)
CWK_x	return    

;***** CHANNEL AND CIRCUIT MAPPING TABLES *****

DATA_CIRCUIT_MAP_TABLES  code_pack	; new code_pack region must have a label

; Table for mapping circuits to channels. Each entry (channel number) has 
; two values:circuit #1 and circuit #2 for that channel. The value of -1 
; (0xFF) is used if no second circuit exists for a channel (as 0x00 is a 
; valid value)

CKT_CHANNEL_MAP
	db	.00, -1		; IT'S (channel 0)
	db	.01, -1		; HALF
	db	.02, -1		; TEN
	db	.03, .04	; QUARTER
	db	.05, .06	; TWENTY
	db	.07, -1		; FIVE
	db	.08, .09	; MINUTES
	db	.10, -1		; PAST
	db	.11, -1		; TO
	db	.12, -1		; ONE
	db	.13, -1		; TWO (channel 10)
	db	.14, .15	; THREE
	db	.16, -1		; FOUR
	db	.17, -1		; FIVE
	db	.18, -1		; SIX
	db	.19, .20	; SEVEN
	db	.21, -1		; EIGHT
	db	.22, -1		; NINE
	db	.23, -1		; TEN
	db	.24, .25	; ELEVEN (channel 20)
	db	.26, .27	; TWELVE
	db	.28, .29	; O'CLOCK
;	db	.30, -1		; +
;	db	.31, -1		; +
;	db	.32, -1		; +
;	db	.33, -1		; +


; circuit table mapping for bit0 base address lookup
CKT_WRITE_PARAMETERS	 ; initial table offsets for b0 location & bitmasks
	db	low CKT_00p, low CKT_00b ; circuit 00
	db	low CKT_01p, low CKT_01b
	db	low CKT_02p, low CKT_02b
	db	low CKT_03p, low CKT_03b
	db	low CKT_04p, low CKT_04b
	db	low CKT_05p, low CKT_05b
	db	low CKT_06p, low CKT_06b
	db	low CKT_07p, low CKT_07b
	db	low CKT_08p, low CKT_08b
	db	low CKT_09p, low CKT_09b
	db	low CKT_10p, low CKT_10b
	db	low CKT_11p, low CKT_11b
	db	low CKT_12p, low CKT_12b
	db	low CKT_13p, low CKT_13b
	db	low CKT_14p, low CKT_14b
	db	low CKT_15p, low CKT_15b
	db	low CKT_16p, low CKT_16b
	db	low CKT_17p, low CKT_17b
	db	low CKT_18p, low CKT_18b
	db	low CKT_19p, low CKT_19b
	db	low CKT_20p, low CKT_20b
	db	low CKT_21p, low CKT_21b
	db	low CKT_22p, low CKT_22b
	db	low CKT_23p, low CKT_23b
	db	low CKT_24p, low CKT_24b
	db	low CKT_25p, low CKT_25b
	db	low CKT_26p, low CKT_26b
	db	low CKT_27p, low CKT_27b
	db	low CKT_28p, low CKT_28b
	db	low CKT_29p, low CKT_29b
;	db	low CKT_30p, low CKT_30b
;	db	low CKT_31p, low CKT_31b
;	db	low CKT_32p, low CKT_32b
;	db	low CKT_33p, low CKT_33b

DATA_CIRCUIT_MAP_TABLES_END	code		; end must also have a label


;---- VALIDATORS ----
;---- CKT_CHECK_CKTNUM / CKT_CHECK_CHNNUM ----
; Helper function to check for a valid ckt ot channel number
; - takes argnum in W (destroys W)
; - returns Z = 1 if OK
; - returns Z = 0 if ERROR
 
CKT_CHECK_CKTNUM
	sublw	CKT_NUM_MAX
	bsf	STATUS,Z
	bc	CCCKx
	bcf	STATUS,Z
CCCKx	return	

CKT_CHECK_CHNNUM
	sublw	CHN_NUM_MAX
	bsf	STATUS,Z
	bc	CCCNx
	bcf	STATUS,Z
CCCNx	return	


;******************************************************************************
; T1_INIT  - Initialize timer1	- USED FOR BAM INTERVAL TIMING
; T1_STOP  - Stop timer1
; T1_START - Start timer1

T1CON_INIT	equ	b'10000000'		; 16 bit R/W (see pg 181)
T1CON_START	equ	b'10000001'		; 16 bit R/W (see pg 181)
TMR1H_INIT	equ	HIGH(CKT_TMR_B0_ON)	; hi byte initial value
TMR1L_INIT	equ	LOW(CKT_TMR_B0_ON)	; lo byte initial value

T1_INIT
T1_STOP	movlw	T1CON_INIT
	movwf	T1CON
	bcf	PIR1,TMR1IF		; clear interrupt flag
	bcf	PIE1,TMR1IE 		; disable interrupts
	bcf	IPR1,TMR1IP		; set to low priority
	return

T1_START 
	movlw	T1CON_START
	movwf	T1CON
	movlw	TMR1L_INIT
	movwf	TMR1L
	movlw	TMR1H_INIT
	movwf	TMR1H
	bcf	PIR1,TMR1IF		; clear interrupt flag
	bsf	PIE1,TMR1IE 		; enable interrupts
;	bsf	IPR1,TMR1IP		; 1 = set to high priority
	bcf	IPR1,TMR1IP		; 0 = set to low priority
	return

;******************************************************************************
; PORT_INIT - Initialize all ports - sets pins as in/out/analog/etc.
;
; Modules that affect the digital IO ports:
;	- AD_INIT 	AD must be set to digital ports
;	- CMP_INIT	COmparator defaults are for digital ports
;
; Note: doesn't deal with PORTB weak pullups, which disable on output and reset

    if INIT_PORTS_EXTERNAL == TRUE	; value set in dev.inc file d18f4520.inc

TRISA_INIT	equ	b'00000001'	; all outputs except the switch bit
TRISB_INIT	equ	b'00000000'	; all outputs
TRISC_INIT	equ	b'00000000'	; all outputs
TRISD_INIT	equ	b'00000000'	; all outputs
TRISE_INIT	equ	b'11101000'	; uses lower 3 bits as outputs
					; must clear b4 to disable PSP mode...
					;...on port C
PORT_INIT
	movlw	TRISA_INIT
	movwf	TRISA
	movlw	TRISB_INIT
	movwf	TRISB
	movlw	TRISC_INIT
	movwf	TRISC
	movlw	TRISD_INIT
	movwf	TRISD
	movlw	TRISE_INIT
	movwf	TRISE

;	bsf	INTCON,PEIE 		; peripheral irq must also be enabled
	return
    endif


;*****************************************************************************
;***** UNIT TESTS ************************************************************
;*****************************************************************************

UT_CKT
 if UNITS_ENABLED
;	call	UT_ELECTRICAL_TEST	; low level electrical test
;	call	UT_CKT_WRITE_CIRCUIT	; test circuit write routine
;	call	UT_CKT_WRITE_CHANNEL	; test channel write rroutine
	call	UT_LOAD_CIRCUIT_TABLE	; load table with some initial values
;	call	UT_DUTY_CYCLE_TEST	; duty cycle generator
    endif
	return

 if UNITS_ENABLED

;-------------------------------------------------
;---- Electrical test - turn on LEDs directly ----
;-------------------------------------------------
; This test routine is left over from a non-transposed circuit table
; Must disable the BAM timer (T1) for this to work correctly

value	equ	0x00

testA	equ	value
testB	equ	value
testC	equ	value
testD	equ	value
testE	equ	value


UT_ELECTRICAL_TEST
	call	T1_INIT			; T1 CAN'T BE ON FOR THIS TO WORK
					; otherwise rows are being strobed
;	movlw	testA
;	movwf	PORTA
;	movlw	testB
;	movwf	PORTB
;	movlw	testC
;	movwf	PORTC

	movlw	testD
	movwf	PORTD

;	movlw	testE
;	movwf	PORTE

UTETxx	bra	UTETxx

;----------------------------------------------
;---- write a value into the circuit table ----
;----------------------------------------------

UT_CKT_WRITE_CIRCUIT

t_ckt	macro	ckt, lvl
	movlw	ckt
	movwf	ckt_num
	movlw	lvl			; value to write
	movwf	ckt_level
	call	CKT_WRITE_CIRCUIT
	endm

	t_ckt 0x00, 0xFF
	t_ckt 0x00, 0x00

	t_ckt 0x00, 0x11
	t_ckt 0x01, 0x22
	t_ckt 0x02, 0x33
	t_ckt 0x04, 0x44
	t_ckt 0x05, 0x55
	t_ckt 0x06, 0x66
	t_ckt 0x08, 0x77
	t_ckt 0x09, 0x88
	t_ckt 0x1E, 0x99		; maximum legal value
	t_ckt 0x1F, 0xAA		; one over maximum legal value
	return

;-----------------------------------------------------------
;---- write a triple value (HSB) into the circuit table ----
;-----------------------------------------------------------

UT_CKT_WRITE_CHANNEL_HSB

    if MONOCHROME_MODE == FALSE
t_triple macro	cktnum, red, grn, blu
	movlw	red
	movwf	red_level
	movlw	grn
	movwf	grn_level
	movlw	blu
	movwf	blu_level
	movlw	LOW (cktnum <<2)	; requires 2 shifts
	movwf	ckt_num
	call	CKT_WRITE_CHANNEL
	endm

	t_triple .00, 0x00, 0x00, 0xFF
	t_triple .01, 0xFF, 0xAA, 0x55
	t_triple .02, 0xFF, 0xAA, 0x55
	t_triple .03, 0xFF, 0xAA, 0x55
    endif
	return

;--------------------------------------------
;---- load values into the circuit table ----
;--------------------------------------------

UT_LOAD_CIRCUIT_TABLE

cktlvl	equ	0xFF

t_load	macro	ckt, lvl
	movlw	ckt
	movwf	ckt_num
	movlw	lvl			; value to write
	movwf	ckt_level
	call	CKT_WRITE_CIRCUIT
	endm

;     	t_load ckt, level
	t_load .00, cktlvl
	t_load .01, cktlvl
	t_load .02, cktlvl
	t_load .03, cktlvl
	t_load .04, cktlvl
    if FALSE
	t_load .05, cktlvl
	t_load .06, cktlvl
	t_load .07, cktlvl
	t_load .08, cktlvl
	t_load .09, cktlvl
	t_load .10, cktlvl
	t_load .11, cktlvl
	t_load .12, cktlvl
	t_load .13, cktlvl
	t_load .14, cktlvl
	t_load .15, cktlvl
	t_load .16, cktlvl
	t_load .17, cktlvl
	t_load .18, cktlvl
	t_load .19, cktlvl
	t_load .20, cktlvl
	t_load .21, cktlvl
	t_load .22, cktlvl
	t_load .23, cktlvl
	t_load .24, cktlvl
	t_load .25, cktlvl
	t_load .26, cktlvl
	t_load .27, cktlvl
	t_load .28, cktlvl
	t_load .29, cktlvl
	t_load .30, cktlvl
	t_load .31, cktlvl
	t_load .32, cktlvl
	t_load .33, cktlvl		; don't exceed CKT_NUM_MAX
    endif
	return

;------------------------------
;---- duty cycle generator ----
;------------------------------

UT_DUTY_CYCLE_TEST

DCT_TMR	equ	0xF447			; times out 5% of a 150 Hz cycle

; This routine requires replacing the jump table with the following:
; (remove the comment on the label:)
;CKI_JMP	bra	dct_00			; initialize
	bra	dct_A0			; 5%
	bra	dct_A1			; 10%
	bra	dct_A2			; 15%
	bra	dct_A3			; 20%
	bra	dct_A4			; 25%
	bra	dct_A5			; 30%
	bra	dct_A6			; 40%
	bra	dct_A7			; 45%
	bra	dct_B0			; 50%
	bra	dct_B1			; 55%
	bra	dct_B2			; 60%
	bra	dct_B3			; 65%
	bra	dct_B4			; 70%
	bra	dct_B5			; 78%
	bra	dct_B6			; 80%
	bra	dct_B7			; 85%
	bra	dct_C0			; 90%
	bra	dct_C1			; 95%
	bra	dct_C2			; 100%

dct_tmr macro				; set timer to 5% or 150 hz period
	movlw	HIGH DCT_TMR
	movwf	TMR1H
	movlw	LOW DCT_TMR
	movwf	TMR1L
	incf	isrckt_index,F		; increment index
	endm

dct_set macro	port,bit		; set timer to 5% or 150 hz period
	movlw	HIGH DCT_TMR
	movwf	TMR1H
	movlw	LOW DCT_TMR
	movwf	TMR1L
	bsf	port,bit		; turn off the indicated bit
	incf	isrckt_index,F		; increment index
	goto	CKI_RET			; return
	endm

dct_00	dct_tmr	
	clrf	LATA			; turn on all bits
	clrf	LATB
	clrf	LATC
	goto	CKI_RET

dct_A0	dct_set	LATA,0
dct_A1	dct_set	LATA,1
dct_A2	dct_set	LATA,2
dct_A3	dct_set	LATA,3
dct_A4	dct_set	LATA,4
dct_A5	dct_set	LATA,5
dct_A6	dct_set	LATA,6
dct_A7	dct_set	LATA,7
dct_B0	dct_set	LATB,0
dct_B1	dct_set	LATB,1
dct_B2	dct_set	LATB,2
dct_B3	dct_set	LATB,3
dct_B4	dct_set	LATB,4
dct_B5	dct_set	LATB,5
dct_B6	dct_set	LATB,6
dct_B7	dct_set	LATB,7
dct_C0	dct_set	LATC,0
dct_C1	dct_set	LATC,1

dct_C2	dct_tmr
	bsf	LATC,2			; turn off the indicated bit
	clrf	isrckt_index		; reset index
	goto	CKI_RET			; return

  endif	; UNITS_ENABLED

	END
