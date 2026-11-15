//  Spike: yt-dlp in embedded CPython (no subprocess, no ffmpeg) + AVFoundation passthrough join.
//  Throwaway. Logs to Documents/spike.log and the screen.

#import "SceneDelegate.h"
#import <Python/Python.h>
@import AVFoundation;
@import AVKit;

@interface SceneDelegate ()
@property (nonatomic, strong) UITextView *text;
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
@end

static NSString *Docs(void) { return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0]; }

// True duration from the file's own movie header (moov/mvhd). AVFoundation reports YouTube DASH files
// (ftyp "dash", sidx + moof fragments) at twice their length; mvhd holds the real one.
static CMTime MvhdDuration(NSString *path) {
    NSFileHandle *h = [NSFileHandle fileHandleForReadingAtPath:path];
    NSData *d = [h readDataOfLength:1 << 16]; [h closeFile];
    const uint8_t *b = d.bytes; NSUInteger n = d.length, o = 0;
    #define U32(p) ((uint32_t)b[p] << 24 | (uint32_t)b[p+1] << 16 | (uint32_t)b[p+2] << 8 | b[p+3])
    while (o + 8 <= n) {
        uint32_t sz = U32(o);
        if (sz < 8) break;
        if (!memcmp(b + o + 4, "moov", 4)) {
            NSUInteger m = o + 8;
            while (m + 8 <= MIN(n, o + sz)) {
                uint32_t s2 = U32(m);
                if (s2 < 8) break;
                if (!memcmp(b + m + 4, "mvhd", 4) && m + 32 <= n) {
                    if (b[m + 8] == 0) return CMTimeMake(U32(m + 24), U32(m + 20));
                    uint64_t dur = (uint64_t)U32(m + 32) << 32 | U32(m + 36);
                    return CMTimeMake((int64_t)dur, U32(m + 28));
                }
                m += s2;
            }
        }
        o += sz;
    }
    return kCMTimeInvalid;
}

@implementation SceneDelegate

- (void)log:(NSString *)s {
    NSLog(@"SPIKE %@", s);
    printf("SPIKE %s\n", s.UTF8String); fflush(stdout);
    NSString *p = [Docs() stringByAppendingPathComponent:@"spike.log"];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:p];
    if (!h) { [@"" writeToFile:p atomically:NO encoding:NSUTF8StringEncoding error:nil]; h = [NSFileHandle fileHandleForWritingAtPath:p]; }
    [h seekToEndOfFile]; [h writeData:[[s stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]]; [h closeFile];
    dispatch_async(dispatch_get_main_queue(), ^{ self.text.text = [self.text.text stringByAppendingFormat:@"%@\n", s]; });
}

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    UIWindowScene *windowScene = (UIWindowScene *)scene;
    self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = UIColor.systemBackgroundColor;
    self.text = [[UITextView alloc] initWithFrame:CGRectInset(vc.view.bounds, 12, 60)];
    self.text.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.text.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.text.editable = NO;
    [vc.view addSubview:self.text];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    [[NSFileManager defaultManager] removeItemAtPath:[Docs() stringByAppendingPathComponent:@"spike.log"] error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:[Docs() stringByAppendingPathComponent:@"dl"] error:nil];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int rc = [self runPython];
        [self log:[NSString stringWithFormat:@"python exit %d", rc]];
        [self avfoundation];
    });
}

- (int)runPython {
    NSString *res = [[NSBundle mainBundle] resourcePath];
    setenv("NO_COLOR", "1", 1);
    PyPreConfig pre; PyConfig config;
    PyPreConfig_InitIsolatedConfig(&pre);
    PyConfig_InitIsolatedConfig(&config);
    pre.utf8_mode = 1;
    config.use_system_logger = 0;
    config.buffered_stdio = 0;
    config.write_bytecode = 0;
    config.install_signal_handlers = 1;
    config.run_module = Py_DecodeLocale("spike", NULL);
    PyStatus st = Py_PreInitialize(&pre);
    if (PyStatus_Exception(st)) { [self log:@"preinit failed"]; return -1; }
    wchar_t *home = Py_DecodeLocale([[res stringByAppendingString:@"/python"] UTF8String], NULL);
    PyConfig_SetString(&config, &config.home, home);
    st = PyConfig_Read(&config);
    if (PyStatus_Exception(st)) { [self log:@"config read failed"]; return -1; }
    char *argv[] = {"spike"};
    PyConfig_SetBytesArgv(&config, 1, argv);
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    st = Py_InitializeFromConfig(&config);
    if (PyStatus_Exception(st)) { [self log:[NSString stringWithFormat:@"init failed %s", st.err_msg]]; return -1; }
    [self log:[NSString stringWithFormat:@"python init %.2fs", CFAbsoluteTimeGetCurrent() - t0]];
    PyObject *site = PyImport_ImportModule("site");
    PyObject *add = PyObject_GetAttrString(site, "addsitedir");
    PyObject *r = PyObject_CallFunction(add, "s", [[res stringByAppendingString:@"/app_packages"] UTF8String]);
    if (!r) { PyErr_Print(); return -1; }
    PyObject *sys_path = PySys_GetObject("path");
    PyList_Insert(sys_path, 0, PyUnicode_FromString([[res stringByAppendingString:@"/app"] UTF8String]));
    [self log:@"---- python ----"];
    return Py_RunMain();
}

- (BOOL)export:(AVAsset *)asset to:(NSString *)path type:(AVFileType)type label:(NSString *)label {
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    AVAssetExportSession *ex = [[AVAssetExportSession alloc] initWithAsset:asset presetName:AVAssetExportPresetPassthrough];
    ex.outputURL = [NSURL fileURLWithPath:path];
    ex.outputFileType = type;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    [ex exportAsynchronouslyWithCompletionHandler:^{ dispatch_semaphore_signal(sem); }];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    [self log:[NSString stringWithFormat:@"%@ export status=%ld err=%@ %.2fs size=%llu", label, (long)ex.status,
               ex.error.localizedDescription ?: @"-", CFAbsoluteTimeGetCurrent() - t0, [a fileSize]]];
    return ex.status == AVAssetExportSessionStatusCompleted;
}

- (void)describe:(NSString *)path label:(NSString *)label {
    AVURLAsset *a = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
    NSMutableArray *tr = [NSMutableArray array];
    for (AVAssetTrack *t in a.tracks) {
        CMFormatDescriptionRef fd = (__bridge CMFormatDescriptionRef)t.formatDescriptions.firstObject;
        FourCharCode c = fd ? CMFormatDescriptionGetMediaSubType(fd) : 0;
        [tr addObject:[NSString stringWithFormat:@"%@:%c%c%c%c", t.mediaType, (c>>24)&255, (c>>16)&255, (c>>8)&255, c&255]];
    }
    [self log:[NSString stringWithFormat:@"%@ playable=%d duration=%.2fs tracks=%@", label, a.isPlayable,
               CMTimeGetSeconds(a.duration), [tr componentsJoinedByString:@","]]];
}

- (void)avfoundation {
    NSString *dl = [Docs() stringByAppendingPathComponent:@"dl"];
    NSString *aud = [dl stringByAppendingPathComponent:@"audio.m4a"];
    NSString *vid = [dl stringByAppendingPathComponent:@"video.mp4"];
    [self log:@"---- AVFoundation ----"];
    [self describe:aud label:@"downloaded audio"];
    [self describe:vid label:@"downloaded video"];
    AVURLAsset *va = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:vid] options:nil];
    AVURLAsset *aa = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:aud] options:nil];
    CMTime vm = MvhdDuration(vid), am = MvhdDuration(aud);
    [self log:[NSString stringWithFormat:@"durations AVFoundation video=%.2f audio=%.2f | mvhd video=%.2f audio=%.2f",
               CMTimeGetSeconds(va.duration), CMTimeGetSeconds(aa.duration), CMTimeGetSeconds(vm), CMTimeGetSeconds(am)]];
    AVAssetTrack *vt = [va tracksWithMediaType:AVMediaTypeVideo].firstObject;
    AVAssetTrack *at = [aa tracksWithMediaType:AVMediaTypeAudio].firstObject;
    if (!vt || !at) { [self log:@"JOIN FAIL: missing track"]; return; }
    // 1. audio-only: DASH m4a -> plain m4a (what yt-dlp's FixupM4a does with ffmpeg), clamped to mvhd
    AVMutableComposition *ac = [AVMutableComposition composition];
    [[ac addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid]
        insertTimeRange:CMTimeRangeMake(kCMTimeZero, CMTIME_IS_VALID(am) ? am : aa.duration) ofTrack:at atTime:kCMTimeZero error:nil];
    NSString *audFixed = [Docs() stringByAppendingPathComponent:@"audio-fixed.m4a"];
    if ([self export:ac to:audFixed type:AVFileTypeAppleM4A label:@"audio remux"])
        [self describe:audFixed label:@"audio-fixed"];
    // 2. join video + audio, clamped to the shorter true (mvhd) duration
    AVMutableComposition *comp = [AVMutableComposition composition];
    CMTime dur = (CMTIME_IS_VALID(vm) && CMTIME_IS_VALID(am)) ? CMTimeMinimum(vm, am) : CMTimeMinimum(va.duration, aa.duration);
    NSError *e1 = nil, *e2 = nil;
    [[comp addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid]
        insertTimeRange:CMTimeRangeMake(kCMTimeZero, dur) ofTrack:vt atTime:kCMTimeZero error:&e1];
    [[comp addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid]
        insertTimeRange:CMTimeRangeMake(kCMTimeZero, dur) ofTrack:at atTime:kCMTimeZero error:&e2];
    if (e1 || e2) { [self log:[NSString stringWithFormat:@"JOIN FAIL insert: %@ %@", e1, e2]]; return; }
    NSString *joined = [Docs() stringByAppendingPathComponent:@"joined.mp4"];
    if (![self export:comp to:joined type:AVFileTypeMPEG4 label:@"join"]) { [self log:@"JOIN FAIL"]; return; }
    [self describe:joined label:@"joined"];
    // 3. play it on screen and check the clock advances
    dispatch_sync(dispatch_get_main_queue(), ^{
        self.player = [AVPlayer playerWithURL:[NSURL fileURLWithPath:joined]];
        self.playerLayer = [AVPlayerLayer playerLayerWithPlayer:self.player];
        UIView *v = self.window.rootViewController.view;
        self.playerLayer.frame = CGRectMake(12, 60, v.bounds.size.width - 24, (v.bounds.size.width - 24) * 9 / 16);
        [v.layer addSublayer:self.playerLayer];
        [self.player seekToTime:CMTimeMake(60, 1)];
        [self.player play];
    });
    [NSThread sleepForTimeInterval:6];
    __block double t = 0; __block long st = 0, tcs = 0;
    dispatch_sync(dispatch_get_main_queue(), ^{
        t = CMTimeGetSeconds(self.player.currentTime); st = self.player.currentItem.status; tcs = self.player.timeControlStatus;
    });
    [self log:[NSString stringWithFormat:@"PLAY item.status=%ld (1=ready) timeControl=%ld (2=playing) t=%.2fs (started at 60s)", st, tcs, t]];
    [self log:@"SPIKE DONE"];
}

@end
