// Raw RFCOMM bridge for a user-selected device.
// stdout is binary protocol traffic; diagnostics go to stderr.
#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

@interface Bridge : NSObject <IOBluetoothRFCOMMChannelDelegate>
@property BOOL done;
@property BOOL connectionDone;
@property IOReturn connectionStatus;
@property BOOL sdpDone;
@property IOReturn sdpStatus;
@property BOOL openDone;
@property IOReturn openStatus;
@end

@implementation Bridge
- (void)connectionComplete:(IOBluetoothDevice *)device status:(IOReturn)status {
    self.connectionStatus = status;
    self.connectionDone = YES;
}
- (void)sdpQueryComplete:(IOBluetoothDevice *)device status:(IOReturn)status {
    self.sdpStatus = status;
    self.sdpDone = YES;
}
- (void)rfcommChannelOpenComplete:(IOBluetoothRFCOMMChannel *)channel status:(IOReturn)status {
    self.openStatus = status;
    self.openDone = YES;
}
- (void)rfcommChannelData:(IOBluetoothRFCOMMChannel *)channel data:(void *)data length:(size_t)length {
    size_t offset = 0;
    while (offset < length) {
        ssize_t count = write(STDOUT_FILENO, (char *)data + offset, length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { self.done = YES; return; }
        offset += count;
    }
}
- (void)rfcommChannelClosed:(IOBluetoothRFCOMMChannel *)channel {
    fprintf(stderr, "RFCOMM channel closed\n");
    self.done = YES;
}
@end

static void tick(void) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}

// 已有物理链路可能被其他系统服务共用。此处只建立或复用，不主动断开它。
static IOReturn connectBaseband(IOBluetoothDevice *device, Bridge *bridge) {
    BOOL needsPairing = !device.isPaired;
    if (!needsPairing && device.isConnected) return kIOReturnSuccess;
    IOReturn result = needsPairing
        ? [device openConnection:bridge withPageTimeout:kDefaultPageTimeout authenticationRequired:YES]
        : [device openConnection:bridge];
    if (result == kIOReturnSuccess) {
        NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + (needsPairing ? 60 : 15);
        while (!bridge.connectionDone && NSProcessInfo.processInfo.systemUptime < deadline) {
            if (!needsPairing && device.isConnected) break;
            tick();
        }
        result = bridge.connectionDone ? bridge.connectionStatus : kIOReturnTimeout;
    }
    // 用户拒绝认证时，即使物理链路仍然连接也必须保留系统错误。
    if (needsPairing) return result;
    return device.isConnected ? kIOReturnSuccess : result;
}

// 等待本轮 SDP 完成；查询尚在进行时禁止启动第二个查询。
static IOReturn queryServices(IOBluetoothDevice *device, Bridge *bridge, NSArray *filter, BOOL *pending) {
    bridge.sdpDone = NO;
    IOReturn result = filter ? [device performSDPQuery:bridge uuids:filter] : [device performSDPQuery:bridge];
    *pending = NO;
    if (result != kIOReturnSuccess) return result;
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 14;
    while (!bridge.sdpDone && NSProcessInfo.processInfo.systemUptime < deadline) tick();
    *pending = !bridge.sdpDone;
    return bridge.sdpDone ? bridge.sdpStatus : kIOReturnTimeout;
}

static BOOL readChannel(IOBluetoothDevice *device, IOBluetoothSDPUUID *uuid, BluetoothRFCOMMChannelID *channelID) {
    IOBluetoothSDPServiceRecord *record = [device getServiceRecordForUUID:uuid];
    return record && [record getRFCOMMChannelID:channelID] == kIOReturnSuccess && *channelID >= 1 && *channelID <= 30;
}

// 只有成功完成的查询才允许取其服务记录。两种查询均失败时保留 SDP 错误。
static BOOL discoverChannel(IOBluetoothDevice *device, Bridge *bridge, IOBluetoothSDPUUID *uuid,
                            BluetoothRFCOMMChannelID *channelID, IOReturn *status) {
    BOOL pending = NO;
    *status = queryServices(device, bridge, nil, &pending);
    if (*status == kIOReturnSuccess && readChannel(device, uuid, channelID)) return YES;
    if (pending) return NO;
    *status = queryServices(device, bridge, @[uuid], &pending);
    return *status == kIOReturnSuccess && readChannel(device, uuid, channelID);
}

// 桥是新启动的进程。先枚举系统记录，再检查同一地址对象的经典蓝牙配对标志。
static IOBluetoothDevice *selectedTarget(NSString *address, Class deviceClass) {
    for (IOBluetoothDevice *candidate in [deviceClass pairedDevices]) {
        NSString *canonical = [candidate.addressString stringByReplacingOccurrencesOfString:@"-" withString:@":"];
        if ([canonical.uppercaseString isEqualToString:address] && candidate.isPaired) return candidate;
    }
    IOBluetoothDevice *device = [deviceClass deviceWithAddressString:address];
    return device;
}

// The inquiry runs only after the user explicitly asks for nearby classic devices.
@interface Inquiry : NSObject <IOBluetoothDeviceInquiryDelegate>
@property BOOL done;
@property IOReturn status;
@end
@implementation Inquiry
- (void)deviceInquiryComplete:(IOBluetoothDeviceInquiry *)sender error:(IOReturn)error aborted:(BOOL)aborted {
    self.status = error; self.done = YES;
}
@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--controller") == 0) {
            NSString *address = [[IOBluetoothHostController defaultController] addressAsString];
            if (!address) { fprintf(stderr, "Bluetooth controller unavailable\n"); return 2; }
            puts(address.UTF8String);
            return 0;
        }
        if (argc == 2 && (!strcmp(argv[1], "--list") || !strcmp(argv[1], "--discover"))) {
            NSArray *devices;
            if (!strcmp(argv[1], "--discover")) {
                Inquiry *delegate = [Inquiry new];
                IOBluetoothDeviceInquiry *inquiry = [IOBluetoothDeviceInquiry inquiryWithDelegate:delegate];
                inquiry.inquiryLength = 8;
                if (!inquiry || [inquiry start] != kIOReturnSuccess) return 3;
                NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:18];
                while (!delegate.done && limit.timeIntervalSinceNow > 0)
                    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
                if (!delegate.done) { [inquiry stop]; return 3; }
                if (delegate.status != kIOReturnSuccess) return 3;
                devices = inquiry.foundDevices;
            } else {
                devices = [IOBluetoothDevice pairedDevices];
            }
            NSMutableArray *result = [NSMutableArray array];
            for (IOBluetoothDevice *device in devices) {
                [result addObject:@{@"name": device.name ?: @"", @"address": device.addressString ?: @""}];
            }
            NSData *json = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
            fwrite(json.bytes, 1, json.length, stdout);
            putchar('\n');
            return 0;
        }
        BOOL liveOnly = argc == 3 && strcmp(argv[1], "--live") == 0;
        if (argc != 2 && !liveOnly) { fprintf(stderr, "usage: bluetooth-bridge [--live] DEVICE-MAC | --list\n"); return 2; }
        NSString *address = [[@(argv[liveOnly ? 2 : 1]) stringByReplacingOccurrencesOfString:@"-" withString:@":"] uppercaseString];
        IOBluetoothDevice *device = selectedTarget(address, IOBluetoothDevice.class);
        if (!device) {
            fprintf(stderr, "Bluetooth target unavailable\n");
            return 8;
        }
        Bridge *bridge = [Bridge new];
        // Apple's accessory-to-phone iAP2 service; obtain its current channel via SDP.
        const uint8_t uuidBytes[16] = {0,0,0,0,0xde,0xca,0xfa,0xde,0xde,0xca,0xde,0xaf,0xde,0xca,0xca,0xfe};
        IOBluetoothSDPUUID *uuid = [IOBluetoothSDPUUID uuidWithBytes:uuidBytes length:16];
        fprintf(stderr, "EW_PHASE baseband\n");
        IOReturn status = connectBaseband(device, bridge);
        if (status != kIOReturnSuccess) {
            fprintf(stderr, "EW_BASEBAND_ERROR status=0x%08x\n", (unsigned)status);
            return 7;
        }
        BluetoothRFCOMMChannelID channelID = 0;
        // 只复用所选配对设备和目标服务 UUID 的记录。客户端会验证检测应答，再开始会话。
        BOOL cached = !liveOnly && readChannel(device, uuid, &channelID);
        BOOL found = cached;
        if (!cached) {
            fprintf(stderr, "EW_PHASE discovery\n");
            found = discoverChannel(device, bridge, uuid, &channelID, &status);
        }
        if (status != kIOReturnSuccess) {
            fprintf(stderr, "EW_SDP_ERROR status=0x%08x\n", (unsigned)status);
            return 3;
        }
        if (!found) {
            fprintf(stderr, "Selected device does not advertise the iAP2 RFCOMM service\n");
            return 6;
        }
        fprintf(stderr, "EW_PHASE open\n");
        IOBluetoothRFCOMMChannel *channel = nil;
        status = [device openRFCOMMChannelAsync:&channel withChannelID:channelID delegate:bridge];
        if (status == kIOReturnSuccess) {
            NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 12;
            while (!bridge.openDone && !bridge.done && !channel.isOpen && NSProcessInfo.processInfo.systemUptime < deadline) tick();
            status = bridge.openDone ? bridge.openStatus : (bridge.done ? kIOReturnNotOpen : (channel.isOpen ? kIOReturnSuccess : kIOReturnTimeout));
            if (status == kIOReturnSuccess && (!channel || bridge.done)) status = kIOReturnNotOpen;
        }
        if (status != kIOReturnSuccess) {
            const char *reason = status == kIOReturnBusy || status == kIOReturnExclusiveAccess ? "busy" :
                status == kIOReturnNotPermitted ? "permission" : status == kIOReturnTimeout ? "timeout" : "other";
            fprintf(stderr, "EW_OPEN_ERROR channel=%u status=0x%08x record=%s cause=%s\n",
                    channelID, (unsigned)status, cached ? "cache" : "live", reason);
            [channel closeChannel];
            return 4;
        }
        // stderr 专用于启动确认与诊断；stdout 仍是 RFCOMM 二进制数据。
        fprintf(stderr, "%s\n", cached ? "EW_OPEN_READY cache" : "EW_OPEN_READY");
        fflush(stderr);
        int flags = fcntl(STDIN_FILENO, F_GETFL, 0);
        fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK);
        uint8_t input[4096];
        int result = 0;
        while (!bridge.done) {
            tick();
            ssize_t size = read(STDIN_FILENO, input, sizeof(input));
            if (size == 0) break;
            if (size < 0) {
                if (errno == EAGAIN || errno == EINTR) continue;
                result = 5; break;
            }
            size_t mtu = MAX(1, channel.getMTU);
            for (size_t offset = 0; offset < size; offset += mtu) {
                UInt16 count = (UInt16)MIN(mtu, size - offset);
                if ([channel writeSync:input + offset length:count] != kIOReturnSuccess) {
                    result = 5; bridge.done = YES; break;
                }
            }
        }
        fcntl(STDIN_FILENO, F_SETFL, flags);
        [channel closeChannel];
        return result;
    }
}
