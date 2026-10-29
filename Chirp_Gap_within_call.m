%% ============================================================
%  CRICKET CHIRP GAP ANALYSIS - CORRECTED
%
%  Project: Plebeiogryllus guttiventris bioacoustics
%  MATLAB: R2025b
%
%  PURPOSE
%  1. Load WAV recordings.
%  2. Detect individual syllables.
%  3. Group syllables into complete chirps.
%  4. Measure gaps BETWEEN chirps, not between syllables.
%  5. Exclude gaps >= 1 second.
%  6. Randomly select up to 50 qualifying gaps per recording.
%  7. Display selected and excluded gaps visually.
%  8. Export individual gaps and recording summaries.
%
%  PLOT COLOURS
%  Blue  = selected and exported gap
%  Green = qualifying gap, not selected
%  Red   = excluded long pause
%
%  IMPORTANT
%  maxWithinChirpSilence_ms is a grouping parameter.
%  Check visually whether it correctly separates chirps.
%% ============================================================

clearvars;
clc;
close all;

%% 1. USER SETTINGS
% ADD PATH TO FOLDER, OUTPUT TOO
audioFolder = ...
    



% Maximum number of gaps exported per recording
maxGapsPerRecording = 50;

% Reproducible random selection
randomSeed = 421;

% Show quality-control plots
showPlots = true;

% Maximum waveform points displayed (plot only)
maxPlotPoints = 30000;

% Optional filtering
useFiltering = false;

lowFreq = 2000;
highFreq = 20000;

% Syllable detection
smoothing_ms = 5;
minSyllableDistance_ms = 15;
minSyllableAmplitude = 0.04;

% NEW: maximum silence BETWEEN syllables in one chirp
maxWithinChirpSilence_ms = 80;

% Minimum syllables required for a valid chirp
% Set to 1 if genuine single-syllable chirps should be retained
minSyllablesPerChirp = 1;

% Maximum syllables permitted per chirp
maxSyllablesPerChirp = 20;

% Syllable start/end detection
boundaryFraction = 0.20;

% Maximum permitted inter-chirp gap
% Gaps >= this value are excluded
maxWithinCallGap_seconds = 1.0;

% Output folder
outputFolder = 
    

gapOutputFile = fullfile(outputFolder, ...
    'Individual_Chirp_Gaps_WithinCalls.csv');

summaryOutputFile = fullfile(outputFolder, ...
    'Chirp_Gap_Recording_Summary_WithinCalls.csv');

%% 2. VALIDATE SETTINGS

if ~isfolder(audioFolder)
    error('Audio folder does not exist: %s', audioFolder);
end

if maxGapsPerRecording < 1 || ...
        maxGapsPerRecording ~= floor(maxGapsPerRecording)
    error('maxGapsPerRecording must be a positive integer.');
end

if boundaryFraction <= 0 || boundaryFraction >= 1
    error('boundaryFraction must be between 0 and 1.');
end

if maxWithinChirpSilence_ms < 0
    error('maxWithinChirpSilence_ms cannot be negative.');
end

if minSyllablesPerChirp < 1 || ...
        maxSyllablesPerChirp < minSyllablesPerChirp
    error('Invalid minimum or maximum syllables per chirp.');
end

if useFiltering && lowFreq >= highFreq
    error('lowFreq must be lower than highFreq.');
end

if ~isfolder(outputFolder)
    mkdir(outputFolder);
end

%% 3. FIND WAV FILES

wavFiles = dir(fullfile(audioFolder, '*.wav'));
wavFilesUpper = dir(fullfile(audioFolder, '*.WAV'));

wavFiles = [wavFiles; wavFilesUpper];

if isempty(wavFiles)
    error('No WAV files found.');
end

[~, uniqueIdx] = unique({wavFiles.name}, 'stable');
wavFiles = wavFiles(uniqueIdx);

fprintf('Found %d WAV recordings.\n', numel(wavFiles));

rng(randomSeed, 'twister');

%% 4. INITIALISE RESULTS TABLES

gapVariableNames = { ...
    'File', ...
    'RecordingDuration_seconds', ...
    'GapNumberWithinExport', ...
    'GapNumberInFullRecording', ...
    'PreviousChirpNumber', ...
    'NextChirpNumber', ...
    'PreviousChirpEnd_seconds', ...
    'NextChirpStart_seconds', ...
    'ChirpGap_seconds', ...
    'ChirpGap_milliseconds'};

gapResults = table( ...
    strings(0,1), ...
    zeros(0,1), zeros(0,1), zeros(0,1), ...
    zeros(0,1), zeros(0,1), zeros(0,1), ...
    zeros(0,1), zeros(0,1), zeros(0,1), ...
    'VariableNames', gapVariableNames);

summaryVariableNames = { ...
    'File', ...
    'Duration_seconds', ...
    'DetectedSyllables', ...
    'DetectedChirps', ...
    'RejectedSyllableGroups', ...
    'CandidateGaps', ...
    'ExcludedLongPauseGaps', ...
    'AvailableWithinCallGaps', ...
    'ExportedGaps', ...
    'NegativeOrInvalidGaps'};

recordingSummary = table( ...
    strings(0,1), ...
    zeros(0,1), zeros(0,1), zeros(0,1), ...
    zeros(0,1), zeros(0,1), zeros(0,1), ...
    zeros(0,1), zeros(0,1), zeros(0,1), ...
    'VariableNames', summaryVariableNames);

%% 5. PROCESS EACH RECORDING

for fileIdx = 1:numel(wavFiles)

    fileName = wavFiles(fileIdx).name;
    filePath = fullfile(audioFolder, fileName);

    fprintf('\n[%d/%d] Processing: %s\n', ...
        fileIdx, numel(wavFiles), fileName);

    %% 5A. LOAD AUDIO

    try
        [audio, Fs] = audioread(filePath);
    catch ME
        warning('Could not read %s: %s', ...
            fileName, ME.message);
        continue;
    end

    if isempty(audio) || Fs <= 0
        warning('Invalid recording skipped: %s', fileName);
        continue;
    end

    if size(audio,2) > 1
        audio = mean(audio, 2);
    end

    audio = double(audio(:));

    nSamples = numel(audio);
    duration_seconds = nSamples / Fs;

    %% 5B. OPTIONAL FILTERING

    signalForDetection = audio;

    if useFiltering

        if highFreq >= Fs/2

            warning(['Filtering skipped for %s: ' ...
                'highFreq exceeds Nyquist frequency.'], ...
                fileName);

        else

            [b,a] = butter(4, ...
                [lowFreq highFreq]/(Fs/2), ...
                'bandpass');

            signalForDetection = filtfilt(b,a,audio);

        end
    end

    %% 5C. CALCULATE AMPLITUDE ENVELOPE

    amplitudeEnvelope = abs(hilbert(signalForDetection));

    smoothingSamples = max(1, ...
        round(smoothing_ms * Fs / 1000));

    amplitudeEnvelope = movmean( ...
        amplitudeEnvelope, smoothingSamples);

    %% 5D. DETECT SYLLABLE PEAKS

    minPeakDistanceSamples = max(1, ...
        round(minSyllableDistance_ms * Fs / 1000));

    [peakAmplitudes, peakLocations] = findpeaks( ...
        amplitudeEnvelope, ...
        'MinPeakHeight', minSyllableAmplitude, ...
        'MinPeakDistance', minPeakDistanceSamples);

    peakLocations = peakLocations(:);
    peakAmplitudes = peakAmplitudes(:);

    nSyllables = numel(peakLocations);

    peakTimes = (peakLocations - 1) / Fs;

    fprintf('  Detected syllables: %d\n', nSyllables);

    %% 5E. HANDLE RECORDINGS WITHOUT SYLLABLES

    if nSyllables == 0

        warning('No syllables detected in %s.', fileName);

        summaryRow = table( ...
            string(fileName), duration_seconds, ...
            0, 0, 0, 0, 0, 0, 0, 0, ...
            'VariableNames', summaryVariableNames);

        recordingSummary = [recordingSummary; summaryRow];

        continue;
    end

    %% 5F. ESTIMATE SYLLABLE START AND END TIMES
    %
    % Each syllable is defined by its peak and a relative
    % amplitude threshold.
    %
    % A syllable begins where the envelope rises above
    % boundaryFraction * peak amplitude.
    %
    % It ends where the envelope falls below that threshold.

    syllableStarts = zeros(nSyllables,1);
    syllableEnds = zeros(nSyllables,1);

    for s = 1:nSyllables

        peakIdx = peakLocations(s);

        threshold = ...
            boundaryFraction * peakAmplitudes(s);

        % Search backwards for syllable beginning
        leftIdx = peakIdx;

        while leftIdx > 1 && ...
                amplitudeEnvelope(leftIdx) > threshold

            leftIdx = leftIdx - 1;

        end

        % Search forwards for syllable ending
        rightIdx = peakIdx;

        while rightIdx < nSamples && ...
                amplitudeEnvelope(rightIdx) > threshold

            rightIdx = rightIdx + 1;

        end

        syllableStarts(s) = (leftIdx - 1) / Fs;
        syllableEnds(s) = (rightIdx - 1) / Fs;

    end

    %% 5G. PREVENT OVERLAPPING SYLLABLE BOUNDARIES

    for s = 1:(nSyllables - 1)

        midpointIdx = floor( ...
            (peakLocations(s) + peakLocations(s+1)) / 2);

        midpointTime = (midpointIdx - 1) / Fs;

        syllableEnds(s) = min( ...
            syllableEnds(s), midpointTime);

        syllableStarts(s+1) = max( ...
            syllableStarts(s+1), midpointTime);

    end

    syllableStarts = max(0, min( ...
        syllableStarts, duration_seconds));

    syllableEnds = max(0, min( ...
        syllableEnds, duration_seconds));

    %% 5H. GROUP SYLLABLES INTO CHIRPS
    %
    % IMPORTANT CORRECTION:
    %
    % OLD METHOD:
    % Distance between syllable peaks.
    %
    % NEW METHOD:
    % Silence between the END of syllable N and the
    % START of syllable N+1.
    %
    % If that silence is <= maxWithinChirpSilence_ms,
    % both syllables belong to the same chirp.
    %
    % A new chirp starts when the silence exceeds
    % the threshold, or the maximum syllable count
    % has been reached.

    maxWithinChirpSilence_seconds = ...
        maxWithinChirpSilence_ms / 1000;

    % Store candidate syllable groups first
    groupFirstIndices = zeros(0,1);
    groupLastIndices = zeros(0,1);

    firstSyllable = 1;
    syllablesInGroup = 1;

    for s = 2:nSyllables

        silenceBetweenSyllables = ...
            syllableStarts(s) - syllableEnds(s-1);

        silenceBetweenSyllables = max( ...
            0, silenceBetweenSyllables);

        startNewGroup = ...
            silenceBetweenSyllables > ...
                maxWithinChirpSilence_seconds || ...
            syllablesInGroup >= maxSyllablesPerChirp;

        if startNewGroup

            groupFirstIndices(end+1,1) = firstSyllable;
            groupLastIndices(end+1,1) = s - 1;

            firstSyllable = s;
            syllablesInGroup = 1;

        else

            syllablesInGroup = syllablesInGroup + 1;

        end
    end

    % Store final group
    groupFirstIndices(end+1,1) = firstSyllable;
    groupLastIndices(end+1,1) = nSyllables;

    %% 5I. VALIDATE COMPLETE CHIRPS

    syllablesPerGroup = ...
        groupLastIndices - groupFirstIndices + 1;

    validGroupMask = ...
        syllablesPerGroup >= minSyllablesPerChirp & ...
        syllablesPerGroup <= maxSyllablesPerChirp;

    nRejectedGroups = sum(~validGroupMask);

    validFirstIndices = ...
        groupFirstIndices(validGroupMask);

    validLastIndices = ...
        groupLastIndices(validGroupMask);

    chirpStartTimes = ...
        syllableStarts(validFirstIndices);

    chirpEndTimes = ...
        syllableEnds(validLastIndices);

    chirpSyllableCounts = ...
        syllablesPerGroup(validGroupMask);

    nChirps = numel(chirpStartTimes);

    fprintf('  Valid chirps: %d\n', nChirps);
    fprintf('  Rejected syllable groups: %d\n', ...
        nRejectedGroups);

    %% 5J. CALCULATE INTER-CHIRP GAPS
    %
    % Gap = start of next chirp - end of previous chirp.
    %
    % These are now gaps between COMPLETE chirps,
    % rather than gaps between individual syllables.

    if nChirps >= 2

        previousChirpNumbers = (1:nChirps-1)';
        nextChirpNumbers = (2:nChirps)';

        previousChirpEnds = chirpEndTimes(1:end-1);
        nextChirpStarts = chirpStartTimes(2:end);

        rawGapSeconds = ...
            nextChirpStarts - previousChirpEnds;

        validGapMask = ...
            isfinite(rawGapSeconds) & ...
            rawGapSeconds >= 0;

        nInvalidGaps = sum(~validGapMask);

        candidateGapSeconds = ...
            rawGapSeconds(validGapMask);

        candidatePreviousChirpNumbers = ...
            previousChirpNumbers(validGapMask);

        candidateNextChirpNumbers = ...
            nextChirpNumbers(validGapMask);

        candidatePreviousChirpEnds = ...
            previousChirpEnds(validGapMask);

        candidateNextChirpStarts = ...
            nextChirpStarts(validGapMask);

    else

        candidateGapSeconds = zeros(0,1);

        candidatePreviousChirpNumbers = zeros(0,1);
        candidateNextChirpNumbers = zeros(0,1);

        candidatePreviousChirpEnds = zeros(0,1);
        candidateNextChirpStarts = zeros(0,1);

        nInvalidGaps = 0;

    end

    nCandidateGaps = max(nChirps - 1, 0);

    %% 5K. EXCLUDE LONG PAUSES

    withinCallMask = ...
        candidateGapSeconds < maxWithinCallGap_seconds;

    nExcludedLongPauseGaps = sum(~withinCallMask);

    qualifyingCandidateIndices = find(withinCallMask);

    allGapSeconds = ...
        candidateGapSeconds(withinCallMask);

    previousChirpNumbers = ...
        candidatePreviousChirpNumbers(withinCallMask);

    nextChirpNumbers = ...
        candidateNextChirpNumbers(withinCallMask);

    previousChirpEnds = ...
        candidatePreviousChirpEnds(withinCallMask);

    nextChirpStarts = ...
        candidateNextChirpStarts(withinCallMask);

    nAvailableGaps = numel(allGapSeconds);

    %% 5L. RANDOMLY SELECT QUALIFYING GAPS

    if nAvailableGaps > maxGapsPerRecording

        selectedIndices = randperm( ...
            nAvailableGaps, maxGapsPerRecording);

        selectedIndices = sort(selectedIndices(:));

    else

        selectedIndices = (1:nAvailableGaps)';

    end

    selectedGapSeconds = ...
        allGapSeconds(selectedIndices);

    selectedPreviousChirps = ...
        previousChirpNumbers(selectedIndices);

    selectedNextChirps = ...
        nextChirpNumbers(selectedIndices);

    selectedPreviousEnds = ...
        previousChirpEnds(selectedIndices);

    selectedNextStarts = ...
        nextChirpStarts(selectedIndices);

    nSelected = numel(selectedIndices);

    %% 5M. MAP SELECTED GAPS BACK TO PLOT

    selectedCandidateIndices = ...
        qualifyingCandidateIndices(selectedIndices);

    selectedCandidateMask = ...
        false(numel(candidateGapSeconds),1);

    selectedCandidateMask(selectedCandidateIndices) = true;

    %% 5N. EXPORT INDIVIDUAL GAPS

    if nSelected > 0

        selectedFiles = ...
            repmat(string(fileName), nSelected, 1);

        selectedDuration = ...
            repmat(duration_seconds, nSelected, 1);

        gapNumbersWithinExport = (1:nSelected)';

        % Original gap positions before long-pause filtering
        gapNumbersInFullRecording = ...
            selectedCandidateIndices(:);

        gapRows = table( ...
            selectedFiles, ...
            selectedDuration, ...
            gapNumbersWithinExport, ...
            gapNumbersInFullRecording, ...
            selectedPreviousChirps(:), ...
            selectedNextChirps(:), ...
            selectedPreviousEnds(:), ...
            selectedNextStarts(:), ...
            selectedGapSeconds(:), ...
            selectedGapSeconds(:)*1000, ...
            'VariableNames', gapVariableNames);

        gapResults = [gapResults; gapRows];

    end

    %% 5O. RECORDING SUMMARY

    summaryRow = table( ...
        string(fileName), ...
        duration_seconds, ...
        nSyllables, ...
        nChirps, ...
        nRejectedGroups, ...
        nCandidateGaps, ...
        nExcludedLongPauseGaps, ...
        nAvailableGaps, ...
        nSelected, ...
        nInvalidGaps, ...
        'VariableNames', summaryVariableNames);

    recordingSummary = [recordingSummary; summaryRow];

    %% 5P. VISUAL QUALITY-CONTROL PLOT

    if showPlots

        figure( ...
            'Name', fileName, ...
            'NumberTitle', 'off', ...
            'Color', 'w');

        hold on;

        % Downsample only the displayed waveform.
        % Analysis remains at the original sampling rate.

        plotStep = max(1, ...
            ceil(nSamples / maxPlotPoints));

        plotIndices = 1:plotStep:nSamples;

        plotTimes = (plotIndices - 1) / Fs;

        plotAudio = audio(plotIndices);
        plotEnvelope = amplitudeEnvelope(plotIndices);

        % Plot limits based on full signal
        yMin = min([min(audio), min(amplitudeEnvelope)]);
        yMax = max([max(audio), max(amplitudeEnvelope)]);

        yRange = yMax - yMin;

        if yRange <= 0
            yRange = 1;
        end

        yMin = yMin - 0.05*yRange;
        yMax = yMax + 0.05*yRange;

        %% SHADE GAP INTERVALS

        for g = 1:numel(candidateGapSeconds)

            gapStart = candidatePreviousChirpEnds(g);
            gapEnd = candidateNextChirpStarts(g);

            if selectedCandidateMask(g)

                % BLUE: selected and exported
                gapColor = [0.10 0.45 0.95];
                gapAlpha = 0.30;

            elseif withinCallMask(g)

                % GREEN: qualifies but not selected
                gapColor = [0.15 0.70 0.25];
                gapAlpha = 0.20;

            else

                % RED: excluded long pause
                gapColor = [0.90 0.20 0.20];
                gapAlpha = 0.18;

            end

            patch( ...
                [gapStart gapEnd gapEnd gapStart], ...
                [yMin yMin yMax yMax], ...
                gapColor, ...
                'FaceAlpha', gapAlpha, ...
                'EdgeColor', 'none', ...
                'HandleVisibility', 'off');

        end

        %% PLOT AUDIO AND ENVELOPE

        hAudio = plot( ...
            plotTimes, plotAudio, ...
            'Color', [0.55 0.55 0.55], ...
            'LineWidth', 0.7);

        hEnvelope = plot( ...
            plotTimes, plotEnvelope, ...
            'b', ...
            'LineWidth', 1);

        hPeaks = plot( ...
            peakTimes, peakAmplitudes, ...
            'rv', ...
            'MarkerFaceColor', 'r', ...
            'MarkerSize', 4);

        %% DISPLAY CHIRP BOUNDARIES
        %
        % Green dashed line = chirp beginning
        % Purple dashed line = chirp ending

        for c = 1:nChirps

            xline( ...
                chirpStartTimes(c), '--', ...
                'Color', [0.0 0.45 0.0], ...
                'HandleVisibility', 'off');

            xline( ...
                chirpEndTimes(c), '--', ...
                'Color', [0.7 0.0 0.7], ...
                'HandleVisibility', 'off');

        end

        %% LEGEND HANDLES

        hSelected = patch( ...
            nan, nan, [0.10 0.45 0.95], ...
            'FaceAlpha', 0.30, ...
            'EdgeColor', 'none');

        hQualifying = patch( ...
            nan, nan, [0.15 0.70 0.25], ...
            'FaceAlpha', 0.20, ...
            'EdgeColor', 'none');

        hExcluded = patch( ...
            nan, nan, [0.90 0.20 0.20], ...
            'FaceAlpha', 0.18, ...
            'EdgeColor', 'none');

        %% LABELS

        xlabel('Time (seconds)');
        ylabel('Amplitude');

        ylim([yMin yMax]);
        xlim([0 duration_seconds]);

        title(sprintf( ...
            ['%s | %d syllables | %d valid chirps | ' ...
             '%d qualifying | %d selected | %d excluded'], ...
            fileName, ...
            nSyllables, ...
            nChirps, ...
            nAvailableGaps, ...
            nSelected, ...
            nExcludedLongPauseGaps), ...
            'Interpreter', 'none');

        legend( ...
            [hAudio hEnvelope hPeaks ...
             hSelected hQualifying hExcluded], ...
            { ...
            'Audio', ...
            'Smoothed envelope', ...
            'Syllable peaks', ...
            'Selected gap (exported)', ...
            'Qualifying gap (not selected)', ...
            'Excluded pause (>= 1 second)'}, ...
            'Location', 'best');

        grid on;
        hold off;

        drawnow;

    end

    %% 5Q. PRINT PROGRESS

    fprintf('  Duration: %.2f seconds\n', ...
        duration_seconds);

    fprintf('  Candidate inter-chirp gaps: %d\n', ...
        nCandidateGaps);

    fprintf('  Excluded long pauses: %d\n', ...
        nExcludedLongPauseGaps);

    fprintf('  Qualifying gaps: %d\n', ...
        nAvailableGaps);

    fprintf('  Exported gaps: %d\n', ...
        nSelected);

end

%% 6. EXPORT RESULTS

writetable(gapResults, gapOutputFile);

writetable(recordingSummary, summaryOutputFile);

%% 7. FINAL SUMMARY

fprintf('\n============================================\n');
fprintf('ANALYSIS COMPLETE\n');
fprintf('============================================\n');

fprintf('Recordings found: %d\n', ...
    numel(wavFiles));

fprintf('Recordings summarised: %d\n', ...
    height(recordingSummary));

fprintf('Detected valid chirps: %d\n', ...
    sum(recordingSummary.DetectedChirps));

fprintf('Rejected syllable groups: %d\n', ...
    sum(recordingSummary.RejectedSyllableGroups));

fprintf('Candidate inter-chirp gaps: %d\n', ...
    sum(recordingSummary.CandidateGaps));

fprintf('Long pauses excluded: %d\n', ...
    sum(recordingSummary.ExcludedLongPauseGaps));

fprintf('Qualifying gaps: %d\n', ...
    sum(recordingSummary.AvailableWithinCallGaps));

fprintf('Individual gaps exported: %d\n', ...
    height(gapResults));

fprintf('\nIndividual gap CSV:\n%s\n', ...
    gapOutputFile);

fprintf('\nRecording summary CSV:\n%s\n', ...
    summaryOutputFile);

fprintf('\nPreview of individual gaps:\n');

disp(gapResults(1:min(10,height(gapResults)), :));

fprintf('\nPreview of recording summary:\n');

disp(recordingSummary(1:min(10,height(recordingSummary)), :));

fprintf('\nVariables retained in workspace:\n');
fprintf('  gapResults\n');
fprintf('  recordingSummary\n');

fprintf('\nDone.\n');
