// Binary RFCOMM bridge used by the existing accessory-location client.
// --controller returns the radio address; --list lists authenticated classic devices.
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2bth.h>
#include <windows.h>
#include <bluetoothapis.h>
#include <io.h>
#include <fcntl.h>
#include <cstdio>
#include <cstring>
#include <string>
#include <iostream>
#include <thread>
#include <vector>

static std::string address(ULONGLONG n) {
    char out[18];
    sprintf_s(out,"%02X:%02X:%02X:%02X:%02X:%02X",int(n>>40)&255,int(n>>32)&255,
              int(n>>24)&255,int(n>>16)&255,int(n>>8)&255,int(n)&255);
    return out;
}
static std::string name(const wchar_t* w) {
    int n = WideCharToMultiByte(CP_UTF8,0,w,-1,nullptr,0,nullptr,nullptr);
    std::string result(n,'\0');
    if(n) WideCharToMultiByte(CP_UTF8,0,w,-1,result.data(),n,nullptr,nullptr);
    if(n) result.pop_back();
    for(auto& ch:result) if(static_cast<unsigned char>(ch)<32) ch=' ';
    return result;
}
// 重试时实时查询所选设备的 iAP2 服务。成功写入通道 1–30 并返回 0，失败返回 Winsock 错误码。
static int discoverChannel(SOCKADDR_BTH &remote, GUID &service) {
    wchar_t context[64]{};
    DWORD chars = sizeof(context) / sizeof(context[0]);
    if (WSAAddressToStringW(reinterpret_cast<sockaddr*>(&remote), sizeof(remote),
                            nullptr, context, &chars) == SOCKET_ERROR) return WSAGetLastError();
    WSAQUERYSETW query{};
    query.dwSize = sizeof(query);
    query.dwNameSpace = NS_BTH;
    query.lpServiceClassId = &service;
    query.lpszContext = context;
    HANDLE lookup{};
    if (WSALookupServiceBeginW(&query, LUP_FLUSHCACHE | LUP_RETURN_ADDR, &lookup) == SOCKET_ERROR)
        return WSAGetLastError();
    int error = WSASERVICE_NOT_FOUND;
    std::vector<BYTE> buffer(2048);
    while (!remote.port) {
        DWORD size = static_cast<DWORD>(buffer.size());
        auto result = reinterpret_cast<WSAQUERYSETW*>(buffer.data());
        result->dwSize = sizeof(*result);
        if (WSALookupServiceNextW(lookup, LUP_RETURN_ADDR, &size, result) == SOCKET_ERROR) {
            error = WSAGetLastError();
            if (error == WSAEFAULT && size > buffer.size()) {
                buffer.resize(size);
                continue;
            }
            if (error == WSA_E_NO_MORE || error == WSAENOMORE) error = WSASERVICE_NOT_FOUND;
            break;
        }
        for (DWORD i = 0; i < result->dwNumberOfCsAddrs && !remote.port; ++i) {
            const auto &entry = result->lpcsaBuffer[i];
            for (const auto &endpoint : {entry.RemoteAddr, entry.LocalAddr}) {
                if (!endpoint.lpSockaddr || endpoint.iSockaddrLength < int(sizeof(SOCKADDR_BTH))) continue;
                auto addr = reinterpret_cast<const SOCKADDR_BTH*>(endpoint.lpSockaddr);
                if (addr->addressFamily == AF_BTH && addr->btAddr == remote.btAddr &&
                    addr->port >= 1 && addr->port <= 30) {
                    remote.port = addr->port;
                    break;
                }
            }
        }
    }
    WSALookupServiceEnd(lookup);
    return remote.port ? 0 : error;
}
int main(int argc,char** argv) {
    if(argc<2) return 1;
    if(strcmp(argv[1],"--self-test")==0){
        WSADATA version{};
        if(WSAStartup(MAKEWORD(2,2),&version)) return 3;
        WSACleanup();
        return address(0x010203040506ULL)=="01:02:03:04:05:06" ? 0 : 1;
    }
    bool list=strcmp(argv[1],"--list")==0, controller=strcmp(argv[1],"--controller")==0;
    bool discover = strcmp(argv[1], "--discover") == 0;
    BLUETOOTH_FIND_RADIO_PARAMS params{sizeof(params)};
    HANDLE radio=nullptr;
    auto find=BluetoothFindFirstRadio(&params,&radio);
    if(!find) return 3;
    BluetoothFindRadioClose(find);
    BLUETOOTH_RADIO_INFO ri{sizeof(ri)};
    if(BluetoothGetRadioInfo(radio,&ri)!=ERROR_SUCCESS) return 3;
    if(controller) {std::cout<<address(ri.address.ullLong)<<std::endl;return 0;}
    BLUETOOTH_DEVICE_SEARCH_PARAMS search{sizeof(search)};
    search.fReturnAuthenticated=TRUE; search.hRadio=radio;
    search.fReturnRemembered = search.fReturnUnknown = search.fReturnConnected = discover || !list;
    search.fIssueInquiry = discover;
    search.cTimeoutMultiplier = discover ? 6 : 0;
    BLUETOOTH_DEVICE_INFO dev{sizeof(dev)};
    auto devices=BluetoothFindFirstDevice(&search,&dev);
    ULONGLONG target=0;
    if(devices) {
        do {
            if(list || discover) std::cout<<address(dev.Address.ullLong)<<"\t"<<name(dev.szName)<<"\n";
            else if(_stricmp(address(dev.Address.ullLong).c_str(),argv[argc-1])==0)
                target=dev.Address.ullLong;
        } while(BluetoothFindNextDevice(devices,&dev));
        BluetoothFindDeviceClose(devices);
    }
    CloseHandle(radio);
    if(list || discover) return 0;
    if(!target) return 8;
    WSADATA data;
    if(WSAStartup(MAKEWORD(2,2),&data)) return 3;
    SOCKET socketFd=socket(AF_BTH,SOCK_STREAM,BTHPROTO_RFCOMM);
    if(socketFd==INVALID_SOCKET) return 4;
    ULONG authenticate = TRUE;
    if(setsockopt(socketFd, SOL_RFCOMM, SO_BTH_AUTHENTICATE,
                  reinterpret_cast<const char*>(&authenticate), sizeof(authenticate)) == SOCKET_ERROR) return 4;
    SOCKADDR_BTH remote{};
    remote.addressFamily=AF_BTH; remote.btAddr=target;
    GUID service={0x00000000,0xdeca,0xfade,{0xde,0xca,0xde,0xaf,0xde,0xca,0xca,0xfe}};
    if (argc == 3 && strcmp(argv[1], "--live") == 0) {
        std::cerr<<"EW_PHASE discovery"<<std::endl;
        int error = discoverChannel(remote, service);
        if (error) {
            std::cerr<<"EW_WINDOWS_SDP_ERROR status="<<error<<std::endl;
            return 4;
        }
    } else {
        remote.serviceClassId = service;
    }
    std::cerr<<"EW_PHASE open"<<std::endl;
    if(connect(socketFd,reinterpret_cast<sockaddr*>(&remote),sizeof(remote))!=0) {
        std::cerr<<"EW_WINDOWS_RFCOMM_ERROR status="<<WSAGetLastError()<<std::endl;return 4;
    }
    _setmode(0,_O_BINARY); _setmode(1,_O_BINARY);
    std::cerr<<"EW_OPEN_READY"<<std::endl;
    std::thread([socketFd]() {
        char chunk[4096]; int n;
        while((n=_read(0,chunk,sizeof(chunk)))>0) {
            int at=0;
            while(at<n) {int sent=send(socketFd,chunk+at,n-at,0); if(sent<=0) break; at+=sent;}
            if(at<n) break;
        }
        shutdown(socketFd,SD_BOTH);
    }).detach();
    char chunk[4096]; int n;
    while((n=recv(socketFd,chunk,sizeof(chunk),0))>0) {
        if(fwrite(chunk,1,n,stdout)!=static_cast<size_t>(n) || fflush(stdout)!=0) break;
    }
    shutdown(socketFd,SD_BOTH); closesocket(socketFd); WSACleanup();
    return 0;
}
