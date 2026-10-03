function [A, audio] = audio_step(A, sirenOn, alertOn, msg, P)
%AUDIO_STEP  Produce one frame (P.frameLen x 2 int16) for the Audio Playback block.
%   sirenOn  node role: loud swept siren (650-1500 Hz yelp, soft-clipped)
%   alertOn  console role: loop the recorded alert message with a 1 s gap
%
%   Called once per 0.1 s step. Each call must return exactly 4410 samples
%   (0.1 s at 44.1 kHz) and continue the waveform where the last call
%   stopped. That is why the phase and position live in the state A.
%   Both sources are added into the same buffer y, so they can overlap.
N = P.frameLen;                               % samples per frame
y = zeros(N, 1);                              % mono accumulator as a column vector, float in [-1, 1]

% ---- siren: phase-accumulator oscillator, frequency sweeps up and down ----
% Like a DDS in Verilog. Every sample the phase advances by 2*pi*f/Fs, and
% f itself ramps lo -> hi -> lo following a triangle wave.
if sirenOn > 0
    dSweep = 1 / (P.Fs * P.sirenSweepSec);    % sweep position advance per sample
    for n = 1:N                               % MATLAB loops are 1..N inclusive
        A.sweep = A.sweep + dSweep;
        if A.sweep >= 1
            A.sweep = A.sweep - 1;            % wrap sweep position into [0,1)
        end
        tri = 1 - abs(2*A.sweep - 1);                 % 0 -> 1 -> 0
        f   = P.sirenLoHz + (P.sirenHiHz - P.sirenLoHz)*tri;   % instantaneous pitch (Hz)
        A.ph = A.ph + 2*pi*f/P.Fs;            % advance carrier phase
        if A.ph >= 2*pi
            A.ph = A.ph - 2*pi;               % keep the phase small so it stays accurate
        end
        v = 1.6*sin(A.ph);                            % soft square = louder
        y(n) = y(n) + P.sirenAmp*min(max(v, -1), 1);  % clip to +-1, scale to sirenAmp
    end
end

% ---- recorded alert message, looped with a silent gap between repeats ----
% msgPos counts samples since the loop began. It runs over the message
% length L plus the gap, then returns to 0 so the message repeats.
L = numel(msg);                               % message length in samples
if alertOn > 0 && L > 0
    period = L + P.msgGapSteps*N;             % message + silence, in samples
    for n = 1:N
        if A.msgPos < L
            y(n) = y(n) + double(msg(A.msgPos + 1))/32768;   % int16 -> [-1,1), +1 because 1-based
        end
        A.msgPos = A.msgPos + 1;
        if A.msgPos >= period
            A.msgPos = 0;                     % loop
        end
    end
else
    A.msgPos = 0;                                     % restart from the top next time
end

% ---- final clip and conversion to what the Audio Playback block wants ----
y = min(max(y, -1), 1);                       % hard limit so the sum cannot overflow int16
s = int16(round(y*32767));                    % float -> 16 bit PCM
audio = [s, s];                               % 4410x2 matrix, same signal on left and right
end
