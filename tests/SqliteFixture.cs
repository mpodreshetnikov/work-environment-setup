using System;
using System.Runtime.InteropServices;
using System.Text;
// Test-only fixture writer. The installer uses the separate read-only adapter.
public static class WesSqliteFixture {
    [DllImport("e_sqlite3.dll", CallingConvention=CallingConvention.Cdecl)] private static extern int sqlite3_open_v2(byte[] path,out IntPtr db,int flags,IntPtr vfs);
    [DllImport("e_sqlite3.dll", CallingConvention=CallingConvention.Cdecl)] private static extern int sqlite3_close(IntPtr db);
    [DllImport("e_sqlite3.dll", CallingConvention=CallingConvention.Cdecl)] private static extern int sqlite3_exec(IntPtr db,byte[] sql,IntPtr callback,IntPtr data,out IntPtr error);
    [DllImport("e_sqlite3.dll", CallingConvention=CallingConvention.Cdecl)] private static extern void sqlite3_free(IntPtr memory);
    public static void Create(string path) {
        IntPtr db=IntPtr.Zero,error=IntPtr.Zero;
        try {
            int status=sqlite3_open_v2(Encoding.UTF8.GetBytes(path+"\0"),out db,6,IntPtr.Zero);
            if(status!=0) throw new Exception("Fixture open failed: "+status);
            string sql="CREATE TABLE ProfileItem (IndexId TEXT, Address TEXT, Port INTEGER, Id TEXT, ConfigType INTEGER, Network TEXT, StreamSecurity TEXT, Security TEXT, Flow TEXT, PublicKey TEXT, Sni TEXT, ShortId TEXT, Fingerprint TEXT);"+
                "INSERT INTO ProfileItem VALUES ('profile''quoted','203.0.113.10',443,'11111111-1111-4111-8111-111111111111',5,'tcp','reality','none','xtls-rprx-vision','fixture-key','example.com','abcd','firefox');";
            status=sqlite3_exec(db,Encoding.UTF8.GetBytes(sql+"\0"),IntPtr.Zero,IntPtr.Zero,out error);
            if(status!=0) throw new Exception("Fixture SQL failed: "+status);
        } finally { if(error!=IntPtr.Zero)sqlite3_free(error); if(db!=IntPtr.Zero)sqlite3_close(db); }
    }
}
