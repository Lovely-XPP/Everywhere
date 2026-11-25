// Local line protocol on stdin; the BLE UUIDs and packet layout match the shipping iPhone app.
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Devices.Bluetooth.h>
#include <winrt/Windows.Devices.Bluetooth.GenericAttributeProfile.h>
#include <winrt/Windows.Storage.Streams.h>
#include <iostream>
#include <mutex>
#include <sstream>
#include <map>
#include <vector>
#include <string>
using namespace winrt;
using namespace Windows::Devices::Bluetooth;
using namespace Windows::Devices::Bluetooth::GenericAttributeProfile;
using namespace Windows::Storage::Streams;
using bytes=std::vector<uint8_t>;
static std::mutex output,state;
static std::string snapshot=R"({"target":"","authenticated":false,"message":"Ready"})";
static std::map<std::string,std::string> reads;
static void emit(std::string s){std::lock_guard l(output);std::cout<<s<<std::endl;}
static std::string hex(bytes const& v){
    static constexpr char digits[]="0123456789abcdef";std::string s;
    for(auto b:v){s+=digits[b>>4];s+=digits[b&15];}return s;
}
static bytes decode(std::string const& s){
    if(s.size()%2 || s.size()>2048) throw std::invalid_argument("hex size");
    bytes v; for(size_t i=0;i<s.size();i+=2) v.push_back(static_cast<uint8_t>(std::stoul(s.substr(i,2),nullptr,16)));
    return v;
}
static std::string peer(GattSession const& session){
    auto id=to_string(session.DeviceId().Id());return hex(bytes(id.begin(),id.end()));
}
static IBuffer buffer(bytes const& v){DataWriter w;w.WriteBytes(v);return w.DetachBuffer();}
static GattLocalCharacteristic field(GattLocalService const& s,wchar_t const* id,GattCharacteristicProperties p){
    GattLocalCharacteristicParameters cfg;cfg.CharacteristicProperties(p);
    cfg.ReadProtectionLevel(GattProtectionLevel::EncryptionRequired);
    cfg.WriteProtectionLevel(GattProtectionLevel::EncryptionRequired);
    auto result=s.CreateCharacteristicAsync(guid(id),cfg).get();
    if(result.Error()!=BluetoothError::Success)throw std::runtime_error("CreateCharacteristic failed");
    return result.Characteristic();
}
static fire_and_forget writeReceipt(GattLocalCharacteristic, GattWriteRequestedEventArgs args){
    auto deferral=args.GetDeferral();
    try {
        auto r=co_await args.GetRequestAsync();
        if(r){
            if(r.Offset()!=0 || r.Value().Length()!=5)r.RespondWithProtocolError(0x0d);
            else{bytes b(5);DataReader::FromBuffer(r.Value()).ReadBytes(b);
                emit("ACK "+peer(args.Session())+" "+hex(b));r.Respond();}
        }
    }catch(...){}deferral.Complete();
}
static fire_and_forget readStatus(GattLocalCharacteristic,GattReadRequestedEventArgs args){
    auto deferral=args.GetDeferral();
    try{
        auto r=co_await args.GetRequestAsync();
        if(r){
            std::lock_guard l(state);auto &data=reads[peer(args.Session())];
            if(r.Offset()==0)data=snapshot;
            if(r.Offset()>data.size())r.RespondWithProtocolError(7);
            else r.RespondWithValue(buffer(bytes(data.begin()+r.Offset(),data.end())));
        }
    }catch(...){}deferral.Complete();
}
int main(int argc,char** argv){
    try{
        init_apartment();
        if(argc==2 && std::string(argv[1])=="--self-test")
            return hex(decode("0180ff"))=="0180ff" ? 0 : 1;
        bool status=argc==2 && std::string(argv[1])=="status";
        auto adapter=BluetoothAdapter::GetDefaultAsync().get();
        if(!adapter || !adapter.IsPeripheralRoleSupported())throw std::runtime_error("BLE peripheral role unsupported");
        auto result=GattServiceProvider::CreateAsync(guid(status?L"8cc42c82-ac28-4f92-a5cf-4e76267234f4":L"62d42c56-03cb-4895-adb6-08b640f25f71")).get();
        if(result.Error()!=BluetoothError::Success)throw std::runtime_error("Create GATT service failed");
        auto provider=result.ServiceProvider();
        using P=GattCharacteristicProperties;
        GattLocalCharacteristic cmd{nullptr},rmc{nullptr},ack{nullptr},report{nullptr};
        if(status){
            report=field(provider.Service(),L"18a6b6aa-4113-477e-8c1c-4bb5c977aa26",P::Read|P::Notify);
            report.ReadRequested(readStatus);
        }else{
            cmd=field(provider.Service(),L"971735a6-f422-4bb2-a924-47fb7a5385c3",P::Indicate);
            rmc=field(provider.Service(),L"221c5cf2-5e82-4bb1-ab2d-48a729b9071f",P::Indicate);
            ack=field(provider.Service(),L"2244d789-b54f-4736-afa4-e98e7c54118c",P::Write);
            ack.WriteRequested(writeReceipt);
        }
        GattServiceProviderAdvertisingParameters ad;ad.IsConnectable(true);ad.IsDiscoverable(true);
        provider.AdvertisementStatusChanged([](auto const&,auto const& args){
            if(args.Status()==GattServiceProviderAdvertisementStatus::Started ||
               args.Status()==GattServiceProviderAdvertisementStatus::StartedWithoutAllAdvertisementData)emit("READY");
            if(args.Status()==GattServiceProviderAdvertisementStatus::Aborted)emit("ERROR advertising aborted");
        });
        provider.StartAdvertising(ad);
        std::string line;
        while(std::getline(std::cin,line)){
            std::istringstream in(line);std::string op,id,data;in>>op;
            if(op=="QUIT")break;
            if(op=="STATUS" && status){
                in>>data;auto b=decode(data);
                {std::lock_guard l(state);snapshot.assign(b.begin(),b.end());}
                if(report.SubscribedClients().Size())report.NotifyValueAsync(buffer({0})).get();
            }else if(op=="PEERS" && !status){
                for(auto const& c:cmd.SubscribedClients())emit("PEER "+peer(c.Session())+" C "+std::to_string(c.MaxNotificationSize()));
                for(auto const& c:rmc.SubscribedClients())emit("PEER "+peer(c.Session())+" R "+std::to_string(c.MaxNotificationSize()));
                emit("END");
            }else if(op=="SEND" && !status){
                std::string kind;in>>id>>kind>>data;
                auto characteristic=kind=="R"?rmc:cmd;bool sent=false;
                auto b=decode(data);
                for(auto const& c:characteristic.SubscribedClients()){
                    if(peer(c.Session())==id && b.size()<=c.MaxNotificationSize()){
                        auto res=characteristic.NotifyValueAsync(buffer(b),c).get();
                        sent=res.Status()==GattCommunicationStatus::Success;break;
                    }
                }
                if(!sent)emit("ERROR peer unreachable");
            }
        }
        provider.StopAdvertising();
    }catch(hresult_error const& e){emit("ERROR "+to_string(e.message()));return 1;}
    catch(std::exception const& e){emit("ERROR "+std::string(e.what()));return 1;}
}
