//
//  main.m
//  CloseInnerScreenApp
//
//  Created by weixin on 3/8/19.
//  Copyright © 2019 weixin. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        // 无 storyboard：手动创建并持有 AppDelegate（NSApplication.delegate 是弱引用）
        AppDelegate *delegate = [[AppDelegate alloc] init];
        NSApplication.sharedApplication.delegate = delegate;
        [NSApp run];
    }
    return 0;
}
