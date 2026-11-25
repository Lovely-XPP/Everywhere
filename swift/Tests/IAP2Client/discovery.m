// 模拟 IOBluetooth 的返回值，在没有无线设备时验证旧缓存不会掩盖服务查询失败。
#define main bluetooth_bridge_entry
#import "../../Host/IAP2Client/native/bluetooth_bridge.m"
#undef main
#include <assert.h>

@interface DeviceStub : NSObject
@property BOOL connected, paired;
@property IOReturn authStatus;
@property unsigned authenticatedOpens;
@property IOReturn fullStatus;
@property IOReturn filteredStatus;
@property unsigned opens, fullQueries, filteredQueries, reads;
@end
@implementation DeviceStub
- (BOOL)isPaired { return self.paired; }
- (IOReturn)openConnection:(Bridge *)bridge withPageTimeout:(BluetoothHCIPageTimeout)timeout authenticationRequired:(BOOL)auth {
    assert(auth && timeout == kDefaultPageTimeout);
    self.authenticatedOpens++;
    [bridge connectionComplete:nil status:self.authStatus];
    return kIOReturnSuccess;
}
- (BOOL)isConnected { return self.connected; }
- (IOReturn)openConnection:(Bridge *)bridge {
    self.opens++;
    self.connected = YES;
    [bridge connectionComplete:nil status:kIOReturnSuccess];
    return kIOReturnSuccess;
}
- (IOReturn)performSDPQuery:(Bridge *)bridge {
    self.fullQueries++;
    [bridge sdpQueryComplete:nil status:self.fullStatus];
    return kIOReturnSuccess;
}
- (IOReturn)performSDPQuery:(Bridge *)bridge uuids:(NSArray *)uuids {
    self.filteredQueries++;
    [bridge sdpQueryComplete:nil status:self.filteredStatus];
    return kIOReturnSuccess;
}
- (id)getServiceRecordForUUID:(id)uuid { self.reads++; return self; }
- (IOReturn)getRFCOMMChannelID:(BluetoothRFCOMMChannelID *)channel {
    *channel = self.filteredQueries ? 7 : 1;
    return kIOReturnSuccess;
}
@end

// 模拟刚启动的桥：按地址能取得对象，但只有枚举系统列表才载入配对标志。
@interface PairRegistryStub : NSObject
@end
static BOOL pairListRead;
@implementation PairRegistryStub
+ (NSArray *)pairedDevices { pairListRead = YES; return @[[self new]]; }
+ (id)deviceWithAddressString:(NSString *)address { return [address isEqual:@"AA:BB:CC:DD:EE:00"] ? [DeviceStub new] : nil; }
- (NSString *)addressString { return @"aa-bb-cc-dd-ee-ff"; }
- (BOOL)isPaired { return pairListRead; }
@end

int main(void) {
    @autoreleasepool {
        assert(selectedTarget(@"AA:BB:CC:DD:EE:FF", PairRegistryStub.class) != nil);
        assert(!selectedTarget(@"AA:BB:CC:DD:EE:00", PairRegistryStub.class).isPaired);
        assert(selectedTarget(@"AA:BB:CC:DD:EE:00", PairRegistryStub.class) != nil);
        DeviceStub *stub = [DeviceStub new];
        IOBluetoothDevice *device = (IOBluetoothDevice *)(id)stub;
        IOBluetoothSDPUUID *uuid = [IOBluetoothSDPUUID uuid16:0x0100];
        Bridge *bridge = [Bridge new];
        assert(connectBaseband(device, bridge) == kIOReturnSuccess && stub.authenticatedOpens == 1);
        stub.connected = YES;
        stub.authStatus = kIOReturnNotPermitted;
        assert(connectBaseband(device, [Bridge new]) == kIOReturnNotPermitted);
        stub.paired = YES;
        stub.connected = NO;
        assert(connectBaseband(device, bridge) == kIOReturnSuccess && stub.opens == 1);
        assert(connectBaseband(device, bridge) == kIOReturnSuccess && stub.opens == 1);
        BluetoothRFCOMMChannelID channel = 0;
        IOReturn result = kIOReturnSuccess;
        assert(discoverChannel(device, bridge, uuid, &channel, &result));
        assert(stub.fullQueries == 1 && stub.filteredQueries == 0 && channel == 1);
        channel = 0;
        stub.reads = 0;
        stub.fullStatus = stub.filteredStatus = kIOReturnTimeout;
        assert(!discoverChannel(device, bridge, uuid, &channel, &result));
        assert(result == kIOReturnTimeout && stub.reads == 0 && channel == 0);
        stub.filteredStatus = kIOReturnSuccess;
        assert(discoverChannel(device, bridge, uuid, &channel, &result));
        assert(result == kIOReturnSuccess && channel == 7 && stub.reads == 1);
    }
}
