using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace WorkEnvironmentSetup {
    public static class SqliteProfileReader {
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern IntPtr LoadLibraryEx(string path, IntPtr file, uint flags);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern uint GetModuleFileName(IntPtr module, StringBuilder path, int capacity);
        [DllImport("e_sqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
        private static extern int sqlite3_open_v2(byte[] path, out IntPtr db, int flags, IntPtr vfs);
        [DllImport("e_sqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
        private static extern int sqlite3_close(IntPtr db);
        [DllImport("e_sqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
        private static extern int sqlite3_busy_timeout(IntPtr db, int milliseconds);
        [DllImport("e_sqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
        private static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int count, out IntPtr statement, IntPtr tail);
        [DllImport("e_sqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
        private static extern int sqlite3_bind_text(IntPtr statement, int parameter, byte[] text, int count, IntPtr destructor);
        [DllImport("e_sqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
        private static extern int sqlite3_step(IntPtr statement);
        [DllImport("e_sqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
        private static extern int sqlite3_finalize(IntPtr statement);
        [DllImport("e_sqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
        private static extern int sqlite3_column_count(IntPtr statement);
        [DllImport("e_sqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
        private static extern IntPtr sqlite3_column_name(IntPtr statement, int column);
        [DllImport("e_sqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
        private static extern IntPtr sqlite3_column_text(IntPtr statement, int column);
        [DllImport("e_sqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
        private static extern int sqlite3_column_bytes(IntPtr statement, int column);
        [DllImport("e_sqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
        private static extern int sqlite3_column_type(IntPtr statement, int column);

        private static IntPtr loadedLibrary = IntPtr.Zero;
        private static string loadedPath;
        private static readonly object loadLock = new object();
        private static byte[] Utf8(string text) { return Encoding.UTF8.GetBytes(text + "\0"); }
        private static string ReadUtf8(IntPtr pointer, int length) {
            if (pointer == IntPtr.Zero) return null;
            if (length < 0) { length = 0; while (Marshal.ReadByte(pointer, length) != 0) length++; }
            byte[] bytes = new byte[length]; Marshal.Copy(pointer, bytes, 0, length);
            return Encoding.UTF8.GetString(bytes);
        }
        private static void Check(int status, string stage) {
            if (status != 0) throw new InvalidOperationException("SQLite " + stage + " failed (" + status.ToString(CultureInfo.InvariantCulture) + ").");
        }
        public static void Load(string libraryPath) {
            string full = Path.GetFullPath(libraryPath);
            if (!File.Exists(full)) throw new FileNotFoundException("The v2rayN SQLite library was not found.");
            lock (loadLock) {
                if (loadedLibrary != IntPtr.Zero) {
                    if (!String.Equals(loadedPath, full, StringComparison.OrdinalIgnoreCase))
                        throw new InvalidOperationException("Another v2rayN SQLite library is already loaded in this host. Use a fresh PowerShell process.");
                    return;
                }
                IntPtr module = LoadLibraryEx(full, IntPtr.Zero, 8);
                if (module == IntPtr.Zero) throw new InvalidOperationException("Could not load the v2rayN SQLite library. Check the PowerShell and v2rayN architectures.");
                var actual = new StringBuilder(32768);
                if (GetModuleFileName(module, actual, actual.Capacity) == 0 || !String.Equals(Path.GetFullPath(actual.ToString()), full, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("Unexpected SQLite library location.");
                loadedLibrary = module; loadedPath = full;
            }
        }
        // Values returned by this method include VPN credentials. Callers must not log them.
        public static Dictionary<string,string> ReadProfile(string databasePath, string profileId) {
            if (loadedLibrary == IntPtr.Zero) throw new InvalidOperationException("Load the v2rayN SQLite library first.");
            if (!File.Exists(databasePath)) throw new FileNotFoundException("The v2rayN profile database was not found.");
            IntPtr db = IntPtr.Zero, statement = IntPtr.Zero;
            try {
                Check(sqlite3_open_v2(Utf8(Path.GetFullPath(databasePath)), out db, 1, IntPtr.Zero), "read-only open");
                Check(sqlite3_busy_timeout(db, 1500), "busy timeout");
                Check(sqlite3_prepare_v2(db, Utf8("SELECT * FROM ProfileItem WHERE IndexId = ? LIMIT 1"), -1, out statement, IntPtr.Zero), "prepare");
                byte[] value = Utf8(profileId);
                Check(sqlite3_bind_text(statement, 1, value, value.Length - 1, new IntPtr(-1)), "bind");
                int status = sqlite3_step(statement);
                if (status == 101) return null;
                if (status != 100) throw new InvalidOperationException("SQLite profile read failed (" + status + ").");
                var result = new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
                for (int column = 0; column < sqlite3_column_count(statement); column++) {
                    string name = ReadUtf8(sqlite3_column_name(statement, column), -1);
                    result[name] = sqlite3_column_type(statement, column) == 5 ? null : ReadUtf8(sqlite3_column_text(statement, column), sqlite3_column_bytes(statement, column));
                }
                return result;
            } finally {
                if (statement != IntPtr.Zero) sqlite3_finalize(statement);
                if (db != IntPtr.Zero) sqlite3_close(db);
            }
        }
    }
}
