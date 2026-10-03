function t = host_epoch()
%HOST_EPOCH  Unix time of the host PC (used only during desktop simulation).
%   This cannot be turned into C, which is why wall_clock only calls it
%   outside of code generation.
%   datetime('now', 'TimeZone', 'UTC') is MATLAB's date object (Python's
%   datetime.now(timezone.utc)). posixtime() converts it to seconds since
%   1970, the same number as time.time() in Python.
t = posixtime(datetime('now', 'TimeZone', 'UTC'));
end
