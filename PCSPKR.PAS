unit PCSPKR;

interface

uses TInterrupts;

const
	PPIPortB = $61;
	Chan2Port = $42;

procedure InitPCspkrPWM;
procedure ResetPCSpkr;

implementation

procedure InitPCSpkrPWM;
var
	ppi: byte;
begin
	{ Enable speaker and tie input pin to CTC Chan 2 by setting bits 1 and 0 }
	ppi := port[PPIPortB];
	ppi := ppi or $3;
	port[PPIPortB] := ppi;

	port[CTCModeCommandReg] := (iMC_Chan2 or iMC_AMLB or iMC_OpMode0 or iMC_BinaryMode);
	port[Chan2Port] := $01;	{ Counter 2 count = 1 - terminate count quickly }
end;

procedure ResetPCSpkr;
var
	ppi: byte;
begin
	{ Disable speaker by clearing bits 1 and 0 }
	ppi := port[PPIPortB];
	ppi := ppi and (not $3);
	port[PPIPortB] := ppi;

	{ Reset timer }
	port[CTCModeCommandReg] := (iMC_Chan2 or iMC_AMLH or iMC_OpMode3 or iMC_BinaryMode);
	port[Chan2Port] := 0;
	port[Chan2Port] := 0;
end;

end.