/**
 * @file main-objc.mm
 * @brief Standalone application for the native Metal presentation bootstrap.
 *
 * $LicenseInfo:firstyear=2026&license=viewerlgpl$
 * Phoenix Firestorm Viewer Source Code
 * Copyright (C) 2026, Firestorm Viewer Project
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation;
 * version 2.1 of the License only.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA
 * $/LicenseInfo$
 */

#import <AppKit/AppKit.h>
#import <CoreFoundation/CoreFoundation.h>

#include "llmetalbootstrap.h"

#include <chrono>
#include <iostream>
#include <memory>
#include <string>
#include <thread>

@interface NSView (LLMetalBootstrapSelfTest)

- (void)simulateDrawableUnavailableOnceForSelfTest;

@end

namespace
{

struct Options
{
    bool self_test = false;
    bool self_test_drawable_retry = false;
    bool help = false;
    std::string metallib_path;
};

bool parseOptions(int argc, const char* argv[], Options& options, std::string& error)
{
    for (int index = 1; index < argc; ++index)
    {
        const std::string argument = argv[index];
        if (argument == "--self-test")
        {
            options.self_test = true;
        }
        else if (argument == "--self-test-drawable-retry")
        {
            options.self_test = true;
            options.self_test_drawable_retry = true;
        }
        else if (argument == "--help" || argument == "-h")
        {
            options.help = true;
        }
        else if (argument == "--metallib")
        {
            if (++index >= argc)
            {
                error = "--metallib requires a path";
                return false;
            }
            options.metallib_path = argv[index];
        }
        else
        {
            error = "unknown option: " + argument;
            return false;
        }
    }

    return true;
}

std::string bundledMetallibPath()
{
    NSURL* url = [[NSBundle mainBundle]
        URLForResource:@"bootstrap"
        withExtension:@"metallib"];
    if (!url.fileSystemRepresentation)
    {
        return {};
    }

    return url.fileSystemRepresentation;
}

void printUsage(const char* executable)
{
    std::cout << "Usage: " << executable
              << " [--self-test | --self-test-drawable-retry] [--metallib PATH]\n"
              << "\n"
              << "Without --self-test, opens an event-driven Metal window.\n"
              << "The self-test waits for command completion and drawable presentation.\n"
              << "The drawable-retry test also verifies one bounded transient retry.\n";
}

void installMainMenu()
{
    NSMenu* main_menu = [[NSMenu alloc] initWithTitle:@"Main menu"];
    NSMenuItem* application_item = [[NSMenuItem alloc] init];
    [main_menu addItem:application_item];

    NSMenu* application_menu = [[NSMenu alloc] initWithTitle:@"Firestorm Metal Bootstrap"];
    NSMenuItem* quit_item = [[NSMenuItem alloc]
        initWithTitle:@"Quit Firestorm Metal Bootstrap"
               action:@selector(terminate:)
        keyEquivalent:@"q"];
    [application_menu addItem:quit_item];
    application_item.submenu = application_menu;
    NSApp.mainMenu = main_menu;
}

} // namespace

@interface LLMetalBootstrapAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>

@property(nonatomic, strong) NSWindow* window;

@end

@implementation LLMetalBootstrapAppDelegate

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender
{
    (void)sender;
    return YES;
}

@end

namespace
{

std::unique_ptr<firestorm::metal::LLMetalBootstrap> createBootstrap(
    const Options& options,
    std::string& error)
{
    const std::string metallib_path = options.metallib_path.empty()
        ? bundledMetallibPath()
        : options.metallib_path;
    if (metallib_path.empty())
    {
        error = "could not find bootstrap.metallib in the application bundle";
        return {};
    }

    return firestorm::metal::LLMetalBootstrap::create(metallib_path, error);
}

NSWindow* createWindow(void* native_view)
{
    constexpr NSWindowStyleMask style =
        NSWindowStyleMaskTitled |
        NSWindowStyleMaskClosable |
        NSWindowStyleMaskMiniaturizable |
        NSWindowStyleMaskResizable;

    NSWindow* window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0.0, 0.0, 960.0, 600.0)
                  styleMask:style
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window.title = @"Firestorm Metal Bootstrap";
    window.restorable = NO;
    window.releasedWhenClosed = NO;
    window.minSize = NSMakeSize(320.0, 200.0);
    window.contentView = (__bridge NSView*)native_view;
    [window center];
    return window;
}

int runSelfTest(
    NSWindow* window,
    firestorm::metal::LLMetalBootstrap& bootstrap,
    bool test_drawable_retry)
{
    [window orderFrontRegardless];
    [window displayIfNeeded];

    std::string error;
    if (bootstrap.submittedFrameCount() == 0)
    {
        const auto submission = bootstrap.drawFrame(&error);
        if (submission != firestorm::metal::FrameSubmission::submitted)
        {
            std::cerr << "self-test frame was " << firestorm::metal::toString(submission);
            if (!error.empty())
            {
                std::cerr << ": " << error;
            }
            std::cerr << '\n';
            return 1;
        }
    }

    if (!bootstrap.waitForIdle(std::chrono::seconds(5), &error))
    {
        std::cerr << "self-test failed: " << error << '\n';
        return 1;
    }

    if (!bootstrap.waitForPresent(std::chrono::seconds(5), &error))
    {
        std::cerr << "self-test failed: " << error << '\n';
        return 1;
    }

    auto background_submission = firestorm::metal::FrameSubmission::submitted;
    std::string background_error;
    std::thread background_draw([&] {
        @autoreleasepool
        {
            background_submission = bootstrap.drawFrame(&background_error);
        }
    });
    background_draw.join();
    if (background_submission != firestorm::metal::FrameSubmission::failed ||
        background_error != "Metal frames must be submitted on the AppKit main thread")
    {
        std::cerr << "self-test failed: off-main draw was not rejected\n";
        return 1;
    }

    std::cout << "Self-test: submitted " << bootstrap.submittedFrameCount()
              << ", completed " << bootstrap.completedFrameCount()
              << ", presented " << bootstrap.presentedFrameCount() << " frame\n";

    if (test_drawable_retry)
    {
        const std::uint64_t submitted_before_retry = bootstrap.submittedFrameCount();
        NSView* native_view = (__bridge NSView*)bootstrap.nativeView();
        if (![native_view respondsToSelector:
                @selector(simulateDrawableUnavailableOnceForSelfTest)])
        {
            std::cerr << "drawable-retry self-test failed: view lacks the test hook\n";
            return 1;
        }
        [native_view simulateDrawableUnavailableOnceForSelfTest];
        [native_view updateLayer];
        if (bootstrap.submittedFrameCount() != submitted_before_retry)
        {
            std::cerr << "drawable-retry self-test failed: transient miss submitted\n";
            return 1;
        }

        NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
        while (bootstrap.submittedFrameCount() == submitted_before_retry &&
               deadline.timeIntervalSinceNow > 0.0)
        {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
            [native_view displayIfNeeded];
        }

        if (bootstrap.submittedFrameCount() != submitted_before_retry + 1)
        {
            std::cerr << "drawable-retry self-test failed: expected exactly one retry\n";
            return 1;
        }

        if (!bootstrap.waitForIdle(std::chrono::seconds(5), &error) ||
            !bootstrap.waitForPresent(std::chrono::seconds(5), &error))
        {
            std::cerr << "drawable-retry self-test failed: " << error << '\n';
            return 1;
        }

        std::cout << "Drawable retry self-test: submitted "
                  << bootstrap.submittedFrameCount()
                  << ", completed " << bootstrap.completedFrameCount()
                  << ", presented " << bootstrap.presentedFrameCount()
                  << "; one transient miss, one presented retry\n";
    }

    [window close];
    return 0;
}

} // namespace

int main(int argc, const char* argv[])
{
    @autoreleasepool
    {
        Options options;
        std::string error;
        if (!parseOptions(argc, argv, options, error))
        {
            std::cerr << error << '\n';
            printUsage(argv[0]);
            return 2;
        }

        if (options.help)
        {
            printUsage(argv[0]);
            return 0;
        }

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:options.self_test
            ? NSApplicationActivationPolicyAccessory
            : NSApplicationActivationPolicyRegular];
        installMainMenu();

        LLMetalBootstrapAppDelegate* delegate =
            [[LLMetalBootstrapAppDelegate alloc] init];
        NSApp.delegate = delegate;
        [NSApp finishLaunching];

        auto bootstrap = createBootstrap(options, error);
        if (!bootstrap)
        {
            std::cerr << "Metal bootstrap initialization failed: " << error << '\n';
            return 1;
        }

        std::cout << bootstrap->capabilityReport() << '\n';

        NSWindow* window = createWindow(bootstrap->nativeView());
        window.delegate = delegate;
        delegate.window = window;

        if (options.self_test)
        {
            return runSelfTest(
                window,
                *bootstrap,
                options.self_test_drawable_retry);
        }

        [window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        bootstrap->requestFrame();
        [NSApp run];
        return 0;
    }
}
