function S = node_init()
%NODE_INIT  Power-on state of the Security Node role.
%   S holds every variable the node needs to remember between 0.1 s steps.
%   Think of it as the register file of a circuit, or the member variables
%   of a C++ class. node_step takes S in and returns the updated S, so there
%   is no hidden global state. It also resets cleanly whenever the phone
%   leaves the node role (node_step calls this again).

% ---- state machine ----
S.state       = 0;           % P.ST_DISARMED
S.armCtr      = 0;           % steps spent in the ARMING exit delay

% ---- baseline accumulators (sums over the last second of ARMING) ----
S.accN        = 0;           % baseline accumulators, how many samples were added
S.accLux      = 0;
S.accPitch    = 0;
S.accRoll     = 0;
S.accAzS      = 0;           % azimuth averaged on the unit circle
S.accAzC      = 0;           % (sum of sin and cos, so 359 and 1 deg average to 0)

% ---- baseline values (what "normal" looks like once ARMED) ----
S.baseLux     = 0;
S.basePitch   = 0;
S.baseRoll    = 0;
S.baseAz      = 0;

% ---- debounce counters (consecutive samples over threshold) ----
S.cntLight    = 0;
S.cntTilt     = 0;
S.cntGyro     = 0;

% ---- last breach record, sent to the console ----
S.breachSeq   = 0;           % increments on every breach
S.breachEpoch = 0;           % when it happened (s since 1970 UTC)
S.cause       = 0;           % bit mask of CAUSE_* values
S.breachLat   = 0;           % where it happened
S.breachLon   = 0;

% ---- misc ----
S.gps         = zeros(1, 3); % last valid fix [lat lon alt], a 1x3 row of zeros
S.siren       = 0;           % 1 while the siren and LED should run
S.lastCmdSeq  = -1;          % sequence number of the last command applied
S.txCtr       = 0;           % steps since the last status packet
S.torchCtr    = 0;           % step counter driving the LED strobe
S.tiltDev     = 0;           % diagnostics, largest pitch/roll change (deg)
end
