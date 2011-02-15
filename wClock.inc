;*****************************************************************************
; wClock - common header file
;*****************************************************************************
;
;    Filename:	    	wClock.inc
;    Author, Company:	Alden Hart, Luke's Lights
;    Date/Time/Rev:	091015
;
;    'sproke notes: If shit breaks, look in the following places:
;	- test ISR dispatcher for not crossing a page boundary
;	- look for all occurrences of "HACK HACK"

;------ Application Switches -----	
; The default initialization routines are provided in the device file: d18fxxxx.asm
; Setting an _EXTERNAL switch TRUE will use an init located in some other file.
; You must also set up an extern in the d18fxxxx.asm file and a global in the 
; target application file to override the default init.

INIT_PORTS_EXTERNAL	equ	TRUE	; set true to use an external init routine
INIT_T0_EXTERNAL	equ	TRUE	; uses the one in wClock.asm
INIT_T1_EXTERNAL	equ	TRUE	; uses the one in led_ckt4520.asm
INIT_WATCHDOG_TIMER	equ	TRUE	; set if WDT enabled. See WDT_INIT

;----- Assembly-Time Switches ------

RX_ENABLED		equ	FALSE	; enable RX ISR processing
ICD_ENABLED		equ	FALSE	; enable ICD2 debugging
UNITS_ENABLED 		equ	TRUE	; enable unit tests
DIAGNOSTICS_ENABLED	equ	TRUE	; takes up space and time

CLK_TIMER		equ	0x0BDC	; value for prescale 128 (rev 1)
;CLK_TIMER		equ	0xC000	; TEST value for prescale 128

;----- switch port assignments and equates

SW_DEBOUNCE_MAX		equ	.8	; # of 6.66 ms cycles to debounce switch
SW_HELD_COUNT		equ	.60	; # of 6.66 ms increments before advance
SW_STATE_ON_bp		equ	.00	; 1=switch is on  0=switch is off
SW_STATE_RISING_bp	equ	.01	; rising edge (this state can be removed)
SW_STATE_FALLING_bp 	equ	.02	; falling edge (this state can be removed)

;----- Table program memory allocation -----
; The following  tables must be aligned on a 0x100 page boundary
; Look at the eFruit.map file for optimal placement

BASE_OF_TABLES		equ	0x2000
HSB_TABLES_LEN		equ	0x600
;HSB_TABLES_LEN		equ	0x00

HSB_TABLES_START	equ	BASE_OF_TABLES
CUE_TABLES_START	equ	HSB_TABLES_START + HSB_TABLES_LEN 
; Cue tables can use the rest of program memory if they need to, and should be last

;--- Flag values for app_flags ----
; Notes on TIME bits:
; - TIME_5MS is an approximate flag set by cycle processing (for switch timing)
; - The other TIME flags are managed by CLK_IRQ

DIRTY_BIT		equ	0	; set to signal new dimmer value
CYCLE_START_FLAG	equ	1	; set once per cycle during BAM interval
SWITCH_READ_FLAG	equ	2	; is set approx every 6 ms
SECOND_FLAG		equ	3	; is set every second (exactly)

;---- Word to channel mapping ----

ITS		equ	.0		; Channel 0 is "IT'S"
HALF		equ	.1
TEN_		equ	.2		; differentiate from hour TEN
QUARTER		equ	.3
TWENTY		equ	.4
FIVE_		equ	.5		; differentiate from hour FIVE
MINUTES		equ	.6
PAST		equ	.7
TO_		equ	.8		; must have an underscore
ONE		equ	.9
TWO		equ	.10
THREE		equ	.11
FOUR		equ	.12
FIVE		equ	.13
SIX		equ	.14
SEVEN		equ	.15
EIGHT		equ	.16
NINE		equ	.17
TEN		equ	.18
ELEVEN		equ	.19
TWELVE		equ	.20
OCLOCK		equ	.21
;PLUS_1		equ	.22
;PLUS_2		equ	.23
;PLUS_3		equ	.24
;PLUS_4		equ	.25
