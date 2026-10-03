function mdl = build_android_model(varargin)
%BUILD_ANDROID_MODEL  Build the deployable Simulink app (one app, both roles).
%
%   build_android_model                       default build
%   build_android_model('PeerIP','192.168.43.1')   unicast instead of broadcast
%   build_android_model('EnableTorch',false)  skip the camera-LED ToApp hook
%   build_android_model('AllowStubs',true)    build with placeholder blocks when
%                                             the Android support package is not
%                                             installed (review / desktop only)
%
%   Uses blocks from "Simulink Support Package for Android Devices":
%   Light Sensor, Orientation, Gyroscope, Location Sensor, UDP Receive,
%   UDP Send, Audio Playback, Button, Data Display, ToApp.
%
%   Layout of this file
%     1. parse options and sanity checks
%     2. create the empty model
%     3. add the SecurityCore (the logic, tested on the PC)
%     4. add sensors, clock, UDP receive and buttons on the left (inputs)
%     5. add UDP send, speaker, LED hook and displays on the right (outputs)
%     6. helper functions at the bottom (library search, block placement, ...)
%   The script only places blocks and draws wires. All behaviour is in the
%   .m files called by SecurityCore. Compare it with a top-level C++ main()
%   that creates objects and connects them.

% ---- 1. options ----
% varargin = the "*args" list. inputParser handles name-value pairs such as
% build_android_model('PeerIP','192.168.43.1') and fills in defaults, like
% keyword arguments with default values in Python.
ip = inputParser;
addParameter(ip, 'ModelName',   'ids_android_app');
addParameter(ip, 'EnableTorch', true);
addParameter(ip, 'PeerIP',      '255.255.255.255');   % broadcast address, reaches every phone on the Wi-Fi
addParameter(ip, 'AllowStubs',  false);
parse(ip, varargin{:});                       % varargin{:} unpacks the list, like f(*args)
o = ip.Results;                               % struct with the final option values
mdl = o.ModelName;

% ---- folder, alert audio file and constants ----
here = fileparts(mfilename('fullpath'));
addpath(here);
if ~isfile(fullfile(here, 'alert_message.mat'))
    make_alert_audio();                       % the app embeds this recording
end
P = ids_params();

% ---- is the Android support package installed? ----
lib = find_android_library();                 % library name or '' if not installed
stub = isempty(lib);                          % stub = build with placeholder blocks
if stub && ~o.AllowStubs
    % Stop with an install hint. error() is like "raise" in Python, throw in C++.
    error(['Simulink Support Package for Android Devices was not found.\n' ...
           'Install it (Home > Add-Ons > Get Hardware Support Packages > "Android"),\n' ...
           'run androidhwsetup, then call build_android_model again.\n' ...
           'Use build_android_model(''AllowStubs'',true) to build a placeholder copy.'], []);
end
if stub
    warning('Android library not found: building with PLACEHOLDER blocks (cannot be deployed).');
    mdl = [mdl '_stub'];                      % different file name so a stub can never be mistaken for the real app
end

% ---- 2. create the empty model ----
if bdIsLoaded(mdl), close_system(mdl, 0); end     % close an open old copy without saving
f = fullfile(here, [mdl '.slx']);
if isfile(f), delete(f); end                      % remove an old file
new_system(mdl);
% Fixed step discrete = the same clocked behaviour as in the harness.
% StopTime inf means the app keeps running on the phone until stopped.
set_param(mdl, 'Solver', 'FixedStepDiscrete', 'FixedStep', num2str(P.Ts), 'StopTime', 'inf');
if ~stub
    try
        set_param(mdl, 'HardwareBoard', 'Android Device');    % selects the Android code generation target
    catch err
        warning('Could not select the Android Device board automatically (%s). Select it in Model Settings > Hardware Implementation.', err.message);
    end
    % Build 64-bit (arm64-v8a) native code. The default is 32-bit only, which
    % newer phones such as the Galaxy S24 refuse to install
    % (INSTALL_FAILED_NO_MATCHING_ABIS). Older 64-bit devices run it too.
    try
        cs = getActiveConfigSet(mdl);
        td = get_param(cs, 'CoderTargetData');            % struct of Android target options
        td.AppOptions.Enable64bitbuild = 1;
        set_param(cs, 'CoderTargetData', td);
    catch err
        warning('Could not enable the 64-bit build (%s). Tick it in Model Settings > Hardware Implementation > App options.', err.message);
    end
end
Ts = num2str(P.Ts);                           % sample time as text, since block parameters are strings

% ------------------------------------------------------------------ core
% 3. SecurityCore subsystem (same one the PC harness tests).
% coreIn(k) is a small function that gives the path of core input port k.
% "@(k) ..." is an anonymous function (Python lambda).
core = build_security_core(mdl, 'SecurityCore', [620 80 860 700]);
coreIn = @(k) sprintf('SecurityCore/%d', k);

% ------------------------------------------------------------------ sensors
% 4a. Four sensor blocks stacked down the left side. Each gets its sample
% time set and a Data Type Conversion to double, then goes to a core input.
% {name, core input port}. Rows are separated by ";" and columns by ",".
y = 60;                                       % vertical position, moved down after every block
sensors = {'Light Sensor', 2; 'Orientation', 3; 'Gyroscope', 4; 'Location Sensor', 5};
for k = 1:size(sensors, 1)                    % size(x, 1) = number of rows
    b = place(lib, sensors{k,1}, [mdl '/' sensors{k,1}], [40 y 140 y+50], stub);
    setp(b, '^sample ?time$', Ts);
    to_double(mdl, b, sensors{k,1}, coreIn(sensors{k,2}), [260 y]);
    y = y + 90;
end

% 4b. wall clock -> epoch
% A MATLAB Function block whose only job is to call wall_clock(), so the
% generated C contains time(NULL).
clk = [mdl '/WallClock'];
add_block('simulink/User-Defined Functions/MATLAB Function', clk, 'Position', [40 y 140 y+50]);
rt = sfroot;
ch = rt.find('-isa', 'Stateflow.EMChart', 'Path', clk);
% In this sprintf "\n" is a newline and "%%" prints one literal "%".
ch.Script = sprintf('function t = wallclock()\n%% Unix time from the phone clock (time(NULL) in the generated C)\nt = wall_clock();\n');
% Make the block run at Ts. If this MATLAB version has no such property
% the try/catch quietly skips it (try/except pass).
try
    ch.ChartUpdate = 'DISCRETE';
    ch.SampleTime  = Ts;
catch
end
add_line(mdl, 'WallClock/1', coreIn(6), 'autorouting', 'on');
y = y + 90;

% 4c. UDP receive -> rx, rxSize
% setp looks up a block mask parameter by its on-screen label (regex) and
% sets it. See setp below. Block outputs: 1 = data, 2 = received size.
udpR = place(lib, 'UDP Receive', [mdl '/UDP Receive'], [40 y 140 y+60], stub);
setp(udpR, '^localPort$', num2str(P.UDP_PORT));
setp(udpR, '^signalDatatype$', 'double');
setp(udpR, '^dims$', num2str(P.PKT_LEN));
% The receive buffer is in bytes. 16 doubles = 128 bytes, so the default of 16 is far too small.
setp(udpR, '^recvBufferSize$', '1024');
setp(udpR, '^sample ?time$', Ts);
ph = get_param(udpR, 'PortHandles');          % struct of the block's port handles
add_line(mdl, 'UDP Receive/1', coreIn(7), 'autorouting', 'on');
if numel(ph.Outport) >= 2
    to_double(mdl, udpR, 'UDP Receive', coreIn(8), [260 y+30], 2);
else
    % Older block versions have no size output. Treat every step as fresh
    % (size 1). The packet checks in packet_ok still reject garbage.
    warning('UDP Receive has no Size port: every step is treated as a fresh packet.');
    add_block('simulink/Sources/Constant', [mdl '/rxSizeConst'], 'Value', '1', 'Position', [260 y+30 300 y+50]);
    add_line(mdl, 'rxSizeConst/1', coreIn(8));
end
y = y + 100;

% ------------------------------------------------------------------ buttons
% 4d. Four Button widgets {label, core input port}. The first selects the role.
% Block names must be valid identifiers. The Android blocks use them as struct field names.
btns = {'ConsoleMode', 1; 'ArmDisarm', 9; 'SirenToggle', 10; 'AckAlert', 11};
for k = 1:size(btns, 1)
    nm = btns{k,1};                           % button label, also used as the block name
    b = place(lib, 'Button', [mdl '/' nm], [40 y 140 y+40], stub);
    setp(b, '^(label|text|title)$', nm, true);   % true = optional, do not warn if there is no such field
    setp(b, '^sample ?time$', Ts);
    if k == 1
        % role = 1 (Security Node) when released, 2 (Monitoring Console) when pressed
        % The button gives 0 or 1, and a Bias block adds 1.
        to_double(mdl, b, nm, '', [260 y]);
        add_block('simulink/Math Operations/Bias', [mdl '/RoleSelect'], 'Bias', '1', 'Position', [380 y 420 y+30]);
        add_line(mdl, [nm ' dbl/1'], 'RoleSelect/1');
        add_line(mdl, 'RoleSelect/1', coreIn(1), 'autorouting', 'on');
    else
        to_double(mdl, b, nm, coreIn(btns{k,2}), [260 y]);
    end
    y = y + 70;
end

% ------------------------------------------------------------------ outputs
% 5a. UDP Send only when the core asks for it (heartbeat or event).
% An Enabled Subsystem runs only while its Enable input is true. The core
% output txEn drives the Enable port, and the packet goes through In1.
tx = [mdl '/Transmit'];
add_block('simulink/Ports & Subsystems/Enabled Subsystem', tx, 'Position', [1000 60 1120 130]);
delete_line(tx, 'In1/1', 'Out1/1');           % the template has In1 -> Out1, remove it
delete_block([tx '/Out1']);
udpS = place(lib, 'UDP Send', [tx '/UDP Send'], [200 40 300 90], stub);
setp(udpS, '^remoteURL$', o.PeerIP);
setp(udpS, '^remotePort$', num2str(P.UDP_PORT));
add_line(tx, 'In1/1', 'UDP Send/1');
add_line(mdl, 'SecurityCore/1', 'Transmit/1', 'autorouting', 'on');
add_line(mdl, 'SecurityCore/2', 'Transmit/Enable', 'autorouting', 'on');

% 5b. speaker: the core's audio frame (4410x2 int16) at 44.1 kHz
ap = place(lib, 'Audio Playback', [mdl '/Audio Playback'], [1000 170 1120 230], stub);
setp(ap, '^SampleFreq$', num2str(P.Fs));
add_line(mdl, 'SecurityCore/3', 'Audio Playback/1', 'autorouting', 'on');

% 5c. camera LED: the ToApp block calls the Java method TorchControl(int[])
% that patch_android_torch adds. Without the hook the signal is terminated.
if o.EnableTorch
    ta = place(lib, 'ToApp', [mdl '/CameraLED'], [1000 260 1120 310], stub);
    setp(ta, '^FunctionName$', 'TorchControl');
    setp(ta, '^NumInputs$', '1');
    add_line(mdl, 'SecurityCore/4', 'CameraLED/1', 'autorouting', 'on');
else
    add_block('simulink/Sinks/Terminator', [mdl '/torchTerm'], 'Position', [1000 270 1020 290]);
    add_line(mdl, 'SecurityCore/4', 'torchTerm/1');
end

% 5d. Data Display widgets, one per UI vector coming out of the core.
% Rows: {core output port, label}. The trailing "..." joins the rows into one matrix.
disp_list = {5, 'NodeStatus'; ...
             6, 'ConsoleStatus'; ...
             7, 'BreachInfo'; ...
             8, 'NodeLive'; ...
             9, 'BreachLog'};
yy = 350;
for k = 1:size(disp_list, 1)
    nm = disp_list{k,2};
    b = place(lib, 'Data Display', [mdl '/' nm], [1000 yy 1160 yy+40], stub);
    setp(b, '^(label|text|title)$', nm, true);
    add_line(mdl, sprintf('SecurityCore/%d', disp_list{k,1}), [nm '/1'], 'autorouting', 'on');
    yy = yy + 70;
end
% Core outputs 10 and 11 (sirenOn, alertOn) are only for the PC logs, so end them in terminators.
for k = 10:11
    tn = sprintf('%s/term%d', mdl, k);
    add_block('simulink/Sinks/Terminator', tn, 'Position', [1000 yy 1020 yy+20]);
    add_line(mdl, sprintf('SecurityCore/%d', k), sprintf('term%d/1', k), 'autorouting', 'on');
    yy = yy + 40;
end

% ---- notes on the canvas, tidy layout and save ----
add_annotation(mdl, stub, o, P);
try
    Simulink.BlockDiagram.arrangeSystem(mdl); % cosmetic only, ignore failures
catch
end
save_system(mdl, f);
fprintf('\nSaved %s\n', f);
if ~stub
    fprintf(['Next: Hardware tab > Build (drop-down, "Build" only), then run\n' ...
             '      patch_android_torch(''%s'')\n' ...
             '  or, without the LED hook: build_android_model(''EnableTorch'',false) and\n' ...
             '      Hardware tab > Build, Deploy & Start.\n'], mdl);
end
end

% ========================================================================
function lib = find_android_library()
%FIND_ANDROID_LIBRARY  Name of the Android block library, or '' if missing.
%   Strategy 1: try the known library names. exist(name,'file') == 4 means
%   "a Simulink model or library file with that name is on the path".
%   Strategy 2: look for the support package's slblocks.m (the file that
%   tells Simulink what to show in the Library Browser).
lib = '';
for c = {'androidlib', 'android_lib', 'androidlibrary', 'androiddeviceslib'}
    if exist(c{1}, 'file') == 4
        lib = c{1};
        return;
    end
end
w = which('slblocks', '-all');                % all slblocks.m files on the path
for k = 1:numel(w)
    if isempty(regexpi(w{k}, 'android', 'once')), continue; end    % skip the ones not under an "android" folder
    old = cd(fileparts(w{k}));                % slblocks must be called from its own folder
    try
        bs = slblocks();                      % returns the Library Browser description
        cd(old);                              % go back to where we were
        cand = bs.Browser(1).Library;
        if exist(cand, 'file') == 4
            lib = cand;
            return;
        end
    catch
        cd(old);                              % restore the folder if slblocks failed
    end
end
end

% ------------------------------------------------------------------------
function src = find_lib_block(lib, name)
% Locate a block by name in the library or any of its sub-libraries.
% The Android library is a top level library whose entries open
% sub-libraries (Sensors, Network, ...). So we collect those first, then
% search the top library and each sub-library, going deeper step by step.
src = '';
libs = {lib};                                 % list of libraries to search
load_system(lib);
top = find_system(lib, 'SearchDepth', 1, 'Type', 'block');
for k = 1:numel(top)
    fcn = get_param(top{k}, 'OpenFcn');       % the command run when the block is double clicked
    tok = regexp(fcn, '([A-Za-z]\w*)', 'tokens', 'once');   % first word of it, the sub-library name
    if ~isempty(tok) && exist(tok{1}, 'file') == 4
        libs{end+1} = tok{1}; %#ok<AGROW>     % append to the list
    end
end
pat = ['^' regexptranslate('escape', name) '$'];     % exact-name regex
for depth = 1:4
    for L = 1:numel(libs)
        load_system(libs{L});
        h = find_system(libs{L}, 'SearchDepth', depth, 'LookUnderMasks', 'all', ...
            'FollowLinks', 'on', 'Regexp', 'on', 'Name', pat);
        if ~isempty(h)
            src = h{1};                       % full path of the library block
            return;
        end
    end
end
end

% ------------------------------------------------------------------------
function b = place(lib, name, dst, pos, stub)
%PLACE  Add a block called "name" to the model at path dst, return dst.
%   With stub = true an orange placeholder is made instead of the library block.
if stub
    make_stub(name, dst, pos);
else
    src = find_lib_block(lib, name);
    if isempty(src)
        error('Block "%s" not found in the Android library "%s".', name, lib);
    end
    add_block(src, dst, 'Position', pos);     % copy the library block into the model
end
b = dst;
end

% ------------------------------------------------------------------------
function setp(blk, promptRegex, value, optional)
%SETP  Set a block parameter found by a regular expression.
%   Library blocks show a dialog with labels such as "Sample time". Their
%   internal names vary between versions, so we search the labels with a
%   regular expression and set the matching parameter. If nothing matches
%   we warn (unless optional), so the user can set it by hand.
if nargin < 4, optional = false; end
if ~strcmp(get_param(blk, 'Mask'), 'on')
    return;                                   % not a masked block, nothing to set
end
names   = get_param(blk, 'MaskNames');        % internal parameter names
prompts = get_param(blk, 'MaskPrompts');      % labels shown in the dialog
idx = find(~cellfun(@isempty, regexpi(names, promptRegex, 'once')), 1);     % first internal name that matches
if isempty(idx)
    idx = find(~cellfun(@isempty, regexpi(prompts, promptRegex, 'once')), 1);   % else first label that matches
end
if isempty(idx)
    if ~optional
        warning('%s: no mask parameter matching "%s" (set it by hand).', blk, promptRegex);
    end
    return;
end
% evaluated edit fields that expect a string need quotes
% Mask variables marked "@" are evaluated as MATLAB expressions, so a text
% value must be wrapped in quotes to be seen as a string and not a variable name.
vars = get_param(blk, 'MaskVariables');
tok = regexp(vars, [names{idx} '=([@&])'], 'tokens', 'once');
styles = get_param(blk, 'MaskStyles');
isEdit = strcmp(styles{idx}, 'edit');
if isEdit && ~isempty(tok) && tok{1} == '@' && isnan(str2double(value)) && isempty(regexp(value, '^[\[''{]', 'once'))
    value = ['''' value ''''];                % '''' is a string holding one quote character
end
try
    set_param(blk, names{idx}, value);
catch err
    warning('%s: could not set "%s" to %s (%s)', blk, prompts{idx}, value, err.message);
end
end

% ------------------------------------------------------------------------
function to_double(mdl, blk, nm, dst, xy, port)
% Mux multi-port sensors into one vector and cast to double.
% Sensor blocks output several ports (x, y, z) and various types. The core
% wants one double vector, so: Mux (join ports) -> Data Type Conversion ->
% destination. port > 0 means "take only that one output port" (used for
% the UDP size output). dst = '' means "do not connect the result yet".
if nargin < 6, port = 0; end
[~, bn] = fileparts(blk);                     % block name without the model path
ph = get_param(blk, 'PortHandles');
cv = [mdl '/' nm ' dbl'];
if port > 0
    cv = [mdl '/' nm ' size'];
end
add_block('simulink/Signal Attributes/Data Type Conversion', cv, 'OutDataTypeStr', 'double', ...
    'Position', [xy(1)+60 xy(2) xy(1)+100 xy(2)+30]);
[~, cvn] = fileparts(cv);
if port > 0
    add_line(mdl, sprintf('%s/%d', bn, port), [cvn '/1'], 'autorouting', 'on');
elseif numel(ph.Outport) > 1
    % several output ports: join them into one vector with a Mux
    mx = [mdl '/' nm ' mux'];
    add_block('simulink/Signal Routing/Mux', mx, 'Inputs', num2str(numel(ph.Outport)), ...
        'Position', [xy(1) xy(2) xy(1)+10 xy(2)+50]);
    [~, mxn] = fileparts(mx);
    for k = 1:numel(ph.Outport)
        add_line(mdl, sprintf('%s/%d', bn, k), sprintf('%s/%d', mxn, k), 'autorouting', 'on');
    end
    add_line(mdl, [mxn '/1'], [cvn '/1']);
else
    add_line(mdl, [bn '/1'], [cvn '/1'], 'autorouting', 'on');
end
if ~isempty(dst)
    add_line(mdl, [cvn '/1'], dst, 'autorouting', 'on');
end
end

% ------------------------------------------------------------------------
function make_stub(kind, dst, pos)
% Placeholder with the same interface as the real Android block.
% Used only for AllowStubs builds on a PC without the support package, so
% the diagram can still be opened and reviewed. Sensors become constants.
add_block('simulink/Ports & Subsystems/Subsystem', dst, 'Position', pos);
delete_line(dst, 'In1/1', 'Out1/1');
delete_block([dst '/In1']);
delete_block([dst '/Out1']);
set_param(dst, 'BackgroundColor', 'orange');  % orange = fake, so it is obvious in the diagram
outs = {};                                    % constant values for the output ports
nIn = 0;                                      % number of input ports (sink-like blocks)
switch kind                                   % switch/case, no fall-through and no break needed
    case 'Light Sensor',    outs = {'single(0.5)'};
    case 'Orientation',     outs = {'single([0 0 0])'};
    case 'Gyroscope',       outs = {'single([0 0 0])'};
    case 'Location Sensor', outs = {'[0 0 0]'};
    case 'UDP Receive',     outs = {'zeros(16,1)', 'uint16(0)'};
    case 'Button',          outs = {'false'};
    otherwise,              nIn = 1;          % sink blocks (UDP Send, Audio, ToApp, Data Display)
end
for k = 1:numel(outs)
    add_block('simulink/Sources/Constant', sprintf('%s/c%d', dst, k), 'Value', outs{k}, ...
        'SampleTime', '0.1', 'Position', [60 40*k 120 40*k+20]);
    add_block('simulink/Sinks/Out1', sprintf('%s/y%d', dst, k), 'Position', [200 40*k 230 40*k+14]);
    add_line(dst, sprintf('c%d/1', k), sprintf('y%d/1', k));
end
for k = 1:nIn
    add_block('simulink/Sources/In1', sprintf('%s/u%d', dst, k), 'Position', [60 40*k 90 40*k+14]);
    add_block('simulink/Sinks/Terminator', sprintf('%s/t%d', dst, k), 'Position', [200 40*k 220 40*k+20]);
    add_line(dst, sprintf('u%d/1', k), sprintf('t%d/1', k));
end
end

% ------------------------------------------------------------------------
function add_annotation(mdl, stub, o, P)
%ADD_ANNOTATION  Write a short legend (ports, states, cause bits) on the canvas.
% sprintf fills %d and %s with the given values, in order.
txt = sprintf(['Mobile Intrusion Detection  (one app, both roles)\n' ...
    'Button "ConsoleMode": released = Security Node (Phone A), pressed = Monitoring Console (Phone B)\n' ...
    'UDP port %d, peer %s, pair ID %d. Heartbeat 0.5 s, commands re-sent until confirmed.\n' ...
    'Node states: 0 DISARMED, 1 ARMING (5 s exit delay), 2 ARMED, 3 ALARM. Cause bits: 1 light, 2 tilt, 4 motion, 8 link lost.\n' ...
    'Times shown as YYYYMMDD and HHMMSS (IST).'], P.UDP_PORT, o.PeerIP, P.PAIR_ID);
if stub
    txt = [txt newline 'PLACEHOLDER BUILD: orange blocks stand in for Android blocks. Not deployable.'];
end
a = Simulink.Annotation([mdl '/note']);       % a text note on the canvas
a.Text = txt;
a.Position = [40 -140 900 -40];
end
