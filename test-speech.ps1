<#
.SYNOPSIS
    WinWhisper Phase 0 -- Validate WinRT Speech Recognition Interop

.DESCRIPTION
    Tests the full interop chain: PowerShell 5.1 -> WinRT SpeechRecognizer.
    Uses reflection-based AsTask helpers (Add-Type with .winmd refs doesn't work).
    Must be run on Windows 11 via powershell.exe (NOT pwsh.exe).

.PARAMETER Language
    IETF language tag (e.g. "en-US", "de-DE"). Defaults to system language.

.PARAMETER DurationSeconds
    How long to listen before auto-stopping. Default 15.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File test-speech.ps1
    powershell.exe -ExecutionPolicy Bypass -File test-speech.ps1 -Language "de-DE"
    powershell.exe -ExecutionPolicy Bypass -File test-speech.ps1 -DurationSeconds 30
#>
param(
    [string]$Language,
    [int]$DurationSeconds = 15
)

$ErrorActionPreference = 'Stop'

# -- Preflight checks ----------------------------------------------------------

Write-Host ""
Write-Host "=== WinWhisper Phase 0: Speech Recognition Test ===" -ForegroundColor Cyan
Write-Host ""

# Must be PowerShell 5.1 Desktop (not Core/7+)
if ($PSVersionTable.PSEdition -eq 'Core') {
    Write-Host "[FAIL] Running on PowerShell Core ($($PSVersionTable.PSVersion))." -ForegroundColor Red
    Write-Host "       Requires Windows PowerShell 5.1 (powershell.exe, not pwsh.exe)." -ForegroundColor Red
    exit 1
}
Write-Host "[OK]   PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))" -ForegroundColor Green

# -- Test 1: Load WinRT types --------------------------------------------------

Write-Host ""
Write-Host "--- Test 1: Load WinRT Types ---" -ForegroundColor Yellow

$typesToLoad = @(
    @{ Name = "SpeechRecognizer";                  Full = "Windows.Media.SpeechRecognition.SpeechRecognizer, Windows.Media.SpeechRecognition, ContentType=WindowsRuntime" }
    @{ Name = "SpeechRecognitionTopicConstraint";   Full = "Windows.Media.SpeechRecognition.SpeechRecognitionTopicConstraint, Windows.Media.SpeechRecognition, ContentType=WindowsRuntime" }
    @{ Name = "SpeechContinuousRecognitionSession"; Full = "Windows.Media.SpeechRecognition.SpeechContinuousRecognitionSession, Windows.Media.SpeechRecognition, ContentType=WindowsRuntime" }
    @{ Name = "SpeechRecognitionScenario";          Full = "Windows.Media.SpeechRecognition.SpeechRecognitionScenario, Windows.Media.SpeechRecognition, ContentType=WindowsRuntime" }
    @{ Name = "Language";                           Full = "Windows.Globalization.Language, Windows.Globalization, ContentType=WindowsRuntime" }
)

foreach ($t in $typesToLoad) {
    try {
        $null = [Type]::GetType($t.Full, $true)
        Write-Host "[OK]   $($t.Name)" -ForegroundColor Green
    } catch {
        Write-Host "[FAIL] $($t.Name): $_" -ForegroundColor Red
        exit 1
    }
}

# -- Test 2: Load System.Runtime.WindowsRuntime for AsTask ---------------------

Write-Host ""
Write-Host "--- Test 2: Async Helpers (Reflection-based AsTask) ---" -ForegroundColor Yellow

try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null = [System.WindowsRuntimeSystemExtensions]
    Write-Host "[OK]   System.Runtime.WindowsRuntime loaded" -ForegroundColor Green
} catch {
    Write-Host "[FAIL] Cannot load System.Runtime.WindowsRuntime: $_" -ForegroundColor Red
    exit 1
}

# Resolve the AsTask overload for IAsyncAction (no return value)
$script:asTaskAction = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and
    -not $_.IsGenericMethod -and
    $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.ToString() -eq 'Windows.Foundation.IAsyncAction'
} | Select-Object -First 1

if ($script:asTaskAction) {
    Write-Host "[OK]   AsTask(IAsyncAction) resolved" -ForegroundColor Green
} else {
    Write-Host "[FAIL] Cannot resolve AsTask(IAsyncAction)" -ForegroundColor Red
    exit 1
}

# Resolve the AsTask overload for IAsyncOperation<TResult> (generic, returns value)
$script:asTaskOperation = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and
    $_.IsGenericMethodDefinition -and
    $_.GetGenericArguments().Count -eq 1 -and
    $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.ToString().StartsWith('Windows.Foundation.IAsyncOperation`1')
} | Select-Object -First 1

if ($script:asTaskOperation) {
    Write-Host "[OK]   AsTask<T>(IAsyncOperation<T>) resolved" -ForegroundColor Green
} else {
    Write-Host "[FAIL] Cannot resolve AsTask<T>(IAsyncOperation<T>)" -ForegroundColor Red
    exit 1
}

# Helper functions
function Await-Action([object]$asyncAction) {
    $task = $script:asTaskAction.Invoke($null, @($asyncAction))
    $task.Wait()
}

function Await-Operation([object]$asyncOperation, [Type]$resultType) {
    $closed = $script:asTaskOperation.MakeGenericMethod(@($resultType))
    $task = $closed.Invoke($null, @($asyncOperation))
    $task.Wait()
    return $task.Result
}

Write-Host "[OK]   Await-Action / Await-Operation helpers ready" -ForegroundColor Green

# -- Test 3: Supported languages -----------------------------------------------

Write-Host ""
Write-Host "--- Test 3: Supported Languages ---" -ForegroundColor Yellow

try {
    $supportedLangs = [Windows.Media.SpeechRecognition.SpeechRecognizer]::SupportedTopicLanguages
    $langTags = @($supportedLangs | ForEach-Object { $_.LanguageTag })
    Write-Host "[OK]   Supported: $($langTags -join ', ')" -ForegroundColor Green

    if ($Language -and $langTags -notcontains $Language) {
        Write-Host "[WARN] Requested language '$Language' not in supported list!" -ForegroundColor Yellow
    }
} catch {
    Write-Host "[WARN] Could not enumerate languages: $_" -ForegroundColor Yellow
}

# -- Test 4: Create SpeechRecognizer + CompileConstraints ----------------------

Write-Host ""
$langLabel = if ($Language) { $Language } else { "(system default)" }
Write-Host "--- Test 4: Initialize SpeechRecognizer [$langLabel] ---" -ForegroundColor Yellow

try {
    if ($Language) {
        $lang = [Windows.Globalization.Language]::new($Language)
        $recognizer = [Windows.Media.SpeechRecognition.SpeechRecognizer]::new($lang)
    } else {
        $recognizer = [Windows.Media.SpeechRecognition.SpeechRecognizer]::new()
    }
    Write-Host "[OK]   SpeechRecognizer created" -ForegroundColor Green
} catch {
    Write-Host "[FAIL] SpeechRecognizer creation failed: $_" -ForegroundColor Red
    if ($_.Exception.Message -like "*privacy*") {
        Write-Host '       Enable: Settings > Privacy & security > Speech > Online speech recognition' -ForegroundColor Yellow
        Start-Process "ms-settings:privacy-speech"
    }
    exit 1
}

# Add dictation constraint -- WinRT IVector.Add() isn't directly callable from PS,
# so we try multiple approaches: IVector.Append via reflection, then default grammar fallback.
$dictation = [Windows.Media.SpeechRecognition.SpeechRecognitionTopicConstraint]::new(
    [Windows.Media.SpeechRecognition.SpeechRecognitionScenario]::Dictation, "dictation")
$constraintAdded = $false

# Approach 1: Reflection on IVector<T>.Append (WinRT native method name)
try {
    $ivectorOpen = [Type]::GetType("Windows.Foundation.Collections.IVector``1, Windows.Foundation, ContentType=WindowsRuntime")
    $constraintType = [Type]::GetType("Windows.Media.SpeechRecognition.ISpeechRecognitionConstraint, Windows.Media.SpeechRecognition, ContentType=WindowsRuntime")
    if ($ivectorOpen -and $constraintType) {
        $vectorType = $ivectorOpen.MakeGenericType($constraintType)
        $appendMethod = $vectorType.GetMethod('Append')
        if ($appendMethod) {
            $appendMethod.Invoke($recognizer.Constraints, @($dictation))
            $constraintAdded = $true
            Write-Host "[OK]   Dictation constraint added (IVector.Append reflection)" -ForegroundColor Green
        }
    }
} catch {
    Write-Host "[INFO] IVector.Append reflection failed: $($_.Exception.Message)" -ForegroundColor DarkGray
}

# Approach 2: InvokeMember on the COM object
if (-not $constraintAdded) {
    try {
        $recognizer.Constraints.GetType().InvokeMember(
            'Append',
            [System.Reflection.BindingFlags]::InvokeMethod,
            $null,
            $recognizer.Constraints,
            @($dictation)
        )
        $constraintAdded = $true
        Write-Host "[OK]   Dictation constraint added (InvokeMember Append)" -ForegroundColor Green
    } catch {
        Write-Host "[INFO] InvokeMember Append failed: $($_.Exception.Message)" -ForegroundColor DarkGray
    }
}

# Approach 3: Proceed without constraint -- default grammar still provides dictation
if (-not $constraintAdded) {
    Write-Host "[WARN] Could not add dictation constraint -- using default grammar" -ForegroundColor Yellow
    Write-Host "       (Recognition may still work; default grammar includes basic dictation)" -ForegroundColor DarkGray
}

# Set long silence timeout
try {
    $recognizer.ContinuousRecognitionSession.AutoStopSilenceTimeout = [TimeSpan]::FromMinutes(5)
    Write-Host "[OK]   AutoStopSilenceTimeout set to 5 minutes" -ForegroundColor Green
} catch {
    Write-Host "[WARN] Could not set AutoStopSilenceTimeout: $_" -ForegroundColor Yellow
}

# Compile constraints
try {
    $compileResult = Await-Operation $recognizer.CompileConstraintsAsync() ([Windows.Media.SpeechRecognition.SpeechRecognitionCompilationResult])
    if ($compileResult.Status -eq [Windows.Media.SpeechRecognition.SpeechRecognitionResultStatus]::Success) {
        Write-Host "[OK]   CompileConstraintsAsync succeeded" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] CompileConstraintsAsync status: $($compileResult.Status)" -ForegroundColor Red
        $recognizer.Dispose()
        exit 1
    }
} catch {
    Write-Host "[FAIL] CompileConstraintsAsync failed: $_" -ForegroundColor Red
    if ($_.Exception.ToString() -like "*privacy*") {
        Write-Host '       Enable: Settings > Privacy & security > Speech > Online speech recognition' -ForegroundColor Yellow
        Start-Process "ms-settings:privacy-speech"
    }
    $recognizer.Dispose()
    exit 1
}

# -- Test 5: Single-shot recognition (RecognizeAsync -- no events needed) ------

Write-Host ""
Write-Host "--- Test 5: Single-Shot Recognition (speak after prompt) ---" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Speak a short phrase when prompted..." -ForegroundColor DarkGray
Write-Host ""

try {
    Write-Host "[....] Listening (single-shot)..." -ForegroundColor Cyan -NoNewline
    $result = Await-Operation $recognizer.RecognizeAsync() ([Windows.Media.SpeechRecognition.SpeechRecognitionResult])
    Write-Host "`r[OK]   Single-shot complete               " -ForegroundColor Green

    $confidence = $result.Confidence.ToString()
    $text = $result.Text
    Write-Host "  Confidence: $confidence" -ForegroundColor White
    Write-Host "  Text:       $text" -ForegroundColor White

    if ($text.Length -gt 0) {
        Write-Host "[OK]   Speech-to-text is WORKING!" -ForegroundColor Green
    } else {
        Write-Host "[WARN] No text captured. Speak louder or check microphone." -ForegroundColor Yellow
    }
} catch {
    Write-Host "`r[FAIL] RecognizeAsync failed" -ForegroundColor Red
    if ($_.Exception.ToString() -match '(?i)privacy') {
        Write-Host ""
        Write-Host '       Online speech recognition is not enabled.' -ForegroundColor Yellow
        Write-Host '       Enable: Settings > Privacy & security > Speech > Online speech recognition' -ForegroundColor Yellow
        Write-Host '       Opening settings page...' -ForegroundColor Yellow
        Start-Process "ms-settings:privacy-speech"
        Write-Host ""
        Write-Host '       Toggle it ON, then re-run this test.' -ForegroundColor White
    } else {
        Write-Host "       $_" -ForegroundColor Red
    }
    $recognizer.Dispose()
    exit 1
}

# -- Test 6: Continuous recognition via C# event bridge ------------------------

Write-Host ""
Write-Host "--- Test 6: Continuous Recognition ($DurationSeconds seconds) ---" -ForegroundColor Yellow
Write-Host ""

# PowerShell cannot subscribe to WinRT events (Register-ObjectEvent fails).
# Add-Type cannot reference .winmd files (HRESULT 0x80131047).
# Solution: C# bridge using runtime reflection + Expression trees to create
# correctly-typed WinRT event delegates without compile-time WinRT references.

$bridgeCode = @'
using System;
using System.Linq.Expressions;
using System.Reflection;
using System.Text;
using System.Threading;

public class SpeechEventBridge : IDisposable
{
    private StringBuilder _accumulated = new StringBuilder();
    private int _resultCount = 0;
    private int _hypothesisCount = 0;
    private bool _disposed = false;

    public event EventHandler<string> ResultReceived;
    public event EventHandler<string> HypothesisReceived;
    public event EventHandler<string> SessionCompleted;

    public string AccumulatedText { get { return _accumulated.ToString(); } }
    public int ResultCount { get { return _resultCount; } }
    public int HypothesisCount { get { return _hypothesisCount; } }

    // Subscribe to WinRT events using runtime reflection + Expression.Lambda
    // to create correctly-typed delegates without compile-time WinRT references.
    public string Subscribe(object recognizer, object session)
    {
        try
        {
            // Load WinRT types at runtime
            var sessionType = Type.GetType(
                "Windows.Media.SpeechRecognition.SpeechContinuousRecognitionSession, " +
                "Windows.Media.SpeechRecognition, ContentType=WindowsRuntime");
            var recognizerType = Type.GetType(
                "Windows.Media.SpeechRecognition.SpeechRecognizer, " +
                "Windows.Media.SpeechRecognition, ContentType=WindowsRuntime");

            if (sessionType == null || recognizerType == null)
                return "ERROR: Cannot load WinRT types at runtime";

            // Wire ResultGenerated
            var resultEvent = sessionType.GetEvent("ResultGenerated");
            if (resultEvent != null)
            {
                var handler = CreateTypedHandler(resultEvent.EventHandlerType,
                    new Action<object, object>(OnResultGenerated));
                resultEvent.AddEventHandler(session, handler);
            }

            // Wire HypothesisGenerated
            var hypothesisEvent = recognizerType.GetEvent("HypothesisGenerated");
            if (hypothesisEvent != null)
            {
                var handler = CreateTypedHandler(hypothesisEvent.EventHandlerType,
                    new Action<object, object>(OnHypothesisGenerated));
                hypothesisEvent.AddEventHandler(recognizer, handler);
            }

            // Wire Completed
            var completedEvent = sessionType.GetEvent("Completed");
            if (completedEvent != null)
            {
                var handler = CreateTypedHandler(completedEvent.EventHandlerType,
                    new Action<object, object>(OnSessionCompleted));
                completedEvent.AddEventHandler(session, handler);
            }

            return "OK";
        }
        catch (Exception ex)
        {
            return "ERROR: " + ex.GetType().Name + ": " + ex.Message +
                (ex.InnerException != null ? " -> " + ex.InnerException.Message : "");
        }
    }

    // Creates a delegate matching the WinRT event handler type signature
    // by building an Expression tree that calls our Action<object, object>.
    private static Delegate CreateTypedHandler(Type eventHandlerType, Action<object, object> callback)
    {
        var invokeMethod = eventHandlerType.GetMethod("Invoke");
        var parameters = invokeMethod.GetParameters();

        // Expression parameters matching the WinRT delegate signature
        var senderParam = Expression.Parameter(parameters[0].ParameterType, "sender");
        var argsParam = Expression.Parameter(parameters[1].ParameterType, "args");

        // Call: callback(sender, args) with args cast to object
        var callExpr = Expression.Call(
            Expression.Constant(callback),
            typeof(Action<object, object>).GetMethod("Invoke"),
            Expression.Convert(senderParam, typeof(object)),
            Expression.Convert(argsParam, typeof(object)));

        var lambda = Expression.Lambda(eventHandlerType, callExpr, senderParam, argsParam);
        return lambda.Compile();
    }

    private void OnResultGenerated(object sender, object eventArgs)
    {
        try
        {
            dynamic args = eventArgs;
            string text = args.Result.Text;
            if (!string.IsNullOrWhiteSpace(text))
            {
                if (_accumulated.Length > 0) _accumulated.Append(" ");
                _accumulated.Append(text);
                Interlocked.Increment(ref _resultCount);
                var h = ResultReceived;
                if (h != null) h(this, text);
            }
        }
        catch { }
    }

    private void OnHypothesisGenerated(object sender, object eventArgs)
    {
        try
        {
            dynamic args = eventArgs;
            string text = args.Hypothesis.Text;
            Interlocked.Increment(ref _hypothesisCount);
            var h = HypothesisReceived;
            if (h != null) h(this, text);
        }
        catch { }
    }

    private void OnSessionCompleted(object sender, object eventArgs)
    {
        try
        {
            dynamic args = eventArgs;
            string status = args.Status.ToString();
            var h = SessionCompleted;
            if (h != null) h(this, status);
        }
        catch { }
    }

    public void Dispose()
    {
        _disposed = true;
    }
}
'@

$bridgeReady = $false
try {
    Add-Type -TypeDefinition $bridgeCode -ReferencedAssemblies @(
        "System.Core",
        "Microsoft.CSharp"
    ) -ErrorAction Stop
    Write-Host "[OK]   C# event bridge compiled (reflection + Expression trees)" -ForegroundColor Green
    $bridgeReady = $true
} catch {
    Write-Host "[FAIL] C# event bridge compilation failed: $($_.Exception.Message)" -ForegroundColor Red
}

if ($bridgeReady) {
    # Create new recognizer for continuous test (previous one used for single-shot)
    $recognizer.Dispose()
    if ($Language) {
        $lang = [Windows.Globalization.Language]::new($Language)
        $recognizer = [Windows.Media.SpeechRecognition.SpeechRecognizer]::new($lang)
    } else {
        $recognizer = [Windows.Media.SpeechRecognition.SpeechRecognizer]::new()
    }

    # Re-add dictation constraint + compile
    $dictation = [Windows.Media.SpeechRecognition.SpeechRecognitionTopicConstraint]::new(
        [Windows.Media.SpeechRecognition.SpeechRecognitionScenario]::Dictation, "dictation")
    $ivectorOpen = [Type]::GetType("Windows.Foundation.Collections.IVector``1, Windows.Foundation, ContentType=WindowsRuntime")
    $constraintType = [Type]::GetType("Windows.Media.SpeechRecognition.ISpeechRecognitionConstraint, Windows.Media.SpeechRecognition, ContentType=WindowsRuntime")
    $vectorType = $ivectorOpen.MakeGenericType($constraintType)
    $vectorType.GetMethod('Append').Invoke($recognizer.Constraints, @($dictation))
    $recognizer.ContinuousRecognitionSession.AutoStopSilenceTimeout = [TimeSpan]::FromMinutes(5)
    $null = Await-Operation $recognizer.CompileConstraintsAsync() ([Windows.Media.SpeechRecognition.SpeechRecognitionCompilationResult])

    $bridge = New-Object SpeechEventBridge

    # Wire WinRT events via bridge
    $subscribeResult = $bridge.Subscribe($recognizer, $recognizer.ContinuousRecognitionSession)
    if ($subscribeResult -eq "OK") {
        Write-Host "[OK]   WinRT events wired via reflection bridge" -ForegroundColor Green

        Register-ObjectEvent -InputObject $bridge -EventName ResultReceived -Action {
            Write-Host "  [RESULT]     $($Event.SourceEventArgs)" -ForegroundColor Green
        } | Out-Null
        Register-ObjectEvent -InputObject $bridge -EventName HypothesisReceived -Action {
            $text = $Event.SourceEventArgs
            $display = if ($text.Length -gt 60) { "..." + $text.Substring($text.Length - 60) } else { $text }
            Write-Host "`r  [HYPOTHESIS] $display                    " -NoNewline -ForegroundColor DarkGray
        } | Out-Null
    } else {
        Write-Host "[WARN] Event wiring: $subscribeResult" -ForegroundColor Yellow
        Write-Host "       Continuous test will run but results may not be captured." -ForegroundColor DarkGray
    }

    # Start continuous recognition
    try {
        Await-Action $recognizer.ContinuousRecognitionSession.StartAsync()
        Write-Host "[OK]   Continuous listening started - speak now!" -ForegroundColor Green
        Write-Host "       (Runs for $DurationSeconds seconds)" -ForegroundColor DarkGray
        Write-Host ""
    } catch {
        Write-Host "[FAIL] Continuous StartAsync failed: $_" -ForegroundColor Red
        $recognizer.Dispose()
        exit 1
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $DurationSeconds) {
        Start-Sleep -Milliseconds 100
    }

    Write-Host ""
    Write-Host ""
    Write-Host "       Stopping..." -ForegroundColor DarkGray
    try {
        Start-Sleep -Milliseconds 300
        Await-Action $recognizer.ContinuousRecognitionSession.StopAsync()
        Start-Sleep -Milliseconds 500
    } catch {
        Write-Host "[WARN] StopAsync issue (may be normal): $_" -ForegroundColor Yellow
    }

    $finalText = $bridge.AccumulatedText

    Write-Host ""
    Write-Host "=== Continuous Results ===" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Language:          $langLabel" -ForegroundColor White
    Write-Host "  Result events:     $($bridge.ResultCount)" -ForegroundColor White
    Write-Host "  Hypothesis events: $($bridge.HypothesisCount)" -ForegroundColor White
    Write-Host "  Duration:          $([math]::Round($stopwatch.Elapsed.TotalSeconds, 1))s" -ForegroundColor White
    Write-Host ""

    if ($finalText.Length -gt 0) {
        Write-Host "  Final text:" -ForegroundColor Green
        Write-Host "  > $finalText" -ForegroundColor White
        Write-Host ""
        Write-Host "[OK]   Continuous speech recognition WORKING!" -ForegroundColor Green
    } else {
        Write-Host "  Final text: (empty)" -ForegroundColor Yellow
        Write-Host "[WARN] No continuous results captured." -ForegroundColor Yellow
    }

    $bridge.Dispose()
} else {
    Write-Host "[SKIP] Continuous recognition test skipped (event bridge failed)" -ForegroundColor Yellow
}

# -- Cleanup -------------------------------------------------------------------

Get-EventSubscriber | Unregister-Event -ErrorAction SilentlyContinue
$recognizer.Dispose()

Write-Host ""
Write-Host "=== Phase 0 Complete ===" -ForegroundColor Cyan
Write-Host ""
