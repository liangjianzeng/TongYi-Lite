// Enumerate OpenCL platforms/devices via ICD loader (uses .NET Framework csc, C# 5 safe).
using System;
using System.Runtime.InteropServices;
using System.Text;

class ClEnum
{
    [DllImport("OpenCL.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern int clGetPlatformIDs(uint num_entries, IntPtr platforms, out uint num_platforms);

    [DllImport("OpenCL.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern int clGetPlatformInfo(IntPtr platform, int pname, uint size, IntPtr value, out uint size_out);

    [DllImport("OpenCL.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern int clGetDeviceIDs(IntPtr platform, int device_type, uint num_entries, IntPtr devices, out uint num_devices);

    [DllImport("OpenCL.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern int clGetDeviceInfo(IntPtr device, int pname, uint size, IntPtr value, out uint size_out);

    const int CL_PLATFORM_NAME = 0x0902;
    const int CL_PLATFORM_VERSION = 0x0911;
    const int CL_DEVICE_NAME = 0x102B;
    const int CL_DEVICE_TYPE = 0x1000;
    const int CL_DEVICE_VERSION = 0x102F;
    const int CL_DEVICE_GLOBAL_MEM_SIZE = 0x101F;
    const int CL_DEVICE_LOCAL_MEM_SIZE = 0x1023;
    const int CL_DEVICE_MAX_COMPUTE_UNITS = 0x1002;
    const int CL_DEVICE_SUB_GROUP_SIZES_INTEL = 0x4108;
    const int CL_DEVICE_TYPE_ALL = unchecked((int)0xFFFFFFFF);

    static string PlatStr(IntPtr obj, int name)
    {
        uint sz;
        if (clGetPlatformInfo(obj, name, 0, IntPtr.Zero, out sz) != 0 || sz == 0) return "<err>";
        IntPtr buf = Marshal.AllocHGlobal((int)sz);
        clGetPlatformInfo(obj, name, sz, buf, out sz);
        string s = Marshal.PtrToStringAnsi(buf);
        Marshal.FreeHGlobal(buf);
        return s;
    }

    static string DevStr(IntPtr obj, int name)
    {
        uint sz;
        if (clGetDeviceInfo(obj, name, 0, IntPtr.Zero, out sz) != 0 || sz == 0) return "<err>";
        IntPtr buf = Marshal.AllocHGlobal((int)sz);
        clGetDeviceInfo(obj, name, sz, buf, out sz);
        string s = Marshal.PtrToStringAnsi(buf);
        Marshal.FreeHGlobal(buf);
        return s;
    }

    static ulong GetU64(IntPtr obj, int name)
    {
        ulong v = 0; uint sz;
        IntPtr p = Marshal.AllocHGlobal(8);
        if (clGetDeviceInfo(obj, name, 8, p, out sz) == 0) v = (ulong)Marshal.ReadInt64(p);
        Marshal.FreeHGlobal(p);
        return v;
    }

    static uint GetU32(IntPtr obj, int name)
    {
        uint v = 0; uint sz;
        IntPtr p = Marshal.AllocHGlobal(4);
        if (clGetDeviceInfo(obj, name, 4, p, out sz) == 0) v = (uint)Marshal.ReadInt32(p);
        Marshal.FreeHGlobal(p);
        return v;
    }

    static void Main()
    {
        uint np;
        int err = clGetPlatformIDs(0, IntPtr.Zero, out np);
        Console.WriteLine("clGetPlatformIDs err=" + err + " platforms=" + np);
        if (err != 0 || np == 0) return;
        IntPtr[] plats = new IntPtr[np];
        GCHandle h = GCHandle.Alloc(plats, GCHandleType.Pinned);
        clGetPlatformIDs(np, h.AddrOfPinnedObject(), out np);
        for (int i = 0; i < np; i++)
        {
            Console.WriteLine("[Platform " + i + "] " + PlatStr(plats[i], CL_PLATFORM_NAME));
            Console.WriteLine("  version: " + PlatStr(plats[i], CL_PLATFORM_VERSION));
            uint nd;
            err = clGetDeviceIDs(plats[i], CL_DEVICE_TYPE_ALL, 0, IntPtr.Zero, out nd);
            Console.WriteLine("  devices err=" + err + " count=" + nd);
            if (err != 0 || nd == 0) continue;
            IntPtr[] devs = new IntPtr[nd];
            GCHandle dh = GCHandle.Alloc(devs, GCHandleType.Pinned);
            clGetDeviceIDs(plats[i], CL_DEVICE_TYPE_ALL, nd, dh.AddrOfPinnedObject(), out nd);
            for (int j = 0; j < nd; j++)
            {
                uint dtype = GetU32(devs[j], CL_DEVICE_TYPE);
                Console.WriteLine("  [Dev " + j + "] " + DevStr(devs[j], CL_DEVICE_NAME)
                    + "  type=0x" + dtype.ToString("X")
                    + "  CUs=" + GetU32(devs[j], CL_DEVICE_MAX_COMPUTE_UNITS)
                    + "  globalMem=" + (GetU64(devs[j], CL_DEVICE_GLOBAL_MEM_SIZE) / (1024UL * 1024UL)) + "MB"
                    + "  localMem=" + (GetU64(devs[j], CL_DEVICE_LOCAL_MEM_SIZE) / 1024UL) + "KB");
                Console.WriteLine("    version: " + DevStr(devs[j], CL_DEVICE_VERSION));
                uint sz;
                if (clGetDeviceInfo(devs[j], CL_DEVICE_SUB_GROUP_SIZES_INTEL, 0, IntPtr.Zero, out sz) == 0 && sz > 0 && sz <= 64)
                {
                    IntPtr p = Marshal.AllocHGlobal((int)sz);
                    clGetDeviceInfo(devs[j], CL_DEVICE_SUB_GROUP_SIZES_INTEL, sz, p, out sz);
                    StringBuilder sb = new StringBuilder();
                    for (int k = 0; k < (int)sz / 4; k++) sb.Append(Marshal.ReadInt32(p, k * 4) + " ");
                    Console.WriteLine("    Intel sub-group sizes: " + sb);
                    Marshal.FreeHGlobal(p);
                }
            }
            dh.Free();
        }
        h.Free();
    }
}
