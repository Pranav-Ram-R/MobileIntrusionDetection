function P = ids_params()
%IDS_PARAMS  Every tunable constant of the mobile intrusion detection app.
%   Both phones must be built with the same PAIR_ID, MAGIC and UDP_PORT.
%
%   How to read this file (Python / C++ view):
%     * P is a MATLAB "struct", like a Python dict with attribute access or
%       a C++ struct. P.Ts = 0.1 creates the field and assigns it in one go.
%     * Every other file receives P as an argument and reads P.xxx, so this
%       is the single place where numbers are edited (a config file).
%     * The trailing "% ..." on a line is a comment (Python uses #, C++ //).
%     * A ";" after a statement only suppresses printing of the result.
%       Without it MATLAB echoes "P.Ts = 0.1000" to the console.

% ---- timing ------------------------------------------------------------
% The whole app is a fixed-step model, like a clocked circuit. Every block
% runs once per Ts. All "Steps" constants below are counts of these ticks.
P.Ts            = 0.1;      % model base step (s). Audio frame = Ts*Fs samples

% ---- network protocol --------------------------------------------------
% Every UDP datagram is a vector of 16 doubles. Word 1 is a magic number,
% word 16 is the pair id. Receivers drop anything that does not match.
P.MAGIC         = 7331;     % first word of every packet
P.PAIR_ID       = 42;       % last word of every packet. Change per group so
                            % neighbouring teams on the same Wi-Fi don't collide
P.PKT_LEN       = 16;       % doubles per UDP datagram (128 bytes)
P.UDP_PORT      = 25000;    % same port on both phones (send and listen)
P.TYPE_STATUS   = 1;        % Security Node  -> Monitoring Console
P.TYPE_CMD      = 2;        % Monitoring Console -> Security Node
P.txPeriodSteps = 5;        % heartbeat every 0.5 s (plus immediate send on events)
P.linkTimeoutSteps = 50;    % 5 s of silence = link lost
P.linkLostAlarm = true;     % console alerts if an ARMED node goes silent

% ---- node states ------------------------------------------------------
% These act like a C++ enum. MATLAB has no cheap enum inside generated
% code, so plain numbers are used and named here.
P.ST_DISARMED = 0;
P.ST_ARMING   = 1;          % exit delay, baseline being learnt
P.ST_ARMED    = 2;
P.ST_ALARM    = 3;          % breach latched until DISARM or re-ARM

% ---- command codes (console -> node) -----------------------------------
P.CMD_NONE      = 0;
P.CMD_ARM       = 1;
P.CMD_DISARM    = 2;
P.CMD_SIREN_ON  = 3;
P.CMD_SIREN_OFF = 4;

% ---- breach cause bit mask --------------------------------------------
% Powers of two, so several causes can be added into one number
% (light + tilt = 3). Test a bit with bitand(cause, P.CAUSE_LIGHT) > 0.
P.CAUSE_LIGHT    = 1;
P.CAUSE_TILT     = 2;       % orientation sensor
P.CAUSE_MOTION   = 4;       % gyroscope
P.CAUSE_LINKLOST = 8;       % console side only

% ---- intrusion detection ----------------------------------------------
% Debounce counts are numbers of consecutive 0.1 s samples a condition must
% hold before it counts, which rejects single-sample sensor glitches.
P.armDelaySteps = 50;       % 5 s exit delay after ARM
P.baselineSteps = 10;       % baseline = mean of last 1 s of the exit delay
P.lightDeltaAbs = 20;       % trip if lux > base + max(20 lux, 100% of base)
P.lightDeltaRel = 1.0;
P.lightDebounce = 3;        % consecutive samples (0.3 s)
P.tiltThreshDeg = 10;       % pitch / roll change from baseline
P.useAzimuth    = true;
P.azThreshDeg   = 30;       % azimuth uses the magnetometer, so wider band
P.tiltDebounce  = 3;
P.gyroThresh    = 0.6;      % rad/s, magnitude of the angular-rate vector
P.gyroDebounce  = 2;

% ---- audio / light outputs --------------------------------------------
P.Fs            = 44100;    % audio sample rate (Hz)
P.frameLen      = 4410;     % = Ts*Fs, samples handed to the speaker per step
P.sirenLoHz     = 650;      % lowest pitch of the siren sweep
P.sirenHiHz     = 1500;     % highest pitch of the siren sweep
P.sirenSweepSec = 0.5;      % one up+down sweep every 0.5 s ("yelp")
P.sirenAmp      = 0.95;     % peak level, 1.0 = full scale
P.msgGapSteps   = 10;       % 1 s silence between repetitions of the message
P.torchHalfPeriodSteps = 2; % LED 0.2 s on, 0.2 s off (2.5 Hz strobe)

% ---- logging / display -------------------------------------------------
P.tzOffsetSec   = 19800;    % IST (+05:30) for the on-screen timestamps
P.logLen        = 5;        % breach log entries kept on the console
end
