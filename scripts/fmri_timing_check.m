function outputs = fmri_timing_check(script_dir, modality, cfg, trials, cb, display_mode, mode, run_num)
% Exercise the production engine, without subject dialogs or scanner hardware.
% display_mode=false is a real-clock simulation, never a display timing test.
if strcmp(mode,'short'), scale=0.02; else, scale=1; end
fields={'prepare','video','post_video_hold','response','initial_dummy','final_rest','delivery','touch','hold'};
for i=1:numel(fields)
    if isfield(cfg,fields{i}), cfg.(fields{i})=cfg.(fields{i})*scale; end
end
iti=double([trials.iti_s]')*scale;
cfg.timing_test_scale=scale;
cfg.timing_test_display=display_mode;
cfg.output_dir=fullfile(cfg.output_dir,'timing_checks');
subject.sub_id='timingcheck'; subject.sub_name='timingcheck';
subject.sub_gender='n/a'; subject.sub_age='n/a'; subject.sub_hand='n/a';
subject.session_id=sprintf('%02d',trials(1).session);
subject.session_num=trials(1).session;
subject.run_num=run_num; subject.run_id=sprintf('%02d',run_num);
subject.exp_mode='timingcheck';
subject.schedule_file=fullfile(script_dir,'experiment_schedule_seed42_current.xlsx');
n=numel(trials);
cb.trial_row=@(trial,i,kind)cb.row(trial,subject.run_id,i,n,kind,0,0,'no_response',NaN,false);
cb.empty_row=@(kind)cb.empty(kind,0,0);
cache=[]; backend=[]; engine=[]; input=[]; win=[];
screen_guard=[]; cache_guard=[]; backend_guard=[]; priority_guard=[]; %#ok<NASGU>
try
    if display_mode
        AssertOpenGL;
        KbName('UnifyKeyNames');
        old_sync=Screen('Preference','SkipSyncTests',2);
        sync_guard=onCleanup(@()Screen('Preference','SkipSyncTests',old_sync));
        Screen('Preference','TextRenderer',0);
        input=cb.make_input(cfg);
        win=Screen('OpenWindow',max(Screen('Screens')),0,[0 0 960 720]);
        screen_guard=onCleanup(@()cb.cleanup(win,input));
        rect=Screen('Rect',win);
        Screen('TextFont',win,'Microsoft YaHei');
        media=cell(0,1);
        cb.read=@()cb.read_keys(input);
        cb.triggers=@(times)cb.log_keys(times,input.trigger_keys);
        cb.abort=@()error('fmri:Abort','Timing check interrupted.');
        if strcmp(modality,'visual')
            files=arrayfun(cb.resolve_video,trials,'UniformOutput',false);
            for i=1:numel(files), assert(isfile(files{i}),'Missing test video: %s',files{i}); end
            cache=FmriVideoCache(files,fullfile(script_dir,'cache','video_preload'), ...
                @poll, @(i,n)fprintf('TIMING CHECK PRELOAD %d/%d\n',i,n));
            cache_guard=onCleanup(@()cache.close());
            cache.prepare_textures(win,@poll);
            media=cell(n,1);
            for i=1:n
                media{i}=cache.get(files{i});
                trials(i).stim_file=files{i};
            end
        end
        backend=FmriPtbBackend(win,rect,modality,trials,cb,media);
        clear media;
        if strcmp(mode,'short')
            % Inspect the newly cached text/counter page outside the timed run.
            if ~isfolder(cfg.output_dir), mkdir(cfg.output_dir); end
            backend.draw('prepare',1,false,[]);
            preview=Screen('GetImage',win,[],'backBuffer');
            imwrite(preview,fullfile(cfg.output_dir,['preview_task-' modality '.png']));
            if strcmp(modality,'visual'), subtitle='准备观看视频';
            else, subtitle='准备触摸物体'; end
            cb.draw(win,rect,'准备',subtitle,1,n);
            reference=Screen('GetImage',win,[],'backBuffer');
            imwrite(reference,fullfile(cfg.output_dir,['reference_task-' modality '.png']));
            cfg.timing_test_page_error=max(abs(double(preview(:))-double(reference(:))));
            assert(nnz(all(preview>240,3))>100 && nnz(all(reference>240,3))>100, ...
                'fmri:BlankCachedPage','Preparation title was not rendered.');
            assert(cfg.timing_test_page_error<=1,'fmri:CachedPageMismatch', ...
                'Cached preparation page differs from the original renderer.');
            Screen('Flip',win);
            clear preview reference;
        end
    else
        input=struct('yes_keys',1,'no_keys',2,'escape_keys',3,'trigger_keys',5);
        cb.read=@no_keys;
        cb.triggers=@(times)[];
        cb.abort=@()error('fmri:Abort','Timing check interrupted.');
        backend=FmriClockBackend;
    end
    backend_guard=onCleanup(@()backend.close());
    engine=FmriTimingEngine(backend,cb,input,modality,cfg,trials,iti);
    if display_mode
        previous_priority=Priority;
        priority_guard=onCleanup(@()Priority(previous_priority));
        cfg.execution_priority=min(1,MaxPriority(win));
        Priority(cfg.execution_priority);
    end
    start_time=backend.now()+0.1;
    cb.reset(start_time);
    fprintf('TIMING CHECK %s / %s / display %d / planned %.6f s\n', ...
        modality,mode,display_mode,engine.plannedSeconds());
    engine.run(start_time);
    clear priority_guard;
    cb.stop();
    rows=engine.events();
    summary=engine.summary();
    backend.close();
    if ~isempty(cache), cache.close(); end
    outputs=cb.save(subject,cfg,rows,engine.plannedSeconds(),start_time,false,engine);
    fprintf('TIMING CHECK DONE: %.6f s; drift %.6f s; extension %.6f s; quality %d\n', ...
        summary.actual_seconds,summary.actual_minus_planned_s,summary.schedule_extension_s,summary.timing_valid);
    fprintf('TIMING LOG: %s\n',outputs.timing.phases);
catch ME
    clear priority_guard;
    cb.stop();
    if ~isempty(backend), backend.close(); end
    clear media;
    if ~isempty(cache), cache.close(); end
    if ~isempty(engine)
        try
            cb.save(subject,cfg,engine.events(),engine.plannedSeconds(),engine.start_time,true,engine);
        catch save_error
            warning('fmri:TimingCheckSave','Cannot save timing check: %s',save_error.message);
        end
    end
    rethrow(ME);
end
clear backend_guard cache_guard screen_guard;

    function poll()
        [codes,times]=cb.read_keys(input);
        cb.log_keys(times,input.trigger_keys);
        if any(codes(input.escape_keys)), error('fmri:Abort','Preload interrupted.'); end
    end
end

function [codes,times]=no_keys()
codes=false(1,256); times=zeros(1,256);
end
