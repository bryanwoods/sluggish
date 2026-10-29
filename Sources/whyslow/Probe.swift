import AppKit
import Darwin

struct Proc {
    var pid: pid_t
    var ppid: pid_t
    var uid: uid_t
    var path: String
    var args: [String]
    var started: Date
    var footprint: UInt64 = 0
    var resident: UInt64 = 0
    var cpu: Double = 0
    var cwd = ""
    var ports: [UInt16] = []
    var name: String { URL(fileURLWithPath: args.first ?? path).lastPathComponent }
}

struct Container {
    var id, name, status, image: String
    var mem: UInt64
}

struct RunningApp {
    var pid: pid_t
    var name, bundleID, path: String
    var background: Bool
}

struct Snapshot {
    var procs: [pid_t: Proc]
    var containers: [Container] = []
    var apps: [RunningApp] = []
    var diskFree: Int64 = 0
    var diskTotal: Int64 = 0
    var ram: UInt64 = 0
    var swapUsed: UInt64 = 0
    var cpuBusy: Double = 0
    var cores = 0
    var uptime: TimeInterval = 0
    var now = Date()
    var thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    var pressure: Int32 = 1
    var access: [String: Access] = [:]
    var tabs: [String: Tabs] = [:]
}

let dockerBin = executable(["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker"])

func sample(seconds: Double = 2) -> Snapshot {
    let dockerPS = dockerBin.flatMap { start($0, ["ps", "--format", "{{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Image}}"]) }
    let dockerStats = dockerBin.flatMap { start($0, ["stats", "--no-stream", "--format", "{{.ID}}\t{{.MemUsage}}"]) }

    let t0 = mach_absolute_time()
    let cpu0 = cpuTicks()
    var before: [pid_t: UInt64] = [:]
    for pid in allPids() { if let u = usage(pid) { before[pid] = u.ri_user_time + u.ri_system_time } }
    Thread.sleep(forTimeInterval: seconds)
    let elapsed = Double(mach_absolute_time() - t0)
    let cpu1 = cpuTicks()

    var procs: [pid_t: Proc] = [:]
    var argBuf = [UInt8](repeating: 0, count: 1 << 20)
    for pid in allPids() {
        guard let bsd = bsdInfo(pid) else { continue }
        var pathBuf = [CChar](repeating: 0, count: 4096)
        proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
        var p = Proc(pid: pid, ppid: pid_t(bsd.pbi_ppid), uid: bsd.pbi_uid, path: String(cString: pathBuf),
                     args: args(pid, &argBuf), started: Date(timeIntervalSince1970: Double(bsd.pbi_start_tvsec)))
        if let u = usage(pid) {
            p.footprint = u.ri_phys_footprint
            p.resident = u.ri_resident_size
            let ticks = u.ri_user_time + u.ri_system_time
            // ri_*_time and mach_absolute_time share units (mach ticks on Apple silicon), so the ratio needs no timebase.
            if let b = before[pid], ticks >= b { p.cpu = Double(ticks - b) / elapsed }
        }
        var vp = proc_vnodepathinfo()
        if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vp, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 {
            p.cwd = withUnsafeBytes(of: vp.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        }
        if p.uid == getuid() { p.ports = listenPorts(pid) }
        procs[pid] = p
    }

    var s = Snapshot(procs: procs)
    s.containers = containers(ps: finish(dockerPS), stats: finish(dockerStats))
    s.ram = ProcessInfo.processInfo.physicalMemory
    s.cores = ProcessInfo.processInfo.activeProcessorCount
    var boot = timeval()
    var bootSize = MemoryLayout<timeval>.size
    sysctlbyname("kern.boottime", &boot, &bootSize, nil, 0)
    s.uptime = s.now.timeIntervalSince1970 - Double(boot.tv_sec)

    s.cpuBusy = Double(cpu1.busy - cpu0.busy) / Double(max(cpu1.total - cpu0.total, 1))
    let disk = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
    s.diskFree = disk?.volumeAvailableCapacityForImportantUsage ?? 0
    s.diskTotal = Int64(disk?.volumeTotalCapacity ?? 0)
    s.apps = NSWorkspace.shared.runningApplications.compactMap { a in
        guard let id = a.bundleIdentifier, let url = a.bundleURL else { return nil }
        return RunningApp(pid: a.processIdentifier, name: a.localizedName ?? url.deletingPathExtension().lastPathComponent,
                          bundleID: id, path: url.path, background: a.activationPolicy != .regular)
    }
    for id in Set(s.apps.map(\.bundleID)).intersection(scriptableBrowsers) {
        s.access[id] = automation(id, ask: false)
        if s.access[id] == .allowed { s.tabs[id] = readTabs(id) }
    }
    var sw = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    sysctlbyname("vm.swapusage", &sw, &size, nil, 0)
    s.swapUsed = sw.xsu_used
    var level: Int32 = 1
    var levelSize = MemoryLayout<Int32>.size
    sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0)
    s.pressure = level
    return s
}

private func cpuTicks() -> (busy: UInt64, total: UInt64) {
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
    _ = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
    }
    let t = info.cpu_ticks
    let busy = UInt64(t.0) + UInt64(t.1) + UInt64(t.3)
    return (busy, busy + UInt64(t.2))
}

func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
}

private func allPids() -> [pid_t] {
    var buf = [pid_t](repeating: 0, count: 16384)
    let n = proc_listallpids(&buf, Int32(buf.count * MemoryLayout<pid_t>.size))
    return Array(buf.prefix(Int(max(n, 0))))
}

private func usage(_ pid: pid_t) -> rusage_info_v4? {
    var ri = rusage_info_v4()
    let rc = withUnsafeMutablePointer(to: &ri) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    return rc == 0 ? ri : nil
}

private func listenPorts(_ pid: pid_t) -> [UInt16] {
    let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard bytes > 0 else { return [] }
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride)
    let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bytes)
    let ports = fds.prefix(Int(max(got, 0)) / MemoryLayout<proc_fdinfo>.stride).compactMap { fd -> UInt16? in
        guard fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) else { return nil }
        var si = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, size) == size,
              Int(si.psi.soi_kind) == SOCKINFO_TCP,
              si.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN
        else { return nil }
        return UInt16(bigEndian: UInt16(truncatingIfNeeded: si.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport))
    }
    return Array(Set(ports)).sorted()
}

// KERN_PROCARGS2 layout: argc (Int32), exec path, NUL padding, then argv strings.
private func args(_ pid: pid_t, _ buf: inout [UInt8]) -> [String] {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = buf.count
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
    let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
    var i = 4
    while i < size, buf[i] != 0 { i += 1 }
    while i < size, buf[i] == 0 { i += 1 }
    var out: [String] = []
    while out.count < argc, i < size {
        let start = i
        while i < size, buf[i] != 0 { i += 1 }
        out.append(String(decoding: buf[start..<i], as: UTF8.self))
        i += 1
    }
    return out
}

func start(_ exe: String, _ args: [String]) -> (Process, Pipe)? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    return (try? p.run()) != nil ? (p, pipe) : nil
}

@discardableResult
func finish(_ h: (Process, Pipe)?) -> String {
    guard let (p, pipe) = h else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

private func containers(ps: String, stats: String) -> [Container] {
    var mem: [String: UInt64] = [:]
    for line in stats.split(separator: "\n") {
        let f = line.split(separator: "\t")
        if f.count == 2 { mem[String(f[0])] = bytes(String(f[1].split(separator: "/").first ?? "")) }
    }
    return ps.split(separator: "\n").compactMap { line in
        let f = line.split(separator: "\t").map(String.init)
        return f.count == 4 ? Container(id: f[0], name: f[1], status: f[2], image: f[3], mem: mem[f[0]] ?? 0) : nil
    }
}

func bytes(_ s: String) -> UInt64 {
    let s = s.trimmingCharacters(in: .whitespaces)
    for (unit, mult) in [("GiB", 1 << 30), ("MiB", 1 << 20), ("KiB", 1 << 10), ("B", 1)] where s.hasSuffix(unit) {
        return UInt64((Double(s.dropLast(unit.count)) ?? 0) * Double(mult))
    }
    return 0
}
