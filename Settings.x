#import <objc/message.h>
#import "Settings.h"
#import "Tweak.h"

%hook _TtC6Twitch25AccountMenuViewController
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
  // automatically. Then we just retitle + add an icon. Falls back to a
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

  // Title — prepended with U+2003 (em-spaces) so the label visibly
  // starts past our leading-edge icon. Twitch's cell adds the title
  // label at the leading edge (no icon slot) and exposes no way to
  // shift it, so we cheat by indenting the string itself. Em-spaces
  // scale with the font size so the relative gap is stable across
  // dynamic-type adjustments. Tweak the em-space count if alignment
  // is off — each "U+2003" = roughly one capital-letter width.
  NSString *paddedTitle = @"  TwitchMods";
  SEL configSel = NSSelectorFromString(@"configureWithTitle:");
  if ([cell respondsToSelector:configSel]) {
    ((void (*)(id, SEL, NSString *))objc_msgSend)(cell, configSel, paddedTitle);
  } else {
    cell.textLabel.text = paddedTitle;
  }

  // Add (or reuse) our leading icon. Tagged so cell reuse doesn't
  // double-add it on subsequent calls.
  static const NSInteger kTWABIconTag = 0x7AB10C0;
  UIImageView *icon = [cell.contentView viewWithTag:kTWABIconTag];
  if (!icon) {
    icon = [[UIImageView alloc] init];
    icon.tag = kTWABIconTag;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.tintColor = UIColor.labelColor;
    [cell.contentView addSubview:icon];
    [NSLayoutConstraint activateConstraints:@[
      [icon.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
      [icon.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
      [icon.widthAnchor constraintEqualToConstant:22],
      [icon.heightAnchor constraintEqualToConstant:22],
    ]];
  }
  icon.image = [UIImage systemImageNamed:@"wrench.and.screwdriver.fill"];

  return cell;
}
%end
