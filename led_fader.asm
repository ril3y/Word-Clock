;*****************************************************************************
; PIC18F family - commands and fader processing
;*****************************************************************************
;
;    Filename:	    	led_fader.asm
;    Function:		supports fader commands
;    Author, Company:	Alden Hart, Luke's Lights
;    Chip Support:	Supports PIC18F family chips
;    Revision:		090711
;
; Faders are the command tables that perform fades. Commands (fader commands) 
; are the instructions that are loaded into them. Things that work with commands 
; are prefixed by CMD_ or cmd_. Things that work with faders are prefixed by
; FDR_ or fdr_. The commands and fader definitions are so intertwined that I 
; decided not to separate them out.

;----- Include files and other setup------

#include <global.inc>			; 1: global defines - must be first
#include <DEV_INCLUDE_FILE>		; 2: Our device include file
#include <LED_INCLUDE_FILE>		; 3: LED subsystem include file
#include <APP_INCLUDE_FILE>		; 4: Application include file

;------ Exports (globals) -----

	global	fdr_level		; finishing level of fade
	global	FDR_DISPATCH		; dispatch a command
	global	FDR_TEST_FDR_DONE	; return Z=1 if fader is done or inactive

	global	cmd_buffer		; command input buffer
	global	CMD_LOADER		; load input buffer into fader table
	global	CMD_VALIDATE_CMDCODE	; validate command code

	global	UT_CMD			; command unit tests

;----- External variables and FUNCTIONS -----

	extern	chn_num
	extern	ckt_num
	extern	app_flags
	extern	cycle_prescale
	extern	cue_watch
	extern	temp_tblptrh
	extern	temp_tblptrl

CMD_BUFFER_LEN	equ	.14		; should be 12.

;---- FADER EQUATES ----
; Fader table indexes (offsets into fader command structure)
; The use of some table entries changes based on fader state, so they overlap
; The code assumes that FDR_STATE, FDR_LEVEL_H and FDR_LEVEL_L are in the 
;    locations and order below. If you change them you must also modify the code.
;    ...big time. Don't do it.

FDR_STATE		equ	.00	; base of table		; MUST BE IN ORDER
FDR_LEVEL_H		equ	.01	; level hi byte		; MUST BE IN ORDER
FDR_LEVEL_L		equ	.02	; level lo byte		; MUST BE IN ORDER

FDR_COUNTER		equ	.02	; counter register
FDR_PRESCALE		equ	.03	; prescaler register	; MUST BE IN ORDER
FDR_UP_INCR_H		equ	.04	; UP increment hi byte
FDR_UP_INCR_L		equ	.05	; UP increment lo byte

FDR_WAIT		equ	.04	; delay to wait register
FDR_XFADE		equ	.05	; cross fade register

FDR_DOWN_DECR_H		equ	.06	; DOWN decrement hi byte
FDR_DOWN_DECR_L		equ	.07	; DOWN decrement lo byte

FDR_UP			equ	.06	; initial UP value
FDR_DOWN		equ	.07	; initial DOWN value
FDR_DWELL		equ	.08	; pulse dwell time (on cycles)
FDR_OFF			equ	.09	; pulse OFF time (off cycles)
FDR_MIN			equ	.10	; minimum pulse level
FDR_MAX			equ	.11	; maximum pulse level
FDR_REPEAT		equ	.12	; repeat counter

FDR_MASTER_CKT		equ	.02	; master circuit number
FDR_MASTER_PRESCALE	equ	.03	; master prescaler value
FDR_MASTER_L		equ	.04	; master address lo byte
FDR_MASTER_H		equ	.05	; master address hi byte

FDR_DIRTY_FLAG_OFS	equ	.02	; flag to set dirty bit for set_hsb and set_rgb

FDR_PRESCALE_1		equ	.01	; prescale setting to fire every time
FDR_DIRTY_FLAG		equ	0xFF	; dirty flag value for set_hsb & set_rgb

; Fader state

FDR_STATE_DONE		equ	.00	; facder is done    !!! MUST BE ZERO !!!
FDR_STATE_DISABLED	equ	FDR_STATE_DONE	; alias of DONE

FDR_STATE_WAIT		equ	.01	; pre-execution delay
FDR_STATE_XFADE_UP	equ	.02	; initial cross-fade, up
FDR_STATE_XFADE_DOWN	equ	.03	; initial cross-fade, down
FDR_STATE_UP		equ	.04	; stepping up
FDR_STATE_DWELL 	equ	.05	; counting on-time
FDR_STATE_DOWN		equ	.06	; stepping down
FDR_STATE_OFF 		equ	.07	; counting off-time

FDR_STATE_PATCH		equ	.08	; patch mode
FDR_STATE_SET_HSB	equ	.09	; set_hsb
FDR_STATE_SET_RGB	equ	.10	; set_rgb

FDR_STATE_MAX		equ	.10  	; upper range for states
					; used to test for bad state variable

;------ RAM definitions -----

;##### BANK 0 #####
UDATA_BANK_0_ACS	udata_acs	; linker allocates space in bank 0

;----- Fader and command variables ----
fdr_level		res	1	; returns LEVEL of fader channel
fdr_temp		res	1	; general purpose working register
fdr_temp_hi		res	1	; working storage for HI byte
fdr_temp_lo		res	1	; working storage for LO byte
fdr_temp_min		res	1	; working storage for MIN
fdr_temp_max		res	1	; working storage for MAX
;fdr_save_table_hi	res	1	; TBLPTR storage for SET_FDR_TABLE_PTR
;fdr_save_table_lo	res	1

cmd_command		res	1	; fader command byte
cmd_argcount		res	1	; fader command argument count
cmd_ut_temp		res	1	; temp for unit tests

cmd_buffer		res	CMD_BUFFER_LEN+1 ; fader command input buffer
				; can be moved to a hi bank if space is needed

;----- Fader tables -----

UDATA_FADER_TABLES_100	udata	0x100

fdr_00	res	FDR_TABLE_LEN
fdr_01	res	FDR_TABLE_LEN		; 19 x 13 = 247 bytes
fdr_02	res	FDR_TABLE_LEN
fdr_03	res	FDR_TABLE_LEN
fdr_04	res	FDR_TABLE_LEN
fdr_05	res	FDR_TABLE_LEN
fdr_06	res	FDR_TABLE_LEN
fdr_07	res	FDR_TABLE_LEN
fdr_08	res	FDR_TABLE_LEN
fdr_09	res	FDR_TABLE_LEN
fdr_10	res	FDR_TABLE_LEN
fdr_11	res	FDR_TABLE_LEN
fdr_12	res	FDR_TABLE_LEN
fdr_13	res	FDR_TABLE_LEN
fdr_14	res	FDR_TABLE_LEN
fdr_15	res	FDR_TABLE_LEN
fdr_16	res	FDR_TABLE_LEN
fdr_17	res	FDR_TABLE_LEN
fdr_18	res	FDR_TABLE_LEN

UDATA_FADER_TABLES_200	udata	0x200

dummy_label_200				; needs this to link. Don't ask me why.

fdr_19	res	FDR_TABLE_LEN		; 7 x 13 = 91 bytes
fdr_20	res	FDR_TABLE_LEN
fdr_21	res	FDR_TABLE_LEN
fdr_22	res	FDR_TABLE_LEN
fdr_23	res	FDR_TABLE_LEN
fdr_24	res	FDR_TABLE_LEN
fdr_25	res	FDR_TABLE_LEN


;###############################
;##### BEGIN CODE SECTION ######
;###############################

CODE_LED_FADER_CODE	code

;******************************************************************************
;***** COMMAND SUBSYSTEM ******************************************************
;******************************************************************************

;******************************************************************************
; CMD_LOADER
;
; Loads commands from buffer pointed to by FSR1 to fader table via FSR2
;
; The command loader is responsible for moving commands from a command input
; buffer into the correct fader table, and for detecting and dispatching 
; commands that require immediate execution. The command loader is also 
; responsible for any translations that may be required to change the command 
; into an internal format.
;
; [Command readers are responsible for collecting bytes from serial IO or from
;  memory and constructing the command buffer that the loader uses]
;
; INPUTS: FSR1		input buffer pointer
; RETURN: Z=1 if OK, OK=0 signals an error occurred in processing
;
; USES:	- W		used primarily for table offsets
;	- FSR2		fader table pointer
;
; Commands:
;	- 0x01		SET_HSB
;	- 0x02		SET_RGB
;	- 0x03		PATCH
;	- 0x04		FADE
;	- 0x05		WATCH

CMD_LOADER
	movf	POSTINC1,W		; get (supposed) command byte
	call	CMD_VALIDATE_CMDCODE
	btfss	STATUS,Z
	retlw	ERR_BAD_COMMAND		; return if error (Z=0)

	; isolate and store command digit and byte count digit
	movwf	cmd_argcount
	movwf	cmd_command
	swapf	cmd_command,F
	movlw	0x0F
	andwf	cmd_argcount,F
	andwf	cmd_command,F

	; dispatch on command code
	rlncf	cmd_command,W
	switch
	data	CL_ERROR		; THESE MUST BE IN ORDER. See led.inc
	data	CL_LOAD_SET_BRT		; 0x1_
	data	CL_LOAD_SET_HSB		; 0x2_
	data	CL_LOAD_SET_RGB		; 0x3_
	data	CL_LOAD_PATCH		; 0x4_
	data	CL_LOAD_FADE		; 0x5_
	data	CL_LOAD_WATCH		; 0x6_

;----- CL_ERROR -----
; Return for loader error

CL_ERROR
	bcf	STATUS,Z		; clear Z to signal ERROR
	retlw	ERR_CMD_LOADER_FAILED

;---- CL_LOAD_SET_BRT -----
; Load brightness value into one fader (reduced version of SET_HSB)
;       - cmd	command   [M] command byte: MSD=command, LSD=arg count
;	- arg0	channel	  [M] <b5-b0> = ch0 - ch63
;	- arg1	brt	  [M] 0x00-0xFF
;
; Routine is entered with:
;	- cmd_command set
;	- cmd_argcount set
;	- FSR1 pointing to arg0

CL_LOAD_SET_BRT
    if MONOCHROME_MODE
	movf	POSTINC1,W		; get channel number
	andlw	0x1F			; mask the unused bits for safety
    else
	rlncf	POSTINC1,W		; get channel number x2
	andlw	0x7E			; mask the unused bits for safety
	movf	POSTINC1,W		; get channel number
	andlw	0x1F			; mask the unused bits for safety
	movwf	fdr_temp
	rlncf	fdr_temp,W		; convert to circuit number in W
    endif

	call	FDR_SET_FDR_TABLE_PTR	; set FRS2 to base of correct fader table
	movlw	FDR_STATE_SET_HSB
	movwf	POSTINC2		; write STATE and advance pointer to VALUE
	movff	POSTINC1,POSTINC2	; write BRT into table
	movlw	FDR_DIRTY_FLAG		; write the dirty flag for first time through
	movwf	POSTINC2		
	movlw	FDR_PRESCALE_1		; write the prescaler value into the table
	movwf	INDF2

	bsf	STATUS,Z		; set Z to signal no error
	return	

;---- CL_LOAD_SET_HSB -----
; Load HSB values into the 3 circuits corresponding to the indicated channel
;       - cmd	command   [M] command byte: MSD=command, LSD=arg count
;	- arg0	channel	  [M] <b5-b0> = ch0 - ch63
;	- arg1	hue	  [M] 0x00-0xFF
;	- arg2	sat	  [M] 0x00-0xFF
;	- arg3	brt	  [M] 0x00-0xFF
;
; Routine is entered with:
;	- cmd_command set
;	- cmd_argcount set
;	- FSR1 pointing to arg0

CL_LOAD_SET_HSB
	rlncf	POSTINC1,W		; get channel number x2
	andlw	0x7E			; mask the unused bits for safety
	movwf	ckt_num			; ckt_num is actually a *CHANNEL NUMBER* 
					;...in this case

	rlncf	ckt_num,W		; convert to circuit number in W
	call	FDR_SET_FDR_TABLE_PTR	; set FRS2 to base of correct fader table
	movlw	FDR_STATE_SET_HSB
	movwf	POSTINC2		; write STATE and advance pointer to VALUE
	movff	POSTINC1,POSTINC2	; write HUE into table
	movlw	FDR_DIRTY_FLAG		; write the dirty flag for first time through
	movwf	POSTINC2		
	movlw	FDR_PRESCALE_1		; write the prescaler value into the table
	movwf	INDF2

	rlncf	ckt_num,W		; convert to circuit number in W
	iorlw	0x01			; set to SAT
	call	FDR_SET_FDR_TABLE_PTR
	movlw	FDR_STATE_SET_HSB
	movwf	POSTINC2		; write STATE and advance pointer to VALUE
	movff	POSTINC1,POSTINC2	; write SAT into table
	movlw	FDR_DIRTY_FLAG		; write the dirty flag for first time through
	movwf	POSTINC2		
	movlw	FDR_PRESCALE_1		; write the prescaler value into the table
	movwf	INDF2

	rlncf	ckt_num,W		; convert to circuit number in W
	iorlw	0x02			; set to BRT
	call	FDR_SET_FDR_TABLE_PTR
	movlw	FDR_STATE_SET_HSB
	movwf	POSTINC2		; write STATE and advance pointer to VALUE
	movff	POSTINC1,POSTINC2	; write BRT into table
	movlw	FDR_DIRTY_FLAG		; write the dirty flag for first time through
	movwf	POSTINC2		
	movlw	FDR_PRESCALE_1		; write the prescaler value into the table
	movwf	INDF2

	bsf	STATUS,Z		; set Z to signal no error
	return	

;---- CL_LOAD_SET_RGB -----

CL_LOAD_SET_RGB				;++++++ NOT IMPLEMENTED
	bsf	STATUS,Z		; set Z to signal no error
	return	


;---- CL_LOAD_PATCH -----

CL_LOAD_PATCH
	movf	POSTINC1,W		; get circuit number for slave circuit
	movwf	fdr_temp		; save slave circuit number (destination)

	movf	INDF1,W			; get master circuit number
	movwf	fdr_temp_min		; just borrow this register for master ckt#
	call	FDR_SET_FDR_TABLE_PTR	; set FSR2 to it
	movf	INDF2,W			; get master STATE
	bz	CLS_x			; master is OFF. Exit
	movff	FSR2H,fdr_temp_hi	; save pointer to master LEVEL_H
	movff	FSR2L,fdr_temp_lo

	movf	fdr_temp,W		; get slave circuit number back
	call	FDR_SET_FDR_TABLE_PTR	; get slave address (I had to say that)
	movlw	FDR_STATE_PATCH
	movwf	POSTINC2		; write state
	movf	POSTINC2,W		; dummy instruction, advances past LEVEL_H
	movf	fdr_temp_min,W		; get and write master circuit number
	movwf	POSTINC2
	movlw	FDR_PRESCALE_1		; write the presaler value into the table
	movwf	POSTINC2
	movff	fdr_temp_lo,POSTINC2	; write master address
	movff	fdr_temp_hi,POSTINC2

CLS_x	bsf	STATUS,Z		; set Z to signal no error
	return	

;---- CL_LOAD_FADE -----
; Load FADE command. Specific actions are required for each argument:
; 
;       - cmd	command   [M] command byte: MSD=command, LSD=arg count
;	- arg0	circuit	  [M] <b7-b2> = ch0 - ch63
;			      <b1-b0> = 0=HUE, 1=SAT, 2=BRT, 3=EXTRA
;	- arg1	prescale  [M] <b7-b0> = 256, 64, 32, 16, 8, 4, 2, 1
;	- arg2	wait      [M] 0x00-0xFF  in cycles (increment on load)
;	- arg3	up        [M] 0x00-0xFF  in cycles
;	- arg4	dwell     [M] 0x00-0xFF  in cycles
;	- arg5	down      [M] 0x00-0xFF  in cycles
;	- arg6	off       [M] 0x00-0xFF  in cycles
;	- arg7	repeat    [O] 0x00-0xFF  0x00 = default = repeat forever
;	- arg8	min       [O] 0x00-0xFF  0x00 = default
;	- arg9	max       [O] 0x00-0xFF  0xFF = default
;	- arg10	xfade     [O] 0x00-0xFF  0x00 = default = no cross fade
;
; Routine is entered with:
;	- cmd_command set
;	- cmd_argcount set
;	- FSR1 pointing to arg0
;
; Do not clobber LEVEL_H in the command table. All else if fair game.
; Don't worry about commands executing during load - these are exclusive

CL_LOAD_FADE
	movf	POSTINC1,W		; load command circuit
	call	FDR_SET_FDR_TABLE_PTR	; set FSR2 to base of table

	; load mandatory arguments
	movlw	FDR_PRESCALE		; arg1 - prescale
	movff	POSTINC1,PLUSW2

	movlw	FDR_WAIT		; arg2 - delay
	movff	POSTINC1,PLUSW2
	incf	PLUSW2			; increment delay by 1

	movlw	FDR_UP			; arg3 - up
	movff	POSTINC1,PLUSW2

	movlw	FDR_DWELL			; arg4 - on
	movff	POSTINC1,PLUSW2

	movlw	FDR_DOWN		; arg5 - down
	movff	POSTINC1,PLUSW2

	movlw	FDR_OFF			; arg6 - off
	movff	POSTINC1,PLUSW2

	; end of mandatory args - rest are optional
	movlw	0x07			; arg7 - repeat
	subwf	cmd_argcount,W
	bnc	CLP_RPT
	movlw	FDR_REPEAT
	movff	POSTINC1,PLUSW2

	movlw	0x08			; arg8 - min
	subwf	cmd_argcount,W
	bnc	CLP_MIN
	movlw	FDR_MIN
	movff	POSTINC1,PLUSW2

	movlw	0x09			; arg9 - max
	subwf	cmd_argcount,W
	bnc	CLP_MAX
	movlw	FDR_MAX
	movff	POSTINC1,PLUSW2

	movlw	0x0A			; arg10 - xfade
	subwf	cmd_argcount,W
	bnc	CLP_XFD
	movlw	FDR_XFADE
	movff	POSTINC1,PLUSW2

	bra	CLP_FIN

	; code sequence to load defaults. Multiple entry points
CLP_RPT	movlw	FDR_REPEAT
	clrf	PLUSW2			; REPEAT = 0

CLP_MIN	movlw	FDR_MIN
	clrf	PLUSW2			; MIN = 0

CLP_MAX	movlw	FDR_MAX
	clrf	PLUSW2			; MAX = 0
	decf	PLUSW2,F		; MAX = 0xFF

CLP_XFD	movlw	FDR_XFADE
	clrf	PLUSW2			; MAX = 0

CLP_FIN	movlw	FDR_STATE_WAIT		; set initial state
	movwf	INDF2
	bsf	STATUS,Z		; return signalling no error
	return	

;---- CL_LOAD_WATCH -----
; Load WATCH register. Legal values are:
;	0x00 to CKT_NUM_MAX		; first fader channel to max encoded ckt
;	NOW (0xFE)			; load cue now
;	NEVER (0xFF)			; never load cue (disable watch)
;
; Routine is entered with:
;	- cmd_command set
;	- cmd_argcount set
;	- FSR1 pointing to arg0 - which is the WATCH value

CL_LOAD_WATCH
	movf	POSTINC1,W		; get watch value
	movwf	cue_watch
	bsf	STATUS,Z		; set Z to signal no error
	return	

;----- CMD_VALIDATE_CMDCODE -----
; validate raw command byte (cmd+argcount) in W
; returns with Z=1 if command is OK, Z=0 if command error
; See led_fader.asm 091125 or earlier if you want a table lookup version

cvc_tst	macro	test_against		; macro to perform code test
	movf	cmd_command,W		; restore command to W
	xorlw	test_against		; sets Z bit if match
	bz	CVC_OK
	endm

CMD_VALIDATE_CMDCODE
	movwf	cmd_command		; save command byte
					
	; comment out the ones you don't need or want
	cvc_tst	SET_BRT
;	cvc_tst	SET_HSB			; color only
;	cvc_tst	SET_RGB			; color only
	cvc_tst	PATCH
	cvc_tst	FADE
	cvc_tst	FADE_REPEAT
	cvc_tst	FADE_MIN
	cvc_tst	FADE_MAX
	cvc_tst	FADE_X
	cvc_tst	WATCH
	; falls through to error condition

CVC_ERR	bcf	STATUS,Z		; clear Z to signal ERROR
	retlw	ERR_BAD_COMMAND		; z is already set to zero

CVC_OK	movf	cmd_command,W		; restore command
	bsf	STATUS,Z		; set Z to signal OK
	return

;******************************************************************************
;***** FADER SUBSYSTEM ********************************************************
;******************************************************************************

;******************************************************************************
; FDR_DISPATCH
;
; Fader command processor - common dispatcher for all commands
;
; INPUTS:
;	- ckt_num	Circuit number to dispatch and execute 
;
; RETURNS:
;	- fdr_level	Final level of computed command. This value is read
;			from the table (LEVEL_H) at the start of the routine
;			and must remain unmolested throughout all processing.
;			It is set to the new value of LEVEL_H on exit; and is
;			used to determine if the DIRTY_BIT needs to be set.
;
;	- app_flags	DIRTY_BIT is set if the output LEVEL_H changes, but 
;			is not cleared if it does not. This allows the DIRTY_BIT
;			to accumulate a state change over an entire HSB triplet.
;
;	- Z bit		Set to reflect dirty bit
;
; Notes: 
;	PRESCALER:	<b7-b0>	prescaler bit flags: 256, 128, 64, 32, 16, 4, 2, 1
;
; The following convention is used for the state machine entry points. 
; (Not all states have all these entry points)
;
;	_FIRST		executed only the first time this state is entered
;	_CYCLE		executed once per cycle
;	_STATE		executed every time the state is called
;
; Profiles measured via unit tests:
;	 9	RETURN FROM DISABLED STATE
;	13	RETURN FROM NO PRESCALER HIT
;	27	WAIT
;	91	XFADE_FIRST
;	53	XFADE_UP_STATE
;      119	XFADE_FIN (includes ON_CYCLE)
;	65	DWELL_CYCLE
;	34	DWELL_STATE
;	60	DOWN_CYCLE
;	55	DOWN_STATE
;	69	OFF_CYCLE
;	34	OFF_STATE
;	62	UP_CYCLE (+REPEAT)
;	53	UP_STATE
;
; Roughly 50 cycles per active pass estimates on the high side. Some percentage
; of channels will be off - i.e. DONE, or not all of H,S & B are running, and 
; some channels may be running slower than 1x prescaler.
;
FDR_DISPATCH
	; set FSR2 to location in table
	movf	chn_num,W
	call	FDR_SET_FDR_TABLE_PTR	

	; always returns the the level value
	movlw	FDR_LEVEL_H
	movff	PLUSW2,fdr_level	; get fader LEVEL from fader table

	; quick cutout for disabled channel
	movlw	FDR_STATE_DISABLED
	cpfsgt	INDF2
	return

	; check the prescaler bits to see if the command should be executed
	movlw	FDR_PRESCALE		; set PRESCALE offset
	movf	PLUSW2,W		; get PRESCALE byte
	andwf	cycle_prescale,W
	bnz	FDR_D1			; branch to execute command
	return				; exit if not a cycle on which to dispatch

	; dispatch to exec routine on command state
FDR_D1	rlncf	INDF2,W			; get state x2 into W...
	switch
	data	FDR_EXEC_EXIT		; 00 = disabled circuit. Just exit.
	data	FDR_EXEC_WAIT_STATE	; initial entry point for PULSE cmd
	data	FDR_EXEC_XFADE_UP_STATE
	data	FDR_EXEC_XFADE_DOWN_STATE
	data	FDR_EXEC_UP_STATE
	data	FDR_EXEC_DWELL_STATE
	data	FDR_EXEC_DOWN_STATE
	data	FDR_EXEC_OFF_STATE
	data	FDR_EXEC_PATCH
	data	FDR_EXEC_SET_HSB	; also serves SET_BRT
	data	FDR_EXEC_SET_RGB

;---- FDR_EXEC_EXIT - Common exit -----
; Tests for LEVEL_H changes and sets dirty bit if so

FDR_EXEC_EXIT
	movlw	FDR_LEVEL_H
	movf	PLUSW2,W		; get LEVEL_H from table
	cpfseq	fdr_level,W
	bsf	app_flags,DIRTY_BIT	; set DIRTY_BIT if not equal
	movwf	fdr_level		; return the new level
	return

;---- FDR_EXEC_DELAY routines -----

;FDR_EXEC_WAIT_FIRST	; first time entry point (NULL)
;FDR_EXEC_WAIT_CYCLE	; cycle re-entry point (NULL)
FDR_EXEC_WAIT_STATE	; state re-entry point 
	; count down pre-exec delay
	movlw	FDR_WAIT		; get delay value
	decfsz	PLUSW2,F		; decrement delay and skip if zero
	return

	; test and branch three XFADE initial conditions
	movlw	FDR_XFADE
	movf	PLUSW2,W		; get XFADE value
	bz	FDR_EXEC_UP_FIRST	; branch if zero to UP fade first time setup
	movlw	FDR_MAX
	movf	PLUSW2,W		; get MAX value
	movwf	fdr_temp_max		; save MAX in working register
	cpfslt	fdr_level	 	; skip if fdr_level < MAX
	bra	FDR_EXEC_XFADE_DOWN_FIRST; XFADE_DOWN also handles the = condition 
;	bra	FDR_EXEC_XFADE_UP_FIRST	; fall through

;---- FDR_EXEC_XFADE UP and DOWN routines -----

FDR_EXEC_XFADE_UP_FIRST	; first time entry point
	; compute XFADE increment = (1/XFADE)*(MAX-LEVEL)
	movlw	FDR_XFADE
	movff	PLUSW2,fdr_temp	; load XFADE step time into fdr_temp
	movff	fdr_temp_max,fdr_temp_hi; load MAX into hi
	movf	fdr_level,W		; load LEVEL into W
	call	FDR_COMPUTE_STEP_UP
;	bra	FDR_EXEC_XFADE_UP_CYCLE ; fall through

FDR_EXEC_XFADE_UP_CYCLE	; cycle re-entry point (NULL)
	; set state
	movlw	FDR_STATE_XFADE_UP
	movwf	INDF2
;	bra	FDR_EXEC_XFADE_UP_STATE	; fall through

FDR_EXEC_XFADE_UP_STATE	; state re-entry point
	; get fresh working values to temp registers
	movlw	FDR_UP_INCR_L
	movff	PLUSW2,fdr_temp_lo
	movlw	FDR_UP_INCR_H
	movff	PLUSW2,fdr_temp_hi
	movlw	FDR_MAX
	movff	PLUSW2,fdr_temp_max

	; add INCR to LEVEL
	movlw	FDR_LEVEL_L		; adjust table pointer to LEVEL_L
	addwf	FSR2L,F
	movf	fdr_temp_lo,W		; 16 bit add with writeback to table
	addwf	POSTDEC2,F
	movf	fdr_temp_hi,W
	addwfc	POSTDEC2,F		; restores pointer to base of table

	; test for the three final conditions
	bc	FDR_EXEC_XFADE_FIN	; test and branch absolute overflow 
	movlw	FDR_LEVEL_H
	movf	PLUSW2,W		; get new LEVEL_H to W
	subwf	fdr_temp_max,W
	bz	FDR_EXEC_XFADE_FIN	; test and branch if equals
	bnc	FDR_EXEC_XFADE_FIN	; test and branch if overflow over MAX
	bra	FDR_EXEC_EXIT		; otherwise normal exit

FDR_EXEC_XFADE_DOWN_FIRST ; first time entry point
	; compute XFADE increment = (1/XFADE)*(LEVEL-MAX)
	movlw	FDR_XFADE
	movff	PLUSW2,fdr_temp	; load XFADE step time into fdr_temp
	movff	fdr_level,fdr_temp_hi	; loaf LEVEL into hi
	movf	fdr_temp_max,W		; load MAX into W
	call	FDR_COMPUTE_STEP_UP
;	bra	FDR_EXEC_XFADE_DOWN_CYCLE ; fall through

FDR_EXEC_XFADE_DOWN_CYCLE  ; cycle re-entry point
	; set state
	movlw	FDR_STATE_XFADE_DOWN
	movwf	INDF2
;	bra	FDR_EXEC_XFADE_DOWN_STATE ; fall through

FDR_EXEC_XFADE_DOWN_STATE  ; re-entry for each state dispatch
	; get fresh working values to temp registers
	movlw	FDR_UP_INCR_L
	movff	PLUSW2,fdr_temp_lo
	movlw	FDR_UP_INCR_H
	movff	PLUSW2,fdr_temp_hi
	movlw	FDR_MAX
	movff	PLUSW2,fdr_temp_max

	; subtract "INCR" from LEVEL
	movlw	FDR_LEVEL_L		; adjust table pointer to LEVEL_L
	addwf	FSR2L,F
	movf	fdr_temp_lo,W		; 16 bit add with writeback to table
	subwf	POSTDEC2,F
	movf	fdr_temp_hi,W
	subwfb	POSTDEC2,F		; restores pointer to base of table

	; test for overflow and final conditions
	bnc	FDR_EXEC_XFADE_FIN	; test and branch absolute underflow
	movlw	FDR_LEVEL_H
	movf	PLUSW2,W		; get new LEVEL_H to W
	subwf	fdr_temp_max,W
	bz	FDR_EXEC_XFADE_FIN	; test and branch if equals
	bc	FDR_EXEC_XFADE_FIN	; test and branch if less than than MAX
	bra	FDR_EXEC_EXIT		; otherwise normal exit

FDR_EXEC_XFADE_FIN  ; shared finalization for XFADE_UP and XFADE_DOWN
		    ; Initializes UP variables, but skips ahead to ON interval

	; set LEVEL_H to MAX
	movff	fdr_temp_max,PREINC2	; set LEVEL_H to MAX
	movf	POSTDEC2,W		; load LEVEL_H in W and reset FSR to base

	; compute UP increment = (1/UP)*(MAX-MIN)
	movlw	FDR_UP
	movff	PLUSW2,fdr_temp	; load UP step time into fdr_temp
	movff	fdr_temp_max,fdr_temp_hi; load MAX into hi
	movlw	FDR_MIN
	movf	PLUSW2,W		; load MIN into W
	call	FDR_COMPUTE_STEP_UP

	; compute DOWN increment = (1/DOWN)*(MAX-MIN)
	movlw	FDR_DOWN
	movff	PLUSW2,fdr_temp	; load UP step time into fdr_temp
	movff	fdr_temp_max,fdr_temp_hi; load MAX into hi
	movlw	FDR_MIN
	movf	PLUSW2,W		; load MIN into W
	call	FDR_COMPUTE_STEP_DOWN

	; got to ON state processing (not UP or DOWN)
	bra	FDR_EXEC_DWELL_FIRST

;---- FDR_EXEC_UP routines -----

FDR_EXEC_UP_FIRST ; first time entry point
	; get and save MAX value from table
	movlw	FDR_MAX
	movf	PLUSW2,W		; get MAX value
	movwf	fdr_temp_max		; save MAX in working register

	; compute UP increment = (1/UP)*(MAX-MIN) and save to table
	movlw	FDR_UP
	movff	PLUSW2,fdr_temp		; load UP step time into fdr_temp
	movff	fdr_temp_max,fdr_temp_hi; load MAX into hi
	movlw	FDR_MIN
	movf	PLUSW2,W		; load MIN into W
	call	FDR_COMPUTE_STEP_UP

	; compute DOWN increment = (1/DOWN)*(MAX-MIN) and save to table
	movlw	FDR_DOWN
	movff	PLUSW2,fdr_temp		; load UP step time into fdr_temp
	movff	fdr_temp_max,fdr_temp_hi; load MAX into hi
	movlw	FDR_MIN
	movf	PLUSW2,W		; load MIN into W
	call	FDR_COMPUTE_STEP_DOWN

;	bra	FDR_EXEC_UP_CYCLE	; fall through

FDR_EXEC_UP_CYCLE ; re-entry point for each new cycle
	; set state
	movlw	FDR_STATE_UP
	movwf	INDF2
;	bra	FDR_EXEC_UP_STATE	; fall through

FDR_EXEC_UP_STATE ; re-entry point for each state dispatch
	; get fresh working values to temp registers
	movlw	FDR_UP_INCR_L
	movff	PLUSW2,fdr_temp_lo
	movlw	FDR_UP_INCR_H
	movff	PLUSW2,fdr_temp_hi
	movlw	FDR_MAX
	movff	PLUSW2,fdr_temp_max

	; add INCR to LEVEL
	movlw	FDR_LEVEL_L		; adjust table pointer to LEVEL_L
	addwf	FSR2L,F
	movf	fdr_temp_lo,W		; 16 bit add with writeback to table
	addwf	POSTDEC2,F
	movf	fdr_temp_hi,W
	addwfc	POSTDEC2,F		; restores pointer to base of table

	; test for overflow and final conditions
	bc	CEU_FIN			; test and branch overflow condition
	movlw	FDR_LEVEL_H
	movf	PLUSW2,W		; get new LEVEL_H to W
	subwf	fdr_temp_max,W
	bz	CEU_FIN			; test and branch equals condition
	bnc	CEU_FIN			; test and branch greater than condition
	bra	FDR_EXEC_EXIT		; exit

CEU_FIN	; set LEVEL_H to MAX
	movff	fdr_temp_max,PREINC2	; set LEVEL_H to MAX
	movf	POSTDEC2,W		; reset FSR to base (load W)
;	bra	FDR_EXEC_ON_CYCLE	; fall through

;---- FDR_EXEC_ON routines -----

FDR_EXEC_DWELL_FIRST	; first time entry point
FDR_EXEC_DWELL_CYCLE	; cycle re-entry point
	; move ON value to counter
	movlw	FDR_DWELL
	movff	PLUSW2,fdr_temp
	movlw	FDR_COUNTER
	movff	fdr_temp,PLUSW2	
	incf	PLUSW2,F		; add 1 to simplify counting

	; set state
	movlw	FDR_STATE_DWELL
	movwf	INDF2
	bra	FDR_EXEC_EXIT		; return thru common exit. 
					; Forces any prior level change to take,
					; and stops the "shit thru a goose" effect

FDR_EXEC_DWELL_STATE	; state re-entry point
	movlw	FDR_COUNTER
	decfsz	PLUSW2,F
	bra	FDR_EXEC_EXIT
;	bra	FDR_EXEC_DOWN_CYCLE	; fall through	

;---- FDR_EXEC_DOWN routines -----

FDR_EXEC_DOWN_FIRST	; first time entry point
	; DOWN_FIRST functions are actually performed during UP_FIRST & XFADE_FIN

FDR_EXEC_DOWN_CYCLE	; cycle re-entry point
	; set state
	movlw	FDR_STATE_DOWN
	movwf	INDF2
;	bra	FDR_EXEC_DOWN_STATE	; fall through

FDR_EXEC_DOWN_STATE	; state re-entry point
	; get fresh working values to temp registers
	movlw	FDR_UP_INCR_L
	movff	PLUSW2,fdr_temp_lo
	movlw	FDR_UP_INCR_H
	movff	PLUSW2,fdr_temp_hi
	movlw	FDR_MIN
	movff	PLUSW2,fdr_temp_min

	; subtract DECR from LEVEL
	movlw	FDR_LEVEL_L		; adjust table pointer to LEVEL_L
	addwf	FSR2L,F
	movf	fdr_temp_lo,W		; 16 bit add with writeback to table
	subwf	POSTDEC2,F
	movf	fdr_temp_hi,W
	subwfb	POSTDEC2,F		; restores pointer to base of table

	; test for overflow and final conditions
	bnc	CED_FIN			; test and branch underflow condition
	movlw	FDR_LEVEL_H
	movff	PLUSW2,fdr_temp_hi	; get new LEVEL_H to temp
	movf	fdr_temp_min,W
	subwf	fdr_temp_hi,W		; subtract min from LEVEL
	bz	CED_FIN			; test and branch equals condition
	bnc	CED_FIN			; test and branch on negative
	bra	FDR_EXEC_EXIT		; exit with FSR pointed to LEVEL

CED_FIN	; set LEVEL_H to MAX
	movff	fdr_temp_min,PREINC2	; set LEVEL_H to MIN
	movf	POSTDEC2,W		; reset FSR to base (load W)
;	bra	FDR_EXEC_OFF_CYCLE	; fall through

;---- FDR_EXEC_OFF routines -----

;FDR_EXEC_OFF_FIRST	; first time entry point
FDR_EXEC_OFF_CYCLE	; cycle re-entry point	
	; move OFF value to counter
	movlw	FDR_OFF
	movff	PLUSW2,fdr_temp
	movlw	FDR_COUNTER
	movff	fdr_temp,PLUSW2	
	incf	PLUSW2,F		; add 1 to simplify counting

	; set state
	movlw	FDR_STATE_OFF
	movwf	INDF2
;	bra	FDR_EXEC_OFF_STATE	; fall through

FDR_EXEC_OFF_STATE	; state re-entry point
	movlw	FDR_COUNTER
	decfsz	PLUSW2,F
	bra	FDR_EXEC_EXIT
;	bra	FDR_EXEC_REPEAT		; fall through	

;---- FDR_EXEC_REPEAT routine -----

FDR_EXEC_REPEAT
	; test for REPEAT=0 --> repeat forever
	movlw	FDR_REPEAT
	movf	PLUSW2,F		; get repeat value (preserve W)
	bz	FDR_EXEC_UP_CYCLE	; always start a new cycle

	; decrement and test
	decfsz	PLUSW2,F
	bra	FDR_EXEC_UP_CYCLE	; decrement once and start again

	; end cycle - fader is DONE
	movlw	FDR_STATE_DONE
	movwf	INDF2
	bra	FDR_EXEC_EXIT

;---- FDR_COMPUTE_STEP_[UP, DOWN] - function to compute a step incr or decr
;
; INPUTS:
;	- W = lower range (MIN)
;	- fdr_temp_hi = upper range (typ MAX) (gets clobbered)
;	- fdr_temp = step time
;
; RETURNS:
;	_UP loads increment / decr into UP_INCR_H/L
;	_DOWN loads increment / decr into DOWN_DECR_H/L

FDR_COMPUTE_STEP_UP
	subwf	fdr_temp_hi,F		; HI-LO (clobbers fdr_temp_hi)
	movf	fdr_temp,W		; STEP
	call	FDR_COMPUTE_RECIPROCAL	; 1/STEP
	mulwf	fdr_temp_hi		; (1/STEP)*(HI-LO)
	movlw	FDR_UP_INCR_H		; load results into UP_INCR
	movff	PRODH,PLUSW2
	movlw	FDR_UP_INCR_L
	movff	PRODL,PLUSW2
	return

FDR_COMPUTE_STEP_DOWN
	subwf	fdr_temp_hi,F		; HI-LO (clobbers HI working reg)
	movf	fdr_temp,W		; STEP
	call	FDR_COMPUTE_RECIPROCAL	; 1/STEP
	mulwf	fdr_temp_hi		; compute (1/STEP)*(HI-LO)
	movlw	FDR_DOWN_DECR_H		; load results into DOWN_DECR
	movff	PRODH,PLUSW2
	movlw	FDR_DOWN_DECR_L
	movff	PRODL,PLUSW2
	return

;---- FDR_EXEC_PATCH routine -----
; Read the STATE and LEVEL_H from the master circuit. Test the level against the 
; current slave level level {fdr_level) and set fdr_level and dirty bit if changed.
; If the master is DONE, then set local state to DONE as well. Exit.
 
FDR_EXEC_PATCH
	movlw	FDR_MASTER_L		; retrieve master pointer
	movff	PLUSW2,FSR1L
	movlw	FDR_MASTER_H
	movff	PLUSW2,FSR1H
	movff	POSTINC1,fdr_temp	; get master STATE to local temp
	movff	INDF1,fdr_temp_hi	; get master LEVEL to local temp

	movlw	FDR_LEVEL_H		; write new level to slave LEVEL
	movff	fdr_temp_hi,PLUSW2
	
	movf	fdr_temp_hi,W
	cpfseq	fdr_level,W		; test master level against slave level
	bsf	app_flags,DIRTY_BIT	; set DIRTY_BIT if not equal
	movwf	fdr_level		; this will return the new level

	movf	fdr_temp		; get the master STATE back
	bnz	CE_SLV1			; relies on STATE_DONE = 0
	clrf	INDF2			; set local state to DONE
CE_SLV1	return


;---- FDR_EXEC_SET_HSB routine -----
; Preconditions are that the loader has loaded LEVEL_H values into an HSB 
; triplet and set the state to FDR_STATE_SET_HSB. This routine will be called
; three times (one for each circuit in the triplet) to return the fdr_level 
; that was set. The DIRTY_BIT is set each time. The caller is then responsible
; for calling the HSB_TO_RGB conversion and the CKT table load routines 
; - as per usual on return from commands.

FDR_EXEC_SET_HSB
	movf	PREINC2,W		; get level (LEVEL_H)
	movwf	fdr_level
	btfss	PREINC2,0		; test the dirty flag...
	return				;...if Nth time through, just return
	clrf	INDF2			; else clear the dirty flag...
	bsf	app_flags,DIRTY_BIT	;...set DIRTY_BIT...
	return				;...and return

;---- FDR_EXEC_SET_RGB routines -----

FDR_EXEC_SET_RGB
	bra	FDR_EXEC_EXIT		; exit with FSR pointed to LEVEL


;---- FDR_TEST_FDR_DONE -----
; Return Z=1 if fader circuit in W is DONE.
;
; INPUTS: W	circuit number: according to the following encoding:
;		<b7-b2> channel 0 - channel N
;		<b1-b0> 00 = HUE
;			01 = SAT
;			01 = BRT
;			11 = EXTRA - extra command channels: 0-15 are valid
;
; RETURN: 	Z=1 if DONE or DISABLED
;		Z=0 if fader is active
;
; USES:	  TBLPTR - but preserves it

FDR_TEST_FDR_DONE
	call	FDR_SET_FDR_TABLE_PTR
	btfss	STATUS,Z
	return				; return with Z=0 & error code from FDR_SET... 

	movf	INDF2,W			; get the fader channel status byte
	xorlw	FDR_STATE_DONE
	bz	FTD_DONE

FTD_NOT_DONE
	bcf	STATUS,Z
	retlw	ERR_NO_ERROR

FTD_DONE
	bsf	STATUS,Z
	retlw	ERR_NO_ERROR


;---- FDR_SET_FDR_TABLE_PTR -----
; Sets FSR2 to base of fader channel in fader table.
; TABLES ARE SETUP FOR MONOCHROME VERSION (code is the same ragardless)
;
; INPUTS: W	fader channel number 
;		- if monochrome it's just the channel # - 0 through N
; 		- if color uses the following encoding:
;		  <b7-b2> channel 0 - channel N
;		  <b1-b0> 00 = HUE
;			  01 = SAT
;			  01 = BRT
;			  11 = EXTRA - extra command channels: 0-15 are valid
;
; RETURN: FSR2 	set to correct table base
;	  Z=1 if OK, Z=0 if a pointer error occurred, W = ERR_BAD_CHANNEL
;
; NOTE: fader tables cannot be located in RAM bank 0 or error trapping will
; fail (you wouldn't want the fader tables in bank 0 anyway).
;
; USES:	  TBLPTR - but preserves it
; Profile: 32 instruction cycles

PTR_ERR	equ	0x0000

FDR_SET_FDR_TABLE_PTR
	; save table pointer
	movff	TBLPTRH,temp_tblptrh
	movff	TBLPTRL,temp_tblptrl

	; compute lookup table offset from W (circuit number)
	; = table base + (circuit number *2)

	movwf	fdr_temp		; save channel number
	sublw	FDR_POINTER_MAX
	bnc	FSF_err

	movlw	LOW FDR_POINTERS	
	movwf	TBLPTRL
	bcf	STATUS,C		; clear carry
	rlcf	fdr_temp,W		; multiply channel number by 2, into C
	addwf	TBLPTRL,F		; add to table pointer base

	movlw	HIGH FDR_POINTERS
	movwf	TBLPTRH
	btfsc	STATUS,C		; C is preserved from addwf instruction
	incf	TBLPTRH,F

	; read RAM address from table
	tblrd*+				; read the low byte
	movff	TABLAT,FSR2L
	tblrd*				; read the high byte
	movf	TABLAT,W
	bz	FSF_err			; need to break this out to detect err
	movwf	FSR2H

	; restore table pointer and exit
	movff	temp_tblptrh,TBLPTRH
	movff	temp_tblptrl,TBLPTRL
	bsf	STATUS,Z		; return OK
	return

FSF_err	movlw	ERR_BAD_CHANNEL		; return a reason code
	bcf	STATUS,Z		; signal error
	return

; code_pack section requires a label for some reason. here goes:
DATA_FADER_POINTER_TABLE   code_pack

FDR_POINTERS ; table of fader table pointers
	data	fdr_00, fdr_01, fdr_02, fdr_03
	data	fdr_04, fdr_05, fdr_06, fdr_07
	data	fdr_08, fdr_09, fdr_10, fdr_11
	data	fdr_12, fdr_13, fdr_14, fdr_15
	data	fdr_16, fdr_17, fdr_18, fdr_19
	data	fdr_20, fdr_21, fdr_22, fdr_23
	data	fdr_24, fdr_25, PTR_ERR, PTR_ERR
FDR_POINTER_MAX	equ	.25

DATA_FADER_POINTER_TABLE_END	code 	; also requries a label (go figure)


;---- FDR_COMPUTE_RECIPROCAL -----
; Returns the reciprocal of the number in W
;
; INPUTS: W	number
; RETURN: W	reciprocal
;
; USES:	  TBLPTR - destroys it

FDR_COMPUTE_RECIPROCAL
	addlw	LOW RECIPROCAL_TABLE
	movwf	TBLPTRL
	movlw	HIGH RECIPROCAL_TABLE
	movwf	TBLPTRH
	btfsc	STATUS,C		; account for the carry bit from low add
	incf	TBLPTRH,F
	tblrd	*
	movf	TABLAT,W
	return

DATA_RECIPROCAL_TABLE	code_pack	; code_pack section requires a label for some reason

RECIPROCAL_TABLE 	; table of 8 bit reciprocals
	db	0xFF, 0x80, 0x55, 0x40, 0x33, 0x2A, 0x24, 0x20, 0x1C, 0x19, 0x17, 0x15, 0x13, 0x12, 0x11, 0x10
	db	0x0F, 0x0E, 0x0D, 0x0C, 0x0C, 0x0B, 0x0B, 0x0A, 0x0A, 0x09, 0x09, 0x09, 0x08, 0x08, 0x08, 0x08
	db	0x07, 0x07, 0x07, 0x07, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05
	db	0x05, 0x05, 0x05, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04
	db	0x04, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03
	db	0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02
	db	0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02
	db	0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02
	db	0x02, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01
	db	0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01
	db	0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01
	db	0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01
	db	0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01
	db	0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01
	db	0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01
	db	0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01

DATA_RECIPROCAL_TABLE_END  code		; code section requires a label for some reason


;*****************************************************************************
;***** UNIT TESTS ************************************************************
;*****************************************************************************

UT_CMD
    if UNITS_ENABLED
;	call	UT_CMD_LOADER		; load one channel with pulse
;	call	UT_CMD_LOADER_ALL	; load all channels
;	call	UT_CMD_LOADER_HSB	; test HSB loader

	call	UT_FDR_SET_FDR_TABLE_PTR ; test the pointer lookup
;	call	UT_FDR_COMPUTE_RECIPROCAL ; test reciprocal function
;	call	UT_FDR_DISPATCH		; call the dispatcher - infinite loop
    endif
	return


    if UNITS_ENABLED

TEST_CHANNEL	equ	.5
TEST_CIRCUIT	equ	(TEST_CHANNEL << 2) | SAT_OFFSET

UT_FDR_COMPUTE_RECIPROCAL
	movlw	0x00
	call	FDR_COMPUTE_RECIPROCAL
	movlw	0x01
	call	FDR_COMPUTE_RECIPROCAL
	movlw	0x02
	call	FDR_COMPUTE_RECIPROCAL
	movlw	0x03
	call	FDR_COMPUTE_RECIPROCAL
	movlw	0x40
	call	FDR_COMPUTE_RECIPROCAL
	movlw	0x80
	call	FDR_COMPUTE_RECIPROCAL
	movlw	0xE0
	call	FDR_COMPUTE_RECIPROCAL
	movlw	0xFE
	call	FDR_COMPUTE_RECIPROCAL
	movlw	0xFF
	call	FDR_COMPUTE_RECIPROCAL

UT_FDR_SET_FDR_TABLE_PTR		; test for set table pointer

; setup to test 8 channels. Modify for 64 or some other number

	movlw	(.0<<2)			
	call	FDR_SET_FDR_TABLE_PTR	; should set 0x400
	movlw	(.0<<2)+1			
	call	FDR_SET_FDR_TABLE_PTR	; 0x40D
	movlw	(.0<<2)+2			
	call	FDR_SET_FDR_TABLE_PTR	; 0x41A

	movlw	(.1<<2)
	call	FDR_SET_FDR_TABLE_PTR	; 0x427
	movlw	(.2<<2)
	call	FDR_SET_FDR_TABLE_PTR	; 0x44E
	movlw	(.3<<2)
	call	FDR_SET_FDR_TABLE_PTR	; 0x475
	movlw	(.4<<2)
	call	FDR_SET_FDR_TABLE_PTR	; 0x49C
	movlw	(.5<<2)
	call	FDR_SET_FDR_TABLE_PTR	; 0x4C3
	movlw	(.6<<2)
	call	FDR_SET_FDR_TABLE_PTR	; 0x4EA
	movlw	(.7<<2)
	call	FDR_SET_FDR_TABLE_PTR	; 0x51A

	; fail cases
	movlw	(.0<<2)+3		; error in HSB offset			
	call	FDR_SET_FDR_TABLE_PTR
	movlw	(.8<<2)			; one over max
	call	FDR_SET_FDR_TABLE_PTR
	movlw	(.63<<2)		; maximum legal (but invalid) value	
	call	FDR_SET_FDR_TABLE_PTR
	return


UT_CMD_LOADER_HSB
	movlw	HIGH cmd_buffer
	movwf	BSR			; work directly with page 3
	movlw	0x13			; command 0x43
	movwf	cmd_buffer,B
	movlw	TEST_CHANNEL		; channel
	movwf	cmd_buffer+.1,B
	movlw	0x80			; HUE
	movwf	cmd_buffer+.2,B
	movlw	0xF0			; SAT
	movwf	cmd_buffer+.3,B
	movlw	0xDE			; BRT
	movwf	cmd_buffer+.4,B
	clrf	BSR			; set to BANK 0
	lfsr	1,cmd_buffer		; set FSR1 to base of cmd input buffer
	call	CMD_LOADER
	return



UT_CMD_LOADER_ALL
	movlw	0xFF
	movwf	cmd_ut_temp		; brt

UT_CLA1	decf	cmd_ut_temp,F
	call	UT_CMD_LOADER
	decf	cmd_ut_temp,F		; sat
	call	UT_CMD_LOADER
	decf	cmd_ut_temp,F		; hue
	bz	UT_CLA2
	call	UT_CMD_LOADER
	decf	cmd_ut_temp,F		; extra, or underflow
	bra	UT_CLA1
UT_CLA2	call	UT_CMD_LOADER
	return

UT_CMD_LOADER	; load some arbitrary garbage into the command buffer
	movlw	HIGH cmd_buffer
	movwf	BSR			; work directly with page 3

	movlw	0x46			; command 0x46 - thru DOWN
	movlw	0x47			; command 0x47 - include REPEAT
	movlw	0x48			; command 0x48 - include MIN
	movlw	0x49			; command 0x49 - include MAX
	movlw	0x4A			; command 0x4A - include XFADE
	movwf	cmd_buffer,B

;	movlw	TEST_CIRCUIT		; circuit
	movf	cmd_ut_temp,W		; circuit
	movwf	cmd_buffer+.1,B

	movlw	0x01			; prescale
	movwf	cmd_buffer+.2,B

	movlw	0x02			; delay
	movwf	cmd_buffer+.3,B

	movlw	0x03			; up
	movwf	cmd_buffer+.4,B

	movlw	0x04			; on
	movwf	cmd_buffer+.5,B

	movlw	0x02			; down
	movwf	cmd_buffer+.6,B

	movlw	0x06			; off
	movwf	cmd_buffer+.7,B

	movlw	0x00			; repeat
	movwf	cmd_buffer+.8,B

	movlw	0x02			; min
	movwf	cmd_buffer+.9,B

	movlw	0xF0			; max
	movwf	cmd_buffer+.10,B

	movlw	0x07			; xfade
	movwf	cmd_buffer+.11,B

	clrf	BSR			; set to BANK 0

	lfsr	1,cmd_buffer		; set FSR1 to base of cmd input buffer
	call	CMD_LOADER
	return

UT_FDR_DISPATCH

    if FALSE
	; pseudo-loader
	movlw	HIGH TEST_CIRCUIT
	movwf	BSR			; work directly with page 4

;	movlw	FDR_STATE_DISABLED
	movlw	FDR_STATE_DELAY		; set initial state to DELAY
	movwf	FDR_STATE,B

;	movlw	0x00			; initial level
	movlw	0x80			; initial level
;	movlw	0xFF			; initial level
	movwf	FDR_LEVEL_H,B

	movlw	0x01			; fire on every cycle
	movwf	FDR_PRESCALE,B

	movlw	0x02			; DELAY value (pre-incremented)
	movwf	FDR_WAIT,B

	movlw	0x05			; XFADE value
	movwf	FDR_XFADE,B

	movlw	0x04			; UP value
	movwf	FDR_UP,B
	
	movlw	0x03			; DOWN value
	movwf	FDR_DOWN,B

	movlw	0x02			; ON value
	movwf	FDR_DWELL,B

	movlw	0x06			; OFF value
	movwf	FDR_OFF,B

	movlw	0x02			; MIN value
	movwf	FDR_MIN,B

	movlw	0xF0			; MAX value
	movwf	FDR_MAX,B

	movlw	0x02			; REPEAT value
	movwf	FDR_REPEAT,B

	clrf	BSR			; set to BANK 0
    endif

	; set prescale to simulate every cycle
	movlw	0x01
	movwf	cycle_prescale	

	; setup and run triplet
	clrf	app_flags		; clear all app flags
	movlw	TEST_CHANNEL		; set channel number
	movwf	chn_num
	movlw	TEST_CIRCUIT
	call	FDR_SET_FDR_TABLE_PTR	; set FSR2 to cmd table base
UT_C1	call	FDR_DISPATCH		; dispatch for HUE
;	goto	UT_C1			; keep repeating

	return
    endif

	END                       	; directive 'end of program'

