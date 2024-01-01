{$M 2048,0,655360}
{$G-,F-,S-,R-}

{{$DEFINE DEBUG}

{{$DEFINE HP95LX} {Undefine to add support for an HP95LX}

{todo:
-- add left/right skip by +/- 5 secs, 1 minute, 5 minutes
  - flash screen to register keypress? or just key click?
  also add spacebar for pause/play
}


{$IFDEF DEBUG}
{$S+,R+}
{$ENDIF}

Program xdc_play;

uses
  xdc_globals,
  xdc_common,
  ringbufu,
  objects,     {file stream support}
  support,     {basic support stuff I don't want to include CRT for}
  cmdlin,      {for parsing command-line options}
  tinterrupts, {8253 manipulation routines}
  I8259A,      {8259A manipulation routines}
  dos,         {for getintvec/setintvec}
  soundlib,    {Sound Blaster detection/setup/init/teardown code}
  pcspkr,      {PC speaker routines for PWM playback}
  PCjrSupport; {Routines for PCjr/Tandy audio}

type
  SoundDevice = (
    SD_None,
    SD_PCSpkr,
    SD_Covox,
    SD_SB,
    SD_Tandy);

const
  {samplerate:word=22050;}
  maxsamplerate=45454;   {this is the maximum the Soundblaster Pro/2.0 can do}
  intfps:byte=24;
  realFPS:real=23.976;
  maxintfps=120;         {CGA CRT maxes out at 60Hz (slightly less, actually)}
  maxsndChunkSize=$4000; {a reasonable maximum to ensure we don't cross DMA
                         boundary}
  sndbufsize:word=0;     {size of actual sound buffer (2 chunks)}
  maxsndBufSize=maxsndChunkSize * 2;

  DataQueued:boolean=false; {If FALSE, then playback pauses while more
                            data is buffered from disk}
  numPauses:word=0;
  sndDev:SoundDevice=SD_None;
  presenting:boolean=false;
  showpip:boolean=false;
  curPlayPacket:word=0;
  packetsLeft:word=0;
  minDiskRead:word=32;      {minimum disk I/O to perform, in KB}

  {to calculate CPU "utilization" of the player (actually the inverse of idle)}
  cpuUsageTicks:longint=0;
  cpuUsageCounter:longint=0;
  cpuUsageCounterIdle:longint=0;
  IOUsageTicks:longint=0;

  Int1CSave:pointer=nil;
  
  { Volume scale for SN76496 used in PCjr and Tandy 1000 }
  { A drop of 2dB will correspond to a ratio of 10-0.1 = 0.79432823 between the current and previous output values. }
  { So linear output level of volume V is MAX_OUTPUT*(0.79432823^V) with V in (0..15), 0 being the loudest, and 15 silence. }
  { In this table, we take MAX_OUTPUT = 32767. }
  volume_table:array[0..15] of Integer = (
    32767, 26028, 20675, 16422, 13045, 10362,  8231,  6568,
     5193,  4125,  3277,  2603,  2067,  1642,  1304,     0
  );

var
  f:tDosStream;
  header:XDVHeader;
  playp:pointer;
  AVRing:TSlabRing;
  fname:string;
  cvxPort:word;
  mt:MachineType;
  samples:word;
  frameInterval:word;
  audio:^byte;
  strans: array [0..255] of byte;

procedure userTickHandler; interrupt;
begin
  inc(cpuUsageTicks);
end;

{$IFDEF HP95LX}
procedure userTickHandler95LX; interrupt;
begin
  inc(cpuUsageTicks);
  play.callproc;
end;
{$ENDIF}

procedure BuildTransPWM(rate:word);
var
  i: word;
  scale: word;
  s: real;
begin
  scale := (PITFREQ div rate) - 2;

  for i := 0 to 255 do
  begin
    s := i / 255.0;
    strans[i] := 1 + trunc(s * scale);
  end;
end;

{  MAX_OUTPUT*(0.79432823^V) = Y
   Solve for V:
   (0.79432823^V) = Y/MAX_OUTPUT
   V = log(Y/MAX_OUTPUT)/log(0.79432823)
}
procedure BuildTransTandy(chan:byte);
var
  i: word;
  iLog:real;
  s: integer;
begin
  chan := chan shl 5;
  chan := chan or $90;
  
  iLog := 1.0/ln(0.79432823);
  
  strans[0] := 15 or chan;

  for i := 1 to 255 do
  begin
    s := trunc(ln(i/255.0)*iLog);
    if s > 15 then
      s := 15;
    if s < 0 then
      s := 0;
    strans[i] := s or chan;
  end;
end;

Procedure PrintHelp;
begin
  asm
        push    ds
        jmp     @start
@message:
        db 'Usage:  xdc_play <switches> [filename] <switches>',0dh,0ah
        db '  <filename> is the video to play',0dh,0ah
        db '  /? or /h   This help',0dh,0ah
        db '  /q         Quiet -- do not attempt to use a sound card',0dh,0ah
        db '  /w         Use PC speaker output',0d0h,0ah
        db '  /c<port>   Use Covox on <port>',0dh,0ah
        db '  /s         Use Sound Blaster',0dh,0ah
        db '  /t         Use Tandy sound',0d,0ah
        db '  /kN        How much KB to read in a single operation',0dh,0ah
        db '  /p         Presentation mode (no messages, stay in graphics mode)',0dh,0ah
        db '  /d         Displays queue depth indicator',0dh,0ah
        db '$'
@start:
        mov     ax,0900h
        lea     dx,@message
        mov     bx,cs
        mov     ds,bx
        int     21h
        pop     ds
  end;
  halt(255);
end;

Procedure prepPlayer;
var
  l:longint;
  p:string;
begin
  {handle user input}
  if (paramcount=0) or is_Param('h') or is_Param('?') then printHelp;
  if is_param('p') then presenting:=true;
  if is_param('d') then showpip:=true;
  if is_param('q') then sndDev:=SD_None;
  if is_param('w') then sndDev:=SD_PCSpkr;
  if is_param('c') then
  begin
   sndDev:=SD_Covox;
   p:=Param_Text('c');
   cvxPort:=StrToInt('$'+p);
  end;
  if is_param('s') then sndDev:=SD_SB;
  if is_param('t') then sndDev:=SD_Tandy;
  if is_param('k') then minDiskRead:=param_int('k');
  if non_flag_count>0 then fname:=non_flag_param(1);
  if not fileexists(fname) then fatalerror(1,'Filename "'+fname+'" not found');

  {Print information on selected audio device}
  if not presenting then
  begin
    case (sndDev) of
      SD_None:
        writeln('User requested silence; using system timer instead of soundcard.');
      SD_PCSpkr:
        writeln('Using PWM sample playback on PC speaker.');
      SD_Covox:
        writeln('Using Covox on port ', hex(cvxPort), '.');
      SD_SB:
        writeln('Using Sound Blaster.');
      SD_Tandy:
        writeln('Using Tandy sound (SN76496).');
    end;
  end;

  f.init(fname,stOpenRead);
  if f.status<>stOK then fatalerror(2,'Problem opening media file: '+fname);
  {read header}
  f.read(header,sizeof(header));
  if header.signature[0]<>'X' {header should start with XDCV}
    then fatalerror(127,'Header signature doesn''t indicate XDCV file...');
  {load packet index}
  getmem(packetindex,header.numpackets);
  f.seek(f.getsize-header.numpackets);
  f.read(packetindex^,header.numpackets);
  {seek back to location of first packet}
  f.seek(sizeof(header));
  sndbufsize:=header.achunksize*2; {because buffer is actually divided into two IRQ firings}
  realfps:=header.samplerate / header.achunksize;
  intfps:=round(realFPS);
  if intfps<4 then intfps:=4; if intfps>maxintfps then intfps:=maxintfps;

  {setup and determine cpu idle counter rate}
  GetIntVec($1C,Int1CSave);
  SetIntVec($1C,@userTickHandler);
  {see how high counter goes for 1 tick when idle}
  if not presenting then writeln('Calibrating CPU idle counter... ');
  l:=cpuUsageTicks;
  repeat
    asm
        hlt
    end
  until l<>cpuUsageTicks; {wait until beginning of tick}
  l:=cpuUsageTicks;
  repeat
    inc(cpuUsageCounterIdle);
  until cpuUsageTicks >= l+8;
  cpuUsageCounterIdle:=cpuUsageCounterIdle div 8;

  AVRing.init(heapPtr,heapEnd); {from now on, we can't use getmem/new/malloc}
  packetsLeft:=header.numPackets;
  with header do begin
    l:=largestPacket div 1024;
    if minDiskRead>64-l then minDiskRead:=64-l;
    if minDiskRead<l then minDiskRead:=l;
  end;
  if not presenting then begin
    writeln('Video FPS:    ',realFPS:2:2);
    writeln('Video length: ',header.numpackets,' frames (',(header.numpackets/realfps)/60:2:2,' minutes)');
    writeln('Audio rate:   ',header.samplerate,' Hz');
    writeln('Using ',AVRing.slabsize div 1024,'KB of RAM for buffering');
    {more arith. checking buggery workarounds, argh}
    l:=header.largestpacket;
    l:=l * intfps;
    l:=l div 1024;
    writeln('This video could demand as much as ',l,' KB/s from your I/O subsystem.');
    writeln('Will read from disk in ',minDiskRead,'KB chunks.');
    writeln('Press key to begin playing.');
    readkeychar;
  end;
end;

procedure soundIntCallerCGA; far;
{
This is where the magic happens.  If we are executing in this code, it means
the sound card just got *finished* playing a buffer, which is our cue to
prepare the next frame.

No check for re-entrancy is performed in this particular snippet because
the parent code in the soundblaster and interrupt routines do that for us.
(In case it wasn't obvious, this is NOT an interrupt handler procedure!)
}

var
  sndBufp:pointer;    {temp pointer to where we should copy our new audio data}
  frameHp:pointer;    {temp pointer video data comes from}
  audioHp:pointer;    {pointer to audio}

begin
  if sndDev = SD_SB then begin
    sndbufp:=play.p; {point to dma buffer}
    if play.activeblock = 2 {If in one half, advance to the second half}
      then inc(word(sndbufp),header.achunksize);
  end;
{$IFNDEF HP95LX}
  {if requested, display a blinking pip onscreen showing queue depth}
  if showpip then asm
        mov     ax,$b800
        mov     es,ax
        mov     di,AVRing.numElements
        mov     cl,3
        shr     di,cl
        mov     ax,di
        or      ax,1000000000000001b
        stosw
  end;
{$ENDIF}
  if AVRing.isEmpty then begin
    if dataQueued then inc(numPauses);
    dataQueued:=false;
  end;
  if DataQueued then begin
    {get a handle to the packet}
    frameHp:=AVRing.retrieve;
    {get a handle to the audio data inside the packet}
    audioHp:=frameHp;
    inc(word(audioHp),(packetIndex^[curPlayPacket]*512)-header.achunksize);
    audio := audioHp;

    {enable interrupts at this point}
    asm sti end;

    if sndDev = SD_SB then begin
      asm
        mov     dx,ds
        les     di,sndbufp
        cld
        mov     cx,header.achunksize
        lds     si,audioHp {don't need vars from DS any more so this is fine}
        rep     movsb
        mov     ds,dx
      end;
    end;
    {execute code in video portion of packet.  Normalized pointers allow:}
    asm
        xor     cx,cx           {Compiler output does not clear CH, so we must}
        call    framehp
        inc     curPlayPacket
    end;
  {if we are NOT allowed to pull AV from the FIFO queue:}
  end else if sndDev = SD_SB then begin
    asm
        les     di,sndbufp
        cld
        mov     cx,header.achunksize
        mov     al,$7f   {fill buffer with silence if we have nothing to put in it}
        rep     stosb
    end;
  end;
  {toggle sound double-buffer blocks}
  asm
        xor     play.activeblock,00000011b {toggles between 1 and 2}
  end;
end;

procedure enqueuefile;
const
  minElements:byte=3; {holdover from 8088flex where each packet was 2K=audiochunk}
  curPacket:word=0;
var
  oldticks:longint;
  numBytes,w,numPackets,commitSize:word;
  p:pointer;
begin
  {ensure we always have half a second's worth of data queued}
  {minElements:=intfps div 2;}
  minElements:=2;
  minDiskRead:=minDiskRead*1024; {convert KB to bytes outside of inner loop}
  {clear fat-finger typing so player doesn't immediately exit}
  if keypressed then repeat readkeychar until not keypressed;
  {must be atomic; 32-bit integer, 2 instructions to zero it, so we wrap it}
  asm
        pushf
        cli
  end;
  cpuUsageTicks:=0;
  asm
        popf
  end;
  cpuUsageCounter:=0;
  with AVRing do begin
    repeat
      if not isFull then begin {if we have space for video+audio data and some extra for handle}
        {determine how many packets to read in this access}
        numBytes:=0;
        numPackets:=0;
        while (packetsLeft>0) and (numBytes<minDiskRead) do begin
          inc(numBytes,(packetIndex^[curPacket+numPackets] * 512));
          inc(numPackets);
          dec(packetsLeft);
        end;
        {reserve an area in the ring buffer}
        p:=reserve(numBytes);
        {if reserve failed, then isFull is true}
        if (p=NIL) or (isFull) then begin
          {unravel what we did above}
          inc(packetsLeft,numPackets);
          {start loop over!}
          continue;
        end;
        {if we got here, we have an area of the slab to write data to}
        {read multiple packets into that area}
        oldticks:=cpuUsageTicks;
        f.read(p^,numBytes);
        inc(IOUsageTicks,cpuUsageTicks-oldticks);
        if f.status<>stOK then fatalerror(2,'disk error');
        {commit multiple packet locations into reserved area}
        for w:=0 to numPackets-1 do begin
          commitSize:=packetIndex^[curPacket]*512;
          if not commit(p,commitSize) then fatalerror(3,'commit failed');
          inc(word(p),commitSize);
          inc(curPacket);
        end;
        (*  The logic here was moved to the interrupt handler
        {If we have such a slow harddisk that we consumed all our data,
        leaving the ring buffer empty, PAUSE PLAYBACK to stop consuming}
        if (numElements < minElements) or isEmpty then begin
          if dataQueued then inc(numPauses);
          dataQueued:=false; {this must be atomic or else playback
          interrupt might try to play non-existent data.  Luckily, it
          compiles to a single instruction.}
        end;
        *)
      end else begin
        DataQueued:=true; {ring buffer is full, we're ready to play}
      end;
      inc(cpuUsageCounter); {record idle time}
      if keypressed then exit;
    {until we reach end of video stream (or file, if something went wrong)}
    until (packetsLeft=0) or (f.status<>stOK);
  end;
  f.done;
  {If entire file fit in RAM, play it. Don't leave here without playback enabled!}
  DataQueued:=true;
end;

Procedure primeSoundcard;
var
  smult:real;
begin
  if initblaster <> 0 then begin
    SetIntVec($01C,Int1CSave); {stop counting ticks}
    fatalError(4,'Couldn''t initialize Sound Blaster');
  end;
  setmemsize(sndbufsize);
  {$IFDEF DPMI} {someday we might take advantage of 286 protected mode ram}
  playp := ptr(play.p,0);
  {$ELSE}
  playp := play.p;
  {$ENDIF}

  fillchar(playp^,sndbufsize,127); {init buffer with silence}
  play.callproc := soundIntCallerCGA;
  initplay(0,play.p,sndbufsize,header.samplerate,snd_8bit+snd_mono+snd_nonsigned);
  if not presenting then writeln(getblasterstring,' initialized.');
end;

{$F+}
procedure noSoundIntCaller; Interrupt;
begin
  play.callproc;

  {We want to be nice, and will maintain the BIOS interrupt}
  inc(PITCycles,frameInterval); {Keep track of how many PIT cycles have gone by}
  if longrec(PITCycles).hi <> 0 then begin {Did we roll over?  Is it time to call the 18.2Hz BIOS handler?}
    longrec(PITCycles).hi:=0; {Update our PIT cycles counter}
    asm pushf end; {simulate an interrupt by pushing flags, then CALLing handler}
    BIOSTimerHandler; {this will acknowledge the interrupt}
  end
  else
    Port[$20] := $20; {send EndOfInterrupt to the PIC to ackn. the interrupt}
end;

procedure pwmSoundIntCaller; Interrupt;
var
  sample:byte;
begin
  {output one 8-bit PCM sample to PC speaker}
  sample := audio^;
  port[Chan2Port] := strans[sample];
  inc(audio);

  dec(samples);
  if samples = 0 then
  begin
    samples := header.achunksize;
    play.callproc;

    {We want to be nice, and will maintain the BIOS interrupt}
    inc(PITCycles,frameInterval); {Keep track of how many PIT cycles have gone by}
    if longrec(PITCycles).hi <> 0 then begin {Did we roll over?  Is it time to call the 18.2Hz BIOS handler?}
      longrec(PITCycles).hi:=0; {Update our PIT cycles counter}
      asm pushf end; {simulate an interrupt by pushing flags, then CALLing handler}
      BIOSTimerHandler; {this will acknowledge the interrupt}
    end
  end;
end;

procedure tpwmSoundIntCaller; Interrupt;
begin
  {output one pre-translated sample to PC speaker}
  port[Chan2Port] := audio^;
  inc(audio);

  dec(samples);
  if samples = 0 then
  begin
    samples := header.achunksize;
    play.callproc;

    {We want to be nice, and will maintain the BIOS interrupt}
    inc(PITCycles,frameInterval); {Keep track of how many PIT cycles have gone by}
    if longrec(PITCycles).hi <> 0 then begin {Did we roll over?  Is it time to call the 18.2Hz BIOS handler?}
      longrec(PITCycles).hi:=0; {Update our PIT cycles counter}
      asm pushf end; {simulate an interrupt by pushing flags, then CALLing handler}
      BIOSTimerHandler; {this will acknowledge the interrupt}
    end
  end;
end;


procedure cvxSoundIntCaller; Interrupt;
begin
  {output one 8-bit PCM sample to Covox via printer port}
  port[cvxPort] := audio^;
  inc(audio);

  dec(samples);
  if samples = 0 then
  begin
    samples := header.achunksize;
    play.callproc;

    {We want to be nice, and will maintain the BIOS interrupt}
    inc(PITCycles,frameInterval); {Keep track of how many PIT cycles have gone by}
    if longrec(PITCycles).hi <> 0 then begin {Did we roll over?  Is it time to call the 18.2Hz BIOS handler?}
      longrec(PITCycles).hi:=0; {Update our PIT cycles counter}
      asm pushf end; {simulate an interrupt by pushing flags, then CALLing handler}
      BIOSTimerHandler; {this will acknowledge the interrupt}
    end
  end;
end;

procedure tdySoundIntCaller; Interrupt;
var
  sample:byte;
begin
  {output one 8-bit PCM sample to SN76496}
  sample := audio^;
  port[SNReg] := strans[sample];
  inc(audio);

  dec(samples);
  if samples = 0 then
  begin
    samples := header.achunksize;
    play.callproc;

    {We want to be nice, and will maintain the BIOS interrupt}
    inc(PITCycles,frameInterval); {Keep track of how many PIT cycles have gone by}
    if longrec(PITCycles).hi <> 0 then begin {Did we roll over?  Is it time to call the 18.2Hz BIOS handler?}
      longrec(PITCycles).hi:=0; {Update our PIT cycles counter}
      asm pushf end; {simulate an interrupt by pushing flags, then CALLing handler}
      BIOSTimerHandler; {this will acknowledge the interrupt}
    end
  end;
end;

procedure ttdySoundIntCaller; Interrupt;
begin
  {output one pre-translated sample to SN76496}
  port[SNReg] := audio^;
  inc(audio);

  dec(samples);
  if samples = 0 then
  begin
    samples := header.achunksize;
    play.callproc;

    {We want to be nice, and will maintain the BIOS interrupt}
    inc(PITCycles,frameInterval); {Keep track of how many PIT cycles have gone by}
    if longrec(PITCycles).hi <> 0 then begin {Did we roll over?  Is it time to call the 18.2Hz BIOS handler?}
      longrec(PITCycles).hi:=0; {Update our PIT cycles counter}
      asm pushf end; {simulate an interrupt by pushing flags, then CALLing handler}
      BIOSTimerHandler; {this will acknowledge the interrupt}
    end
  end;
end;
{$F-}

procedure primeNoCard; {Instead of sound blaster, we will use the system timer}
begin
  play.callproc := soundIntCallerCGA;
  SetTimerExact(@noSoundIntCaller,trunc(PITFreq/realfps)); {set to fire at video's framerate}
  frameInterval := Chan0Counter;
end;

procedure primePwm;
var
  ticks:word;
begin
  {Calc PWM translation table}
  BuildTransPWM(header.samplerate);

  {Set PC speaker to PWM mode}
  InitPCSpkrPWM;

  ticks := trunc(PITFreq div header.samplerate);

  play.callproc := soundIntCallerCGA;
  if header.features and a_pwmdat <> 0 then
    SetTimerExact(@tpwmSoundIntCaller,ticks) {set to fire at video's framerate}
  else
    SetTimerExact(@pwmSoundIntCaller,ticks); {set to fire at video's framerate}
  frameInterval := ticks * header.achunksize;
end;

procedure primeCvx;
var
  ticks:word;
begin
  ticks := trunc(PITFreq div header.samplerate);

  play.callproc := soundIntCallerCGA;
  SetTimerExact(@cvxSoundIntCaller,ticks); {set to fire at video's framerate}
  frameInterval := ticks * header.achunksize;
end;

procedure primeTandy;
var
  ticks:word;
begin
  {Calc SN76496 translation table}
  BuildTransTandy(0);

  {Enable sample playback on SN76496}
  jrInitAudio;
  jrSetAudioPeriod(0, 1);
  jrSetAudioVolume(0, 15);
  jrSetAudioVolume(1, 15);
  jrSetAudioVolume(2, 15);
  jrSetAudioVolume(3, 15);

  ticks := trunc(PITFreq div header.samplerate);

  play.callproc := soundIntCallerCGA;
  if header.features and a_tdydat <> 0 then
    SetTimerExact(@ttdySoundIntCaller,ticks) {set to fire at video's framerate}
  else
    SetTimerExact(@tdySoundIntCaller,ticks); {set to fire at video's framerate}
  frameInterval := ticks * header.achunksize;
end;

{$IFDEF HP95LX}
procedure primeNoCard95LX;
begin
  play.callproc := soundIntCallerCGA;
  SetIntVec($1C,@userTickHandler95LX);
end;
{$ENDIF}

Procedure shutItDown;
begin
  SetIntVec($01C,Int1CSave); {stop counting ticks}

{$IFDEF HP95LX}
  if sndDev = SD_SB
    then exitplay; {shutdown Sound Blaster}
{$ELSE}
  if sndDev <> SD_SB
    then CleanUpTimer {stop our internal "sound" handler}
  else exitplay; {shutdown Sound Blaster}
{$ENDIF}

  if sndDev in [SD_PCSpkr, SD_Covox, SD_Tandy] then
    RestorePICState(mt);

  if sndDev = SD_PCSpkr then
    ResetPCSpkr;

  if sndDev = SD_Tandy then
  begin
    jrCloseAudio;
    jrSetAudio(0, 440, 15);
    jrSetAudio(1, 440, 15);
    jrSetAudio(2, 440, 15);
    jrSetAudioVolume(3, 15);
  end;

  if not presenting then begin
    asm
{$IFDEF HP95LX}
        mov     ax,7
{$ELSE}
        mov     ax,3
{$ENDIF}
        int     10h
    end;
    asm
        push    ds
        jmp     @start
@message:
        db 'XDC Player v0.1, 20140520',0dh,0ah
        db 'All design and code by Trixter / Hornet',0dh,0ah
        db 'Sound Blaster shell (SB "2.01" ;-) by Stefan Goehler',0dh,0ah
        db '$'
@start:
        mov     ax,0900h
        lea     dx,@message
        mov     bx,cs
        mov     ds,bx
        int     21h
        pop     ds
    end;
    writeln('Playback statistics:');
    writeln('# of pauses during playback: ',numPauses);
    writeln('CPU was ',(100*(cpuUsageCounter div cpuUsageTicks)) div cpuUsageCounterIdle,'% idle');
    writeln((100*IOUsageTicks) div cpuUsageTicks,'% of total playback time was spent reading from disk');
    writeln('# of elements still in the ring: ',AVRing.numElements);
  end;
  AVRing.done;
  freemem(packetindex,header.numpackets);
  if keypressed then repeat readkeychar until not keypressed; {absorb keystroke that was used to exit playback}
end;

begin
  samples := 1;

  prepPlayer;
 
  if sndDev in [SD_PCSpkr, SD_Covox, SD_Tandy] then
  begin
    {enable Auto-EOI mode}
    mt := GetMachineType;
    SetAutoEOI(mt);
  end;

  case (sndDev) of
    SD_None:
{$IFDEF HP95LX}
      primeNoCard95LX;
{$ELSE}
      primeNoCard;
{$ENDIF}
    SD_PCSpkr:
      primePwm;
    SD_Covox:
      primeCvx;
    SD_SB:
      primeSoundcard;
    SD_Tandy:
      primeTandy;
  end;
  
  xdc_setvid(header.vidmode);
  {if not presenting then writeln('Performing initial buffering...');}
  EnqueueFile;
  repeat
    {do nothing, because if we're here, we've loaded everything into RAM
    and are just waiting for everything to be played}
    inc(cpuUsageCounter); {record idle time}
  until AVRing.isempty or not dataqueued;
  
  shutItDown;
end.
