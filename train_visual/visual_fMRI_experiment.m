function visual_fMRI_experiment(varargin)
addpath(fullfile(fileparts(fileparts(mfilename('fullpath'))), 'scripts'));
if nargin > 0 && strcmpi(varargin{1}, 'checkschedule')
    script_dir = fileparts(mfilename('fullpath'));
    file_path = choose_schedule_file(script_dir);
    if nargin > 1, file_path = text_value(varargin{2}); end
    schedule =   load_schedule(file_path);
    cfg = apply_schedule_timing(default_config(script_dir), schedule);
    for i = 1:numel(schedule.runs)
        r = schedule.runs(i);
        matched=find_run(schedule,num2str(r.session),r.run);
        assert(matched.session==r.session && matched.run==r.run, 'Input Session/global Run lookup mismatch.');
        for j = 1:numel(r.trials), video_path_for_trial(r.trials(j), cfg); end
        assert(abs(planned_duration(cfg, get_iti_values(r.trials, cfg)) - r.duration_s) < 1e-6);
    end
    fprintf('VIDEO_PATH_FIRST: %s\n', video_path_for_trial(schedule.runs(1).trials(1), cfg));
    fprintf('SCHEDULE OK: %d sessions, %d runs, %d trials\n', ...
        schedule.metadata.n_sessions, schedule.metadata.n_runs, schedule.metadata.n_total_trials);
    return;
end
% 视觉版实验入口。在 MATLAB 命令行输入 visual_fMRI_experiment 运行。
if nargin > 0 && strcmpi(varargin{1}, 'checkmedia')
    script_dir = fileparts(mfilename('fullpath'));
    schedule = load_schedule(choose_schedule_file(script_dir));
    cfg = apply_schedule_timing(default_config(script_dir), schedule);
    run_num = 1;
    if nargin > 1, run_num = str2double(text_value(varargin{2})); end
    run_data = find_run(schedule, '', run_num);
    validate_run_videos(run_data.trials, cfg);
    fprintf('MEDIA OK: Session %d / Run %d / %d trials\n', ...
        run_data.session, run_data.run, numel(run_data.trials));
    return;
end
if nargin > 0 && strcmpi(varargin{1}, 'timingtest')
    timing_check_wrapper(true, false, varargin{2:end});
    return;
end
if nargin > 0 && strcmpi(varargin{1}, 'selftest')
    visual_fMRI_selftest(varargin{2:end});
    return;
end
if nargin > 0 && strcmpi(varargin{1}, 'videotest')
    visual_video_test(varargin{2:end});
    return;
end

close all;
% close all：关闭之前打开的图窗，避免旧窗口影响本次实验。

clc;
% clc：清空命令行窗口，不影响数据，只是让输出更干净。

% 这个文件是实验运行主程序。
% 代码按真实实验顺序写：
% 1. 找到并读取实验日程 Excel，里面规定每个 run 的 trial 顺序和 ITI。
% 2. 让实验员填写被试编号、姓名、run 编号等信息。
% 3. 打开 Psychtoolbox 全屏窗口，设置按键队列。
% 4. 等待开始信号：所有模式都等待扫描仪 S 触发。
% 5. 每个 trial 依次运行：准备、观看视频、等待、回答、ITI。
% 6. 保存每个 trial 的关键结果，主要用于后续 BIDS events.tsv 分析。

% 给没学过 MATLAB 的说明：
% - % 后面的内容是注释，MATLAB 不会执行。
% - = 表示“把右边的结果存到左边变量里”。
% - [] 表示空值，NaN 表示“现在还没有一个有效数字”。
% - cfg.data_dir 这种写法表示结构体字段，可以理解成 cfg 这个盒子里的 data_dir。
% - 函数调用通常写成 函数名(输入1, 输入2)。
% - [a, b] = 函数名(...) 表示这个函数会返回两个结果，分别存到 a 和 b。
% - 每个 if、for、try、function 最后都要有一个 end。

script_dir = fileparts(mfilename('fullpath'));
% mfilename('fullpath') 得到当前 .m 文件的完整路径。
% fileparts(...) 取出文件夹路径。
% script_dir 就是本程序所在的文件夹，后面找 Excel 和保存数据都从这里出发。

cfg = default_config(script_dir);
% 调用下面的 default_config 函数，生成默认实验参数。
% cfg 是一个结构体，里面放时间、数据保存路径、按键等待时间等设置。

% 这些变量放在 try 外面，是为了中途按 ESC 退出时也能用 catch 保存。
% trial_rows 是最终要写入 events.tsv 的数据：每完成一个 trial，就追加多行阶段事件。
% start_time 是计时零点：所有模式下都是第一个有效扫描触发。
subject = [];
% subject 以后会保存被试信息。这里先设为空，表示还没有填写。

trial_rows = empty_trial_rows();
% trial_rows 是结果表。empty_trial_rows() 先创建一个空表结构。

planned_seconds = NaN;
% planned_seconds 是预计总时长。现在还没读 Excel，所以先用 NaN 占位。

start_time = NaN;
% start_time 是实验开始的基准时间。还没开始，所以先用 NaN。

timing_engine = [];
timing_backend = [];
saved = false;
% saved 记录本 run 是否已经成功落盘。这样异常处理时不会重复保存。

try
    % try/catch 的意思是：
    % try 里面正常运行实验；
    % 如果中途按 ESC 抛出指定异常，就跳到下面 catch，保存已完成的数据。

    % 先选 schedule，再填写被试信息。run 编号会用来从 schedule 里取对应 run。
    schedule_file = choose_schedule_file(script_dir);
    if isempty(schedule_file)
        % isempty(...) 判断变量是不是空。
        % 如果用户取消选择 schedule_file，就直接 return 结束程序。
        return;
    end

    subject = get_subject_info(schedule_file);
    if isempty(subject)
        % 如果用户取消填写被试信息，也直接结束程序。
        return;
    end

    % schedule 是 Python 脚本提前生成的实验日程。
    % cfg 先用默认值，再用 schedule.metadata.timing 覆盖，保证 MATLAB 和 Excel 时间一致。
    schedule = load_schedule(schedule_file);
    cfg = apply_schedule_timing(cfg, schedule);
    run_data = find_run(schedule, subject.session_id, subject.run_num);
    trials = run_data.trials;
    % trials 是当前 run 的所有试次。
    % trials(1) 表示第 1 个 trial，trials(2) 表示第 2 个 trial。

    % ITI 优先使用 Excel 里每个 trial 的 iti_s。
    % planned_seconds 是排程名义时长；FmriTimingEngine 根据同一排程安排阶段截止时间。
    n_trials = numel(trials);
    % numel(trials) 是 trial 的个数。
    validate_run_trial_count(schedule, subject.run_num, n_trials);
    validate_run_videos(trials, cfg);

    iti_values = get_iti_values(trials, cfg);
    planned_seconds = planned_duration(cfg, iti_values);

    % Psychtoolbox 初始化。正式实验建议不要跳过同步测试。
    AssertOpenGL;
    KbName('UnifyKeyNames');
    skip_sync_tests = screen_sync_test_setting(cfg, subject);
    Screen('Preference', 'SkipSyncTests', skip_sync_tests);
    Screen('Preference', 'TextRenderer', 0);

    % KbQueue 比 KbCheck 更适合记录反应时，因为它保存按键发生的时间。
    input = make_input(cfg);
    % 即使代码报错或 ESC 退出，也尽量关闭屏幕并释放键盘队列。
    cleanup_guard = onCleanup(@()cleanup_experiment([], input));

    [win, win_rect] = open_ptb_window(cfg, skip_sync_tests);
    screen_cleanup_guard = onCleanup(@()Screen('CloseAll'));
    % [win, win_rect] = ... 是 MATLAB 的多返回值写法。
    % win 是窗口编号，后面画图都要用它。
    % win_rect 是窗口大小和位置。

    [cx, cy] = RectCenter(win_rect);
    % cx 和 cy 是屏幕中心坐标，后面把文字画在屏幕中央会用到。

    Screen('TextFont', win, 'Microsoft YaHei');

    % 在等待扫描触发前完成本 run 所有视频的解码；重复物体共用缓存。
    video_files = arrayfun(@(t)video_path_for_trial(t, cfg), trials, 'UniformOutput', false);
    video_cache = FmriVideoCache(video_files, fullfile(script_dir, 'cache', 'video_preload'), ...
        @()check_keys(input), @(i,n)show_preload_progress(win, win_rect, i, n));
    video_cache_guard = onCleanup(@()video_cache.close());
    video_cache.prepare_textures(win, @()check_keys(input));

    % 所有文字画面、试次数标记、事件元数据和日志空间都在扫描触发前准备。
    media = cell(n_trials,1);
    for i=1:n_trials
        trials(i).stim_file = video_files{i};
        media{i}=video_cache.get(video_files{i});
    end
    cb.draw=@draw_screen; cb.text=@draw_text; cb.response=@draw_response_screen;
    cb.read=@()read_keys(input);
    cb.triggers=@(times)tr_log('add_keys',times,input.trigger_keys);
    cb.abort=@abort_now;
    cb.trial_row=@(trial,i,kind)make_trial_row(trial,subject.run_id,i,n_trials, ...
        kind,0,0,'no_response',NaN,false);
    cb.empty_row=@(kind)make_empty_event_row(kind,0,0);
    timing_backend=FmriPtbBackend(win,win_rect,'visual',trials,cb,media);
    timing_backend_guard=onCleanup(@()timing_backend.close());
    timing_engine=FmriTimingEngine(timing_backend,cb,input,'visual',cfg,trials,iti_values);
    tr_log('stop'); % 预热触发日志并确保等待扫描前处于停止状态。
    clear media;

    show_intro(win, win_rect, cx, cy, input, subject, n_trials, planned_seconds, cfg.max_wait_s);

    % 所有模式都等待扫描仪发来的 S 键触发；行为/fMRI 只影响同步测试设置。
    % 使用兼容键盘输入的保守优先级，并在结束/异常时恢复。
    previous_priority=Priority;
    priority_guard=onCleanup(@()Priority(previous_priority));
    cfg.execution_priority=min(1,MaxPriority(win));
    Priority(cfg.execution_priority);
    start_time = wait_scanner_start(win, win_rect, input);

    % 按统一绝对时间表预约翻屏；实际时长由相邻真实翻屏时间计算。
    timing_engine.run(start_time);
    clear priority_guard;
    trial_rows=timing_engine.events();

    tr_log('stop');
    timing_backend.close();
    clear timing_backend_guard;
    video_cache.close();
    clear video_cache_guard;

    % 数据先保存，再显示 summary。这样即使后面的结束界面出错，trial 数据也已经落盘。
    save_run(subject, cfg, trial_rows, planned_seconds, start_time, false, timing_engine);
    saved = true;

    show_summary(win, win_rect, cx, cy, trial_rows, timing_engine.summary());
    wait_for_key(input, input.space_keys, cfg.max_wait_s);

    draw_screen(win, win_rect, '实验结束', '按空格退出', 0, 0);
    Screen('Flip', win);
    wait_for_exit_key(input, input.space_keys, cfg.max_wait_s);
    cleanup_experiment(win, input);
    clear screen_cleanup_guard;

catch ME
    clear priority_guard;
    if ~isempty(timing_engine), trial_rows=timing_engine.events(); end
    if ~isempty(timing_backend), timing_backend.close(); end
    clear media;
    if exist('video_cache', 'var'), video_cache.close(); end
    % catch ME 表示如果 try 里出了异常，异常信息会存在 ME 里。

    % ESC 退出不是程序错误。
    % 其他错误也先尝试保存已经完成的 trial，再把错误重新抛出。
    tr_log('stop');
    if ~isempty(subject) && ~saved
        try
            save_run(subject, cfg, trial_rows, planned_seconds, start_time, true, timing_engine);
            saved = true; %#ok<NASGU>
        catch saveME
            warning('visual:SaveFailed', '异常退出时保存失败：%s', saveME.message);
        end
    end

    if ~strcmp(ME.identifier, 'visual:Abort')
        % ~ 表示“不”。
        % 如果不是我们自己定义的 ESC 退出异常，就说明是真错误，保存后重新报出来。
        rethrow(ME);
    end
end
end

function visual_fMRI_selftest(varargin)
% 同一计时引擎的真实时钟无屏幕模拟；不验证显示器或原始视频播放。
timing_check_wrapper(false, false, varargin{:});
end

function visual_video_test(varargin)
% 用同一计时引擎播放指定实际 trial；不等待扫描触发。
timing_check_wrapper(true, true, varargin{:});
end

function timing_check_wrapper(display_mode, single_trial, varargin)
script_dir=fileparts(mfilename('fullpath'));
schedule=load_schedule(choose_schedule_file(script_dir));
cfg=apply_schedule_timing(default_config(script_dir),schedule);
number=1;
if ~isempty(varargin), number=str2double(text_value(varargin{1})); end
assert(isfinite(number) && number>=1 && number==fix(number),'Invalid test run/trial number.');
mode='full';
if display_mode && ~single_trial, mode='short'; end
if numel(varargin)>1, mode=text_value(varargin{2}); end
assert(ismember(mode,{'short','full'}),'Use short or full.');
if single_trial
    all_trials=vertcat(schedule.runs.trials);
    assert(number<=numel(all_trials),'Invalid trial number.');
    trials=all_trials(number);
    run_num=trials.run;
else
    data=find_run(schedule,'',number); trials=data.trials; run_num=number;
end
cb.draw=@draw_screen; cb.text=@draw_text; cb.response=@draw_response_screen;
cb.row=@make_trial_row; cb.empty=@make_empty_event_row;
cb.make_input=@make_input; cb.read_keys=@read_keys; cb.cleanup=@cleanup_experiment;
cb.log_keys=@(times,keys)tr_log('add_keys',times,keys);
cb.reset=@(t)tr_log('reset',t); cb.stop=@()tr_log('stop'); cb.save=@save_run;
cb.resolve_video=@(trial)video_path_for_trial(trial,cfg);
fmri_timing_check(script_dir,'visual',cfg,trials,cb,display_mode,mode,run_num);
end

function cfg = default_config(script_dir)
% 默认实验参数。
% 如果 schedule Excel 里有 metadata.timing，就会覆盖这些时间。
% 这样做的好处是：没有 Excel timing 时程序也能跑；有 Excel timing 时以日程文件为准。

% cfg 是一个结构体。下面每一行都在给 cfg 增加一个字段。
% 例如 cfg.video = 6 的意思是：视频阶段默认 6 秒。
cfg.output_dir = fullfile(script_dir, 'output');
% fullfile(...) 用来拼路径，比自己写 '\' 或 '/' 更安全。
cfg.script_dir = script_dir;
cfg.video_dir = ''; % Required settings are loaded from the Excel workbook.
cfg.video_session_pattern = 'session%02d';
% 默认视频目录与 train_visual 同级；实际目录和文件名以执行 Excel 为准。

cfg.max_wait_s = 20;
% max_wait_s 是某些等待界面的最长等待时间，单位是秒。

cfg.prepare = 2;
% prepare：准备阶段时长。

cfg.video = 6;
% 视频播放时长。

cfg.post_video_hold = 2;
% 视频后的等待时长。

cfg.response = 2;
% response：回答阶段时长。

cfg.iti_options = [2 3 4 5 6];
% [2 3 4 5 6] 是一个数字数组，表示 ITI 可以是 2、3、4、5 或 6 秒。

cfg.iti_min = 2;
cfg.iti_max = 6;
cfg.final_rest = 6;
% final_rest：最后一个 trial 后额外显示注视点的时间。
% TR=2 秒时，8 秒相当于 4 个 TR，给最后一个 trial 的 HRF 留出采样时间。

cfg.initial_dummy = 6;
% initial_dummy：开始触发后、第一 trial 前的空扫/基线时间，单位秒。

cfg.trigger_key_names = {'s', 'S', '5%', '5', 't', 'T'};
% trigger_key_names：扫描仪触发键候选。
% 不同扫描仪/响应盒可能发 S、5 或 t，正式扫描前必须用现场设备测试确认。

cfg.skip_sync_tests_behavioral = 1;
% 行为/调试模式默认跳过 Psychtoolbox 同步测试，便于在普通电脑上测试流程。

cfg.skip_sync_tests_fmri = 0;
% 正式 fMRI 模式不要跳过同步测试。若这里改成 1，只适合临时排查，不能作为正式采集设置。

cfg.screen_id = [];
% 默认使用编号最大的屏幕。如果需要指定显示器，可填数字，例如 0 或 1。
end

function skip_sync_tests = screen_sync_test_setting(cfg, subject)
% 根据实验模式选择是否跳过 Psychtoolbox 同步测试。
% 同步测试失败是 Screen('OpenWindow') 报错的最常见原因之一。
if strcmp(subject.exp_mode, 'behavioral')
    skip_sync_tests = cfg.skip_sync_tests_behavioral;
else
    skip_sync_tests = cfg.skip_sync_tests_fmri;
end
end

function [win, win_rect] = open_ptb_window(cfg, skip_sync_tests)
% 打开 Psychtoolbox 窗口，并在失败时输出更直接的诊断信息。
screens = Screen('Screens');
if isempty(cfg.screen_id)
    screen_id = max(screens);
else
    screen_id = cfg.screen_id;
end

if ~ismember(screen_id, screens)
    error('配置的 cfg.screen_id=%d 不存在。当前可用屏幕编号: %s', ...
        screen_id, mat2str(screens));
end

try
    [win, win_rect] = Screen('OpenWindow', screen_id, 0);
catch ME
    fprintf(2, '\n[Psychtoolbox 打开窗口失败]\n');
    fprintf(2, '当前屏幕编号: %d，可用屏幕编号: %s\n', screen_id, mat2str(screens));
    fprintf(2, 'SkipSyncTests: %d\n', skip_sync_tests);
    fprintf(2, ['如果上方 PTB-ERROR 提到 Synchronization failure，' ...
        '普通调试时请在启动信息的模式栏填写“行为”；正式 fMRI 采集不要跳过同步测试，' ...
        '应检查显示器刷新率、独显/驱动、关闭远程桌面和系统合成/缩放干扰。\n\n']);
    rethrow(ME);
end
end

function schedule_file = choose_schedule_file(script_dir)
% Only the explicitly named Excel execution workbook is used.
schedule_file = fullfile(script_dir, 'experiment_schedule_seed42_current.xlsx');
assert(exist(schedule_file, 'file') == 2, 'Missing schedule workbook: %s', schedule_file);
end

function subject = get_subject_info(schedule_file)
% 弹出输入框，收集本次 run 需要的基本信息。
% 这里不做复杂界面，目的是让代码好读、好改。
% 模式只影响 Psychtoolbox 同步测试设置；开始方式始终等待扫描仪 S 触发。
subject = [];
% subject 最后会变成结构体，保存被试信息。

prompt = {'被试编号', '姓名', '性别', '年龄', '利手', 'Session（每4个Run一组）', ...
    '全局Run编号', '模式：行为'};
% prompt 是输入框左边显示的问题。

defaults = {'001', '测试', '男', '20', '右', '01', '01', '行为'};
% defaults 是输入框里的默认值。

answer = inputdlg(prompt, '视觉 fMRI 实验设置', 1, defaults);
% inputdlg 弹出输入窗口。
% answer 是一个 cell 数组，answer{1} 是第一个输入框的内容。

if isempty(answer)
    return;
end

subject.sub_id = strtrim(answer{1});
% strtrim(...) 去掉前后多余空格。

subject.sub_name = strtrim(answer{2});
subject.sub_gender = strtrim(answer{3});
subject.sub_age = strtrim(answer{4});
subject.sub_hand = strtrim(answer{5});
subject.session_id = strtrim(answer{6});
subject.session_num = str2double(subject.session_id);
subject.run_id = strtrim(answer{7});
subject.run_num = str2double(subject.run_id);
% str2double(...) 把文字转成数字。
% run_id 是保存文件名用的文字，run_num 是从 Excel 里找 run 用的数字。

subject.schedule_file = schedule_file;

mode_text = strtrim(answer{8});
if strncmpi(mode_text, 'beh', 3) || contains(mode_text, '行为')
    % strncmpi(..., 3) 表示不区分大小写比较前 3 个字符。
    % 所以 behavioral、Behavioral、beh 都可以被识别为行为模式。
    subject.exp_mode = 'behavioral';
else
    subject.exp_mode = 'fmri';
end

if isempty(subject.sub_id)
    error('需要填写被试编号。');
end
if ~isfinite(subject.session_num) || subject.session_num < 1 || subject.session_num ~= fix(subject.session_num)
    error('会话编号必须是正数。');
end
if ~isfinite(subject.run_num) || subject.run_num < 1 || subject.run_num ~= fix(subject.run_num)
    error('轮次编号必须是正数。');
end
end

function schedule = load_schedule(file_path)
% Excel is the only runtime schedule source. Never infer rows or random ITIs.
params = read_schedule_table(file_path, 'Parameters', {}, {'key', 'value'});
run_numeric = {'session','session_run','run','plate','n_base_trials','nback_targets','n_trials','iti_sum_s','duration_s','stimulus_session'};
trial_numeric = {'session','session_run','run','trial','stimulus_number','plate','plate_row','plate_col','base_trial','nback_target','iti_s','stimulus_session'};
runs = read_schedule_table(file_path, 'Runs', run_numeric, {'order'});
trials = read_schedule_table(file_path, 'Trials', trial_numeric, ...
    {'trial_id','correct_response','question_type','question_text','video_filename'});
assert(height(params) > 0 && numel(unique(params.key)) == height(params), 'Parameters keys must be unique.');
p = struct();
for i = 1:height(params)
    key = char(params.key(i));
    assert(isvarname(key) && ~ismissing(params.value(i)), 'Invalid or empty parameter: %s', key);
    value = char(params.value(i));
    numeric_value = str2double(value);
    text_keys = {'modality','video_root','trigger_key','response_hand','touch_hand','iti_options_s','dataset','numbering_scheme','video_session_pattern'};
    if ~ismember(key, text_keys) && ~isnan(numeric_value)
        p.(key) = numeric_value;
    else
        p.(key) = value;
    end
end
required = {'schema_version','dataset','numbering_scheme','objects_per_session','video_session_pattern','modality','n_sessions','n_runs','n_total_trials','n_base_trials', ...
    'n_total_nback_targets','prepare_s','response_s','initial_dummy_s','final_rest_s','iti_options_s'};
required = [required, {'video_s','post_video_hold_s'}];
assert(all(isfield(p, required)), 'Parameters is missing required settings.');
assert(p.schema_version == 4, 'Unsupported Excel schema_version.');
assert(all(isfield(p,{'runs_per_session','n_stimulus_sessions'})), 'Session grouping parameters missing.');
assert(isnumeric(p.runs_per_session) && isscalar(p.runs_per_session) && ...
    isfinite(p.runs_per_session) && p.runs_per_session>=1 && ...
    p.runs_per_session==fix(p.runs_per_session), 'Invalid runs_per_session.');
assert(strcmp(p.modality, 'visual'), 'This workbook is for a different task.');
[~, program_folder] = fileparts(fileparts(mfilename('fullpath')));
expected_dataset = char(extractBefore(string(program_folder), '_'));
assert(strcmp(p.dataset, expected_dataset), 'Workbook dataset does not match the program folder.');
assert(ismember(string(p.numbering_scheme), ["session_hundreds","sequential"]), 'Unknown numbering scheme.');
assert(isnumeric(p.objects_per_session) && p.objects_per_session > 0 && p.objects_per_session == fix(p.objects_per_session), 'Invalid objects_per_session.');
assert(strcmp(p.video_session_pattern, 'session%02d'), 'Use sessionXX video folders.');
timing_fields = {'prepare_s','response_s','initial_dummy_s','final_rest_s','video_s','post_video_hold_s'};
for i = 1:numel(timing_fields)
    value = p.(timing_fields{i});
    assert(isnumeric(value) && isscalar(value) && isfinite(value) && value >= 0, 'Invalid phase timing.');
end
timing = struct();
for i = 1:numel(timing_fields)
    timing.(timing_fields{i}) = p.(timing_fields{i});
end
if isnumeric(p.iti_options_s)
    timing.iti_options_s = p.iti_options_s;
else
    timing.iti_options_s = str2double(strsplit(p.iti_options_s, ','));
end
assert(all(isfinite(timing.iti_options_s) & timing.iti_options_s > 0), 'Invalid ITI options.');
assert(height(runs) > 0 && height(trials) > 0, 'Schedule contains no runs or trials.');
for key = {'session','session_run','run','n_base_trials','nback_targets','n_trials','stimulus_session'}
    values = runs.(key{1});
    assert(all(isfinite(values) & values > 0 & values == fix(values)), 'Invalid run counters.');
end
for key = {'session','session_run','run','trial','stimulus_number','base_trial','stimulus_session'}
    values = trials.(key{1});
    assert(all(isfinite(values) & values > 0 & values == fix(values)), 'Invalid trial counters.');
end
assert(numel(unique(runs.run)) == height(runs), 'Global run numbers must be unique.');
assert(numel(unique(trials.trial_id)) == height(trials), 'Trial IDs must be unique.');
assert(all(ismember(trials.run, runs.run)), 'Trials refers to an unknown global run.');
assert(height(runs) == p.n_runs && height(trials) == p.n_total_trials, 'Parameter totals do not match Excel rows.');
assert(numel(unique(runs.session)) == p.n_sessions, 'Session total does not match Runs.');
assert(sum(runs.n_base_trials) == p.n_base_trials && sum(runs.nback_targets) == p.n_total_nback_targets, 'Base/target totals do not match Runs.');
assert(all(ismember(trials.nback_target, [0 1])), 'nback_target must be 0 or 1.');
assert(all(isfinite(trials.iti_s) & trials.iti_s > 0), 'Every trial needs an explicit positive ITI.');
assert(all(ismember(trials.iti_s, timing.iti_options_s)), 'Trial ITI is outside the configured options.');
text_fields = {'trial_id','correct_response'};
for i = 1:numel(text_fields)
    values = trials.(text_fields{i});
    assert(all(~ismissing(values) & strlength(strtrim(values)) > 0), 'A required trial field is empty.');
end
runs = sortrows(runs, 'run');
assert(isequal(runs.run',1:height(runs)), 'Global run numbers must be consecutive.');
assert(all(runs.session==floor((runs.run-1)/p.runs_per_session)+1 & ...
    runs.session_run==mod(runs.run-1,p.runs_per_session)+1), 'Session grouping does not match global runs.');
assert(numel(unique(runs.stimulus_session))==p.n_stimulus_sessions, 'Stimulus source total mismatch.');
for session = unique(runs.session)'
    current = runs(runs.session == session, :);
    assert(isequal(sort(current.session_run)', 1:height(current)), 'Session-local run numbers must be consecutive.');
end
run_structs = table2struct(runs);
fixed_s = p.prepare_s + p.video_s + p.post_video_hold_s + p.response_s;
for i = 1:height(runs)
    current = sortrows(trials(trials.run == runs.run(i), :), 'trial');
    n = height(current);
    assert(n == runs.n_trials(i) && isequal(current.trial', 1:n), 'Trial order/count does not match Runs.');
    assert(all(current.session == runs.session(i) & current.session_run == runs.session_run(i)), 'Session/run mapping mismatch.');
    assert(all(current.stimulus_session==runs.stimulus_session(i)), 'Stimulus source mismatch.');
    targets = [false; current.stimulus_number(2:end) == current.stimulus_number(1:end-1)];
    assert(isequal(logical(current.nback_target), targets), '1-back flags do not match adjacent stimuli.');
    if strcmp(p.numbering_scheme, 'session_hundreds')
        expected_sessions = floor(current.stimulus_number / 100);
    else
        expected_sessions = floor((current.stimulus_number - 1) / p.objects_per_session) + 1;
    end
    assert(all(expected_sessions == current.stimulus_session), 'Object number/stimulus source mismatch.');
    assert(sum(targets) == runs.nback_targets(i) && sum(~targets) == runs.n_base_trials(i), 'Base/target counts do not match Runs.');
    answers = repmat("no", n, 1);
    answers(targets) = "yes";
    assert(isequal(current.correct_response, answers), 'Correct responses do not match 1-back flags.');
    duration = p.initial_dummy_s + p.final_rest_s + fixed_s*n + sum(current.iti_s);
    assert(abs(sum(current.iti_s) - runs.iti_sum_s(i)) < 1e-6 && ...
        abs(duration - runs.duration_s(i)) < 1e-6, 'Run timing totals do not match trial rows.');
    run_structs(i).trials = table2struct(current);
end
schedule.metadata = p;
schedule.metadata.timing = timing;
if isfield(p, 'trigger_key')
    schedule.metadata.scanner.trigger_keys = strsplit(text_value(p.trigger_key), ',');
end
if strcmp(p.modality, 'visual')
    assert(isfield(p, 'video_root') && strcmp(strrep(p.video_root, '\', '/'), ['../video/' p.dataset]), 'video_root must point to ../video/train or ../video/test.');
    schedule.metadata.visual_videos.root = p.video_root;
end
schedule.runs = run_structs;
end

function t = read_schedule_table(file_path, sheet, numeric_fields, text_fields)
opts = detectImportOptions(file_path, 'Sheet', sheet, 'VariableNamingRule', 'preserve');
assert(all(ismember([numeric_fields text_fields], opts.VariableNames)), 'Required columns missing from %s.', sheet);
opts = setvartype(opts, text_fields, 'string');
if ~isempty(numeric_fields)
    opts = setvartype(opts, numeric_fields, 'double');
end
t = readtable(file_path, opts);
end

function video_file = video_path_for_trial(trial, cfg)
% Number 101 defaults to 101.mp4; an optional filename overrides this rule.
name = '';
if isfield(trial, 'video_filename')
    value = string(trial.video_filename);
    if ~ismissing(value) && strlength(strtrim(value)) > 0
        name = char(strtrim(value));
    end
end
if isempty(name)
    name = sprintf('%03d.mp4', double(trial.stimulus_number));
end
[folder, base, ext] = fileparts(name);
assert(isempty(folder) && ~isempty(base) && strcmpi(ext, '.mp4'), ...
    'video_filename must be an MP4 filename without a directory: %s', name);
% Input Session is a four-run acquisition group; media stay in source folders.
video_file = fullfile(cfg.video_dir, sprintf(cfg.video_session_pattern, double(trial.stimulus_session)), name);
end

function validate_run_videos(trials, cfg)
% 在打开全屏窗口前检查本 run 所需视频，避免实验中途才发现缺文件。
if exist(cfg.video_dir, 'dir') ~= 7
    error('visual:MissingVideoDirectory', '视频目录不存在：%s', cfg.video_dir);
end
for i = 1:numel(trials)
    video_file = video_path_for_trial(trials(i), cfg);
    if exist(video_file, 'file') ~= 2
        error('visual:MissingVideo', '第 %d 个 trial 缺少视频：%s', i, video_file);
    end
end
end

function cfg = apply_schedule_timing(cfg, schedule)
% 用 schedule 里的 timing 覆盖默认时间。
% 这样 MATLAB 运行程序和 Python 生成的日程文件使用同一套时间参数。
if ~isfield(schedule, 'metadata') || ~isfield(schedule.metadata, 'timing')
    % isfield(...) 判断结构体里有没有某个字段。
    % 如果 Excel 里没有 timing，就保留 default_config 里的默认时间。
    return;
end

t = schedule.metadata.timing;
% 为了少写一点，把 schedule.metadata.timing 临时叫做 t。

if isfield(t, 'prepare_s'), cfg.prepare = double(t.prepare_s); end
if isfield(t, 'video_s'), cfg.video = double(t.video_s); end
if isfield(t, 'post_video_hold_s'), cfg.post_video_hold = double(t.post_video_hold_s); end
if isfield(t, 'response_s'), cfg.response = double(t.response_s); end
if isfield(t, 'iti_options_s'), cfg.iti_options = double(t.iti_options_s(:)'); end
if isfield(t, 'iti_min_s'), cfg.iti_min = double(t.iti_min_s); end
if isfield(t, 'iti_max_s'), cfg.iti_max = double(t.iti_max_s); end
if isfield(t, 'final_rest_s'), cfg.final_rest = double(t.final_rest_s); end
if isfield(t, 'initial_dummy_s'), cfg.initial_dummy = double(t.initial_dummy_s); end
if isfield(schedule.metadata, 'visual_videos') && isfield(schedule.metadata.visual_videos, 'root')
    cfg.video_dir = fullfile(cfg.script_dir, text_value(schedule.metadata.visual_videos.root));
    cfg.video_session_pattern = text_value(schedule.metadata.video_session_pattern);
end

if isfield(schedule.metadata, 'scanner') && isfield(schedule.metadata.scanner, 'trigger_keys')
    cfg.trigger_key_names = text_list(schedule.metadata.scanner.trigger_keys, cfg.trigger_key_names);
elseif isfield(schedule.metadata, 'scanner') && isfield(schedule.metadata.scanner, 'trigger_key')
    cfg.trigger_key_names = text_list(schedule.metadata.scanner.trigger_key, cfg.trigger_key_names);
end
end

function run_data = find_run(schedule, session_id, run_num)
% 使用 session + 全局 run 编号联合查找；session_id 为空时只按 run 查找。
session_num = str2double(text_value(session_id));
for i = 1:numel(schedule.runs)
    % i 是循环变量。第一次 i=1，第二次 i=2，一直到最后一个 run。
    candidate = schedule.runs(i);
    if double(candidate.run) ~= double(run_num)
        continue;
    end

    if ~isnan(session_num) && isfield(candidate, 'session') && ...
            double(candidate.session) ~= session_num
        continue;
    end

    run_data = candidate;
    return;
end

if isnan(session_num)
    error('实验日程中没有第 %d 轮。', run_num);
end
error('实验日程中没有 Session %d / Run %d。请核对会话与全局轮次编号。', ...
    session_num, run_num);
end

function validate_run_trial_count(schedule, run_num, n_trials)
% Each run declares its own trial count in Runs; there is no fixed count here.
run_data = find_run(schedule, '', run_num);
assert(n_trials == double(run_data.n_trials), 'Trial count does not match Runs.n_trials.');
end

function iti_values = get_iti_values(trials, ~)
% Missing ITIs are errors; never add randomness during execution.
iti_values = double([trials.iti_s]');
assert(all(isfinite(iti_values) & iti_values > 0), 'Invalid or missing ITI in Trials.');
end

function seconds = planned_duration(cfg, iti_values)
% 估算本 run 总时长。
% 与共享计时引擎使用同一组阶段参数。
% 正式运行由 FmriTimingEngine 安排绝对截止时间，并记录真实翻屏时刻。
fixed_seconds = cfg.prepare + cfg.video + cfg.post_video_hold + cfg.response;
seconds = cfg.initial_dummy + sum(fixed_seconds + iti_values) + cfg.final_rest;
end

function input = make_input(cfg)
% 统一设置实验会用到的按键。
% ready_keys：开始前确认准备好，按 1。
% yes_keys/no_keys：回答阶段按 1/2。
% trigger_keys：扫描仪触发键，默认兼容 S、5 和 t。
% escape_keys：任何阶段按 ESC 都会中止并保存已有数据。
input.device = [];
% device 为空表示使用默认键盘。

input.space_keys = key_indices({'space', 'SPACE'});
% {'space', 'SPACE'} 是 cell 数组，里面放多个可能的按键名字。

input.escape_keys = key_indices({'ESCAPE', 'escape'});
input.ready_keys = key_indices({'1!', '1'});
input.yes_keys = key_indices({'1!', '1'});
input.no_keys = key_indices({'2@', '2'});
input.trigger_keys = key_indices(cfg.trigger_key_names);

if isempty(input.space_keys) || isempty(input.escape_keys) || isempty(input.trigger_keys)
    error('无法识别必要按键。');
end

KbQueueCreate(input.device);
% 创建键盘队列。

KbQueueStart(input.device);
% 开始记录键盘事件。

KbQueueFlush(input.device);
% 清空队列，避免之前按过的键被读到。
end

function idx = key_indices(names)
% 把按键名字转成 Psychtoolbox 需要的 key code。
% 同一个按键在不同键盘布局下名字可能略有不同，所以传入多个候选名字。
idx = [];
for i = 1:numel(names)
    try
        key = KbName(names{i});
        % KbName 把 'space'、'1'、'S' 这种名字转成数字 key code。

        idx = [idx key(:)']; %#ok<AGROW>
        % [idx key(:)'] 表示把新 key code 接到 idx 后面。
    catch
        % 如果某个按键名字在当前系统不认识，就跳过它。
    end
end
idx = unique(idx);
% unique 去掉重复的 key code。
end

function show_intro(win, win_rect, cx, cy, input, subject, n_trials, ~, max_wait_s)
% 实验开始前的说明页。
% 这里显示 session、run 编号和 trial 数。
% 按 1 只是说明“实验员准备好了”，真正的计时零点还在下一步：
% 所有模式都等扫描仪 S 触发。
draw_screen(win, win_rect, ...
    '形状感知视觉实验', ...
    sprintf('Session %s，Run %s，共 %d 个试次', ...
        subject.session_id, subject.run_id, n_trials), ...
    0, 0);
draw_text(win, '准备好后按 1', cx, cy + 150, 30, [200 200 200]);
Screen('Flip', win);
wait_for_key(input, input.ready_keys, max_wait_s);
end

function start_time = wait_scanner_start(win, win_rect, input)
% 扫描触发开始方式。
% 程序会一直等扫描仪发 S 触发。第一个 S 触发的时间就是 start_time。
% 之后再运行 cfg.initial_dummy 指定的固定空扫/基线时长。
msg = '等待扫描仪 S 触发';

draw_screen(win, win_rect, '准备', msg, 0, 0);
Screen('Flip', win);
flush_keys(input);

while true
    [codes, first_press] = read_keys(input);
    if pressed(codes, input.escape_keys)
        abort_now();
    end

    trigger_times = first_press(input.trigger_keys);
        % first_press(input.trigger_keys) 取出所有扫描仪 trigger 键的触发时间。

    trigger_times = sort(trigger_times(trigger_times > 0));
    % 只保留大于 0 的时间，并按从早到晚排序。

    for i = 1:numel(trigger_times)
        start_time = trigger_times(i);
        tr_log('reset', start_time);
        tr_log('add_time', start_time);
        return;
    end
    WaitSecs(0.005);
end
end

function show_preload_progress(win, win_rect, index, count)
draw_screen(win, win_rect, '视频预加载', ...
    sprintf('正在解码缓存 %d / %d，请等待；', index, count), 0, 0);
Screen('Flip', win);
end

function draw_response_screen(win, win_rect, trial_num, n_trials, answered)
% 画回答阶段屏幕。
% answered 为 true 时，显示“已记录回答”，但阶段仍会等到固定时长结束。
draw_screen(win, win_rect, '是否和前一个物体一样？', '1 = 是     2 = 否', trial_num, n_trials);
if answered
    [cx, cy] = RectCenter(win_rect);
    draw_text(win, '已记录回答', cx, cy + 120, 28, [130 130 130]);
end
end

function draw_screen(win, win_rect, title_text, subtitle_text, trial_num, n_trials)
% 画一个最基础的黑底白字屏幕。
% 所有实验阶段都复用这个函数，避免每个阶段重复写 Screen 绘图代码。
[cx, cy] = RectCenter(win_rect);
% RectCenter 返回窗口中心点坐标。

Screen('FillRect', win, [0 0 0], win_rect);
% FillRect 用黑色填满整个屏幕。[0 0 0] 是 RGB 黑色。

draw_text(win, title_text, cx, cy - 70, 54, [255 255 255]);
% [255 255 255] 是 RGB 白色。

if ~isempty(subtitle_text)
    draw_text(win, subtitle_text, cx, cy + 25, 30, [190 190 190]);
end

if n_trials > 0
    draw_text(win, sprintf('%d / %d', trial_num, n_trials), cx, win_rect(2) + 45, 22, [150 150 150]);
    % sprintf 把数字格式化成文字，例如 "3 / 30"。
end
end

function draw_text(win, text_arg, x, y, font_size, color)
% 在指定位置居中画文字。
% double(text_arg) 是为了让 Psychtoolbox 更稳定地显示中文。
font_size = round(font_size * 1.25);
% 所有屏幕文字按比例放大，保证主标题、提示和页码一起变大。

text_arg = text_value(text_arg);
if isempty(text_arg)
    return;
end

text_to_draw = double(text_arg);
% 对中文来说，直接传 char 有时会乱码；转成 double 后更稳定。

Screen('TextSize', win, font_size);
bounds = Screen('TextBounds', win, text_to_draw, 0, 0);
% TextBounds 计算这段文字画出来会占多大区域。

x1 = round(x - RectWidth(bounds) / 2);
y1 = round(y - RectHeight(bounds) / 2);
% 上面两行把文字左上角位置算出来，让文字中心落在 (x, y)。

Screen('DrawText', win, text_to_draw, x1, y1, color);
end

function check_keys(input)
% 在非回答阶段检查按键。
% 这里不处理 1/2 回答，只做两件事：
% 1. 如果按了扫描仪 trigger 键，就记录 scanner trigger。
% 2. 如果按了 ESC，就中止实验。
[codes, first_press] = read_keys(input);
tr_log('add_keys', first_press, input.trigger_keys);
if pressed(codes, input.escape_keys)
    abort_now();
end
end

function ok = wait_for_key(input, target_keys, timeout_s)
% 等待某个指定按键。
% 用在开始确认、结束确认这些地方。
% 如果超过 timeout_s 还没按，也会返回，避免程序一直卡住。
flush_keys(input);
ok = false;
% ok 最后表示有没有等到目标按键。

t0 = GetSecs;
% t0 是开始等待的时间。

while true
    [codes, first_press] = read_keys(input);
    tr_log('add_keys', first_press, input.trigger_keys);

    if pressed(codes, input.escape_keys)
        abort_now();
    end
    if pressed(codes, target_keys)
        ok = true;
        WaitSecs(0.12);
        return;
    end
    if GetSecs - t0 >= timeout_s
        return;
    end
    WaitSecs(0.005);
end
end

function ok = wait_for_exit_key(input, target_keys, timeout_s)
% 最后一屏退出专用：直接轮询键盘当前状态，检测到空格后立即返回。
ok = false;
flush_keys(input);
t0 = GetSecs;

while true
    [key_down, ~, key_code] = KbCheck(input.device);

    if key_down
        if pressed(key_code, input.escape_keys)
            abort_now();
        end
        if pressed(key_code, target_keys)
            ok = true;
            WaitSecs(0.12);
            return;
        end
    end

    if GetSecs - t0 >= timeout_s
        return;
    end
    WaitSecs(0.005);
end
end

function flush_keys(input)
% 清空键盘队列。
% 这样进入下一个阶段时，前一个阶段残留的按键不会被误读。
KbQueueFlush(input.device);
WaitSecs(0.05);
end

function [codes, first_press] = read_keys(input)
% 读取键盘队列。
% codes 表示哪些键按下过。
% first_press 记录每个键第一次按下的时间，用它计算反应时。
% 读完后立刻清空队列，避免同一次按键在下一轮循环里被重复使用。
[has_key, first_press] = KbQueueCheck(input.device);
% KbQueueCheck 会返回：
% has_key：有没有按键事件；
% first_press：每个键第一次按下的时间。

if has_key
    codes = first_press > 0;
    % first_press > 0 会得到一组 true/false。
    % 某个位置为 true，表示对应 key code 被按过。

    KbQueueFlush(input.device);
else
    codes = false(1, 256);
    % false(1, 256) 创建 1 行 256 列的全 false 数组，表示没有按键。

    first_press = zeros(1, 256);
end
end

function yes = pressed(codes, keys)
% 判断 keys 这一组按键里是否有任意一个被按下。
yes = ~isempty(keys) && any(codes(keys));
end

function row = make_trial_row(trial, run_id, trial_num, trials_per_run, trial_type, onset, duration_s, response, rt, is_correct)
% 生成最终 events.tsv 里的一行。
% 本程序每个 trial 会写多行事件：
% - trial_type 区分准备、视频、视频后等待、1-back 选择和 ITI
% - onset/duration 来自对应阶段
% - 分析数据中的物体 ID 根据 stimulus_number 自动生成
% - response/accuracy/rt 来自回答阶段
% Excel 无需维护 stimulus_id、object_id 等重复物体字段。
row.onset = round_ms(onset);
% onset：事件开始时间，单位秒，相对于 start_time。

row.duration = round_ms(duration_s);
% duration：事件持续时间。

row.trial_type = trial_type;
% trial_type 是 BIDS 常用列名，用来区分本行是哪一种事件。

row.trial_index = trial_num;
% trial_index：当前 run 内的 trial 序号，方便按 run 内顺序检查数据。

row.trial_id = trial_field(trial, 'trial_id', fallback_trial_id(run_id, trial_num, trials_per_run));
row.stimulus_id = sprintf('obj_%03d', double(trial.stimulus_number));
row.object_id = sprintf('obj_%06d', double(trial.stimulus_number));
row.category = trial_field(trial, 'category', 'n/a');
row.stim_file = trial_field(trial, 'stim_file', 'n/a');
% 上面几行优先使用 Excel 里的字段；如果 Excel 没有，就用默认值或自动生成。

row.nback_target = trial_field(trial, 'nback_target', 'n/a');
row.correct_response = trial_field(trial, 'correct_response', 'n/a');
% nback_target 和 correct_response 来自 schedule，用于后续排除 target 或核对行为正确性。

row.response = response;
% response：yes、no 或 no_response。

row.accuracy = sprintf('%d', is_correct);
% accuracy 保存为 '1' 或 '0'，方便表格里看。

if isnan(rt)
    row.rt = 'n/a';
    % 没有回答时，反应时写 n/a。
else
    row.rt = sprintf('%.3f', round_ms(rt));
    % 有回答时，反应时保留三位小数。
end
end

function row = make_empty_event_row(trial_type, onset, duration_s)
% 生成不属于某个具体 trial 的事件行，例如 run 末尾的 final_rest。
row.onset = round_ms(onset);
row.duration = round_ms(duration_s);
row.trial_type = trial_type;
row.trial_index = NaN;
row.trial_id = 'n/a';
row.stimulus_id = 'n/a';
row.object_id = 'n/a';
row.category = 'n/a';
row.stim_file = 'n/a';
row.nback_target = 'n/a';
row.correct_response = 'n/a';
row.response = 'n/a';
row.accuracy = 'n/a';
row.rt = 'n/a';
end

function rows = empty_trial_rows()
% 创建一个空的结果结构。
% 这样即使还没完成任何 trial，save_run 也能生成空表，不会因为变量不存在而报错。
rows = struct( ...
    'onset', {}, ...
    'duration', {}, ...
    'trial_type', {}, ...
    'trial_index', {}, ...
    'trial_id', {}, ...
    'stimulus_id', {}, ...
    'object_id', {}, ...
    'category', {}, ...
    'stim_file', {}, ...
    'nback_target', {}, ...
    'correct_response', {}, ...
    'response', {}, ...
    'accuracy', {}, ...
    'rt', {});
end

function show_summary(win, win_rect, cx, cy, rows, timing_summary)
if nargin<6, timing_summary=[]; end
% 结束时显示简单统计。
% 这里只做现场检查用：完成多少、回答多少、正确多少、平均反应时。
% 正式分析仍然应该使用保存出来的 events.tsv。
if ~isempty(rows)
    response_mask = strcmp({rows.trial_type}, 'one_back_choice');
    rows = rows(response_mask);
end

total = numel(rows);
% total 是完成的 trial 数。

answered = 0;
correct = 0;
rt_values = [];

for i = 1:total
    if ~strcmp(rows(i).response, 'no_response')
        answered = answered + 1;
        % answered + 1 表示计数加一。
    end
    if strcmp(rows(i).accuracy, '1')
        correct = correct + 1;
    end
    rt = str2double(rows(i).rt);
    % rows(i).rt 是文字；str2double 把它转成数字。
    % 如果 rt 是 'n/a'，转出来会是 NaN。

    if ~isnan(rt)
        rt_values(end + 1) = rt; %#ok<AGROW>
    end
end

if isempty(rt_values)
    mean_rt = 0;
else
    mean_rt = mean(rt_values);
end

Screen('FillRect', win, [0 0 0], win_rect);
draw_text(win, '结果', cx, cy - 150, 52, [255 255 255]);
draw_text(win, sprintf('试次：%d', total), cx, cy - 55, 30, [190 190 190]);
draw_text(win, sprintf('已回答：%d / %d', answered, total), cx, cy, 30, [190 190 190]);
draw_text(win, sprintf('正确：%d / %d', correct, total), cx, cy + 55, 30, [190 190 190]);
draw_text(win, sprintf('平均反应时：%.2f 秒', mean_rt), cx, cy + 110, 30, [190 190 190]);
if ~isempty(timing_summary)
    draw_text(win, sprintf('计划 %.3f 秒；实际 %.3f 秒', ...
        timing_summary.planned_seconds,timing_summary.actual_seconds), ...
        cx,cy+160,24,[190 190 190]);
    if timing_summary.timing_valid
        quality_text='阶段计时检查通过';
    else
        quality_text='检测到计时异常，详情已记录';
    end
    draw_text(win,quality_text,cx,cy+205,24,[190 190 190]);
end
draw_text(win, '按空格继续', cx, cy + 250, 26, [120 120 120]);
Screen('Flip', win);
end

function outputs = save_run(subject, cfg, rows, planned_seconds, start_time, aborted, timing_engine)
if nargin < 7, timing_engine=[]; end
% 保存本次 run 的数据。
% 主要输出：
% 1. *_events.tsv：最重要，后续分析用这个。
% 2. 带时间戳的 xlsx：方便人工打开检查，也包含 scanner trigger。
% 3. *_info.mat：保存被试信息、配置、是否中途退出等元信息。
if exist(cfg.output_dir, 'dir') ~= 7
    mkdir(cfg.output_dir);
end

timestamp = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
% timestamp 是当前时间，用来避免每次保存的 Excel/mat 文件互相覆盖。

sub_label = bids_label(subject.sub_id);
ses_label = bids_label(subject.session_id);
run_label = bids_label(subject.run_id);
run_output_dir = fullfile(cfg.output_dir, sprintf('sub-%s', sub_label), ...
    sprintf('ses-%s', ses_label));
if exist(run_output_dir, 'dir') ~= 7
    mkdir(run_output_dir);
end
prefix = sprintf('sub-%s_ses-%s_task-visual_run-%s_%s', ...
    sub_label, ses_label, run_label, timestamp);

events_table = trial_table(rows);
% trial_table 把结构体数组 rows 转成 MATLAB table，writetable 才能保存。

events_tsv = fullfile(run_output_dir, sprintf('sub-%s_ses-%s_task-visual_run-%s_events.tsv', ...
    sub_label, ses_label, run_label));
events_tsv = unique_output_path(events_tsv, timestamp);
fmri_write_events(events_table, events_tsv, fullfile(run_output_dir, [prefix '.xlsx']));
% 所有阶段 duration = 实测结束 - 实测开始；TSV/Excel 统一显示 6 位小数。

trigger_table = tr_log('table');
% 取出实验过程中记录到的扫描仪触发时间。

if ~isempty(trigger_table)
    triggers_tsv = fullfile(run_output_dir, sprintf('sub-%s_ses-%s_task-visual_run-%s_triggers.tsv', ...
        sub_label, ses_label, run_label));
    triggers_tsv = unique_output_path(triggers_tsv, timestamp);
    writetable(trigger_table, triggers_tsv, 'FileType', 'text', 'Delimiter', '\t');
    writetable(trigger_table, fullfile(run_output_dir, [prefix '.xlsx']), 'Sheet', 'triggers');
else
    triggers_tsv = '';
end

timing_paths=struct();
if ~isempty(timing_engine)
    timing_paths=timing_engine.saveLogs(run_output_dir,prefix);
    run_info.timing=timing_engine.summary();
    run_info.actual_seconds=run_info.timing.actual_seconds;
    run_info.timing_valid=run_info.timing.timing_valid;
    run_info.output_timing=timing_paths;
    fprintf('RUN TIMING: planned %.6f s; actual %.6f s; extension %.6f s; valid %d\n', ...
        planned_seconds,run_info.actual_seconds,run_info.timing.schedule_extension_s,run_info.timing_valid);
    if ~run_info.timing_valid
        warning('fmri:TimingQuality','Timing anomaly recorded; inspect *_timing.tsv and *_frames.tsv.');
    end
end

run_info.subject = subject;
% run_info 是保存到 mat 文件里的结构体，记录本次实验基本信息。

run_info.config = cfg;
run_info.planned_seconds = planned_seconds;
run_info.start_time = start_time;
run_info.aborted = aborted;
run_info.output_events_tsv = events_tsv;
run_info.output_triggers_tsv = triggers_tsv;
run_info.output_check_xlsx = fullfile(run_output_dir, [prefix '.xlsx']);
info_mat = fullfile(run_output_dir, [prefix '_info.mat']);
save(info_mat, 'run_info');

outputs.timing=timing_paths;
outputs.events_tsv = events_tsv;
outputs.triggers_tsv = triggers_tsv;
outputs.check_xlsx = fullfile(run_output_dir, [prefix '.xlsx']);
outputs.info_mat = info_mat;
end

function file_path = unique_output_path(file_path, timestamp)
% 如果目标文件已经存在，就在文件名后加时间戳，避免覆盖旧数据。
if exist(file_path, 'file') ~= 2
    return;
end

[folder, base, ext] = fileparts(file_path);
candidate = fullfile(folder, sprintf('%s_%s%s', base, timestamp, ext));
counter = 1;
while exist(candidate, 'file') == 2
    counter = counter + 1;
    candidate = fullfile(folder, sprintf('%s_%s_%02d%s', base, timestamp, counter, ext));
end
file_path = candidate;
end

function t = trial_table(rows)
% 把 trial_rows 结构转成 table。
% 如果没有任何 trial，也返回带同样列名的空表，保证 writetable 不出错。
if ~isempty(rows)
    t = struct2table(rows);
    % struct2table 把结构体数组转成表格。
    return;
end

empty_text = cell(0, 1);
% cell(0, 1) 是 0 行 1 列的空 cell，用来表示空文字列。

t = table(nan(0, 1), nan(0, 1), empty_text, nan(0, 1), empty_text, ...
    empty_text, empty_text, empty_text, empty_text, empty_text, empty_text, ...
    empty_text, empty_text, empty_text, ...
    'VariableNames', {'onset', 'duration', 'trial_type', 'trial_index', ...
    'trial_id', 'stimulus_id', 'object_id', 'category', 'stim_file', ...
    'nback_target', 'correct_response', 'response', 'accuracy', 'rt'});
end

function value = trial_field(trial, field_name, default_value)
% 从 schedule 的某个 trial 里取字段。
% 例如 trial_field(trial, 'category', 'n/a')。
% 如果字段不存在或是空的，就返回 default_value。
value = default_value;
% 先假设用默认值。

if isfield(trial, field_name)
    text = strtrim(text_value(trial.(field_name)));
    % trial.(field_name) 是“动态字段名”写法。
    % 比如 field_name = 'category' 时，它等价于 trial.category。

    if ~isempty(text)
        value = text;
    end
end
end

function label = fallback_trial_id(run_id, trial_num, trials_per_run)
% 如果 Excel 没有 trial_id，就自己补一个 6 位编号。
% 编号规则：前面 run 的 trial 数 + 当前 trial。
% 例如每个 run 30 个 trial，run 2 的第 1 个 trial 就是 000031。
run_num = str2double(text_value(run_id));
if isnan(run_num)
    run_num = 1;
end
label = sprintf('%06d', (run_num - 1) * trials_per_run + trial_num);
end

function value = round_ms(value)
% 时间统一保留到毫秒，也就是小数点后三位。
if isnumeric(value) && isscalar(value) && ~isnan(value)
    value = round(value * 1000) / 1000;
else
    value = NaN;
end
end

function label = bids_label(value)
% 清理 BIDS 文件名标签。
% 文件名里的 sub/ses/run 标签只保留字母和数字，避免空格或中文影响分析软件读取。
label = strtrim(text_value(value));
if strncmp(label, 'sub-', 4) || strncmp(label, 'ses-', 4) || strncmp(label, 'run-', 4)
    label = label(5:end);
    % 如果用户输入了 sub-001，就去掉前面的 sub-，只保留 001。
end
label = regexprep(label, '[^A-Za-z0-9]', '');
% regexprep 用正则表达式替换文字。
% 这里把所有非字母、非数字的字符删掉。

if isempty(label)
    label = 'unknown';
end
end

function text = text_value(value)
% 把 MATLAB 常见类型转成普通 char。
% Excel 读进来后，有些字段可能是 char、string、数字或 cell，这里统一一下。
if ischar(value)
    text = value;
elseif isstring(value)
    text = char(value);
elseif isnumeric(value) || islogical(value)
    if isscalar(value)
        text = num2str(value);
    else
        text = strtrim(sprintf('%g ', value));
    end
elseif iscell(value) && ~isempty(value)
    text = text_value(value{1});
else
    text = '';
end
end

function values = text_list(value, default_values)
% 把 Excel 里的 trigger key 配置转成 cellstr。
% 这样 scanner.trigger_key 可以写成单个字符串，scanner.trigger_keys 也可以写成字符串数组。
if nargin < 2
    default_values = {};
end
values = default_values;

if ischar(value) || isstring(value)
    values = cellstr(value);
elseif iscell(value)
    values = cell(size(value));
    for i = 1:numel(value)
        values{i} = text_value(value{i});
    end
elseif isnumeric(value)
    values = cellstr(string(value));
end

values = values(~cellfun(@isempty, values));
if isempty(values)
    values = default_values;
end
end

function out = tr_log(action, varargin)
% 预分配扫描触发记录；运行期间只写数值，不追加结构体或格式化字符串。
persistent active start_time times count
if isempty(active)
    active=false; start_time=NaN; times=zeros(10000,1); count=0;
end
out=[];
switch action
    case 'reset'
        active=true; start_time=varargin{1}; count=0;
    case 'add_time'
        if active, append(varargin{1}); end
    case 'add_keys'
        if active
            values=varargin{1}; keys=varargin{2};
            values=sort(values(keys)); values=values(values>0);
            for value=values(:)', append(value); end
        end
    case 'stop'
        active=false;
    case 'table'
        if count==0, out=table();
        else
            absolute_time=times(1:count);
            relative_time=absolute_time-start_time;
            tr_index=(0:count-1)';
            out=table(tr_index,absolute_time,relative_time);
        end
    otherwise
        error('Unknown trigger log action: %s',action);
end
    function append(value)
        count=count+1;
        assert(count<=numel(times),'fmri:TriggerOverflow','Scanner trigger log capacity exceeded.');
        times(count)=value;
    end
end

function cleanup_experiment(win, input)
% 清理 Psychtoolbox 资源。
% 无论正常结束、报错还是 ESC 退出，都尽量关闭全屏窗口并释放键盘队列。
try
    % try/catch 在这里是为了“尽量清理”。
    % 即使某一步清理失败，也不要再制造新的报错。
    if ~isempty(win)
        Screen('CloseAll');
    end
catch
end

try
    if isstruct(input) && isfield(input, 'device')
        KbQueueRelease(input.device);
    end
catch
end
end

function abort_now()
% ESC 中止实验。
% 这里先关闭屏幕，再抛出一个专门的异常。
% 主程序 catch 到这个异常后会保存已经完成的 trial。
Screen('CloseAll');
throwAsCaller(MException('visual:Abort', '实验被用户终止。'));
% MException 创建一个异常对象。
% identifier 写成 visual:Abort，主程序 catch 里就是靠这个识别 ESC 退出。
end
