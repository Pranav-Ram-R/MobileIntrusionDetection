function ok = packet_ok(rx, rxSize, msgType, P)
%PACKET_OK  True if rx holds a fresh, well-formed packet of the given type
%   from our own pair. Also filters out our own broadcasts, because a node
%   only accepts TYPE_CMD and a console only accepts TYPE_STATUS.
%
%   Python analogy: a validate(packet) function that returns a bool and
%   never raises. Early "return" statements work exactly as in Python/C++.
ok = false;                                   % default answer is "reject"

% 1) Is there a fresh packet at all? The UDP Receive block outputs a
%    buffer every step and reports the received length in rxSize (0 = none).
if rxSize <= 0 || numel(rx) < P.PKT_LEN       % numel = number of elements (len())
    return;
end

% 2) Reject NaN / Inf garbage. rx(1:P.PKT_LEN) is a slice. MATLAB is
%    1-based and the end index is inclusive, so this is Python's rx[0:16].
if ~all(isfinite(rx(1:P.PKT_LEN)))            % "~" is logical NOT (! in C++)
    return;
end

% 3) Header and trailer checks: magic word, message type, pair id.
%    "&&" short-circuits just like in C++ and Python's "and".
ok = (rx(1) == P.MAGIC) && (rx(2) == msgType) && (rx(P.PKT_LEN) == P.PAIR_ID);
end
