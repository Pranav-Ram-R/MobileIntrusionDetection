function results = run_harness_test()
%RUN_HARNESS_TEST  Build + simulate the two-phone harness and check the
%   assignment requirements end to end (20 % packet loss on the link).
%
%   Flow: build the model, simulate 130 s, pull the logged signals out of
%   the simulation result, run 13 checks against the requirements, draw a
%   timeline picture, and raise an error if any check failed.
%   Naming: A_* are Phone A signals, B_* Phone B. In the first 90 s phone A
%   is the node and B the console. After 90 s the roles swap.

% ---- build and simulate ----
here = fileparts(mfilename('fullpath'));
addpath(here);
P  = ids_params();
sc = ids_scenario();                          % needed here for the expected values (GPS, clock)
mdl = build_sim_harness('ids_sim_harness');   % creates and saves the two-phone model
out = sim(mdl);                               % run the simulation, "out" holds all logged data

% ---- get the logged signals ----
% Each log becomes a matrix with one row per time step (see as_rows).
t   = out.tout(:);                            % time axis as a column
g   = @(name) as_rows(out.get(name));         % shorthand: g('A_uiNode') = log of that name
Ast = g('A_uiNode');   Bst = g('B_uiNode');   % node UI vectors [state breachSeq cause siren lux tilt]
AS  = g('A_uiStatus'); BS  = g('B_uiStatus'); % console UI vectors [linkUp nodeState siren alert cause]
AB  = g('A_uiBreach'); BB  = g('B_uiBreach'); % last breach [seq date time cause lat lon]
Apk = g('A_audioPeak'); Bpk = g('B_audioPeak');   % loudest sample of each audio frame
Ato = g('A_torch');    Asi = g('A_sirenOn'); % LED and siren of phone A
BL  = g('B_uiLog');                           % breach time log shown on B

% ---- small helpers (anonymous functions) ----
% at(x, tq)    = row of x at the first time >= tq (like x[searchsorted(t, tq)])
% win(a, b)    = logical mask of the samples in the window [a, b]
% first(mask)  = time of the first true sample, or [] if there is none
% 1e-6 guards against floating point error in the time stamps.
at   = @(x, tq) x(find(t >= tq - 1e-6, 1), :);
win  = @(tq0, tq1) (t >= tq0 - 1e-6 & t <= tq1 + 1e-6);
first = @(mask) t(find(mask, 1));

results = struct('name', {}, 'pass', {}, 'detail', {});   % empty list of result records

% --- Req 1 + 3b: remote arm
% B tapped ARM at t = 5 s. The node must be ARMED about 5 s later (exit delay).
tArm = first(Ast(:,1) == P.ST_ARMED);
results = add(results, 'R3b  B arms A remotely (exit delay 5 s)', ...
    ~isempty(tArm) && tArm >= 9.9 && tArm < 12, sprintf('A ARMED at t=%.1f s', tArm));

% --- Req 1: light intrusion
% Drawer opens at t = 30 s. Expect ALARM within 0.6 s with the light cause.
% (at(...)*[0;0;1;0;0;0] picks column 3 of the row, a dot product used as an index.)
tA1 = first(Ast(:,1) == P.ST_ALARM);
results = add(results, 'R1   light increase trips A while ARMED', ...
    ~isempty(tA1) && tA1 >= 30 && tA1 < 30.6 && bitand(at(Ast, 31)*[0;0;1;0;0;0], P.CAUSE_LIGHT) > 0, ...
    sprintf('A ALARM at t=%.1f s, cause=%d', tA1, at(Ast,31)*[0;0;1;0;0;0]));

% --- Req 2a: audible alert on B
% B's alert flag must rise within 2 s of the breach, despite 20% packet loss,
% and its speaker must actually carry sound (peak above 1e4 of 32767).
tB1 = first(BS(:,4) == 1);
results = add(results, 'R2a  B raises audible alert (recorded message)', ...
    ~isempty(tB1) && tB1 - tA1 < 2 && any(Bpk(win(tB1, 44)) > 1e4), ...
    sprintf('B alert at t=%.1f s (%.1f s after breach), peak %d', tB1, tB1 - tA1, max(Bpk(win(tB1,44)))));

% --- Req 2b + 2c: GPS and timestamp log
% Expected date and time are computed from the scenario clock and compared
% with what B decoded. bb = B's breach record 4 s after the breach.
bb = at(BB, 34);
[ymd, hms] = epoch_to_civil(sc.baseEpoch + tA1, P.tzOffsetSec);
results = add(results, 'R2b  B receives GPS of A', ...
    abs(bb(5) - 23.2156) < 1e-9 && abs(bb(6) - 72.6369) < 1e-9, sprintf('lat %.4f lon %.4f', bb(5), bb(6)));
results = add(results, 'R2c  B logs breach timestamp', ...
    bb(1) == 1 && bb(2) == ymd && bb(3) == hms && at(BL, 34)*[1;0;0;0;0] == hms, ...
    sprintf('breach #%d at %08d %06d (expected %08d %06d)', bb(1), bb(2), bb(3), ymd, hms));

% --- Req 3a: siren + LED
% B taps SIREN at t = 35 s. After a short start-up, every audio frame of
% A must be loud (peak above 3e4) until t = 49.
tS = first(Asi == 1 & t > 35);
tw = win(tS + 0.5, 49);
results = add(results, 'R3a  B triggers siren on A', ...
    ~isempty(tS) && tS < 37 && all(Apk(tw) > 3e4), sprintf('siren on at t=%.1f s, min peak %d', tS, min(Apk(tw))));
% The LED must be seen both on and off in that window, about half the time on.
results = add(results, 'R3a  camera LED pulses with the siren', ...
    any(Ato(tw) == 1) && any(Ato(tw) == 0) && mean(Ato(tw)) > 0.3 && mean(Ato(tw)) < 0.7, ...
    sprintf('LED duty %.2f', mean(Ato(tw))));

% --- acknowledge
% B taps ACK at t = 45 s. Its alert flag and its audio must be silent from 46 s.
results = add(results, 'ACK  B silences its alert', ...
    all(BS(win(46, 49), 4) == 0) && all(Bpk(win(46, 49)) == 0), 'alert 0, audio 0 after t=46 s');

% --- Req 3b: disarm
% B taps ARM/DISARM at t = 50 s. A must go DISARMED and both siren and LED must stop.
tD = first(Ast(:,1) == P.ST_DISARMED & t > 50);
results = add(results, 'R3b  B disarms A (siren and LED stop)', ...
    ~isempty(tD) && tD < 52 && all(Asi(win(tD+0.2, 59)) == 0) && all(Ato(win(tD+0.2, 59)) == 0), ...
    sprintf('A DISARMED at t=%.1f s', tD));

% --- Req 1: motion / orientation
% A is re-armed at 60 s and picked up at 75 s. Expect breach #2 within 0.6 s,
% with a tilt or motion cause (bit mask), and B showing breach number 2.
tA2 = first(Ast(:,1) == P.ST_ALARM & t > 60);
c2  = at(Ast, 77)*[0;0;1;0;0;0];
results = add(results, 'R1   gyro / orientation tamper trips A', ...
    ~isempty(tA2) && tA2 >= 75 && tA2 < 75.6 && bitand(c2, P.CAUSE_TILT + P.CAUSE_MOTION) > 0 && at(BB, 78)*[1;0;0;0;0;0] == 2, ...
    sprintf('A ALARM #2 at t=%.1f s, cause=%d', tA2, c2));
% The log on B must hold both breaches, newest first. The row times a 5x2
% selection matrix picks the first two log entries, both must be nonzero.
results = add(results, 'LOG  B keeps both breaches newest first', ...
    all(at(BL, 80)*[1 0;0 1;0 0;0 0;0 0] > 0) && at(BL,80)*[0;1;0;0;0] == hms, mat2str(at(BL, 80)));

% --- Req 4: roles swapped
% After t = 90 s phone A is the console and phone B the node. A arms B
% (tap at 95 s), B's light jumps at 110 s, and A must be alerted with B's GPS.
tBarm = first(Bst(:,1) == P.ST_ARMED & t > 90);
tBal  = first(Bst(:,1) == P.ST_ALARM & t > 90);
tAal  = first(AS(:,4) == 1 & t > 90);
ab = at(AB, 113);
results = add(results, 'R4   swapped roles: A (console) arms B (node)', ...
    ~isempty(tBarm) && tBarm < 102, sprintf('B ARMED at t=%.1f s', tBarm));
results = add(results, 'R4   swapped roles: B breach alerts A', ...
    ~isempty(tBal) && ~isempty(tAal) && tAal - tBal < 2 && abs(ab(5) - 23.0225) < 1e-9 && any(Apk(win(tAal, 120)) > 1e4), ...
    sprintf('B ALARM t=%.1f, A alert t=%.1f, A sees lat %.4f', tBal, tAal, ab(5)));

% ---- summary ----
nFail = sum(~[results.pass]);
fprintf('\n%d / %d end-to-end checks passed\n', numel(results) - nFail, numel(results));

% ---- timeline figure: five stacked plots sharing the time axis ----
% The figure is created invisible and written straight to a PNG file.
f = figure('Visible', 'off', 'Position', [100 100 1100 800]);
tl = tiledlayout(f, 5, 1, 'TileSpacing', 'compact');      % 5 rows, 1 column of plots
% 1) node state of both phones (stairs = step plot)
nexttile; stairs(t, Ast(:,1), 'LineWidth', 1.5); hold on; stairs(t, Bst(:,1), '--', 'LineWidth', 1.5);
ylabel('node state'); yticks(0:3); yticklabels({'DISARMED','ARMING','ARMED','ALARM'}); legend('Phone A', 'Phone B', 'Location', 'northwest'); grid on
% 2) the light levels fed to the phones
nexttile; plot(t, sc.A.lux(:,2), t, sc.B.lux(:,2)); ylabel('light (lux)'); grid on
% 3) the console alert flag on whichever phone is the console
nexttile; stairs(t, BS(:,4), 'LineWidth', 1.5); hold on; stairs(t, AS(:,4), '--', 'LineWidth', 1.5);
ylabel('console alert'); ylim([-0.1 1.1]); legend('on B (console until 90 s)', 'on A (console after 90 s)', 'Location', 'northwest'); grid on
% 4) siren and LED of phone A (LED scaled by 0.5 so both lines are visible)
nexttile; stairs(t, Asi, 'LineWidth', 1.5); hold on; stairs(t, 0.5*Ato, 'LineWidth', 1);
ylabel('A siren / LED'); ylim([-0.1 1.1]); legend('siren', 'LED (x0.5)', 'Location', 'northwest'); grid on
% 5) audio activity (peak per frame) of both speakers
nexttile; plot(t, Apk, t, Bpk); ylabel('audio peak'); xlabel('time (s)'); legend('A speaker', 'B speaker', 'Location', 'northwest'); grid on
title(tl, sprintf('Two-phone simulation, %d%% datagram loss', round(100*sc.lossProb)));
exportgraphics(f, fullfile(here, 'harness_timeline.png'), 'Resolution', 150);
close(f);

% ---- fail loudly so scripts and CI notice ----
if nFail > 0
    error('run_harness_test:failed', '%d end-to-end checks failed', nFail);
end
end

% ------------------------------------------------------------------------
function y = as_rows(x)
% To Workspace logs 1xK matrix signals as 1xKxN. Return N x K.
% Example: a 6 element UI vector over 1301 steps arrives as 1x6x1301.
% permute reorders axes (like np.transpose) and reshape flattens to 1301x6.
if ndims(x) == 3
    x = reshape(permute(x, [3 1 2]), size(x, 3), []);
end
y = double(x);                                % plain double matrix for the comparisons above
end

% ------------------------------------------------------------------------
function r = add(r, name, pass, detail)
%ADD  Append one check result (name, pass flag, detail text) and print it.
r(end+1) = struct('name', name, 'pass', logical(pass), 'detail', detail);
fprintf('  %s  %-48s %s\n', ternary(pass), name, detail);     % %-48s = left aligned in 48 characters
end

% ------------------------------------------------------------------------
function s = ternary(p)
%TERNARY  'PASS' or 'FAIL' (MATLAB has no "a if c else b" expression).
if p, s = 'PASS'; else, s = 'FAIL'; end
end
