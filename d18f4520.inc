;*****************************************************************************
; d18f2520 - device header file
;*****************************************************************************
;
;    Filename:	    	d18f4520.inc
;    Author, Company:	Alden Hart, Luke's Lights
;    Date/Time/Rev:	091015
;
; Choses device and sets basic parameters related to the device and it's 
; use in this application
; 

;----- Common, device-specific definitions -----

DEV_FAMILY 	equ	18		; for F18 series
FOSC		equ	.36		; MHz (approximate and must be tested)

; Used to qualify instructions:
A	equ	0			; Access Bank
B	equ	1			; BSR banked

;------ Select Device -----
; pick only one:
;DEVTYPE  equ	2420		; 18F2420
;DEVTYPE  equ	2520		; 18F2520
DEVTYPE  equ	4420		; 18F4420
;DEVTYPE  equ	4520		; 18F4520

; PIC18F2420
    if DEVTYPE == 2420
	nolist
#include <p18f2420.inc>
	list
;	list	p=18f2420 		; not needed - processor is set by MPLAB
MAXRAM	equ	0x02FF
    endif

;PIC18F2520
    if DEVTYPE == 2520
	nolist
#include <p18f2520.inc>
	list
;	list	p=18f2520 		; not needed - processor is set by MPLAB
MAXRAM	equ	0x05FF
    endif

;PIC18F4420
    if DEVTYPE == 4420
	nolist
#include <p18f4420.inc>
	list
;	list	p=18f4420 		; not needed - processor is set by MPLAB
MAXRAM	equ	0x02FF
    endif

;PIC18F4520
    if DEVTYPE == 4520
	nolist
#include <p18f4520.inc>
	list
;	list	p=18f4520 		; not needed - processor is set by MPLAB
MAXRAM	equ	0x05FF
    endif
