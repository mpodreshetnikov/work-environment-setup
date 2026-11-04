using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace WorkEnvironmentSetup.Notifications {
    [ComVisible(true), Guid("53E31837-6600-4A81-9395-75CFFE746F94"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface INotificationActivationCallback {
        void Activate([MarshalAs(UnmanagedType.LPWStr)] string appId, [MarshalAs(UnmanagedType.LPWStr)] string arguments, IntPtr data, uint count);
    }
    [ComVisible(true), Guid("00000001-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IClassFactory {
        [PreserveSig] int CreateInstance(IntPtr outer, ref Guid iid, out IntPtr result);
        [PreserveSig] int LockServer([MarshalAs(UnmanagedType.Bool)] bool locked);
    }
    public sealed class Settings {
        public string Clsid { get; set; }
        public string[] AppIds { get; set; }
        public string ActivationScript { get; set; }
    }
    public sealed class Activation {
        public string AppId { get; set; }
        public string Arguments { get; set; }
    }
    [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
    public sealed class Callback : INotificationActivationCallback {
        public void Activate(string appId, string arguments, IntPtr data, uint count) {
            Bridge.Dispatch(new Activation { AppId=appId, Arguments=arguments });
        }
    }
    [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
    public sealed class Factory : IClassFactory {
        private readonly Callback callback = new Callback();
        public int CreateInstance(IntPtr outer, ref Guid iid, out IntPtr result) {
            result=IntPtr.Zero;
            if(outer!=IntPtr.Zero) return unchecked((int)0x80040110);
            IntPtr unknown=Marshal.GetIUnknownForObject(callback);
            try { return Marshal.QueryInterface(unknown,ref iid,out result); }
            finally { Marshal.Release(unknown); }
        }
        public int LockServer(bool locked) { return 0; }
    }
    public static class Bridge {
        [DllImport("ole32.dll")] static extern int CoRegisterClassObject(ref Guid clsid, [MarshalAs(UnmanagedType.Interface)] IClassFactory factory, uint context, uint flags, out uint cookie);
        [DllImport("ole32.dll")] static extern int CoRevokeClassObject(uint cookie);
        [DllImport("ole32.dll")] static extern int CoCreateInstance(ref Guid clsid,IntPtr outer,uint context,ref Guid iid,out IntPtr instance);
        static Settings settings;
        static string Root { get { return Path.GetDirectoryName(typeof(Bridge).Assembly.Location); } }
        static Settings ReadSettings() {
            var value=new JavaScriptSerializer().Deserialize<Settings>(File.ReadAllText(Path.Combine(Root,"notification-config.private.json")));
            if(value==null || value.AppIds==null || value.AppIds.Length==0 || Path.GetFullPath(value.ActivationScript)!=Path.Combine(Root,"NotificationActivation.ps1")) throw new InvalidDataException("Invalid notification bridge settings.");
            return value;
        }
        public static void Dispatch(Activation activation) {
            if(settings==null) settings=ReadSettings();
            if(activation==null || Array.IndexOf(settings.AppIds,activation.AppId)<0 || activation.Arguments==null || !Regex.IsMatch(activation.Arguments,@"\Atype=(?:action&action=[0-9]{1,3}|click)&tag=[0-9]{1,40}\z")) throw new InvalidDataException("Unknown notification activation.");
            string encoded=Convert.ToBase64String(Encoding.UTF8.GetBytes(new JavaScriptSerializer().Serialize(activation)));
            var start=new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),"WindowsPowerShell\\v1.0\\powershell.exe"));
            start.UseShellExecute=false; start.CreateNoWindow=true;
            start.Arguments="-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \""+settings.ActivationScript+"\" -ActivationBase64 "+encoded;
            using(var process=Process.Start(start)) { }
        }
        [STAThread]
        public static int Main(string[] args) {
            try {
                settings=ReadSettings();
                if(args.Length==2 && args[0]=="--dispatch-base64") {
                    Dispatch(new JavaScriptSerializer().Deserialize<Activation>(Encoding.UTF8.GetString(Convert.FromBase64String(args[1])))); return 0;
                }
                if(args.Length==2 && args[0]=="--probe-com") {
                    using(var key=Microsoft.Win32.Registry.ClassesRoot.OpenSubKey("CLSID\\"+settings.Clsid+"\\LocalServer32")) {
                        if(key==null) throw new InvalidDataException("COM registration is invisible to the client.");
                        File.WriteAllText(Path.Combine(Root,"probe-registration.private.json"),new JavaScriptSerializer().Serialize(new { Clsid=settings.Clsid,Server=key.GetValue("") }));
                    }
                    var payload=new JavaScriptSerializer().Deserialize<Activation>(Encoding.UTF8.GetString(Convert.FromBase64String(args[1])));
                    Guid id=new Guid(settings.Clsid),iid=typeof(INotificationActivationCallback).GUID;IntPtr pointer;
                    Marshal.ThrowExceptionForHR(CoCreateInstance(ref id,IntPtr.Zero,0x80004,ref iid,out pointer));
                    var callback=(INotificationActivationCallback)Marshal.GetObjectForIUnknown(pointer);Marshal.Release(pointer);
                    try { callback.Activate(payload.AppId,payload.Arguments,IntPtr.Zero,0); } finally { Marshal.FinalReleaseComObject(callback); }
                    return 0;
                }
                Guid clsid=new Guid(settings.Clsid); uint cookie;
                var factory=new Factory();
                Marshal.ThrowExceptionForHR(CoRegisterClassObject(ref clsid,factory,4,1,out cookie));
                File.WriteAllText(Path.Combine(Root,"server-ready.private.json"),"{}");
                try {
                    using(var timer=new Timer()) { timer.Interval=45000;timer.Tick+=(s,e)=>Application.ExitThread();timer.Start();Application.Run(); }
                } finally { CoRevokeClassObject(cookie); GC.KeepAlive(factory); }
                return 0;
            } catch(Exception error) {
                try { File.WriteAllText(Path.Combine(Root,"bridge-error.private.json"),new JavaScriptSerializer().Serialize(new { Error=error.Message,HResult=error.HResult,Is64Bit=Environment.Is64BitProcess,User=Environment.UserName,Administrator=new System.Security.Principal.WindowsPrincipal(System.Security.Principal.WindowsIdentity.GetCurrent()).IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator) })); } catch { }
                return 1;
            }
        }
    }
    [ComImport, Guid("00021401-0000-0000-C000-000000000046")] class ShellLink { }
    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore {
        void GetCount(out uint count);
        void GetAt(uint index,out PropertyKey key);
        void GetValue(ref PropertyKey key,out PropVariant value);
        void SetValue(ref PropertyKey key,ref PropVariant value);
        void Commit();
    }
    [StructLayout(LayoutKind.Sequential)] struct PropertyKey { public Guid Format; public uint Id; }
    [StructLayout(LayoutKind.Sequential)] struct PropVariant { public ushort Type,A,B,C; public IntPtr Pointer,Extra; }
    public static class Shortcut {
        public static void SetActivator(string path,string clsid) {
            object link=new ShellLink();
            try {
                var file=(IPersistFile)link;file.Load(path,2);
                var store=(IPropertyStore)link;
                var key=new PropertyKey { Format=new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"),Id=26 };
                IntPtr pointer=Marshal.AllocCoTaskMem(16);
                try { Marshal.StructureToPtr(new Guid(clsid),pointer,false);var value=new PropVariant {Type=72,Pointer=pointer};store.SetValue(ref key,ref value);store.Commit();file.Save(path,true); }
                finally {Marshal.FreeCoTaskMem(pointer);}
            } finally {Marshal.FinalReleaseComObject(link);}
        }
    }
}
