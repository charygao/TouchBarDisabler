//
//  main.c
//  disablerhelper
//
//  Created by Bright on 9/5/17.
//  Copyright © 2017 Bright. All rights reserved.
//

#import <Foundation/Foundation.h>

int main(int argc, const char * argv[]) {
    
    @autoreleasepool {
        NSLog(@"Hello, World!");

        if (argc >= 2)
        {
            setuid(0);  // Here is a key - set user id to 0 - meaning become a root and everything below executes as root.
            
            NSMutableArray *arguments = [[NSMutableArray alloc] init];
            NSString *command = [[NSString alloc] initWithFormat:@"%s", argv[1]];
            
            for (int idx = 2; idx < argc; idx++) {
                NSString *tmp = [[NSString alloc] initWithFormat:@"%s", argv[idx]];
                [arguments addObject:tmp];
            }
            
            NSTask *task = [[NSTask alloc] init];
            [task setLaunchPath:command];
            [task setArguments:arguments];
            
            NSPipe * out = [NSPipe pipe];
            [task setStandardOutput:out];
            [task launch];
            
            [task waitUntilExit];
            
            NSFileHandle * read = [out fileHandleForReading];
            NSData * dataRead = [read readDataToEndOfFile];
            NSString * stringRead = [[NSString alloc] initWithData:dataRead encoding:NSUTF8StringEncoding];
            
            printf("%s", [stringRead UTF8String]);
            
        }
        return 0;
    }
}
