function mdl = build_sim_harness(mdl)
%BUILD_SIM_HARNESS  Desktop model with TWO phones running the same SecurityCore.
%   Phone_A and Phone_B get scripted sensors and button taps (ids_scenario)
%   and talk through a lossy, delayed "Wi-Fi" link. Run run_harness_test to
%   simulate it and check every requirement.
%
%   Think of this as a testbench in Verilog. The device under test
%   (SecurityCore) is instantiated twice and the rest of the model is
%   stimulus generators, a channel model and probes (To Workspace logs).
%   Like build_security_core this script creates the diagram with commands.

% ---- model name, folder, and make sure the alert audio exists ----
if nargin < 1
    mdl = 'ids_sim_harness';
end
here = fileparts(mfilename('fullpath'));      % folder of this file
addpath(here);                                % make sibling .m files callable (like sys.path.append)
if ~isfile(fullfile(here, 'alert_message.mat'))
    make_alert_audio();                       % the AudioEngine needs the message file
end

% ---- start from a clean slate: close and delete an older copy ----
if bdIsLoaded(mdl)
    close_system(mdl, 0);                     % 0 = close without saving
end
if isfile(fullfile(here, [mdl '.slx']))
    delete(fullfile(here, [mdl '.slx']));
end

% ---- constants, scenario data and a new empty model ----
P  = ids_params();
sc = ids_scenario();
new_system(mdl);
% Fixed-step discrete solver at Ts, exactly the clocked behaviour of the phone app.
set_param(mdl, 'Solver', 'FixedStepDiscrete', 'FixedStep', num2str(P.Ts), ...
    'StopTime', num2str(sc.stopTime), 'SaveTime', 'on', 'ReturnWorkspaceOutputs', 'on');

% scenario data lives in the model workspace so the .slx is self-contained
hws = get_param(mdl, 'ModelWorkspace');
phones = {'A', 'B'};
sigs = {'role','lux','ori','gyro','gps','btnArm','btnSiren','btnAck'};   % stimulus signals per phone
% containers.Map = Python dict. Maps a SecurityCore input name to its port number.
coreIn = containers.Map({'role','lux','ori','gyro','gps','epoch','rx','rxSize','btnArm','btnSiren','btnAck'}, 1:11);

% ---- shared wall clock = base epoch + simulation time ----
% Both phones see the same clock, as real phones sync to network time.
add_block('simulink/Sources/Digital Clock', [mdl '/SimTime'], 'SampleTime', num2str(P.Ts), 'Position', [40 20 80 50]);
add_block('simulink/Sources/Constant', [mdl '/BaseEpoch'], 'Value', num2str(sc.baseEpoch, 12), 'Position', [40 60 120 90]);
add_block('simulink/Math Operations/Add', [mdl '/Epoch'], 'Position', [160 30 190 80]);
add_line(mdl, 'SimTime/1', 'Epoch/1');
add_line(mdl, 'BaseEpoch/1', 'Epoch/2');

% ---- lossy network (MATLAB Function) + 0.1 s latency ----
% One block moves datagrams in both directions: A to B and B to A.
net = [mdl '/WiFi_Network'];
add_block('simulink/User-Defined Functions/MATLAB Function', net, 'Position', [800 380 950 520]);
rt = sfroot;
ch = rt.find('-isa', 'Stateflow.EMChart', 'Path', net);
% The channel source code is again a list of strings joined by newlines.
% It uses a tiny linear congruential generator (LCG) for the random loss,
% so the "random" drops are identical on every run and the test is repeatable.
ch.Script = strjoin({
    'function [rxA, szA, rxB, szB] = wifi(txA, enA, txB, enB)'
    '% Delivers each phone''s datagrams to the other phone, dropping a fraction.'
    'persistent s'
    'if isempty(s), s = 12345; end'
    sprintf('loss = %g;', sc.lossProb)        % bake the loss probability into the code text
    's = mod(1664525*s + 1013904223, 4294967296); uA = s/4294967296;'    % next pseudo random number in [0,1) for A to B
    's = mod(1664525*s + 1013904223, 4294967296); uB = s/4294967296;'    % and one for B to A
    'rxB = txA; szB = 0;'                     % packet from A goes to B, size 0 means "nothing arrived"
    'if enA && uA >= loss, szB = 128; end'    % delivered unless the random draw says drop (128 bytes)
    'rxA = txB; szA = 0;'
    'if enB && uB >= loss, szA = 128; end'
    }, newline);
% Unit Delays add one step (0.1 s) of latency to each network output.
% They also break the algebraic loop, since each phone feeds the other.
for k = 1:4
    add_block('simulink/Discrete/Unit Delay', sprintf('%s/Latency%d', mdl, k), ...
        'InitialCondition', '0', 'SampleTime', num2str(P.Ts), ...
        'Position', [1000 380+35*(k-1) 1030 405+35*(k-1)]);
    add_line(mdl, sprintf('WiFi_Network/%d', k), sprintf('Latency%d/1', k));
end

% ---- build the two phones ----
logs = {};                                    % names of the logged variables
for p = 1:2
    X  = phones{p};                           % 'A' or 'B'
    y0 = 40 + (p-1)*700;                      % vertical offset so the phones do not overlap on screen
    core = build_security_core(mdl, ['Phone_' X], [500 y0+100 720 y0+600]);    % the device under test

    % -- stimulus sources: one From Workspace block per input signal --
    for s = 1:numel(sigs)
        vname = sprintf('%s_%s', X, sigs{s});            % for example A_lux
        assignin(hws, vname, sc.(X).(sigs{s}));          % sc.(X) = dynamic field, like getattr(sc, X)
        fw = sprintf('%s/%s', mdl, vname);
        add_block('simulink/Sources/From Workspace', fw, 'VariableName', vname, ...
            'SampleTime', num2str(P.Ts), 'Interpolate', 'off', ...
            'OutputAfterFinalValue', 'Holding final value', ...
            'Position', [200 y0+100+50*s 320 y0+125+50*s]);
        add_line(mdl, [vname '/1'], sprintf('Phone_%s/%d', X, coreIn(sigs{s})), 'autorouting', 'on');
    end
    add_line(mdl, 'Epoch/1', sprintf('Phone_%s/%d', X, coreIn('epoch')), 'autorouting', 'on');

    % network wiring: tx -> WiFi -> latency -> rx of the other phone
    % Phone A uses network ports 1 and 2 (txA, enA). Phone B uses 3 and 4.
    add_line(mdl, sprintf('Phone_%s/1', X), sprintf('WiFi_Network/%d', 2*p-1), 'autorouting', 'on');
    add_line(mdl, sprintf('Phone_%s/2', X), sprintf('WiFi_Network/%d', 2*p), 'autorouting', 'on');
    add_line(mdl, sprintf('Latency%d/1', 2*p-1), sprintf('Phone_%s/%d', X, coreIn('rx')),     'autorouting', 'on');
    add_line(mdl, sprintf('Latency%d/1', 2*p),   sprintf('Phone_%s/%d', X, coreIn('rxSize')), 'autorouting', 'on');

    % logging
    % Each row of outs is {core output port number, log name}.
    outs = {3,'audio'; 4,'torch'; 5,'uiNode'; 6,'uiStatus'; 7,'uiBreach'; 8,'uiLive'; 9,'uiLog'; 10,'sirenOn'; 11,'alertOn'};
    for o = 1:size(outs, 1)
        vn = sprintf('%s_%s', X, outs{o,2});             % log variable name, for example A_torch
        yy = y0 + 100 + 45*(o-1);
        if strcmp(outs{o,2}, 'audio')
            % log the frame peak instead of 4410x2 samples per step
            % chain: int16 -> double -> abs -> max over the frame
            add_block('simulink/Signal Attributes/Data Type Conversion', [mdl '/' vn '_dbl'], ...
                'OutDataTypeStr', 'double', 'Position', [800 yy 840 yy+25]);
            add_block('simulink/Math Operations/Abs', [mdl '/' vn '_abs'], 'Position', [860 yy 890 yy+25]);
            add_block('simulink/Math Operations/MinMax', [mdl '/' vn '_peak'], 'Function', 'max', ...
                'Inputs', '1', 'Position', [910 yy 940 yy+25]);
            add_line(mdl, sprintf('Phone_%s/3', X), [vn '_dbl/1'], 'autorouting', 'on');
            add_line(mdl, [vn '_dbl/1'], [vn '_abs/1']);
            add_line(mdl, [vn '_abs/1'], [vn '_peak/1']);
            src = [vn '_peak/1'];                        % signal to log
            vn = [X '_audioPeak'];                       % log name used by run_harness_test
        else
            src = sprintf('Phone_%s/%d', X, outs{o,1});  % log the output port directly
        end
        % To Workspace block = a probe that stores the signal in a variable.
        tw = [mdl '/log_' vn];
        add_block('simulink/Sinks/To Workspace', tw, 'VariableName', vn, 'SaveFormat', 'Array', ...
            'Position', [1100 yy 1180 yy+25]);
        add_line(mdl, src, ['log_' vn '/1'], 'autorouting', 'on');
        logs{end+1} = vn; %#ok<AGROW>                    % append to the cell array (list.append)
    end
end

% ---- tidy the layout (cosmetic only, so a failure is ignored) and save ----
try
    Simulink.BlockDiagram.arrangeSystem(mdl);
catch
end
save_system(mdl, fullfile(here, [mdl '.slx']));
fprintf('Built %s.slx with phones A and B (logs: %s)\n', mdl, strjoin(logs, ', '));
end
