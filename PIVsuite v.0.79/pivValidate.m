function [pivData] = pivValidate(pivData,pivPar)
% pivValidate - validates displacement vectors in PIV data
%
% Usage:
%     [pivData] = pivValidate(pivData,pivPar)
%
% Inputs:
%     pivData ... (struct) structure containing more detailed results. Required field is
%        X, Y ... position, at which velocity/displacement is calculated
%        U, V ... displacements in x and y direction
%        status ... matrix describing status of velocity vectors (for values, see Outputs section)
%     pivPar ... (struct) parameters defining the evaluation. Following fields are considered:
%         vlTresh, vlEps ... Define treshold for the median test. To accepted, the difference of actual vector
%                            from the median (of vectors in the neighborhood) should be at most 
%                            vlTresh *(vlEps + (neighborhood vectors) - (their median)).
%         vlDist ... to what distance median test is performed (if vlDist = 1, kernel has  size 3x3; for 
%                    vlDist = 2, kernel is 5x5, and so on).  
%          vlDistSeq ... to what distance (in time) the median test is performed. If vlDistSeq == 1, medina test
%              will be based on one previous and one subsequent time slices. This parameter is taken in
%              account only if pivValidate.m is applied on pivData, in which contains data for image sequence.
%              If vlDist is not specified and if pivData contains results for an image sequence, vlDistSeq = 0
%              is assumed (that is, median test is based only on current time slice).
%         vlPasses ... number of passes of the median test
%
% Outputs:
%     pivData  ... (struct) structure containing more detailed results. If pivData was non-empty at the input, its 
%              fields are preserved. Following fields are added or updated: 
%        U, V ... x and y components of the velocity/displacement vector (spurious vectors replaced by NaNs)
%        Status ... matrix with statuis of velocity vectors (uint8). Bits have this coding:
%            1 (bit  1) ... masked (set by pivInterrogate)
%            2 (bit  2) ... cross-correlation failed (set by pivCrossCorr)
%            4 (bit  3) ... peak detection failed (set by pivCrossCorr)
%            8 (bit  4) ... indicated as spurious by median test based on image pair (set by pivValidate)
%           16 (bit  5) ... interpolated (set by pivReplaced)
%           32 (bit  6) ... smoothed (set by pivSmooth)
%           64 (bit  7) ... indicated as spurious by median test based on image sequence (set by pivValidate)
%          128 (bit  8) ... interpolated within image sequence (set by pivReplaced)
%          256 (bit  9) ... smoothed within an image sequence (set by pivSmooth)
%        spuriousN ... number of spurious vectors
%        spuriousX, spuriousY ... positions, at which the velocity is spurious
%        spuriousU, spuriousV ... components of the velocity/displacement vectors, which were indicated as
%                             spurious
%
%        
% This subroutine is a part of
%
% =========================================
%               PIVsuite
% =========================================
%
% PIVsuite is a set of subroutines intended for processing of data acquired with PIV (particle image
% velocimetry). 
%
% Written by Jiri Vejrazka, Institute of Chemical Process Fundamentals, Prague, Czech Republic
%
% For the use, see files example_XX_xxxxxx.m, which acompany this file. PIVsuite was tested with
% Matlab 7.12 (R2011a) and 7.14 (R2012a).
%
% In the case of a bug, contact me: vejrazka (at) icpf (dot) cas (dot) cz
%
%
% Requirements:
%     Image Processing Toolbox
% 
%     inpaint_nans.m
%         subroutine by John D'Errico, available at http://www.mathworks.com/matlabcentral/fileexchange/4551
%
%     smoothn.m
%         subroutine by Damien Garcia, available at 
%         http://www.mathworks.com/matlabcentral/fileexchange/274-smooth
%
% Credits:
%    PIVsuite is a redesigned version of PIVlab software [3], developped by W. Thielicke and E. J. Stamhuis. 
%    Some parts of this code are copied or adapted from it (especially from its piv_FFTmulti.m subroutine). 
%    PIVsuite uses 3rd party software:
%        inpaint_nans.m, by J. D'Errico, [2]
%        smoothn.m, by Damien Garcia, [5]
%        
% References:
%   [1] Adrian & Whesterweel, Particle Image Velocimetry, Cambridge University Press 2011
%   [2] John D'Errico, inpaint_nans subroutine, http://www.mathworks.com/matlabcentral/fileexchange/4551
%   [3] W. Thielicke and E. J. Stamhuid, PIVlab 1.31, http://pivlab.blogspot.com
%   [4] Raffel, Willert, Wereley & Kompenhans, Particle Image Velocimetry: A Practical Guide. 2nd edition,
%       Springer 2007
%   [5] Damien Garcia, smoothn subroutine, http://www.mathworks.com/matlabcentral/fileexchange/274-smooth


% Acronyms and meaning of variables used in this subroutine:
%    IA ... concerns "Interrogation Area"
%    im ... image
%    dx ... some index
%    ex ... expanded (image)
%    est ... estimate (velocity from previous pass) - will be used to deform image
%    aux ... auxiliary variable (which is of no use just a few lines below)
%    cc ... cross-correlation
%    vl ... validation
%    sm ... smoothing
%    Word "velocity" should be understood as "displacement"



%% Velocity field validation by median test

% initialize fields
vlMedU = pivData.U + NaN;       % velocity median in the neighborhood of given IA
vlMedV = vlMedU;
vlRmsU = vlMedU;       % rms (from median) in the neighborhood of given IA
vlRmsV = vlMedU;
X = pivData.X;
Y = pivData.Y;
U = pivData.U;
V = pivData.V;
status = pivData.Status;
if isfield(pivPar,'vlDistTSeq')
    distT = pivPar.vlDistTSeq;
else
    distT = 0;
end
if size(U,3) == 1
    distT = 0;
end
% choose parameters, depending if Pair or Sequence is validated
if size(U,3) == 1
    distXY = pivPar.vlDist;
    passes = pivPar.vlPasses;
    tresh = pivPar.vlTresh;
    epsi = pivPar.vlEps;
    statusbit = 4;
else
    distXY = pivPar.vlDistSeq;
    passes = pivPar.vlPassesSeq;
    tresh = pivPar.vlTreshSeq;
    epsi = pivPar.vlEpsSeq;
    statusbit = 7;
end

for kpass = 1:passes       % proceed in two passes
    % replace anything invalid by NaN. Invalid vectors are those with any flag in status, except flags
    % "smoothed" or "smoothed in a sequence".
    auxStatus = status;
    auxStatus = bitset(auxStatus,6,0);    % clear "smoothed" flag
    auxStatus = bitset(auxStatus,9,0);    % clear "smoothed in sequence" flag
    U(auxStatus~=0) = NaN;                % replace anything masked, wrong, interpolated or spurious by NaN
    V(auxStatus~=0) = NaN;
    % pad U and V with NaNs to allow validation at borders
    auxU = padarray(U,[distXY, distXY, distT],NaN);
    auxV = padarray(V,[distXY, distXY, distT],NaN);
    tpass = tic;
    % validate inner cells
    for kt = 1:size(U,3)
        if (kt-1)/5 == round((kt-1)/5) && size(U,3) > 1
            if kt > 1
                fprintf(' Average time %.2f s per time slice.\n',toc/5);
            end
            if isfield(pivPar,'expName')
                auxstr = pivPar.expName;
            else
                auxstr = '???';
            end
            fprintf('Validation of vectors in a sequence (%s): pass %d of %d, time slice %d of %d...',auxstr,kpass,passes,kt,size(U,3));
            if isfield(pivPar,'anLockFile') && numel(pivPar.anLockFile)>0
                flock = fopen(pivPar.anLockFile,'w');
                fprintf(flock,[datestr(clock) '\nValidating sequence...']);
                fclose(flock);
            end
            tic;
        end
        for kx = 1:size(U,2)
            for ky = 1:size(U,1)
                % compute the medians and deviations from median
                auxNeighU = auxU(ky:ky+2*distXY,kx:kx+2*distXY,kt:kt+2*distT);
                auxNeighV = auxV(ky:ky+2*distXY,kx:kx+2*distXY,kt:kt+2*distT);
                vlMedU(ky,kx,kt) = median(removeNaNs(reshape(auxNeighU,1,(2*distT+1)*(2*distXY+1)^2)));
                vlMedV(ky,kx,kt) = median(removeNaNs(reshape(auxNeighV,1,(2*distT+1)*(2*distXY+1)^2)));
                auxNeighU(distXY+1,distXY+1,distT+1) = NaN;   % remove examined vector from the rms calculation
                auxNeighV(distXY+1,distXY+1,distT+1) = NaN;
                vlRmsU(ky,kx,kt) = stdfast(auxNeighU-vlMedU(ky,kx,kt));  % rms of velues from the median
                vlRmsV(ky,kx,kt) = stdfast(auxNeighV-vlMedV(ky,kx,kt));
                if status(ky,kx,kt) == 0 && abs(U(ky,kx,kt)-vlMedU(ky,kx,kt))>(tresh*vlRmsU(ky,kx,kt)+epsi)
                    status(ky,kx,kt) = bitset(status(ky,kx,kt),statusbit);
                end
                if status(ky,kx,kt)==0 && abs(V(ky,kx,kt)-vlMedV(ky,kx,kt))>(tresh*vlRmsV(ky,kx,kt)+epsi)
                    status(ky,kx,kt) = bitset(status(ky,kx,kt),statusbit);
                end
            end
        end
    end
    if kt>1
        [~] = toc;
        fprintf(' Validation pass finished in %.2f s. \n',toc(tpass)); 
    end
end
% replace spurious vectors with NaN's
spurious = bitget(status,4) | bitget(status,7);
U(spurious) = NaN;       
V(spurious) = NaN;
% output detailed pivData
if size(U,3)==1
    auxSpur = logical(bitget(status,4))|logical(bitget(status,7));
    vlNSpur = sum(sum(auxSpur));    % number of spurious vectors
    spuriousX = X(auxSpur);
    spuriousY = Y(auxSpur);
    spuriousU = pivData.U(auxSpur);
    spuriousV = pivData.V(auxSpur);
else
    vlNSpur = zeros(size(U,3),1)+NaN;
    for kt=1:size(U,3)
        auxSpur = logical(bitget(status(:,:,kt),4))|logical(bitget(status(:,:,kt),7));
        vlNSpur(kt) = sum(sum(auxSpur));    % number of spurious vectors
    end
end

% output variables
pivData.U = U;
pivData.V = V;
pivData.Status = uint16(status);
pivData.spuriousN = vlNSpur;
if size(U,3)==1
    pivData.spuriousX = spuriousX;
    pivData.spuriousY = spuriousY;
    pivData.spuriousU = spuriousU;
    pivData.spuriousV = spuriousV;
end

end


%% XX Local functions

function [out] = removeNaNs(in)
% remove NaNs from a vector or column
out = in(~isnan(in));
end

function [out] = stdfast(in)
% computes root-mean-square (reprogramed, because std in Matlab is somewhat slow due to some additional tests)
in = reshape(in,1,numel(in));
notnan = ~isnan(in);
n = sum(notnan);
in(~notnan) = 0;
avg = sum(in)/n;
out = sqrt(sum(((in - avg).*notnan).^2)/(n-0)); % there should be -1 in the denominator for true std
end


