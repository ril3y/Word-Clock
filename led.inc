;*****************************************************************************
; PIC18F family - LED subsystem include file
;*****************************************************************************
;*****************************************************************************
;
;    Filename:	    	led.inc
;    Author, Company:	Alden Hart, Luke's Lights
;    Chip Support:	Supports PIC18F family
;    Revision:		091015
;
;    This file basically serves as documentation for creating cues and playback
;
;*****************************************************************************
; CUES AND PLAYBACK
; 
; PLAY_INIT		  Init playlist/cue module and load first playlist/cue
; PLAY_GET_NEXT_PLAYLIST  Return ptr to next playlist in playlist master table
; PLAY_GET_PREV_PLAYLIST  Return ptr to previous playlist in playlist master table
; PLAY_START_PLAYIST	  Start a playlist from playlist ptr (becomes active playlist)
; PLAY_RUN_NEXT_CUE	  Run next cue in active playlist
;	  
; CUE_LOAD_CUE		  Load an entire cue
; CUE_GET_NEXT_COMMAND	  Iterator used for for loading an entire cue
; CUE_GET_COMMAND	  Load a single command from cue (into FDR_LOADER buffer)
; CUE_SET_ARGUMENT	  Load an argument into arg table
; CUE_GET_ARGUMENT	  Get an argument from arg table
;
; CUES
;
; A CUE is a set of COMMANDS that run as a unit to load the state of the 
; lighting system. A cue takes data from program memory and loads the commands
; in to the FADER tables (there are some exceptions).
;
; For example, if you wanted to load 8 different hue waveforms, set 
; saturations to 8 different static levels, and PATCH all brightnesses to a 
; master channel, this could be done using a cue. 
;
; The challenge is to define (and encode) complex cues in a way that's both 
; simple to understand and program and is also relatively memory efficicient. 
; The above example would take about ~200 bytes if performed as a simple set of 
; commands. Using the cue tools for definition and encoding this same 
; operation could be encoded in as little as ~20 bytes.
;
; To do this, a series of other operations is supported for cues:
; 
;	- CUE_CMD		load a regular command from pgm memory to RAM
;	- CUE_ARG		load an argument structure into an arg cell
;	- CUE_LOOP		load the next command N times		
;	- CUE_LOOP_BLOCK	loop until END_ADDR, N times, starting at START_ADDR
;	- CUE_JUMP		jump to JUMP_ADDR
;	- CUE_DONE		end of cue or playback
;	- CUE_CODA		start queue over
;
; Details of the above operations are littered throughout the headers in this
; file. Summaries of the cue operations are provided below;
;
; CUE_CMD:	CUE_CMD, cmd, argmask, arg0....argN
;
; Action is to load the command into RAM - similarly to if the command was 
; received in a serial RX buffer. Contains a command code followed by a 
; bitmask specifying which args in the command are to be read lterally from 
; the command line and which args are to be loaded from the argument cells. 
; The argmask is one byte long except in the case of the FADE command where 
; it is 2 bytes. See CUE_LOAD_COMMAND for details.
; 
; CUE_ARG:	CUE_ARG, argnum, opcode, var1, [var2], [var3]
;
; Action is to initialize one of the argument cells with an opcode and one or
; more starting values (vars). Consists of a CUE_ARG byte and 3 - 5 data
; bytes. Arguments can increment, decrement, add, and do other things between
; command calls that allow common commands to be set up generically.
; See CUE_LOAD_ARGUMENT for details.
;
; CUE_LOOP:		CUE_LOOP, repeat_count
;
; Action is to run the next command N times. The next table entry must be a 
; command.
;
; CUE_LOOP_BLOCK:	CUE_LOOP_BLOCK, repeat_count, start_address
;
; Action is to loop N times between the start address and CUE_DONE (the 
; "looping block"). CUE execution continues on the next line after the 
; CUE_LOOP_BLOCK command once the loop is complete.
;
; This command is useful to iterate through a series of channels with 
; parameters that vary based on the number of times an arg is used. Typically 
; a set of CUE_ARGS is setup before calling the block. This is useful to 
; create "subroutines" of commonly used preset operations. This command 
; DOES NOT nest and cannot be called recursively (sorry!).
;
; CUE_JUMP:		CUE_JUMP, jump_address
;
; Action is to transfer cue exeution to a new address, from which execution
; will not return. Any number of jumps may be chained. Useful for "finishing up"
; with common code.
;
; CUE_DONE:		CUE_DONE <no parameters>
;
; Signals the end of a cue block (see above descriptions). If found in 
; the main body of the called cue, it terminates the interpretation of the 
; cue and returns control to the caller. If found in a LOOP is terminates
; that iteration of the loop and returns control to the cue line that 
; called the loop.
; 
; 
; RESOURCE USAGE:
; - The PLAYBACK sub-system uses FSR1 as its primary pointer, FSR2 as secondary. 
; - Does not use FSR0 as this is reserved for interrupts.
; - The ARG table takes 128 bytes of RAM to store 32 arguments.
; - Routines follow the convnetion of returning Z bit set for OK, or to indicate
;   the further processing is required.

;----- Circuit and Command Processing Definitions ----
; See Ckt Mapping tab of spreadsheet for further documentation

FDR_TABLE_LEN		equ	.13	; bytes allocated per fader table
CHN_NUM_MAX		equ	.21	; number of color or mono channels (zero based)
CKT_NUM_MAX		equ	.29	; maximum encoded circuit number (zero based)
CKT_TABLE_INCREMENT	equ	.5	; number of ports being serviced
CKT_TABLE_LEN		equ	.39	; circuit table is 5 ports * 8 bits (zero based)

switch01p		equ	PORTA
switch01b		equ	.0

MONOCHROME_MODE		equ	TRUE	; set TRUE if running monochrome, FALSE for color

; not used in monochrome mode apps
RED_OFFSET		equ	0	; table offsets
GRN_OFFSET		equ	1
BLU_OFFSET		equ	2
EXT_OFFSET		equ	3	; offset for extra channel
HUE_OFFSET		equ	0
SAT_OFFSET		equ	1
BRT_OFFSET		equ	2

;---- COMMAND SET ----
; Command set - MSbyte is command code, LSbyte is argument counter
; Adding a command involves:
;  - adding it to this list and adjusting any values
;  - adding it to CMD_LOADER dispatch table (led_fader.asm)
;  - adding it to CMD_VALIDATE_CMDCODE (led_fader.asm)
;  - adding it to CUE_GET_COMMAND (led_cue.asm)

SET_BRT			equ	0x11	; set BRT for color or monochrome
SET_HSB			equ	0x23	; set HSB values (color only)
SET_RGB			equ	0x33	; set RGB values (color only)
PATCH			equ	0x41	; PATCH command
FADE			equ	0x56	; FADE command args up through OFF
FADE_REPEAT		equ	0x57	; FADE command args up through REPEAT 
FADE_MIN		equ	0x58	; FADE command args up through MIN
FADE_MAX		equ	0x59	; FADE command args up through MAX
FADE_X			equ	0x5A	; FADE command args up through XFADE
WATCH			equ	0x60	; WATCH command - takes one arg (0)

NOW			equ	0xFF	; WATCH command value - load now
NEVER			equ	0xFE	; WATCH command value - never load

;---- Cue command line templates (very useful) ----
; SET_HSB 	CUE_CMD  CMD_SET_HSB  mask  chn  hue   sat   brt 	
; PATCH 	CUE_CMD  CMD_PATCH  mask   slave_ckt     master_ckt
; FADE_46	CUE_CMD CMD_FADE  mask  ckt_num     presc  dly   up   on  down off 	

;---- CUE AND PLAYBACK EQUATES ----

ARG_NUM_MAX		equ	.0	; maximum argument number (zero is a valid #)
					; each arg takes 4 bytes of RAM
ARG_HI_FLAG		equ	.0	; bit to set and test for hi args (>7)

CUE_DONE		equ	.00	; should be zero
CUE_CMD			equ	.01	; prefix for a command
CUE_ARG			equ	.02	; prefix for an argument
CUE_LOOP		equ	.03
CUE_LOOP_BLOCK		equ	.04
CUE_JUMP		equ	.05
CUE_MAX			equ	.05	; maximum allowable cmd instruction value

; MSbyte of these PLAYLIST_xxxx values must be zero:
PLAYLIST_DONE		equ	0x0000	; requries a 16 bit value
PLAYLIST_CODA		equ	0x0001

;---- Argument OPCODE definitions ----
;
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
; op2(op1) means use the value of op1 found at the argnum provided in op2
;   an arg error returns the value of zero.
;
; opcode	    op1    op2	  op3	usage
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

; actual definitions used by the code:

OP_LIT			equ	.00	; use op1 as literal value
OP_INC			equ	.01	; use op1, post increment & store in op1
OP_INC_RANGE		equ	.02	; inc by 1 [op2=max, op3=min], store in op1
OP_INCX2_RANGE		equ	.03	; inc by 2 [op2=max, op3=min], store in op1
OP_INCX3_RANGE		equ	.04	; inc by 3 [op2=max, op3=min], store in op1
OP_INCX4_RANGE		equ	.05	; inc by 4 [op2=max, op3=min], store in op1
OP_DEC			equ	.06	; use op1, post decrement & store in op1
OP_DEC_RANGE		equ	.07	; dec by 1 [op2=max, op3=min], store in op1
OP_DECX2_RANGE		equ	.08	; dec by 2 [op2=max, op3=min], store in op1
OP_DECX3_RANGE		equ	.09	; dec by 3 [op2=max, op3=min], store in op1
OP_DECX4_RANGE		equ	.10	; dec by 4 [op2=max, op3=min], store in op1
OP_ADD			equ	.11	; (op1+op2), save result in op1
OP_ADD_AND		equ	.12	; (op1+op2), AND with op3, do not save result
OP_ADD_AND_SAVE		equ	.13	; (op1+op2), AND with op3l, save result in op1
OP_ADD_IND		equ	.14	; (op1+op2(op1)), do not save result
OP_ADD_IND_SAVE		equ	.15	; (op1+op2(op1)), save result in op1
OP_ADD_IND_AND		equ	.16	; (op1+op2(op1)), AND with op3, do not save
OP_ADD_IND_AND_SAVE	equ	.17	; (op1+op2(op1)), AND with op3, save in op1
OP_SUB			equ	.18	; (op1-op2), save result in op1
OP_SUB_AND		equ	.19	; (op1-op2), AND with op3, do not save result
OP_SUB_AND_SAVE		equ	.20	; (op1-op2), AND with op3, save in op1
OP_SUB_IND		equ	.21	; (op1-op2(op1)), do not save result
OP_SUB_IND_SAVE		equ	.22	; (op1-op2(op1)), save result in op1
OP_SUB_IND_AND		equ	.23	; (op1-op2(op1)), AND with op3, do not save
OP_SUB_IND_AND_SAVE	equ	.24	; (op1-op2(op1)), AND with op3, save in op1
OP_RAND			equ	.25	; pseudo-random#, op1=seed, update seed
OP_RAND_RANGE		equ	.26	; pseudo-random# [op2=max, op3=min], op1=seed
OP_OPCODE_MAX		equ	.26	; MAXIMUM LEGAL OPCODE VALUE


;--- SOME USEFUL SHORTHAND ----

HUE	equ	HUE_OFFSET
SAT	equ	SAT_OFFSET
BRT	equ	BRT_OFFSET

; Colors (applies to HUE)

RED	equ	0x00			; red
ORN	equ	0x15			; orange
YEL	equ	0x2A			; yellow
GRN	equ	0x55			; green
CYN	equ	0x7F			; cyan
BLU	equ	0xAB			; blue
MAG	equ	0xD5			; magenta
VIO	equ	MAG			; violet = magenta

; Channel specifiers with the 2 left shifts:
c00	equ	.00 <<2
c01	equ	.01 <<2
c02	equ	.02 <<2
c03	equ	.03 <<2
c04	equ	.04 <<2
c05	equ	.05 <<2
c06	equ	.06 <<2
c07	equ	.07 <<2
c08	equ	.08 <<2
c09	equ	.09 <<2
c10	equ	.10 <<2
c11	equ	.11 <<2
c12	equ	.12 <<2
c13	equ	.13 <<2
c14	equ	.14 <<2
c15	equ	.15 <<2
c16	equ	.16 <<2
c17	equ	.17 <<2
c18	equ	.18 <<2
c19	equ	.19 <<2
c20	equ	.20 <<2
c21	equ	.21 <<2
c22	equ	.22 <<2
c23	equ	.23 <<2
c24	equ	.24 <<2
c25	equ	.25 <<2
c26	equ	.26 <<2
c27	equ	.27 <<2
c28	equ	.28 <<2
c29	equ	.29 <<2
c30	equ	.30 <<2
c31	equ	.31 <<2
c32	equ	.32 <<2
c33	equ	.33 <<2
c34	equ	.34 <<2
c35	equ	.35 <<2
c36	equ	.36 <<2
c37	equ	.37 <<2
c38	equ	.38 <<2
c39	equ	.39 <<2
c40	equ	.40 <<2
c41	equ	.41 <<2
c42	equ	.42 <<2
c43	equ	.43 <<2
c44	equ	.44 <<2
c45	equ	.45 <<2
c46	equ	.46 <<2
c47	equ	.47 <<2
c48	equ	.48 <<2
c49	equ	.49 <<2
c50	equ	.50 <<2
c51	equ	.51 <<2
c52	equ	.52 <<2
c53	equ	.53 <<2
c54	equ	.54 <<2
c55	equ	.55 <<2
c56	equ	.56 <<2
c57	equ	.57 <<2
c58	equ	.58 <<2
c59	equ	.59 <<2
c60	equ	.60 <<2
c61	equ	.61 <<2
c62	equ	.62 <<2
c63	equ	.63 <<2

	