classdef FmriFakeBackend < handle
    % Deterministic display/clock fixture, not used by production entry points.
    properties
        ifi=1/60
        time=1000
        origin=1000.1
        stall_at_s=Inf
        stall_seconds=1
        stalled=false
        read_stall_frame=Inf
        read_stalled=false
        abort_at_s=Inf
        key_schedule=zeros(0,2)
        key_sent=false(0,1)
    end
    methods
        function t=now(obj), t=obj.time; end
        function waitUntil(obj,t)
            obj.time=max(obj.time,t);
            if ~obj.stalled && obj.time-obj.origin>=obj.stall_at_s
                obj.time=obj.time+obj.stall_seconds; obj.stalled=true;
            end
        end
        function [a,b,c,d]=flip(obj,when)
            target=max(obj.time,when);
            a=ceil((target-1e-9)/obj.ifi)*obj.ifi;
            obj.time=a+0.00002; b=a; c=obj.time;
            if when>0, d=a-when-obj.ifi; else, d=0; end
        end
        function draw(obj,~,~,~,~), obj.time=obj.time+0.00005; end
        function t=firstTexture(~,~), t=1; end
        function [n,r]=videoInfo(~,~), n=360; r=60; end
        function frame=readFrame(obj,~,index)
            if index==obj.read_stall_frame && ~obj.read_stalled
                obj.time=obj.time+0.2; obj.read_stalled=true;
            end
            frame=zeros(2,2,3,'uint8');
        end
        function t=makeTexture(obj,~), t=1; obj.time=obj.time+0.00005; end
        function closeTexture(~,~), end
        function close(~), end
        function [codes,times]=read(obj)
            if obj.time-obj.origin>=obj.abort_at_s
                error('test:InjectedAbort','Intentional partial-run abort.');
            end
            codes=false(1,256); times=zeros(1,256);
            if isempty(obj.key_schedule), return; end
            due=find(~obj.key_sent & obj.key_schedule(:,1)<=obj.time);
            for i=due(:)'
                key=obj.key_schedule(i,2);
                if times(key)==0, times(key)=obj.key_schedule(i,1); end
                codes(key)=true; obj.key_sent(i)=true;
            end
        end
    end
end
