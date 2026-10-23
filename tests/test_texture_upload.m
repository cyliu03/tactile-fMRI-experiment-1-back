function test_texture_upload()
% Compare PTB's documented fast texture path against the original RGB path.
root=fileparts(fileparts(mfilename('fullpath')));
addpath(fullfile(root,'scripts'));
reader=VideoReader(fullfile(root,'video','train','session01','101.mp4'));
frame=readFrame(reader);
old=Screen('Preference','SkipSyncTests',2);
sync_guard=onCleanup(@()Screen('Preference','SkipSyncTests',old));
win=Screen('OpenWindow',max(Screen('Screens')),0,[0 0 960 720]);
guard=onCleanup(@()Screen('CloseAll'));
flags=[0 4]; times=zeros(40,2);
for pass=1:2
    for i=1:40
        begin=GetSecs;
        tex=Screen('MakeTexture',win,frame,0, ...
            fmri_texture_flags(frame,flags(pass),max(720/size(frame,1),720/size(frame,2))));
        times(i,pass)=GetSecs-begin;
        Screen('FillRect',win,0);
        Screen('DrawTexture',win,tex,[],[120 0 840 720]);
        Screen('Flip',win);
        Screen('Close',tex);
    end
end
maximum_error=0;
for index=[1 61 181 360 0 -1 -2]
    if index>0
        reader.CurrentTime=(index-1)/reader.FrameRate;
        frame=readFrame(reader);
    else
        % Asymmetric colors also detect channel/order/orientation errors that
        % would be difficult to notice in the grayscale source videos.
        [x,y]=meshgrid(0:239,0:159);
        frame=cat(3,uint8(x),uint8(y),uint8(mod(x+2*y,256)));
        if index<0
            for channel=1:3
                color=30*channel;
                if index==-2, color=128; end
                frame([1 end],:,channel)=uint8(color);
                frame(:,[1 end],channel)=uint8(color);
            end
        end
    end
    pictures=cell(2,1);
    for pass=1:2
        selected=fmri_texture_flags(frame,flags(pass),max(720/size(frame,1),720/size(frame,2)));
        tex=Screen('MakeTexture',win,frame,0,selected);
        Screen('FillRect',win,0);
        Screen('DrawTexture',win,tex,[],[120 0 840 720]);
        pictures{pass}=Screen('GetImage',win,[],'backBuffer');
        Screen('Flip',win);
        Screen('Close',tex);
    end
    error_values=abs(double(pictures{1}(:))-double(pictures{2}(:)));
    frame_error=max(error_values);
    maximum_error=max(maximum_error,frame_error);
    fprintf('TEXTURE FRAME %d flags %d error max %.0f mean %.6f\n',index,selected,frame_error,mean(error_values));
    imwrite(pictures{1},fullfile(root,'tests','timing_validation',sprintf('texture_standard_%d.png',index)));
    imwrite(pictures{2},fullfile(root,'tests','timing_validation',sprintf('texture_fast_%d.png',index)));
end
assert(maximum_error<=1,'Fast texture rendering differs from the original by more than one uint8 level.');
fprintf('TEXTURE UPLOAD median standard %.3f ms; fast %.3f ms; max pixel error %.0f.\n', ...
    1000*median(times(3:end,1)),1000*median(times(3:end,2)),maximum_error);
imwrite(pictures{2},fullfile(root,'tests','timing_validation','fast_texture_preview.png'));
clear guard sync_guard;
end
