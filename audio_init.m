function A = audio_init()
%AUDIO_INIT  State of the audio engine (siren oscillator + message player).
%   Like a circuit's registers: the audio is produced in 0.1 s frames, so
%   the oscillator phase must survive from one frame to the next or each
%   frame boundary would produce an audible click.
A.ph     = 0;   % siren carrier phase (rad)
A.sweep  = 0;   % siren sweep position in [0,1)
A.msgPos = 0;   % playback index into the recorded message
end
