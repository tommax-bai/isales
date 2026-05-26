# DingRTC 3.9.0 SDK API ground truth

Captured 2026-05-26 from actual SDK headers (vendor at `~/codes/vendor/DingRTC_*_SDK_3_9_0/`).
Replaces speculative API names in design.md / proposal.md where they differ.

vendor README (`api/README` in Linux/Windows SDK):
> DingRTC，作为AliRTC的升级版本，接口定义保持一致。服务器为钉钉的基础设施，和旧版本AliRTC并不互通。

## Cloud Linux + Windows (shared C++ API)

**Headers**: `api/engine_interface.h`, `api/engine_types.h`, `api/engine_conf.h`, `api/engine_utils.h`
**Namespace**: `ding::rtc`
**Linux .so**: `lib/x86_64/libDingRTC.so`
**Windows .dll/.lib**: `lib/x64/DingRTC.{dll,lib}`

### `struct RtcEngineAuthInfo`
```cpp
namespace ding::rtc {
  struct RtcEngineAuthInfo {
    String channelId;   // 1..64 chars
    String userId;      // 1..64 chars
    String appId;
    String token;       // <- rtc_token.py v3.0 binary output goes here
    String gslbServer;  // default "https://gslb.dingrtc.com"
  };
}
```

### `struct RtcEngineAudioFrame`
```cpp
typedef enum { RtcEngineAudioFramePcm16 = 0 } RtcEngineAudioFrameType;

typedef struct {
  RtcEngineAudioFrameType type;  // PCM 16bit LE
  int bytesPerSample;             // 2 for PCM16
  int samplesPerSec;              // 8000/16000/32000/44100/48000
  int channels;                   // 1 (mono) or 2 (stereo)
  int samples;                    // per-channel sample count
  void* buffer;                   // raw PCM bytes, buffer_size = samples*channels*bytesPerSample
  long long timestamp;
} RtcEngineAudioFrame;
```

### `class RtcEngine` (key methods only — full interface has ~250 methods)
```cpp
// Static factory
static RtcEngine* Create(const char *extras);              // extras may be NULL
static void Destroy(RtcEngine *instance);
static int SetLogDirPath(const char *logDirPath);
static int SetLogLevel(RtcEngineLogLevel logLevel);

// Event listener
virtual int SetEngineEventListener(RtcEngineEventListener *listener) = 0;

// Channel lifecycle
virtual int JoinChannel(const RtcEngineAuthInfo &authInfo, const char *userNameUtf8) = 0;
virtual int LeaveChannel() = 0;

// Pub/sub
virtual int PublishLocalAudioStream(bool enable) = 0;     // true for engine
virtual int PublishLocalVideoStream(bool enable) = 0;     // false for engine (audio-only)
virtual int SubscribeAllRemoteAudioStreams(bool sub) = 0; // true for engine (混流模式)

// External audio source (engine pushes TTS PCM)
virtual int SetExternalAudioSource(bool enable, int sampleRate, int channels) = 0;
virtual int PushExternalAudioFrame(RtcEngineAudioFrame *frame) = 0;

// External audio render (alternative: push to remote speaker; not used by engine)
virtual int SetExternalAudioRender(bool enable, int sampleRate, int channels) = 0;
virtual int PushExternalAudioRenderFrame(RtcEngineAudioFrame *frame) = 0;

// Audio frame observer (receive remote PCM)
virtual int RegisterAudioFrameObserver(RtcEngineAudioFrameObserver *observer) = 0;
virtual int EnableAudioFrameObserver(bool enabled, unsigned int position) = 0;
virtual int EnableAudioFrameObserver(bool enabled, unsigned int position,
                                      const RtcEngineAudioFrameObserverConfig &config) = 0;
```

### `class RtcEngineEventListener`
Key callbacks (signatures verified from `engine_types.h:219+`):
```cpp
virtual void OnJoinChannelResult(int result, const char *channel, const char *userId, int elapsed);
virtual void OnLeaveChannelResult(int result, RtcEngineStats stats);
virtual void OnBye(int code);                              // forced kick (3.x: no leave callback after this)
virtual void OnOccurError(int error, const char *message);
virtual void OnConnectionStatusChange(RtcEngineConnectionStatus status, RtcEngineConnectionChangedReason reason);
// (plus ~40 more — see engine_types.h:210-770)
```

### `class RtcEngineAudioFrameObserver`
```cpp
virtual void OnCapturedAudioFrame(RtcEngineAudioFrame *frame);
virtual void OnProcessCapturedAudioFrame(RtcEngineAudioFrame *frame);
virtual void OnPublishAudioFrame(RtcEngineAudioFrame *frame);
virtual void OnPlaybackAudioFrame(RtcEngineAudioFrame *frame);     // <- iSales 用这个收下行
virtual void OnRemoteUserAudioFrame(const char *uid, RtcEngineAudioFrame *frame);
```

### Position enum (for `EnableAudioFrameObserver`)
```
RtcEngineAudioObservePositionCapture         = 1   // OnCapturedAudioFrame
RtcEngineAudioObservePositionProcessCapture  = 2   // OnProcessCapturedAudioFrame
RtcEngineAudioObservePositionPublish         = 4   // OnPublishAudioFrame
RtcEngineAudioObservePositionPlayback        = 8   // OnPlaybackAudioFrame  <-- iSales engine
RtcEngineAudioObservePositionRemoteUser      = 16  // OnRemoteUserAudioFrame
```

### Key error codes (`engine_conf.h`)
```
RtcEngineErrorJoinBadAppId        = 0x02010202
RtcEngineErrorJoinInvalidChannel  = 0x02010203
RtcEngineErrorJoinBadChannel      = 0x02010204
RtcEngineErrorJoinBadToken        = 0x02010205   // <-- 2026-05-25 PoC 错码
RtcEngineErrorJoinTimeout         = 0x01020204
RtcEngineErrorJoinBadParam        = 0x01030101
RtcEngineErrorJoinChannelFailed   = 0x01030202
```

## macOS framework Obj-C API

**Headers**: `~/codes/vendor/DingRTC_macOS_SDK_3_9_0/DingRTC.framework/Headers/`
**Main headers**: `DingRtcEngine.h`, `DingRtcEngineTypes.h`
**Framework binary**: `Versions/A/DingRTC`

### `@interface DingRtcAuthInfo : NSObject <NSCopying>`
```objc
@property (nonatomic, copy) NSString * _Nonnull channelId;
@property (nonatomic, copy) NSString * _Nonnull userId;
@property (nonatomic, copy) NSString * _Nonnull appId;
@property (nonatomic, copy) NSString * _Nonnull token;
@property (nonatomic, copy) NSString * _Nullable gslbServer;
```

### `@interface DingRtcAudioDataSample : NSObject`
```objc
@property (nonatomic, assign) void* _Nonnull data;
@property (nonatomic, assign) int numOfSamples;
@property (nonatomic, assign) int bytesPerSample;
@property (nonatomic, assign) int numOfChannels;
@property (nonatomic, assign) int sampleRate;
```

### `@protocol DingRtcEngineDelegate <NSObject>` (key selectors)
```objc
- (void)onJoinChannelResult:(int)result channel:(NSString *_Nonnull)channel
    userId:(NSString *_Nonnull)userId elapsed:(int)elapsed;
- (void)onLeaveChannelResult:(int)result stats:(DingRtcStats *_Nonnull)stats;
- (void)onBye:(DingRtcOnByeType)code;
- (void)onOccurError:(int)error message:(NSString *_Nonnull)message;
- (void)onConnectionStatusChanged:(DingRtcConnectionStatus)status
    reason:(DingRtcConnectionStatusChangeReason)reason;
- (void)onRemoteUserOnLineNotify:(NSString *_Nonnull)uid elapsed:(int)elapsed;
- (void)onRemoteUserOffLineNotify:(NSString *_Nonnull)uid
    offlineReason:(DingRtcUserOfflineReason)reason;
- (void)onRemoteTrackAvailableNotify:(NSString *_Nonnull)uid
    audioTrack:(DingRtcAudioTrack)audioTrack videoTrack:(DingRtcVideoTrack)videoTrack;
```

### `@protocol DingRtcAudioFrameDelegate <NSObject>`
```objc
- (void)onRemoteUserAudioFrame:(NSString *_Nonnull)uid frame:(DingRtcAudioDataSample *_Nonnull)frame;
- (void)onPlaybackAudioFrame:(DingRtcAudioDataSample *_Nonnull)frame;
- (void)onCapturedAudioFrame:(DingRtcAudioDataSample *_Nonnull)frame;
- (void)onProcessCapturedAudioFrame:(DingRtcAudioDataSample *_Nonnull)frame;
- (void)onPublishAudioFrame:(DingRtcAudioDataSample *_Nonnull)frame;
```

### `@interface DingRtcEngine : NSObject <DingRtcEngineDelegate>`
```objc
// Factory (use createInstance — sharedInstance is for singleton, we want per-call)
+ (instancetype _Nonnull)createInstance:(id<DingRtcEngineDelegate>_Nullable)delegate
    extras:(NSString *_Nullable)extras;
+ (void)destroyInstance:(DingRtcEngine *_Nonnull)instance;
+ (NSString *_Nonnull)getSDKVersion;

// Channel lifecycle (returns int = errCode; 0 = success)
- (int)joinChannel:(DingRtcAuthInfo *_Nonnull)authInfo
    name:(NSString *_Nullable)userName
    onResultWithUserId:(void(^_Nullable)(NSInteger errCode, NSString *channel, NSString *userId, NSInteger elapsed))onResult;
- (int)leaveChannel;

// Pub/sub
- (int)publishLocalAudioStream:(BOOL)enabled;
- (int)publishLocalVideoStream:(BOOL)enabled;
- (int)subscribeAllRemoteAudioStreams:(BOOL)sub;

// External audio
- (int)setExternalAudioSource:(BOOL)enable
    withSampleRate:(NSUInteger)sampleRate channelsPerFrame:(NSUInteger)channelsPerFrame;
- (int)pushExternalAudioFrame:(DingRtcAudioDataSample *_Nonnull)data;
- (int)setExternalAudioRender:(BOOL)enable
    withSampleRate:(NSUInteger)sampleRate channelsPerFrame:(NSUInteger)channelsPerFrame;
- (int)pushExternalAudioRenderFrame:(DingRtcAudioDataSample *_Nonnull)data;

// Audio frame observer
- (int)registerAudioFrameObserver:(id<DingRtcAudioFrameDelegate> _Nullable)observer;
- (int)enableAudioFrameObserver:(BOOL)enable position:(DingRtcAudioObservePosition)position;
- (int)enableAudioFrameObserver:(BOOL)enable position:(DingRtcAudioObservePosition)position
    config:(DingRtcAudioObserveConfig *_Nonnull)config;
```

## Vendor SDK file sha256 (2025-04-15 release)

```
3dc2361fbf6e9e181aba0fbdc30b488064e47f866c7d2d2ab1607c3cd53622e6  DingRTC_Linux_SDK_3_9_0.zip
197337f2bc2ff2476abc988672cf5b20b381f5e12e9069f37dbd3fd157f7020e  DingRTC_macOS_SDK_3_9_0.zip
f59482589a211e3fc4368c4750dfa50603f03c0acdf3d157728a41ac1ca19974  DingRTC_Windows_SDK_3_9_0.zip
```

Download URLs (3.9.0, OSS `dingrtc.oss-cn-zhangjiakou.aliyuncs.com`):
- `https://dingrtc.oss-cn-zhangjiakou.aliyuncs.com/sdk/linux/3.9.0/DingRTC_Linux_SDK_3_9_0.zip`
- `https://dingrtc.oss-cn-zhangjiakou.aliyuncs.com/sdk/mac/3.9.0/DingRTC_macOS_SDK_3_9_0.zip`
- `https://dingrtc.oss-cn-zhangjiakou.aliyuncs.com/sdk/windows/3.9.0/DingRTC_Windows_SDK_3_9_0.zip`

## Deviations from design.md / proposal.md

| Doc claim | Actual | Action |
|---|---|---|
| Cloud "gslbServer default `https://gslb.dingrtc.com`" | Headers say "GSLB地址" but no documented default | Use the documented value from vendor wiki; if empty, SDK falls back internally |
| macOS class `_AliRtcAudioDelegate` | `@protocol DingRtcAudioFrameDelegate` (protocol, not class) | binding implements NSObject subclass conforming to this protocol |
| macOS `loadBundle("DingRTC", ...)` | `objc.loadBundle("DingRTC", bundle_path=<framework>)` — class lookup is `DingRtcEngine` / `DingRtcAuthInfo` / `DingRtcAudioDataSample` | confirmed |
| Linux `subscribeAudioFormat=PcmBeforMixing` per-uid | Not in 3.9.0 C++ API (only混流 via `SubscribeAllRemoteAudioStreams`); per-position observer via `EnableAudioFrameObserver(..., position)` | use混流 + `OnPlaybackAudioFrame` |
| Cloud "audio_pipe AliyunRTCCapture/Playback" | Doesn't exist; only `AliyunRtcSession` | tasks.md §3.7 already作废 |
