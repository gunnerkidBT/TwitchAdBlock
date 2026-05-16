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
  if (indexPath.section == [self numberOfSectionsInTableView:tableView] - 1 &&
      indexPath.row == [self tableView:tableView numberOfRowsInSection:indexPath.section] - 1) {
    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleDefault
      reuseIdentifier:@"TwitchAdBlockEntry"];
    cell.textLabel.text = @"TwitchMods";
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
  }
  return %orig;
}
%end
