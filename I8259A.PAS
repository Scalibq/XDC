unit I8259A;

interface

const
{ 8259A Programmable Interrupt Controller }
	PC_PIC1 = $20;		{ IO base address for master PIC }
	PC_PIC2 = $A0;		{ IO base address for slave PIC (AT only) }
	PC_PIC1_COMMAND = PC_PIC1;
	PC_PIC1_DATA = (PC_PIC1+1);
	PC_PIC2_COMMAND = PC_PIC2;
	PC_PIC2_DATA = (PC_PIC2+1);
	
	PC_PIC1_VECTOR_BASE = $08;
	PC_PIC2_VECTOR_BASE = $70;
	
	PC_DELAY_PORT = $EE;

	ICW1_ICW4 = $01;		{ ICW4 (not) needed }
	ICW1_SINGLE	= $02;		{ Single (cascade) mode }
	ICW1_INTERVAL4 = $04;	{ Call address interval 4 (8) }
	ICW1_LEVEL = $08;		{ Level triggered (edge) mode }
	ICW1_INIT = $10;		{ Initialization - required! }

	ICW4_8086 = $01;		{ 8086/88 (MCS-80/85) mode }
	ICW4_AEOI = $02;		{ Auto (normal) EOI }
	ICW4_BUF_SLAVE = $08;	{ Buffered mode/slave }
	ICW4_BUF_MASTER = $0C;	{ Buffered mode/master }
	ICW4_SFNM = $10;		{ Special fully nested (not) }

{ OCW1 is mapped directly to the DATA port of the PIC }

{ OCW2 and OCW3 are mapped to the COMMAND port of the PIC }
{ Bits 3 and 4 select which command word is used }
	OCW2 = $00;
	OCW3 = $08;

	OCW2_EOI = (OCW2 or $20);	{ End-of-interrupt command code }
	OCW2_SL = (OCW2 or $40);	{ Specific end-of-interrupt (interrupt specified in low 3 bits) }
	OCW2_R = (OCW2 or $80);	{ Rotate priorities }

	OCW3_RIS = (OCW3 or $01);	{ Read ISR (instead of IRR) }
	OCW3_RR = (OCW3 or $02);	{ Read register }
	OCW3_P = (OCW3 or $04);	{ Poll }
	OCW3_SMM = (OCW3 or $20);	{ Set special mask mode (else reset) }
	OCW3_ESMM = (OCW3 or $40);	{ Special mask mode }

type
	MachineType = (
		MACHINE_PCXT,
		MACHINE_PCAT,
		MACHINE_PS2,
		MACHINE_PC98);

function GetMachineType: MachineType;
procedure InitPIC(command: word; data: word; ICW1: byte; ICW2: byte; ICW3: byte; ICW4: byte);
procedure SetAutoEOI(mt: MachineType);
Procedure RestorePICState(mt: MachineType);

implementation

function GetMachineType: MachineType;
var
	ret: MachineType;
begin
	asm
		mov [ret], MACHINE_PCXT
		
		push es

		{ Get BIOS configuration }
		mov ah, $C0
		int $15
		jc @@notSupported

		mov al, es:[bx+5]	{ Get feature byte 1 }
		test al, $40		{ Do we have a second 8259A? }
		jz @@exit

		mov [ret], MACHINE_PCAT

		test al, $3		{ Do we have MCA bus? }
		jz @@exit

		mov [ret], MACHINE_PS2
		jmp @@exit

@@notSupported:
		{ First try to test for known machine byte }
		mov ax, $F000
		mov es, ax
		mov al, es:[$FFFE]

		{ Is it a PC, XT or PCjr (FF, FE and FD respectively) }
		cmp al, $FD
		jae @@exit

		{ Is it an AT? }
		cmp al, $FC
		jne @@unknownMachineType

		mov [ret], MACHINE_PCAT
		jmp @@exit

@@unknownMachineType:
		cli

		{ First check for physical second PIC }
		in al, PC_PIC2_DATA
		mov bl, al	{ Save PIC2 mask }
		not al		{ Flip bits to see if they 'stick' }
		out PC_PIC2_DATA, al
		out PC_DELAY_PORT, al	{ delay }
		in al, PC_PIC2_DATA
		xor al, bl	{ If writing worked, we expect al to be 0xFF }
		inc al		{ Set zero flag on 0xFF }
		mov al, bl
		out PC_PIC2_DATA, al	{ Restore mask }
		jnz @@noCascade

		mov [ret], MACHINE_PCAT

@@noCascade:
		sti

@@exit:
		pop es
	end;
	
	GetMachineType := ret;
end;

procedure InitPIC(command: word; data: word; ICW1: byte; ICW2: byte; ICW3: byte; ICW4: byte);
begin
	asm
		cli

		mov dx, [data]
		in al, dx	{ Save old mask }
		mov bl, al

		mov dx, [command]
		mov al, [ICW1]
		out dx, al
		out PC_DELAY_PORT, al	{ delay }
		mov dx, [data]
		mov al, [ICW2]
		out	dx, al
		out PC_DELAY_PORT, al	{ delay }

		{ Do we need to set ICW3? }
		test [ICW1], ICW1_SINGLE
		jnz @@skipICW3

		mov al, [ICW3]
		out dx, al
		out PC_DELAY_PORT, al	{ delay }
@@skipICW3:
		{ Do we need to set ICW4? }
		test [ICW1], ICW1_ICW4
		jz @@skipICW4

		mov al, [ICW4]
		out dx, al
		out PC_DELAY_PORT, al	{ delay }
@@skipICW4:
		mov al, bl		{ Restore old mask }
		out dx, al

		sti
	end;
end;

procedure SetAutoEOI(mt: MachineType);
begin
	case (mt) of
		MACHINE_PCXT:
		begin
			InitPIC(PC_PIC1_COMMAND, PC_PIC1_DATA,
				ICW1_INIT or ICW1_SINGLE or ICW1_ICW4,
				PC_PIC1_VECTOR_BASE,
				$00,
				ICW4_8086 or ICW4_BUF_SLAVE or ICW4_AEOI);
		end;
		MACHINE_PCAT:
		begin
			InitPIC(PC_PIC1_COMMAND, PC_PIC1_DATA,
				ICW1_INIT or ICW1_ICW4,
				PC_PIC1_VECTOR_BASE,
				$04,
				ICW4_8086 or ICW4_AEOI);
			InitPIC(PC_PIC2_COMMAND, PC_PIC2_DATA,
				ICW1_INIT or ICW1_ICW4,
				PC_PIC2_VECTOR_BASE,
				$02,
				ICW4_8086 or ICW4_AEOI);
		end;
		MACHINE_PS2:
                begin
			InitPIC(PC_PIC1_COMMAND, PC_PIC1_DATA,
				ICW1_INIT or ICW1_LEVEL or ICW1_ICW4,
				PC_PIC1_VECTOR_BASE,
				$04,
				ICW4_8086 or ICW4_AEOI);
			InitPIC(PC_PIC2_COMMAND, PC_PIC2_DATA,
				ICW1_INIT or ICW1_LEVEL or ICW1_ICW4,
				PC_PIC2_VECTOR_BASE,
				$02,
				ICW4_8086 or ICW4_AEOI);
		end;
	end;
end;

Procedure RestorePICState(mt: MachineType);
begin

	case (mt) of
		MACHINE_PCXT:
		begin
			InitPIC(PC_PIC1_COMMAND, PC_PIC1_DATA,
				ICW1_INIT or ICW1_SINGLE or ICW1_ICW4,
				PC_PIC1_VECTOR_BASE,
				$00,
				ICW4_8086 or ICW4_BUF_SLAVE);
		end;
		MACHINE_PCAT:
		begin
			InitPIC(PC_PIC1_COMMAND, PC_PIC1_DATA,
				ICW1_INIT or ICW1_ICW4,
				PC_PIC1_VECTOR_BASE,
				$04,
				ICW4_8086);
			InitPIC(PC_PIC2_COMMAND, PC_PIC2_DATA,
				ICW1_INIT or ICW1_ICW4,
				PC_PIC2_VECTOR_BASE,
				$02,
				ICW4_8086);
		end;
		MACHINE_PS2:
		begin
			InitPIC(PC_PIC1_COMMAND, PC_PIC1_DATA,
				ICW1_INIT or ICW1_LEVEL or ICW1_ICW4,
				PC_PIC1_VECTOR_BASE,
				$04,
				ICW4_8086);
			InitPIC(PC_PIC2_COMMAND, PC_PIC2_DATA,
				ICW1_INIT or ICW1_LEVEL or ICW1_ICW4,
				PC_PIC2_VECTOR_BASE,
				$02,
				ICW4_8086);
		end;
	end;
end;

end.