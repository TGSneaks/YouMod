// OnlyMyComments.x
// Keeps the comments panel but removes every comment not written by the handle set in settings.
#import <objc/runtime.h>
#import "Headers.h"

static const NSInteger OMCMaxAttempts = 4;
static const NSUInteger OMCDebugLimit = 8;
static const NSUInteger OMCDebugTextLimit = 300;
static const NSInteger OMCMaxCollapsedCells = 60;
static const void *OMCCollapsedCountKey = &OMCCollapsedCountKey;

static NSMutableArray<NSString *> *omcDebugEntries;

static NSString *OMCHandle(void) {
    NSString *handle = [[NSUserDefaults standardUserDefaults] stringForKey:MyCommentHandle];
    handle = [handle stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (handle.length == 0) return nil;
    return [handle hasPrefix:@"@"] ? handle : [@"@" stringByAppendingString:handle];
}

static void OMCAppendNodeText(id node, NSMutableString *text, NSInteger depth) {
    if (!node || depth > 12) return;
    if ([NSStringFromClass([node class]) containsString:@"TextNode"]) {
        @try {
            NSAttributedString *attributed = [node valueForKey:@"_attributedText"];
            if (attributed.string.length > 0) [text appendFormat:@"%@\n", attributed.string];
        } @catch (NSException *exception) {}
    }
    if (![node isKindOfClass:%c(ASDisplayNode)]) return;
    for (id child in [((ASDisplayNode *)node).yogaChildren copy]) {
        OMCAppendNodeText(child, text, depth + 1);
    }
}

static NSString *OMCCellText(UIView *cell) {
    NSMutableString *text = [NSMutableString string];
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:cell];
    Class asDisplayClass = %c(_ASDisplayView);
    while (queue.count > 0) {
        UIView *current = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (current.accessibilityLabel.length > 0) [text appendFormat:@"%@\n", current.accessibilityLabel];
        if ([current isKindOfClass:asDisplayClass]) {
            OMCAppendNodeText([current performSelector:@selector(keepalive_node)], text, 0);
        }
        [queue addObjectsFromArray:current.subviews];
    }
    return text;
}

static void OMCRecordDebugEntry(NSString *text, BOOL isMine) {
    if (!omcDebugEntries) omcDebugEntries = [NSMutableArray array];
    NSString *trimmed = text.length > OMCDebugTextLimit ? [text substringToIndex:OMCDebugTextLimit] : text;
    [omcDebugEntries addObject:[NSString stringWithFormat:@"[%@] %@", isMine ? @"mine" : @"hidden", trimmed]];
    if (omcDebugEntries.count > OMCDebugLimit) [omcDebugEntries removeObjectAtIndex:0];
}

static void OMCRemoveCell(UIView *cell) {
    cell.hidden = YES;
    _ASCollectionViewCell *mainView = (_ASCollectionViewCell *)cell.superview;
    while (mainView != nil && ![mainView isKindOfClass:%c(_ASCollectionViewCell)]) {
        mainView = (_ASCollectionViewCell *)mainView.superview;
    }
    ASDisplayNode *node = mainView.node;
    for (id child in [node.yogaChildren copy]) {
        [node removeYogaChild:child];
    }
    [node setNeedsLayout];
}

// Collapsed rows pull the next page into view, so each list stops collapsing at a limit. Rows past it stay invisible at full height, which stops the paging.
static BOOL OMCCanCollapseCell(UIView *cell) {
    UIView *list = cell.superview;
    while (list != nil && ![list isKindOfClass:[UICollectionView class]]) {
        list = list.superview;
    }
    if (!list) return YES;
    NSInteger count = [objc_getAssociatedObject(list, OMCCollapsedCountKey) integerValue];
    if (count >= OMCMaxCollapsedCells) return NO;
    objc_setAssociatedObject(list, OMCCollapsedCountKey, @(count + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}

// Cells start invisible. Cell contents load after the cell appears, so unreadable cells are retried and then shown.
static void OMCFilterCell(UIView *cell, NSInteger attempt) {
    __weak UIView *weakCell = cell;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * (attempt + 1) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView *strongCell = weakCell;
        NSString *handle = OMCHandle();
        if (!strongCell) return;
        if (!handle || !IS_ENABLED(OnlyMyComments)) {
            strongCell.alpha = 1;
            return;
        }
        NSString *text = OMCCellText(strongCell);
        if (text.length == 0) {
            if (attempt + 1 < OMCMaxAttempts) OMCFilterCell(strongCell, attempt + 1);
            else strongCell.alpha = 1;
            return;
        }
        BOOL isMine = [text rangeOfString:handle options:NSCaseInsensitiveSearch].location != NSNotFound;
        OMCRecordDebugEntry(text, isMine);
        if (isMine) strongCell.alpha = 1;
        else if (OMCCanCollapseCell(strongCell)) OMCRemoveCell(strongCell);
    });
}

void YMPromptForCommentHandle(UIViewController *presenter) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:LOC(@"MY_COMMENT_HANDLE") message:LOC(@"MY_COMMENT_HANDLE_DESC") preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = [[NSUserDefaults standardUserDefaults] stringForKey:MyCommentHandle];
        textField.placeholder = @"@handle";
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:LOC(@"CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:LOC(@"SAVE") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [[NSUserDefaults standardUserDefaults] setObject:weakAlert.textFields.firstObject.text ?: @"" forKey:MyCommentHandle];
    }]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

void YMCopyCommentDebugInfo(void) {
    NSString *entries = [omcDebugEntries componentsJoinedByString:@"\n---\n"];
    [UIPasteboard generalPasteboard].string = [NSString stringWithFormat:@"handle: %@\n%@", OMCHandle() ?: @"(none)", entries ?: @"(no comments seen yet)"];
}

%hook _ASDisplayView
- (void)didMoveToWindow {
    %orig;
    if (self.window && !self.hidden && [self.accessibilityIdentifier isEqualToString:@"id.ui.comment_cell"] && IS_ENABLED(OnlyMyComments) && OMCHandle()) {
        self.alpha = 0;
        OMCFilterCell(self, 0);
    }
}
%end
