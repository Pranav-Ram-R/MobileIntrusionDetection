function [S, tx, txEn, torch, ui] = node_step(S, active, lux, ori, gyro, gps, epoch, rx, rxSize, P)
%NODE_STEP  One 0.1 s step of the Security Node (Phone A role).
%
%   Inputs
%     active  true when this phone is in Security Node role
%     lux     ambient light (lux)
%     ori     [pitch roll azimuth] in degrees (Orientation block)
%     gyro    [wx wy wz] in rad/s (Gyroscope block)
%     gps     [lat lon alt] (Location Sensor block, zeros when no fix)
%     epoch   wall clock, s since 1970 UTC
%     rx      received UDP packet (P.PKT_LEN doubles), rxSize > 0 if fresh
%
%   Outputs
%     tx, txEn  status packet and "send now" flag
%     torch     1 = camera LED on
%     ui        [state breachSeq cause siren lux tiltDeviationDeg]
%
%   State machine
%     DISARMED --ARM--> ARMING --(5 s, baseline learnt)--> ARMED
%     ARMED --light | tilt | motion--> ALARM (latched, breach logged)
%     any --DISARM--> DISARMED (siren off),  ALARM --ARM--> ARMING (re-arm)
%
%   Python / C++ view: this is a pure function new_state = f(state, inputs).
%   S is passed in and returned (MATLAB passes by value, like a copy).
%   Nothing is stored between calls except what is inside S, so the same
%   function can drive two independent phones and can be unit tested by
%   simply calling it in a loop. Blocks below run top to bottom each step.

% ---- default outputs, so every path through the function defines them ----
tx    = zeros(P.PKT_LEN, 1);                  % 16x1 column of zeros (np.zeros(16))
txEn  = false;                                % "send the packet this step?"
torch = 0;                                    % LED off unless the strobe block says otherwise

% ---- not in the node role: reset all state and do nothing ----
% The same app runs in both roles. When the Button selects console mode
% this function is called with active = false and just keeps S at power-on.
if ~active
    S  = node_init();
    ui = [S.state, S.breachSeq, S.cause, S.siren, 0, 0];   % [a, b, c] builds a row vector
    return;
end

% ---- unpack inputs into plain scalar doubles ----
% Simulink signals can be single, int or vector. Forcing double scalars
% here keeps the arithmetic below uniform. MATLAB indexing is 1-based.
lux   = double(lux(1));
pitch = double(ori(1));
roll  = double(ori(2));
az    = double(ori(3));                       % azimuth = compass heading
g     = double(gyro(:));                      % (:) forces a column vector
gmag  = sqrt(g(1)^2 + g(2)^2 + g(3)^2);       % length of the angular-rate vector, rad/s
forceTx = false;                              % set when an event needs an immediate packet

% ---- keep the last valid GPS fix (the block outputs zeros without a fix) ----
% "|| " and "&&" short-circuit. gps(1:3) is a slice, and isfinite rejects NaN/Inf.
if (gps(1) ~= 0 || gps(2) ~= 0) && all(isfinite(gps(1:3)))   % "~=" means not equal (!=)
    S.gps = [double(gps(1)), double(gps(2)), double(gps(3))];
end

% ---- remote commands. Applied once per new sequence number. The console
%      keeps re-sending its latest command, so a lost datagram only delays it.
if packet_ok(rx, rxSize, P.TYPE_CMD, P)       % valid command packet from our console?
    seq  = rx(3);                             % rx(3) = sequence number, rx(4) = command code
    code = rx(4);
    if seq ~= S.lastCmdSeq                    % new sequence number = new command
        S.lastCmdSeq = seq;                   % remember it so repeats are ignored (idempotent)
        forceTx = true;                       % acknowledge promptly
        if code == P.CMD_ARM
            % Ignore ARM if already arming or armed, so a repeated ARM cannot restart the exit delay.
            if S.state ~= P.ST_ARMING && S.state ~= P.ST_ARMED
                S = start_arming(S);          % local helper, defined at the bottom of this file
            end
        elseif code == P.CMD_DISARM
            S.state = P.ST_DISARMED;          % works from any state, also clears the alarm
            S.siren = 0;
        elseif code == P.CMD_SIREN_ON
            S.siren = 1;                      % the siren and LED are driven by this flag below
        elseif code == P.CMD_SIREN_OFF
            S.siren = 0;
        end
    end
end

% ---- detection state machine ----
if S.state == P.ST_ARMING
    % ARMING: the owner has 5 s to leave. In the last 1 s the phone learns
    % what "normal" looks like (baseline), so later changes are relative.
    S.armCtr = S.armCtr + 1;
    if S.armCtr > P.armDelaySteps - P.baselineSteps
        % Last second only: accumulate sums for the baseline average.
        S.accN     = S.accN + 1;
        S.accLux   = S.accLux + lux;
        S.accPitch = S.accPitch + pitch;
        S.accRoll  = S.accRoll + roll;
        S.accAzS   = S.accAzS + sind(az);     % sind/cosd take degrees
        S.accAzC   = S.accAzC + cosd(az);
    end
    if S.armCtr >= P.armDelaySteps && S.accN > 0
        % Exit delay over: turn sums into means and start watching.
        S.baseLux   = S.accLux / S.accN;
        S.basePitch = S.accPitch / S.accN;
        S.baseRoll  = S.accRoll / S.accN;
        S.baseAz    = atan2d(S.accAzS, S.accAzC);   % circular mean, avoids the 359/1 deg trap
        S.cntLight = 0; S.cntTilt = 0; S.cntGyro = 0;   % start with clean debounce counters
        S.state = P.ST_ARMED;
        forceTx = true;                       % tell the console right away
    end
    S.tiltDev = 0;

elseif S.state == P.ST_ARMED
    % ARMED: three independent detectors, each with its own debounce counter.

    % -- light: drawer / cabinet opened --
    % Threshold = baseline + the larger of an absolute and a relative step.
    % The absolute part protects a dark room (baseline near 0 lux) from
    % noise, the relative part scales with a bright room.
    thr = S.baseLux + max(P.lightDeltaAbs, P.lightDeltaRel*S.baseLux);
    if lux > thr
        S.cntLight = S.cntLight + 1;          % one more consecutive bright sample
    else
        S.cntLight = 0;                       % streak broken, start over
    end

    % -- orientation: phone picked up or tilted --
    % wrap180 keeps angle differences in [-180, 180) so a compass wrap is not a jump.
    dP  = abs(wrap180(pitch - S.basePitch));
    dR  = abs(wrap180(roll  - S.baseRoll));
    dAz = abs(wrap180(az    - S.baseAz));
    S.tiltDev = max(dP, dR);                  % shown on the UI as a diagnostic
    tilted = (dP > P.tiltThreshDeg) || (dR > P.tiltThreshDeg) || ...
             (P.useAzimuth && dAz > P.azThreshDeg);    % "..." continues a statement on the next line
    if tilted
        S.cntTilt = S.cntTilt + 1;
    else
        S.cntTilt = 0;
    end

    % -- gyroscope: phone being moved / tampered with --
    if gmag > P.gyroThresh
        S.cntGyro = S.cntGyro + 1;
    else
        S.cntGyro = 0;
    end

    % -- combine: a detector fires after enough consecutive samples --
    % Adding the CAUSE_* values builds the bit mask (light=1, tilt=2, motion=4).
    cause = 0;
    if S.cntLight >= P.lightDebounce, cause = cause + P.CAUSE_LIGHT;  end
    if S.cntTilt  >= P.tiltDebounce,  cause = cause + P.CAUSE_TILT;   end
    if S.cntGyro  >= P.gyroDebounce,  cause = cause + P.CAUSE_MOTION; end

    % -- latch the breach: ALARM stays until a DISARM or a new ARM command --
    if cause > 0
        S.state       = P.ST_ALARM;
        S.breachSeq   = S.breachSeq + 1;      % unique breach number, console uses it to spot new ones
        S.breachEpoch = epoch;                % timestamp of the breach
        S.cause       = cause;
        S.breachLat   = S.gps(1);             % where the phone was when it happened
        S.breachLon   = S.gps(2);
        forceTx = true;                       % alert the console immediately
    end
else
    % DISARMED or ALARM: nothing to detect, just clear the diagnostic.
    S.tiltDev = 0;
end

% ---- camera LED strobe while the siren is on ----
% torchCtr counts steps. Dividing by torchHalfPeriodSteps and taking the
% parity gives 2 steps on, 2 steps off (a square wave at 2.5 Hz).
if S.siren > 0
    torch = double(mod(floor(S.torchCtr / P.torchHalfPeriodSteps), 2) == 0);
    S.torchCtr = S.torchCtr + 1;
else
    S.torchCtr = 0;                           % restart the pattern at the next siren start
end

% ---- status packet: heartbeat every txPeriodSteps, immediately on events ----
% Packet layout (1-based word numbers, 16 doubles in total):
%   1 MAGIC  2 TYPE  3 state  4 breachSeq  5 breachEpoch  6 cause
%   7 breachLat  8 breachLon  9-11 live lat/lon/alt  12 siren
%   13 last command seq (the ack)  14 lux  15 epoch now  16 PAIR_ID
S.txCtr = S.txCtr + 1;
if forceTx || S.txCtr >= P.txPeriodSteps
    S.txCtr = 0;
    txEn = true;                              % tells the UDP Send block to transmit this step
    tx(1)  = P.MAGIC;
    tx(2)  = P.TYPE_STATUS;
    tx(3)  = S.state;
    tx(4)  = S.breachSeq;
    tx(5)  = S.breachEpoch;
    tx(6)  = S.cause;
    tx(7)  = S.breachLat;
    tx(8)  = S.breachLon;
    tx(9)  = S.gps(1);           % live position, useful if the phone is taken
    tx(10) = S.gps(2);
    tx(11) = S.gps(3);
    tx(12) = S.siren;
    tx(13) = S.lastCmdSeq;       % lets the console confirm delivery
    tx(14) = lux;
    tx(15) = epoch;
    tx(16) = P.PAIR_ID;
end

% ---- values for the on-screen Data Display blocks ----
ui = [S.state, S.breachSeq, S.cause, S.siren, lux, S.tiltDev];
end

% -------------------------------------------------------------------------
function S = start_arming(S)
%START_ARMING  Local helper: begin the exit delay and clear the old baseline sums.
%   A function placed after the main one in the same file is only visible
%   inside this file, like a static function in C++ or a private helper.
S.state    = 1;              % P.ST_ARMING
S.armCtr   = 0;              % restart the exit delay
S.accN     = 0;              % empty the baseline accumulators
S.accLux   = 0;
S.accPitch = 0;
S.accRoll  = 0;
S.accAzS   = 0;
S.accAzC   = 0;
S.cntLight = 0;              % and the debounce counters
S.cntTilt  = 0;
S.cntGyro  = 0;
S.cause    = 0;              % forget the cause of an earlier alarm
end
