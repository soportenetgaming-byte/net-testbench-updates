<#
    NET Gaming - Banco de pruebas de hardware usado  (v2.11)
    -------------------------------------------------------
    CPU, motherboard, RAM (inventario/slots) y discos (SMART, lectura, escritura+verificación).
    Correr como administrador (usar Iniciar-TestBench.bat).

    Uso:
      .\NET-TestBench.ps1                 -> interfaz con pasos guiados
      .\NET-TestBench.ps1 -Modo Menu      -> menú de consola
      .\NET-TestBench.ps1 -Modo Rapido    -> inventario + chequeo de salud (1-2 min)
      .\NET-TestBench.ps1 -Modo Protocolo -> protocolo completo guiado

    Al iniciar ofrece bajar las herramientas que falten (smartctl, Prime95, CoreCycler/y-cruncher,
    LibreHardwareMonitor) a la carpeta "tools". Menú H para bajarlas, actualizarlas o abrirlas.
#>
[CmdletBinding()]
param(
    [ValidateSet('UI', 'Menu', 'Rapido', 'Protocolo')]
    [string]$Modo = 'UI',
    [switch]$CargarSolo
)

$ErrorActionPreference = 'Continue'
$Version = '2.11'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$IsWin = [Environment]::OSVersion.Platform -eq 'Win32NT'

# ======================================================================
#  Actualización automática: al abrir, si hay una versión nueva publicada, la baja y arranca con esa.
#  Se publica en un repositorio público que tiene SOLO el programa (sin la clave del taller).
#  Para desactivarla: config.txt (al lado del script) con la línea  actualizar=no
# ======================================================================
$UpdateBase = 'https://raw.githubusercontent.com/soportenetgaming-byte/net-testbench-updates/main/'

function Get-ConfigBanco {
    $c = @{}
    $f = Join-Path $Root 'config.txt'
    if (Test-Path $f) {
        foreach ($l in (Get-Content -Path $f -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            $t = $l.Trim()
            if (-not $t -or $t.StartsWith('#') -or -not $t.Contains('=')) { continue }
            $i = $t.IndexOf('=')
            $c[$t.Substring(0, $i).Trim().ToLower()] = $t.Substring($i + 1).Trim()
        }
    }
    return $c
}

function Invoke-AutoActualizacion {
    if ($env:NETBENCH_ACTUALIZADO -or $CargarSolo -or -not $IsWin) { return $false }
    if ((Get-ConfigBanco)['actualizar'] -match '^(no|0|false)$') { return $false }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
    $pp = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
    $tmp = $null
    try {
        Write-Host 'Buscando actualizaciones...' -ForegroundColor DarkGray
        $man = $null
        try { $man = Invoke-RestMethod -Uri ($UpdateBase + 'version.json?t=' + [DateTime]::UtcNow.Ticks) -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop }
        catch { Write-Host ("Sin conexión para buscar actualizaciones: sigue con la versión {0}." -f $Version) -ForegroundColor DarkGray; return $false }
        if ($man -is [string]) { $man = $man | ConvertFrom-Json }
        $nueva = [string]$man.version
        $vN = $null; $vA = $null
        if (-not [version]::TryParse($nueva, [ref]$vN) -or -not [version]::TryParse($Version, [ref]$vA)) { return $false }
        if ($vN -le $vA) { Write-Host ("Versión al día ({0})." -f $Version) -ForegroundColor DarkGray; return $false }
        Write-Host ("Hay una versión nueva: {0} (esta es la {1}). Actualizando..." -f $nueva, $Version) -ForegroundColor Cyan
        $archivos = @($man.archivos)
        if (-not @($archivos | Where-Object { $_.nombre -eq 'NET-TestBench.ps1' }).Count) { throw 'la publicación no trae NET-TestBench.ps1' }
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ('netbench-act-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        foreach ($a in $archivos) {
            $n = [string]$a.nombre
            if ($n -notmatch '^[\w\-. ]+(/[\w\-. ]+)?$' -or $n -match '\.\.') { throw ("nombre de archivo no permitido: {0}" -f $n) }
            $url = $UpdateBase + ((($n -split '/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/')
            $dest = Join-Path $tmp ($n -replace '/', '__')
            # ?t= para que GitHub no entregue una copia en caché de la versión anterior (daría "no coincide")
            Invoke-WebRequest -Uri ($url + '?t=' + [DateTime]::UtcNow.Ticks) -OutFile $dest -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
            if ((Get-FileHash -Path $dest -Algorithm SHA256).Hash -ne ([string]$a.sha256).ToUpper()) { throw ("{0} no coincide con lo publicado (descarga incompleta)" -f $n) }
        }
        $nuevo = Join-Path $tmp 'NET-TestBench.ps1'
        $err = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($nuevo, [ref]$null, [ref]$err)
        if ($err -and $err.Count) { throw 'el script nuevo tiene errores de sintaxis' }
        if ([IO.File]::ReadAllText($nuevo) -notmatch ("\`$Version = '" + [regex]::Escape($nueva) + "'")) { throw 'la versión del script no coincide con la publicada' }
        # copia de la versión que se reemplaza (las últimas 5), por si hay que volver atrás
        $bak = Join-Path $Root 'tools\versiones-anteriores'
        New-Item -ItemType Directory -Path $bak -Force | Out-Null
        Copy-Item -Path $PSCommandPath -Destination (Join-Path $bak ("NET-TestBench-v{0}.ps1" -f $Version)) -Force
        Get-ChildItem -Path $bak -Filter 'NET-TestBench-v*.ps1' | Sort-Object LastWriteTime -Descending | Select-Object -Skip 5 | Remove-Item -Force -ErrorAction SilentlyContinue
        foreach ($a in $archivos) {
            $n = [string]$a.nombre
            $dst = Join-Path $Root ($n -replace '/', '\')
            New-Item -ItemType Directory -Path (Split-Path -Parent $dst) -Force | Out-Null
            Copy-Item -Path (Join-Path $tmp ($n -replace '/', '__')) -Destination $dst -Force
        }
        $env:NETBENCH_ACTUALIZADO = ('{0}|{1}|{2}' -f $Version, $nueva, ((@($man.cambios) | ForEach-Object { [string]$_ }) -join ' · '))
        Write-Host ("Actualizado a la versión {0}." -f $nueva) -ForegroundColor Green
        return $true
    } catch {
        Write-Host ("No se pudo actualizar ({0}). Sigue con la versión {1}." -f $_.Exception.Message, $Version) -ForegroundColor Yellow
        return $false
    } finally {
        $ProgressPreference = $pp
        if ($tmp) { Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# Antes de cargar nada: si se actualizó, se corre la versión nueva en este mismo proceso y esta termina acá
if (Invoke-AutoActualizacion) { & $PSCommandPath @PSBoundParameters; return }

# ======================================================================
#  Motor (C#): stress de CPU con verificación + acceso a disco sin caché
# ======================================================================
$EngineSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

// Motor del banco de pruebas NET Gaming. C# 5 (compatible con Add-Type de PowerShell 5.1).
namespace NetBench
{
    public static class Native
    {
        [DllImport("kernel32.dll")]
        public static extern IntPtr GetCurrentThread();

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern UIntPtr SetThreadAffinityMask(IntPtr hThread, UIntPtr mask);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sec, uint disposition, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool ReadFile(SafeFileHandle h, IntPtr buffer, uint toRead, out uint read, IntPtr overlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool WriteFile(SafeFileHandle h, IntPtr buffer, uint toWrite, out uint written, IntPtr overlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool SetFilePointerEx(SafeFileHandle h, long distance, out long newPos, uint method);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr VirtualAlloc(IntPtr addr, UIntPtr size, uint type, uint protect);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool VirtualFree(IntPtr addr, UIntPtr size, uint type);

        [DllImport("kernel32.dll")]
        public static extern IntPtr GetConsoleWindow();

        [DllImport("user32.dll")]
        public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        public static void MinimizeConsole()
        {
            if (!IsWindows) return;
            try { IntPtr h = GetConsoleWindow(); if (h != IntPtr.Zero) ShowWindow(h, 6); } catch { }
        }

        public static bool IsWindows
        {
            get { return Environment.OSVersion.Platform == PlatformID.Win32NT; }
        }

        public static bool PinCurrentThread(int cpu)
        {
            if (!IsWindows || cpu < 0 || cpu >= IntPtr.Size * 8) return false;
            try { return SetThreadAffinityMask(GetCurrentThread(), new UIntPtr(1UL << cpu)) != UIntPtr.Zero; }
            catch { return false; }
        }
    }

    // Resuelve dependencias de LibreHardwareMonitorLib desde su carpeta, sin importar la version
    // Temperaturas de NVIDIA leídas directo de NVAPI (las mismas que muestran GPU-Z y HWiNFO).
    // LibreHardwareMonitor con PawnIO reemplaza el "GPU Hot Spot" por el máximo de varios canales
    // internos y en algunas placas (ej. RTX 4060) da 15-20 °C más que el hotspot real.
    public static class NvThermal
    {
        [DllImport("nvapi64.dll", EntryPoint = "nvapi_QueryInterface", CallingConvention = CallingConvention.Cdecl)]
        private static extern IntPtr QueryInterface(uint id);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int InitD();
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int EnumD([Out] IntPtr[] handles, out int count);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int NameD(IntPtr handle, StringBuilder name);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int ThermD(IntPtr handle, ref Sensors sensors);

        [StructLayout(LayoutKind.Sequential, Pack = 8)]
        private struct Sensors
        {
            public uint Version;
            public uint Mask;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 8)] public int[] Reserved;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)] public int[] Temperatures;
        }

        private static readonly object Sync = new object();
        private static bool _tried;
        private static ThermD _therm;
        private static IntPtr[] _handles;
        private static string[] _names;
        private static uint[] _masks;
        public static string Error;

        private static T Get<T>(uint id) where T : class
        {
            IntPtr p = QueryInterface(id);
            if (p == IntPtr.Zero) return null;
            return (T)(object)Marshal.GetDelegateForFunctionPointer(p, typeof(T));
        }

        private static int[] Read(IntPtr h, uint mask, out int status)
        {
            Sensors s = new Sensors();
            s.Version = (uint)(Marshal.SizeOf(typeof(Sensors)) | (2 << 16));
            s.Mask = mask;
            s.Reserved = new int[8];
            s.Temperatures = new int[32];
            status = _therm(h, ref s);
            return s.Temperatures;
        }

        public static int Count
        {
            get
            {
                lock (Sync)
                {
                    Init();
                    return _handles == null ? 0 : _handles.Length;
                }
            }
        }

        private static void Init()
        {
            if (_tried) return;
            _tried = true;
            try
            {
                InitD init = Get<InitD>(0x0150E828);
                if (init == null || init() != 0) { Error = "NvAPI_Initialize"; return; }
                EnumD en = Get<EnumD>(0xE5AC921F);
                NameD nm = Get<NameD>(0xCEEE8E9F);
                _therm = Get<ThermD>(0x65FE3AAD);
                if (en == null || _therm == null) { Error = "funciones no disponibles"; return; }
                IntPtr[] hs = new IntPtr[64];
                int n;
                if (en(hs, out n) != 0 || n <= 0) { Error = "sin GPUs NVIDIA"; return; }
                IntPtr[] handles = new IntPtr[n];
                string[] names = new string[n];
                uint[] masks = new uint[n];
                for (int i = 0; i < n; i++)
                {
                    handles[i] = hs[i];
                    StringBuilder sb = new StringBuilder(64);
                    names[i] = (nm != null && nm(hs[i], sb) == 0) ? sb.ToString() : "";
                    // mismo sondeo que LibreHardwareMonitor: bits válidos hasta el primero que falla
                    int bit = 0;
                    for (; bit < 32; bit++)
                    {
                        int st;
                        Read(hs[i], 1u << bit, out st);
                        if (st != 0) break;
                    }
                    masks[i] = bit == 0 ? 0u : (bit >= 32 ? uint.MaxValue : (1u << bit) - 1u);
                }
                _handles = handles; _names = names; _masks = masks;
            }
            catch (Exception e) { Error = e.Message; _handles = null; }
        }

        public static string Name(int i)
        {
            lock (Sync)
            {
                Init();
                return (_names != null && i >= 0 && i < _names.Length) ? _names[i] : null;
            }
        }

        public static int ValidCount(int i)
        {
            lock (Sync)
            {
                Init();
                if (_masks == null || i < 0 || i >= _masks.Length) return 0;
                int c = 0;
                for (uint m = _masks[i]; m != 0; m >>= 1) c++;
                return c;
            }
        }

        // Temperaturas en °C por índice (0 = núcleo, 1 = hotspot, 7/9 = memoria según la serie). null si no se pudo leer.
        public static double[] Temps(int i)
        {
            lock (Sync)
            {
                Init();
                if (_handles == null || i < 0 || i >= _handles.Length || _masks[i] == 0) return null;
                try
                {
                    int st;
                    int[] t = Read(_handles[i], _masks[i], out st);
                    if (st != 0) return null;
                    double[] r = new double[32];
                    for (int k = 0; k < 32; k++) r[k] = t[k] / 256.0;
                    return r;
                }
                catch { return null; }
            }
        }
    }

    public static class AsmResolver
    {
        static string dir;
        public static void Install(string d)
        {
            if (dir == null) AppDomain.CurrentDomain.AssemblyResolve += Resolve;
            dir = d;
        }
        static System.Reflection.Assembly Resolve(object sender, ResolveEventArgs e)
        {
            try
            {
                string n = new System.Reflection.AssemblyName(e.Name).Name;
                string p = System.IO.Path.Combine(dir, n + ".dll");
                if (File.Exists(p)) return System.Reflection.Assembly.LoadFrom(p);
            }
            catch { }
            return null;
        }
    }

    // ------------------------------------------------------------------
    // Carga de CPU deterministica: mismo resultado en cualquier nucleo sano.
    // ------------------------------------------------------------------
    public sealed class Workload
    {
        public const int Seed = 20261022;
        public const int DataSize = 2 * 1024 * 1024;
        const int N = 112;

        readonly byte[] data;
        readonly byte[] outBuf;
        readonly double[] a0, a, b, c;
        readonly SHA256 sha;

        public Workload()
        {
            data = new byte[DataSize];
            outBuf = new byte[DataSize];
            ulong s = unchecked((ulong)Seed * 0x9E3779B97F4A7C15UL + 1);
            // Texto pseudo aleatorio (comprimible) para ejercitar deflate
            string[] words = { "net", "gaming", "placa", "ryzen", "core", "nvme", "ddr5", "fuente", "vrm", "pcie",
                               "termica", "pasta", "cooler", "socket", "bios", "driver", "kernel", "cache", "bus", "clock" };
            int pos = 0;
            while (pos < DataSize)
            {
                s ^= s << 13; s ^= s >> 7; s ^= s << 17;
                string w = words[(int)(s % (ulong)words.Length)];
                for (int i = 0; i < w.Length && pos < DataSize; i++) data[pos++] = (byte)w[i];
                if (pos < DataSize) data[pos++] = (byte)((s >> 20) % 10 == 0 ? (byte)('0' + (s >> 40) % 10) : (byte)' ');
            }
            a0 = new double[N * N]; a = new double[N * N]; b = new double[N * N]; c = new double[N * N];
            for (int i = 0; i < N * N; i++)
            {
                s ^= s << 13; s ^= s >> 7; s ^= s << 17;
                a0[i] = ((double)(s >> 11) / (double)(1UL << 53)) * 2.0 - 1.0;
                s ^= s << 13; s ^= s >> 7; s ^= s << 17;
                b[i] = ((double)(s >> 11) / (double)(1UL << 53)) * 2.0 - 1.0;
            }
            sha = SHA256.Create();
        }

        static ulong Mix(ulong h, ulong v)
        {
            h ^= v; h *= 0x100000001B3UL; h ^= h >> 29; return h;
        }

        // Punto flotante: multiplicacion de matrices encadenada + raices
        public ulong Fp()
        {
            Array.Copy(a0, a, a0.Length);
            double invN = 1.0 / N;
            for (int r = 0; r < 10; r++)
            {
                for (int i = 0; i < N; i++)
                {
                    int ri = i * N;
                    for (int j = 0; j < N; j++)
                    {
                        double s0 = 0, s1 = 0;
                        int k = 0;
                        for (; k + 1 < N; k += 2)
                        {
                            s0 += a[ri + k] * b[k * N + j];
                            s1 += a[ri + k + 1] * b[(k + 1) * N + j];
                        }
                        for (; k < N; k++) s0 += a[ri + k] * b[k * N + j];
                        double v = (s0 + s1) * invN * 4.0;
                        c[ri + j] = v / (1.0 + Math.Sqrt(Math.Abs(v) + 1e-9));
                    }
                }
                Array.Copy(c, a, c.Length);
            }
            ulong h = 1469598103934665603UL;
            for (int i = 0; i < c.Length; i++) h = Mix(h, (ulong)BitConverter.DoubleToInt64Bits(c[i]));
            return h;
        }

        // Enteros: SHA-256 encadenado sobre el buffer
        public ulong Sha()
        {
            ulong h = 1469598103934665603UL;
            for (int r = 0; r < 12; r++)
            {
                int off = r * 4096;
                byte[] d = sha.ComputeHash(data, off, DataSize - off);
                h = Mix(h, BitConverter.ToUInt64(d, 0));
                h = Mix(h, BitConverter.ToUInt64(d, 24));
            }
            return h;
        }

        // Compresion + descompresion (lo que falla en CPUs degradados) con comparacion byte a byte
        public ulong Gzip(out bool roundTripOk)
        {
            byte[] comp;
            using (MemoryStream ms = new MemoryStream(DataSize))
            {
                using (DeflateStream z = new DeflateStream(ms, CompressionLevel.Optimal, true))
                    z.Write(data, 0, DataSize);
                comp = ms.ToArray();
            }
            int total = 0;
            using (MemoryStream src = new MemoryStream(comp))
            using (DeflateStream z = new DeflateStream(src, CompressionMode.Decompress))
            {
                int n;
                while (total < DataSize && (n = z.Read(outBuf, total, DataSize - total)) > 0) total += n;
            }
            roundTripOk = total == DataSize;
            if (roundTripOk)
                for (int i = 0; i < DataSize; i++)
                    if (outBuf[i] != data[i]) { roundTripOk = false; break; }
            ulong h = 1469598103934665603UL;
            h = Mix(h, (ulong)comp.Length);
            for (int i = 0; i + 8 <= comp.Length; i += 64) h = Mix(h, BitConverter.ToUInt64(comp, i));
            return h;
        }

        public static ulong[] Reference()
        {
            Workload w1 = new Workload();
            Workload w2 = new Workload();
            bool ok1, ok2;
            ulong[] r1 = { w1.Fp(), w1.Sha(), w1.Gzip(out ok1) };
            ulong[] r2 = { w2.Fp(), w2.Sha(), w2.Gzip(out ok2) };
            if (!ok1 || !ok2 || r1[0] != r2[0] || r1[1] != r2[1] || r1[2] != r2[2])
                throw new Exception("La referencia dio distinto en dos corridas seguidas: el CPU ya es inestable en reposo.");
            return r1;
        }
    }

    public sealed class StressRun
    {
        public readonly int[] Cpus;
        public readonly double Seconds;
        public readonly long[] Iter;
        public readonly long[] Errors;
        public readonly string[] LastError;
        public readonly bool[] Pinned;
        public readonly double[] IterPerSec;
        public volatile bool StopFlag;
        readonly ulong[] reference;
        int running;
        readonly Stopwatch clock = new Stopwatch();

        public StressRun(int[] cpus, double seconds, ulong[] reference)
        {
            Cpus = cpus; Seconds = seconds; this.reference = reference;
            int n = cpus.Length;
            Iter = new long[n]; Errors = new long[n]; LastError = new string[n];
            Pinned = new bool[n]; IterPerSec = new double[n];
        }

        public bool Running { get { return Thread.VolatileRead(ref running) > 0; } }
        public double Elapsed { get { return clock.Elapsed.TotalSeconds; } }

        public long TotalErrors
        {
            get { long t = 0; for (int i = 0; i < Errors.Length; i++) t += Errors[i]; return t; }
        }

        public void Start()
        {
            clock.Start();
            for (int i = 0; i < Cpus.Length; i++)
            {
                Interlocked.Increment(ref running);
                Thread t = new Thread(Worker, 16 * 1024 * 1024);
                t.IsBackground = true;
                t.Priority = ThreadPriority.BelowNormal;
                t.Start(i);
            }
        }

        void Fail(int i, string what)
        {
            Interlocked.Increment(ref Errors[i]);
            LastError[i] = what + " @ " + clock.Elapsed.TotalSeconds.ToString("F0") + "s";
        }

        void Worker(object o)
        {
            int i = (int)o;
            Stopwatch sw = Stopwatch.StartNew();
            try
            {
                Pinned[i] = Native.PinCurrentThread(Cpus[i]);
                Workload w = new Workload();
                while (!StopFlag && sw.Elapsed.TotalSeconds < Seconds)
                {
                    try
                    {
                        if (w.Fp() != reference[0]) Fail(i, "FP (calculo flotante)");
                        if (w.Sha() != reference[1]) Fail(i, "SHA256 (enteros)");
                        bool rt;
                        ulong g = w.Gzip(out rt);
                        if (!rt) Fail(i, "Descompresion corrupta");
                        else if (g != reference[2]) Fail(i, "Compresion distinta");
                    }
                    catch (Exception e)
                    {
                        Fail(i, "Excepcion " + e.GetType().Name);
                    }
                    Iter[i]++;
                    if (Errors[i] > 50) break;
                }
            }
            catch (Exception e)
            {
                Fail(i, "Worker murio: " + e.GetType().Name + " " + e.Message);
            }
            finally
            {
                double el = sw.Elapsed.TotalSeconds;
                IterPerSec[i] = el > 0 ? Iter[i] / el : 0;
                Interlocked.Decrement(ref running);
            }
        }
    }


    // ------------------------------------------------------------------
    // Corre un programa externo capturando su salida linea por linea.
    // ------------------------------------------------------------------
    public sealed class ProcCapture
    {
        readonly Process p;
        readonly List<string> lines = new List<string>();
        public volatile bool Exited;
        public int ExitCode = -1;

        public ProcCapture(string exe, string args, string workDir)
        {
            ProcessStartInfo si = new ProcessStartInfo(exe, args ?? "");
            si.UseShellExecute = false;
            si.RedirectStandardOutput = true;
            si.RedirectStandardError = true;
            si.RedirectStandardInput = true;
            si.CreateNoWindow = true;
            if (!string.IsNullOrEmpty(workDir)) si.WorkingDirectory = workDir;
            p = new Process();
            p.StartInfo = si;
            p.EnableRaisingEvents = true;
            p.OutputDataReceived += OnData;
            p.ErrorDataReceived += OnData;
            p.Exited += delegate { try { ExitCode = p.ExitCode; } catch { } Exited = true; };
            p.Start();
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
            try { p.StandardInput.Close(); } catch { }
        }

        void OnData(object sender, DataReceivedEventArgs e)
        {
            if (e.Data == null) return;
            lock (lines) { lines.Add(e.Data); }
        }

        public int Pid { get { return p.Id; } }
        public int Count { get { lock (lines) { return lines.Count; } } }

        public string[] Lines(int from)
        {
            lock (lines)
            {
                if (from < 0) from = 0;
                if (from >= lines.Count) return new string[0];
                return lines.GetRange(from, lines.Count - from).ToArray();
            }
        }

        public void KillTree()
        {
            if (Exited) return;
            try
            {
                if (Native.IsWindows)
                {
                    Process k = Process.Start(new ProcessStartInfo("taskkill", "/T /F /PID " + p.Id) { UseShellExecute = false, CreateNoWindow = true });
                    if (k != null) k.WaitForExit(10000);
                }
                if (!p.HasExited) p.Kill();
            }
            catch { }
        }
    }

    // ------------------------------------------------------------------
    // Servidor local para la pagina de stress de GPU (solo 127.0.0.1)
    // ------------------------------------------------------------------
    public sealed class GpuServer
    {
        readonly System.Net.HttpListener http = new System.Net.HttpListener();
        readonly string page;
        public readonly int Port;
        public volatile string LastStatus = "";
        public volatile string FinalStatus = "";
        public volatile string Sensors = "null";
        public volatile bool PageLoaded, Done;
        public DateTime LastUpdate = DateTime.MinValue;
        Thread t;

        public GpuServer(string html, int port)
        {
            page = html;
            Port = port;
            http.Prefixes.Add("http://127.0.0.1:" + port + "/");
            http.Start();
            t = new Thread(Loop);
            t.IsBackground = true;
            t.Start();
        }

        void Loop()
        {
            while (http.IsListening)
            {
                System.Net.HttpListenerContext ctx;
                try { ctx = http.GetContext(); } catch { return; }
                try { Handle(ctx); } catch { }
            }
        }

        void Handle(System.Net.HttpListenerContext ctx)
        {
            string path = ctx.Request.Url.AbsolutePath;
            string body = "";
            if (ctx.Request.HasEntityBody)
                using (StreamReader r = new StreamReader(ctx.Request.InputStream, System.Text.Encoding.UTF8)) body = r.ReadToEnd();
            byte[] outBytes = new byte[0];
            string type = "text/plain";
            if (path == "/" || path == "/index.html")
            {
                PageLoaded = true;
                outBytes = System.Text.Encoding.UTF8.GetBytes(page);
                type = "text/html; charset=utf-8";
            }
            else if (path == "/status") { LastStatus = body; LastUpdate = DateTime.Now; }
            else if (path == "/done") { FinalStatus = body; LastStatus = body; LastUpdate = DateTime.Now; Done = true; }
            else if (path == "/sensors") { outBytes = System.Text.Encoding.UTF8.GetBytes(Sensors ?? "null"); type = "application/json; charset=utf-8"; }
            else ctx.Response.StatusCode = 404;
            ctx.Response.ContentType = type;
            ctx.Response.Headers.Add("Cache-Control", "no-store");
            ctx.Response.ContentLength64 = outBytes.Length;
            if (outBytes.Length > 0) ctx.Response.OutputStream.Write(outBytes, 0, outBytes.Length);
            ctx.Response.OutputStream.Close();
        }

        public void Stop()
        {
            try { http.Stop(); http.Close(); } catch { }
        }
    }


    // ------------------------------------------------------------------
    // Interfaz: servidor local con estado, log en vivo, preguntas y comandos
    // ------------------------------------------------------------------
    public sealed class UiServer
    {
        readonly System.Net.HttpListener http = new System.Net.HttpListener();
        public readonly int Port;
        public volatile string Page = "";
        public volatile string Snapshot = "{}";
        public volatile string Progress = "null";
        public volatile string Task = "";
        public volatile bool Busy, Cancel, PageLoaded;
        public DateTime LastPoll = DateTime.Now;
        readonly List<string> log = new List<string>();
        int logEpoch = 1;
        readonly System.Collections.Concurrent.ConcurrentQueue<string> cmds = new System.Collections.Concurrent.ConcurrentQueue<string>();
        readonly object pl = new object();
        string promptJson = "null";
        int promptId;
        string answer;
        readonly ManualResetEvent answered = new ManualResetEvent(false);

        public UiServer(int port)
        {
            Port = port;
            http.Prefixes.Add("http://127.0.0.1:" + port + "/");
            http.Start();
            Thread t = new Thread(Loop);
            t.IsBackground = true;
            t.Start();
        }

        public static string J(string s)
        {
            if (s == null) return "null";
            System.Text.StringBuilder sb = new System.Text.StringBuilder(s.Length + 8);
            sb.Append('"');
            foreach (char ch in s)
            {
                switch (ch)
                {
                    case '"': sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': break;
                    case '\t': sb.Append("\\t"); break;
                    default:
                        if (ch < 0x20) sb.Append("\\u").Append(((int)ch).ToString("x4"));
                        else sb.Append(ch);
                        break;
                }
            }
            sb.Append('"');
            return sb.ToString();
        }

        public void AddLog(string text, string color)
        {
            lock (log) { log.Add("{\"t\":" + J(text) + ",\"c\":" + J(color) + "}"); }
        }

        public void ClearLog()
        {
            lock (log) { log.Clear(); logEpoch++; }
        }

        public void SetProgress(string activity, string status, int pct)
        {
            Progress = "{\"a\":" + J(activity) + ",\"s\":" + J(status) + ",\"p\":" + pct + "}";
        }

        public void ClearProgress() { Progress = "null"; }

        public string NextCommand(int waitMs)
        {
            string c;
            if (cmds.TryDequeue(out c)) return c;
            Thread.Sleep(waitMs);
            return cmds.TryDequeue(out c) ? c : null;
        }

        public void Enqueue(string cmd) { cmds.Enqueue(cmd); }

        public double SecondsSincePoll { get { return (DateTime.Now - LastPoll).TotalSeconds; } }

        // Bloquea al script hasta que la interfaz responda (o se cierre la ventana).
        public string Ask(string kind, string question, string def, string extraJson)
        {
            int id;
            lock (pl)
            {
                id = ++promptId;
                answer = null;
                answered.Reset();
                promptJson = "{\"id\":" + id + ",\"kind\":" + J(kind) + ",\"q\":" + J(question) + ",\"def\":" + J(def) +
                             ",\"extra\":" + (string.IsNullOrEmpty(extraJson) ? "null" : extraJson) + "}";
            }
            while (!answered.WaitOne(300))
            {
                if (PageLoaded && SecondsSincePoll > 30) break;   // ventana cerrada: se toma el valor por defecto
            }
            lock (pl)
            {
                promptJson = "null";
                return answer ?? def;
            }
        }

        void Loop()
        {
            while (http.IsListening)
            {
                System.Net.HttpListenerContext ctx;
                try { ctx = http.GetContext(); } catch { return; }
                try { Handle(ctx); } catch { try { ctx.Response.Abort(); } catch { } }
            }
        }

        void Reply(System.Net.HttpListenerContext ctx, string body, string type)
        {
            byte[] b = System.Text.Encoding.UTF8.GetBytes(body ?? "");
            ctx.Response.ContentType = type;
            ctx.Response.Headers.Add("Cache-Control", "no-store");
            ctx.Response.ContentLength64 = b.Length;
            ctx.Response.OutputStream.Write(b, 0, b.Length);
            ctx.Response.OutputStream.Close();
        }

        void Handle(System.Net.HttpListenerContext ctx)
        {
            string path = ctx.Request.Url.AbsolutePath;
            // Solo la propia interfaz puede mandar órdenes: se rechaza lo que venga de otra página abierta en el navegador
            string origin = ctx.Request.Headers["Origin"];
            if (!string.IsNullOrEmpty(origin) && origin != "http://127.0.0.1:" + Port)
            {
                ctx.Response.StatusCode = 403;
                Reply(ctx, "", "text/plain");
                return;
            }
            string body = "";
            if (ctx.Request.HasEntityBody)
                using (StreamReader r = new StreamReader(ctx.Request.InputStream, System.Text.Encoding.UTF8)) body = r.ReadToEnd();
            if (path == "/" || path == "/index.html")
            {
                PageLoaded = true;
                LastPoll = DateTime.Now;
                Reply(ctx, Page, "text/html; charset=utf-8");
                return;
            }
            if (path == "/api/state")
            {
                LastPoll = DateTime.Now;
                int since = 0, epoch = 0;
                int.TryParse(ctx.Request.QueryString["since"], out since);
                int.TryParse(ctx.Request.QueryString["epoch"], out epoch);
                System.Text.StringBuilder sb = new System.Text.StringBuilder();
                string pj;
                lock (pl) { pj = promptJson; }
                lock (log)
                {
                    if (epoch != logEpoch) since = 0;
                    if (since < 0 || since > log.Count) since = 0;
                    sb.Append("{\"epoch\":").Append(logEpoch).Append(",\"next\":").Append(log.Count).Append(",\"log\":[");
                    for (int i = since; i < log.Count; i++) { if (i > since) sb.Append(','); sb.Append(log[i]); }
                    sb.Append("]");
                }
                sb.Append(",\"busy\":").Append(Busy ? "true" : "false");
                sb.Append(",\"cancel\":").Append(Cancel ? "true" : "false");
                sb.Append(",\"task\":").Append(J(Task));
                sb.Append(",\"progress\":").Append(Progress);
                sb.Append(",\"prompt\":").Append(pj);
                sb.Append(",\"snap\":").Append(string.IsNullOrEmpty(Snapshot) ? "{}" : Snapshot);
                sb.Append("}");
                Reply(ctx, sb.ToString(), "application/json; charset=utf-8");
                return;
            }
            if (path == "/api/cmd" && body.Length > 0) { cmds.Enqueue(body); Reply(ctx, "ok", "text/plain"); return; }
            if (path == "/api/cancel") { Cancel = true; Reply(ctx, "ok", "text/plain"); return; }
            if (path == "/api/answer")
            {
                int id;
                int.TryParse(ctx.Request.QueryString["id"], out id);
                lock (pl)
                {
                    if (id == promptId && promptJson != "null") { answer = body; answered.Set(); }
                }
                Reply(ctx, "ok", "text/plain");
                return;
            }
            ctx.Response.StatusCode = 404;
            Reply(ctx, "", "text/plain");
        }

        public void Stop()
        {
            try { http.Stop(); http.Close(); } catch { }
        }
    }

    // ------------------------------------------------------------------
    // Acceso a disco sin cache (NO_BUFFERING) para no medir la RAM.
    // ------------------------------------------------------------------
    public sealed class RawFile : IDisposable
    {
        readonly bool win;
        readonly SafeFileHandle h;
        readonly FileStream fs;
        readonly IntPtr buf;
        readonly int bufSize;
        byte[] scratch;

        public RawFile(string path, bool write, bool create, int bufferSize)
        {
            bufSize = bufferSize;
            win = Native.IsWindows;
            if (win)
            {
                uint access = write ? 0xC0000000u : 0x80000000u;
                uint disp = create ? 2u : 3u;                       // CREATE_ALWAYS / OPEN_EXISTING
                uint flags = 0x20000000u | (write ? 0x80000000u : 0x08000000u); // NO_BUFFERING | WRITE_THROUGH / SEQUENTIAL_SCAN
                h = Native.CreateFile(path, access, 3u, IntPtr.Zero, disp, flags, IntPtr.Zero);
                if (h.IsInvalid)
                    throw new IOException("No se pudo abrir " + path + " (error Win32 " + Marshal.GetLastWin32Error() + ")");
                buf = Native.VirtualAlloc(IntPtr.Zero, new UIntPtr((ulong)bufSize), 0x3000u, 4u);
                if (buf == IntPtr.Zero) throw new OutOfMemoryException("VirtualAlloc");
            }
            else
            {
                fs = new FileStream(path, create ? FileMode.Create : FileMode.Open,
                    write ? FileAccess.ReadWrite : FileAccess.Read, FileShare.ReadWrite, 1 << 16);
            }
        }

        public int ReadAt(long offset, byte[] dest, int count, out int err)
        {
            err = 0;
            if (win)
            {
                long np; uint got;
                if (!Native.SetFilePointerEx(h, offset, out np, 0)) { err = Marshal.GetLastWin32Error(); return -1; }
                if (!Native.ReadFile(h, buf, (uint)count, out got, IntPtr.Zero)) { err = Marshal.GetLastWin32Error(); return -1; }
                if (dest != null) Marshal.Copy(buf, dest, 0, (int)got);
                return (int)got;
            }
            try
            {
                if (dest == null) { if (scratch == null) scratch = new byte[count]; dest = scratch; }
                fs.Position = offset;
                int total = 0, n;
                while (total < count && (n = fs.Read(dest, total, count - total)) > 0) total += n;
                return total;
            }
            catch (IOException) { err = -1; return -1; }
        }

        public bool WriteAt(long offset, byte[] src, int count, out int err)
        {
            err = 0;
            if (win)
            {
                Marshal.Copy(src, 0, buf, count);
                long np; uint put;
                if (!Native.SetFilePointerEx(h, offset, out np, 0)) { err = Marshal.GetLastWin32Error(); return false; }
                if (!Native.WriteFile(h, buf, (uint)count, out put, IntPtr.Zero) || put != count)
                { err = Marshal.GetLastWin32Error(); return false; }
                return true;
            }
            try { fs.Position = offset; fs.Write(src, 0, count); fs.Flush(true); return true; }
            catch (IOException) { err = -1; return false; }
        }

        public void Dispose()
        {
            if (win)
            {
                if (buf != IntPtr.Zero) Native.VirtualFree(buf, UIntPtr.Zero, 0x8000u);
                if (h != null) h.Dispose();
            }
            else if (fs != null) fs.Dispose();
        }
    }

    // Lectura de superficie (solo lectura, no destructivo)
    public sealed class DiskReader
    {
        public const int Chunk = 4 * 1024 * 1024;
        public const int Buckets = 20;
        public readonly string Path;
        public readonly long Size;
        public readonly bool Full;
        public int SamplePoints = 200;
        public int ChunksPerPoint = 16;
        public double SlowMs = 500;

        public long BytesPlanned, BytesDone;
        public int Errors, SlowChunks;
        public double WorstMs;
        public readonly List<string> ErrorList = new List<string>();
        public readonly double[] BucketBytes = new double[Buckets];
        public readonly double[] BucketSecs = new double[Buckets];
        public volatile bool StopFlag, Finished;
        public string Fatal;
        public double ElapsedSec;

        public DiskReader(string path, long size, bool full) { Path = path; Size = size; Full = full; }

        public void Start()
        {
            Thread t = new Thread(Run);
            t.IsBackground = true;
            t.Start();
        }

        void Run()
        {
            Stopwatch total = Stopwatch.StartNew();
            try
            {
                long chunks = Size / Chunk;
                List<long[]> ranges = new List<long[]>();
                if (Full || chunks <= (long)SamplePoints * ChunksPerPoint)
                    ranges.Add(new long[] { 0, chunks });
                else
                {
                    long step = chunks / SamplePoints;
                    for (int p = 0; p < SamplePoints; p++)
                    {
                        long start = p == SamplePoints - 1 ? chunks - ChunksPerPoint : p * step;
                        ranges.Add(new long[] { start, ChunksPerPoint });
                    }
                }
                foreach (long[] r in ranges) BytesPlanned += r[1] * (long)Chunk;

                using (RawFile f = new RawFile(Path, false, false, Chunk))
                {
                    Stopwatch sw = new Stopwatch();
                    foreach (long[] r in ranges)
                    {
                        for (long c = r[0]; c < r[0] + r[1]; c++)
                        {
                            if (StopFlag) return;
                            long off = c * Chunk;
                            int err;
                            sw.Restart();
                            int n = f.ReadAt(off, null, Chunk, out err);
                            double ms = sw.Elapsed.TotalMilliseconds;
                            if (n < Chunk)
                            {
                                Errors++;
                                lock (ErrorList)
                                    ErrorList.Add(string.Format("{0:F2} GB: lectura fallida (error {1}, {2} bytes)", off / 1e9, err, n));
                                if (Errors >= 100) { Fatal = "Mas de 100 errores de lectura, se corto el test."; return; }
                                BytesDone += Chunk;
                                continue;
                            }
                            BytesDone += n;
                            int b = (int)(off * Buckets / Size);
                            if (b >= Buckets) b = Buckets - 1;
                            BucketBytes[b] += n; BucketSecs[b] += ms / 1000.0;
                            if (ms > WorstMs) WorstMs = ms;
                            if (ms > SlowMs) SlowChunks++;
                        }
                    }
                }
            }
            catch (Exception e) { Fatal = e.GetType().Name + ": " + e.Message; }
            finally { ElapsedSec = total.Elapsed.TotalSeconds; Finished = true; }
        }
    }

    // Escritura + verificacion por archivos (tipo H2testw). No toca datos existentes.
    public sealed class FillVerify
    {
        public const int Chunk = 4 * 1024 * 1024;
        public readonly long FileSize;
        public readonly string Dir;
        public int Files;
        public int Phase;               // 1 escribiendo, 2 verificando
        public int CurrentFile;
        public int FilesWritten;
        public long BytesWritten, BytesVerified;
        public int IoErrors, BadChunks;
        public long BadWords;
        public readonly List<string> ErrorList = new List<string>();
        public double[] WriteMBs, ReadMBs;
        public volatile bool StopFlag, Finished;
        public string Fatal;
        public bool SkipWrite;   // solo para pruebas del motor

        public FillVerify(string dir, int files, long fileSize)
        {
            Dir = dir; Files = files; FileSize = fileSize;
            WriteMBs = new double[files]; ReadMBs = new double[files];
        }

        public string FileName(int f) { return System.IO.Path.Combine(Dir, string.Format("NETTEST_{0:D4}.bin", f)); }

        public void Start()
        {
            Thread t = new Thread(Run);
            t.IsBackground = true;
            t.Start();
        }

        static void Fill(ulong[] tmp, int file, long chunk)
        {
            ulong s = ((ulong)(uint)file << 32) ^ (ulong)chunk ^ 0xA5A5F00DCAFEBEEFUL;
            s += 0x9E3779B97F4A7C15UL; s = (s ^ (s >> 30)) * 0xBF58476D1CE4E5B9UL;
            s = (s ^ (s >> 27)) * 0x94D049BB133111EBUL; s ^= s >> 31;
            if (s == 0) s = 1;
            for (int i = 0; i < tmp.Length; i++)
            {
                s ^= s << 13; s ^= s >> 7; s ^= s << 17;
                tmp[i] = s;
            }
        }

        void AddError(string e) { lock (ErrorList) { if (ErrorList.Count < 200) ErrorList.Add(e); } }

        void Run()
        {
            byte[] bytes = new byte[Chunk];
            ulong[] words = new ulong[Chunk / 8];
            ulong[] got = new ulong[Chunk / 8];
            long chunksPerFile = FileSize / Chunk;
            Stopwatch sw = new Stopwatch();
            try
            {
                Phase = 1;
                if (SkipWrite) FilesWritten = Files;
                for (int f = 0; f < Files && !StopFlag && !SkipWrite; f++)
                {
                    CurrentFile = f;
                    bool full = false;
                    sw.Restart();
                    using (RawFile rf = new RawFile(FileName(f), true, true, Chunk))
                    {
                        for (long c = 0; c < chunksPerFile && !StopFlag; c++)
                        {
                            Fill(words, f, c);
                            Buffer.BlockCopy(words, 0, bytes, 0, Chunk);
                            int err;
                            if (!rf.WriteAt(c * Chunk, bytes, Chunk, out err))
                            {
                                if (err == 112 || err == 39) { full = true; break; } // disco lleno
                                IoErrors++;
                                AddError(string.Format("Archivo {0}, {1} MB: error de escritura {2}", f, c * 4, err));
                                if (IoErrors > 50) { Fatal = "Demasiados errores de escritura."; return; }
                            }
                            BytesWritten += Chunk;
                        }
                    }
                    if (full) { Fatal = "Disco lleno antes de lo previsto (se verifica lo escrito)."; break; }
                    WriteMBs[f] = (chunksPerFile * (double)Chunk / 1048576.0) / Math.Max(sw.Elapsed.TotalSeconds, 0.001);
                    FilesWritten = f + 1;
                }

                Phase = 2;
                for (int f = 0; f < FilesWritten && !StopFlag; f++)
                {
                    CurrentFile = f;
                    sw.Restart();
                    using (RawFile rf = new RawFile(FileName(f), false, false, Chunk))
                    {
                        for (long c = 0; c < chunksPerFile && !StopFlag; c++)
                        {
                            int err;
                            int n = rf.ReadAt(c * Chunk, bytes, Chunk, out err);
                            if (n != Chunk)
                            {
                                IoErrors++;
                                AddError(string.Format("Archivo {0}, {1} MB: error de lectura {2}", f, c * 4, err));
                                BytesVerified += Chunk;
                                continue;
                            }
                            Fill(words, f, c);
                            Buffer.BlockCopy(bytes, 0, got, 0, Chunk);
                            long bad = 0;
                            for (int i = 0; i < got.Length; i++) if (got[i] != words[i]) bad++;
                            if (bad > 0)
                            {
                                BadChunks++; BadWords += bad;
                                AddError(string.Format("Archivo {0}, {1} MB: {2} bloques de 8 bytes NO coinciden", f, c * 4, bad));
                            }
                            BytesVerified += Chunk;
                        }
                    }
                    ReadMBs[f] = (chunksPerFile * (double)Chunk / 1048576.0) / Math.Max(sw.Elapsed.TotalSeconds, 0.001);
                }
            }
            catch (Exception e) { Fatal = e.GetType().Name + ": " + e.Message; }
            finally { Finished = true; }
        }

        public int Cleanup()
        {
            int n = 0;
            for (int f = 0; f < Files; f++)
            {
                try { if (File.Exists(FileName(f))) { File.Delete(FileName(f)); n++; } } catch { }
            }
            return n;
        }
    }
}
'@

if (-not ('NetBench.StressRun' -as [type])) {
    Add-Type -TypeDefinition $EngineSource -Language CSharp
}

# ======================================================================
#  Utilidades: reporte, veredictos, preguntas
# ======================================================================
$ReportDir = Join-Path $Root 'Reportes'
$Global:LogBuffer = New-Object System.Collections.Generic.List[string]
$Global:OutputMoved = $false

# Disco físico donde está el programa (pendrive): no se le mandan comandos ni se le escribe de prueba
function Get-OwnDisk {
    if ($null -ne $Global:OwnDiskCache) { return $Global:OwnDiskCache }
    $r = [pscustomobject]@{ Letra = ''; Numero = -1 }
    try {
        $q = [IO.Path]::GetPathRoot($Root)
        if ($q -match '^([A-Za-z]):') {
            $r.Letra = $Matches[1].ToUpper()
            $r.Numero = [int](Get-Partition -DriveLetter $r.Letra -ErrorAction Stop | Get-Disk -ErrorAction Stop).Number
        }
    } catch {}
    $Global:OwnDiskCache = $r
    return $r
}
$MarkerFile = Join-Path $ReportDir '_prueba_en_curso.txt'
$Global:ReportFile = $null
$Global:Verdicts = [ordered]@{}
$Global:Pendientes = New-Object System.Collections.ArrayList
$Rank = @{ 'OK' = 0; 'INFO' = 0; 'ATENCION' = 1; 'FALLA' = 2 }

# ---- Modo interfaz: todo lo que se escribe o se pregunta pasa también por la ventana
$Global:UiMode = $false
$Global:Ui = $null
$Global:UiLastPub = [datetime]::MinValue

function Ui-Log([string]$Text, [string]$Color) {
    if ($Global:UiMode -and $Global:Ui) {
        $Global:Ui.AddLog($Text, $Color)
        Ui-MaybePublish
    }
}

function Ui-MaybePublish {
    if ($Global:UiMode -and ((Get-Date) - $Global:UiLastPub).TotalMilliseconds -gt 1500) { Ui-Publish }
}

function Ui-Publish {
    if (-not ($Global:UiMode -and $Global:Ui)) { return }
    $Global:UiLastPub = Get-Date
    try { $Global:Ui.Snapshot = (Get-UiSnapshot | ConvertTo-Json -Depth 6 -Compress) } catch {}
}

function Ui-Prompt([string]$Kind, [string]$Question, [string]$Default, $Extra) {
    $ej = if ($null -ne $Extra) { ConvertTo-Json -InputObject $Extra -Depth 5 -Compress } else { $null }
    Ui-Publish
    $a = $Global:Ui.Ask($Kind, $Question, $Default, $ej)
    Ui-Log ("  > {0}: {1}" -f $Question, $a) 'DarkGray'
    return $a
}

function Write-Host {
    param([Parameter(Position = 0, ValueFromRemainingArguments = $true)] $Object, $ForegroundColor, [switch]$NoNewline)
    $txt = (@($Object) | ForEach-Object { [string]$_ }) -join ' '
    if ($Global:UiMode) { Ui-Log $txt $(if ($ForegroundColor) { [string]$ForegroundColor } else { 'Gray' }) }
    if ($ForegroundColor) { Microsoft.PowerShell.Utility\Write-Host $txt -ForegroundColor $ForegroundColor -NoNewline:$NoNewline }
    else { Microsoft.PowerShell.Utility\Write-Host $txt -NoNewline:$NoNewline }
}

function Write-Progress {
    param([Parameter(Position = 0)][string]$Activity, [Parameter(Position = 1)][string]$Status, [int]$PercentComplete = -1, [switch]$Completed, [int]$Id = 0)
    if ($Global:UiMode -and $Global:Ui) {
        if ($Completed) { $Global:Ui.ClearProgress() } else { $Global:Ui.SetProgress($Activity, $Status, $PercentComplete) }
        Ui-MaybePublish
        return
    }
    $p = @{ Activity = $(if ($Activity) { $Activity } else { ' ' }) }
    if ($Status) { $p.Status = $Status }
    if ($PercentComplete -ge 0) { $p.PercentComplete = $PercentComplete }
    if ($Completed) { $p.Completed = $true }
    Microsoft.PowerShell.Utility\Write-Progress @p
}

function Log {
    param([string]$Text = '', [string]$Color = 'Gray', [switch]$NoFile)
    Microsoft.PowerShell.Utility\Write-Host $Text -ForegroundColor $Color
    Ui-Log $Text $Color
    if (-not $NoFile) {
        $Global:LogBuffer.Add($Text)
        if ($Global:ReportFile) { try { Add-Content -Path $Global:ReportFile -Value $Text -Encoding UTF8 -ErrorAction Stop } catch {} }
    }
}

function Section([string]$Title) {
    Log ''
    Log ('=' * 78) 'Cyan'
    Log ("  $Title") 'Cyan'
    Log ('=' * 78) 'Cyan'
}

# GeForce RTX 5050-5090 (no las RTX 5000 Ada ni las Quadro RTX 5000, que son de otra generación)
function Test-Rtx50([string]$Nombre) { return [bool]($Nombre -match 'RTX\s*50[5-9]0') }

function Set-Verdict {
    param([string]$Area, [string]$Estado, [string]$Detalle)
    if (-not $Global:Verdicts.Contains($Area)) {
        $Global:Verdicts[$Area] = [pscustomobject]@{ Estado = 'OK'; Detalles = (New-Object System.Collections.ArrayList) }
    }
    $v = $Global:Verdicts[$Area]
    if ($Rank[$Estado] -gt $Rank[$v.Estado]) { $v.Estado = $Estado }
    if ($Detalle) {
        $item = "[$Estado] $Detalle"
        if ($v.Detalles.Contains($item)) { return }   # mismo aviso de una corrida anterior
        [void]$v.Detalles.Add($item)
        $color = switch ($Estado) { 'FALLA' { 'Red' } 'ATENCION' { 'Yellow' } 'INFO' { 'DarkCyan' } default { 'Green' } }
        Log ("  -> [{0}] {1}" -f $Estado, $Detalle) $color
    }
}

function Add-Pendiente([string]$Texto) {
    if (-not $Global:Pendientes.Contains($Texto)) { [void]$Global:Pendientes.Add($Texto) }
}

function Ask([string]$Prompt, $Default) {
    if ($Global:UiMode) { return [string](Ui-Prompt 'text' $Prompt ([string]$Default) $null) }
    $a = Read-Host ("{0} [{1}]" -f $Prompt, $Default)
    if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
    return $a.Trim()
}

function Ask-Int([string]$Prompt, [int]$Default, [int]$Min = 1, [int]$Max = 100000) {
    if ($Global:UiMode) {
        $a = Ui-Prompt 'int' $Prompt ([string]$Default) @{ min = $Min; max = $Max }
        $n = 0
        if ([int]::TryParse([string]$a, [ref]$n)) { return [math]::Min($Max, [math]::Max($Min, $n)) }
        return $Default
    }
    while ($true) {
        $a = Ask $Prompt $Default
        $n = 0
        if ([int]::TryParse([string]$a, [ref]$n) -and $n -ge $Min -and $n -le $Max) { return $n }
        Write-Host "  Valor inválido ($Min a $Max)." -ForegroundColor Yellow
    }
}

function Ask-Yes([string]$Prompt, [bool]$Default = $false) {
    $d = if ($Default) { 'S' } else { 'N' }
    if ($Global:UiMode) { return ([string](Ui-Prompt 'yesno' $Prompt $d $null) -match '^[sSyY]') }
    $a = Ask "$Prompt (S/N)" $d
    return ($a -match '^[sSyY]')
}

# Opciones con descripción: en consola se elige por número/letra, en la interfaz con botones
function Ask-Choice([string]$Prompt, [object[]]$Options, $Default) {
    if ($Global:UiMode) {
        $ops = @($Options | ForEach-Object { @{ v = [string]$_.Value; l = [string]$_.Label; d = [string]$_.Desc } })
        return [string](Ui-Prompt 'choice' $Prompt ([string]$Default) $ops)
    }
    foreach ($o in $Options) { Write-Host ("   {0}) {1}{2}" -f $o.Value, $o.Label, $(if ($o.Desc) { '  - ' + $o.Desc } else { '' })) }
    $vals = @($Options | ForEach-Object { [string]$_.Value })
    while ($true) {
        $a = [string](Ask $Prompt $Default)
        if ($vals -contains $a) { return $a }
        Write-Host '  Opción inválida.' -ForegroundColor Yellow
    }
}

function Test-KeyQ {
    if ($Global:UiMode) { return [bool]($Global:Ui -and $Global:Ui.Cancel) }
    try {
        while ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.Key -eq 'Q' -or $k.Key -eq 'Escape') { return $true }
        }
    } catch {}
    return $false
}

function Set-Marker([string]$What) {
    try {
        New-Item -ItemType Directory -Force -Path $ReportDir -ErrorAction SilentlyContinue | Out-Null
        ("{0}|{1}|{2}" -f (Get-Date -Format 's'), $What, $Global:ReportFile) | Set-Content -Path $MarkerFile -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {}
}
function Clear-Marker { Remove-Item -Path $MarkerFile -ErrorAction SilentlyContinue }

function Format-Bytes([double]$b) {
    if ($b -ge 1e12) { return ('{0:N2} TB' -f ($b / 1e12)) }
    if ($b -ge 1e9) { return ('{0:N1} GB' -f ($b / 1e9)) }
    return ('{0:N0} MB' -f ($b / 1e6))
}

function Get-Clean([string]$s) {
    if (-not $s) { return '' }
    return ($s -replace '\(R\)|\(TM\)|®|™', '' -replace '\s+', ' ').Trim()
}

# ======================================================================
#  Sesión anterior cortada (cuelgue / reinicio durante una prueba)
# ======================================================================
function Test-PreviousSession {
    if (-not (Test-Path $MarkerFile)) { return }
    $raw = (Get-Content -Path $MarkerFile -Raw -ErrorAction SilentlyContinue)
    if (-not $raw) { Clear-Marker; return }
    $p = $raw.Trim() -split '\|', 3
    Write-Host ''
    Write-Host ('!' * 78) -ForegroundColor Red
    Write-Host '  LA SESIÓN ANTERIOR NO TERMINÓ' -ForegroundColor Red
    Write-Host ("  Se cortó durante: {0}" -f $p[1]) -ForegroundColor Red
    Write-Host ("  Inicio de esa prueba: {0}" -f $p[0]) -ForegroundColor Red
    Write-Host '  Si la PC se colgó, se apagó o reinició sola, ESO ES UNA FALLA de esa prueba.' -ForegroundColor Red
    Write-Host ('!' * 78) -ForegroundColor Red
    if ($p.Count -ge 3 -and $p[2] -and (Test-Path $p[2])) {
        Add-Content -Path $p[2] -Encoding UTF8 -Value @('', ('*' * 78),
            ("*** PRUEBA INTERRUMPIDA: la PC se colgó/reinició durante: {0} (iniciada {1})" -f $p[1], $p[0]),
            ('*' * 78))
        Write-Host ("  Se anotó en el reporte anterior: {0}" -f $p[2]) -ForegroundColor Yellow
    }
    $Global:SesionCortada = $p[1]
    Clear-Marker
    if (-not $Global:UiMode) { Read-Host '  Enter para continuar' | Out-Null }
}

# ======================================================================
#  Inventario
# ======================================================================
function Get-Microcode {
    try {
        $k = Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -ErrorAction Stop
        foreach ($name in 'Update Revision', 'Previous Update Revision') {
            $b = $k.$name
            if ($null -eq $b) { continue }
            $v = [uint64]0
            if ($b -is [byte[]]) {
                if ($b.Length -ge 8) {
                    $v = [BitConverter]::ToUInt32($b, 4)
                    if ($v -eq 0) { $v = [BitConverter]::ToUInt32($b, 0) }
                } elseif ($b.Length -ge 4) { $v = [BitConverter]::ToUInt32($b, 0) }
            } elseif ($b -is [int] -or $b -is [long]) { $v = [uint64]([long]$b -band 0xFFFFFFFFL) }
            if ($v -ne 0) { return ('0x{0:X}' -f $v) }
        }
    } catch {}
    return $null
}

function Get-CpuInfo {
    $c = Get-CimInstance Win32_Processor | Select-Object -First 1
    [pscustomobject]@{
        Nombre    = Get-Clean $c.Name
        Nucleos   = [int]$c.NumberOfCores
        Hilos     = [int]$c.NumberOfLogicalProcessors
        BaseMHz   = [int]$c.MaxClockSpeed
        Socket    = $c.SocketDesignation
        L2KB      = $c.L2CacheSize
        L3KB      = $c.L3CacheSize
        Microcode = Get-Microcode
    }
}

function Get-CoreLabel([int]$Logical) {
    $c = $Global:Cpu
    if (-not $c -or $c.Nucleos -le 0) { return '' }
    if ($c.Hilos -eq 2 * $c.Nucleos) { return ('núcleo {0}' -f [math]::Floor($Logical / 2)) }
    if ($c.Hilos -eq $c.Nucleos) { return ('núcleo {0}' -f $Logical) }
    # Intel híbrido con HT: los P-cores (2 hilos c/u) van primero, después los E-cores
    $p = $c.Hilos - $c.Nucleos
    if ($p -gt 0 -and $p -lt $c.Nucleos) {
        if ($Logical -lt 2 * $p) { return ('P-core {0}' -f [math]::Floor($Logical / 2)) }
        return ('E-core {0}' -f ($Logical - 2 * $p))
    }
    return ''
}

function Start-Report([string]$Etiqueta) {
    $Global:LogBuffer.Clear()
    New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
    $cpuName = if ($Global:Cpu) { $Global:Cpu.Nombre } else { 'PC' }
    $short = $cpuName
    if ($cpuName -match '(i[3579]-\w+|Ryzen \d+ (PRO )?\w+|Ultra \d \w+|Xeon \S+|Athlon \S+|Pentium \S+|Celeron \S+)') { $short = $Matches[1] }
    $parts = @((Get-Date -Format 'yyyyMMdd-HHmm'))
    if ($Etiqueta) { $parts += $Etiqueta }
    if ($Global:M.Pieza) { $parts += ('SN' + $Global:M.Pieza) }
    $parts += $short
    $name = (($parts -join '_') -replace '[\\/:*?"<>|]', '' -replace '\s+', '-') + '.txt'
    $det = Join-Path $ReportDir 'detalle'
    New-Item -ItemType Directory -Force -Path $det | Out-Null
    $Global:ReportFile = Join-Path $det $name
    Log ("NET Gaming - Banco de pruebas v{0}" -f $Version) 'White'
    try { Sync-Historial } catch {}
    if ($env:NETBENCH_ACTUALIZADO -and -not $Global:AvisoActualizacion) {
        $Global:AvisoActualizacion = $true
        $pz = $env:NETBENCH_ACTUALIZADO -split '\|', 3
        Log ("Programa actualizado solo: v{0} -> v{1}.{2}" -f $pz[0], $pz[1], $(if ($pz.Count -gt 2 -and $pz[2]) { ' Cambios: ' + $pz[2] } else { '' })) 'Green'
    }
    Log ("Fecha: {0}   Equipo/orden: {1}   PC: {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm'), $(if ($Etiqueta) { $Etiqueta } else { '-' }), $env:COMPUTERNAME)
    if ($Global:M.Suelta) { Log ("Placa de video suelta, probada en el banco{0}{1}. El inventario de abajo es el del banco." -f $(if ($Global:M.Pieza) { " | N.º de serie termina en $($Global:M.Pieza)" } else { '' }), $(if ($Global:M.Grupo) { " | va junto con el ticket $($Global:M.Grupo)" } else { '' })) 'White' }
    if ($Global:SesionCortada) {
        Log ("ANTECEDENTE: la sesión anterior se cortó durante '{0}' (posible cuelgue/reinicio)." -f $Global:SesionCortada) 'Red'
        if ($Global:SesionCortada -match 'fuente') {
            Set-Verdict 'Fuente' 'FALLA' 'La PC se apagó o se reinició durante la prueba de fuente (CPU y GPU al 100%): la fuente no sostiene el consumo del equipo (o se activó una protección por temperatura).'
            $Global:M.Fuente['Res'] = 'se apagó'
            Add-Prueba 'Fuente: CPU + GPU al 100%' $null 'FALLA' 'la PC se apagó o reinició durante la prueba'
        }
        $Global:SesionCortadaUsada = $Global:SesionCortada
        $Global:SesionCortada = $null      # el antecedente va solo en el primer equipo después del corte
    }
}

function Show-Inventario {
    Section 'INVENTARIO'
    $c = $Global:Cpu
    $bb = Get-CimInstance Win32_BaseBoard | Select-Object -First 1
    $bios = Get-CimInstance Win32_BIOS | Select-Object -First 1
    $os = Get-CimInstance Win32_OperatingSystem
    $mods = @(Get-CimInstance Win32_PhysicalMemory)
    # sin los adaptadores virtuales (visor de realidad virtual, escritorio remoto, monitores virtuales): no son placas
    $gpus = @(Get-CimInstance Win32_VideoController | Where-Object { [string]$_.Name -notmatch 'Virtual|Parsec|IddCx|Idd Sample|Remote Display|DisplayLink|spacedesk|Citrix|Mirror Driver|TeamViewer|AnyDesk|Sunshine' })
    $Global:Boot = $os.LastBootUpTime

    Log ("CPU     : {0}" -f $c.Nombre) 'White'
    Log ("          {0} núcleos / {1} hilos | base {2} MHz | L2 {3} KB | L3 {4} KB | socket {5} | microcode {6}" -f `
            $c.Nucleos, $c.Hilos, $c.BaseMHz, $c.L2KB, $c.L3KB, $c.Socket, $(if ($c.Microcode) { $c.Microcode } elseif ($c.Nombre -match 'AMD') { 'n/d (en AMD mirar la versión AGESA del BIOS)' } else { 'n/d' }))
    Log '          >>> Compará núcleos/hilos con la ficha oficial del modelo: si faltan, hay núcleos o un CCD deshabilitado.' 'Yellow'
    Log ("Mother  : {0} {1} {2}" -f (Get-Clean $bb.Manufacturer), (Get-Clean $bb.Product), $(if ($bb.Version) { "(rev $($bb.Version))" })) 'White'
    $bdate = $null
    if ($bios.ReleaseDate) { $bdate = [datetime]$bios.ReleaseDate }
    Log ("BIOS    : {0} {1}" -f $bios.SMBIOSBIOSVersion, $(if ($bdate) { '(' + $bdate.ToString('yyyy-MM-dd') + ')' }))
    $tot = ($mods | Measure-Object -Property Capacity -Sum).Sum
    Log ("RAM     : {0} GB en {1} módulo(s)" -f [math]::Round($tot / 1GB), $mods.Count) 'White'
    foreach ($g in $gpus) { Log ("GPU     : {0} (driver {1})" -f (Get-Clean $g.Name), $g.DriverVersion) }
    $types = @{ 24 = 'DDR3'; 26 = 'DDR4'; 34 = 'DDR5'; 30 = 'LPDDR4'; 35 = 'LPDDR5' }
    $mts = ($mods | Measure-Object -Property ConfiguredClockSpeed -Maximum).Maximum
    $rt = if ($mods.Count) { $types[[int]$mods[0].SMBIOSMemoryType] } else { '' }
    $Global:M.Equipo['Mother'] = ('{0} {1}' -f (Get-Clean $bb.Manufacturer), (Get-Clean $bb.Product)).Trim()
    $Global:M.Equipo['BIOS'] = ('{0}{1}' -f $bios.SMBIOSBIOSVersion, $(if ($bdate) { ' (' + $bdate.ToString('yyyy-MM-dd') + ')' })).Trim()
    $Global:M.Equipo['RamGB'] = [math]::Round($tot / 1GB)
    $Global:M.Equipo['RamMTs'] = $mts
    $Global:M.Equipo['RamTipo'] = $rt
    $Global:M.Equipo['RamTexto'] = ('{0} GB {1} a {2} MT/s ({3} módulo{4})' -f [math]::Round($tot / 1GB), $rt, $mts, $mods.Count, $(if ($mods.Count -ne 1) { 's' })) -replace '\s+', ' '
    $Global:M.Equipo['GPU'] = @($gpus | ForEach-Object { Get-Clean $_.Name })
    try {
        foreach ($d in (Get-Disk | Sort-Object Number)) {
            Log ("Disco {0} : {1} | {2} | {3} | SN {4}" -f $d.Number, (Get-Clean $d.FriendlyName), $d.BusType, (Format-Bytes $d.Size), ($d.SerialNumber -replace '\s', ''))
            if ([string]$d.BusType -ne 'USB') { Update-DiscoMetric (Get-Clean $d.FriendlyName) @{ Capacidad = (Format-Bytes $d.Size); Bus = [string]$d.BusType } }
        }
    } catch {}
    Log ("Windows : {0} (build {1}) | arranque: {2}" -f $os.Caption, $os.BuildNumber, $Global:Boot)
}

# ======================================================================
#  Chequeo de salud
# ======================================================================
function Test-RaptorLake {
    $c = $Global:Cpu
    if ($c.Nombre -notmatch 'i[3579]-1[34]\d{3}([A-Z]*)') { return }
    $suf = $Matches[1]
    if ($suf -match '[HUP]') { return }   # notebooks: fuera del problema de degradación de escritorio
    Set-Verdict 'CPU' 'INFO' 'Intel 13ª/14ª gen de escritorio: familia con degradación por voltaje (Vmin shift). Síntomas: crashes compilando shaders, errores de descompresión, "out of video memory" en juegos Unreal.'
    if ($c.Microcode -match '^0x([0-9A-F]+)$') {
        $v = [Convert]::ToUInt32($Matches[1], 16)
        if ($v -lt 0x12B) {
            Set-Verdict 'CPU' 'ATENCION' ("Microcode {0} anterior a 0x12B: actualizar BIOS antes de entregar. Ojo: el BIOS nuevo frena la degradación pero NO repara un CPU ya degradado." -f $c.Microcode)
        } else {
            Set-Verdict 'CPU' 'INFO' ("Microcode {0} (0x12B o posterior): OK en ese aspecto." -f $c.Microcode)
        }
    }
    Add-Pendiente 'Raptor Lake: correr el test por núcleo en modo profundo (180 s) + Intel Processor Diagnostic Tool. Un núcleo que falla solo = CPU degradado.'
}

function Get-SystemEvents([datetime]$Desde) {
    try {
        return @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $Desde; Level = 1, 2, 3 } -MaxEvents 3000 -ErrorAction Stop)
    } catch { return @() }
}

function Get-WheaSince([datetime]$Desde) {
    try {
        return @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = $Desde } -ErrorAction Stop)
    } catch { return @() }
}

function Get-EventLine($e) {
    $msg = ''
    try { $msg = (($e.Message -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -First 3) -join ' / ' } catch {}
    if ($msg.Length -gt 170) { $msg = $msg.Substring(0, 170) + '...' }
    return ("{0:dd/MM HH:mm:ss}  ID {1,-4} {2}" -f $e.TimeCreated, $e.Id, $msg)
}

function Show-Whea($events, [switch]$DuranteTest) {
    foreach ($e in $events) { Log ('    ' + (Get-EventLine $e)) 'Red' }
    $grave = if ($DuranteTest) { 'FALLA' } else { 'ATENCION' }
    $ids = @($events | ForEach-Object { $_.Id } | Sort-Object -Unique)
    foreach ($id in $ids) {
        $n = @($events | Where-Object { $_.Id -eq $id }).Count
        switch ($id) {
            18 { Set-Verdict 'CPU' 'FALLA' "WHEA 18 (error fatal de hardware) x$n." }
            19 { Set-Verdict 'CPU' $grave "WHEA 19 (error de CPU/caché/fabric corregido) x$n. En stock no debería aparecer nunca." }
            20 { Set-Verdict 'CPU' $grave "WHEA 20 x$n." }
            17 { Set-Verdict 'Motherboard' 'ATENCION' "WHEA 17 (PCIe corregido) x$($n): slot, riser, placa o NVMe con enlace inestable." }
            47 { Set-Verdict 'RAM' $grave "WHEA 47 (memoria corregido) x$n." }
            1 { Set-Verdict 'Plataforma' 'ATENCION' "WHEA 1 (BERT): hubo un error fatal en un arranque anterior." }
            default { Set-Verdict 'Plataforma' 'ATENCION' "WHEA ID $id x$n." }
        }
    }
}

function Show-Eventos([datetime]$Desde, [string]$Titulo) {
    Section $Titulo
    $ev = Get-SystemEvents $Desde
    $whea = @($ev | Where-Object { $_.ProviderName -eq 'Microsoft-Windows-WHEA-Logger' })
    $crash = @($ev | Where-Object {
            ($_.ProviderName -eq 'Microsoft-Windows-WER-SystemErrorReporting' -and $_.Id -eq 1001) -or
            ($_.ProviderName -eq 'Microsoft-Windows-Kernel-Power' -and $_.Id -eq 41) -or
            ($_.ProviderName -eq 'EventLog' -and $_.Id -eq 6008) })
    $diskProv = 'disk', 'stornvme', 'storahci', 'storport', 'nvme', 'iaStorAC', 'iaStorVD', 'iaStorA'
    $disk = @($ev | Where-Object { (($diskProv -contains $_.ProviderName) -or ($_.ProviderName -eq 'Ntfs' -and $_.Level -le 2)) -and -not ($_.ProviderName -eq 'disk' -and $_.Id -eq 158) })
    $dup = @($ev | Where-Object { $_.ProviderName -eq 'disk' -and $_.Id -eq 158 })
    if ($dup.Count) { Log ("  Evento 158 (disco con identificador duplicado) x{0}: suele ser un pendrive que se reconectó o un disco clonado. No es una falla." -f $dup.Count) 'DarkGray' }

    Log ("Eventos desde {0}: WHEA {1} | apagados/BSOD {2} | disco/almacenamiento {3}" -f $Desde, $whea.Count, $crash.Count, $disk.Count)
    if ($whea.Count) { Show-Whea $whea } else { Set-Verdict 'CPU' 'OK' '' }
    if ($crash.Count) {
        foreach ($e in ($crash | Select-Object -First 5)) { Log ('    ' + (Get-EventLine $e)) 'Yellow' }
        Set-Verdict 'Plataforma' 'ATENCION' ("Hay {0} evento(s) de apagado inesperado/BSOD (41/1001/6008) en este período." -f $crash.Count)
    }
    if ($disk.Count) {
        foreach ($e in ($disk | Select-Object -First 8)) { Log ('    ' + $e.ProviderName + ' ' + (Get-EventLine $e)) 'Yellow' }
        Set-Verdict 'Discos' 'ATENCION' ("{0} evento(s) de error/advertencia de almacenamiento (bloques malos, resets de controlador, reintentos). Ver arriba qué disco." -f $disk.Count)
    }
}

function Show-Ram {
    Section 'RAM (slots y configuración)'
    $mods = @(Get-CimInstance Win32_PhysicalMemory)
    $arr = Get-CimInstance Win32_PhysicalMemoryArray -ErrorAction SilentlyContinue | Select-Object -First 1
    $types = @{ 20 = 'DDR'; 21 = 'DDR2'; 24 = 'DDR3'; 26 = 'DDR4'; 34 = 'DDR5'; 29 = 'LPDDR3'; 30 = 'LPDDR4'; 35 = 'LPDDR5' }
    foreach ($m in $mods) {
        $t = $types[[int]$m.SMBIOSMemoryType]
        Log ("  {0,-14} {1,-10} {2,3} GB  {3,-5} nominal {4,5} MT/s  actual {5,5} MT/s  {6} {7}" -f `
                $m.DeviceLocator, $m.BankLabel, [math]::Round($m.Capacity / 1GB), $t, $m.Speed, $m.ConfiguredClockSpeed, (Get-Clean $m.Manufacturer), ($m.PartNumber -replace '\s+$', ''))
    }
    if ($arr -and $arr.MemoryDevices) { Log ("  Slots usados: {0} de {1}" -f $mods.Count, $arr.MemoryDevices) }
    $inst = ($mods | Measure-Object -Property Capacity -Sum).Sum
    $vis = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
    if ($inst -gt 0) {
        $pct = 100 * $vis / $inst
        Log ("  Instalada {0:N1} GB | utilizable por Windows {1:N1} GB ({2:N0}%)" -f ($inst / 1GB), ($vis / 1GB), $pct)
        if ($pct -lt 85) { Set-Verdict 'RAM' 'ATENCION' 'Mucha memoria "reservada para hardware": revisar si un módulo/canal no levanta bien o el reparto de la iGPU.' }
    }
    $pns = @($mods | ForEach-Object { ($_.PartNumber -replace '\s', '') } | Sort-Object -Unique)
    if ($pns.Count -gt 1) { Set-Verdict 'RAM' 'INFO' 'Módulos con distinto part number: kit mezclado, probar estabilidad con más cuidado.' }
    $slow = @($mods | Where-Object { $_.ConfiguredClockSpeed -and $_.Speed -and $_.ConfiguredClockSpeed -lt $_.Speed })
    if ($slow.Count) { Set-Verdict 'RAM' 'INFO' 'La RAM corre por debajo de su velocidad nominal (JEDEC, sin XMP/EXPO). Probar primero así y después con XMP/EXPO.' }
    if (-not $Global:M.Ram['Tm5Res']) { Add-Pendiente 'RAM: TestMem5 (paso 6, automático) con XMP/EXPO activado; en DDR5 el ECC interno del chip esconde errores leves, así que el test con XMP/EXPO es el que vale.' }
    Add-Pendiente 'Mother/RAM: probar cada slot DIMM (un módulo por vez en cada slot, o rotar los módulos) para descartar slot o canal muerto.'
}

function Get-PcieGen($v) {
    switch ([int]$v) { 1 { 'Gen1' } 2 { 'Gen2' } 3 { 'Gen3' } 4 { 'Gen4' } 5 { 'Gen5' } 6 { 'Gen6' } default { '?' } }
}

function Show-Mother {
    Section 'MOTHERBOARD (BIOS, enlaces PCIe, dispositivos, red)'
    $bios = Get-CimInstance Win32_BIOS | Select-Object -First 1
    if ($bios.ReleaseDate) {
        $age = ((Get-Date) - [datetime]$bios.ReleaseDate).TotalDays / 365
        if ($age -gt 3) { Set-Verdict 'Motherboard' 'INFO' ("BIOS de hace {0:N1} años: considerar actualizar (compatibilidad de CPU, AGESA/microcode, estabilidad)." -f $age) }
    }

    # Enlaces PCIe
    $keys = 'DEVPKEY_PciDevice_CurrentLinkSpeed', 'DEVPKEY_PciDevice_MaxLinkSpeed', 'DEVPKEY_PciDevice_CurrentLinkWidth', 'DEVPKEY_PciDevice_MaxLinkWidth'
    $devs = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
            $_.InstanceId -like 'PCI\*' -and @('Display', 'SCSIAdapter', 'Net', 'HDC', 'USB', 'MEDIA') -contains $_.Class })
    $shown = 0
    Log 'Enlaces PCIe (actual / máximo del dispositivo):'
    foreach ($d in $devs) {
        $h = @{}
        foreach ($x in @(Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName $keys -ErrorAction SilentlyContinue)) { $h[$x.KeyName] = $x.Data }
        $mw = $h['DEVPKEY_PciDevice_MaxLinkWidth']; $cw = $h['DEVPKEY_PciDevice_CurrentLinkWidth']
        $ms = $h['DEVPKEY_PciDevice_MaxLinkSpeed']; $cs = $h['DEVPKEY_PciDevice_CurrentLinkSpeed']
        if (-not $mw -or -not $cw) { continue }
        $shown++
        $line = "  {0,-48} x{1,-2}/x{2,-2}  {3}/{4}" -f (Get-Clean $d.FriendlyName), $cw, $mw, (Get-PcieGen $cs), (Get-PcieGen $ms)
        $col = 'Gray'
        if ([int]$cw -lt [int]$mw) {
            $col = 'Yellow'
            $apu8000 = $Global:Cpu -and $Global:Cpu.Nombre -match 'Ryzen \d \d*8\d{2}0?GE?\b|Ryzen \d 8\d{3}G'
            if ($d.Class -eq 'Display' -and $apu8000 -and $d.FriendlyName -notmatch '7[0-9]0M|Radeon \d{3}M') {
                Set-Verdict 'Motherboard' 'INFO' ("{0} a x{1} de x{2}: con Ryzen 8000G el slot de video trabaja a x8 o x4 según el CPU. Es normal." -f (Get-Clean $d.FriendlyName), $cw, $mw)
            } elseif ($d.Class -eq 'Display') {
                Set-Verdict 'Motherboard' 'ATENCION' ("{0} trabaja a x{1} de x{2}: verificar que esté en el slot principal, que ningún M.2 comparta líneas, y revisar slot/contactos (suciedad o pin dañado)." -f (Get-Clean $d.FriendlyName), $cw, $mw)
            } else {
                $extra = if ($apu8000) { ' Con Ryzen 8000G algunos M.2 bajan a x2 según la placa.' } else { '' }
                Set-Verdict 'Motherboard' 'INFO' ("{0} a x{1} de x{2} (puede ser normal según el slot; revisar el manual).{3}" -f (Get-Clean $d.FriendlyName), $cw, $mw, $extra)
            }
        }
        Log $line $col
    }
    if ($shown -eq 0) { Log '  No se pudo leer el enlace PCIe: verificarlo con GPU-Z (Bus Interface).' 'DarkGray' }
    else { Log '  Nota: las GPUs bajan la generación en reposo para ahorrar energía; lo que importa es el ancho (x16).' 'DarkGray' }

    # Dispositivos con problema
    $codes = @{ 1 = 'mal configurado'; 3 = 'driver dañado / sin memoria'; 10 = 'no puede iniciar'; 12 = 'sin recursos'; 14 = 'requiere reinicio'
        18 = 'reinstalar driver'; 19 = 'registro dañado'; 24 = 'no presente / falla'; 28 = 'sin driver'; 31 = 'no funciona bien'; 39 = 'driver dañado'
        43 = 'el dispositivo reportó una falla'; 52 = 'driver sin firma válida' }
    $bad = @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -and @(22, 45) -notcontains [int]$_.ConfigManagerErrorCode })
    if ($bad.Count) {
        Log 'Dispositivos con problema:'
        foreach ($b in $bad) {
            $code = [int]$b.ConfigManagerErrorCode
            Log ("  Código {0,-2} {1,-28} {2}" -f $code, $codes[$code], (Get-Clean $b.Name)) 'Yellow'
        }
        $hw = @($bad | Where-Object { @(10, 24, 43) -contains [int]$_.ConfigManagerErrorCode })
        if ($hw.Count) { Set-Verdict 'Motherboard' 'ATENCION' ("{0} dispositivo(s) con código 10/24/43: posible falla de hardware (instalar drivers de chipset primero y re-chequear)." -f $hw.Count) }
        $nodrv = @($bad | Where-Object { [int]$_.ConfigManagerErrorCode -eq 28 })
        if ($nodrv.Count) { Set-Verdict 'Motherboard' 'INFO' ("{0} dispositivo(s) sin driver (código 28): instalar chipset/LAN/audio antes de juzgar." -f $nodrv.Count) }
    } else { Log 'Dispositivos: ninguno con error en el Administrador de dispositivos.' 'Green' }

    # Red
    try {
        foreach ($n in @(Get-NetAdapter -Physical -ErrorAction Stop)) {
            $col = 'Gray'
            if ($n.Status -eq 'Up' -and $n.MediaType -eq '802.3' -and $n.ReceiveLinkSpeed -and $n.ReceiveLinkSpeed -le 100000000) {
                $col = 'Yellow'
                Set-Verdict 'Motherboard' 'ATENCION' ("{0} negocia a {1}: probar otro cable/puerto; si sigue, el PHY o el puerto de la placa. Si pasa en todas las PCs del banco, el problema es el cable o el switch del banco." -f $n.InterfaceDescription, $n.LinkSpeed)
            }
            Log ("  Red: {0,-45} {1,-12} {2}" -f $n.InterfaceDescription, $n.Status, $n.LinkSpeed) $col
        }
    } catch {}

    Add-Pendiente 'Mother: todos los USB traseros y frontales (pendrive), audio trasero/frontal, LAN con cable, WiFi/BT si tiene.'
    Add-Pendiente 'Mother: cada slot M.2 y cada slot PCIe con algo conectado (el script muestra x/Gen de lo que esté puesto).'
    Add-Pendiente 'Mother: revisión visual: pines del socket (LGA), capacitores, VRM sin marcas de temperatura, headers de fans/RGB.'
    Add-Pendiente 'Mother: temperatura de VRM bajo carga (LibreHardwareMonitor o HWiNFO Pro) durante el stress all-core.'
}

# ======================================================================
#  SMART
# ======================================================================
function Find-Smartctl {
    $cands = @((Join-Path $Root 'tools\smartctl.exe'), (Join-Path $Root 'smartctl.exe'),
        "$env:ProgramFiles\smartmontools\bin\smartctl.exe", "${env:ProgramFiles(x86)}\smartmontools\bin\smartctl.exe")
    foreach ($c in $cands) { if ($c -and (Test-Path $c)) { return $c } }
    $cmd = Get-Command smartctl.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Invoke-SmartJson([string]$Exe, [string[]]$SmartArgs) {
    try {
        $txt = (& $Exe @SmartArgs 2>$null) | Out-String
        if ($txt -match '^\s*\{') { return ($txt | ConvertFrom-Json) }
    } catch {}
    return $null
}

function Get-SmartAttr($j, [int]$Id) {
    if (-not $j.ata_smart_attributes) { return $null }
    foreach ($a in @($j.ata_smart_attributes.table)) { if ([int]$a.id -eq $Id) { return $a } }
    return $null
}

# Evalúa el JSON de smartctl. Devuelve lista de @{Estado; Msg} y las líneas de resumen.
function Get-SmartEval($j) {
    $res = New-Object System.Collections.ArrayList
    $lines = New-Object System.Collections.ArrayList
    $model = if ($j.model_name) { $j.model_name } else { $j.model_family }
    $cap = if ($j.user_capacity.bytes) { $j.user_capacity.bytes } else { $j.nvme_total_capacity }
    [void]$lines.Add(("{0} | SN {1} | FW {2} | {3} | {4}" -f $model, $j.serial_number, $j.firmware_version, $j.device.protocol, $(if ($cap) { Format-Bytes $cap } else { '?' })))

    $passed = $null
    if ($j.smart_status -and $null -ne $j.smart_status.passed) { $passed = [bool]$j.smart_status.passed }
    if ($passed -eq $false) { [void]$res.Add(@{ Estado = 'FALLA'; Msg = 'SMART general: FAILED (el propio disco se declara en falla).' }) }
    $temp = $j.temperature.current
    $poh = $j.power_on_time.hours

    $met = @{ Salud = $null; Horas = $poh; TB = $null; Temp = $temp }
    $h = $j.nvme_smart_health_information_log
    if ($h) {
        $tb = [double]$h.data_units_written * 512000 / 1e12
        $met.Salud = [math]::Max(0, 100 - [int]$h.percentage_used); $met.Horas = $h.power_on_hours; $met.TB = [math]::Round($tb, 1); $met.Temp = $h.temperature
        [void]$lines.Add(("SMART {0} | Temp {1}°C | Horas {2} | Escrito {3:N1} TB | Desgaste {4}% | Spare {5}% (umbral {6}%)" -f `
                    $(if ($passed -eq $false) { 'FAILED' } else { 'PASSED' }), $h.temperature, $h.power_on_hours, $tb, $h.percentage_used, $h.available_spare, $h.available_spare_threshold))
        [void]$lines.Add(("Errores de medio {0} | Apagados inseguros {1} | Entradas en log de errores {2}" -f $h.media_errors, $h.unsafe_shutdowns, $h.num_err_log_entries))
        if ([int]$h.critical_warning -ne 0) { [void]$res.Add(@{ Estado = 'FALLA'; Msg = ("Critical warning = 0x{0:X2} (spare, temperatura, solo lectura o confiabilidad degradada)." -f [int]$h.critical_warning) }) }
        if ([double]$h.media_errors -gt 0) { [void]$res.Add(@{ Estado = 'FALLA'; Msg = ("{0} errores de medio/integridad: NAND con datos que no pudo recuperar." -f $h.media_errors) }) }
        if ($null -ne $h.available_spare -and $null -ne $h.available_spare_threshold) {
            if ([int]$h.available_spare -le [int]$h.available_spare_threshold) { [void]$res.Add(@{ Estado = 'FALLA'; Msg = 'Bloques de reserva (spare) en el umbral o debajo.' }) }
            elseif ([int]$h.available_spare -lt 50) { [void]$res.Add(@{ Estado = 'ATENCION'; Msg = ("Spare al {0}%: ya consumió reserva por bloques malos." -f $h.available_spare) }) }
        }
        $u = [int]$h.percentage_used
        if ($u -ge 100) { [void]$res.Add(@{ Estado = 'FALLA'; Msg = "Desgaste $u%: superó la vida útil nominal (TBW)." }) }
        elseif ($u -ge 80) { [void]$res.Add(@{ Estado = 'ATENCION'; Msg = "Desgaste $u%: le queda poca vida útil." }) }
        elseif ($u -ge 30) { [void]$res.Add(@{ Estado = 'INFO'; Msg = "Desgaste $u%." }) }
        if ([int]$h.temperature -ge 75) { [void]$res.Add(@{ Estado = 'ATENCION'; Msg = ("Temperatura {0}°C en reposo/prueba: revisar disipador o flujo de aire." -f $h.temperature) }) }
        if ([double]$h.num_err_log_entries -gt 0) { [void]$res.Add(@{ Estado = 'INFO'; Msg = 'El log de errores NVMe tiene entradas: suele ser ruido del host, solo preocupa junto con errores de medio.' }) }
    } elseif ($j.ata_smart_attributes) {
        $raw = { param($id) $a = Get-SmartAttr $j $id; if ($a) { [double]$a.raw.value } else { $null } }
        $show = { param($v) if ($null -eq $v) { '-' } else { $v } }
        $r5 = & $raw 5; $r187 = & $raw 187; $r197 = & $raw 197; $r198 = & $raw 198; $r199 = & $raw 199
        $life = $null
        foreach ($id in 231, 177, 233, 202) { $a = Get-SmartAttr $j $id; if ($a -and $null -eq $life) { $life = [int]$a.value } }
        [void]$lines.Add(("SMART {0} | Temp {1}°C | Horas {2} | Reasignados {3} | Pendientes {4} | Incorregibles {5} | CRC {6} | Vida restante {7}" -f `
                    $(if ($passed -eq $false) { 'FAILED' } else { 'PASSED' }), (& $show $temp), (& $show $poh), (& $show $r5), (& $show $r197), (& $show $r198), (& $show $r199), $(if ($null -ne $life) { "$life%" } else { '-' })))
        if ($r5 -gt 0) { [void]$res.Add(@{ Estado = 'ATENCION'; Msg = "$r5 sectores reasignados." }) }
        if ($r197 -gt 0) { [void]$res.Add(@{ Estado = 'FALLA'; Msg = "$r197 sectores pendientes (ilegibles)." }) }
        if ($r198 -gt 0) { [void]$res.Add(@{ Estado = 'FALLA'; Msg = "$r198 sectores incorregibles." }) }
        if ($r187 -gt 0) { [void]$res.Add(@{ Estado = 'ATENCION'; Msg = "$r187 errores incorregibles reportados." }) }
        if ($r199 -gt 0) { [void]$res.Add(@{ Estado = 'ATENCION'; Msg = "$r199 errores CRC: típico de cable SATA/puerto, no del disco en sí." }) }
        if ($null -ne $life -and $life -lt 20) { [void]$res.Add(@{ Estado = 'ATENCION'; Msg = "Vida restante informada: $life%." }) }
        $met.Salud = $life
    } else {
        [void]$lines.Add('El dispositivo no devolvió atributos SMART (adaptador USB/RAID o disco no compatible).')
    }
    $cap = if ($cap) { Format-Bytes $cap } else { $null }
    return [pscustomobject]@{ Lineas = $lines; Hallazgos = $res; Modelo = $model; Met = $met; Capacidad = $cap; TieneSmart = [bool]($h -or $j.ata_smart_attributes) }
}

function Get-SelfTestState($j) {
    # Devuelve: $null (sin datos), 'CORRIENDO', o @{Ok; Texto}
    $l = $j.nvme_self_test_log
    if ($l) {
        if ($l.current_self_test_operation -and [int]$l.current_self_test_operation.value -ne 0) { return 'CORRIENDO' }
        $t = @($l.table)
        if ($t.Count -gt 0 -and $t[0].self_test_result) { return @{ Ok = ([int]$t[0].self_test_result.value -eq 0); Texto = $t[0].self_test_result.string } }
        return $null
    }
    if ($j.ata_smart_data.self_test.status -and $null -ne $j.ata_smart_data.self_test.status.remaining_percent) { return 'CORRIENDO' }
    $s = $j.ata_smart_self_test_log.standard
    if ($s) {
        $t = @($s.table)
        if ($t.Count -gt 0) { return @{ Ok = [bool]$t[0].status.passed; Texto = $t[0].status.string } }
    }
    return $null
}

function Update-DiscoMetric([string]$Modelo, [hashtable]$Datos) {
    $key = ($Modelo -replace '\s', '').ToUpper()
    $d = $null
    foreach ($x in $Global:M.Discos) { if ((($x.Modelo -replace '\s', '').ToUpper()) -eq $key) { $d = $x; break } }
    if (-not $d) {
        $d = [ordered]@{ Modelo = $Modelo; Capacidad = $null; Bus = $null; Salud = $null; Horas = $null; TB = $null; Temp = $null; Autotest = $null; Estado = 'OK' }
        [void]$Global:M.Discos.Add($d)
    }
    foreach ($k in $Datos.Keys) { if ($null -ne $Datos[$k]) { $d[$k] = $Datos[$k] } }
}

function Show-Smart([switch]$SelfTest) {
    Section ($(if ($SelfTest) { 'DISCOS - SMART + AUTOTEST CORTO' } else { 'DISCOS - SMART' }))
    $sc = Find-Smartctl
    if (-not $sc) {
        Log 'smartctl.exe no encontrado (ponelo en la carpeta "tools"). Uso la info básica de Windows:' 'Yellow'
        try {
            foreach ($pd in @(Get-PhysicalDisk -ErrorAction Stop)) {
                $rc = $pd | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
                Log ("  {0} | {1} | salud {2} | temp {3}°C | desgaste {4}% | errores de lectura no corregidos {5} | horas {6}" -f `
                        (Get-Clean $pd.FriendlyName), $pd.BusType, $pd.HealthStatus, $rc.Temperature, $rc.Wear, $rc.ReadErrorsUncorrected, $rc.PowerOnHours)
                if ($pd.HealthStatus -ne 'Healthy') { Set-Verdict 'Discos' 'FALLA' ("{0}: Windows lo marca {1}." -f $pd.FriendlyName, $pd.HealthStatus) }
                if ($rc.ReadErrorsUncorrected -gt 0) { Set-Verdict 'Discos' 'FALLA' ("{0}: {1} errores de lectura no corregidos." -f $pd.FriendlyName, $rc.ReadErrorsUncorrected) }
                if ($rc.Wear -ge 80) { Set-Verdict 'Discos' 'ATENCION' ("{0}: desgaste {1}%." -f $pd.FriendlyName, $rc.Wear) }
                if ([string]$pd.BusType -ne 'USB') {
                    Update-DiscoMetric (Get-Clean $pd.FriendlyName) @{ Salud = $(if ($null -ne $rc.Wear) { 100 - [int]$rc.Wear }); Horas = $rc.PowerOnHours; Temp = $rc.Temperature; Capacidad = (Format-Bytes $pd.Size) }
                }
            }
        } catch { Log '  No se pudo leer.' 'Yellow' }
        Add-Pendiente 'Discos: conseguir smartctl.exe para SMART completo y autotest.'
        return
    }
    $scan = Invoke-SmartJson $sc @('--scan-open', '-j')
    $devs = @()
    if ($scan -and $scan.devices) { $devs = @($scan.devices) }
    # Se omiten los USB (pendrives, adaptadores) y el disco del programa: algunos pendrives se
    # reinician si reciben comandos SMART y Windows los desconecta (el programa pierde sus archivos).
    $own = Get-OwnDisk
    $winDisks = @{}
    try { foreach ($wd in @(Get-Disk -ErrorAction Stop)) { $winDisks[[int]$wd.Number] = $wd } } catch {}
    $keep = @()
    foreach ($d in $devs) {
        $num = -1
        if ([string]$d.name -match '^/dev/sd([a-z])$') { $num = [int][char]$Matches[1] - [int][char]'a' }
        $wd = if ($num -ge 0) { $winDisks[$num] } else { $null }
        $isUsb = ($wd -and [string]$wd.BusType -eq 'USB') -or ([string]$d.type -eq 'scsi' -and [string]$d.protocol -eq 'SCSI')
        if ($isUsb -or ($num -ge 0 -and $num -eq $own.Numero)) {
            $nm = if ($wd) { Get-Clean $wd.FriendlyName } else { [string]$d.name }
            Log ("  [{0}] {1}: USB o disco del programa, se omite (no se le mandan comandos SMART)." -f $d.name, $nm) 'DarkGray'
            continue
        }
        $keep += $d
    }
    $devs = $keep
    if (-not $devs.Count) { Log 'smartctl no encontró discos internos.' 'Yellow'; return }

    if ($SelfTest) {
        foreach ($d in $devs) {
            $o = (& $sc -t short -d $d.type $d.name 2>&1) | Out-String
            if ($o -match 'not supported|No soportado|failed|Unknown') { Log ("  {0}: no acepta autotest ({1})" -f $d.name, (($o -split "`n" | Where-Object { $_ -match 'support|fail|Unknown' } | Select-Object -First 1))) 'DarkGray' }
            else { Log ("  {0}: autotest corto iniciado." -f $d.name) }
        }
        Log 'Esperando a que terminen (hasta 3 minutos, Q para no esperar)...'
        $t0 = Get-Date
        $sawRunning = $false
        while (((Get-Date) - $t0).TotalSeconds -lt 180) {
            $running = 0
            foreach ($d in $devs) {
                $j = Invoke-SmartJson $sc @('-j', '-c', '-l', 'selftest', '-d', $d.type, $d.name)
                if ($j -and (Get-SelfTestState $j) -eq 'CORRIENDO') { $running++ }
            }
            if ($running -gt 0) { $sawRunning = $true }
            $el = ((Get-Date) - $t0).TotalSeconds
            # si nunca se vio "corriendo", esperar al menos 130 s para no leer un resultado viejo
            if ($running -eq 0 -and (($sawRunning -and $el -gt 10) -or $el -gt 130)) { break }
            Write-Progress -Activity 'Autotest SMART corto' -Status ("{0} disco(s) todavía testeando" -f $running) -PercentComplete ([math]::Min(100, ((Get-Date) - $t0).TotalSeconds / 1.8))
            if (Test-KeyQ) { break }
            Start-Sleep -Seconds 5
        }
        Write-Progress -Activity 'Autotest SMART corto' -Completed
        Add-Prueba 'Autotest SMART corto de discos' (((Get-Date) - $t0).TotalMinutes) 'Realizado'
    }

    foreach ($d in $devs) {
        $j = Invoke-SmartJson $sc @('-j', '-a', '-l', 'selftest', '-d', $d.type, $d.name)
        if (-not $j) { Log ("  {0}: sin respuesta" -f $d.name) 'Yellow'; continue }
        $ev = Get-SmartEval $j
        Log ''
        Log ("  [{0}] {1}" -f $d.name, $ev.Lineas[0]) 'White'
        foreach ($l in ($ev.Lineas | Select-Object -Skip 1)) { Log ("        " + $l) }
        foreach ($f in $ev.Hallazgos) { Set-Verdict 'Discos' $f.Estado ("{0}: {1}" -f $ev.Modelo, $f.Msg) }
        $auto = $null
        if ($SelfTest) {
            $st = Get-SelfTestState $j
            if ($st -eq 'CORRIENDO') { Set-Verdict 'Discos' 'INFO' ("{0}: el autotest sigue corriendo; revisar después con smartctl -l selftest." -f $ev.Modelo) }
            elseif ($st -is [hashtable]) {
                $auto = if ($st.Ok) { 'sin errores' } else { 'con errores' }
                if ($st.Ok) { Set-Verdict 'Discos' 'OK' ("{0}: autotest corto -> {1}" -f $ev.Modelo, $st.Texto) }
                else { Set-Verdict 'Discos' 'FALLA' ("{0}: autotest corto -> {1}" -f $ev.Modelo, $st.Texto) }
            }
        }
        if ($ev.TieneSmart) {
            $estado = Get-WorstState @($ev.Hallazgos | ForEach-Object { $_.Estado })
            if ($auto -eq 'con errores') { $estado = 'FALLA' }
            Update-DiscoMetric (Get-Clean $ev.Modelo) @{ Capacidad = $ev.Capacidad; Salud = $ev.Met.Salud; Horas = $ev.Met.Horas; TB = $ev.Met.TB; Temp = $ev.Met.Temp; Autotest = $auto; Estado = $estado }
        }
        if (-not $ev.Hallazgos.Count) { Set-Verdict 'Discos' 'OK' '' }
    }
}

# ======================================================================
#  CPU
# ======================================================================
function Get-EffectiveMHz([string]$Instance = '_Total') {
    try {
        $p = Get-CimInstance -ClassName Win32_PerfFormattedData_Counters_ProcessorInformation -Filter ("Name='{0}'" -f $Instance) -ErrorAction Stop
        if ($p -and $p.ProcessorFrequency) { return [math]::Round([double]$p.ProcessorFrequency * [double]$p.PercentProcessorPerformance / 100) }
    } catch {}
    return $null
}

function Get-Reference {
    try { return [NetBench.Workload]::Reference() }
    catch {
        Set-Verdict 'CPU' 'FALLA' ("Resultado de referencia inestable: " + $_.Exception.GetBaseException().Message)
        return $null
    }
}

function Invoke-Stress {
    param([int[]]$Cpus, [double]$Seconds, $Ref, [string]$Instance = '_Total', [string]$Activity = 'Stress CPU', $Stats)
    $start = Get-Date
    $run = New-Object NetBench.StressRun -ArgumentList @([int[]]$Cpus, [double]$Seconds, [uint64[]]$Ref)
    $mhz = New-Object System.Collections.Generic.List[double]
    $wheaCount = 0
    $stopped = $false
    $tempTxt = ''
    if (-not $Stats) { $Stats = New-SensorStats }
    $run.Start()
    $lastPoll = [datetime]::MinValue
    while ($run.Running) {
        Start-Sleep -Milliseconds 500
        if (((Get-Date) - $lastPoll).TotalSeconds -ge 3) {
            $lastPoll = Get-Date
            $m = Get-EffectiveMHz $Instance
            if ($m -and $run.Elapsed -gt 3) { $mhz.Add($m) }
            $w = @(Get-WheaSince $start)
            if ($w.Count -gt $wheaCount) {
                $wheaCount = $w.Count
                Write-Host ("  !! WHEA durante el test ({0})" -f $wheaCount) -ForegroundColor Red
            }
            if ($Global:Lhm) {
                $sr = Read-Sensors
                if ($run.Elapsed -gt 2) { Update-SensorStats $Stats $sr }
                $tempTxt = if ($null -ne $sr.CpuTemp) { ' | {0:N0} °C' -f $sr.CpuTemp } else { '' }
                if ($null -ne $sr.CpuPower) { $tempTxt += (' {0:N0} W' -f $sr.CpuPower) }
            }
        }
        $pct = [math]::Min(100, [int](100 * $run.Elapsed / $Seconds))
        $it = 0; foreach ($x in $run.Iter) { $it += $x }
        $cur = if ($mhz.Count) { $mhz[$mhz.Count - 1] } else { '-' }
        Write-Progress -Activity $Activity -Status ("{0:N0}/{1:N0} s | iteraciones {2} | errores {3} | WHEA {4} | {5} MHz{6} | Q = cancelar" -f `
                $run.Elapsed, $Seconds, $it, $run.TotalErrors, $wheaCount, $cur, $tempTxt) -PercentComplete $pct
        if (Test-KeyQ) { $run.StopFlag = $true; $stopped = $true }
    }
    Write-Progress -Activity $Activity -Completed
    $avg = $null; $min = $null; $max = $null
    if ($mhz.Count) {
        $s = $mhz | Measure-Object -Average -Minimum -Maximum
        $avg = [math]::Round($s.Average); $min = $s.Minimum; $max = $s.Maximum
    }
    return [pscustomobject]@{ Run = $run; MHzAvg = $avg; MHzMin = $min; MHzMax = $max; Whea = @(Get-WheaSince $start); Stopped = $stopped; Sensores = $Stats }
}

function Invoke-CpuAllCore([int]$Minutes) {
    $n = [Environment]::ProcessorCount
    Section ("CPU - TODOS LOS NÚCLEOS ({0} min, {1} hilos)" -f $Minutes, $n)
    Log 'Cada hilo calcula lo mismo (flotante, SHA-256, compresión/descompresión) y se compara con la referencia.'
    Log 'Un solo resultado distinto = el CPU calculó mal. Mirá temperatura y throttling en LibreHardwareMonitor.' 'DarkGray'
    Offer-Monitor
    [void](Start-Sensors)
    $ref = Get-Reference
    if (-not $ref) { Add-Prueba 'Estabilidad CPU - todos los núcleos' 0 'FALLA'; return }
    Set-Marker ("CPU all-core ({0} min)" -f $Minutes)
    $stats = New-SensorStats
    $r = Invoke-Stress -Cpus (0..($n - 1)) -Seconds ($Minutes * 60) -Ref $ref -Activity 'CPU: todos los núcleos' -Stats $stats
    Clear-Marker
    $run = $r.Run
    $it = 0; foreach ($x in $run.Iter) { $it += $x }
    Log ("Duración {0:N0} s | iteraciones {1} | errores de cálculo {2} | frecuencia efectiva prom/min/max {3}/{4}/{5} MHz" -f `
            $run.Elapsed, $it, $run.TotalErrors, $r.MHzAvg, $r.MHzMin, $r.MHzMax)
    if (-not $run.Pinned[0] -and $IsWin) { Log 'No se pudo fijar afinidad por hilo (el test igual vale).' 'DarkGray' }
    if ($r.Stopped) { Set-Verdict 'CPU' 'INFO' 'Test all-core cancelado antes de terminar.' }
    if ($run.TotalErrors -gt 0) {
        for ($i = 0; $i -lt $run.Cpus.Length; $i++) {
            if ($run.Errors[$i] -gt 0) { Log ("  CPU lógico {0} ({1}): {2} errores, último: {3}" -f $run.Cpus[$i], (Get-CoreLabel $run.Cpus[$i]), $run.Errors[$i], $run.LastError[$i]) 'Red' }
        }
        Set-Verdict 'CPU' 'FALLA' ("Errores de cálculo en el test all-core ({0}). Con todo en stock = CPU defectuoso; si hay OC/PBO/curve/XMP, volver a defaults y repetir." -f $run.TotalErrors)
    } else {
        Set-Verdict 'CPU' 'OK' ("All-core {0:N0} min sin errores de cálculo." -f ($run.Elapsed / 60))
    }
    if ($r.Whea.Count) { Show-Whea $r.Whea -DuranteTest }
    if ($r.MHzAvg -and $Global:Cpu.BaseMHz -and $r.MHzAvg -lt 0.85 * $Global:Cpu.BaseMHz) {
        Set-Verdict 'CPU' 'ATENCION' ("Frecuencia promedio bajo carga ({0} MHz) por debajo de la base ({1} MHz): throttling térmico o de potencia. Revisar pasta/cooler/VRM con LibreHardwareMonitor." -f $r.MHzAvg, $Global:Cpu.BaseMHz)
    }
    Show-SensorStats $r.Sensores 'all-core'
    $ips = 0.0; foreach ($x in $run.IterPerSec) { $ips += $x }
    $Global:M.Cpu['AllCoreMin'] = [math]::Round($run.Elapsed / 60, 1)
    $Global:M.Cpu['AllCoreErr'] = $run.TotalErrors
    if (-not $r.Stopped -and $run.Elapsed -ge 60 -and $run.TotalErrors -eq 0) {
        $Global:M.Cpu['AllCoreIps'] = [math]::Round($ips, 2)
        Log ("  Rendimiento all-core: {0:N1} it/s" -f $ips)
        $cmp = Show-Comparacion 'AllCoreIps' $ips 'Rendimiento all-core'
        if ($cmp) { $Global:M.Cpu['VsHist'] = @{ Pct = [math]::Round($cmp.Pct); N = $cmp.N } }
    }
    $res = if ($run.TotalErrors -gt 0 -or $r.Whea.Count) { 'FALLA' } elseif ($r.Stopped) { 'Cancelada' } else { 'OK' }
    Add-Prueba 'Estabilidad CPU - todos los núcleos' ($run.Elapsed / 60) $res ("{0} hilos con verificación de resultados" -f $n)
}

function Invoke-CpuPerCore([int]$Seconds) {
    Offer-Monitor
    [void](Start-Sensors)
    $stats = New-SensorStats
    $t0 = Get-Date
    $n = [Environment]::ProcessorCount
    Section ("CPU - TEST POR NÚCLEO ({0} s por CPU lógico, {1} en total ~{2:N0} min)" -f $Seconds, $n, ($Seconds * $n / 60))
    Log 'Carga UN solo hilo por vez: ese núcleo sube a su boost máximo, que es donde fallan los CPUs degradados,'
    Log 'los que traen curve optimizer/undervolt agresivo y los núcleos flojos. Si la PC se cuelga, al reabrir'
    Log 'el script te dice en qué núcleo pasó.' 'DarkGray'
    $ref = Get-Reference
    if (-not $ref) { return }
    $fallados = New-Object System.Collections.ArrayList
    $mhzAll = @{}
    $rows = New-Object System.Collections.ArrayList
    Log '  CPU  núcleo         it/s   MHz aprox  errores  WHEA'
    for ($i = 0; $i -lt $n; $i++) {
        $label = Get-CoreLabel $i
        Set-Marker ("Test por núcleo: CPU lógico {0} ({1})" -f $i, $label)
        $r = Invoke-Stress -Cpus @($i) -Seconds $Seconds -Ref $ref -Instance ("0,{0}" -f $i) -Activity ("Test por núcleo: CPU lógico {0} de {1} ({2})" -f $i, ($n - 1), $label) -Stats $stats
        $run = $r.Run
        $bad = ($run.Errors[0] -gt 0) -or ($r.Whea.Count -gt 0)
        if ($r.MHzAvg) { $mhzAll[$i] = $r.MHzAvg }
        $ips = [double]$run.IterPerSec[0]
        if (-not $r.Stopped) { [void]$rows.Add([pscustomobject]@{ Cpu = $i; Label = $label; Grupo = ($label -replace '\s*\d+$', ''); Ips = $ips }) }
        $txt = "  {0,3}  {1,-12} {2,6:N2}  {3,9}  {4,7}  {5,4}  {6}" -f $i, $label, $ips, $(if ($r.MHzAvg) { $r.MHzAvg } else { '-' }), $run.Errors[0], $r.Whea.Count, $(if ($bad) { 'FALLA: ' + $run.LastError[0] } else { 'OK' })
        Log $txt $(if ($bad) { 'Red' } else { 'Gray' })
        if ($bad) { [void]$fallados.Add(("{0} ({1})" -f $i, $label)) }
        if ($r.Whea.Count) { Show-Whea $r.Whea -DuranteTest }
        if ($i -eq 0 -and -not $run.Pinned[0] -and $IsWin) { Log '  No se pudo fijar el hilo a un núcleo: este modo no identifica núcleos.' 'Yellow' }
        if ($r.Stopped) { Log 'Cancelado por el técnico.' 'Yellow'; Set-Verdict 'CPU' 'INFO' ("Test por núcleo cancelado en el CPU lógico {0}." -f $i); break }
    }
    Clear-Marker
    # Rendimiento relativo: cada núcleo contra la mediana de los de su mismo tipo (P/E o todos)
    $lentos = New-Object System.Collections.ArrayList
    $sospechosos = New-Object System.Collections.ArrayList
    foreach ($g in @($rows | ForEach-Object { $_.Grupo } | Sort-Object -Unique)) {
        $grp = @($rows | Where-Object { $_.Grupo -eq $g -and $_.Ips -gt 0 })
        if ($grp.Count -lt 2) { continue }
        $sorted = @($grp | ForEach-Object { $_.Ips } | Sort-Object)
        $med = $sorted[[math]::Floor($sorted.Count / 2)]
        $minPct = 100 * $sorted[0] / $med; $maxPct = 100 * $sorted[-1] / $med
        Log ("  Rendimiento {0}: mín {1:N0}% / máx {2:N0}% de la mediana ({3:N2} it/s)" -f $(if ($g) { $g } else { 'núcleos' }), $minPct, $maxPct, $med)
        foreach ($x in $grp) { if ($x.Ips -lt 0.85 * $med) { [void]$sospechosos.Add([pscustomobject]@{ Row = $x; Med = $med }) } }
    }
    # Un núcleo lento puede ser otro programa que justo usó ese núcleo: se repite una vez para confirmar
    if ($sospechosos.Count -and -not $fallados.Count -and $rows.Count -eq $n) {
        Log ("  Repitiendo {0} CPU lógico(s) que rindieron menos, para descartar que haya sido otro programa..." -f $sospechosos.Count) 'DarkGray'
        foreach ($sp in $sospechosos) {
            $x = $sp.Row
            Set-Marker ("Test por núcleo (repetición): CPU lógico {0} ({1})" -f $x.Cpu, $x.Label)
            $r2 = Invoke-Stress -Cpus @($x.Cpu) -Seconds $Seconds -Ref $ref -Instance ("0,{0}" -f $x.Cpu) -Activity ("Repitiendo CPU lógico {0} ({1})" -f $x.Cpu, $x.Label) -Stats $stats
            Clear-Marker
            if ($r2.Stopped) { [void]$lentos.Add(("{0} ({1}, {2:N0}%)" -f $x.Cpu, $x.Label, (100 * $x.Ips / $sp.Med))); break }
            $ips2 = [double]$r2.Run.IterPerSec[0]
            $bad2 = ($r2.Run.Errors[0] -gt 0) -or ($r2.Whea.Count -gt 0)
            $pct1 = 100 * $x.Ips / $sp.Med; $pct2 = 100 * $ips2 / $sp.Med
            if ($bad2) {
                [void]$fallados.Add(("{0} ({1}, en la repetición)" -f $x.Cpu, $x.Label))
                Log ("  CPU {0} ({1}): en la repetición dio ERRORES: {2}" -f $x.Cpu, $x.Label, $r2.Run.LastError[0]) 'Red'
            } elseif ($ips2 -ge 0.85 * $sp.Med) {
                Log ("  CPU {0} ({1}): {2:N0}% -> {3:N0}% al repetir. Normal: fue otro programa usando ese núcleo." -f $x.Cpu, $x.Label, $pct1, $pct2) 'Green'
                Set-Verdict 'CPU' 'INFO' ("CPU lógico {0} rindió {1:N0}% en la primera pasada y {2:N0}% al repetir: interferencia de otro programa, no del CPU." -f $x.Cpu, $pct1, $pct2)
            } else {
                Log ("  CPU {0} ({1}): {2:N0}% -> {3:N0}% al repetir. Se confirma que rinde menos." -f $x.Cpu, $x.Label, $pct1, $pct2) 'Yellow'
                [void]$lentos.Add(("{0} ({1}, {2:N0}% y {3:N0}% al repetir)" -f $x.Cpu, $x.Label, $pct1, $pct2))
            }
        }
    } else {
        foreach ($sp in $sospechosos) { [void]$lentos.Add(("{0} ({1}, {2:N0}%)" -f $sp.Row.Cpu, $sp.Row.Label, (100 * $sp.Row.Ips / $sp.Med))) }
    }
    if ($lentos.Count) {
        Set-Verdict 'CPU' 'ATENCION' ("Rinden menos que sus pares (confirmado al repetir): CPU lógicos {0}. Núcleo que no sostiene el boost: revisar temperatura, curve optimizer/undervolt en el BIOS; con todo en stock, posible degradación." -f ($lentos -join ', '))
    }
    Log '  (La frecuencia que informa Windows por núcleo es aproximada; para comparar núcleos vale el it/s.)' 'DarkGray'
    Show-SensorStats $stats 'test por núcleo'
    $allIps = @($rows | ForEach-Object { $_.Ips } | Where-Object { $_ -gt 0 } | Sort-Object)
    $Global:M.Cpu['PerCoreSeg'] = $Seconds
    $Global:M.Cpu['PerCoreN'] = $rows.Count
    $Global:M.Cpu['PerCoreFail'] = $fallados.Count
    if ($allIps.Count -eq $n -and -not $fallados.Count) {
        $medAll = $allIps[[math]::Floor($allIps.Count / 2)]
        $Global:M.Cpu['PerCoreIps'] = [math]::Round($medAll, 3)
        $cmp = Show-Comparacion 'PerCoreIps' $medAll 'Rendimiento por núcleo'
        if ($cmp -and -not $Global:M.Cpu['VsHist']) { $Global:M.Cpu['VsHist'] = @{ Pct = [math]::Round($cmp.Pct); N = $cmp.N } }
    }
    $res = if ($fallados.Count) { 'FALLA' } elseif ($lentos.Count) { 'Con observaciones' } elseif ($rows.Count -lt $n) { 'Cancelada' } else { 'OK' }
    Add-Prueba 'CPU núcleo por núcleo' (((Get-Date) - $t0).TotalMinutes) $res ("{0} de {1} CPU lógicos, {2} s cada uno" -f $rows.Count, $n, $Seconds)
    if ($fallados.Count) {
        Set-Verdict 'CPU' 'FALLA' ("Fallaron los CPU lógicos: {0}. Un núcleo que falla solo en carga liviana = núcleo débil/degradado (o curve optimizer/undervolt si no está en stock)." -f ($fallados -join ', '))
    } elseif ($mhzAll.Count) {
        $v = $mhzAll.Values | Measure-Object -Average -Maximum -Minimum
        Set-Verdict 'CPU' 'OK' ("Test por núcleo sin errores. Frecuencia por núcleo (aprox.): mín {0} / prom {1:N0} / máx {2} MHz." -f $v.Minimum, $v.Average, $v.Maximum)
    } else {
        Set-Verdict 'CPU' 'OK' 'Test por núcleo sin errores.'
    }
}

# ======================================================================
#  RAM: TestMem5 automático (config según DDR4/DDR5 e Intel/AMD, resultado leído de su Log.txt)
# ======================================================================
$Tm5Configs = [ordered]@{
    'auto'                        = 'Automática (según la RAM y el CPU)'
    'Extreme @ anta777.cfg'       = 'anta777 Extreme (DDR4)'
    'DDR5 Ryzen3D @ anta777.cfg'  = 'anta777 DDR5 (AMD)'
    'DDR5 Intel @ anta777.cfg'    = 'anta777 DDR5 (Intel)'
    '1usmus v3 @ 1usmus.cfg'      = '1usmus v3'
    'Absolut @ anta777.cfg'       = 'anta777 Absolut'
}

function Get-Tm5ConfigAuto {
    $ddr5 = [string]$Global:M.Equipo['RamTipo'] -match 'DDR5'
    $amd = $Global:Cpu -and $Global:Cpu.Nombre -match 'AMD'
    if ($ddr5 -and $amd) { return 'DDR5 Ryzen3D @ anta777.cfg' }
    if ($ddr5) { return 'DDR5 Intel @ anta777.cfg' }
    return 'Extreme @ anta777.cfg'
}

# Cambia solo las claves indicadas de la sección [Settings] de TM5.ini y deja el resto como estaba
function Set-Tm5Ini([string]$Path, [hashtable]$Valores) {
    $lineas = New-Object System.Collections.ArrayList
    if (Test-Path $Path) { foreach ($l in [IO.File]::ReadAllLines($Path, [Text.Encoding]::Default)) { [void]$lineas.Add($l) } }
    $ini = -1; $fin = $lineas.Count
    for ($i = 0; $i -lt $lineas.Count; $i++) {
        if ($lineas[$i].Trim() -match '^\[(.+)\]$') {
            if ($ini -ge 0) { $fin = $i; break }
            if ($Matches[1] -eq 'Settings') { $ini = $i }
        }
    }
    if ($ini -lt 0) { [void]$lineas.Add('[Settings]'); $ini = $lineas.Count - 1; $fin = $lineas.Count }
    foreach ($k in $Valores.Keys) {
        $hecho = $false
        for ($i = $ini + 1; $i -lt $fin; $i++) {
            if ($lineas[$i] -match ('^\s*' + [regex]::Escape($k) + '\s*=')) { $lineas[$i] = ('{0}={1}' -f $k, $Valores[$k]); $hecho = $true; break }
        }
        if (-not $hecho) { $lineas.Insert($fin, ('{0}={1}' -f $k, $Valores[$k])); $fin++ }
    }
    [IO.File]::WriteAllLines($Path, [string[]]$lineas.ToArray(), [Text.Encoding]::Default)
}

function Invoke-TestMem5([int]$Minutes = 30, [string]$Config = 'auto') {
    Section ("RAM - TestMem5 ({0} min como mínimo)" -f $Minutes)
    $exe = Find-TestMem5
    if (-not $exe) {
        Log '  Falta TestMem5 0.13 en tools (la 0.12 copiada a mano no escribe el log que se necesita). Bajándolo...'
        Install-Tools @(Get-ToolStatus | Where-Object { $_.Id -eq 'tm5' })
        $exe = Find-TestMem5
    }
    if (-not $exe) { Set-Verdict 'RAM' 'INFO' 'No se pudo correr TestMem5: no se pudo bajar (sin internet). Se baja desde Herramientas.'; return }
    $dir = Split-Path $exe
    if (-not $Config -or $Config -eq 'auto') { $Config = Get-Tm5ConfigAuto }
    if (-not (Test-Path (Join-Path $dir ('bin\' + $Config)))) {
        Log ("  No está la config {0}: se usa la de TestMem5 por defecto." -f $Config) 'Yellow'
        $Config = 'Universal 2 @ LMhz.cfg'
    }
    $ramTxt = [string]$Global:M.Equipo['RamTexto']
    Log ("Config: {0} | RAM: {1}" -f $Config, $ramTxt)
    Log 'TestMem5 arranca solo y el resultado se lee de su log: no hace falta tocar nada. En DDR5, el test que vale es con XMP/EXPO activado.' 'DarkGray'
    Log 'Si encuentra un error, TestMem5 se frena ahí (es suficiente para saber que la RAM falla).' 'DarkGray'
    try { Set-Tm5Ini (Join-Path $dir 'TM5.ini') @{ 'Config File' = $Config; 'Minutes' = $Minutes; 'Show Log' = 1 } }
    catch { Log ("  No se pudo escribir TM5.ini ({0}): se usa la configuración que tenga TestMem5." -f $_.Exception.Message) 'Yellow' }
    Get-Process -Name 'TM5' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    $logPath = Join-Path $dir 'Log.txt'
    $crash = Join-Path $dir 'Crash.log'
    $desde = if (Test-Path $logPath) { (Get-Item $logPath).Length } else { 0 }
    Offer-Monitor
    [void](Start-Sensors)
    $stats = New-SensorStats
    Set-Marker ("TestMem5 ({0})" -f $Config)
    $start = Get-Date
    $p = $null
    try { $p = Start-Process -FilePath $exe -WorkingDirectory $dir -PassThru } catch { Log ("  No se pudo abrir TestMem5: {0}" -f $_.Exception.Message) 'Red'; Clear-Marker; return }
    $errores = New-Object System.Collections.ArrayList
    $fin = $null; $cobertura = ''; $awe = $false; $vioActividad = $false; $avisoArranque = $false; $whea = 0; $cortado = $false
    $limite = $Minutes * 1.8 + 20
    while ($true) {
        $t = 0
        while ($t -lt 4) { Start-Sleep -Milliseconds 500; $t++; if (Test-KeyQ) { $cortado = $true; break } }
        if ($cortado) { break }
        # lo nuevo del log desde que se abrió
        if (Test-Path $logPath) {
            try {
                $fs = [IO.File]::Open($logPath, 'Open', 'Read', 'ReadWrite')
                try {
                    if ($fs.Length -lt $desde) { $desde = 0 }
                    [void]$fs.Seek($desde, 'Begin')
                    $buf = New-Object byte[] ($fs.Length - $desde)
                    $n = $fs.Read($buf, 0, $buf.Length)
                    $desde += $n
                    $txt = [Text.Encoding]::UTF8.GetString($buf, 0, $n)
                } finally { $fs.Dispose() }
                foreach ($l in ($txt -split "`r?`n")) {
                    $l = $l.Trim([char]0xFEFF, ' ')
                    if (-not $l) { continue }
                    $vioActividad = $true
                    if ($l -match 'Error in test|Ошибка в тесте') { [void]$errores.Add($l); Log ('  ' + $l) 'Red' }
                    elseif ($l -match 'Testing completed|Тестирование закончено') { $fin = 'completo' }
                    elseif ($l -match 'Testing stopped|Тестирование прервано') { $fin = 'cortado'; Log ('  ' + $l) 'Yellow' }
                    elseif ($l -match '(\d+)\s*MB\s*x\s*(\d+)\s*\((\d+)%\)\s*(out of|из)\s*(\d+)\s*MB') { $cobertura = ('{0}% de {1:N0} GB' -f $Matches[3], ([double]$Matches[5] / 1024)); Log ('  ' + $l) 'DarkGray' }
                    elseif ($l -match 'AWE') { $awe = $true; Log ('  ' + $l) 'Yellow' }
                    elseif ($l -match 'error|ошибка') { Log ('  ' + $l) 'Yellow' }
                }
            } catch {}
        }
        $w = @(Get-WheaSince $start)
        if ($w.Count -gt $whea) { $whea = $w.Count; Log ("  !! WHEA durante TestMem5 ({0})" -f $whea) 'Red' }
        $sTxt = ''
        if ($Global:Lhm) {
            $sr = Read-Sensors
            Update-SensorStats $stats $sr
            if ($null -ne $sr.CpuTemp) { $sTxt = (' | CPU {0:N0} °C' -f $sr.CpuTemp) }
        }
        $el = (Get-Date) - $start
        if (-not $vioActividad -and $el.TotalSeconds -gt 90 -and -not $avisoArranque) {
            $avisoArranque = $true
            Log '  TestMem5 todavía no empezó a escribir su log: si su ventana está esperando, tocá el botón para empezar (Start/Iniciar).' 'Yellow'
        }
        Write-Progress -Activity ("TestMem5 ({0})" -f $Config) -Status ("{0:hh\:mm\:ss} de {1} min mínimo | errores {2} | WHEA {3}{4}{5} | Q = dejar de vigilar" -f $el, $Minutes, $errores.Count, $whea, $(if ($cobertura) { ' | ' + $cobertura }), $sTxt) -PercentComplete ([math]::Min(99, 100 * $el.TotalMinutes / $Minutes))
        if ($fin -or $errores.Count) { if ($errores.Count) { Start-Sleep -Seconds 2 }; break }
        if ($p.HasExited) {
            # si TestMem5 se relanzó solo (el proceso que abrimos termina y queda otro TM5), se sigue vigilando ese
            $otro = @(Get-Process -Name 'TM5' -ErrorAction SilentlyContinue | Where-Object { -not $_.HasExited }) | Select-Object -First 1
            if ($otro) { $p = $otro } else { if (-not $fin) { $fin = 'cerrado' }; break }
        }
        if ($el.TotalMinutes -gt $limite) { $fin = 'tiempo'; break }
    }
    Write-Progress -Activity 'TestMem5' -Completed
    Clear-Marker
    $dur = ((Get-Date) - $start).TotalMinutes
    $crashNuevo = (Test-Path $crash) -and ((Get-Item $crash).LastWriteTime -ge $start)
    $w = @(Get-WheaSince $start)
    if ($w.Count) { Show-Whea $w -DuranteTest }
    Show-SensorStats $stats 'TestMem5' 'RAM'
    $Global:M.Ram['Tm5Config'] = $Config
    $Global:M.Ram['Tm5Min'] = [math]::Round($dur, 1)
    $Global:M.Ram['Tm5Cobertura'] = $cobertura
    $res = 'OK'
    $cfgNombre = if ($Tm5Configs[$Config]) { [string]$Tm5Configs[$Config] } else { $Config -replace '\.cfg$', '' }
    if ($errores.Count -or $crashNuevo) {
        $res = 'FALLA'
        $Global:M.Ram['Tm5Res'] = 'con errores'
        $det = if ($errores.Count) { ($errores | Select-Object -First 3) -join ' / ' } else { 'un proceso de prueba se cayó (Crash.log), casi siempre por la memoria' }
        Set-Verdict 'RAM' 'FALLA' ("TestMem5 encontró errores en la memoria ({0}). Con XMP/EXPO: probar sin XMP o un escalón menos; si falla también en stock, probar los módulos de a uno para encontrar el fallado." -f $det)
        if (-not $p.HasExited) { Log '  TestMem5 queda abierto para que veas el error.' 'Yellow' }
    } elseif ($fin -eq 'completo') {
        $Global:M.Ram['Tm5Res'] = 'sin errores'
        Set-Verdict 'RAM' 'OK' ("TestMem5 ({0}) {1:N0} min sin errores{2}." -f $cfgNombre, $dur, $(if ($cobertura) { ", probó el $cobertura" }))
        try { if (-not $p.HasExited) { $p.CloseMainWindow() | Out-Null; Start-Sleep -Seconds 2; if (-not $p.HasExited) { $p.Kill() } } } catch {}
    } elseif ($w.Count) {
        $res = 'FALLA'
        $Global:M.Ram['Tm5Res'] = 'WHEA'
    } elseif ($cortado -or $fin -eq 'cortado') {
        $res = 'Cancelada'
        $Global:M.Ram['Tm5Res'] = 'cortado'
        Set-Verdict 'RAM' 'INFO' ("TestMem5 se cortó a los {0:N0} min sin errores hasta ese momento." -f $dur)
    } elseif (-not $vioActividad) {
        # sin log (por ejemplo, el log desactivado en sus opciones): se pregunta como antes
        $ok = Ask-Yes '¿TestMem5 terminó SIN errores?' $true
        $res = if ($ok) { 'OK' } else { 'FALLA' }
        $Global:M.Ram['Tm5Res'] = $(if ($ok) { 'sin errores' } else { 'con errores' })
        Set-Verdict 'RAM' $(if ($ok) { 'OK' } else { 'FALLA' }) ("TestMem5: {0} (informado por el técnico)." -f $(if ($ok) { 'sin errores' } else { 'con errores' }))
    } else {
        $res = 'Con observaciones'
        $Global:M.Ram['Tm5Res'] = 'no terminó'
        Set-Verdict 'RAM' 'ATENCION' ("TestMem5 no llegó a terminar ({0}, {1:N0} min) y no mostró errores hasta ahí." -f $(if ($fin -eq 'tiempo') { 'superó el tiempo esperado' } else { 'se cerró' }), $dur)
    }
    if ($awe) { Set-Verdict 'RAM' 'INFO' 'TestMem5 no pudo usar AWE (memoria bloqueada): probó menos RAM de la habitual. Suele resolverse cerrando sesión y volviendo a entrar, o reiniciando, después del primer uso.' }
    if ($res -ne 'Cancelada') { foreach ($pe in @($Global:Pendientes | Where-Object { $_ -match '^RAM: TestMem5' })) { [void]$Global:Pendientes.Remove($pe) } }
    Add-Prueba 'Memoria RAM (TestMem5)' $dur $res ("{0}{1}" -f $cfgNombre, $(if ($cobertura) { ' · ' + $cobertura }))
}

function Watch-Externo([int]$Sel = 0) {
    Section 'PRUEBA EXTERNA CON VIGILANCIA'
    if ($Sel -lt 1 -or $Sel -gt 5) {
        $ops = @(
            @{ Value = '1'; Label = 'Prime95'; Desc = 'Small FFT: máximo calor y AVX en el CPU' },
            @{ Value = '2'; Label = 'y-cruncher'; Desc = 'stress de CPU con cargas variadas' },
            @{ Value = '3'; Label = 'CoreCycler'; Desc = 'núcleo por núcleo con Prime95/y-cruncher' },
            @{ Value = '4'; Label = 'TestMem5'; Desc = 'memoria RAM' },
            @{ Value = '5'; Label = 'Otro'; Desc = 'cualquier otra prueba (se anota con su nombre)' })
        $sel = [int](Ask-Choice '¿Qué vas a correr?' $ops '1')
    } else { $sel = $Sel }
    $map = @{ 1 = @('Prime95', 'prime95', 'CPU'); 2 = @('y-cruncher', 'ycruncher', 'CPU'); 3 = @('CoreCycler', 'corecycler', 'CPU'); 4 = @('TestMem5', 'tm5', 'RAM'); 5 = @('', '', 'CPU') }
    $tool = $map[$sel][0]; $id = $map[$sel][1]; $area = $map[$sel][2]
    if ($sel -eq 4) { Invoke-TestMem5 (Ask-Int 'Minutos mínimos de TestMem5' 30 5 1440) 'auto'; return }
    if ($sel -eq 5) {
        $tool = Ask 'Nombre de la prueba' 'OCCT'
        if ($tool -match 'furmark|3d|gpu|video|kombustor|heaven|superposition|time ?spy') { $area = 'GPU' }
    }
    $min = Ask-Int 'Minutos máximos de vigilancia' 60 1 1440

    $p95Results = $null; $p95From = 0
    $ccLogDir = $null
    if ($id) {
        $t = Get-ToolStatus | Where-Object { $_.Id -eq $id }
        if ($t.Path) {
            if ($id -eq 'prime95') {
                $p95Results = Join-Path (Split-Path $t.Path) 'results.txt'
                if (Test-Path $p95Results) { $p95From = (Get-Item $p95Results).Length }
            }
            if ($id -eq 'corecycler') { $ccLogDir = Join-Path (Split-Path $t.Path) 'logs' }
            if (Ask-Yes ("¿Abrir {0} ahora?" -f $tool) $true) { [void](Start-Tool $id) }
            switch ($id) {
                'prime95' { Log '  En Prime95: Torture Test > Small FFTs > OK. Para cortar: Test > Stop.' 'DarkGray' }
                'ycruncher' { Log '  En y-cruncher: opción 1 (Component Stress Tester) y Enter para arrancar con todo.' 'DarkGray' }
                'corecycler' { Log '  CoreCycler arranca solo con su config.ini (por defecto Prime95 SSE, 6 min por núcleo).' 'DarkGray' }
            }
        } else {
            Log ("  {0} no está en la carpeta tools (menú H para bajarlo). Abrilo a mano si lo tenés en otro lado." -f $tool) 'Yellow'
        }
    }
    Offer-Monitor
    [void](Start-Sensors)
    $stats = New-SensorStats
    Log ("Vigilando WHEA y frecuencia mientras corre: {0}. Q para terminar antes." -f $tool)
    Set-Marker ("Prueba externa: {0}" -f $tool)
    $start = Get-Date
    $mhz = New-Object System.Collections.Generic.List[double]
    $seen = 0
    while (((Get-Date) - $start).TotalMinutes -lt $min) {
        $m = Get-EffectiveMHz
        if ($m) { $mhz.Add($m) }
        $w = @(Get-WheaSince $start)
        if ($w.Count -gt $seen) {
            foreach ($e in ($w | Select-Object -First ($w.Count - $seen))) { Log ('  !! ' + (Get-EventLine $e)) 'Red' }
            $seen = $w.Count
        }
        $p95e = if ($p95Results) { @(Get-Prime95Errors $p95Results $p95From).Count } else { 0 }
        $sTxt = ''
        if ($Global:Lhm) {
            $sr = Read-Sensors
            Update-SensorStats $stats $sr
            if ($null -ne $sr.CpuTemp) { $sTxt += (' | CPU {0:N0} °C' -f $sr.CpuTemp) }
            if ($null -ne $sr.GpuTemp) { $sTxt += (' | GPU {0:N0} °C' -f $sr.GpuTemp) }
        }
        $el = (Get-Date) - $start
        Write-Progress -Activity ("Vigilando: {0}" -f $tool) -Status ("{0:hh\:mm\:ss} | WHEA {1} | errores Prime95 {2} | {3} MHz{4} | Q = terminar" -f $el, $seen, $p95e, $m, $sTxt) -PercentComplete ([math]::Min(100, 100 * $el.TotalMinutes / $min))
        $t = 0
        while ($t -lt 10) { Start-Sleep -Milliseconds 500; $t++; if (Test-KeyQ) { break } }
        if ($t -lt 10) { break }
    }
    Write-Progress -Activity 'Vigilando' -Completed
    Clear-Marker
    $dur = ((Get-Date) - $start).TotalMinutes
    $s = if ($mhz.Count) { $mhz | Measure-Object -Average -Minimum -Maximum } else { $null }
    Log ("{0}: {1:N0} min vigilados | WHEA {2} | MHz prom/min/max {3:N0}/{4}/{5}" -f $tool, $dur, $seen, $s.Average, $s.Minimum, $s.Maximum)
    $w = @(Get-WheaSince $start)
    if ($w.Count) { Show-Whea $w -DuranteTest }
    Show-SensorStats $stats $tool $area

    $autoFail = $false
    if ($p95Results) {
        $errs = @(Get-Prime95Errors $p95Results $p95From)
        if ($errs.Count) {
            foreach ($l in ($errs | Select-Object -First 10)) { Log ('  Prime95: ' + $l) 'Red' }
            Set-Verdict 'CPU' 'FALLA' ("Prime95 reportó {0} línea(s) de error en results.txt." -f $errs.Count)
            $autoFail = $true
        } else { Log '  Prime95: sin errores en results.txt durante la vigilancia.' 'Green' }
    }
    if ($ccLogDir -and (Test-Path $ccLogDir)) {
        $log = Get-ChildItem -Path $ccLogDir -Filter '*.log' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $start } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($log) {
            $errs = @(Select-String -Path $log.FullName -Pattern 'thrown an error|has failed|^\s*ERROR' -CaseSensitive -ErrorAction SilentlyContinue | ForEach-Object { $_.Line.Trim() })
            Log ("  Log de CoreCycler: {0}" -f $log.FullName) 'DarkGray'
            if ($errs.Count) {
                foreach ($l in ($errs | Select-Object -Unique -First 10)) { Log ('  CoreCycler: ' + $l) 'Red' }
                Set-Verdict 'CPU' 'FALLA' 'CoreCycler reportó núcleos con error (ver líneas arriba y el log).'
                $autoFail = $true
            } else { Log '  CoreCycler: sin errores en el log.' 'Green' }
        }
    }
    $res = 'OK'
    if ($autoFail -or $w.Count) { $res = 'FALLA' }
    if (-not $autoFail) {
        $ok = Ask-Yes ("¿{0} terminó SIN errores?" -f $tool) $true
        if ($ok -and -not $w.Count) { Set-Verdict $area 'OK' ("{0}: {1:N0} min sin errores." -f $tool, $dur) }
        elseif (-not $ok) { Set-Verdict $area 'FALLA' ("{0}: el técnico informa errores." -f $tool); $res = 'FALLA' }
    }
    Add-Prueba $tool $dur $res $(switch ($area) { 'RAM' { 'Prueba de memoria' } 'GPU' { 'Prueba de video' } default { 'Stress de CPU' } })
}

# ======================================================================
#  Discos: lectura de superficie y escritura + verificación
# ======================================================================
function Invoke-DiskRead {
    Section 'DISCO - LECTURA DE SUPERFICIE (no destructivo)'
    $disks = @(Get-Disk | Sort-Object Number)
    if (-not $disks.Count) { Log 'No se encontraron discos.' 'Yellow'; return }
    $ops = @($disks | ForEach-Object { @{ Value = [string]$_.Number; Label = ('Disco {0}: {1}' -f $_.Number, (Get-Clean $_.FriendlyName)); Desc = ('{0} | {1}{2}' -f (Format-Bytes $_.Size), $_.BusType, $(if ($_.IsSystem -or $_.IsBoot) { ' | disco del sistema' } else { '' })) } })
    $num = [int](Ask-Choice '¿Qué disco leer?' $ops ([string]$disks[-1].Number))
    $disk = $disks | Where-Object { $_.Number -eq $num }
    if (-not $disk) { Log 'Disco inexistente.' 'Yellow'; return }
    $full = Ask-Yes '¿Lectura COMPLETA? (N = muestreo de 200 puntos, ~13 GB)' $false
    $name = Get-Clean $disk.FriendlyName
    Log ("Disco {0}: {1} ({2}) - modo {3}" -f $num, $name, (Format-Bytes $disk.Size), $(if ($full) { 'completo' } else { 'muestreo' }))
    Set-Marker ("Lectura de disco {0} ({1})" -f $num, $name)
    $rd = New-Object NetBench.DiskReader -ArgumentList ("\\.\PhysicalDrive{0}" -f $num), ([long]$disk.Size), $full
    $rd.Start()
    $last = 0; $lastT = Get-Date; $speed = 0
    while (-not $rd.Finished) {
        Start-Sleep -Milliseconds 500
        $now = Get-Date; $dt = ($now - $lastT).TotalSeconds
        if ($dt -ge 1) { $speed = ($rd.BytesDone - $last) / 1MB / $dt; $last = $rd.BytesDone; $lastT = $now }
        $pct = if ($rd.BytesPlanned) { [math]::Min(100, 100 * $rd.BytesDone / $rd.BytesPlanned) } else { 0 }
        Write-Progress -Activity ("Leyendo disco {0}" -f $num) -Status ("{0} de {1} | {2:N0} MB/s | errores {3} | lentos {4} | Q = cancelar" -f `
                (Format-Bytes $rd.BytesDone), (Format-Bytes $rd.BytesPlanned), $speed, $rd.Errors, $rd.SlowChunks) -PercentComplete $pct
        if (Test-KeyQ) { $rd.StopFlag = $true }
    }
    Write-Progress -Activity 'Leyendo' -Completed
    Clear-Marker
    if ($rd.Fatal) { Log ("  " + $rd.Fatal) 'Red' }
    $avg = if ($rd.ElapsedSec -gt 0) { $rd.BytesDone / 1MB / $rd.ElapsedSec } else { 0 }
    Log ("Leído {0} en {1:N0} s | promedio {2:N0} MB/s | peor bloque de 4 MB: {3:N0} ms | bloques lentos (>500 ms): {4} | errores: {5}" -f `
            (Format-Bytes $rd.BytesDone), $rd.ElapsedSec, $avg, $rd.WorstMs, $rd.SlowChunks, $rd.Errors)
    $prof = @()
    for ($b = 0; $b -lt [NetBench.DiskReader]::Buckets; $b++) {
        if ($rd.BucketSecs[$b] -gt 0) { $prof += ('{0,3}%:{1,5:N0}' -f ($b * 5), ($rd.BucketBytes[$b] / 1MB / $rd.BucketSecs[$b])) }
    }
    for ($k = 0; $k -lt $prof.Count; $k += 5) { Log ('  MB/s por zona  ' + (($prof[$k..([math]::Min($k + 4, $prof.Count - 1))]) -join '  ')) }
    foreach ($e in ($rd.ErrorList | Select-Object -First 15)) { Log ('  ' + $e) 'Red' }
    if ($rd.Errors -gt 0) { Set-Verdict 'Discos' 'FALLA' ("{0}: {1} zona(s) ilegibles en la lectura de superficie." -f $name, $rd.Errors) }
    elseif ($rd.SlowChunks -gt 0) { Set-Verdict 'Discos' 'ATENCION' ("{0}: {1} bloques que tardaron más de 500 ms (zonas débiles o reintentos internos)." -f $name, $rd.SlowChunks) }
    elseif (-not $rd.Fatal) { Set-Verdict 'Discos' 'OK' ("{0}: lectura de superficie sin errores ({1:N0} MB/s prom)." -f $name, $avg) }
    $res = if ($rd.Errors -gt 0) { 'FALLA' } elseif ($rd.SlowChunks -gt 0) { 'Con observaciones' } elseif ($rd.StopFlag) { 'Cancelada' } else { 'OK' }
    Add-Prueba ("Lectura de superficie: {0}" -f $name) ($rd.ElapsedSec / 60) $res ("{0}, {1:N0} MB/s promedio" -f $(if ($full) { 'completa' } else { 'muestreo' }), $avg)
    if ($disk.BusType -match 'NVMe|SATA' -and $name -notmatch 'HDD|WD\d|ST\d') {
        Log '  En SSD, las zonas vacías (TRIM) se leen sin tocar la NAND: para validar la NAND usá la escritura + verificación.' 'DarkGray'
    }
}

function Invoke-DiskFill {
    Section 'DISCO - ESCRITURA + VERIFICACIÓN (tipo H2testw)'
    Log 'Escribe archivos de 1 GB con datos conocidos en el espacio LIBRE, los relee sin caché y compara. No toca archivos existentes.'
    Log 'Detecta NAND fallada, controlador que corrompe datos y capacidad falsa. Usar en el disco testeado, no en el del sistema.' 'DarkGray'
    $sys = $env:SystemDrive.TrimEnd(':')
    $own = Get-OwnDisk
    $vols = @(Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -in 'Fixed', 'Removable' -and $_.Size -gt 0 -and [string]$_.DriveLetter -ne $own.Letra } | Sort-Object DriveLetter)
    if (-not @($vols | Where-Object { [string]$_.DriveLetter -ne $sys }).Count) {
        Log 'No hay otro disco además del del sistema (y del pendrive del programa): se omite. Para probar un disco, conectalo como secundario.' 'Yellow'
        Add-Prueba 'Escritura y verificación de disco' $null 'Cancelada' 'no había un disco secundario conectado'
        return
    }
    $ops = @()
    foreach ($v in $vols) {
        $model = ''
        try { $model = Get-Clean (Get-Partition -DriveLetter $v.DriveLetter | Get-Disk).FriendlyName } catch {}
        $ops += @{ Value = [string]$v.DriveLetter; Label = ('{0}: {1} {2}' -f $v.DriveLetter, $v.FileSystemLabel, $model).Trim()
            Desc = ('libre {0} de {1}{2}' -f (Format-Bytes $v.SizeRemaining), (Format-Bytes $v.Size), $(if ([string]$v.DriveLetter -eq $sys) { ' | SISTEMA: no se puede usar' } else { '' })) }
    }
    if (-not $ops.Count) { Log 'No hay unidades con letra para probar.' 'Yellow'; return }
    $def = @($ops | Where-Object { $_.Value -ne $sys } | Select-Object -First 1)
    $letter = ([string](Ask-Choice '¿En qué unidad escribir y verificar?' $ops $(if ($def.Count) { $def[0].Value } else { '' }))).ToUpper().TrimEnd(':')
    $vol = $vols | Where-Object { [string]$_.DriveLetter -eq $letter }
    if (-not $vol) { Log 'Unidad inválida.' 'Yellow'; return }
    if ($letter -eq $sys) { Log 'No se testea la unidad del sistema (llenarla deja Windows inestable). Conectá el disco como secundario.' 'Yellow'; return }
    $freeGB = [math]::Floor($vol.SizeRemaining / 1GB) - 1
    if ($freeGB -lt 1) { Log 'No hay espacio libre suficiente.' 'Yellow'; return }
    $gb = Ask-Int ("GB a escribir (todo el libre = {0})" -f $freeGB) $freeGB 1 $freeGB
    $dir = "{0}:\NET_TEST" -f $letter
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $model = ''
    try { $model = Get-Clean (Get-Partition -DriveLetter $letter | Get-Disk).FriendlyName } catch {}
    Log ("Unidad {0}: ({1}) - {2} GB a escribir y verificar en {3}" -f $letter, $model, $gb, $dir)
    Set-Marker ("Escritura+verificación en {0}: ({1})" -f $letter, $model)
    $fv = New-Object NetBench.FillVerify -ArgumentList $dir, $gb, ([long]1GB)
    $fv.Start()
    $last = 0; $lastT = Get-Date; $speed = 0; $lastPhase = 0
    while (-not $fv.Finished) {
        Start-Sleep -Milliseconds 500
        $done = if ($fv.Phase -eq 2) { $fv.BytesVerified } else { $fv.BytesWritten }
        if ($fv.Phase -ne $lastPhase) { $last = $done; $lastPhase = $fv.Phase }
        $now = Get-Date; $dt = ($now - $lastT).TotalSeconds
        if ($dt -ge 1) { $speed = ($done - $last) / 1MB / $dt; $last = $done; $lastT = $now }
        $total = if ($fv.Phase -eq 2) { [double]$fv.FilesWritten * 1GB } else { [double]$gb * 1GB }
        $pct = if ($total) { [math]::Min(100, 100 * $done / $total) } else { 0 }
        $ph = if ($fv.Phase -eq 2) { 'Verificando' } else { 'Escribiendo' }
        Write-Progress -Activity ("{0} {1}:" -f $ph, $letter) -Status ("{0} de {1} | {2:N0} MB/s | errores E/S {3} | bloques corruptos {4} | Q = cancelar" -f `
                (Format-Bytes $done), (Format-Bytes $total), $speed, $fv.IoErrors, $fv.BadChunks) -PercentComplete $pct
        if (Test-KeyQ) { $fv.StopFlag = $true }
    }
    Write-Progress -Activity 'Disco' -Completed
    Clear-Marker
    if ($fv.Fatal) { Log ('  ' + $fv.Fatal) 'Yellow' }
    $w = @($fv.WriteMBs | Select-Object -First $fv.FilesWritten | Where-Object { $_ -gt 0 })
    $r = @($fv.ReadMBs | Select-Object -First $fv.FilesWritten | Where-Object { $_ -gt 0 })
    $ws = if ($w.Count) { $w | Measure-Object -Average -Minimum -Maximum } else { $null }
    $rs = if ($r.Count) { $r | Measure-Object -Average -Minimum } else { $null }
    Log ("Escritos {0} GB | escritura prom/mín/máx {1:N0}/{2:N0}/{3:N0} MB/s | lectura prom/mín {4:N0}/{5:N0} MB/s" -f `
            $fv.FilesWritten, $ws.Average, $ws.Minimum, $ws.Maximum, $rs.Average, $rs.Minimum)
    if ($w.Count -gt 4) {
        $curve = @()
        $step = [math]::Max(1, [math]::Floor($w.Count / 10))
        for ($k = 0; $k -lt $w.Count; $k += $step) { $curve += ('{0}GB:{1:N0}' -f ($k + 1), $w[$k]) }
        Log ('  Escritura MB/s a lo largo del llenado: ' + ($curve -join '  '))
        Log '  (Es normal que caiga cuando se llena la caché SLC; lo raro son caídas a casi cero o cortes.)' 'DarkGray'
    }
    foreach ($e in ($fv.ErrorList | Select-Object -First 15)) { Log ('  ' + $e) 'Red' }
    $removed = $fv.Cleanup()
    Remove-Item -Path $dir -Force -ErrorAction SilentlyContinue
    Log ("Archivos de prueba borrados: {0}" -f $removed) 'DarkGray'
    if ($fv.BadChunks -gt 0) { Set-Verdict 'Discos' 'FALLA' ("{0}: DATOS CORRUPTOS en {1} bloques de 4 MB (lo leído no coincide con lo escrito). No apto." -f $model, $fv.BadChunks) }
    if ($fv.IoErrors -gt 0) { Set-Verdict 'Discos' 'FALLA' ("{0}: {1} errores de E/S en escritura/lectura." -f $model, $fv.IoErrors) }
    if ($fv.Fatal -match 'lleno') { Set-Verdict 'Discos' 'ATENCION' ("{0}: se llenó antes de lo que Windows informaba como libre (¿capacidad falsa?)." -f $model) }
    if ($ws -and $ws.Minimum -lt 30 -and $fv.FilesWritten -gt 2) { Set-Verdict 'Discos' 'ATENCION' ("{0}: escritura mínima {1:N0} MB/s tras llenar la caché (QLC sin caché o NAND gastada)." -f $model, $ws.Minimum) }
    if ($fv.BadChunks -eq 0 -and $fv.IoErrors -eq 0 -and $fv.FilesWritten -gt 0 -and -not $fv.StopFlag) {
        Set-Verdict 'Discos' 'OK' ("{0}: {1} GB escritos y verificados sin errores." -f $model, $fv.FilesWritten)
    }
    $res = if ($fv.BadChunks -gt 0 -or $fv.IoErrors -gt 0) { 'FALLA' } elseif ($fv.StopFlag) { 'Cancelada' } else { 'OK' }
    Add-Prueba ("Escritura y verificación: {0}" -f $model) $null $res ("{0} GB escritos y releídos" -f $fv.FilesWritten)
}

# ======================================================================
#  Herramientas externas: detección, descarga automática y lanzadores
#  (todo se guarda en la carpeta "tools", así viaja en el pendrive)
# ======================================================================
$ToolsDir = Join-Path $Root 'tools'
$NoAskFile = Join-Path $ToolsDir '.no_preguntar'

# Respaldo por si no se puede consultar la última versión
$Fallback = @{
    Prime95Url    = 'https://download.mersenne.ca/gimps/v30/30.19/p95v3019b20.win64.zip'
    Prime95Sha    = 'd9475f2ff3f4a6a701abc49a86a66126cb48abd10bda6fa87039d98fa8756bca'
    CoreCyclerUrl = 'https://github.com/sp00n/CoreCycler/releases/download/v0.11.0.3/CoreCycler-v0.11.0.3.7z'
    SevenZrUrls   = @('https://github.com/ip7z/7zip/releases/download/26.05/7zr.exe', 'https://www.7-zip.org/a/7zr.exe')
    SmartVersions = @('7.5-1', '7.5-2', '7.4-1')
    LhmUrl        = 'https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases/download/v0.9.6/LibreHardwareMonitor.zip'
    MemtestVkUrl  = 'https://github.com/GpuZelenograd/memtest_vulkan/releases/download/v0.5.0/memtest_vulkan-v0.5.0.exe'
    TestMem5Url   = 'https://github.com/CoolCmd/TestMem5/releases/download/v0.13.1/TestMem5.7z'
}

function Find-ToolFile([string]$Sub, [string]$FileName) {
    $dir = Join-Path $ToolsDir $Sub
    if (-not (Test-Path $dir)) { return $null }
    $f = Get-ChildItem -Path $dir -Filter $FileName -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { return $f.FullName }
    return $null
}

function Get-ToolStatus {
    @(
        [pscustomobject]@{ Id = 'smartctl'; Nombre = 'smartctl (smartmontools)'; Uso = 'SMART y autotest de discos'; Path = (Find-Smartctl); Auto = $true }
        [pscustomobject]@{ Id = 'prime95'; Nombre = 'Prime95'; Uso = 'Stress de CPU, máximo calor y AVX'; Path = (Find-ToolFile 'Prime95' 'prime95.exe'); Auto = $true }
        [pscustomobject]@{ Id = 'corecycler'; Nombre = 'CoreCycler'; Uso = 'Test por núcleo con Prime95/y-cruncher'; Path = (Find-ToolFile 'CoreCycler' 'Run CoreCycler.bat'); Auto = $true }
        [pscustomobject]@{ Id = 'ycruncher'; Nombre = 'y-cruncher (viene con CoreCycler)'; Uso = 'Stress de CPU con cargas variadas'; Path = (Find-ToolFile 'CoreCycler' 'y-cruncher.exe'); Auto = $false }
        [pscustomobject]@{ Id = 'memtestvk'; Nombre = 'memtest_vulkan'; Uso = 'Test de memoria de video (VRAM)'; Path = (Find-ToolFile 'memtest_vulkan' 'memtest_vulkan*.exe'); Auto = $true }
        [pscustomobject]@{ Id = 'lhm'; Nombre = 'LibreHardwareMonitor'; Uso = 'Temperaturas, voltajes, frecuencias'; Path = (Find-ToolFile 'LibreHardwareMonitor' 'LibreHardwareMonitor.exe'); Auto = $true }
        [pscustomobject]@{ Id = 'tm5'; Nombre = 'TestMem5 0.13'; Uso = 'Test de RAM (se configura y se lee solo)'; Path = (Find-TestMem5); Auto = $true }
    )
}

function Initialize-Net {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
}

function Test-Internet {
    try {
        $null = Invoke-WebRequest -Uri 'https://api.github.com' -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        return $true
    } catch { return $false }
}

function Test-ExeFile([string]$Path) {
    try {
        $fs = [IO.File]::OpenRead($Path)
        try { return ($fs.ReadByte() -eq 0x4D -and $fs.ReadByte() -eq 0x5A) } finally { $fs.Dispose() }
    } catch { return $false }
}

function Save-Url([string]$Url, [string]$Dest, [string]$Sha256) {
    $old = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'   # en PS 5.1 la barra de progreso hace lentísima la descarga
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -UserAgent 'NET-TestBench' -TimeoutSec 900 -ErrorAction Stop
        if (-not (Test-Path $Dest) -or (Get-Item $Dest).Length -lt 1024) { throw 'archivo vacío' }
        if ($Sha256) {
            $h = (Get-FileHash -Path $Dest -Algorithm SHA256).Hash
            if ($h -ne $Sha256) { Remove-Item $Dest -Force -ErrorAction SilentlyContinue; throw "el hash SHA-256 no coincide (archivo alterado o incompleto)" }
        }
        return $true
    } catch {
        Log ("    No se pudo bajar {0}: {1}" -f $Url, $_.Exception.Message) 'DarkGray'
        return $false
    } finally { $ProgressPreference = $old }
}

function Get-GitHubLatestAsset([string]$Repo, [string]$Pattern, [string]$Prefer, [string]$Exclude) {
    try {
        $r = Invoke-RestMethod -Uri ("https://api.github.com/repos/{0}/releases/latest" -f $Repo) -UseBasicParsing -TimeoutSec 30 `
            -Headers @{ 'User-Agent' = 'NET-TestBench'; 'Accept' = 'application/vnd.github+json' } -ErrorAction Stop
        $assets = @($r.assets | Where-Object { $_.name -match $Pattern -and (-not $Exclude -or $_.name -notmatch $Exclude) })
        if ($Prefer) {
            $pref = @($assets | Where-Object { $_.name -match $Prefer })
            if ($pref.Count) { $assets = $pref }
        }
        if ($assets.Count) {
            $a = $assets[0]
            $sha = $null
            if ($a.digest -and [string]$a.digest -match '^sha256:([0-9a-fA-F]{64})$') { $sha = $Matches[1] }
            return [pscustomobject]@{ Url = $a.browser_download_url; Name = $a.name; Sha256 = $sha; Tag = $r.tag_name }
        }
    } catch {}
    return $null
}

function Get-7zr {
    $p = Join-Path $ToolsDir '7zr.exe'
    if ((Test-Path $p) -and (Test-ExeFile $p)) { return $p }
    $a = Get-GitHubLatestAsset 'ip7z/7zip' '^7zr\.exe$'
    $urls = @()
    if ($a) { $urls += $a.Url }
    $urls += $Fallback.SevenZrUrls
    foreach ($u in $urls) {
        if ((Save-Url $u $p $null) -and (Test-ExeFile $p)) { return $p }
    }
    return $null
}

function Install-Smartctl {
    $dest = Join-Path $ToolsDir 'smartctl.exe'
    $pf = Join-Path $env:ProgramFiles 'smartmontools\bin\smartctl.exe'
    if (-not (Test-Path $pf)) {
        $wg = Get-Command winget.exe -ErrorAction SilentlyContinue
        if ($wg) {
            Log '    Instalando smartmontools con winget...'
            & $wg.Source install -e --id smartmontools.smartmontools --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
        }
    }
    if (-not (Test-Path $pf)) {
        Log '    Probando el instalador oficial (SourceForge)...'
        foreach ($v in $Fallback.SmartVersions) {
            $ver = $v.Split('-')[0]
            $u = "https://sourceforge.net/projects/smartmontools/files/smartmontools/$ver/smartmontools-$v.win32-setup.exe/download"
            $tmp = Join-Path $env:TEMP "smartmontools-$v-setup.exe"
            if ((Save-Url $u $tmp $null) -and (Test-ExeFile $tmp)) {
                Start-Process -FilePath $tmp -ArgumentList '/S' -Wait
                Remove-Item $tmp -Force -ErrorAction SilentlyContinue
                if (Test-Path $pf) { break }
            }
        }
    }
    if (Test-Path $pf) {
        Copy-Item -Path $pf -Destination $dest -Force   # copia portable para el pendrive
        return $true
    }
    return $false
}

function Install-Prime95 {
    $dir = Join-Path $ToolsDir 'Prime95'
    $url = $null
    try {
        $page = Invoke-WebRequest -Uri 'https://www.mersenne.org/download/' -UseBasicParsing -UserAgent 'NET-TestBench' -TimeoutSec 30 -ErrorAction Stop
        $m = [regex]::Match($page.Content, 'https?://[^"''\s<>]+?p95v\d+b\d+\.win64\.zip')
        if ($m.Success) { $url = $m.Value }
    } catch {}
    if (-not $url) { $url = $Fallback.Prime95Url }
    $sha = if ($url -eq $Fallback.Prime95Url) { $Fallback.Prime95Sha } else { $null }
    $zip = Join-Path $env:TEMP 'prime95.zip'
    if (-not (Save-Url $url $zip $sha)) { return $false }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Expand-Archive -Path $zip -DestinationPath $dir -Force
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    $exe = Find-ToolFile 'Prime95' 'prime95.exe'
    if (-not $exe) { return $false }
    # Evita la pregunta de "unirse a GIMPS": modo solo stress test, sin conexión
    $pt = Join-Path (Split-Path $exe) 'prime.txt'
    if (-not (Test-Path $pt)) { "StressTester=1`r`nUsePrimenet=0`r`n" | Set-Content -Path $pt -Encoding ASCII }
    return $true
}

function Install-CoreCycler {
    $z = Get-7zr
    if (-not $z) { Log '    No se pudo conseguir 7zr.exe para descomprimir CoreCycler.' 'Yellow'; return $false }
    $a = Get-GitHubLatestAsset 'sp00n/CoreCycler' '\.7z$'
    $url = if ($a) { $a.Url } else { $Fallback.CoreCyclerUrl }
    $sha = if ($a) { $a.Sha256 } else { $null }
    $arch = Join-Path $env:TEMP 'corecycler.7z'
    if (-not (Save-Url $url $arch $sha)) { return $false }
    $dir = Join-Path $ToolsDir 'CoreCycler'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    & $z x $arch ("-o{0}" -f $dir) -y | Out-Null
    $ok = ($LASTEXITCODE -eq 0)
    Remove-Item $arch -Force -ErrorAction SilentlyContinue
    return ($ok -and [bool](Find-ToolFile 'CoreCycler' 'Run CoreCycler.bat'))
}

# TestMem5 0.13 (fork de CoolCmd): trae las configs de anta777/1usmus, se configura por TM5.ini y escribe Log.txt
function Find-TestMem5 {
    $exe = Find-ToolFile 'TestMem5' 'TM5.exe'
    if ($exe -and (Test-Path (Join-Path (Split-Path $exe) 'TM5.dll'))) { return $exe }   # sin TM5.dll = la 0.12 vieja
    return $null
}

function Install-TestMem5 {
    $z = Get-7zr
    if (-not $z) { Log '    No se pudo conseguir 7zr.exe para descomprimir TestMem5.' 'Yellow'; return $false }
    $a = Get-GitHubLatestAsset 'CoolCmd/TestMem5' '^TestMem5\.7z$'
    $url = if ($a) { $a.Url } else { $Fallback.TestMem5Url }
    $sha = if ($a) { $a.Sha256 } else { $null }
    $arch = Join-Path $env:TEMP 'testmem5.7z'
    if (-not (Save-Url $url $arch $sha)) { return $false }
    $dir = Join-Path $ToolsDir 'TestMem5'
    if ((Test-Path $dir) -and -not (Test-Path (Join-Path $dir 'TM5.dll'))) {
        # había una 0.12 copiada a mano: se guarda aparte por si tenía configs propias
        $viejo = Join-Path $ToolsDir 'TestMem5-0.12'
        Remove-Item $viejo -Recurse -Force -ErrorAction SilentlyContinue
        Rename-Item -Path $dir -NewName 'TestMem5-0.12' -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    & $z x $arch ("-o{0}" -f $dir) -y | Out-Null
    $ok = ($LASTEXITCODE -eq 0)
    Remove-Item $arch -Force -ErrorAction SilentlyContinue
    return ($ok -and [bool](Find-TestMem5))
}

function Install-LHM {
    # El zip "LibreHardwareMonitor.zip" es el de .NET Framework 4.7.2 (carga en PowerShell 5.1);
    # el ".NET.10" necesita otro runtime y no sirve para el script.
    $a = Get-GitHubLatestAsset 'LibreHardwareMonitor/LibreHardwareMonitor' '\.zip$' '^LibreHardwareMonitor\.zip$' 'NET\.\d+|net\d{2,}|Lib\.zip'
    if (-not $a) { $a = [pscustomobject]@{ Url = $Fallback.LhmUrl; Sha256 = $null } }
    $zip = Join-Path $env:TEMP 'lhm.zip'
    if (-not (Save-Url $a.Url $zip $a.Sha256)) { return $false }
    $dir = Join-Path $ToolsDir 'LibreHardwareMonitor'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Expand-Archive -Path $zip -DestinationPath $dir -Force
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    return [bool](Find-ToolFile 'LibreHardwareMonitor' 'LibreHardwareMonitor.exe')
}

function Install-Tools([object[]]$Lista) {
    Initialize-Net
    New-Item -ItemType Directory -Force -Path $ToolsDir | Out-Null
    Write-Host '  Verificando conexión...' -ForegroundColor DarkGray
    if (-not (Test-Internet)) {
        Write-Host '  Sin internet. Bajalas en una PC con conexión usando este mismo pendrive (menú H) y quedan guardadas.' -ForegroundColor Yellow
        return
    }
    foreach ($t in $Lista) {
        Write-Host ("  Descargando {0}..." -f $t.Nombre) -ForegroundColor White
        $ok = $false
        try {
            switch ($t.Id) {
                'smartctl' { $ok = Install-Smartctl }
                'prime95' { $ok = Install-Prime95 }
                'corecycler' { $ok = Install-CoreCycler }
                'lhm' { $ok = Install-LHM }
                'memtestvk' { $ok = Install-MemtestVulkan }
                'tm5' { $ok = Install-TestMem5 }
            }
        } catch { Write-Host ("    Error: {0}" -f $_.Exception.Message) -ForegroundColor DarkGray }
        if ($ok) { Write-Host ("    OK: {0}" -f $t.Nombre) -ForegroundColor Green }
        else { Write-Host ("    No se pudo instalar {0}. Se puede bajar a mano (ver LEEME)." -f $t.Nombre) -ForegroundColor Yellow }
    }
}

function Initialize-Tools {
    $falt = @(Get-ToolStatus | Where-Object { -not $_.Path -and $_.Auto })
    if (-not $falt.Count) { return }
    if (Test-Path $NoAskFile) { return }
    Write-Host ''
    Write-Host '  Faltan herramientas en la carpeta tools:' -ForegroundColor Yellow
    foreach ($t in $falt) { Write-Host ("    - {0}: {1}" -f $t.Nombre, $t.Uso) }
    $a = Ask-Choice '¿Descargarlas ahora?' @(
        @{ Value = 'S'; Label = 'Sí, descargar'; Desc = 'quedan en la carpeta tools (necesita internet)' },
        @{ Value = 'N'; Label = 'Ahora no'; Desc = 'se vuelve a preguntar la próxima vez' },
        @{ Value = 'X'; Label = 'No preguntar más'; Desc = 'se pueden bajar después desde Herramientas' }) 'S'
    if ($a -match '^[xX]') { New-Item -ItemType Directory -Force -Path $ToolsDir | Out-Null; '' | Set-Content -Path $NoAskFile; return }
    if ($a -match '^[sSyY]') { Install-Tools $falt }
}

function Start-Tool([string]$Id) {
    $t = Get-ToolStatus | Where-Object { $_.Id -eq $Id }
    if (-not $t -or -not $t.Path) { return $false }
    try {
        if ($t.Path -like '*.bat') { Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', ('"{0}"' -f $t.Path) -WorkingDirectory (Split-Path $t.Path) }
        else { Start-Process -FilePath $t.Path -WorkingDirectory (Split-Path $t.Path) }
        return $true
    } catch { return $false }
}

function Offer-Monitor {
    if ($Global:MonitorOfrecido) { return }
    $Global:MonitorOfrecido = $true
    $lhm = Get-ToolStatus | Where-Object { $_.Id -eq 'lhm' }
    if ($lhm.Path -and -not (Get-Process -Name 'LibreHardwareMonitor', 'HWiNFO64' -ErrorAction SilentlyContinue)) {
        if (Ask-Yes '¿Abrir LibreHardwareMonitor para ver temperaturas durante la prueba?' $true) { [void](Start-Tool 'lhm') }
    }
}

function Show-Herramientas {
    while ($true) {
        Write-Host ''
        Write-Host '  HERRAMIENTAS (carpeta tools)' -ForegroundColor Cyan
        $list = @(Get-ToolStatus)
        for ($i = 0; $i -lt $list.Count; $i++) {
            $t = $list[$i]
            $st = if ($t.Path) { 'OK      ' } else { 'FALTA   ' }
            $col = if ($t.Path) { 'Green' } else { 'Yellow' }
            Write-Host ("   {0}) {1} {2,-44} {3}" -f ($i + 1), $st, $t.Nombre, $t.Uso) -ForegroundColor $col
        }
        Write-Host '   D) Descargar las que faltan    A) Actualizar todas    0) Volver'
        $op = (Read-Host 'Opción (número = abrir)').Trim()
        if ($op -eq '0' -or $op -eq '') { return }
        if ($op -match '^[dD]$') { Remove-Item $NoAskFile -ErrorAction SilentlyContinue; Install-Tools @($list | Where-Object { -not $_.Path -and $_.Auto }); continue }
        if ($op -match '^[aA]$') {
            foreach ($sub in 'Prime95', 'CoreCycler', 'LibreHardwareMonitor', 'memtest_vulkan') {
                Remove-Item -Path (Join-Path $ToolsDir $sub) -Recurse -Force -ErrorAction SilentlyContinue
            }
            Remove-Item -Path (Join-Path $ToolsDir 'smartctl.exe') -Force -ErrorAction SilentlyContinue
            Install-Tools @($list | Where-Object { $_.Auto })
            continue
        }
        $n = 0
        if ([int]::TryParse($op, [ref]$n) -and $n -ge 1 -and $n -le $list.Count) {
            $t = $list[$n - 1]
            if ($t.Id -eq 'smartctl') { Write-Host '  smartctl se usa desde las opciones 1 y 4 del menú.' -ForegroundColor DarkGray }
            elseif (-not (Start-Tool $t.Id)) { Write-Host '  No está disponible.' -ForegroundColor Yellow }
        }
    }
}

# Busca errores en el results.txt de Prime95 escritos después de cierto punto del archivo
function Get-Prime95Errors([string]$ResultsFile, [long]$FromByte) {
    if (-not (Test-Path $ResultsFile)) { return @() }
    try {
        $fs = [IO.File]::Open($ResultsFile, 'Open', 'Read', 'ReadWrite')
        try {
            if ($FromByte -gt $fs.Length) { $FromByte = 0 }
            [void]$fs.Seek($FromByte, 'Begin')
            $txt = (New-Object IO.StreamReader($fs)).ReadToEnd()
        } finally { $fs.Dispose() }
        return @($txt -split "`r?`n" | Where-Object { $_ -match 'FATAL ERROR|Hardware failure|ILLEGAL SUMOUT|SUM\(INPUTS\) != SUM\(OUTPUTS\)|Possible hardware|Rounding was .* expected less than|[1-9]\d* errors?,' })
    } catch { return @() }
}

# ======================================================================
#  Métricas de la sesión (alimentan el historial, el informe HTML y el JSON)
# ======================================================================
$MotorVersion = '1'      # cambia si cambia la carga de trabajo del motor (invalida comparaciones)
$HistFile = Join-Path $ReportDir 'historial.csv'
function New-Session {
    $Global:Verdicts = [ordered]@{}
    $Global:Pendientes = New-Object System.Collections.ArrayList
    $Global:SesionSensores = $null
    $Global:AvisosSensor = @{}
    $Global:ReportFile = $null
    $Global:InformeHtml = $null
    $Global:InformePdf = $null
    $Global:InformeOrdenPdf = $null
    $Global:InformeOrdenHtml = $null
    $Global:StepState = @{}
    $Global:Started = $false
    $Global:GpuIdDone = $false
    $Global:M = [ordered]@{
    Sesion   = ([guid]::NewGuid().ToString('N').Substring(0, 10))
    Version  = $Version
    Fecha    = (Get-Date -Format 's')
    Orden    = ''
    Pieza    = ''
    Grupo    = ''
    Suelta   = $false
    Tecnico  = ''
    PC       = $env:COMPUTERNAME
    Equipo   = [ordered]@{}
    Cpu      = [ordered]@{}
    Sensores = [ordered]@{}
    Ram      = [ordered]@{}
    Gpu      = [ordered]@{}
    Fuente   = [ordered]@{}
    Discos   = (New-Object System.Collections.ArrayList)
    Pruebas  = (New-Object System.Collections.ArrayList)
    }
}
New-Session

function Add-Prueba([string]$Nombre, $Minutos, [string]$Resultado, [string]$Detalle = '') {
    [void]$Global:M.Pruebas.Add([ordered]@{ Nombre = $Nombre; Minutos = $(if ($null -ne $Minutos) { [math]::Round([double]$Minutos, 1) } else { $null }); Resultado = $Resultado; Detalle = $Detalle })
}

function Get-WorstState([string[]]$States) {
    $w = 'OK'
    foreach ($s in $States) { if ($s -and $Rank[$s] -gt $Rank[$w]) { $w = $s } }
    return $w
}

# ======================================================================
#  Sensores (LibreHardwareMonitorLib desde la carpeta tools)
# ======================================================================
$Global:Lhm = $null
$Global:LhmState = $null
$Global:SesionSensores = $null

function New-SensorStats {
    return @{ CpuTempMax = $null; CpuPowerMax = $null; V12Min = $null; V12Max = $null; VrmMax = $null; GpuTempMax = $null; GpuPowerMax = $null
        GpuHotMax = $null; GpuMemMax = $null; GpuDeltaMax = $null; GpuLoadSum = 0.0; GpuLoadN = 0; GpuName = $null; Muestras = 0 }
}

function Get-PrefSensor($List, [string]$Type, [string[]]$Names, [string]$Like) {
    $c = @($List | Where-Object { [string]$_.SensorType -eq $Type -and $null -ne $_.Value })
    foreach ($n in $Names) {
        $m = $c | Where-Object { $_.Name -eq $n } | Select-Object -First 1
        if ($m) { return [double]$m.Value }
    }
    if ($Like) {
        $m = $c | Where-Object { $_.Name -like "*$Like*" } | Sort-Object -Property Value -Descending | Select-Object -First 1
        if ($m) { return [double]$m.Value }
    }
    return $null
}

function Start-Sensors {
    if ($Global:LhmState) { return ($Global:LhmState -eq 'ok') }
    $dll = Find-ToolFile 'LibreHardwareMonitor' 'LibreHardwareMonitorLib.dll'
    if (-not $dll) {
        $Global:LhmState = 'sin-dll'
        Log '  Sensores: falta LibreHardwareMonitor (menú H). El reporte va a salir sin temperaturas.' 'Yellow'
        return $false
    }
    try {
        [NetBench.AsmResolver]::Install((Split-Path $dll))
        $asm = [Reflection.Assembly]::LoadFrom($dll)
        $pawn = $null
        try { $pawn = [bool]$asm.GetType('LibreHardwareMonitor.PawnIo.PawnIo').GetProperty('IsInstalled').GetValue($null, $null) } catch {}
        $c = New-Object LibreHardwareMonitor.Hardware.Computer
        $c.IsCpuEnabled = $true
        $c.IsMotherboardEnabled = $true
        $c.IsGpuEnabled = $true
        $c.Open()
        $Global:Lhm = $c
        $s = Read-Sensors
        if ($null -eq $s.CpuTemp) {
            $Global:LhmState = 'parcial'
            if ($pawn -eq $false) {
                Log '  Sensores: falta el driver PawnIO. Abrí LibreHardwareMonitor una vez (menú H), aceptá instalarlo y volvé a abrir el script.' 'Yellow'
            } else {
                Log '  Sensores: no se encontró la temperatura del CPU en esta placa/CPU.' 'Yellow'
            }
        } else {
            $Global:LhmState = 'ok'
            Log ("  Sensores OK: CPU {0:N0} °C{1}{2}" -f $s.CpuTemp, $(if ($null -ne $s.CpuPower) { (" | {0:N0} W" -f $s.CpuPower) }), $(if ($null -ne $s.V12) { (" | +12V {0:N2} V" -f $s.V12) })) 'DarkGray'
        }
        return ($Global:LhmState -eq 'ok')
    } catch {
        $Global:LhmState = 'error'
        Log ("  No se pudieron leer los sensores: {0}" -f $_.Exception.GetBaseException().Message) 'Yellow'
        return $false
    }
}

# Índice NVAPI de la placa NVIDIA que LibreHardwareMonitor llama $Nombre (cache por nombre)
function Get-NvThermalIndex([string]$Nombre) {
    if (-not $Global:NvIdx) { $Global:NvIdx = @{} }
    if ($Global:NvIdx.ContainsKey($Nombre)) { return $Global:NvIdx[$Nombre] }
    $idx = -1
    try {
        $n = [NetBench.NvThermal]::Count
        $norm = { param($x) (([string]$x) -replace '(?i)nvidia', '' -replace '\s+', '').ToUpper() }
        for ($i = 0; $i -lt $n; $i++) { if ((& $norm ([NetBench.NvThermal]::Name($i))) -eq (& $norm $Nombre)) { $idx = $i; break } }
        if ($idx -lt 0 -and $n -eq 1) { $idx = 0 }
    } catch {}
    $Global:NvIdx[$Nombre] = $idx
    return $idx
}

# Máximo de cada sensor de temperatura de la GPU (para comparar con HWiNFO/GPU-Z en el reporte técnico)
function Update-GpuTempDump([string]$Clave, $Valor) {
    if ($null -eq $Valor -or $Valor -le 0 -or $Valor -ge 150) { return }
    if (-not $Global:GpuTempDump) { $Global:GpuTempDump = [ordered]@{} }
    if (-not $Global:GpuTempDump.Contains($Clave) -or $Valor -gt $Global:GpuTempDump[$Clave]) { $Global:GpuTempDump[$Clave] = [double]$Valor }
}

function Read-Sensors {
    $r = @{ CpuTemp = $null; CpuPower = $null; V12 = $null; Vrm = $null; GpuTemp = $null; GpuPower = $null; GpuHot = $null; GpuMem = $null; GpuLoad = $null; GpuName = $null }
    if (-not $Global:Lhm) { return $r }
    $gpus = New-Object System.Collections.ArrayList
    try {
        foreach ($h in $Global:Lhm.Hardware) {
            $h.Update()
            $all = New-Object System.Collections.ArrayList
            foreach ($x in $h.Sensors) { [void]$all.Add($x) }
            foreach ($sub in $h.SubHardware) { $sub.Update(); foreach ($x in $sub.Sensors) { [void]$all.Add($x) } }
            $type = [string]$h.HardwareType
            if ($type -eq 'Cpu') {
                $t = Get-PrefSensor $all 'Temperature' @('Core (Tctl/Tdie)', 'Core (Tctl)', 'CPU Package', 'Core Max', 'Core (Tdie)', 'CCDs Max (Tdie)') 'Core'
                if ($null -ne $t -and $t -gt 0 -and $t -lt 130) { $r.CpuTemp = $t }
                $p = Get-PrefSensor $all 'Power' @('Package', 'CPU Package') 'Package'
                if ($null -ne $p -and $p -gt 0 -and $p -lt 1000) { $r.CpuPower = $p }
            } elseif ($type -eq 'Motherboard') {
                $v = Get-PrefSensor $all 'Voltage' @('+12V', '+12V Voltage', '12V')
                if ($null -ne $v -and $v -ge 10 -and $v -le 13.5) { $r.V12 = $v }   # fuera de ese rango: canal mal mapeado, se ignora
                $t = Get-PrefSensor $all 'Temperature' @('VRM MOS', 'VRM') 'VRM'
                if ($null -ne $t -and $t -gt 0 -and $t -lt 150) { $r.Vrm = $t }
            } elseif ($type -like 'Gpu*') {
                $ok = { param($v, $max) if ($null -ne $v -and $v -gt 0 -and $v -lt $max) { $v } else { $null } }
                $hot = (& $ok (Get-PrefSensor $all 'Temperature' @('GPU Hot Spot', 'GPU Hotspot') 'Hot') 150)
                $hw = ([string]$h.Name) -replace '(?i)^(NVIDIA|AMD)\s+', ''
                foreach ($x in $all) { if ([string]$x.SensorType -eq 'Temperature') { Update-GpuTempDump ('{0} · {1}' -f $hw, $x.Name) $x.Value } }
                if ($type -eq 'GpuNvidia') {
                    # Hotspot de NVAPI (el de GPU-Z/HWiNFO). Con PawnIO, LibreHardwareMonitor informa el máximo de
                    # varios canales internos, que en algunas placas da 15-20 °C de más. Las RTX 50 no lo publican.
                    $ix = Get-NvThermalIndex ([string]$h.Name)
                    if ($ix -ge 0) {
                        $raw = $null
                        try { $raw = [NetBench.NvThermal]::Temps($ix) } catch {}
                        if ($raw) {
                            $nv = [int][NetBench.NvThermal]::ValidCount($ix)
                            for ($k = 0; $k -lt [math]::Min($nv, 32); $k++) { Update-GpuTempDump ('{0} · NVAPI[{1}]' -f $hw, $k) $raw[$k] }
                            if (-not (Test-Rtx50 $h.Name) -and $nv -ge 2 -and $raw[1] -gt 0 -and $raw[1] -lt 150) {
                                if ($null -ne $hot -and [math]::Abs($hot - $raw[1]) -ge 3) { $Global:NvHotCorregido = $true }
                                $hot = [double]$raw[1]
                            }
                        }
                    }
                }
                [void]$gpus.Add(@{
                        Name  = [string]$h.Name
                        Core  = (& $ok (Get-PrefSensor $all 'Temperature' @('GPU Core') 'Core') 150)
                        Hot   = $hot
                        Mem   = (& $ok (Get-PrefSensor $all 'Temperature' @('GPU Memory Junction', 'GPU Memory') 'Memory') 150)
                        Power = (& $ok (Get-PrefSensor $all 'Power' @('GPU Package', 'GPU Power', 'GPU Board Power', 'GPU PPT', 'Board Power') 'GPU') 2000)
                        Load  = (Get-PrefSensor $all 'Load' @('GPU Core', 'D3D 3D', 'GPU') 'GPU')
                    })
            }
        }
        # Si hay varias GPU (iGPU + placa), se toma la que más trabaja
        $best = $gpus | Sort-Object -Property @{ Expression = { if ($null -ne $_.Load) { $_.Load } else { -1 } } }, @{ Expression = { if ($null -ne $_.Power) { $_.Power } else { -1 } } } -Descending | Select-Object -First 1
        if ($best) {
            $r.GpuName = $best.Name; $r.GpuHot = $best.Hot; $r.GpuMem = $best.Mem; $r.GpuPower = $best.Power; $r.GpuLoad = $best.Load
            $r.GpuTemp = if ($null -ne $best.Core) { $best.Core } else { $best.Hot }
        }
    } catch {}
    return $r
}

function Update-SensorStats($St, $R) {
    if (-not $St -or -not $R) { return }
    $St.Muestras++
    if ($null -ne $R.GpuLoad) { $St.GpuLoadSum += $R.GpuLoad; $St.GpuLoadN++ }
    if ($R.GpuName) { $St.GpuName = $R.GpuName }
    if (-not $St.ContainsKey('Win')) { $St['Win'] = @{}; $St['Peak'] = @{} }
    $vals = @{}
    foreach ($k in 'CpuTemp', 'CpuPower', 'Vrm', 'GpuTemp', 'GpuPower', 'V12', 'GpuHot', 'GpuMem') { $vals[$k] = $R[$k] }
    $vals['Total'] = $(if ($null -ne $R.CpuPower -and $null -ne $R.GpuPower) { $R.CpuPower + $R.GpuPower } else { $null })
    $vals['GpuDelta'] = $(if ($null -ne $R.GpuTemp -and $null -ne $R.GpuHot -and $R.GpuHot -ge $R.GpuTemp) { $R.GpuHot - $R.GpuTemp } else { $null })
    foreach ($k in @($vals.Keys)) {
        $v = $vals[$k]
        if ($null -eq $v) { continue }
        $w = $St.Win[$k]
        if (-not $w) { $w = New-Object System.Collections.Generic.List[double]; $St.Win[$k] = $w }
        $w.Add([double]$v)
        if ($w.Count -gt 3) { $w.RemoveAt(0) }
        $o = @($w | Sort-Object)
        # sostenido: con 3 lecturas, la del medio; con menos, la más baja (un pico suelto no cuenta)
        $hi = if ($o.Count -ge 3) { $o[1] } else { $o[0] }
        $lo = if ($o.Count -ge 3) { $o[1] } else { $o[-1] }
        $mk = $k + 'Max'
        if ($null -eq $St[$mk] -or $hi -gt $St[$mk]) { $St[$mk] = $hi }
        if ($k -eq 'V12' -and ($null -eq $St.V12Min -or $lo -lt $St.V12Min)) { $St.V12Min = $lo }
        if ($null -eq $St.Peak[$k] -or $v -gt $St.Peak[$k]) { $St.Peak[$k] = [double]$v }
    }
    # acumulado de toda la sesión
    if (-not $Global:SesionSensores) { $Global:SesionSensores = New-SensorStats }
    if (-not [object]::ReferenceEquals($St, $Global:SesionSensores)) { Update-SensorStats $Global:SesionSensores $R }
}

function Get-CpuTempLimit {
    $n = if ($Global:Cpu) { $Global:Cpu.Nombre } else { '' }
    if ($n -match 'X3D') { return 89 }
    if ($n -match 'AMD|Ryzen') { return 95 }
    if ($n -match 'Intel') { return 100 }
    return 95
}

function Show-SensorStats($St, [string]$Contexto, [string]$Area = 'CPU') {
    if (-not $St -or $St.Muestras -eq 0) { return }
    $parts = @()
    if ($null -ne $St.CpuTempMax) { $parts += ("CPU máx {0:N0} °C" -f $St.CpuTempMax) }
    if ($null -ne $St.CpuPowerMax) { $parts += ("{0:N0} W" -f $St.CpuPowerMax) }
    if ($null -ne $St.VrmMax) { $parts += ("VRM máx {0:N0} °C" -f $St.VrmMax) }
    if ($null -ne $St.V12Min) { $parts += ("+12V mín {0:N2} V" -f $St.V12Min) }
    if ($null -ne $St.GpuTempMax) { $parts += ("GPU máx {0:N0} °C" -f $St.GpuTempMax) }
    if ($null -ne $St.GpuPowerMax) { $parts += ("GPU {0:N0} W" -f $St.GpuPowerMax) }
    if (-not $parts.Count) { return }
    Log ("Sensores ({0}): {1}" -f $Contexto, ($parts -join ' | '))
    # Un solo aviso por tipo en toda la sesión (si no, cada prueba repite lo mismo en el informe)
    if (-not $Global:AvisosSensor) { $Global:AvisosSensor = @{} }
    $lim = Get-CpuTempLimit
    if ($null -ne $St.CpuTempMax -and -not $Global:AvisosSensor['temp']) {
        if ($St.CpuTempMax -ge $lim - 1) {
            $Global:AvisosSensor['temp'] = $true
            Set-Verdict 'CPU' 'ATENCION' ("El procesador llegó a {0:N0} °C bajo carga (su límite es {1} °C) y baja la velocidad para protegerse (throttling). Revisar cooler, pasta térmica y montaje." -f $St.CpuTempMax, $lim)
        } elseif ($St.CpuTempMax -ge $lim - 8) {
            Set-Verdict 'CPU' 'INFO' ("Temperatura alta bajo carga: {0:N0} °C (límite {1} °C)." -f $St.CpuTempMax, $lim)
        }
    }
    if ($null -ne $St.V12Min -and $St.V12Min -lt 11.4 -and -not $Global:AvisosSensor['v12']) {
        $Global:AvisosSensor['v12'] = $true
        Set-Verdict 'Motherboard' 'ATENCION' ("La línea de +12 V bajó a {0:N2} V bajo carga (el mínimo normal es 11,4 V). El sensor de la placa es aproximado: se confirma con tester; si se confirma, revisar fuente y cables." -f $St.V12Min)
    }
    if ($null -ne $St.VrmMax -and $St.VrmMax -ge 105 -and -not $Global:AvisosSensor['vrm']) {
        $Global:AvisosSensor['vrm'] = $true
        Set-Verdict 'Motherboard' 'ATENCION' ("Los reguladores de voltaje de la placa (VRM) llegaron a {0:N0} °C: falta flujo de aire sobre sus disipadores." -f $St.VrmMax)
    }
    if ($Area -eq 'GPU') { Show-GpuSensorStats $St $Contexto }
}

# ======================================================================
#  Drivers de chipset y video
# ======================================================================
function Test-Drivers {
    Section 'DRIVERS DE CHIPSET Y VIDEO'
    $drv = @()
    try { $drv = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop | Where-Object { $_.DeviceName }) } catch { Log '  No se pudo leer la lista de drivers.' 'DarkGray'; return }
    $cpuName = if ($Global:Cpu) { $Global:Cpu.Nombre } else { '' }
    $uninst = @()
    foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*') {
        $uninst += @(Get-ItemProperty $k -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName } | ForEach-Object { $_.DisplayName })
    }
    if ($cpuName -match 'AMD') {
        $amd = @($drv | Where-Object { $_.DriverProviderName -match 'Advanced Micro Devices|^AMD' -and $_.DeviceName -match 'PSP|GPIO|SMBus|I2C|UART|SFH|Sensor Fusion|PCI|Chipset|Power|PPM|Micro-?PEP|Provisioning' })
        $pkg = @($uninst | Where-Object { $_ -match 'AMD Chipset Software' })
        if ($pkg.Count -or $amd.Count -ge 2) {
            Log ("  Chipset AMD: instalado{0} ({1} dispositivos con driver AMD)." -f $(if ($pkg.Count) { ' (' + $pkg[0] + ')' }), $amd.Count) 'Green'
            Set-Verdict 'Plataforma' 'OK' ''
        } else {
            Set-Verdict 'Plataforma' 'ATENCION' 'Faltan los drivers de chipset AMD. Instalarlos ANTES de testear (paso D, Drivers, lo hace solo): sin ellos aparecen cuelgues/BSOD (HYPERVISOR_ERROR, amdppm) que no son del hardware.'
        }
    } elseif ($cpuName -match 'Intel') {
        $intel = @($drv | Where-Object { $_.DriverProviderName -match 'Intel' -and $_.DeviceName -match 'Management Engine|Serial IO|SMBus|Chipset|GNA|Thermal|Dynamic Tuning|LPC|SPI' })
        if ($intel.Count) { Log ("  Chipset Intel: {0} dispositivos con driver Intel (ME/Serial IO/SMBus)." -f $intel.Count) 'Green'; Set-Verdict 'Plataforma' 'OK' '' }
        else { Set-Verdict 'Plataforma' 'INFO' 'No se ven drivers de chipset Intel (ME, Serial IO): conviene instalarlos antes de testear (paso D, Drivers, los busca en Windows Update).' }
    }
    $vga = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
    foreach ($g in $vga) {
        if ($g.Name -match 'Basic Display|Básico|Microsoft Basic') {
            Set-Verdict 'GPU' 'ATENCION' 'Video con el "Adaptador de pantalla básico de Microsoft": falta el driver de video. Instalarlo antes de probar la GPU/iGPU (paso D, Drivers).'
        } else {
            Log ("  Video: {0} (driver {1})" -f (Get-Clean $g.Name), $g.DriverVersion)
        }
    }
}

# ======================================================================
#  Historial (CSV compartido en Reportes) y comparación con equipos iguales
# ======================================================================
# Acepta coma o punto decimal: el historial se comparte entre PCs con Windows en distintos idiomas
function ConvertTo-Num($s) {
    if ($null -eq $s) { return $null }
    $t = ([string]$s).Trim()
    if ($t -eq '') { return $null }
    if ($t -match '^-?\d{1,3}(\.\d{3})+,\d+$') { $t = $t -replace '\.', '' }   # 1.234,5
    $t = $t -replace ',', '.'
    $d = 0.0
    if ([double]::TryParse($t, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
    return $null
}

function Get-Historial {
    if (-not (Test-Path $HistFile)) { return @() }
    try { return @(Import-Csv -Path $HistFile -Delimiter ';' -Encoding UTF8) } catch { return @() }
}

function Compare-Historial([string]$Campo, [double]$Valor) {
    if (-not $Global:Cpu -or $Valor -le 0) { return $null }
    $rows = @(Get-Historial | Where-Object { $_.CPU -eq $Global:Cpu.Nombre -and $_.Motor -eq $MotorVersion -and $_.Sesion -ne $Global:M.Sesion })
    $vals = @($rows | ForEach-Object { ConvertTo-Num $_.$Campo } | Where-Object { $_ -gt 0 } | Sort-Object)
    if (-not $vals.Count) { return $null }
    $med = $vals[[math]::Floor($vals.Count / 2)]
    return [pscustomobject]@{ N = $vals.Count; Mediana = $med; Pct = 100 * $Valor / $med }
}

function Compare-HistorialPor([string]$ColClave, [string]$Clave, [string]$Campo, [double]$Valor) {
    if (-not $Clave -or $Valor -le 0) { return $null }
    $rows = @(Get-Historial | Where-Object { $_.$ColClave -eq $Clave -and $_.Sesion -ne $Global:M.Sesion })
    $vals = @($rows | ForEach-Object { ConvertTo-Num $_.$Campo } | Where-Object { $_ -gt 0 } | Sort-Object)
    if (-not $vals.Count) { return $null }
    $med = $vals[[math]::Floor($vals.Count / 2)]
    return [pscustomobject]@{ N = $vals.Count; Mediana = $med; Pct = 100 * $Valor / $med }
}

function Show-ComparacionGpu([string]$Campo, [double]$Valor, [string]$Texto) {
    $dev = $Global:M.Gpu['DevId']
    $nom = if ($Global:M.Gpu['ChipNombre']) { $Global:M.Gpu['ChipNombre'] } else { $dev }
    $c = Compare-HistorialPor 'GpuDev' $dev $Campo $Valor
    if (-not $c) { Log ("  {0}: primera placa con este chip ({1}) en el historial, queda como referencia." -f $Texto, $nom) 'DarkGray'; return $null }
    Log ("  {0}: {1:N0}% de la mediana de {2} placa(s) con el mismo chip." -f $Texto, $c.Pct, $c.N)
    if ($c.N -ge 2 -and $c.Pct -lt 75) {
        Set-Verdict 'GPU' 'ATENCION' ("{0}: rinde {1:N0}% de lo normal para este chip ({2} placas de referencia). Puede ser temperatura/throttling, potencia limitada, memoria a menor velocidad o una placa adulterada." -f $Texto, $c.Pct, $c.N)
    }
    return $c
}

function Show-Comparacion([string]$Campo, [double]$Valor, [string]$Texto) {
    $c = Compare-Historial $Campo $Valor
    if (-not $c) {
        Log ("  {0}: primer {1} en el historial, queda como referencia para los próximos." -f $Texto, $Global:Cpu.Nombre) 'DarkGray'
        return $null
    }
    Log ("  {0}: {1:N0}% de la mediana de {2} equipo(s) iguales testeados antes." -f $Texto, $c.Pct, $c.N)
    if ($c.N -ge 2 -and $c.Pct -lt 85) {
        Set-Verdict 'CPU' 'ATENCION' ("{0}: rinde {1:N0}% de lo normal para este modelo (mediana de {2} equipos). Revisar temperatura, límites de potencia del BIOS y RAM (canales/velocidad)." -f $Texto, $c.Pct, $c.N)
    }
    return $c
}

function Save-Historial {
    $e = $Global:M.Equipo; $c = $Global:M.Cpu; $s = $Global:SesionSensores
    $st = @{}
    foreach ($k in $Global:Verdicts.Keys) { $st[$k] = $Global:Verdicts[$k].Estado }
    # siempre con coma decimal (como Excel en español), sea cual sea el idioma del Windows que se está testeando
    $esAr = [Globalization.CultureInfo]::GetCultureInfo('es-AR')
    $fmt = { param($v, $d) if ($null -eq $v) { '' } else { ([double]$v).ToString("F$d", $esAr) } }
    $row = [pscustomobject][ordered]@{
        Sesion       = $Global:M.Sesion
        Fecha        = (Get-Date -Format 'yyyy-MM-dd HH:mm')
        Orden        = $Global:M.Orden
        Pieza        = $Global:M.Pieza
        Grupo        = $Global:M.Grupo
        Tecnico      = $Global:M.Tecnico
        CPU          = $(if ($Global:Cpu) { $Global:Cpu.Nombre } else { '' })
        Nucleos      = $(if ($Global:Cpu) { $Global:Cpu.Nucleos } else { '' })
        Hilos        = $(if ($Global:Cpu) { $Global:Cpu.Hilos } else { '' })
        Mother       = $e.Mother
        BIOS         = $e.BIOS
        RAM_GB       = $e.RamGB
        RAM_MTs      = $e.RamMTs
        GPU          = ($e.GPU -join ' + ')
        Discos       = (@($Global:M.Discos | ForEach-Object { $_.Modelo }) -join ' + ')
        Motor        = $MotorVersion
        AllCoreMin   = (& $fmt $c.AllCoreMin 1)
        AllCoreIps   = (& $fmt $c.AllCoreIps 2)
        PerCoreSeg   = $c.PerCoreSeg
        PerCoreIps   = (& $fmt $c.PerCoreIps 3)
        CpuTempMax   = (& $fmt $(if ($s) { $s.CpuTempMax }) 0)
        CpuPowerMax  = (& $fmt $(if ($s) { $s.CpuPowerMax }) 0)
        V12Min       = (& $fmt $(if ($s) { $s.V12Min }) 2)
        GPU_Probada  = $Global:M.Gpu['Modelo']
        GpuTempMax   = $Global:M.Gpu['GpuTempMax']
        GpuHotMax    = $Global:M.Gpu['GpuHotMax']
        GpuStressErr = $Global:M.Gpu['StressErr']
        GpuVram      = $Global:M.Gpu['VramRes']
        GpuDev       = $Global:M.Gpu['DevId']
        GpuChip      = $Global:M.Gpu['Chip']
        GpuFabricante = $Global:M.Gpu['Fabricante']
        GpuVbios     = $Global:M.Gpu['Vbios']
        GpuCoincide  = $Global:M.Gpu['Coincide']
        GpuPuntaje2  = $Global:M.Gpu['Score']   # v2.10+: sin tope de capas ni de cuadros. GpuPuntaje (2.8-2.9) y GpuScore eran cargas anteriores, no comparables
        VramGBs      = $Global:M.Gpu['VramGBs']
        GpuDif       = $Global:M.Gpu['GpuDeltaMax']
        Resultado    = (Get-ResultadoSesion)
        CPU_Estado   = $st['CPU']
        Mother_Estado = $st['Motherboard']
        RAM_Estado   = $st['RAM']
        Discos_Estado = $st['Discos']
        GPU_Estado   = $st['GPU']
        Fuente_Estado = $st['Fuente']
        Sistema_Estado = $st['Plataforma']
        FuenteW      = $Global:M.Fuente['TotalMax']
        Fuente12V    = (& $fmt $Global:M.Fuente['V12Min'] 2)
        TestMem5     = $Global:M.Ram['Tm5Res']
        TestMem5Min  = (& $fmt $Global:M.Ram['Tm5Min'] 0)
        Reporte      = $(if ($Global:ReportFile) { Split-Path -Leaf $Global:ReportFile } else { '' })
    }
    try {
        $rows = @(Get-Historial | Where-Object { $_.Sesion -ne $Global:M.Sesion })
        Write-HistorialCsv (@($rows) + @($row)) $HistFile @($row.PSObject.Properties.Name)
    } catch {
        Log ("  No se pudo guardar el historial ({0}). ¿Está abierto en Excel?" -f $_.Exception.Message) 'Yellow'
        return
    }
    Sync-Historial -Subir
}

# Columnas: las de la versión actual primero y después las que traigan filas de otras versiones
# (Export-Csv toma solo las columnas de la primera fila, por eso se unifican)
function Get-HistorialColumnas($Rows, [string[]]$Primero) {
    $cols = New-Object System.Collections.ArrayList
    foreach ($n in $Primero) { if ($n -and -not $cols.Contains($n)) { [void]$cols.Add($n) } }
    foreach ($r in $Rows) { foreach ($n in $r.PSObject.Properties.Name) { if (-not $cols.Contains($n)) { [void]$cols.Add($n) } } }
    return @($cols)
}

function Write-HistorialCsv($Rows, [string]$Path, [string[]]$Primero = @()) {
    $cols = Get-HistorialColumnas $Rows $Primero
    @($Rows) | Select-Object -Property $cols | Export-Csv -Path $Path -Delimiter ';' -NoTypeInformation -Encoding UTF8
}

# Une dos historiales por Sesion. Si una misma sesión está en los dos, queda la fila con más datos (empate: la local).
function Merge-Historial($Local, $Remoto) {
    $map = [ordered]@{}
    $llenos = { param($r) @($r.PSObject.Properties | Where-Object { [string]$_.Value -ne '' }).Count }
    foreach ($r in @($Remoto) + @($Local)) {
        if (-not $r -or -not $r.Sesion) { continue }
        $k = [string]$r.Sesion
        if (-not $map.Contains($k) -or (& $llenos $r) -ge (& $llenos $map[$k])) { $map[$k] = $r }
    }
    return @(@($map.Values) | Sort-Object { [string]$_.Fecha })
}

# Historial compartido: se guarda en el NET-Receptor de la PC de soporte (modo "guardar"). Cada banco baja
# lo que hay, lo une con lo suyo y lo vuelve a subir. Sin conexión queda en el pendrive y se une la próxima vez.
function Sync-Historial([switch]$Subir) {
    $cfg = Get-EnvioConfig
    if (-not $cfg.Clave) { return }
    $recs = @()
    try { $recs = @(Find-Receptores 1200 | Where-Object { $_.Modo -eq 'guardar' }) } catch {}
    if (-not $recs.Count) {
        if (-not $Global:HistAvisoSinPc) {
            $Global:HistAvisoSinPc = $true
            Log '  Historial compartido: no se encontró la PC de soporte (NET-Receptor). Queda en este pendrive y se une la próxima vez.' 'DarkGray'
        }
        return
    }
    foreach ($r in $recs) {
        $url = "http://{0}:{1}/api/historial" -f $r.Ip, $r.Puerto
        $h = @{ 'X-Clave' = $cfg.Clave }
        try {
            $resp = Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        } catch {
            $code = 0
            try { $code = [int]$_.Exception.Response.StatusCode } catch {}
            if ($code -eq 404) { Log ("  Historial compartido: el NET-Receptor de {0} es de una versión anterior. Reinstalarlo una vez (Instalar-Receptor.bat) para compartir el historial." -f $r.Nombre) 'Yellow' }
            else { Log ("  Historial compartido: no se pudo leer de {0} ({1})." -f $r.Nombre, $_.Exception.Message) 'DarkGray' }
            continue
        }
        try {
            $txt = ([string]$resp.Content).TrimStart([char]0xFEFF)
            $lineas = @($txt -split "`r?`n" | Where-Object { $_.Trim() })
            $remoto = if ($lineas.Count -gt 1) { @($lineas | ConvertFrom-Csv -Delimiter ';') } else { @() }
            $local = @(Get-Historial)
            $todo = Merge-Historial $local $remoto
            $primero = if ($local.Count) { @($local[0].PSObject.Properties.Name) } else { @() }
            Write-HistorialCsv $todo $HistFile $primero
            $nuevos = $todo.Count - $local.Count
            if ($Subir -or $todo.Count -ne $remoto.Count) {
                $csv = (@($todo) | Select-Object -Property (Get-HistorialColumnas $todo $primero) | ConvertTo-Csv -Delimiter ';' -NoTypeInformation) -join "`r`n"
                $null = Invoke-WebRequest -Uri $url -Method Post -Headers $h -Body ([Text.Encoding]::UTF8.GetBytes($csv + "`r`n")) -ContentType 'text/csv; charset=utf-8' -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
            }
            Log ("  Historial compartido con {0}: {1} equipos{2}." -f $r.Nombre, $todo.Count, $(if ($nuevos -gt 0) { " ($nuevos traídos de otros bancos)" } else { '' })) 'DarkGray'
        } catch {
            Log ("  Historial compartido: error al sincronizar con {0} ({1})." -f $r.Nombre, $_.Exception.Message) 'DarkGray'
        }
    }
}

# ======================================================================
#  Informe para el cliente (HTML imprimible) + JSON
# ======================================================================
function HtmlEnc($s) { return [System.Net.WebUtility]::HtmlEncode([string]$s) }

function Get-LogoDataUri {
    foreach ($dir in @($ToolsDir, $ReportDir, $Root)) {
        foreach ($ext in 'png', 'svg', 'jpg', 'jpeg', 'webp') {
            $p = Join-Path $dir "logo.$ext"
            if (Test-Path $p) {
                $mime = switch ($ext) { 'svg' { 'image/svg+xml' } 'jpg' { 'image/jpeg' } 'jpeg' { 'image/jpeg' } default { "image/$ext" } }
                return ("data:{0};base64,{1}" -f $mime, [Convert]::ToBase64String([IO.File]::ReadAllBytes($p)))
            }
        }
    }
    return $null
}

# Gráfico de temperaturas de la GPU durante el stress (SVG dentro del informe)
function Get-TempChartSvg($Serie) {
    $raw = @($Serie)
    if ($raw.Count -lt 3) { return '' }
    $ci = [Globalization.CultureInfo]::InvariantCulture
    # mismo criterio que los máximos: mediana de 3 lecturas, así una lectura falsa del sensor no se dibuja
    $pts = @()
    for ($j = 0; $j -lt $raw.Count; $j++) {
        $row = @($raw[$j][0], $null, $null, $null)
        foreach ($i in 1, 2, 3) {
            $win = @()
            foreach ($k in ($j - 1), $j, ($j + 1)) { if ($k -ge 0 -and $k -lt $raw.Count -and $null -ne $raw[$k][$i]) { $win += [double]$raw[$k][$i] } }
            if ($win.Count) { $o = @($win | Sort-Object); $row[$i] = $o[[math]::Floor(($o.Count - 1) / 2)] }
        }
        $pts += , $row
    }
    $W = 640; $H = 190; $L = 36; $R = 12; $T = 10; $B = 26
    $vals = @(); foreach ($p in $pts) { foreach ($i in 1, 2, 3) { if ($null -ne $p[$i]) { $vals += [double]$p[$i] } } }
    if (-not $vals.Count) { return '' }
    $lo = [math]::Floor((($vals | Measure-Object -Minimum).Minimum - 3) / 10) * 10
    $hi = [math]::Ceiling((($vals | Measure-Object -Maximum).Maximum + 3) / 10) * 10
    if ($hi -le $lo) { $hi = $lo + 10 }
    $tmax = [math]::Max(1, [double]$pts[-1][0])
    $X = { param($t) $L + ($W - $L - $R) * [double]$t / $tmax }
    $Y = { param($v) $T + ($H - $T - $B) * (1 - ([double]$v - $lo) / ($hi - $lo)) }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append(('<div class="chart"><svg viewBox="0 0 {0} {1}" role="img" aria-label="Temperaturas de la GPU durante la prueba">' -f $W, $H))
    $stepY = if (($hi - $lo) -gt 60) { 20 } else { 10 }
    for ($v = $lo; $v -le $hi; $v += $stepY) {
        $yy = & $Y $v
        [void]$sb.Append([string]::Format($ci, '<line x1="{0}" y1="{1:F1}" x2="{2}" y2="{1:F1}" stroke="#e3e7ee" stroke-width="1"/><text x="{3}" y="{4:F1}" font-size="11" fill="#5b6472" text-anchor="end">{5}°</text>', $L, $yy, ($W - $R), ($L - 6), ($yy + 4), $v))
    }
    $mins = [math]::Round($tmax / 60, 1)
    foreach ($fr in 0, 0.5, 1) {
        $tx = & $X ($tmax * $fr)
        $lab = if ($fr -eq 0) { '0' } else { '{0:0.#} min' -f ($mins * $fr) }
        $anc = if ($fr -eq 0) { 'start' } elseif ($fr -eq 1) { 'end' } else { 'middle' }
        [void]$sb.Append([string]::Format($ci, '<text x="{0:F1}" y="{1}" font-size="11" fill="#5b6472" text-anchor="{2}">{3}</text>', $tx, ($H - 8), $anc, $lab))
    }
    $hay = @{}
    foreach ($ser in @(@(3, '#38bdf8'), @(1, '#F13E88'), @(2, '#FFA601'))) {
        $coords = @()
        foreach ($p in $pts) { if ($null -ne $p[$ser[0]]) { $coords += [string]::Format($ci, '{0:F1},{1:F1}', (& $X $p[0]), (& $Y $p[$ser[0]])) } }
        if ($coords.Count -ge 2) { $hay[$ser[0]] = $true; [void]$sb.Append(('<polyline fill="none" stroke="{0}" stroke-width="2.4" stroke-linejoin="round" points="{1}"/>' -f $ser[1], ($coords -join ' '))) }
    }
    [void]$sb.Append('</svg><div class="lg">')
    if ($hay[1]) { [void]$sb.Append('<span><i style="background:#F13E88"></i>Núcleo</span>') }
    if ($hay[2]) { [void]$sb.Append('<span><i style="background:#FFA601"></i>Punto más caliente (hotspot)</span>') }
    if ($hay[3]) { [void]$sb.Append('<span><i style="background:#38bdf8"></i>Memoria de video</span>') }
    [void]$sb.Append('<span>Temperaturas durante el stress de la placa de video</span></div></div>')
    return $sb.ToString()
}

function Get-StateInfo([string]$Estado) {
    switch ($Estado) {
        'FALLA' { return @{ Cls = 'fail'; Txt = 'Falla' } }
        'ATENCION' { return @{ Cls = 'warn'; Txt = 'Con observaciones' } }
        default { return @{ Cls = 'ok'; Txt = 'OK' } }
    }
}

function Convert-HtmlToPdf([string]$Html, [string]$Pdf) {
    $Global:PdfMotivo = ''
    $b = Find-Browser
    if (-not $b) { $Global:PdfMotivo = 'no se encontró Edge ni Chrome'; return $false }
    $uri = (New-Object System.Uri([IO.Path]::GetFullPath($Html))).AbsoluteUri
    Remove-Item -Path $Pdf -Force -ErrorAction SilentlyContinue
    $listo = { (Test-Path $Pdf) -and (Get-Item $Pdf).Length -gt 1000 }
    # dos intentos: en PCs lentas (o recién terminado un stress) el primero a veces no llega a escribir el archivo
    foreach ($modo in '--headless=new', '--headless') {
        $prof = Join-Path ([IO.Path]::GetTempPath()) ('netbench-pdf-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $pargs = @($modo, '--disable-gpu', '--no-first-run', '--no-default-browser-check', '--disable-extensions',
            "--user-data-dir=`"$prof`"", '--no-pdf-header-footer', '--print-to-pdf-no-header', "--print-to-pdf=`"$Pdf`"", $uri)
        try {
            $pp = if ($IsWin) { Start-Process -FilePath $b -ArgumentList $pargs -PassThru -WindowStyle Hidden } else { Start-Process -FilePath $b -ArgumentList $pargs -PassThru }
            if (-not $pp.WaitForExit(90000)) { try { $pp.Kill() } catch {}; $Global:PdfMotivo = 'el navegador tardó más de 90 s' }
        } catch { $Global:PdfMotivo = 'no se pudo abrir el navegador: ' + $_.Exception.Message }
        $t0 = Get-Date
        while (((Get-Date) - $t0).TotalSeconds -lt 10 -and -not (& $listo)) { Start-Sleep -Milliseconds 300 }
        Remove-Item -Path $prof -Recurse -Force -ErrorAction SilentlyContinue
        if (& $listo) { $Global:PdfMotivo = ''; return $true }
    }
    if (-not $Global:PdfMotivo) { $Global:PdfMotivo = 'el navegador no generó el archivo' }
    return $false
}

$InformeCss = @'
:root { --magenta:#EA06CF; --rosa:#F13E88; --naranja:#FFA601; --accent:#F13E88;
        --grad:linear-gradient(90deg, #EA06CF 0%, #F13E88 50%, #FFA601 100%); --ink:#14181f; --muted:#5b6472; --line:#e3e7ee; --bg:#f4f6f9; --card:#ffffff;
        --ok:#15803d; --ok-bg:#e7f6ec; --warn:#b45309; --warn-bg:#fdf3e1; --fail:#b91c1c; --fail-bg:#fde8e8; }
* { box-sizing:border-box; }
body { margin:0; background:var(--bg); color:var(--ink); font:14px/1.5 "Segoe UI", Roboto, Arial, sans-serif; }
.page { max-width:900px; margin:24px auto; background:var(--card); border-radius:14px; overflow:hidden; box-shadow:0 2px 18px rgba(20,24,31,.08); }
header.top { display:flex; justify-content:space-between; align-items:center; gap:16px; padding:18px 32px; background:#000; color:#fff; position:relative; }
header.top::after { content:""; position:absolute; left:0; right:0; bottom:0; height:5px; background:var(--grad); }
.brand { display:flex; align-items:center; gap:12px; }
.brand img { height:68px; width:auto; }
.word { font-weight:800; font-size:24px; letter-spacing:.06em; }
.word span, .grad-text { background:var(--grad); -webkit-background-clip:text; background-clip:text; color:transparent; }
.doc { text-align:right; font-size:12.5px; color:#c9d1dc; }
.doc b { display:block; color:#fff; font-size:15px; letter-spacing:.02em; margin-bottom:2px; }
.doc .orden { color:var(--naranja); font-weight:600; }
main { padding:26px 32px 8px; }
.verdict { display:flex; gap:16px; align-items:center; padding:18px 20px; border-radius:12px; margin-bottom:24px; }
.verdict .dot { width:44px; height:44px; flex:none; border-radius:50%; display:grid; place-items:center; color:#fff; font-size:24px; font-weight:800; }
.verdict h1 { margin:0; font-size:21px; }
.verdict p { margin:2px 0 0; color:var(--muted); }
.verdict.ok { background:var(--ok-bg); } .verdict.ok .dot { background:var(--ok); }
.verdict.warn { background:var(--warn-bg); } .verdict.warn .dot { background:var(--warn); }
.verdict.fail { background:var(--fail-bg); } .verdict.fail .dot { background:var(--fail); }
h2 { font-size:13px; text-transform:uppercase; letter-spacing:.09em; color:var(--muted); margin:26px 0 10px; display:flex; align-items:center; gap:8px; }
h2::before { content:""; width:18px; height:4px; border-radius:2px; background:var(--grad); }
table.spec { width:100%; border-collapse:collapse; }
table.spec th { text-align:left; width:150px; color:var(--muted); font-weight:600; vertical-align:top; }
table.spec th, table.spec td { padding:6px 0; border-bottom:1px solid var(--line); }
.cards { display:grid; grid-template-columns:repeat(auto-fit, minmax(380px, 1fr)); gap:14px; }
.card { border:1px solid var(--line); border-radius:12px; padding:14px 16px; break-inside:avoid; }
.card.wide { grid-column:1 / -1; break-inside:auto; }
.kv, .chart, .obs li, table.tests tr, table.sum tr, .verdict { break-inside:avoid; }
h2, .card h3 { break-after:avoid; }
table.sum { width:100%; border-collapse:collapse; font-size:13px; }
table.sum th { text-align:left; color:var(--muted); font-weight:600; border-bottom:2px solid var(--line); padding:6px 8px 6px 0; }
table.sum td { border-bottom:1px solid var(--line); padding:7px 8px 7px 0; vertical-align:top; }
table.sum td.n { font-weight:800; white-space:nowrap; }
table.sum td.hi { color:var(--warn); font-weight:700; }
.pz { color:#c2410c; font-weight:800; letter-spacing:.03em; }
.nota { color:var(--muted); font-size:12.5px; margin:8px 0 0; }
.chart { margin-top:12px; }
.chart svg { width:100%; height:auto; display:block; }
.chart .lg { display:flex; gap:16px; font-size:12px; color:var(--muted); margin-top:4px; flex-wrap:wrap; }
.chart .lg i { display:inline-block; width:14px; height:3px; border-radius:2px; vertical-align:middle; margin-right:5px; }
.card h3 { margin:0 0 8px; font-size:15.5px; display:flex; justify-content:space-between; align-items:center; gap:8px; }
.chip { font-size:11.5px; font-weight:700; padding:3px 10px; border-radius:99px; white-space:nowrap; }
.chip.ok { color:var(--ok); background:var(--ok-bg); } .chip.warn { color:var(--warn); background:var(--warn-bg); } .chip.fail { color:var(--fail); background:var(--fail-bg); }
.kv { display:grid; grid-template-columns:auto 1fr; gap:3px 14px; font-size:13.5px; }
.kv dt { color:var(--muted); } .kv dd { margin:0; font-weight:600; }
.obs { margin:10px 0 0; padding:0; list-style:none; font-size:13px; }
.obs li { padding:6px 10px; border-radius:8px; margin-top:6px; }
.obs li.warn { background:var(--warn-bg); } .obs li.fail { background:var(--fail-bg); }
table.tests { width:100%; border-collapse:collapse; font-size:13.5px; }
table.tests th { text-align:left; color:var(--muted); font-weight:600; border-bottom:2px solid var(--line); padding:6px 8px 6px 0; }
table.tests td { border-bottom:1px solid var(--line); padding:7px 8px 7px 0; vertical-align:top; }
table.tests td.d { color:var(--muted); white-space:nowrap; }
.sub { color:var(--muted); font-weight:400; font-size:12.5px; }
footer { margin-top:26px; padding:16px 32px 22px; border-top:1px solid var(--line); position:relative; font-size:12px; color:var(--muted); display:flex; justify-content:space-between; gap:16px; flex-wrap:wrap; }
@media (max-width:640px) { header.top, main, footer { padding-left:16px; padding-right:16px; } table.spec th { width:110px; } .cards { grid-template-columns:1fr; } header.top { flex-direction:column; align-items:flex-start; } .doc { text-align:left; } }
@media print { body { background:#fff; } .page { box-shadow:none; margin:0; max-width:none; border-radius:0; }
  header.top, header.top::after, h2::before, .word span, .verdict, .chip, .obs li, .chart { -webkit-print-color-adjust:exact; print-color-adjust:exact; }
  @page { size:A4; margin:10mm; } }
'@

# Filas "dato / valor" de la placa de video. $g es $Global:M.Gpu o el bloque Gpu de un informe guardado (.json)
function Get-GpuKv($g, [string]$ModeloAlt) {
    $kv = New-Object System.Collections.ArrayList
    if (-not $g) { return $kv }
    $modelo = if ($g.Modelo) { $g.Modelo } elseif ($g.VramDispositivo) { $g.VramDispositivo } else { $ModeloAlt }
    if ($modelo) { [void]$kv.Add(@('Modelo', (HtmlEnc $modelo))) }
    if ($null -ne $g.Coincide) {
        $var = if ($g.Variante) { ' · ' + $g.Variante } else { '' }
        $txtId = if ($g.Coincide) { 'Original: el chip {0} corresponde al modelo{1}' -f $g.Chip, $var } else { 'NO coincide: el chip real es {0}' -f $g.ChipNombre }
        [void]$kv.Add(@('Identidad de la placa', (HtmlEnc $txtId)))
    }
    if ($g.Fabricante) { [void]$kv.Add(@('Fabricante', (HtmlEnc $g.Fabricante))) }
    if ($g.VramGB) { [void]$kv.Add(@('Memoria de video', ('{0} GB' -f $g.VramGB))) }
    if ($g.Vbios) { [void]$kv.Add(@('BIOS de video', (HtmlEnc $g.Vbios))) }
    if ($g.VramRes) { [void]$kv.Add(@('Memoria de video (VRAM)', ('{0} <span class="sub">(se verificó toda la memoria, {1:N0} min)</span>' -f (HtmlEnc $g.VramRes), $g.VramMin))) }
    if ($null -ne $g.StressMin -and $g.StressMin -gt 0) {
        [void]$kv.Add(@('Stress con verificación', ('{0:N0} min, {1}' -f $g.StressMin, $(if ($g.StressErr) { "$($g.StressErr) errores" } else { 'sin errores' }))))
    }
    if ($null -ne $g.GpuTempMax) { [void]$kv.Add(@('Temperatura del núcleo', ('{0} °C <span class="sub">(la que muestran FurMark y GPU-Z)</span>' -f $g.GpuTempMax))) }
    if ($null -ne $g.GpuHotMax -and -not (Test-Rtx50 $modelo)) {   # en RTX 50 no hay lectura oficial
        $dl = if ($null -ne $g.GpuDeltaMax) { ' <span class="sub">({0} °C sobre el núcleo)</span>' -f $g.GpuDeltaMax } else { '' }
        [void]$kv.Add(@('Punto más caliente (hotspot)', ('{0} °C{1}' -f $g.GpuHotMax, $dl)))
    }
    if ($null -ne $g.GpuMemMax) { [void]$kv.Add(@('Temperatura de la memoria', ('{0} °C <span class="sub">(bajo carga de juego)</span>' -f $g.GpuMemMax))) }
    # La temperatura del test de VRAM (carga extrema, tipo minería) queda solo en el reporte técnico:
    # en el informe del cliente se muestra la del stress, que es la comparable con un juego.
    # Si en el test de VRAM pasó el límite real (108 °C), igual aparece como observación.
    if ($null -ne $g.GpuPowerMax) { [void]$kv.Add(@('Consumo máximo', ('{0} W' -f $g.GpuPowerMax))) }
    if ($g.Enlace) { [void]$kv.Add(@('Conexión PCIe bajo carga', (HtmlEnc $g.Enlace))) }
    if ($g.VsHist) { [void]$kv.Add(@('Rendimiento vs. placas iguales', ('{0:N0}% <span class="sub">({1} placas con el mismo chip)</span>' -f $g.VsHist.Pct, $g.VsHist.N))) }
    if ($g.Reinicios) { [void]$kv.Add(@('Reinicios del driver', ([string]$g.Reinicios))) }
    return $kv
}

function Export-Informe {
    if (-not $Global:ReportFile) { return $null }
    $base = [IO.Path]::ChangeExtension($Global:ReportFile, $null).TrimEnd('.')
    $htmlPath = $base + '.html'
    $jsonPath = $base + '.json'
    $e = $Global:M.Equipo; $c = $Global:M.Cpu; $s = $Global:SesionSensores
    $suelta = [bool]$Global:M.Suelta
    $areasInf = @(Get-AreasInforme)
    $worst = Get-ResultadoSesion
    $vt = switch ($worst) {
        'FALLA' { @('fail', 'Se detectaron fallas', $(if ($suelta) { 'La placa no superó las pruebas. El detalle está en las observaciones.' } else { 'Al menos un componente no superó las pruebas. El detalle está en las observaciones.' })) }
        'ATENCION' { @('warn', 'Apto con observaciones', $(if ($suelta) { 'La placa superó las pruebas de funcionamiento; hay puntos a tener en cuenta, detallados abajo.' } else { 'El equipo superó las pruebas de funcionamiento; hay puntos a tener en cuenta, detallados abajo.' })) }
        default { @('ok', 'Sin fallas detectadas', 'Todas las pruebas automáticas se completaron sin errores.') }
    }
    $fecha = $Global:M.Fecha
    $dt = [datetime]::MinValue
    if ([datetime]::TryParse([string]$Global:M.Fecha, [ref]$dt)) { $fecha = $dt.ToString('dd/MM/yyyy HH:mm') }
    $logo = Get-LogoDataUri
    $sb = New-Object System.Text.StringBuilder

    $css = $InformeCss
    [void]$sb.Append('<!doctype html><html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">')
    [void]$sb.Append(('<title>Informe de diagnóstico {0}</title><style>{1}</style></head><body><div class="page">' -f (HtmlEnc $Global:M.Orden), $css))

    # Encabezado
    $brand = if ($logo) { '<img src="' + $logo + '" alt="NET Gaming">' } else { '<div class="word">NET <span>GAMING</span></div>' }
    [void]$sb.Append('<header class="top"><div class="brand">' + $brand + '</div><div class="doc"><b>Informe de diagnóstico de hardware</b>')
    if ($Global:M.Orden) { [void]$sb.Append('<span class="orden">Orden ' + (HtmlEnc $Global:M.Orden) + '</span> &middot; ') }
    if ($Global:M.Pieza) { [void]$sb.Append('<span class="orden">Placa S/N &hellip;' + (HtmlEnc $Global:M.Pieza) + '</span> &middot; ') }
    [void]$sb.Append((HtmlEnc $fecha))
    if ($Global:M.Tecnico) { [void]$sb.Append('<br>Técnico: ' + (HtmlEnc $Global:M.Tecnico)) }
    [void]$sb.Append('</div></header><main>')

    # Resultado general
    $sym = switch ($vt[0]) { 'ok' { '&#10003;' } 'warn' { '!' } default { '&#10005;' } }
    [void]$sb.Append(('<section class="verdict {0}"><div class="dot">{1}</div><div><h1>{2}</h1><p>{3}</p></div></section>' -f $vt[0], $sym, $vt[1], $vt[2]))

    # Equipo (o, si es una placa suelta, la placa: el procesador y la mother son los del banco y no van)
    $gm = $Global:M.Gpu
    $placaNombre = if ($gm.Modelo) { $gm.Modelo } elseif ($gm.NombreWindows) { $gm.NombreWindows } else { (@($e.GPU | Where-Object { $_ -match $DedicadaRegex }) + @($e.GPU) | Select-Object -First 1) }
    [void]$sb.Append($(if ($suelta) { '<h2>Pieza probada</h2><table class="spec">' } else { '<h2>Equipo</h2><table class="spec">' }))
    $specRows = if ($suelta) { @(
        @('Placa de video', (HtmlEnc $placaNombre)),
        @('Fabricante', (HtmlEnc $gm.Fabricante)),
        @('N.º de serie', $(if ($Global:M.Pieza) { 'termina en <b class="pz">' + (HtmlEnc $Global:M.Pieza) + '</b>' })),
        @('Probada en', 'Banco de pruebas de NET Gaming')
    ) } else { @(
        @('Procesador', $(if ($Global:Cpu) { "{0} <span class=""sub"">({1} núcleos / {2} hilos)</span>" -f (HtmlEnc $Global:Cpu.Nombre), $Global:Cpu.Nucleos, $Global:Cpu.Hilos })),
        @('Motherboard', (HtmlEnc $e.Mother) + $(if ($e.BIOS) { ' <span class="sub">(BIOS ' + (HtmlEnc $e.BIOS) + ')</span>' })),
        @('Memoria RAM', (HtmlEnc $e.RamTexto)),
        @('Video', (HtmlEnc ($e.GPU -join ' + '))),
        @('Almacenamiento', (HtmlEnc ((@($Global:M.Discos | ForEach-Object { '{0} ({1})' -f $_.Modelo, $_.Capacidad })) -join ' + ')))
    ) }
    foreach ($r in $specRows) { if ($r[1]) { [void]$sb.Append(('<tr><th>{0}</th><td>{1}</td></tr>' -f $r[0], $r[1])) } }
    [void]$sb.Append('</table>')

    # Resultados por componente
    $areaNames = [ordered]@{ 'CPU' = 'Procesador'; 'RAM' = 'Memoria RAM'; 'Discos' = 'Almacenamiento'; 'Motherboard' = 'Motherboard'; 'GPU' = 'Video'; 'Fuente' = 'Fuente de alimentación'; 'Plataforma' = 'Sistema y drivers' }
    [void]$sb.Append('<h2>Resultados por componente</h2><div class="cards">')
    foreach ($area in $areaNames.Keys) {
        if (-not $Global:Verdicts.Contains($area) -or $areasInf -notcontains $area) { continue }
        $v = $Global:Verdicts[$area]
        $si = Get-StateInfo $v.Estado
        $kv = New-Object System.Collections.ArrayList
        switch ($area) {
            'CPU' {
                if ($null -ne $c.AllCoreMin) { [void]$kv.Add(@('Estabilidad (todos los núcleos)', ('{0:N0} min, {1}' -f $c.AllCoreMin, $(if ($c.AllCoreErr) { "$($c.AllCoreErr) errores" } else { 'sin errores' })))) }
                if ($c.PerCoreN) { [void]$kv.Add(@('Prueba núcleo por núcleo', ('{0} de {1} OK' -f ($c.PerCoreN - $c.PerCoreFail), $c.PerCoreN))) }
                if ($s -and $null -ne $s.CpuTempMax) { [void]$kv.Add(@('Temperatura máxima', ('{0:N0} °C' -f $s.CpuTempMax))) }
                if ($s -and $null -ne $s.CpuPowerMax) { [void]$kv.Add(@('Consumo máximo', ('{0:N0} W' -f $s.CpuPowerMax))) }
                if ($c.VsHist) { [void]$kv.Add(@('Rendimiento vs. equipos iguales', ('{0:N0}% <span class="sub">({1} equipos)</span>' -f $c.VsHist.Pct, $c.VsHist.N))) }
            }
            'RAM' {
                if ($e.RamTexto) { [void]$kv.Add(@('Configuración', (HtmlEnc $e.RamTexto))) }
                $rm = $Global:M.Ram
                if ($rm.Tm5Res) {
                    [void]$kv.Add(@('Prueba de memoria (TestMem5)', ('{0:N0} min, {1}' -f $rm.Tm5Min, (HtmlEnc $rm.Tm5Res))))
                    if ($rm.Tm5Cobertura) { [void]$kv.Add(@('Memoria probada', (HtmlEnc $rm.Tm5Cobertura))) }
                } else {
                    foreach ($p in @($Global:M.Pruebas | Where-Object { $_.Nombre -match 'TestMem|TM5|memtest|Karhu' })) { [void]$kv.Add(@((HtmlEnc $p.Nombre), ('{0} min, {1}' -f $p.Minutos, (HtmlEnc $p.Resultado)))) }
                }
            }
            'Discos' {
                foreach ($d in $Global:M.Discos) {
                    $l1 = @(); $l2 = @()
                    if ($null -ne $d.Salud) { $l1 += ('Salud {0}%' -f $d.Salud) }
                    if ($null -ne $d.Horas) { $l1 += ('{0:N0} h de uso' -f $d.Horas) }
                    if ($null -ne $d.TB) { $l2 += ('{0:N1} TB escritos' -f $d.TB) }
                    if ($d.Autotest) { $l2 += ('autotest ' + $d.Autotest) }
                    $val = (HtmlEnc ($l1 -join ' · '))
                    if ($l2.Count) { $val += '<br><span class="sub">' + (HtmlEnc ($l2 -join ' · ')) + '</span>' }
                    if (-not $val) { $val = '<span class="sub">sin datos SMART</span>' }
                    [void]$kv.Add(@((HtmlEnc $d.Modelo), $val))
                }
            }
            'Fuente' {
                $fu = $Global:M.Fuente
                if ($null -ne $fu.Min) { [void]$kv.Add(@('CPU y GPU al 100% juntos', ('{0:N0} min, {1}' -f $fu.Min, $(if ($fu.Res -eq 'OK') { 'sin apagones ni errores' } else { HtmlEnc $fu.Res })))) }
                elseif ($fu.Res) { [void]$kv.Add(@('CPU y GPU al 100% juntos', (HtmlEnc $fu.Res))) }
                if ($null -ne $fu.TotalMax) { [void]$kv.Add(@('Consumo CPU + placa de video', ('{0:N0} W <span class="sub">(CPU {1} W + GPU {2} W)</span>' -f $fu.TotalMax, $fu.CpuPowerMax, $fu.GpuPowerMax))) }
                if ($null -ne $fu.V12Min) { [void]$kv.Add(@('+12 V con el equipo al máximo', ('{0:N2} V' -f $fu.V12Min))) }
            }
            'Motherboard' {
                if ($e.Mother) { [void]$kv.Add(@('Modelo', (HtmlEnc $e.Mother))) }
                if ($s -and $null -ne $s.VrmMax) { [void]$kv.Add(@('VRM máximo', ('{0:N0} °C' -f $s.VrmMax))) }
                if ($s -and $null -ne $s.V12Min) { [void]$kv.Add(@('+12 V bajo carga', ('{0:N2} V' -f $s.V12Min))) }
            }
            'GPU' { foreach ($x in @(Get-GpuKv $Global:M.Gpu ($e.GPU -join ' + '))) { [void]$kv.Add($x) } }
        }
        $chart = if ($area -eq 'GPU') { Get-TempChartSvg $Global:M.Gpu['Serie'] } else { '' }
        [void]$sb.Append(('<div class="card{3}"><h3>{0}<span class="chip {1}">{2}</span></h3>' -f $areaNames[$area], $si.Cls, $si.Txt, $(if ($chart) { ' wide' } else { '' })))
        if ($kv.Count) {
            [void]$sb.Append('<dl class="kv">')
            foreach ($x in $kv) { [void]$sb.Append(('<dt>{0}</dt><dd>{1}</dd>' -f $x[0], $x[1])) }
            [void]$sb.Append('</dl>')
        }
        if ($chart) { [void]$sb.Append($chart) }
        $obs = @($v.Detalles | Where-Object { $_ -match '^\[(ATENCION|FALLA)\]' })
        if ($obs.Count) {
            [void]$sb.Append('<ul class="obs">')
            foreach ($o in $obs) {
                $cls = if ($o -match '^\[FALLA\]') { 'fail' } else { 'warn' }
                [void]$sb.Append(('<li class="{0}">{1}</li>' -f $cls, (HtmlEnc ($o -replace '^\[\w+\]\s*', ''))))
            }
            [void]$sb.Append('</ul>')
        } elseif (-not $kv.Count) {
            [void]$sb.Append('<p class="sub">Sin observaciones.</p>')
        }
        [void]$sb.Append('</div>')
    }
    [void]$sb.Append('</div>')

    # Pruebas realizadas
    if ($Global:M.Pruebas.Count) {
        [void]$sb.Append('<h2>Pruebas realizadas</h2><table class="tests"><tr><th>Prueba</th><th>Duración</th><th>Resultado</th></tr>')
        foreach ($p in $Global:M.Pruebas) {
            $cls = if ($p.Resultado -match 'FALLA|error') { 'fail' } elseif ($p.Resultado -match 'ATENCI|observ|cancel') { 'warn' } else { 'ok' }
            $dur = if ($null -ne $p.Minutos) { if ($p.Minutos -lt 1) { '< 1 min' } else { ('{0:N0} min' -f $p.Minutos) } } else { '-' }
            [void]$sb.Append(('<tr><td>{0}{1}</td><td class="d">{2}</td><td><span class="chip {3}">{4}</span></td></tr>' -f `
                        (HtmlEnc $p.Nombre), $(if ($p.Detalle) { '<br><span class="sub">' + (HtmlEnc $p.Detalle) + '</span>' }), $dur, $cls, (HtmlEnc $p.Resultado)))
        }
        [void]$sb.Append('</table>')
    }

    [void]$sb.Append('</main><footer><div><b class="grad-text">NET Gaming</b> &middot; netgaming.ar</div>')
    [void]$sb.Append(('<div>Resultados válidos al momento del diagnóstico &middot; NET-TestBench v{0} &middot; ID {1}</div></footer></div></body></html>' -f $Version, $Global:M.Sesion))

    try {
        [IO.File]::WriteAllText($htmlPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
        $pdfPath = Join-Path $ReportDir ((Split-Path -Leaf $base) + '.pdf')   # el PDF queda a la vista en Reportes
        $Global:InformePdf = $null
        if (Convert-HtmlToPdf $htmlPath $pdfPath) { $Global:InformePdf = $pdfPath }
        else { Log ('  No se pudo generar el PDF ({0}): queda el informe en HTML (Reportes\detalle), que se puede imprimir como PDF desde el navegador.' -f $Global:PdfMotivo) 'Yellow' }
        $out = [ordered]@{}
        foreach ($k in $Global:M.Keys) { $out[$k] = $Global:M[$k] }
        $out['Sensores'] = $s
        $out['Resultado'] = $worst
        $out['Areas'] = [ordered]@{}
        foreach ($k in $Global:Verdicts.Keys) { $out['Areas'][$k] = [ordered]@{ Estado = $Global:Verdicts[$k].Estado; Detalles = @($Global:Verdicts[$k].Detalles) } }
        $out['Pendientes'] = @($Global:Pendientes)
        [IO.File]::WriteAllText($jsonPath, ($out | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
        try { Export-InformeOrden } catch { Log ("  No se pudo armar el informe de la orden completa: {0}" -f $_.Exception.Message) 'Yellow' }
    } catch {
        Log ("  No se pudo guardar el informe HTML: {0}" -f $_.Exception.Message) 'Yellow'
        return $null
    }
    return $htmlPath
}

# ======================================================================
#  Informe de la orden completa: cuando una orden trae varias placas, cada una se prueba por separado
#  (hay que apagar para cambiarla) cargando la misma orden y el final de su número de serie. Con dos o más,
#  además del informe de cada placa se arma UNO de la orden, con todas juntas y comparadas.
# ======================================================================
function Get-NombreArchivo([string]$Texto) { return ($Texto -replace '[\\/:*?"<>|]', '' -replace '\s+', '-') }

function Get-FechaSesion($J) {
    if ($J.Fecha -is [datetime]) { return $J.Fecha }
    $d = [datetime]::MinValue
    [void][datetime]::TryParse([string]$J.Fecha, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$d)
    return $d
}

# Las placas sueltas de un grupo, leídas de los informes guardados (.json) del último mes. Son del grupo las que
# cargaron "va junto con <ticket>" y la del propio ticket; también las de una misma orden con distinto N.º de serie.
# Cada placa es su ticket + su N.º de serie: si se probó más de una vez, vale la última.
function Get-SesionesGrupo([string]$Grupo) {
    $ses = @{}
    $desde = (Get-Date).AddDays(-31)
    foreach ($f in @(Get-ChildItem -Path (Join-Path $ReportDir 'detalle') -Filter '*.json' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $desde })) {
        $j = $null
        try {
            $txt = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
            if ($txt.IndexOf($Grupo, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            $j = $txt | ConvertFrom-Json
        } catch { continue }
        if (-not $j -or -not $j.Suelta) { continue }
        $clave = if ($j.Grupo) { [string]$j.Grupo } else { [string]$j.Orden }
        if ($clave -ne $Grupo) { continue }
        $k = ('{0}|{1}' -f $j.Orden, $j.Pieza).ToUpper()
        if (-not $ses.ContainsKey($k) -or (Get-FechaSesion $j) -gt (Get-FechaSesion $ses[$k])) { $ses[$k] = $j }
    }
    return @($ses.Values | Sort-Object { (Get-FechaSesion $_).Ticks })
}

function Export-InformeOrden {
    $Global:InformeOrdenPdf = $null
    $Global:InformeOrdenHtml = $null
    $orden = Get-GrupoSesion
    if (-not $orden -or -not $Global:M.Suelta) { return }
    $ses = @(Get-SesionesGrupo $orden)
    if ($ses.Count -lt 2) { return }
    $n = $ses.Count
    # cómo se nombra cada placa: por su ticket si son tickets distintos, y por el final del N.º de serie si se cargó
    $tickets = @($ses | ForEach-Object { [string]$_.Orden } | Where-Object { $_ } | Select-Object -Unique)
    $varios = $tickets.Count -gt 1
    $etq = { param($j) $t = @(); if (($varios -or -not $j.Pieza) -and $j.Orden) { $t += [string]$j.Orden }; if ($j.Pieza) { $t += ('S/N …' + $j.Pieza) }; if ($t.Count) { $t -join ' · ' } else { 'Placa' } }
    $titOrden = if (-not $varios) { 'Orden ' + $orden } elseif ($tickets.Count -le 4) { 'Órdenes ' + ($tickets -join ', ') } else { 'Órdenes ' + (($tickets | Select-Object -First 3) -join ', ') + (' y {0} más' -f ($tickets.Count - 3)) }
    $nF = @($ses | Where-Object { [string]$_.Resultado -eq 'FALLA' }).Count
    $nA = @($ses | Where-Object { [string]$_.Resultado -eq 'ATENCION' }).Count
    $nOk = $n - $nF - $nA
    $vt = if ($nF) { @('fail', ('{0} de {1} placas con fallas' -f $nF, $n), 'Abajo está el detalle de cada placa, identificada por su orden o por el final de su número de serie.') }
    elseif ($nA) { @('warn', ('{0} de {1} placas con observaciones' -f $nA, $n), ('Las {0} placas superaron las pruebas de funcionamiento: {1} sin observaciones y {2} con puntos a tener en cuenta, detallados abajo.' -f $n, $nOk, $nA)) }
    else { @('ok', ('Las {0} placas sin fallas' -f $n), 'Todas completaron las pruebas automáticas sin errores.') }
    $sym = switch ($vt[0]) { 'ok' { '&#10003;' } 'warn' { '!' } default { '&#10005;' } }
    $logo = Get-LogoDataUri
    $corto = { param($t) ([string]$t) -replace '^(NVIDIA GeForce|AMD Radeon|NVIDIA|AMD)\s+', '' }
    $modeloDe = { param($j) $g = $j.Gpu; if ($g.Modelo) { [string]$g.Modelo } elseif ($g.NombreWindows) { [string]$g.NombreWindows } else { [string](@($j.Equipo.GPU) | Select-Object -Last 1) } }
    $val = { param($v, $u) if ($null -eq $v -or [string]$v -eq '') { '-' } else { ('{0:N0}{1}' -f [double]$v, $u) } }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<!doctype html><html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">')
    [void]$sb.Append(('<title>Informe de la orden {0}</title><style>{1}</style></head><body><div class="page">' -f (HtmlEnc $orden), $InformeCss))
    $brand = if ($logo) { '<img src="' + $logo + '" alt="NET Gaming">' } else { '<div class="word">NET <span>GAMING</span></div>' }
    [void]$sb.Append('<header class="top"><div class="brand">' + $brand + '</div><div class="doc"><b>Informe de diagnóstico de hardware</b>')
    [void]$sb.Append('<span class="orden">' + (HtmlEnc $titOrden) + '</span> &middot; ' + $n + ' placas de video &middot; ' + (Get-Date -Format 'dd/MM/yyyy'))
    $tecs = @($ses | ForEach-Object { [string]$_.Tecnico } | Where-Object { $_ } | Select-Object -Unique)
    if ($tecs.Count) { [void]$sb.Append('<br>Técnico: ' + (HtmlEnc ($tecs -join ', '))) }
    [void]$sb.Append('</div></header><main>')
    [void]$sb.Append(('<section class="verdict {0}"><div class="dot">{1}</div><div><h1>{2}</h1><p>{3}</p></div></section>' -f $vt[0], $sym, $vt[1], $vt[2]))

    # Comparación: una fila por placa. En naranja, la que más temperatura levantó (si la diferencia entre placas es de 5 °C o más)
    $maxDe = { param($campo) $v = @($ses | ForEach-Object { $_.Gpu.$campo } | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ }); if ($v.Count -ge 2 -and (($v | Measure-Object -Maximum).Maximum - ($v | Measure-Object -Minimum).Minimum) -ge 5) { ($v | Measure-Object -Maximum).Maximum } else { $null } }
    $mxT = & $maxDe 'GpuTempMax'; $mxH = & $maxDe 'GpuHotMax'; $mxM = & $maxDe 'GpuMemMax'
    $celda = { param($v, $mx, $u) $t = & $val $v $u; if ($null -ne $mx -and $null -ne $v -and [double]$v -ge $mx) { '<td class="hi">' + $t + '</td>' } else { '<td>' + $t + '</td>' } }
    # las columnas sin ningún dato (placas sin sensor de memoria o de consumo) no se muestran
    $hayCol = { param($campo) [bool](@($ses | Where-Object { $null -ne $_.Gpu.$campo -and -not ($campo -eq 'GpuHotMax' -and (Test-Rtx50 (& $modeloDe $_))) }).Count) }
    $cH = & $hayCol 'GpuHotMax'; $cM = & $hayCol 'GpuMemMax'; $cP = & $hayCol 'GpuPowerMax'
    [void]$sb.Append('<h2>Comparación de las placas</h2><table class="sum"><tr><th>Placa</th><th>Modelo</th><th>Núcleo</th>' + $(if ($cH) { '<th>Hotspot</th>' }) + $(if ($cM) { '<th>Memoria</th>' }) + $(if ($cP) { '<th>Consumo</th>' }) + '<th>VRAM</th><th>Stress</th><th>Resultado</th></tr>')
    foreach ($j in $ses) {
        $g = $j.Gpu
        $modelo = & $modeloDe $j
        $si = Get-StateInfo ([string]$j.Resultado)
        $hot = if (Test-Rtx50 $modelo) { $null } else { $g.GpuHotMax }
        $stress = if ($null -ne $g.StressMin -and [double]$g.StressMin -gt 0) { ('{0:N0} min, {1}' -f [double]$g.StressMin, $(if ($g.StressErr) { "$($g.StressErr) errores" } else { 'sin errores' })) } else { '-' }
        [void]$sb.Append('<tr><td class="n">' + (HtmlEnc (& $etq $j)) + '</td><td>' + (HtmlEnc (& $corto $modelo)) + '</td>')
        [void]$sb.Append((& $celda $g.GpuTempMax $mxT ' °C') + $(if ($cH) { & $celda $hot $mxH ' °C' }) + $(if ($cM) { & $celda $g.GpuMemMax $mxM ' °C' }) + $(if ($cP) { '<td>' + (& $val $g.GpuPowerMax ' W') + '</td>' }))
        [void]$sb.Append('<td>' + (HtmlEnc $(if ($g.VramRes) { $g.VramRes } else { '-' })) + '</td><td>' + (HtmlEnc $stress) + '</td>')
        [void]$sb.Append(('<td><span class="chip {0}">{1}</span></td></tr>' -f $si.Cls, $si.Txt))
    }
    [void]$sb.Append('</table><p class="nota">Temperaturas máximas durante el stress de cada placa, en el mismo banco de pruebas. Núcleo: la que muestran FurMark y GPU-Z.</p>')

    # Detalle: una tarjeta por placa
    [void]$sb.Append('<h2>Detalle por placa</h2><div class="cards">')
    foreach ($j in $ses) {
        $g = $j.Gpu
        $modelo = & $modeloDe $j
        $si = Get-StateInfo ([string]$j.Resultado)
        [void]$sb.Append(('<div class="card wide"><h3><span><span class="pz">{0}</span> &middot; {1}</span><span class="chip {2}">{3}</span></h3>' -f (HtmlEnc (& $etq $j)), (HtmlEnc (& $corto $modelo)), $si.Cls, $si.Txt))
        $kv = @(Get-GpuKv $g $modelo | Where-Object { $_[0] -ne 'Modelo' })
        if ($kv.Count) {
            [void]$sb.Append('<dl class="kv">')
            foreach ($x in $kv) { [void]$sb.Append(('<dt>{0}</dt><dd>{1}</dd>' -f $x[0], $x[1])) }
            [void]$sb.Append('</dl>')
        }
        [void]$sb.Append((Get-TempChartSvg $g.Serie))
        $obs = @(@($j.Areas.GPU.Detalles) | Where-Object { $_ -match '^\[(ATENCION|FALLA)\]' })
        if ($obs.Count) {
            [void]$sb.Append('<ul class="obs">')
            foreach ($o in $obs) { [void]$sb.Append(('<li class="{0}">{1}</li>' -f $(if ($o -match '^\[FALLA\]') { 'fail' } else { 'warn' }), (HtmlEnc ($o -replace '^\[\w+\]\s*', '')))) }
            [void]$sb.Append('</ul>')
        }
        $f = Get-FechaSesion $j
        [void]$sb.Append(('<p class="nota">Probada el {0} &middot; ID {1}</p></div>' -f $f.ToString('dd/MM/yyyy HH:mm'), (HtmlEnc $j.Sesion)))
    }
    [void]$sb.Append('</div></main><footer><div><b class="grad-text">NET Gaming</b> &middot; netgaming.ar</div>')
    [void]$sb.Append(('<div>Resultados válidos al momento del diagnóstico &middot; NET-TestBench v{0}</div></footer></div></body></html>' -f $Version))

    $nom = (Get-NombreArchivo $orden) + '_resumen'
    $htmlPath = Join-Path (Join-Path $ReportDir 'detalle') ($nom + '.html')
    $pdfPath = Join-Path $ReportDir ($nom + '.pdf')
    [IO.File]::WriteAllText($htmlPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
    $Global:InformeOrdenHtml = $htmlPath
    if (Convert-HtmlToPdf $htmlPath $pdfPath) {
        $Global:InformeOrdenPdf = $pdfPath
        Log ("Informe conjunto ({0} placas comparadas: {1}): {2}" -f $n, (@($ses | ForEach-Object { & $etq $_ }) -join ', '), $pdfPath) 'White'
    } else {
        Log ("  Informe conjunto ({0} placas): no se pudo pasar a PDF ({1}); queda en {2}" -f $n, $Global:PdfMotivo, $htmlPath) 'Yellow'
    }
}

# ======================================================================
#  Video (GPU): VRAM con memtest_vulkan + stress verificado en el navegador
# ======================================================================
$GpuStressHtml = @'
<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>NET-TestBench · Stress de GPU</title>
<style>
  :root { --magenta:#EA06CF; --rosa:#F13E88; --naranja:#FFA601; --grad:linear-gradient(90deg,#EA06CF,#F13E88,#FFA601); }
  html, body { margin:0; height:100%; background:#000; overflow:hidden; font:15px/1.45 "Segoe UI", Roboto, Arial, sans-serif; color:#fff; }
  #c { position:fixed; inset:0; width:100vw; height:100vh; display:block; }
  .panel { position:fixed; top:20px; left:20px; width:360px; max-width:calc(100vw - 40px); max-height:calc(100vh - 40px); overflow-y:auto;
           background:rgba(0,0,0,.78); border-radius:14px; padding:16px 18px 14px; backdrop-filter:blur(6px); border:1px solid rgba(255,255,255,.12); }
  .sec { margin:14px 0 8px; font-size:11.5px; letter-spacing:.1em; text-transform:uppercase; color:#9aa3b0; display:flex; align-items:center; gap:8px; }
  .sec::before { content:""; width:14px; height:3px; border-radius:2px; background:var(--grad); }
  .temps { display:grid; grid-template-columns:1fr auto auto; gap:3px 12px; align-items:baseline; font-variant-numeric:tabular-nums; }
  .temps .lbl { color:#9aa3b0; }
  .temps .now { font-weight:800; font-size:19px; text-align:right; min-width:62px; }
  .temps .max { color:#7f8896; font-size:12px; text-align:right; min-width:70px; }
  .lv0 { color:#4ade80; } .lv1 { color:#fbbf24; } .lv2 { color:#f87171; } .lvn { color:#e5e7eb; }
  .spark { display:block; width:100%; height:74px; margin-top:8px; background:rgba(255,255,255,.04); border-radius:8px; }
  .legend { display:flex; gap:12px; font-size:11.5px; color:#9aa3b0; margin-top:4px; }
  .legend i { display:inline-block; width:10px; height:3px; border-radius:2px; vertical-align:middle; margin-right:4px; }
  .nosens { color:#9aa3b0; font-size:12.5px; }
  .panel::before { content:""; position:absolute; left:0; right:0; top:0; height:4px; border-radius:14px 14px 0 0; background:var(--grad); }
  .brand { font-weight:800; letter-spacing:.06em; font-size:20px; }
  .brand span { background:var(--grad); -webkit-background-clip:text; background-clip:text; color:transparent; }
  .sub { color:#b8bfca; font-size:12.5px; margin-bottom:10px; }
  dl { display:grid; grid-template-columns:auto 1fr; gap:4px 14px; margin:0; }
  dt { color:#9aa3b0; } dd { margin:0; font-weight:600; font-variant-numeric:tabular-nums; overflow-wrap:anywhere; }
  .bar { height:6px; background:rgba(255,255,255,.12); border-radius:4px; margin:12px 0 8px; overflow:hidden; }
  .bar i { display:block; height:100%; width:0; background:var(--grad); }
  .hint { color:#7f8896; font-size:12px; }
  .ok { color:#4ade80; } .bad { color:#f87171; }
  .result { position:fixed; inset:0; display:none; place-items:center; background:rgba(0,0,0,.82); }
  .result div { text-align:center; padding:30px 40px; border-radius:16px; background:#0b0b0e; border:1px solid rgba(255,255,255,.14); max-width:560px; }
  .result h1 { margin:0 0 8px; font-size:30px; }
</style>
</head>
<body>
<canvas id="c"></canvas>
<div class="panel">
  <div class="brand">NET <span>GAMING</span></div>
  <div class="sub">Stress de GPU con verificación de resultados</div>
  <dl>
    <dt>Tiempo</dt><dd id="tiempo">-</dd>
    <dt>GPU</dt><dd id="gpu">-</dd>
    <dt>Cuadros/s</dt><dd id="fps">-</dd>
    <dt>Carga</dt><dd id="carga">-</dd>
    <dt>Verificaciones</dt><dd id="checks">0</dd>
    <dt>Errores</dt><dd id="errores" class="ok">0</dd>
  </dl>
  <div class="bar"><i id="prog"></i></div>
  <div class="sec">Temperaturas</div>
  <div id="sens"><div class="nosens">Esperando sensores...</div></div>
  <canvas class="spark" id="spark" width="648" height="148"></canvas>
  <div class="legend"><span><i style="background:#F13E88"></i>Núcleo</span><span><i style="background:#FFA601"></i>Hotspot</span><span><i style="background:#38bdf8"></i>Memoria</span><span id="rango"></span></div>
  <div class="hint" style="margin-top:8px">Amarillo = cerca del límite · Rojo = sale como observación en el informe.<br>No uses la PC durante la prueba. Esc = terminar antes.</div>
</div>
<div class="result" id="result"><div><h1 id="rtitle"></h1><p id="rtext"></p><p class="hint">Podés cerrar esta ventana; el resultado ya quedó en el script.</p></div></div>
<script>
(function () {
  "use strict";
  var q = new URLSearchParams(location.search);
  var DURATION = Math.max(10, (parseFloat(q.get("min")) || 10) * 60) * 1000;
  var SIMERR = q.get("simerr") === "1";          // solo para probar la detección
  // MAX_PASSES alto: con 400 las placas de gama alta (4070 Ti para arriba) no llegaban al 100%.
  // LOTE: las capas se dibujan de a tandas en una sola orden (instancias), así el procesador del banco no limita a la placa.
  var CHECK_EVERY = 3000, CHECK_SIZE = 256, CHECK_LAYERS = 48, MAX_PASSES = 8000, LOTE = 64, NOISE = 2048;
  var FPS_ALTO = 45, FPS_BAJO = 22;   // más capas mientras pase de 45 cuadros/s; menos si baja de 22

  var t0 = performance.now(), scoreSum = 0, scoreN = 0;
  var st = { score: 0, state: "starting", elapsed: 0, duration: DURATION / 1000, fps: 0, passes: 1, checks: 0, errors: 0,
             diffPixels: 0, renderer: "", lost: false, aborted: false, error: "", width: 0, height: 0 };
  var $ = function (id) { return document.getElementById(id); };
  function post(path) { try { fetch(path, { method: "POST", body: JSON.stringify(st), keepalive: true }); } catch (e) {} }

  var canvas = $("c");
  var gl = canvas.getContext("webgl2", { antialias: false, depth: false, stencil: false, alpha: false,
                                         powerPreference: "high-performance", preserveDrawingBuffer: false });
  if (!gl) { finish("Sin WebGL2: falta el driver de video o el navegador no usa la GPU."); return; }

  var dbg = gl.getExtension("WEBGL_debug_renderer_info");
  st.renderer = dbg ? gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER);
  // "ANGLE (NVIDIA, NVIDIA GeForce RTX 3070 (0x00002484) Direct3D11 ...)" -> "NVIDIA GeForce RTX 3070"
  var corto = st.renderer, parts = st.renderer.match(/^ANGLE \((.*)\)$/);
  if (parts) { var pz = parts[1].split(", "); if (pz.length > 1) corto = pz[1].replace(/\s*\(0x[0-9A-Fa-f]+\).*$/, "").replace(/\s+Direct3D.*$/, "").replace(/\s+\(.*$/, ""); }
  if (/SwiftShader|llvmpipe|Basic Render/i.test(st.renderer)) corto = "Software (no está usando la GPU)";
  $("gpu").textContent = corto;
  $("gpu").title = st.renderer;

  canvas.addEventListener("webglcontextlost", function (e) {
    e.preventDefault();
    st.lost = true;
    finish("La GPU dejó de responder y el driver se reinició (contexto perdido).");
  });

  var VS = "#version 300 es\nin vec2 p; uniform float base; flat out float layer; void main(){ layer = base + float(gl_InstanceID); gl_Position = vec4(p, 0.0, 1.0); }";
  // Carga tipo FurMark / juego: capas de "pelo" semitransparentes una arriba de otra. Usa a la vez
  // texturas (con caché y memoria), cálculo de iluminación y mezcla de colores (ROPs), así el calor se
  // reparte por el chip como en un juego exigente y no se concentra solo en los núcleos de cálculo.
  var FS = [
    "#version 300 es",
    "precision highp float;",
    "uniform vec2 res; uniform float t; uniform float nl; uniform sampler2D noise;",
    "flat in float layer;",
    "out vec4 o;",
    "void main(){",
    "  vec2 uv = gl_FragCoord.xy / res.y;",
    "  float h = (layer + 0.5) / nl;",
    "  vec2 sway = vec2(sin(t * 0.9 + uv.y * 3.0), cos(t * 0.7 + uv.x * 2.5)) * 0.02 * h;",
    "  vec2 p = uv * 0.045 + sway * 0.03;",
    "  vec4 n1 = texture(noise, p);",
    "  vec4 n2 = texture(noise, p * 2.03 + n1.xy * 0.004);",
    "  vec4 n3 = texture(noise, p * 4.11 + n2.zw * 0.003);",
    "  vec4 n4 = texture(noise, p * 0.37 + vec2(h * 0.002, t * 0.0004));",
    "  vec4 n5 = texture(noise, p.yx * 9.3 + n3.xy * 0.002);",
    "  vec4 n6 = textureLod(noise, p * 23.7 - n4.zw * 0.004, 0.0);",
    "  float strand = n5.x * 0.55 + n6.y * 0.25 + n2.z * 0.2;",
    "  vec3 nrm = normalize(vec3(n1.xy - 0.5, 0.6) + vec3(n3.zw - 0.5, 0.0) * 0.5);",
    "  vec3 L = normalize(vec3(0.4 * sin(t * 0.3), 0.6, 0.7));",
    "  float dif = max(dot(nrm, L), 0.0);",
    "  float spe = pow(max(dot(reflect(-L, nrm), vec3(0.0, 0.0, 1.0)), 0.0), 24.0);",
    "  vec3 base = mix(mix(vec3(0.918, 0.024, 0.812), vec3(0.945, 0.243, 0.533), n4.x), vec3(1.0, 0.651, 0.004), n4.y * n4.y);",
    "  vec3 col = base * (0.25 + 0.75 * dif) * (0.35 + 0.65 * h) + spe * 0.35;",
    "  float a = smoothstep(h - 0.08, h + 0.02, strand) * (1.0 - h * 0.6);",
    "  o = vec4(col, a * 0.85);",
    "}"].join("\n");

  function compile(type, src) {
    var s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
    return s;
  }
  function program(fs) {
    var p = gl.createProgram();
    gl.attachShader(p, compile(gl.VERTEX_SHADER, VS)); gl.attachShader(p, compile(gl.FRAGMENT_SHADER, fs));
    gl.bindAttribLocation(p, 0, "p"); gl.linkProgram(p);
    if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p));
    return p;
  }
  var prog;
  try { prog = program(FS); }
  catch (e) { finish("No se pudo compilar el shader: " + e.message); return; }

  var vb = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, vb);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
  gl.enableVertexAttribArray(0); gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);

  var U = {}; ["res", "t", "base", "nl", "noise"].forEach(function (n) { U[n] = gl.getUniformLocation(prog, n); });

  // Textura de ruido fija (siempre la misma, para que la verificación sea reproducible), con mipmaps
  var noiseTex = (function () {
    var px = new Uint8Array(NOISE * NOISE * 4), x = 0x9E3779B9 >>> 0;
    for (var i = 0; i < px.length; i++) { x ^= x << 13; x >>>= 0; x ^= x >>> 17; x ^= x << 5; x >>>= 0; px[i] = x & 255; }
    var tex = gl.createTexture();
    gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, NOISE, NOISE, 0, gl.RGBA, gl.UNSIGNED_BYTE, px);
    gl.generateMipmap(gl.TEXTURE_2D);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.REPEAT);
    return tex;
  })();

  function target(w, h) {
    var tex = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    var fb = gl.createFramebuffer();
    gl.bindFramebuffer(gl.FRAMEBUFFER, fb);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex, 0);
    return { tex: tex, fb: fb, w: w, h: h };
  }

  var W = 0, H = 0;
  var chkA = target(CHECK_SIZE, CHECK_SIZE);
  function resize() {
    var w = Math.max(64, Math.floor(innerWidth * (devicePixelRatio || 1)));
    var h = Math.max(64, Math.floor(innerHeight * (devicePixelRatio || 1)));
    if (w === W && h === H) return;
    W = w; H = h; canvas.width = W; canvas.height = H; st.width = W; st.height = H;
  }
  resize(); addEventListener("resize", resize);

  // Dibuja "capas" capas de pelo sobre un fondo oscuro
  function drawFur(fb, w, h, t, capas) {
    gl.bindFramebuffer(gl.FRAMEBUFFER, fb);
    gl.viewport(0, 0, w, h);
    gl.disable(gl.BLEND);
    gl.clearColor(0.03, 0.02, 0.04, 1); gl.clear(gl.COLOR_BUFFER_BIT);
    gl.useProgram(prog);
    gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, noiseTex);
    gl.uniform1i(U.noise, 0); gl.uniform2f(U.res, w, h); gl.uniform1f(U.t, t); gl.uniform1f(U.nl, capas);
    gl.enable(gl.BLEND); gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
    for (var i = 0; i < capas; i += LOTE) { gl.uniform1f(U.base, i); gl.drawArraysInstanced(gl.TRIANGLES, 0, 3, Math.min(LOTE, capas - i)); }
    gl.disable(gl.BLEND);
  }

  // Verificación: el mismo cuadro fijo tiene que dar siempre el mismo resultado.
  var refHash = null, refPix = null, pix = new Uint8Array(CHECK_SIZE * CHECK_SIZE * 4);
  function hash(a) {
    var h = 0x811c9dc5 >>> 0;
    for (var i = 0; i < a.length; i++) { h ^= a[i]; h = Math.imul(h, 0x01000193) >>> 0; }
    return h;
  }
  function check() {
    drawFur(chkA.fb, CHECK_SIZE, CHECK_SIZE, 7.77, CHECK_LAYERS);
    gl.bindFramebuffer(gl.FRAMEBUFFER, chkA.fb);
    gl.readPixels(0, 0, CHECK_SIZE, CHECK_SIZE, gl.RGBA, gl.UNSIGNED_BYTE, pix);
    if (SIMERR && st.checks === 4) pix[1234] ^= 0x10;
    var h = hash(pix);
    st.checks++;
    if (refHash === null) { refHash = h; refPix = pix.slice(); return; }
    if (h !== refHash) {
      var d = 0;
      for (var i = 0; i < pix.length; i += 4) {
        if (pix[i] !== refPix[i] || pix[i + 1] !== refPix[i + 1] || pix[i + 2] !== refPix[i + 2]) d++;
      }
      st.errors++; st.diffPixels += d;
    }
  }

  t0 = performance.now(); var lastCheck = t0, lastSec = t0, frames = 0, passes = 8, running = true;
  st.state = "running";
  // Cuadros en vuelo: se manda un cuadro nuevo solo cuando la GPU terminó alguno de los anteriores (hasta 2 en cola).
  // Así la placa nunca se queda esperando al monitor ni al procesador, y los cuadros/s son los que realmente dibujó.
  var pend = [];
  function gpuLibre(now) {
    while (pend.length && (gl.getSyncParameter(pend[0].s, gl.SYNC_STATUS) === gl.SIGNALED || now - pend[0].t > 3000)) gl.deleteSync(pend.shift().s);
    return pend.length < 2;
  }
  function frame() {
    if (!running) return;
    var now = performance.now();   // el reloj real: sin tope de cuadros, la hora que pasa el navegador a esta función no es confiable
    if (gl.isContextLost()) return;
    var dibujo = gpuLibre(now);
    if (dibujo) {
      resize();
      drawFur(null, W, H, (now - t0) / 1000, passes);
      var sy = gl.fenceSync(gl.SYNC_GPU_COMMANDS_COMPLETE, 0);
      gl.flush();
      if (sy) pend.push({ s: sy, t: now });
      frames++;
      if (now - lastCheck >= CHECK_EVERY) { lastCheck = now; check(); }
    }
    if (now - lastSec >= 1000) {
      var fps = frames * 1000 / (now - lastSec); frames = 0; lastSec = now;
      // carga adaptativa: más capas hasta que la GPU no pueda pasar de 45 cuadros/s (= GPU al 100%)
      if (fps > FPS_ALTO && passes < MAX_PASSES) passes = Math.min(MAX_PASSES, Math.ceil(passes * (fps > FPS_ALTO * 2 ? 1.6 : 1.25)) + 1);
      else if (fps < FPS_BAJO && passes > 1) passes = Math.max(1, Math.floor(passes * 0.8));
      st.fps = Math.round(fps * 10) / 10; st.passes = passes; st.elapsed = Math.round((now - t0) / 1000);
      if (now - t0 > Math.min(30000, DURATION * 0.3)) {      // puntaje: recién cuando la carga se estabilizó
        scoreSum += fps * passes * W * H / 1e6; scoreN++;
        st.score = Math.round(scoreSum / scoreN);
      }
      ui(); post("/status");
    }
    if (now - t0 >= DURATION) { finish(null); return; }
    // si la GPU todavía está ocupada se espera un instante, sin dejar al procesador girando en vacío
    if (dibujo) requestAnimationFrame(frame); else setTimeout(frame, 2);
  }
  function fmt(s) { s = Math.max(0, Math.round(s)); return Math.floor(s / 60) + ":" + ("0" + (s % 60)).slice(-2); }
  function ui() {
    $("tiempo").textContent = fmt(st.elapsed) + " / " + fmt(st.duration);
    $("fps").textContent = st.fps;
    $("carga").textContent = st.passes + (st.passes === 1 ? " capa" : " capas") + " por cuadro";
    $("checks").textContent = st.checks;
    $("errores").textContent = st.errors + (st.errors ? " (" + st.diffPixels + " píxeles)" : "");
    $("errores").className = st.errors ? "bad" : "ok";
    $("prog").style.width = Math.min(100, 100 * st.elapsed / st.duration) + "%";
  }
  function finish(err) {
    if (st.state === "done") return;
    running = false;
    if (err) st.error = err;
    st.state = "done";
    st.elapsed = Math.round((performance.now() - t0) / 1000);
    var ok = !st.errors && !st.lost && !st.error && !st.aborted;
    $("rtitle").textContent = st.aborted && !st.errors ? "Prueba cortada" : (ok ? "Sin errores" : "Se detectaron problemas");
    $("rtitle").className = ok ? "ok" : "bad";
    $("rtext").textContent = st.error || (st.errors + (st.errors === 1 ? " error" : " errores") + " de cálculo en " + st.checks + " verificaciones, " + fmt(st.elapsed) + " de prueba.");
    $("result").style.display = "grid";
    try { ui(); } catch (e) {}
    post("/done");
  }
  addEventListener("keydown", function (e) { if (e.key === "Escape") { st.aborted = true; finish(null); } });
  // ---- Temperaturas en vivo (las lee el script con LibreHardwareMonitor)
  var LIM = { core: [80, 88], hot: [95, 105], delta: [22, 28], mem: [96, 104], cpu: [85, 95] };
  // el gráfico cubre toda la prueba (una muestra cada 1,5 s)
  var hist = [], HIST_MAX = Math.min(1200, Math.max(30, Math.ceil(DURATION / 1500) + 4));
  function lv(k, v) { if (v == null || !LIM[k]) return "lvn"; return v >= LIM[k][1] ? "lv2" : v >= LIM[k][0] ? "lv1" : "lv0"; }
  function row(label, k, v, mx, unit) {
    if (v == null && mx == null) return "";
    unit = unit || " °C";
    return '<span class="lbl">' + label + '</span><span class="now ' + lv(k, v) + '">' + (v == null ? "-" : v + unit) + "</span>" +
           '<span class="max">' + (mx == null ? "" : "máx " + '<b class="' + lv(k, mx) + '">' + mx + unit + "</b>") + "</span>";
  }
  function drawSpark() {
    var c = $("spark"), g = c.getContext("2d"), w = c.width, h = c.height;
    g.clearRect(0, 0, w, h);
    if (hist.length < 2) return;
    var lo = 1e9, hi = -1e9;
    hist.forEach(function (p) { ["core", "hot", "mem"].forEach(function (k) { if (p[k] != null) { lo = Math.min(lo, p[k]); hi = Math.max(hi, p[k]); } }); });
    if (lo > hi) return;
    lo = Math.floor((lo - 3) / 5) * 5; hi = Math.ceil((hi + 3) / 5) * 5;
    $("rango").textContent = lo + "–" + hi + " °C";
    g.strokeStyle = "rgba(255,255,255,.08)"; g.lineWidth = 1;
    for (var y = 1; y < 4; y++) { g.beginPath(); g.moveTo(0, h * y / 4); g.lineTo(w, h * y / 4); g.stroke(); }
    [["mem", "#38bdf8"], ["core", "#F13E88"], ["hot", "#FFA601"]].forEach(function (s) {
      g.strokeStyle = s[1]; g.lineWidth = 3; g.beginPath(); var started = false;
      hist.forEach(function (p, i) {
        if (p[s[0]] == null) return;
        var x = 2 + Math.min(1, p.t / DURATION) * (w - 4), yy = h - 4 - (p[s[0]] - lo) * (h - 8) / (hi - lo);
        if (!started) { g.moveTo(x, yy); started = true; } else g.lineTo(x, yy);
      });
      g.stroke();
    });
  }
  function sensors() {
    if (st.state === "done") return;
    fetch("/sensors", { cache: "no-store" }).then(function (r) { return r.json(); }).then(function (d) {
      if (!d) return;
      if (!d.ok) { $("sens").innerHTML = '<div class="nosens">' + (d.motivo || "Sin sensores") + "</div>"; $("spark").style.display = "none"; return; }
      $("spark").style.display = "block";
      $("sens").innerHTML = '<div class="temps">' +
        row("GPU núcleo", "core", d.core, d.coreMax) + row("GPU hotspot", "hot", d.hot, d.hotMax) +
        row("Diferencia", "delta", d.delta, d.deltaMax) + row("Memoria de video", "mem", d.mem, d.memMax) +
        row("Consumo", "", d.power, d.powerMax, " W") + row("Carga GPU", "", d.load, null, " %") +
        row("CPU", "cpu", d.cpu, d.cpuMax) + "</div>";
      hist.push({ t: performance.now() - t0, core: d.core, hot: d.hot, mem: d.mem });
      if (hist.length > HIST_MAX) hist.shift();
      drawSpark();
    }).catch(function () {});
  }
  setInterval(sensors, 1500); sensors();

  ui(); post("/status");
  requestAnimationFrame(frame);
})();
</script>
</body>
</html>
'@

$IntegradaRegex = 'Radeon\(TM\) Graphics|Radeon Graphics|Radeon \d{3}M|Vega \d|Intel.*(UHD|Iris|HD Graphics|Graphics$)|Intel\(R\) Graphics|Arc\(TM\) Graphics$|Microsoft Basic|SwiftShader|llvmpipe|lavapipe'
$DedicadaRegex = 'NVIDIA|GeForce|Quadro|RTX|GTX|Radeon RX|Radeon Pro|Radeon VII|Arc A\d|Arc B\d|Arc\(TM\) [AB]\d'

function Install-MemtestVulkan {
    $a = Get-GitHubLatestAsset 'GpuZelenograd/memtest_vulkan' '^memtest_vulkan.*\.exe$' $null 'verbose'
    $url = if ($a) { $a.Url } else { $Fallback.MemtestVkUrl }
    $sha = if ($a) { $a.Sha256 } else { $null }
    $dir = Join-Path $ToolsDir 'memtest_vulkan'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $dest = Join-Path $dir 'memtest_vulkan.exe'
    if (-not (Save-Url $url $dest $sha)) { return $false }
    return (Test-ExeFile $dest)
}

function Find-Browser {
    $c = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )
    foreach ($p in $c) { if ($p -and (Test-Path $p)) { return $p } }
    foreach ($n in 'msedge.exe', 'chrome.exe') {
        try {
            $v = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$n" -ErrorAction Stop).'(default)'
            if ($v -and (Test-Path $v)) { return $v }
        } catch {}
    }
    return $null
}

function Get-PciLinkProps([string]$Id) {
    $keys = 'DEVPKEY_PciDevice_CurrentLinkSpeed', 'DEVPKEY_PciDevice_MaxLinkSpeed', 'DEVPKEY_PciDevice_CurrentLinkWidth', 'DEVPKEY_PciDevice_MaxLinkWidth'
    $h = @{}
    foreach ($x in @(Get-PnpDeviceProperty -InstanceId $Id -KeyName $keys -ErrorAction SilentlyContinue)) { $h[$x.KeyName] = $x.Data }
    if (-not $h['DEVPKEY_PciDevice_MaxLinkWidth']) { return $null }
    return @{
        Cw = [int]$h['DEVPKEY_PciDevice_CurrentLinkWidth']; Mw = [int]$h['DEVPKEY_PciDevice_MaxLinkWidth']
        Cs = [int]$h['DEVPKEY_PciDevice_CurrentLinkSpeed']; Ms = [int]$h['DEVPKEY_PciDevice_MaxLinkSpeed']
    }
}

# Enlace en este momento según el driver de NVIDIA (Windows a veces deja guardado el del arranque, en reposo)
function Get-NvidiaLink([string]$Dev) {
    $smi = Get-NvidiaSmi
    if (-not $smi -or -not $Dev) { return $null }
    try {
        $out = & $smi '--query-gpu=pci.device_id,pcie.link.gen.current,pcie.link.width.current' '--format=csv,noheader,nounits' 2>$null
        foreach ($l in @($out)) {
            $v = @([string]$l -split ',\s*')
            if ($v.Count -lt 3 -or $v[0] -notmatch $Dev) { continue }
            $g = 0; $w = 0
            if ([int]::TryParse($v[1].Trim(), [ref]$g) -and [int]::TryParse($v[2].Trim(), [ref]$w) -and $g -ge 1 -and $g -le 6 -and $w -ge 1) { return @{ Cs = $g; Cw = $w } }
        }
    } catch {}
    return $null
}

function Get-GpuLinks {
    $out = @()
    foreach ($d in @(Get-PnpDevice -PresentOnly -Class Display -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'PCI\*' })) {
        $id = [string]$d.InstanceId
        $l = Get-PciLinkProps $id
        if (-not $l) { continue }
        $fuente = 'Windows'
        if ($id -match '^PCI\\VEN_1002') {
            # Radeon RX 5000 en adelante: el chip cuelga de un puente que trae la propia placa, y su enlace con ese puente
            # siempre figura al máximo (x16 Gen4/Gen5). El enlace real con la mother es el del puente de más arriba.
            $cur = $id
            for ($n = 0; $n -lt 3; $n++) {
                $par = $null
                try { $par = [string](Get-PnpDeviceProperty -InstanceId $cur -KeyName 'DEVPKEY_Device_Parent' -ErrorAction Stop).Data } catch {}
                if (-not $par -or $par -notmatch '^PCI\\VEN_1002') { break }
                $pl = Get-PciLinkProps $par
                if ($pl) { $l = $pl; $fuente = 'puente de la placa' }
                $cur = $par
            }
        } elseif ($id -match '^PCI\\VEN_10DE&DEV_([0-9A-F]{4})') {
            $nl = Get-NvidiaLink $Matches[1]
            if ($nl) { $l.Cs = $nl.Cs; $l.Cw = $nl.Cw; $fuente = 'driver NVIDIA' }
        }
        $out += [pscustomobject]@{ Nombre = Get-Clean $d.FriendlyName; Cw = $l.Cw; Mw = $l.Mw; Cs = $l.Cs; Ms = $l.Ms; Fuente = $fuente }
    }
    return $out
}

function Get-DriverResets([datetime]$Desde) {
    $prov = 'Display', 'nvlddmkm', 'amdkmdag', 'amdwddmg', 'igfx', 'igfxn', 'igfxnd', 'igdkmd64', 'igdkmdn64', 'igdkmdnd64'
    return @(Get-SystemEvents $Desde | Where-Object { $prov -contains $_.ProviderName })
}

function Show-GpuSensorStats($St, [string]$Contexto) {
    if (-not $St -or $St.Muestras -eq 0) { return }
    $parts = @()
    if ($St.GpuName) { $parts += $St.GpuName }
    if ($null -ne $St.GpuTempMax) { $parts += ("núcleo máx {0:N0} °C" -f $St.GpuTempMax) }
    if ($null -ne $St.GpuHotMax) { $parts += ("hotspot máx {0:N0} °C" -f $St.GpuHotMax) }
    if ($null -ne $St.GpuDeltaMax) { $parts += ("diferencia máx {0:N0} °C" -f $St.GpuDeltaMax) }
    if ($null -ne $St.GpuMemMax) { $parts += ("memoria máx {0:N0} °C" -f $St.GpuMemMax) }
    if ($null -ne $St.GpuPowerMax) { $parts += ("{0:N0} W" -f $St.GpuPowerMax) }
    if ($St.GpuLoadN) { $parts += ("carga prom {0:N0}%" -f ($St.GpuLoadSum / $St.GpuLoadN)) }
    if ($parts.Count) { Log ("Sensores GPU ({0}, máximos sostenidos): {1}" -f $Contexto, ($parts -join ' | ')) }
    if ($St.Peak) {
        $picos = @()
        foreach ($pk in @(@('GpuTemp', 'núcleo'), @('GpuHot', 'hotspot'), @('GpuMem', 'memoria'))) {
            $pv = $St.Peak[$pk[0]]; $mv = $St[$pk[0] + 'Max']
            if ($null -ne $pv -and $null -ne $mv -and $pv -ge $mv + 3) { $picos += ('{0} {1:N0} °C' -f $pk[1], $pv) }
        }
        if ($picos.Count) { Log ("  Picos de una sola lectura (no se tienen en cuenta): {0}" -f ($picos -join ', ')) 'DarkGray' }
    }
    if ($Global:GpuTempDump -and $Global:GpuTempDump.Count) {
        Log ("  Detalle de los sensores de temperatura de la GPU ({0}, máximo de una lectura, para comparar con HWiNFO/GPU-Z):" -f $Contexto) 'DarkGray'
        Log ("    " + ((@($Global:GpuTempDump.Keys) | ForEach-Object { '{0} {1:N0}' -f $_, $Global:GpuTempDump[$_] }) -join ' | ')) 'DarkGray'
        if ($Global:NvHotCorregido) { Log '    El hotspot se toma de NVAPI (el mismo que GPU-Z/HWiNFO): el "GPU Hot Spot" de LibreHardwareMonitor daba distinto.' 'DarkGray' }
        $Global:GpuTempDump = [ordered]@{}
    }
    if (-not $Global:AvisosSensor) { $Global:AvisosSensor = @{} }
    if ($null -ne $St.GpuTempMax -and $St.GpuTempMax -ge 88 -and -not $Global:AvisosSensor['gpucore']) {
        $Global:AvisosSensor['gpucore'] = $true
        Set-Verdict 'GPU' 'ATENCION' ("El núcleo de la GPU llegó a {0:N0} °C: cerca de su límite. Revisar pasta, ventiladores y flujo de aire del gabinete." -f $St.GpuTempMax)
    }
    # Diferencia núcleo/hotspot: solo se evalúa en el stress (núcleo al 100%, como un juego). En el test de
    # VRAM el núcleo está casi sin carga y el calor se concentra en el controlador de memoria del chip:
    # el hotspot sube mucho más que la temperatura promedio del núcleo y la diferencia sale grande
    # aunque la pasta esté bien (ej. 3090: 27 °C en el test de VRAM y 14 °C en el stress).
    if ($Contexto -match 'VRAM' -and $null -ne $St.GpuDeltaMax -and $St.GpuDeltaMax -ge 20) {
        Log ("  La diferencia núcleo/hotspot del test de VRAM ({0:N0} °C) no se evalúa: con la memoria saturada y el núcleo casi sin carga es normal que sea alta. Se evalúa en el stress." -f $St.GpuDeltaMax) 'DarkGray'
    }
    # RTX 50: NVIDIA no publica el hotspot. Lo que haya sale de una lectura no oficial (LibreHardwareMonitor
    # con PawnIO) que puede marcar de más: se anota en el reporte técnico pero no genera aviso.
    $rtx50 = Test-Rtx50 $St.GpuName
    if ($rtx50 -and $null -ne $St.GpuDeltaMax) {
        Log ("  RTX 50: el hotspot ({0:N0} °C, diferencia {1:N0} °C) es una lectura no oficial; no se evalúa. Para revisar la pasta, comparar con HWiNFO/GPU-Z actualizados." -f $St.GpuHotMax, $St.GpuDeltaMax) 'DarkGray'
    }
    # Diferencia núcleo/hotspot con el stress tipo FurMark. Con 2+ placas del mismo chip en el historial
    # se compara contra ellas (lo más justo); si no, límites fijos.
    if (-not $rtx50 -and $Contexto -notmatch 'VRAM' -and $null -ne $St.GpuDeltaMax -and -not $Global:AvisosSensor['gpudelta']) {
        $d = [double]$St.GpuDeltaMax
        $ref = Compare-HistorialPor 'GpuDev' ([string]$Global:M.Gpu['DevId']) 'GpuDif' 1
        if ($ref -and $ref.N -ge 2) {
            $med = [double]$ref.Mediana
            Log ("  Diferencia núcleo/hotspot: {0:N0} °C; en {1} placa(s) con el mismo chip la mediana es {2:N0} °C." -f $d, $ref.N, $med)
            if ($d -ge 20 -and $d -ge $med + 8) {
                $Global:AvisosSensor['gpudelta'] = $true
                Set-Verdict 'GPU' 'ATENCION' ("Diferencia de {0:N0} °C entre el núcleo y el punto más caliente (hotspot), {1:N0} °C más que otras placas con el mismo chip: típico de pasta térmica seca o disipador que no apoya parejo." -f $d, ($d - $med))
            } elseif ($d -ge 20 -and $d -ge $med + 5) {
                Set-Verdict 'GPU' 'INFO' ("Diferencia núcleo/hotspot de {0:N0} °C, algo más alta que en otras placas con el mismo chip ({1:N0} °C)." -f $d, $med)
            }
        } elseif ($d -ge 28) {
            $Global:AvisosSensor['gpudelta'] = $true
            Set-Verdict 'GPU' 'ATENCION' ("Diferencia de {0:N0} °C entre el núcleo y el punto más caliente (hotspot): típico de pasta térmica seca o disipador que no apoya parejo." -f $d)
        } elseif ($d -ge 22) {
            Set-Verdict 'GPU' 'INFO' ("Diferencia núcleo/hotspot de {0:N0} °C: un poco alta. Si en FurMark da menos de 20 °C, la pasta está bien; si da más, revisar pasta y montaje." -f $d)
        }
    }
    if (-not $rtx50 -and $null -ne $St.GpuHotMax -and $St.GpuHotMax -ge 105 -and -not $Global:AvisosSensor['gpuhot']) {
        $Global:AvisosSensor['gpuhot'] = $true
        Set-Verdict 'GPU' 'ATENCION' ("El hotspot de la GPU llegó a {0:N0} °C: la placa baja la velocidad para protegerse. Revisar pasta y montaje del disipador." -f $St.GpuHotMax)
    }
    # Memoria de video: memtest_vulkan la usa al 100% (lectura/escritura continua de toda la VRAM, como
    # minar) y la calienta mucho más que un juego o el stress. GDDR6X empieza a bajar velocidad a ~110 °C.
    $esVram = $Contexto -match 'VRAM'
    $memAviso = if ($esVram) { 108 } else { 104 }
    $memInfo = if ($esVram) { 100 } else { 96 }
    if ($null -ne $St.GpuMemMax -and $St.GpuMemMax -ge $memAviso -and -not $Global:AvisosSensor['gpumem']) {
        $Global:AvisosSensor['gpumem'] = $true
        Set-Verdict 'GPU' 'ATENCION' ("La memoria de video llegó a {0:N0} °C en {1} (empieza a bajar velocidad cerca de 110 °C): revisar los thermal pads de la VRAM." -f $St.GpuMemMax, $Contexto)
    } elseif ($null -ne $St.GpuMemMax -and $St.GpuMemMax -ge $memInfo -and -not $Global:AvisosSensor['gpumem']) {
        $Global:AvisosSensor['gpumem'] = $true
        $txt = if ($esVram) { 'normal con esta prueba, que satura la memoria más que cualquier juego' } else { 'alta pero dentro de lo que maneja la memoria' }
        Set-Verdict 'GPU' 'INFO' ("Memoria de video a {0:N0} °C en {1}: {2}." -f $St.GpuMemMax, $Contexto, $txt)
    }
}

function Invoke-VramTest([int]$MaxMin = 9) {
    Section 'VIDEO - MEMORIA (VRAM) CON memtest_vulkan'
    $exe = Find-ToolFile 'memtest_vulkan' 'memtest_vulkan*.exe'
    if (-not $exe) {
        if (Ask-Yes 'Falta memtest_vulkan. ¿Bajarlo ahora?' $true) { Install-Tools @(Get-ToolStatus | Where-Object { $_.Id -eq 'memtestvk' }) }
        $exe = Find-ToolFile 'memtest_vulkan' 'memtest_vulkan*.exe'
    }
    if (-not $exe) { Set-Verdict 'GPU' 'INFO' 'No se hizo el test de VRAM: falta memtest_vulkan (menú H).'; return }
    Log 'Escribe y verifica la memoria de la placa de video (~5 minutos). Prueba primero la placa dedicada. Q = cortar.'
    [void](Start-Sensors)
    $stats = New-SensorStats
    Set-Marker 'Test de VRAM (memtest_vulkan)'
    $t0 = Get-Date
    $pc = $null
    try { $pc = New-Object NetBench.ProcCapture -ArgumentList $exe, '', (Split-Path $exe) }
    catch { Log ("  No se pudo iniciar memtest_vulkan: {0}" -f $_.Exception.GetBaseException().Message) 'Yellow'; Clear-Marker; return }
    $seen = 0; $device = ''; $devices = @(); $estado = $null; $errLines = @(); $stopped = $false; $lastLine = ''; $vramBw = $null
    $calientes = 0; $cortePorTemp = $null; $pasadas = 0
    $VramCorte = 100   # °C de memoria sostenidos: se corta para no exigirla de más (GDDR6X baja velocidad recién a ~110 °C)
    while ($true) {
        Start-Sleep -Milliseconds 500
        foreach ($l in $pc.Lines($seen)) {
            $seen++
            $t = $l.Trim()
            if (-not $t) { continue }
            $lastLine = $t
            if ($t -match '^\d+: Bus=') { $devices += $t; Log ('  ' + $t) 'DarkGray' }
            elseif ($t -match 'Standard 5-minute test of (.+)$') { $device = $Matches[1]; Log ('  Probando: ' + $device) }
            elseif ($t -match 'Error found') { $errLines += $t; Log ('  ' + $t) 'Red' }
            elseif ($t -match 'checked:\s*[\d.]+GB\s*([\d.]+)GB/s') {
                $bw = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
                if ($null -eq $vramBw -or $bw -gt $vramBw) { $vramBw = $bw }
                if ($t -match '^(\d+)\s+iteration') { $pasadas = [math]::Max($pasadas, [int]$Matches[1]) }
            }
            elseif ($t -match 'Standard 5-minute test PASSed') { $estado = 'OK' }
            elseif ($t -match 'Standard 5-minute test fail|ERRORS FOUND') { $estado = 'FALLA' }
            elseif ($t -match 'Runtime error|early exit|failed|Retrying') { Log ('  ' + $t) 'Yellow' }
        }
        $tTxt = ''
        if ($Global:Lhm) {
            $sr = Read-Sensors
            Update-SensorStats $stats $sr
            if ($null -ne $sr.GpuTemp) { $tTxt = (' | GPU {0:N0} °C' -f $sr.GpuTemp) }
            if ($null -ne $sr.GpuMem) { $tTxt += (' | memoria {0:N0} °C' -f $sr.GpuMem) }
            if ($null -ne $sr.GpuMem -and $sr.GpuMem -ge $VramCorte) { $calientes++ } else { $calientes = 0 }
            if ($calientes -ge 6 -and $pasadas -gt 0) { $cortePorTemp = [double]$sr.GpuMem; Log ("  La memoria llegó a {0:N0} °C: se corta el test para no exigirla de más ({1} iteraciones de memtest_vulkan sin errores)." -f $sr.GpuMem, $pasadas) 'Yellow'; break }
        }
        $el = ((Get-Date) - $t0).TotalSeconds
        if ($estado -or ($errLines.Count -gt 0 -and $el -gt 20)) { break }
        if ($pc.Exited -or $el -gt $MaxMin * 60) { break }
        $short = if ($lastLine.Length -gt 70) { $lastLine.Substring(0, 70) } else { $lastLine }
        Write-Progress -Activity 'Test de VRAM (memtest_vulkan)' -Status ("{0:N0} s | errores {1}{2} | {3}" -f $el, $errLines.Count, $tTxt, $short) -PercentComplete ([math]::Min(100, 100 * $el / 320))
        if (Test-KeyQ) { $stopped = $true; break }
    }
    Write-Progress -Activity 'Test de VRAM' -Completed
    $pc.KillTree()
    Clear-Marker
    $min = ((Get-Date) - $t0).TotalMinutes
    if (-not $device -and $devices.Count) { $device = $devices[0] }
    $devName = $device
    if ($device -match '(\d+)GB\s+(.+)$') { $devName = ('{0} ({1} GB)' -f $Matches[2].Trim(), $Matches[1]) }
    if ($devName -match $IntegradaRegex) { Log '  El dispositivo probado es la iGPU: este test revisa la RAM compartida, no una placa de video.' 'DarkGray' }
    $Global:M.Gpu['VramDispositivo'] = $devName
    $Global:M.Gpu['VramMin'] = [math]::Round($min, 1)
    if ($vramBw -and $devName -notmatch $IntegradaRegex) {
        $Global:M.Gpu['VramGBs'] = [math]::Round($vramBw)
        Log ("  Velocidad de la memoria (lectura y verificación): {0:N0} GB/s" -f $vramBw)
        [void](Show-ComparacionGpu 'VramGBs' $vramBw 'Velocidad de la memoria de video')
    }
    if ($errLines.Count -or $estado -eq 'FALLA') {
        $Global:M.Gpu['VramRes'] = 'con errores'
        Set-Verdict 'GPU' 'FALLA' ("La memoria de video (VRAM) tiene errores: {0} detección(es) de memtest_vulkan. Chip de memoria fallado, soldadura o VRAM sobrecalentada." -f [math]::Max(1, $errLines.Count))
        Add-Prueba 'Memoria de video (VRAM)' $min 'FALLA' $devName
    } elseif ($cortePorTemp) {
        $Global:M.Gpu['VramRes'] = 'sin errores'
        Set-Verdict 'GPU' 'OK' ("VRAM: sin errores en {0} iteraciones de memtest_vulkan ({1}); el test se cortó antes por temperatura." -f $pasadas, $devName)
        if (-not $Global:AvisosSensor) { $Global:AvisosSensor = @{} }
        $Global:AvisosSensor['gpumem'] = $true
        Set-Verdict 'GPU' 'INFO' ("La memoria de video llegó a {0:N0} °C con la prueba de memoria al 100% (más exigente que cualquier juego) y se cortó por seguridad, sin errores. En juegos queda más baja; si en juegos pasa los 100 °C, conviene cambiar los thermal pads." -f $cortePorTemp)
        Add-Prueba 'Memoria de video (VRAM)' $min 'OK' ("{0} · {1} iteraciones" -f $devName, $pasadas)
    } elseif ($estado -eq 'OK') {
        $Global:M.Gpu['VramRes'] = 'sin errores'
        Set-Verdict 'GPU' 'OK' ("VRAM: prueba completa de memtest_vulkan sin errores ({0})." -f $devName)
        Add-Prueba 'Memoria de video (VRAM)' $min 'OK' $devName
    } elseif ($stopped) {
        $Global:M.Gpu['VramRes'] = 'cortada'
        Set-Verdict 'GPU' 'INFO' ("Test de VRAM cortado a los {0:N1} min sin errores hasta ese momento." -f $min)
        Add-Prueba 'Memoria de video (VRAM)' $min 'Cancelada' $devName
    } else {
        $Global:M.Gpu['VramRes'] = 'no se pudo completar'
        Set-Verdict 'GPU' 'ATENCION' ("memtest_vulkan no pudo completar la prueba (última línea: {0}). Revisar el driver de video; si el driver está bien, puede ser la placa." -f $lastLine)
        Add-Prueba 'Memoria de video (VRAM)' $min 'Con observaciones' 'no se pudo completar'
    }
    if ($null -ne $stats.GpuMemMax) { $Global:M.Gpu['VramMemMax'] = [math]::Round($stats.GpuMemMax) }
    Show-GpuSensorStats $stats 'test de VRAM'
}

# Lo que ve la página del stress: valores actuales y máximos (los mismos que van al informe)
function Get-GpuSensorJson($R, $St) {
    $rd = { param($v) if ($null -eq $v) { $null } else { [math]::Round([double]$v) } }
    $delta = $null
    if ($null -ne $R.GpuTemp -and $null -ne $R.GpuHot) { $delta = $R.GpuHot - $R.GpuTemp }
    $o = [ordered]@{
        ok      = ($null -ne $R.GpuTemp -or $null -ne $R.GpuHot)
        motivo  = $(if ($null -eq $R.GpuTemp -and $null -eq $R.GpuHot) { 'La GPU no informa temperatura a LibreHardwareMonitor.' } else { '' })
        nombre  = $R.GpuName
        core    = (& $rd $R.GpuTemp); hot = (& $rd $R.GpuHot); delta = (& $rd $delta); mem = (& $rd $R.GpuMem)
        power   = (& $rd $R.GpuPower); load = (& $rd $R.GpuLoad); cpu = (& $rd $R.CpuTemp)
        coreMax = (& $rd $St.GpuTempMax); hotMax = (& $rd $St.GpuHotMax); deltaMax = (& $rd $St.GpuDeltaMax); memMax = (& $rd $St.GpuMemMax)
        powerMax = (& $rd $St.GpuPowerMax); cpuMax = (& $rd $St.CpuTempMax)
    }
    return (ConvertTo-Json -Compress -InputObject $o)
}

function Invoke-GpuStress([int]$Minutes) {
    Section ("VIDEO - STRESS DE GPU CON VERIFICACIÓN ({0} min)" -f $Minutes)
    $browser = Find-Browser
    if (-not $browser) { Set-Verdict 'GPU' 'INFO' 'No se encontró Edge ni Chrome para el stress de GPU.'; return }
    Log 'Se abre el navegador a pantalla completa con un render pesado. Cada 3 s se dibuja un cuadro fijo y se compara:'
    Log 'si sale distinto, la GPU calculó mal. No toques la PC durante la prueba (Esc en el navegador = terminar).' 'DarkGray'
    [void](Start-Sensors)
    $stats = New-SensorStats
    $srv = $null; $port = 0
    foreach ($try in 1..5) {
        $port = Get-Random -Minimum 47000 -Maximum 48999
        try { $srv = New-Object NetBench.GpuServer -ArgumentList $GpuStressHtml, $port; break } catch { $srv = $null }
    }
    if (-not $srv) { Set-Verdict 'GPU' 'INFO' 'No se pudo abrir el servidor local para el stress de GPU.'; return }
    $prof = Join-Path $env:TEMP 'netbench-gpu-browser'
    $url = "http://127.0.0.1:$port/?min=$Minutes"
    $bargs = @("--user-data-dir=`"$prof`"", '--no-first-run', '--no-default-browser-check', '--start-fullscreen', '--new-window',
        '--force_high_performance_gpu', '--disable-background-timer-throttling', '--disable-renderer-backgrounding',
        '--disable-backgrounding-occluded-windows', '--autoplay-policy=no-user-gesture-required',
        '--disable-gpu-vsync', '--disable-frame-rate-limit', $url)   # sin tope de cuadros: la GPU trabaja al 100% y no espera al monitor
    Set-Marker ("Stress de GPU ({0} min)" -f $Minutes)
    $t0 = Get-Date
    $bp = $null
    try { $bp = Start-Process -FilePath $browser -ArgumentList $bargs -PassThru } catch { Log ("  No se pudo abrir el navegador: {0}" -f $_.Exception.Message) 'Yellow' }
    $links = $null; $resets = @(); $lastPoll = [datetime]::MinValue; $st = $null; $stopped = $false; $corte = ''
    $lastSens = [datetime]::MinValue
    $serie = New-Object System.Collections.ArrayList
    if (-not $Global:Lhm) { $srv.Sensors = (ConvertTo-Json -Compress -InputObject ([ordered]@{ ok = $false; motivo = 'Sin sensores: falta LibreHardwareMonitor (Herramientas).' })) }
    $limit = $Minutes * 60 + 120
    while (-not $srv.Done) {
        Start-Sleep -Milliseconds 700
        $el = ((Get-Date) - $t0).TotalSeconds
        if ($srv.LastStatus) { try { $st = $srv.LastStatus | ConvertFrom-Json } catch {} }
        if ($Global:Lhm -and ((Get-Date) - $lastSens).TotalMilliseconds -ge 1400) {
            $lastSens = Get-Date
            $sr = Read-Sensors
            if ($st -and $st.elapsed -ge 8) { Update-SensorStats $stats $sr }   # sin los primeros segundos de arranque
            $srv.Sensors = (Get-GpuSensorJson $sr $stats)
            if ($null -ne $sr.GpuTemp -or $null -ne $sr.GpuHot) {
                $rr = { param($v) if ($null -eq $v) { $null } else { [math]::Round([double]$v, 1) } }
                [void]$serie.Add(@([math]::Round($el), (& $rr $sr.GpuTemp), (& $rr $sr.GpuHot), (& $rr $sr.GpuMem)))
            }
        }
        if (((Get-Date) - $lastPoll).TotalSeconds -ge 3) {
            $lastPoll = Get-Date
            $r = @(Get-DriverResets $t0)
            if ($r.Count -gt $resets.Count) { $resets = $r; Write-Host ("  !! El driver de video se reinició ({0})" -f $r.Count) -ForegroundColor Red }
            if (-not $links -and $st -and $st.elapsed -ge 40) { $links = @(Get-GpuLinks) }
        }
        if (-not $srv.PageLoaded -and $el -gt 60) { $corte = 'el navegador no cargó la página de prueba'; Log '  El navegador no cargó la página de prueba.' 'Yellow'; break }
        if ($srv.PageLoaded -and $srv.LastUpdate -ne [datetime]::MinValue -and ((Get-Date) - $srv.LastUpdate).TotalSeconds -gt 45) {
            $corte = 'la ventana de la prueba dejó de responder (navegador cerrado o minimizado, o GPU colgada)'
            Log '  La página dejó de responder más de 45 s (GPU colgada o navegador cerrado).' 'Yellow'; break
        }
        if ($el -gt $limit) { $corte = 'no terminó en el tiempo previsto'; break }
        $txt = if ($st) { "{0}/{1} s | {2} cuadros/s | {3} pasadas | verificaciones {4} | errores {5}" -f $st.elapsed, $st.duration, $st.fps, $st.passes, $st.checks, $st.errors } else { 'esperando al navegador...' }
        if ($stats.GpuName -and $null -ne $stats.GpuTempMax) { $txt += (" | GPU máx {0:N0} °C" -f $stats.GpuTempMax) }
        Write-Progress -Activity 'Stress de GPU (mirá la ventana del navegador)' -Status ($txt + ' | Q = cortar') -PercentComplete ([math]::Min(100, 100 * $el / ($Minutes * 60)))
        if (Test-KeyQ) { $stopped = $true; break }
    }
    Write-Progress -Activity 'Stress de GPU' -Completed
    if ($srv.FinalStatus) { try { $st = $srv.FinalStatus | ConvertFrom-Json } catch {} }
    Start-Sleep -Seconds 2
    if ($srv.FinalStatus) { try { $st = $srv.FinalStatus | ConvertFrom-Json } catch {} }
    $completo = [bool]$srv.Done      # la página llegó al final (o se cortó con Esc): el resultado es el definitivo
    $srv.Stop()
    if ($bp) { try { Start-Process -FilePath 'taskkill.exe' -ArgumentList '/T', '/F', '/PID', $bp.Id -WindowStyle Hidden -Wait } catch {} }
    Clear-Marker
    $resets = @(Get-DriverResets $t0)
    $min = ((Get-Date) - $t0).TotalMinutes
    if ($st) {
        Log ("GPU usada por el navegador: {0}" -f $st.renderer)
        Log ("Duración {0} s | {1} cuadros/s con {2} pasadas | verificaciones {3} | errores {4}{5}" -f $st.elapsed, $st.fps, $st.passes, $st.checks, $st.errors, $(if ($st.lost) { ' | CONTEXTO PERDIDO' } else { '' }))
    }
    foreach ($e in ($resets | Select-Object -First 5)) { Log ('    ' + $e.ProviderName + ' ' + (Get-EventLine $e)) 'Red' }
    $res = 'OK'
    $hayDedicada = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $DedicadaRegex }).Count -gt 0
    if (-not $st -and $stopped) {
        $res = 'Cancelada'
    } elseif (-not $st) {
        $res = 'Con observaciones'
        Set-Verdict 'GPU' 'ATENCION' 'El stress de GPU no devolvió resultados (el navegador no arrancó o se cerró).'
    } else {
        if ($st.error) { $res = 'Con observaciones'; Set-Verdict 'GPU' 'ATENCION' ("No se pudo correr el stress de GPU: {0}" -f $st.error) }
        if ($st.renderer -match 'SwiftShader|llvmpipe|Basic Render|Microsoft Basic') {
            $res = 'Con observaciones'; Set-Verdict 'GPU' 'ATENCION' 'El navegador dibujó por software, no con la GPU: falta el driver de video o la aceleración está desactivada.'
        } elseif ($hayDedicada -and $st.renderer -notmatch $DedicadaRegex) {
            $res = 'Con observaciones'; Set-Verdict 'GPU' 'ATENCION' ("El stress corrió en {0} y no en la placa dedicada: el monitor tiene que estar conectado a la placa de video." -f $st.renderer)
        }
        if ([int]$st.errors -gt 0) {
            $res = 'FALLA'
            Set-Verdict 'GPU' 'FALLA' ("La GPU calculó mal en {0} de {1} verificaciones (artefactos). Típico de VRAM o núcleo inestables, overclock de fábrica agresivo o temperatura." -f $st.errors, $st.checks)
        }
        if ($st.lost) { $res = 'FALLA'; Set-Verdict 'GPU' 'FALLA' 'La GPU dejó de responder durante el stress y el driver se reinició.' }
        if (($st.aborted -or $stopped) -and $res -eq 'OK') { $res = 'Cancelada' }
        elseif (-not $completo -and $res -eq 'OK') {
            # antes esto salía como "OK": una prueba que no terminó no es una prueba aprobada
            $res = 'Con observaciones'
            Set-Verdict 'GPU' 'ATENCION' ("El stress de GPU no llegó a terminar: {0} a los {1:N0} s de {2:N0}. Repetirlo sin tocar la PC; si vuelve a pasar, la placa se cuelga bajo carga." -f $(if ($corte) { $corte } else { 'se interrumpió' }), $st.elapsed, $st.duration)
        }
    }
    if ($resets.Count) {
        $res = 'FALLA'
        Set-Verdict 'GPU' 'FALLA' ("El driver de video se reinició {0} vez/veces bajo carga (evento 4101/nvlddmkm/amdkmdag): placa inestable, alimentación (cables PCIe) o temperatura." -f $resets.Count)
    }
    if ($links) {
        foreach ($l in $links) {
            Log ("Enlace PCIe bajo carga: {0} x{1}/x{2} {3}/{4} (leído de: {5})" -f $l.Nombre, $l.Cw, $l.Mw, (Get-PcieGen $l.Cs), (Get-PcieGen $l.Ms), $l.Fuente)
            if ($l.Nombre -match $IntegradaRegex) { continue }
            $Global:M.Gpu['Enlace'] = ("x{0} {1}" -f $l.Cw, (Get-PcieGen $l.Cs))
            $apu8000 = $Global:Cpu -and $Global:Cpu.Nombre -match 'Ryzen \d 8\d{3}G'
            if ($l.Cw -lt $l.Mw -and -not $apu8000) {
                Set-Verdict 'GPU' 'ATENCION' ("Bajo carga la placa trabaja a x{0} de x{1}: slot sucio, pin dañado, riser o líneas compartidas con un M.2." -f $l.Cw, $l.Mw)
            } elseif ($l.Cs -lt $l.Ms) {
                Set-Verdict 'GPU' 'INFO' ("Bajo carga el enlace va a {0} y la placa soporta {1}: normal si el slot o la mother son de una generación menor; si no, revisar riser/slot." -f (Get-PcieGen $l.Cs), (Get-PcieGen $l.Ms))
            }
        }
    }
    if ($stats.GpuLoadN -and ($stats.GpuLoadSum / $stats.GpuLoadN) -lt 80 -and $st -and -not $st.aborted) {
        Set-Verdict 'GPU' 'INFO' ("La GPU promedió {0:N0}% de carga en el stress (lo ideal es más de 90%)." -f ($stats.GpuLoadSum / $stats.GpuLoadN))
    }
    Show-GpuSensorStats $stats 'stress de GPU'
    if ($serie.Count -ge 3) {
        $step = [math]::Max(1, [math]::Ceiling($serie.Count / 160))
        $Global:M.Gpu['Serie'] = @(for ($i = 0; $i -lt $serie.Count; $i += $step) { , $serie[$i] })
    }
    if ($res -eq 'OK' -and $st -and -not $st.error) { Set-Verdict 'GPU' 'OK' ("Stress de GPU {0:N0} min sin errores de cálculo." -f ($st.elapsed / 60)) }
    $Global:M.Gpu['StressMin'] = $(if ($st) { [math]::Round($st.elapsed / 60, 1) } else { 0 })
    $Global:M.Gpu['StressErr'] = $(if ($st) { [int]$st.errors } else { $null })
    $Global:M.Gpu['StressChecks'] = $(if ($st) { [int]$st.checks } else { $null })
    $Global:M.Gpu['Renderer'] = $(if ($st) { $st.renderer } else { '' })
    if ($st -and $completo -and -not $stopped -and $st.score -and -not $st.aborted -and -not $st.error -and $st.renderer -notmatch 'SwiftShader|llvmpipe|Basic Render') {
        $Global:M.Gpu['Score'] = [int]$st.score
        Log ("  Puntaje del stress: {0:N0} (trabajo por segundo, independiente de la resolución)" -f $st.score)
        $cmp = Show-ComparacionGpu 'GpuPuntaje2' ([double]$st.score) 'Rendimiento de la GPU'
        if ($cmp) { $Global:M.Gpu['VsHist'] = @{ Pct = [math]::Round($cmp.Pct); N = $cmp.N } }
    }
    $Global:M.Gpu['Reinicios'] = $resets.Count
    foreach ($k in 'GpuTempMax', 'GpuHotMax', 'GpuDeltaMax', 'GpuMemMax', 'GpuPowerMax') { if ($null -ne $stats[$k]) { $Global:M.Gpu[$k] = [math]::Round($stats[$k]) } }
    if ($stats.GpuName) { $Global:M.Gpu['Modelo'] = $stats.GpuName }
    Add-Prueba 'Stress de GPU con verificación' $min $res $(if ($st) { "{0} verificaciones, {1} errores" -f $st.checks, $st.errors } else { '' })
}

# ======================================================================
#  Fuente: CPU y GPU al 100% al mismo tiempo (el peor caso de consumo, como un juego pesado)
# ======================================================================
function Invoke-PruebaFuente([int]$Minutes = 10) {
    Section ("FUENTE - CPU Y GPU AL 100% JUNTOS ({0} min)" -f $Minutes)
    Log 'Carga el CPU (todos los hilos, con verificación) y la GPU (stress del navegador) a la vez: es el máximo consumo'
    Log 'del equipo. Una fuente floja o un VRM al límite se nota acá: apagón, reinicio, errores o caída de los 12 V.' 'DarkGray'
    Log 'Si la PC se apaga, al volver a abrir el programa queda anotado como falla de la fuente.' 'DarkGray'
    $browser = Find-Browser
    if (-not $browser) { Set-Verdict 'Fuente' 'INFO' 'No se encontró Edge ni Chrome para la parte de GPU de la prueba de fuente.'; return }
    [void](Start-Sensors)
    $ref = Get-Reference
    if (-not $ref) { return }
    $stats = New-SensorStats
    $srv = $null; $port = 0
    foreach ($try in 1..5) {
        $port = Get-Random -Minimum 47000 -Maximum 48999
        try { $srv = New-Object NetBench.GpuServer -ArgumentList $GpuStressHtml, $port; break } catch { $srv = $null }
    }
    if (-not $srv) { Set-Verdict 'Fuente' 'INFO' 'No se pudo abrir el servidor local para la prueba de fuente.'; return }
    if (-not $Global:Lhm) { $srv.Sensors = (ConvertTo-Json -Compress -InputObject ([ordered]@{ ok = $false; motivo = 'Sin sensores: falta LibreHardwareMonitor (Herramientas).' })) }
    $n = [Environment]::ProcessorCount
    $run = New-Object NetBench.StressRun -ArgumentList @([int[]](0..($n - 1)), [double]($Minutes * 60 + 20), [uint64[]]$ref)
    Set-Marker ("Prueba de fuente CPU+GPU ({0} min)" -f $Minutes)
    $t0 = Get-Date
    $prof = Join-Path $env:TEMP 'netbench-gpu-browser'
    $url = "http://127.0.0.1:$port/?min=$Minutes"
    $bargs = @("--user-data-dir=`"$prof`"", '--no-first-run', '--no-default-browser-check', '--start-fullscreen', '--new-window',
        '--force_high_performance_gpu', '--disable-background-timer-throttling', '--disable-renderer-backgrounding',
        '--disable-backgrounding-occluded-windows', '--disable-gpu-vsync', '--disable-frame-rate-limit', $url)
    $bp = $null
    try { $bp = Start-Process -FilePath $browser -ArgumentList $bargs -PassThru } catch { Log ("  No se pudo abrir el navegador: {0}" -f $_.Exception.Message) 'Yellow' }
    $cpuArrancado = $false; $st = $null; $stopped = $false; $corte = ''; $resets = @(); $whea = 0
    $lastSens = [datetime]::MinValue; $lastPoll = [datetime]::MinValue
    $limit = $Minutes * 60 + 120
    while (-not $srv.Done) {
        Start-Sleep -Milliseconds 700
        $el = ((Get-Date) - $t0).TotalSeconds
        if ($srv.LastStatus) { try { $st = $srv.LastStatus | ConvertFrom-Json } catch {} }
        # el CPU arranca cuando la página ya está dibujando, así los dos trabajan el mismo tiempo
        if (-not $cpuArrancado -and $srv.PageLoaded -and $st -and $st.state -eq 'running') { $run.Start(); $cpuArrancado = $true }
        if ($Global:Lhm -and ((Get-Date) - $lastSens).TotalMilliseconds -ge 1400) {
            $lastSens = Get-Date
            $sr = Read-Sensors
            if ($cpuArrancado -and $run.Elapsed -ge 10) { Update-SensorStats $stats $sr }
            $srv.Sensors = (Get-GpuSensorJson $sr $stats)
        }
        if (((Get-Date) - $lastPoll).TotalSeconds -ge 3) {
            $lastPoll = Get-Date
            $r = @(Get-DriverResets $t0)
            if ($r.Count -gt $resets.Count) { $resets = $r; Write-Host ("  !! El driver de video se reinició ({0})" -f $r.Count) -ForegroundColor Red }
            $w = @(Get-WheaSince $t0)
            if ($w.Count -gt $whea) { $whea = $w.Count; Write-Host ("  !! WHEA durante la prueba ({0})" -f $whea) -ForegroundColor Red }
        }
        if (-not $srv.PageLoaded -and $el -gt 60) { $corte = 'el navegador no cargó la página de prueba'; Log '  El navegador no cargó la página de prueba.' 'Yellow'; break }
        if ($srv.PageLoaded -and $srv.LastUpdate -ne [datetime]::MinValue -and ((Get-Date) - $srv.LastUpdate).TotalSeconds -gt 45) {
            $corte = 'la ventana de la prueba dejó de responder (navegador cerrado o minimizado, o GPU colgada)'
            Log '  La página dejó de responder más de 45 s (GPU colgada o navegador cerrado).' 'Yellow'; break
        }
        if ($el -gt $limit) { $corte = 'no terminó en el tiempo previsto'; break }
        $tot = if ($null -ne $stats.TotalMax) { (' | consumo CPU+GPU máx {0:N0} W' -f $stats.TotalMax) } else { '' }
        $txt = if ($st) { "{0}/{1} s | GPU: {2} cuadros/s, errores {3} | CPU: errores {4}{5}" -f $st.elapsed, $st.duration, $st.fps, $st.errors, $run.TotalErrors, $tot } else { 'esperando al navegador...' }
        Write-Progress -Activity 'Prueba de fuente: CPU + GPU al 100%' -Status ($txt + ' | Q = cortar') -PercentComplete ([math]::Min(100, 100 * $el / ($Minutes * 60)))
        if (Test-KeyQ) { $stopped = $true; break }
    }
    Write-Progress -Activity 'Prueba de fuente' -Completed
    $run.StopFlag = $true
    $w0 = Get-Date
    while ($run.Running -and ((Get-Date) - $w0).TotalSeconds -lt 15) { Start-Sleep -Milliseconds 200 }
    if ($srv.FinalStatus) { try { $st = $srv.FinalStatus | ConvertFrom-Json } catch {} }
    Start-Sleep -Seconds 1
    if ($srv.FinalStatus) { try { $st = $srv.FinalStatus | ConvertFrom-Json } catch {} }
    $completo = [bool]$srv.Done
    $cortada = $stopped -or ($st -and $st.aborted)
    $srv.Stop()
    if ($bp) { try { Start-Process -FilePath 'taskkill.exe' -ArgumentList '/T', '/F', '/PID', $bp.Id -WindowStyle Hidden -Wait } catch {} }
    Clear-Marker
    $min = ((Get-Date) - $t0).TotalMinutes
    $resets = @(Get-DriverResets $t0)
    $w = @(Get-WheaSince $t0)
    if ($st) { Log ("GPU: {0} s, {1} cuadros/s, {2} verificaciones, {3} errores{4}" -f $st.elapsed, $st.fps, $st.checks, $st.errors, $(if ($st.lost) { ', CONTEXTO PERDIDO' } else { '' })) }
    Log ("CPU: {0:N0} s con {1} hilos, {2} errores de cálculo" -f $run.Elapsed, $n, $run.TotalErrors)
    foreach ($e in ($resets | Select-Object -First 5)) { Log ('    ' + $e.ProviderName + ' ' + (Get-EventLine $e)) 'Red' }
    if ($w.Count) { Show-Whea $w -DuranteTest }
    $f = $Global:M.Fuente
    $f['Min'] = [math]::Round($min, 1)
    foreach ($k in 'CpuPowerMax', 'GpuPowerMax', 'TotalMax', 'V12Min') { if ($null -ne $stats[$k]) { $f[$k] = [math]::Round([double]$stats[$k], $(if ($k -eq 'V12Min') { 2 } else { 0 })) } }
    if ($null -ne $stats.CpuPowerMax -or $null -ne $stats.GpuPowerMax) {
        Log ("Consumo máximo sostenido: CPU {0} W | GPU {1} W | CPU+GPU {2} W (el resto del equipo suma ~40-80 W más)" -f $(if ($null -ne $f.CpuPowerMax) { $f.CpuPowerMax } else { '-' }), $(if ($null -ne $f.GpuPowerMax) { $f.GpuPowerMax } else { '-' }), $(if ($null -ne $f.TotalMax) { $f.TotalMax } else { '-' }))
    }
    if ($null -ne $f.V12Min) { Log ("+12 V mínimo bajo carga (según el sensor de la mother): {0:N2} V" -f $f.V12Min) }
    $res = 'OK'
    $problemas = @()
    if ($run.TotalErrors -gt 0) { $problemas += ("{0} errores de cálculo del CPU" -f $run.TotalErrors) }
    if ($st -and [int]$st.errors -gt 0) { $problemas += ("{0} errores de la GPU" -f $st.errors) }
    if ($st -and $st.lost) { $problemas += 'la GPU dejó de responder' }
    if ($resets.Count) { $problemas += ("{0} reinicio(s) del driver de video" -f $resets.Count) }
    if ($w.Count) { $problemas += ("{0} error(es) WHEA" -f $w.Count) }
    if ($problemas.Count) {
        $res = 'FALLA'
        Set-Verdict 'Fuente' 'FALLA' ("Con CPU y GPU juntos al 100% hubo {0}. Si cada uno por separado pasó bien, apunta a la fuente (o al VRM de la mother) que no sostiene la carga combinada: probar con otra fuente." -f ($problemas -join ', '))
    }
    if ($null -ne $f.V12Min -and $f.V12Min -lt 11.4) {
        if ($res -eq 'OK') { $res = 'Con observaciones' }
        Set-Verdict 'Fuente' 'ATENCION' ("Los +12 V bajaron a {0:N2} V con el equipo al máximo (lo mínimo aceptable es 11,4 V). Medir con tester: puede ser la fuente o el sensor de la mother." -f $f.V12Min)
    }
    if ($st -and $st.error -or (-not $st -and -not $stopped)) {
        if ($res -eq 'OK') { $res = 'Con observaciones' }
        Set-Verdict 'Fuente' 'ATENCION' 'La parte de GPU de la prueba de fuente no corrió bien (ver el stress de GPU).'
    } elseif ($st -and $st.renderer -match 'SwiftShader|llvmpipe|Basic Render|Microsoft Basic') {
        if ($res -eq 'OK') { $res = 'Con observaciones' }
        Set-Verdict 'Fuente' 'ATENCION' 'El navegador dibujó por software: la GPU no se cargó y la prueba de fuente no es válida (falta el driver de video).'
    } elseif (-not $completo -and -not $cortada) {
        if ($res -eq 'OK') { $res = 'Con observaciones' }
        Set-Verdict 'Fuente' 'ATENCION' ("La prueba de fuente no llegó a terminar: {0} a los {1:N0} s de {2:N0}. Repetirla sin tocar la PC; si vuelve a pasar, el equipo se cuelga con CPU y GPU al máximo." -f $(if ($corte) { $corte } else { 'se interrumpió' }), $st.elapsed, $st.duration)
    }
    if ($cortada -and $res -eq 'OK') { $res = 'Cancelada'; Set-Verdict 'Fuente' 'INFO' ("Prueba de fuente cortada a los {0:N0} min sin problemas hasta ese momento." -f $min) }
    if ($res -eq 'OK') {
        Set-Verdict 'Fuente' 'OK' ("{0:N0} min con CPU y GPU al 100% juntos, sin apagones, reinicios ni errores{1}." -f $min, $(if ($null -ne $f.TotalMax) { (" (CPU+GPU {0:N0} W)" -f $f.TotalMax) } else { '' }))
    }
    $f['Res'] = $res
    Show-SensorStats $stats 'prueba de fuente'
    Add-Prueba 'Fuente: CPU + GPU al 100%' $min $res $(if ($null -ne $f.TotalMax) { "consumo CPU+GPU máx {0:N0} W" -f $f.TotalMax } else { 'CPU y GPU con verificación' })
}

function Invoke-GpuTest {
    Test-GpuIdentity
    Section 'VIDEO (GPU)'
    $vga = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
    foreach ($g in $vga) {
        $mem = if ($g.AdapterRAM -gt 0) { ' | {0:N0} GB informados por Windows' -f ($g.AdapterRAM / 1GB) } else { '' }
        Log ("  {0} (driver {1}){2}" -f (Get-Clean $g.Name), $g.DriverVersion, $mem)
        if ($g.Name -match 'Basic Display|Básico|Microsoft Basic') {
            Set-Verdict 'GPU' 'ATENCION' 'Falta el driver de video: instalarlo antes de probar la GPU (sin driver los resultados no sirven).'
        }
    }
    $doV = Ask-Yes 'Test de memoria de video (memtest_vulkan, ~5 min)' $true
    $min = Ask-Int 'Minutos de stress de GPU (0 = no hacer)' 10 0 120
    if ($doV) { Invoke-VramTest }
    if ($min -gt 0) { Invoke-GpuStress $min }
    Add-Pendiente 'Video: mirar que no haya artefactos en pantalla, probar todas las salidas (HDMI/DP) y que los ventiladores giren sin ruido.'
}

# ======================================================================
#  Modo interfaz (ventana con pasos guiados)
# ======================================================================
$UiHtml = @'
<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>NET-TestBench</title>
<style>
:root {
  --bg:#0b0b0e; --panel:#141419; --panel2:#1b1b22; --line:#2a2a33; --ink:#f3f4f6; --muted:#9aa1ad; --dim:#6b7280;
  --magenta:#EA06CF; --rosa:#F13E88; --naranja:#FFA601; --grad:linear-gradient(90deg,#EA06CF,#F13E88,#FFA601);
  --ok:#22c55e; --ok-bg:rgba(34,197,94,.12); --warn:#f59e0b; --warn-bg:rgba(245,158,11,.13); --fail:#ef4444; --fail-bg:rgba(239,68,68,.13);
  --run:#38bdf8; --run-bg:rgba(56,189,248,.12);
}
* { box-sizing:border-box; }
html, body { margin:0; height:100%; background:var(--bg); color:var(--ink); font:14px/1.45 "Segoe UI", Roboto, Arial, sans-serif; }
button { font:inherit; color:inherit; cursor:pointer; }
kbd { display:inline-block; min-width:20px; padding:0 6px; border-radius:5px; border:1px solid #3a3a46; border-bottom-width:2px; background:#202029;
      font:600 11.5px/18px Consolas, "Segoe UI", monospace; color:#d1d5db; text-align:center; }
.app { display:grid; grid-template-rows:auto auto 1fr; height:100vh; }

/* Encabezado */
header { display:flex; align-items:center; gap:16px; padding:10px 18px; background:#000; position:relative; }
header::after { content:""; position:absolute; left:0; right:0; bottom:0; height:3px; background:var(--grad); }
.logo { height:46px; width:46px; }
.word { font-weight:800; letter-spacing:.06em; font-size:18px; }
.word span { background:var(--grad); -webkit-background-clip:text; background-clip:text; color:transparent; }
.title { display:flex; flex-direction:column; }
.title small { color:var(--muted); font-size:12px; }
.session { margin-left:auto; display:flex; align-items:center; gap:14px; font-size:13px; color:var(--muted); }
.session b { color:var(--ink); font-weight:600; }
.session .orden b { color:var(--naranja); }
.hbtn { display:flex; align-items:center; gap:8px; background:#16161c; border:1px solid var(--line); border-radius:9px; padding:6px 10px; }
.hbtn:hover { border-color:#4b4b58; }

/* Franja del equipo */
.equipo { display:flex; flex-wrap:wrap; gap:4px 22px; padding:9px 18px; background:#0f0f13; border-bottom:1px solid var(--line); font-size:12.5px; color:var(--muted); }
.equipo b { color:#e5e7eb; font-weight:600; }

/* Cuerpo */
main { display:grid; grid-template-columns:minmax(420px, 1fr) minmax(440px, 1.15fr); gap:14px; padding:14px 18px 16px; min-height:0; }
.col { display:flex; flex-direction:column; gap:12px; min-height:0; }
.scroll { overflow-y:auto; min-height:0; padding-right:4px; }
.scroll::-webkit-scrollbar, .log::-webkit-scrollbar { width:9px; }
.scroll::-webkit-scrollbar-thumb, .log::-webkit-scrollbar-thumb { background:#2c2c36; border-radius:6px; }
h2 { margin:2px 0 8px; font-size:12px; letter-spacing:.1em; text-transform:uppercase; color:var(--muted); display:flex; align-items:center; gap:8px; }
h2::before { content:""; width:16px; height:3px; border-radius:2px; background:var(--grad); }

.card { background:var(--panel); border:1px solid var(--line); border-radius:12px; }
.proto { padding:14px 16px; display:grid; gap:10px; }
.proto .row { display:flex; flex-wrap:wrap; gap:8px 16px; align-items:center; color:var(--muted); font-size:13px; }
.proto label { display:flex; align-items:center; gap:6px; }
.big { display:flex; align-items:center; justify-content:center; gap:10px; border:0; border-radius:10px; padding:11px 16px; font-weight:700; font-size:15px;
       background:var(--grad); color:#fff; }
.big:disabled { filter:grayscale(.8) brightness(.6); cursor:not-allowed; }
.big kbd { background:rgba(0,0,0,.25); border-color:rgba(0,0,0,.3); color:#fff; }

.steps { display:grid; gap:8px; }
.step { display:grid; grid-template-columns:34px 1fr auto; gap:4px 12px; padding:12px 14px; align-items:start; transition:border-color .15s; }
.step.running { border-color:var(--run); box-shadow:0 0 0 1px var(--run) inset; }
.num { width:30px; height:30px; border-radius:50%; display:grid; place-items:center; font-weight:800; background:#24242d; color:#d1d5db; font-size:13px; }
.step.ok .num { background:var(--ok); color:#04130a; } .step.atencion .num { background:var(--warn); color:#1d1300; }
.step.falla .num { background:var(--fail); color:#fff; } .step.running .num { background:var(--run); color:#04121a; }
.st-title { font-weight:700; font-size:14.5px; display:flex; align-items:center; gap:8px; flex-wrap:wrap; }
.st-dur { color:var(--dim); font-weight:500; font-size:12px; }
.st-desc { color:var(--muted); font-size:12.8px; grid-column:2; }
.st-opts { grid-column:2; display:flex; flex-wrap:wrap; gap:6px 12px; align-items:center; font-size:12.5px; color:var(--muted); margin-top:4px; }
.st-res { grid-column:2 / 4; font-size:12.5px; color:var(--muted); margin-top:4px; }
.st-side { display:flex; flex-direction:column; align-items:flex-end; gap:6px; }
.run { display:flex; align-items:center; gap:7px; background:#1f1f27; border:1px solid #34343f; border-radius:8px; padding:6px 10px; font-weight:600; }
.run:hover:not(:disabled) { border-color:var(--rosa); }
.run:disabled { opacity:.45; cursor:not-allowed; }
details { grid-column:2 / 4; font-size:12.5px; color:var(--muted); }
details summary { cursor:pointer; color:#c7cbd3; width:max-content; }
details p { margin:6px 0 0; }
select, input[type=number], input[type=text] { background:#0f0f14; color:var(--ink); border:1px solid #34343f; border-radius:7px; padding:4px 8px; font:inherit; }
input[type=checkbox] { accent-color:var(--rosa); width:15px; height:15px; }
.chip { font-size:11.5px; font-weight:700; padding:2px 9px; border-radius:99px; white-space:nowrap; }
.chip.ok { color:var(--ok); background:var(--ok-bg); } .chip.atencion, .chip.ATENCION { color:var(--warn); background:var(--warn-bg); }
.chip.falla, .chip.FALLA { color:var(--fail); background:var(--fail-bg); } .chip.corriendo { color:var(--run); background:var(--run-bg); }
.chip.pend { color:var(--dim); background:#1d1d24; } .chip.cancelada, .chip.sin { color:#cbd5e1; background:#262630; }
.chip.OK { color:var(--ok); background:var(--ok-bg); }
.sep { margin:6px 0 2px; font-size:12px; color:var(--dim); letter-spacing:.06em; text-transform:uppercase; }

/* Panel derecho */
.now { padding:14px 16px; display:grid; gap:8px; }
.now-top { display:flex; align-items:center; gap:10px; }
.now-title { font-weight:700; font-size:15px; }
.now-idle { color:var(--muted); }
.cancel { margin-left:auto; background:var(--fail-bg); color:#fecaca; border:1px solid rgba(239,68,68,.4); border-radius:8px; padding:6px 12px; font-weight:600; display:flex; gap:8px; align-items:center; }
.bar { height:8px; background:#23232c; border-radius:6px; overflow:hidden; }
.bar i { display:block; height:100%; width:0; background:var(--grad); transition:width .4s; }
.bar.indet i { width:35% !important; animation:ind 1.4s infinite ease-in-out; }
@keyframes ind { 0% { margin-left:-35%; } 100% { margin-left:100%; } }
.pstatus { font-size:12.5px; color:#c7cbd3; font-variant-numeric:tabular-nums; min-height:18px; }
.logwrap { display:flex; flex-direction:column; min-height:0; flex:1; }
.log { flex:1; overflow-y:auto; background:#08080b; border:1px solid var(--line); border-radius:12px; padding:10px 12px;
       font:12.4px/1.5 Consolas, "Cascadia Mono", monospace; white-space:pre-wrap; word-break:break-word; min-height:160px; }
.log .h { color:#fff; font-weight:700; margin-top:8px; }
.c-Red { color:#f87171; } .c-Yellow { color:#fbbf24; } .c-Green { color:#4ade80; } .c-Cyan { color:#67e8f9; } .c-White { color:#fff; }
.c-DarkGray { color:#6b7280; } .c-DarkCyan { color:#5eead4; } .c-Gray { color:#cbd5e1; } .c-Magenta { color:#f0abfc; }
.results { padding:14px 16px; display:grid; gap:10px; }
.res-top { display:flex; align-items:center; gap:10px; flex-wrap:wrap; }
.verdict { font-weight:800; font-size:16px; }
.verdict.ok { color:var(--ok); } .verdict.ATENCION { color:var(--warn); } .verdict.FALLA { color:var(--fail); }
.areas { display:grid; gap:6px; }
.area { display:grid; grid-template-columns:150px auto 1fr; gap:4px 10px; align-items:start; font-size:13px; }
.area ul { grid-column:1 / 4; margin:0 0 4px; padding-left:18px; color:#d1d5db; font-size:12.5px; }
.area li.FALLA::marker { color:var(--fail); } .area li.ATENCION::marker { color:var(--warn); }
.actions { display:flex; flex-wrap:wrap; gap:8px; }
.act { background:#1f1f27; border:1px solid #34343f; border-radius:8px; padding:6px 11px; display:flex; gap:7px; align-items:center; }
.act:hover:not(:disabled) { border-color:var(--rosa); }
.act:disabled { opacity:.4; cursor:not-allowed; }
.send { border-top:1px solid var(--line); padding-top:10px; display:grid; gap:8px; }
.send-top { display:flex; align-items:center; gap:10px; flex-wrap:wrap; }
.send-top .act { margin-left:auto; }
.recs { display:grid; gap:6px; }
.rec { display:flex; align-items:center; gap:12px; flex-wrap:wrap; }
.hint2 { color:var(--muted); font-size:12.5px; display:flex; align-items:center; gap:6px; }
.okt { color:#4ade80; } .badt { color:#f87171; }
.act.pri2 { background:var(--grad); border:0; color:#fff; font-weight:700; }
.banner { padding:10px 14px; border-radius:10px; font-size:13px; display:flex; gap:10px; align-items:center; }
.banner.warn { background:var(--warn-bg); color:#fde68a; } .banner.fail { background:var(--fail-bg); color:#fecaca; }

/* Inicio */
.start { display:grid; place-items:center; padding:20px; }
.start .card { width:min(560px, 100%); padding:22px 24px; display:grid; gap:14px; }
.start h1 { margin:0; font-size:22px; }
.start p { margin:0; color:var(--muted); }
.field { display:grid; gap:6px; }
.field label { font-size:12.5px; color:var(--muted); }
.field input, .field select { padding:9px 11px; font-size:15px; }
.pref { display:flex; align-items:stretch; }
.pref span { display:grid; place-items:center; padding:0 12px; border:1px solid var(--line); border-right:0; border-radius:8px 0 0 8px; background:#1d1d25; color:var(--naranja); font-weight:800; font-size:16px; letter-spacing:.02em; transition:opacity .15s; }
.pref span.sinpre { opacity:.3; text-decoration:line-through; }
.pref input { flex:1; border-radius:0 8px 8px 0; font-size:18px; font-weight:700; letter-spacing:.04em; }
.field .hint { font-size:12px; color:var(--muted); }
.field label.chk { display:flex; align-items:center; gap:8px; font-size:13.5px; color:#d1d5db; cursor:pointer; }
.field label.chk input { width:16px; height:16px; padding:0; }
.check { display:grid; gap:6px; font-size:13px; color:#d1d5db; margin:0; padding-left:18px; }

/* Ventanas */
.modal { position:fixed; inset:0; background:rgba(0,0,0,.66); display:none; place-items:center; z-index:20; padding:20px; }
.modal.show { display:grid; }
.dlg { width:min(560px, 100%); background:#121217; border:1px solid #33333d; border-radius:14px; padding:20px 22px; display:grid; gap:14px; position:relative; max-height:90vh; overflow:auto; }
.dlg::before { content:""; position:absolute; left:0; right:0; top:0; height:3px; border-radius:14px 14px 0 0; background:var(--grad); }
.dlg h3 { margin:0; font-size:17px; }
.dlg .hint { color:var(--dim); font-size:12px; }
.opts { display:grid; gap:8px; }
.opt { display:grid; grid-template-columns:auto 1fr; gap:2px 12px; text-align:left; background:#1b1b22; border:1px solid #33333d; border-radius:10px; padding:10px 12px; }
.opt:hover, .opt.def { border-color:var(--rosa); }
.opt small { grid-column:2; color:var(--muted); }
.btns { display:flex; gap:10px; justify-content:flex-end; flex-wrap:wrap; }
.btn { border-radius:9px; padding:9px 16px; font-weight:700; border:1px solid #3a3a46; background:#1f1f27; display:flex; gap:8px; align-items:center; }
.btn.pri { background:var(--grad); border:0; color:#fff; }
.btn.pri kbd { background:rgba(0,0,0,.25); border-color:rgba(0,0,0,.3); color:#fff; }
.tools { display:grid; gap:8px; }
.tool { display:grid; grid-template-columns:1fr auto auto; gap:2px 12px; align-items:center; background:#1b1b22; border:1px solid #2e2e38; border-radius:10px; padding:9px 12px; }
.tool small { color:var(--muted); grid-column:1; }
.keys { display:grid; grid-template-columns:auto 1fr; gap:6px 14px; align-items:center; font-size:13.5px; }
.off { position:fixed; inset:0; background:rgba(0,0,0,.85); display:none; place-items:center; z-index:30; text-align:center; color:var(--muted); }
.off.show { display:grid; }
.off h2 { justify-content:center; font-size:15px; color:#fff; }
@media (max-width:1000px) { main { grid-template-columns:1fr; } .scroll { overflow:visible; } .app { height:auto; } }
</style>
</head>
<body>
<div class="app">
  <header>
    <img class="logo" id="logo" alt="NET Gaming">
    <div class="title"><div class="word">NET <span>GAMING</span></div><small>Banco de pruebas · v__VERSION__</small></div>
    <div class="session" id="session"></div>
  </header>
  <div class="equipo" id="equipo" style="display:none"></div>
  <div id="startView" class="start" style="display:none"></div>
  <main id="mainView" style="display:none">
    <section class="col scroll" id="left"></section>
    <section class="col">
      <div class="card now" id="now"></div>
      <div class="logwrap"><h2>Registro</h2><div class="log" id="log"></div></div>
      <div class="card results" id="results"></div>
    </section>
  </main>
</div>

<div class="modal" id="promptModal"><div class="dlg" id="promptDlg"></div></div>
<div class="modal" id="toolsModal"><div class="dlg" id="toolsDlg"></div></div>
<div class="modal" id="helpModal"><div class="dlg" id="helpDlg"></div></div>
<div class="off" id="off"><div><h2>Se cerró el motor de pruebas</h2><p>La ventana de PowerShell ya no responde. Podés cerrar esta ventana.</p></div></div>

<script>
(function () {
  "use strict";
  var LOGO = "__LOGO__";
  if (LOGO && LOGO.indexOf("data:") === 0) document.getElementById("logo").src = LOGO; else document.getElementById("logo").style.display = "none";

  var STEPS = [
    { id: "chequeo", key: "1", title: "Chequeo general", dur: "1 min",
      desc: "Lo primero: revisa errores de hardware desde el arranque, drivers, RAM, conexiones PCIe, red y la salud de los discos.",
      more: "Lee los eventos WHEA, BSOD y de disco desde que se prendió la PC, controla que estén los drivers de chipset y de video, muestra cada módulo de RAM con su velocidad real, el ancho de enlace de la GPU y los NVMe, dispositivos con error y la velocidad de la red. En Intel 13ª/14ª gen controla el microcode." },
    { id: "drivers", key: "D", title: "Drivers: buscar e instalar", dur: "5-20 min",
      desc: "Si el chequeo marca drivers faltantes: busca e instala solo el chipset AMD, el driver de video (NVIDIA/AMD) y lo que falte por Windows Update.",
      more: "Chipset AMD: baja la última versión de amd.com y la instala sola. NVIDIA: identifica la placa por el ID del chip (sirve aunque no tenga driver), busca el último driver oficial y lo instala solo. AMD Radeon: baja el instalador de AMD, que detecta la placa (hay que tocar Instalar). Windows Update: chipset Intel, ME, red, audio, Wi-Fi y video Intel. Antes de instalar verifica la firma digital del fabricante. Nunca toca BIOS ni firmware. Lo bajado queda en tools\\drivers y se reusa en el próximo equipo. Si algo pide reiniciar, reiniciar antes de seguir con las pruebas. Necesita internet." },
    { id: "smart", key: "2", title: "Discos: SMART + autotest", dur: "3 min",
      desc: "Lee el estado interno de cada disco (desgaste, horas, errores) y corre el autotest corto del propio disco.",
      more: "Un disco con errores de medio, sectores pendientes, spare bajo o critical warning queda como no apto. Necesita smartctl (se baja desde Herramientas)." },
    { id: "allcore", key: "3", title: "CPU: todos los núcleos", durFn: function (o) { return o.min + " min"; },
      desc: "Carga todos los hilos y verifica que cada cálculo dé el resultado correcto. Mide temperatura y consumo.",
      more: "Un solo resultado distinto significa que el CPU calculó mal. También vigila errores WHEA, la frecuencia real (throttling) y compara el rendimiento con otros equipos iguales testeados antes.",
      opts: [{ k: "min", label: "Duración", type: "select", values: [[5, "5 min"], [10, "10 min"], [15, "15 min"], [30, "30 min"]], def: 15 }] },
    { id: "percore", key: "4", title: "CPU: núcleo por núcleo", durFn: function (o, s) { var h = (s.cpu && s.cpu.hilos) || 16; return "~" + Math.max(1, Math.round(o.seg * h / 60)) + " min"; },
      desc: "Prueba un núcleo por vez al boost máximo: es donde fallan los CPUs degradados o con núcleos flojos.",
      more: "Si la PC se cuelga en este paso, al volver a abrir el programa te avisa en qué núcleo fue. Compara el rendimiento de cada núcleo contra sus pares. Para descartar un Intel 13ª/14ª gen degradado usá 180 s.",
      opts: [{ k: "seg", label: "Por núcleo", type: "select", values: [[20, "20 s (rápido)"], [45, "45 s (normal)"], [180, "180 s (profundo)"]], def: 45 }] },
    { id: "gpu", key: "5", title: "Video: identidad + VRAM + stress", durFn: function (o) { return "~" + ((o.vram ? 5 : 0) + o.min) + " min"; },
      desc: "Controla que la placa sea realmente el modelo que dice, prueba la memoria de video y después la GPU al 100% verificando cada cuadro. El monitor tiene que estar en la placa de video.",
      more: "Identidad: compara el chip real grabado en la placa con el nombre que muestra Windows (placas truchas, RX 580 2048SP, LHR), dice el fabricante según el BIOS (si la etiqueta dice otra marca, tiene BIOS de otra placa), la memoria, la versión de BIOS, el límite de potencia vs referencia (NVIDIA) y si el driver está modificado o sin firmar. Al final compara el rendimiento con placas del mismo chip del historial. La VRAM se prueba con memtest_vulkan; si la memoria llega a 100 °C se corta antes, para no exigirla de más. El stress abre el navegador a pantalla completa con una carga tipo FurMark (capas de pelo con texturas, iluminación y transparencias, que reparte el calor como un juego exigente) y compara un cuadro fijo cada 3 s: si sale distinto, la GPU calculó mal. En la misma pantalla del stress se ven en vivo las temperaturas (núcleo, hotspot, diferencia, memoria, CPU), el consumo y un gráfico: no hace falta salir. También vigila reinicios del driver y el enlace PCIe bajo carga.",
      opts: [{ k: "vram", label: "Probar VRAM", type: "check", def: true },
             { k: "min", label: "Stress", type: "select", values: [[0, "no"], [5, "5 min"], [10, "10 min"], [20, "20 min"]], def: 10 }] },
    { id: "fuente", key: "F", title: "Fuente: CPU + GPU al 100%", durFn: function (o) { return o.min + " min"; },
      desc: "CPU y placa de video al máximo al mismo tiempo, como un juego pesado: así se ven las fuentes que no dan más.",
      more: "Corre el stress de CPU con verificación y el de GPU juntos. Si la PC se apaga o se reinicia, al volver a abrir el programa queda anotado como falla de la fuente. También marca errores de cálculo, reinicios del driver de video, WHEA y caída de los +12 V, y mide el consumo de CPU + GPU. Conviene correrla después de los pasos 3 y 5: si cada uno por separado anduvo bien y juntos falla, es la fuente (o el VRM).",
      opts: [{ k: "min", label: "Duración", type: "select", values: [[5, "5 min"], [10, "10 min"], [15, "15 min"], [20, "20 min"]], def: 10 }] },
    { id: "ram", key: "6", title: "RAM: TestMem5", durFn: function (o) { return o.min + "+ min"; },
      desc: "Abre TestMem5 con la config que corresponde a la RAM, y lee el resultado solo: no hay que tocar nada.",
      more: "Se baja solo (TestMem5 0.13). Automática: anta777 DDR5 para Ryzen o Intel, o anta777 Extreme para DDR4. El tiempo es el mínimo: termina la vuelta que esté haciendo. Lee el log de TestMem5: errores, si terminó bien y cuánta RAM probó. En DDR5 la pasada que vale es con XMP/EXPO activado.",
      opts: [{ k: "min", label: "Mínimo", type: "select", values: [[15, "15 min"], [30, "30 min"], [60, "60 min"], [120, "120 min"]], def: 30 },
             { k: "cfg", label: "Config", type: "select", values: [["auto", "Automática"], ["Extreme @ anta777.cfg", "anta777 Extreme"], ["DDR5 Ryzen3D @ anta777.cfg", "anta777 DDR5 AMD"], ["DDR5 Intel @ anta777.cfg", "anta777 DDR5 Intel"], ["1usmus v3 @ 1usmus.cfg", "1usmus v3"], ["Absolut @ anta777.cfg", "anta777 Absolut"]], def: "auto" }] },
    { sep: "Opcionales" },
    { id: "lectura", key: "7", title: "Disco: lectura de superficie", dur: "2-60 min",
      desc: "Lee el disco que elijas buscando zonas ilegibles o lentas. No borra nada.", more: "Modo muestreo (unos 13 GB repartidos en todo el disco) o lectura completa." },
    { id: "escritura", key: "8", title: "Disco: escritura + verificación", dur: "según tamaño",
      desc: "Escribe datos en el espacio libre, los relee y compara: detecta NAND fallada y capacidad falsa.",
      more: "No toca los archivos existentes y borra los suyos al terminar. No deja usar el disco del sistema ni el pendrive del programa: hace falta un disco secundario conectado." },
    { id: "externo", key: "9", title: "Otra prueba externa", dur: "a elección",
      desc: "Prime95, y-cruncher, CoreCycler u otra: el programa la abre, vigila y anota el resultado.",
      more: "Lee solo los errores de Prime95 y de CoreCycler. Para las demás te pregunta si dieron errores." }
  ];
  var opts = {};
  STEPS.forEach(function (s) { if (s.id) { opts[s.id] = {}; (s.opts || []).forEach(function (o) { opts[s.id][o.k] = o.def; }); } });
  var protoOpts = { gpu: null, fuente: null, escritura: false };

  var $ = function (id) { return document.getElementById(id); };
  var esc = function (s) { return String(s == null ? "" : s).replace(/[&<>"]/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]; }); };
  var S = null, logNext = 0, logEpoch = 0, fails = 0, promptShown = 0, lastRender = "";

  function post(path, body) { return fetch(path, { method: "POST", body: body == null ? "" : body }).catch(function () {}); }
  function cmd(o) { return post("/api/cmd", JSON.stringify(o)); }

  // ---------- render ----------
  function chipFor(st) {
    var m = { ok: ["ok", "OK"], atencion: ["atencion", "Con observaciones"], falla: ["falla", "Falla"], corriendo: ["corriendo", "Corriendo"],
              cancelada: ["cancelada", "Cortada"], "sin datos": ["sin", "Sin resultado"] };
    var x = m[st] || ["pend", "Pendiente"];
    return '<span class="chip ' + x[0] + '">' + x[1] + "</span>";
  }
  function renderSession() {
    var h = "";
    if (S.started) {
      h += '<span class="orden">Orden <b>' + esc(S.orden || "-") + "</b></span>";
      if (S.pieza) h += '<span class="orden">Placa S/N <b>…' + esc(S.pieza) + "</b></span>";
      else if (S.suelta) h += "<span>Placa suelta</span>";
      if (S.grupo) h += "<span>Va con <b>" + esc(S.grupo) + "</b></span>";
      h += "<span>Técnico <b>" + esc(S.tecnico || "-") + "</b></span>";
      h += '<button class="hbtn" id="bNuevo">Nuevo equipo <kbd>N</kbd></button>';
    }
    h += '<button class="hbtn" id="bTools">Herramientas <kbd>H</kbd></button><button class="hbtn" id="bHelp">Ayuda <kbd>?</kbd></button>';
    $("session").innerHTML = h;
    if ($("bNuevo")) $("bNuevo").onclick = nuevo;
    $("bTools").onclick = showTools; $("bHelp").onclick = showHelp;
    var e = S.equipo || {};
    if (S.started) {
      $("equipo").style.display = "flex";
      $("equipo").innerHTML = (S.cpu ? "<span>CPU <b>" + esc(S.cpu.nombre) + "</b> (" + S.cpu.nucleos + "/" + S.cpu.hilos + ")</span>" : "") +
        (e.mother ? "<span>Mother <b>" + esc(e.mother) + "</b></span>" : "") + (e.ram ? "<span>RAM <b>" + esc(e.ram) + "</b></span>" : "") +
        (e.gpu ? "<span>Video <b>" + esc(e.gpu) + "</b></span>" : "") + (e.discos ? "<span>Discos <b>" + esc(e.discos) + "</b></span>" : "");
    } else $("equipo").style.display = "none";
  }

  function renderStart() {
    if ($("startView").dataset.ready) return;
    $("startView").dataset.ready = "1";
    var tec = S.tecnicos || [];
    var tecField = tec.length <= 1
      ? '<input id="fTec" type="text" value="' + esc(tec[0] || "") + '" placeholder="Nombre">'
      : '<select id="fTec">' + tec.map(function (t) { return "<option>" + esc(t) + "</option>"; }).join("") + "</select>";
    var faltan = (S.tools || []).filter(function (t) { return !t.ok && t.auto; });
    $("startView").innerHTML = '<div class="card">' +
      "<h1>Nuevo equipo</h1><p>Cargá la orden y tocá Empezar. Después seguí los pasos en orden: cada uno explica qué hace y cuánto tarda.</p>" +
      (S.previa ? '<div class="banner fail">La sesión anterior se cortó durante: <b>' + esc(S.previa) + "</b>. Si la PC se colgó o reinició sola, eso es una falla de esa prueba.</div>" : "") +
      (faltan.length ? '<div class="banner warn">Faltan herramientas: ' + esc(faltan.map(function (t) { return t.nombre; }).join(", ")) + '. <button class="act" id="sDl">Descargar</button></div>' : "") +
      (S.prefijo
        ? '<div class="field"><label>Número de orden</label><div class="pref"><span id="fPre">' + esc(S.prefijo) + '</span><input id="fOrden" type="text" inputmode="numeric" autocomplete="off" placeholder="23100" autofocus></div>' +
          '<div class="hint">Solo los números: queda ' + esc(S.prefijo) + '23100. Si escribís letras o un número corto (ej. "PC mostrador", "4060"), se usa tal cual, sin el ' + esc(S.prefijo) + '</div></div>'
        : '<div class="field"><label>Orden o etiqueta del equipo</label><input id="fOrden" type="text" placeholder="Ej: NG-23100" autofocus></div>') +
      '<div class="field"><label class="chk"><input type="checkbox" id="fSuelta"' + (S.banco ? " checked" : "") + '> Es una placa de video suelta (esta PC es el banco de pruebas)</label>' +
      '<div id="fPiezaBox"' + (S.banco ? "" : ' style="display:none"') + '><input id="fPieza" type="text" maxlength="12" style="width:100%;margin-top:6px" autocomplete="off" placeholder="Final del N.º de serie de la placa (ej. 4826)">' +
      '<div class="hint">Opcional: sirve para saber cuál es cuál cuando hay varias placas iguales.</div>' +
      '<label style="margin-top:10px;display:block">¿Va junto con otra placa del mismo cliente?</label>' +
      '<input id="fGrupo" type="text" maxlength="24" autocomplete="off" style="width:100%;margin-top:6px" placeholder="Ticket de la primera placa (ej. 23421). Vacío si va sola o es la primera">' +
      (S.grupoSugerido ? '<button type="button" class="act" id="fGrupoSug" style="margin-top:6px">Mismo grupo que la anterior: <b>' + esc(S.grupoSugerido) + "</b></button>" : "") +
      '<div class="hint">Cuando un cliente trae varias placas y cada una tiene su ticket: en la primera no pongas nada; en las siguientes poné el ticket de la primera. Sale un informe de cada placa y uno solo con todas comparadas.</div></div></div>' +
      '<div class="field"><label>Técnico</label>' + tecField + "</div>" +
      '<div class="field"><label>Antes de empezar</label><ul class="check"><li>Drivers de chipset y de video instalados (si faltan, el paso D los busca e instala solo).</li>' +
      "<li>BIOS en valores por defecto (sin PBO, undervolt ni OC) y XMP/EXPO apagado para la primera pasada.</li>" +
      "<li>Un cooler que alcance y el monitor conectado a la placa de video.</li></ul></div>" +
      '<button class="big" id="sGo">Empezar <kbd>Enter</kbd></button></div>';
    $("sGo").onclick = start;
    if ($("sDl")) $("sDl").onclick = function () { cmd({ cmd: "tools", what: "download" }); };
    $("fSuelta").onchange = function () { $("fPiezaBox").style.display = $("fSuelta").checked ? "" : "none"; };
    if ($("fGrupoSug")) $("fGrupoSug").onclick = function () { $("fGrupo").value = S.grupoSugerido; $("fGrupo").focus(); };
    setTimeout(function () { if ($("fOrden")) $("fOrden").focus(); }, 50);
    if ($("fPre")) {
      var pf = S.prefijo.replace(/[^A-Za-z]/g, "");
      $("fOrden").oninput = function () {
        var v = $("fOrden").value.trim();
        // el prefijo se tacha cuando lo que se escribe no es un número (se va a usar tal cual)
        var minDig = S.prefijoMin || 5;
        var conPrefijo = !v || (/^\d+$/.test(v) && v.length >= minDig) || (pf && new RegExp("^" + pf + "[\\s\\-_#]*\\d+$", "i").test(v));
        $("fPre").className = conPrefijo ? "" : "sinpre";
      };
    }
  }
  function start() {
    var o = $("fOrden").value.trim(), t = $("fTec").value.trim();
    if (t && (S.tecnicos || []).indexOf(t) < 0) cmd({ cmd: "tecnico", nombre: t });
    var su = $("fSuelta").checked;
    cmd({ cmd: "start", orden: o, tecnico: t, suelta: su, pieza: su ? $("fPieza").value.trim() : "", grupo: su ? $("fGrupo").value.trim() : "" });
    $("sGo").disabled = true; $("sGo").textContent = "Preparando...";
  }

  function optControl(stepId, o) {
    var id = "o_" + stepId + "_" + o.k, v = opts[stepId][o.k];
    if (o.type === "check") return '<label><input type="checkbox" id="' + id + '"' + (v ? " checked" : "") + "> " + esc(o.label) + "</label>";
    return '<label>' + esc(o.label) + ' <select id="' + id + '">' + o.values.map(function (x) {
      return '<option value="' + x[0] + '"' + (String(x[0]) === String(v) ? " selected" : "") + ">" + esc(x[1]) + "</option>"; }).join("") + "</select></label>";
  }
  function stepDur(s) { return s.durFn ? s.durFn(opts[s.id], S) : s.dur; }

  function renderLeft() {
    var busy = S._busy;
    if (protoOpts.gpu === null && S.started) protoOpts.gpu = !!S.dedicada;
    if (protoOpts.fuente === null && S.started) protoOpts.fuente = !!S.dedicada;
    var h = '<h2>Protocolo recomendado</h2><div class="card proto">' +
      '<div style="color:var(--muted);font-size:13px">Corre en orden los pasos 1 a 4' + (protoOpts.gpu ? ", 5 (video)" : "") + (protoOpts.fuente ? ", F (fuente)" : "") + (protoOpts.escritura ? " y la escritura de disco" : "") +
      ' y al final arma el informe. Duración: ' + opts.allcore.min + " min de CPU + " + stepDur(STEPS.filter(function (x) { return x.id === "percore"; })[0]) + " por núcleo" + (protoOpts.gpu ? " + ~15 min de video" : "") + (protoOpts.fuente ? " + 10 min de fuente" : "") + ".</div>" +
      '<div class="row"><label><input type="checkbox" id="pGpu"' + (protoOpts.gpu ? " checked" : "") + '> Incluir video (VRAM + stress 10 min)</label>' +
      '<label><input type="checkbox" id="pFill"' + (protoOpts.escritura ? " checked" : "") + "> Incluir escritura + verificación de disco</label>" +
      '<label><input type="checkbox" id="pFuente"' + (protoOpts.fuente ? " checked" : "") + "> Incluir prueba de fuente (CPU + GPU, 10 min)</label></div>" +
      '<button class="big" id="bProto"' + (busy ? " disabled" : "") + ">Correr protocolo completo <kbd>P</kbd></button></div>" +
      '<h2 style="margin-top:6px">Pasos en orden</h2><div class="steps">';
    var n = 0;
    STEPS.forEach(function (s) {
      if (s.sep) { h += '<div class="sep">' + esc(s.sep) + "</div>"; return; }
      n++;
      var st = (S.steps && S.steps[s.id]) || null, est = st ? st.estado : "", cls = est === "corriendo" ? "running" : est;
      h += '<div class="card step ' + esc(cls) + '" id="step_' + s.id + '">' +
        '<div class="num">' + s.key + "</div>" +
        '<div><div class="st-title">' + esc(s.title) + ' <span class="st-dur">' + esc(stepDur(s)) + "</span> " + chipFor(est) + "</div></div>" +
        '<div class="st-side"><button class="run" data-step="' + s.id + '"' + (busy ? " disabled" : "") + ">Correr <kbd>" + s.key + "</kbd></button></div>" +
        '<div class="st-desc">' + esc(s.desc) + "</div>" +
        ((s.opts || []).length ? '<div class="st-opts">' + s.opts.map(function (o) { return optControl(s.id, o); }).join("") + "</div>" : "") +
        (st && st.resumen ? '<div class="st-res">' + esc(st.hora ? st.hora + " · " : "") + esc(st.resumen) + "</div>" : "") +
        "<details><summary>¿Qué hace?</summary><p>" + esc(s.more) + "</p></details></div>";
    });
    h += "</div>";
    var openDetails = {};
    Array.prototype.forEach.call(document.querySelectorAll("#left details"), function (d) { if (d.open) openDetails[d.parentNode.id] = 1; });
    var scrollTop = $("left").scrollTop;
    $("left").innerHTML = h;
    $("left").scrollTop = scrollTop;
    Object.keys(openDetails).forEach(function (id) { var el = document.querySelector("#" + id + " details"); if (el) el.open = true; });
    Array.prototype.forEach.call(document.querySelectorAll(".run[data-step]"), function (b) { b.onclick = function () { runStep(b.dataset.step); }; });
    STEPS.forEach(function (s) {
      (s.opts || []).forEach(function (o) {
        var el = $("o_" + s.id + "_" + o.k); if (!el) return;
        el.onchange = function () { opts[s.id][o.k] = o.type === "check" ? el.checked : (typeof o.def === "number" ? parseInt(el.value, 10) : el.value); lastRender = ""; render(); };
      });
    });
    $("pGpu").onchange = function () { protoOpts.gpu = $("pGpu").checked; lastRender = ""; render(); };
    $("pFill").onchange = function () { protoOpts.escritura = $("pFill").checked; lastRender = ""; render(); };
    $("pFuente").onchange = function () { protoOpts.fuente = $("pFuente").checked; lastRender = ""; render(); };
    $("bProto").onclick = runProto;
  }

  function renderNow() {
    var p = S._progress, h;
    if (S._busy) {
      var pct = p && p.p >= 0 ? p.p : -1;
      h = '<div class="now-top"><span class="chip corriendo">En curso</span><span class="now-title">' + esc(S._task || (p && p.a) || "Trabajando") + "</span>" +
          '<button class="cancel" id="bCancel"' + (S._cancel ? " disabled" : "") + ">" + (S._cancel ? "Cortando..." : "Cortar") + " <kbd>Esc</kbd></button></div>" +
          '<div class="bar' + (pct < 0 ? " indet" : "") + '"><i style="width:' + Math.max(0, pct) + '%"></i></div>' +
          '<div class="pstatus">' + esc(p ? (p.a && p.a !== S._task ? p.a + " · " : "") + (p.s || "") : "") + "</div>";
    } else {
      h = '<div class="now-top"><span class="now-title now-idle">' + (S.started ? "Listo. Elegí un paso o corré el protocolo completo." : "Esperando el equipo.") + "</span></div>";
    }
    $("now").innerHTML = h;
    if ($("bCancel")) $("bCancel").onclick = cancel;
  }

  function renderResults() {
    var areas = S.areas || [], h = '<div class="res-top"><h2 style="margin:0">Resultado</h2>';
    if (areas.length) {
      var r = S.resultado, txt = r === "FALLA" ? "No apto: hay fallas" : r === "ATENCION" ? "Apto con observaciones" : "Sin fallas detectadas";
      h += '<span class="verdict ' + esc(r === "OK" ? "ok" : r) + '">' + txt + "</span>";
    } else h += '<span style="color:var(--muted)">Todavía no hay pruebas.</span>';
    h += "</div>";
    if (areas.length) {
      h += '<div class="areas">' + areas.map(function (a) {
        var c = a.estado === "OK" || a.estado === "INFO" ? "OK" : a.estado;
        return '<div class="area"><b>' + esc(a.nombre) + '</b><span class="chip ' + esc(c) + '">' + (c === "OK" ? "OK" : c === "ATENCION" ? "Observaciones" : "Falla") + "</span><span></span>" +
          ((a.obs || []).length ? "<ul>" + a.obs.map(function (o) { var i = o.indexOf("|"); return '<li class="' + esc(o.slice(0, i)) + '">' + esc(o.slice(i + 1)) + "</li>"; }).join("") + "</ul>" : "") + "</div>";
      }).join("") + "</div>";
    }
    var dis = S._busy || !S.pruebas ? " disabled" : "";
    h += '<div class="actions"><button class="act" id="bInf"' + dis + ">Generar y abrir informe <kbd>I</kbd></button>" +
      '<button class="act" id="bOpenInf"' + (S.informe ? "" : " disabled") + ">Abrir informe</button>" +
      (S.informeOrden ? '<button class="act pri2" id="bOrden">Informe de la orden (todas las placas)</button>' : "") +
      '<button class="act" id="bTxt"' + (S.reporte ? "" : " disabled") + ">Reporte técnico</button>" +
      '<button class="act" id="bDir">Carpeta de reportes</button></div>';
    // ---- enviar el informe a otras PCs (NET-Receptor)
    var rec = S.receptores || [];
    h += '<div class="send"><div class="send-top"><b>Enviar informe</b><span class="hint2">a tu PC o a la pantalla del mostrador</span>' +
      '<button class="act" id="bBuscar"' + (S._busy ? " disabled" : "") + '>Buscar PCs</button></div>';
    if (!S.envioClave) h += '<div class="hint2">Falta la clave en envio.txt.</div>';
    else if (!rec.length) h += '<div class="hint2">No hay PCs con NET-Receptor a la vista. Instalalo en tu PC y en la del mostrador (carpeta NET-Receptor).</div>';
    else h += '<div class="recs">' + rec.map(function (r, i) {
      return '<div class="rec"><button class="act pri2" data-send="' + i + '"' + (S._busy || !S.pruebas ? " disabled" : "") + '>Enviar a ' + esc(r.nombre) + "</button>" +
        '<span class="hint2">' + (r.modo === "mostrar" ? "pantalla para el cliente" : "guarda y avisa") + " · " + esc(r.ip) + "</span>" +
        '<label class="hint2"><input type="checkbox" data-auto="' + i + '"' + (r.auto ? " checked" : "") + "> enviar siempre</label></div>";
    }).join("") + "</div>";
    if (S.envio) h += '<div class="hint2 ' + (/^Enviado/.test(S.envio) ? "okt" : "badt") + '">' + esc(S.envio) + "</div>";
    h += "</div>";
    $("results").innerHTML = h;
    $("bBuscar").onclick = function () { cmd({ cmd: "buscar" }); };
    Array.prototype.forEach.call(document.querySelectorAll("[data-send]"), function (b) {
      b.onclick = function () { var r = rec[+b.dataset.send]; if (r) cmd({ cmd: "enviar", nombre: r.nombre }); };
    });
    Array.prototype.forEach.call(document.querySelectorAll("[data-auto]"), function (b) {
      b.onchange = function () { var r = rec[+b.dataset.auto]; if (r) cmd({ cmd: "auto", nombre: r.nombre, on: b.checked }); };
    });
    $("bInf").onclick = informe; $("bOpenInf").onclick = function () { cmd({ cmd: "abrir", what: "informe" }); };
    $("bTxt").onclick = function () { cmd({ cmd: "abrir", what: "txt" }); };
    if ($("bOrden")) $("bOrden").onclick = function () { cmd({ cmd: "abrir", what: "orden" }); };
    $("bDir").onclick = function () { cmd({ cmd: "abrir", what: "carpeta" }); };
  }

  function appendLog(lines) {
    if (!lines.length) return;
    var box = $("log"), atBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 40, frag = document.createDocumentFragment(), prevBar = false;
    lines.forEach(function (l) {
      var t = l.t || "";
      if (/^=+$/.test(t.trim())) { prevBar = true; return; }
      var d = document.createElement("div");
      d.className = (prevBar && l.c === "Cyan" ? "h " : "") + "c-" + (l.c || "Gray");
      d.textContent = t || " ";
      frag.appendChild(d);
      prevBar = false;
    });
    box.appendChild(frag);
    while (box.childNodes.length > 4000) box.removeChild(box.firstChild);
    if (atBottom) box.scrollTop = box.scrollHeight;
  }

  function render() {
    renderSession();
    if (!S.started) {
      $("mainView").style.display = "none"; $("startView").style.display = "grid"; renderStart();
    } else {
      $("startView").style.display = "none"; $("startView").dataset.ready = ""; $("mainView").style.display = "grid";
      var key = JSON.stringify([S.steps, S._busy, S.areas, S.informe, S.pruebas, S.reporte, S.dedicada, S.cpu, S.receptores, S.envio, S.envioClave, S.informeOrden]);
      if (key !== lastRender) { lastRender = key; renderLeft(); renderResults(); }
      renderNow();
    }
    if ($("toolsModal").classList.contains("show")) showTools();
  }

  // ---------- preguntas ----------
  function renderPrompt(pr) {
    if (!pr) { if (promptShown) { $("promptModal").classList.remove("show"); promptShown = 0; } return; }
    if (promptShown === pr.id) return;
    promptShown = pr.id;
    var h = "<h3>" + esc(pr.q) + "</h3>", k = pr.kind;
    if (k === "yesno") {
      var defYes = /^[sy]/i.test(pr.def || "");
      h += '<div class="btns"><button class="btn' + (defYes ? "" : " pri") + '" data-v="N">No <kbd>N</kbd></button><button class="btn' + (defYes ? " pri" : "") + '" data-v="S">Sí <kbd>S</kbd></button></div>' +
           '<div class="hint">Enter = ' + (defYes ? "Sí" : "No") + "</div>";
    } else if (k === "choice") {
      h += '<div class="opts">' + (pr.extra || []).map(function (o, i) {
        return '<button class="opt' + (String(o.v) === String(pr.def) ? " def" : "") + '" data-v="' + esc(o.v) + '"><kbd>' + (i < 9 ? i + 1 : "") + "</kbd><b>" + esc(o.l) + "</b>" + (o.d ? "<small>" + esc(o.d) + "</small>" : "") + "</button>";
      }).join("") + '</div><div class="hint">Número o clic para elegir · Enter = la opción marcada</div>';
    } else {
      var isInt = k === "int", ex = pr.extra || {};
      h += '<input id="pIn" type="' + (isInt ? "number" : "text") + '" value="' + esc(pr.def) + '"' + (isInt ? ' min="' + ex.min + '" max="' + ex.max + '"' : "") + ' style="font-size:16px;padding:9px 11px">' +
           (isInt ? '<div class="hint">Entre ' + ex.min + " y " + ex.max + "</div>" : "") +
           '<div class="btns"><button class="btn pri" data-v="__in">Aceptar <kbd>Enter</kbd></button></div>';
    }
    $("promptDlg").innerHTML = h;
    $("promptModal").classList.add("show");
    Array.prototype.forEach.call($("promptDlg").querySelectorAll("[data-v]"), function (b) {
      b.onclick = function () { answer(b.dataset.v === "__in" ? $("pIn").value : b.dataset.v); };
    });
    if ($("pIn")) { $("pIn").focus(); $("pIn").select(); }
  }
  function answer(v) {
    if (!S || !S._prompt) return;
    post("/api/answer?id=" + S._prompt.id, String(v));
    $("promptModal").classList.remove("show");
  }

  // ---------- acciones ----------
  function runStep(id) { if (!S || S._busy || !S.started) return; cmd({ cmd: "step", id: id, opts: opts[id] }); S._busy = true; render(); }
  function runProto() {
    if (!S || S._busy || !S.started) return;
    cmd({ cmd: "protocolo", opts: { min: opts.allcore.min, seg: opts.percore.seg, gpu: !!protoOpts.gpu, fuente: !!protoOpts.fuente, escritura: !!protoOpts.escritura } });
    S._busy = true; render();
  }
  function informe() { if (S && !S._busy && S.pruebas) cmd({ cmd: "informe" }); }
  function cancel() { post("/api/cancel"); }
  function nuevo() {
    if (!S || S._busy) return;
    if (confirm("¿Terminar este equipo y empezar uno nuevo? El informe de este equipo se guarda solo.")) { cmd({ cmd: "nuevo" }); protoOpts.gpu = null; protoOpts.fuente = null; $("log").innerHTML = ""; }
  }
  function showTools() {
    var t = S ? S.tools || [] : [];
    var h = "<h3>Herramientas</h3><p class=\"hint\" style=\"margin:0\">Se guardan en la carpeta tools: si las bajás una vez, el pendrive ya las lleva.</p><div class=\"tools\">" +
      t.map(function (x) {
        return '<div class="tool"><b>' + esc(x.nombre) + '</b><span class="chip ' + (x.ok ? "ok" : "atencion") + '">' + (x.ok ? "OK" : "Falta") + "</span>" +
          '<button class="act" data-open="' + esc(x.id) + '"' + (x.ok && x.id !== "smartctl" ? "" : " disabled") + ">Abrir</button><small>" + esc(x.uso) + "</small></div>";
      }).join("") + '</div><div class="btns"><button class="btn" id="tUpd"' + (S && S._busy ? " disabled" : "") + '>Actualizar todas</button>' +
      '<button class="btn pri" id="tDl"' + (S && S._busy ? " disabled" : "") + ">Descargar las que faltan</button>" +
      '<button class="btn" id="tClose">Cerrar <kbd>Esc</kbd></button></div>';
    $("toolsDlg").innerHTML = h;
    $("toolsModal").classList.add("show");
    Array.prototype.forEach.call($("toolsDlg").querySelectorAll("[data-open]"), function (b) { b.onclick = function () { cmd({ cmd: "toolopen", id: b.dataset.open }); }; });
    $("tDl").onclick = function () { cmd({ cmd: "tools", what: "download" }); };
    $("tUpd").onclick = function () { cmd({ cmd: "tools", what: "update" }); };
    $("tClose").onclick = function () { $("toolsModal").classList.remove("show"); };
  }
  function showHelp() {
    $("helpDlg").innerHTML = "<h3>Atajos de teclado</h3><div class=\"keys\">" +
      "<span><kbd>1</kbd> – <kbd>9</kbd></span><span>Correr ese paso</span>" +
      "<kbd>D</kbd><span>Drivers: buscar e instalar</span><kbd>F</kbd><span>Prueba de fuente (CPU + GPU juntos)</span>" +
      "<kbd>P</kbd><span>Correr el protocolo completo</span><kbd>Esc</kbd><span>Cortar la prueba en curso / cerrar ventanas</span>" +
      "<kbd>I</kbd><span>Generar y abrir el informe para el cliente</span><kbd>N</kbd><span>Terminar este equipo y empezar otro</span>" +
      "<kbd>H</kbd><span>Herramientas</span><kbd>?</kbd><span>Esta ayuda</span></div>" +
      "<h3>Orden recomendado</h3><ol style=\"margin:0;padding-left:20px;color:#d1d5db\"><li>Chequeo general: si marca drivers faltantes, instalalos antes de seguir.</li>" +
      "<li>Discos: SMART + autotest.</li><li>CPU todos los núcleos (calor y estabilidad).</li><li>CPU núcleo por núcleo (boost máximo).</li>" +
      "<li>Video, si tiene placa dedicada.</li><li>Fuente: CPU + GPU juntos, después de que cada uno pasó por separado.</li><li>RAM con TestMem5 (con XMP/EXPO activado).</li><li>Informe para el cliente.</li></ol>" +
      '<p class="hint" style="margin:0">Si la PC se cuelga o reinicia en medio de una prueba, eso cuenta como falla: al volver a abrir el programa te dice en qué prueba (y en qué núcleo) pasó.</p>' +
      '<div class="btns"><button class="btn" id="hClose">Cerrar <kbd>Esc</kbd></button></div>';
    $("helpModal").classList.add("show");
    $("hClose").onclick = function () { $("helpModal").classList.remove("show"); };
  }

  // ---------- teclado ----------
  document.addEventListener("keydown", function (e) {
    var tag = (e.target && e.target.tagName) || "";
    var typing = tag === "INPUT" || tag === "SELECT" || tag === "TEXTAREA";
    if ($("promptModal").classList.contains("show") && S && S._prompt) {
      var pr = S._prompt;
      if (e.key === "Enter") { e.preventDefault(); answer(pr.kind === "int" || pr.kind === "text" ? $("pIn").value : pr.def); return; }
      if (pr.kind === "yesno" && /^[sSnNyY]$/.test(e.key)) { answer(/[sSyY]/.test(e.key) ? "S" : "N"); return; }
      if (pr.kind === "choice" && /^[1-9]$/.test(e.key)) { var o = (pr.extra || [])[parseInt(e.key, 10) - 1]; if (o) answer(o.v); return; }
      if (e.key === "Escape") { answer(pr.def); }
      return;
    }
    if (e.key === "Escape") {
      if ($("toolsModal").classList.contains("show")) { $("toolsModal").classList.remove("show"); return; }
      if ($("helpModal").classList.contains("show")) { $("helpModal").classList.remove("show"); return; }
      if (S && S._busy) cancel();
      return;
    }
    if (!S) return;
    if (!S.started) { if (e.key === "Enter" && $("sGo")) { e.preventDefault(); start(); } return; }
    if (typing) return;
    var k = e.key.toLowerCase();
    if (/^[1-9df]$/.test(k)) { var st = STEPS.filter(function (s) { return s.key && s.key.toLowerCase() === k; })[0]; if (st) runStep(st.id); }
    else if (k === "p") runProto();
    else if (k === "i") informe();
    else if (k === "n") nuevo();
    else if (k === "h") showTools();
    else if (k === "?" || k === "¿") showHelp();
  });

  // ---------- sondeo ----------
  function poll() {
    fetch("/api/state?since=" + logNext + "&epoch=" + logEpoch, { cache: "no-store" }).then(function (r) { return r.json(); }).then(function (d) {
      fails = 0; $("off").classList.remove("show");
      if (d.epoch !== logEpoch) { $("log").innerHTML = ""; logEpoch = d.epoch; }
      logNext = d.next;
      var snap = d.snap || {};
      snap._busy = d.busy; snap._task = d.task; snap._progress = d.progress; snap._prompt = d.prompt; snap._cancel = d.cancel;
      S = snap;
      appendLog(d.log || []);
      render();
      renderPrompt(d.prompt);
    }).catch(function () { if (++fails > 4) $("off").classList.add("show"); })
      .then(function () { setTimeout(poll, 500); });
  }
  poll();
})();
</script>
</body>
</html>
'@

$Global:UiTools = @()
$Global:UiRunning = $null
$Global:UiCancelled = $false
$Global:UiExit = $false

$StepNames = [ordered]@{
    chequeo   = 'Chequeo general'
    drivers   = 'Drivers: buscar e instalar'
    smart     = 'Discos: SMART + autotest'
    allcore   = 'CPU: todos los núcleos'
    percore   = 'CPU: núcleo por núcleo'
    gpu       = 'Video: identidad + VRAM + stress'
    fuente    = 'Fuente: CPU + GPU al 100%'
    ram       = 'RAM: TestMem5'
    lectura   = 'Disco: lectura de superficie'
    escritura = 'Disco: escritura + verificación'
    externo   = 'Otra prueba externa'
}
$AreaNames = [ordered]@{ 'CPU' = 'Procesador'; 'RAM' = 'Memoria RAM'; 'Discos' = 'Almacenamiento'; 'Motherboard' = 'Motherboard'; 'GPU' = 'Video'; 'Fuente' = 'Fuente de alimentación'; 'Plataforma' = 'Sistema y drivers' }

function Update-UiTools {
    $Global:UiTools = @(Get-ToolStatus | ForEach-Object { [ordered]@{ id = $_.Id; nombre = $_.Nombre; uso = $_.Uso; ok = [bool]$_.Path; auto = [bool]$_.Auto } })
}

function Get-UiSnapshot {
    $areas = @()
    foreach ($k in $AreaNames.Keys) {
        if (-not $Global:Verdicts.Contains($k)) { continue }
        $v = $Global:Verdicts[$k]
        $areas += [ordered]@{
            area   = $k
            nombre = $AreaNames[$k]
            estado = $v.Estado
            obs    = @($v.Detalles | Where-Object { $_ -match '^\[(ATENCION|FALLA)\]' } | ForEach-Object { $_ -replace '^\[(\w+)\]\s*', '$1|' })
            ok     = @($v.Detalles | Where-Object { $_ -match '^\[(OK|INFO)\]' } | ForEach-Object { $_ -replace '^\[\w+\]\s*', '' })
        }
    }
    $e = $Global:M.Equipo
    $hayDedicada = $false
    if ($e.GPU) { $hayDedicada = [bool](@($e.GPU | Where-Object { $_ -match $DedicadaRegex }).Count) }
    return [ordered]@{
        version    = $Version
        started    = [bool]$Global:Started
        orden      = $Global:M.Orden
        tecnico    = $Global:M.Tecnico
        tecnicos   = @(Get-Tecnicos)
        previa     = $Global:SesionCortada
        prefijo    = (Get-PrefijoOrden)
        prefijoMin = (Get-OrdenMinDigitos)
        pieza      = $Global:M.Pieza
        grupo      = $Global:M.Grupo
        grupoSugerido = $(if ($Global:Started) { '' } else { Get-UltimoGrupo })
        suelta     = [bool]$Global:M.Suelta
        banco      = (Get-EsBanco)
        informeOrden = [bool]($Global:InformeOrdenPdf -and (Test-Path $Global:InformeOrdenPdf))
        cpu        = $(if ($Global:Cpu) { [ordered]@{ nombre = $Global:Cpu.Nombre; nucleos = $Global:Cpu.Nucleos; hilos = $Global:Cpu.Hilos } } else { $null })
        equipo     = [ordered]@{ mother = $e.Mother; bios = $e.BIOS; ram = $e.RamTexto; gpu = (@($e.GPU) -join ' + '); discos = (@($Global:M.Discos | ForEach-Object { '{0} ({1})' -f $_.Modelo, $_.Capacidad }) -join ' + ') }
        dedicada   = $hayDedicada
        steps      = $Global:StepState
        running    = $Global:UiRunning
        areas      = $areas
        resultado  = (Get-WorstState @($Global:Verdicts.Values | ForEach-Object { $_.Estado }))
        pruebas    = $Global:M.Pruebas.Count
        informe    = [bool]($Global:InformeHtml -and (Test-Path $Global:InformeHtml))
        reporte    = $(if ($Global:ReportFile) { Split-Path -Leaf $Global:ReportFile } else { '' })
        tools      = $Global:UiTools
        pendientes = @($Global:Pendientes)
        receptores = @($Global:Receptores | ForEach-Object { [ordered]@{ nombre = $_.Nombre; ip = $_.Ip; modo = $_.Modo; auto = [bool]((Get-EnvioConfig).Auto -contains $_.Nombre) } })
        envio      = $Global:EnvioEstado
        envioClave = [bool](Get-EnvioConfig).Clave
    }
}

# Prefijo de las órdenes (config.txt: prefijo_orden=NG-). Si se cargan solo números, se le agrega;
# "ng 23100" o "ng23100" quedan como NG-23100; cualquier otra etiqueta (ej. "PC mostrador") queda como está.
function Get-PrefijoOrden {
    $p = (Get-ConfigBanco)['prefijo_orden']
    if ($null -eq $p) { return 'NG-' }
    return [string]$p
}

function Get-OrdenMinDigitos {
    $n = 0
    if ([int]::TryParse([string](Get-ConfigBanco)['orden_min_digitos'], [ref]$n) -and $n -ge 1) { return $n }
    return 5
}

# Banco de pruebas de placas: se recuerda por PC (nombre de Windows) para que la opción "placa suelta" ya venga marcada
function Get-EsBanco {
    try { return [bool](@(Get-Content -Path (Join-Path $ReportDir '.bancos') -ErrorAction Stop | Where-Object { $_.Trim() -eq $env:COMPUTERNAME }).Count) } catch { return $false }
}

function Set-EsBanco([bool]$Si) {
    try {
        $f = Join-Path $ReportDir '.bancos'
        New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
        $l = @(Get-Content -Path $f -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne $env:COMPUTERNAME })
        if ($Si) { $l += $env:COMPUTERNAME }
        [IO.File]::WriteAllLines($f, [string[]]$l)
    } catch {}
}

# Grupo: cuando cada placa de un cliente entra con su propio ticket, en la segunda (y las siguientes) se carga
# "va junto con el ticket <el de la primera>". Ese ticket es el nombre del grupo y del informe que las junta.
function Format-Grupo([string]$Grupo, [string]$Orden) {
    $g = Format-Orden $Grupo
    if ($g -and $g -eq $Orden) { return '' }
    return $g
}

# El último grupo usado en esta PC (hasta 6 horas): la interfaz lo ofrece para la placa siguiente
function Get-UltimoGrupo {
    try {
        $p = @(([string](Get-Content -Path (Join-Path $ReportDir '.ultimo_grupo') -Raw -ErrorAction Stop)).Trim() -split '\|')
        if ($p.Count -ge 3 -and $p[0] -eq [string]$env:COMPUTERNAME -and $p[1] -and ((Get-Date) - (New-Object datetime ([long]$p[2]))).TotalHours -lt 6) { return [string]$p[1] }
    } catch {}
    return ''
}

function Set-UltimoGrupo([string]$Grupo) {
    if (-not $Grupo) { return }
    try {
        New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
        [IO.File]::WriteAllText((Join-Path $ReportDir '.ultimo_grupo'), ('{0}|{1}|{2}' -f $env:COMPUTERNAME, $Grupo, (Get-Date).Ticks))
    } catch {}
}

function Get-GrupoSesion {
    if ($Global:M.Grupo) { return [string]$Global:M.Grupo }
    return [string]$Global:M.Orden
}

function Format-Pieza([string]$Pieza) {
    $p = (([string]$Pieza) -replace '[^A-Za-z0-9\-]', '').ToUpper()
    if ($p.Length -gt 12) { $p = $p.Substring($p.Length - 12) }
    return $p
}

# En una placa suelta el resultado es el de la placa: lo que diga el chequeo sobre el banco no cuenta
function Get-AreasInforme {
    if ($Global:M.Suelta) { return @($Global:Verdicts.Keys | Where-Object { $_ -eq 'GPU' }) }
    return @($Global:Verdicts.Keys)
}

function Get-ResultadoSesion {
    return (Get-WorstState @(Get-AreasInforme | ForEach-Object { $Global:Verdicts[$_].Estado }))
}

function Format-Orden([string]$Orden) {
    $o = ([string]$Orden).Trim()
    $pre = Get-PrefijoOrden
    if (-not $o -or -not $pre) { return $o }
    $letras = ($pre -replace '[^A-Za-z]', '')
    # solo números: es una orden si tiene los dígitos de una orden (5 o más); "4060" o "3090" son etiquetas de un modelo
    if ($o -match '^\d+$') { if ($o.Length -ge (Get-OrdenMinDigitos)) { return $pre + $o } else { return $o } }
    if ($letras -and $o -match ('^(?i)' + [regex]::Escape($letras) + '[\s\-_#]*(\d+)$')) { return $pre + $Matches[1] }
    return $o
}

function Start-Equipo([string]$Orden, [string]$Tecnico, [string]$Pieza = '', [bool]$Suelta = $false, [string]$Grupo = '') {
    if ($Global:Started) { return }
    $Global:Ui.Busy = $true
    $Global:Ui.Task = 'Preparando el equipo'
    $Global:M.Orden = Format-Orden $Orden
    $Global:M.Pieza = Format-Pieza $Pieza
    $Global:M.Grupo = Format-Grupo $Grupo $Global:M.Orden
    $Global:M.Suelta = [bool]($Suelta -or $Global:M.Pieza -or $Global:M.Grupo)
    Set-EsBanco $Global:M.Suelta
    if ($Global:M.Suelta) { Set-UltimoGrupo (Get-GrupoSesion) }
    $Global:M.Tecnico = $Tecnico.Trim()
    try {
        if ($Global:M.Tecnico) { New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null; $Global:M.Tecnico | Set-Content -Path (Join-Path $ReportDir '.ultimo_tecnico') -Encoding UTF8 }
        Start-Report $Global:M.Orden
        if ($Global:M.Tecnico) { Log ("Técnico: {0}" -f $Global:M.Tecnico) }
        Show-Inventario
        $Global:Started = $true
    } catch { Log ("Error preparando el equipo: {0}" -f $_.Exception.Message) 'Red' }
    finally { $Global:Ui.Busy = $false; $Global:Ui.Task = ''; Ui-Publish }
}

function Get-StepEstado($Nuevas, [string]$Id) {
    if ($Id -eq 'chequeo') {
        $w = Get-WorstState @($Global:Verdicts.Values | ForEach-Object { $_.Estado })
        return $(switch ($w) { 'FALLA' { 'falla' } 'ATENCION' { 'atencion' } default { 'ok' } })
    }
    $r = @($Nuevas | ForEach-Object { [string]$_.Resultado })
    if (-not $r.Count) { return 'sin datos' }
    if ($r -match 'FALLA') { return 'falla' }
    if ($r -match 'observ|ATENCI') { return 'atencion' }
    if ($r -match 'Cancel') { return 'cancelada' }
    return 'ok'
}

function Invoke-Step([string]$Id, $Opts) {
    if (-not $Global:Started) { return }
    $before = $Global:M.Pruebas.Count
    $Global:UiRunning = $Id
    $Global:StepState[$Id] = [ordered]@{ estado = 'corriendo'; resumen = ''; hora = (Get-Date -Format 'HH:mm') }
    $Global:Ui.Cancel = $false
    $Global:Ui.Busy = $true
    $Global:Ui.Task = $StepNames[$Id]
    Ui-Publish
    try {
        switch ($Id) {
            'chequeo' { Invoke-Chequeo }
            'drivers' { Invoke-Drivers }
            'smart' { Show-Smart -SelfTest }
            'allcore' { Invoke-CpuAllCore ([int]$Opts.min) }
            'percore' { Invoke-CpuPerCore ([int]$Opts.seg) }
            'gpu' {
                Test-GpuIdentity
                if ($Opts.vram) { Invoke-VramTest }
                if ([int]$Opts.min -gt 0 -and -not $Global:Ui.Cancel) { Invoke-GpuStress ([int]$Opts.min) }
                Add-Pendiente 'Video: mirar que no haya artefactos en pantalla, probar todas las salidas (HDMI/DP) y que los ventiladores giren sin ruido.'
            }
            'fuente' { Invoke-PruebaFuente ([int]$Opts.min) }
            'ram' { Invoke-TestMem5 ([int]$Opts.min) ([string]$Opts.cfg) }
            'externo' { Watch-Externo }
            'lectura' { Invoke-DiskRead }
            'escritura' { Invoke-DiskFill }
        }
    } catch {
        Log ("Error en '{0}': {1}" -f $StepNames[$Id], $_.Exception.Message) 'Red'
    } finally {
        $nuevas = @($Global:M.Pruebas | Select-Object -Skip $before)
        $Global:UiCancelled = [bool]$Global:Ui.Cancel
        $res = (@($nuevas | ForEach-Object { '{0}: {1}' -f $_.Nombre, $_.Resultado }) -join ' · ')
        $Global:StepState[$Id] = [ordered]@{ estado = (Get-StepEstado $nuevas $Id); resumen = $res; hora = (Get-Date -Format 'HH:mm') }
        $Global:Ui.Busy = $false
        $Global:Ui.Task = ''
        $Global:Ui.ClearProgress()
        $Global:Ui.Cancel = $false
        $Global:UiRunning = $null
        $Global:InformeHtml = $null       # el informe anterior quedó viejo
        Ui-Publish
    }
}

function Invoke-UiProtocolo($Opts) {
    $t0 = Get-Date
    $Global:UiCancelled = $false
    Section 'PROTOCOLO COMPLETO'
    $plan = @(
        @('chequeo', $null), @('smart', $null),
        @('allcore', @{ min = [int]$Opts.min }), @('percore', @{ seg = [int]$Opts.seg })
    )
    if ($Opts.gpu) { $plan += , @('gpu', @{ vram = $true; min = 10 }) }
    if ($Opts.fuente) { $plan += , @('fuente', @{ min = 10 }) }
    if ($Opts.escritura) { $plan += , @('escritura', $null) }
    foreach ($p in $plan) {
        if ($Global:UiCancelled) { Log 'Protocolo cortado por el técnico.' 'Yellow'; break }
        Invoke-Step $p[0] $p[1]
    }
    Show-Eventos $t0 'EVENTOS DE HARDWARE DURANTE EL PROTOCOLO'
    Add-Pendiente 'CPU: complementar con Prime95 Small FFT 30-60 min o CoreCycler (paso "Otra prueba externa").'
    Invoke-UiInforme
}

function Invoke-UiInforme {
    $Global:Ui.Busy = $true; $Global:Ui.Task = 'Generando el informe'
    try { Show-Resumen } catch { Log ("Error generando el informe: {0}" -f $_.Exception.Message) 'Red' }
    try { if ((Get-EnvioConfig).Auto.Count) { $Global:Ui.Task = 'Enviando el informe'; Ui-Publish; Invoke-EnvioAuto } } catch {}
    finally { $Global:Ui.Busy = $false; $Global:Ui.Task = ''; Ui-Publish }
}

function Complete-Equipo {
    if ($Global:Started -and $Global:M.Pruebas.Count -gt 0 -and -not $Global:InformeHtml) {
        try { Show-Resumen } catch {}
    }
}

function Invoke-UiCommand([string]$Json) {
    $c = $null
    try { $c = $Json | ConvertFrom-Json } catch { return }
    switch ([string]$c.cmd) {
        'start' { Start-Equipo ([string]$c.orden) ([string]$c.tecnico) ([string]$c.pieza) ([bool]$c.suelta) ([string]$c.grupo) }
        'step' { if (-not $Global:Ui.Busy) { Invoke-Step ([string]$c.id) $c.opts } }
        'protocolo' { if ($Global:Started) { Invoke-UiProtocolo $c.opts } }
        'informe' { if ($Global:Started) { Invoke-UiInforme; if ($Global:InformeHtml) { Start-Process (Get-InformeParaAbrir) } } }
        'abrir' {
            switch ([string]$c.what) {
                'informe' { if ($Global:InformeHtml -and (Test-Path $Global:InformeHtml)) { Start-Process (Get-InformeParaAbrir) } }
                'txt' { if ($Global:ReportFile) { Start-Process notepad.exe $Global:ReportFile } }
                'orden' { if ($Global:InformeOrdenPdf -and (Test-Path $Global:InformeOrdenPdf)) { Start-Process $Global:InformeOrdenPdf } }
                'carpeta' { New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null; Start-Process explorer.exe $ReportDir }
                'historial' { if (Test-Path $HistFile) { Start-Process $HistFile } }
                'tecnicos' { Start-Process notepad.exe $TecnicosFile }
            }
        }
        'tools' {
            $Global:Ui.Busy = $true; $Global:Ui.Task = 'Herramientas'
            try {
                if ($c.what -eq 'update') {
                    foreach ($sub in 'Prime95', 'CoreCycler', 'LibreHardwareMonitor', 'memtest_vulkan') { Remove-Item -Path (Join-Path $ToolsDir $sub) -Recurse -Force -ErrorAction SilentlyContinue }
                    Remove-Item -Path (Join-Path $ToolsDir 'smartctl.exe') -Force -ErrorAction SilentlyContinue
                    Install-Tools @(Get-ToolStatus | Where-Object { $_.Auto })
                } elseif ($c.what -eq 'download') {
                    Install-Tools @(Get-ToolStatus | Where-Object { -not $_.Path -and $_.Auto })
                }
            } finally { Update-UiTools; $Global:Ui.Busy = $false; $Global:Ui.Task = ''; Ui-Publish }
        }
        'toolopen' { [void](Start-Tool ([string]$c.id)) }
        'buscar' {
            $Global:Ui.Busy = $true; $Global:Ui.Task = 'Buscando PCs con NET-Receptor'; Ui-Publish
            try {
                $r = @(Find-Receptores)
                if ($r.Count) { Log ("PCs encontradas: {0}" -f (($r | ForEach-Object { '{0} ({1})' -f $_.Nombre, $_.Ip }) -join ', ')) 'DarkGray' }
                else { Log 'No se encontró ninguna PC con NET-Receptor. Revisá que esté instalado y abierto, y que la clave sea la misma que en envio.txt.' 'Yellow' }
            } finally { $Global:Ui.Busy = $false; $Global:Ui.Task = '' }
        }
        'enviar' {
            $rec = $Global:Receptores | Where-Object { $_.Nombre -eq [string]$c.nombre } | Select-Object -First 1
            if ($rec -and $Global:Started) {
                $Global:Ui.Busy = $true; $Global:Ui.Task = ("Enviando el informe a {0}" -f $rec.Nombre); Ui-Publish
                try { [void](Send-Informe $rec) } finally { $Global:Ui.Busy = $false; $Global:Ui.Task = '' }
            }
        }
        'auto' { Set-EnvioAuto ([string]$c.nombre) ([bool]$c.on) }
        'tecnico' {
            $n = ([string]$c.nombre).Trim()
            if ($n -and @(Get-Tecnicos) -notcontains $n) { Add-Content -Path $TecnicosFile -Value $n -Encoding UTF8 }
        }
        'nuevo' {
            Complete-Equipo
            New-Session
            $Global:Ui.ClearLog()
            Log 'Listo para un equipo nuevo.' 'DarkGray'
        }
        'salir' { Complete-Equipo; $Global:UiExit = $true }
    }
    Ui-Publish
}

function Start-UiMode {
    $Global:UiMode = $true
    $srv = $null
    foreach ($try in 1..8) {
        $port = Get-Random -Minimum 46000 -Maximum 46999
        try { $srv = New-Object NetBench.UiServer -ArgumentList $port; break } catch { $srv = $null }
    }
    if (-not $srv) { $Global:UiMode = $false; Microsoft.PowerShell.Utility\Write-Host 'No se pudo abrir la interfaz: se usa el menú de consola.' -ForegroundColor Yellow; Main; return }
    $Global:Ui = $srv
    $logo = Get-LogoDataUri
    $Global:Ui.Page = $UiHtml.Replace('__LOGO__', $(if ($logo) { $logo } else { '' })).Replace('__VERSION__', $Version)
    $url = "http://127.0.0.1:$($srv.Port)/"
    Test-PreviousSession
    $Global:Cpu = Get-CpuInfo
    Update-UiTools
    try { [void](Find-Receptores 1200) } catch {}
    Log ("NET-TestBench v{0} listo. Cargá la orden y tocá Empezar." -f $Version) 'DarkGray'
    Ui-Publish

    $browser = Find-Browser
    $bp = $null
    if ($browser) {
        $prof = Join-Path $env:TEMP 'netbench-ui'
        $bargs = @("--app=$url", "--user-data-dir=`"$prof`"", '--no-first-run', '--no-default-browser-check', '--start-maximized',
            '--disable-background-timer-throttling', '--disable-renderer-backgrounding')
        try { $bp = Start-Process -FilePath $browser -ArgumentList $bargs -PassThru } catch {}
    }
    if (-not $bp) { try { Start-Process $url } catch {} }
    Microsoft.PowerShell.Utility\Write-Host ''
    Microsoft.PowerShell.Utility\Write-Host ("  Interfaz abierta en {0}" -f $url) -ForegroundColor Cyan
    Microsoft.PowerShell.Utility\Write-Host '  No cierres esta ventana: es el motor de las pruebas. Se cierra sola al cerrar la interfaz.' -ForegroundColor DarkGray
    Start-Sleep -Seconds 2
    [NetBench.Native]::MinimizeConsole()

    $t0 = Get-Date
    try {
        while (-not $Global:UiExit) {
            $c = $Global:Ui.NextCommand(250)
            if ($c) {
                try { Invoke-UiCommand $c }
                catch {
                    Log ("Error: {0}" -f $_.Exception.Message) 'Red'
                    $Global:Ui.Busy = $false; $Global:Ui.Task = ''; $Global:Ui.ClearProgress(); $Global:UiRunning = $null
                    Ui-Publish
                }
                continue
            }
            if ($Global:Ui.PageLoaded -and $Global:Ui.SecondsSincePoll -gt 25) {
                Microsoft.PowerShell.Utility\Write-Host '  La interfaz se cerró. Guardando y saliendo...' -ForegroundColor DarkGray
                Complete-Equipo
                break
            }
            if (-not $Global:Ui.PageLoaded -and ((Get-Date) - $t0).TotalSeconds -gt 120) {
                Microsoft.PowerShell.Utility\Write-Host ("  La interfaz no abrió. Abrí {0} en el navegador o cerrá esto y usá Iniciar-Consola.bat" -f $url) -ForegroundColor Yellow
                $t0 = Get-Date
            }
            if (((Get-Date) - $Global:UiLastPub).TotalSeconds -gt 3) { Ui-Publish }
        }
    } finally {
        Start-Sleep -Milliseconds 800
        $Global:Ui.Stop()
        if ($bp) { try { Start-Process -FilePath 'taskkill.exe' -ArgumentList '/T', '/F', '/PID', $bp.Id -WindowStyle Hidden } catch {} }
    }
}

# ======================================================================
#  Envío del informe a otras PCs del local (NET-Receptor)
# ======================================================================
$EnvioFile = Join-Path $Root 'envio.txt'
$ReceptorPort = 47950
$ReceptorUdp = 47951
$Global:Receptores = @()
$Global:EnvioEstado = ''

function Get-EnvioConfig {
    $c = [ordered]@{ Clave = ''; Auto = @(); Fijas = @() }
    if (-not (Test-Path $EnvioFile)) { return $c }
    foreach ($l in (Get-Content -Path $EnvioFile -Encoding UTF8)) {
        $t = $l.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        $i = $t.IndexOf('=')
        if ($i -le 0) { continue }
        $k = $t.Substring(0, $i).Trim(); $v = $t.Substring($i + 1).Trim()
        switch ($k.ToLower()) {
            'clave' { $c.Clave = $v }
            'auto' { $c.Auto = @($v -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
            default { if ($v) { $c.Fijas += [pscustomobject]@{ Nombre = $k; Ip = $v } } }
        }
    }
    return $c
}

function Set-EnvioAuto([string]$Nombre, [bool]$On) {
    $cfg = Get-EnvioConfig
    $list = New-Object System.Collections.ArrayList
    foreach ($a in $cfg.Auto) { if ($a -ne $Nombre) { [void]$list.Add($a) } }
    if ($On) { [void]$list.Add($Nombre) }
    $lines = @()
    $done = $false
    if (Test-Path $EnvioFile) { $lines = @(Get-Content -Path $EnvioFile -Encoding UTF8) }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*auto\s*=') { $lines[$i] = 'auto=' + ($list -join ', '); $done = $true }
    }
    if (-not $done) { $lines += ('auto=' + ($list -join ', ')) }
    try { [IO.File]::WriteAllLines($EnvioFile, [string[]]$lines, (New-Object System.Text.UTF8Encoding($true))) } catch {}
}

function Get-ClaveHash([string]$Clave) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $h = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('netbench:' + $Clave))
    return (($h[0..7] | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-BroadcastAddresses {
    $out = New-Object System.Collections.ArrayList
    [void]$out.Add('255.255.255.255')
    try {
        foreach ($a in @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' })) {
            $ip = [Net.IPAddress]::Parse($a.IPAddress).GetAddressBytes()
            $bits = [int]$a.PrefixLength
            $mask = [uint32]0
            if ($bits -gt 0) { $mask = [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $bits)) }
            $mb = [BitConverter]::GetBytes($mask); [Array]::Reverse($mb)
            $bc = New-Object byte[] 4
            for ($i = 0; $i -lt 4; $i++) { $bc[$i] = [byte]($ip[$i] -bor (255 -bxor $mb[$i])) }
            [void]$out.Add(([Net.IPAddress]::new($bc)).ToString())
        }
    } catch {}
    [void]$out.Add('127.0.0.1')     # por si el receptor está en esta misma PC
    return @($out | Select-Object -Unique)
}

function Find-Receptores([int]$Ms = 1500) {
    $cfg = Get-EnvioConfig
    $found = New-Object System.Collections.ArrayList
    if (-not $cfg.Clave) {
        Log '  Falta la clave en envio.txt: no se pueden buscar PCs.' 'Yellow'
        $Global:Receptores = @(); return @()
    }
    $msg = [Text.Encoding]::UTF8.GetBytes('NETBENCH-DESCUBRIR ' + (Get-ClaveHash $cfg.Clave))
    $u = $null
    try {
        $u = New-Object System.Net.Sockets.UdpClient
        $u.EnableBroadcast = $true
        $u.Client.ReceiveTimeout = 250
        foreach ($b in (Get-BroadcastAddresses)) { try { [void]$u.Send($msg, $msg.Length, $b, $ReceptorUdp) } catch {} }
        $t0 = Get-Date
        while (((Get-Date) - $t0).TotalMilliseconds -lt $Ms) {
            try {
                $ep = New-Object System.Net.IPEndPoint([Net.IPAddress]::Any, 0)
                $data = $u.Receive([ref]$ep)
                $txt = [Text.Encoding]::UTF8.GetString($data)
                if ($txt -match '^NETBENCH-RECEPTOR (\{.*\})$') {
                    $j = $Matches[1] | ConvertFrom-Json
                    [void]$found.Add([pscustomobject]@{ Nombre = [string]$j.nombre; Ip = $ep.Address.ToString(); Puerto = [int]$j.puerto; Modo = [string]$j.modo })
                }
            } catch {}
        }
    } catch {} finally { if ($u) { $u.Close() } }
    # PCs fijas de envio.txt (por si la búsqueda no llega, por ejemplo otra subred)
    foreach ($f in $cfg.Fijas) {
        try {
            $hostPart = $f.Ip; $p = $ReceptorPort
            if ($f.Ip -match '^(.+):(\d+)$') { $hostPart = $Matches[1]; $p = [int]$Matches[2] }
            $j = Invoke-RestMethod -Uri ("http://{0}:{1}/api/ping" -f $hostPart, $p) -TimeoutSec 3 -UseBasicParsing
            [void]$found.Add([pscustomobject]@{ Nombre = $(if ($j.nombre) { [string]$j.nombre } else { $f.Nombre }); Ip = $hostPart; Puerto = $p; Modo = [string]$j.modo })
        } catch {}
    }
    # la misma PC puede contestar por varias interfaces: una entrada por nombre (se prefiere la IP no local)
    $uniq = @{}
    foreach ($r in $found) {
        if (-not $uniq.Contains($r.Nombre) -or ($uniq[$r.Nombre].Ip -eq '127.0.0.1' -and $r.Ip -ne '127.0.0.1')) { $uniq[$r.Nombre] = $r }
    }
    $Global:Receptores = @($uniq.Values | Sort-Object Nombre)
    return $Global:Receptores
}

function Send-Informe($Rec) {
    if (-not $Global:InformeHtml -or -not (Test-Path $Global:InformeHtml)) { Show-Resumen }
    if (-not $Global:InformeHtml) { Log '  No hay informe para enviar.' 'Yellow'; return $false }
    $cfg = Get-EnvioConfig
    $base = [IO.Path]::ChangeExtension($Global:InformeHtml, $null).TrimEnd('.')
    $files = @()
    foreach ($ext in '.json', '.html') { if (Test-Path ($base + $ext)) { $files += ($base + $ext) } }
    foreach ($x in $Global:InformeOrdenHtml, $Global:InformeOrdenPdf) { if ($x -and (Test-Path $x)) { $files += $x } }
    if ($Global:InformePdf -and (Test-Path $Global:InformePdf)) { $files += $Global:InformePdf }
    $ok = $true
    for ($i = 0; $i -lt $files.Count; $i++) {
        $f = $files[$i]
        $h = @{
            'X-Clave'   = $cfg.Clave
            'X-Archivo' = [Uri]::EscapeDataString((Split-Path -Leaf $f))
            'X-Orden'   = [Uri]::EscapeDataString([string]$Global:M.Orden)
            'X-Ultimo'  = $(if ($i -eq $files.Count - 1) { '1' } else { '0' })
        }
        try {
            $null = Invoke-WebRequest -Uri ("http://{0}:{1}/api/recibir" -f $Rec.Ip, $Rec.Puerto) -Method Post -InFile $f -ContentType 'application/octet-stream' -Headers $h -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
        } catch {
            $ok = $false
            $code = $null; try { $code = [int]$_.Exception.Response.StatusCode } catch {}
            $why = if ($code -eq 403) { 'la clave no coincide (revisar envio.txt y la del receptor)' } else { $_.Exception.Message }
            Log ("  No se pudo enviar a {0} ({1}): {2}" -f $Rec.Nombre, $Rec.Ip, $why) 'Red'
            break
        }
    }
    $hora = Get-Date -Format 'HH:mm'
    if ($ok) {
        $que = if ($Rec.Modo -eq 'mostrar') { 'se muestra en su pantalla' } else { 'quedó guardado' }
        Log ("  Informe enviado a {0} ({1}): {2}." -f $Rec.Nombre, $Rec.Ip, $que) 'Green'
        $Global:EnvioEstado = "Enviado a $($Rec.Nombre) a las $hora"
    } else {
        $Global:EnvioEstado = "No se pudo enviar a $($Rec.Nombre) ($hora)"
    }
    return $ok
}

function Invoke-EnvioAuto {
    $cfg = Get-EnvioConfig
    if (-not $cfg.Auto.Count -or -not $Global:InformeHtml) { return }
    $recs = @(Find-Receptores)
    foreach ($n in $cfg.Auto) {
        $r = $recs | Where-Object { $_.Nombre -eq $n } | Select-Object -First 1
        if ($r) { [void](Send-Informe $r) } else { Log ("  Envío automático: '{0}' no respondió (¿está prendida y con NET-Receptor?)." -f $n) 'Yellow' }
    }
}

function Invoke-EnvioConsola {
    Section 'ENVIAR INFORME A OTRA PC'
    Log 'Buscando PCs con NET-Receptor en la red del local...' 'DarkGray'
    $recs = @(Find-Receptores)
    if (-not $recs.Count) {
        Log '  No se encontró ninguna. Revisá que NET-Receptor esté instalado y abierto en la otra PC, y que la clave de envio.txt sea la misma.' 'Yellow'
        return
    }
    $ops = @(); $i = 0
    foreach ($r in $recs) { $i++; $ops += @{ Value = [string]$i; Label = $r.Nombre; Desc = ('{0} | {1}' -f $r.Ip, $(if ($r.Modo -eq 'mostrar') { 'pantalla para el cliente' } else { 'guardar' })) } }
    $sel = [int](Ask-Choice '¿A qué PC enviar el informe?' $ops '1')
    [void](Send-Informe $recs[$sel - 1])
}

# ======================================================================
#  Identidad de la placa de video: ¿es realmente el modelo que dice?
#  Tabla de chips y modelos de placa: pci.ids (pciutils), comprimida.
# ======================================================================
$GpuDbB64 = @'
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
'@
$GpuDbFecha = '2026-10-28'

# Potencia de referencia (TGP, W) de NVIDIA de escritorio, para comparar con el límite por defecto del BIOS
$NvRefTgp = [ordered]@{
    'GTX 1050' = 75; 'GTX 1050 TI' = 75; 'GTX 1060 3GB' = 120; 'GTX 1060 6GB' = 120; 'GTX 1060' = 120; 'GTX 1070' = 150; 'GTX 1070 TI' = 180
    'GTX 1080' = 180; 'GTX 1080 TI' = 250; 'GTX 1630' = 75; 'GTX 1650' = 75; 'GTX 1650 SUPER' = 100; 'GTX 1660' = 120; 'GTX 1660 SUPER' = 125
    'GTX 1660 TI' = 120; 'RTX 2060' = 160; 'RTX 2060 SUPER' = 175; 'RTX 2070' = 175; 'RTX 2070 SUPER' = 215; 'RTX 2080' = 215
    'RTX 2080 SUPER' = 250; 'RTX 2080 TI' = 250; 'RTX 3050' = 130; 'RTX 3060' = 170; 'RTX 3060 TI' = 200; 'RTX 3070' = 220
    'RTX 3070 TI' = 290; 'RTX 3080' = 320; 'RTX 3080 12GB' = 350; 'RTX 3080 TI' = 350; 'RTX 3090' = 350; 'RTX 3090 TI' = 450
    'RTX 4060' = 115; 'RTX 4060 TI' = 160; 'RTX 4070' = 200; 'RTX 4070 SUPER' = 220; 'RTX 4070 TI' = 285; 'RTX 4070 TI SUPER' = 285
    'RTX 4080' = 320; 'RTX 4080 SUPER' = 320; 'RTX 4090' = 450; 'RTX 5060' = 145; 'RTX 5060 TI' = 180; 'RTX 5070' = 250
    'RTX 5070 TI' = 300; 'RTX 5080' = 360; 'RTX 5090' = 575
}

function Get-GpuDb {
    if ($Global:GpuDb) { return $Global:GpuDb }
    $db = @{ Dev = @{}; Sub = @{}; Vend = @{} }
    try {
        $bytes = [Convert]::FromBase64String(($GpuDbB64 -replace '\s', ''))
        $ms = New-Object IO.MemoryStream(, $bytes)
        $gz = New-Object IO.Compression.GZipStream($ms, [IO.Compression.CompressionMode]::Decompress)
        $sr = New-Object IO.StreamReader($gz, [Text.Encoding]::UTF8)
        while ($null -ne ($l = $sr.ReadLine())) {
            if ($l.Length -lt 8) { continue }
            switch ($l[0]) {
                'D' { $db.Dev[$l.Substring(2, 8)] = $l.Substring(11) }
                'S' { $db.Sub[$l.Substring(2, 16)] = $l.Substring(19) }
                'V' { $db.Vend[$l.Substring(2, 4)] = $l.Substring(7) }
            }
        }
        $sr.Dispose()
    } catch {}
    $Global:GpuDb = $db
    return $db
}

# "NVIDIA GeForce RTX 3080 Laptop GPU" -> "RTX 3080"; "AMD Radeon RX 580 2048SP" -> "RX 580 2048SP"
function Get-GpuModelKey([string]$Name) {
    $n = " " + $Name.ToUpper() + " "
    $n = $n -replace '\(TM\)|\(R\)|®|™', ' '
    foreach ($w in 'NVIDIA', 'GEFORCE', 'AMD', 'ATI', 'RADEON', 'INTEL', 'GRAPHICS', 'LAPTOP GPU', 'LAPTOP', 'MOBILE', 'MAX-Q', 'MAX-P', 'DESIGN', 'LITE HASH RATE', 'LHR', 'OEM', 'REV. A', 'REV A', 'GDDR6X', 'GDDR6', 'GDDR5X', 'GDDR5', 'SERIES', 'EDITION', 'FOUNDERS') {
        $n = $n -replace ('\s' + [regex]::Escape($w) + '(?=\s)'), ' '
    }
    $n = $n -replace '\b\d{1,2}\s?GB\b', ' '
    return (($n -replace '[^A-Z0-9 ]', ' ' -replace '\s+', ' ').Trim())
}

# Los nombres de pci.ids vienen agrupados: "Radeon RX 470/480/570/570X/580/580X/590", "RX 6800/6800 XT / 6900 XT"
function Get-PciModelNames([string]$PciName) {
    $out = New-Object System.Collections.ArrayList
    $m = [regex]::Match($PciName, '\[(.+)\]')
    $txt = if ($m.Success) { $m.Groups[1].Value } else { $PciName }
    $prefix = ''
    foreach ($grp in ($txt -split '\s/\s')) {
        $parts = $grp -split '/'
        $first = $parts[0].Trim()
        if ($first -match '^(.*?\b(GeForce|Radeon|Quadro|TITAN|Arc|RTX|GTX|GT|RX|Pro|FirePro)\b\s*(RTX|GTX|GT|RX|Pro|R\d)?\s*)(\S.*)$') { $prefix = $Matches[1] }
        elseif ($prefix -and $first -match '^\d') { $first = $prefix + $first }
        [void]$out.Add($first)
        for ($i = 1; $i -lt $parts.Count; $i++) {
            $p = $parts[$i].Trim()
            if ($p -match '^\d' -and $prefix) { $p = $prefix + $p }
            [void]$out.Add($p)
        }
    }
    return @($out | ForEach-Object { Get-GpuModelKey $_ } | Where-Object { $_ } | Select-Object -Unique)
}

function Get-GpuRegistryInfo([string]$PnpId) {
    $r = @{ MemBytes = $null; Bios = $null; Fecha = $null }
    try {
        $base = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
        $want = ($PnpId -split '\\')[1]
        foreach ($k in @(Get-ChildItem $base -ErrorAction Stop | Where-Object { $_.PSChildName -match '^\d{4}$' })) {
            $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
            if (-not $p -or -not $p.MatchingDeviceId) { continue }
            if ($want -notlike ($p.MatchingDeviceId.ToUpper().Replace('PCI\', '') + '*')) { continue }
            $q = $p.'HardwareInformation.qwMemorySize'
            if ($q) { $r.MemBytes = [double]$q }
            elseif ($p.'HardwareInformation.MemorySize') {
                $v = $p.'HardwareInformation.MemorySize'
                $r.MemBytes = if ($v -is [byte[]]) { [double][BitConverter]::ToUInt32($v, 0) } else { [double]$v }
            }
            $b = $p.'HardwareInformation.BiosString'
            if ($b -is [byte[]]) { $b = [Text.Encoding]::Unicode.GetString($b) }
            if ($b) { $r.Bios = ([string]$b).Trim([char]0, ' ') }
            $r.Fecha = $p.DriverDate
            break
        }
    } catch {}
    return $r
}

function Get-NvidiaSmi {
    $c = @("$env:SystemRoot\System32\nvidia-smi.exe", "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe")
    foreach ($p in $c) { if ($p -and (Test-Path $p)) { return $p } }
    return $null
}

function Get-NvidiaInfo {
    $smi = Get-NvidiaSmi
    if (-not $smi) { return @() }
    $fields = 'name,pci.device_id,pci.sub_device_id,vbios_version,memory.total,power.default_limit,power.max_limit,clocks.max.graphics,clocks.max.memory'
    try {
        $out = & $smi "--query-gpu=$fields" '--format=csv,noheader,nounits' 2>$null
        $res = @()
        foreach ($l in @($out)) {
            $v = @($l -split ',\s*')
            if ($v.Count -lt 9) { continue }
            $num = { param($x) $d = 0.0; if ([double]::TryParse(($x -replace '[^\d.]', ''), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { $d } else { $null } }
            $res += [pscustomobject]@{
                Nombre = $v[0].Trim(); DevId = $v[1].Trim(); SubId = $v[2].Trim(); Vbios = $v[3].Trim()
                MemMB = (& $num $v[4]); PotDef = (& $num $v[5]); PotMax = (& $num $v[6]); RelojMax = (& $num $v[7]); MemRelojMax = (& $num $v[8])
            }
        }
        return $res
    } catch { return @() }
}

function Test-GpuIdentity {
    if ($Global:GpuIdDone) { return }
    $Global:GpuIdDone = $true
    Section 'VIDEO - IDENTIDAD DE LA PLACA'
    $db = Get-GpuDb
    if (-not $db.Dev.Count) { Log '  No se pudo cargar la tabla de chips.' 'Yellow'; return }
    $vga = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.PNPDeviceID -like 'PCI\VEN_*' })
    $nv = @(Get-NvidiaInfo)
    $signed = @{}
    try { foreach ($d in @(Get-CimInstance Win32_PnPSignedDriver -Filter "DeviceClass='DISPLAY'" -ErrorAction Stop)) { $signed[[string]$d.DeviceID] = $d } } catch {}
    $any = $false
    foreach ($g in $vga) {
        $pnp = [string]$g.PNPDeviceID
        if ($pnp -notmatch 'VEN_([0-9A-F]{4})&DEV_([0-9A-F]{4})(&SUBSYS_([0-9A-F]{4})([0-9A-F]{4}))?(&REV_([0-9A-F]{2}))?') { continue }
        $ven = $Matches[1].ToLower(); $dev = $Matches[2].ToLower(); $subDev = "$($Matches[4])".ToLower(); $subVen = "$($Matches[5])".ToLower(); $rev = $Matches[7]
        if (@('10de', '1002', '8086') -notcontains $ven) { continue }
        $nombre = Get-Clean $g.Name
        if ($nombre -match $IntegradaRegex -and $nombre -notmatch 'Arc\s+[AB]\d') { continue }     # las integradas tienen nombres genéricos
        $any = $true
        if ([int]$g.ConfigManagerErrorCode -eq 43) {
            Set-Verdict 'GPU' 'ATENCION' ('El driver de {0} no carga (código 43). En placas usadas suele ser un BIOS modificado (en AMD el driver oficial rechaza los BIOS de minería) o una falla de la placa.' -f (Get-Clean $g.Name))
        }
        $pci = $db.Dev[$ven + $dev]
        $marca = if ($subVen) { $db.Vend[$subVen] } else { $null }
        $placa = if ($subVen) { $db.Sub[$ven + $dev + $subVen + $subDev] } else { $null }
        Log ("  {0}" -f $nombre) 'White'
        Log ("    ID: {0}:{1}  subsistema {2}:{3}  rev {4}" -f $ven.ToUpper(), $dev.ToUpper(), $subVen.ToUpper(), $subDev.ToUpper(), $rev)
        $gi = $Global:M.Gpu
        $gi['DevId'] = ($ven + $dev).ToUpper()
        $gi['NombreWindows'] = $nombre
        if ($pci) {
            $chip = ($pci -replace '\s*\[.*$', '').Trim()
            Log ("    Chip real según el ID: {0}" -f $pci)
            $gi['Chip'] = $chip; $gi['ChipNombre'] = $pci
            $key = Get-GpuModelKey $nombre
            $cands = @(Get-PciModelNames $pci)
            $coincide = ($cands -contains $key)
            $compartido = ''
            if (-not $coincide -and $ven -eq '1002') {
                # AMD usa el mismo ID de chip para la versión XT y la común (solo cambia la revisión): RX 5500 / RX 5500 XT, etc.
                $comun = $key -replace '\s(XTX|XT|GRE)$', ''
                if ($comun -ne $key -and $cands -contains $comun) { $coincide = $true; $compartido = $comun }
            }
            if ($coincide) {
                $gi['Coincide'] = $true
                Set-Verdict 'GPU' 'OK' ("Identidad: el chip {0} corresponde a una {1}{2}." -f $chip, $key, $(if ($compartido) { " (AMD usa el mismo ID que la $compartido)" } else { '' }))
            } else {
                $gi['Coincide'] = $false
                Set-Verdict 'GPU' 'ATENCION' ("El nombre que muestra Windows ({0}) NO coincide con el chip real de la placa ({1}). Posible placa adulterada (chip de otro modelo con BIOS o driver modificado): verificar con GPU-Z y mirar la placa." -f $nombre, $pci)
            }
            if ($pci -match 'Lite Hash Rate') { $gi['Variante'] = 'LHR'; Log '    Variante LHR (Lite Hash Rate): rendimiento en juegos igual a la normal.' 'DarkGray' }
            if ($pci -match '2048SP') {
                $gi['Variante'] = '2048SP'
                Set-Verdict 'GPU' 'ATENCION' 'Es la variante recortada "RX 580 2048SP" (Polaris 20 XL): menos núcleos y ~15-20% menos rendimiento que una RX 580 común. Se suele vender como RX 580 normal.'
            }
            if ($pci -match '(\d+)\s?GB' -and $null -eq $gi['VramEsperadaGB']) { $gi['VramEsperadaGB'] = [int]$Matches[1] }
        } else {
            Log ("    El ID {0}:{1} no está en la tabla de chips (actualizada al {2})." -f $ven.ToUpper(), $dev.ToUpper(), $GpuDbFecha) 'Yellow'
            Set-Verdict 'GPU' 'INFO' ("No se pudo verificar la identidad: el chip {0}:{1} no está en la tabla." -f $ven.ToUpper(), $dev.ToUpper())
        }
        if ($marca) {
            $txt = if ($placa) { "$marca - $placa" } else { $marca }
            Log ("    Fabricante según el BIOS de la placa: {0}" -f $txt)
            $gi['Fabricante'] = $txt
            Add-Pendiente ("Video: la etiqueta de la placa tiene que decir {0}. Si dice otra marca, tiene el BIOS de otro fabricante (cross-flash)." -f $marca)
        }
        # Memoria informada
        $reg = Get-GpuRegistryInfo $pnp
        $nvi = $nv | Where-Object { $_.DevId -match $dev } | Select-Object -First 1
        $memGB = $null
        if ($nvi -and $nvi.MemMB) { $memGB = [math]::Round($nvi.MemMB / 1024) }
        elseif ($reg.MemBytes) { $memGB = [math]::Round($reg.MemBytes / 1GB) }
        if ($memGB) {
            $gi['VramGB'] = $memGB
            Log ("    Memoria de video informada: {0} GB" -f $memGB)
            if ($gi['VramEsperadaGB'] -and [math]::Abs($memGB - $gi['VramEsperadaGB']) -ge 1) {
                Set-Verdict 'GPU' 'ATENCION' ("La placa informa {0} GB de memoria y ese chip/modelo trae {1} GB." -f $memGB, $gi['VramEsperadaGB'])
            }
        }
        # BIOS de video
        $bios = if ($nvi -and $nvi.Vbios) { $nvi.Vbios } else { $reg.Bios }
        if ($bios) { $gi['Vbios'] = $bios; Log ("    BIOS de video: {0}" -f $bios) }
        # Límite de potencia (NVIDIA): un BIOS de otro modelo suele cambiarlo
        if ($nvi -and $nvi.PotDef) {
            $gi['PotDef'] = [math]::Round($nvi.PotDef); $gi['PotMax'] = [math]::Round($nvi.PotMax)
            $k = Get-GpuModelKey $nombre
            $refKey = if ($k -match '^RTX 3080$' -and $memGB -ge 12) { 'RTX 3080 12GB' } else { $k }
            $ref = $NvRefTgp[$refKey]
            $refTxt = if ($ref) { " (referencia de NVIDIA para {0}: {1} W)" -f $k, $ref } else { '' }
            Log ("    Límite de potencia: {0:N0} W por defecto, {1:N0} W máximo{2}" -f $nvi.PotDef, $nvi.PotMax, $refTxt)
            if ($nvi.RelojMax) { Log ("    Relojes máximos: núcleo {0:N0} MHz, memoria {1:N0} MHz" -f $nvi.RelojMax, $nvi.MemRelojMax) }
            if ($ref) {
                $ratio = $nvi.PotDef / $ref
                if ($ratio -gt 1.45) { Set-Verdict 'GPU' 'ATENCION' ("Límite de potencia por defecto de {0:N0} W, muy por encima de los {1} W de referencia: típico de un BIOS de otro modelo (cross-flash)." -f $nvi.PotDef, $ref) }
                elseif ($ratio -gt 1.25) { Set-Verdict 'GPU' 'INFO' ("Límite de potencia por defecto alto ({0:N0} W vs {1} W de referencia): normal en versiones tope (Strix, FTW3, Suprim, Aorus Master); en una placa básica puede ser un BIOS de otro modelo." -f $nvi.PotDef, $ref) }
                elseif ($ratio -lt 0.8) { Set-Verdict 'GPU' 'INFO' ("Límite de potencia por defecto bajo ({0:N0} W vs {1} W de referencia): puede tener un BIOS modificado o de otro modelo." -f $nvi.PotDef, $ref) }
            }
        }
        # Driver: firmado y sin modificar
        $sd = $signed[$pnp]
        if ($sd) {
            $gi['DriverFirmado'] = [bool]$sd.IsSigned
            if (-not $sd.IsSigned) { Set-Verdict 'GPU' 'ATENCION' 'El driver de video instalado NO está firmado: driver modificado, típico de placas truchas (para que Windows muestre otro nombre) o de BIOS modificados en AMD.' }
            else { Log ("    Driver firmado por: {0}" -f $sd.Signer) 'DarkGray' }
        }
    }
    if (-not $any) { Log '  No hay placa de video dedicada para verificar.' 'DarkGray'; return }
    # Archivos del driver alterados y Windows en "modo de prueba"
    try {
        foreach ($svc in @(Get-CimInstance Win32_SystemDriver -ErrorAction Stop | Where-Object { @('nvlddmkm', 'amdkmdag', 'amdwddmg', 'igfxn', 'igfx') -contains $_.Name -and $_.State -eq 'Running' })) {
            $path = ([string]$svc.PathName) -replace '^\\\?\?\\', '' -replace '^\\SystemRoot', $env:SystemRoot
            if ($path -and (Test-Path $path)) {
                $sig = Get-AuthenticodeSignature -FilePath $path -ErrorAction SilentlyContinue
                if ($sig -and @('HashMismatch', 'NotTrusted') -contains [string]$sig.Status) {
                    $Global:M.Gpu['DriverFirmado'] = $false
                    Set-Verdict 'GPU' 'ATENCION' ("El archivo del driver de video ({0}) fue modificado: la firma no coincide. Se usa para hacer andar BIOS modificados (minería en AMD) o placas truchas." -f (Split-Path -Leaf $path))
                }
            }
        }
    } catch {}
    try {
        $bcd = (& bcdedit.exe /enum '{current}' 2>$null) | Out-String
        if ($bcd -match '(?im)^\s*testsigning\s+(Yes|Sí|Si)\b' -or $bcd -match '(?im)^\s*nointegritychecks\s+(Yes|Sí|Si)\b') {
            Set-Verdict 'GPU' 'ATENCION' 'Windows está en "modo de prueba" (acepta drivers sin firma). Se usa para drivers modificados: revisar por qué está activado.'
        }
    } catch {}
    Log ('  Tabla de chips: pci.ids al {0}. Lo que no se puede ver desde Windows: si el BIOS de NVIDIA es de otra marca solo se nota por el fabricante y la potencia; en AMD (RX 400/500) un BIOS modificado normalmente hace que el driver oficial no cargue (código 43) o obliga a parchear el driver, y las dos cosas se marcan acá.' -f $GpuDbFecha) 'DarkGray'
}

# ======================================================================
#  Drivers: buscar e instalar solos (AMD chipset, Windows Update, NVIDIA, AMD Radeon)
# ======================================================================
# Todo sale de fuentes oficiales y cada instalador se verifica con la firma digital del fabricante
# antes de ejecutarlo. Lo bajado queda en tools\drivers para reusarlo en el próximo equipo.
$DriversDir = Join-Path $ToolsDir 'drivers'
$NavegadorUA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36'
$DrvFuentes = @{
    AmdChipsetPaginas = @('https://www.amd.com/en/support/downloads/drivers.html/chipsets/am5/b650.html', 'https://www.amd.com/en/support/downloads/drivers.html/chipsets/am4/b550.html')
    AmdChipsetRegex   = 'https://drivers\.amd\.com/drivers/amd_chipset_software_[\d.]+\.exe'
    AmdChipsetUrl     = 'https://drivers.amd.com/drivers/amd_chipset_software_8.09.28.1124.exe'   # si la página no responde
    AmdGpuPaginas     = @('https://www.amd.com/en/support/downloads/drivers.html/graphics/radeon-rx/radeon-rx-9000-series/amd-radeon-rx-9070-xt.html', 'https://www.amd.com/en/support/downloads/drivers.html/graphics/radeon-rx/radeon-rx-6000-series/amd-radeon-rx-6600.html')
    AmdGpuRegex       = 'https://drivers\.amd\.com/drivers/installer/[\w.]+/whql/amd-software-adrenalin-edition-[\w.\-]+-minimalsetup-\w+_web\.exe'
    AmdGpuUrl         = 'https://drivers.amd.com/drivers/installer/26.20/whql/amd-software-adrenalin-edition-26.10.1-minimalsetup-261018_web.exe'
    AmdReferer        = 'https://www.amd.com/'
    NvProductos       = 'https://www.nvidia.com/Download/API/lookupValueSearch.aspx?TypeID=3'
    NvBuscar          = 'https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php?func=DriverManualLookup&psid={0}&pfid={1}&osID={2}&languageCode=1033&isWHQL=1&dch={3}&sort1=0&numberOfResults=1'
}

function Get-WebTexto([string]$Url) {
    try {
        $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -UserAgent $NavegadorUA -TimeoutSec 30 -Headers @{ 'Accept-Language' = 'en-US,en;q=0.9' } -ErrorAction Stop
        return [string]$r.Content
    } catch { return $null }
}

function Find-UrlEnPaginas([string[]]$Paginas, [string]$Regex) {
    foreach ($p in $Paginas) {
        $t = Get-WebTexto $p
        if (-not $t) { continue }
        $m = [regex]::Matches($t, $Regex)
        if ($m.Count) { return $m[0].Value }
    }
    return $null
}

# Descarga grande con progreso (los drivers de video pesan ~1 GB) y Q/Esc para cortar
function Save-UrlGrande([string]$Url, [string]$Dest, [string]$Referer, [string]$Que) {
    $part = $Dest + '.part'
    $resp = $null; $in = $null; $out = $null
    try {
        $req = [Net.HttpWebRequest]::Create($Url)
        $req.UserAgent = $NavegadorUA
        $req.Accept = '*/*'
        if ($Referer) { $req.Referer = $Referer }
        $req.Timeout = 60000
        $req.ReadWriteTimeout = 120000
        $resp = $req.GetResponse()
        $total = [double]$resp.ContentLength
        $in = $resp.GetResponseStream()
        $out = [IO.File]::Create($part)
        $buf = New-Object byte[] 1048576
        $done = 0.0; $t0 = Get-Date; $lastUi = Get-Date; $lastLog = 0
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $out.Write($buf, 0, $n)
            $done += $n
            if (((Get-Date) - $lastUi).TotalMilliseconds -lt 700) { continue }
            $lastUi = Get-Date
            $vel = $done / 1MB / [math]::Max(0.1, ((Get-Date) - $t0).TotalSeconds)
            if ($total -gt 0) {
                $pct = [int](100 * $done / $total)
                Write-Progress "Descargando $Que" ('{0:N0} de {1:N0} MB · {2:N1} MB/s' -f ($done / 1MB), ($total / 1MB), $vel) $pct
                $q = [int][math]::Floor($pct / 25)
                if ($q -gt $lastLog -and $q -lt 4) { $lastLog = $q; Log ('    {0}% ({1:N1} MB/s)' -f ($q * 25), $vel) 'DarkGray' }
            } else {
                Write-Progress "Descargando $Que" ('{0:N0} MB · {1:N1} MB/s' -f ($done / 1MB), $vel)
            }
            if (Test-KeyQ) { throw 'cortado por el técnico' }
        }
        $out.Dispose(); $out = $null
        if ($total -gt 0 -and $done -lt $total) { throw 'la descarga quedó incompleta' }
        if ($done -lt 100KB) { throw 'el archivo bajado es demasiado chico' }
        Move-Item -Force -Path $part -Destination $Dest
        return $true
    } catch {
        Log ('    No se pudo bajar {0}: {1}' -f $Url, $_.Exception.Message) 'Yellow'
        return $false
    } finally {
        if ($out) { $out.Dispose() }
        if ($in) { $in.Dispose() }
        if ($resp) { $resp.Close() }
        Remove-Item $part -Force -ErrorAction SilentlyContinue
        Write-Progress -Completed
    }
}

function Test-FirmaDe([string]$Path, [string]$Patron) {
    if (-not (Test-Path $Path)) { return $false }
    try { $s = Get-AuthenticodeSignature -FilePath $Path -ErrorAction Stop } catch { return $false }
    return ([string]$s.Status -eq 'Valid' -and $s.SignerCertificate -and $s.SignerCertificate.Subject -match $Patron)
}

# Baja (o reusa de tools\drivers) y verifica la firma. Devuelve la ruta o $null.
function Get-InstaladorFirmado([string]$Url, [string]$Firma, [string]$Referer, [string]$Que) {
    New-Item -ItemType Directory -Force -Path $DriversDir -ErrorAction SilentlyContinue | Out-Null
    $file = Join-Path $DriversDir ([IO.Path]::GetFileName(([uri]$Url).AbsolutePath))
    if (Test-FirmaDe $file $Firma) { Log ('  Ya estaba bajado en tools\drivers: {0}' -f (Split-Path -Leaf $file)) 'DarkGray'; return $file }
    Remove-Item $file -Force -ErrorAction SilentlyContinue
    Log ('  Bajando {0}...' -f $Que)
    if (-not (Save-UrlGrande $Url $file $Referer $Que)) { return $null }
    if (-not (Test-FirmaDe $file $Firma)) {
        Log '  El archivo bajado NO tiene la firma digital del fabricante: se borra y no se instala.' 'Red'
        Remove-Item $file -Force -ErrorAction SilentlyContinue
        return $null
    }
    Log '  Firma digital del fabricante verificada.' 'DarkGray'
    return $file
}

# Corre un instalador y espera (con el tiempo en la barra de progreso). Devuelve el código de salida o $null.
function Invoke-Instalador([string]$Exe, [string]$Argumentos, [int]$MaxMin, [string]$Que) {
    try {
        $p = if ($Argumentos) { Start-Process -FilePath $Exe -ArgumentList $Argumentos -PassThru -ErrorAction Stop } else { Start-Process -FilePath $Exe -PassThru -ErrorAction Stop }
    } catch { Log ('  No se pudo abrir el instalador: {0}' -f $_.Exception.Message) 'Yellow'; return $null }
    $t0 = Get-Date
    while (-not $p.WaitForExit(1000)) {
        $el = (Get-Date) - $t0
        Write-Progress $Que ('{0}:{1:00} · no apagar ni cerrar' -f [math]::Floor($el.TotalMinutes), $el.Seconds)
        if ($el.TotalMinutes -gt $MaxMin) { Log ('  El instalador sigue abierto después de {0} min: se deja corriendo.' -f $MaxMin) 'Yellow'; Write-Progress -Completed; return $null }
    }
    Write-Progress -Completed
    return $p.ExitCode
}

function Get-ProgramaInstalado([string]$Patron) {
    foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*') {
        $x = @(Get-ItemProperty $k -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match $Patron })
        if ($x.Count) { return [pscustomobject]@{ Nombre = [string]$x[0].DisplayName; Version = [string]$x[0].DisplayVersion } }
    }
    return $null
}

function ConvertTo-Version([string]$s) {
    if ($s -notmatch '(\d+(\.\d+){1,3})') { return $null }
    try { return [version]$Matches[1] } catch { return $null }
}

# ---------- Chipset AMD (Ryzen/Athlon AM4-AM5, Threadripper) ----------
function Install-ChipsetAmd {
    $cpu = if ($Global:Cpu) { [string]$Global:Cpu.Nombre } else { '' }
    if ($cpu -notmatch 'AMD' -or $cpu -notmatch 'Ryzen|Athlon|Threadripper') { return }
    Log ''
    Log 'Chipset AMD (AMD Chipset Software):' 'White'
    $inst = Get-ProgramaInstalado '^AMD Chipset Software'
    $url = Find-UrlEnPaginas $DrvFuentes.AmdChipsetPaginas $DrvFuentes.AmdChipsetRegex
    if (-not $url) { $url = $DrvFuentes.AmdChipsetUrl; Log '  La página de AMD no respondió: se usa la última versión conocida.' 'DarkGray' }
    $ver = if ($url -match 'software_([\d.]+)\.exe') { $Matches[1] } else { '' }
    $vi = if ($inst) { ConvertTo-Version $inst.Version } else { $null }
    $vu = ConvertTo-Version $ver
    if ($vi -and $vu -and $vi -ge $vu) { Log ('  Al día: {0} (la última es {1}).' -f $inst.Version, $ver) 'Green'; return }
    $msg = if ($inst) { '¿Actualizar el chipset AMD de {0} a {1} (~80 MB)?' -f $inst.Version, $ver } else { 'No tiene el chipset AMD. ¿Bajar e instalar la versión {0} (~80 MB)?' -f $ver }
    if (-not (Ask-Yes $msg $true)) { return }
    $f = Get-InstaladorFirmado $url 'Advanced Micro Devices' $DrvFuentes.AmdReferer 'chipset AMD'
    if (-not $f) { Log '  Instalarlo a mano desde amd.com/support (Chipsets).' 'Yellow'; return }
    Log '  Instalando en modo automático (2-5 min)...'
    $code = Invoke-Instalador $f '/S' 20 'Instalando chipset AMD'
    $nuevo = Get-ProgramaInstalado '^AMD Chipset Software'
    if ($nuevo -and (ConvertTo-Version $nuevo.Version) -ge $vu) {
        Log ('  Chipset AMD {0} instalado.' -f $nuevo.Version) 'Green'
        [void]$Global:DrvHechos.Add("chipset AMD $($nuevo.Version)")
        $Global:DrvReinicio = $true
    } else {
        Log ('  El instalador terminó (código {0}) pero no se ve la versión nueva. Se abre en modo normal para terminarlo a mano.' -f $code) 'Yellow'
        [void](Start-Process -FilePath $f -PassThru -ErrorAction SilentlyContinue)
        if (Ask-Yes 'Cuando termine el instalador del chipset AMD, tocá Sí' $true) {
            $nuevo = Get-ProgramaInstalado '^AMD Chipset Software'
            if ($nuevo) { [void]$Global:DrvHechos.Add("chipset AMD $($nuevo.Version)"); $Global:DrvReinicio = $true }
        }
    }
}

# ---------- Windows Update (Intel chipset/ME/Serial IO, red, audio, Wi-Fi, iGPU Intel, etc.) ----------
$WuJobScript = {
    param([string]$Modo, [string[]]$Ids)
    $out = @{ Error = $null; Lista = @(); Res = @(); Reinicio = $false }
    try {
        $ses = New-Object -ComObject Microsoft.Update.Session
        $ses.ClientApplicationID = 'NET-TestBench'
        $sr = $ses.CreateUpdateSearcher()
        $sr.ServerSelection = 2          # Windows Update directo (aunque la PC tenga un WSUS configurado)
        $sr.Online = $true
        $r = $sr.Search("IsInstalled=0 and Type='Driver' and IsHidden=0")
        $col = New-Object -ComObject Microsoft.Update.UpdateColl
        $lista = @()
        foreach ($u in $r.Updates) {
            $id = [string]$u.Identity.UpdateID
            $fecha = ''
            try { $fecha = ([datetime]$u.DriverVerDate).ToString('yyyy-MM-dd') } catch {}
            $lista += [pscustomobject]@{ Id = $id; Titulo = [string]$u.Title; Clase = [string]$u.DriverClass; Fabricante = [string]$u.DriverManufacturer; Modelo = [string]$u.DriverModel; Fecha = $fecha; MB = [math]::Round([double]$u.MaxDownloadSize / 1MB, 1) }
            if ($Modo -eq 'instalar' -and $Ids -contains $id) {
                try { if (-not $u.EulaAccepted) { $u.AcceptEula() } } catch {}
                [void]$col.Add($u)
            }
        }
        $out.Lista = $lista
        if ($Modo -eq 'instalar' -and $col.Count -gt 0) {
            $dl = $ses.CreateUpdateDownloader()
            $dl.Updates = $col
            [void]$dl.Download()
            $ins = $ses.CreateUpdateInstaller()
            $ins.Updates = $col
            try { $ins.ForceQuiet = $true } catch {}
            $ir = $ins.Install()
            $res = @()
            for ($i = 0; $i -lt $col.Count; $i++) { $res += [pscustomobject]@{ Titulo = [string]$col.Item($i).Title; Codigo = [int]$ir.GetUpdateResult($i).ResultCode } }
            $out.Res = $res
            $out.Reinicio = [bool]$ir.RebootRequired
        }
    } catch { $out.Error = $_.Exception.Message }
    return $out
}

function Invoke-WuJob([string]$Modo, [string[]]$Ids, [int]$MaxMin, [string]$Que) {
    if (-not $Ids -or -not $Ids.Count) { $Ids = @('') }
    $job = Start-Job -ScriptBlock $WuJobScript -ArgumentList $Modo, $Ids
    $t0 = Get-Date
    $cortado = $false
    while ($job.State -eq 'Running' -or $job.State -eq 'NotStarted') {
        $el = (Get-Date) - $t0
        Write-Progress $Que ('{0}:{1:00}' -f [math]::Floor($el.TotalMinutes), $el.Seconds)
        if ($el.TotalMinutes -gt $MaxMin) { Log ('  Windows Update no terminó en {0} min: se corta.' -f $MaxMin) 'Yellow'; $cortado = $true; break }
        if ($Modo -eq 'buscar' -and (Test-KeyQ)) { Log '  Búsqueda cortada por el técnico.' 'Yellow'; $cortado = $true; break }
        Start-Sleep -Milliseconds 800
    }
    Write-Progress -Completed
    if ($cortado) { Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force -ErrorAction SilentlyContinue; return $null }
    $r = @(Receive-Job $job -ErrorAction SilentlyContinue)
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    if (-not $r.Count) { return $null }
    return $r[-1]
}

function Install-DriversWindowsUpdate {
    Log ''
    Log 'Windows Update (chipset Intel, ME, red, audio, Wi-Fi, video Intel y el resto de los dispositivos):' 'White'
    Log '  Buscando drivers que falten o estén viejos (1-3 min)...'
    $r = Invoke-WuJob 'buscar' @() 8 'Buscando drivers en Windows Update'
    $Global:WuVideo = @()
    if (-not $r) { Log '  Windows Update no respondió. Probar de nuevo, o desde Configuración > Windows Update > Opciones avanzadas > Actualizaciones opcionales.' 'Yellow'; return }
    if ($r.Error) { Log ('  Windows Update dio un error: {0}. Si el servicio está deshabilitado en esta PC, activarlo o instalar los drivers a mano.' -f $r.Error) 'Yellow'; return }
    $lista = @($r.Lista)
    $instalar = @()
    foreach ($u in $lista) {
        $desc = '{0}{1}' -f $u.Titulo, $(if ($u.Fecha) { " ($($u.Fecha), $($u.MB) MB)" } else { '' })
        if ($u.Clase -match 'Firmware' -or $u.Titulo -match 'Firmware|BIOS|UEFI') {
            Log ("  - {0}  -> no se instala: es firmware/BIOS, se actualiza a mano si hace falta." -f $desc) 'DarkGray'
        } elseif ($u.Clase -match 'Display' -and ($u.Fabricante + ' ' + $u.Titulo) -match 'NVIDIA|Advanced Micro Devices|AMD|ATI') {
            $Global:WuVideo += $u
            Log ("  - {0}  -> el de video se instala con el driver oficial de la marca (más nuevo)." -f $desc) 'DarkGray'
        } else {
            $instalar += $u
            Log ("  - {0}" -f $desc)
        }
    }
    if (-not $instalar.Count) { Log '  No hay drivers pendientes en Windows Update.' 'Green'; return }
    $txt = if ($instalar.Count -eq 1) { '¿Instalar este driver de Windows Update?' } else { '¿Instalar estos {0} drivers de Windows Update?' -f $instalar.Count }
    if (-not (Ask-Yes $txt $true)) { return }
    [void](Install-WuIds @($instalar | ForEach-Object { $_.Id }) 'Windows Update')
}

function Install-WuIds([string[]]$Ids, [string]$Etiqueta) {
    Log '  Bajando e instalando (puede tardar varios minutos, la pantalla puede parpadear)...'
    $r = Invoke-WuJob 'instalar' $Ids 45 'Instalando drivers de Windows Update'
    if (-not $r) { Log '  La instalación no terminó a tiempo: revisar en Configuración > Windows Update.' 'Yellow'; return 0 }
    if ($r.Error) { Log ('  Error de Windows Update: {0}' -f $r.Error) 'Yellow' }
    $ok = 0
    foreach ($x in @($r.Res)) {
        switch ([int]$x.Codigo) {
            2 { $ok++; Log ('  OK: {0}' -f $x.Titulo) 'Green' }
            3 { $ok++; Log ('  OK (con avisos): {0}' -f $x.Titulo) 'Green' }
            4 { Log ('  Falló: {0}' -f $x.Titulo) 'Yellow' }
            default { Log ('  No se instaló: {0}' -f $x.Titulo) 'Yellow' }
        }
    }
    if ($ok) { [void]$Global:DrvHechos.Add(('{0} de {1}' -f $ok, $Etiqueta)) }
    if ($r.Reinicio) { $Global:DrvReinicio = $true }
    return $ok
}

# ---------- Video: NVIDIA (servicio oficial de drivers) y AMD Radeon (instalador de AMD) ----------
function Get-NvVersion([string]$WinVer) {
    # versión de Windows 32.0.15.6121 -> versión NVIDIA 561.21
    $p = $WinVer -split '\.'
    if ($p.Count -lt 4) { return $null }
    $s = $p[2] + $p[3].PadLeft(4, '0')
    if ($s.Length -lt 5) { return $null }
    $s = $s.Substring($s.Length - 5)
    return [double]($s.Substring(0, 3) + '.' + $s.Substring(3))
}

function Get-VideoDe([string]$Pnp) {
    return @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.PNPDeviceID -eq $Pnp }) | Select-Object -First 1
}

function Test-VideoBasico($G) {
    return (-not $G -or [string]$G.Name -match 'Basic Display|Básico|Microsoft Basic' -or [int]$G.ConfigManagerErrorCode -eq 28)
}

function Find-NvProducto([string[]]$Claves, [bool]$Notebook) {
    if (-not $Global:NvProductos) {
        $t = Get-WebTexto $DrvFuentes.NvProductos
        if (-not $t) { return $null }
        $lista = New-Object System.Collections.ArrayList
        try {
            $x = New-Object System.Xml.XmlDocument
            $x.LoadXml($t.TrimStart([char]0xFEFF))
            foreach ($n in @($x.SelectNodes("//*[local-name()='LookupValue']"))) {
                $nom = [string]$n.SelectSingleNode("*[local-name()='Name']").InnerText
                [void]$lista.Add([pscustomobject]@{ Nombre = $nom; Pfid = [string]$n.SelectSingleNode("*[local-name()='Value']").InnerText; Psid = [string]$n.GetAttribute('ParentID'); Clave = (Get-GpuModelKey $nom); Note = [bool]($nom -match 'Laptop|Notebook|Mobile|Max-Q') })
            }
        } catch { return $null }
        $Global:NvProductos = $lista
    }
    foreach ($k in $Claves) {
        if (-not $k) { continue }
        $c = @($Global:NvProductos | Where-Object { $_.Clave -eq $k })
        if (-not $c.Count) { continue }
        $pref = @($c | Where-Object { $_.Note -eq $Notebook })
        if ($pref.Count) { return $pref[0] }
        return $c[0]
    }
    return $null
}

function Get-NvUltimo($Prod) {
    $os = if ([Environment]::OSVersion.Version.Build -ge 22000) { 135 } else { 57 }
    foreach ($dch in 1, 0) {
        try {
            $r = Invoke-RestMethod -Uri ($DrvFuentes.NvBuscar -f $Prod.Psid, $Prod.Pfid, $os, $dch) -UseBasicParsing -UserAgent $NavegadorUA -TimeoutSec 30 -ErrorAction Stop
            if ($r -is [string]) { $r = $r | ConvertFrom-Json }
            if ([string]$r.Success -eq '1' -and $r.IDS -and $r.IDS[0].downloadInfo.DownloadURL) {
                $d = $r.IDS[0].downloadInfo
                return [pscustomobject]@{
                    Version = [string]$d.Version
                    Url     = [string]$d.DownloadURL
                    Tam     = [uri]::UnescapeDataString([string]$d.DownloadURLFileSize)
                    Fecha   = [uri]::UnescapeDataString([string]$d.ReleaseDateTime)
                    Nombre  = [uri]::UnescapeDataString([string]$d.Name)
                }
            }
        } catch {}
    }
    return $null
}

function Install-DriverNvidia($G, [string]$Dev) {
    $pnp = [string]$G.PNPDeviceID
    $basico = Test-VideoBasico $G
    $pci = (Get-GpuDb).Dev['10de' + $Dev]
    $claves = @()
    if (-not $basico) { $claves += Get-GpuModelKey (Get-Clean $G.Name) }
    if ($pci) { $claves += @(Get-PciModelNames $pci) }
    $nombre = if (-not $basico) { Get-Clean $G.Name } elseif ($pci) { $pci } else { "NVIDIA (DEV_$Dev)" }
    Log ''
    Log ('Video NVIDIA: {0}' -f $nombre) 'White'
    $prod = Find-NvProducto $claves ([bool](($G.Name + ' ' + $pci) -match 'Laptop|Mobile|Max-Q'))
    if (-not $prod) { Log '  No se encontró el modelo en el buscador de NVIDIA (o no respondió). Bajarlo a mano de nvidia.com/drivers.' 'Yellow'; return $false }
    $ult = Get-NvUltimo $prod
    if (-not $ult) { Log '  El buscador de NVIDIA no respondió. Bajarlo a mano de nvidia.com/drivers.' 'Yellow'; return $false }
    $inst = if ($basico) { $null } else { Get-NvVersion ([string]$G.DriverVersion) }
    Log ('  Último driver oficial para {0}: {1} ({2}, {3}).' -f $prod.Nombre, $ult.Version, $ult.Fecha, $ult.Tam)
    if ($inst -and $inst -ge [double]$ult.Version) { Log ('  Al día: tiene el {0}.' -f $inst) 'Green'; return $true }
    if ($inst) {
        if (-not (Ask-Yes ('Tiene el driver {0}. ¿Actualizar al {1} ({2})?' -f $inst, $ult.Version, $ult.Tam) $false)) { return $true }
    } else {
        if (-not (Ask-Yes ('No tiene driver de video. ¿Bajar e instalar el {0} ({1})?' -f $ult.Version, $ult.Tam) $true)) { return $false }
    }
    $f = Get-InstaladorFirmado $ult.Url 'NVIDIA' $null "driver NVIDIA $($ult.Version)"
    if (-not $f) { return $false }
    $objetivo = [double]$ult.Version
    $leer = { $g2 = Get-VideoDe $pnp; if (Test-VideoBasico $g2) { $null } else { Get-NvVersion ([string]$g2.DriverVersion) } }
    Log '  Instalando en modo automático (3-8 min). La pantalla se puede poner negra o parpadear: es normal.'
    [void](Invoke-Instalador $f '-s -noreboot -noeula' 25 'Instalando driver NVIDIA')
    Start-Sleep -Seconds 3
    $v = & $leer
    if ($v -ne $objetivo) {
        # algunas versiones del paquete solo descomprimen: el instalador real queda en C:\NVIDIA\DisplayDriver
        $setup = Get-ChildItem -Path (Join-Path $env:SystemDrive ('NVIDIA\DisplayDriver\' + $ult.Version)) -Filter 'setup.exe' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($setup) { [void](Invoke-Instalador $setup.FullName '-s -noreboot -noeula' 25 'Instalando driver NVIDIA'); Start-Sleep -Seconds 3; $v = & $leer }
    }
    if ($v -ne $objetivo) {
        Log '  No se pudo instalar en modo automático: se abre el instalador de NVIDIA, seguí los pasos (Aceptar y continuar > Rápida > Siguiente).' 'Yellow'
        [void](Start-Process -FilePath $f -PassThru -ErrorAction SilentlyContinue)
        [void](Ask-Yes 'Cuando termine el instalador de NVIDIA, tocá Sí' $true)
        $v = & $leer
    }
    if ($v) {
        Log ('  Driver NVIDIA {0} instalado.' -f $v) 'Green'
        [void]$Global:DrvHechos.Add("video NVIDIA $v")
        $Global:DrvReinicio = $true
        return $true
    }
    Log '  El driver de video sigue sin cargar.' 'Yellow'
    return $false
}

function Install-DriverAmdGpu($G, [bool]$Integrada) {
    $pnp = [string]$G.PNPDeviceID
    $basico = Test-VideoBasico $G
    Log ''
    Log ('Video AMD: {0}' -f $(if ($basico) { 'sin driver (adaptador básico de Microsoft)' } else { Get-Clean $G.Name })) 'White'
    if (-not $basico) {
        Log ('  Tiene driver ({0}).' -f $G.DriverVersion) 'Green'
        if (-not (Ask-Yes '¿Abrir el instalador de AMD para buscar una versión más nueva?' $false)) { return $true }
    } elseif (-not (Ask-Yes ('No tiene driver de video{0}. ¿Bajar el instalador de AMD? Detecta la placa solo y baja el driver que corresponde (~1 GB).' -f $(if ($Integrada) { ' (gráficos integrados del Ryzen)' } else { '' })) $true)) {
        return $false
    }
    $url = Find-UrlEnPaginas $DrvFuentes.AmdGpuPaginas $DrvFuentes.AmdGpuRegex
    if (-not $url) { $url = $DrvFuentes.AmdGpuUrl; Log '  La página de AMD no respondió: se usa la última versión conocida del instalador.' 'DarkGray' }
    $f = Get-InstaladorFirmado $url 'Advanced Micro Devices' $DrvFuentes.AmdReferer 'instalador de AMD Software'
    if (-not $f) { Log '  Bajarlo a mano de amd.com/support (Auto-Detect and Install).' 'Yellow'; return $false }
    Log '  Se abre el instalador de AMD: detecta la placa y baja el driver. Tocá Instalar (si pregunta, "Solo el driver" o "Mínima").' 'Yellow'
    [void](Start-Process -FilePath $f -PassThru -ErrorAction SilentlyContinue)
    [void](Ask-Yes 'Cuando termine el instalador de AMD, tocá Sí' $true)
    $g2 = Get-VideoDe $pnp
    if (-not (Test-VideoBasico $g2)) {
        Log ('  Driver AMD {0} instalado.' -f $g2.DriverVersion) 'Green'
        if ($basico -or [string]$g2.DriverVersion -ne [string]$G.DriverVersion) { [void]$Global:DrvHechos.Add("video AMD $($g2.DriverVersion)"); $Global:DrvReinicio = $true }
        return $true
    }
    Log '  El driver de video sigue sin cargar (puede que necesite reiniciar).' 'Yellow'
    return $false
}

function Install-DriversVideo {
    $vga = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.PNPDeviceID -like 'PCI\VEN_*' })
    foreach ($g in $vga) {
        if ([string]$g.PNPDeviceID -notmatch 'VEN_([0-9A-F]{4})&DEV_([0-9A-F]{4})') { continue }
        $ven = $Matches[1].ToLower(); $dev = $Matches[2].ToLower()
        if (@('10de', '1002') -notcontains $ven) { continue }   # Intel: viene por Windows Update
        $ok = $true
        switch ($ven) {
            '10de' { $ok = Install-DriverNvidia $g $dev }
            '1002' {
                $pci = [string](Get-GpuDb).Dev['1002' + $dev]
                $integ = ([string]$g.Name -match $IntegradaRegex -and -not (Test-VideoBasico $g)) -or ($pci -and $pci -notmatch 'Radeon (RX|Pro|VII|R\d)|FirePro')
                $ok = Install-DriverAmdGpu $g ([bool]$integ)
            }
        }
        # si el oficial no se pudo, el de Windows Update (más viejo pero sirve para testear)
        if (-not $ok -and (Test-VideoBasico (Get-VideoDe ([string]$g.PNPDeviceID)))) {
            $wu = @($Global:WuVideo | Where-Object { ($_.Fabricante + ' ' + $_.Titulo) -match $(if ($ven -eq '10de') { 'NVIDIA' } else { 'Advanced Micro Devices|AMD|ATI' }) })
            if ($wu.Count -and (Ask-Yes ('¿Instalar el driver de video de Windows Update ({0})? Es más viejo pero alcanza para testear.' -f $wu[0].Titulo) $true)) {
                [void](Install-WuIds @($wu[0].Id) 'Windows Update (video)')
            }
        }
    }
}

# ---------- Lo que quedó sin driver ----------
function Show-DispositivosSinDriver {
    $sin = @()
    try { $sin = @(Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode = 28' -ErrorAction Stop) } catch {}
    Log ''
    if (-not $sin.Count) { Log 'No quedan dispositivos sin driver.' 'Green'; return }
    Log ('Siguen sin driver {0} dispositivo(s):' -f $sin.Count) 'Yellow'
    foreach ($d in $sin) {
        $hw = @($d.HardwareID) | Select-Object -First 1
        Log ('  - {0}  [{1}]' -f $(if ($d.Name) { $d.Name } else { 'Dispositivo desconocido' }), $hw) 'Yellow'
    }
    $mother = if ($Global:M.Equipo -and $Global:M.Equipo.Mother) { [string]$Global:M.Equipo.Mother } else { '' }
    Log ('  Buscarlos en la página de soporte de la mother{0} (Soporte > Drivers).' -f $(if ($mother) { " ($mother)" } else { '' }))
    if ($mother -and (Ask-Yes '¿Abrir la búsqueda de la página de soporte de la mother en el navegador?' $false)) {
        Start-Process ('https://www.google.com/search?q=' + [uri]::EscapeDataString("$mother drivers support"))
    }
}

function Clear-VerdictDetalle([string]$Area, [string]$Patron) {
    if (-not $Global:Verdicts.Contains($Area)) { return }
    $v = $Global:Verdicts[$Area]
    foreach ($d in @($v.Detalles | Where-Object { $_ -match $Patron })) { [void]$v.Detalles.Remove($d) }
    $w = 'OK'
    foreach ($d in $v.Detalles) { if ($d -match '^\[(\w+)\]' -and $Rank[$Matches[1]] -gt $Rank[$w]) { $w = $Matches[1] } }
    $v.Estado = $w
}

function Invoke-Drivers {
    Section 'DRIVERS: BUSCAR E INSTALAR'
    $t0 = Get-Date
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
    $Global:DrvHechos = New-Object System.Collections.ArrayList
    $Global:DrvReinicio = $false
    $Global:WuVideo = @()
    if (-not (Test-Internet)) { Log 'No hay internet: conectar el cable de red (o Wi-Fi) y volver a correr este paso.' 'Yellow'; return }
    Log 'Busca en las fuentes oficiales (AMD, NVIDIA y Windows Update) y verifica la firma del fabricante antes de instalar.'
    Log 'Lo que se baja queda en tools\drivers y se reusa en el próximo equipo. No toca el BIOS ni el firmware.'
    Install-ChipsetAmd
    Install-DriversWindowsUpdate
    Install-DriversVideo
    Show-DispositivosSinDriver
    # el chequeo de drivers se vuelve a hacer con lo nuevo
    Clear-VerdictDetalle 'Plataforma' 'drivers de chipset'
    Clear-VerdictDetalle 'GPU' 'falta el driver de video'
    Test-Drivers
    Log ''
    if ($Global:DrvHechos.Count) { Log ('Instalado: {0}.' -f ($Global:DrvHechos -join ', ')) 'Green' } else { Log 'No se instaló nada nuevo.' }
    if ($Global:DrvReinicio) {
        Log 'REINICIAR LA PC antes de seguir con las pruebas: algunos drivers recién se activan después de reiniciar.' 'Yellow'
    }
    Add-Prueba 'Drivers' (((Get-Date) - $t0).TotalMinutes) $(if ($Global:DrvHechos.Count) { 'Instalados' } else { 'Al día' }) $(if ($Global:DrvHechos.Count) { 'Se instaló: ' + ($Global:DrvHechos -join ', ') } else { 'Chipset y video al día' })
}

# ======================================================================
#  Chequeo, protocolo, resumen
# ======================================================================
function Invoke-Chequeo {
    $t0 = Get-Date
    Test-RaptorLake
    Test-Drivers
    Test-GpuIdentity
    $desde = if ($Global:Boot) { [datetime]$Global:Boot } else { (Get-Date).AddDays(-1) }
    Show-Eventos $desde 'EVENTOS DE HARDWARE DESDE EL ARRANQUE'
    Show-Ram
    Show-Mother
    Show-Smart
    if (Start-Sensors) { Update-SensorStats (New-SensorStats) (Read-Sensors) }
    Add-Prueba 'Chequeo general' (((Get-Date) - $t0).TotalMinutes) 'Realizado' 'Eventos de hardware, drivers, RAM, enlaces PCIe, red y SMART'
}

# Si el pendrive se desconectó o la carpeta no se puede escribir, los reportes van al Escritorio
function Confirm-OutputDir {
    $ok = $false
    try {
        if (-not (Test-Path $ReportDir)) { New-Item -ItemType Directory -Force -Path $ReportDir -ErrorAction Stop | Out-Null }
        $probe = Join-Path $ReportDir ('.w' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        [IO.File]::WriteAllText($probe, 'ok'); Remove-Item $probe -Force -ErrorAction SilentlyContinue
        $ok = $true
    } catch {}
    if ($ok) { return }
    $alt = $null
    $bases = @([Environment]::GetFolderPath('Desktop'), $(if ($env:USERPROFILE) { Join-Path $env:USERPROFILE 'Desktop' }), $env:PUBLIC, [IO.Path]::GetTempPath())
    foreach ($bse in $bases) {
        if (-not $bse) { continue }
        try {
            $cand = Join-Path $bse 'NET-TestBench-Reportes'
            New-Item -ItemType Directory -Force -Path $cand -ErrorAction Stop | Out-Null
            $alt = $cand; break
        } catch {}
    }
    if (-not $alt) { Log 'No hay ninguna carpeta donde guardar los reportes.' 'Red'; return }
    $old = $ReportDir
    $script:ReportDir = $alt
    $script:HistFile = Join-Path $alt 'historial.csv'
    $script:MarkerFile = Join-Path $alt '_prueba_en_curso.txt'
    if ($Global:ReportFile) {
        $altDet = Join-Path $alt 'detalle'
        New-Item -ItemType Directory -Force -Path $altDet -ErrorAction SilentlyContinue | Out-Null
        $Global:ReportFile = Join-Path $altDet (Split-Path -Leaf $Global:ReportFile)
        try { [IO.File]::WriteAllLines($Global:ReportFile, $Global:LogBuffer.ToArray(), (New-Object System.Text.UTF8Encoding($true))) } catch {}
    }
    $Global:OutputMoved = $true
    Log ''
    Log ("ATENCIÓN: no se puede escribir en {0} (¿se desconectó el pendrive?). Los reportes se guardan en {1}" -f $old, $alt) 'Yellow'
}

function Show-Resumen {
    Confirm-OutputDir
    Section 'RESUMEN'
    $peor = 'OK'
    foreach ($k in $Global:Verdicts.Keys) {
        $v = $Global:Verdicts[$k]
        $col = switch ($v.Estado) { 'FALLA' { 'Red' } 'ATENCION' { 'Yellow' } default { 'Green' } }
        Log ("{0,-12} {1}" -f $k, $v.Estado) $col
        foreach ($d in $v.Detalles) { Log ("     " + $d) $col }
        if ($Rank[$v.Estado] -gt $Rank[$peor]) { $peor = $v.Estado }
    }
    Log ''
    switch ($peor) {
        'FALLA' { Log 'RESULTADO: NO APTO / REVISAR - hay al menos una falla.' 'Red' }
        'ATENCION' { Log 'RESULTADO: APTO CON OBSERVACIONES - revisar los puntos en amarillo.' 'Yellow' }
        default { Log 'RESULTADO: SIN FALLAS DETECTADAS en las pruebas automáticas.' 'Green' }
    }
    if ($Global:Pendientes.Count) {
        Log ''
        Log 'Pruebas manuales / complementarias pendientes:' 'White'
        foreach ($p in $Global:Pendientes) { Log ("  [ ] " + $p) }
    }
    Save-Historial
    $Global:InformeHtml = Export-Informe
    Log ''
    Log ("Reporte técnico: {0}" -f $Global:ReportFile) 'White'
    if ($Global:InformePdf) { Log ("Informe para el cliente (PDF): {0}" -f $Global:InformePdf) 'White' }
    elseif ($Global:InformeHtml) { Log ("Informe para el cliente: {0}" -f $Global:InformeHtml) 'White' }
}

function Get-InformeParaAbrir {
    if ($Global:InformePdf -and (Test-Path $Global:InformePdf)) { return $Global:InformePdf }
    return $Global:InformeHtml
}

function Open-Informe {
    if ($Global:InformeHtml -and (Test-Path $Global:InformeHtml)) {
        if (Ask-Yes 'Abrir el informe para el cliente' $true) { Start-Process (Get-InformeParaAbrir) }
    }
    if (Ask-Yes 'Abrir el reporte técnico (txt)' $false) { Start-Process notepad.exe $Global:ReportFile }
}

function Invoke-Protocolo {
    Section 'PROTOCOLO COMPLETO'
    Log 'Antes de arrancar: BIOS en defaults (sin PBO/OC/undervolt), XMP/EXPO apagado, monitor de temperaturas abierto.' 'Yellow'
    $allMin = Ask-Int 'Minutos de stress all-core' 15 1 600
    $perSec = Ask-Int 'Segundos por CPU lógico en el test por núcleo (20 rápido / 45 normal / 180 profundo)' 45 5 3600
    $hayDedicada = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $DedicadaRegex }).Count -gt 0
    $doGpu = Ask-Yes '¿Incluir prueba de video (VRAM + stress de GPU 10 min)?' $hayDedicada
    $doFill = Ask-Yes '¿Incluir escritura+verificación de un disco (se elige al final)?' $false
    $t0 = Get-Date
    Invoke-Chequeo
    Show-Smart -SelfTest
    Invoke-CpuAllCore $allMin
    Invoke-CpuPerCore $perSec
    if ($doGpu) { Invoke-VramTest; Invoke-GpuStress 10 }
    Show-Eventos $t0 'EVENTOS DE HARDWARE DURANTE EL PROTOCOLO'
    if ($doFill) { Invoke-DiskFill }
    Add-Pendiente 'CPU: complementar con Prime95 Small FFT (calor y AVX) 30-60 min o CoreCycler, desde la opción 7 (los abre y lee sus errores).'
    Show-Resumen
}

function Show-Menu {
    Write-Host ''
    Write-Host '  NET Gaming - Banco de pruebas' -ForegroundColor Cyan
    Write-Host '  ---------------------------------------------------------------'
    Write-Host '   1) Chequeo de salud (eventos, RAM/slots, PCIe, dispositivos, SMART)  ~1 min'
    Write-Host '   D) Drivers: buscar e instalar solos (chipset AMD, NVIDIA, Radeon, Windows Update)'
    Write-Host '   2) CPU: todos los núcleos con verificación de resultados'
    Write-Host '   3) CPU: test por núcleo (uno por uno, al boost máximo)'
    Write-Host '   4) Discos: SMART + autotest corto (smartctl)                      ~3 min'
    Write-Host '   5) Disco: lectura de superficie (no destructivo)'
    Write-Host '   6) Disco: escritura + verificación en espacio libre'
    Write-Host '   7) Prueba externa con vigilancia: Prime95 / y-cruncher / CoreCycler / TM5 / OCCT'
    Write-Host '   G) Video: identidad de la placa + memoria (VRAM) + stress de GPU con verificación'
    Write-Host '   F) Fuente: CPU + GPU al 100% juntos (apagones, reinicios, errores, 12 V)'
    Write-Host '   R) RAM: TestMem5 automático (config según DDR4/DDR5, resultado leído solo)'
    Write-Host '   E) Enviar el informe a otra PC (tu PC o la pantalla del mostrador)'
    Write-Host '   8) Protocolo completo (1 + 4 + 2 + 3 + eventos, + video opcional)'
    Write-Host '   H) Herramientas: descargar / abrir Prime95, CoreCycler, y-cruncher, LibreHardwareMonitor'
    Write-Host '   9) Resumen, informe para el cliente y salir'
    Write-Host ''
}

# Técnicos: un nombre por línea en tecnicos.txt (al lado del script).
# Con un solo nombre se usa directo; con varios se elige de una lista.
$TecnicosFile = Join-Path $Root 'tecnicos.txt'

function Get-Tecnicos {
    if (-not (Test-Path $TecnicosFile)) {
        try { "Nehuen" | Set-Content -Path $TecnicosFile -Encoding UTF8 } catch {}
    }
    return @(Get-Content -Path $TecnicosFile -Encoding UTF8 -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') } | Select-Object -Unique)
}

function Select-Tecnico {
    $list = @(Get-Tecnicos)
    if ($list.Count -eq 0) { return '' }
    if ($list.Count -eq 1) { return $list[0] }
    $lastFile = Join-Path $ReportDir '.ultimo_tecnico'
    $last = ''
    if (Test-Path $lastFile) { $last = (Get-Content -Path $lastFile -Raw -ErrorAction SilentlyContinue).Trim() }
    $def = [math]::Max(1, [array]::IndexOf($list, $last) + 1)
    Write-Host ''
    for ($i = 0; $i -lt $list.Count; $i++) { Write-Host ("   {0}) {1}" -f ($i + 1), $list[$i]) }
    $n = Ask-Int 'Técnico' $def 1 $list.Count
    $tec = $list[$n - 1]
    try { New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null; $tec | Set-Content -Path $lastFile -Encoding UTF8 } catch {}
    return $tec
}

function Main {
    Clear-Host
    Write-Host ("NET Gaming - Banco de pruebas v{0}" -f $Version) -ForegroundColor Cyan
    if (-not [Environment]::Is64BitProcess) { Write-Host 'Atención: PowerShell de 32 bits. Usá el de 64 bits (Iniciar-TestBench.bat).' -ForegroundColor Yellow }
    Test-PreviousSession
    Initialize-Tools
    $Global:Cpu = Get-CpuInfo
    $pre = Get-PrefijoOrden
    $etq = Format-Orden (Read-Host ("Orden ({0}: solo los números) o etiqueta del equipo (Enter para omitir)" -f $(if ($pre) { $pre } else { 'sin prefijo' })))
    $esBanco = Get-EsBanco
    if (Ask-Yes '¿Es una placa de video suelta (esta PC es el banco de pruebas)?' $esBanco) {
        $Global:M.Suelta = $true
        $Global:M.Pieza = Format-Pieza (Read-Host 'Últimos 4 o 5 dígitos del N.º de serie de la placa (Enter para omitir)')
        $sug = Get-UltimoGrupo
        $gr = Read-Host ("¿Va junto con otro ticket del mismo cliente? Ticket de la primera placa{0} (Enter = no, va sola o es la primera)" -f $(if ($sug) { " [la anterior fue del grupo $sug]" } else { '' }))
        $Global:M.Grupo = Format-Grupo $gr $etq
        Set-UltimoGrupo $(if ($Global:M.Grupo) { $Global:M.Grupo } else { $etq })
    }
    Set-EsBanco ([bool]$Global:M.Suelta)
    $tec = Select-Tecnico
    $Global:M.Orden = $etq
    $Global:M.Tecnico = $tec
    Start-Report $etq
    if ($tec) { Log ("Técnico: {0}" -f $tec) }
    Show-Inventario
    switch ($Modo) {
        'Rapido' { Invoke-Chequeo; Show-Resumen; Open-Informe; return }
        'Protocolo' { Invoke-Protocolo; Open-Informe; return }
    }
    while ($true) {
        Show-Menu
        $op = Read-Host 'Opción'
        switch ($op.Trim()) {
            '1' { Invoke-Chequeo }
            '2' { Invoke-CpuAllCore (Ask-Int 'Minutos' 15 1 600) }
            '3' { Invoke-CpuPerCore (Ask-Int 'Segundos por CPU lógico (20 rápido / 45 normal / 180 profundo)' 45 5 3600) }
            '4' { Show-Smart -SelfTest }
            '5' { Invoke-DiskRead }
            '6' { Invoke-DiskFill }
            '7' { Watch-Externo }
            '8' { Invoke-Protocolo; Read-Host 'Enter para volver al menú' | Out-Null }
            { $_ -match '^[hH]$' } { Show-Herramientas }
            { $_ -match '^[gG]$' } { Invoke-GpuTest }
            { $_ -match '^[dD]$' } { Invoke-Drivers }
            { $_ -match '^[fF]$' } { Invoke-PruebaFuente (Ask-Int 'Minutos' 10 1 120) }
            { $_ -match '^[rR]$' } { Invoke-TestMem5 (Ask-Int 'Minutos mínimos' 30 5 1440) 'auto' }
            { $_ -match '^[eE]$' } { Invoke-EnvioConsola }
            '9' { Show-Resumen; Open-Informe; return }
            default { Write-Host 'Opción inválida.' -ForegroundColor Yellow }
        }
    }
}

if ($CargarSolo) { return }

if ($IsWin) {
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) {
        Write-Host 'Hace falta correr como administrador. Reabriendo elevado...' -ForegroundColor Yellow
        try {
            Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath), '-Modo', $Modo)
        } catch { Write-Host 'No se pudo elevar. Abrí Iniciar-TestBench.bat con clic derecho > Ejecutar como administrador.' -ForegroundColor Red; Read-Host }
        return
    }
}

try {
    if ($Modo -eq 'UI') { Start-UiMode } else { Main }
} catch {
    Write-Host ("Error inesperado: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    if ($Global:ReportFile) { Add-Content -Path $Global:ReportFile -Encoding UTF8 -Value ("ERROR DEL SCRIPT: {0}" -f $_.Exception.Message) }
    Read-Host 'Enter para salir'
}
