/* Root helper for the Power Modes menu bar app (run through a narrow sudoers rule).
 * --switch keeps the built-in display unchanged during a power-mode switch;
 * --set changes the profile of the power source that is not in use.
 * macOS CoreBrightness's native update lock prevents the dim, instead of undoing it.
 * Private API: capability-check every use; do not change auto brightness, display
 * sleep, external displays, or an existing display-preset lock.
 * A separate short-lived watchdog unlocks on pipe EOF, SIGKILL, or a 20s timeout.
 */
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <poll.h>
#include <signal.h>
#include <unistd.h>

@interface NSObject (PowerModeBrightness)
- (id)copyPropertyForKey:(id)key andDisplay:(unsigned long long)display;
- (BOOL)setProperty:(id)value withKey:(id)key andDisplay:(unsigned long long)display;
@end

static NSString *const lockKey = @"CBDisplayPresetLockBrightnessUpdates";
static volatile sig_atomic_t interrupted;
static void onSignal(int signalNumber) { interrupted = signalNumber; }
static void report(NSString *message) { fprintf(stderr, "power-modes-helper: %s\n", message.UTF8String); }
static double now(void) { return NSProcessInfo.processInfo.systemUptime; }
static void pauseBriefly(void) { [NSThread sleepForTimeInterval:0.02]; }

static id newClient(void) {
    if (!dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW | RTLD_LOCAL)) return nil;
    id client = [[NSClassFromString(@"BrightnessSystemClient") alloc] init];
    if (![client respondsToSelector:@selector(copyPropertyForKey:andDisplay:)] ||
        ![client respondsToSelector:@selector(setProperty:withKey:andDisplay:)]) return nil;
    return client;
}
static NSNumber *get(id client, CGDirectDisplayID display, NSString *key) {
    id value = [client copyPropertyForKey:key andDisplay:display];
    return [value isKindOfClass:NSNumber.class] ? value : nil;
}
static BOOL setLock(id client, CGDirectDisplayID display, BOOL enabled) {
    if (![client setProperty:@(enabled) withKey:lockKey andDisplay:display]) return NO;
    NSNumber *value = get(client, display, lockKey);
    return value && value.boolValue == enabled;
}
static char readByte(int fd, int timeoutMs) {
    struct pollfd item = { .fd = fd, .events = POLLIN };
    int result;
    do { result = poll(&item, 1, timeoutMs); } while (result < 0 && errno == EINTR);
    char byte = 0;
    return result > 0 && read(fd, &byte, 1) == 1 ? byte : 0;
}

static int watchdog(CGDirectDisplayID display) {
    // Leave the caller's process group: a signal sent to that group must not
    // kill this watchdog before it can release the parent's brightness lock.
    if (setpgid(0, 0) != 0) { (void)write(STDOUT_FILENO, "E", 1); return 1; }
    signal(SIGPIPE, SIG_IGN);
    id client = newClient();
    NSNumber *original = get(client, display, lockKey);
    if (!original || original.boolValue) { (void)write(STDOUT_FILENO, "E", 1); return 1; }
    (void)write(STDOUT_FILENO, "R", 1);
    struct pollfd item = { .fd = STDIN_FILENO, .events = POLLIN | POLLHUP };
    int result;
    double deadline = now() + 20;
    do { result = poll(&item, 1, (int)fmax(0, (deadline - now()) * 1000)); }
    while (result < 0 && errno == EINTR && now() < deadline);
    BOOL ok = setLock(client, display, NO);
    if (!ok) report(@"ERROR: could not release brightness lock");
    if (result == 0) report(@"Watchdog released brightness lock after timeout");
    (void)write(STDOUT_FILENO, ok ? "O" : "E", 1);
    return ok ? 0 : 1;
}

static BOOL runPmset(NSString *source, NSString *mode) {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/pmset"];
    task.arguments = @[[ @"-" stringByAppendingString:source], @"powermode", mode];
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) { report(error.localizedDescription); return NO; }
    double deadline = now() + 8;
    while (task.running && !interrupted && now() < deadline) pauseBriefly();
    if (task.running) {
        [task terminate];
        deadline = now() + 1;
        while (task.running && now() < deadline) pauseBriefly();
        if (task.running) (void)kill(task.processIdentifier, SIGKILL);
        [task waitUntilExit];
        report(@"Power-mode command interrupted or timed out");
        return NO;
    }
    [task waitUntilExit];
    return task.terminationReason == NSTaskTerminationReasonExit && task.terminationStatus == 0;
}

static CGDirectDisplayID awakeBuiltInDisplay(void) {
    CGDirectDisplayID displays[16]; uint32_t count = 0;
    if (CGGetOnlineDisplayList(16, displays, &count) != kCGErrorSuccess) return UINT32_MAX;
    for (uint32_t i = 0; i < count; i++) {
        if (CGDisplayIsBuiltin(displays[i]) && CGDisplayIsActive(displays[i]) && !CGDisplayIsAsleep(displays[i])) return displays[i];
    }
    return 0;
}

static int switchMode(NSString *executable, NSString *source, NSString *mode) {
    if (geteuid() != 0) { report(@"Power-mode changes must run as root"); return 1; }
    CGDirectDisplayID display = awakeBuiltInDisplay();
    if (display == UINT32_MAX) { report(@"Unable to enumerate displays; mode not changed"); return 1; }
    if (!display) return runPmset(source, mode) ? 0 : 1; // Do not wake a sleeping/closed display.
    id client = newClient();
    NSNumber *locked = get(client, display, lockKey);
    if (!locked) { report(@"Native brightness lock unavailable; mode not changed"); return 1; }
    if (locked.boolValue) return runPmset(source, mode) ? 0 : 1; // Preserve an existing preset's lock.
    NSNumber *brightness = get(client, display, @"DisplayServicesBrightness");
    NSNumber *nits = get(client, display, @"NitsPhysical");
    if (!brightness || !isfinite(brightness.doubleValue) || brightness.doubleValue < 0 || brightness.doubleValue > 1 ||
        !nits || !isfinite(nits.doubleValue) || nits.doubleValue < 0) {
        report(@"Unable to read current brightness; mode not changed"); return 1;
    }

    NSPipe *control = [NSPipe pipe];
    NSPipe *ack = [NSPipe pipe];
    int controlFd = control.fileHandleForWriting.fileDescriptor;
    (void)fcntl(controlFd, F_SETFD, FD_CLOEXEC);
    NSTask *guard = [[NSTask alloc] init];
    guard.executableURL = [NSURL fileURLWithPath:executable];
    guard.arguments = @[@"--unlock-on-exit", [NSString stringWithFormat:@"%u", display]];
    guard.standardInput = control;
    guard.standardOutput = ack;
    NSError *error = nil;
    if (![guard launchAndReturnError:&error]) { report(error.localizedDescription); return 1; }
    int ackFd = ack.fileHandleForReading.fileDescriptor;
    if (readByte(ackFd, 3000) != 'R') {
        [control.fileHandleForWriting closeFile];
        report(@"Brightness watchdog not ready; mode not changed");
        return 1;
    }
    BOOL success = NO;
    BOOL released = NO;
    @try {
        if (!interrupted && setLock(client, display, YES)) {
#ifdef POWER_MODE_TESTING
            if (getenv("POWER_MODE_TEST_CRASH")) _exit(99);
#endif
            success = runPmset(source, mode);
            // Wait for CoreBrightness to acknowledge Low Power Mode, not just pmset.
            BOOL expectedEco = [mode isEqualToString:@"1"];
            BOOL acknowledged = NO;
            double deadline = now() + 3;
            while (success && !interrupted && now() < deadline) {
                NSNumber *eco = get(client, display, @"EcoModeState");
                if (eco && eco.boolValue == expectedEco) { acknowledged = YES; break; }
                pauseBriefly();
            }
            if (success && !acknowledged) report(@"Display did not acknowledge power mode (power source may have changed)");
            success = success && acknowledged && !interrupted;
            // Let the native dimming ramp finish while all brightness writes are paused.
            deadline = now() + 0.75;
            while (!interrupted && now() < deadline) pauseBriefly();
        } else {
            report(@"Could not lock brightness; mode not changed");
        }
    } @finally {
        [control.fileHandleForWriting closeFile]; // EOF also works if this process is killed.
        released = readByte(ackFd, 3000) == 'O';
        if (!released) released = setLock(client, display, NO);
        if (!released) report(@"ERROR: brightness lock release failed");
    }
    if (!success || !released || interrupted) return 1;
    NSNumber *after = get(client, display, @"DisplayServicesBrightness");
    NSNumber *afterNits = get(client, display, @"NitsPhysical");
    if (!after || !afterNits || fabs(after.doubleValue - brightness.doubleValue) > 0.005 ||
        fabs(afterNits.doubleValue - nits.doubleValue) > fmax(1.0, nits.doubleValue * 0.01)) {
        report(@"Brightness changed during switch; not overriding user brightness"); return 1;
    }
    printf("brightness preserved: display=%u slider=%.6g nits=%.6g; lock released\n", display, after.doubleValue, afterNits.doubleValue);
    return 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 3 && !strcmp(argv[1], "--unlock-on-exit")) {
            char *end; errno = 0;
            unsigned long display = strtoul(argv[2], &end, 10);
            if (errno || !*argv[2] || *end || !display || display >= UINT32_MAX) return 2;
            return watchdog((CGDirectDisplayID)display);
        }
        if (argc == 2 && !strcmp(argv[1], "--status")) {
            CGDirectDisplayID display = awakeBuiltInDisplay();
            if (!display || display == UINT32_MAX) { report(@"No awake built-in display"); return 3; }
            id client = newClient();
            NSNumber *locked = get(client, display, lockKey);
            NSNumber *brightness = get(client, display, @"DisplayServicesBrightness");
            NSNumber *nits = get(client, display, @"NitsPhysical");
            if (!locked || !brightness || !nits) return 1;
            printf("display=%u slider=%.6g nits=%.6g lock=%d low_power=%d\n", display, brightness.doubleValue,
                   nits.doubleValue, locked.boolValue, [get(client, display, @"EcoModeState") boolValue]);
            return 0;
        }
        BOOL plain = argc == 4 && !strcmp(argv[1], "--set");
        if (argc != 4 || (strcmp(argv[1], "--switch") && !plain) ||
            (strcmp(argv[2], "b") && strcmp(argv[2], "c")) ||
            (strcmp(argv[3], "0") && strcmp(argv[3], "1") && strcmp(argv[3], "2"))) {
            report(@"Usage: power-modes-helper --status | --switch {b|c} {0|1|2} | --set {b|c} {0|1|2}"); return 2;
        }
        if (plain) {
            // Profile of the power source not in use: nothing on screen changes, so no brightness lock.
            if (geteuid() != 0) { report(@"Power-mode changes must run as root"); return 1; }
            return runPmset([NSString stringWithUTF8String:argv[2]], [NSString stringWithUTF8String:argv[3]]) ? 0 : 1;
        }
        struct sigaction action = {0}; action.sa_handler = onSignal;
        sigaction(SIGTERM, &action, NULL); sigaction(SIGINT, &action, NULL); sigaction(SIGHUP, &action, NULL);
        signal(SIGPIPE, SIG_IGN);
        char resolved[PATH_MAX];
        if (!realpath(argv[0], resolved)) { report(@"Cannot resolve executable path"); return 1; }
        return switchMode([NSString stringWithUTF8String:resolved], [NSString stringWithUTF8String:argv[2]], [NSString stringWithUTF8String:argv[3]]);
    }
}
