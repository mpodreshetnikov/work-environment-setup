using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace WorkEnvironmentSetup {
    public sealed class NativeCommandPlan {
        public string Executable { get; set; }
        public string[] PrefixArguments { get; set; }
    }
    public sealed class CliLaunchPlan {
        public bool Success { get; set; }
        public string Scope { get; set; }
        public string Error { get; set; }
        public string ProxyUrl { get; set; }
        public NativeCommandPlan Command { get; set; }
    }
    public sealed class CliArgumentsPayload {
        public int SchemaVersion { get; set; }
        public string OwnerSid { get; set; }
        public string[] Arguments { get; set; }
    }
    public static class CliBridge {
        [DllImport("kernel32.dll")] private static extern IntPtr GetConsoleWindow();
        public static string QuoteArgument(string value) {
            if (value == null) value = "";
            if (value.IndexOf('\0') >= 0) throw new ArgumentException("CLI arguments cannot contain NUL.");
            var result = new StringBuilder(); result.Append('"'); int slashes=0;
            foreach (char character in value) {
                if (character == '\\') { slashes++; continue; }
                if (character == '"') { result.Append('\\', slashes*2+1); result.Append('"'); }
                else { result.Append('\\', slashes); result.Append(character); }
                slashes=0;
            }
            result.Append('\\', slashes*2); result.Append('"'); return result.ToString();
        }
        public static string JoinArguments(string[] arguments) {
            var values=new List<string>(); foreach (string value in arguments) values.Add(QuoteArgument(value));
            return String.Join(" ",values.ToArray());
        }
        private static string PowerShellPath() {
            string folder=Environment.Is64BitOperatingSystem && !Environment.Is64BitProcess ? "Sysnative" : "System32";
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),folder,"WindowsPowerShell","v1.0","powershell.exe");
        }
        private static CliLaunchPlan ReadPlan(string root,string scope,JavaScriptSerializer serializer) {
            string script=Path.Combine(root,"runtime","Check.ps1");
            if (!File.Exists(script)) throw new InvalidOperationException("The VPN launch check is missing. Repair the installation.");
            var start=new ProcessStartInfo(PowerShellPath(),JoinArguments(new string[] {"-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-File",script,"-Scope",scope}));
            start.UseShellExecute=false;start.CreateNoWindow=true;start.RedirectStandardOutput=true;start.RedirectStandardError=true;
            start.StandardOutputEncoding=Encoding.UTF8;start.StandardErrorEncoding=Encoding.UTF8;
            using (var process=Process.Start(start)) {
                var stdout=process.StandardOutput.ReadToEndAsync();var stderr=process.StandardError.ReadToEndAsync();
                if (!process.WaitForExit(45000)) { process.Kill();throw new InvalidOperationException("The VPN launch check timed out."); }
                string text=stdout.GetAwaiter().GetResult();stderr.GetAwaiter().GetResult();
                if (process.ExitCode!=0) throw new InvalidOperationException("The VPN launch check failed. Run the verification command.");
                CliLaunchPlan plan;
                try { plan=serializer.Deserialize<CliLaunchPlan>(text); }
                catch { throw new InvalidOperationException("The VPN launch check returned invalid metadata."); }
                if (plan==null || !plan.Success) throw new InvalidOperationException(plan==null || String.IsNullOrEmpty(plan.Error) ? "The VPN is not ready." : plan.Error);
                if (plan.Scope!=scope || plan.Command==null || !Path.IsPathRooted(plan.Command.Executable) || !File.Exists(plan.Command.Executable) || !String.Equals(Path.GetExtension(plan.Command.Executable),".exe",StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("The VPN launch plan is invalid.");
                Uri proxy;
                if (!Uri.TryCreate(plan.ProxyUrl,UriKind.Absolute,out proxy) || proxy.Scheme!="http" || proxy.Host!="127.0.0.1" || proxy.Port<1 || proxy.Port>65535 || proxy.UserInfo.Length!=0 || proxy.Query.Length!=0 || proxy.Fragment.Length!=0 || proxy.AbsolutePath!="/")
                    throw new InvalidOperationException("The pinned proxy address is invalid.");
                return plan;
            }
        }
        private static int RunTarget(CliLaunchPlan plan,string[] arguments) {
            var all=new List<string>();if (plan.Command.PrefixArguments!=null) all.AddRange(plan.Command.PrefixArguments);all.AddRange(arguments);
            string commandLine=JoinArguments(all.ToArray());
            if(commandLine.Length+plan.Command.Executable.Length+4>=32767) throw new ArgumentException("The native command line is too long. Use stdin or a file for large input.");
            var start=new ProcessStartInfo(plan.Command.Executable,commandLine);
            bool console=GetConsoleWindow()!=IntPtr.Zero;
            start.UseShellExecute=false;start.CreateNoWindow=!console;
            start.RedirectStandardOutput=Console.IsOutputRedirected;start.RedirectStandardError=Console.IsErrorRedirected;start.RedirectStandardInput=Console.IsInputRedirected;
            start.EnvironmentVariables["HTTP_PROXY"]=plan.ProxyUrl;start.EnvironmentVariables["HTTPS_PROXY"]=plan.ProxyUrl;start.EnvironmentVariables["ALL_PROXY"]=plan.ProxyUrl;
            start.EnvironmentVariables["NO_PROXY"]="localhost,127.0.0.1,::1";
            ConsoleCancelEventHandler cancel=delegate(object sender,ConsoleCancelEventArgs e) { e.Cancel=true; };
            if (console) Console.CancelKeyPress+=cancel;
            try {
                using (var process=Process.Start(start)) {
                    var outputs=new List<Task>();
                    if(start.RedirectStandardOutput) outputs.Add(process.StandardOutput.BaseStream.CopyToAsync(Console.OpenStandardOutput()));
                    if(start.RedirectStandardError) outputs.Add(process.StandardError.BaseStream.CopyToAsync(Console.OpenStandardError()));
                    foreach(var copy in outputs) copy.ContinueWith(delegate(Task failed) { var observed=failed.Exception;try { if(!process.HasExited) process.Kill(); } catch { } },TaskContinuationOptions.OnlyOnFaulted);
                    if(start.RedirectStandardInput) {
                        var input=Console.OpenStandardInput().CopyToAsync(process.StandardInput.BaseStream);
                        input.ContinueWith(delegate(Task completed) { var observed=completed.Exception;try { process.StandardInput.Close(); } catch { } });
                    }
                    process.WaitForExit();
                    foreach(var copy in outputs) { try { copy.GetAwaiter().GetResult(); } catch(IOException) { } }
                    return process.ExitCode;
                }
            }
            finally { if (console) Console.CancelKeyPress-=cancel; }
        }
        private static string[] ReadPrivateArguments(string root,string name,JavaScriptSerializer serializer) {
            Guid id;
            if(!Guid.TryParseExact(name,"N",out id)) throw new ArgumentException("The private argument identifier is invalid.");
            string path=Path.Combine(root,".cli-args-"+id.ToString("N")+".private.json");
            string owner=WindowsIdentity.GetCurrent().User.Value;
            if(!File.Exists(path) || (File.GetAttributes(path)&FileAttributes.ReparsePoint)!=0) throw new InvalidOperationException("The private argument file is missing or unsafe.");
            var allowed=new HashSet<string>(StringComparer.OrdinalIgnoreCase) {owner,"S-1-5-18","S-1-5-32-544"};
            bool ownerAllowed=false;
            var acl=File.GetAccessControl(path,AccessControlSections.Access);
            foreach(FileSystemAccessRule rule in acl.GetAccessRules(true,true,typeof(SecurityIdentifier))) {
                if(rule.AccessControlType!=AccessControlType.Allow) continue;
                string sid=rule.IdentityReference.Value;
                if(!allowed.Contains(sid)) throw new InvalidOperationException("The private argument file grants access to another user.");
                if(sid==owner && (rule.FileSystemRights&FileSystemRights.FullControl)==FileSystemRights.FullControl) ownerAllowed=true;
            }
            if(!ownerAllowed) throw new InvalidOperationException("The private argument file does not belong to this user.");
            try {
                CliArgumentsPayload payload;
                try { payload=serializer.Deserialize<CliArgumentsPayload>(File.ReadAllText(path,Encoding.UTF8)); }
                catch { throw new ArgumentException("The private argument payload is invalid."); }
                if(payload==null || payload.SchemaVersion!=1 || payload.OwnerSid!=owner || payload.Arguments==null) throw new ArgumentException("The private argument payload has an invalid owner or schema.");
                return payload.Arguments;
            } finally { File.Delete(path); }
        }
        public static int Main(string[] arguments) {
            try {
                if (arguments.Length==0 || (arguments[0]!="ClaudeCode" && arguments[0]!="CodexCli")) throw new ArgumentException("Specify ClaudeCode or CodexCli before the application arguments.");
                string scope=arguments[0];var serializer=new JavaScriptSerializer();
                string root=Directory.GetParent(AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar)).FullName;
                string[] forwarded;
                if (arguments.Length==3 && arguments[1]=="--wes-private-arguments") forwarded=ReadPrivateArguments(root,arguments[2],serializer);
                else { forwarded=new string[arguments.Length-1];Array.Copy(arguments,1,forwarded,0,forwarded.Length); }
                if (forwarded==null) throw new ArgumentException("The application argument payload is invalid.");
                var plan=ReadPlan(root,scope,serializer);
                return RunTarget(plan,forwarded);
            } catch (Exception error) {
                // The check contract must return redacted errors, never raw private JSON.
                if (error is InvalidOperationException || error is ArgumentException) Console.Error.WriteLine(error.Message);
                else Console.Error.WriteLine("VPN guarded launch failed. Run verification or repair.");
                return 1;
            }
        }
    }
}
