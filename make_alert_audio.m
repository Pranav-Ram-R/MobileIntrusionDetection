function make_alert_audio(wavFile)
%MAKE_ALERT_AUDIO  Convert the recorded alert message into alert_message.mat.
%   make_alert_audio                  uses alert_message.wav in this folder
%   make_alert_audio('myvoice.wav')   uses your own recording (any rate,
%                                     mono or stereo, up to 6 s is kept)
%   The AudioEngine block embeds the samples (int16, 44.1 kHz mono) into the
%   app at build time, so re-run this and rebuild the app after changing it.
%
%   This is an offline helper script (run it by hand in MATLAB). The phone
%   never runs it. Its only product is the file alert_message.mat holding
%   one variable, msg, a vector of 16 bit samples.

% ---- locate this folder and read the constants ----
here = fileparts(mfilename('fullpath'));      % folder containing this .m file (like Path(__file__).parent)
P = ids_params();
if nargin < 1                                 % nargin = number of arguments given (optional argument)
    wavFile = fullfile(here, 'alert_message.wav');   % fullfile joins path parts (os.path.join)
end

if isfile(wavFile)
    % ---- load the recording and bring it to 44.1 kHz mono ----
    [y, fs] = audioread(wavFile);             % y = samples in [-1,1], fs = original rate
    y = mean(y, 2);                           % to mono (average across the channel columns)
    if fs ~= P.Fs                             % resample (no toolbox needed)
        tIn  = (0:numel(y)-1)'/fs;            % time stamp of each input sample, ' = transpose to a column
        tOut = (0:1/P.Fs:tIn(end))';          % wanted time stamps at 44.1 kHz (start:step:stop)
        y = interp1(tIn, y, tOut, 'pchip');   % smooth interpolation onto the new grid
    end
    src = wavFile;                            % remember the source for the printout
else
    % fallback: a two-tone "ding-dong" chime so the build never breaks
    t = (0:round(1.6*P.Fs)-1)'/P.Fs;          % 1.6 s time axis
    y = [sin(2*pi*880*t(t < 0.8)).*exp(-3*t(t < 0.8)); ...     % first 0.8 s: 880 Hz, decaying
         sin(2*pi*660*t(t < 0.8)).*exp(-3*t(t < 0.8))];        % second 0.8 s: 660 Hz, decaying
    % ".*" is element-wise multiply (NumPy "*"). Plain "*" would be a matrix product.
    % t(t < 0.8) is a boolean mask index, the same as t[t < 0.8] in NumPy.
    src = 'synthesised chime (alert_message.wav not found)';
end

% ---- keep at most 6 s ----
y = y(1:min(end, 6*P.Fs));                    % "end" = last index, so this is y[:6*Fs]

% ---- trim leading / trailing silence ----
idx = find(abs(y) > 0.01*max(abs(y)));        % indices of samples above 1% of the peak
if ~isempty(idx)
    y = y(max(1, idx(1) - 200):min(end, idx(end) + 2000));    % keep a short margin around the sound
end

% ---- normalise to 90% of full scale and convert to 16 bit ----
y = 0.9 * y / max(abs(y));
msg = int16(round(y * 32767));                        %#ok<NASGU>

% ---- save as alert_message.mat. The build script loads it into the app. ----
save(fullfile(here, 'alert_message.mat'), 'msg');     % like pickle.dump of the variable "msg"
fprintf('alert_message.mat: %.2f s from %s\n', numel(y)/P.Fs, src);
end
