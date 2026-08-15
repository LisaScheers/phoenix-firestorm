/**
 * @file llwindowmacosx-objc.mm
 * @brief Definition of functions shared between llwindowmacosx.cpp
 * and llwindowmacosx-objc.mm.
 *
 * $LicenseInfo:firstyear=2006&license=viewerlgpl$
 * Second Life Viewer Source Code
 * Copyright (C) 2010, Linden Research, Inc.
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
 *
 * Linden Research, Inc., 945 Battery Street, San Francisco, CA  94111  USA
 * $/LicenseInfo$
 */

#include <AppKit/AppKit.h>
#include <Cocoa/Cocoa.h>
#include <OpenGL/OpenGL.h>
#include <cmath>
#include <errno.h>
#include "llopenglview-objc.h"
#include "llwindowmacosx-objc.h"
#include "llappdelegate-objc.h"
#if defined(LL_ACTIVE_METAL_VIEWER)
#include "llmetalprogram.h"
#endif

/*
 * These functions are broken out into a separate file because the
 * objective-C typedef for 'BOOL' conflicts with the one in
 * llcommon/stdtypes.h.  This makes it impossible to use the standard
 * linden headers with any objective-C++ source.
 */

int createNSApp(int argc, const char *argv[])
{
    return NSApplicationMain(argc, argv);
}

void setupCocoa()
{
    static bool inited = false;

    if(!inited)
    {
        @autoreleasepool {
            // The following prevents the Cocoa command line parser from trying to open 'unknown' arguements as documents.
            // ie. running './secondlife -set Language fr' would cause a pop-up saying can't open document 'fr'
            // when init'ing the Cocoa App window.
            [[NSUserDefaults standardUserDefaults] setObject:@"NO" forKey:@"NSTreatUnknownArgumentsAsOpen"];
        }

        inited = true;
    }
}

bool copyToPBoard(const unsigned short *str, unsigned int len)
{
    @autoreleasepool {
        NSPasteboard *pboard = [NSPasteboard generalPasteboard];
        [pboard clearContents];

        NSArray *contentsToPaste = [[[NSArray alloc] initWithObjects:[NSString stringWithCharacters:str length:len], nil] autorelease];
        return [pboard writeObjects:contentsToPaste];
    }
}

bool pasteBoardAvailable()
{
    NSArray *classArray = [NSArray arrayWithObject:[NSString class]];
    return [[NSPasteboard generalPasteboard] canReadObjectForClasses:classArray options:[NSDictionary dictionary]];
}

unsigned short *copyFromPBoard()
{
    @autoreleasepool {
        NSPasteboard *pboard = [NSPasteboard generalPasteboard];
        NSArray *classArray = [NSArray arrayWithObject:[NSString class]];
        NSString *str = NULL;
        BOOL ok = [pboard canReadObjectForClasses:classArray options:[NSDictionary dictionary]];
        if (ok)
        {
            NSArray *objToPaste = [pboard readObjectsForClasses:classArray options:[NSDictionary dictionary]];
            str = [objToPaste objectAtIndex:0];
        }
        NSUInteger str_len = [str length];
        unichar* temp = (unichar*)calloc(str_len+1, sizeof(unichar));
        [str getCharacters:temp range:NSMakeRange(0, str_len)];
        return temp;
    }
}

CursorRef createImageCursor(const char *fullpath, int hotspotX, int hotspotY)
{
    NSCursor *cursor = nil;
    @autoreleasepool {
        // extra retain on the NSCursor since we want it to live for the lifetime of the app.
        cursor =
        [[[NSCursor alloc]
          initWithImage:
              [[[NSImage alloc] initWithContentsOfFile:
                    [NSString stringWithUTF8String:fullpath]
               ] autorelease]
          hotSpot:NSMakePoint(hotspotX, hotspotY)
         ] retain];
    }

    return (CursorRef)cursor;
}

void setArrowCursor()
{
    NSCursor *cursor = [NSCursor arrowCursor];
    [NSCursor unhide];
    [cursor set];
}

void setIBeamCursor()
{
    NSCursor *cursor = [NSCursor IBeamCursor];
    [cursor set];
}

void setPointingHandCursor()
{
    NSCursor *cursor = [NSCursor pointingHandCursor];
    [cursor set];
}

void setCopyCursor()
{
    NSCursor *cursor = [NSCursor dragCopyCursor];
    [cursor set];
}

void setCrossCursor()
{
    NSCursor *cursor = [NSCursor crosshairCursor];
    [cursor set];
}

void setNotAllowedCursor()
{
    NSCursor *cursor = [NSCursor operationNotAllowedCursor];
    [cursor set];
}

void hideNSCursor()
{
    [NSCursor hide];
}

void showNSCursor()
{
    [NSCursor unhide];
}

#if LL_DARWIN
// For CGCursorIsVisible no replacement in modern API
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#endif

bool isCGCursorVisible()
{
    return CGCursorIsVisible();
}

#if LL_DARWIN
#pragma clang diagnostic pop
#endif

void hideNSCursorTillMove(bool hide)
{
    [NSCursor setHiddenUntilMouseMoves:hide];
}

// This is currently unused, since we want all our cursors to persist for the life of the app, but I've included it for completeness.
OSErr releaseImageCursor(CursorRef ref)
{
    if( ref != NULL )
    {
        @autoreleasepool {
            NSCursor *cursor = (NSCursor*)ref;
            [cursor autorelease];
        }
    }
    else
    {
        return paramErr;
    }

    return noErr;
}

OSErr setImageCursor(CursorRef ref)
{
    if( ref != NULL )
    {
        @autoreleasepool {
            NSCursor *cursor = (NSCursor*)ref;
            [cursor set];
        }
    }
    else
    {
        return paramErr;
    }

    return noErr;
}

// Now for some unholy juggling between generic pointers and casting them to Obj-C objects!
// Note: things can get a bit hairy from here.  This is not for the faint of heart.

NSWindowRef createNSWindow(int x, int y, int width, int height)
{
    LLNSWindow *window = [[LLNSWindow alloc]initWithContentRect:NSMakeRect(x, y, width, height)
                                                      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
                                                        backing:NSBackingStoreBuffered defer:NO];
    [window makeKeyAndOrderFront:nil];
    [window setAcceptsMouseMovedEvents:TRUE];
    [window setRestorable:FALSE]; // Viewer manages state from own settings
    return window;
}

#if defined(LL_ACTIVE_METAL_VIEWER)
GLViewRef createCocoaInputView(NSWindowRef window)
{
    NSView *content_view = [(LLNSWindow*)window contentView];
    LLOpenGLView *input_view = [[LLOpenGLView alloc]
        initWithFrame:[content_view bounds]
         withSamples:0
            andVsync:NO];
    [input_view setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [(LLNSWindow*)window setContentView:input_view];
    return input_view;
}

void setCocoaMetalWindowContentSize(
    NSWindowRef window_ref, float width, float height)
{
    [(NSWindow*)window_ref setContentSize:NSMakeSize(width, height)];
}

bool prepareCocoaMetalWindow(NSWindowRef window_ref, GLViewRef view_ref)
{
    NSWindow *window = (NSWindow*)window_ref;
    NSView *view = (NSView*)view_ref;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [NSApp activateIgnoringOtherApps:YES];
#pragma clang diagnostic pop
    [window makeKeyAndOrderFront:nil];
    [window orderFrontRegardless];
    [window.contentView layoutSubtreeIfNeeded];
    [window displayIfNeeded];
    [view displayIfNeeded];
    // AppKit publishes the new occlusion state asynchronously after ordering
    // the window. The deferred production path remains occlusion-gated.
    return window.visible && !window.miniaturized;
}

bool resizeCocoaMetalWindow(
    NSWindowRef window_ref, float width_delta, float height_delta)
{
    NSWindow *window = (NSWindow*)window_ref;
    const NSSize content_size = window.contentView.bounds.size;
    const CGFloat width = content_size.width + width_delta;
    const CGFloat height = content_size.height + height_delta;
    if (!std::isfinite(width) || !std::isfinite(height) ||
        width <= 0.0 || height <= 0.0)
    {
        return false;
    }

    [window setContentSize:NSMakeSize(width, height)];
    [window.contentView layoutSubtreeIfNeeded];
    return true;
}

std::string getBundledMetalLibraryPath()
{
    @autoreleasepool
    {
        const std::string_view resource =
            firestorm::metal::metalProgramCatalog().libraryResource;
        NSString *filename = [[[NSString alloc]
            initWithBytes:resource.data()
                   length:resource.size()
                 encoding:NSUTF8StringEncoding] autorelease];
        if (!filename)
        {
            return {};
        }

        NSString *extension = filename.pathExtension;
        NSString *basename = filename.stringByDeletingPathExtension;
        NSURL *url = [[NSBundle mainBundle] URLForResource:basename
                                             withExtension:extension];
        if (!url.isFileURL || !url.fileSystemRepresentation)
        {
            return {};
        }
        return url.fileSystemRepresentation;
    }
}

bool runCocoaInputSelfTest(GLViewRef view_ref, std::string& report)
{
    LLOpenGLView *view = (LLOpenGLView*)view_ref;
    NSMutableArray<NSString*> *checks = [NSMutableArray array];

    const bool no_nsopengl_context = [NSOpenGLContext currentContext] == nil;
    const bool no_cgl_context = CGLGetCurrentContext() == nullptr;
    [checks addObject:(no_nsopengl_context ? @"nsopengl-current=none" : @"nsopengl-current=unexpected")];
    [checks addObject:(no_cgl_context ? @"cgl-current=none" : @"cgl-current=unexpected")];

    const bool responder = [view acceptsFirstResponder] &&
        [view conformsToProtocol:@protocol(NSTextInputClient)];
    [checks addObject:(responder ? @"responder=ok" : @"responder=failed")];

    const bool drag = [[view registeredDraggedTypes]
        containsObject:NSPasteboardTypeURL] &&
        [view respondsToSelector:@selector(draggingEntered:)] &&
        [view respondsToSelector:@selector(performDragOperation:)];
    [checks addObject:(drag ? @"drag=ok" : @"drag=failed")];

    const bool ime = [view respondsToSelector:@selector(setMarkedText:selectedRange:replacementRange:)] &&
        [view respondsToSelector:@selector(insertText:replacementRange:)] &&
        [view respondsToSelector:@selector(firstRectForCharacterRange:actualRange:)];
    [checks addObject:(ime ? @"ime=ok" : @"ime=failed")];

    const NSRange marked_range = [view markedRange];
    const NSRange selected_range = [view selectedRange];
    const bool ime_ranges =
        marked_range.location == NSNotFound && marked_range.length == 0 &&
        selected_range.location == NSNotFound && selected_range.length == 0;
    [checks addObject:(ime_ranges ? @"ime-ranges=empty" : @"ime-ranges=failed")];

    NSEvent *move = [NSEvent mouseEventWithType:NSEventTypeMouseMoved
                                        location:NSMakePoint(16.0, 16.0)
                                   modifierFlags:0
                                       timestamp:0.0
                                    windowNumber:view.window.windowNumber
                                         context:nil
                                     eventNumber:1
                                      clickCount:0
                                        pressure:0.0];
    NSEvent *click = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                         location:NSMakePoint(16.0, 16.0)
                                    modifierFlags:0
                                        timestamp:0.0
                                     windowNumber:view.window.windowNumber
                                          context:nil
                                      eventNumber:2
                                       clickCount:1
                                         pressure:1.0];
    NSEvent *key = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                     location:NSZeroPoint
                                modifierFlags:0
                                    timestamp:0.0
                                 windowNumber:view.window.windowNumber
                                      context:nil
                                   characters:@"a"
                  charactersIgnoringModifiers:@"a"
                                     isARepeat:NO
                                       keyCode:0];
    const bool events = move && click && key;
    if (events)
    {
        [view mouseMoved:move];
        [view mouseDown:click];
        [view keyDown:key];
        [view insertText:@"x" replacementRange:NSMakeRange(NSNotFound, 0)];
    }
    [checks addObject:(events ? @"events=sent" : @"events=failed")];

    NSView *metal_view = view.subviews.lastObject;
    const bool routing = metal_view && [metal_view hitTest:NSMakePoint(1.0, 1.0)] == nil;
    [checks addObject:(routing ? @"metal-hit-test=transparent" : @"metal-hit-test=failed")];

    const bool no_nsopengl_context_after = [NSOpenGLContext currentContext] == nil;
    const bool no_cgl_context_after = CGLGetCurrentContext() == nullptr;
    [checks addObject:(no_nsopengl_context_after ? @"nsopengl-after=none" : @"nsopengl-after=unexpected")];
    [checks addObject:(no_cgl_context_after ? @"cgl-after=none" : @"cgl-after=unexpected")];
    report = [[[checks componentsJoinedByString:@", "] description] UTF8String];
    return no_nsopengl_context && no_cgl_context && responder && drag && ime &&
        ime_ranges && events && routing && no_nsopengl_context_after &&
        no_cgl_context_after;
}
#else
GLViewRef createOpenGLView(NSWindowRef window, unsigned int samples, bool vsync)
{
    LLOpenGLView *glview = [[LLOpenGLView alloc]initWithFrame:[(LLNSWindow*)window frame] withSamples:samples andVsync:vsync];
    [(LLNSWindow*)window setContentView:glview];
    return glview;
}

void glSwapBuffers(void* context)
{
    [(NSOpenGLContext*)context flushBuffer];
}

CGLContextObj getCGLContextObj(GLViewRef view)
{
    return [(LLOpenGLView *)view getCGLContextObj];
}

CGLPixelFormatObj* getCGLPixelFormatObj(NSWindowRef window)
{
    LLOpenGLView *glview = [(LLNSWindow*)window contentView];
    return [glview getCGLPixelFormatObj];
}

unsigned long getVramSize(GLViewRef view)
{
    return [(LLOpenGLView *)view getVramSize];
}
#endif

float getDeviceUnitSize(GLViewRef view)
{
    return [(LLOpenGLView*)view convertSizeToBacking:NSMakeSize(1, 1)].width;
}

CGRect getContentViewRect(NSWindowRef window)
{
    return [[(LLNSWindow*)window contentView] bounds];
}

CGRect getBackingViewRect(NSWindowRef window, GLViewRef view)
{
#if defined(LL_ACTIVE_METAL_VIEWER)
    return [(NSView*)view convertRectToBacking:[[(LLNSWindow*)window contentView] bounds]];
#else
    return [(NSOpenGLView*)view convertRectToBacking:[[(LLNSWindow*)window contentView] bounds]];
#endif
}

void getWindowSize(NSWindowRef window, float* size)
{
    NSRect frame = [(LLNSWindow*)window frame];
    size[0] = frame.origin.x;
    size[1] = frame.origin.y;
    size[2] = frame.size.width;
    size[3] = frame.size.height;
}

void setWindowSize(NSWindowRef window, int width, int height)
{
    NSRect frame = [(LLNSWindow*)window frame];
    frame.size.width = width;
    frame.size.height = height;
    [(LLNSWindow*)window setFrame:frame display:TRUE];
}

void setWindowPos(NSWindowRef window, float* pos)
{
    NSPoint point;
    point.x = pos[0];
    point.y = pos[1];
    [(LLNSWindow*)window setFrameOrigin:point];
}

void getCursorPos(NSWindowRef window, float* pos)
{
    NSPoint mLoc;
    mLoc = [(LLNSWindow*)window mouseLocationOutsideOfEventStream];
    pos[0] = mLoc.x;
    pos[1] = mLoc.y;
}

void makeWindowOrderFront(NSWindowRef window)
{
    [(LLNSWindow*)window makeKeyAndOrderFront:nil];
}

void convertScreenToWindow(NSWindowRef window, float *coord)
{
    NSRect point = NSMakeRect(coord[0], coord[1], 0,0);
    point = [(LLNSWindow*)window convertRectFromScreen:point];
    coord[0] = point.origin.x;
    coord[1] = point.origin.y;
}

void convertRectToScreen(NSWindowRef window, float *coord)
{
    NSRect rect = NSMakeRect(coord[0], coord[1], coord[2], coord[3]);;
    rect = [(LLNSWindow*)window convertRectToScreen:rect];

    coord[0] = rect.origin.x;
    coord[1] = rect.origin.y;
    coord[2] = rect.size.width;
    coord[3] = rect.size.height;
}

void convertRectFromScreen(NSWindowRef window, float *coord)
{
    NSRect point = NSMakeRect(coord[0], coord[1], coord[2], coord[3]);
    point = [(LLNSWindow*)window convertRectFromScreen:point];

    coord[0] = point.origin.x;
    coord[1] = point.origin.y;
    coord[2] = point.size.width;
    coord[3] = point.size.height;
}

void convertWindowToScreen(NSWindowRef window, float *coord)
{
    NSRect rect = NSMakeRect(coord[0], coord[1], 0, 0);
    rect = [(LLNSWindow*)window convertRectToScreen:rect];

      coord[0] = rect.origin.x;
    coord[1] = [[NSScreen screens][0] frame].size.height - rect.origin.y;
}

void closeWindow(NSWindowRef window)
{
    [(LLNSWindow*)window close];
    [(LLNSWindow*)window release];
}

void removeGLView(GLViewRef view)
{
#if !defined(LL_ACTIVE_METAL_VIEWER)
    [(LLOpenGLView*)view clearGLContext];
#endif
    [(LLOpenGLView*)view removeFromSuperview];
}

void setupInputWindow(NSWindowRef window, GLViewRef glview)
{
    [[(LLAppDelegate*)[NSApp delegate] inputView] setGLView:(LLOpenGLView*)glview];
}

void commitCurrentPreedit(GLViewRef glView)
{
    [(LLOpenGLView*)glView commitCurrentPreedit];
}

void allowDirectMarkedTextInput(bool allow, GLViewRef glView)
{
    [(LLOpenGLView*)glView allowMarkedTextInput:allow];
}

NSWindowRef getMainAppWindow()
{
    LLNSWindow *winRef = [(LLAppDelegate*)[[NSApplication sharedApplication] delegate] window];

    [winRef setAcceptsMouseMovedEvents:TRUE];
    return winRef;
}

void makeFirstResponder(NSWindowRef window, GLViewRef view)
{
    [(LLNSWindow*)window makeFirstResponder:(LLOpenGLView*)view];
}

void requestUserAttention()
{
    [[NSApplication sharedApplication] requestUserAttention:NSInformationalRequest];
}

long showAlert(std::string text, std::string title, int type)
{
    long ret = 0;
    @autoreleasepool {
        NSAlert *alert = [[[NSAlert alloc] init] autorelease];

        [alert setMessageText:[NSString stringWithCString:title.c_str() encoding:[NSString defaultCStringEncoding]]];
        [alert setInformativeText:[NSString stringWithCString:text.c_str() encoding:[NSString defaultCStringEncoding]]];
        if (type == 0)
        {
            [alert addButtonWithTitle:@"Okay"];
        } else if (type == 1)
        {
            [alert addButtonWithTitle:@"Okay"];
            [alert addButtonWithTitle:@"Cancel"];
        } else if (type == 2)
        {
            [alert addButtonWithTitle:@"Yes"];
            [alert addButtonWithTitle:@"No"];
        }
        ret = [alert runModal];
    }

    if (ret == NSAlertFirstButtonReturn)
    {
        if (type == 1)
        {
            ret = 3;
        } else if (type == 2)
        {
            ret = 0;
        }
    } else if (ret == NSAlertSecondButtonReturn)
    {
        if (type == 0 || type == 1)
        {
            ret = 2;
        } else if (type == 2)
        {
            ret = 1;
        }
    }

    return ret;
}

/*
 GLViewRef getGLView()
 {
 return [(LLAppDelegate*)[[NSApplication sharedApplication] delegate] glview];
 }
 */

unsigned int getModifiers()
{
    return [NSEvent modifierFlags];
}

// <FS:CR> Set Window Title - sigh.
void setTitleCocoa(NSWindowRef window, const std::string &title)
{
    NSString *str = [NSString stringWithCString:title.c_str() encoding:[NSString defaultCStringEncoding]];
    [(LLNSWindow*)window setTitle:str];
}
// </FS:CR>
