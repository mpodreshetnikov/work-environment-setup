using System;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
namespace WorkEnvironmentSetup.Tests {
    public sealed class HttpFixture : IDisposable {
        private readonly TcpListener listener;
        public int Port { get; private set; }
        public HttpFixture() {
            listener=new TcpListener(IPAddress.Loopback,0);listener.Start();Port=((IPEndPoint)listener.LocalEndpoint).Port;
            ThreadPool.QueueUserWorkItem(delegate(object ignored) {
                try {while(true) {using(var client=listener.AcceptTcpClient()) {
                    var stream=client.GetStream();stream.ReadTimeout=2000;var request=new byte[4096];stream.Read(request,0,request.Length);
                    byte[] response=Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK");stream.Write(response,0,response.Length);
                }}} catch(SocketException) { } catch(ObjectDisposedException) { } catch(System.IO.IOException) { }
            });
        }
        public void Dispose() { listener.Stop(); }
    }
}
