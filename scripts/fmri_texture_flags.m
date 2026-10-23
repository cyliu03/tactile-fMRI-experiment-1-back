function selected = fmri_texture_flags(frame, preferred, scale)
% The old fast PTB shader can sample across RGB planes at enlarged borders.
% At native size/downsampling, pixel centers stay inside the image. Enlarged
% images use the standard path unless every border component is identical.
if nargin<3, scale=Inf; end
selected=preferred;
if preferred~=4, return; end
if ~isa(frame,'uint8') || ndims(frame)~=3 || size(frame,3)~=3
    selected=0; return;
end
if scale<=1, return; end
edges=[reshape(frame(:,[1 end],:),[],3); reshape(frame([1 end],:,:),[],3)];
if ~all(edges(:)==edges(1))
    selected=0;
end
end
