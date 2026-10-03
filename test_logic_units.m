function results = test_logic_units()
%TEST_LOGIC_UNITS  Unit tests for the node / console / audio / clock logic.
%   Runs in plain MATLAB. Prints a PASS/FAIL line per check and errors at
%   the end if anything failed.
%
%   Python / C++ view: this is a pytest or GoogleTest file written as one
%   long script. There is no test framework, each check calls the helper
%   add(...) which records the result and prints it. The step functions are
%   pure (state in, state out), so a test just feeds inputs one step at a
%   time and inspects the returned state S or C.
%
%   Sections: 1 clock, 2 node, 3 console, 4 audio.
P = ids_params();
results = struct('name', {}, 'pass', {});     % empty struct array, a list of {name, pass} records

% ======================================================================
% 1. clock conversion against MATLAB datetime
% Compare the hand written calendar maths with MATLAB's own datetime for a
% spread of timestamps, including 2000-02-29 (leap day, epoch 951782400).
rng(1);                                       % fixed random seed so any noise below is repeatable
ok = true;
for e = [0.5e9, 1.0e9, 1.7e9 + 12345, 1790000000 + (0:7:400)*86400 + 3601, 951782400]   % "for" over a row vector, one value per loop
    [ymd, hms] = epoch_to_civil(e, P.tzOffsetSec);
    % Reference answer from datetime, shifted to the same timezone offset.
    d = datetime(floor(e), 'ConvertFrom', 'posixtime', 'TimeZone', 'UTC') + seconds(P.tzOffsetSec);
    ref_ymd = year(d)*10000 + month(d)*100 + day(d);
    ref_hms = hour(d)*10000 + minute(d)*100 + floor(second(d));
    ok = ok && ymd == ref_ymd && hms == ref_hms;    % stays true only if every timestamp matches
end
results = add(results, 'epoch_to_civil matches datetime (incl. leap day 2000-02-29)', ok);

% ======================================================================
% 2. node: arming, baseline and light breach
S = node_init();
% "quiet" is a lambda that runs one node step with fixed GPS and clock.
% Arguments: state, received packet, lux, [pitch roll azimuth], gyro.
% Its outputs are the same as node_step: [S, tx, txEn, torch, ui].
quiet = @(S, cmd, lux, ori, gyro) node_step(S, true, lux, ori, gyro, [23.2 72.6 50], 1.79e9, cmd, 1, P);
none  = zeros(P.PKT_LEN, 1);                  % an all zero packet, fails the MAGIC check, so it means "nothing"
% "~" in the output list means "ignore this output" (Python's "_").
[S, ~, ~, ~, ~] = quiet(S, cmdpkt(P, 0, P.CMD_NONE), 0.5, [0 0 90], [0 0 0]);
results = add(results, 'node starts DISARMED, NONE command ignored', S.state == P.ST_DISARMED);

% Send ARM (sequence 1). Expect ARMING, plus an immediate status packet
% whose word 13 echoes sequence 1 as the acknowledgement.
[S, tx, txEn] = quiet(S, cmdpkt(P, 1, P.CMD_ARM), 0.5, [0 0 90], [0 0 0]);
results = add(results, 'ARM command -> ARMING, status sent at once with cmd ack', ...
    S.state == P.ST_ARMING && txEn && tx(13) == 1);

% Run the exit delay with a little sensor noise (randn). Stop 2 steps early.
% The ARM command is re-sent each step as the real console does, and the
% node must ignore the repeats.
for n = 1:P.armDelaySteps - 2
    [S, ~, ~, ~, ~] = quiet(S, cmdpkt(P, 1, P.CMD_ARM), 0.5 + 0.1*randn, [0.3*randn 0.3*randn 90], [0 0 0]);
end
results = add(results, 'still ARMING just before the exit delay ends', S.state == P.ST_ARMING);
[S, ~, ~, ~, ~] = quiet(S, none, 0.5, [0 0 90], [0 0 0]);
results = add(results, 'ARMED after 5 s, baseline learnt', S.state == P.ST_ARMED && abs(S.baseLux - 0.5) < 0.2);

% repeated ARM (same seq) must not restart arming
[S, ~, ~, ~, ~] = quiet(S, cmdpkt(P, 1, P.CMD_ARM), 0.5, [0 0 90], [0 0 0]);
results = add(results, 'duplicate command seq is ignored', S.state == P.ST_ARMED);

% own status broadcast (TYPE_STATUS) and foreign pair must be ignored
% "own" has a DISARM code but the wrong type, "bad" has the wrong pair id.
% If either was accepted the node would drop out of ARMED.
own = zeros(P.PKT_LEN,1); own(1) = P.MAGIC; own(2) = P.TYPE_STATUS; own(4) = P.CMD_DISARM; own(3)= 99; own(16) = P.PAIR_ID;
[S, ~, ~, ~, ~] = quiet(S, own, 0.5, [0 0 90], [0 0 0]);
bad = cmdpkt(P, 50, P.CMD_DISARM); bad(16) = P.PAIR_ID + 1;
[S, ~, ~, ~, ~] = quiet(S, bad, 0.5, [0 0 90], [0 0 0]);
results = add(results, 'own broadcasts and other pairs ignored', S.state == P.ST_ARMED);

% light spike of 2 samples is debounced, 3 samples trips
% Two bright samples then a dark one resets the counter, so no alarm.
[S, ~, ~, ~, ~] = quiet(S, none, 80, [0 0 90], [0 0 0]);
[S, ~, ~, ~, ~] = quiet(S, none, 80, [0 0 90], [0 0 0]);
[S, ~, ~, ~, ~] = quiet(S, none, 0.5, [0 0 90], [0 0 0]);
results = add(results, 'two-sample light glitch does not trip', S.state == P.ST_ARMED);
% Now 3 consecutive bright samples (2 here plus the explicit call below).
for n = 1:2
    [S, ~, ~, ~, ~] = quiet(S, none, 80, [0 0 90], [0 0 0]);
end
% node_step is called directly here, because the clock value matters: the
% breach time must be 1790000123.
[S, tx, txEn, ~, ui] = node_step(S, true, 80, [0 0 90], [0 0 0], [23.2 72.6 50], 1790000123, none, 0, P);
results = add(results, 'third bright sample -> ALARM, light cause, immediate packet', ...
    S.state == P.ST_ALARM && S.cause == P.CAUSE_LIGHT && txEn && tx(3) == P.ST_ALARM && tx(4) == 1);
results = add(results, 'breach packet carries time and GPS', ...
    tx(5) == 1790000123 && tx(7) == 23.2 && tx(8) == 72.6 && ui(2) == 1);

% siren + torch strobe, then DISARM kills both
% Collect 8 consecutive LED values, expect 1 1 0 0 1 1 0 0 (2 steps each).
[S, ~, ~, torch1] = quiet(S, cmdpkt(P, 2, P.CMD_SIREN_ON), 0.5, [0 0 90], [0 0 0]);
tp = torch1;
for n = 1:7
    [S, ~, ~, t] = quiet(S, none, 0.5, [0 0 90], [0 0 0]);
    tp(end+1) = t; %#ok<AGROW>               % append to a growing array (list.append)
end
results = add(results, 'siren ON -> LED strobes 0.2 s on / 0.2 s off', isequal(tp, [1 1 0 0 1 1 0 0]));
[S, ~, ~, t] = quiet(S, cmdpkt(P, 3, P.CMD_DISARM), 0.5, [0 0 90], [0 0 0]);
results = add(results, 'DISARM -> DISARMED, siren and LED off', S.state == P.ST_DISARMED && S.siren == 0 && t == 0);

% motion trip after re-arm
% Arm again (sequence 4) with the phone slightly tilted [2 1 90], let the
% exit delay finish, then shake it (gyro 0.9 rad/s) for 2 samples.
[S, ~, ~, ~, ~] = quiet(S, cmdpkt(P, 4, P.CMD_ARM), 0.5, [2 1 90], [0 0 0]);
for n = 1:P.armDelaySteps
    [S, ~, ~, ~, ~] = quiet(S, none, 0.5, [2 1 90], [0 0 0]);
end
[S, ~, ~, ~, ~] = quiet(S, none, 0.5, [2 1 90], [0.9 0.2 0]);
[S, ~, ~, ~, ~] = quiet(S, none, 0.5, [2 1 90], [0.9 0.2 0]);
results = add(results, 'gyro > 0.6 rad/s for 0.2 s -> ALARM (motion)', ...
    S.state == P.ST_ALARM && bitand(S.cause, P.CAUSE_MOTION) > 0 && S.breachSeq == 2);

% tilt trip, azimuth wrap-around must NOT trip (359 -> 1 deg is a 2 deg change)
% Fresh node, baseline azimuth 359. A naive subtraction would give 358 deg
% and trip. wrap180 turns it into -2 deg.
S = node_init();
[S, ~, ~, ~, ~] = quiet(S, cmdpkt(P, 1, P.CMD_ARM), 0.5, [0 0 359], [0 0 0]);
for n = 1:P.armDelaySteps
    [S, ~, ~, ~, ~] = quiet(S, none, 0.5, [0 0 359], [0 0 0]);
end
for n = 1:5
    [S, ~, ~, ~, ~] = quiet(S, none, 0.5, [0 0 1], [0 0 0]);
end
results = add(results, 'azimuth 359 -> 1 deg does not trip (wrap-around)', S.state == P.ST_ARMED);
% A real tilt (pitch +15 deg, threshold is 10) held for 3 samples trips.
for n = 1:3
    [S, ~, ~, ~, ~] = quiet(S, none, 0.5, [15 0 1], [0 0 0]);
end
results = add(results, 'pitch change of 15 deg for 0.3 s -> ALARM (tilt)', ...
    S.state == P.ST_ALARM && bitand(S.cause, P.CAUSE_TILT) > 0);

% last good GPS is kept when the fix drops out
% First step has a fix, second step reports zeros (no fix).
S = node_init();
[S] = node_step(S, true, 1, [0 0 0], [0 0 0], [23.2 72.6 50], 1, none, 0, P);
[S] = node_step(S, true, 1, [0 0 0], [0 0 0], [0 0 0], 1, none, 0, P);
results = add(results, 'last valid GPS fix retained', isequal(S.gps, [23.2 72.6 50]));

% inactive role resets and stays silent
[S, ~, txEn] = node_step(S, false, 1, [0 0 0], [0 0 0], [0 0 0], 1, none, 0, P);
results = add(results, 'inactive node is reset and does not transmit', ~txEn && S.state == 0);

% ======================================================================
% 3. console
C = console_init(P.logLen);
% "cs" runs one console step with a fixed clock. Arguments: state, the
% three button levels (arm, siren, ack), received packet, packet size.
cs = @(C, a, s, k, rx, sz) console_step(C, true, a, s, k, 1.79e9, rx, sz, P);
[C, tx, txEn] = cs(C, 0, 0, 0, none, 0);
results = add(results, 'console first step: no taps inferred from initial button state', C.cmdSeq == 0);
% The arm button level changes 0 -> 1, which is one tap. The node is
% reported as DISARMED, so the console must send ARM (command seq 1).
[C, tx, txEn] = cs(C, 1, 0, 0, statpkt(P, P.ST_DISARMED, 0, 0, 0, -1), 1);
results = add(results, 'arm tap on DISARMED node -> ARM command sent at once', ...
    txEn && tx(2) == P.TYPE_CMD && tx(3) == 1 && tx(4) == P.CMD_ARM);
% Tap again (level 1 -> 0) before the node confirmed. The pending ARM is
% remembered, so this must become DISARM, not another ARM.
[C, tx] = cs(C, 0, 0, 0, none, 0);
results = add(results, 'second tap before node confirms -> DISARM (uses pending intent)', ...
    C.cmdSeq == 2 && C.cmdCode == P.CMD_DISARM);
% Node now confirms (ack = 2) and reports ARMED, so another tap is DISARM.
[C] = cs(C, 1, 0, 0, statpkt(P, P.ST_ARMED, 0, 0, 0, 2), 1);
results = add(results, 'confirmed ARMED node + arm tap -> DISARM', C.cmdCode == P.CMD_DISARM && C.cmdSeq == 3);

% Breach arrives. Use the full 7-output form to check what the UI shows.
C = console_init(P.logLen);
[C] = cs(C, 0, 0, 0, statpkt(P, P.ST_ARMED, 0, 0, 0, -1), 1);
[C, ~, ~, uiS, uiB, ~, uiL] = console_step(C, true, 0, 0, 0, 1.79e9, statpkt(P, P.ST_ALARM, 1, 1790000123, P.CAUSE_LIGHT, -1), 1, P);
[ymd, hms] = epoch_to_civil(1790000123, P.tzOffsetSec);       % the expected date and time numbers
results = add(results, 'ALARM status -> audible alert raised', uiS(4) == 1 && uiS(5) == P.CAUSE_LIGHT);
results = add(results, 'breach time decoded and logged', uiB(2) == ymd && uiB(3) == hms && uiL(1) == hms);
% Ack button (level 0 -> 1) silences the alert.
[C, ~, ~, uiS] = cs(C, 0, 0, 1, statpkt(P, P.ST_ALARM, 1, 1790000123, P.CAUSE_LIGHT, -1), 1);
results = add(results, 'ack tap silences alert', uiS(4) == 0);
% The node keeps repeating the same breach #1 in its heartbeat. It must stay silent.
[C, ~, ~, uiS] = cs(C, 0, 0, 1, statpkt(P, P.ST_ALARM, 1, 1790000123, P.CAUSE_LIGHT, -1), 1);
results = add(results, 'same breach does not re-alert after ack', uiS(4) == 0);
% Breach #2 is new, so it alerts again and is logged in front of #1.
[C, ~, ~, uiS, ~, ~, uiL] = cs(C, 0, 0, 1, statpkt(P, P.ST_ALARM, 2, 1790000999, P.CAUSE_MOTION, -1), 1);
results = add(results, 'new breach seq re-alerts and is logged newest first', uiS(4) == 1 && uiL(2) == hms);
[C, ~, ~, uiS] = cs(C, 0, 0, 1, statpkt(P, P.ST_DISARMED, 2, 1790000999, P.CAUSE_MOTION, -1), 1);
results = add(results, 'alert stops when node reports DISARMED', uiS(4) == 0);

% link supervision
% Hear an ARMED node once, then stay silent for linkTimeoutSteps steps.
C = console_init(P.logLen);
[C] = cs(C, 0, 0, 0, statpkt(P, P.ST_ARMED, 0, 0, 0, -1), 1);
for n = 1:P.linkTimeoutSteps
    [C, ~, ~, uiS] = cs(C, 0, 0, 0, none, 0);
end
results = add(results, 'armed node silent for 5 s -> link-lost alert', uiS(1) == 0 && uiS(4) == 1 && uiS(5) == P.CAUSE_LINKLOST);
[C, ~, ~, uiS] = cs(C, 0, 0, 1, none, 0);
[C, ~, ~, uiS] = cs(C, 0, 0, 1, none, 0);
results = add(results, 'link-lost alert can be acknowledged', uiS(4) == 0);
% Same silence but the node was DISARMED: no reason to alarm.
C = console_init(P.logLen);
[C] = cs(C, 0, 0, 0, statpkt(P, P.ST_DISARMED, 0, 0, 0, -1), 1);
for n = 1:P.linkTimeoutSteps + 5
    [C, ~, ~, uiS] = cs(C, 0, 0, 0, none, 0);
end
results = add(results, 'disarmed node going silent does not alert', uiS(4) == 0);

% siren toggle
C = console_init(P.logLen);
[C] = cs(C, 0, 0, 0, statpkt(P, P.ST_ALARM, 1, 5, 1, -1), 1);
[C] = cs(C, 0, 1, 0, none, 0);
results = add(results, 'siren tap with siren off -> SIREN_ON', C.cmdCode == P.CMD_SIREN_ON);
% Node confirms the command and reports siren on (word 12), then tap again.
st = statpkt(P, P.ST_ALARM, 1, 5, 1, C.cmdSeq); st(12) = 1;
[C] = cs(C, 0, 1, 0, st, 1);
[C] = cs(C, 0, 0, 0, none, 0);
results = add(results, 'siren tap with siren on -> SIREN_OFF', C.cmdCode == P.CMD_SIREN_OFF);

% console ignores its own command broadcasts
% A console only accepts TYPE_STATUS. A command packet must be ignored.
C = console_init(P.logLen);
[C] = cs(C, 0, 0, 0, cmdpkt(P, 7, P.CMD_ARM), 1);
results = add(results, 'console ignores command packets (own broadcast)', ~C.everRx);

% ======================================================================
% 4. audio engine
% Test message: 1.5 s sine at 440 Hz, half scale. The transposed column
% (' after the parentheses) makes it a column vector like a real recording.
A = audio_init();
msg = int16(round(0.5*32767*sin(2*pi*440*(0:P.Fs*1.5-1)'/P.Fs)));
[A, fr] = audio_step(A, 1, 0, msg, P);
results = add(results, 'frame is 4410x2 int16', isequal(size(fr), [P.frameLen 2]) && isa(fr, 'int16'));
results = add(results, 'siren is near full scale', max(abs(double(fr(:,1)))) > 0.9*32767);
% Message loop: 1.5 s = 15 frames of sound, then 10 frames (1 s) of silence,
% then it starts over. pk holds the peak level of each of 40 frames.
A = audio_init();
pk = zeros(1, 40);
for n = 1:40
    [A, fr] = audio_step(A, 0, 1, msg, P);
    pk(n) = max(abs(double(fr(:,1))));
end
results = add(results, 'message plays 1.5 s, 1 s gap, then repeats', ...
    all(pk(1:15) > 1e4) && all(pk(17:25) == 0) && pk(26) > 1e4);
[A, fr] = audio_step(A, 0, 0, msg, P);
results = add(results, 'silent when neither siren nor alert', ~any(fr(:)));

% ======================================================================
% ---- summary: count failures and raise an error if there were any ----
nFail = sum(~[results.pass]);                 % [results.pass] collects the field from every record
fprintf('\n%d / %d unit checks passed\n', numel(results) - nFail, numel(results));
if nFail > 0
    error('test_logic_units:failed', '%d unit checks failed', nFail);
end
end

% ----------------------------------------------------------------------
function r = add(r, name, pass)
%ADD  Append one {name, pass} record to the results and print PASS or FAIL.
%   MATLAB passes by value, so the updated list is returned and the caller
%   writes it back (results = add(results, ...)).
r(end+1) = struct('name', name, 'pass', logical(pass));
if pass
    fprintf('  PASS  %s\n', name);
else
    fprintf('  FAIL  %s\n', name);
end
end

% ----------------------------------------------------------------------
function p = cmdpkt(P, seq, code)
%CMDPKT  Build a console -> node command packet (as the console would send it).
p = zeros(P.PKT_LEN, 1);
p(1) = P.MAGIC; p(2) = P.TYPE_CMD; p(3) = seq; p(4) = code; p(P.PKT_LEN) = P.PAIR_ID;
end

% ----------------------------------------------------------------------
function p = statpkt(P, state, seq, t, cause, cmdAck)
%STATPKT  Build a node -> console status packet with the given fields.
%   state = node state, seq = breach number, t = breach epoch, cause = cause
%   mask, cmdAck = last command sequence the node confirms. Position is fixed.
p = zeros(P.PKT_LEN, 1);
p(1) = P.MAGIC; p(2) = P.TYPE_STATUS; p(3) = state; p(4) = seq; p(5) = t;
p(6) = cause; p(7) = 23.2; p(8) = 72.6; p(9) = 23.2; p(10) = 72.6; p(11) = 50;
p(13) = cmdAck; p(P.PKT_LEN) = P.PAIR_ID;
end
