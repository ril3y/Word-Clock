;*****************************************************************************
; PIC18F family - cues and playback code
;*****************************************************************************
;
;    Filename:	    	led_cue.asm
;    Author, Company:	Alden Hart, Luke's Lights
;    Chip Support:	Supports PIC18F family
;    Revision:		091130
;
;*****************************************************************************
; A CUE is a single lighting event that may involve a dynamic or repeating fade
; CUES are made of one or more individual commands (CMDs)
; A set of CUEs that run in sequence are a PLAYLIST (aka cue list, cue sheet)
; PLAYBACK is automatically playing one cue after another by detecting cue ends
;
; DISCUSSION OF TABLES AND POINTERS (see spreadsheet Playlists tab for details). 
; There is a hierarchy of tables:
;   - Playlist Master table
;       - Playlist_XXX tables	(one of which will be the "active" playlist)
;	    - Cue_XXX tables	(one of which will be the "current" cue)
;
; The playlist master table is a collection of 16 bit pointers to one or more
; playlist tables, and is always terminated by PLAYLIST_DONE (0x0000). It is
; also be preceded by PLAYLIST_DONE to support backwards navigation.
;
; The play_master_ptr_hi/lo pointer (master prointer) is initialized to the 
; first location of the master table. A helper function is provided to reset 
; this pointer. The pointer is manipulated using the PLAY_GET_NEXT_PLAYLIST 
; and PLAY_GET_PREV_PLAYLIST calls. GET_NEXT will wrap to the beginning of 
; the table on overflow. GET_PREV will stick at the beginning. There are no 
; looping or jump commands in this table. The master pointer can also be set 
; directly using the PLAYLIST command from the serial port (or in a cue?).
;
; The playlist pointed to by the master pointer is considered the "active playlist".
;
; The play_ptr_hi/lo pointer (playlist pointer) points to the current cue in the 
; active playlist. By convention the pointer is not advanced until it's needed 
; (i.e. it's pre-incremented). The playlist pointer is manipulated using the
; PLAY_GET_NEXT_CUE function - which executes all increments, looping, jumps, 
; DONE and CODA handling. There is no PLAY_GET_PREV_CUE command. 
;
; The cue pointed to by the play_ptr_hi/lo is considered the "current cue".
;
; The cue_ptr_hi/lo pointer (cue pointer) points to the command in the 
; current cue. Since all commands in a cue are run to completion, the cue
; pointer is a more dynamic pointer than the playlist pointers. The cue pointer
; is under the control of the CUE_RUN_NEXT_CUE and CUE_LOAD_CUE functions 
; which use various navigation functions to move this pointer.
;
; I'm not sure if I have the dividing line between the playlist functions and 
; the cue functions exactly right.


;----- Include files and other setup------

#include <global.inc>			; 1: global defines - must be first
#include <DEV_INCLUDE_FILE>		; 2: Our device include file
#include <LED_INCLUDE_FILE>		; 3: LED subsystem include file
#include <APP_INCLUDE_FILE>		; 4: Application include file

;------ Exports (globals) - specific to the clock application -----

	global	CUE_CLK_READOUT		; application specific routine
	global	cue_clk_min
	global	cue_clk_hour

;------ Needed to export these just so I could WATCH them. MPLAB bug?

	global	cue_clk_min_plus
	global	cue_clk_min_five
	global	cue_ptr_hi
	global	cue_ptr_lo

;------ Exports (globals) - not application specific -----

	global	PLAY_INIT
	global	cue_watch		; used by command loader only
	global	CUE_WATCHER
	global	UT_PLAY			; playlist and cues unit tests

;----- External variables and FUNCTIONS -----

	extern	chn_num			; channel number
	extern	chn_level		; circuit level
	extern	CKT_WRITE_CHANNEL	; write a mono value or RGB triplet to ckt table

	extern	cmd_buffer		; command input buffer
	extern	CMD_VALIDATE_CMDCODE	; validate command code
	extern	CMD_LOADER
	extern	FDR_TEST_FDR_DONE	; returns Z=1 if fader is done or inactive
	extern	temp_tblptrh
	extern	temp_tblptrl

;------ RAM definitions -----

;##### BANK 0 #####
UDATA_BANK_0_ACS	udata_acs	; linker allocates space in bank 0

; application specific variables (clock application)
cue_clk_hour		res	1	; hour to read out
cue_clk_min		res	1	; minutes to read out
cue_clk_min_five	res	1	; minutes by 5 minutes counter (0-11)
cue_clk_min_plus	res	1	; minutes plus signs isolated (0-4)

; general variables
play_master_ptr_hi	res	1	; playlist master table pointer
play_master_ptr_lo	res	1
play_ptr_hi		res	1	; active playlist table pointer
play_ptr_lo		res	1
cue_ptr_hi		res	1	; current cue table pointer
cue_ptr_lo		res	1
cue_num_hi		res	1	; cue number hi/lo
cue_num_lo		res	1

cue_fsr1_temp_hi	res	1	; needed for GET_ARGUMENT
cue_fsr1_temp_lo	res	1
;cue_loop_end_addr_hi	res	1	; end address of a CUE_LOOP command
;cue_loop_end_addr_lo	res	1

cue_command		res	1	; command code (4 bits)
cue_argcount		res	1	; command argument count (4 bits)
cue_argnum		res	1	; argment number being processed
cue_argmask		res	1	; argument bitmask, args <7-0>
cue_argmask_hi		res	1	; argument bitmask, args <F-8>
cue_argvalue		res	1	; argument value as read from the table
cue_argflags		res	1	; set b0 to signal there are upper args
cue_loop_work		res	1	; working register for loop counting

cue_loop_counter	res	1	; counter for LOOP commands
cue_loop_table_hi	res	1
cue_loop_table_lo	res	1

cue_opcode		res	1	; argument opcode byte
cue_op1			res	1	; argument operand 1
cue_op2			res	1	; argument operand 2
cue_op3			res	1	; argument operand 3

cue_watch		res	1	; cue DONE watch register

;##### BANK 3 #####
;UDATA_ARG_TABLE udata	0x300		; argtable must be on a page boundary 
					; or you must change CUE_SET_ARG_ADDR
arg_table		res	4*(ARG_NUM_MAX+1)

;###############################
;##### BEGIN CODE SECTION ######
;###############################

CODE_LED_CUE_CODE	code

;*****************************************************************************
;***** WCLOCK APPLICATION SPECIFIC ROUTINES **********************************
;*****************************************************************************

;******************************************************************************
; CUE_CLK_READOUT - Read out the clock display from the clock registers
;
; Normally called from the main loop each time FLAG_MINUTE is set by CLK_ISR. 
; It can also be called as part of setting the clock 
;
; INPUTS (expected to be loaded when routine is called)
;	- cue_clk_min			; minutes to read out
;	- cue_clk_hour			; hour to read out
; USES:	- cue_clk_min_five		; 5 minute marks (0-11)
;	- cue_clk_min_plus		; minutes beyond the 5 minute mark (0-4)
;
; Generating the cue_clk_min_five and cue_clk_min_plus terms is tricky without
; having a ready division function. To generate the _five term, dividing by 5 
; is the same as multiplying by 1/5, which is 256/5 = 51.2. Using 52 has an 
; error term that's small enough not to present a problem in the 0-59 range. 
; Result is in PRODH. (By the way, this breaks when you hit 64/5, so this 
; method will not work above 63/5)
; 
; The cue_clk_min_plus term can be derived by multiplying the remainder (PRODL) 
; by 5 and picking the result out of PRODH.

CUE_CLK_READOUT
	; generate the cue_clk_min_five and cue_clk_min_plus terms
	movf	cue_clk_min,W		; divide 0-59 by 5 (multiply by 52)
	mullw	.52			; changes every 5 minutes...
	movff	PRODH,cue_clk_min_five	; ...varies from 0 - 11
	movf	PRODL,W			; now go get the _plus term
	mullw	.5			; changes every minute...
	movff	PRODH,cue_clk_min_plus	; ...varies from 0 - 4
; removed next 2 instructions or time set functions won't work reliably
;	movf	PRODH,W			; test for 5 minute boundaries
;	bnz	CCR_EXIT		; only update on 5 minute marks

	; adjust hours. We use an hour from twenty-five to, to half-past
	movf	cue_clk_min_five,W
	sublw	.6			; find "twenty-five to" division
	bnn	CCR_DSP
	movf	cue_clk_hour,W
	sublw	.12			; adjust hour forward, with rollover
	btfsc	STATUS,Z
	clrf	cue_clk_hour		; sets hour to 1 if it's 12 o'clock
	incf	cue_clk_hour,F

CCR_DSP	; display routines (see global.inc for macro listings)

	call	CUE_CLK_LOADER

	; display minutes preamble and o'clock postfix
;	tblindx	CLK_MINUTES_MAP, cue_clk_min_five  ; set index into MIN map
;	tblread	cue_ptr_hi, cue_ptr_lo		   ; set cue_ptr from MIN map
;	call	CUE_LOAD_CUE

	; display hours
;	tblindx	CLK_HOURS_MAP, cue_clk_hour	; set index into HOURS map 
;	tblread	cue_ptr_hi, cue_ptr_lo		; set cue_ptr from HOURS map
;	call	CUE_LOAD_CUE

CCR_EXIT
	return


;--- CUE_CLK_LOADER - 
; Load tables into channels
; First load the 5min values, then load the hours

CUE_CLK_LOADER
	movlw	CHN_NUM_MAX		; turn all channels off
	movwf	chn_num
CCL2	clrf	chn_level
	call	CKT_WRITE_CHANNEL
	decf	chn_num
	bnn	CCL2

	;#### THIS CODE SEGMENT CANNOT CROSS A 0x100 PROGRAM MEMORY BOUNDARY
	movlw	HIGH CCL_MIN
	movwf	PCLATH
	rlncf	cue_clk_min_five,W	; get index x2 into W...
	addlw	LOW CCL_MIN		;...this only works with BRAs 
	movwf	PCL			;...GOTOs require x4
CCL_MIN	bra	_min00			; dispatch to 00 minutes
	bra	_min05
	bra	_min10
	bra	_min15
	bra	_min20
	bra	_min25
	bra	_min30
	bra	_min35
	bra	_min40
	bra	_min45
	bra	_min50
	bra	_min55

CCL_HOURS
	movlw	HIGH CCL_HR
	movwf	PCLATH
	rlncf	cue_clk_hour,W		; get index x2 into W...
	addlw	LOW CCL_HR		;...this only works with BRAs 
	movwf	PCL			;...GOTOs require x4
CCL_HR	bra	_hour00			; NULL never happens
	bra	_hour01
	bra	_hour02
	bra	_hour03
	bra	_hour04
	bra	_hour05
	bra	_hour06
	bra	_hour07
	bra	_hour08
	bra	_hour09
	bra	_hour10
	bra	_hour11
	bra	_hour12
	; #### TO HERE

ccload	macro	channel, level
	movlw	level
	movwf	chn_level
	movlw	channel
	movwf	chn_num
	call	CKT_WRITE_CHANNEL
	endm
	
_min00	ccload	OCLOCK, LIT
	bra	CCL_HOURS

_min05	ccload	ITS, LIT
	ccload	FIVE_, LIT
	ccload	MINUTES, LIT
	ccload	PAST, LIT
	bra	CCL_HOURS

_min10	ccload	ITS, LIT
	ccload	TEN_, LIT
	ccload	PAST, LIT
	bra	CCL_HOURS

_min15	ccload	ITS, LIT
	ccload	QUARTER, LIT
	ccload	PAST, LIT
	bra	CCL_HOURS

_min20	ccload	ITS, LIT
	ccload	TWENTY, LIT
	ccload	PAST, LIT
	bra	CCL_HOURS

_min25	ccload	ITS, LIT
	ccload	TWENTY, LIT
	ccload	FIVE_, LIT
	ccload	MINUTES, LIT
	ccload	PAST, LIT
	bra	CCL_HOURS

_min30	ccload	ITS, LIT
	ccload	HALF, LIT
	ccload	PAST, LIT
	bra	CCL_HOURS

_min35	ccload	ITS, LIT
	ccload	TWENTY, LIT
	ccload	FIVE_, LIT
	ccload	TO_, LIT
	bra	CCL_HOURS

_min40	ccload	ITS, LIT
	ccload	TWENTY, LIT
	ccload	MINUTES, LIT
	ccload	TO_, LIT
	bra	CCL_HOURS

_min45	ccload	ITS, LIT
	ccload	QUARTER, LIT
	ccload	TO_, LIT
	bra	CCL_HOURS

_min50	ccload	ITS, LIT
	ccload	TEN_, LIT
	ccload	MINUTES, LIT
	ccload	TO_, LIT
	bra	CCL_HOURS

_min55	ccload	ITS, LIT
	ccload	FIVE_, LIT
	ccload	MINUTES, LIT
	ccload	TO_, LIT
	bra	CCL_HOURS

_hour00	ccload	ONE, LIT
	bra	CCL_HOURS

_hour01	ccload	ONE, LIT
	bra	CCL_HOURS

_hour02	ccload	TWO, LIT
	bra	CCL_HOURS

_hour03	ccload	THREE, LIT
	bra	CCL_HOURS

_hour04	ccload	FOUR, LIT
	bra	CCL_HOURS

_hour05	ccload	FIVE, LIT
	bra	CCL_HOURS

_hour06	ccload	SIX, LIT
	bra	CCL_HOURS

_hour07	ccload	SEVEN, LIT
	bra	CCL_HOURS

_hour08	ccload	EIGHT, LIT
	bra	CCL_HOURS

_hour09	ccload	NINE, LIT
	bra	CCL_HOURS

_hour10	ccload	TEN, LIT
	bra	CCL_HOURS

_hour11	ccload	ELEVEN, LIT
	bra	CCL_HOURS

_hour12	ccload	TWELVE, LIT
	bra	CCL_HOURS


;*****************************************************************************
;***** PLAYLIST LEVEL FUNCTIONS **********************************************
;*****************************************************************************

;*****************************************************************************
; PLAY_INIT		Init playback module and load first cue
;
; INPUTS: <none>
; RETURNS: <none>

PLAY_INIT	
	call	_PLAY_RESET_MASTER_PTR	; init playlist master table pointer 
	call	_PLAY_SET_PLAY_PTR	; set active playlist pointer from master
	call	_PLAY_SET_CUE_PTR	; set cue pointer from playlist pointer
	call	CUE_LOAD_CUE		; start playlist at first cue
	return

;*****************************************************************************
; PLAY_GET_NEXT_PLAYLIST	Advance to next playlist
; PLAY_GET_PREV_PLAYLIST	Back up to previous playlist
;
; INPUTS:	play_master_ptr_hi/lo current state
;
; RETURNS:	play_master_ptr_hi/lo next/previous state
;		play_ptr_hi/lo set to value in master playlist
;
; PLAYLIST_DONE is technically treated as a CODA (which also would test positive)

PLAY_GET_NEXT_PLAYLIST
	call	_PLAY_INCR_MASTER_PTR
	bra	PGP_01

PLAY_GET_PREV_PLAYLIST
	call	_PLAY_DECR_MASTER_PTR
PGP_01	call	_PLAY_SET_PLAY_PTR
	movf	play_ptr_hi,W		; test pointer for master playlist DONE
	xorlw	HIGH PLAYLIST_DONE	; test for both list overflow and underflow
	bz	PGP_RESTART		; if MSByte is zer, restart the master list
	return				; otehrwise return without pointer adjustment

PGP_RESTART
	call	_PLAY_RESET_MASTER_PTR
	call	_PLAY_SET_PLAY_PTR
	return

;*****************************************************************************
; PLAY_RUN_NEXT_CUE	Run next cue in active playlist
;
PLAY_RUN_NEXT_CUE
	call	PLAY_GET_NEXT_CUE	; get the next cue
	bnz	PRNC_OK			; if Z=0 exit with no cue load 
	call	CUE_LOAD_CUE		; run the next cue	
PRNC_OK	return

;*****************************************************************************
; PLAY_GET_NEXT_CUE   Get next cue in active playlist. 
; Handles DONE, CODA, LOOPs and JUMPs.
;
; INPUTS:	cue_ptr_hi/lo points to current cue in active playlist
;
; RETURNS:	Z=1	pointer advanced successfully (cue should be exectuted)
;		Z=0	pointer did not advance because: (do not run cue)
;			 - DONE encountered
;			 - error detected
PLAY_GET_NEXT_CUE
	; read next cue pointer from active playlist
	call	_PLAY_INCR_PLAY_PTR	; increment play pointer to next cue 
	call	_PLAY_SET_CUE_PTR	; set cue pointer from playlist pointer

	; test cue pointer for playlist DONE or CODA
	movf	cue_ptr_hi,W
	bnz	PGNC_01			; if MSbyte is not zero skip these tests

	movf	cue_ptr_lo,W
	xorlw	LOW PLAYLIST_DONE	; test for DONE
	bz	PGNC_DONE		; it's done - exit OK

	movf	cue_ptr_lo,W		; test for CODA
	xorlw	LOW PLAYLIST_CODA
	bnz	PGNC_ERR		; it's not DONE or CODA - error

	call	_PLAY_SET_PLAY_PTR	; it's a CODA. (Re)set playlist ptr from master
	call	_PLAY_SET_CUE_PTR	; set cue pointer from playlist pointer

PGNC_01	; put looping controls here
	
PGNC_OK	bsf	STATUS,Z		; OK exit. Run next cue
	retlw	ERR_NO_ERROR

PGNC_DONE				; DONE exit. Do not run next cue
	bcf	STATUS,Z
	retlw	ERR_NO_ERROR

PGNC_ERR				; Error exit. Do not run next cue
	bcf	STATUS,Z
	retlw	ERR_BAD_COMMAND

;*****************************************************************************
; Playlist helper routines
;
_PLAY_RESET_MASTER_PTR			; reset playlist master pointer
	movlw	HIGH PLAYLIST_MASTER_TABLE
	movwf	play_master_ptr_hi
	movlw	LOW PLAYLIST_MASTER_TABLE
	movwf	play_master_ptr_lo
	return

_PLAY_INCR_MASTER_PTR			; increment playlist master pointer 
	movlw	0x02
	addwf	play_master_ptr_lo,F	
	movlw	0x00
	addwfc	play_master_ptr_hi,F	
	return

_PLAY_DECR_MASTER_PTR			; decrement playlist master pointer 
	movlw	0x02
	subwf	play_master_ptr_lo,F	
	movlw	0x00
	subwfb	play_master_ptr_hi,F	
	return

_PLAY_SET_PLAY_PTR			; set playlist pointer from master pointer 
	movff	play_master_ptr_hi,TBLPTRH
	movff	play_master_ptr_lo,TBLPTRL
	tblrd*+
	movff	TABLAT,play_ptr_lo
	tblrd*+
	movff	TABLAT,play_ptr_hi
	return

_PLAY_INCR_PLAY_PTR			; increment playlist pointer 
	movlw	0x02
	addwf	play_ptr_lo,F	
	movlw	0x00
	addwfc	play_ptr_hi,F	
	return

_PLAY_SET_CUE_PTR			; set cue pointer from playlist pointer
	movff	play_ptr_hi,TBLPTRH
	movff	play_ptr_lo,TBLPTRL
	tblrd*+
	movff	TABLAT,cue_ptr_lo
	tblrd*+
	movff	TABLAT,cue_ptr_hi
	return


;*****************************************************************************
;***** CUE LEVEL FUNCTIONS ***************************************************
;*****************************************************************************

;*****************************************************************************
; CUE_WATCHER 		Test cue_watch for cue done & run cue if needed
;
; See if the current cue is finished by checking the fade channel status.
; Run the next cue in the active playlist if this is true
;
; INPUTS:  cue_watch	watch state:
;   			0x00 - 0xNN 	- Check fader NN for DONE & load cue if true
;    	  		0xFE (NOW)	- Load next cue right now.
;    			0xFF (NEVER)	- Never load next cue (disabled).

CUE_WATCHER
	movf	cue_watch,W		; test for NEVER condition
	xorlw	NEVER
	bz	CUW_EXIT_NO_CHANGE

	movf	cue_watch,W		; test for NOW condition
	xorlw	NOW
	bz	CUW_RUN_NEXT_CUE

	call	FDR_TEST_FDR_DONE	; test watched fader channel for completion status
	bz	CUW_EXIT_NO_CHANGE

CUW_RUN_NEXT_CUE
	call	PLAY_RUN_NEXT_CUE

CUW_EXIT_NO_CHANGE
	return


;*****************************************************************************
; CUE_RUN_CUE		Run a cue from cue table by mumber
;
; INPUTS cue_num_hi	cue number to run
;	 cue_num_lo	
;
; FUNCTION	Calls CUE_LOAD_CUE with cue pointer from CUE_NUMBER_TABLE

CUE_RUN_CUE
	tblindx	CUE_NUMBER_TABLE, cue_num_lo	; set table pointer
	tblrd*+
	movff	TABLAT,cue_ptr_lo
	tblrd*
	movff	TABLAT,cue_ptr_hi
	call	CUE_LOAD_CUE
	return

;*****************************************************************************
; CUE_LOAD_CUE		Load an entire cue from cue_ptr_hi/lo cue pointer
;
CUE_LOAD_CUE
	movff	cue_ptr_lo,TBLPTRL	; setup the table pointer
	movff	cue_ptr_hi,TBLPTRH

	movlw	NEVER			; clear the watch register
	movwf	cue_watch

PLP_01	call	CUE_GET_NEXT_COMMAND	; loop in the command
	btfsc	STATUS,Z
	bra	PLP_01
	return

;*****************************************************************************
; CUE_GET_NEXT_COMMAND	Get and execute next command from cue
;
; INPUTS TBLPTR 	points to CUE_xxxx in code space as per the following:
;			 - CUE_DONE
;			 - CUE_CMD
;			 - CUE_ARG
;			 - CUE_LOOP
;			 - CUE_LOOP_BLOCK
;			 - CUE_JUMP
;
; RETURN  TBLPTR	points to next CUE_xxxx byte in string
;	- Z=0		signals an error occurred in processing (errcode in Z)
;	- Z=1		signals processing occurred OK
;
; USES:
;	- FSR1		primary memory pointer (trashed)
;	- FSR2		used in some ARG cases (might be trashed)
;
; See CUE_GET_COMMAND for details of the command structure

CUE_GET_NEXT_COMMAND
	tblrd*+				; read CUE_xxx byte (with post increment)
	movf	TABLAT,W
	sublw	CUE_MAX+1
	bc	CGN_01
	bcf	STATUS,Z
	retlw	ERR_GET_NEXT_CMD_FAILED

CGN_01	rlncf	TABLAT,W		; get CUE_xxxxx code x2 into W...
	switch
	data	CGN_DONE
	data	CGN_COMMAND
	data	CGN_ARGUMENT
	data	CGN_LOOP
	data	CGN_LOOP_LOCAL
	data	CGN_LOOP_REMOTE
	data	CGN_JUMP

CGN_DONE
	bcf	STATUS,Z		; signal DONE
	retlw	ERR_NO_ERROR

CGN_COMMAND
	call	CUE_GET_COMMAND		; this will pass back OK or ERR condition
	bra	CGN_EXIT

CGN_ARGUMENT
	call	CUE_SET_ARGUMENT
	bra	CGN_EXIT

CGN_LOOP
	tblrd*+				; get repeat counter
	movff	TABLAT,cue_loop_counter
	
	tblrd*+				; read the CUE_COMMAND code
	movf	TABLAT,W
	xorlw	CUE_CMD
	bz	CGNL01
	bcf	STATUS,Z
	retlw	ERR_BAD_COMMAND		; return if error (with Z=0)
	
CGNL01	movff	TBLPTRH,cue_loop_table_hi ; save the command starting address
	movff	TBLPTRL,cue_loop_table_lo

CGNL02	movff	cue_loop_table_hi,TBLPTRH ; restore command starting address
	movff	cue_loop_table_lo,TBLPTRL

	call	CUE_GET_COMMAND		; this will pass back OK or ERR condition
	btfss	STATUS,Z
	retlw	ERR_BAD_COMMAND		; return if error (with Z=0)

	decfsz	cue_loop_counter
	bra	CGNL02
	bra	CGN_EXIT

CGN_LOOP_LOCAL
	bra	CGN_EXIT

CGN_LOOP_REMOTE
	bra	CGN_EXIT

CGN_JUMP
	bra	CGN_EXIT

CGN_EXIT
	bsf	STATUS,Z
	return

;*****************************************************************************
; CUE_GET_COMMAND	Get single command from cue (into FDR_LOADER buffer)
;
; INPUTS:
;	- TBLPTR 	points to cmd byte in code space as per the following:
;			CUE_CMD, cmd, argmask, arg0....argN    (see below)
; RETURNS:
;	- chn_num	set to channel number of command
;	- FSR1		points to beginning of command buffer --
;			suitable for passing to FDR_LOADER
;	- TBLPTR	points to next byte in in-memory cue string
;	- Z=0		signals an error occurred in processing
;	- Z=1		signals processing occurred OK
;
; Commands are represented by the following bytes:
;	- cmd		full command w/arg count (see color64.inc for defs)
;			MSdigit is command code, LSdigit is arg count (zero based)
;
;	- argmask	single-byte bitfield organized <b7-b0> corresponding to 
;			arg7 - arg0 for all commands except FADE 0x48, 0x49
;			and 0x4A which require a preceding byte to encode the 
;			upper bits as <bF-b8> corresponding to arg 0x0F - 0x08.
;			If a bit is clear the literal value present in the 
;			following arg string will be used. If a bit is set 
;			then the arg at that location will be treated as an 
;			arg number, and the value computed from the arg of that 
;			number. If the arg number is greater than the max arg 
;			number an error will be returned.
;
;	- arg0		first arg in the arg string
;	- arg1		second arg in the arg string
;	  ....
;	- argN		Nth arg in the arg string
;

CUE_GET_COMMAND
	tblrd*+				; read cmd
	movf	TABLAT,W
	call	CMD_VALIDATE_CMDCODE
	btfss	STATUS,Z
	retlw	ERR_BAD_COMMAND		; return if error (with Z=0)

	; initialize context - each CGC_xxx gets the folling setup for them:
	; - cue_command = command code in lower 4 bits
	; - cue_argcount = number of args, 1 based
	; - cue_argmask = lower argmask (or upper if there are 2 argmask bytes)
	; - TBLPTR pointing to arg0 (or lower argmask if tehre are 2 argmask bytes)
	;
	lfsr	1,cmd_buffer		; initialize command buffer pointer
	movwf	POSTINC1		; save command code in first byte
	movwf	cue_argcount		; isolate & save arg count...
	movwf	cue_command		;...and command digit
	swapf	cue_command,F
	movlw	0x0F
	andwf	cue_argcount,F
	andwf	cue_command,F

	tblrd*+				; get first argument bitmask
	movff	TABLAT,cue_argmask	; will fix later if cmd has > 8 args

	; dispatch on command codes
	rlncf	cue_command,W		; get command code x2 into W...
	switch
	data	CGC_ERROR		; 00 = no command - error exit
	data	CGC_SET_BRT
	data	CGC_SET_HSB
	data	CGC_SET_RGB
	data	CGC_PATCH
	data	CGC_FADE
	data	CGC_WATCH

CGC_ERROR				; error return
	bcf	STATUS,Z
	retlw	ERR_GET_COMMAND_FAILED


;--- SET_BRT command handler ----
;--- SET_HSB command handler ----
;--- PATCH command handler ----
; Same code works for all commands

CGC_SET_BRT
CGC_SET_HSB
CGC_PATCH
	movff	cue_argcount,cue_loop_work
	incf	cue_loop_work,F		; increment to make counting easier
CGC_H1	tblrd*+				; get and save arg value
	movff	TABLAT,cue_argvalue
	btfsc	cue_argmask,0		; bit of interest in argmask is found in LSB
	call	CUE_GET_ARGUMENT	; perform arg reeplacement - returns in argvalue
	movff	cue_argvalue,POSTINC1	; move the value in
	rrncf	cue_argmask,F		; shift next arg bitmask value into bit 0
	decfsz	cue_loop_work,F		; looping test
	bra	CGC_H1
	call	CGC_COMMON_EXIT		; load command into comamnd table and exit	
	return

;--- SET_HSB command handler ----

CGC_SET_RGB				; ++++++ not implemented
	return

;--- WATCH command handler ---- 

CGC_WATCH
	tblrd*+				; get and save WATCH circuit or arg value
	movff	TABLAT,cue_argvalue	; save in arg_value
	btfsc	cue_argmask,0		; bit of interest in argmask is found in LSB
	call	CUE_GET_ARGUMENT	; perform arg replacement - returns in argvalue
	movff	cue_argvalue,POSTINC1	; move the value in
	call	CGC_COMMON_EXIT		; load command into comamnd table and exit	
	return

;--- FADE command handler ----

CGC_FADE
	clrf	cue_argflags		; initialize flags (ARG_HI_FLAG is zeroed)
	movf	cue_argcount,W
	sublw	0x07			; test if a larger argmask is required
	bc	CGC_P1
	movff	cue_argmask, cue_argmask_hi
	tblrd+*				; get second argument bitmask
	movff	TABLAT,cue_argmask
	bsf	cue_argflags,ARG_HI_FLAG ; signal that there are upper args
	movlw	0x08
	movwf	cue_loop_work		; set loop counter to do all 8 lo args
	bra	CGC_P2

	; do lower (up to) 8 arguments 
CGC_P1	movff	cue_argcount,cue_loop_work
	incf	cue_loop_work,F		; increment to make counting easier
CGC_P2	tblrd*+				; get and save arg value
	movff	TABLAT,cue_argvalue
	btfsc	cue_argmask,0		; bit of interest in argmask is found in LSB
	call	CUE_GET_ARGUMENT	; perform arg replacement - returns in argvalue
	movff	cue_argvalue,POSTINC1	; move the value in
	rrncf	cue_argmask,F		; shift next arg bitmask value into bit 0
	decfsz	cue_loop_work,F		; looping test
	bra	CGC_P2

	; test for and do upper (up to) 8 arguments 
	btfss	cue_argflags,ARG_HI_FLAG
	bra	CGC_COMMON_EXIT		; load command into command table
	movlw	0x07			; 8 minus 1
	subwf	cue_argcount,W
	movwf	cue_loop_work		; set loop counter
CGC_P3	tblrd*+				; get and save arg value
	movff	TABLAT,cue_argvalue
	btfsc	cue_argmask_hi,0	; bit of interest in argmask is found in LSB
	call	CUE_GET_ARGUMENT	; perform arg replacement - returns in argvalue
	movff	cue_argvalue,POSTINC1	; move the value in
	rrncf	cue_argmask_hi,F	; shift next arg bitmask value into bit 0
	decfsz	cue_loop_work,F
	bra	CGC_P3

;---- COMMON EXIT for PGC routines ----
; Load command into the command table and exit with status propogated from loader

CGC_COMMON_EXIT 
	; load the command into the command table
	lfsr	1,cmd_buffer		; initialize command buffer pointer
	call	CMD_LOADER		; load command (TBLPTR must be preserved)
;	bsf	STATUS,Z
	return

;*****************************************************************************
; CUE_SET_ARGUMENT	Load an argument structure into arg cell
;
; INPUTS:
;	- TBLPTR 	points to argnum in code space as per the following:
; 			CUE_ARG, argnum, opcode, var1, [var2], [var3]
; RETURNS:
;	- TBLPTR	points to next CUE_xxxx byte in string
;	- Z=0		signals an error occurred in processing
;	- Z=1		signals processing occurred OK

; Command arguments (args) are 4 byte structures that perform substitutions 
; for command variables during command loads. Args can perform literal 
; substitution for variables or a variety of simple math functions. Structure:
;
; 	- Arg number	args number 0 - N. Implicit based on location in table
;	- Opcode	operation to perform during argument substitution
;	- Operand1	(op1) first operand interprested by opcode
;	- Operand2	(op2) second operand interprested by opcode
;	- Operand3	(op3) thirg operand interprested by opcode
;
; Op2 and op3 can be used as a 16 bit address - refered to as "addr".
; See Argument OPCODE definitions for opcode details
;
; opcode	    var1   var2	  var3	usage
; OP_LIT	    value  ---	  ---	; use op1 as literal value
; OP_INC	    start  ---	  ---	; use op1, post increment & store in op1
; OP_INC_RANGE	    start  max	  min	; inc by 1 [op2=max, op3=min], store in op1
; OP_INCX2_RANGE    start  max	  min	; inc by 2 [op2=max, op3=min], store in op1
; OP_INCX3_RANGE    start  max	  min	; inc by 3 [op2=max, op3=min], store in op1
; OP_INCX4_RANGE    start  max	  min	; inc by 4 [op2=max, op3=min], store in op1
; OP_DEC	    start  ---	  ---	; use op1, post decrement & store in op1
; OP_DEC_RANGE	    start  max	  min	; dec by 1 [op2=max, op3=min], store in op1
; OP_DECX2_RANGE    start  max	  min	; dec by 2 [op2=max, op3=min], store in op1
; OP_DECX3_RANGE    start  max	  min	; dec by 3 [op2=max, op3=min], store in op1
; OP_DECX4_RANGE    start  max	  min	; dec by 4 [op2=max, op3=min], store in op1
; OP_ADD	    start  add	  ---	; (op1+op2), save result in op1
; OP_ADD_AND	    start  add	  and	; (op1+op2), AND with op3, do not save result
; OP_ADD_AND_SAVE   start  add	  and	; (op1+op2), AND with op3l, save result in op1
; OP_ADD_IND	    start  ind	  ---	; (op1+op2(op1)), do not save result
; OP_ADD_IND_SAVE   start  ind	  ---	; (op1+op2(op1)), save result in op1
; OP_ADD_IND_AND    start  ind	  and	; (op1+op2(op1)), AND with op3, do not save
; OP_ADD_IND_AND_SAVE srt  ind	  and	; (op1+op2(op1)), AND with op3, save in op1
; OP_SUB	    start  sub	  ---	; (op1-op2), save result in op1
; OP_SUB_AND	    start  sub	  and	; (op1-op2), AND with op3, do not save result
; OP_SUB_AND_SAVE   start  sub	  and	; (op1-op2), AND with op3, save in op1
; OP_SUB_IND	    start  ind	  ---	; (op1-op2(op1)), do not save result
; OP_SUB_IND_SAVE   start  ind	  ---	; (op1-op2(op1)), save result in op1
; OP_SUB_IND_AND    start  ind	  and	; (op1-op2(op1)), AND with op3, do not save
; OP_SUB_IND_AND_SAVE srt  ind	  and	; (op1-op2(op1)), AND with op3, save in op1
; OP_RAND	    seed   ---	  ---	; pseudo-random#, op1=seed, update seed
; OP_RAND_RANGE	    seed   max	  min	; pseudo-random# [op2=max, op3=min], op1=seed

CUE_SET_ARGUMENT
	tblrd*+				; read argnum
	movf	TABLAT,W
	call	CUE_SET_ARG_ADDR	; set FSR to opcode in arg_table
	tblrd*+				; get the opcode (keep in TABLAT)
	movf	TABLAT,W
	sublw	OP_OPCODE_MAX		; test for error in opcode value
	bc	CSA_DSP
	bcf	STATUS,Z		; return with error
	retlw	ERR_BAD_OPCODE

		; dispatch on opcode
CSA_DSP	rlncf	TABLAT,W		; get opcode x2 into W...
	switch
	data	CSA_OP_LIT		; start	 ---	---
	data	CSA_OP_INC		; start	 ---	---
	data	CSA_OP_INC_RANGE	; start  max	min
	data	CSA_OP_INCX2_RANGE	; start  max	min
	data	CSA_OP_INCX3_RANGE	; start  max	min
	data	CSA_OP_INCX4_RANGE	; start  max	min
	data	CSA_OP_DEC		; start  ---	---
	data	CSA_OP_DEC_RANGE	; start  max	min
	data	CSA_OP_DECX2_RANGE	; start  max	min
	data	CSA_OP_DECX3_RANGE	; start  max	min
	data	CSA_OP_DECX4_RANGE	; start  max	min
	data	CSA_OP_ADD		; start  add	---
	data	CSA_OP_ADD_AND		; start  add	and
	data	CSA_OP_ADD_AND_SAVE   	; start  add	and
	data	CSA_OP_ADD_IND		; start  ind	---
	data	CSA_OP_ADD_IND_SAVE	; start  ind	---
	data	CSA_OP_ADD_IND_AND	; start  ind	and
	data	CSA_OP_ADD_IND_AND_SAVE	; start  ind	and
	data	CSA_OP_SUB		; start  sub	---
	data	CSA_OP_SUB_AND		; start  sub	and
	data	CSA_OP_SUB_AND_SAVE	; start  sub	and
	data	CSA_OP_SUB_IND		; start  ind	---
	data	CSA_OP_SUB_IND_SAVE	; start  ind	---
	data	CSA_OP_SUB_IND_AND	; start  ind	---
	data	CSA_OP_SUB_IND_AND_SAVE	; start  ind	---
	data	CSA_OP_RAND		; seed   ---	---
	data	CSA_OP_RAND_RANGE	; seed   max	min

CSA_OP_INC_RANGE			; start  max	min
CSA_OP_INCX2_RANGE			; start  max	min
CSA_OP_INCX3_RANGE			; start  max	min
CSA_OP_INCX4_RANGE			; start  max	min
CSA_OP_DEC_RANGE			; start  max	min
CSA_OP_DECX2_RANGE			; start  max	min
CSA_OP_DECX3_RANGE			; start  max	min
CSA_OP_DECX4_RANGE			; start  max	min
CSA_OP_ADD_AND				; start  add	and
CSA_OP_ADD_AND_SAVE  		 	; start  add	and
CSA_OP_ADD_IND_AND			; start  ind	and
CSA_OP_ADD_IND_AND_SAVE			; start  ind	and
CSA_OP_SUB_AND				; start  sub	and
CSA_OP_SUB_AND_SAVE			; start  sub	and
CSA_OP_SUB_IND_AND			; start  ind	and
CSA_OP_SUB_IND_AND_SAVE			; start  ind	and
CSA_OP_RAND_RANGE			; seed   max	min
	; args w/ op1, op2, op3
	tblrd*+				; get op1
	movff	TABLAT,POSTINC1		; move to arg table
	; args w/ op1, op2
CSA_OP_ADD				; start  add	---
CSA_OP_ADD_IND				; start  ind	---
CSA_OP_ADD_IND_SAVE			; start  ind	---
CSA_OP_SUB				; start  sub	---
CSA_OP_SUB_IND				; start  ind	---
CSA_OP_SUB_IND_SAVE			; start  ind	---
	tblrd*+				; get op1 or op2
	movff	TABLAT,POSTINC1		; move to arg table
	; args w/ op1 only
CSA_OP_LIT				; start	 ---	---
CSA_OP_INC				; start	 ---	---
CSA_OP_DEC				; start  ---	---
CSA_OP_RAND				; seed   ---	---
	tblrd*+				; get op1 or op2 or op3
	movff	TABLAT,POSTINC1		; move to arg table
	bsf	STATUS,Z		; return OK
	return

;*****************************************************************************
; CUE_GET_ARGUMENT	Get an arguemnt value from an arg cell
;
; INPUTS:
;	- cue_argvalue 	contains the argument *number* to get
;
; RETURNS:
;	- cue_argvalue 	returns the argument *value*
;
; USES:
;	- uses FSR1 but restores it

CUE_GET_ARGUMENT
	movf	cue_argvalue,W		; validate arg number range
	call	CUE_CHECK_ARGNUM	; Note: validator destroys W
	btfss	STATUS,Z
	retlw	ERR_BAD_ARGNUM		; error return

	movff	FSR1H,cue_fsr1_temp_hi	; save FSR1
	movff	FSR1L,cue_fsr1_temp_lo
	movf	cue_argvalue,W
	call	CUE_SET_ARG_ADDR	; set FSR1 to arg table entry - opcode byte

	movff	POSTINC1,cue_opcode	; get opcode - FSR1 now points to op1
	movf	cue_opcode,W		; check for valid opcode
	call	CUE_CHECK_OPCODE	; Note: validator destroys W
	bz	PGA_01			; if Z=1, things are OK, otherwise error
	movff	cue_fsr1_temp_hi,FSR1H	; restore FSR1
	movff	cue_fsr1_temp_lo,FSR1L
	retlw	ERR_BAD_OPCODE		; error return

PGA_01	movff	POSTINC1,cue_op1	; get op1
	movff	POSTINC1,cue_op2	; get op2
	movff	INDF1,cue_op3		; get op3
	movf	POSTDEC1,W		; dummy instruction to decrement pointer
	movf	POSTDEC1,W		; leave pointer to op1

PGA_DSP	rlncf	cue_opcode,W		; get opcode x2 into W...
	switch				;...GOTOs require x4
	data	PGA_OP_LIT		; start	 ---	---
	data	PGA_OP_INC		; start	 ---	---
	data	PGA_OP_INC_RANGE	; start  max	min
	data	PGA_OP_INCX2_RANGE	; start  max	min
	data	PGA_OP_INCX3_RANGE	; start  max	min
	data	PGA_OP_INCX4_RANGE	; start  max	min
	data	PGA_OP_DEC		; start  ---	---
	data	PGA_OP_DEC_RANGE	; start  max	min
	data	PGA_OP_DECX2_RANGE	; start  max	min
	data	PGA_OP_DECX3_RANGE	; start  max	min
	data	PGA_OP_DECX4_RANGE	; start  max	min
	data	PGA_OP_ADD		; start  add	---
	data	PGA_OP_ADD_AND		; start  add	and
	data	PGA_OP_ADD_AND_SAVE   	; start  add	and
	data	PGA_OP_ADD_IND		; start  ind	---
	data	PGA_OP_ADD_IND_SAVE	; start  ind	---
	data	PGA_OP_ADD_IND_AND	; start  ind	and
	data	PGA_OP_ADD_IND_AND_SAVE	; start  ind	and
	data	PGA_OP_SUB		; start  sub	---
	data	PGA_OP_SUB_AND		; start  sub	and
	data	PGA_OP_SUB_AND_SAVE	; start  sub	and
	data	PGA_OP_SUB_IND		; start  ind	---
	data	PGA_OP_SUB_IND_SAVE	; start  ind	---
	data	PGA_OP_SUB_IND_AND	; start  ind	---
	data	PGA_OP_SUB_IND_AND_SAVE	; start  ind	---
	data	PGA_OP_RAND		; seed   ---	---
	data	PGA_OP_RAND_RANGE	; seed   max	min

PGA_OP_LIT				; use op1 as literal value
	bra	PGA_OK			; cue_argvalue is returned unchanged

PGA_OP_INC				; use op1, post increment & store in op1
	movff	cue_op1,cue_argvalue 
	incf	INDF1,F			; increment op1 unconditionally
	bra	PGA_OK

PGA_OP_INC_RANGE			; inc by 1 [op2=max, op3=min], store in op1
	movff	cue_op1,cue_argvalue
	incf	INDF1,F			; increment op1
	movf	cue_op2,W
	cpfsgt	INDF1			; compare and skip if op1 > op2
	bra	PGA_OK
	movff	cue_op3,INDF1		; load op1 with minimum value
	bra	PGA_OK

PGA_OP_INCX2_RANGE			; inc by 2 [op2=max, op3=min], store in op1
	movff	cue_op1,cue_argvalue
	movlw	0x02
	addwf	INDF1,F			; increment op1 by 2
	movf	cue_op2,W
	cpfsgt	INDF1			; compare and skip if op1 > op2
	bra	PGA_OK
	movff	cue_op3,INDF1		; load op1 with minimum value
	bra	PGA_OK

PGA_OP_INCX3_RANGE			; inc by 3 [op2=max, op3=min], store in op1
	movff	cue_op1,cue_argvalue
	movlw	0x03
	addwf	INDF1,F			; increment op1 by 3
	movf	cue_op2,W
	cpfsgt	INDF1			; compare and skip if op1 > op2
	bra	PGA_OK
	movff	cue_op3,INDF1		; load op1 with minimum value
	bra	PGA_OK

PGA_OP_INCX4_RANGE			; inc by 4 [op2=max, op3=min], store in op1
	movff	cue_op1,cue_argvalue
	movlw	0x04
	addwf	INDF1,F			; increment op1 by 4
	movf	cue_op2,W
	cpfsgt	INDF1			; compare and skip if op1 > op2
	bra	PGA_OK
	movff	cue_op3,INDF1		; load op1 with minimum value
	bra	PGA_OK

PGA_OP_DEC				; use op1, post decrement & store in op1
	movff	cue_op1,cue_argvalue 
	decf	INDF1,F			; increment op1 unconditionally
	bra	PGA_OK

PGA_OP_DEC_RANGE			; dec by 1 [op2=max, op3=min], store in op1
	movff	cue_op1,cue_argvalue
	decf	INDF1,F			; decrement op1 in place
	movf	cue_op3,W
	subwf	INDF1,W			; subtract the minimum from the new value
	bnc	PGAODR
	bra	PGA_OK
PGAODR	movff	cue_op2,INDF1		; load op1 with maximum value
	bra	PGA_OK

PGA_OP_DECX2_RANGE			; dec by 2 [op2=max, op3=min], store in op1
	movff	cue_op1,cue_argvalue
	movlw	0x02
	subwf	INDF1,F			; decrement op1 in place by 2
	bn	PGAOD2R			; trap the overlapped underflow condition
	movf	cue_op3,W
	subwf	INDF1,W			; subtract the minimum from the new value
	bnc	PGAOD2R
	bra	PGA_OK
PGAOD2R	movff	cue_op2,INDF1		; load op1 with maximum value
	bra	PGA_OK

PGA_OP_DECX3_RANGE			; dec by 3 [op2=max, op3=min], store in op1
	movff	cue_op1,cue_argvalue
	movlw	0x03
	subwf	INDF1,F			; decrement op1 in place by 2
	bn	PGAOD3R			; trap the overlapped underflow condition
	movf	cue_op3,W
	subwf	INDF1,W			; subtract the minimum from the new value
	bnc	PGAOD2R
	bra	PGA_OK
PGAOD3R	movff	cue_op2,INDF1		; load op1 with maximum value
	bra	PGA_OK

PGA_OP_DECX4_RANGE			; dec by 4 [op2=max, op3=min], store in op1
	movff	cue_op1,cue_argvalue
	movlw	0x04
	subwf	INDF1,F			; decrement op1 in place by 2
	bn	PGAOD4R			; trap the overlapped underflow condition
	movf	cue_op3,W
	subwf	INDF1,W			; subtract the minimum from the new value
	bnc	PGAOD2R
	bra	PGA_OK
PGAOD4R	movff	cue_op2,INDF1		; load op1 with maximum value
	bra	PGA_OK

PGA_OP_ADD				; (op1+op2), store in op1
	movf	cue_op2,W
	addwf	cue_op1,W
	movwf	INDF1
	movwf	cue_argvalue
	bra	PGA_OK

PGA_OP_ADD_AND				; (op1+op2), AND with op3, do not save result
	movf	cue_op2,W
	addwf	cue_op1,W
	movwf	INDF1
	movf	cue_op3,W
	andwf	INDF1,W
	movwf	cue_argvalue
	bra	PGA_OK

PGA_OP_ADD_AND_SAVE			; (op1+op2), AND with op3, save result in op1
	movf	cue_op2,W
	addwf	cue_op1,W
	movwf	INDF1
	movf	cue_op3,W
	andwf	INDF1,W
	movwf	INDF1			; save result
	movwf	cue_argvalue
	bra	PGA_OK

PGA_OP_ADD_IND				; (op1+op2(op1)), do not save result
	movf	cue_op2,W		; check for invalid arg number...
	call	CUE_CHECK_ARGNUM	; and return zero if so
	bz	POAI1
	clrf	cue_argvalue
	bra	PGA_OK
POAI1	movf	cue_op2,W
	call	CUE_SET_ARG_ADDR2	; set FSR2 to the indirect arg
	movf	PREINC2,W		; get value of op1 at argnum op2
	addwf	cue_op1,W
	movwf	cue_argvalue
	bra	PGA_OK

PGA_OP_ADD_IND_SAVE			; (op1+op2(op1)), save result in op1
	movf	cue_op2,W		; check for invalid arg number...
	call	CUE_CHECK_ARGNUM	; and return zero if so
	bz	POAIS1
	clrf	cue_argvalue
	bra	PGA_OK
POAIS1	movf	cue_op2,W
	call	CUE_SET_ARG_ADDR2	; set FSR2 to the indirect arg
	movf	PREINC2,W		; get value of op1 at argnum op2
	addwf	cue_op1,W
	movwf	cue_argvalue
	movwf	INDF1			; save result
	bra	PGA_OK

PGA_OP_ADD_IND_AND			; (op1+op2(op1)), AND with op3, do not save result
	movf	cue_op2,W		; check for invalid arg number...
	call	CUE_CHECK_ARGNUM	; and return zero if so
	bz	POAIA1
	clrf	cue_argvalue
	bra	PGA_OK
POAIA1	movf	cue_op2,W
	call	CUE_SET_ARG_ADDR2	; set FSR2 to the indirect arg
	movf	PREINC2,W		; get value of op1 at argnum op2
	addwf	cue_op1,W
	movf	cue_op3,W
	andwf	INDF1,W
	movwf	cue_argvalue
	bra	PGA_OK

PGA_OP_ADD_IND_AND_SAVE			; (op1+op2(op1)), AND with op3, save result
	movf	cue_op2,W		; check for invalid arg number...
	call	CUE_CHECK_ARGNUM	; and return zero if so
	bz	POAIAS1
	clrf	cue_argvalue
	bra	PGA_OK
POAIAS1	movf	cue_op2,W
	call	CUE_SET_ARG_ADDR2	; set FSR2 to the indirect arg
	movf	PREINC2,W		; get value of op1 at argnum op2
	addwf	cue_op1,W
	movf	cue_op3,W
	andwf	INDF1,W
	movwf	cue_argvalue
	movwf	INDF1			; save result
	bra	PGA_OK

PGA_OP_SUB				; (op1-op2), save result in op1
	movf	cue_op2,W
	subwf	cue_op1,W
	movwf	INDF1
	movwf	cue_argvalue
	bra	PGA_OK

PGA_OP_SUB_AND				; (op1-op2), AND with op3, do not save result
	movf	cue_op2,W
	subwf	cue_op1,W
	movwf	INDF1
	movf	cue_op3,W
	andwf	INDF1,W
	movwf	cue_argvalue
	bra	PGA_OK

PGA_OP_SUB_AND_SAVE			; (op1-op2), AND with op3, save result in op1
	movf	cue_op2,W
	subwf	cue_op1,W
	movwf	INDF1
	movf	cue_op3,W
	andwf	INDF1,W
	movwf	INDF1			; save result
	movwf	cue_argvalue
	bra	PGA_OK

;+++++ Not done yet
PGA_OP_SUB_IND				; (op1-op2(op1)), do not save result
PGA_OP_SUB_IND_SAVE			; (op1-op2(op1)), save result in op1
PGA_OP_SUB_IND_AND			; (op1-op2(op1)), AND with op3, do not save
PGA_OP_SUB_IND_AND_SAVE			; (op1-op2(op1)), AND with op3, save in op1
	bra	PGA_OK

PGA_OP_RAND				; pseudo-random#, op1=seed, update seed
	call	RAND
	movwf	INDF1
	movwf	cue_argvalue
	bra	PGA_OK
	
PGA_OP_RAND_RANGE			; pseudo-random# [op2=max, op3=min], op1=seed
	call	RAND
	movwf	INDF1			; reset seed to new value
	movwf	cue_op1			; working register

	movf	cue_op3,W		; get minumum
	subwf	cue_op2,W		; get difference between min and max (range)
	mulwf	cue_op1			; multiply rand * range
	movf	PRODH,W			; get hi byte of product
	addwf	cue_op3,W		; offset by minimum
	movwf	cue_argvalue		; return this value
	bra	PGA_OK

PGA_OK	movff	cue_fsr1_temp_hi,FSR1H	; restore FSR1
	movff	cue_fsr1_temp_lo,FSR1L
	bsf	STATUS,Z		; set status to OK
	return


;---- CUE_SET_ARG_ADDR ----
; Helper function to set the argument table address
; - takes argnum in W
; - returns FSR1 pointer to opcode byte in arg_table
; - assumes arg_table is on a page boundary
 
CUE_SET_ARG_ADDR
	movwf	FSR1L			; argument number...
	rlncf	FSR1L,F			; ...x2...
	rlncf	FSR1L,F			; ...x4
	movlw	HIGH arg_table
	movwf	FSR1H
	return

;---- CUE_SET_ARG_ADDR2 ----
; same as above, but sets FSR2

CUE_SET_ARG_ADDR2
	movwf	FSR2L			; argument number...
	rlncf	FSR2L,F			; ...x2...
	rlncf	FSR2L,F			; ...x4
	movlw	HIGH arg_table
	movwf	FSR2H
	return

;---- CUE_CHECK_ARGNUM ----
; Helper function to check for a valid argnum
; - takes argnum in W (destroys W)
; - returns Z = 1 if OK
; - returns Z = 0 if ERROR
 
CUE_CHECK_ARGNUM
	sublw	ARG_NUM_MAX
	bsf	STATUS,Z
	bc	PCAx
	bcf	STATUS,Z
PCAx	retlw	ERR_BAD_ARGNUM		; meaningful only if argnum fails

;---- CUE_CHECK_OPCODE ----
; Helper function to check for a valid opcode
; - takes argnum in W (destroys W)
; - returns Z = 1 if OK
; - returns Z = 0 if ERROR
 
CUE_CHECK_OPCODE
	sublw	OP_OPCODE_MAX
	bsf	STATUS,Z
	bc	PCOx
	bcf	STATUS,Z
PCOx	retlw	ERR_BAD_OPCODE		; meaningful only if opcode fails

;----- 8 bit pseudo random number generator - LFSR style -----
; The 'random' register (op1) must be seeded with a non-zero value
; Returns new randon # in W
; Will never return to zero
; Reference: http://www.piclist.com/techref/microchip/rand8bit.htm, LFSR example

RAND	rlncf	cue_op1,W	; seed must be non-zero... test for this
	bnz	RAND1
	movlw	0x01		; artificially set seed to 1
RAND1	btfsc	cue_op1,4
	xorlw	1
	btfsc	cue_op1,5
	xorlw	1
	btfsc	cue_op1,3
	xorlw	1
	return

;Alternate Random routine from Robert LaBudde and Nikolai Golovchenko
; Rnew = Rold * 221 + 53
; 221 = 256 - 32 - 4 + 1
; 256 can be eliminated so we need to calculate 
; Rnew = Rold * (1 - 32 - 4) + 53 
; using truncating arithmetic or Rnew = Rold * (-32 - 3) + 53
;	clrc
;	rlf     Number, 1	; needs conversion for PIC16
;	swapf   Number, 0
;	andlw   0xE0
;	rrf     Number, 1
;	addwf   Number, 0
;	addwf   Number, 0
;	addwf   Number, 0
;	sublw   0x35
;	movwf   Number

;*****************************************************************************
;***** UNIT TESTS ************************************************************
;*****************************************************************************

UT_PLAY
    if UNITS_ENABLED
;	call	UT_CUE_SET_ARGUMENT	; test setting all argument types
;	call	UT_CUE_GET_ARGUMENT	; test getting all argument types
;	call	UT_CUE_GET_COMMAND	; test getting commands
;	call	UT_CUE_GET_NEXT		; test loading commands
;	call	UT_CUE_LOAD_CUE		; test loading a cue
	call	UT_CUE_RUN_CUE		; run a cue from CUE_NUMBER_TABLE
;	call	UT_WALK_PLAYLIST	; walk playlist to test pointer routines
    endif
	return				; always have a return here for safety

    if UNITS_ENABLED

;--- test running a cue from the CUE_NUMBER_TABLE

UT_CUE_RUN_CUE
	clrf	cue_num_hi
	movlw	0x01
	movwf	cue_num_lo
	call	CUE_RUN_CUE
	return


;--- test Walk Playlist - pointer navigation routines ----

UT_WALK_PLAYLIST
	call	PLAY_INIT		; init and load first cue
	call	PLAY_GET_NEXT_PLAYLIST
	call	PLAY_GET_NEXT_PLAYLIST
	call	PLAY_GET_PREV_PLAYLIST
	call	PLAY_GET_PREV_PLAYLIST
	call	PLAY_GET_PREV_PLAYLIST
	call	PLAY_RUN_NEXT_CUE	; load next cue
	return

;--- test CUE_LOAD_CUE ----

ut_plp	macro	ADDRESS
	movlw	HIGH ADDRESS
	movwf	cue_ptr_hi
	movlw	LOW ADDRESS
	movwf	cue_ptr_lo
	call	CUE_LOAD_CUE
	endm
UT_CUE_LOAD_CUE
	ut_plp	UT_TEST2
	return

;--- test SET_ARGUMENT ----

ut_psa	macro	ADDRESS
	movlw	HIGH ADDRESS
	movwf	TBLPTRH
	movlw	LOW ADDRESS
	movwf	TBLPTRL
	tblrd+*				; increment past CUE_ARG
	call	CUE_SET_ARGUMENT
	endm
UT_CUE_SET_ARGUMENT			; set one of each type of argument
	ut_psa	UPSA_00
	ut_psa	UPSA_01
	ut_psa	UPSA_02
	ut_psa	UPSA_03
	ut_psa	UPSA_04
	ut_psa	UPSA_05
	ut_psa	UPSA_05
	ut_psa	UPSA_06
	ut_psa	UPSA_07
	ut_psa	UPSA_08
	ut_psa	UPSA_09
	ut_psa	UPSA_10
	ut_psa	UPSA_11
	ut_psa	UPSA_12
	ut_psa	UPSA_13
	ut_psa	UPSA_14
	ut_psa	UPSA_15
	ut_psa	UPSA_16
	ut_psa	UPSA_17
	ut_psa	UPSA_18
	ut_psa	UPSA_19
	ut_psa	UPSA_20
	ut_psa	UPSA_21
	ut_psa	UPSA_22
	ut_psa	UPSA_23
	ut_psa	UPSA_24
	ut_psa	UPSA_25
	ut_psa	UPSA_26
	return

;--- test GET_ARGUMENT ----

ut_pga	macro	ARGNUM, REPEAT		; set REPEAT to non-zero to loop forever
	local	restart
restart	movlw	ARGNUM
	movwf	cue_argvalue
	call	CUE_GET_ARGUMENT
    if REPEAT
	bra	restart
    endif
	endm
UT_CUE_GET_ARGUMENT
	ut_pga	.00,0			; OP_LIT	
	ut_pga	.01,0			; OP_INC
	ut_pga	.02,1			; OP_INC_RANGE
	ut_pga	.03,0			; OP_INCX2_RANGE	
	ut_pga	.04,0			; OP_INCX3_RANGE
	ut_pga	.05,0			; OP_INCX4_RANGE
	ut_pga	.06,0			; OP_DEC
	ut_pga	.07,0			; OP_DEC_RANGE
	ut_pga	.08,0			; OP_DECX2_RANGE
	ut_pga	.09,0			; OP_DECX3_RANGE
	ut_pga	.10,0			; OP_DECX4_RANGE
	ut_pga	.11,0			; OP_ADD
	ut_pga	.12,0			; OP_ADD_AND
	ut_pga	.13,0			; OP_ADD_AND_SAVE
	ut_pga	.14,0			; OP_ADD_IND
	ut_pga	.15,0			; OP_ADD_IND_SAVE
	ut_pga	.16,0			; OP_ADD_IND_AND
	ut_pga	.17,0			; OP_ADD_IND_AND_SAVE
	ut_pga	.18,0			; OP_SUB
	ut_pga	.19,0			; OP_SUB_AND
	ut_pga	.20,0			; OP_SUB_AND_SAVE
	ut_pga	.21,0			; OP_SUB_IND
	ut_pga	.22,0			; OP_SUB_IND_SAVE
	ut_pga	.23,0			; OP_SUB_IND_AND
	ut_pga	.24,0			; OP_SUB_IND_AND_SAVE
	ut_pga	.25,0			; OP_RAND
	ut_pga	.26,0			; OP_RAND_RANGE
	return

;--- test CUE_GET_COMMAND ----

ut_getc	macro	ADDRESS
	movlw	HIGH ADDRESS
	movwf	TBLPTRH
	movlw	LOW ADDRESS
	movwf	TBLPTRL
	tblrd+*				; skip the CUE_CMD table entry
	call	CUE_GET_COMMAND
	endm

UT_CUE_GET_COMMMAND
;	ut_getc	UPGC_00
;	ut_getc	UPGC_01
;	ut_getc	UPGC_02
;	ut_getc	UPGC_03
;	ut_getc	UPGC_04
	ut_getc	UPGC_05
	return
    endif

;--- test CUE_GET_NEXT_CMD ----

ut_lodc	macro	ADDRESS
	movlw	HIGH ADDRESS
	movwf	TBLPTRH
	movlw	LOW ADDRESS
	movwf	TBLPTRL
	call	CUE_GET_NEXT_COMMAND
	endm

UT_CUE_GET_NEXT
	ut_lodc	UT_TEST1
;	ut_lodc	UPGC_00
;	ut_lodc	UPGC_01
;	ut_lodc	UPGC_02
;	ut_lodc	UPGC_03
;	ut_lodc	UPGC_04
;	ut_lodc	UPGC_05
	return

;###########################################
;##### BEGIN DATA TABLES CODE SECTION ######
;###########################################

; Use code_pack of things can get out of alignment due to zero padding

DATA_LED_CUE_TABLES	code_pack

;---- Data used by unit tests

    if UNITS_ENABLED
;		CUE_ARG,argnum,opcode, var1, [var2], [var3]
UPSA_00	db	CUE_ARG, .00, OP_LIT, 0xAA
UPSA_01	db	CUE_ARG, .01, OP_INC, 0x02
UPSA_02	db	CUE_ARG, .02, OP_INC_RANGE, 0x01, 0x04, 0x00
UPSA_03	db	CUE_ARG, .03, OP_INCX2_RANGE, 0x01, 0x06, 0x00
UPSA_04	db	CUE_ARG, .04, OP_INCX3_RANGE, 0x01, 0x06, 0x00
UPSA_05	db	CUE_ARG, .05, OP_INCX4_RANGE, 0x01, 0x07, 0x00
UPSA_06	db	CUE_ARG, .06, OP_DEC, 0x02
UPSA_07	db	CUE_ARG, .07, OP_DEC_RANGE, 0x01, 0x08, 0x04
UPSA_08	db	CUE_ARG, .08, OP_DECX2_RANGE, 0x01, 0x08, 0x00
UPSA_09	db	CUE_ARG, .09, OP_DECX3_RANGE, 0x01, 0x10, 0x00
UPSA_10	db	CUE_ARG, .10, OP_DECX4_RANGE, 0x01, 0x10, 0x00
UPSA_11	db	CUE_ARG, .11, OP_ADD, 0x02, 0x07
UPSA_12	db	CUE_ARG, .12, OP_ADD_AND, 0x02, 0x07, 0x1F
UPSA_13	db	CUE_ARG, .13, OP_ADD_AND_SAVE, 0x02, 0x07, 0x1F
UPSA_14	db	CUE_ARG, .14, OP_ADD_IND, 0x02, 0x00, 0x00
UPSA_15	db	CUE_ARG, .15, OP_ADD_IND_SAVE, 0x02, 0x00, 0x00
UPSA_16	db	CUE_ARG, .16, OP_ADD_IND_AND, 0x02, 0x00, 0x00
UPSA_17	db	CUE_ARG, .17, OP_ADD_IND_AND_SAVE, 0x02, 0x00, 0x00
UPSA_18	db	CUE_ARG, .18, OP_SUB, 0x02, 0x01
UPSA_19	db	CUE_ARG, .19, OP_SUB_AND, 0x02, 0x01, 0x07
UPSA_20	db	CUE_ARG, .20, OP_SUB_AND_SAVE, 0x02, 0x01, 0x07
UPSA_21	db	CUE_ARG, .21, OP_SUB_IND, 0x02, 0x00, 0x00
UPSA_22	db	CUE_ARG, .22, OP_SUB_IND_SAVE, 0x02, 0x00, 0x00
UPSA_23	db	CUE_ARG, .23, OP_SUB_IND_AND, 0x02, 0x00, 0x00
UPSA_24	db	CUE_ARG, .24, OP_SUB_IND_AND_SAVE, 0x02, 0x00, 0x00
UPSA_25	db	CUE_ARG, .25, OP_RAND, 0xCB
UPSA_26	db	CUE_ARG, .26, OP_RAND_RANGE, 0xCB, 0x88, 0x78

;		CUE_CMD,cmd,argmask,ckt,prescale,delay,up,on,down,off,[rpt,min,max,xfade]
UPGC_00	db	CUE_CMD,FADE,0x0F, .23, 1,2,3,4,5,6
UPGC_01	db	CUE_CMD,FADE_REPEAT,0x0F, 23, 1,2,3,4,5,6,7
UPGC_02	db	CUE_CMD,FADE_MIN,0x00,0x0F, 23, 1,2,3,4,5,6,7,8
UPGC_03	db	CUE_CMD,FADE_X,0x00,0x0F, 23, 1,2,3,4,5,6,7,8,9,.10
UPGC_04	db	CUE_CMD,FADE,0x0F, 23, 1,2,3,4,5,6
UPGC_05	db	CUE_CMD,FADE,0x00, .5, 1,0,0xFF,0xFF,0xFF,0xFF

UT_TEST1
	db	CUE_ARG,4,OP_INCX4_RANGE,0,0xFF,0x00 ; arg0, increment by 1, starting at 0

		;			  arg0
	db	CUE_CMD,FADE,0x01, 4, 1,0,0xFF,0xFF,0xFF,0xFF
	db	CUE_CMD,FADE,0x01, 4, 1,0,0xFF,0xFF,0xFF,0xFF
	db	CUE_CMD,FADE,0x01, 4, 1,0,0xFF,0xFF,0xFF,0xFF
	db	CUE_CMD,FADE,0x01, 4, 1,0,0xFF,0xFF,0xFF,0xFF

	db	CUE_DONE

UT_TEST2
; SET_HSB 	CUE_CMD SET_HSB  mask  chn  hue   sat   brt 	
	db	CUE_CMD,SET_HSB, 0x00, .00, 0x00, 0x00, 0xFF
	db	CUE_CMD,SET_HSB, 0x00, .01, 0x00, 0x00, 0x80
	db	CUE_CMD,SET_HSB, 0x00, .02, 0x00, 0x00, 0x00
	db	CUE_CMD,SET_HSB, 0x00, .03, 0x00, 0x00, 0x00
	db	CUE_CMD,SET_HSB, 0x00, .04, 0x00, 0x00, 0x00
	db	CUE_CMD,SET_HSB, 0x00, .05, 0x00, 0x00, 0x00
	db	CUE_CMD,SET_HSB, 0x00, .06, 0x00, 0x00, 0x00
	db	CUE_CMD,SET_HSB, 0x00, .07, 0x00, 0x00, 0x00
	db	CUE_CMD,SET_HSB, 0x00, .08, 0x00, 0x00, 0x00
	db	CUE_CMD,SET_HSB, 0x00, .09, 0x00, 0x00, 0x00
	db	CUE_CMD,SET_HSB, 0x00, .10, 0x00, 0x00, 0x00
	db	CUE_CMD,SET_HSB, 0x00, .11, 0x00, 0x00, 0x00
	db	CUE_CMD,SET_HSB, 0x00, .12, 0x00, 0x00, 0x00
	db	CUE_CMD,SET_HSB, 0x00, .13, 0x00, 0x00, 0x00
	db	CUE_CMD,SET_HSB, 0x00, .14, 0x00, 0x00, 0x00
	db	CUE_CMD,SET_HSB, 0x00, .15, 0x00, 0x00, 0x00
	db	CUE_CMD,SET_HSB, 0x00, .16, 0x00, 0x00, 0x00
	db	CUE_CMD,SET_HSB, 0x00, .17, 0x00, 0x00, 0x00
	db	CUE_CMD,SET_HSB, 0x00, .18, 0x00, 0x00, 0x00
	db	CUE_CMD,SET_HSB, 0x00, .19, 0x00, 0x00, 0x00
	db	CUE_CMD,SET_HSB, 0x00, .20, 0x00, 0x00, 0x00
	db	CUE_CMD,SET_HSB, 0x00, .21, 0x00, 0x00, 0x00
	db	CUE_CMD,SET_HSB, 0x00, .22, 0x00, 0x00, 0x00
	db	CUE_CMD,SET_HSB, 0x00, .23, 0x00, 0x00, 0x00
	db	CUE_CMD,SET_HSB, 0x00, .24, 0x00, 0x00, 0x00
	db	CUE_CMD,SET_HSB, 0x00, .25, 0x00, 0x00, 0x00
	db	CUE_CMD,WATCH,0x00,NEVER
	db	CUE_DONE

    endif

;******************************************************************************
; PLAYLIST AND CUE DATA FILE

#include <led_data.inc>

	END
