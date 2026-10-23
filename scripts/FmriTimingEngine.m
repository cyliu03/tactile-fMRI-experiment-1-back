classdef FmriTimingEngine < handle
    % Absolute phase deadlines, preallocated logs, and measured display bounds.
    % Large misses extend all later deadlines and invalidate timing quality;
    % they never silently consume a later stimulus/response window.
    properties (SetAccess = private)
        plan
        start_time = NaN
        actual_end = NaN
        shift_s = 0
        tolerance_s
        failure = ''
        completed = false
    end
    properties (Access = private)
        backend
        cb
        keys
        trials
        templates
        timing
        trace
        keylog
        trace_count = 0
        key_count = 0
        opened = 0
        active = 0
        last_poll_end = NaN
        acked
        response_keys
        poll_interval_s = 0.001
    end
    methods
        function obj = FmriTimingEngine(backend, cb, keys, modality, cfg, trials, iti)
            obj.backend=backend; obj.cb=cb; obj.keys=keys; obj.trials=trials;
            obj.plan=fmri_phase_plan(modality,cfg,iti);
            n=numel(obj.plan);
            obj.tolerance_s=max(0.020,2*backend.ifi);
            if isfield(cfg,'timing_poll_interval_s')
                obj.poll_interval_s=cfg.timing_poll_interval_s;
                assert(isfinite(obj.poll_interval_s) && obj.poll_interval_s>0 && obj.poll_interval_s<=0.010);
            end
            obj.timing=nan(n+1,35);
            obj.timing(:,9)=0; obj.timing(:,22:24)=0;
            obj.acked=false(numel(trials),1);
            obj.response_keys=unique([keys.yes_keys keys.no_keys]);
            for i=1:n
                p=obj.plan(i);
                if p.trial > 0, row=cb.trial_row(trials(p.trial),p.trial,p.kind);
                else, row=cb.empty_row(p.kind); end
                row.planned_onset=p.onset;
                row.planned_duration=p.duration;
                row.actual_end=NaN;
                row.onset_error=NaN;
                row.duration_error=NaN;
                row.schedule_shift=0;
                row.timing_late=0;
                if i==1, obj.templates=repmat(row,n,1); end
                obj.templates(i)=row;
                obj.timing(i,1:4)=[i p.trial p.onset p.duration];
            end
            obj.timing(n+1,1:4)=[n+1 0 obj.plannedSeconds() 0];
            capacity=numel(trials)+1;
            for i=1:n
                if strcmp(obj.plan(i).kind,'view_video')
                    [count,~]=backend.videoInfo(obj.plan(i).trial);
                    capacity=capacity+count;
                end
            end
            obj.trace=nan(capacity,19);
            obj.keylog=nan(max(10000,100*numel(trials)),4);
            % Warm callbacks before the timing origin; discard these key values.
            [~,~]=cb.read();
        end

        function seconds = plannedSeconds(obj)
            seconds=obj.plan(end).onset+obj.plan(end).duration;
        end

        function run(obj, start_time)
            assert(isnan(obj.start_time),'This timing engine already ran.');
            obj.start_time=start_time;
            try
                for i=1:numel(obj.plan)+1
                    obj.timing(i,34)=obj.backend.now()-obj.start_time;
                    obj.transition(i);
                    obj.timing(i,33)=obj.backend.now()-obj.start_time;
                    if i<=numel(obj.plan) && strcmp(obj.plan(i).kind,'view_video')
                        obj.playVideo(i);
                    end
                    obj.timing(i,35)=obj.backend.now()-obj.start_time;
                end
                obj.actual_end=obj.timing(end,13);
                obj.completed=true;
            catch ME
                obj.failure=ME.identifier;
                obj.actual_end=obj.backend.now()-obj.start_time;
                obj.closeActiveEvent(obj.actual_end);
                rethrow(ME);
            end
        end

        function rows = events(obj)
            count=min(obj.opened,numel(obj.plan));
            rows=obj.templates(1:count);
            for i=1:count
                rows(i).onset=obj.timing(i,13);
                rows(i).duration=obj.timing(i,20);
                rows(i).actual_end=obj.timing(i,19);
                rows(i).onset_error=obj.timing(i,13)-obj.plan(i).onset;
                rows(i).duration_error=obj.timing(i,21);
                rows(i).schedule_shift=obj.timing(i,18);
                rows(i).timing_late=obj.timing(i,24);
            end
            % Format response/identity strings only after the timing-critical run.
            for trial=1:numel(obj.trials)
                index=find(strcmp({rows.trial_type},'one_back_choice') & [rows.trial_index]==trial,1);
                if isempty(index), continue; end
                a=rows(index).onset; b=rows(index).actual_end;
                candidates=obj.keylog(1:obj.key_count,:);
                candidates=candidates(candidates(:,1)>=a & candidates(:,1)<b,:);
                response='no_response'; rt=NaN; correct=false;
                if ~isempty(candidates)
                    [~,first]=min(candidates(:,1));
                    key=candidates(first,2);
                    if ismember(key,obj.keys.yes_keys), response='yes'; else, response='no'; end
                    rt=candidates(first,1)-a;
                    expected='no';
                    if trial>1 && obj.trials(trial).stimulus_number==obj.trials(trial-1).stimulus_number
                        expected='yes';
                    end
                    correct=strcmp(response,expected);
                end
                for j=find([rows.trial_index]==trial)
                    rows(j).response=response; rows(j).accuracy=sprintf('%d',correct);
                    if isnan(rt), rows(j).rt='n/a'; else, rows(j).rt=sprintf('%.6f',rt); end
                end
            end
        end

        function result = summary(obj)
            result.policy='absolute_deadlines_with_explicit_extension_for_large_misses';
            result.backend=class(obj.backend);
            if isprop(obj.backend,'texture_flags'), result.texture_flags=obj.backend.texture_flags; end
            if isprop(obj.backend,'texture_fallback_frames')
                result.texture_fallback_frames=obj.backend.texture_fallback_frames;
            end
            result.planned_seconds=obj.plannedSeconds();
            result.actual_seconds=obj.actual_end;
            result.actual_minus_planned_s=obj.actual_end-result.planned_seconds;
            result.end_measured_by_flip=obj.completed;
            result.aborted=~obj.completed;
            result.failure=obj.failure;
            result.refresh_interval_s=obj.backend.ifi;
            result.lateness_tolerance_s=obj.tolerance_s;
            result.schedule_extension_s=obj.shift_s;
            result.late_phase_count=nnz(obj.timing(:,24)>0);
            result.opened_phase_count=min(obj.opened,numel(obj.plan));
            t=obj.trace(1:obj.trace_count,:);
            result.dropped_video_frames=sum(t(:,4)==1 & t(:,5)==0);
            result.late_video_frames=sum(t(:,4)==1 & t(:,5)==1 & t(:,15)-t(:,6)>obj.tolerance_s);
            result.timing_valid=obj.completed && result.late_phase_count==0 ...
                && result.dropped_video_frames==0 && result.late_video_frames==0;
            result.note='Aborted last event ends at abort observation, not a measured display offset. PTB missed values are diagnostics, not sole validity criteria.';
        end

        function paths = saveLogs(obj, folder, prefix)
            phase_names={'phase_index','trial_index','planned_onset_s','planned_duration_s', ...
                'scheduled_onset_s','transition_enter_s','draw_start_s','draw_end_s', ...
                'draw_count','wait_start_s','wait_exit_s','flip_call_s','vbl_s', ...
                'stimulus_onset_s','flip_return_s','ptb_missed_s','scheduled_onset_error_s', ...
                'schedule_shift_after_s','actual_end_s','actual_duration_s','duration_error_s', ...
                'max_poll_seconds','max_poll_gap_seconds','late_onset','last_poll_start_s','last_poll_end_s', ...
                'flip_return_observed_s','transition_entry_s','post_flip_policy_end_s', ...
                'post_flip_commit_end_s','post_flip_close_event_end_s','transition_finish_s', ...
                'run_after_transition_s','run_before_transition_s','run_iteration_end_s'};
            count=obj.opened;
            table_phase=array2table(obj.timing(1:count,:),'VariableNames',phase_names);
            kinds=[{obj.plan.kind} {'run_end'}]';
            table_phase.phase=kinds(1:count);
            paths.phases=fullfile(folder,[prefix '_timing.tsv']);
            writetable(table_phase,paths.phases,'FileType','text','Delimiter','\t');
            trace_names={'phase_index','trial_index','frame_index','action','displayed', ...
                'target_s','cache_read_start_s','cache_read_end_s','upload_start_s','upload_end_s', ...
                'draw_start_s','draw_end_s','wait_exit_s','flip_call_s','vbl_s', ...
                'stimulus_onset_s','flip_return_s','ptb_missed_s','flip_return_observed_s'};
            table_trace=array2table(obj.trace(1:obj.trace_count,:),'VariableNames',trace_names);
            paths.frames=fullfile(folder,[prefix '_frames.tsv']);
            writetable(table_trace,paths.frames,'FileType','text','Delimiter','\t');
            table_keys=array2table(obj.keylog(1:obj.key_count,:), ...
                'VariableNames',{'key_time_s','key_code','received_phase','received_time_s'});
            paths.keys=fullfile(folder,[prefix '_keypresses.tsv']);
            writetable(table_keys,paths.keys,'FileType','text','Delimiter','\t');
            paths.summary=fullfile(folder,[prefix '_timing_summary.json']);
            fid=fopen(paths.summary,'w','n','UTF-8');
            assert(fid>=0,'Cannot write timing summary.');
            guard=onCleanup(@()fclose(fid));
            fprintf(fid,'%s\n',jsonencode(obj.summary(),'PrettyPrint',true));
            clear guard;
        end
    end

    methods (Access = private)
        function transition(obj,index)
            obj.timing(index,28)=obj.backend.now()-obj.start_time;
            n=numel(obj.plan);
            if index<=n, p=obj.plan(index);
            else, p=struct('kind','run_end','trial',0,'onset',obj.plannedSeconds(),'duration',0); end
            target=obj.start_time+p.onset+obj.shift_s;
            obj.timing(index,5:6)=[target-obj.start_time obj.backend.now()-obj.start_time];
            obj.drawNext(index,p);
            obj.timing(index,10)=obj.backend.now()-obj.start_time;
            obj.waitFor(target,index,p);
            obj.timing(index,11)=obj.backend.now()-obj.start_time;
            obj.timing(index,12)=obj.backend.now()-obj.start_time;
            [vbl,onset,returned,missed]=obj.backend.flip(target-obj.backend.ifi/2);
            obj.timing(index,27)=obj.backend.now()-obj.start_time;
            relative=vbl-obj.start_time;
            late=vbl-target;
            if abs(late)>obj.tolerance_s
                if late>0, obj.shift_s=obj.shift_s+late; end
                obj.timing(index,24)=1;
            end
            obj.timing(index,29)=obj.backend.now()-obj.start_time;
            obj.timing(index,13:18)=[relative onset-obj.start_time returned-obj.start_time missed late obj.shift_s];
            obj.timing(index,30)=obj.backend.now()-obj.start_time;
            obj.closeActiveEvent(relative);
            obj.timing(index,31)=obj.backend.now()-obj.start_time;
            obj.active=index; obj.opened=index;
            if index>n
                obj.timing(index,19:21)=[relative 0 0];
            end
            obj.timing(index,32)=obj.backend.now()-obj.start_time;
        end

        function closeActiveEvent(obj, ending)
            i=obj.active;
            if i<1 || i>numel(obj.plan), return; end
            duration=max(0,ending-obj.timing(i,13));
            obj.timing(i,19:21)=[ending duration duration-obj.plan(i).duration];
        end

        function drawNext(obj,index,p)
            if isnan(obj.timing(index,7)), obj.timing(index,7)=obj.backend.now()-obj.start_time; end
            texture=[];
            if strcmp(p.kind,'view_video'), texture=obj.backend.firstTexture(p.trial); end
            obj.backend.draw(p.kind,p.trial,false,texture);
            obj.timing(index,8)=obj.backend.now()-obj.start_time;
            obj.timing(index,9)=obj.timing(index,9)+1;
        end

        function waitFor(obj,target,next,p)
            limit=target-obj.backend.ifi*0.75;
            while obj.backend.now()<limit
                ack=obj.poll();
                if ack && obj.backend.now()<target-2*obj.backend.ifi
                    obj.showAck();
                    % Ack flips replace/clear the back buffer: restore next page.
                    if next>0, obj.drawNext(next,p); end
                end
                now=obj.backend.now();
                if now<limit, obj.backend.waitUntil(min(now+obj.poll_interval_s,limit)); end
            end
        end

        function ack = poll(obj)
            begin=obj.backend.now();
            [codes,times]=obj.cb.read();
            obj.cb.triggers(times);
            ending=obj.backend.now();
            i=obj.active;
            if i>0 && i<=numel(obj.plan)
                obj.timing(i,22)=max(obj.timing(i,22),ending-begin);
                if isfinite(obj.last_poll_end)
                    obj.timing(i,23)=max(obj.timing(i,23),begin-obj.last_poll_end);
                end
                obj.timing(i,25:26)=[begin ending]-obj.start_time;
            end
            obj.last_poll_end=ending;
            if any(codes(obj.keys.escape_keys)), obj.cb.abort(); end
            hit=obj.response_keys(times(obj.response_keys)>0);
            for key=hit(:)'
                obj.key_count=obj.key_count+1;
                assert(obj.key_count<=size(obj.keylog,1),'fmri:KeyLogOverflow','Response-key log capacity exceeded.');
                obj.keylog(obj.key_count,:)=[times(key)-obj.start_time key i ending-obj.start_time];
            end
            ack=false;
            if i>0 && i<=numel(obj.plan) && strcmp(obj.plan(i).kind,'one_back_choice')
                trial=obj.plan(i).trial;
                valid=times(hit)>=obj.start_time+obj.timing(i,13);
                if ~obj.acked(trial) && any(valid)
                    obj.acked(trial)=true; ack=true;
                end
            end
        end

        function showAck(obj)
            i=obj.active; p=obj.plan(i);
            row=nan(1,19); row(1:6)=[i p.trial 0 2 1 obj.backend.now()-obj.start_time];
            row(11)=obj.backend.now()-obj.start_time;
            obj.backend.draw(p.kind,p.trial,true,[]);
            row(12)=obj.backend.now()-obj.start_time;
            row(13:14)=row(12);
            [a,b,c,d]=obj.backend.flip(0);
            row(19)=obj.backend.now()-obj.start_time;
            row(15:18)=[a-obj.start_time b-obj.start_time c-obj.start_time d];
            obj.addTrace(row);
        end

        function playVideo(obj,index)
            p=obj.plan(index); trial=p.trial;
            [count,rate]=obj.backend.videoInfo(trial);
            base=obj.start_time+obj.timing(index,13);
            boundary=obj.start_time+p.onset+p.duration+obj.shift_s;
            row=nan(1,19); row(1:6)=[index trial 1 1 1 base-obj.start_time];
            row(11:18)=[obj.timing(index,7:8) obj.timing(index,11:16)];
            row(19)=obj.timing(index,27);
            obj.addTrace(row);
            for frame=2:count
                target=base+(frame-1)/rate;
                if target>=boundary-obj.backend.ifi/2, break; end
                obj.poll();
                row=nan(1,19); row(1:6)=[index trial frame 1 0 target-obj.start_time];
                if obj.backend.now()>target+max(obj.backend.ifi,1/rate)
                    obj.addTrace(row); continue;
                end
                row(7)=obj.backend.now()-obj.start_time;
                pixels=obj.backend.readFrame(trial,frame);
                row(8)=obj.backend.now()-obj.start_time;
                row(9)=obj.backend.now()-obj.start_time;
                texture=obj.backend.makeTexture(pixels);
                row(10)=obj.backend.now()-obj.start_time;
                clear pixels;
                try
                    row(11)=obj.backend.now()-obj.start_time;
                    obj.backend.draw('view_video',trial,false,texture);
                    row(12)=obj.backend.now()-obj.start_time;
                    obj.waitFor(target,0,p);
                    row(13)=obj.backend.now()-obj.start_time;
                    row(14)=obj.backend.now()-obj.start_time;
                    [a,b,c,d]=obj.backend.flip(target-obj.backend.ifi/2);
                    row(19)=obj.backend.now()-obj.start_time;
                    row(5)=1;
                    row(15:18)=[a-obj.start_time b-obj.start_time c-obj.start_time d];
                    obj.addTrace(row);
                catch ME
                    obj.backend.closeTexture(texture);
                    rethrow(ME);
                end
                obj.backend.closeTexture(texture);
            end
        end

        function addTrace(obj,row)
            obj.trace_count=obj.trace_count+1;
            assert(obj.trace_count<=size(obj.trace,1),'fmri:FrameLogOverflow','Frame log capacity exceeded.');
            obj.trace(obj.trace_count,:)=row;
        end
    end
end
