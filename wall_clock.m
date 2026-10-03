function t = wall_clock()
%WALL_CLOCK  Seconds since 1970-01-01 UTC.
%   On the phone (generated C) this calls time(NULL) from the NDK libc.
%   In a desktop simulation it asks MATLAB for the host clock.
%
%   One source file, three execution contexts. coder.target() tells the code
%   where it is running. This works like an #ifdef in C++.
%     'MATLAB' = plain MATLAB on the PC
%     'Rtw'    = code generation for the phone (the C code is being built)
%     other    = Simulink simulating a MATLAB Function block on the PC
%
% host_epoch cannot be compiled, so it is declared "extrinsic" (called back
% through MATLAB at run time). coder.extrinsic must sit at the top of the
% function, not inside an if, so it is declared here for every context. It
% has no effect in plain MATLAB, and the phone build never reaches the call.
coder.extrinsic('host_epoch');
t = 0;                                        % must be defined on every path (codegen rule)
if coder.target('MATLAB')
    % Plain MATLAB: call the normal helper.
    t = host_epoch();
elseif coder.target('Rtw')
    % Phone build: emit a real call to C's time(NULL) in the generated code.
    % tt is kept as C's own time_t ("opaque" = MATLAB passes it through
    % untouched). Declaring it int64 fails on 32-bit ARM phones, where
    % Simulink emulates int64 as a struct that time() cannot be assigned to.
    coder.cinclude('<time.h>');               % adds #include <time.h> to the generated C
    tt = coder.opaque('time_t', '0');         % declares: time_t tt = 0;
    tt = coder.ceval('time', coder.opaque('time_t *', 'NULL'));   % tt = time(NULL)
    % difftime(a, b) is standard C and returns (a - b) as a double, so this
    % converts time_t to double without any cast MATLAB has to understand.
    t = coder.ceval('difftime', tt, coder.opaque('time_t', '0'));
else
    % Simulink simulation on the PC: call host_epoch at run time through
    % MATLAB instead of compiling it (declared extrinsic above).
    t = host_epoch();
end
end
