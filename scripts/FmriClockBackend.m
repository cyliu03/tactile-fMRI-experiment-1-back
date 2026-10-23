classdef FmriClockBackend < handle
    % Real-clock, no-screen selftest backend. Does not validate visual timing.
    properties (SetAccess = private)
        ifi = 0.001
    end
    methods
        function t=now(~), t=GetSecs; end
        function waitUntil(~,t), WaitSecs('UntilTime',t); end
        function [a,b,c,d]=flip(~,when)
            if when>0, WaitSecs('UntilTime',when+0.0005); end
            a=GetSecs; b=a; c=a; d=NaN;
        end
        function draw(~,~,~,~,~), end
        function texture=firstTexture(~,~), texture=1; end
        function [count,rate]=videoInfo(~,~), count=1; rate=60; end
        function frame=readFrame(~,~,~), frame=zeros(1,1,3,'uint8'); end
        function texture=makeTexture(~,~), texture=1; end
        function closeTexture(~,~), end
        function close(~), end
    end
end
