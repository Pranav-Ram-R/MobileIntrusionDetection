function [ymd, hms] = epoch_to_civil(epoch, tzOffsetSec)
%EPOCH_TO_CIVIL  Unix time (s, UTC) -> local date YYYYMMDD and time HHMMSS.
%   Pure integer arithmetic (Hinnant's civil_from_days), so it generates
%   plain C for the phone. Returns zeros for epoch <= 0 (clock unknown).
%
%   Why not use MATLAB's datetime? Code generated for the phone cannot call
%   datetime, so the calendar maths is done by hand with floor() and
%   multiplication only. The result is two plain numbers, for example
%   ymd = 20261002 and hms = 143005 (14:30:05), which are easy to put in a
%   UDP packet and to print on a Data Display block.
%
%   MATLAB has two outputs here: [ymd, hms] = f(...) is like returning a
%   tuple in Python. Outputs are whatever the variables hold at the end.
ymd = 0;                                      % default outputs (clock unknown)
hms = 0;
if epoch <= 0
    return;                                   % exits early, outputs stay 0
end

% ---- split the timestamp into whole days and seconds-in-day ----
t    = floor(epoch) + tzOffsetSec;            % shift UTC to local time, drop fraction
days = floor(t/86400);                        % days since 1970-01-01 (86400 s per day)
secs = t - days*86400;                        % seconds since local midnight

% ---- days since 1970 -> calendar year/month/day (Hinnant algorithm) ----
% The algorithm counts years from 1 March, so Feb 29 falls at the END of a
% "year" and leap days need no special case. Time is grouped into 400 year
% "eras" of 146097 days, which is the full Gregorian leap cycle.
z   = days + 719468;                          % shift origin to 0000-03-01
era = floor(z/146097);                        % which 400 year era
doe = z - era*146097;                         % day of era, 0..146096
yoe = floor((doe - floor(doe/1460) + floor(doe/36524) - floor(doe/146096))/365);  % year of era, 0..399
y   = yoe + era*400;                          % year counted from March
doy = doe - (365*yoe + floor(yoe/4) - floor(yoe/100));   % day of the March-based year, 0..365
mp  = floor((5*doy + 2)/153);                 % month index, 0 = March ... 11 = February
d   = doy - floor((153*mp + 2)/5) + 1;        % day of month, 1..31
if mp < 10
    m = mp + 3;                               % March..December -> 3..12
else
    m = mp - 9;                               % January, February -> 1, 2
end
if m <= 2
    y = y + 1;                                % Jan and Feb belong to the next calendar year
end

% ---- seconds-in-day -> hours, minutes, seconds ----
hh = floor(secs/3600);
mm = floor((secs - hh*3600)/60);
ss = secs - hh*3600 - mm*60;

% ---- pack as decimal numbers, easy to ship in a double and to display ----
ymd = y*10000 + m*100 + d;                    % 2026, 10, 2 -> 20261002
hms = hh*10000 + mm*100 + ss;                 % 14, 30, 5   -> 143005
end
