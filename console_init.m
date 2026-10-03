function C = console_init(logLen)
%CONSOLE_INIT  Power-on state of the Monitoring Console role.
%   C is the console's memory between 0.1 s steps (see node_init for the
%   idea). logLen is the number of breach times kept for the log display.

% ---- last known state of the node, copied from its status packets ----
C.nodeState    = -1;          % -1 = never heard from the node
C.breachSeq    = 0;           % latest breach number reported by the node
C.breachEpoch  = 0;           % when it happened (node clock)
C.cause        = 0;           % cause bit mask of that breach
C.bLat         = 0;           % GPS where the breach happened
C.bLon         = 0;
C.gps          = zeros(1, 3); % node's live position [lat lon alt]
C.siren        = 0;           % is the node's siren on
C.nodeCmdAck   = -1;          % last command seq the node confirmed
C.nodeLux      = 0;

% ---- link supervision ----
C.everRx       = false;       % has any valid packet arrived yet
C.stepsSinceRx = 0;           % silence counter, in 0.1 s steps

% ---- local alert state ----
C.alert        = 0;           % 1 = audible alert playing
C.alertCause   = 0;
C.ackSeq       = 0;           % breaches up to this seq are acknowledged
C.linkLostAcked = false;      % user silenced a link-lost alert

% ---- outgoing command bookkeeping ----
C.cmdSeq       = 0;           % sequence number of the latest command
C.cmdCode      = 0;           % and its code (re-sent until the node echoes the seq)
C.armIntentSeq = -1;          % pending ARM/DISARM not yet confirmed
C.armIntent    = 0;
C.sirenIntentSeq = -1;        % same for the siren toggle
C.sirenIntent  = 0;

% ---- button edge detection ----
C.prevArm      = -1;          % -1 = first sample, no edge
C.prevSiren    = -1;
C.prevAck      = -1;

% ---- misc ----
C.txCtr        = 0;           % steps since the last command packet
C.lastLogged   = 0;           % highest breach number already written to the log
C.logHms       = zeros(1, logLen);   % breach times HHMMSS, newest first
C.logYmd       = zeros(1, logLen);   % matching dates YYYYMMDD
end
