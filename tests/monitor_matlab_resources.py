"""Read-only low-rate Windows process sampling for a diagnostic MATLAB run."""
import argparse
import csv
import ctypes as c
from ctypes import wintypes as w
import time


class Memory(c.Structure):
    _fields_ = [("cb", w.DWORD), ("PageFaultCount", w.DWORD)] + [(k, c.c_size_t) for k in [
        "PeakWorkingSetSize", "WorkingSetSize", "QuotaPeakPagedPoolUsage", "QuotaPagedPoolUsage",
        "QuotaPeakNonPagedPoolUsage", "QuotaNonPagedPoolUsage", "PagefileUsage", "PeakPagefileUsage", "PrivateUsage"]]


class IO(c.Structure):
    _fields_ = [(k, c.c_ulonglong) for k in ["ReadOperationCount", "WriteOperationCount", "OtherOperationCount", "ReadTransferCount", "WriteTransferCount", "OtherTransferCount"]]


class Global(c.Structure):
    _fields_ = [("dwLength", w.DWORD), ("dwMemoryLoad", w.DWORD)] + [(k, c.c_ulonglong) for k in [
        "ullTotalPhys", "ullAvailPhys", "ullTotalPageFile", "ullAvailPageFile", "ullTotalVirtual", "ullAvailVirtual", "ullAvailExtendedVirtual"]]


def run(pid, path):
    kernel = c.WinDLL("kernel32", use_last_error=True)
    psapi = c.WinDLL("psapi", use_last_error=True)
    kernel.OpenProcess.argtypes = [w.DWORD, w.BOOL, w.DWORD]
    kernel.OpenProcess.restype = w.HANDLE
    kernel.GetProcessTimes.argtypes = [w.HANDLE] + [c.POINTER(c.c_ulonglong)] * 4
    kernel.GetProcessIoCounters.argtypes = [w.HANDLE, c.POINTER(IO)]
    kernel.GlobalMemoryStatusEx.argtypes = [c.POINTER(Global)]
    kernel.CloseHandle.argtypes = [w.HANDLE]
    psapi.GetProcessMemoryInfo.argtypes = [w.HANDLE, c.POINTER(Memory), w.DWORD]
    handle = kernel.OpenProcess(0x1010, False, pid)
    if not handle:
        raise c.WinError(c.get_last_error())
    try:
        with open(path, "w", encoding="utf-8", newline="") as output:
            writer = csv.writer(output)
            writer.writerow(["qpc_seconds", "epoch_seconds", "process_cpu_seconds", "page_fault_count", "working_set_bytes", "private_bytes", "read_bytes", "write_bytes", "available_physical_bytes"])
            end = time.monotonic() + 780
            while time.monotonic() < end:
                created, exited, system, user = [c.c_ulonglong() for _ in range(4)]
                if not kernel.GetProcessTimes(handle, c.byref(created), c.byref(exited), c.byref(system), c.byref(user)) or exited.value:
                    break
                memory, io, status = Memory(), IO(), Global()
                memory.cb = c.sizeof(memory)
                status.dwLength = c.sizeof(status)
                if not psapi.GetProcessMemoryInfo(handle, c.byref(memory), memory.cb):
                    raise c.WinError(c.get_last_error())
                kernel.GetProcessIoCounters(handle, c.byref(io))
                kernel.GlobalMemoryStatusEx(c.byref(status))
                writer.writerow([time.perf_counter(), time.time(), (system.value + user.value) / 1e7, memory.PageFaultCount, memory.WorkingSetSize, memory.PrivateUsage, io.ReadTransferCount, io.WriteTransferCount, status.ullAvailPhys])
                output.flush()
                time.sleep(0.5)
    finally:
        kernel.CloseHandle(handle)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pid", type=int)
    parser.add_argument("output")
    args = parser.parse_args()
    run(args.pid, args.output)
