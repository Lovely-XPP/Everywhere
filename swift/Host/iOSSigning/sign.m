// macOS 构建工具：使用 Security.framework 在内存中签署单一 iOS App。
// 参数依次为 DER 叶证书、带签名槽头的 entitlements、App 路径。RSA 私钥从 stdin 接收。
#import <Foundation/Foundation.h>
#import <Security/Security.h>

// macOS 的代码签名 SPI。输入和输出均由系统代码签名实现处理。
extern const CFStringRef kSecCodeSignerIdentity, kSecCodeSignerEntitlements;
extern OSStatus SecCodeSignerCreate(CFDictionaryRef, SecCSFlags, CFTypeRef *);
extern OSStatus SecCodeSignerAddSignatureWithErrors(CFTypeRef, SecStaticCodeRef, SecCSFlags, CFErrorRef *);

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 4) return EXIT_FAILURE;
        NSData *privateDER = [NSFileHandle.fileHandleWithStandardInput readDataToEndOfFile];
        NSDictionary *attributes = @{ (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeRSA,
                                       (__bridge id)kSecAttrKeyClass: (__bridge id)kSecAttrKeyClassPrivate };
        SecKeyRef key = SecKeyCreateWithData((__bridge CFDataRef)privateDER, (__bridge CFDictionaryRef)attributes, NULL);
        NSData *certificateDER = [NSData dataWithContentsOfFile:@(argv[1])];
        SecCertificateRef certificate = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)certificateDER);
        id identity = key && certificate ? CFBridgingRelease(SecIdentityCreate(NULL, certificate, key)) : nil;
        if (!identity) {
            fprintf(stderr, "无法从提供的 RSA 私钥和证书创建签名身份。\n");
            return EXIT_FAILURE;
        }
        NSDictionary *options = @{ (__bridge id)kSecCodeSignerIdentity: identity,
                                   (__bridge id)kSecCodeSignerEntitlements: [NSData dataWithContentsOfFile:@(argv[2])] };
        CFTypeRef signer = NULL;
        SecStaticCodeRef code = NULL;
        CFErrorRef error = NULL;
        OSStatus status = SecCodeSignerCreate((__bridge CFDictionaryRef)options, 0, &signer);
        if (!status) status = SecStaticCodeCreateWithPath((__bridge CFURLRef)[NSURL fileURLWithPath:@(argv[3])], 0, &code);
        if (!status) status = SecCodeSignerAddSignatureWithErrors(signer, code, 0, &error);
        if (status) NSLog(@"iOS 签名失败 (%d) %@", (int)status, (__bridge NSError *)error);
        return status ? EXIT_FAILURE : EXIT_SUCCESS;
    }
}
