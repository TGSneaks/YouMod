// OnlyMyComments.x
// Keeps the comments panel but shows only its first comment, which is where YouTube places the signed-in user's comment.
#import "Headers.h"

static NSString *const OMCCommentCellID = @"id.ui.comment_cell";
static const NSTimeInterval OMCRecheckDelay = 0.3;

static id OMCAncestor(UIView *view, Class type) {
    UIView *current = view.superview;
    while (current != nil && ![current isKindOfClass:type]) {
        current = current.superview;
    }
    return current;
}

static BOOL OMCContainsComment(UIView *root) {
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    while (queue.count > 0) {
        UIView *current = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([current.accessibilityIdentifier isEqualToString:OMCCommentCellID]) return YES;
        [queue addObjectsFromArray:current.subviews];
    }
    return NO;
}

// Rows keep their height and the list stops scrolling, so YouTube never needs to load another page.
static void OMCShowFirstCommentOnly(UICollectionView *list) {
    list.scrollEnabled = NO;
    NSArray<UICollectionViewCell *> *rows = [list.visibleCells sortedArrayUsingComparator:^NSComparisonResult(UICollectionViewCell *a, UICollectionViewCell *b) {
        return [@(a.frame.origin.y) compare:@(b.frame.origin.y)];
    }];
    BOOL foundFirst = NO;
    for (UICollectionViewCell *row in rows) {
        if (foundFirst) {
            row.contentView.alpha = 0;
        } else if (OMCContainsComment(row)) {
            foundFirst = YES;
            row.contentView.alpha = 1;
        }
    }
}

%hook _ASDisplayView
- (void)didMoveToWindow {
    %orig;
    if (!self.window || !IS_ENABLED(OnlyMyComments) || ![self.accessibilityIdentifier isEqualToString:OMCCommentCellID]) return;
    UICollectionViewCell *row = OMCAncestor(self, [UICollectionViewCell class]);
    UICollectionView *list = OMCAncestor(row, [UICollectionView class]);
    if (!list) return;
    row.contentView.alpha = 0;
    __weak UICollectionView *weakList = list;
    dispatch_async(dispatch_get_main_queue(), ^{
        OMCShowFirstCommentOnly(weakList);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(OMCRecheckDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        OMCShowFirstCommentOnly(weakList);
    });
}
%end
