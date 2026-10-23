classdef FmriTimingDiagnosticBackend < FmriFakeBackend
    % Wall-clock observations of the unchanged engine on a virtual display.
    % No media files, GPU operations, sleeps or production code changes.
    properties
        gaps=zeros(1000,6)
        gap_count=0
        previous_wall=NaN
        last_kind=0
        last_trial=0
        flips=0
        flip_wall=zeros(20000,4)
    end
    methods
        function t=now(obj)
            wall=GetSecs;
            if isfinite(obj.previous_wall) && wall-obj.previous_wall>0.005
                obj.gap_count=obj.gap_count+1;
                obj.gaps(obj.gap_count,:)=[obj.last_kind obj.last_trial obj.flips ...
                    obj.time-obj.origin wall-obj.previous_wall wall];
            end
            obj.previous_wall=wall;
            t=obj.time;
        end
        function draw(obj,kind,trial,ack,texture)
            names={'initial_dummy_scans','prepare','view_video','post_video_hold', ...
                'one_back_choice','iti','final_rest','run_end','touch_shape','release_hold'};
            obj.last_kind=find(strcmp(names,kind),1); obj.last_trial=trial;
            draw@FmriFakeBackend(obj,kind,trial,ack,texture);
        end
        function [a,b,c,d]=flip(obj,when)
            wall=GetSecs;
            [a,b,c,d]=flip@FmriFakeBackend(obj,when);
            obj.flips=obj.flips+1;
            obj.flip_wall(obj.flips,:)=[obj.last_kind obj.last_trial wall GetSecs];
        end
    end
end
