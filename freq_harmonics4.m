
%% ============================================================
% CRICKET FREQUENCY HARMONICS ANALYSIS
% Species: Plebeiogryllus guttiventris
% MATLAB R2025b
%
% PURPOSE
% 1. Detect syllables and group them into chirps.
% 2. Randomly sample up to N chirps per recording.
% 3. Select one syllable from each chirp.
% 4. Extract a 5 ms spectral window centred on its peak.
% 5. Calculate the FFT of the original audio.
% 6. Identify the fundamental frequency (H1).
% 7. Measure higher harmonics H2-H5.
% 8. Calculate amplitudes relative to the fundamental.
% 9. Exclude entire recordings if BOTH H2 and H3 are
%    below the adjustable minimum amplitude threshold
%    in at least one measured chirp.
% 10. Match recording temperatures using metadata.
% 11. Automatically export measurements and QC results.
%
% Requires Signal Processing Toolbox.
%% ============================================================

clearvars;
clc;
close all;


%% ============================================================
% 1. USER SETTINGS
%% ============================================================
% add path to folder below
% Folder containing the WAV recordings
audioFolder = ...
    

% Folder for exported CSV files
outputFolder = ...
    

% Recording temperatures come from the metadata spreadsheet.
% The sheet must contain columns named Audio and Temperature.
% Audio IDs can be written with or without the .wav extension.
%
% If the spreadsheet is not here, the script looks one or two
% folders above this folder, then asks you to select the file.

temperatureFile = fullfile(audioFolder, ...
    'recording_temperature_data.xlsx');


% ------------------------------------------------------------
% RANDOM SAMPLING
% ------------------------------------------------------------

% Maximum number of chirps sampled from each recording
maxChirpsPerRecording = 100;

% Random seed for reproducibility
randomSeed = 421;


% ------------------------------------------------------------
% OPTIONAL AUDIO FILTERING
% ------------------------------------------------------------

useFiltering = false;

lowFreq = 2000;
highFreq = 20000;


% ------------------------------------------------------------
% SYLLABLE DETECTION
% ------------------------------------------------------------

% Amplitude envelope smoothing
smoothing_ms = 5;

% Minimum separation between syllable peaks
minSyllableDistance_ms = 15;

% Minimum amplitude required to detect a syllable
minSyllableAmplitude = 0.040;

% Minimum prominence of a syllable peak
minSyllableProminence = 0.015;

% Minimum detected syllable duration
minSyllableDuration_ms = 5;

% Fraction of peak amplitude used to identify boundaries
boundaryFraction = 0.20;


% ------------------------------------------------------------
% CHIRP GROUPING
% ------------------------------------------------------------

% Maximum silence between syllables in one chirp
maxWithinChirpSilence_ms = 80;

% Minimum syllables per chirp
minSyllablesPerChirp = 1;

% Maximum syllables per chirp
maxSyllablesPerChirp = 20;


% ------------------------------------------------------------
% FREQUENCY ANALYSIS
% ------------------------------------------------------------

% Length of FFT spectral window
spectralWindow_ms = 5;

% Expected fundamental frequency range in Hz
fundamentalSearchHz = [3000 8000];

% Number of harmonics INCLUDING the fundamental
numberOfHarmonics = 5;

% Search range around predicted harmonic frequencies
harmonicSearchToleranceHz = 300;

% Zero-padding factor
zeroPaddingFactor = 8;


% ------------------------------------------------------------
% MINIMUM RELATIVE HARMONIC AMPLITUDE
% ------------------------------------------------------------

% Minimum harmonic amplitude compared with H1.
%
% Examples:
% 0.005 = 0.5% of fundamental amplitude
% 0.010 = 1.0% of fundamental amplitude
% 0.020 = 2.0% of fundamental amplitude
% 0.050 = 5.0% of fundamental amplitude
%
% This threshold uses AMPLITUDE, not frequency.

minRelativeHarmonicAmplitude = 0.01;


% ------------------------------------------------------------
% RECORDING EXCLUSION
% ------------------------------------------------------------

% If true:
% Exclude an ENTIRE recording when BOTH H2 and H3
% are below the minimum relative amplitude threshold
% in at least one measured chirp.
%
% If false:
% Keep all recordings regardless of harmonic amplitude.
%
% NaN values do not trigger exclusion.

excludeRecordingOnWeakH2H3 = true;


% ------------------------------------------------------------
% VISUAL QUALITY CONTROL
% ------------------------------------------------------------

% Show plots for individual spectral measurements
showPlots = true;

% Maximum number of plots displayed per recording
maxPlotsPerRecording = 5;


% ------------------------------------------------------------
% OUTPUT FILES
% ------------------------------------------------------------

individualOutputFile = fullfile( ...
    outputFolder, ...
    'Individual_Cricket_Harmonics.csv');

summaryOutputFile = fullfile( ...
    outputFolder, ...
    'Cricket_Harmonics_Recording_Summary.csv');

excludedOutputFile = fullfile( ...
    outputFolder, ...
    'Cricket_Harmonics_Excluded_WeakH2H3.csv');


%% ============================================================
% 2. VALIDATE USER SETTINGS
%% ============================================================

if ~isfolder(audioFolder)
    error('Audio folder does not exist: %s', audioFolder);
end

if ~isfolder(outputFolder)
    mkdir(outputFolder);
end

if numberOfHarmonics < 3 || ...
        numberOfHarmonics ~= floor(numberOfHarmonics)

    error('numberOfHarmonics must be an integer >= 3.');
end

if maxChirpsPerRecording < 1 || ...
        maxChirpsPerRecording ~= floor(maxChirpsPerRecording)

    error('maxChirpsPerRecording must be a positive integer.');
end

if spectralWindow_ms <= 0 || smoothing_ms <= 0
    error('Window and smoothing durations must be positive.');
end

if boundaryFraction <= 0 || boundaryFraction >= 1
    error('boundaryFraction must lie between 0 and 1.');
end

if fundamentalSearchHz(1) <= 0 || ...
        fundamentalSearchHz(2) <= fundamentalSearchHz(1)

    error('Invalid fundamental frequency interval.');
end

if zeroPaddingFactor < 1
    error('zeroPaddingFactor must be at least 1.');
end

if ~isscalar(minRelativeHarmonicAmplitude) || ...
        ~isfinite(minRelativeHarmonicAmplitude) || ...
        minRelativeHarmonicAmplitude < 0 || ...
        minRelativeHarmonicAmplitude > 1

    error(['minRelativeHarmonicAmplitude must be ' ...
           'between 0 and 1.']);
end

fprintf('\n============================================\n');
fprintf('CRICKET HARMONIC ANALYSIS\n');
fprintf('============================================\n');

fprintf('Minimum relative amplitude: %.2f%%\n', ...
    100*minRelativeHarmonicAmplitude);

fprintf('Recording exclusion enabled: %d\n', ...
    excludeRecordingOnWeakH2H3);


%% ============================================================
% 3. FIND WAV RECORDINGS
%% ============================================================

wavFiles = [ ...
    dir(fullfile(audioFolder, '*.wav')); ...
    dir(fullfile(audioFolder, '*.WAV'))];

if isempty(wavFiles)
    error('No WAV files found in %s', audioFolder);
end

[~, uniqueIdx] = unique( ...
    {wavFiles.name}, 'stable');

wavFiles = wavFiles(uniqueIdx);

nFiles = numel(wavFiles);

fprintf('\nFound %d WAV recordings.\n', nFiles);


%% ============================================================
% 3A. READ AND MATCH RECORDING TEMPERATURES
%% ============================================================

% Locate the temperature spreadsheet.
% If the file is stored elsewhere, use the file selector
% instead of guessing temperatures.

if ~isfile(temperatureFile)

    [parentFolder,~,~] = fileparts(audioFolder);
    [grandparentFolder,~,~] = fileparts(parentFolder);

    candidateFiles = { ...
        fullfile(parentFolder, ...
            'recording_temperature_data.xlsx'), ...
        fullfile(grandparentFolder, ...
            'recording_temperature_data.xlsx')};

    foundFile = '';

    for k = 1:numel(candidateFiles)

        if isfile(candidateFiles{k})
            foundFile = candidateFiles{k};
            break;
        end

    end

    if ~isempty(foundFile)

        temperatureFile = foundFile;

    else

        [selectedName,selectedFolder] = uigetfile( ...
            {'*.xlsx;*.xls;*.csv', ...
            'Temperature files (*.xlsx, *.xls, *.csv)'}, ...
            'Select recording_temperature_data.xlsx');

        if isequal(selectedName,0)
            error(['No temperature metadata file selected; ' ...
                   'analysis stopped.']);
        end

        temperatureFile = fullfile( ...
            selectedFolder,selectedName);

    end
end

fprintf('Reading temperature metadata: %s\n', ...
    temperatureFile);

temperatureTable = readtable(temperatureFile, ...
    'TextType','string', ...
    'VariableNamingRule','preserve');


% ------------------------------------------------------------
% FIND CORRECT COLUMNS
% ------------------------------------------------------------

% Accept capitalization differences in metadata headers.

columnNames = string( ...
    temperatureTable.Properties.VariableNames);

audioColumn = find( ...
    strcmpi(strtrim(columnNames),'Audio'),1);

temperatureColumn = find( ...
    strcmpi(strtrim(columnNames),'Temperature'),1);

if isempty(audioColumn) || isempty(temperatureColumn)

    error(['Temperature file must contain columns named Audio ' ...
           'and Temperature. Found: %s'], ...
           strjoin(columnNames,', '));

end


% ------------------------------------------------------------
% NORMALIZE RECORDING IDS
% ------------------------------------------------------------

% APP_1.wav and APP_1 match.
% APP_1 and APP_2 never match.

metadataIDs = lower(strtrim(regexprep( ...
    string(temperatureTable{:,audioColumn}), ...
    '(?i)\.wav$','')));

rawTemperatures = temperatureTable{:,temperatureColumn};

if isnumeric(rawTemperatures)

    metadataTemperatures = double(rawTemperatures);

else

    % Supports decimal commas such as 30,5.

    metadataTemperatures = str2double( ...
        replace(strtrim(string(rawTemperatures)),',','.'));

end

metadataTemperatures = metadataTemperatures(:);
metadataIDs = metadataIDs(:);


% ------------------------------------------------------------
% MATCH EACH WAV FILE TO ITS TEMPERATURE
% ------------------------------------------------------------

recordingTemperatures = nan(nFiles,1);

temperatureMatchStatus = strings(nFiles,1);

for k = 1:nFiles

    [~,recordingID,~] = fileparts(wavFiles(k).name);

    recordingID = lower(strtrim(string(recordingID)));

    matches = find(metadataIDs == recordingID);

    if isempty(matches)

        temperatureMatchStatus(k) = "NoMatchingID";
        continue;

    end

    validTemperatures = unique( ...
        metadataTemperatures(matches( ...
            isfinite(metadataTemperatures(matches)))));

    if isempty(validTemperatures)

        temperatureMatchStatus(k) = ...
            "MissingOrInvalidTemperature";

    elseif numel(validTemperatures) > 1

        temperatureMatchStatus(k) = ...
            "ConflictingTemperatures";

    else

        recordingTemperatures(k) = validTemperatures(1);

        if numel(matches) > 1

            temperatureMatchStatus(k) = ...
                "MatchedDuplicateSameValue";

        else

            temperatureMatchStatus(k) = "Matched";

        end

    end
end


% ------------------------------------------------------------
% PRINT TEMPERATURE MATCHING RESULTS
% ------------------------------------------------------------

fprintf('Temperatures matched: %d/%d recordings.\n', ...
    sum(isfinite(recordingTemperatures)),nFiles);

unmatchedIdx = find(~isfinite(recordingTemperatures));

if ~isempty(unmatchedIdx)

    warning(['%d recording(s) have no unambiguous temperature. ' ...
        'Their temperature is NaN in the exports. ' ...
        'Review TemperatureMatchStatus in the summary CSV.'], ...
        numel(unmatchedIdx));

    for k = unmatchedIdx(:)'

        fprintf('  TEMPERATURE NOT MATCHED: %s (%s)\n', ...
            wavFiles(k).name,temperatureMatchStatus(k));

    end
end

rng(randomSeed, 'twister');


%% ============================================================
% 4. INITIALISE RESULT STORAGE
%% ============================================================

baseVariableNames = { ...
    'File', ...
    'RecordingTemperature_C', ...
    'RecordingDuration_seconds', ...
    'ChirpNumber', ...
    'SyllablesInChirp', ...
    'SelectedSyllableNumber', ...
    'SyllablePeakTime_seconds', ...
    'SpectralWindowStart_seconds', ...
    'SpectralWindowEnd_seconds', ...
    'FundamentalFrequency_Hz'};


% Create harmonic column names dynamically.

harmonicVariableNames = cell( ...
    1, 4*numberOfHarmonics);

for h = 1:numberOfHarmonics

    k = 4*(h-1);

    harmonicVariableNames{k+1} = ...
        sprintf('H%d_Frequency_Hz', h);

    harmonicVariableNames{k+2} = ...
        sprintf('H%d_Amplitude', h);

    harmonicVariableNames{k+3} = ...
        sprintf('H%d_RelativeAmplitude', h);

    harmonicVariableNames{k+4} = ...
        sprintf('H%d_RelativeAmplitude_dB', h);

end

allVariableNames = [ ...
    baseVariableNames, harmonicVariableNames];

nNumericCols = numel(allVariableNames)-1;


% ------------------------------------------------------------
% INDIVIDUAL MEASUREMENT STORAGE
% ------------------------------------------------------------

allFiles = strings(0,1);

allNumericResults = zeros(0,nNumericCols);


% ------------------------------------------------------------
% RECORDING SUMMARY STORAGE
% ------------------------------------------------------------

summaryFile = strings(nFiles,1);

summaryTemperature = recordingTemperatures;

summaryTemperatureMatch = temperatureMatchStatus;

summaryDuration = nan(nFiles,1);

summarySyllables = zeros(nFiles,1);

summaryChirps = zeros(nFiles,1);

summarySampled = zeros(nFiles,1);

summaryMeasured = zeros(nFiles,1);

summaryRejectedShort = zeros(nFiles,1);

summaryRejectedFundamental = zeros(nFiles,1);

summaryExcluded = false(nFiles,1);

summaryStatus = strings(nFiles,1);


% ------------------------------------------------------------
% WEAK HARMONIC RECORDING STORAGE
% ------------------------------------------------------------

excludedFiles = strings(0,1);

excludedTemperatures = zeros(0,1);

excludedChirps = zeros(0,1);

excludedH2Values = zeros(0,1);

excludedH3Values = zeros(0,1);


%% ============================================================
% 5. PROCESS EACH RECORDING
%% ============================================================

for fileIdx = 1:nFiles

    fileName = wavFiles(fileIdx).name;

    recordingTemperature_C = ...
        recordingTemperatures(fileIdx);

    filePath = fullfile(audioFolder, fileName);

    summaryFile(fileIdx) = string(fileName);

    summaryStatus(fileIdx) = "ReadError";

    fprintf('\n[%d/%d] Processing: %s\n', ...
        fileIdx, nFiles, fileName);


    %% --------------------------------------------------------
    % 5A. LOAD ORIGINAL AUDIO
    %% --------------------------------------------------------

    try

        [audio, Fs] = audioread(filePath);

    catch ME

        warning('Cannot read %s: %s', ...
            fileName, ME.message);

        continue;

    end

    if isempty(audio) || ...
            ~isfinite(Fs) || Fs <= 0

        summaryStatus(fileIdx) = "InvalidAudio";

        warning('Invalid audio in %s', fileName);

        continue;

    end


    % Convert stereo to mono.

    if size(audio,2) > 1

        audio = mean(audio,2);

    end

    audio = double(audio(:));

    nSamples = numel(audio);

    duration_seconds = nSamples/Fs;

    summaryDuration(fileIdx) = duration_seconds;


    %% --------------------------------------------------------
    % 5B. OPTIONAL FILTERING
    %% --------------------------------------------------------

    detectionSignal = audio;

    if useFiltering

        if highFreq >= Fs/2 || ...
                lowFreq <= 0 || lowFreq >= highFreq

            warning( ...
                'Invalid filter limits for %s. No filter used.', ...
                fileName);

        else

            [b,a] = butter(4, ...
                [lowFreq highFreq]/(Fs/2), ...
                'bandpass');

            detectionSignal = filtfilt(b,a,audio);

        end

    end


    %% --------------------------------------------------------
    % 5C. AMPLITUDE ENVELOPE
    %% --------------------------------------------------------

    envelope = abs(hilbert(detectionSignal));

    smoothSamples = max(1, ...
        round(smoothing_ms*Fs/1000));

    envelope = movmean(envelope, smoothSamples);


    %% --------------------------------------------------------
    % 5D. DETECT SYLLABLE PEAKS
    %% --------------------------------------------------------

    minDistance = max(1, ...
        round(minSyllableDistance_ms*Fs/1000));

    [peakAmplitudes, peakLocations] = findpeaks( ...
        envelope, ...
        'MinPeakHeight', minSyllableAmplitude, ...
        'MinPeakProminence', minSyllableProminence, ...
        'MinPeakDistance', minDistance);

    peakAmplitudes = peakAmplitudes(:);

    peakLocations = peakLocations(:);

    nCandidates = numel(peakLocations);


    %% --------------------------------------------------------
    % 5E. ESTIMATE SYLLABLE BOUNDARIES
    %% --------------------------------------------------------

    startSamples = zeros(nCandidates,1);

    endSamples = zeros(nCandidates,1);

    for s = 1:nCandidates

        threshold = ...
            boundaryFraction*peakAmplitudes(s);

        leftIdx = peakLocations(s);

        while leftIdx > 1 && ...
                envelope(leftIdx) > threshold

            leftIdx = leftIdx-1;

        end

        rightIdx = peakLocations(s);

        while rightIdx < nSamples && ...
                envelope(rightIdx) > threshold

            rightIdx = rightIdx+1;

        end

        startSamples(s) = leftIdx;

        endSamples(s) = rightIdx;

    end


    % Prevent neighbouring syllable boundaries from overlapping.

    for s = 1:(nCandidates-1)

        midpoint = floor( ...
            (peakLocations(s)+peakLocations(s+1))/2);

        endSamples(s) = min( ...
            endSamples(s), midpoint);

        startSamples(s+1) = max( ...
            startSamples(s+1), midpoint);

    end


    %% --------------------------------------------------------
    % 5E-2. REJECT VERY SHORT SYLLABLES
    %% --------------------------------------------------------

    syllableDuration_ms = ...
        (endSamples-startSamples)/Fs*1000;

    validSyllables = ...
        syllableDuration_ms >= minSyllableDuration_ms & ...
        endSamples > startSamples;

    peakLocations = ...
        peakLocations(validSyllables);

    peakAmplitudes = ...
        peakAmplitudes(validSyllables);

    startSamples = ...
        startSamples(validSyllables);

    endSamples = ...
        endSamples(validSyllables);

    nSyllables = numel(peakLocations);

    summarySyllables(fileIdx) = nSyllables;


    %% --------------------------------------------------------
    % 5F. GROUP SYLLABLES INTO CHIRPS
    %% --------------------------------------------------------

    groupFirst = zeros(0,1);

    groupLast = zeros(0,1);

    if nSyllables > 0

        firstSyllable = 1;

        nInGroup = 1;

        for s = 2:nSyllables

            silence_ms = max(0, ...
                (startSamples(s)-endSamples(s-1))/Fs*1000);

            newGroup = ...
                silence_ms > maxWithinChirpSilence_ms || ...
                nInGroup >= maxSyllablesPerChirp;

            if newGroup

                groupFirst(end+1,1) = firstSyllable;

                groupLast(end+1,1) = s-1;

                firstSyllable = s;

                nInGroup = 1;

            else

                nInGroup = nInGroup+1;

            end

        end

        groupFirst(end+1,1) = firstSyllable;

        groupLast(end+1,1) = nSyllables;

    end


    groupLengths = groupLast-groupFirst+1;

    keepGroups = ...
        groupLengths >= minSyllablesPerChirp & ...
        groupLengths <= maxSyllablesPerChirp;

    chirpFirst = groupFirst(keepGroups);

    chirpLast = groupLast(keepGroups);

    nChirps = numel(chirpFirst);

    summaryChirps(fileIdx) = nChirps;


    %% --------------------------------------------------------
    % 5G. RANDOMLY SAMPLE CHIRPS
    %% --------------------------------------------------------

    nSampled = min( ...
        nChirps, maxChirpsPerRecording);

    summarySampled(fileIdx) = nSampled;

    if nSampled > 0

        sampledChirps = sort( ...
            randperm(nChirps,nSampled));

    else

        sampledChirps = [];

    end


    %% --------------------------------------------------------
    % 5H. PREPARE RECORDING STORAGE
    %% --------------------------------------------------------

    % Measurements are stored temporarily.
    % They are not exported until recording exclusion
    % has been checked.

    fileNumericRows = zeros(0,nNumericCols);

    fileWeakChirps = zeros(0,1);

    fileWeakH2 = zeros(0,1);

    fileWeakH3 = zeros(0,1);

    nRejectedShort = 0;

    nRejectedFundamental = 0;

    nPlotsShown = 0;


    %% --------------------------------------------------------
    % 5I. ANALYSE SAMPLED CHIRPS
    %% --------------------------------------------------------

    for sampledIdx = 1:numel(sampledChirps)

        chirpNumber = sampledChirps(sampledIdx);

        syllableIndices = ( ...
            chirpFirst(chirpNumber):chirpLast(chirpNumber))';

        nSyllablesInChirp = numel(syllableIndices);


        % -----------------------------------------------------
        % SELECT SYLLABLE
        % -----------------------------------------------------

        if nSyllablesInChirp >= 3

            % Second-to-last syllable
            localSyllableIdx = nSyllablesInChirp-1;

        elseif nSyllablesInChirp == 2

            % Strongest of the two syllables
            [~,localSyllableIdx] = max( ...
                peakAmplitudes(syllableIndices));

        else

            localSyllableIdx = 1;

        end

        targetIdx = syllableIndices(localSyllableIdx);

        peakSample = peakLocations(targetIdx);

        peakTime = (peakSample-1)/Fs;


        % -----------------------------------------------------
        % EXTRACT 5 MS SPECTRAL WINDOW
        % -----------------------------------------------------

        windowSamples = max(3, ...
            round(spectralWindow_ms*Fs/1000));

        leftHalf = floor((windowSamples-1)/2);

        rightHalf = windowSamples-1-leftHalf;

        lo = peakSample-leftHalf;

        hi = peakSample+rightHalf;


        % Reject windows extending beyond the syllable.

        if lo < 1 || hi > nSamples || ...
                lo < startSamples(targetIdx) || ...
                hi > endSamples(targetIdx)

            nRejectedShort = nRejectedShort+1;

            continue;

        end

        windowStartTime = (lo-1)/Fs;

        windowEndTime = (hi-1)/Fs;


        % -----------------------------------------------------
        % PREPARE ORIGINAL AUDIO FOR FFT
        % -----------------------------------------------------

        % Use original waveform, not the amplitude envelope.

        slice = audio(lo:hi);

        slice = slice(:)-mean(slice);

        N = numel(slice);

        weights = hann(N,'periodic');

        windowedSlice = slice.*weights;

        nFFT = 2^nextpow2( ...
            max(N,zeroPaddingFactor*N));

        X = fft(windowedSlice,nFFT);


        % -----------------------------------------------------
        % FREQUENCY AXIS
        % -----------------------------------------------------

        positiveBins = ...
            (1:(floor(nFFT/2)+1))';

        frequencies = ...
            (positiveBins-1)*Fs/nFFT;


        % -----------------------------------------------------
        % ONE-SIDED AMPLITUDE SPECTRUM
        % -----------------------------------------------------

        amplitudes = ...
            abs(X(positiveBins))/sum(weights);

        if rem(nFFT,2) == 0

            doubledBins = 2:(numel(amplitudes)-1);

        else

            doubledBins = 2:numel(amplitudes);

        end

        amplitudes(doubledBins) = ...
            2*amplitudes(doubledBins);


        % -----------------------------------------------------
        % FIND FUNDAMENTAL FREQUENCY
        % -----------------------------------------------------

        f0mask = ...
            frequencies >= fundamentalSearchHz(1) & ...
            frequencies <= fundamentalSearchHz(2);

        if ~any(f0mask)

            nRejectedFundamental = ...
                nRejectedFundamental+1;

            continue;

        end

        fSearch = frequencies(f0mask);

        aSearch = amplitudes(f0mask);

        [fundamentalAmplitude,idxF0] = max(aSearch);

        fundamentalFrequency = fSearch(idxF0);

        if ~isfinite(fundamentalAmplitude) || ...
                fundamentalAmplitude <= 0

            nRejectedFundamental = ...
                nRejectedFundamental+1;

            continue;

        end


        % -----------------------------------------------------
        % MEASURE HARMONICS
        % -----------------------------------------------------

        harmFreq = nan(1,numberOfHarmonics);

        harmAmp = nan(1,numberOfHarmonics);

        relAmp = nan(1,numberOfHarmonics);

        relDB = nan(1,numberOfHarmonics);


        % H1: Fundamental

        harmFreq(1) = fundamentalFrequency;

        harmAmp(1) = fundamentalAmplitude;

        relAmp(1) = 1;

        relDB(1) = 0;


        % H2 and higher

        for h = 2:numberOfHarmonics

            expectedHz = h*fundamentalFrequency;


            % Frequencies above Nyquist cannot be measured.

            if expectedHz >= Fs/2
                continue;
            end

            mask = ...
                abs(frequencies-expectedHz) <= ...
                harmonicSearchToleranceHz;

            if ~any(mask)
                continue;
            end

            localHz = frequencies(mask);

            localAmp = amplitudes(mask);

            [harmAmp(h),peakIdx] = max(localAmp);

            harmFreq(h) = localHz(peakIdx);


            % Amplitude relative to fundamental.

            relAmp(h) = ...
                harmAmp(h)/fundamentalAmplitude;


            % Relative amplitude in decibels.

            if relAmp(h) > 0

                relDB(h) = ...
                    20*log10(relAmp(h));

            end

        end


        %% ----------------------------------------------------
        % CHECK MINIMUM HARMONIC AMPLITUDE
        %% ----------------------------------------------------

        % H2 and H3 are expressed relative to H1.
        %
        % Example:
        % H2 = 0.005 means H2 is 0.5% of H1.
        % H3 = 0.008 means H3 is 0.8% of H1.
        %
        % With a minimum of 0.01, both are too weak.
        %
        % If BOTH are below the cutoff, flag the recording.
        %
        % NaN values do not trigger this rule.

        weakH2 = ...
            isfinite(relAmp(2)) && ...
            relAmp(2) >= 0 && ...
            relAmp(2) < minRelativeHarmonicAmplitude;

        weakH3 = ...
            isfinite(relAmp(3)) && ...
            relAmp(3) >= 0 && ...
            relAmp(3) < minRelativeHarmonicAmplitude;


        if excludeRecordingOnWeakH2H3 && ...
                weakH2 && weakH3

            fileWeakChirps(end+1,1) = chirpNumber;

            fileWeakH2(end+1,1) = relAmp(2);

            fileWeakH3(end+1,1) = relAmp(3);

        end


        %% ----------------------------------------------------
        % BUILD OUTPUT ROW
        %% ----------------------------------------------------

        % Include recording temperature in every measurement.

        numericRow = [ ...
            recordingTemperature_C, ...
            duration_seconds, ...
            chirpNumber, ...
            nSyllablesInChirp, ...
            localSyllableIdx, ...
            peakTime, ...
            windowStartTime, ...
            windowEndTime, ...
            fundamentalFrequency];


        for h = 1:numberOfHarmonics

            numericRow = [ ...
                numericRow, ...
                harmFreq(h), ...
                harmAmp(h), ...
                relAmp(h), ...
                relDB(h)];

        end

        fileNumericRows(end+1,:) = numericRow;


        %% ----------------------------------------------------
        % VISUAL QUALITY CONTROL
        %% ----------------------------------------------------

        if showPlots && ...
                nPlotsShown < maxPlotsPerRecording

            nPlotsShown = nPlotsShown+1;

            figure( ...
                'Name',sprintf( ...
                '%s - Chirp %d',fileName,chirpNumber), ...
                'NumberTitle','off', ...
                'Color','w');

            tiledlayout(2,1);


            % TOP: WAVEFORM

            nexttile;

            contextStart = max(1, ...
                peakSample-round(0.05*Fs));

            contextEnd = min(nSamples, ...
                peakSample+round(0.05*Fs));

            indices = contextStart:contextEnd;

            plot( ...
                (indices-1)/Fs, ...
                audio(indices), ...
                'Color',[0.4 0.4 0.4]);

            hold on;

            xline(windowStartTime,'b--');

            xline(windowEndTime,'b--');

            xline(peakTime,'r--');

            xlabel('Time (s)');

            ylabel('Waveform amplitude');

            title(sprintf( ...
                'Chirp %d, syllable %d of %d, %.1f ms FFT', ...
                chirpNumber, ...
                localSyllableIdx, ...
                nSyllablesInChirp, ...
                spectralWindow_ms));

            grid on;

            hold off;


            % BOTTOM: FREQUENCY SPECTRUM

            nexttile;

            plot(frequencies,amplitudes,'g');

            hold on;

            for h = 1:numberOfHarmonics

                if isfinite(harmFreq(h))

                    plot( ...
                        harmFreq(h), ...
                        harmAmp(h), ...
                        'ro', ...
                        'MarkerFaceColor','r');

                    text( ...
                        harmFreq(h), ...
                        harmAmp(h), ...
                        sprintf(' H%d',h), ...
                        'VerticalAlignment','bottom');

                end

            end

            xlim([0 Fs/2]);

            xlabel('Frequency (Hz)');

            ylabel('Spectral amplitude');

            title(sprintf( ...
                'Fundamental: %.1f Hz', ...
                fundamentalFrequency));

            grid on;

            hold off;

            drawnow;

        end

    end


    %% --------------------------------------------------------
    % 5J. APPLY RECORDING-LEVEL EXCLUSION
    %% --------------------------------------------------------

    summaryRejectedShort(fileIdx) = nRejectedShort;

    summaryRejectedFundamental(fileIdx) = ...
        nRejectedFundamental;

    summaryMeasured(fileIdx) = ...
        size(fileNumericRows,1);


    % Check whether any sampled chirp triggered exclusion.

    if ~isempty(fileWeakChirps)

        summaryExcluded(fileIdx) = true;

        summaryStatus(fileIdx) = "ExcludedWeakH2H3";


        % Record first chirp that triggered exclusion.

        excludedFiles(end+1,1) = string(fileName);

        excludedTemperatures(end+1,1) = ...
            recordingTemperature_C;

        excludedChirps(end+1,1) = fileWeakChirps(1);

        excludedH2Values(end+1,1) = fileWeakH2(1);

        excludedH3Values(end+1,1) = fileWeakH3(1);


        fprintf('\n');

        fprintf('  EXCLUDED ENTIRE RECORDING\n');

        fprintf('  Both H2 and H3 below %.2f%% of H1.\n', ...
            100*minRelativeHarmonicAmplitude);

        fprintf('  Triggering chirp: %d\n', ...
            fileWeakChirps(1));

        fprintf('  H2/H1: %.6f\n',fileWeakH2(1));

        fprintf('  H3/H1: %.6f\n',fileWeakH3(1));

    else

        summaryStatus(fileIdx) = "Included";


        % Only add the recording if it passed QC.

        if ~isempty(fileNumericRows)

            allNumericResults = [ ...
                allNumericResults; ...
                fileNumericRows];

            allFiles = [ ...
                allFiles; ...
                repmat( ...
                string(fileName), ...
                size(fileNumericRows,1),1)];

        end

    end


    %% --------------------------------------------------------
    % 5K. PRINT RECORDING SUMMARY
    %% --------------------------------------------------------

    fprintf('  Syllables detected: %d\n',nSyllables);

    fprintf('  Chirps detected: %d\n',nChirps);

    fprintf('  Chirps sampled: %d\n',nSampled);

    fprintf('  Successful measurements: %d\n', ...
        size(fileNumericRows,1));

    fprintf('  Rejected short windows: %d\n', ...
        nRejectedShort);

    fprintf('  Fundamental detection failures: %d\n', ...
        nRejectedFundamental);

end


%% ============================================================
% 6. BUILD INDIVIDUAL RESULTS TABLE
%% ============================================================

if isempty(allNumericResults)

    harmonicResults = table( ...
        'Size',[0,numel(allVariableNames)], ...
        'VariableTypes', ...
        [{'string'}, ...
        repmat({'double'},1,nNumericCols)], ...
        'VariableNames',allVariableNames);

else

    harmonicResults = array2table( ...
        allNumericResults, ...
        'VariableNames',allVariableNames(2:end));

    harmonicResults = addvars( ...
        harmonicResults, ...
        allFiles, ...
        'Before',1, ...
        'NewVariableNames','File');

end


%% ============================================================
% 7. BUILD RECORDING SUMMARY TABLE
%% ============================================================

recordingSummary = table( ...
    summaryFile, ...
    summaryTemperature, ...
    summaryTemperatureMatch, ...
    summaryDuration, ...
    summarySyllables, ...
    summaryChirps, ...
    summarySampled, ...
    summaryMeasured, ...
    summaryRejectedShort, ...
    summaryRejectedFundamental, ...
    summaryExcluded, ...
    summaryStatus, ...
    'VariableNames',{ ...
    'File', ...
    'RecordingTemperature_C', ...
    'TemperatureMatchStatus', ...
    'Duration_seconds', ...
    'DetectedSyllables', ...
    'DetectedChirps', ...
    'SampledChirps', ...
    'SuccessfulMeasurementsBeforeExclusion', ...
    'RejectedShortWindows', ...
    'RejectedFundamentalDetection', ...
    'ExcludedWeakH2H3', ...
    'Status'});


%% ============================================================
% 8. BUILD EXCLUDED RECORDINGS TABLE
%% ============================================================

excludedRecordings = table( ...
    excludedFiles, ...
    excludedTemperatures, ...
    excludedChirps, ...
    excludedH2Values, ...
    excludedH3Values, ...
    'VariableNames',{ ...
    'File', ...
    'RecordingTemperature_C', ...
    'FirstChirpTriggeringExclusion', ...
    'H2_RelativeAmplitude', ...
    'H3_RelativeAmplitude'});


%% ============================================================
% 9. AUTOMATICALLY SAVE CSV FILES
%% ============================================================

writetable( ...
    harmonicResults, ...
    individualOutputFile);

writetable( ...
    recordingSummary, ...
    summaryOutputFile);

writetable( ...
    excludedRecordings, ...
    excludedOutputFile);


%% ============================================================
% 10. FINAL SUMMARY
%% ============================================================

fprintf('\n============================================\n');
fprintf('HARMONIC ANALYSIS COMPLETE\n');
fprintf('============================================\n');

fprintf('WAV recordings found: %d\n',nFiles);

fprintf('Recordings with matched temperatures: %d\n', ...
    sum(isfinite(recordingTemperatures)));

fprintf('Recordings with missing/conflicting temperatures: %d\n', ...
    sum(~isfinite(recordingTemperatures)));

fprintf('Recordings excluded: %d\n', ...
    height(excludedRecordings));

fprintf('Recordings retained: %d\n', ...
    sum(summaryStatus == "Included"));

fprintf('Individual harmonic measurements saved: %d\n', ...
    height(harmonicResults));

fprintf('Minimum harmonic amplitude: %.2f%% of H1\n', ...
    100*minRelativeHarmonicAmplitude);


fprintf('\nIndividual results:\n%s\n', ...
    individualOutputFile);

fprintf('\nRecording summary:\n%s\n', ...
    summaryOutputFile);

fprintf('\nExcluded recordings:\n%s\n', ...
    excludedOutputFile);


% Preview individual harmonic results.

if height(harmonicResults) > 0

    fprintf('\nIndividual measurement preview:\n');

    disp(harmonicResults( ...
        1:min(5,height(harmonicResults)),:));

end


% Preview excluded recordings.

if height(excludedRecordings) > 0

    fprintf('\nExcluded recordings:\n');

    disp(excludedRecordings);

end

fprintf('\nDone.\n');
