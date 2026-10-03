function a = wrap180(a)
%WRAP180  Wrap an angle in degrees to [-180, 180).
%   Needed because compass azimuth jumps from 359 to 0. The difference
%   359 - 1 should be -2 degrees, not 358. Works on scalars and arrays.
%   Example: wrap180(358) = -2, wrap180(-190) = 170.
%   (The same as ((a + 180) mod 360) - 180 using a floored modulo.)
a = a - 360*floor((a + 180)/360);   % subtract whole turns until in range
end
