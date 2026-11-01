using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace WorkEnvironmentSetup {
    public static class CanonicalPath {
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr attributes, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern uint GetFinalPathNameByHandle(SafeFileHandle handle, StringBuilder path, uint capacity, uint flags);
        public static string Resolve(string path) {
            string full=Path.GetFullPath(path);
            // Attribute-only access works for running executables and directories.
            using(var handle=CreateFile(full,0,7,IntPtr.Zero,3,0x02000000,IntPtr.Zero)) {
                if(handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(),"Cannot resolve an installation path.");
                var buffer=new StringBuilder(32768);
                uint size=GetFinalPathNameByHandle(handle,buffer,(uint)buffer.Capacity,0);
                if(size==0 || size>=buffer.Capacity) throw new Win32Exception(Marshal.GetLastWin32Error(),"Cannot read the final installation path.");
                string result=buffer.ToString();
                if(result.StartsWith(@"\\?\UNC\",StringComparison.OrdinalIgnoreCase)) return @"\\"+result.Substring(8);
                if(result.StartsWith(@"\\?\",StringComparison.OrdinalIgnoreCase)) return result.Substring(4);
                return result;
            }
        }
    }
}
