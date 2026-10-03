function sc = ids_scenario()
%IDS_SCENARIO  Scripted two-phone test story for the desktop harness.
%
%   t =   5  B (console) taps ARM          -> A arms, ARMED ~5 s later
%   t =  30  drawer opened: A lux 0.5 -> 80 for 3 s  -> breach #1 (light)
%   t =  35  B taps SIREN                  -> A siren + LED strobe
%   t =  45  B taps ACK                    -> B stops the voice alert
%   t =  50  B taps ARM/DISARM             -> A disarmed, siren off
%   t =  60  B taps ARM                    -> A re-armed
%   t =  75  A picked up: gyro spike + 25 deg tilt -> breach #2 (tilt/motion)
%   t =  85  B taps ARM/DISARM             -> A disarmed
%   t =  90  ROLES SWAP: A becomes console, B becomes security node
%   t =  95  A taps ARM                    -> B arms
%   t = 110  light on B                    -> A (now console) is alerted
%   Network: 20 % random datagram loss, 0.1 s latency.
%
%   Output sc is a struct of "time + value" tables, one per input signal,
%   in the format Simulink's From Workspace block expects: column 1 is the
%   time stamp and the remaining columns are the signal values.

% ---- global settings and the time axis ----
Ts = 0.1;
sc.stopTime  = 130;             % simulation length (s)
sc.baseEpoch = 1790000000;      % 2026-09-21 18:23:20 IST, fake wall clock at t = 0
sc.lossProb  = 0.2;             % probability that the simulated Wi-Fi drops a datagram
t  = (0:Ts:sc.stopTime)';       % time column 0, 0.1, ... 130 (start:step:stop)
n  = numel(t);                  % number of samples
rng(7);                         % fixed random seed, the noise is the same every run (like random.seed(7))

% ---- role selection: 1 = node, 2 = console ----
% Logical expressions give 0/1, so "1 + (t >= 90)" is 1 before 90 s and 2 after.
sc.A.role = mat(t, 1 + (t >= 90));      % A: node, then console
sc.B.role = mat(t, 2 - (t >= 90));      % B: console, then node

% ---- ambient light: dim room with sensor noise, plus scripted events ----
luxA = 0.5 + 0.05*randn(n, 1);          % randn = Gaussian noise (np.random.randn)
luxA(t >= 30 & t < 33) = 80;            % drawer opened for 3 s (boolean mask assignment, "&" = element-wise AND)
sc.A.lux = mat(t, luxA);
luxB = 0.5 + 0.05*randn(n, 1);
luxB(t >= 110) = 120;                   % light on at B after it became the node
sc.B.lux = mat(t, luxB);

% ---- orientation [pitch roll azimuth] in degrees ----
oriA = [1 + 0.2*randn(n,1), 0.5 + 0.2*randn(n,1), 120 + 1.0*randn(n,1)];   % phone lying nearly flat
oriA(t >= 75, 1) = oriA(t >= 75, 1) + 25;     % from 75 s the phone is picked up: +25 deg pitch
sc.A.ori = mat(t, oriA);
sc.B.ori = mat(t, [0.2*randn(n,1), 0.2*randn(n,1), 200 + randn(n,1)]);

% ---- gyroscope [wx wy wz] in rad/s: tiny noise, plus one short spike at 75 s ----
gyA = 0.02*randn(n, 3);
gyA(t >= 75 & t < 75.35, 1) = 1.5;            % 0.35 s shake on the x axis
sc.A.gyro = mat(t, gyA);
sc.B.gyro = mat(t, 0.02*randn(n, 3));

% ---- GPS [lat lon alt]. Zeros until t = 2 s emulate "no fix yet". ----
% The 1x3 row times the boolean (t >= 2) column broadcasts to n x 3.
sc.A.gps = mat(t, [23.2156, 72.6369, 50] .* (t >= 2));
sc.B.gps = mat(t, [23.0225, 72.5714, 40] .* (t >= 2));

% ---- button taps (each listed time flips the toggle, see toggles below) ----
sc.B.btnArm   = mat(t, toggles(t, [5 50 60 85]));    % arm, disarm, arm, disarm
sc.B.btnSiren = mat(t, toggles(t, 35));
sc.B.btnAck   = mat(t, toggles(t, 45));
sc.A.btnArm   = mat(t, toggles(t, 95));              % A as console arms B after the swap
sc.A.btnSiren = mat(t, zeros(n, 1));                 % never pressed
sc.A.btnAck   = mat(t, zeros(n, 1));
end

% -------------------------------------------------------------------------
function m = mat(t, v)
%MAT  Build the [time, value] table that From Workspace expects.
if size(v, 1) == 1
    v = repmat(v, numel(t), 1);                      % a single row is a constant, repeat it for every time stamp
end
m = [t, double(v)];                                  % [a, b] joins side by side (hstack)
end

% -------------------------------------------------------------------------
function b = toggles(t, tapTimes)
%TOGGLES  Button level over time. Starts at 0 and flips at each tap time.
% Button widget: each tap flips the state
b = zeros(numel(t), 1);
for k = 1:numel(tapTimes)
    b = xor(b, t >= tapTimes(k) - 1e-9);             % flip everything from the tap time onwards (tolerance for float error)
end
b = double(b);                                       % logical -> 0/1 numbers
end
