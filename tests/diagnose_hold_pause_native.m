function diagnose_hold_pause_native()
% Focused actual-video/display probe; debug window, not acquisition validation.
root=fileparts(fileparts(mfilename('fullpath')));
addpath(fullfile(root,'scripts'),fullfile(root,'tests'));
folder=fullfile(root,'tests','timing_validation','hold_pause_diagnosis');
if ~isfolder(folder),mkdir(folder);end
AssertOpenGL;
old_sync=Screen('Preference','SkipSyncTests',2);
sync_guard=onCleanup(@()Screen('Preference','SkipSyncTests',old_sync));
Screen('Preference','TextRenderer',0);
win=Screen('OpenWindow',max(Screen('Screens')),0,[0 0 960 720]);
screen_guard=onCleanup(@()Screen('CloseAll'));
rect=Screen('Rect',win);Screen('TextFont',win,'Microsoft YaHei');
cache=FmriVideoCache({fullfile(root,'video','train','session01','160.mp4')}, ...
    fullfile(folder,'cache'),@()[],@(i,n)fprintf('DIAGNOSTIC PRELOAD %d/%d\n',i,n));
cache_guard=onCleanup(@()cache.close());
cache.prepare_textures(win,@()[]);
media={cache.get(fullfile(root,'video','train','session01','160.mp4'))};
trials=struct('stimulus_number',160);
cb.draw=@draw;cb.text=@text;cb.response=@response;
cb.read=@read;cb.triggers=@(~)[];cb.abort=@()error('test:Abort','Abort');
cb.trial_row=@row;cb.empty_row=@empty;
inner=FmriPtbBackend(win,rect,'visual',trials,cb,media);clear media;
backend_guard=onCleanup(@()inner.close());
keys=struct('yes_keys',1,'no_keys',2,'escape_keys',3,'trigger_keys',5);
cfg=struct('prepare',2,'video',6,'post_video_hold',2,'response',2, ...
    'initial_dummy',1,'final_rest',1);
old_priority=Priority;priority_guard=onCleanup(@()Priority(old_priority));
Priority(min(1,MaxPriority(win)));
results=cell(1,2);
for i=1:2
    backend=FmriNativeDiagnosticBackend(inner);
    engine=FmriTimingEngine(backend,cb,keys,'visual',cfg,trials,5);
    fprintf('NATIVE PROBE %d: injected 0.20 s near final video frame, actual video.\n',i);
    engine.run(GetSecs+0.1);
    results{i}=engine.summary();
    engine.saveLogs(folder,sprintf('native_injected_final_frame_%d',i));
    rows=engine.events();hold=rows(strcmp({rows.trial_type},'post_video_hold'));
    fprintf('NATIVE PROBE %d: hold %.6f s; extension %.6f s\n', ...
        i,hold.duration,results{i}.schedule_extension_s);
end
save(fullfile(folder,'native_results.mat'),'results');
clear priority_guard backend_guard cache_guard screen_guard sync_guard;
end
function draw(win,rect,title,~,~,~)
Screen('FillRect',win,0);Screen('TextSize',win,32);
Screen('DrawText',win,double(title),rect(3)/3,rect(4)/2,255);
end
function text(win,message,x,y,size,color)
Screen('TextSize',win,size);Screen('DrawText',win,double(message),x,y,color);
end
function response(win,rect,~,~,~),draw(win,rect,'response','',0,0);end
function [codes,times]=read(),codes=false(1,256);times=zeros(1,256);end
function r=row(~,index,kind),r=empty(kind);r.trial_index=index;end
function r=empty(kind)
r=struct('onset',0,'duration',0,'trial_type',kind,'trial_index',NaN, ...
    'response','n/a','accuracy','n/a','rt','n/a');
end
