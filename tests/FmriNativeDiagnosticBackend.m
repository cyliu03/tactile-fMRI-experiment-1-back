classdef FmriNativeDiagnosticBackend < handle
    % Native display diagnostic only: one explicitly injected final-frame delay.
    properties
        ifi
        inner
        last_frame=0
        stalled=false
        stall_seconds=0.20
        stall_frame=355
    end
    methods
        function obj=FmriNativeDiagnosticBackend(inner)
            obj.inner=inner; obj.ifi=inner.ifi;
        end
        function t=now(~),t=GetSecs;end
        function waitUntil(~,t),WaitSecs('UntilTime',t);end
        function [a,b,c,d]=flip(obj,t),[a,b,c,d]=obj.inner.flip(t);end
        function draw(obj,k,i,a,t),obj.inner.draw(k,i,a,t);end
        function t=firstTexture(obj,i),t=obj.inner.firstTexture(i);end
        function [n,r]=videoInfo(obj,i),[n,r]=obj.inner.videoInfo(i);end
        function frame=readFrame(obj,i,f)
            obj.last_frame=f;frame=obj.inner.readFrame(i,f);
        end
        function t=makeTexture(obj,frame)
            if obj.last_frame>=obj.stall_frame && ~obj.stalled
                WaitSecs(obj.stall_seconds);obj.stalled=true;
            end
            t=obj.inner.makeTexture(frame);
        end
        function closeTexture(obj,t),obj.inner.closeTexture(t);end
        function close(obj),obj.inner.close();end
    end
end
