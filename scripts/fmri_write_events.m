function fmri_write_events(events, tsv_path, xlsx_path)
% Export measured event times consistently, after the timed run has ended.
% TSV: fixed six decimals. XLSX: numeric doubles, displayed to six decimals.
fields={'onset','duration','planned_onset','planned_duration','actual_end', ...
    'onset_error','duration_error','schedule_shift'};
fields=fields(ismember(fields,events.Properties.VariableNames));
if ~isempty(events)
    assert(all(ismember({'onset','duration','actual_end'},events.Properties.VariableNames)), ...
        'fmri:MissingMeasuredDuration','Events must include measured start, duration and end.');
    assert(all(isfinite(events.duration) & events.duration>=0) && ...
        all(abs(events.duration-(events.actual_end-events.onset))<1e-8), ...
        'fmri:InvalidMeasuredDuration','Every duration must equal measured end minus onset.');
end
text_events=events;
for i=1:numel(fields)
    name=fields{i};
    assert(isnumeric(events.(name)),'Timing columns must be numeric.');
    text_events.(name)=compose('%.6f',events.(name));
end
writetable(text_events,tsv_path,'FileType','text','Delimiter','\t');
writetable(events,xlsx_path,'Sheet','events');
format_times(xlsx_path,find(ismember(events.Properties.VariableNames,fields)));
end

function format_times(path, columns)
% Apply an OOXML number format without Excel/COM or external dependencies.
% Leave cell values numeric and retain all other workbook content/styles.
work=tempname; mkdir(work);
guard=onCleanup(@()rmdir(work,'s'));
unpacked=fullfile(work,'unpacked');
unzip(path,unpacked);
styles_path=fullfile(unpacked,'xl','styles.xml');
styles=xmlread(styles_path); root=styles.getDocumentElement();
ns=char(root.getNamespaceURI());
formats=root.getElementsByTagName('numFmts');
if formats.getLength()==0
    formats=styles.createElementNS(ns,'numFmts');
    root.insertBefore(formats,root.getFirstChild());
else
    formats=formats.item(0);
end
existing=formats.getElementsByTagName('numFmt');
format_id=164;
for i=0:existing.getLength()-1
    format_id=max(format_id,str2double(char(existing.item(i).getAttribute('numFmtId')))+1);
end
fmt=styles.createElementNS(ns,'numFmt');
fmt.setAttribute('numFmtId',num2str(format_id)); fmt.setAttribute('formatCode','0.000000');
formats.appendChild(fmt);
formats.setAttribute('count',num2str(existing.getLength()));
xfs=root.getElementsByTagName('cellXfs').item(0);
xf_nodes=xfs.getElementsByTagName('xf');
original_count=xf_nodes.getLength();
style_map=nan(1,original_count);

book=xmlread(fullfile(unpacked,'xl','workbook.xml'));
sheets=book.getElementsByTagName('sheet'); relation='';
for i=0:sheets.getLength()-1
    if strcmp(char(sheets.item(i).getAttribute('name')),'events')
        relation=char(sheets.item(i).getAttribute('r:id')); break;
    end
end
rels=xmlread(fullfile(unpacked,'xl','_rels','workbook.xml.rels'));
nodes=rels.getElementsByTagName('Relationship'); target='';
for i=0:nodes.getLength()-1
    if strcmp(char(nodes.item(i).getAttribute('Id')),relation)
        target=char(nodes.item(i).getAttribute('Target')); break;
    end
end
assert(~isempty(target),'Cannot find events worksheet.');
if startsWith(target,'/'), sheet_path=fullfile(unpacked,target(2:end));
else, sheet_path=fullfile(unpacked,'xl',target); end
sheet=xmlread(sheet_path); cells=sheet.getElementsByTagName('c');
letters=arrayfun(@column_letters,columns,'UniformOutput',false);
for i=0:cells.getLength()-1
    cell_node=cells.item(i); ref=char(cell_node.getAttribute('r'));
    parts=regexp(ref,'^([A-Z]+)([0-9]+)$','tokens','once');
    if isempty(parts) || str2double(parts{2})<2 || ~ismember(parts{1},letters), continue; end
    kind=char(cell_node.getAttribute('t'));
    if ~isempty(kind) && ~strcmp(kind,'n'), continue; end
    old=char(cell_node.getAttribute('s'));
    if isempty(old), index=0; else, index=str2double(old); end
    if isnan(style_map(index+1))
        xf=xf_nodes.item(index).cloneNode(true);
        xf.setAttribute('numFmtId',num2str(format_id)); xf.setAttribute('applyNumberFormat','1');
        style_map(index+1)=xf_nodes.getLength(); xfs.appendChild(xf);
    end
    cell_node.setAttribute('s',num2str(style_map(index+1)));
end
xfs.setAttribute('count',num2str(xf_nodes.getLength()));
xmlwrite(styles_path,styles); xmlwrite(sheet_path,sheet);
entries=dir(unpacked); entries=entries(~ismember({entries.name},{'.','..'}));
archive=fullfile(work,'formatted.zip');
zip(archive,{entries.name},unpacked);
movefile(archive,path,'f');
end

function label=column_letters(index)
label='';
while index>0
    digit=mod(index-1,26);
    label=[char(65+digit) label]; %#ok<AGROW>
    index=floor((index-1)/26);
end
end
