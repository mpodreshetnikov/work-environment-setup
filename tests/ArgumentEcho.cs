using System;
using System.Text;
using System.IO;
using System.Web.Script.Serialization;
public static class WesArgumentEcho {
    public static int Main(string[] args) {
        string input=null;
        if(Array.IndexOf(args,"--fixture-stdin")>=0) using(var reader=new StreamReader(Console.OpenStandardInput(),Encoding.UTF8)) input=reader.ReadToEnd();
        var data=new {Arguments=args,Proxy=Environment.GetEnvironmentVariable("HTTPS_PROXY"),Input=input};
        Console.WriteLine(Convert.ToBase64String(Encoding.UTF8.GetBytes(new JavaScriptSerializer().Serialize(data))));
        return 17;
    }
}
