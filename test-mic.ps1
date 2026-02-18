# Minimal microphone + RecognizeAsync test
$ErrorActionPreference = 'Stop'

Write-Host "=== Microphone & Speech Test ===" -ForegroundColor Cyan
Write-Host ""

# Check privacy settings
$micKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone'
if (Test-Path $micKey) {
    $val = (Get-ItemProperty $micKey -Name Value -ErrorAction SilentlyContinue).Value
    Write-Host "Microphone consent (user): $val" -ForegroundColor $(if ($val -eq 'Allow') { 'Green' } else { 'Red' })
}
$micKeyMachine = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone'
if (Test-Path $micKeyMachine) {
    $val = (Get-ItemProperty $micKeyMachine -Name Value -ErrorAction SilentlyContinue).Value
    Write-Host "Microphone consent (machine): $val" -ForegroundColor $(if ($val -eq 'Allow') { 'Green' } else { 'Red' })
}

# Check online speech recognition
$speechKey = 'HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy'
if (Test-Path $speechKey) {
    $val = (Get-ItemProperty $speechKey -Name HasAccepted -ErrorAction SilentlyContinue).HasAccepted
    Write-Host "Online speech recognition: $val" -ForegroundColor $(if ($val -eq 1) { 'Green' } else { 'Red' })
}

Write-Host ""
Write-Host "Loading WinRT..." -ForegroundColor Gray
$null = [Type]::GetType('Windows.Media.SpeechRecognition.SpeechRecognizer, Windows.Media.SpeechRecognition, ContentType=WindowsRuntime', $true)
$null = [Type]::GetType('Windows.Media.SpeechRecognition.SpeechRecognitionResult, Windows.Media.SpeechRecognition, ContentType=WindowsRuntime', $true)
$null = [Type]::GetType('Windows.Media.SpeechRecognition.SpeechRecognitionCompilationResult, Windows.Media.SpeechRecognition, ContentType=WindowsRuntime', $true)
Add-Type -AssemblyName System.Runtime.WindowsRuntime

# Resolve AsTask
$asTaskOp = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.IsGenericMethodDefinition -and
    $_.GetGenericArguments().Count -eq 1 -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.ToString().StartsWith('Windows.Foundation.IAsyncOperation')
} | Select-Object -First 1

Write-Host "Creating recognizer..." -ForegroundColor Gray
$rec = [Windows.Media.SpeechRecognition.SpeechRecognizer]::new()
Write-Host "  Language: $($rec.CurrentLanguage.DisplayName)" -ForegroundColor White

Write-Host "Compiling constraints..." -ForegroundColor Gray
$compileOp = $rec.CompileConstraintsAsync()
$closedCompile = $asTaskOp.MakeGenericMethod([Windows.Media.SpeechRecognition.SpeechRecognitionCompilationResult])
$compileTask = $closedCompile.Invoke($null, @($compileOp))
$compileTask.Wait()
Write-Host "  Status: $($compileTask.Result.Status)" -ForegroundColor White

Write-Host ""
Write-Host "Starting RecognizeAsync..." -ForegroundColor Yellow
Write-Host "  Speak a short phrase now! (10 second timeout)" -ForegroundColor Yellow
Write-Host ""

$recOp = $rec.RecognizeAsync()
$closedRec = $asTaskOp.MakeGenericMethod([Windows.Media.SpeechRecognition.SpeechRecognitionResult])
$recTask = $closedRec.Invoke($null, @($recOp))

$completed = $recTask.Wait(10000)

if ($completed) {
    $result = $recTask.Result
    Write-Host "  Status:     $($result.Status)" -ForegroundColor White
    Write-Host "  Confidence: $($result.Confidence)" -ForegroundColor White
    Write-Host "  Text:       '$($result.Text)'" -ForegroundColor White
    Write-Host "  RawConf:    $($result.RawConfidence)" -ForegroundColor White

    if ($result.Text.Length -gt 0) {
        Write-Host ""
        Write-Host "[OK] Speech recognition works!" -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "[WARN] RecognizeAsync returned but with no text." -ForegroundColor Yellow
        Write-Host "  Status '$($result.Status)' suggests: $(
            switch ($result.Status.ToString()) {
                'Success' { 'recognized but empty text' }
                'NoMatch' { 'audio heard but no speech matched' }
                'InitialSilenceTimeout' { 'no audio input detected - MICROPHONE NOT WORKING' }
                'BabbleTimeout' { 'background noise but no clear speech' }
                'MicrophoneUnavailable' { 'MICROPHONE NOT AVAILABLE' }
                'NetworkFailure' { 'NETWORK ERROR - check internet connection' }
                default { 'unknown' }
            }
        )" -ForegroundColor Yellow
    }
} else {
    Write-Host "[FAIL] RecognizeAsync TIMED OUT after 10 seconds." -ForegroundColor Red
    Write-Host ""
    Write-Host "  This likely means microphone access is blocked." -ForegroundColor Red
    Write-Host "  Fix: Settings > Privacy & Security > Microphone" -ForegroundColor Yellow
    Write-Host "    1. 'Microphone access' must be ON" -ForegroundColor Yellow
    Write-Host "    2. 'Let desktop apps access your microphone' must be ON" -ForegroundColor Yellow

    try {
        # Try to cancel
        $cancelMethod = $recOp.GetType().GetMethod('Cancel')
        if ($cancelMethod) { $cancelMethod.Invoke($recOp, @()) }
    } catch {}
}

$rec.Dispose()
Write-Host ""
Write-Host "Done." -ForegroundColor Gray
