;*****************************************************************************
; global.inc - global header file for any application or chip family
;*****************************************************************************
;
;    Filename:	    	global.inc
;    Function:		define files, global equates and macros
;    Author, Company:	Alden Hart, Luke's Lights
;    Date/Time/Rev:	091015
;
; This file must be the first include file in each .asm file
; Set this file up first

;----- Include file definitions ------
;
; All ASM files must have this set of includes in this order:
;#include <global.inc>			; 1: global defines - must be first
;#include <DEV_INCLUDE_FILE>		; 2: Our device include file
;#include <LED_INCLUDE_FILE>		; 3: LED subsystem include file
;#include <APP_INCLUDE_FILE>		; 4: Application include file
;
; Which are set up here:
#define DEV_INCLUDE_FILE d18f4520.inc 	; device header file
#define LED_INCLUDE_FILE led.inc 	; led sub-system header file
#define APP_INCLUDE_FILE wClock.inc 	; application header file

;----- Fundamental definitions ------

TRUE		equ	1	; must equal 1 - do not re-assign
FALSE		equ	0	; must equal 0 - do not re-assign
ON		equ	1
OFF		equ	0

;---- Global error return codes ----

ERR_NO_ERROR		equ	.00	; not actually an error, probably an end
ERR_BAD_COMMAND		equ	.01	; invalid command value
ERR_BAD_CHANNEL		equ	.02	; invalid channel number or encoded channel
ERR_BAD_ARGNUM		equ	.03	; invalid argument number
ERR_BAD_OPCODE		equ	.04	; invalid argument opcode
ERR_CMD_LOADER_FAILED	equ	.05	; command loader failed in cmd module
ERR_GET_COMMAND_FAILED	equ	.06	; get_command failed in presets module
ERR_GET_NEXT_CMD_FAILED	equ	.07	; get_next failed in presets module

;---- Handy global macros ----

;---- Handy macro to set a 16 bit pointer to a literal address

setptr	macro	ADDRESS, ptr_hi, ptr_lo
	movlw	HIGH ADDRESS
	movwf	ptr_hi
	movlw	LOW ADDRESS
	movwf	ptr_lo
	endm

;---- Handy macro to set table pointer to an address

tbladdr	macro	ADDRESS
	movlw	HIGH ADDRESS
	movwf	TBLPTRH
	movlw	LOW ADDRESS
	movwf	TBLPTRL
	endm

;---- Handy macro to set table pointer to an address indexed by a second value

tblindx	macro	ADDRESS, index	; index is a mem variable name, not a literal
	movlw	high ADDRESS
	movwf	TBLPTRH
	movlw	low ADDRESS
	movwf	TBLPTRL
	rlncf	index,W			; multiply index value by 2
	addwf	TBLPTRL
	movlw	0			; propagate carry (if any)
	addwfc	TBLPTRH
	endm

;---- Handy macro to read a 16 bitvalue from a table into a pointer
;     Usually follows tbladdr or tblindx
;     Leaves table pointer to next location

tblread	macro	ptr_hi, ptr_lo		; hi and lo registers for table read
	tblrd*+
	movff	TABLAT,ptr_lo		; DATA statements are lo/hi endian
	tblrd*+
	movff	TABLAT,ptr_hi
	endm

;---- SWITCH statement macro (jump through a vector table) ----
; OK, it's not REALLY a switch/case statement - ot works differently than C
;
; Calling convention is:
;
;	rlncf	cmd_command,W		; load table index x2 into W
;	switch				; call the macro
;	data	CL_ERROR		; table index 0
;	data	CL_LOAD_SET_HSB		; table index 1 (etc).
;	data	CL_LOAD_SET_RGB
;	data	CL_LOAD_PATCH
;	data	CL_LOAD_FADE
;	data	CL_LOAD_WATCH		; max index. not range checked.
;
; You must also include the following lines in any file but the main:
;
;	extern	tblptrh_temp
;	extern	tblptrl_temp
;
; CONSTRAINTS:
; 	W must contain the table index multipled by 2 prior to invoking switch
; 	The macro must be followed by the actual jump table as illustrated above.
;	The first element in the jump table must be index zero (0)
; 	Tables are limited to 128 entries or you must change case for 16-bit math
; 	The macro does not check that the index is in range for the table...
;	...presumably this is validated by an upstream data validation checker.
;
; This macro is not nearly as code efficient as a computed BRA (below), but  
; doesn't break if it crosses on page boundaries:
;
;	movlw	HIGH jump
;	movwf	PCLATH
;	rlncf	index,W			; get command code x2 into W...
;	addlw	LOW jump		;...this only works with BRAs 
;	movwf	PCL			;...GOTOs require x4
;jump	bra	CL_ERROR
;	bra	CL_LOAD_SET_HSB
;	bra	CL_LOAD_SET_RGB
;	bra	CL_LOAD_PATCH
;	bra	CL_LOAD_FADE
;	bra	CL_LOAD_WATCH

switch	macro
	local	table_base
	movff	TBLPTRH,temp_tblptrh	; save current table pointer
	movff	TBLPTRL,temp_tblptrl

	addlw	LOW table_base		; add index (W) to table base
	movwf	TBLPTRL			; set low pointer
	movlw	HIGH table_base
	movwf	TBLPTRH
	btfsc	STATUS,C		; propagate the carry from the add
	incf	TBLPTRH,F

	tblrd*+				; read and save vector address lo byte
	movf	TABLAT,W
	tblrd*				; read and save vector address hi byte
	movff	TABLAT,PCLATH

	movff	temp_tblptrh,TBLPTRH	; restore calling table pointer
	movff	temp_tblptrl,TBLPTRL

	movwf	PCL			; jump to case routine
table_base
	endm

