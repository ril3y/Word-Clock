;*****************************************************************************
; PIC18F2420/2520/4420/4520 - device configuration and initialization
;*****************************************************************************
;
;    Filename:	    	d18f4520.asm
;    Function:		Device config / init / start / stop routines
;    Author, Company:	Alden Hart, Luke's Lights
;    Chip Support:	Supports PIC18F2420 / 2520 / 4420 / 4520
;    Revision:		091013
;
; This file provides initialization for the modules in the supported devices (above)
; Most modules are disabled during reset, except AD, and ports are all input.
;
; Since it may be more conveneient to init ports and timers in their home routines
; switches are provided to disable these init calls.

;----- Include files and other setup------

#include <global.inc>			; 1: global defines - must be first
#include <DEV_INCLUDE_FILE>		; 2: Our device include file
#include <LED_INCLUDE_FILE>		; 3: LED subsystem include file
#include <APP_INCLUDE_FILE>		; 4: Application include file

;------ Exported functions and variables -----

	global	MASTER_INIT
	global	WDT_START		; export watchdog timer startup

;------ Imported functions and variables -----

    if INIT_PORTS_EXTERNAL
	extern	PORT_INIT		; somebody must export PORT_INIT
    endif
    if INIT_T0_EXTERNAL
	extern	T0_INIT			; somebody must export these T0's
	extern	T0_STOP
	extern	T0_START
    endif
    if INIT_T1_EXTERNAL
	extern	T1_INIT			; somebody must export these T1's
	extern	T1_STOP
	extern	T1_START
    endif

;----- Configuration bits -----		; See p18f2520.inc for definitions

;	CONFIG	OSC = INTIO67		; Internal osc w/port function RA6, RA7
	CONFIG	OSC = HSPLL		; IExternal osc w/PLL
	CONFIG	FCMEN = OFF		; Fail-Safe Clock Monitor
	CONFIG	IESO = OFF		; Internal/External Oscillator Switchover
	CONFIG	PWRT = OFF		; Power-up Timer
	CONFIG	BOREN = OFF		; Brown-out Reset Enable
	CONFIG	BORV = 0		; Brown-out Reset Voltage

;	CONFIG	WDT = ON		; Watchdog Timer Enable (OFF/ON)
	CONFIG	WDT = OFF		; Watchdog Timer Enable (OFF/ON)
	CONFIG	WDTPS = 8		; Watchdog Timer Postscale Select Bits
					; legal values are binary strings, e.g.
					; 1, 2, 4, 8, 16...

;	CONFIG	MCLRE = ON		; MCLR Pin Enable - should be ON
	CONFIG	MCLRE = OFF		; MCLR Pin Enable - should be ON

	CONFIG	LPT1OSC = OFF		; Low-Power Timer1 Oscillator Enable 
	CONFIG	PBADEN = OFF		; PORTB A/D Enable
	CONFIG	CCP2MX = PORTC		; ECCP/P2A multiplexed with RC1
	CONFIG	STVREN = ON		; Stack Full/Underflow Reset Enable

	CONFIG	LVP = OFF		; Single-Supply ICSP Enable
;	CONFIG	LVP = ON		; Single-Supply ICSP Enable

	CONFIG	XINST = OFF		; Extended Instruction Set Enable 
	CONFIG	DEBUG = OFF		; Background Debugger Enable

	CONFIG	CP0 = OFF		; Code Protection bit Block 0
	CONFIG	CP1 = OFF		; Code Protection bit Block 1
    if DEVTYPE == 4520
	CONFIG	CP2 = OFF		; Code Protection bit Block 2
	CONFIG	CP3 = OFF		; Code Protection bit Block 3
    endif
	CONFIG	CPB = OFF		; Boot Block Code Protection
	CONFIG	CPD = OFF		; Data EEROM Code Protection Bit
	CONFIG	WRT0 = OFF		; Write Protection bit Block 0
	CONFIG	WRT1 = OFF		; Write Protection bit Block 1
    if DEVTYPE == 4520
	CONFIG	WRT2 = OFF		; Write Protection bit Block 2
	CONFIG	WRT3 = OFF		; Write Protection bit Block 3
    endif
	CONFIG	WRTB = OFF		; Boot Block Write Protection
	CONFIG	WRTC = OFF		; Configuration Register Write Protection
	CONFIG	WRTD = OFF		; Data EEROM Write Protection Bit
	CONFIG	EBTR0 = OFF		; Table Read Protection bit Block 0
	CONFIG	EBTR1 = OFF		; Table Read Protection bit Block 1
    if DEVTYPE == 4520
	CONFIG	EBTR2 = OFF		; Table Read Protection bit Block 2
	CONFIG	EBTR3 = OFF		; Table Read Protection bit Block 3
    endif



CODE_DEVICE_INITS	code

;******************************************************************************
; MASTER_INIT
; Init subroutines handle all initialization for their respective sub-system, 
; including interrupts, which are enabled en-masse at the end via GIE enables.

MASTER_INIT
	clrf	BSR			; set to bank 0

	; call initialization routines for peripherals and ports
	; NOTE: Required routine sequence is noted. Change with caution.

	call	RESET_INIT	; #0 	; resets and interrupts
	call	OSC_INIT	; #1	; oscillator module
	call	WDT_INIT	; #2	; init and stop WDT. start from main loop
	call	RAM_INIT	; #3	; clear all user ram ( set to all 0's )
	call	AD_INIT		; #4	; AD init should precede port inits
	call	PORT_INIT	; #5	; setup ports before other inits

	call	CCP_INIT		; all capture / compare / PWM modules
	call	CMP_INIT		; comparator module

	call	T0_INIT			; timers - start timers from main loop
	call	T1_INIT
	call	T2_INIT
	call	T3_INIT

	call	MSSP_INIT		; MSSP - takes some IO ports
	call	USART_INIT		; EUSART - takes some IO ports

; do this at the end of the START code so other application inits can run first 
;	bsf	INTCON,GIEH		; enable hi priority interrupts
;	bsf	INTCON,GIEL		; enable lo priority interrupts

	return

;******************************************************************************
; RESET_INIT  - Init resets and interrupts

RCON_INIT	equ	b'10000000'	; IPEN = 1 (enable priority interrupts)
					; SBOREN = 0 (SW brown out reset disabled)
RESET_INIT
	movlw	RCON_INIT		; enable priority interrupt scheme
	movwf	RCON
	; disable and clear all interrupts
	; enabled by individual device inits and starts
	clrf	INTCON			; clear interrupt register (& GIEs)
	clrf	INTCON2
	clrf	INTCON3
	clrf	PIR1			; clear all interrput request bits
	clrf	PIR2
	clrf	PIE1			; clear all interrput enable bits
	clrf	PIE2
	clrf	IPR1			; set all interrupts to low priority
	clrf	IPR2
	return


;******************************************************************************
; OSC_INIT  - Init internal oscillators 

OSCCON_INIT	equ	b'01110000'	; IDLEN = 0
					; IRCF = 111 (8 Mhz)
					; SCS = 00 (default primary oscillator)
OSCTUNE_INIT	equ	b'01011111'	; INTSRC = 0 (internal src of 31.25 Khz)
					; PLLEN = 1 (PLL enabled)
					; TUN = Maximum frequency
OSC_INIT
	movlw	OSCCON_INIT		; initialize oscillator setting
	movwf	OSCCON
	movlw	OSCTUNE_INIT		; tune FOSC up or down
	movwf	OSCTUNE
	return


;******************************************************************************
; WDT_INIT  - Init watchdog timer
; WDT_START - Start watchdog timer
; WDT_STOP  - Stop watchdog timer
;
; WDT_INIT does not start the WDT, this should be done from the main loop

WDTCON_INIT	equ	b'00000000'	; WDT off
WDTCON_START	equ	b'00000001'	; WDT on
; NOTE: Postscaler value must be set in configuration registers

WDT_INIT
WDT_STOP
	movlw	WDTCON_INIT
	movwf	WDTCON
	return

WDT_START
	movlw	WDTCON_START
	movwf	WDTCON
	return

;******************************************************************************
; RAM_INIT - set data RAM to all 0x00's

RAM_INIT
	lfsr	FSR0,MAXRAM		; clear down from top GPR address
RT_0	clrf	POSTDEC0
	movf	FSR0H,W			; load W to test for bank zero
	btfss	STATUS,Z
	bra	RT_0
	movf	FSR0L,W			; load W to test for location zero
	btfss	STATUS,Z
	bra	RT_0
	clrf	INDF0
	return

;******************************************************************************
; AD_INIT  - Initialize AD module
; AD_STOP  - Stop AD module
; AD_START - Start AD module
;
; INIT must always be called - so ports are properly disabled

ADCON0_INIT	equ	b'00000000'	; ADON = 0 (disabled)
ADCON1_INIT	equ	b'00001111'	; PCFG = 1111 (set as digital ports)
ADCON2_INIT	equ	b'00000000'	; off

ADCON0_START	equ	b'00000000'	; ADON = 0 (disabled)
ADCON1_START	equ	b'00001111'	; PCFG = 1111 (set as digital ports)
ADCON2_START	equ	b'00000000'	; off

AD_INIT
AD_STOP
	movlw	ADCON0_INIT
	movwf	ADCON0
	movlw	ADCON1_INIT
	movwf	ADCON1
	movlw	ADCON2_INIT
	movwf	ADCON2
	return

AD_START
	movlw	ADCON0_START
	movwf	ADCON0
	movlw	ADCON1_START
	movwf	ADCON1
	movlw	ADCON2_START
	movwf	ADCON2
;	bsf	PIE1,ADIE 		; enable AD irq (do PEIE & GIE later)
;	bcf	PIR1,ADIF 		; clear AD interrupt flag
;	bsf	IPR1,ADIP		; 1 = high-priority
	return


;******************************************************************************
; PORT_INIT - Initialize all ports - sets pins as in/out/analog/etc.
;
; Modules that affect the digital IO ports:
;	- AD_INIT 	AD must be set to digital ports
;	- CMP_INIT	COmparator defaults are for digital ports
;
; Note: doesn't deal with PORTB weak pullups, which disable on output and reset

    if INIT_PORTS_EXTERNAL == FALSE	; value set in dev .inc file d18f4520.inc

TRISA_INIT	equ	b'00000000'	; all outputs
TRISB_INIT	equ	b'00000000'	; all outputs
TRISC_INIT	equ	b'00000000'	; all outputs

    if DEVTYPE == 4420 | DEVTYPE == 4520

TRISD_INIT	equ	b'00000000'	; 4420/4520 only
TRISE_INIT	equ	b'00000000'	; 4420/4520 only
    endif

PORT_INIT
	movlw	TRISA_INIT
	movwf	TRISA
	movlw	TRISB_INIT
	movwf	TRISB
	movlw	TRISC_INIT
	movwf	TRISC

    if DEVTYPE == 4420 | DEVTYPE == 4520
	movlw	TRISD_INIT
	movwf	TRISD
	movlw	TRISE_INIT
	movwf	TRISE
    endif

;	bsf	INTCON,PEIE 		; peripheral irq must also be enabled
	return
    endif


;******************************************************************************
; T0_INIT  - Initialize timer0
; T0_STOP  - Stop timer0
; T0_START - Start timer0

    if INIT_T0_EXTERNAL == FALSE

T0CON_INIT	equ	b'00000111'	; 7 - TMR0ON = 0 (0FF, see pg 123)
					; 6 - T08BIT = 0 (as 16 bit timer)
					; 5 - T0CS = 0 (internal clock)
					; 4 - TOSC = 0 (lo to hi transition)
					; 3 - PSA = 0 (use the prescaler)
					; 2-0 T0PS = 111 (256 prescale)
T0CON_START	equ	T0CON_INIT | 0x80 ; TMR0ON = 1 (0N)

TMR0H_INIT	equ	0x00		; initial HI value
TMR0L_INIT	equ	0x00		; initial LO value

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
;	bsf	INTCON,TMR0IE 		; enable interrupts
	; pick one...
;	bsf	INTCON2,TMR0IP		; 1 = high priority
;	bcf	INTCON2,TMR0IP		; 0 = low priority
	return
    endif

;******************************************************************************
; T1_INIT  - Initialize timer1
; T1_STOP  - Stop timer1
; T1_START - Start timer1

    if INIT_T1_EXTERNAL == FALSE

T1CON_INIT	equ	b'10000000'	; RD16 = 1 (16 bit R/W, see pg 127)
					; TMR1ON = 0 (timer is OFF)
T1CON_START	equ	b'10000001'	; TMR1ON = 1 (timer is ON)

TMR1L_INIT	equ	0x00		; initial LO value
TMR1H_INIT	equ	0x00		; initial HI value

T1_INIT
T1_STOP	
	movlw	T1CON_INIT
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
	bsf	IPR1,TMR1IP		; 1 = high priority
	return
    endif


;******************************************************************************
; T2_INIT  - Initialize timer2
; T2_STOP  - Stop timer2
; T2_START - Start timer2 

T2CON_INIT	equ	b'00000000'	; TMR2ON = 0 (disabled, see pg 133)
T2CON_START	equ	b'00000100'	; TMR2ON = 1 (enabled)

TMR2_INIT	equ	0x00		; timer register
PR2_INIT	equ	0x00		; period register

T2_INIT
T2_STOP	movlw	T2CON_INIT
	movwf	T2CON
	bcf	PIR1,TMR2IF		; clear interrupt flag
	bcf	PIE1,TMR2IE 		; disable interrupts
	bcf	IPR1,TMR2IP		; set to low priority
	return

T2_START
	movlw	T2CON_START
	movwf	T2CON
	movlw	TMR2_INIT
	movwf	TMR2
	movlw	PR2_INIT
	movwf	PR2
	bcf	PIR1,TMR2IF		; clear interrupt flag
;	bsf	PIE1,TMR2IE 		; enable interrupts
;	bsf	IPR1,TMR2IP		; set to high priority
	return

;******************************************************************************
; T3_INIT  - Initialize timer
; T3_STOP  - Stop timer
; T3_START - Start timer

T3CON_INIT	equ	b'10000000'	; RD16 = 1 (16 bit R/W, see pg 135)
					; TMR3ON = 0 (timer is OFF)
T3CON_START	equ	b'10000001'	; TMR3ON = 1 (timer is ON)

TMR3L_INIT	equ	0x00		; initial LO value
TMR3H_INIT	equ	0x00		; initial HI value

T3_INIT
T3_STOP	movlw	T3CON_INIT
	movwf	T3CON
	bcf	PIR1,TMR3IF		; clear interrupt flag
	bcf	PIE1,TMR3IE 		; disable interrupts
	bcf	IPR1,TMR3IP		; set to low priority
	return

T3_START 
	movlw	T3CON_START
	movwf	T3CON
	movlw	TMR3L_INIT
	movwf	TMR3L
	movlw	TMR3H_INIT
	movwf	TMR3H
	bcf	PIR1,TMR3IF		; clear interrupt flag
;	bsf	PIE1,TMR3IE 		; enable interrupts
;	bsf	IPR1,TMR3IP		; set to high priority
	return


;******************************************************************************
; CMP_INIT - Initialize comparator and voltage references
; Note: Haven't built a START/STOP for this one yet.

CMP_INIT

CMCON_INIT	equ	b'00000111'	; CM = 111 (comparators off)
CVRCON_INIT	equ	b'00000000'	; disabled

	movlw	CMCON_INIT
	movwf	CMCON
	movlw	CVRCON_INIT
	movwf	CVRCON
	bcf	PIR2,CMIF		; clear interrupt flag
;	bsf	PIE2,CMIE 		; enable interrupts
;	bsf	IPR2,CMIP		; 1 = high priority

	return


;******************************************************************************
; CCP_INIT - Initialize all capture / compare / PWM modules
; Note: Haven't built a START/STOP for this one yet.

CCP1CON_INIT	equ	b'00000000'	; CCP1M = 0000 (disabled, see pg 139)
CCP2CON_INIT	equ	b'00000000'	; CCP2M = 0000 

CCP_INIT
	; CCP1
	movlw	CCP1CON_INIT
	movwf	CCP1CON

	bcf	PIR1,CCP1IF		; clear interrupt flag
;	bsf	PIE1,CCP1IE 		; enable interrupts
;	bsf	IPR1,CCP1IP		; 1 = high priority

	; CCP2
	movlw	CCP2CON_INIT
	movwf	CCP2CON

	bcf	PIR2,CCP2IF		; clear interrupt flag
;	bsf	PIE2,CCP2IE 		; enable interrupts
;	bsf	IPR2,CCP2IP		; 1 = high priority

	return


;******************************************************************************
; MSSP_INIT - Initialises synchronous serial IO module (SSP, MSSP, BSSP) 
; Used for I2C communications. See MSSP documentation.

SSPSTAT_INIT	equ	b'00000000'	; status register

SSPCON1_INIT	equ	b'00000000'	; disable serial IO
SSPCON1_START	equ	b'00101111'	; SSPEN = 1 (enables serial modes)
					; SSPM = 1111 (e.g. I2C slave mode...)

SSPCON2_INIT	equ	b'00000000'	; used for I2C mode only
SSPCON2_START	equ	b'00000000'

MSSP_INIT 	; make sure port pins are setup before calling this routine
MSSP_STOP
	movlw	SSPSTAT_INIT
	movwf	SSPSTAT
	movlw	SSPCON1_INIT
	movwf	SSPCON1
	movlw	SSPCON2_INIT
	movwf	SSPCON2
	return

MSSP_START
	movlw	SSPSTAT_INIT
	movwf	SSPSTAT
	movlw	SSPCON1_INIT
	movwf	SSPCON1
	movlw	SSPCON2_INIT
	movwf	SSPCON2

	;>>> Must set bits to input or output depending on I2C vs SSP,
	;	master vs slave modes. For example:
	bsf	TRISC,3			; set to input for slave I2C clock in
	bsf	TRISC,4			; set to input for slave I2C data in

	bcf	PIR1,SSPIF		; clear interrupt flag
;	bsf	PIE1,SSPIE 		; enable interrupts
;	bsf	IPR1,SSPIP		; 1 = high priority

	return


;******************************************************************************
; USART1_INIT  - Initialize USART
; USART1_STOP  - Stop USART
; USART1_START - Start USART with appropriate RX and TX interrupts
;
; Make sure ports are setup properly before calling this routine:
; Note: TXIF and RCIF are only cleared by hardware - firmware cannot clear them

TXSTA_INIT	equ	b'00100110'	; xxxx | *TX9 | TXEN | *ASYNC | BRGH | TSR Empty
TXSTA_START	equ	b'10100110'	; xxxx | *TX9 | TXEN | *ASYNC | BRGH | TSR Empty
RCSTA_INIT	equ	b'00010000'	; SPEN | *RX9 | xxxx | CREN
RCSTA_START	equ	b'10010000'	; SPEN | *RX9 | xxxx | CREN
BAUDCON_INIT	equ	b'00000000'
SPBRGH_INIT	equ	.0
SPBRG_INIT	equ	.0

USART_INIT
USART_STOP
	movlw	TXSTA_INIT
	movwf	TXSTA
	movlw	RCSTA_INIT
	movwf	RCSTA
	movlw	BAUDCON_INIT
	movwf	BAUDCON

	bcf	PIR1,RCIF		; clear flags
	bcf	PIE1,RCIE		; disable receiver interrupts
	bcf	IPR1,RCIP		; set to low priority

	bcf	PIR1,TXIF		; clear flags
	bcf	PIE1,TXIE		; disable transmitter interrupts
	bcf	IPR1,TXIP		; set to low priority
	return

USART_START				; start USART receiver & transmitter
	movlw	TXSTA_START
	movwf	TXSTA
	movlw	RCSTA_START
	movwf	RCSTA
	movlw	BAUDCON_INIT
	movwf	BAUDCON
	movlw	SPBRGH_INIT		; set baudrate
	movwf	SPBRGH
	movlw	SPBRG_INIT
	movwf	SPBRG

	bcf	PIR1,RCIF		; clear flags
	bsf	PIE1,RCIE		; enable receiver interrupts
	bcf	IPR1,RCIP		; set to low priority

	bcf	PIR1,TXIF		; clear flags
	bsf	PIE1,TXIE		; enable transmitter interrupts
	bcf	IPR1,TXIP		; set to low priority

	bcf	RCSTA,CREN		; clear and start RX
	bsf	RCSTA,CREN
	return				; PIE and GIE must also be enabled

;USART_RESTART				; ISR-friendly restart
;	call	USART_START
;	goto	ISR_RX_EXIT

 
;******************************************************************************
; EE_INIT

EECON1_INIT	equ	b'10000000'	; EEPGD = 1 (access flash)

EE_INIT	
	movlw	EECON1_INIT
	movwf	EECON1
	return
  

	END                       	; directive 'end of program'

