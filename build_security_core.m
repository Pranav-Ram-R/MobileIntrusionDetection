function blk = build_security_core(parent, name, pos)
%BUILD_SECURITY_CORE  Add the hardware-independent "SecurityCore" subsystem.
%   The same subsystem is used by the Android app model and by the desktop
%   test harness, so what is tested on the PC is what runs on the phones.
%
%   Inputs  1 role (1 = Security Node, 2 = Monitoring Console)
%           2 lux  3 ori[3]  4 gyro[3]  5 gps[3]  6 epoch
%           7 rx[16]  8 rxSize  9 btnArm  10 btnSiren  11 btnAck
%   Outputs 1 tx[16]  2 txEn  3 audio[4410x2 int16]  4 torch (int32)
%           5 uiNode  6 uiStatus  7 uiBreach  8 uiLive  9 uiLog
%           10 sirenOn  11 alertOn
%
%   What this file does: it is a script that BUILDS a Simulink diagram with
%   function calls (add_block, add_line), instead of dragging blocks by
%   hand. Think of it as a generator that prints a netlist. The diagram
%   has 11 input ports, two MATLAB Function blocks (Controller and
%   AudioEngine) and 11 output ports, all wired together.
%
%   Arguments: parent = path of the model or subsystem to add into,
%   name = name of the new subsystem, pos = [left top right bottom] pixels.

% ---- default position, and the full path of the new block ----
if nargin < 3                                 % optional argument not given
    pos = [300 100 520 420];
end
blk = [parent '/' name];                      % [a b c] concatenates strings, Simulink paths use "/"

% ---- create an empty subsystem ----
add_block('simulink/Ports & Subsystems/Subsystem', blk, 'Position', pos);
% clear the default In1 -> Out1 contents
delete_line(blk, 'In1/1', 'Out1/1');          % a new Subsystem comes with one input wired to one output
delete_block([blk '/In1']);
delete_block([blk '/Out1']);

% ---- port names, cell arrays {..} are lists of strings (Python list) ----
inNames  = {'role','lux','ori','gyro','gps','epoch','rx','rxSize','btnArm','btnSiren','btnAck'};
outNames = {'tx','txEn','audio','torch','uiNode','uiStatus','uiBreach','uiLive','uiLog','sirenOn','alertOn'};

% ---- add the Inport and Outport blocks in two columns ----
% Name-value pairs ('Position', [..]) are how Simulink functions take
% keyword arguments. The "..." continues the call on the next line.
for k = 1:numel(inNames)
    add_block('simulink/Sources/In1', [blk '/' inNames{k}], ...
        'Position', [40 40+45*k 70 54+45*k], 'Port', num2str(k));    % curly braces {k} pull out one list element
end
for k = 1:numel(outNames)
    add_block('simulink/Sinks/Out1', [blk '/' outNames{k}], ...
        'Position', [760 40+45*k 790 54+45*k], 'Port', num2str(k));
end

% ---- Controller: node + console state machines
% A MATLAB Function block holds ordinary MATLAB code that is compiled to C
% for the phone. We create the empty block, then inject the source text.
ctl = [blk '/Controller'];
add_block('simulink/User-Defined Functions/MATLAB Function', ctl, 'Position', [220 60 480 560]);
set_mlfb_script(ctl, controller_code());

% ---- Audio engine: siren synthesis + recorded message playback
aud = [blk '/AudioEngine'];
add_block('simulink/User-Defined Functions/MATLAB Function', aud, 'Position', [560 420 700 500]);
set_mlfb_script(aud, audio_code());

% ---- wiring: every input port goes to the same-numbered Controller input ----
for k = 1:numel(inNames)
    add_line(blk, [inNames{k} '/1'], sprintf('Controller/%d', k), 'autorouting', 'on');   % sprintf = C printf into a string
end
% ---- wiring: Controller outputs to the output ports and to the AudioEngine ----
% Controller outputs: tx txEn torch sirenOn alertOn uiNode uiStatus uiBreach uiLive uiLog
% (1 = first output, 4 = sirenOn, 5 = alertOn, and so on, same order as the controller function signature)
add_line(blk, 'Controller/1', 'tx/1',       'autorouting', 'on');
add_line(blk, 'Controller/2', 'txEn/1',     'autorouting', 'on');
add_line(blk, 'Controller/3', 'torch/1',    'autorouting', 'on');
add_line(blk, 'Controller/4', 'AudioEngine/1', 'autorouting', 'on');     % sirenOn drives the audio engine
add_line(blk, 'Controller/5', 'AudioEngine/2', 'autorouting', 'on');     % alertOn drives the audio engine
add_line(blk, 'Controller/4', 'sirenOn/1',  'autorouting', 'on');        % also exported for logging and the app
add_line(blk, 'Controller/5', 'alertOn/1',  'autorouting', 'on');
add_line(blk, 'Controller/6', 'uiNode/1',   'autorouting', 'on');
add_line(blk, 'Controller/7', 'uiStatus/1', 'autorouting', 'on');
add_line(blk, 'Controller/8', 'uiBreach/1', 'autorouting', 'on');
add_line(blk, 'Controller/9', 'uiLive/1',   'autorouting', 'on');
add_line(blk, 'Controller/10','uiLog/1',    'autorouting', 'on');
add_line(blk, 'AudioEngine/1','audio/1',    'autorouting', 'on');
end

% ------------------------------------------------------------------------
function set_mlfb_script(blkPath, code)
%SET_MLFB_SCRIPT  Put source text into a MATLAB Function block.
%   Under the hood a MATLAB Function block is a Stateflow "EMChart" object.
%   sfroot is the root of all Stateflow objects, find() searches it by
%   path, and the .Script property is the code editor text.
rt = sfroot;
ch = rt.find('-isa', 'Stateflow.EMChart', 'Path', blkPath);
ch.Script = code;
end

% ------------------------------------------------------------------------
function c = controller_code()
%CONTROLLER_CODE  Source text of the Controller block, returned as one string.
%   Each quoted line below is one line of the generated code. strjoin glues
%   them with newlines. Inside a quoted string a single quote must be
%   doubled ('' means one '), which is why you see '' in the code below.
%   The Controller keeps both state structs and runs node_step and
%   console_step every step. Only the one matching "role" is active.
c = strjoin({
'function [tx, txEn, torch, sirenOn, alertOn, uiNode, uiStatus, uiBreach, uiLive, uiLog] = controller(role, lux, ori, gyro, gps, epoch, rx, rxSize, btnArm, btnSiren, btnAck)'
'%#codegen'
'% Runs the Security Node and the Monitoring Console logic. Only the role'
'% selected by "role" is active, the other one is held in reset.'
'% Load the constants once at compile time so they become C literals.'
'P = coder.const(ids_params());'
'% "persistent" = a C static variable. Values survive between calls, which'
'% is how the block remembers its state from one 0.1 s step to the next.'
'persistent N C'
'if isempty(N)                     % true only on the very first call'
'    N = node_init();'
'    C = console_init(P.logLen);'
'end'
'% role comes from the Button: 1 = node, 2 = console. Comparing with 1.5 is'
'% robust to float or integer typing of the signal.'
'isNode = double(role(1)) < 1.5;'
'% Convert Simulink signals to plain doubles for the step functions.'
'rxd = double(rx(:));'
'rxs = double(rxSize(1));'
't   = double(epoch(1));'
'% Both state machines run every step. The inactive one gets active = false'
'% and just resets itself. The transpose (apostrophe) makes row vectors.'
'[N, txN, enN, torchD, uiNode] = node_step(N, isNode, double(lux(1)), double(ori(:)''), double(gyro(:)''), double(gps(:)''), t, rxd, rxs, P);'
'[C, txC, enC, uiStatus, uiBreach, uiLive, uiLog] = console_step(C, ~isNode, double(btnArm(1)), double(btnSiren(1)), double(btnAck(1)), t, rxd, rxs, P);'
'% Pick the packet of the active role.'
'if isNode'
'    tx = txN;'
'    txEn = enN;'
'else'
'    tx = txC;'
'    txEn = enC;'
'end'
'% Outputs for the rest of the diagram. The Android ToApp block needs an int32.'
'torch   = int32(torchD);'
'sirenOn = double(isNode && N.siren > 0);'
'alertOn = double(~isNode && C.alert > 0);'
'end'
}, newline);
end

% ------------------------------------------------------------------------
function c = audio_code()
%AUDIO_CODE  Source text of the AudioEngine block, returned as one string.
%   Same trick as controller_code. The block calls audio_step once per step
%   and keeps the oscillator state in a persistent variable.
c = strjoin({
'function audio = audio_engine(sirenOn, alertOn)'
'%#codegen'
'P = coder.const(ids_params());'
'persistent A                      % audio state kept between steps'
'if isempty(A)'
'    A = audio_init();'
'end'
'% coder.load reads alert_message.mat while the code is being generated, so'
'% the recorded message becomes a constant array inside the app.'
'S = coder.load(''alert_message.mat'', ''msg'');'
'[A, audio] = audio_step(A, sirenOn, alertOn, S.msg, P);'
'end'
}, newline);
end
