function [C, tx, txEn, uiStatus, uiBreach, uiLive, uiLog] = console_step(C, active, btnArm, btnSiren, btnAck, epoch, rx, rxSize, P)
%CONSOLE_STEP  One 0.1 s step of the Monitoring Console (Phone B role).
%
%   The Android Button widget is a toggle, so every change of its state is
%   treated as one tap.
%     btnArm    tap -> ARM if the node is disarmed, DISARM otherwise
%     btnSiren  tap -> siren ON if it is off, OFF otherwise
%     btnAck    tap -> silence the audible alert
%
%   Outputs (for Data Display widgets)
%     uiStatus  [linkUp nodeState siren alert alertCause]
%     uiBreach  [breachSeq dateYYYYMMDD timeHHMMSS cause lat lon]
%     uiLive    [lat lon alt nodeLux secondsSinceLastPacket]
%     uiLog     last P.logLen breach times (HHMMSS), newest first
%
%   Like node_step this is a pure function new_state = f(state, inputs).
%   Blocks run top to bottom: buttons, receive, supervise, acknowledge,
%   build commands, send, display. The console never touches the sensors.

% ---- default outputs ----
tx   = zeros(P.PKT_LEN, 1);                   % 16x1 command packet buffer
txEn = false;                                 % "send this step?"

% ---- not in the console role: reset and output zeros ----
if ~active
    C = console_init(P.logLen);
    uiStatus = zeros(1, 5);
    uiBreach = zeros(1, 6);
    uiLive   = zeros(1, 5);
    uiLog    = zeros(1, P.logLen);
    return;
end

% ---- button edge detection ----
% Toggle buttons give a level (0 or 1), not an event. A change from the
% previous sample is one tap. prev = -1 means "no previous sample yet", so
% the very first sample can never count as a tap.
a = double(btnArm   > 0);                     % comparison gives logical, double() makes 0/1
s = double(btnSiren > 0);
k = double(btnAck   > 0);
armTap   = (C.prevArm   >= 0) && (a ~= C.prevArm);
sirenTap = (C.prevSiren >= 0) && (s ~= C.prevSiren);
ackTap   = (C.prevAck   >= 0) && (k ~= C.prevAck);
C.prevArm = a;  C.prevSiren = s;  C.prevAck = k;    % remember for the next step

% ---- status from the node ----
if packet_ok(rx, rxSize, P.TYPE_STATUS, P)
    % Valid packet: copy the node's report into local memory. rx(n) is the
    % n-th word of the layout documented in node_step.
    C.everRx       = true;
    C.stepsSinceRx = 0;                       % heard from the node just now
    C.nodeState    = rx(3);
    C.breachSeq    = rx(4);
    C.breachEpoch  = rx(5);
    C.cause        = rx(6);
    C.bLat         = rx(7);
    C.bLon         = rx(8);
    C.gps          = [rx(9), rx(10), rx(11)];
    C.siren        = rx(12);
    C.nodeCmdAck   = rx(13);                  % which command the node has applied
    C.nodeLux      = rx(14);
    C.linkLostAcked = false;                  % link is alive, so a future loss alerts again
    if C.alertCause == P.CAUSE_LINKLOST
        C.alert = 0;                          % link is back
        C.alertCause = 0;
    end

    % -- breach log (timestamp from the node's clock, console clock as fallback) --
    % The node repeats the same breachSeq in every heartbeat, so only a
    % number higher than the last logged one is a new breach.
    if C.breachSeq > C.lastLogged
        C.lastLogged = C.breachSeq;
        tb = C.breachEpoch;
        if tb <= 0
            tb = epoch;                       % node had no clock, use ours
        end
        [ymd, hms] = epoch_to_civil(tb, P.tzOffsetSec);
        % Insert at the front and drop the oldest: new row = [newest, old(1:end-1)].
        % "end" inside an index means the last element.
        C.logHms = [hms, C.logHms(1:end-1)];
        C.logYmd = [ymd, C.logYmd(1:end-1)];
    end

    % -- raise the alarm for an unacknowledged breach --
    if C.nodeState == P.ST_ALARM && C.breachSeq > C.ackSeq
        C.alert = 1;
        C.alertCause = C.cause;
    end
    % -- stop it once the node leaves ALARM (disarmed or re-armed) --
    if C.nodeState ~= P.ST_ALARM && C.alert > 0 && C.alertCause ~= P.CAUSE_LINKLOST
        C.alert = 0;
        C.alertCause = 0;
        C.ackSeq = C.breachSeq;
    end
else
    C.stepsSinceRx = C.stepsSinceRx + 1;      % no valid packet this step
end

% ---- is the link up? (heard within the timeout window) ----
linkUp = C.everRx && (C.stepsSinceRx < P.linkTimeoutSteps);

% ---- link supervision: an armed node that goes silent is suspicious ----
% Someone may have switched the phone off or blocked the Wi-Fi. "..." is
% the line continuation, so the if condition continues on the next line.
if P.linkLostAlarm && C.everRx && ~linkUp && ~C.linkLostAcked && ...
        (C.nodeState == P.ST_ARMED || C.nodeState == P.ST_ALARM)
    C.alert = 1;
    C.alertCause = P.CAUSE_LINKLOST;
end

% ---- acknowledge ----
% Silences the alert here only. It does not disarm the node.
if ackTap
    C.ackSeq = C.breachSeq;                   % everything up to now is acknowledged
    if C.alertCause == P.CAUSE_LINKLOST
        C.linkLostAcked = true;               % do not re-raise until the link returns
    end
    C.alert = 0;
    C.alertCause = 0;
end

% ---- remote commands. Toggle decisions use the pending intent if the node
%      has not yet confirmed the previous command, so double taps behave.
% Example: tap ARM twice quickly. The node has not reported ARMING yet, so
% looking at nodeState alone would send ARM twice. With the intent the
% second tap correctly becomes DISARM.
newCmd = false;
if armTap
    if C.armIntentSeq > C.nodeCmdAck          % previous arm/disarm command not yet confirmed
        armedNow = (C.armIntent == P.CMD_ARM);
    else
        armedNow = (C.nodeState == P.ST_ARMING || C.nodeState == P.ST_ARMED || ...
                    C.nodeState == P.ST_ALARM);
    end
    C.cmdSeq = C.cmdSeq + 1;                  % every new command gets a new number
    if armedNow
        C.cmdCode = P.CMD_DISARM;
    else
        C.cmdCode = P.CMD_ARM;
    end
    C.armIntentSeq = C.cmdSeq;
    C.armIntent    = C.cmdCode;
    newCmd = true;
end
if sirenTap
    if C.sirenIntentSeq > C.nodeCmdAck        % same idea for the siren
        sirenNow = (C.sirenIntent == P.CMD_SIREN_ON);
    else
        sirenNow = (C.siren > 0);
    end
    C.cmdSeq = C.cmdSeq + 1;
    if sirenNow
        C.cmdCode = P.CMD_SIREN_OFF;
    else
        C.cmdCode = P.CMD_SIREN_ON;
    end
    C.sirenIntentSeq = C.cmdSeq;
    C.sirenIntent    = C.cmdCode;
    newCmd = true;
end

% ---- command packet: latest command re-sent every heartbeat ----
% The node ignores repeats of an old sequence number, so re-sending is
% harmless and makes delivery survive lost datagrams (UDP has no retry).
% Words: 1 MAGIC, 2 TYPE_CMD, 3 seq, 4 code, 5 ackSeq, 6 epoch, 16 PAIR_ID.
C.txCtr = C.txCtr + 1;
if newCmd || C.txCtr >= P.txPeriodSteps
    C.txCtr = 0;
    txEn  = true;
    tx(1) = P.MAGIC;
    tx(2) = P.TYPE_CMD;
    tx(3) = C.cmdSeq;
    tx(4) = C.cmdCode;
    tx(5) = C.ackSeq;
    tx(6) = epoch;
    tx(P.PKT_LEN) = P.PAIR_ID;
end

% ---- values for the on-screen Data Display blocks ----
[bYmd, bHms] = epoch_to_civil(C.breachEpoch, P.tzOffsetSec);   % last breach as date and time numbers
uiStatus = [double(linkUp), C.nodeState, C.siren, C.alert, C.alertCause];
uiBreach = [C.breachSeq, bYmd, bHms, C.cause, C.bLat, C.bLon];
uiLive   = [C.gps(1), C.gps(2), C.gps(3), C.nodeLux, C.stepsSinceRx*P.Ts];   % last item is seconds of silence
uiLog    = C.logHms;
end
