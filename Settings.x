#import <objc/message.h>
#import "Settings.h"
#import "Tweak.h"

// Our "TwitchMods" row is one past the end of Twitch's last section. Every
// per-row UITableView method Twitch implements would otherwise receive that
// index path and look it up in its own (shorter) model — a Swift
// index-out-of-range crash as soon as the row scrolls into view (31.7 added
// per-row delegate methods 30.x didn't have). So each per-row method below
// either handles our row itself or hands Twitch the row above ours instead.
// Logos only hooks the ones the class actually implements.
static BOOL twab_isOurRow(UIViewController<UITableViewDataSource> *vc, UITableView *tableView,
                          NSIndexPath *indexPath) {
  NSInteger lastSection = [vc numberOfSectionsInTableView:tableView] - 1;
  return indexPath.section == lastSection &&
         indexPath.row == [vc tableView:tableView numberOfRowsInSection:lastSection] - 1;
}

static NSIndexPath *twab_templateRow(NSIndexPath *ours) {
  return [NSIndexPath indexPathForRow:MAX(ours.row - 1, 0) inSection:ours.section];
}

// Our row borrows a cell that may have no chevron (My Schedule has none). One we add
// is marked and removed in prepareForReuse, before Twitch sets the cell up for its
// next row, so it can't carry over.
static char twab_addedChevronKey;

static void twab_addChevron(UITableViewCell *cell, UITableView *tableView) {
  if (cell.accessoryType != UITableViewCellAccessoryNone || cell.accessoryView) return;
  UIImageView *chevron = nil;
  for (UITableViewCell *other in tableView.visibleCells) {
    if (other == cell || ![other.accessoryView isKindOfClass:UIImageView.class]) continue;
    UIImageView *theirs = (UIImageView *)other.accessoryView;
    if (!theirs.image) continue;
    chevron = [[UIImageView alloc] initWithImage:theirs.image];
    chevron.tintColor = theirs.tintColor;
    chevron.frame = theirs.bounds;
    break;
  }
  if (!chevron) {
    UIImageSymbolConfiguration *size =
        [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightMedium];
    chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right" withConfiguration:size]];
    chevron.tintColor = UIColor.secondaryLabelColor;
    [chevron sizeToFit];
  }
  cell.accessoryView = chevron;
  objc_setAssociatedObject(cell, &twab_addedChevronKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void twab_collectCellContent(UIView *view, NSMutableArray *images, NSMutableArray *labels) {
  for (UIView *sub in view.subviews) {
    if (sub.hidden) continue;
    if ([sub isKindOfClass:UIImageView.class] && ((UIImageView *)sub).image) [images addObject:sub];
    if ([sub isKindOfClass:UILabel.class] && ((UILabel *)sub).text.length) [labels addObject:sub];
    twab_collectCellContent(sub, images, labels);
  }
}

// Keep the borrowed row exactly as Twitch built it and swap what it shows: its
// leftmost icon, its first label, and no subtitle. Twitch sets these again when it
// reuses the cell. Returns NO if the row doesn't have both.
static BOOL twab_restyleBorrowedCell(UITableViewCell *cell, UIImage *image, NSString *title) {
  [cell layoutIfNeeded];
  NSMutableArray<UIImageView *> *images = [NSMutableArray array];
  NSMutableArray<UILabel *> *labels = [NSMutableArray array];
  twab_collectCellContent(cell.contentView, images, labels);
  UIImageView *icon = nil;
  for (UIImageView *candidate in images) {
    if (!icon || [candidate convertRect:candidate.bounds toView:cell].origin.x < [icon convertRect:icon.bounds toView:cell].origin.x)
      icon = candidate;
  }
  if (!icon || !labels.count) return NO;
  icon.image = image;
  labels.firstObject.text = title;
  for (NSUInteger i = 1; i < labels.count; i++) labels[i].text = nil;
  return YES;
}

%hook _TtC6Twitch19SimpleTableViewCell
- (void)prepareForReuse {
  UITableViewCell *cell = (UITableViewCell *)self;
  if (objc_getAssociatedObject(cell, &twab_addedChevronKey)) {
    objc_setAssociatedObject(cell, &twab_addedChevronKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    cell.accessoryView = nil;
  }
  %orig;
}
%end

%hook _TtC6Twitch25AccountMenuViewController
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
  if (twab_isOurRow((id)self, tableView, indexPath)) return %orig(tableView, twab_templateRow(indexPath));
  return %orig;
}
- (CGFloat)tableView:(UITableView *)tableView estimatedHeightForRowAtIndexPath:(NSIndexPath *)indexPath {
  if (twab_isOurRow((id)self, tableView, indexPath)) return %orig(tableView, twab_templateRow(indexPath));
  return %orig;
}
- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell
    forRowAtIndexPath:(NSIndexPath *)indexPath {
  if (twab_isOurRow((id)self, tableView, indexPath)) return;  // no analytics impression for our row
  %orig;
}
- (void)tableView:(UITableView *)tableView didEndDisplayingCell:(UITableViewCell *)cell
    forRowAtIndexPath:(NSIndexPath *)indexPath {
  if (twab_isOurRow((id)self, tableView, indexPath)) return;
  %orig;
}
- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
  if (twab_isOurRow((id)self, tableView, indexPath)) return YES;
  return %orig;
}
- (void)tableView:(UITableView *)tableView didHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
  if (twab_isOurRow((id)self, tableView, indexPath)) return;
  %orig;
}
- (void)tableView:(UITableView *)tableView didUnhighlightRowAtIndexPath:(NSIndexPath *)indexPath {
  if (twab_isOurRow((id)self, tableView, indexPath)) return;
  %orig;
}
- (NSIndexPath *)tableView:(UITableView *)tableView willSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  if (twab_isOurRow((id)self, tableView, indexPath)) return indexPath;
  return %orig;
}
- (NSInteger)tableView:(UITableView *)tableView indentationLevelForRowAtIndexPath:(NSIndexPath *)indexPath {
  if (twab_isOurRow((id)self, tableView, indexPath)) return 0;
  return %orig;
}
- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
  if (twab_isOurRow((id)self, tableView, indexPath)) return NO;
  return %orig;
}
- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
    contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
  if (twab_isOurRow((id)self, tableView, indexPath)) return nil;
  return %orig;
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
  if (twab_isOurRow((id)self, tableView, indexPath)) return nil;
  return %orig;
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
  if (twab_isOurRow((id)self, tableView, indexPath)) return nil;
  return %orig;
}
- (BOOL)tableView:(UITableView *)tableView shouldShowMenuForRowAtIndexPath:(NSIndexPath *)indexPath {
  if (twab_isOurRow((id)self, tableView, indexPath)) return NO;
  return %orig;
}
- (void)tableView:(UITableView *)tableView accessoryButtonTappedForRowWithIndexPath:(NSIndexPath *)indexPath {
  if (twab_isOurRow((id)self, tableView, indexPath)) return;
  %orig;
}
- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath {
  if (twab_isOurRow((id)self, tableView, indexPath)) return NO;
  return %orig;
}
- (BOOL)tableView:(UITableView *)tableView canFocusRowAtIndexPath:(NSIndexPath *)indexPath {
  if (twab_isOurRow((id)self, tableView, indexPath)) return YES;
  return %orig;
}
// UITableViewDataSourcePrefetching: scrolling hands over batches of upcoming
// rows, ours included.
- (void)tableView:(UITableView *)tableView prefetchRowsAtIndexPaths:(NSArray<NSIndexPath *> *)indexPaths {
  NSIndexSet *keep = [indexPaths indexesOfObjectsPassingTest:^BOOL(NSIndexPath *ip, NSUInteger i, BOOL *stop) {
    return !twab_isOurRow((id)self, tableView, ip);
  }];
  if (keep.count) %orig(tableView, [indexPaths objectsAtIndexes:keep]);
}
- (void)tableView:(UITableView *)tableView cancelPrefetchingForRowsAtIndexPaths:(NSArray<NSIndexPath *> *)indexPaths {
  NSIndexSet *keep = [indexPaths indexesOfObjectsPassingTest:^BOOL(NSIndexPath *ip, NSUInteger i, BOOL *stop) {
    return !twab_isOurRow((id)self, tableView, ip);
  }];
  if (keep.count) %orig(tableView, [indexPaths objectsAtIndexes:keep]);
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  if (indexPath.section == [self numberOfSectionsInTableView:tableView] - 1 &&
      indexPath.row == [self tableView:tableView numberOfRowsInSection:indexPath.section] - 1) {
    TWABSettingsVC *vc = [TWABSettingsVC settingsVC];
    return [self.navigationController pushViewController:vc animated:YES];
  }
  %orig;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  NSInteger numberOfRows = %orig;
  if (section == [self numberOfSectionsInTableView:tableView] - 1) numberOfRows++;
  return numberOfRows;
}
- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  NSInteger lastSection = [self numberOfSectionsInTableView:tableView] - 1;
  NSInteger ourRow = [self tableView:tableView numberOfRowsInSection:lastSection] - 1;
  if (indexPath.section != lastSection || indexPath.row != ourRow) return %orig;

  // Borrow a real Twitch-styled cell from the row above ours so we
  // inherit the private nested AccountMenuViewController.Cell class —
  // that gets us bold title, themed chevron, themed background, all
  // automatically. Then we just retitle + set its icon. Falls back to a
  // direct allocation if borrowing fails (e.g., we're the only row).
  //
  // Why not UIListContentConfiguration on a fresh cell instead: setting
  // cell.contentConfiguration in Twitch's tableview crashes the settings
  // VC — confirmed twice. Twitch's tableview presumably has a delegate
  // override that doesn't expect arbitrary cells. Borrowing keeps the
  // cell entirely within Twitch's expected universe.
  UITableViewCell *cell = nil;
  if (ourRow >= 1) {
    NSIndexPath *template = [NSIndexPath indexPathForRow:ourRow - 1 inSection:lastSection];
    cell = %orig(tableView, template);
  }
  if (!cell) {
    Class cls = NSClassFromString(@"_TtC6Twitch34ConfigurableAccessoryTableViewCell") ?:
                NSClassFromString(@"_TtC6Twitch19SimpleTableViewCell");
    cell = cls ? [[cls alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"TWABMenuEntry"]
               : [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"TWABMenuEntry"];
  }

  // Only a cell that couldn't be restyled is configured from scratch, because
  // configureWithTitle: clears the row's icon and shifts its text.
  UIImage *wrench = [[UIImage systemImageNamed:@"wrench.and.screwdriver.fill"]
      imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
  if (!twab_restyleBorrowedCell(cell, wrench, @"TwitchMods")) {
    SEL configSel = NSSelectorFromString(@"configureWithTitle:");
    if ([cell respondsToSelector:configSel]) {
      ((void (*)(id, SEL, NSString *))objc_msgSend)(cell, configSel, @"TwitchMods");
    } else {
      cell.textLabel.text = @"TwitchMods";
    }
    cell.imageView.image = wrench;
  }
  twab_addChevron(cell, tableView);

  return cell;
}
%end
