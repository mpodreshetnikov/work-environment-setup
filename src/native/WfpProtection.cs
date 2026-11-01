using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Security.Cryptography;

namespace WorkEnvironmentSetup { public static class WfpProtection {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct Display { public string name, description; }
    [StructLayout(LayoutKind.Sequential)] struct Blob { public uint size; public IntPtr data; }
    [StructLayout(LayoutKind.Explicit, Size=8)] struct Union { [FieldOffset(0)] public ulong number; [FieldOffset(0)] public IntPtr pointer; }
    [StructLayout(LayoutKind.Sequential)] struct Value { public uint type; public Union value; }
    [StructLayout(LayoutKind.Sequential)] struct Condition { public Guid key; public uint match; public Value value; }
    [StructLayout(LayoutKind.Sequential)] struct Action { public uint type; public Guid key; }
    [StructLayout(LayoutKind.Explicit,Size=16)] struct Context { [FieldOffset(0)] public ulong raw; [FieldOffset(0)] public Guid key; }
    [StructLayout(LayoutKind.Sequential)] struct Filter {
        public Guid key; public Display display; public uint flags; public IntPtr provider; public Blob providerData;
        public Guid layer, sublayer; public Value weight; public uint count; public IntPtr conditions;
        public Action action; public Context context; public IntPtr reserved; public ulong id; public Value effective;
    }
    [StructLayout(LayoutKind.Sequential)] struct Sublayer { public Guid key; public Display display; public uint flags; public IntPtr provider; public Blob data; public ushort weight; }
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct Session { public Guid key; public Display display; public uint flags,timeout,pid; public IntPtr sid; public string user; [MarshalAs(UnmanagedType.Bool)] public bool kernel; }
    [DllImport("fwpuclnt.dll",CharSet=CharSet.Unicode)] static extern uint FwpmEngineOpen0(string server,uint authentication,IntPtr identity,ref Session session,out IntPtr engine);
    [DllImport("fwpuclnt.dll")] static extern uint FwpmEngineClose0(IntPtr engine);
    [DllImport("fwpuclnt.dll")] static extern uint FwpmSubLayerAdd0(IntPtr engine,ref Sublayer sublayer,IntPtr sd);
    [DllImport("fwpuclnt.dll")] static extern uint FwpmFilterAdd0(IntPtr engine,ref Filter filter,IntPtr sd,out ulong id);
    [DllImport("fwpuclnt.dll")] static extern uint FwpmFilterDeleteByKey0(IntPtr engine,ref Guid key);
    [DllImport("fwpuclnt.dll")] static extern uint FwpmFilterGetByKey0(IntPtr engine,ref Guid key,out IntPtr filter);
    [DllImport("fwpuclnt.dll")] static extern uint FwpmSubLayerDeleteByKey0(IntPtr engine,ref Guid key);
    [DllImport("fwpuclnt.dll")] static extern uint FwpmTransactionBegin0(IntPtr engine,uint flags);
    [DllImport("fwpuclnt.dll")] static extern uint FwpmTransactionCommit0(IntPtr engine);
    [DllImport("fwpuclnt.dll")] static extern uint FwpmTransactionAbort0(IntPtr engine);
    [DllImport("fwpuclnt.dll",CharSet=CharSet.Unicode)] static extern uint FwpmGetAppIdFromFileName0(string path,out IntPtr blob);
    [DllImport("fwpuclnt.dll")] static extern void FwpmFreeMemory0(ref IntPtr memory);
    [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)] static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string s,uint revision,out IntPtr sd,out uint size);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);
    static void Check(uint result,string stage) { if(result!=0) throw new Exception(stage+": 0x"+result.ToString("X8")); }
    static Value Number(uint type,ulong number) { return new Value {type=type,value=new Union {number=number}}; }
    static Value Pointer(uint type,IntPtr pointer) { return new Value {type=type,value=new Union {pointer=pointer}}; }
    static Guid FilterKey(Guid sublayer,string selector,ushort port,bool ipv6) {
        using(var hash=SHA256.Create()) {
            byte[] digest=hash.ComputeHash(Encoding.UTF8.GetBytes(sublayer+"|"+selector.ToUpperInvariant()+"|"+port+"|"+ipv6));
            byte[] bytes=new byte[16]; Array.Copy(digest,bytes,16); return new Guid(bytes);
        }
    }
    static void ValidateSid(string sid) { new System.Security.Principal.SecurityIdentifier(sid); }
    static IntPtr SecurityBlob(string sddl,out IntPtr sd) {
        uint size;
        if(!ConvertStringSecurityDescriptorToSecurityDescriptor(sddl,1,out sd,out size)) throw new Win32Exception(Marshal.GetLastWin32Error());
        IntPtr blob=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(Blob)));
        Marshal.StructureToPtr(new Blob {size=size,data=sd},blob,false);return blob;
    }
    public static string[] InstallBlocks(string tag,string ownerSid,string[] programs,ushort[] ports,Guid sublayerKey) {
        if(!System.Text.RegularExpressions.Regex.IsMatch(tag,"^[A-Za-z0-9_]+$")) throw new Exception("Invalid tag key.");
        ValidateSid(ownerSid);
        if(IntPtr.Size!=8 || ports.Length==0) throw new Exception("A 64-bit host and at least one alternate proxy port are required.");
        var keys=new List<string>(); IntPtr engine=IntPtr.Zero, sd=IntPtr.Zero, blob=IntPtr.Zero, memory=IntPtr.Zero;
        IntPtr userSd=IntPtr.Zero,userBlob=IntPtr.Zero,objectSd=IntPtr.Zero;
        bool transaction=false;
        try {
            var session=new Session {key=Guid.NewGuid(),display=new Display {name="AI VPN scoped persistent filters"}};
            Check(FwpmEngineOpen0(null,10,IntPtr.Zero,ref session,out engine),"EngineOpen");
            Check(FwpmTransactionBegin0(engine,0),"TransactionBegin"); transaction=true;
            uint objectSdSize;
            if(!ConvertStringSecurityDescriptorToSecurityDescriptor("D:(A;;GA;;;SY)(A;;GA;;;BA)(A;;GR;;;"+ownerSid+")",1,out objectSd,out objectSdSize)) throw new Win32Exception(Marshal.GetLastWin32Error());
            var sub=new Sublayer {key=sublayerKey,display=new Display {name="AI VPN scoped alternate proxy denial"},flags=1,weight=65535};
            Check(FwpmSubLayerAdd0(engine,ref sub,objectSd),"SubLayerAdd");
            blob=SecurityBlob("D:(XA;;0x1;;;"+ownerSid+";(Exists POLICYAPPID://"+tag+"))",out sd);
            userBlob=SecurityBlob("D:(A;;0x1;;;"+ownerSid+")",out userSd);
            int stride=Marshal.SizeOf(typeof(Condition)); memory=Marshal.AllocHGlobal(stride*3);
            var selectors=new List<string>(); selectors.Add("TAG:"+tag); foreach(string program in programs) { if(String.IsNullOrEmpty(program)) throw new Exception("Empty executable path."); selectors.Add(program); }
            foreach(string selector in selectors) {
                IntPtr app=IntPtr.Zero;
                try {
                    Condition identity;
                    if(selector.StartsWith("TAG:")) identity=new Condition {key=new Guid("af043a0a-b34d-4f86-979c-c90371af6e66"),match=0,value=Pointer(14,blob)};
                    else { Check(FwpmGetAppIdFromFileName0(selector,out app),"GetAppId"); identity=new Condition {key=new Guid("d78e1e87-8644-4ea5-9437-d809ecefc971"),match=0,value=Pointer(12,app)}; }
                    Marshal.StructureToPtr(identity,memory,false);
                    uint count=2;
                    if(!selector.StartsWith("TAG:")) {
                        Marshal.StructureToPtr(new Condition {key=new Guid("af043a0a-b34d-4f86-979c-c90371af6e66"),match=0,value=Pointer(14,userBlob)},IntPtr.Add(memory,stride*2),false);count=3;
                    }
                    foreach(ushort port in ports) {
                        if(port==0) throw new Exception("A remote proxy port cannot be zero.");
                        Marshal.StructureToPtr(new Condition {key=new Guid("c35a604d-d22b-4e1a-91b4-68f674ee674b"),match=0,value=Number(2,port)},IntPtr.Add(memory,stride),false);
                        foreach(bool ipv6 in new bool[] {false,true}) {
                            Guid key=FilterKey(sublayerKey,selector,port,ipv6);
                            var f=new Filter {key=key,display=new Display {name="AI VPN: alternate proxy denied for "+tag},flags=1,layer=new Guid(ipv6?"4a72393b-319f-44bc-84c3-ba54dcb3b6b4":"c38d57d1-05a7-4c33-904f-7fbceee60e82"),sublayer=sublayerKey,weight=Number(1,15),count=count,conditions=memory,action=new Action {type=0x1001}};
                            ulong id; Check(FwpmFilterAdd0(engine,ref f,objectSd,out id),"FilterAdd"); keys.Add(key.ToString());
                        }
                    }
                } finally { if(app!=IntPtr.Zero) FwpmFreeMemory0(ref app); }
            }
            Check(FwpmTransactionCommit0(engine),"TransactionCommit"); transaction=false;
            return keys.ToArray();
        } finally {
            if(transaction && engine!=IntPtr.Zero) FwpmTransactionAbort0(engine);
            if(engine!=IntPtr.Zero) FwpmEngineClose0(engine);
            if(memory!=IntPtr.Zero) Marshal.FreeHGlobal(memory);
            if(blob!=IntPtr.Zero) Marshal.FreeHGlobal(blob);
            if(sd!=IntPtr.Zero) LocalFree(sd);
            if(userBlob!=IntPtr.Zero) Marshal.FreeHGlobal(userBlob);
            if(userSd!=IntPtr.Zero) LocalFree(userSd);
            if(objectSd!=IntPtr.Zero) LocalFree(objectSd);
        }
    }
    public static void RemoveBlocks(Guid sublayer,string[] keys) {
        IntPtr engine=IntPtr.Zero; bool transaction=false;
        try {
            var session=new Session {key=Guid.NewGuid(),display=new Display {name="AI VPN scoped filter rollback"}};
            Check(FwpmEngineOpen0(null,10,IntPtr.Zero,ref session,out engine),"EngineOpen");
            Check(FwpmTransactionBegin0(engine,0),"TransactionBegin"); transaction=true;
            foreach(string value in keys) { Guid key=new Guid(value);uint result=FwpmFilterDeleteByKey0(engine,ref key);if(result!=0x80320003) Check(result,"FilterDelete"); }
            uint removed=FwpmSubLayerDeleteByKey0(engine,ref sublayer);if(removed!=0x80320007) Check(removed,"SubLayerDelete");
            Check(FwpmTransactionCommit0(engine),"TransactionCommit"); transaction=false;
        } finally {
            if(transaction && engine!=IntPtr.Zero) FwpmTransactionAbort0(engine);
            if(engine!=IntPtr.Zero) FwpmEngineClose0(engine);
        }
    }
    public static bool VerifyBlocks(Guid sublayer,string[] keys) {
        IntPtr engine=IntPtr.Zero;
        try {
            var session=new Session {key=Guid.NewGuid()};Check(FwpmEngineOpen0(null,10,IntPtr.Zero,ref session,out engine),"EngineOpen");
            if(keys.Length==0) return false;
            foreach(string value in keys) {
                Guid key=new Guid(value);IntPtr pointer=IntPtr.Zero;
                uint result=FwpmFilterGetByKey0(engine,ref key,out pointer);
                if(result==0x80320003) return false;Check(result,"FilterGet");
                try {var filter=(Filter)Marshal.PtrToStructure(pointer,typeof(Filter));if(filter.sublayer!=sublayer || filter.action.type!=0x1001 || (filter.flags&1)==0) return false;}
                finally {if(pointer!=IntPtr.Zero) FwpmFreeMemory0(ref pointer);}
            }
            return true;
        } finally { if(engine!=IntPtr.Zero) FwpmEngineClose0(engine); }
    }
    static int Fetch(string exe,int port) {
        var s=new ProcessStartInfo(exe,"--noproxy * --connect-timeout 2 --max-time 3 --silent --output NUL http://127.0.0.1:"+port+"/");
        s.UseShellExecute=false; s.CreateNoWindow=true;
        using(var p=Process.Start(s)) { if(!p.WaitForExit(6000)) { p.Kill(); return 99; } return p.ExitCode; }
    }
    public static Dictionary<string,object> Test(string exe,string tag,string ownerSid) {
        if(IntPtr.Size!=8) throw new Exception("This probe requires a 64-bit host.");
        ValidateSid(ownerSid);
        var listener=new TcpListener(IPAddress.Loopback,0); listener.Start();
        int port=((IPEndPoint)listener.LocalEndpoint).Port;
        ThreadPool.QueueUserWorkItem(delegate(object ignored) {
            try { while(true) { using(var client=listener.AcceptTcpClient()) { var bytes=Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK"); var stream=client.GetStream(); byte[] request=new byte[4096]; stream.ReadTimeout=2000; stream.Read(request,0,request.Length); stream.Write(bytes,0,bytes.Length); } } } catch { }
        });
        IntPtr engine=IntPtr.Zero, app=IntPtr.Zero, sd=IntPtr.Zero, sdBlob=IntPtr.Zero, memory=IntPtr.Zero;
        try {
            int before=Fetch(exe,port);
            var session=new Session {key=Guid.NewGuid(),display=new Display {name="Temporary AI VPN isolated probe"},flags=1};
            Check(FwpmEngineOpen0(null,10,IntPtr.Zero,ref session,out engine),"EngineOpen");
            var sub=new Sublayer {key=Guid.NewGuid(),display=new Display {name="Temporary AI VPN isolated probe"},weight=65535};
            Check(FwpmSubLayerAdd0(engine,ref sub,IntPtr.Zero),"SubLayerAdd");
            var conditions=new List<Condition>();
            if(String.IsNullOrEmpty(tag)) {
                Check(FwpmGetAppIdFromFileName0(exe,out app),"GetAppId");
                conditions.Add(new Condition {key=new Guid("d78e1e87-8644-4ea5-9437-d809ecefc971"),match=0,value=Pointer(12,app)});
                sdBlob=SecurityBlob("D:(A;;0x1;;;"+ownerSid+")",out sd);
                conditions.Add(new Condition {key=new Guid("af043a0a-b34d-4f86-979c-c90371af6e66"),match=0,value=Pointer(14,sdBlob)});
            } else {
                uint size;
                string sddl="D:(XA;;0x1;;;"+ownerSid+";(Exists POLICYAPPID://"+tag+"))";
                if(!ConvertStringSecurityDescriptorToSecurityDescriptor(sddl,1,out sd,out size)) throw new Win32Exception(Marshal.GetLastWin32Error(),"Tag security descriptor");
                sdBlob=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(Blob)));
                Marshal.StructureToPtr(new Blob {size=size,data=sd},sdBlob,false);
                conditions.Add(new Condition {key=new Guid("af043a0a-b34d-4f86-979c-c90371af6e66"),match=0,value=Pointer(14,sdBlob)});
            }
            conditions.Add(new Condition {key=new Guid("c35a604d-d22b-4e1a-91b4-68f674ee674b"),match=0,value=Number(2,(ulong)port)});
            int stride=Marshal.SizeOf(typeof(Condition)); memory=Marshal.AllocHGlobal(stride*conditions.Count);
            for(int i=0;i<conditions.Count;i++) Marshal.StructureToPtr(conditions[i],IntPtr.Add(memory,i*stride),false);
            var filter=new Filter {key=Guid.NewGuid(),display=new Display {name="Temporary AI VPN isolated probe"},layer=new Guid("c38d57d1-05a7-4c33-904f-7fbceee60e82"),sublayer=sub.key,weight=Number(1,15),count=(uint)conditions.Count,conditions=memory,action=new Action {type=0x1001}};
            ulong id; Check(FwpmFilterAdd0(engine,ref filter,IntPtr.Zero,out id),"FilterAdd");
            int blocked=Fetch(exe,port);
            Check(FwpmEngineClose0(engine),"EngineClose"); engine=IntPtr.Zero;
            int restored=Fetch(exe,port);
            return new Dictionary<string,object> {{"before",before},{"blocked",blocked},{"afterCleanup",restored},{"port",port},{"tag",tag??""},{"filterSize",Marshal.SizeOf(typeof(Filter))}};
        } finally {
            if(engine!=IntPtr.Zero) FwpmEngineClose0(engine);
            if(app!=IntPtr.Zero) FwpmFreeMemory0(ref app);
            if(memory!=IntPtr.Zero) Marshal.FreeHGlobal(memory);
            if(sdBlob!=IntPtr.Zero) Marshal.FreeHGlobal(sdBlob);
            if(sd!=IntPtr.Zero) LocalFree(sd);
            listener.Stop();
        }
    }
}
}
