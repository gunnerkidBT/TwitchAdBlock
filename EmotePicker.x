// TwitchAdBlock — chat emote picker for sending 7TV / BTTV / FFZ emotes.
//
// Third-party emotes are plain words in the IRC message — anyone running
// 7TV/BTTV/FFZ (or this tweak) renders them. Twitch's own emote picker only
// knows Twitch emotes, so this adds a "7TV" button next to it in the chat
// input bar. Tapping it opens a searchable grid of the current channel's
// emotes plus globals (from the Emotes.x registry); picking one types its
// name into the chat box.
//
// Hook surface is UIKit-only: we splice our button into the Auto Layout chain
// just before Twitch's ChatInputViewEmoticonButton, and insert text via
// -[UITextView insertText:] so Twitch's textView delegate sees it as normal
// typing (send button / char counter update as usual).

#import <UIKit/UIKit.h>
#import <ImageIO/ImageIO.h>
#import <objc/runtime.h>
#import <os/log.h>
#import "SettingsKeys.h"

extern NSUserDefaults *tweakDefaults;
extern NSArray<NSDictionary *> *twab_pickerEmotes(void);
extern NSURL *twab_pickerImageURL(NSDictionary *emote);

static const NSUInteger TWAB_MAX_RECENT_EMOTES = 24;

// ─── Thumbnail loading ──────────────────────────────────────────────────────

static NSCache<NSURL *, UIImage *> *twab_thumbCache(void) {
    static NSCache *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        c = [NSCache new];
        c.countLimit = 600;
        // Animated thumbnails hold every frame; cap by decoded bytes too.
        c.totalCostLimit = 48 * 1024 * 1024;
    });
    return c;
}

static const CGFloat TWAB_THUMB_MAX_PIXELS = 96;

// Decode emote bytes into a thumbnail. Multi-frame images (GIF — what the CDNs
// serve for animated emotes) become an animated UIImage, which UIImage's own
// imageWithData: doesn't do. Frames are downsampled to thumbnail size so a
// grid full of animated emotes stays light. *cost = decoded bytes.
static UIImage *twab_decodeThumb(NSData *data, NSUInteger *cost) {
    *cost = 0;
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!src) return nil;
    size_t count = CGImageSourceGetCount(src);
    NSDictionary *opts = @{
        (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize: @(TWAB_THUMB_MAX_PIXELS),
    };
    UIImage *result = nil;
    if (count <= 1) {
        CGImageRef cg = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
        if (cg) {
            *cost = CGImageGetBytesPerRow(cg) * CGImageGetHeight(cg);
            result = [UIImage imageWithCGImage:cg scale:2 orientation:UIImageOrientationUp];
            CGImageRelease(cg);
        }
    } else {
        NSMutableArray<UIImage *> *frames = [NSMutableArray arrayWithCapacity:count];
        NSTimeInterval duration = 0;
        for (size_t i = 0; i < count; i++) {
            CGImageRef cg = CGImageSourceCreateThumbnailAtIndex(src, i, (__bridge CFDictionaryRef)opts);
            if (!cg) continue;
            *cost += CGImageGetBytesPerRow(cg) * CGImageGetHeight(cg);
            [frames addObject:[UIImage imageWithCGImage:cg scale:2 orientation:UIImageOrientationUp]];
            CGImageRelease(cg);

            NSDictionary *props = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src, i, NULL));
            NSDictionary *gif = props[(id)kCGImagePropertyGIFDictionary];
            NSNumber *delay = gif[(id)kCGImagePropertyGIFUnclampedDelayTime] ?:
                              gif[(id)kCGImagePropertyGIFDelayTime];
            // Browsers treat tiny delays as 0.1s; match them so emotes run at
            // the speed people expect.
            duration += delay.doubleValue >= 0.02 ? delay.doubleValue : 0.1;
        }
        if (frames.count)
            result = frames.count == 1 ? frames.firstObject
                                       : [UIImage animatedImageWithImages:frames duration:duration];
    }
    CFRelease(src);
    return result;
}

// ─── Picker cell ────────────────────────────────────────────────────────────

@interface TWABEmoteCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) NSURL *imageURL;
@end

@implementation TWABEmoteCell

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _imageView = [UIImageView new];
        _imageView.contentMode = UIViewContentModeScaleAspectFit;
        _imageView.translatesAutoresizingMaskIntoConstraints = NO;
        _nameLabel = [UILabel new];
        _nameLabel.font = [UIFont systemFontOfSize:10];
        _nameLabel.textColor = UIColor.secondaryLabelColor;
        _nameLabel.textAlignment = NSTextAlignmentCenter;
        _nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_imageView];
        [self.contentView addSubview:_nameLabel];
        [NSLayoutConstraint activateConstraints:@[
            [_imageView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4],
            [_imageView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:4],
            [_imageView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-4],
            [_imageView.heightAnchor constraintEqualToConstant:36],
            [_nameLabel.topAnchor constraintEqualToAnchor:_imageView.bottomAnchor constant:2],
            [_nameLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:2],
            [_nameLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-2],
        ]];
        self.contentView.layer.cornerRadius = 8;
    }
    return self;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.contentView.backgroundColor = highlighted ? UIColor.tertiarySystemFillColor : nil;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.imageView.image = nil;
    self.imageURL = nil;
}

- (void)configureWithEmote:(NSDictionary *)emote {
    self.nameLabel.text = emote[@"word"];
    self.accessibilityLabel = emote[@"word"];
    self.isAccessibilityElement = YES;
    NSURL *url = twab_pickerImageURL(emote);
    self.imageURL = url;
    if (!url) return;
    UIImage *cached = [twab_thumbCache() objectForKey:url];
    if (cached) {
        self.imageView.image = cached;
        return;
    }
    __weak TWABEmoteCell *weakSelf = self;
    [[NSURLSession.sharedSession dataTaskWithURL:url
                              completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        NSUInteger cost = 0;
        // ImageIO first (handles animated GIF); UIImage as a fallback for
        // anything ImageIO can't open.
        UIImage *img = d ? (twab_decodeThumb(d, &cost) ?: [UIImage imageWithData:d]) : nil;
        if (!img) return;
        [twab_thumbCache() setObject:img forKey:url cost:cost];
        dispatch_async(dispatch_get_main_queue(), ^{
            TWABEmoteCell *cell = weakSelf;
            // Cell may have been reused for another emote while loading.
            if ([cell.imageURL isEqual:url]) cell.imageView.image = img;
        });
    }] resume];
}

@end

// ─── Section header ─────────────────────────────────────────────────────────

@interface TWABEmoteHeader : UICollectionReusableView
@property (nonatomic, strong) UILabel *label;
@end

@implementation TWABEmoteHeader

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _label = [UILabel new];
        _label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        _label.textColor = UIColor.secondaryLabelColor;
        _label.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_label];
        [NSLayoutConstraint activateConstraints:@[
            [_label.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
            [_label.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
            [_label.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        ]];
    }
    return self;
}

@end

// ─── Picker view controller ─────────────────────────────────────────────────

@interface TWABEmotePickerVC : UIViewController <UICollectionViewDataSource,
                                                 UICollectionViewDelegate,
                                                 UISearchBarDelegate>
@property (nonatomic, copy) void (^onPick)(NSString *word);
@end

@implementation TWABEmotePickerVC {
    NSArray<NSDictionary *> *_all;
    NSString *_pendingWord;   // picked emote, inserted once the sheet is gone
    // Parallel arrays: section titles and their emotes. Rebuilt on search.
    NSArray<NSString *> *_titles;
    NSArray<NSArray<NSDictionary *> *> *_sections;
    UISearchBar *_searchBar;
    UICollectionView *_collectionView;
    UILabel *_emptyLabel;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Emotes";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                             target:self action:@selector(close)];

    _searchBar = [UISearchBar new];
    _searchBar.placeholder = @"Search 7TV, BTTV & FFZ emotes";
    _searchBar.searchBarStyle = UISearchBarStyleMinimal;
    _searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    _searchBar.delegate = self;
    _searchBar.translatesAutoresizingMaskIntoConstraints = NO;

    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.itemSize = CGSizeMake(68, 58);
    layout.minimumInteritemSpacing = 2;
    layout.minimumLineSpacing = 4;
    layout.sectionInset = UIEdgeInsetsMake(0, 8, 8, 8);
    layout.headerReferenceSize = CGSizeMake(0, 28);
    _collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    _collectionView.backgroundColor = UIColor.clearColor;
    _collectionView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    _collectionView.dataSource = self;
    _collectionView.delegate = self;
    _collectionView.translatesAutoresizingMaskIntoConstraints = NO;
    [_collectionView registerClass:TWABEmoteCell.class forCellWithReuseIdentifier:@"emote"];
    [_collectionView registerClass:TWABEmoteHeader.class
        forSupplementaryViewOfKind:UICollectionElementKindSectionHeader
               withReuseIdentifier:@"header"];

    _emptyLabel = [UILabel new];
    _emptyLabel.numberOfLines = 0;
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    _emptyLabel.textColor = UIColor.secondaryLabelColor;
    _emptyLabel.font = [UIFont systemFontOfSize:15];
    _emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;

    [self.view addSubview:_searchBar];
    [self.view addSubview:_collectionView];
    [self.view addSubview:_emptyLabel];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_searchBar.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [_searchBar.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:4],
        [_searchBar.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-4],
        [_collectionView.topAnchor constraintEqualToAnchor:_searchBar.bottomAnchor],
        [_collectionView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [_collectionView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [_collectionView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_emptyLabel.topAnchor constraintEqualToAnchor:_searchBar.bottomAnchor constant:40],
        [_emptyLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24],
        [_emptyLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],
    ]];

    _all = twab_pickerEmotes();
    [self rebuildForQuery:nil];
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)rebuildForQuery:(NSString *)query {
    NSMutableArray *titles = [NSMutableArray array];
    NSMutableArray *sections = [NSMutableArray array];
    if (query.length) {
        // Prefix matches first, keeping the channel-then-global order within each.
        NSMutableArray *ordered = [NSMutableArray array];
        NSMutableArray *infix = [NSMutableArray array];
        for (NSDictionary *e in _all) {
            NSRange r = [e[@"word"] rangeOfString:query options:NSCaseInsensitiveSearch];
            if (r.location == 0) [ordered addObject:e];
            else if (r.location != NSNotFound) [infix addObject:e];
        }
        [ordered addObjectsFromArray:infix];
        if (ordered.count) {
            [titles addObject:@"Results"];
            [sections addObject:ordered];
        }
    } else {
        NSMutableDictionary *byWord = [NSMutableDictionary dictionary];
        for (NSDictionary *e in _all) byWord[e[@"word"]] = e;
        NSMutableArray *recent = [NSMutableArray array];
        for (NSString *w in [tweakDefaults arrayForKey:TWABKeyRecentEmotes]) {
            if ([w isKindOfClass:NSString.class] && byWord[w]) [recent addObject:byWord[w]];
        }
        NSArray *channel = [_all filteredArrayUsingPredicate:
            [NSPredicate predicateWithFormat:@"channel == YES"]];
        NSArray *global = [_all filteredArrayUsingPredicate:
            [NSPredicate predicateWithFormat:@"channel == NO"]];
        if (recent.count)  { [titles addObject:@"Recently Used"];  [sections addObject:recent]; }
        if (channel.count) { [titles addObject:@"This Channel"];   [sections addObject:channel]; }
        if (global.count)  { [titles addObject:@"Global"];         [sections addObject:global]; }
    }
    _titles = titles;
    _sections = sections;
    [_collectionView reloadData];

    if (!_all.count) {
        _emptyLabel.text = [tweakDefaults boolForKey:TWABKeyEmotesEnabled]
            ? @"No 7TV, BTTV or FFZ emotes loaded yet.\nWait for chat to connect, then try again."
            : @"3rd-Party Emotes are turned off in TwitchAdBlock settings.";
    } else {
        _emptyLabel.text = sections.count ? nil : @"No emotes match your search.";
    }
    _emptyLabel.hidden = _emptyLabel.text == nil;
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    [self rebuildForQuery:[searchText stringByTrimmingCharactersInSet:
                              NSCharacterSet.whitespaceCharacterSet]];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)cv {
    return _sections.count;
}

- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)section {
    return _sections[section].count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)cv
                  cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    TWABEmoteCell *cell = [cv dequeueReusableCellWithReuseIdentifier:@"emote" forIndexPath:indexPath];
    [cell configureWithEmote:_sections[indexPath.section][indexPath.item]];
    return cell;
}

- (UICollectionReusableView *)collectionView:(UICollectionView *)cv
           viewForSupplementaryElementOfKind:(NSString *)kind
                                 atIndexPath:(NSIndexPath *)indexPath {
    TWABEmoteHeader *h = [cv dequeueReusableSupplementaryViewOfKind:kind
                                                withReuseIdentifier:@"header"
                                                       forIndexPath:indexPath];
    h.label.text = _titles[indexPath.section];
    return h;
}

- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    NSString *word = _sections[indexPath.section][indexPath.item][@"word"];
    if (!word.length) return;

    NSMutableArray *recent = [[tweakDefaults arrayForKey:TWABKeyRecentEmotes] mutableCopy]
                             ?: [NSMutableArray array];
    [recent removeObject:word];
    [recent insertObject:word atIndex:0];
    while (recent.count > TWAB_MAX_RECENT_EMOTES) [recent removeLastObject];
    [tweakDefaults setObject:recent forKey:TWABKeyRecentEmotes];

    os_log(OS_LOG_DEFAULT, "[TWAB-Picker] picked \"%{public}@\"", word);
    // Inserted from viewDidDisappear: rather than the dismiss completion,
    // which doesn't always run (e.g. the sheet is swiped away mid-dismiss).
    _pendingWord = word;
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    NSString *word = _pendingWord;
    _pendingWord = nil;
    if (word && self.onPick) self.onPick(word);
}

@end

// ─── Chat input integration ─────────────────────────────────────────────────

static UIView *twab_findSubview(UIView *root, BOOL (^match)(UIView *), NSUInteger depth) {
    if (!root || depth > 12) return nil;
    for (UIView *v in root.subviews) {
        if (match(v)) return v;
        UIView *found = twab_findSubview(v, match, depth + 1);
        if (found) return found;
    }
    return nil;
}

static void twab_collectTextInputs(UIView *root, NSMutableArray<UIView *> *out, NSUInteger depth) {
    if (!root || depth > 14) return;
    for (UIView *v in root.subviews) {
        if ([v isKindOfClass:UITextView.class] || [v isKindOfClass:UITextField.class]) [out addObject:v];
        twab_collectTextInputs(v, out, depth + 1);
    }
}

static BOOL twab_isUsableTextInput(UIView *v) {
    if (!v.window || v.hidden || v.alpha < 0.01 || CGRectIsEmpty(v.bounds)) return NO;
    for (UIView *p = v.superview; p; p = p.superview)
        if (p.hidden || p.alpha < 0.01) return NO;
    if ([v isKindOfClass:UITextView.class]) return ((UITextView *)v).isEditable;
    return ((UITextField *)v).isEnabled;
}

// The chat box: the focused text input under ChatInputView, else the visible
// editable one with the widest frame. The input bar holds more than one text
// view (hidden / non-editable ones too), so "first UITextView found" can be
// the wrong one.
static UIView<UITextInput> *twab_chatTextInput(UIView *chatInput) {
    NSMutableArray<UIView *> *all = [NSMutableArray array];
    twab_collectTextInputs(chatInput, all, 0);
    UIView *best = nil;
    for (UIView *v in all) {
        if (v.isFirstResponder) return (UIView<UITextInput> *)v;
        if (!twab_isUsableTextInput(v)) continue;
        if (!best || v.bounds.size.width > best.bounds.size.width) best = v;
    }
    return (UIView<UITextInput> *)best;
}

static NSString *twab_textOf(UIView *v) {
    if ([v isKindOfClass:UITextView.class]) return ((UITextView *)v).text ?: @"";
    if ([v isKindOfClass:UITextField.class]) return ((UITextField *)v).text ?: @"";
    return @"";
}

static void twab_logTextInputs(UIView *chatInput) {
    NSMutableArray<UIView *> *all = [NSMutableArray array];
    twab_collectTextInputs(chatInput, all, 0);
    for (UIView *v in all) {
        os_log(OS_LOG_DEFAULT, "[TWAB-Picker]   input %{public}@ %{public}@ usable=%d focused=%d text=\"%{public}@\"",
               NSStringFromClass(v.class), NSStringFromCGRect(v.frame),
               twab_isUsableTextInput(v), v.isFirstResponder, twab_textOf(v));
    }
}

// Type the emote name at the cursor, padded with spaces so it's a separate
// word (emotes only match whole space-delimited words). `target` is the chat
// box captured when the picker opened; re-resolved if it's gone.
static void twab_insertEmoteWord(UIView *chatInput, UIView<UITextInput> *target, NSString *word) {
    UIView<UITextInput> *input = (target.window ? target : nil) ?: twab_chatTextInput(chatInput);
    if (!input) {
        os_log_error(OS_LOG_DEFAULT, "[TWAB-Picker] chat text input not found");
        twab_logTextInputs(chatInput);
        return;
    }
    if (!input.isFirstResponder) [input becomeFirstResponder];
    NSString *before = twab_textOf(input);
    UITextRange *sel = input.selectedTextRange;
    NSUInteger cursor = sel ? (NSUInteger)[input offsetFromPosition:input.beginningOfDocument
                                                         toPosition:sel.start]
                            : before.length;
    if (cursor > before.length) cursor = before.length;
    BOOL needsLeadingSpace = cursor > 0 &&
        ![NSCharacterSet.whitespaceAndNewlineCharacterSet
            characterIsMember:[before characterAtIndex:cursor - 1]];
    [input insertText:[NSString stringWithFormat:@"%@%@ ", needsLeadingSpace ? @" " : @"", word]];
    NSString *after = twab_textOf(input);
    os_log(OS_LOG_DEFAULT, "[TWAB-Picker] inserted \"%{public}@\" into %{public}@ (focused=%d): \"%{public}@\" -> \"%{public}@\"",
           word, NSStringFromClass(input.class), input.isFirstResponder, before, after);
    if ([after isEqualToString:before]) twab_logTextInputs(chatInput);
}

static UIViewController *twab_presenterForView(UIView *view) {
    UIResponder *r = view;
    while (r && ![r isKindOfClass:UIViewController.class]) r = r.nextResponder;
    UIViewController *vc = (UIViewController *)r ?: view.window.rootViewController;
    while (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed)
        vc = vc.presentedViewController;
    return vc;
}

@interface TWABEmotePickerButton : UIButton
@property (nonatomic, weak) UIView *chatInput;
// Zeroed when the button is hidden so the row closes the gap (a hidden view
// still takes up space outside a stack view).
@property (nonatomic, strong) NSLayoutConstraint *widthConstraint;
- (void)openPicker;
@end

// Show the picker sheet; the picked emote is typed into `target` (the chat
// box), falling back to re-finding it under `chatInput` if it went away.
static void twab_presentPicker(UIView *chatInput, UIView<UITextInput> *target) {
    UIViewController *presenter = twab_presenterForView(chatInput ?: target);
    if (!presenter) return;
    os_log(OS_LOG_DEFAULT, "[TWAB-Picker] opening picker; chat box = %{public}@",
           target ? NSStringFromClass(target.class) : @"(none)");
    if (!target && chatInput) twab_logTextInputs(chatInput);

    // Drop the keyboard so the sheet's search field doesn't fight it; the
    // chat box is focused again when an emote is inserted.
    [target resignFirstResponder];

    TWABEmotePickerVC *picker = [TWABEmotePickerVC new];
    __weak UIView *weakInput = chatInput;
    __weak UIView<UITextInput> *weakTarget = target;
    picker.onPick = ^(NSString *word) { twab_insertEmoteWord(weakInput, weakTarget, word); };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:picker];
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sheet = nav.sheetPresentationController;
        sheet.detents = @[ UISheetPresentationControllerDetent.mediumDetent,
                           UISheetPresentationControllerDetent.largeDetent ];
        sheet.prefersGrabberVisible = YES;
    }
    [presenter presentViewController:nav animated:YES completion:nil];
}

@implementation TWABEmotePickerButton

- (void)openPicker {
    // Remember the chat box now, while it's identifiable (focused/visible).
    UIView *chatInput = self.chatInput;
    if (chatInput) twab_presentPicker(chatInput, twab_chatTextInput(chatInput));
}

@end

static char twab_pickerButtonKey;
static char twab_pickerLongPressKey;

// ─── Diagnostics ────────────────────────────────────────────────────────────
// What the installer last saw, shown on the settings Diagnostics screen so a
// missing button can be explained without a device log.

static NSString *twab_pickerStatus = @"chat input never laid out (hook not firing)";
static NSString *twab_pickerChain = @"";

static void twab_setPickerStatus(NSString *status, UIView *emoticon) {
    if ([status isEqualToString:twab_pickerStatus]) return;
    twab_pickerStatus = status;
    NSMutableArray *chain = [NSMutableArray array];
    for (UIView *v = emoticon.superview; v && chain.count < 6; v = v.superview)
        [chain addObject:NSStringFromClass(v.class)];
    twab_pickerChain = [chain componentsJoinedByString:@" → "];
    os_log(OS_LOG_DEFAULT, "[TWAB-Picker] %{public}@ (%{public}@)", status, twab_pickerChain);
}

NSArray<NSString *> *twab_pickerDiagnostics(void) {
    NSMutableArray *a = [NSMutableArray arrayWithObject:twab_pickerStatus];
    if (twab_pickerChain.length) [a addObject:[@"Emote button parents: " stringByAppendingString:twab_pickerChain]];
    return a;
}

// ─── Install ────────────────────────────────────────────────────────────────

static TWABEmotePickerButton *twab_makePickerButton(UIView *chatInput, UIView *emoticon) {
    TWABEmotePickerButton *btn = [TWABEmotePickerButton buttonWithType:UIButtonTypeSystem];
    btn.chatInput = chatInput;
    [btn setTitle:@"7TV" forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightHeavy];
    btn.tintColor = emoticon.tintColor;
    btn.accessibilityLabel = @"7TV, BetterTTV and FrankerFaceZ emotes";
    [btn addTarget:btn action:@selector(openPicker) forControlEvents:UIControlEventTouchUpInside];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    btn.widthConstraint = [btn.widthAnchor constraintEqualToConstant:36];
    btn.widthConstraint.active = YES;
    return btn;
}

// Long-press on Twitch's own emote button also opens our picker. Works no
// matter how the input bar is laid out, so it covers the times the visible
// button can't be placed.
@interface UIView (TWABPicker)
- (void)twab_emoticonLongPress:(UILongPressGestureRecognizer *)g;
@end

@implementation UIView (TWABPicker)
- (void)twab_emoticonLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    TWABEmotePickerButton *btn = objc_getAssociatedObject(self, &twab_pickerButtonKey);
    [btn openPicker];
}
@end

static BOOL twab_isLeadingAttr(NSLayoutAttribute a) {
    return a == NSLayoutAttributeLeading || a == NSLayoutAttributeLeft;
}
static BOOL twab_isTrailingAttr(NSLayoutAttribute a) {
    return a == NSLayoutAttributeTrailing || a == NSLayoutAttributeRight;
}

// The active constraint tying `view`'s leading edge to its left neighbour's
// trailing edge (either way round), searched in the nearest few ancestors.
static NSLayoutConstraint *twab_leadingLinkConstraint(UIView *view, UIView *exclude) {
    NSUInteger depth = 0;
    for (UIView *holder = view.superview; holder && depth < 3; holder = holder.superview, depth++) {
        for (NSLayoutConstraint *c in holder.constraints) {
            if (!c.active || ![c.firstItem isKindOfClass:UIView.class] ||
                ![c.secondItem isKindOfClass:UIView.class]) continue;
            if (c.firstItem == exclude || c.secondItem == exclude) continue;
            if (c.firstItem == view && twab_isLeadingAttr(c.firstAttribute) &&
                twab_isTrailingAttr(c.secondAttribute)) return c;
            if (c.secondItem == view && twab_isLeadingAttr(c.secondAttribute) &&
                twab_isTrailingAttr(c.firstAttribute)) return c;
        }
    }
    return nil;
}

// True if `btn` overlaps a visible sibling control (Twitch re-laid out the
// row under us, e.g. by re-activating its own constraints).
static BOOL twab_buttonOverlapsSibling(UIView *btn) {
    if (CGRectIsEmpty(btn.frame)) return NO;
    for (UIView *v in btn.superview.subviews) {
        if (v == btn || v.hidden || v.alpha < 0.01 || ![v isKindOfClass:UIControl.class]) continue;
        if (CGRectGetWidth(CGRectIntersection(v.frame, btn.frame)) > 4) return YES;
    }
    return NO;
}

// Put our button right before Twitch's emote button by splicing it into the
// Auto Layout chain (30.7: the Bits button's trailing edge is chained to the
// emote button's leading edge), so the neighbours make room. That link only
// exists in some input-bar states — Bits and the emote button share a slot
// otherwise — so until it appears there's no visible button (long-press still
// works). Idempotent; runs after every layout pass.
static void twab_installPickerButton(UIView *chatInput) {
    TWABEmotePickerButton *existing = objc_getAssociatedObject(chatInput, &twab_pickerButtonKey);
    BOOL enabled = [tweakDefaults boolForKey:TWABKeyEmotesEnabled];
    // Settings → "Hide 7TV Bar": no visible button, long-press only.
    BOOL buttonWanted = enabled && ![tweakDefaults boolForKey:TWABKeyHidePickerButton];
    if (existing.superview) {
        CGFloat width = buttonWanted ? 36 : 0;
        if (existing.widthConstraint.constant != width) existing.widthConstraint.constant = width;
        BOOL overlaps = buttonWanted && twab_buttonOverlapsSibling(existing);
        existing.hidden = !buttonWanted || overlaps;
        if (!enabled)
            twab_setPickerStatus(@"off: 3rd-Party Emotes disabled", nil);
        else if (!buttonWanted)
            twab_setPickerStatus(@"button hidden by setting (long-press works)", nil);
        else if (overlaps)
            twab_setPickerStatus(@"hidden: would overlap a Twitch button", nil);
        else
            twab_setPickerStatus(@"installed: button next to emote button", nil);
        return;
    }
    if (!enabled) {
        twab_setPickerStatus(@"off: 3rd-Party Emotes disabled", nil);
        return;
    }

    Class emoticonCls = objc_getClass("_TtC6Twitch27ChatInputViewEmoticonButton");
    if (!emoticonCls) {
        twab_setPickerStatus(@"failed: emote button class missing", nil);
        return;
    }
    UIView *emoticon = twab_findSubview(chatInput, ^BOOL(UIView *v) {
        return [v isKindOfClass:emoticonCls];
    }, 0);
    if (!emoticon || !emoticon.superview) {
        twab_setPickerStatus(@"waiting: emote button not in chat input yet", nil);
        return;
    }

    TWABEmotePickerButton *btn = existing ?: twab_makePickerButton(chatInput, emoticon);
    objc_setAssociatedObject(chatInput, &twab_pickerButtonKey, btn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (!objc_getAssociatedObject(emoticon, &twab_pickerLongPressKey)) {
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
            initWithTarget:chatInput action:@selector(twab_emoticonLongPress:)];
        [emoticon addGestureRecognizer:lp];
        objc_setAssociatedObject(emoticon, &twab_pickerLongPressKey, lp, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // Don't touch Twitch's layout at all while the button is turned off; it
    // gets placed on the first layout pass after the setting is switched back.
    if (!buttonWanted) {
        twab_setPickerStatus(@"button hidden by setting (long-press works)", emoticon);
        return;
    }

    UIStackView *stack = (UIStackView *)emoticon.superview;
    NSUInteger index = [stack isKindOfClass:UIStackView.class]
        ? [stack.arrangedSubviews indexOfObject:emoticon] : NSNotFound;
    if (index != NSNotFound) {
        [stack insertArrangedSubview:btn atIndex:index];
        twab_setPickerStatus(@"installed: in stack view", emoticon);
        return;
    }

    NSLayoutConstraint *link = twab_leadingLinkConstraint(emoticon, btn);
    if (!link) {
        twab_setPickerStatus(@"waiting: no layout link into emote button yet (long-press works)", emoticon);
        return;
    }
    BOOL emoticonIsFirst = link.firstItem == emoticon;
    NSLayoutConstraint *spliced = [NSLayoutConstraint
        constraintWithItem:emoticonIsFirst ? btn : link.firstItem
                 attribute:link.firstAttribute
                 relatedBy:link.relation
                    toItem:emoticonIsFirst ? link.secondItem : btn
                 attribute:link.secondAttribute
                multiplier:link.multiplier
                  constant:link.constant];
    spliced.priority = link.priority;
    [emoticon.superview addSubview:btn];
    link.active = NO;
    [NSLayoutConstraint activateConstraints:@[
        spliced,
        [btn.trailingAnchor constraintEqualToAnchor:emoticon.leadingAnchor],
        [btn.centerYAnchor constraintEqualToAnchor:emoticon.centerYAnchor],
        [btn.heightAnchor constraintEqualToAnchor:emoticon.heightAnchor],
    ]];
    twab_setPickerStatus([NSString stringWithFormat:@"installed: spliced after %@",
                             NSStringFromClass([(emoticonIsFirst ? link.secondItem : link.firstItem) class])],
                         emoticon);
}

%hook _TtC6Twitch13ChatInputView
- (void)layoutSubviews {
    %orig;
    UIView *view = (UIView *)self;
    // Defer so we never mutate the row in the middle of its layout pass.
    dispatch_async(dispatch_get_main_queue(), ^{ twab_installPickerButton(view); });
}
%end

// ─── React Native chat (Twitch 31.x) ────────────────────────────────────────
// The React Native chat's input is twitch_rn_emote_input.TwitchEmoteInputView
// wrapping a UITextView; its emote button is a generic React Native view we
// can't reliably find, and React Native owns (and recycles) the layout. So
// instead of a button in the row, the chat text view gets a slim keyboard
// accessory bar with a 7TV button — independent of React Native's layout, and
// visible exactly while typing. insertText: on that text view goes through its
// delegate (textViewDidChange: → onChangeText), so the chat sees it as typing.

@interface TWABKeyboardBar : UIInputView
@property (nonatomic, weak) UIView<UITextInput> *target;
@end

@implementation TWABKeyboardBar

- (instancetype)init {
    if ((self = [super initWithFrame:CGRectMake(0, 0, UIScreen.mainScreen.bounds.size.width, 40)
                      inputViewStyle:UIInputViewStyleKeyboard])) {
        self.allowsSelfSizing = YES;
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        [btn setTitle:@"7TV" forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightHeavy];
        btn.accessibilityLabel = @"7TV, BetterTTV and FrankerFaceZ emotes";
        btn.translatesAutoresizingMaskIntoConstraints = NO;
        [btn addTarget:self action:@selector(openPicker) forControlEvents:UIControlEventTouchUpInside];
        UILabel *hint = [UILabel new];
        hint.text = @"7TV · BTTV · FFZ emotes";
        hint.font = [UIFont systemFontOfSize:13];
        hint.textColor = UIColor.secondaryLabelColor;
        hint.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:btn];
        [self addSubview:hint];
        [NSLayoutConstraint activateConstraints:@[
            [self.heightAnchor constraintEqualToConstant:40],
            [btn.leadingAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.leadingAnchor constant:12],
            [btn.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [hint.leadingAnchor constraintEqualToAnchor:btn.trailingAnchor constant:8],
            [hint.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        ]];
        // The hint is part of the tap target too.
        [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self
                                                                           action:@selector(openPicker)]];
    }
    return self;
}

- (void)openPicker {
    UIView<UITextInput> *target = self.target;
    if (target) twab_presentPicker(nil, target);
}

@end

static char twab_keyboardBarKey;

// ── Long-press on the React Native chat's emote button ──
// The button is a generic React Native view, so it's found by its
// accessibility label / testID (React Native maps testID to
// accessibilityIdentifier) containing "emote", within the chat input's row.

@interface TWABRNLongPress : NSObject
@property (nonatomic, weak) UIView<UITextInput> *target;
@property (nonatomic, weak) UIView *button;
@end

@implementation TWABRNLongPress
- (void)fired:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    // Cancel React Native's own touch so the button's tap doesn't also fire
    // (opening Twitch's palette under our sheet) when the finger lifts.
    // Toggling a recognizer's `enabled` cancels its in-flight touches.
    for (UIView *v = g.view; v; v = v.superview) {
        for (UIGestureRecognizer *r in v.gestureRecognizers) {
            if (r != g && [NSStringFromClass(r.class) containsString:@"TouchHandler"]) {
                r.enabled = NO;
                r.enabled = YES;
            }
        }
    }
    UIView<UITextInput> *target = self.target;
    if (target) twab_presentPicker(nil, target);
}
@end

static char twab_rnLongPressKey;

static BOOL twab_mentionsEmote(UIView *v) {
    NSString *s = [NSString stringWithFormat:@"%@ %@", v.accessibilityIdentifier ?: @"",
                                                       v.accessibilityLabel ?: @""];
    return [s rangeOfString:@"emote" options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [s rangeOfString:@"emoji" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static UIView *twab_findRNEmoteButton(UIView *root, UIView *exclude, NSUInteger depth) {
    if (!root || depth > 10) return nil;
    for (UIView *v in root.subviews) {
        if (v == exclude || v.hidden) continue;
        CGSize s = v.bounds.size;
        if (twab_mentionsEmote(v) && s.width >= 16 && s.width <= 80 && s.height >= 16 && s.height <= 80)
            return v;
        UIView *found = twab_findRNEmoteButton(v, exclude, depth + 1);
        if (found) return found;
    }
    return nil;
}

// One-time layout dump of the chat input's surroundings, so the button can be
// matched precisely if the label heuristic misses.
static void twab_dumpRNComposer(UIView *v, NSUInteger depth, NSUInteger *budget) {
    if (!v || depth > 8 || *budget == 0) return;
    (*budget)--;
    NSMutableString *line = [NSMutableString string];
    for (NSUInteger i = 0; i < depth; i++) [line appendString:@". "];
    [line appendFormat:@"%@ %@", NSStringFromClass(v.class), NSStringFromCGRect(v.frame)];
    if (v.hidden) [line appendString:@" HIDDEN"];
    if (v.accessibilityIdentifier.length) [line appendFormat:@" id=%@", v.accessibilityIdentifier];
    if (v.accessibilityLabel.length) [line appendFormat:@" ax=\"%@\"", v.accessibilityLabel];
    if (v.gestureRecognizers.count) [line appendFormat:@" gr=%lu", (unsigned long)v.gestureRecognizers.count];
    os_log(OS_LOG_DEFAULT, "[TWAB-RNComposer] %{public}@", line);
    for (UIView *s in v.subviews) twab_dumpRNComposer(s, depth + 1, budget);
}

static void twab_installRNLongPress(UIView *emoteInput, UITextView *tv) {
    // Already attached to a live button for this input? (React Native can
    // recycle the button view, so re-search once it leaves the window.)
    TWABRNLongPress *existing = objc_getAssociatedObject(emoteInput, &twab_rnLongPressKey);
    if (existing.button.window) {
        existing.target = (UIView<UITextInput> *)tv;
        return;
    }
    // Search outward from the input: the emote button sits in the same row.
    UIView *button = nil, *scope = emoteInput;
    for (NSUInteger i = 0; i < 4 && scope.superview && !button; i++) {
        scope = scope.superview;
        button = twab_findRNEmoteButton(scope, emoteInput, 0);
    }
    if (!button) {
        static BOOL dumped;
        if (!dumped && scope) {
            dumped = YES;
            os_log(OS_LOG_DEFAULT, "[TWAB-Picker] React Native emote button not found; dumping chat input row");
            NSUInteger budget = 150;
            twab_dumpRNComposer(scope, 0, &budget);
        }
        return;
    }
    TWABRNLongPress *handler = objc_getAssociatedObject(button, &twab_rnLongPressKey);
    if (handler) {
        handler.target = (UIView<UITextInput> *)tv;
        objc_setAssociatedObject(emoteInput, &twab_rnLongPressKey, handler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    handler = [TWABRNLongPress new];
    handler.target = (UIView<UITextInput> *)tv;
    handler.button = button;
    objc_setAssociatedObject(emoteInput, &twab_rnLongPressKey, handler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:handler action:@selector(fired:)];
    lp.cancelsTouchesInView = YES;
    [button addGestureRecognizer:lp];
    // The recognizer holds its target weakly; keep the handler alive with it.
    objc_setAssociatedObject(button, &twab_rnLongPressKey, handler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(handler, &twab_rnLongPressKey, lp, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    os_log(OS_LOG_DEFAULT, "[TWAB-Picker] React Native emote button long-press attached: %{public}@ id=%{public}@ ax=\"%{public}@\"",
           NSStringFromClass(button.class), button.accessibilityIdentifier ?: @"",
           button.accessibilityLabel ?: @"");
}

static void twab_installKeyboardBar(UIView *emoteInput) {
    UITextView *tv = (UITextView *)twab_findSubview(emoteInput, ^BOOL(UIView *v) {
        return [v isKindOfClass:UITextView.class];
    }, 0);
    if (!tv) return;
    // Hold-the-emote-button works whenever 3rd-party emotes are on — like
    // native chat, "Hide 7TV Bar" only removes the visible bar (or button).
    if ([tweakDefaults boolForKey:TWABKeyEmotesEnabled]) twab_installRNLongPress(emoteInput, tv);
    TWABKeyboardBar *bar = objc_getAssociatedObject(tv, &twab_keyboardBarKey);
    BOOL wanted = [tweakDefaults boolForKey:TWABKeyEmotesEnabled] &&
                  ![tweakDefaults boolForKey:TWABKeyHidePickerButton];
    UIView *current = tv.inputAccessoryView;
    if (wanted) {
        if (current && current != bar) {
            // Twitch set its own accessory; don't clobber it.
            twab_setPickerStatus(@"React Native chat: text view already has a keyboard accessory", nil);
            return;
        }
        if (current == bar && bar) return;
        if (!bar) {
            bar = [TWABKeyboardBar new];
            objc_setAssociatedObject(tv, &twab_keyboardBarKey, bar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        bar.target = (UIView<UITextInput> *)tv;
        tv.inputAccessoryView = bar;
        if (tv.inputAccessoryView != bar) {
            twab_setPickerStatus(@"React Native chat: text view ignores keyboard accessories", nil);
            return;
        }
        if (tv.isFirstResponder) [tv reloadInputViews];
        twab_setPickerStatus(@"installed: React Native chat, 7TV bar above keyboard", nil);
    } else if (current && current == bar) {
        tv.inputAccessoryView = nil;
        if (tv.isFirstResponder) [tv reloadInputViews];
        twab_setPickerStatus(@"React Native chat: 7TV bar off", nil);
    }
}

%hook _TtC21twitch_rn_emote_input20TwitchEmoteInputView
- (void)didMoveToWindow {
    %orig;
    UIView *view = (UIView *)self;
    if (view.window) dispatch_async(dispatch_get_main_queue(), ^{ twab_installKeyboardBar(view); });
}
- (void)layoutSubviews {
    %orig;
    UIView *view = (UIView *)self;
    // Cheap when already installed; also picks up the settings toggle.
    dispatch_async(dispatch_get_main_queue(), ^{ twab_installKeyboardBar(view); });
}
%end
