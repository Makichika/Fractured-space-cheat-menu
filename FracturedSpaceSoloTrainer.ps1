# Fractured Space SOLO Trainer - allied + enemy team manager FIX13
# Targets only the local spserver.exe process.

param(
    [switch]$DebugConsole
)

$script:DebugConsoleEnabled = [bool]$DebugConsole

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$nativeCode = @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading.Tasks;

public static class NativeMemoryV4
{
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, int dwProcessId);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool ReadProcessMemory(
        IntPtr hProcess,
        IntPtr lpBaseAddress,
        [Out] byte[] lpBuffer,
        int dwSize,
        out IntPtr lpNumberOfBytesRead);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool WriteProcessMemory(
        IntPtr hProcess,
        IntPtr lpBaseAddress,
        byte[] lpBuffer,
        int nSize,
        out IntPtr lpNumberOfBytesWritten);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool CloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll", SetLastError = true, ExactSpelling = true)]
    public static extern IntPtr VirtualAllocEx(
        IntPtr hProcess, IntPtr lpAddress, UIntPtr dwSize, uint flAllocationType, uint flProtect);

    [DllImport("kernel32.dll", SetLastError = true, ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool VirtualFreeEx(
        IntPtr hProcess, IntPtr lpAddress, UIntPtr dwSize, uint dwFreeType);

    [DllImport("kernel32.dll", SetLastError = true, ExactSpelling = true)]
    public static extern IntPtr CreateRemoteThread(
        IntPtr hProcess, IntPtr lpThreadAttributes, UIntPtr dwStackSize,
        IntPtr lpStartAddress, IntPtr lpParameter, uint dwCreationFlags, out uint lpThreadId);

    [DllImport("kernel32.dll", SetLastError = true, ExactSpelling = true)]
    public static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

    [DllImport("kernel32.dll", SetLastError = true, ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool FlushInstructionCache(IntPtr hProcess, IntPtr lpBaseAddress, UIntPtr dwSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern UIntPtr VirtualQueryEx(
        IntPtr hProcess,
        IntPtr lpAddress,
        out MEMORY_BASIC_INFORMATION lpBuffer,
        UIntPtr dwLength);

    [StructLayout(LayoutKind.Sequential)]
    public struct MEMORY_BASIC_INFORMATION
    {
        public IntPtr BaseAddress;
        public IntPtr AllocationBase;
        public uint AllocationProtect;
        public UIntPtr RegionSize;
        public uint State;
        public uint Protect;
        public uint Type;
    }

    const uint MEM_COMMIT = 0x1000;
    const uint MEM_PRIVATE = 0x20000;
    const uint PAGE_NOACCESS = 0x01;
    const uint PAGE_GUARD = 0x100;

    static bool IsReadablePrivate(MEMORY_BASIC_INFORMATION mbi)
    {
        if (mbi.State != MEM_COMMIT || mbi.Type != MEM_PRIVATE)
            return false;
        if ((mbi.Protect & PAGE_GUARD) != 0 || (mbi.Protect & PAGE_NOACCESS) != 0)
            return false;
        uint p = mbi.Protect & 0xff;
        return p == 0x02 || p == 0x04 || p == 0x08 || p == 0x20 || p == 0x40 || p == 0x80;
    }

    static bool ReadU64Internal(IntPtr hProcess, ulong address, out ulong value)
    {
        value = 0;
        byte[] b = new byte[8];
        IntPtr got;
        if (!ReadProcessMemory(hProcess, new IntPtr(unchecked((long)address)), b, 8, out got) || got.ToInt64() != 8)
            return false;
        value = BitConverter.ToUInt64(b, 0);
        return true;
    }

    static bool ReadByteInternal(IntPtr hProcess, ulong address, out byte value)
    {
        value = 0;
        byte[] b = new byte[1];
        IntPtr got;
        if (!ReadProcessMemory(hProcess, new IntPtr(unchecked((long)address)), b, 1, out got) || got.ToInt64() != 1)
            return false;
        value = b[0];
        return true;
    }

    static bool MatchesU64(byte[] b, int i, ulong v)
    {
        if (i < 0 || i + 8 > b.Length) return false;
        return b[i]     == (byte)(v) &&
               b[i + 1] == (byte)(v >> 8) &&
               b[i + 2] == (byte)(v >> 16) &&
               b[i + 3] == (byte)(v >> 24) &&
               b[i + 4] == (byte)(v >> 32) &&
               b[i + 5] == (byte)(v >> 40) &&
               b[i + 6] == (byte)(v >> 48) &&
               b[i + 7] == (byte)(v >> 56);
    }

    static bool IsValidPlayerStateBasic(IntPtr hProcess, ulong candidate, ulong classPtr)
    {
        if (candidate < 0x10000UL) return false;

        ulong classCheck;
        if (!ReadU64Internal(hProcess, candidate + 0x10UL, out classCheck) || classCheck != classPtr)
            return false;

        byte team;
        if (!ReadByteInternal(hProcess, candidate + 0x590UL, out team) || team > 16)
            return false;

        // Do not require PlayerState.Owner here. In this game that link can be
        // temporarily null/stale even for a perfectly live bot. Live filtering
        // is done later by resolving Controller/Pawn/HealthComponent instead.

        return true;
    }

    static long[] CollectPlayerStateCluster(IntPtr hProcess, ulong referenceAddress, ulong localPlayerState, ulong classPtr)
    {
        const int radiusSlots = 64;
        ulong bytesBefore = (ulong)(radiusSlots * 8);
        ulong start = referenceAddress > bytesBefore ? referenceAddress - bytesBefore : 0x10000UL;
        start &= ~7UL;
        int byteCount = (radiusSlots * 2 + 1) * 8;

        byte[] block = new byte[byteCount];
        IntPtr got;
        if (!ReadProcessMemory(hProcess, new IntPtr(unchecked((long)start)), block, block.Length, out got))
            return new long[0];

        int n = (int)Math.Min((long)block.Length, got.ToInt64());
        HashSet<long> found = new HashSet<long>();

        for (int i = 0; i <= n - 8; i += 8)
        {
            ulong candidate = BitConverter.ToUInt64(block, i);
            if (candidate < 0x10000UL) continue;
            if (IsValidPlayerStateBasic(hProcess, candidate, classPtr))
                found.Add(unchecked((long)candidate));
        }

        if (!found.Contains(unchecked((long)localPlayerState)) || found.Count < 2)
            return new long[0];

        long[] result = new long[found.Count];
        found.CopyTo(result);
        return result;
    }

    static long[] FindPlayerStatesFast(IntPtr hProcess, ulong localPlayerState, ulong classPtr, int maxSeconds)
    {
        if (hProcess == IntPtr.Zero || localPlayerState < 0x10000UL || classPtr < 0x10000UL)
            return new long[0];

        Stopwatch sw = Stopwatch.StartNew();
        int mbiSize = Marshal.SizeOf(typeof(MEMORY_BASIC_INFORMATION));
        const int chunkSize = 4 * 1024 * 1024;
        const ulong maxAddress = 0x00007fffffff0000UL;
        const ulong radius = 8UL * 1024UL * 1024UL * 1024UL;
        const ulong centerRadius = 1UL * 1024UL * 1024UL * 1024UL;

        ulong rangeStart = localPlayerState > radius ? localPlayerState - radius : 0x10000UL;
        ulong rangeEnd = localPlayerState + radius;
        if (rangeEnd < localPlayerState || rangeEnd > maxAddress) rangeEnd = maxAddress;
        rangeStart &= ~0xFFFUL;

        ulong centerStart = localPlayerState > centerRadius ? localPlayerState - centerRadius : rangeStart;
        if (centerStart < rangeStart) centerStart = rangeStart;
        centerStart &= ~0xFFFUL;
        ulong centerEnd = localPlayerState + centerRadius;
        if (centerEnd < localPlayerState || centerEnd > rangeEnd) centerEnd = rangeEnd;

        byte firstLocal = (byte)localPlayerState;
        byte firstClass = (byte)classPtr;
        HashSet<long> classCandidates = new HashSet<long>();
        classCandidates.Add(unchecked((long)localPlayerState));

        Action<ulong, ulong> scanRange = (scanRangeStart, scanRangeEnd) =>
        {
            ulong address = scanRangeStart;
            while (address < scanRangeEnd && sw.Elapsed.TotalSeconds < maxSeconds)
            {
                MEMORY_BASIC_INFORMATION mbi;
                UIntPtr q = VirtualQueryEx(hProcess, new IntPtr(unchecked((long)address)), out mbi, new UIntPtr((uint)mbiSize));
                if (q == UIntPtr.Zero) break;

                ulong regionBase = unchecked((ulong)mbi.BaseAddress.ToInt64());
                ulong regionSize = mbi.RegionSize.ToUInt64();
                if (regionSize == 0) break;
                ulong regionEnd = regionBase + regionSize;
                if (regionEnd <= regionBase) break;

                ulong readStart = Math.Max(regionBase, scanRangeStart);
                ulong readEnd = Math.Min(regionEnd, scanRangeEnd);

                if (readEnd > readStart && IsReadablePrivate(mbi))
                {
                    ulong cur = readStart;
                    while (cur < readEnd && sw.Elapsed.TotalSeconds < maxSeconds)
                    {
                        int want = (int)Math.Min((ulong)chunkSize, readEnd - cur);
                        byte[] buffer = new byte[want];
                        IntPtr got;

                        if (ReadProcessMemory(hProcess, new IntPtr(unchecked((long)cur)), buffer, want, out got))
                        {
                            int n = (int)Math.Min((long)want, got.ToInt64());

                            int pos = 0;
                            while (pos <= n - 8)
                            {
                                int remaining = n - pos;
                                int idx = Array.IndexOf<byte>(buffer, firstLocal, pos, remaining);
                                if (idx < 0 || idx > n - 8) break;

                                ulong absolute = cur + (ulong)idx;
                                if ((absolute & 7UL) == 0 && MatchesU64(buffer, idx, localPlayerState))
                                {
                                    long[] cluster = CollectPlayerStateCluster(hProcess, absolute, localPlayerState, classPtr);
                                    if (cluster.Length >= 2)
                                    {
                                        foreach (long item in cluster)
                                            classCandidates.Add(item);
                                    }
                                }
                                pos = idx + 1;
                            }

                            pos = 0;
                            while (pos <= n - 8 && classCandidates.Count < 1024)
                            {
                                int remaining = n - pos;
                                int idx = Array.IndexOf<byte>(buffer, firstClass, pos, remaining);
                                if (idx < 0 || idx > n - 8) break;

                                ulong absolute = cur + (ulong)idx;
                                if ((absolute & 7UL) == 0 && MatchesU64(buffer, idx, classPtr) && absolute >= 0x10UL)
                                {
                                    ulong candidate = absolute - 0x10UL;
                                    if ((candidate & 7UL) == 0 && IsValidPlayerStateBasic(hProcess, candidate, classPtr))
                                        classCandidates.Add(unchecked((long)candidate));
                                }
                                pos = idx + 1;
                            }
                        }

                        cur += (ulong)want;
                    }
                }

                address = regionEnd > address ? regionEnd : address + 0x1000UL;
            }
        };

        // Scan around the live local PlayerState first. This makes short/quiet
        // refreshes useful, then expand outward only if time remains.
        scanRange(centerStart, centerEnd);
        if (sw.Elapsed.TotalSeconds < maxSeconds && rangeStart < centerStart)
            scanRange(rangeStart, centerStart);
        if (sw.Elapsed.TotalSeconds < maxSeconds && centerEnd < rangeEnd)
            scanRange(centerEnd, rangeEnd);

        long[] result = new long[classCandidates.Count];
        classCandidates.CopyTo(result);
        return result;
    }

    public static Task<long[]> StartFindPlayerStatesFast(IntPtr hProcess, ulong localPlayerState, ulong classPtr, int maxSeconds)
    {
        return Task.Run(() => FindPlayerStatesFast(hProcess, localPlayerState, classPtr, maxSeconds));
    }

    public static int LastSpawnError = 0;

    static void PutU64(byte[] b, int off, ulong value)
    {
        byte[] x = BitConverter.GetBytes(value);
        Buffer.BlockCopy(x, 0, b, off, 8);
    }

    static void PutI32(byte[] b, int off, int value)
    {
        byte[] x = BitConverter.GetBytes(value);
        Buffer.BlockCopy(x, 0, b, off, 4);
    }

    static void PutFString(byte[] payload, int structOff, int stringOff, ulong remoteBase, string value)
    {
        if (String.IsNullOrEmpty(value))
            return;

        byte[] text = System.Text.Encoding.Unicode.GetBytes(value + "\0");
        Buffer.BlockCopy(text, 0, payload, stringOff, text.Length);
        PutU64(payload, structOff, remoteBase + (ulong)stringOff);
        PutI32(payload, structOff + 8, value.Length + 1);
        PutI32(payload, structOff + 12, value.Length + 1);
    }

    static void EmitU64(List<byte> code, ulong value)
    {
        code.AddRange(BitConverter.GetBytes(value));
    }

    public static long SpawnBotNative(
        IntPtr hProcess,
        ulong moduleBase,
        ulong worldContextObject,
        byte teamId,
        byte difficulty,
        string botName,
        string layoutName)
    {
        LastSpawnError = 0;
        if (hProcess == IntPtr.Zero || moduleBase < 0x10000UL || worldContextObject < 0x10000UL)
        {
            LastSpawnError = 100;
            return 0;
        }

        if (botName == null) botName = "TrainerBot";
        if (layoutName == null) layoutName = "";
        if (botName.Length > 96) botName = botName.Substring(0, 96);
        if (layoutName.Length > 160) layoutName = layoutName.Substring(0, 160);

        // Build guard for the supplied spserver.exe: ServerSpawnBot RVA 0x356040.
        byte[] signature = new byte[8];
        IntPtr sigRead;
        IntPtr spawnAddressForCheck = new IntPtr(unchecked((long)(moduleBase + 0x00356040UL)));
        if (!ReadProcessMemory(hProcess, spawnAddressForCheck, signature, signature.Length, out sigRead) ||
            sigRead.ToInt64() != signature.Length ||
            signature[0] != 0x48 || signature[1] != 0x89 || signature[2] != 0x6C || signature[3] != 0x24 ||
            signature[4] != 0x10 || signature[5] != 0x48 || signature[6] != 0x89 || signature[7] != 0x74)
        {
            LastSpawnError = 10;
            return 0;
        }

        const uint MEM_COMMIT_RESERVE = 0x3000;
        const uint MEM_RELEASE = 0x8000;
        const uint PAGE_EXECUTE_READWRITE = 0x40;
        const uint WAIT_OBJECT_0 = 0x00000000;
        const uint WAIT_TIMEOUT = 0x00000102;
        const int blockSize = 0x1000;
        const int nameF = 0x100;
        const int layoutF = 0x110;
        const int materialF = 0x120;
        const int resultOff = 0x130;
        const int nameText = 0x200;
        const int layoutText = 0x400;

        IntPtr remote = VirtualAllocEx(hProcess, IntPtr.Zero, new UIntPtr((uint)blockSize), MEM_COMMIT_RESERVE, PAGE_EXECUTE_READWRITE);
        if (remote == IntPtr.Zero)
        {
            LastSpawnError = 1;
            return 0;
        }

        bool safeToFree = true;
        IntPtr thread = IntPtr.Zero;
        try
        {
            ulong rb = unchecked((ulong)remote.ToInt64());
            byte[] payload = new byte[blockSize];
            PutFString(payload, nameF, nameText, rb, botName);
            PutFString(payload, layoutF, layoutText, rb, layoutName);
            // Material modifier intentionally left as an empty FString.

            ulong spawnFunction = moduleBase + 0x00356040UL;
            List<byte> code = new List<byte>();

            // Windows x64 ABI: 32 bytes shadow space + 2 stack args; maintain 16-byte alignment.
            code.AddRange(new byte[] { 0x48, 0x83, 0xEC, 0x38 });                 // sub rsp,38
            code.AddRange(new byte[] { 0x48, 0xB9 }); EmitU64(code, worldContextObject); // mov rcx, world
            code.AddRange(new byte[] { 0x48, 0xBA }); EmitU64(code, rb + nameF);          // mov rdx, &Name
            code.AddRange(new byte[] { 0x49, 0xB8 }); EmitU64(code, rb + layoutF);        // mov r8, &Layout
            code.AddRange(new byte[] { 0x41, 0xB9 }); code.AddRange(BitConverter.GetBytes((uint)teamId)); // mov r9d,team
            code.AddRange(new byte[] { 0xC6, 0x44, 0x24, 0x20, difficulty });             // [rsp+20]=difficulty
            code.AddRange(new byte[] { 0x48, 0xB8 }); EmitU64(code, rb + materialF);      // rax=&Material
            code.AddRange(new byte[] { 0x48, 0x89, 0x44, 0x24, 0x28 });                   // [rsp+28]=rax
            code.AddRange(new byte[] { 0x48, 0xB8 }); EmitU64(code, spawnFunction);       // rax=ServerSpawnBot
            code.AddRange(new byte[] { 0xFF, 0xD0 });                                     // call rax
            code.AddRange(new byte[] { 0x48, 0xBA }); EmitU64(code, rb + resultOff);      // rdx=&result
            code.AddRange(new byte[] { 0x48, 0x89, 0x02 });                               // [rdx]=rax
            code.AddRange(new byte[] { 0x31, 0xC0 });                                     // xor eax,eax
            code.AddRange(new byte[] { 0x48, 0x83, 0xC4, 0x38, 0xC3 });                   // add rsp,38; ret

            if (code.Count >= nameF)
            {
                LastSpawnError = 2;
                return 0;
            }
            Buffer.BlockCopy(code.ToArray(), 0, payload, 0, code.Count);

            IntPtr wrote;
            if (!WriteProcessMemory(hProcess, remote, payload, payload.Length, out wrote) || wrote.ToInt64() != payload.Length)
            {
                LastSpawnError = 3;
                return 0;
            }
            FlushInstructionCache(hProcess, remote, new UIntPtr((uint)code.Count));

            uint threadId;
            thread = CreateRemoteThread(hProcess, IntPtr.Zero, UIntPtr.Zero, remote, IntPtr.Zero, 0, out threadId);
            if (thread == IntPtr.Zero)
            {
                LastSpawnError = 4;
                return 0;
            }

            uint wait = WaitForSingleObject(thread, 8000);
            if (wait == WAIT_TIMEOUT)
            {
                // Do not free the executable buffer while the remote thread might still use it.
                safeToFree = false;
                LastSpawnError = 5;
                return 0;
            }
            if (wait != WAIT_OBJECT_0)
            {
                safeToFree = false;
                LastSpawnError = 6;
                return 0;
            }

            byte[] result = new byte[8];
            IntPtr got;
            IntPtr resultAddress = new IntPtr(unchecked((long)(rb + resultOff)));
            if (!ReadProcessMemory(hProcess, resultAddress, result, 8, out got) || got.ToInt64() != 8)
            {
                LastSpawnError = 7;
                return 0;
            }

            ulong controller = BitConverter.ToUInt64(result, 0);
            if (controller < 0x10000UL)
            {
                LastSpawnError = 8;
                return 0;
            }
            return unchecked((long)controller);
        }
        catch
        {
            LastSpawnError = 9;
            return 0;
        }
        finally
        {
            if (thread != IntPtr.Zero)
                CloseHandle(thread);
            if (safeToFree && remote != IntPtr.Zero)
                VirtualFreeEx(hProcess, remote, UIntPtr.Zero, MEM_RELEASE);
        }
    }

    static int EmitJzRel32(List<byte> code)
    {
        code.Add(0x0F); code.Add(0x84);
        int immPos = code.Count;
        code.AddRange(new byte[4]);
        return immPos;
    }

    static int EmitJnzRel32(List<byte> code)
    {
        code.Add(0x0F); code.Add(0x85);
        int immPos = code.Count;
        code.AddRange(new byte[4]);
        return immPos;
    }

    static void PatchRel32(List<byte> code, int immPos, int targetPos)
    {
        int rel = targetPos - (immPos + 4);
        byte[] b = BitConverter.GetBytes(rel);
        for (int i = 0; i < 4; i++) code[immPos + i] = b[i];
    }

    static bool TryParseGuid32(string text, out uint a, out uint b, out uint c, out uint d)
    {
        a = b = c = d = 0;
        if (String.IsNullOrWhiteSpace(text)) return false;
        string g = text.Replace("-", "").Trim();
        if (g.Length != 32) return false;
        try
        {
            a = Convert.ToUInt32(g.Substring(0, 8), 16);
            b = Convert.ToUInt32(g.Substring(8, 8), 16);
            c = Convert.ToUInt32(g.Substring(16, 8), 16);
            d = Convert.ToUInt32(g.Substring(24, 8), 16);
            return true;
        }
        catch { return false; }
    }

    static void EmitMovDwordAtRcx(List<byte> code, int displacement, uint value)
    {
        code.AddRange(new byte[] { 0xC7, 0x81 });
        code.AddRange(BitConverter.GetBytes(displacement));
        code.AddRange(BitConverter.GetBytes(value));
    }

    static void EmitCmpDwordAtRcx(List<byte> code, int displacement, uint value)
    {
        code.AddRange(new byte[] { 0x81, 0xB9 });
        code.AddRange(BitConverter.GetBytes(displacement));
        code.AddRange(BitConverter.GetBytes(value));
    }

    // Build-specific local/offline selected-ship path:
    // create a normal BotController, ask the game's own PlayerState setter to
    // validate/apply desiredShipGUID, then spawn the pawn through ServerSpawnBotShip.
    public static long SpawnBotByGuidNative(
        IntPtr hProcess,
        ulong moduleBase,
        ulong worldContextObject,
        byte teamId,
        byte difficulty,
        string botName,
        string shipGuid)
    {
        LastSpawnError = 0;
        if (hProcess == IntPtr.Zero || moduleBase < 0x10000UL || worldContextObject < 0x10000UL)
        {
            LastSpawnError = 100;
            return 0;
        }

        uint ga, gb, gc, gd;
        if (!TryParseGuid32(shipGuid, out ga, out gb, out gc, out gd))
        {
            LastSpawnError = 11;
            return 0;
        }

        if (botName == null) botName = "TrainerBot";
        if (botName.Length > 96) botName = botName.Substring(0, 96);

        // Guards for the exact supplied spserver.exe build.
        byte[] sigCreate = new byte[8];
        byte[] sigSetter = new byte[8];
        byte[] sigShip = new byte[6];
        IntPtr got1, got2, got3;
        if (!ReadProcessMemory(hProcess, new IntPtr(unchecked((long)(moduleBase + 0x00358EB0UL))), sigCreate, sigCreate.Length, out got1) ||
            got1.ToInt64() != sigCreate.Length ||
            sigCreate[0] != 0x48 || sigCreate[1] != 0x83 || sigCreate[2] != 0xEC || sigCreate[3] != 0x38 ||
            sigCreate[4] != 0x48 || sigCreate[5] != 0x8B || sigCreate[6] != 0x81 || sigCreate[7] != 0xE0 ||
            !ReadProcessMemory(hProcess, new IntPtr(unchecked((long)(moduleBase + 0x0052FC70UL))), sigSetter, sigSetter.Length, out got2) ||
            got2.ToInt64() != sigSetter.Length ||
            sigSetter[0] != 0x48 || sigSetter[1] != 0x89 || sigSetter[2] != 0x5C || sigSetter[3] != 0x24 ||
            sigSetter[4] != 0x08 || sigSetter[5] != 0x48 || sigSetter[6] != 0x89 || sigSetter[7] != 0x6C ||
            !ReadProcessMemory(hProcess, new IntPtr(unchecked((long)(moduleBase + 0x00356100UL))), sigShip, sigShip.Length, out got3) ||
            got3.ToInt64() != sigShip.Length ||
            sigShip[0] != 0x40 || sigShip[1] != 0x57 || sigShip[2] != 0x48 || sigShip[3] != 0x83 || sigShip[4] != 0xEC || sigShip[5] != 0x20)
        {
            LastSpawnError = 12;
            return 0;
        }

        const uint MEM_COMMIT_RESERVE = 0x3000;
        const uint MEM_RELEASE = 0x8000;
        const uint PAGE_EXECUTE_READWRITE = 0x40;
        const uint WAIT_OBJECT_0 = 0x00000000;
        const uint WAIT_TIMEOUT = 0x00000102;
        const int blockSize = 0x1000;
        const int resultOff = 0x220;
        const int guidOff = 0x240;
        const int nameF = 0x280;
        const int nameText = 0x300;

        IntPtr remote = VirtualAllocEx(hProcess, IntPtr.Zero, new UIntPtr((uint)blockSize), MEM_COMMIT_RESERVE, PAGE_EXECUTE_READWRITE);
        if (remote == IntPtr.Zero)
        {
            LastSpawnError = 1;
            return 0;
        }

        bool safeToFree = true;
        IntPtr thread = IntPtr.Zero;
        try
        {
            ulong rb = unchecked((ulong)remote.ToInt64());
            byte[] payload = new byte[blockSize];
            PutFString(payload, nameF, nameText, rb, botName);
            PutI32(payload, guidOff + 0, unchecked((int)ga));
            PutI32(payload, guidOff + 4, unchecked((int)gb));
            PutI32(payload, guidOff + 8, unchecked((int)gc));
            PutI32(payload, guidOff + 12, unchecked((int)gd));

            ulong gEnginePtr = moduleBase + 0x035C50E0UL;
            ulong getWorldFromContext = moduleBase + 0x016919E0UL;
            ulong worldAuthorityCheck = moduleBase + 0x016D9AB0UL;
            ulong getAuthGameMode = moduleBase + 0x002738B0UL;
            ulong createBotPlayerDefault = moduleBase + 0x00358EB0UL;
            ulong setDesiredShipGuid = moduleBase + 0x0052FC70UL;
            ulong spawnBotShip = moduleBase + 0x00356100UL;

            List<byte> code = new List<byte>();
            List<int> failJumps = new List<int>();
            List<int> guidFailJumps = new List<int>();

            code.Add(0x53);                                                   // push rbx
            code.AddRange(new byte[] { 0x48, 0x83, 0xEC, 0x20 });             // sub rsp,20

            // Resolve UWorld and authoritative GameMode exactly as the game does.
            code.AddRange(new byte[] { 0x48, 0xB8 }); EmitU64(code, gEnginePtr);
            code.AddRange(new byte[] { 0x48, 0x8B, 0x08 });                   // mov rcx,[rax]
            code.AddRange(new byte[] { 0x48, 0x85, 0xC9 });
            failJumps.Add(EmitJzRel32(code));
            code.AddRange(new byte[] { 0x48, 0xBA }); EmitU64(code, worldContextObject);
            code.AddRange(new byte[] { 0x45, 0x31, 0xC0 });                   // xor r8d,r8d
            code.AddRange(new byte[] { 0x48, 0xB8 }); EmitU64(code, getWorldFromContext);
            code.AddRange(new byte[] { 0xFF, 0xD0 });
            code.AddRange(new byte[] { 0x48, 0x85, 0xC0 });
            failJumps.Add(EmitJzRel32(code));
            code.AddRange(new byte[] { 0x48, 0x8B, 0xD8 });                   // rbx=world

            code.AddRange(new byte[] { 0x48, 0x8B, 0xC8 });
            code.AddRange(new byte[] { 0x48, 0xB8 }); EmitU64(code, worldAuthorityCheck);
            code.AddRange(new byte[] { 0xFF, 0xD0 });
            code.AddRange(new byte[] { 0x84, 0xC0 });
            failJumps.Add(EmitJzRel32(code));

            code.AddRange(new byte[] { 0x48, 0x8B, 0xCB });                   // rcx=world
            code.AddRange(new byte[] { 0x48, 0xB8 }); EmitU64(code, getAuthGameMode);
            code.AddRange(new byte[] { 0xFF, 0xD0 });
            code.AddRange(new byte[] { 0x48, 0x85, 0xC0 });
            failJumps.Add(EmitJzRel32(code));

            // Create a normal bot controller + PlayerState with selected difficulty.
            code.AddRange(new byte[] { 0x48, 0x8B, 0xC8 });                   // rcx=game mode
            code.AddRange(new byte[] { 0x48, 0xBA }); EmitU64(code, rb + (ulong)nameF);
            code.AddRange(new byte[] { 0x41, 0xB8 }); code.AddRange(BitConverter.GetBytes((uint)teamId));
            code.AddRange(new byte[] { 0x41, 0xB9 }); code.AddRange(BitConverter.GetBytes((uint)difficulty));
            code.AddRange(new byte[] { 0x48, 0xB8 }); EmitU64(code, createBotPlayerDefault);
            code.AddRange(new byte[] { 0xFF, 0xD0 });
            code.AddRange(new byte[] { 0x48, 0x8B, 0xD8 });                   // rbx=controller
            code.AddRange(new byte[] { 0x48, 0x85, 0xDB });
            failJumps.Add(EmitJzRel32(code));

            // Controller.PlayerState = +0x320.
            code.AddRange(new byte[] { 0x48, 0x8B, 0x8B, 0x20, 0x03, 0x00, 0x00 });
            code.AddRange(new byte[] { 0x48, 0x85, 0xC9 });
            failJumps.Add(EmitJzRel32(code));

            // Use the game's own validated desiredShipGUID setter. The previous
            // build accidentally wrote 0x4C0 (ForcedLoadout); the real GUID is 0x5AC.
            code.AddRange(new byte[] { 0x48, 0xBA }); EmitU64(code, rb + (ulong)guidOff); // rdx=&FGuid
            code.AddRange(new byte[] { 0x48, 0xB8 }); EmitU64(code, setDesiredShipGuid);
            code.AddRange(new byte[] { 0xFF, 0xD0 });

            // Re-read PlayerState and make sure the game accepted exactly this GUID.
            code.AddRange(new byte[] { 0x48, 0x8B, 0x8B, 0x20, 0x03, 0x00, 0x00 });
            code.AddRange(new byte[] { 0x48, 0x85, 0xC9 });
            failJumps.Add(EmitJzRel32(code));
            EmitCmpDwordAtRcx(code, 0x5AC, ga); guidFailJumps.Add(EmitJnzRel32(code));
            EmitCmpDwordAtRcx(code, 0x5B0, gb); guidFailJumps.Add(EmitJnzRel32(code));
            EmitCmpDwordAtRcx(code, 0x5B4, gc); guidFailJumps.Add(EmitJnzRel32(code));
            EmitCmpDwordAtRcx(code, 0x5B8, gd); guidFailJumps.Add(EmitJnzRel32(code));

            // Spawn the selected ship through the normal bot-ship path.
            code.AddRange(new byte[] { 0x48, 0xB9 }); EmitU64(code, worldContextObject);
            code.AddRange(new byte[] { 0x48, 0x8B, 0xD3 });                   // rdx=controller
            code.AddRange(new byte[] { 0x48, 0xB8 }); EmitU64(code, spawnBotShip);
            code.AddRange(new byte[] { 0xFF, 0xD0 });

            // Success: return controller and status 0.
            code.AddRange(new byte[] { 0x48, 0xB8 }); EmitU64(code, rb + (ulong)resultOff);
            code.AddRange(new byte[] { 0x48, 0x89, 0x18 });                   // [result]=controller
            code.Add(0xE9); int doneJumpImm = code.Count; code.AddRange(new byte[4]);

            // GUID rejected by the game's ship database.
            int guidFailPos = code.Count;
            code.AddRange(new byte[] { 0x48, 0xB8 }); EmitU64(code, rb + (ulong)resultOff);
            code.AddRange(new byte[] { 0x48, 0xC7, 0x00, 0, 0, 0, 0 });
            code.AddRange(new byte[] { 0xC7, 0x40, 0x08, 13, 0, 0, 0 });
            code.Add(0xE9); int guidDoneJumpImm = code.Count; code.AddRange(new byte[4]);

            // World/GameMode/controller setup failed.
            int failPos = code.Count;
            code.AddRange(new byte[] { 0x48, 0xB8 }); EmitU64(code, rb + (ulong)resultOff);
            code.AddRange(new byte[] { 0x48, 0xC7, 0x00, 0, 0, 0, 0 });
            code.AddRange(new byte[] { 0xC7, 0x40, 0x08, 14, 0, 0, 0 });

            int donePos = code.Count;
            code.AddRange(new byte[] { 0x31, 0xC0, 0x48, 0x83, 0xC4, 0x20, 0x5B, 0xC3 });

            foreach (int imm in failJumps) PatchRel32(code, imm, failPos);
            foreach (int imm in guidFailJumps) PatchRel32(code, imm, guidFailPos);
            PatchRel32(code, doneJumpImm, donePos);
            PatchRel32(code, guidDoneJumpImm, donePos);

            if (code.Count >= resultOff)
            {
                LastSpawnError = 2;
                return 0;
            }
            Buffer.BlockCopy(code.ToArray(), 0, payload, 0, code.Count);

            IntPtr wrote;
            if (!WriteProcessMemory(hProcess, remote, payload, payload.Length, out wrote) || wrote.ToInt64() != payload.Length)
            {
                LastSpawnError = 3;
                return 0;
            }
            FlushInstructionCache(hProcess, remote, new UIntPtr((uint)code.Count));

            uint threadId;
            thread = CreateRemoteThread(hProcess, IntPtr.Zero, UIntPtr.Zero, remote, IntPtr.Zero, 0, out threadId);
            if (thread == IntPtr.Zero)
            {
                LastSpawnError = 4;
                return 0;
            }

            uint wait = WaitForSingleObject(thread, 8000);
            if (wait == WAIT_TIMEOUT)
            {
                safeToFree = false;
                LastSpawnError = 5;
                return 0;
            }
            if (wait != WAIT_OBJECT_0)
            {
                safeToFree = false;
                LastSpawnError = 6;
                return 0;
            }

            byte[] result = new byte[16];
            IntPtr got;
            IntPtr resultAddress = new IntPtr(unchecked((long)(rb + (ulong)resultOff)));
            if (!ReadProcessMemory(hProcess, resultAddress, result, result.Length, out got) || got.ToInt64() != result.Length)
            {
                LastSpawnError = 7;
                return 0;
            }

            ulong controller = BitConverter.ToUInt64(result, 0);
            if (controller < 0x10000UL)
            {
                int remoteStatus = BitConverter.ToInt32(result, 8);
                LastSpawnError = remoteStatus != 0 ? remoteStatus : 8;
                return 0;
            }
            return unchecked((long)controller);
        }
        catch
        {
            LastSpawnError = 9;
            return 0;
        }
        finally
        {
            if (thread != IntPtr.Zero) CloseHandle(thread);
            if (safeToFree && remote != IntPtr.Zero) VirtualFreeEx(hProcess, remote, UIntPtr.Zero, MEM_RELEASE);
        }
    }


    // Resolve a UObject's runtime name through UE4's own KismetSystemLibrary::GetObjectName.
    // We use this on the pawn's UClass so Last Stand small AI ships can be identified
    // by their real Blueprint class instead of the generic Reaper GUID they often carry.
    public static string GetUObjectNameNative(
        IntPtr hProcess,
        ulong moduleBase,
        ulong objectPtr)
    {
        if (hProcess == IntPtr.Zero || moduleBase < 0x10000UL || objectPtr < 0x10000UL)
            return "";

        ulong getObjectName = moduleBase + 0x0143ABA0UL;
        byte[] sig = new byte[6];
        IntPtr sigRead;
        if (!ReadProcessMemory(hProcess, new IntPtr(unchecked((long)getObjectName)), sig, sig.Length, out sigRead) ||
            sigRead.ToInt64() != sig.Length ||
            sig[0] != 0x40 || sig[1] != 0x53 || sig[2] != 0x48 || sig[3] != 0x83 || sig[4] != 0xEC || sig[5] != 0x20)
            return "";

        const uint MEM_COMMIT_RESERVE = 0x3000;
        const uint MEM_RELEASE = 0x8000;
        const uint PAGE_EXECUTE_READWRITE = 0x40;
        const uint WAIT_OBJECT_0 = 0x00000000;
        const uint WAIT_TIMEOUT = 0x00000102;
        const int blockSize = 0x200;
        const int resultOff = 0x100;

        IntPtr remote = VirtualAllocEx(hProcess, IntPtr.Zero, new UIntPtr((uint)blockSize), MEM_COMMIT_RESERVE, PAGE_EXECUTE_READWRITE);
        if (remote == IntPtr.Zero)
            return "";

        bool safeToFree = true;
        IntPtr thread = IntPtr.Zero;
        ulong stringData = 0;
        try
        {
            ulong rb = unchecked((ulong)remote.ToInt64());
            List<byte> code = new List<byte>();
            code.AddRange(new byte[] { 0x48, 0x83, 0xEC, 0x28 });             // sub rsp,28
            code.AddRange(new byte[] { 0x48, 0xB9 }); EmitU64(code, rb + resultOff); // rcx=&FString result
            code.AddRange(new byte[] { 0x48, 0xBA }); EmitU64(code, objectPtr);      // rdx=UObject*
            code.AddRange(new byte[] { 0x48, 0xB8 }); EmitU64(code, getObjectName);
            code.AddRange(new byte[] { 0xFF, 0xD0 });                         // call rax
            code.AddRange(new byte[] { 0x31, 0xC0 });                         // xor eax,eax
            code.AddRange(new byte[] { 0x48, 0x83, 0xC4, 0x28, 0xC3 });       // add rsp,28; ret

            byte[] payload = new byte[blockSize];
            Buffer.BlockCopy(code.ToArray(), 0, payload, 0, code.Count);
            IntPtr wrote;
            if (!WriteProcessMemory(hProcess, remote, payload, payload.Length, out wrote) || wrote.ToInt64() != payload.Length)
                return "";
            FlushInstructionCache(hProcess, remote, new UIntPtr((uint)code.Count));

            uint threadId;
            thread = CreateRemoteThread(hProcess, IntPtr.Zero, UIntPtr.Zero, remote, IntPtr.Zero, 0, out threadId);
            if (thread == IntPtr.Zero)
                return "";

            uint wait = WaitForSingleObject(thread, 3000);
            if (wait == WAIT_TIMEOUT)
            {
                safeToFree = false;
                return "";
            }
            if (wait != WAIT_OBJECT_0)
            {
                safeToFree = false;
                return "";
            }

            byte[] fs = new byte[16];
            IntPtr got;
            if (!ReadProcessMemory(hProcess, new IntPtr(unchecked((long)(rb + resultOff))), fs, fs.Length, out got) || got.ToInt64() != fs.Length)
                return "";

            stringData = BitConverter.ToUInt64(fs, 0);
            int num = BitConverter.ToInt32(fs, 8);
            int max = BitConverter.ToInt32(fs, 12);
            if (stringData < 0x10000UL || num <= 0 || num > 256 || max < num || max > 512)
                return "";

            byte[] text = new byte[num * 2];
            if (!ReadProcessMemory(hProcess, new IntPtr(unchecked((long)stringData)), text, text.Length, out got) || got.ToInt64() != text.Length)
                return "";

            string value = System.Text.Encoding.Unicode.GetString(text);
            int zero = value.IndexOf('\0');
            if (zero >= 0) value = value.Substring(0, zero);
            return value;
        }
        catch
        {
            return "";
        }
        finally
        {
            if (thread != IntPtr.Zero) CloseHandle(thread);

            // GetObjectName returns an FString whose character buffer is allocated by UE4.
            // Free that small temporary buffer through the same FMemory::Free routine used by
            // the game's own reflection thunk. Class names are cached, so this path is rare.
            if (stringData >= 0x10000UL)
            {
                try
                {
                    ulong freeFunction = moduleBase + 0x006B92B0UL;
                    uint freeThreadId;
                    IntPtr freeThread = CreateRemoteThread(
                        hProcess, IntPtr.Zero, UIntPtr.Zero,
                        new IntPtr(unchecked((long)freeFunction)),
                        new IntPtr(unchecked((long)stringData)),
                        0, out freeThreadId);
                    if (freeThread != IntPtr.Zero)
                    {
                        WaitForSingleObject(freeThread, 2000);
                        CloseHandle(freeThread);
                    }
                }
                catch { }
            }

            if (safeToFree && remote != IntPtr.Zero)
                VirtualFreeEx(hProcess, remote, UIntPtr.Zero, MEM_RELEASE);
        }
    }


    // Read ShipPawn::GetShipGUID through the same virtual method used by the
    // game's reflected GetShipGUID thunk (vtable slot +0x730 in this build).
    // This is more reliable for Final Stand capital ships than reading the raw
    // ShipLayoutGUID / desiredShipGUID fields, which can keep generic values.
    public static string GetShipGuidNative(
        IntPtr hProcess,
        ulong moduleBase,
        ulong shipPawn)
    {
        if (hProcess == IntPtr.Zero || moduleBase < 0x10000UL || shipPawn < 0x10000UL)
            return "";

        // Guard the supplied build's execGetShipGUID thunk. It calls [vtable+0x730].
        ulong execGetShipGuid = moduleBase + 0x00635800UL;
        byte[] sig = new byte[12];
        IntPtr got;
        if (!ReadProcessMemory(hProcess, new IntPtr(unchecked((long)execGetShipGuid)), sig, sig.Length, out got) ||
            got.ToInt64() != sig.Length ||
            sig[0] != 0x40 || sig[1] != 0x53 || sig[2] != 0x48 || sig[3] != 0x83 ||
            sig[4] != 0xEC || sig[5] != 0x30 || sig[6] != 0x48 || sig[7] != 0x8B ||
            sig[8] != 0x42 || sig[9] != 0x20)
            return "";

        byte[] ptr = new byte[8];
        if (!ReadProcessMemory(hProcess, new IntPtr(unchecked((long)shipPawn)), ptr, 8, out got) || got.ToInt64() != 8)
            return "";
        ulong vtable = BitConverter.ToUInt64(ptr, 0);
        if (vtable < 0x10000UL) return "";

        if (!ReadProcessMemory(hProcess, new IntPtr(unchecked((long)(vtable + 0x730UL))), ptr, 8, out got) || got.ToInt64() != 8)
            return "";
        ulong getter = BitConverter.ToUInt64(ptr, 0);
        if (getter < 0x10000UL) return "";

        const uint MEM_COMMIT_RESERVE = 0x3000;
        const uint MEM_RELEASE = 0x8000;
        const uint PAGE_EXECUTE_READWRITE = 0x40;
        const uint WAIT_OBJECT_0 = 0x00000000;
        const uint WAIT_TIMEOUT = 0x00000102;
        const int blockSize = 0x180;
        const int resultOff = 0x100;

        IntPtr remote = VirtualAllocEx(hProcess, IntPtr.Zero, new UIntPtr((uint)blockSize), MEM_COMMIT_RESERVE, PAGE_EXECUTE_READWRITE);
        if (remote == IntPtr.Zero) return "";

        bool safeToFree = true;
        IntPtr thread = IntPtr.Zero;
        try
        {
            ulong rb = unchecked((ulong)remote.ToInt64());
            List<byte> code = new List<byte>();
            code.AddRange(new byte[] { 0x48, 0x83, 0xEC, 0x28 });             // sub rsp,28
            code.AddRange(new byte[] { 0x48, 0xB9 }); EmitU64(code, shipPawn); // rcx=ShipPawn
            code.AddRange(new byte[] { 0x48, 0xBA }); EmitU64(code, rb + resultOff); // rdx=&FGuid
            code.AddRange(new byte[] { 0x48, 0xB8 }); EmitU64(code, getter);
            code.AddRange(new byte[] { 0xFF, 0xD0 });                         // call getter
            // The getter returns FGuid*. Copy the returned value over the output
            // buffer too, matching the game's exec thunk behavior.
            code.AddRange(new byte[] { 0x48, 0x85, 0xC0 });                   // test rax,rax
            code.AddRange(new byte[] { 0x74, 0x10 });                         // jz +0x10
            code.AddRange(new byte[] { 0x0F, 0x10, 0x00 });                   // movups xmm0,[rax]
            code.AddRange(new byte[] { 0x48, 0xBA }); EmitU64(code, rb + resultOff);
            code.AddRange(new byte[] { 0x0F, 0x11, 0x02 });                   // movups [rdx],xmm0
            code.AddRange(new byte[] { 0x31, 0xC0 });                         // xor eax,eax
            code.AddRange(new byte[] { 0x48, 0x83, 0xC4, 0x28, 0xC3 });       // add rsp,28; ret

            if (code.Count >= resultOff) return "";
            byte[] payload = new byte[blockSize];
            Buffer.BlockCopy(code.ToArray(), 0, payload, 0, code.Count);
            IntPtr wrote;
            if (!WriteProcessMemory(hProcess, remote, payload, payload.Length, out wrote) || wrote.ToInt64() != payload.Length)
                return "";
            FlushInstructionCache(hProcess, remote, new UIntPtr((uint)code.Count));

            uint threadId;
            thread = CreateRemoteThread(hProcess, IntPtr.Zero, UIntPtr.Zero, remote, IntPtr.Zero, 0, out threadId);
            if (thread == IntPtr.Zero) return "";
            uint wait = WaitForSingleObject(thread, 3000);
            if (wait == WAIT_TIMEOUT) { safeToFree = false; return ""; }
            if (wait != WAIT_OBJECT_0) { safeToFree = false; return ""; }

            byte[] guid = new byte[16];
            if (!ReadProcessMemory(hProcess, new IntPtr(unchecked((long)(rb + resultOff))), guid, guid.Length, out got) || got.ToInt64() != guid.Length)
                return "";

            uint a = BitConverter.ToUInt32(guid, 0);
            uint b = BitConverter.ToUInt32(guid, 4);
            uint c = BitConverter.ToUInt32(guid, 8);
            uint d = BitConverter.ToUInt32(guid, 12);
            if ((a | b | c | d) == 0) return "";
            return a.ToString("X8") + b.ToString("X8") + c.ToString("X8") + d.ToString("X8");
        }
        catch { return ""; }
        finally
        {
            if (thread != IntPtr.Zero) CloseHandle(thread);
            if (safeToFree && remote != IntPtr.Zero)
                VirtualFreeEx(hProcess, remote, UIntPtr.Zero, MEM_RELEASE);
        }
    }

    public static int LastActorDeleteError = 0;

    // Clean local/offline ally removal. The game's ServerDestroyAIPlayer path
    // destroys the controller but can leave its pawn behind as an orphaned red
    // ship. We already have both live pointers, so destroy the controller and
    // then the pawn in one server-thread call using AActor::Destroy.
    public static bool DestroyAllyActorsNative(
        IntPtr hProcess,
        ulong moduleBase,
        ulong controller,
        ulong pawn)
    {
        LastActorDeleteError = 0;
        if (hProcess == IntPtr.Zero || moduleBase < 0x10000UL || controller < 0x10000UL || pawn < 0x10000UL)
        {
            LastActorDeleteError = 100;
            return false;
        }

        // AActor::Destroy(bool bNetForce, bool bShouldModifyLevel), exact supplied build.
        ulong actorDestroy = moduleBase + 0x01171840UL;
        byte[] sig = new byte[10];
        IntPtr sigRead;
        if (!ReadProcessMemory(hProcess, new IntPtr(unchecked((long)actorDestroy)), sig, sig.Length, out sigRead) ||
            sigRead.ToInt64() != sig.Length ||
            sig[0] != 0x48 || sig[1] != 0x89 || sig[2] != 0x5C || sig[3] != 0x24 || sig[4] != 0x10 ||
            sig[5] != 0x48 || sig[6] != 0x89 || sig[7] != 0x74 || sig[8] != 0x24 || sig[9] != 0x18)
        {
            LastActorDeleteError = 10;
            return false;
        }

        const uint MEM_COMMIT_RESERVE = 0x3000;
        const uint MEM_RELEASE = 0x8000;
        const uint PAGE_EXECUTE_READWRITE = 0x40;
        const uint WAIT_OBJECT_0 = 0x00000000;
        const uint WAIT_TIMEOUT = 0x00000102;
        const int blockSize = 0x200;
        const int resultOff = 0x180;

        IntPtr remote = VirtualAllocEx(hProcess, IntPtr.Zero, new UIntPtr((uint)blockSize), MEM_COMMIT_RESERVE, PAGE_EXECUTE_READWRITE);
        if (remote == IntPtr.Zero)
        {
            LastActorDeleteError = 1;
            return false;
        }

        bool safeToFree = true;
        IntPtr thread = IntPtr.Zero;
        try
        {
            ulong rb = unchecked((ulong)remote.ToInt64());
            List<byte> code = new List<byte>();
            code.AddRange(new byte[] { 0x48, 0x83, 0xEC, 0x28 }); // sub rsp,28

            // Destroy controller first so it cannot auto-respawn the pawn.
            code.AddRange(new byte[] { 0x48, 0xB9 }); EmitU64(code, controller);
            code.AddRange(new byte[] { 0x31, 0xD2 });             // xor edx,edx
            code.AddRange(new byte[] { 0x41, 0xB8, 0x01, 0x00, 0x00, 0x00 }); // r8d=1
            code.AddRange(new byte[] { 0x48, 0xB8 }); EmitU64(code, actorDestroy);
            code.AddRange(new byte[] { 0xFF, 0xD0 });

            // Then remove the ship actor itself so no red/orphan hull stays on-map.
            code.AddRange(new byte[] { 0x48, 0xB9 }); EmitU64(code, pawn);
            code.AddRange(new byte[] { 0x31, 0xD2 });
            code.AddRange(new byte[] { 0x41, 0xB8, 0x01, 0x00, 0x00, 0x00 });
            code.AddRange(new byte[] { 0x48, 0xB8 }); EmitU64(code, actorDestroy);
            code.AddRange(new byte[] { 0xFF, 0xD0 });

            code.AddRange(new byte[] { 0x48, 0xBA }); EmitU64(code, rb + resultOff);
            code.AddRange(new byte[] { 0xC6, 0x02, 0x01 });       // result=1
            code.AddRange(new byte[] { 0x31, 0xC0 });
            code.AddRange(new byte[] { 0x48, 0x83, 0xC4, 0x28, 0xC3 });

            if (code.Count >= resultOff)
            {
                LastActorDeleteError = 2;
                return false;
            }

            byte[] payload = new byte[blockSize];
            Buffer.BlockCopy(code.ToArray(), 0, payload, 0, code.Count);
            IntPtr wrote;
            if (!WriteProcessMemory(hProcess, remote, payload, payload.Length, out wrote) || wrote.ToInt64() != payload.Length)
            {
                LastActorDeleteError = 3;
                return false;
            }
            FlushInstructionCache(hProcess, remote, new UIntPtr((uint)code.Count));

            uint threadId;
            thread = CreateRemoteThread(hProcess, IntPtr.Zero, UIntPtr.Zero, remote, IntPtr.Zero, 0, out threadId);
            if (thread == IntPtr.Zero)
            {
                LastActorDeleteError = 4;
                return false;
            }

            uint wait = WaitForSingleObject(thread, 6000);
            if (wait == WAIT_TIMEOUT)
            {
                safeToFree = false;
                LastActorDeleteError = 5;
                return false;
            }
            if (wait != WAIT_OBJECT_0)
            {
                safeToFree = false;
                LastActorDeleteError = 6;
                return false;
            }

            byte[] result = new byte[1];
            IntPtr got;
            if (!ReadProcessMemory(hProcess, new IntPtr(unchecked((long)(rb + resultOff))), result, 1, out got) || got.ToInt64() != 1)
            {
                LastActorDeleteError = 7;
                return false;
            }
            return result[0] != 0;
        }
        catch
        {
            LastActorDeleteError = 9;
            return false;
        }
        finally
        {
            if (thread != IntPtr.Zero) CloseHandle(thread);
            if (safeToFree && remote != IntPtr.Zero) VirtualFreeEx(hProcess, remote, UIntPtr.Zero, MEM_RELEASE);
        }
    }

    public static int LastDestroyError = 0;

    // Local/offline helper for GameplayBlueprintLibrary.ServerDestroyAIPlayer.
    // Signature for the supplied spserver.exe build: RVA 0x355A90.
    public static bool DestroyAIPlayerNative(
        IntPtr hProcess,
        ulong moduleBase,
        ulong worldContextObject,
        string botName)
    {
        LastDestroyError = 0;
        if (hProcess == IntPtr.Zero || moduleBase < 0x10000UL || worldContextObject < 0x10000UL || String.IsNullOrWhiteSpace(botName))
        {
            LastDestroyError = 100;
            return false;
        }

        if (botName.Length > 96) botName = botName.Substring(0, 96);

        byte[] sig = new byte[8];
        IntPtr sigRead;
        IntPtr fnForCheck = new IntPtr(unchecked((long)(moduleBase + 0x00355A90UL)));
        if (!ReadProcessMemory(hProcess, fnForCheck, sig, sig.Length, out sigRead) ||
            sigRead.ToInt64() != sig.Length ||
            sig[0] != 0x48 || sig[1] != 0x89 || sig[2] != 0x5C || sig[3] != 0x24 ||
            sig[4] != 0x08 || sig[5] != 0x57 || sig[6] != 0x48 || sig[7] != 0x83)
        {
            LastDestroyError = 10;
            return false;
        }

        const uint MEM_COMMIT_RESERVE = 0x3000;
        const uint MEM_RELEASE = 0x8000;
        const uint PAGE_EXECUTE_READWRITE = 0x40;
        const uint WAIT_OBJECT_0 = 0x00000000;
        const uint WAIT_TIMEOUT = 0x00000102;
        const int blockSize = 0x800;
        const int nameF = 0x100;
        const int resultOff = 0x120;
        const int nameText = 0x200;

        IntPtr remote = VirtualAllocEx(hProcess, IntPtr.Zero, new UIntPtr((uint)blockSize), MEM_COMMIT_RESERVE, PAGE_EXECUTE_READWRITE);
        if (remote == IntPtr.Zero)
        {
            LastDestroyError = 1;
            return false;
        }

        bool safeToFree = true;
        IntPtr thread = IntPtr.Zero;
        try
        {
            ulong rb = unchecked((ulong)remote.ToInt64());
            byte[] payload = new byte[blockSize];
            PutFString(payload, nameF, nameText, rb, botName);

            ulong destroyFunction = moduleBase + 0x00355A90UL;
            List<byte> code = new List<byte>();
            code.AddRange(new byte[] { 0x48, 0x83, 0xEC, 0x28 });                 // sub rsp,28
            code.AddRange(new byte[] { 0x48, 0xB9 }); EmitU64(code, worldContextObject); // rcx=world context
            code.AddRange(new byte[] { 0x48, 0xBA }); EmitU64(code, rb + nameF);          // rdx=&Name
            code.AddRange(new byte[] { 0x48, 0xB8 }); EmitU64(code, destroyFunction);     // rax=function
            code.AddRange(new byte[] { 0xFF, 0xD0 });                                     // call rax
            code.AddRange(new byte[] { 0x48, 0xBA }); EmitU64(code, rb + resultOff);      // rdx=&result
            code.AddRange(new byte[] { 0x88, 0x02 });                                     // [rdx]=al
            code.AddRange(new byte[] { 0x31, 0xC0 });                                     // xor eax,eax
            code.AddRange(new byte[] { 0x48, 0x83, 0xC4, 0x28, 0xC3 });                   // add rsp,28; ret

            if (code.Count >= nameF)
            {
                LastDestroyError = 2;
                return false;
            }
            Buffer.BlockCopy(code.ToArray(), 0, payload, 0, code.Count);

            IntPtr wrote;
            if (!WriteProcessMemory(hProcess, remote, payload, payload.Length, out wrote) || wrote.ToInt64() != payload.Length)
            {
                LastDestroyError = 3;
                return false;
            }
            FlushInstructionCache(hProcess, remote, new UIntPtr((uint)code.Count));

            uint threadId;
            thread = CreateRemoteThread(hProcess, IntPtr.Zero, UIntPtr.Zero, remote, IntPtr.Zero, 0, out threadId);
            if (thread == IntPtr.Zero)
            {
                LastDestroyError = 4;
                return false;
            }

            uint wait = WaitForSingleObject(thread, 8000);
            if (wait == WAIT_TIMEOUT)
            {
                safeToFree = false;
                LastDestroyError = 5;
                return false;
            }
            if (wait != WAIT_OBJECT_0)
            {
                safeToFree = false;
                LastDestroyError = 6;
                return false;
            }

            byte[] result = new byte[1];
            IntPtr got;
            if (!ReadProcessMemory(hProcess, new IntPtr(unchecked((long)(rb + resultOff))), result, 1, out got) || got.ToInt64() != 1)
            {
                LastDestroyError = 7;
                return false;
            }
            if (result[0] == 0)
            {
                LastDestroyError = 8;
                return false;
            }
            return true;
        }
        catch
        {
            LastDestroyError = 9;
            return false;
        }
        finally
        {
            if (thread != IntPtr.Zero) CloseHandle(thread);
            if (safeToFree && remote != IntPtr.Zero) VirtualFreeEx(hProcess, remote, UIntPtr.Zero, MEM_RELEASE);
        }
    }

}
"@

Add-Type -TypeDefinition $nativeCode -Language CSharp

# PROCESS_CREATE_THREAD | PROCESS_VM_OPERATION | PROCESS_VM_READ | PROCESS_VM_WRITE | PROCESS_QUERY_INFORMATION
$PROCESS_ACCESS = [uint32]0x043A

# Stable pointer from realGODMOD.CT.
$BASE_OFFSET = [int64]0x0360E908

# The chain before the final ShipPawn.HealthComponent field.
$DEREF_TO_SHIP_OFFSETS = @(
    [int64]0x620,
    [int64]0xCF8,
    [int64]0x5F0,
    [int64]0x590,
    [int64]0x90
)

# Offsets verified directly from the supplied spserver.exe reflection tables.
$ACTOR_OWNER_OFFSET = [int64]0x108
$UOBJECT_OUTER_OFFSET = [int64]0x20
$LEVEL_ACTORS_OFFSET = [int64]0x28
$LEVEL_OWNING_WORLD_OFFSET = [int64]0xC0
$WORLD_PERSISTENT_LEVEL_OFFSET = [int64]0x30
$WORLD_GAMESTATE_OFFSET = [int64]0xF8
$GAMESTATE_PLAYERARRAY_OFFSET = [int64]0x330
$CONTROLLER_PLAYERSTATE_OFFSET = [int64]0x320
$CONTROLLER_PAWN_OFFSET = [int64]0x348
$PAWN_PLAYERSTATE_OFFSET = [int64]0x338
$PAWN_CONTROLLER_OFFSET = [int64]0x350
$PLAYERSTATE_TEAM_OFFSET = [int64]0x590
$SHIP_HEALTH_COMPONENT_OFFSET = [int64]0x520
$CURRENT_HEALTH_OFFSET = [int64]0x298
$PLAYERSTATE_DESIRED_SHIP_GUID_OFFSET = [int64]0x5AC
$SHIP_LAYOUT_GUID_OFFSET = [int64]0x508
$BOT_DIFFICULTY_TYPE_OFFSET = [int64]0xE30
# The game copies the selected 0x90-byte BotDifficultyPreset into the controller here.
$BOT_ACTIVE_DIFFICULTY_PRESET_OFFSET = [int64]0xDA0

# Friendly ship names used by the dropdown. The spawn code writes the selected internal FGuid.
$SHIP_GUIDS = [ordered]@{
    "Aegis"       = "80C054A748F1BAABA7FDA09168054B73"
    "Basilisk"    = "6D22A2D740E6D2217A48F4947BCF9861"
    "Black Widow" = "747DEE6D476875B019857EA5D30D170E"
    "Brawler"     = "5B80159348B5CD480E07EB967950F7C9"
    "Centurion"   = "A878C8B04B8177BF0BA612B97069ADCD"
    "Colossus"    = "CCAA8EFC48379FCDB11C24B649795998"
    "Destroyer"   = "75AFB889459F2EEF8B6BF5AB61ABD438"
    "Displacer"   = "B0EAB08C4553A594C34426AE5CE6897A"
    "Disruptor"   = "6CFCB7834AA56ADE1F064E83EBDBECE1"
    "Endeavor"    = "186BE8CE40151435863FAA9339418EC7"
    "Enforcer"    = "2FA3BF8A41485B3E77DA3BA2E12E6EEF"
    "Equalizer"   = "0D7F05F34FA2F59D379CF9821E0F5C93"
    "Executioner" = "1CB7531942CAA92F5741739A9124B5C9"
    "Furion"      = "FB09DFA0428992D18A32AEBE47CB9AD1"
    "Ghost"       = "C890501B4E153EE73B7189A8CA811488"
    "Gladiator"   = "3CD44BFB40EDAA2C05E7C99FA24F0731"
    "Guardian"    = "94722BAE45AB5D87A57E2A8CAD1C4619"
    "Hunter"      = "04F456694A1981252D1370B0D7CFCE94"
    "Infiltrator" = "EBE532C246872D08ACB1F2BFC16E29A4"
    "Interceptor" = "026A1CF143A04A2320BB1493FC97E2CF"
    "Leviathan"   = "05BBCBAA41CB21B6C98E129FE6A9651F"
    "Overseer"    = "9A93FF8A41BEB20D24C000B52930A637"
    "Paladin"     = "19975BA247BC0095F887E78EF5EDA693"
    "Paragon"     = "1253D6F14151734ECBAA3F8C92C66BDF"
    "Persecutor"  = "406A83094DAC130A4938D9B809BDBEAB"
    "Pioneer"     = "54D0DFA14E57170E5CA88AA0B89AF409"
    "Protector"   = "BAC28DC14785A1BB535EFC8C5493363C"
    "Punisher"    = "43F6918449A10D489FB8948394814C10"
    "Raider"      = "E6AB6576452D92A66130C3B9DFC0CAD3"
    "Ranger"      = "631F72BD449A24A05AB022950FD34B28"
    "Raven"       = "451B35444A8050A857541BAC1D75753D"
    "Reaper"      = "CD8A513447E61CF2928BB185AE26138B"
    "Sentinel"    = "20090F1A40A2E7A97DDB7A8EA437A69C"
    "Superlifter" = "04F07A294367CA512614BC8A43B052CA"
    "Venturer"    = "7AD71B5846A966A6F05844BFFC9D941E"
    "Watchman"    = "3D00470D4738A8FA14F637963FF5CE8A"
}

$GUID_TO_SHIP = @{}
foreach ($entry in $SHIP_GUIDS.GetEnumerator()) {
    $GUID_TO_SHIP[[string]$entry.Value.ToUpperInvariant()] = [string]$entry.Key
}

$script:ServerProcess = $null
$script:ProcessHandle = [IntPtr]::Zero
$script:ModuleBase = [IntPtr]::Zero
$script:ConnectedProcessId = 0

$script:GodEnabled = $false
$script:LockedHealth = [single]0
$script:LastHealthAddress = [int64]0

$script:AllyGodEnabled = $false
$script:EnemyGodEnabled = $false
$script:PlayerStateAddresses = @()
$script:TeamLocks = @{}
$script:EnemyLocks = @{}
$script:LastEnemyTeamId = -1
$script:ScanningPlayers = $false
$script:ScanAttempted = $false
$script:ScanTask = $null
$script:ScanProcessId = 0
$script:SpawnRescanAt = [DateTime]::MinValue
$script:NextAutoRescanAt = [DateTime]::MinValue
$script:ScanQuiet = $false
$script:LastWaitingAllies = 0
$script:ControllerCache = @{}
$script:PawnCache = @{}
$script:PawnClassNameCache = @{}
$script:ShipGuidCache = @{}
$script:CurrentLevelAddress = [int64]0
$script:LastDirectDiscoveryDetail = "not run"
$script:SpawnedBotNames = @{}
$script:PendingSpawnControllers = @()
$script:TrackedAllies = @{}
$script:PlayerNameOffset = [int64]0x3A8
$script:NextRosterRefreshAt = [DateTime]::MinValue
$script:NextRosterUiAt = [DateTime]::MinValue
$script:LastRosterSignature = ""
$script:LastEnemyRosterSignature = ""

function Clear-TeamState {
    $script:PlayerStateAddresses = @()
    $script:TeamLocks = @{}
    $script:EnemyLocks = @{}
    $script:LastEnemyTeamId = -1
    $script:ScanningPlayers = $false
    $script:ScanAttempted = $false
    $script:ScanTask = $null
    $script:ScanProcessId = 0
    $script:SpawnRescanAt = [DateTime]::MinValue
    $script:NextAutoRescanAt = [DateTime]::MinValue
    $script:ScanQuiet = $false
    $script:LastWaitingAllies = 0
    $script:ControllerCache = @{}
    $script:PawnCache = @{}
    $script:PawnClassNameCache = @{}
    $script:ShipGuidCache = @{}
    $script:CurrentLevelAddress = [int64]0
    $script:LastDirectDiscoveryDetail = "not run"
    $script:SpawnedBotNames = @{}
    $script:PendingSpawnControllers = @()
    $script:TrackedAllies = @{}
    $script:PlayerNameOffset = [int64]0x3A8
    $script:NextRosterRefreshAt = [DateTime]::MinValue
    $script:NextRosterUiAt = [DateTime]::MinValue
    $script:LastRosterSignature = ""
    $script:LastEnemyRosterSignature = ""
}

function Close-ServerHandle {
    if ($script:ProcessHandle -ne [IntPtr]::Zero) {
        [void][NativeMemoryV4]::CloseHandle($script:ProcessHandle)
    }
    $script:ServerProcess = $null
    $script:ProcessHandle = [IntPtr]::Zero
    $script:ModuleBase = [IntPtr]::Zero
    $script:ConnectedProcessId = 0
    $script:LastHealthAddress = 0
    Clear-TeamState
}

function Test-ServerAlive {
    if ($null -eq $script:ServerProcess) { return $false }
    try {
        return -not $script:ServerProcess.HasExited
    } catch {
        return $false
    }
}

function Connect-Server {
    if ((Test-ServerAlive) -and $script:ProcessHandle -ne [IntPtr]::Zero) {
        return $true
    }

    Close-ServerHandle

    $servers = @([System.Diagnostics.Process]::GetProcessesByName("spserver"))
    if ($servers.Count -eq 0) {
        return $false
    }

    $proc = $servers | Sort-Object Id -Descending | Select-Object -First 1

    try {
        $base = $proc.MainModule.BaseAddress
    } catch {
        return $false
    }

    $handle = [NativeMemoryV4]::OpenProcess($PROCESS_ACCESS, $false, $proc.Id)
    if ($handle -eq [IntPtr]::Zero) {
        return $false
    }

    $script:ServerProcess = $proc
    $script:ProcessHandle = $handle
    $script:ModuleBase = $base
    $script:ConnectedProcessId = $proc.Id
    $script:LastHealthAddress = 0
    Clear-TeamState
    $script:NextRosterRefreshAt = [DateTime]::UtcNow.AddSeconds(1)
    return $true
}

function Read-U64([IntPtr]$Address) {
    if ($script:ProcessHandle -eq [IntPtr]::Zero) { return $null }
    [byte[]]$buffer = New-Object byte[] 8
    [IntPtr]$bytesRead = [IntPtr]::Zero
    $ok = [NativeMemoryV4]::ReadProcessMemory(
        $script:ProcessHandle,
        $Address,
        $buffer,
        8,
        [ref]$bytesRead)
    if (-not $ok -or $bytesRead.ToInt64() -ne 8) { return $null }
    return [BitConverter]::ToUInt64($buffer, 0)
}

function Read-U8([IntPtr]$Address) {
    if ($script:ProcessHandle -eq [IntPtr]::Zero) { return $null }
    [byte[]]$buffer = New-Object byte[] 1
    [IntPtr]$bytesRead = [IntPtr]::Zero
    $ok = [NativeMemoryV4]::ReadProcessMemory(
        $script:ProcessHandle,
        $Address,
        $buffer,
        1,
        [ref]$bytesRead)
    if (-not $ok -or $bytesRead.ToInt64() -ne 1) { return $null }
    return [int]$buffer[0]
}

function Read-F32([IntPtr]$Address) {
    if ($script:ProcessHandle -eq [IntPtr]::Zero) { return $null }
    [byte[]]$buffer = New-Object byte[] 4
    [IntPtr]$bytesRead = [IntPtr]::Zero
    $ok = [NativeMemoryV4]::ReadProcessMemory(
        $script:ProcessHandle,
        $Address,
        $buffer,
        4,
        [ref]$bytesRead)
    if (-not $ok -or $bytesRead.ToInt64() -ne 4) { return $null }
    return [BitConverter]::ToSingle($buffer, 0)
}

function Write-F32([IntPtr]$Address, [single]$Value) {
    if ($script:ProcessHandle -eq [IntPtr]::Zero) { return $false }
    [byte[]]$buffer = [BitConverter]::GetBytes([single]$Value)
    [IntPtr]$bytesWritten = [IntPtr]::Zero
    $ok = [NativeMemoryV4]::WriteProcessMemory(
        $script:ProcessHandle,
        $Address,
        $buffer,
        4,
        [ref]$bytesWritten)
    return ($ok -and $bytesWritten.ToInt64() -eq 4)
}

function Read-I32([IntPtr]$Address) {
    if ($script:ProcessHandle -eq [IntPtr]::Zero) { return $null }
    [byte[]]$buffer = New-Object byte[] 4
    [IntPtr]$bytesRead = [IntPtr]::Zero
    $ok = [NativeMemoryV4]::ReadProcessMemory($script:ProcessHandle, $Address, $buffer, 4, [ref]$bytesRead)
    if (-not $ok -or $bytesRead.ToInt64() -ne 4) { return $null }
    return [BitConverter]::ToInt32($buffer, 0)
}

function Read-Bytes([IntPtr]$Address, [int]$Count) {
    if ($script:ProcessHandle -eq [IntPtr]::Zero -or $Count -le 0 -or $Count -gt 4096) { return $null }
    [byte[]]$buffer = New-Object byte[] $Count
    [IntPtr]$bytesRead = [IntPtr]::Zero
    $ok = [NativeMemoryV4]::ReadProcessMemory($script:ProcessHandle, $Address, $buffer, $Count, [ref]$bytesRead)
    if (-not $ok -or $bytesRead.ToInt64() -ne $Count) { return $null }
    return $buffer
}

function Read-RemoteFString([int64]$StructAddress) {
    if ($StructAddress -le 0) { return $null }
    $dataPtr = Read-U64 ([IntPtr]$StructAddress)
    if (-not (Is-PlausiblePointer $dataPtr)) { return $null }
    $len = Read-I32 ([IntPtr]($StructAddress + 8))
    $max = Read-I32 ([IntPtr]($StructAddress + 12))
    if ($null -eq $len -or $null -eq $max -or $len -le 0 -or $len -gt 128 -or $max -lt $len -or $max -gt 256) { return $null }
    $bytes = Read-Bytes ([IntPtr][int64]$dataPtr) ([int]$len * 2)
    if ($null -eq $bytes) { return $null }
    try {
        return ([System.Text.Encoding]::Unicode.GetString($bytes)).TrimEnd([char]0)
    } catch { return $null }
}

function Find-FStringOffsetByExactValue([int64]$ObjectAddress, [string]$Expected) {
    if ($ObjectAddress -le 0 -or [string]::IsNullOrWhiteSpace($Expected)) { return [int64]-1 }
    for ($off = 0x100; $off -le 0x700; $off += 8) {
        $v = Read-RemoteFString ($ObjectAddress + $off)
        if ($null -ne $v -and [string]$v -ceq [string]$Expected) { return [int64]$off }
    }
    return [int64]-1
}

function Try-CalibratePlayerNameOffset {
    if ($script:PlayerNameOffset -ge 0) { return $true }
    foreach ($k in @($script:SpawnedBotNames.Keys)) {
        try { $ps = [Convert]::ToInt64([string]$k, 16) } catch { continue }
        $expected = [string]$script:SpawnedBotNames[$k]
        $off = Find-FStringOffsetByExactValue $ps $expected
        if ($off -ge 0) {
            $script:PlayerNameOffset = [int64]$off
            return $true
        }
    }
    return $false
}

function Get-PlayerStateName([int64]$PlayerStateAddress) {
    if ($PlayerStateAddress -le 0) { return $null }
    $key = "{0:X}" -f [uint64]$PlayerStateAddress
    if ($script:SpawnedBotNames.ContainsKey($key)) { return [string]$script:SpawnedBotNames[$key] }
    if ($script:PlayerNameOffset -lt 0) { [void](Try-CalibratePlayerNameOffset) }
    if ($script:PlayerNameOffset -ge 0) {
        return Read-RemoteFString ($PlayerStateAddress + $script:PlayerNameOffset)
    }
    return $null
}


function Get-PawnClassName([int64]$ShipAddress) {
    if ($ShipAddress -le 0 -or $script:ModuleBase -eq [IntPtr]::Zero) { return $null }

    $classPtr = Read-U64 ([IntPtr]($ShipAddress + 0x10))
    if (-not (Is-PlausiblePointer $classPtr)) { return $null }
    $classKey = "{0:X}" -f [uint64]$classPtr

    if ($script:PawnClassNameCache.ContainsKey($classKey)) {
        $cached = [string]$script:PawnClassNameCache[$classKey]
        if ([string]::IsNullOrWhiteSpace($cached)) { return $null }
        return $cached
    }

    $rawClassName = ""
    try {
        $rawClassName = [NativeMemoryV4]::GetUObjectNameNative(
            $script:ProcessHandle,
            [uint64]$script:ModuleBase.ToInt64(),
            [uint64]$classPtr)
    } catch { $rawClassName = "" }

    $script:PawnClassNameCache[$classKey] = [string]$rawClassName
    if ([string]::IsNullOrWhiteSpace($rawClassName)) { return $null }
    return $rawClassName
}

function Test-IsMinorShipPawn([int64]$ShipAddress) {
    if ($ShipAddress -le 0) { return $false }
    $rawClassName = Get-PawnClassName $ShipAddress
    if ([string]::IsNullOrWhiteSpace($rawClassName)) { return $false }
    $n = ($rawClassName -replace '[^A-Za-z0-9]', '').ToLowerInvariant()

    # Final Stand's escort/frigate craft are spawned through ServerSpawnSmallAIShip
    # and should not be treated as full-size team ships in the manager.
    if ($n.Contains('smallbeamship'))       { return $true }
    if ($n.Contains('smallgunnership'))     { return $true }
    if ($n.Contains('smallhealership'))     { return $true }
    if ($n.Contains('smallkamikaziship'))   { return $true }
    if ($n.Contains('smallmissileship'))    { return $true }
    if ($n.Contains('smallmissile'))        { return $true }
    if ($n.Contains('basefrigate'))         { return $true }
    if ($n.Contains('smlfrigate'))          { return $true }
    if ($n.Contains('smallfrigate'))        { return $true }
    if ($n.Contains('corvette'))            { return $true }
    if ($n.Contains('smallship'))           { return $true }
    return $false
}

function Get-NativeShipGuid([int64]$ShipAddress) {
    if ($ShipAddress -le 0) { return $null }
    $key = "{0:X}" -f [uint64]$ShipAddress
    if ($script:ShipGuidCache.ContainsKey($key)) {
        $cached = [string]$script:ShipGuidCache[$key]
        if ([string]::IsNullOrWhiteSpace($cached)) { return $null }
        return $cached
    }

    $guid = ""
    try {
        $guid = [NativeMemoryV4]::GetShipGuidNative(
            $script:ProcessHandle,
            [uint64]$script:ModuleBase.ToInt64(),
            [uint64]$ShipAddress)
    } catch { $guid = "" }

    $script:ShipGuidCache[$key] = [string]$guid
    if ([string]::IsNullOrWhiteSpace($guid)) { return $null }
    return $guid.ToUpperInvariant()
}

function Get-ShipNameFromPlayerState([int64]$PlayerStateAddress, [int64]$ShipAddress = 0) {
    if ($ShipAddress -le 0 -and $PlayerStateAddress -gt 0) {
        try {
            $resolvedShip = Resolve-ShipFromPlayerState $PlayerStateAddress
            if ($null -ne $resolvedShip) { $ShipAddress = [int64]$resolvedShip }
        } catch { }
    }

    if ($ShipAddress -gt 0) {
        # Use the ship's own GetShipGUID virtual getter first. Final Stand itself
        # calls this getter when it needs the live capital ship identity.
        $nativeGuid = Get-NativeShipGuid ([int64]$ShipAddress)
        if (-not [string]::IsNullOrWhiteSpace($nativeGuid) -and $GUID_TO_SHIP.ContainsKey($nativeGuid)) {
            return [string]$GUID_TO_SHIP[$nativeGuid]
        }

        # Fallback for normal trainer-spawned ships / builds where the virtual
        # getter could not be invoked.
        $shipBytes = Read-Bytes ([IntPtr]($ShipAddress + $SHIP_LAYOUT_GUID_OFFSET)) 16
        if ($null -ne $shipBytes) {
            try {
                $shipGuid = ("{0:X8}{1:X8}{2:X8}{3:X8}" -f [BitConverter]::ToUInt32($shipBytes,0), [BitConverter]::ToUInt32($shipBytes,4), [BitConverter]::ToUInt32($shipBytes,8), [BitConverter]::ToUInt32($shipBytes,12))
                if ($GUID_TO_SHIP.ContainsKey($shipGuid)) { return [string]$GUID_TO_SHIP[$shipGuid] }
            } catch { }
        }
    }

    if ($PlayerStateAddress -gt 0) {
        $bytes = Read-Bytes ([IntPtr]($PlayerStateAddress + $PLAYERSTATE_DESIRED_SHIP_GUID_OFFSET)) 16
        if ($null -ne $bytes) {
            try {
                $guid = ("{0:X8}{1:X8}{2:X8}{3:X8}" -f [BitConverter]::ToUInt32($bytes,0), [BitConverter]::ToUInt32($bytes,4), [BitConverter]::ToUInt32($bytes,8), [BitConverter]::ToUInt32($bytes,12))
                if ($GUID_TO_SHIP.ContainsKey($guid)) { return [string]$GUID_TO_SHIP[$guid] }
            } catch { }
        }
    }
    return "Unknown ship"
}

function Is-PlausiblePointer($Value) {
    if ($null -eq $Value) { return $false }
    try { return ([uint64]$Value -ge [uint64]0x10000) } catch { return $false }
}

function Is-PlausibleHealth($Value) {
    if ($null -eq $Value) { return $false }
    $v = [double]$Value
    if ([double]::IsNaN($v) -or [double]::IsInfinity($v)) { return $false }
    return ($v -ge 0 -and $v -le 100000000)
}

function Resolve-PlayerShipAddress {
    if ($script:ModuleBase -eq [IntPtr]::Zero) { return $null }

    $baseAddress = [IntPtr]($script:ModuleBase.ToInt64() + $BASE_OFFSET)
    $ptr = Read-U64 $baseAddress
    if (-not (Is-PlausiblePointer $ptr)) { return $null }

    foreach ($offset in $DEREF_TO_SHIP_OFFSETS) {
        $readAt = [IntPtr]([int64]$ptr + $offset)
        $ptr = Read-U64 $readAt
        if (-not (Is-PlausiblePointer $ptr)) { return $null }
    }

    return [IntPtr]([int64]$ptr)
}

function Resolve-HealthAddress {
    $ship = Resolve-PlayerShipAddress
    if ($null -eq $ship) { return $null }

    $healthComponent = Read-U64 ([IntPtr]($ship.ToInt64() + $SHIP_HEALTH_COMPONENT_OFFSET))
    if (-not (Is-PlausiblePointer $healthComponent)) { return $null }

    return [IntPtr]([int64]$healthComponent + $CURRENT_HEALTH_OFFSET)
}

function Get-LocalPlayerStateInfo {
    $ship = Resolve-PlayerShipAddress
    if ($null -eq $ship) { return $null }

    $playerState = Read-U64 ([IntPtr]($ship.ToInt64() + $PAWN_PLAYERSTATE_OFFSET))
    if (-not (Is-PlausiblePointer $playerState)) { return $null }

    $team = Read-U8 ([IntPtr]([int64]$playerState + $PLAYERSTATE_TEAM_OFFSET))
    if ($null -eq $team) { return $null }

    $classPtr = Read-U64 ([IntPtr]([int64]$playerState + 0x10))
    if (-not (Is-PlausiblePointer $classPtr)) { return $null }

    return [pscustomobject]@{
        Ship = [int64]$ship.ToInt64()
        PlayerState = [int64]$playerState
        Team = [int]$team
        ClassPtr = [uint64]$classPtr
    }
}


function Get-EnemyTeamId {
    $local = Get-LocalPlayerStateInfo
    if ($null -eq $local) { return -1 }

    # Prefer the real GameState.PlayerArray so we do not guess team ids.
    if ($script:PlayerStateAddresses.Count -eq 0) {
        try {
            $snap = Get-DirectPlayerStateSnapshot
            if ($null -ne $snap -and $null -ne $snap.States) {
                $script:PlayerStateAddresses = @($snap.States | Where-Object { $null -ne $_ -and [int64]$_ -gt 0 } | Sort-Object -Unique)
                if ([int64]$snap.Level -gt 0) {
                    $script:CurrentLevelAddress = [int64]$snap.Level
                    Refresh-LevelPawnCache ([int64[]]$script:PlayerStateAddresses) $script:CurrentLevelAddress
                }
            }
        } catch { }
    }

    $counts = @{}
    foreach ($psRaw in @($script:PlayerStateAddresses)) {
        $ps = [int64]$psRaw
        if ($ps -le 0 -or $ps -eq [int64]$local.PlayerState) { continue }
        $t = Read-U8 ([IntPtr]($ps + $PLAYERSTATE_TEAM_OFFSET))
        if ($null -eq $t) { continue }
        $ti = [int]$t
        if ($ti -lt 0 -or $ti -gt 16 -or $ti -eq [int]$local.Team) { continue }
        if (-not $counts.ContainsKey($ti)) { $counts[$ti] = 0 }
        $counts[$ti] = [int]$counts[$ti] + 1
    }

    if ($counts.Count -gt 0) {
        $best = $counts.GetEnumerator() | Sort-Object -Property @{Expression={$_.Value};Descending=$true}, @{Expression={$_.Key};Descending=$false} | Select-Object -First 1
        $script:LastEnemyTeamId = [int]$best.Key
        return [int]$script:LastEnemyTeamId
    }

    if ($script:LastEnemyTeamId -ge 0 -and $script:LastEnemyTeamId -ne [int]$local.Team) {
        return [int]$script:LastEnemyTeamId
    }

    # Fallback only when the enemy roster is temporarily empty (for example after
    # Delete All Enemies). Fractured Space standard matches use the opposite 1/2 side.
    if ([int]$local.Team -eq 1) { $script:LastEnemyTeamId = 2 }
    elseif ([int]$local.Team -eq 2) { $script:LastEnemyTeamId = 1 }
    elseif ([int]$local.Team -eq 0) { $script:LastEnemyTeamId = 1 }
    else { $script:LastEnemyTeamId = ([int]$local.Team -bxor 1) }
    return [int]$script:LastEnemyTeamId
}

function Resolve-ShipFromPlayerState([int64]$PlayerStateAddress) {
    if ($PlayerStateAddress -le 0) { return $null }
    $key = "{0:X}" -f [uint64]$PlayerStateAddress

    # Prefer a controller we have already validated. PlayerState.Owner can briefly
    # be null/stale during spawn and respawn, while the controller itself survives.
    if ($script:ControllerCache.ContainsKey($key)) {
        $cached = [int64]$script:ControllerCache[$key]
        if ($cached -gt 0) {
            $controllerPs = Read-U64 ([IntPtr]($cached + $CONTROLLER_PLAYERSTATE_OFFSET))
            if ($null -ne $controllerPs -and [uint64]$controllerPs -eq [uint64]$PlayerStateAddress) {
                $pawn = Read-U64 ([IntPtr]($cached + $CONTROLLER_PAWN_OFFSET))
                if (Is-PlausiblePointer $pawn) {
                    $backPs = Read-U64 ([IntPtr]([int64]$pawn + $PAWN_PLAYERSTATE_OFFSET))
                    if ($null -ne $backPs -and [uint64]$backPs -eq [uint64]$PlayerStateAddress) {
                        $script:PawnCache[$key] = [int64]$pawn
                        return [int64]$pawn
                    }
                }
            }
        }
    }

    # Fallback discovered from ULevel.Actors. This is useful when PlayerState.Owner
    # is temporarily unavailable, and it avoids the weak AssociatedShipPawn field.
    if ($script:PawnCache.ContainsKey($key)) {
        $cachedPawn = [int64]$script:PawnCache[$key]
        if ($cachedPawn -gt 0) {
            $backPs = Read-U64 ([IntPtr]($cachedPawn + $PAWN_PLAYERSTATE_OFFSET))
            if ($null -ne $backPs -and [uint64]$backPs -eq [uint64]$PlayerStateAddress) {
                return $cachedPawn
            } else {
                [void]$script:PawnCache.Remove($key)
            }
        }
    }

    $controller = Read-U64 ([IntPtr]($PlayerStateAddress + $ACTOR_OWNER_OFFSET))
    if (-not (Is-PlausiblePointer $controller)) { return $null }

    $controllerPs = Read-U64 ([IntPtr]([int64]$controller + $CONTROLLER_PLAYERSTATE_OFFSET))
    if ($null -eq $controllerPs -or [uint64]$controllerPs -ne [uint64]$PlayerStateAddress) { return $null }

    $script:ControllerCache[$key] = [int64]$controller
    $pawn = Read-U64 ([IntPtr]([int64]$controller + $CONTROLLER_PAWN_OFFSET))
    if (-not (Is-PlausiblePointer $pawn)) { return $null }

    $backPs = Read-U64 ([IntPtr]([int64]$pawn + $PAWN_PLAYERSTATE_OFFSET))
    if ($null -eq $backPs -or [uint64]$backPs -ne [uint64]$PlayerStateAddress) { return $null }

    $script:PawnCache[$key] = [int64]$pawn
    return [int64]$pawn
}

function Get-DirectPlayerStateSnapshot {
    $local = Get-LocalPlayerStateInfo
    if ($null -eq $local) {
        return [pscustomobject]@{ Success=$false; States=@(); Level=[int64]0; Detail="local ship/player state not ready" }
    }

    $level = Read-U64 ([IntPtr]([int64]$local.Ship + $UOBJECT_OUTER_OFFSET))
    if (-not (Is-PlausiblePointer $level)) {
        return [pscustomobject]@{ Success=$false; States=@([int64]$local.PlayerState); Level=[int64]0; Detail="ship -> level failed" }
    }

    $world = Read-U64 ([IntPtr]([int64]$level + $LEVEL_OWNING_WORLD_OFFSET))
    if (-not (Is-PlausiblePointer $world)) {
        # ULevel normally also has the UWorld as its UObject Outer.
        $world = Read-U64 ([IntPtr]([int64]$level + $UOBJECT_OUTER_OFFSET))
    }
    if (-not (Is-PlausiblePointer $world)) {
        return [pscustomobject]@{ Success=$false; States=@([int64]$local.PlayerState); Level=[int64]$level; Detail="level -> world failed" }
    }

    $gameState = Read-U64 ([IntPtr]([int64]$world + $WORLD_GAMESTATE_OFFSET))
    if (-not (Is-PlausiblePointer $gameState)) {
        return [pscustomobject]@{ Success=$false; States=@([int64]$local.PlayerState); Level=[int64]$level; Detail="world -> game state failed" }
    }

    $arrayBase = [int64]$gameState + $GAMESTATE_PLAYERARRAY_OFFSET
    $data = Read-U64 ([IntPtr]$arrayBase)
    $num = Read-I32 ([IntPtr]($arrayBase + 8))
    $max = Read-I32 ([IntPtr]($arrayBase + 12))
    if (-not (Is-PlausiblePointer $data)) {
        return [pscustomobject]@{ Success=$false; States=@([int64]$local.PlayerState); Level=[int64]$level; Detail="PlayerArray data pointer invalid" }
    }
    if ($null -eq $num -or $null -eq $max -or $num -lt 1 -or $num -gt 64 -or $max -lt $num -or $max -gt 128) {
        return [pscustomobject]@{ Success=$false; States=@([int64]$local.PlayerState); Level=[int64]$level; Detail="PlayerArray header invalid (Num=$num Max=$max)" }
    }

    $states = @()
    for ($i = 0; $i -lt $num; $i++) {
        $ps = Read-U64 ([IntPtr]([int64]$data + ($i * 8)))
        if (Is-PlausiblePointer $ps) { $states += [int64]$ps }
    }
    if ($states -notcontains [int64]$local.PlayerState) { $states += [int64]$local.PlayerState }
    $states = @($states | Sort-Object -Unique)

    return [pscustomobject]@{
        Success = $true
        States = $states
        Level = [int64]$level
        Detail = "direct PlayerArray: $($states.Count)/$num readable"
    }
}

function Refresh-LevelPawnCache([int64[]]$States, [int64]$LevelAddress) {
    if ($LevelAddress -le 0 -or $null -eq $States -or $States.Count -eq 0) { return }

    $wanted = @{}
    foreach ($psRaw in @($States)) {
        $ps = [int64]$psRaw
        if ($ps -gt 0) { $wanted[("{0:X}" -f [uint64]$ps)] = $ps }
    }
    if ($wanted.Count -eq 0) { return }

    # First use the normal Owner -> Controller -> Pawn route. It is cheap and
    # usually resolves most players immediately.
    foreach ($ps in @($wanted.Values)) {
        $ship = Resolve-ShipFromPlayerState ([int64]$ps)
        if ($null -ne $ship -and [int64]$ship -gt 0) {
            [void]$wanted.Remove(("{0:X}" -f [uint64]$ps))
        }
    }
    if ($wanted.Count -eq 0) { return }

    # Remaining states are matched against ULevel.Actors by APawn.PlayerState.
    # This is deterministic and avoids scanning hundreds of MB for same-class objects.
    $actorsBase = $LevelAddress + $LEVEL_ACTORS_OFFSET
    $actorData = Read-U64 ([IntPtr]$actorsBase)
    $actorNum = Read-I32 ([IntPtr]($actorsBase + 8))
    $actorMax = Read-I32 ([IntPtr]($actorsBase + 12))
    if (-not (Is-PlausiblePointer $actorData) -or $null -eq $actorNum -or $null -eq $actorMax -or
        $actorNum -lt 1 -or $actorNum -gt 12000 -or $actorMax -lt $actorNum -or $actorMax -gt 20000) { return }

    for ($i = 0; $i -lt $actorNum; $i++) {
        if ($wanted.Count -eq 0) { break }
        $actor = Read-U64 ([IntPtr]([int64]$actorData + ($i * 8)))
        if (-not (Is-PlausiblePointer $actor)) { continue }
        $ps = Read-U64 ([IntPtr]([int64]$actor + $PAWN_PLAYERSTATE_OFFSET))
        if (-not (Is-PlausiblePointer $ps)) { continue }
        $key = "{0:X}" -f [uint64]$ps
        if (-not $wanted.ContainsKey($key)) { continue }

        $script:PawnCache[$key] = [int64]$actor
        $controller = Read-U64 ([IntPtr]([int64]$actor + $PAWN_CONTROLLER_OFFSET))
        if (Is-PlausiblePointer $controller) {
            $controllerPs = Read-U64 ([IntPtr]([int64]$controller + $CONTROLLER_PLAYERSTATE_OFFSET))
            if ($null -ne $controllerPs -and [uint64]$controllerPs -eq [uint64]$ps) {
                $script:ControllerCache[$key] = [int64]$controller
            }
        }
        [void]$wanted.Remove($key)
    }
}

function Start-PlayerStateDiscovery([bool]$Quiet = $false) {
    if ($script:ScanningPlayers) { return $false }
    if ($script:ProcessHandle -eq [IntPtr]::Zero) { return $false }

    $script:ScanningPlayers = $true
    $script:ScanAttempted = $true
    $script:ScanQuiet = $Quiet
    try {
        if (-not $Quiet) {
            if ($null -ne $allyInfoLabel) {
                $allyInfoLabel.Text = "Allied bots: reading GameState.PlayerArray..."
                $allyInfoLabel.ForeColor = [System.Drawing.Color]::Khaki
            }
            if ($null -ne $enemyInfoLabel) {
                $enemyInfoLabel.Text = "Enemy bots: reading GameState.PlayerArray..."
                $enemyInfoLabel.ForeColor = [System.Drawing.Color]::Khaki
            }
            [System.Windows.Forms.Application]::DoEvents()
        }

        $snap = Get-DirectPlayerStateSnapshot
        $script:LastDirectDiscoveryDetail = [string]$snap.Detail
        $script:CurrentLevelAddress = [int64]$snap.Level

        $combined = @($snap.States)
        foreach ($entry in @($script:TrackedAllies.Values)) {
            if ($null -ne $entry -and [int64]$entry.PlayerState -gt 0) { $combined += [int64]$entry.PlayerState }
        }
        $script:PlayerStateAddresses = @($combined | Where-Object { $null -ne $_ -and [int64]$_ -gt 0 } | Sort-Object -Unique)

        if ($script:CurrentLevelAddress -gt 0 -and $script:PlayerStateAddresses.Count -gt 0) {
            Refresh-LevelPawnCache ([int64[]]$script:PlayerStateAddresses) $script:CurrentLevelAddress
        }
        [void](Get-EnemyTeamId)
        $script:LastRosterSignature = ""
        $script:LastEnemyRosterSignature = ""

        if (-not $Quiet) {
            if ($snap.Success) {
                if ($null -ne $allyInfoLabel) {
                    $allyInfoLabel.Text = "Allied bots: $($script:PlayerStateAddresses.Count) real player states - resolving ships..."
                    $allyInfoLabel.ForeColor = [System.Drawing.Color]::LightGreen
                }
                if ($null -ne $enemyInfoLabel) {
                    $enemyInfoLabel.Text = "Enemy bots: $($script:PlayerStateAddresses.Count) real player states - resolving ships..."
                    $enemyInfoLabel.ForeColor = [System.Drawing.Color]::LightGreen
                }
            } else {
                if ($null -ne $allyInfoLabel) {
                    $allyInfoLabel.Text = "Allied bots: direct list unavailable; spawned allies still tracked"
                    $allyInfoLabel.ForeColor = [System.Drawing.Color]::Khaki
                }
                if ($null -ne $enemyInfoLabel) {
                    $enemyInfoLabel.Text = "Enemy bots: direct list unavailable; spawned enemies still tracked"
                    $enemyInfoLabel.ForeColor = [System.Drawing.Color]::Khaki
                }
            }
        }
        return [bool]$snap.Success
    } catch {
        $script:LastDirectDiscoveryDetail = "direct discovery exception: $($_.Exception.Message)"
        if (-not $Quiet) {
            if ($null -ne $allyInfoLabel) {
                $allyInfoLabel.Text = "Allied bots: direct refresh error - spawned allies still tracked"
                $allyInfoLabel.ForeColor = [System.Drawing.Color]::Salmon
            }
            if ($null -ne $enemyInfoLabel) {
                $enemyInfoLabel.Text = "Enemy bots: direct refresh error - spawned enemies still tracked"
                $enemyInfoLabel.ForeColor = [System.Drawing.Color]::Salmon
            }
        }
        return $false
    } finally {
        $script:ScanningPlayers = $false
        $script:ScanTask = $null
        $script:ScanQuiet = $false
        if ($script:AllyGodEnabled -or $script:EnemyGodEnabled) {
            $script:NextAutoRescanAt = [DateTime]::UtcNow.AddSeconds(5)
        }
    }
}

function Poll-PlayerStateDiscovery {
    # FIX5 uses the game's GameState.PlayerArray directly; there is no background
    # process-wide memory scan to poll.
    return
}

function Update-TeamGod([int]$TargetTeam, $Locks, $InfoLabel, [string]$Prefix, [bool]$Enabled, [bool]$MajorOnly = $false) {
    if (-not $Enabled) { return }

    $local = Get-LocalPlayerStateInfo
    if ($null -eq $local) {
        $InfoLabel.Text = "$Prefix bots: waiting for your ship..."
        $InfoLabel.ForeColor = [System.Drawing.Color]::Khaki
        return
    }
    if ($TargetTeam -lt 0) {
        $InfoLabel.Text = "$Prefix bots: waiting for team data..."
        $InfoLabel.ForeColor = [System.Drawing.Color]::Khaki
        return
    }

    if ($script:PlayerStateAddresses.Count -eq 0) {
        if (-not $script:ScanningPlayers -and $script:ScanAttempted) {
            $InfoLabel.Text = "$Prefix bots: searching automatically..."
            $InfoLabel.ForeColor = [System.Drawing.Color]::Khaki
        }
        return
    }

    $sameTeam = 0
    $waitingForShip = 0
    $lockedCount = 0

    foreach ($psRaw in @($script:PlayerStateAddresses)) {
        $psAddr = [int64]$psRaw
        if ($psAddr -le 0) { continue }
        if ($psAddr -eq [int64]$local.PlayerState) { continue }

        $team = Read-U8 ([IntPtr]($psAddr + $PLAYERSTATE_TEAM_OFFSET))
        if ($null -eq $team -or [int]$team -ne $TargetTeam) { continue }

        $ship = Resolve-ShipFromPlayerState $psAddr
        if ($null -eq $ship) { $waitingForShip++; continue }
        if ($MajorOnly -and (Test-IsMinorShipPawn ([int64]$ship))) { continue }
        $sameTeam++

        $healthComponent = Read-U64 ([IntPtr]([int64]$ship + $SHIP_HEALTH_COMPONENT_OFFSET))
        if (-not (Is-PlausiblePointer $healthComponent)) { $waitingForShip++; continue }

        $healthAddress = [int64]$healthComponent + $CURRENT_HEALTH_OFFSET
        $hp = Read-F32 ([IntPtr]$healthAddress)
        if (-not (Is-PlausibleHealth $hp)) { $waitingForShip++; continue }

        $key = "{0:X}" -f [uint64]$psAddr
        $lock = $Locks[$key]
        if ($null -eq $lock -or [int64]$lock.HealthAddress -ne $healthAddress) {
            $lock = [pscustomobject]@{
                ShipAddress = [int64]$ship
                HealthAddress = [int64]$healthAddress
                LockedHealth = [single]$hp
            }
            $Locks[$key] = $lock
        } else {
            $lock.ShipAddress = [int64]$ship
            if ([single]$hp -gt [single]$lock.LockedHealth) { $lock.LockedHealth = [single]$hp }
        }

        if (Write-F32 ([IntPtr]$healthAddress) ([single]$lock.LockedHealth)) { $lockedCount++ }
    }

    if ($sameTeam -gt 0) {
        if ($waitingForShip -gt 0) {
            $InfoLabel.Text = "$Prefix bots: $lockedCount locked / $sameTeam ships ($waitingForShip spawning/respawning)"
            $InfoLabel.ForeColor = [System.Drawing.Color]::Khaki
        } else {
            $InfoLabel.Text = "$Prefix bots: $lockedCount locked / $sameTeam ships"
            $InfoLabel.ForeColor = [System.Drawing.Color]::LightGreen
        }
    } else {
        $InfoLabel.Text = "$Prefix bots: searching - $($script:PlayerStateAddresses.Count) player states cached"
        $InfoLabel.ForeColor = [System.Drawing.Color]::Khaki
    }
}

function Update-AllyGod {
    $local = Get-LocalPlayerStateInfo
    if ($null -eq $local) {
        if ($script:AllyGodEnabled) {
            $allyInfoLabel.Text = "Allied bots: waiting for your ship..."
            $allyInfoLabel.ForeColor = [System.Drawing.Color]::Khaki
        }
        return
    }
    Update-TeamGod ([int]$local.Team) $script:TeamLocks $allyInfoLabel "Allied" $script:AllyGodEnabled
}

function Update-EnemyGod {
    $enemyTeam = Get-EnemyTeamId
    Update-TeamGod ([int]$enemyTeam) $script:EnemyLocks $enemyInfoLabel "Enemy" $script:EnemyGodEnabled $true
}

function Register-TrackedAlly([int64]$Controller, [string]$ShipName, [int]$Team, [string]$BotName) {
    if ($Controller -le 0) { return }
    $ckey = "{0:X}" -f [uint64]$Controller
    $existing = $script:TrackedAllies[$ckey]
    if ($null -eq $existing) {
        $script:TrackedAllies[$ckey] = [pscustomobject]@{
            Controller = [int64]$Controller
            PlayerState = [int64]0
            Pawn = [int64]0
            Ship = if ([string]::IsNullOrWhiteSpace($ShipName)) { "Unknown ship" } else { [string]$ShipName }
            Team = [int]$Team
            Name = [string]$BotName
            AddedAt = [DateTime]::UtcNow
        }
    } else {
        if (-not [string]::IsNullOrWhiteSpace($ShipName)) { $existing.Ship = [string]$ShipName }
        if (-not [string]::IsNullOrWhiteSpace($BotName)) { $existing.Name = [string]$BotName }
        $existing.Team = [int]$Team
    }
    $script:LastRosterSignature = ""
    $script:LastEnemyRosterSignature = ""
}

function Update-TrackedAllyPointers([int64]$Controller) {
    if ($Controller -le 0) { return $null }
    $ckey = "{0:X}" -f [uint64]$Controller
    $entry = $script:TrackedAllies[$ckey]
    if ($null -eq $entry) { return $null }

    $ps = Read-U64 ([IntPtr]($Controller + $CONTROLLER_PLAYERSTATE_OFFSET))
    if (Is-PlausiblePointer $ps) {
        $entry.PlayerState = [int64]$ps
        $pkey = "{0:X}" -f [uint64]$ps
        $script:ControllerCache[$pkey] = [int64]$Controller
        $script:PlayerStateAddresses = @((@($script:PlayerStateAddresses) + [int64]$ps) | Sort-Object -Unique)
        if (-not [string]::IsNullOrWhiteSpace([string]$entry.Name)) {
            $script:SpawnedBotNames[$pkey] = [string]$entry.Name
        }
    }

    $pawn = Read-U64 ([IntPtr]($Controller + $CONTROLLER_PAWN_OFFSET))
    if (Is-PlausiblePointer $pawn) {
        $entry.Pawn = [int64]$pawn
        if ([int64]$entry.PlayerState -gt 0) {
            $pkey = "{0:X}" -f [uint64]$entry.PlayerState
            $script:PawnCache[$pkey] = [int64]$pawn
        }
    }
    return $entry
}

function Pump-PendingSpawnControllers {
    if ($script:ProcessHandle -eq [IntPtr]::Zero) { return }

    # First refresh every controller we already own. This is independent of the
    # PlayerState scanner, so spawned allies still appear in the list even when
    # the generic scan misses them.
    foreach ($ckey in @($script:TrackedAllies.Keys)) {
        $entry = $script:TrackedAllies[$ckey]
        if ($null -eq $entry) { continue }
        [void](Update-TrackedAllyPointers ([int64]$entry.Controller))
    }

    if ($null -eq $script:PendingSpawnControllers -or $script:PendingSpawnControllers.Count -eq 0) { return }
    $keep = @()
    foreach ($pending in @($script:PendingSpawnControllers)) {
        if ($null -eq $pending) { continue }
        $controller = [int64]$pending.Controller
        if ($controller -le 0) { continue }

        $entry = Update-TrackedAllyPointers $controller
        $ready = ($null -ne $entry -and [int64]$entry.PlayerState -gt 0 -and [int64]$entry.Pawn -gt 0)
        if (-not $ready) {
            $age = ([DateTime]::UtcNow - [DateTime]$pending.AddedAt).TotalSeconds
            if ($age -lt 20) { $keep += $pending }
        }
    }
    $script:PendingSpawnControllers = @($keep)
}

function Get-SpawnDifficultyByte {
    if ($null -eq $difficultyCombo -or $difficultyCombo.SelectedIndex -lt 0) { return [byte]4 }
    return [byte]$difficultyCombo.SelectedIndex
}

function Get-EnemySpawnDifficultyByte {
    if ($null -eq $enemyDifficultyCombo -or $enemyDifficultyCombo.SelectedIndex -lt 0) { return [byte]4 }
    return [byte]$enemyDifficultyCombo.SelectedIndex
}

function Get-BotDifficultyName([int]$Value) {
    switch ($Value) {
        0 { return "Easy 1" }
        1 { return "Easy 2" }
        2 { return "Easy 3" }
        3 { return "Medium 1" }
        4 { return "Medium 2" }
        5 { return "Medium 3" }
        6 { return "Hard 1" }
        7 { return "Hard 2" }
        8 { return "Hard 3" }
        9 { return "Milcho Bot" }
        default { return "Unknown ($Value)" }
    }
}

function Get-ActualBotDifficultyName([int64]$Controller) {
    if ($Controller -le 0) { return "N/A" }
    $v = Read-U8 ([IntPtr]($Controller + $BOT_DIFFICULTY_TYPE_OFFSET))
    if ($null -eq $v) { return "N/A" }
    if ([int]$v -lt 0 -or [int]$v -gt 9) { return "N/A" }
    return (Get-BotDifficultyName ([int]$v))
}

function Format-DifficultyDebugFloat($Value) {
    if ($null -eq $Value) { return "N/A" }
    $d = [double]$Value
    if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return "N/A" }
    return ("{0:0.####}" -f $d)
}

function Format-DifficultyDebugRange([int64]$Base, [int64]$Offset) {
    $a = Read-F32 ([IntPtr]($Base + $Offset))
    $b = Read-F32 ([IntPtr]($Base + $Offset + 4))
    return ((Format-DifficultyDebugFloat $a) + " .. " + (Format-DifficultyDebugFloat $b))
}

function Write-DifficultyDebugReport([int64]$Controller, [string]$ShipName, [int]$RequestedDifficulty, [string]$Side) {
    if (-not $script:DebugConsoleEnabled) { return }
    if ($Controller -le 0) { return }

    $requestedName = Get-BotDifficultyName $RequestedDifficulty
    $liveRaw = Read-U8 ([IntPtr]($Controller + $BOT_DIFFICULTY_TYPE_OFFSET))
    $presetBase = [int64]($Controller + $BOT_ACTIVE_DIFFICULTY_PRESET_OFFSET)
    $presetRaw = Read-U8 ([IntPtr]$presetBase)

    $liveName = if ($null -eq $liveRaw) { "N/A" } else { Get-BotDifficultyName ([int]$liveRaw) }
    $presetName = if ($null -eq $presetRaw) { "N/A" } else { Get-BotDifficultyName ([int]$presetRaw) }

    Write-Host ""
    Write-Host "============================================================"
    Write-Host " BOT DIFFICULTY - LIVE GAME PRESET CHECK"
    Write-Host "============================================================"
    Write-Host (" Side                    : {0}" -f $Side)
    Write-Host (" Ship                    : {0}" -f $ShipName)
    Write-Host (" Controller              : 0x{0:X}" -f $Controller)
    Write-Host (" Requested by trainer    : {0}  (raw {1})" -f $requestedName, $RequestedDifficulty)
    Write-Host (" Controller difficulty   : {0}  (raw {1})" -f $liveName, $(if ($null -eq $liveRaw) { "N/A" } else { [string]$liveRaw }))
    Write-Host (" Active preset difficulty: {0}  (raw {1})" -f $presetName, $(if ($null -eq $presetRaw) { "N/A" } else { [string]$presetRaw }))
    Write-Host ""
    Write-Host " Values below are read from the game's ACTIVE BotDifficultyPreset"
    Write-Host (" cached at Controller+0x{0:X} (not copied from the dropdown):" -f $BOT_ACTIVE_DIFFICULTY_PRESET_OFFSET)
    Write-Host ""

    # BotDifficultyPreset layout for this supplied spserver.exe build.
    # The game copies a 0x90-byte preset to Controller+0xDA0 when
    # SetBotDifficultyType applies the selected EBotDifficultyType.
    $fields = @(
        @("ObjectiveLogicPeriod",       0x04),
        @("NavigationLogicPeriod",      0x08),
        @("CustomOrientationLogicPeriod",0x0C),
        @("CheckBeingStuckPeriod",      0x10),
        @("UpgradeLogicPeriod",         0x14),
        @("ChangeWobblePeriod",         0x18),
        @("UnderAttackDefenseFactor",   0x1C),
        @("ObjectiveCompletionFactor",  0x20),
        @("MainFireSequencePeriod",     0x38),
        @("FireAccuracyHoningTime",     0x3C),
        @("AutoAimLeadFactor",          0x40),
        @("MaxTimeKeepLostTarget",      0x44)
    )
    foreach ($field in $fields) {
        $v = Read-F32 ([IntPtr]($presetBase + [int64]$field[1]))
        Write-Host (" {0,-30}: {1}" -f ([string]$field[0]), (Format-DifficultyDebugFloat $v))
    }

    Write-Host (" {0,-30}: {1}" -f "DecisionRandomFactor",              (Format-DifficultyDebugRange $presetBase 0x48))
    Write-Host (" {0,-30}: {1}" -f "FireAccuracyStartFactor",           (Format-DifficultyDebugRange $presetBase 0x50))
    Write-Host (" {0,-30}: {1}" -f "FireAccuracyEndFactor",             (Format-DifficultyDebugRange $presetBase 0x58))
    Write-Host (" {0,-30}: {1}" -f "FireAccuracyWhenLostSight",         (Format-DifficultyDebugRange $presetBase 0x60))
    Write-Host (" {0,-30}: {1}" -f "FireAccuracyRandomizeTime",         (Format-DifficultyDebugRange $presetBase 0x68))
    Write-Host (" {0,-30}: {1}" -f "MinWobbleFactor",                   (Format-DifficultyDebugRange $presetBase 0x70))
    Write-Host (" {0,-30}: {1}" -f "MaxWobbleFactor",                   (Format-DifficultyDebugRange $presetBase 0x78))

    if ($null -ne $liveRaw -and $null -ne $presetRaw -and [int]$liveRaw -eq [int]$presetRaw -and [int]$presetRaw -eq $RequestedDifficulty) {
        Write-Host ""
        Write-Host " RESULT: requested enum, live controller enum, and active preset enum MATCH."
    } else {
        Write-Host ""
        Write-Host " RESULT: one or more difficulty values DO NOT MATCH - check this output."
    }
    Write-Host "============================================================"
    Write-Host ""
}

function Get-SpawnErrorText([int]$Code) {
    switch ($Code) {
        1 { return "could not allocate memory in local server" }
        2 { return "internal payload was too large" }
        3 { return "could not write spawn request" }
        4 { return "could not start local spawn call" }
        5 { return "spawn call timed out (server may still finish it)" }
        6 { return "spawn wait failed" }
        7 { return "could not read spawn result" }
        8 { return "game could not create the selected bot" }
        9 { return "unexpected spawn helper error" }
        10 { return "this spserver.exe build does not match the old spawn helper" }
        11 { return "invalid internal ship GUID" }
        12 { return "this spserver.exe build does not match the ship-menu helpers" }
        13 { return "selected ship GUID was rejected by the game" }
        14 { return "game could not finish creating the bot controller" }
        100 { return "server/ship context is not ready" }
        default { return "unknown spawn error $Code" }
    }
}

function Recover-NewSpawnController($BeforeSnapshot, [int]$Team) {
    # Some PowerShell/.NET builds can report an interop conversion error after
    # the native helper has already completed. Recover the new bot from the
    # authoritative PlayerArray instead of treating that as a failed spawn.
    [System.Threading.Thread]::Sleep(250)
    $after = Get-DirectPlayerStateSnapshot
    if ($null -eq $after -or $null -eq $after.States) { return [int64]0 }

    $before = @{}
    if ($null -ne $BeforeSnapshot -and $null -ne $BeforeSnapshot.States) {
        foreach ($psRaw in @($BeforeSnapshot.States)) {
            $ps = [int64]$psRaw
            if ($ps -gt 0) { $before[("{0:X}" -f [uint64]$ps)] = $true }
        }
    }

    $script:CurrentLevelAddress = [int64]$after.Level
    $script:PlayerStateAddresses = @($after.States | Where-Object { $null -ne $_ -and [int64]$_ -gt 0 } | Sort-Object -Unique)
    if ($script:CurrentLevelAddress -gt 0) {
        Refresh-LevelPawnCache ([int64[]]$script:PlayerStateAddresses) $script:CurrentLevelAddress
    }

    foreach ($psRaw in @($after.States)) {
        $ps = [int64]$psRaw
        if ($ps -le 0) { continue }
        $key = "{0:X}" -f [uint64]$ps
        if ($before.ContainsKey($key)) { continue }
        $t = Read-U8 ([IntPtr]($ps + $PLAYERSTATE_TEAM_OFFSET))
        if ($null -eq $t -or [int]$t -ne $Team) { continue }

        $ship = Resolve-ShipFromPlayerState $ps
        if ($null -eq $ship -or [int64]$ship -le 0) { continue }
        if ($script:ControllerCache.ContainsKey($key)) {
            $c = [int64]$script:ControllerCache[$key]
            if ($c -gt 0) { return $c }
        }
        $c = Read-U64 ([IntPtr]([int64]$ship + $PAWN_CONTROLLER_OFFSET))
        if (Is-PlausiblePointer $c) {
            $script:ControllerCache[$key] = [int64]$c
            return [int64]$c
        }
    }
    return [int64]0
}

function Invoke-SpawnAlliedBot {
    if (-not (Connect-Server)) {
        $spawnInfoLabel.Text = "Spawn: start a solo match first"
        $spawnInfoLabel.ForeColor = [System.Drawing.Color]::Khaki
        return
    }

    $local = Get-LocalPlayerStateInfo
    if ($null -eq $local) {
        $spawnInfoLabel.Text = "Spawn: wait until your ship is fully spawned"
        $spawnInfoLabel.ForeColor = [System.Drawing.Color]::Khaki
        return
    }

    if ($null -eq $shipCombo -or $shipCombo.SelectedIndex -lt 0) {
        $spawnInfoLabel.Text = "Spawn: select a ship first"
        $spawnInfoLabel.ForeColor = [System.Drawing.Color]::Khaki
        return
    }

    $shipName = [string]$shipCombo.SelectedItem
    $shipGuid = [string]$SHIP_GUIDS[$shipName]
    if ([string]::IsNullOrWhiteSpace($shipGuid)) {
        $spawnInfoLabel.Text = "Spawn: no internal GUID for '$shipName'"
        $spawnInfoLabel.ForeColor = [System.Drawing.Color]::Salmon
        return
    }

    $difficulty = Get-SpawnDifficultyByte
    $botName = "TrainerBot_" + [DateTime]::Now.ToString("HHmmssfff")

    $spawnButton.Enabled = $false
    $spawnInfoLabel.Text = "Spawn: creating $shipName on team $($local.Team)..."
    $spawnInfoLabel.ForeColor = [System.Drawing.Color]::Khaki
    [System.Windows.Forms.Application]::DoEvents()

    $beforeSnap = Get-DirectPlayerStateSnapshot
    $controller = [int64]0
    $invokeError = $null
    try {
        $rawController = [NativeMemoryV4]::SpawnBotByGuidNative(
            $script:ProcessHandle,
            [uint64]$script:ModuleBase.ToInt64(),
            [uint64]$local.Ship,
            [byte]$local.Team,
            [byte]$difficulty,
            [string]$botName,
            [string]$shipGuid)
        if ($null -ne $rawController) { $controller = [Convert]::ToInt64($rawController) }
    } catch {
        $invokeError = [string]$_.Exception.Message
    }

    # If the helper side effect succeeded but PowerShell failed while converting
    # the return value, recover the controller from the new PlayerArray entry.
    if ($controller -le 0) {
        $controller = Recover-NewSpawnController $beforeSnap ([int]$local.Team)
    }

    if ($controller -le 0) {
        if (-not [string]::IsNullOrWhiteSpace($invokeError)) {
            $spawnInfoLabel.Text = "Spawn: failed - $invokeError"
        } else {
            $code = [NativeMemoryV4]::LastSpawnError
            $spawnInfoLabel.Text = "Spawn: " + (Get-SpawnErrorText $code)
        }
        $spawnInfoLabel.ForeColor = [System.Drawing.Color]::Salmon
        $spawnButton.Enabled = $true
        return
    }

    # The native spawn succeeded. Never let optional roster/cache work overwrite
    # this with a false "argument types do not match" error afterwards.
    $requestedDifficultyName = Get-BotDifficultyName ([int]$difficulty)
    $actualDifficultyName = Get-ActualBotDifficultyName $controller
    Write-DifficultyDebugReport $controller $shipName ([int]$difficulty) "ALLY"
    if ([string]::IsNullOrWhiteSpace($invokeError)) {
        $spawnInfoLabel.Text = "Spawn: $shipName | requested $requestedDifficultyName | game $actualDifficultyName"
    } else {
        $spawnInfoLabel.Text = "Spawn: $shipName | requested $requestedDifficultyName | game $actualDifficultyName (return recovered)"
    }
    if ($actualDifficultyName -eq $requestedDifficultyName) {
        $spawnInfoLabel.ForeColor = [System.Drawing.Color]::LightGreen
    } else {
        $spawnInfoLabel.ForeColor = [System.Drawing.Color]::Khaki
    }

    # The native call returned the real BotController. Register it immediately so
    # the ally list does not depend on the generic PlayerState memory scan.
    Register-TrackedAlly $controller $shipName ([int]$local.Team) $botName
    # Put the newly-created controller in the visible list immediately.
    $script:LastRosterSignature = ""
    $script:LastEnemyRosterSignature = ""
    try { Refresh-AllyRosterUI $true } catch { }
    try { Refresh-EnemyRosterUI $true } catch { }

    try {
        # PlayerState/Pawn may appear a few frames after the controller. Track the
        # returned controller until its PlayerState becomes ready instead of
        # assuming it exists immediately.
        $script:PendingSpawnControllers = @(
            @($script:PendingSpawnControllers) +
            [pscustomobject]@{
                Controller = $controller
                Name = [string]$botName
                AddedAt = [DateTime]::UtcNow
            }
        )
        Pump-PendingSpawnControllers

        # Always refresh the ally list after a spawn, even if Allied God Mode is off.
        $script:NextRosterRefreshAt = [DateTime]::UtcNow.AddSeconds(1)
        $script:LastRosterSignature = ""

        # Merge-only background discovery catches the new bot plus existing allies.
        if (-not $script:ScanningPlayers) {
            [void](Start-PlayerStateDiscovery $true)
        }

        if ($script:AllyGodEnabled) {
            $script:SpawnRescanAt = [DateTime]::UtcNow.AddSeconds(1.25)
            $script:NextAutoRescanAt = [DateTime]::UtcNow.AddSeconds(10)
        }
    } catch {
        # Spawn already succeeded; roster bookkeeping is best-effort and must not
        # turn a successful spawn into a red failure message.
    } finally {
        # Avoid stacking multiple bot initialization sequences on the same frame.
        [System.Threading.Thread]::Sleep(350)
        $spawnButton.Enabled = $true
    }
}


function Invoke-SpawnEnemyBot {
    if (-not (Connect-Server)) {
        $enemySpawnInfoLabel.Text = "Spawn: start a solo match first"
        $enemySpawnInfoLabel.ForeColor = [System.Drawing.Color]::Khaki
        return
    }

    $local = Get-LocalPlayerStateInfo
    if ($null -eq $local) {
        $enemySpawnInfoLabel.Text = "Spawn: wait until your ship is fully spawned"
        $enemySpawnInfoLabel.ForeColor = [System.Drawing.Color]::Khaki
        return
    }

    $enemyTeam = Get-EnemyTeamId
    if ($enemyTeam -lt 0 -or $enemyTeam -eq [int]$local.Team) {
        $enemySpawnInfoLabel.Text = "Spawn: enemy team could not be resolved yet"
        $enemySpawnInfoLabel.ForeColor = [System.Drawing.Color]::Khaki
        return
    }

    if ($null -eq $enemyShipCombo -or $enemyShipCombo.SelectedIndex -lt 0) {
        $enemySpawnInfoLabel.Text = "Spawn: select a ship first"
        $enemySpawnInfoLabel.ForeColor = [System.Drawing.Color]::Khaki
        return
    }

    $shipName = [string]$enemyShipCombo.SelectedItem
    $shipGuid = [string]$SHIP_GUIDS[$shipName]
    if ([string]::IsNullOrWhiteSpace($shipGuid)) {
        $enemySpawnInfoLabel.Text = "Spawn: no internal GUID for '$shipName'"
        $enemySpawnInfoLabel.ForeColor = [System.Drawing.Color]::Salmon
        return
    }

    $difficulty = Get-EnemySpawnDifficultyByte
    $botName = "TrainerEnemy_" + [DateTime]::Now.ToString("HHmmssfff")

    $enemySpawnButton.Enabled = $false
    $enemySpawnInfoLabel.Text = "Spawn: creating $shipName on enemy team $enemyTeam..."
    $enemySpawnInfoLabel.ForeColor = [System.Drawing.Color]::Khaki
    [System.Windows.Forms.Application]::DoEvents()

    $beforeSnap = Get-DirectPlayerStateSnapshot
    $controller = [int64]0
    $invokeError = $null
    try {
        $rawController = [NativeMemoryV4]::SpawnBotByGuidNative(
            $script:ProcessHandle,
            [uint64]$script:ModuleBase.ToInt64(),
            [uint64]$local.Ship,
            [byte]$enemyTeam,
            [byte]$difficulty,
            [string]$botName,
            [string]$shipGuid)
        if ($null -ne $rawController) { $controller = [Convert]::ToInt64($rawController) }
    } catch {
        $invokeError = [string]$_.Exception.Message
    }

    if ($controller -le 0) { $controller = Recover-NewSpawnController $beforeSnap ([int]$enemyTeam) }

    if ($controller -le 0) {
        if (-not [string]::IsNullOrWhiteSpace($invokeError)) {
            $enemySpawnInfoLabel.Text = "Spawn: failed - $invokeError"
        } else {
            $enemySpawnInfoLabel.Text = "Spawn: " + (Get-SpawnErrorText ([NativeMemoryV4]::LastSpawnError))
        }
        $enemySpawnInfoLabel.ForeColor = [System.Drawing.Color]::Salmon
        $enemySpawnButton.Enabled = $true
        return
    }

    $requestedDifficultyName = Get-BotDifficultyName ([int]$difficulty)
    $actualDifficultyName = Get-ActualBotDifficultyName $controller
    Write-DifficultyDebugReport $controller $shipName ([int]$difficulty) "ENEMY"
    if ([string]::IsNullOrWhiteSpace($invokeError)) {
        $enemySpawnInfoLabel.Text = "Spawn: $shipName | requested $requestedDifficultyName | game $actualDifficultyName"
    } else {
        $enemySpawnInfoLabel.Text = "Spawn: $shipName | requested $requestedDifficultyName | game $actualDifficultyName (return recovered)"
    }
    if ($actualDifficultyName -eq $requestedDifficultyName) {
        $enemySpawnInfoLabel.ForeColor = [System.Drawing.Color]::LightGreen
    } else {
        $enemySpawnInfoLabel.ForeColor = [System.Drawing.Color]::Khaki
    }

    Register-TrackedAlly $controller $shipName ([int]$enemyTeam) $botName
    $script:LastRosterSignature = ""
    $script:LastEnemyRosterSignature = ""
    try { Refresh-EnemyRosterUI $true } catch { }

    try {
        $script:PendingSpawnControllers = @(
            @($script:PendingSpawnControllers) +
            [pscustomobject]@{
                Controller = $controller
                Name = [string]$botName
                AddedAt = [DateTime]::UtcNow
            }
        )
        Pump-PendingSpawnControllers
        $script:NextRosterRefreshAt = [DateTime]::UtcNow.AddSeconds(1)
        if (-not $script:ScanningPlayers) { [void](Start-PlayerStateDiscovery $true) }
        if ($script:EnemyGodEnabled) {
            $script:SpawnRescanAt = [DateTime]::UtcNow.AddSeconds(1.25)
            $script:NextAutoRescanAt = [DateTime]::UtcNow.AddSeconds(10)
        }
    } catch { }
    finally {
        [System.Threading.Thread]::Sleep(350)
        $enemySpawnButton.Enabled = $true
    }
}

function Get-ActorDeleteErrorText([int]$Code) {
    switch ($Code) {
        1 { return "could not allocate memory in local server" }
        2 { return "internal delete payload was too large" }
        3 { return "could not write delete request" }
        4 { return "could not start local delete call" }
        5 { return "delete call timed out" }
        6 { return "delete wait failed" }
        7 { return "could not read delete result" }
        9 { return "unexpected delete helper error" }
        10 { return "this spserver.exe build does not match the clean-delete helper" }
        100 { return "ally controller/ship is not live anymore" }
        default { return "unknown delete error $Code" }
    }
}

function Get-LiveTeamRows([int]$TargetTeam, [bool]$GodEnabled, $Locks) {
    $rows = @()
    if ($TargetTeam -lt 0) { return @($rows) }
    if (-not (Connect-Server)) { return @($rows) }
    $local = Get-LocalPlayerStateInfo
    if ($null -eq $local) { return @($rows) }

    $seenControllers = @{}

    # Trainer-spawned ships are authoritative because we own the returned controller.
    foreach ($ckey in @($script:TrackedAllies.Keys)) {
        $entry = $script:TrackedAllies[$ckey]
        if ($null -eq $entry -or [int]$entry.Team -ne $TargetTeam) { continue }
        $entry = Update-TrackedAllyPointers ([int64]$entry.Controller)
        if ($null -eq $entry) { continue }

        $controller = [int64]$entry.Controller
        if ($controller -le 0) { continue }
        $pawn = [int64]$entry.Pawn
        $ps = [int64]$entry.PlayerState

        $status = "Spawning"
        if ($pawn -gt 0) { $status = "Ready" }
        if ($ps -gt 0) {
            $pkey = "{0:X}" -f [uint64]$ps
            if ($GodEnabled -and $Locks.ContainsKey($pkey)) { $status = "God" }
        }

        $shortId = if ($ckey.Length -gt 6) { $ckey.Substring($ckey.Length - 6) } else { $ckey }
        $rows += [pscustomobject]@{
            PlayerState = $ps
            Controller = $controller
            Pawn = $pawn
            Ship = if ([string]::IsNullOrWhiteSpace([string]$entry.Ship)) { "Unknown ship" } else { [string]$entry.Ship }
            Id = $shortId
            Difficulty = Get-ActualBotDifficultyName $controller
            Status = $status
            Key = if ($ps -gt 0) { "{0:X}" -f [uint64]$ps } else { "C:$ckey" }
            TrackedKey = $ckey
            Team = $TargetTeam
        }
        $seenControllers[$ckey] = $true
    }

    # Merge ships that were already in the match before the trainer spawned anything.
    foreach ($psRaw in @($script:PlayerStateAddresses | Sort-Object -Unique)) {
        $ps = [int64]$psRaw
        if ($ps -le 0 -or $ps -eq [int64]$local.PlayerState) { continue }

        $team = Read-U8 ([IntPtr]($ps + $PLAYERSTATE_TEAM_OFFSET))
        if ($null -eq $team -or [int]$team -ne $TargetTeam) { continue }

        $ship = Resolve-ShipFromPlayerState $ps
        if ($null -eq $ship -or [int64]$ship -le 0) { continue }
        $pkey = "{0:X}" -f [uint64]$ps
        if (-not $script:ControllerCache.ContainsKey($pkey)) { continue }
        $controller = [int64]$script:ControllerCache[$pkey]
        if ($controller -le 0) { continue }
        $ckey = "{0:X}" -f [uint64]$controller
        if ($seenControllers.ContainsKey($ckey)) { continue }

        $controllerPawn = Read-U64 ([IntPtr]($controller + $CONTROLLER_PAWN_OFFSET))
        if (-not (Is-PlausiblePointer $controllerPawn) -or [uint64]$controllerPawn -ne [uint64]$ship) { continue }

        $shipName = Get-ShipNameFromPlayerState $ps ([int64]$ship)
        if ([string]::IsNullOrWhiteSpace($shipName)) { $shipName = "Unknown ship" }
        $shortId = if ($ckey.Length -gt 6) { $ckey.Substring($ckey.Length - 6) } else { $ckey }
        $status = if ($GodEnabled -and $Locks.ContainsKey($pkey)) { "God" } else { "Ready" }
        $rows += [pscustomobject]@{
            PlayerState = $ps
            Controller = $controller
            Pawn = [int64]$ship
            Ship = $shipName
            Id = $shortId
            Difficulty = Get-ActualBotDifficultyName $controller
            Status = $status
            Key = $pkey
            TrackedKey = ""
            Team = $TargetTeam
        }
        $seenControllers[$ckey] = $true
    }
    return @($rows)
}

function Get-LiveAllyRows {
    $local = Get-LocalPlayerStateInfo
    if ($null -eq $local) { return @() }
    return @(Get-LiveTeamRows ([int]$local.Team) $script:AllyGodEnabled $script:TeamLocks)
}

function Get-LiveEnemyRows {
    $enemyTeam = Get-EnemyTeamId
    $allRows = @(Get-LiveTeamRows ([int]$enemyTeam) $script:EnemyGodEnabled $script:EnemyLocks)
    return @($allRows | Where-Object {
        $pawn = [int64]$_.Pawn
        if ($pawn -le 0) { return $true }
        return -not (Test-IsMinorShipPawn $pawn)
    })
}

function Refresh-AllyRosterUI([bool]$Force = $false) {
    if ($null -eq $allyListView) { return }
    if (-not (Connect-Server)) {
        if ($allyListView.Items.Count -gt 0) { $allyListView.Items.Clear() }
        return
    }
    $rows = @(Get-LiveAllyRows)
    $sig = (($rows | ForEach-Object { "$($_.Key)|$($_.Ship)|$($_.Difficulty)|$($_.Status)" }) -join ';')
    if (-not $Force -and $sig -eq $script:LastRosterSignature) { return }
    $script:LastRosterSignature = $sig

    $selectedPs = [int64]0
    if ($allyListView.SelectedItems.Count -gt 0 -and $null -ne $allyListView.SelectedItems[0].Tag) {
        try { $selectedPs = [int64]$allyListView.SelectedItems[0].Tag.PlayerState } catch { }
    }
    $allyListView.BeginUpdate()
    try {
        $allyListView.Items.Clear()
        foreach ($row in $rows) {
            $item = New-Object System.Windows.Forms.ListViewItem([string]$row.Ship)
            [void]$item.SubItems.Add([string]$row.Id)
            [void]$item.SubItems.Add([string]$row.Difficulty)
            [void]$item.SubItems.Add([string]$row.Status)
            $item.Tag = $row
            [void]$allyListView.Items.Add($item)
            if ($selectedPs -ne 0 -and [int64]$row.PlayerState -eq $selectedPs) { $item.Selected = $true }
        }
    } finally { $allyListView.EndUpdate() }
}

function Refresh-EnemyRosterUI([bool]$Force = $false) {
    if ($null -eq $enemyListView) { return }
    if (-not (Connect-Server)) {
        if ($enemyListView.Items.Count -gt 0) { $enemyListView.Items.Clear() }
        return
    }
    $rows = @(Get-LiveEnemyRows)
    $sig = (($rows | ForEach-Object { "$($_.Key)|$($_.Ship)|$($_.Difficulty)|$($_.Status)" }) -join ';')
    if (-not $Force -and $sig -eq $script:LastEnemyRosterSignature) { return }
    $script:LastEnemyRosterSignature = $sig

    $selectedPs = [int64]0
    if ($enemyListView.SelectedItems.Count -gt 0 -and $null -ne $enemyListView.SelectedItems[0].Tag) {
        try { $selectedPs = [int64]$enemyListView.SelectedItems[0].Tag.PlayerState } catch { }
    }
    $enemyListView.BeginUpdate()
    try {
        $enemyListView.Items.Clear()
        foreach ($row in $rows) {
            $item = New-Object System.Windows.Forms.ListViewItem([string]$row.Ship)
            [void]$item.SubItems.Add([string]$row.Id)
            [void]$item.SubItems.Add([string]$row.Difficulty)
            [void]$item.SubItems.Add([string]$row.Status)
            $item.Tag = $row
            [void]$enemyListView.Items.Add($item)
            if ($selectedPs -ne 0 -and [int64]$row.PlayerState -eq $selectedPs) { $item.Selected = $true }
        }
    } finally { $enemyListView.EndUpdate() }
}

function Remove-AllyCacheEntry([int64]$PlayerStateAddress, [int64]$ControllerAddress = 0) {
    if ($PlayerStateAddress -gt 0) {
        $key = "{0:X}" -f [uint64]$PlayerStateAddress
        $script:PlayerStateAddresses = @($script:PlayerStateAddresses | Where-Object { [int64]$_ -ne $PlayerStateAddress })
        [void]$script:TeamLocks.Remove($key)
        [void]$script:EnemyLocks.Remove($key)
        [void]$script:ControllerCache.Remove($key)
        [void]$script:PawnCache.Remove($key)
        [void]$script:SpawnedBotNames.Remove($key)
    }
    if ($ControllerAddress -gt 0) {
        $ckey = "{0:X}" -f [uint64]$ControllerAddress
        [void]$script:TrackedAllies.Remove($ckey)
        $script:PendingSpawnControllers = @($script:PendingSpawnControllers | Where-Object { [int64]$_.Controller -ne $ControllerAddress })
    }
    $script:LastRosterSignature = ""
    $script:LastEnemyRosterSignature = ""
}

function Invoke-DeleteAllyRow($row) {
    if ($null -eq $row) { return $false }
    $ps = [int64]$row.PlayerState
    $controller = [int64]$row.Controller
    $pawn = [int64]$row.Pawn
    if ($controller -le 0) { return $false }

    # If possession was still finishing, re-read the pawn right before delete.
    if ($pawn -le 0) {
        $p = Read-U64 ([IntPtr]($controller + $CONTROLLER_PAWN_OFFSET))
        if (Is-PlausiblePointer $p) { $pawn = [int64]$p }
    }
    if ($pawn -le 0) { return $false }

    $ok = [NativeMemoryV4]::DestroyAllyActorsNative(
        $script:ProcessHandle,
        [uint64]$script:ModuleBase.ToInt64(),
        [uint64]$controller,
        [uint64]$pawn)
    if ($ok) {
        Remove-AllyCacheEntry $ps $controller
        return $true
    }
    return $false
}

function Invoke-DeleteSelectedAlly {
    if ($null -eq $allyListView -or $allyListView.SelectedItems.Count -eq 0) {
        $deleteInfoLabel.Text = "Delete: select a live allied ship first"
        $deleteInfoLabel.ForeColor = [System.Drawing.Color]::Khaki
        return
    }
    if (-not (Connect-Server)) {
        $deleteInfoLabel.Text = "Delete: start a solo match first"
        $deleteInfoLabel.ForeColor = [System.Drawing.Color]::Khaki
        return
    }

    $row = $allyListView.SelectedItems[0].Tag
    if ($null -eq $row) { return }
    $deleteButton.Enabled = $false
    $deleteAllButton.Enabled = $false
    $deleteInfoLabel.Text = "Delete: removing $($row.Ship)..."
    $deleteInfoLabel.ForeColor = [System.Drawing.Color]::Khaki
    [System.Windows.Forms.Application]::DoEvents()
    try {
        if (Invoke-DeleteAllyRow $row) {
            $script:LastRosterSignature = ""
            $deleteInfoLabel.Text = "Delete: removed $($row.Ship) completely"
            $deleteInfoLabel.ForeColor = [System.Drawing.Color]::LightGreen
            Refresh-AllyRosterUI $true
            $script:NextRosterRefreshAt = [DateTime]::UtcNow.AddSeconds(2)
            if ($script:AllyGodEnabled) { $script:SpawnRescanAt = [DateTime]::UtcNow.AddSeconds(2) }
        } else {
            $deleteInfoLabel.Text = "Delete: " + (Get-ActorDeleteErrorText ([NativeMemoryV4]::LastActorDeleteError))
            $deleteInfoLabel.ForeColor = [System.Drawing.Color]::Salmon
        }
    } catch {
        $deleteInfoLabel.Text = "Delete: failed - $($_.Exception.Message)"
        $deleteInfoLabel.ForeColor = [System.Drawing.Color]::Salmon
    } finally {
        $deleteButton.Enabled = $true
        $deleteAllButton.Enabled = $true
    }
}

function Invoke-DeleteAllAllies {
    if (-not (Connect-Server)) {
        $deleteInfoLabel.Text = "Delete all: start a solo match first"
        $deleteInfoLabel.ForeColor = [System.Drawing.Color]::Khaki
        return
    }
    $rows = @(Get-LiveAllyRows)
    if ($rows.Count -eq 0) {
        $deleteInfoLabel.Text = "Delete all: no live allied ships in the list"
        $deleteInfoLabel.ForeColor = [System.Drawing.Color]::Khaki
        return
    }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Delete all $($rows.Count) live allied ships?`r`n`r`nYour own ship is never included.",
        "Delete all allies",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $deleteButton.Enabled = $false
    $deleteAllButton.Enabled = $false
    $removed = 0
    $failed = 0
    try {
        foreach ($row in $rows) {
            $deleteInfoLabel.Text = "Delete all: removing $($row.Ship)... ($removed/$($rows.Count))"
            $deleteInfoLabel.ForeColor = [System.Drawing.Color]::Khaki
            [System.Windows.Forms.Application]::DoEvents()
            if (Invoke-DeleteAllyRow $row) { $removed++ } else { $failed++ }
        }
        $script:LastRosterSignature = ""
        Refresh-AllyRosterUI $true
        $script:NextRosterRefreshAt = [DateTime]::UtcNow.AddSeconds(2)
        if ($script:AllyGodEnabled) { $script:SpawnRescanAt = [DateTime]::UtcNow.AddSeconds(2) }
        if ($failed -eq 0) {
            $deleteInfoLabel.Text = "Delete all: removed $removed allied ships"
            $deleteInfoLabel.ForeColor = [System.Drawing.Color]::LightGreen
        } else {
            $deleteInfoLabel.Text = "Delete all: removed $removed, failed $failed"
            $deleteInfoLabel.ForeColor = [System.Drawing.Color]::Khaki
        }
    } finally {
        $deleteButton.Enabled = $true
        $deleteAllButton.Enabled = $true
    }
}


function Invoke-DeleteSelectedEnemy {
    if ($null -eq $enemyListView -or $enemyListView.SelectedItems.Count -eq 0) {
        $enemyDeleteInfoLabel.Text = "Delete: select a live enemy ship first"
        $enemyDeleteInfoLabel.ForeColor = [System.Drawing.Color]::Khaki
        return
    }
    if (-not (Connect-Server)) {
        $enemyDeleteInfoLabel.Text = "Delete: start a solo match first"
        $enemyDeleteInfoLabel.ForeColor = [System.Drawing.Color]::Khaki
        return
    }

    $row = $enemyListView.SelectedItems[0].Tag
    if ($null -eq $row) { return }
    $enemyDeleteButton.Enabled = $false
    $enemyDeleteAllButton.Enabled = $false
    $enemyDeleteInfoLabel.Text = "Delete: removing $($row.Ship)..."
    $enemyDeleteInfoLabel.ForeColor = [System.Drawing.Color]::Khaki
    [System.Windows.Forms.Application]::DoEvents()
    try {
        if (Invoke-DeleteAllyRow $row) {
            $script:LastEnemyRosterSignature = ""
            $enemyDeleteInfoLabel.Text = "Delete: removed $($row.Ship) completely"
            $enemyDeleteInfoLabel.ForeColor = [System.Drawing.Color]::LightGreen
            Refresh-EnemyRosterUI $true
            $script:NextRosterRefreshAt = [DateTime]::UtcNow.AddSeconds(2)
            if ($script:EnemyGodEnabled) { $script:SpawnRescanAt = [DateTime]::UtcNow.AddSeconds(2) }
        } else {
            $enemyDeleteInfoLabel.Text = "Delete: " + (Get-ActorDeleteErrorText ([NativeMemoryV4]::LastActorDeleteError))
            $enemyDeleteInfoLabel.ForeColor = [System.Drawing.Color]::Salmon
        }
    } catch {
        $enemyDeleteInfoLabel.Text = "Delete: failed - $($_.Exception.Message)"
        $enemyDeleteInfoLabel.ForeColor = [System.Drawing.Color]::Salmon
    } finally {
        $enemyDeleteButton.Enabled = $true
        $enemyDeleteAllButton.Enabled = $true
    }
}

function Invoke-DeleteAllEnemies {
    if (-not (Connect-Server)) {
        $enemyDeleteInfoLabel.Text = "Delete all: start a solo match first"
        $enemyDeleteInfoLabel.ForeColor = [System.Drawing.Color]::Khaki
        return
    }
    $rows = @(Get-LiveEnemyRows)
    if ($rows.Count -eq 0) {
        $enemyDeleteInfoLabel.Text = "Delete all: no live enemy ships in the list"
        $enemyDeleteInfoLabel.ForeColor = [System.Drawing.Color]::Khaki
        return
    }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Delete all $($rows.Count) live enemy ships?",
        "Delete all enemies",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $enemyDeleteButton.Enabled = $false
    $enemyDeleteAllButton.Enabled = $false
    $removed = 0
    $failed = 0
    try {
        foreach ($row in $rows) {
            $enemyDeleteInfoLabel.Text = "Delete all: removing $($row.Ship)... ($removed/$($rows.Count))"
            $enemyDeleteInfoLabel.ForeColor = [System.Drawing.Color]::Khaki
            [System.Windows.Forms.Application]::DoEvents()
            if (Invoke-DeleteAllyRow $row) { $removed++ } else { $failed++ }
        }
        $script:LastEnemyRosterSignature = ""
        Refresh-EnemyRosterUI $true
        $script:NextRosterRefreshAt = [DateTime]::UtcNow.AddSeconds(2)
        if ($script:EnemyGodEnabled) { $script:SpawnRescanAt = [DateTime]::UtcNow.AddSeconds(2) }
        if ($failed -eq 0) {
            $enemyDeleteInfoLabel.Text = "Delete all: removed $removed enemy ships"
            $enemyDeleteInfoLabel.ForeColor = [System.Drawing.Color]::LightGreen
        } else {
            $enemyDeleteInfoLabel.Text = "Delete all: removed $removed, failed $failed"
            $enemyDeleteInfoLabel.ForeColor = [System.Drawing.Color]::Khaki
        }
    } finally {
        $enemyDeleteButton.Enabled = $true
        $enemyDeleteAllButton.Enabled = $true
    }
}

# ---------------- UI ----------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "Fractured Space - Solo Trainer (Team Manager FIX13)"
$form.Size = New-Object System.Drawing.Size(940, 890)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false
$form.MinimizeBox = $true
$form.BackColor = [System.Drawing.Color]::FromArgb(24, 27, 32)
$form.ForeColor = [System.Drawing.Color]::White

$title = New-Object System.Windows.Forms.Label
$title.Text = "FRACTURED SPACE - SOLO TRAINER"
$title.Font = New-Object System.Drawing.Font("Segoe UI", 15, [System.Drawing.FontStyle]::Bold)
$title.Location = New-Object System.Drawing.Point(20, 18)
$title.Size = New-Object System.Drawing.Size(870, 32)
$form.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = "Local spserver.exe only"
$subtitle.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$subtitle.ForeColor = [System.Drawing.Color]::FromArgb(170, 175, 185)
$subtitle.Location = New-Object System.Drawing.Point(22, 51)
$subtitle.Size = New-Object System.Drawing.Size(870, 22)
$form.Controls.Add($subtitle)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "Server: waiting for spserver.exe..."
$statusLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$statusLabel.ForeColor = [System.Drawing.Color]::Orange
$statusLabel.Location = New-Object System.Drawing.Point(22, 83)
$statusLabel.Size = New-Object System.Drawing.Size(870, 24)
$form.Controls.Add($statusLabel)

$healthLabel = New-Object System.Windows.Forms.Label
$healthLabel.Text = "Your HP: --"
$healthLabel.Font = New-Object System.Drawing.Font("Segoe UI", 11)
$healthLabel.Location = New-Object System.Drawing.Point(22, 112)
$healthLabel.Size = New-Object System.Drawing.Size(870, 26)
$form.Controls.Add($healthLabel)

$godButton = New-Object System.Windows.Forms.Button
$godButton.Text = "PLAYER GOD MODE: OFF"
$godButton.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$godButton.Location = New-Object System.Drawing.Point(22, 148)
$godButton.Size = New-Object System.Drawing.Size(876, 50)
$godButton.FlatStyle = "Flat"
$godButton.BackColor = [System.Drawing.Color]::FromArgb(55, 60, 68)
$godButton.ForeColor = [System.Drawing.Color]::White
$godButton.FlatAppearance.BorderSize = 1
$form.Controls.Add($godButton)

$separator = New-Object System.Windows.Forms.Panel
$separator.Location = New-Object System.Drawing.Point(459, 214)
$separator.Size = New-Object System.Drawing.Size(1, 610)
$separator.BackColor = [System.Drawing.Color]::FromArgb(75, 80, 88)
$form.Controls.Add($separator)

# ----- ALLIED TEAM / LEFT COLUMN -----
$allyColumnTitle = New-Object System.Windows.Forms.Label
$allyColumnTitle.Text = "ALLIED TEAM"
$allyColumnTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$allyColumnTitle.Location = New-Object System.Drawing.Point(22, 214)
$allyColumnTitle.Size = New-Object System.Drawing.Size(410, 26)
$form.Controls.Add($allyColumnTitle)

$allyButton = New-Object System.Windows.Forms.Button
$allyButton.Text = "ALLIED BOT GOD MODE: OFF"
$allyButton.Font = New-Object System.Drawing.Font("Segoe UI", 10.5, [System.Drawing.FontStyle]::Bold)
$allyButton.Location = New-Object System.Drawing.Point(22, 244)
$allyButton.Size = New-Object System.Drawing.Size(410, 48)
$allyButton.FlatStyle = "Flat"
$allyButton.BackColor = [System.Drawing.Color]::FromArgb(55, 60, 68)
$allyButton.ForeColor = [System.Drawing.Color]::White
$form.Controls.Add($allyButton)

$allyInfoLabel = New-Object System.Windows.Forms.Label
$allyInfoLabel.Text = "Allied bots: --"
$allyInfoLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$allyInfoLabel.ForeColor = [System.Drawing.Color]::FromArgb(170, 175, 185)
$allyInfoLabel.Location = New-Object System.Drawing.Point(22, 301)
$allyInfoLabel.Size = New-Object System.Drawing.Size(410, 24)
$form.Controls.Add($allyInfoLabel)

$spawnSectionLabel = New-Object System.Windows.Forms.Label
$spawnSectionLabel.Text = "SPAWN ALLIED SHIP"
$spawnSectionLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$spawnSectionLabel.Location = New-Object System.Drawing.Point(22, 334)
$spawnSectionLabel.Size = New-Object System.Drawing.Size(410, 24)
$form.Controls.Add($spawnSectionLabel)

$shipLabel = New-Object System.Windows.Forms.Label
$shipLabel.Text = "Ship:"
$shipLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$shipLabel.Location = New-Object System.Drawing.Point(22, 365)
$shipLabel.Size = New-Object System.Drawing.Size(105, 22)
$form.Controls.Add($shipLabel)

$shipCombo = New-Object System.Windows.Forms.ComboBox
$shipCombo.Location = New-Object System.Drawing.Point(130, 362)
$shipCombo.Size = New-Object System.Drawing.Size(302, 28)
$shipCombo.DropDownStyle = "DropDownList"
$shipCombo.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$shipCombo.MaxDropDownItems = 14
$shipCombo.IntegralHeight = $false
$shipCombo.DropDownHeight = 300
[void]$shipCombo.Items.AddRange([string[]]@($SHIP_GUIDS.Keys))
$shipCombo.SelectedItem = "Punisher"
$form.Controls.Add($shipCombo)

$difficultyLabel = New-Object System.Windows.Forms.Label
$difficultyLabel.Text = "Bot difficulty:"
$difficultyLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$difficultyLabel.Location = New-Object System.Drawing.Point(22, 402)
$difficultyLabel.Size = New-Object System.Drawing.Size(105, 22)
$form.Controls.Add($difficultyLabel)

$difficultyCombo = New-Object System.Windows.Forms.ComboBox
$difficultyCombo.Location = New-Object System.Drawing.Point(130, 399)
$difficultyCombo.Size = New-Object System.Drawing.Size(302, 28)
$difficultyCombo.DropDownStyle = "DropDownList"
$difficultyCombo.Font = New-Object System.Drawing.Font("Segoe UI", 9)
[void]$difficultyCombo.Items.AddRange(@("Easy 1", "Easy 2", "Easy 3", "Medium 1", "Medium 2", "Medium 3", "Hard 1", "Hard 2", "Hard 3", "Milcho Bot"))
$difficultyCombo.SelectedIndex = 4
$form.Controls.Add($difficultyCombo)

$spawnButton = New-Object System.Windows.Forms.Button
$spawnButton.Text = "SPAWN SELECTED SHIP ON MY TEAM"
$spawnButton.Font = New-Object System.Drawing.Font("Segoe UI", 9.8, [System.Drawing.FontStyle]::Bold)
$spawnButton.Location = New-Object System.Drawing.Point(22, 438)
$spawnButton.Size = New-Object System.Drawing.Size(410, 48)
$spawnButton.FlatStyle = "Flat"
$spawnButton.BackColor = [System.Drawing.Color]::FromArgb(58, 78, 105)
$spawnButton.ForeColor = [System.Drawing.Color]::White
$form.Controls.Add($spawnButton)

$spawnInfoLabel = New-Object System.Windows.Forms.Label
$spawnInfoLabel.Text = "Spawn: select a ship and difficulty, then click Spawn"
$spawnInfoLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8.7)
$spawnInfoLabel.ForeColor = [System.Drawing.Color]::FromArgb(170, 175, 185)
$spawnInfoLabel.Location = New-Object System.Drawing.Point(22, 495)
$spawnInfoLabel.Size = New-Object System.Drawing.Size(410, 40)
$form.Controls.Add($spawnInfoLabel)

$managerSectionLabel = New-Object System.Windows.Forms.Label
$managerSectionLabel.Text = "ALLIED SHIPS"
$managerSectionLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$managerSectionLabel.Location = New-Object System.Drawing.Point(22, 541)
$managerSectionLabel.Size = New-Object System.Drawing.Size(410, 24)
$form.Controls.Add($managerSectionLabel)

$allyListView = New-Object System.Windows.Forms.ListView
$allyListView.Location = New-Object System.Drawing.Point(22, 568)
$allyListView.Size = New-Object System.Drawing.Size(410, 165)
$allyListView.View = [System.Windows.Forms.View]::Details
$allyListView.FullRowSelect = $true
$allyListView.MultiSelect = $false
$allyListView.HideSelection = $false
$allyListView.GridLines = $true
$allyListView.BackColor = [System.Drawing.Color]::FromArgb(31, 35, 41)
$allyListView.ForeColor = [System.Drawing.Color]::White
[void]$allyListView.Columns.Add("Ship", 145)
[void]$allyListView.Columns.Add("ID", 65)
[void]$allyListView.Columns.Add("Difficulty", 100)
[void]$allyListView.Columns.Add("Status", 90)
$form.Controls.Add($allyListView)

$deleteButton = New-Object System.Windows.Forms.Button
$deleteButton.Text = "DELETE SELECTED"
$deleteButton.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$deleteButton.Location = New-Object System.Drawing.Point(22, 743)
$deleteButton.Size = New-Object System.Drawing.Size(200, 38)
$deleteButton.FlatStyle = "Flat"
$deleteButton.BackColor = [System.Drawing.Color]::FromArgb(125, 54, 54)
$deleteButton.ForeColor = [System.Drawing.Color]::White
$form.Controls.Add($deleteButton)

$deleteAllButton = New-Object System.Windows.Forms.Button
$deleteAllButton.Text = "DELETE ALL ALLIES"
$deleteAllButton.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$deleteAllButton.Location = New-Object System.Drawing.Point(232, 743)
$deleteAllButton.Size = New-Object System.Drawing.Size(200, 38)
$deleteAllButton.FlatStyle = "Flat"
$deleteAllButton.BackColor = [System.Drawing.Color]::FromArgb(150, 48, 48)
$deleteAllButton.ForeColor = [System.Drawing.Color]::White
$form.Controls.Add($deleteAllButton)

$deleteInfoLabel = New-Object System.Windows.Forms.Label
$deleteInfoLabel.Text = "Delete: live allied ships only"
$deleteInfoLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8.7)
$deleteInfoLabel.ForeColor = [System.Drawing.Color]::FromArgb(170, 175, 185)
$deleteInfoLabel.Location = New-Object System.Drawing.Point(22, 790)
$deleteInfoLabel.Size = New-Object System.Drawing.Size(410, 28)
$form.Controls.Add($deleteInfoLabel)

# ----- ENEMY TEAM / RIGHT COLUMN -----
$enemyColumnTitle = New-Object System.Windows.Forms.Label
$enemyColumnTitle.Text = "ENEMY TEAM"
$enemyColumnTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$enemyColumnTitle.Location = New-Object System.Drawing.Point(488, 214)
$enemyColumnTitle.Size = New-Object System.Drawing.Size(410, 26)
$form.Controls.Add($enemyColumnTitle)

$enemyGodButton = New-Object System.Windows.Forms.Button
$enemyGodButton.Text = "ENEMY BOT GOD MODE: OFF"
$enemyGodButton.Font = New-Object System.Drawing.Font("Segoe UI", 10.5, [System.Drawing.FontStyle]::Bold)
$enemyGodButton.Location = New-Object System.Drawing.Point(488, 244)
$enemyGodButton.Size = New-Object System.Drawing.Size(410, 48)
$enemyGodButton.FlatStyle = "Flat"
$enemyGodButton.BackColor = [System.Drawing.Color]::FromArgb(55, 60, 68)
$enemyGodButton.ForeColor = [System.Drawing.Color]::White
$form.Controls.Add($enemyGodButton)

$enemyInfoLabel = New-Object System.Windows.Forms.Label
$enemyInfoLabel.Text = "Enemy bots: --"
$enemyInfoLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$enemyInfoLabel.ForeColor = [System.Drawing.Color]::FromArgb(170, 175, 185)
$enemyInfoLabel.Location = New-Object System.Drawing.Point(488, 301)
$enemyInfoLabel.Size = New-Object System.Drawing.Size(410, 24)
$form.Controls.Add($enemyInfoLabel)

$enemySpawnSectionLabel = New-Object System.Windows.Forms.Label
$enemySpawnSectionLabel.Text = "SPAWN ENEMY SHIP"
$enemySpawnSectionLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$enemySpawnSectionLabel.Location = New-Object System.Drawing.Point(488, 334)
$enemySpawnSectionLabel.Size = New-Object System.Drawing.Size(410, 24)
$form.Controls.Add($enemySpawnSectionLabel)

$enemyShipLabel = New-Object System.Windows.Forms.Label
$enemyShipLabel.Text = "Ship:"
$enemyShipLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$enemyShipLabel.Location = New-Object System.Drawing.Point(488, 365)
$enemyShipLabel.Size = New-Object System.Drawing.Size(105, 22)
$form.Controls.Add($enemyShipLabel)

$enemyShipCombo = New-Object System.Windows.Forms.ComboBox
$enemyShipCombo.Location = New-Object System.Drawing.Point(596, 362)
$enemyShipCombo.Size = New-Object System.Drawing.Size(302, 28)
$enemyShipCombo.DropDownStyle = "DropDownList"
$enemyShipCombo.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$enemyShipCombo.MaxDropDownItems = 14
$enemyShipCombo.IntegralHeight = $false
$enemyShipCombo.DropDownHeight = 300
[void]$enemyShipCombo.Items.AddRange([string[]]@($SHIP_GUIDS.Keys))
$enemyShipCombo.SelectedItem = "Punisher"
$form.Controls.Add($enemyShipCombo)

$enemyDifficultyLabel = New-Object System.Windows.Forms.Label
$enemyDifficultyLabel.Text = "Bot difficulty:"
$enemyDifficultyLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$enemyDifficultyLabel.Location = New-Object System.Drawing.Point(488, 402)
$enemyDifficultyLabel.Size = New-Object System.Drawing.Size(105, 22)
$form.Controls.Add($enemyDifficultyLabel)

$enemyDifficultyCombo = New-Object System.Windows.Forms.ComboBox
$enemyDifficultyCombo.Location = New-Object System.Drawing.Point(596, 399)
$enemyDifficultyCombo.Size = New-Object System.Drawing.Size(302, 28)
$enemyDifficultyCombo.DropDownStyle = "DropDownList"
$enemyDifficultyCombo.Font = New-Object System.Drawing.Font("Segoe UI", 9)
[void]$enemyDifficultyCombo.Items.AddRange(@("Easy 1", "Easy 2", "Easy 3", "Medium 1", "Medium 2", "Medium 3", "Hard 1", "Hard 2", "Hard 3", "Milcho Bot"))
$enemyDifficultyCombo.SelectedIndex = 4
$form.Controls.Add($enemyDifficultyCombo)

$enemySpawnButton = New-Object System.Windows.Forms.Button
$enemySpawnButton.Text = "SPAWN SELECTED SHIP ON ENEMY TEAM"
$enemySpawnButton.Font = New-Object System.Drawing.Font("Segoe UI", 9.8, [System.Drawing.FontStyle]::Bold)
$enemySpawnButton.Location = New-Object System.Drawing.Point(488, 438)
$enemySpawnButton.Size = New-Object System.Drawing.Size(410, 48)
$enemySpawnButton.FlatStyle = "Flat"
$enemySpawnButton.BackColor = [System.Drawing.Color]::FromArgb(105, 62, 62)
$enemySpawnButton.ForeColor = [System.Drawing.Color]::White
$form.Controls.Add($enemySpawnButton)

$enemySpawnInfoLabel = New-Object System.Windows.Forms.Label
$enemySpawnInfoLabel.Text = "Spawn: select a ship and difficulty, then click Spawn"
$enemySpawnInfoLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8.7)
$enemySpawnInfoLabel.ForeColor = [System.Drawing.Color]::FromArgb(170, 175, 185)
$enemySpawnInfoLabel.Location = New-Object System.Drawing.Point(488, 495)
$enemySpawnInfoLabel.Size = New-Object System.Drawing.Size(410, 40)
$form.Controls.Add($enemySpawnInfoLabel)

$enemyManagerSectionLabel = New-Object System.Windows.Forms.Label
$enemyManagerSectionLabel.Text = "ENEMY SHIPS"
$enemyManagerSectionLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$enemyManagerSectionLabel.Location = New-Object System.Drawing.Point(488, 541)
$enemyManagerSectionLabel.Size = New-Object System.Drawing.Size(410, 24)
$form.Controls.Add($enemyManagerSectionLabel)

$enemyListView = New-Object System.Windows.Forms.ListView
$enemyListView.Location = New-Object System.Drawing.Point(488, 568)
$enemyListView.Size = New-Object System.Drawing.Size(410, 165)
$enemyListView.View = [System.Windows.Forms.View]::Details
$enemyListView.FullRowSelect = $true
$enemyListView.MultiSelect = $false
$enemyListView.HideSelection = $false
$enemyListView.GridLines = $true
$enemyListView.BackColor = [System.Drawing.Color]::FromArgb(31, 35, 41)
$enemyListView.ForeColor = [System.Drawing.Color]::White
[void]$enemyListView.Columns.Add("Ship", 145)
[void]$enemyListView.Columns.Add("ID", 65)
[void]$enemyListView.Columns.Add("Difficulty", 100)
[void]$enemyListView.Columns.Add("Status", 90)
$form.Controls.Add($enemyListView)

$enemyDeleteButton = New-Object System.Windows.Forms.Button
$enemyDeleteButton.Text = "DELETE SELECTED"
$enemyDeleteButton.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$enemyDeleteButton.Location = New-Object System.Drawing.Point(488, 743)
$enemyDeleteButton.Size = New-Object System.Drawing.Size(200, 38)
$enemyDeleteButton.FlatStyle = "Flat"
$enemyDeleteButton.BackColor = [System.Drawing.Color]::FromArgb(125, 54, 54)
$enemyDeleteButton.ForeColor = [System.Drawing.Color]::White
$form.Controls.Add($enemyDeleteButton)

$enemyDeleteAllButton = New-Object System.Windows.Forms.Button
$enemyDeleteAllButton.Text = "DELETE ALL ENEMIES"
$enemyDeleteAllButton.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$enemyDeleteAllButton.Location = New-Object System.Drawing.Point(698, 743)
$enemyDeleteAllButton.Size = New-Object System.Drawing.Size(200, 38)
$enemyDeleteAllButton.FlatStyle = "Flat"
$enemyDeleteAllButton.BackColor = [System.Drawing.Color]::FromArgb(150, 48, 48)
$enemyDeleteAllButton.ForeColor = [System.Drawing.Color]::White
$form.Controls.Add($enemyDeleteAllButton)

$enemyDeleteInfoLabel = New-Object System.Windows.Forms.Label
$enemyDeleteInfoLabel.Text = "Delete: live enemy ships only"
$enemyDeleteInfoLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8.7)
$enemyDeleteInfoLabel.ForeColor = [System.Drawing.Color]::FromArgb(170, 175, 185)
$enemyDeleteInfoLabel.Location = New-Object System.Drawing.Point(488, 790)
$enemyDeleteInfoLabel.Size = New-Object System.Drawing.Size(410, 28)
$form.Controls.Add($enemyDeleteInfoLabel)

function Set-DisconnectedUi {
    $statusLabel.Text = "Server: waiting for local spserver.exe..."
    $statusLabel.ForeColor = [System.Drawing.Color]::Orange
    $healthLabel.Text = "Your HP: --"
    if (-not $script:AllyGodEnabled) {
        $allyInfoLabel.Text = "Allied bots: --"
        $allyInfoLabel.ForeColor = [System.Drawing.Color]::FromArgb(170, 175, 185)
    } else { $allyInfoLabel.Text = "Allied bots: waiting for server..." }
    if (-not $script:EnemyGodEnabled) {
        $enemyInfoLabel.Text = "Enemy bots: --"
        $enemyInfoLabel.ForeColor = [System.Drawing.Color]::FromArgb(170, 175, 185)
    } else { $enemyInfoLabel.Text = "Enemy bots: waiting for server..." }
}

function Set-ConnectedUi([int]$ProcessId) {
    $statusLabel.Text = "Server: CONNECTED (PID $ProcessId)"
    $statusLabel.ForeColor = [System.Drawing.Color]::LightGreen
}

$godButton.Add_Click({
    if (-not $script:GodEnabled) {
        if (-not (Connect-Server)) {
            [System.Windows.Forms.MessageBox]::Show("No local spserver.exe is available yet.`r`n`r`nStart a solo match first, then try again.", "Fractured Space Solo Trainer", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            return
        }
        $addr = Resolve-HealthAddress
        if ($null -eq $addr) {
            [System.Windows.Forms.MessageBox]::Show("The server was found, but your ship pointer is not valid yet.`r`n`r`nWait until your ship is fully spawned, then try again.", "Ship not ready", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            return
        }
        $hp = Read-F32 $addr
        if (-not (Is-PlausibleHealth $hp)) { return }
        $script:LockedHealth = [single]$hp
        $script:LastHealthAddress = $addr.ToInt64()
        $script:GodEnabled = $true
        $godButton.Text = "PLAYER GOD MODE: ON"
        $godButton.BackColor = [System.Drawing.Color]::FromArgb(45, 125, 72)
    } else {
        $script:GodEnabled = $false
        $godButton.Text = "PLAYER GOD MODE: OFF"
        $godButton.BackColor = [System.Drawing.Color]::FromArgb(55, 60, 68)
    }
})

$allyButton.Add_Click({
    if (-not $script:AllyGodEnabled) {
        if (-not (Connect-Server)) { return }
        $local = Get-LocalPlayerStateInfo
        if ($null -eq $local) { return }
        $script:AllyGodEnabled = $true
        $script:TeamLocks = @{}
        $script:NextAutoRescanAt = [DateTime]::UtcNow.AddSeconds(10)
        $allyButton.Text = "ALLIED BOT GOD MODE: ON"
        $allyButton.BackColor = [System.Drawing.Color]::FromArgb(45, 125, 72)
        [void](Start-PlayerStateDiscovery $false)
    } else {
        $script:AllyGodEnabled = $false
        $script:TeamLocks = @{}
        if (-not $script:EnemyGodEnabled) {
            $script:SpawnRescanAt = [DateTime]::MinValue
            $script:NextAutoRescanAt = [DateTime]::MinValue
        }
        $allyButton.Text = "ALLIED BOT GOD MODE: OFF"
        $allyButton.BackColor = [System.Drawing.Color]::FromArgb(55, 60, 68)
        $allyInfoLabel.Text = "Allied bots: --"
        $allyInfoLabel.ForeColor = [System.Drawing.Color]::FromArgb(170, 175, 185)
        $script:LastRosterSignature = ""
    }
})

$enemyGodButton.Add_Click({
    if (-not $script:EnemyGodEnabled) {
        if (-not (Connect-Server)) { return }
        $local = Get-LocalPlayerStateInfo
        if ($null -eq $local) { return }
        $enemyTeam = Get-EnemyTeamId
        if ($enemyTeam -lt 0 -or $enemyTeam -eq [int]$local.Team) {
            $enemyInfoLabel.Text = "Enemy bots: enemy team not resolved yet"
            $enemyInfoLabel.ForeColor = [System.Drawing.Color]::Khaki
            return
        }
        $script:EnemyGodEnabled = $true
        $script:EnemyLocks = @{}
        $script:NextAutoRescanAt = [DateTime]::UtcNow.AddSeconds(10)
        $enemyGodButton.Text = "ENEMY BOT GOD MODE: ON"
        $enemyGodButton.BackColor = [System.Drawing.Color]::FromArgb(45, 125, 72)
        [void](Start-PlayerStateDiscovery $false)
    } else {
        $script:EnemyGodEnabled = $false
        $script:EnemyLocks = @{}
        if (-not $script:AllyGodEnabled) {
            $script:SpawnRescanAt = [DateTime]::MinValue
            $script:NextAutoRescanAt = [DateTime]::MinValue
        }
        $enemyGodButton.Text = "ENEMY BOT GOD MODE: OFF"
        $enemyGodButton.BackColor = [System.Drawing.Color]::FromArgb(55, 60, 68)
        $enemyInfoLabel.Text = "Enemy bots: --"
        $enemyInfoLabel.ForeColor = [System.Drawing.Color]::FromArgb(170, 175, 185)
        $script:LastEnemyRosterSignature = ""
    }
})

$spawnButton.Add_Click({ Invoke-SpawnAlliedBot })
$enemySpawnButton.Add_Click({ Invoke-SpawnEnemyBot })
$deleteButton.Add_Click({ Invoke-DeleteSelectedAlly })
$deleteAllButton.Add_Click({ Invoke-DeleteAllAllies })
$enemyDeleteButton.Add_Click({ Invoke-DeleteSelectedEnemy })
$enemyDeleteAllButton.Add_Click({ Invoke-DeleteAllEnemies })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 50
$timer.Add_Tick({
    if (-not (Connect-Server)) { Set-DisconnectedUi; return }
    Set-ConnectedUi -ProcessId $script:ConnectedProcessId

    $addr = Resolve-HealthAddress
    if ($null -eq $addr) {
        $healthLabel.Text = "Your HP: waiting for ship..."
    } else {
        $hp = Read-F32 $addr
        if (-not (Is-PlausibleHealth $hp)) {
            $healthLabel.Text = "Your HP: waiting for ship..."
        } else {
            if ($script:GodEnabled -and ($script:LastHealthAddress -eq 0 -or $addr.ToInt64() -ne $script:LastHealthAddress)) { $script:LockedHealth = [single]$hp }
            $script:LastHealthAddress = $addr.ToInt64()
            if ($script:GodEnabled) {
                if (Write-F32 $addr $script:LockedHealth) { $healthLabel.Text = ("Your HP: {0:0.##}  (locked)" -f $script:LockedHealth) }
                else { $healthLabel.Text = "Your HP: write failed" }
            } else { $healthLabel.Text = ("Your HP: {0:0.##}" -f [double]$hp) }
        }
    }

    Pump-PendingSpawnControllers

    if (($script:AllyGodEnabled -or $script:EnemyGodEnabled) -and $script:SpawnRescanAt -ne [DateTime]::MinValue -and [DateTime]::UtcNow -ge $script:SpawnRescanAt) {
        $script:SpawnRescanAt = [DateTime]::MinValue
        if (-not $script:ScanningPlayers) { [void](Start-PlayerStateDiscovery $true) }
    }

    Poll-PlayerStateDiscovery

    if (($script:AllyGodEnabled -or $script:EnemyGodEnabled) -and -not $script:ScanningPlayers -and
        $script:NextAutoRescanAt -ne [DateTime]::MinValue -and [DateTime]::UtcNow -ge $script:NextAutoRescanAt) {
        $script:NextAutoRescanAt = [DateTime]::UtcNow.AddSeconds(10)
        [void](Start-PlayerStateDiscovery $true)
    }

    if (-not $script:ScanningPlayers -and $script:NextRosterRefreshAt -ne [DateTime]::MinValue -and [DateTime]::UtcNow -ge $script:NextRosterRefreshAt) {
        $script:NextRosterRefreshAt = [DateTime]::UtcNow.AddMilliseconds(600)
        [void](Start-PlayerStateDiscovery $true)
    }

    if ([DateTime]::UtcNow -ge $script:NextRosterUiAt) {
        $script:NextRosterUiAt = [DateTime]::UtcNow.AddMilliseconds(750)
        Refresh-AllyRosterUI $false
        Refresh-EnemyRosterUI $false
    }

    if ($script:AllyGodEnabled) { Update-AllyGod }
    if ($script:EnemyGodEnabled) { Update-EnemyGod }
})

$form.Add_FormClosed({
    $timer.Stop()
    Close-ServerHandle
})

$timer.Start()
[void]$form.ShowDialog()
