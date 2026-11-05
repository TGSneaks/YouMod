// CommentTimestamps.x
// Reads the signed-in user's own comment on the current video in the background and
// offers its timestamps as seek targets. Comments are never shown on screen.
#import "Headers.h"

extern NSString *YouModGlobalAuthHeader;

static NSString *const YMCTEndpoint = @"https://www.youtube.com/youtubei/v1/next?prettyPrint=false";
static NSString *const YMCTButtonID = @"timestamps.video";
static NSString *const YMCTCommentPanelID = @"comment-item-section";
static const NSInteger YMCTMaxAuthWaits = 4;
static const NSTimeInterval YMCTAuthWaitDelay = 3.0;
static const NSUInteger YMCTDebugAuthorLimit = 3;

@interface YMCommentTimestamp : NSObject
@property (nonatomic, assign) NSInteger seconds;
@property (nonatomic, copy) NSString *label;
@end

@implementation YMCommentTimestamp
@end

static NSMutableDictionary<NSString *, NSArray<YMCommentTimestamp *> *> *ymctCache;
static NSMutableSet<NSString *> *ymctLoading;
static NSString *ymctRequestAuthHeader;
static NSString *ymctDebugInfo;

static NSString *YMCTAuthHeader(void) {
    @synchronized ([YMCommentTimestamp class]) {
        return ymctRequestAuthHeader ?: YouModGlobalAuthHeader;
    }
}

static NSString *YMCTFormatTime(NSInteger seconds) {
    NSInteger hours = seconds / 3600;
    NSInteger minutes = (seconds % 3600) / 60;
    NSInteger remainder = seconds % 60;
    if (hours > 0) return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)hours, (long)minutes, (long)remainder];
    return [NSString stringWithFormat:@"%ld:%02ld", (long)minutes, (long)remainder];
}

static NSInteger YMCTGroupValue(NSTextCheckingResult *match, NSUInteger group, NSString *text) {
    NSRange range = [match rangeAtIndex:group];
    return range.location == NSNotFound ? 0 : [[text substringWithRange:range] integerValue];
}

// A label runs from the end of its timestamp to the next timestamp or the end of the line.
static NSString *YMCTLabel(NSString *text, NSUInteger start, NSUInteger limit) {
    NSString *tail = [text substringWithRange:NSMakeRange(start, limit - start)];
    NSRange lineEnd = [tail rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]];
    if (lineEnd.location != NSNotFound) tail = [tail substringToIndex:lineEnd.location];
    NSMutableCharacterSet *edges = [NSMutableCharacterSet whitespaceAndNewlineCharacterSet];
    [edges addCharactersInString:@"-–—:|,"];
    return [tail stringByTrimmingCharactersInSet:edges];
}

static NSArray<YMCommentTimestamp *> *YMCTParse(NSString *text) {
    static NSRegularExpression *pattern;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pattern = [NSRegularExpression regularExpressionWithPattern:@"(?<![\\d:])(?:(\\d{1,2}):)?(\\d{1,3}):(\\d{2})(?![\\d:])" options:0 error:nil];
    });
    NSArray<NSTextCheckingResult *> *matches = [pattern matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    NSMutableArray<YMCommentTimestamp *> *stamps = [NSMutableArray array];
    for (NSUInteger index = 0; index < matches.count; index++) {
        NSTextCheckingResult *match = matches[index];
        NSInteger seconds = YMCTGroupValue(match, 3, text);
        if (seconds >= 60) continue;
        YMCommentTimestamp *stamp = [YMCommentTimestamp new];
        stamp.seconds = YMCTGroupValue(match, 1, text) * 3600 + YMCTGroupValue(match, 2, text) * 60 + seconds;
        NSUInteger limit = index + 1 < matches.count ? matches[index + 1].range.location : text.length;
        stamp.label = YMCTLabel(text, NSMaxRange(match.range), limit);
        [stamps addObject:stamp];
    }
    return stamps;
}

static NSArray<YMCommentTimestamp *> *YMCTSortedUnique(NSArray<YMCommentTimestamp *> *stamps) {
    NSMutableDictionary<NSNumber *, YMCommentTimestamp *> *bySecond = [NSMutableDictionary dictionary];
    for (YMCommentTimestamp *stamp in stamps) {
        if (!bySecond[@(stamp.seconds)]) bySecond[@(stamp.seconds)] = stamp;
    }
    return [bySecond.allValues sortedArrayUsingComparator:^NSComparisonResult(YMCommentTimestamp *a, YMCommentTimestamp *b) {
        return [@(a.seconds) compare:@(b.seconds)];
    }];
}

static void YMCTPost(NSDictionary *body, void (^completion)(NSDictionary *json, NSInteger status)) {
    NSString *version = [NSBundle mainBundle].infoDictionary[@"CFBundleShortVersionString"] ?: @"21.38.3";
    NSDictionary *client = @{
        @"clientName": @"IOS",
        @"clientVersion": version,
        @"deviceMake": @"Apple",
        @"deviceModel": @"iPhone14,5",
        @"hl": [NSLocale currentLocale].languageCode ?: @"en"
    };
    NSMutableDictionary *payload = [body mutableCopy];
    payload[@"context"] = @{@"client": client};

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:YMCTEndpoint]];
    request.HTTPMethod = @"POST";
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"5" forHTTPHeaderField:@"X-YouTube-Client-Name"];
    [request setValue:version forHTTPHeaderField:@"X-YouTube-Client-Version"];
    [request setValue:[NSString stringWithFormat:@"com.google.ios.youtube/%@ (iPhone14,5; U; CPU iOS 26_0 like Mac OS X)", version] forHTTPHeaderField:@"User-Agent"];
    NSString *auth = YMCTAuthHeader();
    if (auth) [request setValue:auth forHTTPHeaderField:@"Authorization"];

    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            completion([json isKindOfClass:[NSDictionary class]] ? json : nil, status);
        });
    }] resume];
}

static NSString *YMCTCommentContinuation(NSDictionary *watchResponse) {
    for (NSDictionary *panel in watchResponse[@"engagementPanels"]) {
        NSDictionary *section = panel[@"engagementPanelSectionListRenderer"];
        if (![section[@"panelIdentifier"] isEqual:YMCTCommentPanelID]) continue;
        NSArray *continuations = section[@"content"][@"sectionListRenderer"][@"continuations"];
        NSString *token = [continuations.firstObject valueForKeyPath:@"reloadContinuationData.continuation"];
        if ([token isKindOfClass:[NSString class]]) return token;
    }
    return nil;
}

static NSArray<NSDictionary *> *YMCTComments(NSDictionary *response) {
    NSMutableArray<NSDictionary *> *comments = [NSMutableArray array];
    for (NSDictionary *mutation in response[@"frameworkUpdates"][@"entityBatchUpdate"][@"mutations"]) {
        NSDictionary *comment = mutation[@"payload"][@"commentEntityPayload"];
        if (comment) [comments addObject:comment];
    }
    return comments;
}

static void YMCTFinish(NSString *videoID, NSString *debug, NSArray<YMCommentTimestamp *> *stamps) {
    [ymctLoading removeObject:videoID];
    ymctDebugInfo = debug;
    if (stamps) ymctCache[videoID] = stamps;
}

static void YMCTReadComments(NSString *videoID, NSString *token, NSString *prefix) {
    YMCTPost(@{@"continuation": token}, ^(NSDictionary *json, NSInteger status) {
        NSArray<NSDictionary *> *comments = YMCTComments(json);
        NSMutableArray<YMCommentTimestamp *> *stamps = [NSMutableArray array];
        NSMutableArray<NSString *> *authors = [NSMutableArray array];
        NSInteger mine = 0;
        for (NSDictionary *comment in comments) {
            BOOL isMine = [comment[@"author"][@"isCurrentUser"] boolValue];
            if (authors.count < YMCTDebugAuthorLimit) {
                [authors addObject:[NSString stringWithFormat:@"%@=%@", comment[@"author"][@"displayName"], isMine ? @"me" : @"other"]];
            }
            if (!isMine) continue;
            mine++;
            NSString *text = comment[@"properties"][@"content"][@"content"];
            if ([text isKindOfClass:[NSString class]]) [stamps addObjectsFromArray:YMCTParse(text)];
        }
        NSArray<YMCommentTimestamp *> *unique = YMCTSortedUnique(stamps);
        NSString *debug = [NSString stringWithFormat:@"%@ comments_http=%ld comments=%lu mine=%ld timestamps=%lu first=%@", prefix, (long)status, (unsigned long)comments.count, (long)mine, (unsigned long)unique.count, [authors componentsJoinedByString:@", "]];
        YMCTFinish(videoID, debug, status == 200 ? unique : nil);
    });
}

static void YMCTLoad(NSString *videoID, NSInteger authWaits) {
    if (!IS_ENABLED(CommentTimestamps) || videoID.length == 0 || ymctCache[videoID]) return;
    if (authWaits == 0 && [ymctLoading containsObject:videoID]) return;
    [ymctLoading addObject:videoID];

    if (!YMCTAuthHeader()) {
        if (authWaits >= YMCTMaxAuthWaits) {
            YMCTFinish(videoID, [NSString stringWithFormat:@"video=%@ no sign-in header captured", videoID], nil);
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(YMCTAuthWaitDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            YMCTLoad(videoID, authWaits + 1);
        });
        return;
    }

    YMCTPost(@{@"videoId": videoID}, ^(NSDictionary *json, NSInteger status) {
        NSString *token = YMCTCommentContinuation(json);
        NSString *prefix = [NSString stringWithFormat:@"video=%@ auth=yes watch_http=%ld token=%lu", videoID, (long)status, (unsigned long)token.length];
        if (!token) {
            YMCTFinish(videoID, prefix, nil);
            return;
        }
        YMCTReadComments(videoID, token, prefix);
    });
}

static NSArray<YMCommentTimestamp *> *YMCTStampsForPlayer(YTPlayerViewController *player) {
    NSString *videoID = player.currentVideoID;
    return videoID ? ymctCache[videoID] : nil;
}

static void YMCTShowList(YTPlayerViewController *player, UIView *sender) {
    NSArray<YMCommentTimestamp *> *stamps = YMCTStampsForPlayer(player);
    if (stamps.count == 0) return;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:LOC(@"MY_TIMESTAMPS") message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    __weak YTPlayerViewController *weakPlayer = player;
    for (YMCommentTimestamp *stamp in stamps) {
        NSString *time = YMCTFormatTime(stamp.seconds);
        NSString *title = stamp.label.length > 0 ? [NSString stringWithFormat:@"%@  %@", time, stamp.label] : time;
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [weakPlayer seekToTime:(CGFloat)stamp.seconds];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:LOC(@"CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = sender;
    sheet.popoverPresentationController.sourceRect = sender.bounds;

    UIViewController *presenter = sender.window.rootViewController ?: player;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    [presenter presentViewController:sheet animated:YES completion:nil];
}

void YMCopyTimestampDebugInfo(void) {
    [UIPasteboard generalPasteboard].string = ymctDebugInfo ?: [NSString stringWithFormat:@"no video read yet, auth=%@", YMCTAuthHeader() ? @"yes" : @"no"];
}

// YouTube's own API requests carry the signed-in account's header.
%hook NSMutableURLRequest
- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    %orig;
    if ([field caseInsensitiveCompare:@"Authorization"] != NSOrderedSame || ![value hasPrefix:@"Bearer "]) return;
    if (![self.URL.host containsString:@"youtube"]) return;
    @synchronized ([YMCommentTimestamp class]) {
        ymctRequestAuthHeader = [value copy];
    }
}
%end

%hook YTPlayerViewController
- (void)playbackController:(id)playbackController didActivateVideo:(id)video withPlaybackData:(id)playbackData {
    %orig;
    if (self.isPlayingAd || [self.parentViewController isKindOfClass:%c(YTShortsPlayerViewController)]) return;
    YMCTLoad(self.currentVideoID, 0);
}
%end

%ctor {
    ymctCache = [NSMutableDictionary dictionary];
    ymctLoading = [NSMutableSet set];
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{CommentTimestamps: @YES}];
    %init;

    YMOverlayButtonSpec *button = [[YMOverlayButtonSpec alloc] init];
    button.identifier = YMCTButtonID;
    button.symbolName = @"bookmark.fill";
    button.settingsSymbolName = @"bookmark.fill";
    button.displayName = LOC(@"TIMESTAMPS_BUTTON");
    button.tintColor = [UIColor whiteColor];
    button.sortOrder = 850;
    button.isVisible = ^BOOL(YTPlayerViewController *player) {
        return IS_ENABLED(CommentTimestamps) && YMIsOverlayButtonEnabled(YMCTButtonID) && YMCTStampsForPlayer(player).count > 0;
    };
    button.onTap = ^(YTPlayerViewController *player, YTQTMButton *sender) {
        YMCTShowList(player, sender);
    };
    YMRegisterOverlayButton(button);
}
