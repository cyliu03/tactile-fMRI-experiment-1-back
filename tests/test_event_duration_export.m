function test_event_duration_export()
% Verify every phase, numeric Excel values, fixed TSV precision and failures.
root=fileparts(fileparts(mfilename('fullpath')));
addpath(fullfile(root,'scripts'));
folder=fullfile(root,'tests','timing_validation','duration_export');
if ~isfolder(folder), mkdir(folder); end
for modality={'visual','tactile'}
    if strcmp(modality{1},'visual')
        names={'initial_dummy_scans','prepare','view_video','post_video_hold', ...
            'one_back_choice','iti','final_rest'}';
    else
        names={'initial_dummy_scans','prepare','touch_shape','release_hold', ...
            'one_back_choice','iti','final_rest'}';
    end
    duration=[6.000123456;1.999876543;6.001234567;1.998765432;2.000456789;4;6.000987654];
    onset=[0;cumsum(duration(1:end-1))]; actual_end=onset+duration;
    planned_duration=[6;2;6;2;2;4;6];
    duration_error=duration-planned_duration;
    events=table(onset,duration,names,planned_duration,actual_end,duration_error, ...
        'VariableNames',{'onset','duration','trial_type','planned_duration','actual_end','duration_error'});
    tsv=fullfile(folder,[modality{1} '_events.tsv']);
    xlsx=fullfile(folder,[modality{1} '_events.xlsx']);
    fmri_write_events(events,tsv,xlsx);
    lines=splitlines(strtrim(fileread(tsv)));
    for i=2:numel(lines)
        parts=split(lines(i),sprintf('\t'));
        for col=[1 2 4 5 6]
            assert(~isempty(regexp(char(parts(col)),'^-?\d+\.\d{6}$','once')));
        end
        assert(abs(str2double(parts(2))-duration(i-1))<=0.5e-6+eps);
    end
    numeric=readtable(xlsx,'Sheet','events');
    assert(isnumeric(numeric.duration) && max(abs(numeric.duration-duration))<1e-12);
    % Appending scanner triggers, as production does, must preserve formatting.
    writetable(table([0;2],'VariableNames',{'trigger_time'}),xlsx,'Sheet','triggers');
    check_formats(xlsx,height(events));
    bad=events; bad.duration(3)=6;
    try
        fmri_write_events(bad,tsv,xlsx);
        error('test:MissingFailure','Nominal replacement was accepted.');
    catch ME
        assert(strcmp(ME.identifier,'fmri:InvalidMeasuredDuration'));
    end
    fprintf('PASS %s: all phase durations, fixed 6 decimals, numeric XLSX, triggers preserve style.\n',modality{1});
end
end

function check_formats(path,n)
folder=tempname; mkdir(folder);
guard=onCleanup(@()rmdir(folder,'s'));
unzip(path,folder);
styles=xmlread(fullfile(folder,'xl','styles.xml'));
xfs=styles.getElementsByTagName('cellXfs').item(0).getElementsByTagName('xf');
formats=styles.getElementsByTagName('numFmt'); ids=[];
for i=0:formats.getLength()-1
    node=formats.item(i);
    if strcmp(char(node.getAttribute('formatCode')),'0.000000')
        ids(end+1)=str2double(char(node.getAttribute('numFmtId'))); %#ok<AGROW>
    end
end
sheet=xmlread(fullfile(folder,'xl','worksheets','sheet1.xml'));
cells=sheet.getElementsByTagName('c'); checked=0;
for i=0:cells.getLength()-1
    node=cells.item(i); ref=char(node.getAttribute('r'));
    if isempty(regexp(ref,'^B([2-9]|[1-9][0-9]+)$','once')), continue; end
    style=str2double(char(node.getAttribute('s')));
    fmt=str2double(char(xfs.item(style).getAttribute('numFmtId')));
    assert(ismember(fmt,ids) && ~strcmp(char(node.getAttribute('t')),'s'));
    checked=checked+1;
end
assert(checked==n,'Every duration cell must retain numeric six-decimal style.');
end
