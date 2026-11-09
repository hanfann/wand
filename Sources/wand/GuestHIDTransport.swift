import CryptoKit
import Foundation
import Darwin

/// Xcode 27 watch touches use the guest's digitizer service. A single warm
/// process dispatches digitizer events through the guest's IOKit event system.
/// No UI focus, host mouse events, app changes, or simulator resets are involved.
final class GuestHIDTransport {
    private var process = Process()
    private var input: FileHandle!
    private var output: FileHandle!
    private let udid: String
    private let helperPath: String
    private var broken = false
    private var lastPacket: Data?

    private static let source = #"""
    #import <Foundation/Foundation.h>
    #import <dlfcn.h>
    #import <mach/mach_time.h>
    typedef CFTypeRef Event;
    static int read_exact(void *p, size_t n) {
        size_t done = 0;
        while (done < n) { ssize_t count = read(0, (char *)p + done, n - done);
            if (count <= 0) return 0; done += count; }
        return 1;
    }
    static void reply(uint32_t status) { write(1, &status, 4); }
    int main(void) { @autoreleasepool {
        void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        Event (*client)(CFAllocatorRef) = dlsym(h, "IOHIDEventSystemClientCreate");
        CFArrayRef (*list)(Event) = dlsym(h, "IOHIDEventSystemClientCopyServices");
        Event (*property)(Event, CFStringRef) = dlsym(h, "IOHIDServiceClientCopyProperty");
        Event (*registry)(Event) = dlsym(h, "IOHIDServiceClientGetRegistryID");
        Event (*hand)(CFAllocatorRef,uint64_t,uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,double,double,double,double,double,Boolean,Boolean,uint32_t) = dlsym(h,"IOHIDEventCreateDigitizerEvent");
        Event (*finger)(CFAllocatorRef,uint64_t,uint32_t,uint32_t,uint32_t,double,double,double,double,double,Boolean,Boolean,uint32_t) = dlsym(h,"IOHIDEventCreateDigitizerFingerEvent");
        void (*set)(Event,uint32_t,int64_t) = dlsym(h,"IOHIDEventSetIntegerValue");
        void (*sender)(Event,uint64_t) = dlsym(h,"IOHIDEventSetSenderID");
        void (*append)(Event,Event,uint32_t) = dlsym(h,"IOHIDEventAppendEvent");
        void (*dispatch)(Event,Event) = dlsym(h,"IOHIDEventSystemClientDispatchEvent");
        if (!client || !list || !property || !registry || !hand || !finger || !set || !sender || !append || !dispatch) { reply(1); return 1; }
        Event c = client(NULL);
        CFArrayRef services = list(c);
        uint64_t senderID = 0;
        int bestPriority = -1;
        for (id service in (__bridge NSArray *)services) {
            Event page = property((__bridge Event)service, CFSTR("PrimaryUsagePage"));
            Event usage = property((__bridge Event)service, CFSTR("PrimaryUsage"));
            if (page && usage && CFEqual(page, (__bridge Event)@13) && CFEqual(usage, (__bridge Event)@4)) {
                Event builtIn = property((__bridge Event)service, CFSTR("Built-In"));
                int priority = [(__bridge NSNumber *)builtIn boolValue] ? 1 : 0;
                if (priority > bestPriority) {
                    senderID = [(__bridge NSNumber *)registry((__bridge Event)service) unsignedLongLongValue];
                    bestPriority = priority;
                }
                if (builtIn) CFRelease(builtIn);
            }
            if (page) CFRelease(page); if (usage) CFRelease(usage);
        }
        if (services) CFRelease(services);
        if (!senderID) { reply(2); return 2; }
        reply(0);
        CFRunLoopRef loop = CFRunLoopGetCurrent();
        // Keep the HID client's run loop alive while a background queue reads
        // stdin. Blocking the HID thread can delay dispatch until a later input.
        void (*schedule)(Event, CFRunLoopRef, CFStringRef) = dlsym(h, "IOHIDEventSystemClientScheduleWithRunLoop");
        if (!schedule) return 5;
        schedule(c, loop, kCFRunLoopDefaultMode);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        uint32_t length;
        while (read_exact(&length, 4)) { @autoreleasepool {
            unsigned char bytes[40];
            if ((length != 24 && length != 40) || !read_exact(bytes, length)) { reply(3); break; }
            uint32_t phase, count;
            memcpy(&phase, bytes, 4); memcpy(&count, bytes + 4, 4);
            if ((count != 1 && count != 2) || length != 8 + count * 16 || (phase != 1 && phase != 2 && phase != 6)) { reply(4); break; }
            double coordinates[4] = {0}; memcpy(coordinates, bytes + 8, count * 16);
            CGPoint point0 = {coordinates[0], coordinates[1]};
            CGPoint point1 = {coordinates[2], coordinates[3]};
            dispatch_semaphore_t sent = dispatch_semaphore_create(0);
            CFRunLoopPerformBlock(loop, kCFRunLoopDefaultMode, ^{
            double points[] = {point0.x, point0.y, point1.x, point1.y};
            bool down = phase != 2;
            uint32_t mask = phase == 6 ? 4 : 3;
            uint64_t now = mach_absolute_time();
            double x = count == 2 ? (points[0] + points[2]) / 2 : points[0];
            double y = count == 2 ? (points[1] + points[3]) / 2 : points[1];
            Event event = hand(NULL, now, 3, 0, 0, mask, 0, x, y, 0, 0, 0, down, down, 0);
            set(event, 0xb0019, 1); // kIOHIDEventFieldDigitizerIsDisplayIntegrated
            sender(event, senderID);
            for (uint32_t i = 0; i < count; i++) {
                Event child = finger(NULL, now, i + 1, i + 1, mask, points[i * 2], points[i * 2 + 1], 0, down ? 1 : 0, 0, down, down, 0);
                append(event, child, 0); CFRelease(child);
            }
            dispatch(c, event); CFRelease(event);
            reply(0);
            dispatch_semaphore_signal(sent);
            });
            CFRunLoopWakeUp(loop);
            dispatch_semaphore_wait(sent, DISPATCH_TIME_FOREVER);
        }}
        CFRunLoopStop(loop);
        CFRunLoopWakeUp(loop);
        });
        CFRunLoopRun();
        CFRelease(c);
        return 0;
    }}
    """#

    private static func run(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.terminationStatus == 0 else { throw failure(text) }
        return text
    }

    static func isNeeded(udid: String) throws -> Bool {
        let version = try run(["simctl", "getenv", udid, "SIMULATOR_RUNTIME_VERSION"])
        guard let major = Int(version.split(separator: ".").first ?? "") else {
            throw failure("cannot determine watchOS runtime version: \(version)")
        }
        return major >= 27
    }

    init(udid: String) throws {
        self.udid = udid
        let sdk = try Self.run(["--sdk", "watchsimulator", "--show-sdk-build-version"])
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        let digest = SHA256.hash(data: Data((sdk + arch + Self.source).utf8))
            .map { String(format: "%02x", $0) }.joined()
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".wand/hid/\(digest)")
        let helper = dir.appendingPathComponent("guest-hid")
        if !FileManager.default.isExecutableFile(atPath: helper.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let sourceURL = dir.appendingPathComponent("guest-hid.m")
            try Data(Self.source.utf8).write(to: sourceURL, options: .atomic)
            // A unique output avoids two daemons observing a half-built helper.
            let temporary = dir.appendingPathComponent("guest-hid-\(UUID().uuidString)")
            _ = try Self.run(["--sdk", "watchsimulator", "clang", "-target", "\(arch)-apple-watchos11.0-simulator",
                              "-fobjc-arc", "-framework", "Foundation", sourceURL.path, "-o", temporary.path])
            guard rename(temporary.path, helper.path) == 0 else {
                throw Self.failure("cannot cache helper: \(String(cString: strerror(errno)))")
            }
        }
        self.helperPath = helper.path
        try start()
    }

    private func start() throws {
        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "spawn", udid, helperPath]
        let incoming = Pipe(), outgoing = Pipe()
        input = incoming.fileHandleForWriting
        output = outgoing.fileHandleForReading
        process.standardInput = incoming
        process.standardOutput = outgoing
        process.standardError = FileHandle.standardError
        try process.run()
        try receiveStatus()
    }

    private func close() {
        try? input?.close()
        try? output?.close()
        if process.isRunning { process.terminate() }
    }

    deinit { close() }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "com.wand.guest-hid", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Guest HID: \(message)"])
    }

    private func receiveStatus() throws {
        var data = Data()
        while data.count < 4 {
            var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 5000) > 0,
                  let part = try output.read(upToCount: 4 - data.count), !part.isEmpty else {
                throw Self.failure("bridge stopped or acknowledgement timed out")
            }
            data.append(part)
        }
        let status = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard status == 0 else { throw Self.failure("digitizer dispatch failed (0x\(String(status, radix: 16)))") }
    }

    private func transmit(_ packet: Data) throws {
        guard process.isRunning else { throw Self.failure("bridge exited") }
        var length = UInt32(packet.count)
        var frame = Data(bytes: &length, count: 4)
        frame.append(packet)
        try input.write(contentsOf: frame)
        try receiveStatus()
    }

    func send(_ packet: Data) -> String? {
        do {
            if broken || !process.isRunning {
                close()
                try start()
                // Release the previous contact before beginning another gesture.
                // Never replay an ambiguously acknowledged tap: that can double-act.
                if var release = lastPacket {
                    release.replaceSubrange(0..<4, with: [2, 0, 0, 0])
                    try transmit(release)
                }
                broken = false
            }
            lastPacket = packet
            try transmit(packet)
            if getenv("WAND_HID_DEBUG") != nil {
                FileHandle.standardError.write(Data("[WAND_HID] guest touch bytes=\(packet.count) acknowledged\n".utf8))
            }
            return nil
        } catch {
            broken = true
            close()
            return error.localizedDescription
        }
    }
}
