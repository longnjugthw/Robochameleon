%> @file Laser_v1.m
%> @brief Laser model
%>
%> @class Laser_v1
%> @brief Laser model
%>
%>  @ingroup physModels
%>
%> Outputs a time-domain phase noise sequence with the desired frequency
%> noise power spectral density.
%>
%> __Basic algorithm__
%>  -# FM noise PSD is generated in the frequency domain
%>  -# FM noise PSD is converted to time domain using IDFT
%>  -# FM noise PSD is convolved with white Gaussian noise
%>  -# PM noise is generated by integrating FM noise
%> The length of the FM noise PSD is specified in model.Lpsd, or in the
%> constructor, param.L. Noise at the lowest frequency component (DC) is
%> forced to zero unless L=1.  This means phase noise will be zero-mean
%> unless L=1.
%>
%> __How to use it__
%>
%> Two ways for using within the Robochameleon framework:
%>   -# Source: Specify signal_interface parameters (Fs,Lnoise)
%>   -# Traverseable: Gets the signal parameters as an input
%>
%> Two types of operation
%>   -# lorentzian: You need to specifiy linewidth.
%>   It creates a flat frequency power spectral density
%>   (PSD) at linewidth/pi level, which corresponds to a lorenztian
%>   optical spectrum with a FWHM of linewidth.
%>   -# semiconductor: You need to specify LFLW1GHZ, HFLW, fr, K and
%>   alpha. It creates the desired semiconductor frequency noise PSD
%>   based on those 5 parameters and outputs a time-domain phase noise
%>   sequence that matches the desired PSD.
%>
%>
%> _Basic use case:_
%> Build a Lorentizan laser with linewidth of 100 KHz at 1550 nm with 2^10 samples
%> @code
%>     param.laser.Fs = 80e9;
%>     param.laser.Lnoise = 2^10;
%> @endcode
%>
%> Lorentzian examples:
%> @code
%> Txparam = struct('Power', pwr(150, {5, 'dBm'}), 'linewidth', 1e5, 'Fc', const.c/1550e-9, 'L', 2^7, ...
%>      'Fs', param.ppg.Rs*param.ps.US_factor, 'Rs', Rs, 'Lnoise', param.ps.US_factor*L);
%> LOparam = struct('Power', pwr(150, {5, 'dBm'}), 'linewidth', 1e5, 'Fc', const.c/1550e-9+foffset, 'L', 1);
%> @endcode
%> A laser with Txparam would generate a signal; a laser with
%> LOparam would read many properties from an input
%> signal_interface.  The LO uses filter lengths 1, so phase will act
%> like a random walk (no low-frequency noise suppression).  The TX
%> uses a long filter, so low-frequency noise will be suppressed.
%> Runtime will also be longer.
%>
%> SCL example:
%> @code
%> SCLparam = struct('Power', pwr(150, {5, 'dBm'}), 'Fc', const.c/1550e-9+foffset, 'L', 2^14, ...
%>          'alpha', 3, 'fr', 1e9, 'K', .3e-9, 'LFLW1GHZ', 1e6, 'HFLW', 1e5);
%> badSCLparam = struct('Power', pwr(150, {5, 'dBm'}), 'linewidth', 1e5, 'Fc', const.c/1550e-9+foffset, 'L', 2^14, ...
%>          'alpha', 3, 'fr', 1e9, 'K', .3e-9, 'LFLW1GHZ', 1e6, 'HFLW', 1e5););
%> @endcode
%>
%> A laser with SCLparam will be a standarad SCL with the
%> properties specified.  A laser with badSCLparam will be a
%> Lorentzian, because 'linewidth' will take precedence over alpha,
%> fr, etc.  See:
%>
%> __References__
%>
%> M. Iglesias Olmedo, X. Pang, A. Udalcovs, R. Schatz,
%> D. Zibar, G. Jacobsen, S. Popov, and I. T. Monroy, "Impact of
%> Carrier Induced Frequency Noise from the Transmitter Laser on 28
%> and 56 Gbaud DP-QPSK Metro Links," in Asia Communications and
%> Photonics Conference 2014, OSA Technical Digest (online)
%> (Optical Society of America, 2014), paper ATh1E.1.
%> https://www.osapublishing.org/abstract.cfm?uri=ACPC-2014-ATh1E.1
%>
%> for definitions of these terms.  They are also defined in many
%> other sources (e.g. Coldren & Corzine).
%>
%> @author Miguel Iglesias Olmedo
%>
%> @see PhaseNoiseModel_v1
%> @version 1
classdef Laser_v1 < unit
    properties
        % Unit properties
        %> Number of inputs
        nInputs;
        %> Number of outputs
        nOutputs = 1;
        % Signal dependent properties
        %> carrier frequency  (Hz, can also be set by parameters)
        Fc = const.c/1550e-9;
        %> Lorentzian linewidth for standard (non-semiconductor) laser
        linewidth;
        %> Sampling frequency (Hz)
        Fs;
        %> Symbol rate (/sec)
        Rs = 1;
        %> Length of the noise signal (samples)
        Lnoise;
        %> Saves the waveform onto a file for speed porposes
        cacheEnabled = 0;
        
        % General properties
        %> Output power (pwr object)
        Power = pwr(inf,0);
        
        %> Phase Noise Model (Type PhaseNoiseModel_v1)
        model;
        %> Phase noise clipping limit [-1 1]*limitPn
        limitPn = 0;
        
        % Frequency and Phase noise calculation results
        %> Frequency Modulation noise
        FMnoiseCal;
        %> Phase Modulation noise
        PMnoiseCal;
        %> Frequency noise time sequence
        fn;
        %> Phase noise time sequence
        pn;
        %> FM noise PSD length
        L;
        %> FM noise PSD length
        Lir;
        %> Equivalent linewidth for 1/f noise defined at 1GHz
        LFLW1GHZ;
        %> High-frequency (Lorentzian-equivalent) linewidth
        HFLW;
        %> Relaxation resonance frequency
        fr;
        %> Damping factor
        K;
        %> Linewidth enhancement factor
        alpha;
    end
    
    methods
        
        %> @brief Class constructor
        %>
        %> Determines whether user wants to take signal parameters from
        %> another input signal or to specify them.  Also determines whether
        %> to operate in Lorentzian or semiconductor laser mode.
        %>
        %> @param param.Fs  Sampling frequency [Hz];
        %> @param param.Rs  Symbol rate [Hz]. Default: nan (Don't use this information).
        %> @param param.Lnoise Signal length [Samples].
        %> @param param.Fc Carrier frequency [Hz]. Default: 193.41 THz (1550 nm);
        %> @param param.Power Output power (pwr object). Default: SNR:inf, P: 0 dBm
        %>
        %> @param param.linewidth Lorentzian linewidth - forces operation in Lorentzian mode if specified [Hz]
        %> @param param.LFLW1GHZ linewidth at 1GHz
        %> @param param.HFLW high-frequency linewidth   [Hz]
        %> @param param.fr relaxation resonance frequency [Hz]
        %> @param param.K Damping factor
        %> @param param.alpha Linewidth enhancement factor [unitless]
        %>
        function obj = Laser_v1(param)
            % Check Fs and Rs is given (source) or takes it from an input
            REQUIRED_PARAMS = {};
            QUIET_PARAMS = {'Fs', 'Lnoise', 'model', 'nInputs', 'nOutputs', ...
                'FMnoiseCal', 'PMnoiseCal', 'fn', 'pn', 'results', 'label', ...
                'L', 'draw','cacheEnabled', 'Power'};
            
            if isfield(param, 'Fs') && isfield(param, 'Lnoise')
                obj.Fs=param.Fs;
                obj.Lnoise=param.Lnoise;
                obj.nInputs = 0;
            else
                robolog(['Either one among Fs, Lnoise has not been specified. Parameters will be ' ...
                    'copied from traverse input signal.'], 'NFO0');
                obj.nInputs = 1;
            end
            
            param.Power = paramdefault(param, 'Power', pwr(inf,0));     %setparams can't handle objects
           
            obj.setparams(param, REQUIRED_PARAMS, QUIET_PARAMS);
            
            %Intialize phase noise model
            param_model.type = 'linear';
            if isfield(param, 'linewidth') || ~isfield(param, 'LFLW1GHZ')
                robolog('Using Lorentzian mode.');
                param_model.linewidth = paramdefault(param, 'linewidth', 100e3);
                param_model.Lpsd = 1;
            else
                robolog('Using SCL mode.');
                param_model = param;
                param_model.Lpsd = paramdefault(param, {'L', 'Lir'}, 2^11);
            end
            obj.model = PhaseNoiseModel_v1(param_model);
            obj.draw = paramdefault(param, 'draw', 0);
        end
        
        function out = traverse(obj,varargin)
            if obj.nInputs == 1 && isempty(varargin)
                robolog('Missing input signal from where to copy parameters', 'ERR');
            elseif obj.nInputs == 0 && ~isempty(varargin)
                robolog('Too many input arguments. Laser parameters are already set.', 'ERR');
            end
            %>
            %> This function copies signal_interface parameters from input
            %> signal if any.
            %>
            %> @param varargin input signal_interface
            %> @retval fn frequency noise sequence
            %> @retval fn phase noise sequence
            if obj.nInputs == 1
                % Obtain params from signal
                obj.Fs = varargin{1}.Fs;
                obj.Rs = varargin{1}.Rs;
                obj.Lnoise = varargin{1}.L;
                obj.model.MinFreq = obj.MinFreq();
                obj.model.MaxFreq = obj.MaxFreq();
            end
            
            % Load waveforms from cache, if enabled
            if obj.cacheEnabled
                if isempty(obj.model.linewidth)
                    cache_params.LFLW1GHZ=obj.model.LFLW1GHZ;
                    cache_params.HFLW=obj.model.HFLW;
                    cache_params.fr=obj.model.fr;
                    cache_params.K=obj.model.K;
                    cache_params.alpha=obj.model.alpha;
                else
                    cache_params.linewidth=obj.model.linewidth;
                end
                cache_params.Lnoise=obj.Lnoise;
                tmpFolder = robopath(['tmp/' class(obj) '/']);
                if ~exist(tmpFolder,'file')
                    mkdir(tmpFolder);
                end
                fileName=[tmpFolder paramParser(cache_params) '.mat'];
                if exist(fileName, 'file');
                    load(fileName);
                else
                    %main calculations done here
                    [fn,pn] = process(obj);
                end
            else
                [fn,pn] = process(obj);
            end
            
            % Save waveforms to cache, if enabled
            if obj.cacheEnabled
                save(fileName,'fn','pn');
            end
            % Plot
            if obj.draw
                obj.fn = single(fn);
                obj.pn = single(pn);
                obj.plot();
            end
            if ~isnan(pn)
                % Create the complex baseband optical field
                field = sqrt(obj.Power.Ptot('W')).*exp(1j*pn(1:obj.Lnoise));
                % Output it as a signal_interface object
                out=signal_interface(field(:),struct('Fs', obj.Fs, 'Rs', obj.Rs, 'P', obj.Power, 'Fc', obj.Fc));
            end
        end
        
        %> @brief save parameters, generate noise
        function [fn,pn] = process(obj,varargin)
        %> 
        %> This function copies signal_interface parameters from input
        %> signal if any, then calls genNoise to generate
        %> appropriate phase noise and frequency noise sequences.
        %>
        %> @param varargin input signal_interface
        %> @retval fn frequency noise sequence
        %> @retval fn phase noise sequence
            if obj.nInputs == 1
                % Obtain params from signal
                obj.Fs = varargin{1}.Fs;
                obj.Rs = varargin{1}.Rs;
                obj.Lnoise = varargin{1}.L;
                obj.model.MinFreq = obj.MinFreq();
                obj.model.MaxFreq = obj.MaxFreq();
            end
            % The final time sequence will be mirrored in order to avoid
            % discontinuities in case of repetition
            obj.Lnoise = (obj.Lnoise + 2*obj.model.Lpsd)/2;
            % Generate the desired frequency noise PSD
            [obj.FMnoiseCal, obj.PMnoiseCal] = obj.model.genPSD();
            % Generate a gaussian time-domain sequence with desired PSD
            [fn, pn] = obj.genNoise();
        end
        
        %% Noise calculation methods
        function val = MaxFreq(obj)
            val = obj.Fs/2;
        end
        
        function val = MinFreq(obj)
            val = obj.Fs/obj.model.Lpsd;
        end
        
        %> @brief generate noise
        %>
        %> Generates frequency and phase noise time sequences.  Generates a
        %> time-domain filter with length obj.Lpsd (in constructor, param.L
        %> or param.Lir), generates white noise, then filters that noise
        %> using the constructed filter.  NB: filter will remove DC
        %> component of noise if length>1.
        %>
        %> @retval fn frequency noise sequence
        %> @retval fn phase noise sequence
        function [fn, pn] = genNoise(obj)
            % Time and frequency vectors (we double everything)
            freqs = [-flipud(obj.model.FMfreq);0; obj.model.FMfreq];
            time=linspace(-obj.model.Lpsd,obj.model.Lpsd,2*obj.model.Lpsd+1)/obj.Fs;
            % Frequency domain filters
            H_FN = obj.FMnoiseCal(:);
            H_FN = [ flipud(H_FN(:)); 0; H_FN(:)]/2;
            H_FN = sqrt(H_FN);
            % Time domain filters
            h_fn = obj.idft(freqs, H_FN, time);
            h_fn = real(h_fn(:));
            % Frequency and phase noise generation
            noise = awgn(zeros(2*obj.Lnoise,1),0)/sqrt(obj.Fs);
            fn =conv(noise,h_fn,'valid');
            pn = cumsum(2*pi*fn/obj.Fs);
            if obj.limitPn>0
                limit=[-1 1]*obj.limitPn;
                pn = pn-mean(pn);
                pn(pn>max(limit)) = -pn(pn>max(limit))+2*max(limit);
                pn(pn<min(limit)) = -pn(pn<min(limit))+2*min(limit);
            end
            obj.Lnoise = 2*(obj.Lnoise - obj.model.Lpsd);
        end
 
        %% Plotting functions
        function plotLineShape(obj)
            model2 = obj.model;
            model2.type ='log';
            model2.MinFreq = 1e3;
            model2.MaxFreq = 50e9;
            model2.Lpsd = 2^12;
            model2.Llw = 2^12;
            model2.plotLineShape;
        end
        
        function plotFMPSD(obj)
            colors
            % Plot desired frequency noise
            obj.model.plotFMPSD();
            % Plot desired constructed frequency noise PSD
            if ~isnan(obj.fn)
                Lwindow = 2^12;
                overlap = Lwindow/2;
                Win=hamming(Lwindow);
                hold on
                [FN, freqs] = pwelch(obj.fn, Win, overlap, obj.model.Lpsd, obj.Fs);
                loglog(freqs,  pi*FN,  'color', blue);
%                 legend('Desired PSD', 'Obtained PSD' , 'Location','SouthWest')
            end
            xlim([obj.MinFreq, obj.MaxFreq])
            if ~isnan(obj.fn)
                ylim(1.1*pi*[min(FN) max(FN)]);
            end
            grid on
        end
        
        function plotPNPSD(obj)
            colors
            % Plot desired frequency noise
            obj.model.plotPNPSD();
            % Plot phase PSDs
            if ~isnan(obj.pn)
                Lwindow = 2^12;
                overlap = Lwindow/2;
                Win=hamming(Lwindow);
                hold on
                [PN, freqs] = pwelch(obj.pn, Win, overlap, obj.model.Lpsd, obj.Fs);
                loglog(freqs,  PN, 'color', blue);
%                 legend('Desired PSD', 'Obtained PSD' , 'Location','SouthWest')
            end
            xlim([obj.MinFreq, obj.MaxFreq])
            grid on
        end
        % Plot frequency noise in time domain
        function plotFreqNoise(obj)
            colors
            timenoise = linspace(-obj.Lnoise,obj.Lnoise,obj.Lnoise)/obj.Fs;
            plot(timenoise*1e9,obj.fn*1e-6, 'color', blue)
            axis tight
            xlabel('ns')
            ylabel('MHz')
            title('Frequency noise');
        end
        % Plot phase noise in time domain
        function plotPhaseNoise(obj,varargin)
            % Plot PHASE NOISE SEQUENCE
            colors
            timenoise = linspace(-obj.Lnoise,obj.Lnoise,obj.Lnoise)/obj.Fs;
            if nargin > 1
                plot(timenoise*1e9, obj.pn,varargin)
            else
                plot(timenoise*1e9, obj.pn, 'color', blue)
            end
            axis tight
            xlabel('ns')
            ylabel('Rad')
            title('Phase noise');
        end
        function plot(obj)
            if isnan(obj.pn)
                width = 748;
                figure('Position', [100, 100, width, width*3/8])
                subplot(1,2,1)
                obj.plotLineShape
                subplot(1,2,2)
                obj.model.plotFMPSD
            else
                width = 1080;
                figure('Position', [100, 100, width, width*9/24])
                subplot(2,4,[1 2 5 6])
                obj.plotLineShape
                subplot(2,4,3)
                obj.plotFMPSD
                subplot(2,4,4)
                obj.plotPNPSD
                subplot(2,4,7)
                obj.plotFreqNoise
                subplot(2,4,8)
                obj.plotPhaseNoise
            end
            
        end
    end
    
    
    %% Static methods
    methods (Static)
        function x=idft(f,X,t)
            % function X=idft(f,X,t)
            % Compute IDFT (Inverse Discrete Fourier Transform) at times given
            % in t, given frequency terms X taken at frequencies f:
            % x(t) = sum { X(k) * e**(2*pi*j*t*f(k)) }
            % k
            
            shape = size(t);
            f = f(:); % Format 'f' into a column vector
            X = X(:); % Format 'X' into a column vector
            t = t(:); % Format 't' into a column vector
            
            df=diff(f);
            df(length(df)/2)=0;
            df=([0;df]+[df;0])/2;
            
            %df(end)=0;
            %df=f(2)-f(1);
            %X(1)=X(1)/2;
            %X(end)=X(end)/2;
            x(1:length(t))=0;
            x=x';
            fspan=2*f(end);
            for k=1:length(t)
                % It's just this simple:
                %x(k) = exp( 2*pi*1i * round(t(k)*fspan)/fspan*f')*(X.*df) ;
                x(k) = exp( 2*pi*1i * t(k)*f')*(X.*df) ;
            end;
            x = reshape(x,shape);
        end
    end
end
