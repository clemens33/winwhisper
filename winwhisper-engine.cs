using System;
using System.IO;
using System.Linq;
using System.Linq.Expressions;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

/// <summary>
/// WinWhisper Engine — WinRT speech recognition helper process.
/// Communicates with winwhisper.ps1 via stdin (commands) / stdout (JSON events).
///
/// Commands (stdin, one per line):
///   start    — begin continuous recognition
///   stop     — stop recognition, emit accumulated text
///   quit     — exit process
///
/// Events (stdout, JSON per line):
///   {"type":"ready"}
///   {"type":"hypothesis","text":"partial..."}
///   {"type":"result","text":"final text","confidence":"High"}
///   {"type":"stopped","text":"accumulated text","results":N}
///   {"type":"error","message":"..."}
///   {"type":"status","message":"..."}
/// </summary>
class WinWhisperEngine
{
    static MethodInfo asTaskAction;
    static MethodInfo asTaskOperation;

    static Type recType;
    static Type sessionType;
    static Type resultType;
    static Type compileResultType;
    static Type scenarioType;
    static Type topicConstraintType;

    static object recognizer;
    static object session;

    static StringBuilder accumulated = new StringBuilder();
    static int resultCount = 0;
    static bool isListening = false;
    static bool running = true;

    [STAThread]
    static void Main()
    {
        try
        {
            Initialize();
            Emit("ready", null, null);
            MainLoop();
        }
        catch (Exception ex)
        {
            EmitError(ex.Message);
        }
    }

    /// <summary>
    /// Main loop: pumps WinForms messages (needed for WinRT async/events)
    /// and reads stdin asynchronously via BeginRead (non-blocking).
    /// </summary>
    static void MainLoop()
    {
        var stdin = Console.OpenStandardInput();
        var readBuffer = new byte[256];
        var lineBuffer = new StringBuilder();

        // Start first async read
        IAsyncResult asyncRead = stdin.BeginRead(readBuffer, 0, readBuffer.Length, null, null);

        while (running)
        {
            // Pump WinRT/WinForms messages
            Application.DoEvents();

            // Check if stdin data is available (non-blocking)
            if (asyncRead.IsCompleted)
            {
                int bytesRead = stdin.EndRead(asyncRead);
                if (bytesRead == 0)
                {
                    // EOF — stdin closed
                    ProcessCommand("quit");
                    break;
                }

                string chunk = Encoding.UTF8.GetString(readBuffer, 0, bytesRead);
                lineBuffer.Append(chunk);

                // Process complete lines
                string buffered = lineBuffer.ToString();
                int idx;
                while ((idx = buffered.IndexOf('\n')) >= 0)
                {
                    string line = buffered.Substring(0, idx).TrimEnd('\r');
                    buffered = buffered.Substring(idx + 1);
                    ProcessCommand(line.Trim().ToLower());
                }
                lineBuffer.Clear();
                lineBuffer.Append(buffered);

                // Start next async read (only if still running)
                if (running)
                {
                    asyncRead = stdin.BeginRead(readBuffer, 0, readBuffer.Length, null, null);
                }
            }

            Thread.Sleep(10);
        }
    }

    static void ProcessCommand(string cmd)
    {
        switch (cmd)
        {
            case "start":
                StartListening();
                break;
            case "stop":
                StopListening();
                break;
            case "quit":
                if (isListening) StopListening();
                try { ((dynamic)recognizer).Dispose(); } catch { }
                running = false;
                break;
            default:
                EmitError("Unknown command: " + cmd);
                break;
        }
    }

    static void Initialize()
    {
        // Load WinRT types
        recType = Type.GetType(
            "Windows.Media.SpeechRecognition.SpeechRecognizer, " +
            "Windows.Media.SpeechRecognition, ContentType=WindowsRuntime", true);
        sessionType = Type.GetType(
            "Windows.Media.SpeechRecognition.SpeechContinuousRecognitionSession, " +
            "Windows.Media.SpeechRecognition, ContentType=WindowsRuntime", true);
        resultType = Type.GetType(
            "Windows.Media.SpeechRecognition.SpeechRecognitionResult, " +
            "Windows.Media.SpeechRecognition, ContentType=WindowsRuntime", true);
        compileResultType = Type.GetType(
            "Windows.Media.SpeechRecognition.SpeechRecognitionCompilationResult, " +
            "Windows.Media.SpeechRecognition, ContentType=WindowsRuntime", true);
        scenarioType = Type.GetType(
            "Windows.Media.SpeechRecognition.SpeechRecognitionScenario, " +
            "Windows.Media.SpeechRecognition, ContentType=WindowsRuntime", true);
        topicConstraintType = Type.GetType(
            "Windows.Media.SpeechRecognition.SpeechRecognitionTopicConstraint, " +
            "Windows.Media.SpeechRecognition, ContentType=WindowsRuntime", true);

        // Resolve AsTask
        var extType = typeof(WindowsRuntimeSystemExtensions);

        asTaskAction = extType.GetMethods().First(m =>
            m.Name == "AsTask" && !m.IsGenericMethod &&
            m.GetParameters().Length == 1 &&
            m.GetParameters()[0].ParameterType.ToString() == "Windows.Foundation.IAsyncAction");

        asTaskOperation = extType.GetMethods().First(m =>
            m.Name == "AsTask" && m.IsGenericMethodDefinition &&
            m.GetGenericArguments().Length == 1 &&
            m.GetParameters().Length == 1 &&
            m.GetParameters()[0].ParameterType.ToString().StartsWith("Windows.Foundation.IAsyncOperation`1"));

        // Create recognizer
        recognizer = Activator.CreateInstance(recType);

        // Add dictation constraint
        try
        {
            object dictationScenario = Enum.Parse(scenarioType, "Dictation");
            object dictation = Activator.CreateInstance(topicConstraintType, dictationScenario, "dictation");

            var ivectorOpen = Type.GetType(
                "Windows.Foundation.Collections.IVector`1, Windows.Foundation, ContentType=WindowsRuntime");
            var iconstraintType = Type.GetType(
                "Windows.Media.SpeechRecognition.ISpeechRecognitionConstraint, " +
                "Windows.Media.SpeechRecognition, ContentType=WindowsRuntime");

            if (ivectorOpen != null && iconstraintType != null)
            {
                var vectorType = ivectorOpen.MakeGenericType(iconstraintType);
                var appendMethod = vectorType.GetMethod("Append");
                if (appendMethod != null)
                {
                    appendMethod.Invoke(((dynamic)recognizer).Constraints, new object[] { dictation });
                }
            }
        }
        catch { }

        // Compile constraints — Wait() is OK here since no message pump yet
        object compileOp = ((dynamic)recognizer).CompileConstraintsAsync();
        var compileTask = (Task)asTaskOperation
            .MakeGenericMethod(compileResultType)
            .Invoke(null, new object[] { compileOp });
        compileTask.Wait();
        dynamic compileResult = ((dynamic)compileTask).Result;
        if (compileResult.Status.ToString() != "Success")
        {
            throw new Exception("CompileConstraintsAsync failed: " + compileResult.Status);
        }

        // Get session
        session = ((dynamic)recognizer).ContinuousRecognitionSession;

        // Subscribe to events
        SubscribeEvents();

        EmitStatus("initialized");
    }

    static void SubscribeEvents()
    {
        // ResultGenerated on session
        var resultEvent = sessionType.GetEvent("ResultGenerated");
        if (resultEvent != null)
        {
            var handler = CreateTypedHandler(resultEvent.EventHandlerType,
                new Action<object, object>(OnResultGenerated));
            ((dynamic)session).ResultGenerated += (dynamic)handler;
        }

        // HypothesisGenerated on recognizer
        var hypothesisEvent = recType.GetEvent("HypothesisGenerated");
        if (hypothesisEvent != null)
        {
            var handler = CreateTypedHandler(hypothesisEvent.EventHandlerType,
                new Action<object, object>(OnHypothesisGenerated));
            ((dynamic)recognizer).HypothesisGenerated += (dynamic)handler;
        }

        // Completed on session
        var completedEvent = sessionType.GetEvent("Completed");
        if (completedEvent != null)
        {
            var handler = CreateTypedHandler(completedEvent.EventHandlerType,
                new Action<object, object>(OnSessionCompleted));
            ((dynamic)session).Completed += (dynamic)handler;
        }
    }

    static Delegate CreateTypedHandler(Type eventHandlerType, Action<object, object> callback)
    {
        var invokeMethod = eventHandlerType.GetMethod("Invoke");
        var parameters = invokeMethod.GetParameters();
        var senderParam = Expression.Parameter(parameters[0].ParameterType, "sender");
        var argsParam = Expression.Parameter(parameters[1].ParameterType, "args");
        var callExpr = Expression.Call(
            Expression.Constant(callback),
            typeof(Action<object, object>).GetMethod("Invoke"),
            Expression.Convert(senderParam, typeof(object)),
            Expression.Convert(argsParam, typeof(object)));
        var lambda = Expression.Lambda(eventHandlerType, callExpr, senderParam, argsParam);
        return lambda.Compile();
    }

    static void OnResultGenerated(object sender, object eventArgs)
    {
        try
        {
            dynamic args = eventArgs;
            string text = args.Result.Text;
            string confidence = args.Result.Confidence.ToString();

            if (!string.IsNullOrWhiteSpace(text))
            {
                if (accumulated.Length > 0) accumulated.Append(" ");
                accumulated.Append(text);
                Interlocked.Increment(ref resultCount);
                Emit("result", text, confidence);
            }
        }
        catch (Exception ex)
        {
            EmitError("ResultGenerated: " + ex.Message);
        }
    }

    static void OnHypothesisGenerated(object sender, object eventArgs)
    {
        try
        {
            dynamic args = eventArgs;
            string text = args.Hypothesis.Text;
            Emit("hypothesis", text, null);
        }
        catch (Exception ex)
        {
            EmitError("HypothesisGenerated: " + ex.Message);
        }
    }

    static void OnSessionCompleted(object sender, object eventArgs)
    {
        try
        {
            dynamic args = eventArgs;
            string status = args.Status.ToString();
            isListening = false;
            EmitStatus("session_completed:" + status);
        }
        catch (Exception ex)
        {
            EmitError("SessionCompleted: " + ex.Message);
        }
    }

    static void StartListening()
    {
        if (isListening) return;
        accumulated.Clear();
        resultCount = 0;

        try
        {
            object startOp = ((dynamic)session).StartAsync();
            var startTask = (Task)asTaskAction.Invoke(null, new object[] { startOp });

            // Pump messages while waiting for StartAsync to complete
            while (!startTask.IsCompleted)
            {
                Application.DoEvents();
                Thread.Sleep(10);
            }

            if (startTask.IsFaulted)
            {
                string msg = "StartAsync failed";
                if (startTask.Exception != null && startTask.Exception.InnerException != null)
                    msg = startTask.Exception.InnerException.Message;
                EmitError("StartAsync: " + msg);
                return;
            }

            isListening = true;
            EmitStatus("listening");
        }
        catch (Exception ex)
        {
            EmitError("StartAsync: " + ex.Message);
        }
    }

    static void StopListening()
    {
        if (!isListening) return;

        try
        {
            object stopOp = ((dynamic)session).StopAsync();
            var stopTask = (Task)asTaskAction.Invoke(null, new object[] { stopOp });

            // Pump messages while waiting for StopAsync
            int timeout = 500; // 5 seconds max
            while (!stopTask.IsCompleted && timeout > 0)
            {
                Application.DoEvents();
                Thread.Sleep(10);
                timeout--;
            }

            if (stopTask.IsFaulted)
            {
                string msg = "StopAsync failed";
                if (stopTask.Exception != null && stopTask.Exception.InnerException != null)
                    msg = stopTask.Exception.InnerException.Message;
                EmitError("StopAsync: " + msg);
            }
        }
        catch (Exception ex)
        {
            EmitError("StopAsync: " + ex.Message);
        }

        isListening = false;

        // Emit final accumulated text
        string finalText = accumulated.ToString();
        Console.WriteLine("{\"type\":\"stopped\",\"text\":" + JsonEscape(finalText) +
            ",\"results\":" + resultCount + "}");
        Console.Out.Flush();
    }

    // --- Output helpers ---

    static void Emit(string type, string text, string confidence)
    {
        var sb = new StringBuilder();
        sb.Append("{\"type\":\"").Append(type).Append("\"");
        if (text != null)
            sb.Append(",\"text\":").Append(JsonEscape(text));
        if (confidence != null)
            sb.Append(",\"confidence\":\"").Append(confidence).Append("\"");
        sb.Append("}");
        Console.WriteLine(sb.ToString());
        Console.Out.Flush();
    }

    static void EmitError(string message)
    {
        Console.WriteLine("{\"type\":\"error\",\"message\":" + JsonEscape(message) + "}");
        Console.Out.Flush();
    }

    static void EmitStatus(string message)
    {
        Console.WriteLine("{\"type\":\"status\",\"message\":" + JsonEscape(message) + "}");
        Console.Out.Flush();
    }

    static string JsonEscape(string s)
    {
        if (s == null) return "null";
        return "\"" + s.Replace("\\", "\\\\").Replace("\"", "\\\"")
            .Replace("\n", "\\n").Replace("\r", "\\r").Replace("\t", "\\t") + "\"";
    }
}
