#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <execinfo.h>
#include <signal.h>
#include <stdio.h>
#include <unistd.h>

typedef BOOL (*BoolMessageSend)(id, SEL);
typedef id (*ConfigurationMessageSend)(
    id,
    SEL,
    NSArray *,
    NSUserDefaults *,
    BOOL,
    NSError **);
typedef void (*XCTestMainFunction)(id);

static int fail(const char *message) {
    fprintf(stderr, "xctest-host: %s\n", message);
    return 1;
}

static void print_crash_backtrace(int signal_number) {
    static const char message[] = "xctest-host: test process crashed\n";
    void *frames[64];
    write(STDERR_FILENO, message, sizeof(message) - 1);
    int frame_count = backtrace(frames, 64);
    backtrace_symbols_fd(frames, frame_count, STDERR_FILENO);
    _exit(128 + signal_number);
}

static void install_crash_handlers(void) {
    struct sigaction action = {0};
    action.sa_handler = print_crash_backtrace;
    sigemptyset(&action.sa_mask);
    for (int signal_number = SIGILL; signal_number <= SIGSYS; signal_number++) {
        switch (signal_number) {
            case SIGILL:
            case SIGABRT:
            case SIGBUS:
            case SIGSEGV:
            case SIGSYS:
                sigaction(signal_number, &action, NULL);
                break;
        }
    }
}

static id unavailable_symbol_info(
    id self,
    SEL selector,
    uintptr_t address,
    NSError **error) {
    (void)self;
    (void)selector;
    (void)address;
    if (error) {
        *error = nil;
    }
    return nil;
}

static void disable_process_symbolication(void) {
    Class service = objc_getClass("XCTInProcessSymbolicationService");
    SEL selector = sel_registerName("symbolInfoForAddressInCurrentProcess:error:");
    Method method = service ? class_getInstanceMethod(service, selector) : NULL;
    if (method) {
        method_setImplementation(method, (IMP)unavailable_symbol_info);
    }
}

int main(int argc, char *argv[]) {
    (void)argc;
    (void)argv;
    install_crash_handlers();

    @autoreleasepool {
        void *framework = dlopen(
            "/System/Developer/Library/Frameworks/XCTest.framework/XCTest",
            RTLD_NOW | RTLD_GLOBAL);
        if (!framework) {
            const char *error = dlerror();
            return fail(error ? error : "could not load XCTest");
        }
        disable_process_symbolication();

        Class driver = objc_getClass("XCTestDriver");
        Class helper = objc_getClass("XCTCommandLineToolHelper");
        if (driver == Nil || helper == Nil) {
            return fail("XCTest command-line classes are unavailable");
        }

        BOOL has_environment_configuration =
            ((BoolMessageSend)objc_msgSend)(
                (id)driver,
                sel_registerName("environmentSpecifiesTestConfiguration"));

        id configuration = nil;
        if (!has_environment_configuration) {
            NSError *error = nil;
            configuration = ((ConfigurationMessageSend)objc_msgSend)(
                (id)helper,
                sel_registerName(
                    "configurationFromCommandLineArguments:"
                    "userDefaults:"
                    "requiresTestBundleURL:"
                    "outError:"),
                [[NSProcessInfo processInfo] arguments],
                [NSUserDefaults standardUserDefaults],
                YES,
                &error);
            if (!configuration) {
                const char *description = [[error localizedDescription] UTF8String];
                return fail(description ? description :
                    "could not create XCTest configuration");
            }
        }

        (void)dlerror();
        XCTestMainFunction xctest_main =
            (XCTestMainFunction)dlsym(RTLD_DEFAULT, "_XCTestMain");
        const char *symbol_error = dlerror();
        if (!xctest_main || symbol_error) {
            return fail(symbol_error ? symbol_error :
                "XCTest entry point is unavailable");
        }

        xctest_main(configuration);
        return 0;
    }
}
