// PlaylistSort.x
// Adds a sort button to playlist pages that lists every video in the playlist by view count.
#import <objc/message.h>
#import <objc/runtime.h>
#import "Headers.h"

extern NSString *YMCTCurrentAuthHeader(void);

static NSString *const YMPSEndpoint = @"https://www.youtube.com/youtubei/v1/browse?prettyPrint=false";
static const NSInteger YMPSButtonTag = 9950;
static const CGFloat YMPSButtonSize = 40.0;
static const NSInteger YMPSMaxPages = 30;
static const NSInteger YMPSScanDepth = 2;
static const void *YMPSPlaylistKey = &YMPSPlaylistKey;

static NSString *ymPSDebugInfo;

#pragma mark - Finding the open playlist

static id YMPSSend(id object, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!object || ![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

// Playlist pages are opened with a browse endpoint whose ID is "VL" + the playlist ID.
static NSString *YMPSPlaylistIDFromObject(id object) {
    if (!object || ![NSStringFromClass([object class]) hasPrefix:@"YTI"]) return nil;
    id endpoint = [NSStringFromClass([object class]) containsString:@"BrowseEndpoint"] ? object : YMPSSend(object, @"browseEndpoint");
    NSString *browseID = YMPSSend(endpoint, @"browseId");
    if (![browseID isKindOfClass:[NSString class]] || ![browseID hasPrefix:@"VL"] || browseID.length < 4) return nil;
    return [browseID substringFromIndex:2];
}

static NSString *YMPSPlaylistIDInController(UIViewController *controller) {
    for (NSString *name in @[@"navEndpoint", @"navigationEndpoint", @"browseEndpoint", @"endpoint"]) {
        NSString *found = YMPSPlaylistIDFromObject(YMPSSend(controller, name));
        if (found) return found;
    }
    for (Class cls = [controller class]; cls && cls != [UIViewController class]; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        NSString *found = nil;
        for (unsigned int i = 0; i < count && !found; i++) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (!type || type[0] != '@') continue;
            found = YMPSPlaylistIDFromObject(object_getIvar(controller, ivars[i]));
        }
        free(ivars);
        if (found) return found;
    }
    return nil;
}

static NSString *YMPSPlaylistIDInTree(UIViewController *controller, NSInteger depth, NSMutableArray<NSString *> *visited) {
    if (!controller || depth > YMPSScanDepth) return nil;
    [visited addObject:NSStringFromClass([controller class])];
    NSString *found = YMPSPlaylistIDInController(controller);
    if (found) return found;
    NSArray<UIViewController *> *children = [controller isKindOfClass:[UINavigationController class]]
        ? @[((UINavigationController *)controller).topViewController ?: controller]
        : controller.childViewControllers;
    for (UIViewController *child in children) {
        if (child == controller) continue;
        found = YMPSPlaylistIDInTree(child, depth + 1, visited);
        if (found) return found;
    }
    return nil;
}

// Checks the view controllers above the navigation buttons, and the page shown by any navigation controller among them.
static NSString *YMPSPlaylistIDForView(UIView *view) {
    NSMutableArray<NSString *> *visited = [NSMutableArray array];
    NSString *found = nil;
    for (UIResponder *responder = view.nextResponder; responder && !found; responder = responder.nextResponder) {
        if (![responder isKindOfClass:[UIViewController class]]) continue;
        UIViewController *controller = (UIViewController *)responder;
        found = YMPSPlaylistIDInController(controller);
        if (!found && [controller isKindOfClass:[UINavigationController class]]) {
            found = YMPSPlaylistIDInTree(((UINavigationController *)controller).topViewController, 0, visited);
        }
        [visited addObject:NSStringFromClass([controller class])];
    }
    ymPSDebugInfo = [NSString stringWithFormat:@"playlist=%@ checked=%@", found ?: @"none", [visited componentsJoinedByString:@","]];
    return found;
}

static UIViewController *YMPSPageController(UIView *view) {
    for (UIResponder *responder = view.nextResponder; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:[UINavigationController class]]) {
            return ((UINavigationController *)responder).topViewController;
        }
    }
    for (UIResponder *responder = view.nextResponder; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:[UIViewController class]]) return (UIViewController *)responder;
    }
    return nil;
}

// Scans once per page; the answer is stored on the page's view controller.
static NSString *YMPSCachedPlaylistID(UIView *view) {
    UIViewController *page = YMPSPageController(view);
    if (!page) return nil;
    id cached = objc_getAssociatedObject(page, YMPSPlaylistKey);
    if (cached) return [cached isKindOfClass:[NSString class]] ? cached : nil;
    NSString *found = YMPSPlaylistIDForView(view);
    objc_setAssociatedObject(page, YMPSPlaylistKey, found ?: [NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return found;
}

#pragma mark - Reading the playlist

static void YMPSCollect(id node, NSString *key, NSMutableArray *found, NSInteger depth) {
    if (depth > 60) return;
    if ([node isKindOfClass:[NSDictionary class]]) {
        id value = node[key];
        if (value) [found addObject:value];
        for (id child in [node allValues]) YMPSCollect(child, key, found, depth + 1);
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id child in node) YMPSCollect(child, key, found, depth + 1);
    }
}

static NSArray *YMPSAll(id node, NSString *key) {
    NSMutableArray *found = [NSMutableArray array];
    YMPSCollect(node, key, found, 0);
    return found;
}

static long long YMPSParseViews(NSString *label) {
    static NSRegularExpression *pattern;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pattern = [NSRegularExpression regularExpressionWithPattern:@"([\\d.,]+)\\s*(thousand|million|billion)?\\s*views?\\b" options:NSRegularExpressionCaseInsensitive error:nil];
    });
    if (![label isKindOfClass:[NSString class]]) return -1;
    NSTextCheckingResult *match = [pattern firstMatchInString:label options:0 range:NSMakeRange(0, label.length)];
    if (!match) return -1;
    double number = [[[label substringWithRange:[match rangeAtIndex:1]] stringByReplacingOccurrencesOfString:@"," withString:@""] doubleValue];
    NSRange unitRange = [match rangeAtIndex:2];
    NSString *unit = unitRange.location == NSNotFound ? @"" : [[label substringWithRange:unitRange] lowercaseString];
    double scale = [unit isEqualToString:@"thousand"] ? 1e3 : [unit isEqualToString:@"million"] ? 1e6 : [unit isEqualToString:@"billion"] ? 1e9 : 1;
    return (long long)(number * scale);
}

static NSDictionary *YMPSVideo(NSDictionary *data) {
    NSString *videoID = [YMPSAll(data[@"onTap"], @"videoId") firstObject];
    if (![videoID isKindOfClass:[NSString class]]) return nil;
    NSString *title = nil;
    for (id candidate in YMPSAll(data[@"videoData"], @"title")) {
        if ([candidate isKindOfClass:[NSDictionary class]] && [candidate[@"content"] isKindOfClass:[NSString class]]) {
            title = candidate[@"content"];
            break;
        }
    }
    long long views = -1;
    for (NSArray *parts in YMPSAll(data[@"videoData"], @"metadataParts")) {
        if (![parts isKindOfClass:[NSArray class]]) continue;
        for (NSDictionary *part in parts) {
            if (views < 0 && [part isKindOfClass:[NSDictionary class]]) views = YMPSParseViews(part[@"accessibilityLabel"]);
        }
    }
    return @{@"id": videoID, @"title": title ?: videoID, @"views": @(views)};
}

static void YMPSPost(NSDictionary *body, void (^completion)(NSDictionary *json, NSInteger status)) {
    NSString *version = [NSBundle mainBundle].infoDictionary[@"CFBundleShortVersionString"] ?: @"21.38.3";
    NSDictionary *client = @{@"clientName": @"IOS", @"clientVersion": version, @"deviceMake": @"Apple", @"deviceModel": @"iPhone14,5", @"hl": @"en"};
    NSMutableDictionary *payload = [body mutableCopy];
    payload[@"context"] = @{@"client": client};

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:YMPSEndpoint]];
    request.HTTPMethod = @"POST";
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"5" forHTTPHeaderField:@"X-YouTube-Client-Name"];
    [request setValue:version forHTTPHeaderField:@"X-YouTube-Client-Version"];
    NSString *auth = YMCTCurrentAuthHeader();
    if (auth) [request setValue:auth forHTTPHeaderField:@"Authorization"];

    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            completion([json isKindOfClass:[NSDictionary class]] ? json : nil, status);
        });
    }] resume];
}

// Reads page after page, adding each new video, until there are no more pages.
static void YMPSLoadPage(NSDictionary *body, NSMutableArray<NSDictionary *> *videos, NSMutableSet<NSString *> *seen, NSInteger page,
                         void (^progress)(NSUInteger count), void (^completion)(NSArray<NSDictionary *> *videos, NSString *error)) {
    YMPSPost(body, ^(NSDictionary *json, NSInteger status) {
        if (!json) {
            completion(videos, [NSString stringWithFormat:@"YouTube returned an error (%ld)", (long)status]);
            return;
        }
        for (NSDictionary *data in YMPSAll(json, @"videoWithContextData")) {
            NSDictionary *video = [data isKindOfClass:[NSDictionary class]] ? YMPSVideo(data) : nil;
            if (!video || [seen containsObject:video[@"id"]]) continue;
            [seen addObject:video[@"id"]];
            [videos addObject:video];
        }
        progress(videos.count);
        NSDictionary *next = [YMPSAll(json, @"nextContinuationData") firstObject];
        NSString *token = [next isKindOfClass:[NSDictionary class]] ? next[@"continuation"] : nil;
        if (![token isKindOfClass:[NSString class]] || page + 1 >= YMPSMaxPages) {
            completion(videos, nil);
            return;
        }
        YMPSLoadPage(@{@"continuation": token}, videos, seen, page + 1, progress, completion);
    });
}

#pragma mark - The list

static NSString *YMPSFormatViews(long long views) {
    if (views < 0) return @"views unknown";
    if (views >= 1000000000) return [NSString stringWithFormat:@"%.1fB views", views / 1e9];
    if (views >= 1000000) return [NSString stringWithFormat:@"%.1fM views", views / 1e6];
    if (views >= 1000) return [NSString stringWithFormat:@"%.0fK views", views / 1e3];
    return [NSString stringWithFormat:@"%lld views", views];
}

@interface YMPlaylistSortViewController : UITableViewController <UISearchResultsUpdating>
@property (nonatomic, copy) NSString *playlistID;
@property (nonatomic, copy) NSArray<NSDictionary *> *videos;
@property (nonatomic, copy) NSArray<NSDictionary *> *shownVideos;
@property (nonatomic, copy) NSString *query;
@property (nonatomic, copy) NSString *status;
@property (nonatomic, assign) BOOL leastFirst;
@end

@implementation YMPlaylistSortViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.navigationController.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(closeList)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.up.arrow.down"] style:UIBarButtonItemStylePlain target:self action:@selector(flipOrder)];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 60;
    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = LOC(@"PLAYLIST_SEARCH");
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    self.status = LOC(@"PLAYLIST_SORT_LOADING");
    [self refreshTitle];

    __weak typeof(self) weakSelf = self;
    YMPSLoadPage(@{@"browseId": [@"VL" stringByAppendingString:self.playlistID]}, [NSMutableArray array], [NSMutableSet set], 0, ^(NSUInteger count) {
        weakSelf.status = [NSString stringWithFormat:LOC(@"PLAYLIST_SORT_PROGRESS"), (unsigned long)count];
        [weakSelf.tableView reloadData];
    }, ^(NSArray<NSDictionary *> *videos, NSString *error) {
        weakSelf.videos = videos;
        weakSelf.status = error ?: (videos.count == 0 ? LOC(@"PLAYLIST_SORT_EMPTY") : nil);
        ymPSDebugInfo = [NSString stringWithFormat:@"%@ videos=%lu error=%@", ymPSDebugInfo ?: @"", (unsigned long)videos.count, error ?: @"none"];
        [weakSelf sortAndReload];
    });
}

- (void)refreshTitle {
    self.title = self.leastFirst ? LOC(@"PLAYLIST_SORT_LEAST") : LOC(@"PLAYLIST_SORT_MOST");
}

- (void)sortAndReload {
    BOOL leastFirst = self.leastFirst;
    self.videos = [self.videos sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        long long left = [a[@"views"] longLongValue], right = [b[@"views"] longLongValue];
        if (left < 0 || right < 0) return left < 0 && right < 0 ? NSOrderedSame : (left < 0 ? NSOrderedDescending : NSOrderedAscending);
        if (left == right) return NSOrderedSame;
        return ((left < right) == leastFirst) ? NSOrderedAscending : NSOrderedDescending;
    }];
    [self refreshTitle];
    [self applyQuery];
}

// Rank numbers always come from the full sorted list, so a search keeps each video's real place.
- (void)applyQuery {
    NSString *query = [self.query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (query.length == 0) {
        self.shownVideos = self.videos;
    } else {
        NSPredicate *match = [NSPredicate predicateWithBlock:^BOOL(NSDictionary *video, NSDictionary *bindings) {
            return [video[@"title"] localizedCaseInsensitiveContainsString:query];
        }];
        self.shownVideos = [self.videos filteredArrayUsingPredicate:match];
    }
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    self.query = searchController.searchBar.text;
    [self applyQuery];
}

- (void)flipOrder {
    self.leastFirst = !self.leastFirst;
    [self sortAndReload];
}

// The active search bar is presented on top of this list, so the whole sheet is dismissed from below it.
- (void)closeListThen:(void (^)(void))completion {
    UIViewController *presenter = self.navigationController.presentingViewController ?: self.presentingViewController;
    [presenter dismissViewControllerAnimated:YES completion:completion];
}

- (void)closeList {
    [self closeListThen:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (self.status) return 1;
    return self.shownVideos.count > 0 || self.query.length == 0 ? self.shownVideos.count : 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"video"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"video"];
    cell.textLabel.numberOfLines = 2;
    if (self.status) {
        cell.textLabel.text = self.status;
        cell.detailTextLabel.text = nil;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    if (self.shownVideos.count == 0) {
        cell.textLabel.text = LOC(@"PLAYLIST_SEARCH_EMPTY");
        cell.detailTextLabel.text = nil;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    NSDictionary *video = self.shownVideos[indexPath.row];
    NSUInteger rank = [self.videos indexOfObjectIdenticalTo:video] + 1;
    cell.textLabel.text = [NSString stringWithFormat:@"%lu. %@", (unsigned long)rank, video[@"title"]];
    cell.detailTextLabel.text = YMPSFormatViews([video[@"views"] longLongValue]);
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.status || indexPath.row >= (NSInteger)self.shownVideos.count) return;
    NSURL *url = [NSURL URLWithString:[@"youtube://" stringByAppendingString:self.shownVideos[indexPath.row][@"id"]]];
    [self closeListThen:^{
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }];
}

@end

static void YMPSShowList(NSString *playlistID) {
    YMPlaylistSortViewController *list = [[YMPlaylistSortViewController alloc] initWithStyle:UITableViewStylePlain];
    list.playlistID = playlistID;
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:list];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        navigation.sheetPresentationController.detents = @[UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent];
    }
    [[%c(YTUIUtils) topViewControllerForPresenting] presentViewController:navigation animated:YES completion:nil];
}

void YMCopyPlaylistSortDebugInfo(void) {
    [UIPasteboard generalPasteboard].string = ymPSDebugInfo ?: @"no playlist page checked yet";
}

#pragma mark - The button

@interface YTRightNavigationButtons (YMPlaylistSort)
- (void)ymSortPlaylistTapped:(UIButton *)sender;
@end

%hook YTRightNavigationButtons
- (void)layoutSubviews {
    %orig;
    UIButton *button = (UIButton *)[self viewWithTag:YMPSButtonTag];
    NSString *playlistID = IS_ENABLED(PlaylistSortByViews) && self.window ? YMPSCachedPlaylistID(self) : nil;
    if (!playlistID) {
        button.hidden = YES;
        return;
    }
    if (!button) {
        button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tag = YMPSButtonTag;
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightMedium];
        [button setImage:[UIImage systemImageNamed:@"arrow.up.arrow.down" withConfiguration:config] forState:UIControlStateNormal];
        button.tintColor = [UIColor labelColor];
        button.accessibilityLabel = LOC(@"PLAYLIST_SORT_MOST");
        [button addTarget:self action:@selector(ymSortPlaylistTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:button];
    }
    CGFloat leftEdge = CGRectGetWidth(self.bounds);
    CGFloat centerY = CGRectGetMidY(self.bounds);
    for (UIView *subview in self.subviews) {
        if (subview == button || subview.hidden || subview.alpha < 0.01 || CGRectGetWidth(subview.frame) < 1) continue;
        if (CGRectGetMinX(subview.frame) < leftEdge) {
            leftEdge = CGRectGetMinX(subview.frame);
            centerY = CGRectGetMidY(subview.frame);
        }
    }
    button.hidden = NO;
    button.frame = CGRectMake(leftEdge - YMPSButtonSize, centerY - YMPSButtonSize / 2.0, YMPSButtonSize, YMPSButtonSize);
}

// The button sits left of YouTube's buttons, so taps there must count as inside this view.
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (%orig) return YES;
    UIView *button = [self viewWithTag:YMPSButtonTag];
    return button && !button.hidden && CGRectContainsPoint(button.frame, point);
}

%new
- (void)ymSortPlaylistTapped:(UIButton *)sender {
    NSString *playlistID = YMPSCachedPlaylistID(self);
    if (playlistID) YMPSShowList(playlistID);
}
%end

%ctor {
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{PlaylistSortByViews: @YES}];
    %init;
}
