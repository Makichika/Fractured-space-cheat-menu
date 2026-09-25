$native = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

public static class DeferredFrigateNative {
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool ReadProcessMemory(IntPtr h, IntPtr a, byte[] b, int n, out IntPtr got);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool WriteProcessMemory(IntPtr h, IntPtr a, byte[] b, int n, out IntPtr wrote);
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr VirtualAllocEx(IntPtr h, IntPtr a, UIntPtr n, uint flags, uint protect);
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr CreateRemoteThread(IntPtr h, IntPtr attributes, UIntPtr stack, IntPtr start, IntPtr parameter, uint flags, out uint id);
    [DllImport("kernel32.dll", SetLastError=true)] static extern uint WaitForSingleObject(IntPtr h, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool FlushInstructionCache(IntPtr h, IntPtr start, UIntPtr size);

    static ulong U64(IntPtr h, ulong a) {
        byte[] b = new byte[8]; IntPtr got;
        if (!ReadProcessMemory(h,new IntPtr(unchecked((long)a)),b,8,out got) || got.ToInt64()!=8) return 0;
        return BitConverter.ToUInt64(b,0);
    }
    static bool Write(IntPtr h, ulong a, byte[] b) {
        IntPtr wrote;
        return WriteProcessMemory(h,new IntPtr(unchecked((long)a)),b,b.Length,out wrote) && wrote.ToInt64()==b.Length;
    }
    static void Q(List<byte> code, ulong value) { code.AddRange(BitConverter.GetBytes(value)); }
    static void PatchJump(List<byte> code, int displacementAt, int targetAt) {
        byte[] d=BitConverter.GetBytes(targetAt-(displacementAt+4));
        for(int i=0;i<4;i++) code[displacementAt+i]=d[i];
    }
    static bool Allowed(string shipName) {
        return shipName=="SmallBeamShip" || shipName=="SmallGunnerShip" ||
            shipName=="SmallHealerShip" || shipName=="SmallKamikaziShip" ||
            shipName=="SmallMissileShip";
    }
    public static Task<ulong> BeginLoad(int pid, ulong moduleBase, ulong classMeta, string shipName) {
        if(!Allowed(shipName)) throw new ArgumentException("Choose a frigate.");
        return Task.Run(() => LoadOnGameThread(pid,moduleBase,classMeta,shipName));
    }
    static ulong LoadOnGameThread(int pid, ulong moduleBase, ulong classMeta, string shipName) {
        const uint access=0x043A; // create thread, VM read/write/operation, query information
        IntPtr h=OpenProcess(access,false,pid);
        if(h==IntPtr.Zero) throw new Exception("OpenProcess failed " + Marshal.GetLastWin32Error());
        IntPtr thread=IntPtr.Zero;
        ulong interfaceAddress=0, originalTable=0, block=0;
        bool patched=false;
        try {
            ulong engine=U64(h,moduleBase+0x35C50E0UL);
            if(engine<0x10000UL) throw new Exception("GEngine unavailable");
            interfaceAddress=engine+0x28UL;
            originalTable=U64(h,interfaceAddress);
            ulong originalExec=U64(h,originalTable+8UL);
            if(originalTable<0x10000UL || originalExec!=moduleBase+0x139F120UL)
                throw new Exception("Unexpected FExec vtable");
            byte[] table=new byte[0x100]; IntPtr got;
            if(!ReadProcessMemory(h,new IntPtr(unchecked((long)originalTable)),table,table.Length,out got) || got.ToInt64()!=table.Length)
                throw new Exception("Could not copy FExec vtable");
            IntPtr allocation=VirtualAllocEx(h,IntPtr.Zero,new UIntPtr(0x1000),0x3000,0x40);
            if(allocation==IntPtr.Zero) throw new Exception("VirtualAllocEx failed");
            block=unchecked((ulong)allocation.ToInt64());
            ulong hook=block+0x100UL, command=block+0x400UL, clonedTable=block+0x600UL;
            ulong status=block+0x700UL, queued=block+0x708UL, result=block+0x710UL, path=block+0x800UL;
            if (classMeta < 0x10000UL) throw new Exception("BlueprintGeneratedClass unavailable");
            byte[] signature=new byte[8];
            if(!ReadProcessMemory(h,new IntPtr(unchecked((long)(moduleBase+0x16920D0UL))),signature,8,out got) || got.ToInt64()!=8 ||
                signature[0]!=0x48 || signature[1]!=0x89 || signature[2]!=0x5C)
                throw new Exception("Deferred-command function signature changed");
            byte[] loadSignature=new byte[] {0x40,0x55,0x53,0x56,0x57,0x41,0x54,0x41,0x55,0x41,0x56,0x41,0x57};
            byte[] actualLoad=new byte[loadSignature.Length];
            if(!ReadProcessMemory(h,new IntPtr(unchecked((long)(moduleBase+0x92A8A0UL))),actualLoad,actualLoad.Length,out got) || got.ToInt64()!=actualLoad.Length)
                throw new Exception("StaticLoadObject signature unreadable");
            for(int i=0;i<loadSignature.Length;i++) if(actualLoad[i]!=loadSignature[i]) throw new Exception("StaticLoadObject signature changed");
            List<byte> callback=new List<byte>();
            callback.AddRange(new byte[]{0x4D,0x85,0xC0,0x0F,0x84}); int nullJump=callback.Count;callback.AddRange(new byte[4]); // test r8,r8; je fallback
            callback.AddRange(new byte[]{0x41,0x81,0x38});callback.AddRange(BitConverter.GetBytes(0x00530046)); // FS
            callback.AddRange(new byte[]{0x0F,0x85});int firstJump=callback.Count;callback.AddRange(new byte[4]);
            callback.AddRange(new byte[]{0x41,0x81,0x78,0x04});callback.AddRange(BitConverter.GetBytes(0x00210058)); // X!
            callback.AddRange(new byte[]{0x0F,0x85});int secondJump=callback.Count;callback.AddRange(new byte[4]);
            callback.AddRange(new byte[]{0x49,0xBA});Q(callback,originalTable); // r10=old table
            callback.AddRange(new byte[]{0x4C,0x89,0x11}); // [rcx]=r10
            callback.AddRange(new byte[]{0x48,0x83,0xEC,0x38,0x31,0xC0}); // Win64 shadow space and three zero stack args
            callback.AddRange(new byte[]{0x48,0x89,0x44,0x24,0x20,0x48,0x89,0x44,0x24,0x28,0x48,0x89,0x44,0x24,0x30});
            callback.AddRange(new byte[]{0x48,0xB9});Q(callback,classMeta);
            callback.AddRange(new byte[]{0x31,0xD2,0x49,0xB8});Q(callback,path);
            callback.AddRange(new byte[]{0x45,0x31,0xC9,0x48,0xB8});Q(callback,moduleBase+0x92A8A0UL);
            callback.AddRange(new byte[]{0xFF,0xD0,0x49,0xBA});Q(callback,result);
            callback.AddRange(new byte[]{0x49,0x89,0x02,0x49,0xBA});Q(callback,status);
            callback.AddRange(new byte[]{0x41,0xC6,0x02,0x01,0x48,0x83,0xC4,0x38,0xB8,0x01,0x00,0x00,0x00,0xC3});
            int fallback=callback.Count;
            callback.AddRange(new byte[]{0x49,0xBA});Q(callback,originalTable);
            callback.AddRange(new byte[]{0x4C,0x89,0x11});
            callback.AddRange(new byte[]{0x48,0xB8});Q(callback,originalExec);callback.AddRange(new byte[]{0xFF,0xE0});
            PatchJump(callback,nullJump,fallback);PatchJump(callback,firstJump,fallback);PatchJump(callback,secondJump,fallback);
            if(callback.Count>0x300) throw new Exception("Hook too large");
            List<byte> queueCode=new List<byte>();
            queueCode.AddRange(new byte[]{0x48,0x83,0xEC,0x28,0x48,0xB9});Q(queueCode,engine);
            queueCode.AddRange(new byte[]{0x48,0xBA});Q(queueCode,command);
            queueCode.AddRange(new byte[]{0x48,0xB8});Q(queueCode,moduleBase+0x16920D0UL);
            queueCode.AddRange(new byte[]{0xFF,0xD0,0x0F,0xB6,0xC0,0x48,0xBA});Q(queueCode,queued);
            queueCode.AddRange(new byte[]{0x48,0x89,0x02,0x48,0x83,0xC4,0x28,0xC3});
            if(queueCode.Count>0x100) throw new Exception("Queue stub too large");
            byte[] payload=new byte[0x1000];
            Buffer.BlockCopy(queueCode.ToArray(),0,payload,0,queueCode.Count);
            Buffer.BlockCopy(callback.ToArray(),0,payload,0x100,callback.Count);
            byte[] commandBytes=System.Text.Encoding.Unicode.GetBytes("FSX!\0");
            Buffer.BlockCopy(commandBytes,0,payload,0x400,commandBytes.Length);
            Buffer.BlockCopy(table,0,payload,0x600,table.Length);
            Buffer.BlockCopy(BitConverter.GetBytes(hook),0,payload,0x608,8);
            byte[] pathBytes=System.Text.Encoding.Unicode.GetBytes(
                "/Game/Blueprints/SimpleAIShips/"+shipName+"."+shipName+"_C\0");
            if(pathBytes.Length>0x200) throw new Exception("Frigate path too long.");
            Buffer.BlockCopy(pathBytes,0,payload,0x800,pathBytes.Length);
            if(!Write(h,block,payload)) throw new Exception("Payload write failed");
            FlushInstructionCache(h,new IntPtr(unchecked((long)block)),new UIntPtr(0x400));
            if(U64(h,interfaceAddress)!=originalTable) throw new Exception("FExec vtable changed during setup");
            if(!Write(h,interfaceAddress,BitConverter.GetBytes(clonedTable))) throw new Exception("Vtable swap failed");
            patched=true;
            uint id;
            thread=CreateRemoteThread(h,IntPtr.Zero,UIntPtr.Zero,new IntPtr(unchecked((long)block)),IntPtr.Zero,0,out id);
            if(thread==IntPtr.Zero) throw new Exception("Queue thread failed");
            uint wait=WaitForSingleObject(thread,3000);
            if(wait!=0) throw new Exception("Queue thread wait="+wait);
            ulong queueResult=U64(h,queued);
            for(int i=0;i<200 && U64(h,status)==0;i++) Thread.Sleep(50);
            ulong ran=U64(h,status),loadedClass=U64(h,result);
            if(queueResult!=1 || ran!=1 || U64(h,interfaceAddress)!=originalTable)
                throw new Exception("Frigate class load did not finish on the game thread.");
            if(loadedClass<0x10000UL)
                throw new Exception(shipName+" class could not be loaded in this match.");
            return loadedClass;
        } finally {
            if(patched && U64(h,interfaceAddress)!=originalTable)
                Write(h,interfaceAddress,BitConverter.GetBytes(originalTable));
            if(thread!=IntPtr.Zero) CloseHandle(thread);
            CloseHandle(h);
            // The small remote block stays allocated so a delayed callback cannot jump into freed code.
        }
    }
}
'@
Add-Type -TypeDefinition $native -ErrorAction Stop
