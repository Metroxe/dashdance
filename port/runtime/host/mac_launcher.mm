// macOS launcher: an AppKit window with the disc, Slippi account, a few settings and
// Play. Vector artwork and motion are Core Animation: an animated gradient backdrop
// with drifting glows, the ring mark drawn in with a stroke animation, staggered
// card entrances. Disc images can be dropped onto the window.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include "mac_launcher.h"
#include "slippi_login.h"

namespace {
void prepare_application() {
  [NSApplication sharedApplication];
  [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
  static bool launched = false;
  if (!launched) { [NSApp finishLaunching]; launched = true; }
  [NSApp activateIgnoringOtherApps:YES];
}
NSColor* rgb(CGFloat r, CGFloat g, CGFloat b, CGFloat a = 1) { return [NSColor colorWithSRGBRed:r green:g blue:b alpha:a]; }
NSImage* symbol(NSString* name, CGFloat size, NSFontWeight weight) {
  NSImage* image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
  return [image imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:size weight:weight]];
}
}  // namespace

// Animated backdrop: gradient shifting hue plus two drifting radial glows (layer-backed).
@interface MUBackdropView : NSView
@end
@implementation MUBackdropView { CAGradientLayer* _gradient; NSArray<CAGradientLayer*>* _orbs; }
- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  self.wantsLayer = YES;
  self.layer.backgroundColor = rgb(0.06, 0.04, 0.12).CGColor;
  _gradient = [CAGradientLayer layer];
  _gradient.colors = @[(id)rgb(0.14, 0.09, 0.34).CGColor, (id)rgb(0.05, 0.03, 0.11).CGColor];
  _gradient.startPoint = CGPointMake(0, 1); _gradient.endPoint = CGPointMake(1, 0);
  [self.layer addSublayer:_gradient];
  NSMutableArray* orbs = [NSMutableArray array];
  for (int i = 0; i < 2; ++i) {
    CAGradientLayer* orb = [CAGradientLayer layer];
    orb.type = kCAGradientLayerRadial;
    orb.colors = i == 0 ? @[(id)rgb(0.45, 0.32, 1.0, 0.5).CGColor, (id)rgb(0.45, 0.32, 1.0, 0).CGColor]
                        : @[(id)rgb(0.20, 0.60, 1.0, 0.35).CGColor, (id)rgb(0.20, 0.60, 1.0, 0).CGColor];
    orb.startPoint = CGPointMake(0.5, 0.5); orb.endPoint = CGPointMake(1, 1);
    [self.layer addSublayer:orb];
    [orbs addObject:orb];
  }
  _orbs = orbs;
  return self;
}
- (BOOL)isFlipped { return YES; }
- (void)layout {
  [super layout];
  [CATransaction begin]; [CATransaction setDisableActions:YES];
  _gradient.frame = self.bounds;
  const CGFloat w = self.bounds.size.width, h = self.bounds.size.height, d = MAX(w, h) * 0.9;
  _orbs[0].bounds = CGRectMake(0, 0, d, d); _orbs[0].position = CGPointMake(w * 0.15, h * 0.10);
  _orbs[1].bounds = CGRectMake(0, 0, d * 0.8, d * 0.8); _orbs[1].position = CGPointMake(w * 0.95, h * 0.9);
  [CATransaction commit];
  if (![_gradient animationForKey:@"shift"]) {
    CABasicAnimation* shift = [CABasicAnimation animationWithKeyPath:@"colors"];
    shift.toValue = @[(id)rgb(0.08, 0.14, 0.38).CGColor, (id)rgb(0.10, 0.03, 0.14).CGColor];
    shift.duration = 9; shift.autoreverses = YES; shift.repeatCount = HUGE_VALF;
    shift.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [_gradient addAnimation:shift forKey:@"shift"];
    for (NSUInteger i = 0; i < _orbs.count; ++i) {
      CABasicAnimation* drift = [CABasicAnimation animationWithKeyPath:@"position"];
      CGPoint from = _orbs[i].position;
      drift.fromValue = [NSValue valueWithPoint:NSPointFromCGPoint(from)];
      drift.toValue = [NSValue valueWithPoint:NSMakePoint(from.x + (i == 0 ? w * 0.25 : -w * 0.2), from.y + (i == 0 ? h * 0.18 : -h * 0.22))];
      drift.duration = 11 + 4 * i; drift.autoreverses = YES; drift.repeatCount = HUGE_VALF;
      drift.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
      [_orbs[i] addAnimation:drift forKey:@"drift"];
    }
  }
}
@end

// Vector logo: ring drawn in with a stroke animation, then core pops in; breathing glow.
@interface MULogoView : NSView
@property(nonatomic) CAShapeLayer* ring;
@property(nonatomic) CAShapeLayer* core;
@property(nonatomic) CAShapeLayer* slash;
@end
@implementation MULogoView
- (instancetype)initWithSize:(CGFloat)size {
  self = [super initWithFrame:NSMakeRect(0, 0, size, size)];
  self.wantsLayer = YES;
  self.translatesAutoresizingMaskIntoConstraints = NO;
  [self.widthAnchor constraintEqualToConstant:size].active = YES;
  [self.heightAnchor constraintEqualToConstant:size].active = YES;
  CGMutablePathRef ring = CGPathCreateMutable();
  CGPathAddArc(ring, nullptr, size * 0.5, size * 0.5, size * 0.35, M_PI_2, M_PI_2 + 2 * M_PI, false);
  self.ring = [CAShapeLayer layer];
  self.ring.path = ring; CGPathRelease(ring);
  self.ring.strokeColor = NSColor.whiteColor.CGColor; self.ring.fillColor = NSColor.clearColor.CGColor;
  self.ring.lineWidth = size * 0.14; self.ring.lineCap = kCALineCapRound; self.ring.strokeEnd = 0;
  CGMutablePathRef core = CGPathCreateMutable();
  CGPathAddArc(core, nullptr, size * 0.5, size * 0.5, size * 0.16, 0, 2 * M_PI, false);
  self.core = [CAShapeLayer layer];
  self.core.path = core; CGPathRelease(core);
  self.core.fillColor = NSColor.whiteColor.CGColor; self.core.opacity = 0;
  self.core.frame = self.bounds;
  CGMutablePathRef cut = CGPathCreateMutable();
  CGPathMoveToPoint(cut, nullptr, size * 0.10, size * 0.44);
  CGPathAddLineToPoint(cut, nullptr, size * 0.90, size * 0.60);
  CGPathAddLineToPoint(cut, nullptr, size * 0.90, size * 0.53);
  CGPathAddLineToPoint(cut, nullptr, size * 0.10, size * 0.37);
  CGPathCloseSubpath(cut);
  self.slash = [CAShapeLayer layer];
  self.slash.path = cut; CGPathRelease(cut);
  self.slash.fillColor = rgb(0.10, 0.07, 0.24).CGColor; self.slash.opacity = 0;
  [self.layer addSublayer:self.ring]; [self.layer addSublayer:self.core]; [self.layer addSublayer:self.slash];
  self.layer.shadowColor = rgb(0.55, 0.45, 1.0).CGColor;
  self.layer.shadowOpacity = 0.6; self.layer.shadowRadius = size * 0.25; self.layer.shadowOffset = CGSizeZero;
  self.layer.masksToBounds = NO;
  return self;
}
- (void)animateIn {
  CABasicAnimation* draw = [CABasicAnimation animationWithKeyPath:@"strokeEnd"];
  draw.fromValue = @0; draw.toValue = @1; draw.duration = 0.9;
  draw.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
  self.ring.strokeEnd = 1;
  [self.ring addAnimation:draw forKey:@"draw"];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.85 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    CABasicAnimation* fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @0; fade.toValue = @1; fade.duration = 0.35;
    self.core.opacity = 1; [self.core addAnimation:fade forKey:@"fade"];
    self.slash.opacity = 1; [self.slash addAnimation:fade forKey:@"fade"];
    CASpringAnimation* pop = [CASpringAnimation animationWithKeyPath:@"transform.scale"];
    pop.fromValue = @0.2; pop.toValue = @1; pop.damping = 9; pop.stiffness = 180; pop.duration = pop.settlingDuration;
    [self.core addAnimation:pop forKey:@"pop"];
  });
  CABasicAnimation* glow = [CABasicAnimation animationWithKeyPath:@"shadowOpacity"];
  glow.fromValue = @0.35; glow.toValue = @0.8; glow.duration = 2.4; glow.autoreverses = YES; glow.repeatCount = HUGE_VALF;
  glow.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
  [self.layer addAnimation:glow forKey:@"glow"];
}
@end

@class MULauncherWindow;
// Content view that accepts a dropped disc image.
@interface MUDropView : NSView
@property(nonatomic, weak) MULauncherWindow* owner;
@end

@interface MULauncherWindow : NSObject <NSWindowDelegate>
@property(nonatomic) host::LauncherSettings* settings;
@property(nonatomic) NSWindow* window;
@property(nonatomic) NSArray<NSView*>* entrance;
@property(nonatomic) MULogoView* logo;
@property(nonatomic) NSTextField* discName;
@property(nonatomic) NSTextField* discHint;
@property(nonatomic) NSButton* playButton;
@property(nonatomic) NSButton* widescreen;
@property(nonatomic) NSButton* online;
@property(nonatomic) NSSlider* sharpness;
@property(nonatomic, copy) NSString* startupError;
@property(nonatomic) NSTextField* accountLabel;
@property(nonatomic) NSImageView* accountIcon;
@property(nonatomic) NSTextField* emailField;
@property(nonatomic) NSSecureTextField* passwordField;
@property(nonatomic) NSButton* signInButton;
@property(nonatomic) NSProgressIndicator* spinner;
@property(nonatomic) NSButton* signOutButton;
@property(nonatomic) NSButton* resetButton;
@property(nonatomic) NSStackView* signInRows;
@property(nonatomic) BOOL busy, closed;
- (void)acceptDroppedDisc:(NSString*)path;
@end

@implementation MUDropView
- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
  return self;
}
- (BOOL)isFlipped { return YES; }
- (NSURL*)discURLIn:(id<NSDraggingInfo>)sender {
  NSArray* urls = [sender.draggingPasteboard readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
  for (NSURL* url in urls) {
    NSString* ext = url.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"iso"] || [ext isEqualToString:@"gcm"]) return url;
  }
  return nil;
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender { return [self discURLIn:sender] ? NSDragOperationCopy : NSDragOperationNone; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
  NSURL* url = [self discURLIn:sender];
  if (!url) return NO;
  [self.owner acceptDroppedDisc:[NSString stringWithUTF8String:url.fileSystemRepresentation]];
  return YES;
}
@end

@implementation MULauncherWindow
- (instancetype)initWithSettings:(host::LauncherSettings*)settings error:(NSString*)error {
  self = [super init];
  self.settings = settings;
  self.startupError = error;
  NSRect frame = NSMakeRect(0, 0, 580, 760);
  self.window = [[NSWindow alloc] initWithContentRect:frame
                                            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskFullSizeContentView
                                              backing:NSBackingStoreBuffered defer:NO];
  self.window.title = @"iSlippi";
  self.window.titlebarAppearsTransparent = YES;
  self.window.titleVisibility = NSWindowTitleHidden;
  self.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
  self.window.backgroundColor = rgb(0.06, 0.04, 0.12);
  self.window.delegate = self;
  [self.window center];

  MUDropView* content = [[MUDropView alloc] initWithFrame:frame];
  content.owner = self;
  self.window.contentView = content;
  MUBackdropView* backdrop = [[MUBackdropView alloc] initWithFrame:frame];
  backdrop.translatesAutoresizingMaskIntoConstraints = NO;
  [content addSubview:backdrop];
  [NSLayoutConstraint activateConstraints:@[
    [backdrop.topAnchor constraintEqualToAnchor:content.topAnchor], [backdrop.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
    [backdrop.leadingAnchor constraintEqualToAnchor:content.leadingAnchor], [backdrop.trailingAnchor constraintEqualToAnchor:content.trailingAnchor]]];

  NSStackView* stack = [[NSStackView alloc] init];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.alignment = NSLayoutAttributeLeading;
  stack.spacing = 14;
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  [content addSubview:stack];
  [NSLayoutConstraint activateConstraints:@[
    [stack.topAnchor constraintEqualToAnchor:content.topAnchor constant:44],
    [stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:36],
    [stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-36]]];

  // Hero: logo left, title and subtitle right
  NSStackView* hero = [[NSStackView alloc] init];
  hero.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  hero.alignment = NSLayoutAttributeCenterY;
  hero.spacing = 18;
  self.logo = [[MULogoView alloc] initWithSize:72];
  NSStackView* titles = [[NSStackView alloc] init];
  titles.orientation = NSUserInterfaceLayoutOrientationVertical;
  titles.alignment = NSLayoutAttributeLeading;
  titles.spacing = 4;
  NSTextField* title = [NSTextField labelWithString:@"iSlippi"];
  title.font = [NSFont systemFontOfSize:36 weight:NSFontWeightBold];
  title.textColor = NSColor.whiteColor;
  NSTextField* subtitle = [NSTextField wrappingLabelWithString:@"Super Smash Bros. Melee with Slippi rollback netplay, native on your Mac."];
  subtitle.font = [NSFont systemFontOfSize:14];
  subtitle.textColor = [NSColor colorWithWhite:1 alpha:0.7];
  [titles addArrangedSubview:title];
  [titles addArrangedSubview:subtitle];
  [hero addArrangedSubview:self.logo];
  [hero addArrangedSubview:titles];
  [stack addArrangedSubview:hero];
  [stack setCustomSpacing:26 afterView:hero];

  NSBox* card = [self card];
  NSStackView* cardStack = [self stackIn:card];
  [cardStack addArrangedSubview:[self caption:@"GAME DISC" symbol:@"opticaldisc"]];
  self.discName = [NSTextField labelWithString:@""];
  self.discName.font = [NSFont systemFontOfSize:17 weight:NSFontWeightSemibold];
  self.discName.textColor = NSColor.whiteColor;
  self.discName.lineBreakMode = NSLineBreakByTruncatingMiddle;
  self.discHint = [NSTextField wrappingLabelWithString:@""];
  self.discHint.font = [NSFont systemFontOfSize:12];
  self.discHint.textColor = [NSColor colorWithWhite:1 alpha:0.6];
  NSButton* choose = [self button:@"Choose Disc Image…" symbol:@"folder" action:@selector(chooseDisc)];
  [cardStack addArrangedSubview:self.discName];
  [cardStack addArrangedSubview:self.discHint];
  [cardStack addArrangedSubview:choose];
  [stack addArrangedSubview:card];

  NSBox* accountCard = [self card];
  NSStackView* accountStack = [self stackIn:accountCard];
  [accountStack addArrangedSubview:[self caption:@"SLIPPI ONLINE ACCOUNT" symbol:@"person.crop.circle"]];
  NSStackView* accountRow = [[NSStackView alloc] init];
  accountRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  accountRow.alignment = NSLayoutAttributeCenterY;
  accountRow.spacing = 8;
  self.accountIcon = [NSImageView imageViewWithImage:symbol(@"checkmark.seal.fill", 18, NSFontWeightSemibold)];
  self.accountIcon.contentTintColor = [NSColor systemGreenColor];
  self.accountIcon.hidden = YES;
  self.accountLabel = [NSTextField wrappingLabelWithString:@""];
  self.accountLabel.font = [NSFont systemFontOfSize:13];
  self.accountLabel.textColor = NSColor.whiteColor;
  [accountRow addArrangedSubview:self.accountIcon];
  [accountRow addArrangedSubview:self.accountLabel];
  [accountStack addArrangedSubview:accountRow];
  self.signInRows = [[NSStackView alloc] init];
  self.signInRows.orientation = NSUserInterfaceLayoutOrientationVertical;
  self.signInRows.alignment = NSLayoutAttributeLeading;
  self.signInRows.spacing = 6;
  NSStackView* fields = [[NSStackView alloc] init];
  fields.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  fields.spacing = 8;
  self.emailField = [[NSTextField alloc] init];
  self.emailField.placeholderString = @"Email";
  self.emailField.bezelStyle = NSTextFieldRoundedBezel;
  self.emailField.controlSize = NSControlSizeLarge;
  self.passwordField = [[NSSecureTextField alloc] init];
  self.passwordField.placeholderString = @"Password";
  self.passwordField.bezelStyle = NSTextFieldRoundedBezel;
  self.passwordField.controlSize = NSControlSizeLarge;
  self.passwordField.target = self; self.passwordField.action = @selector(signIn);
  [self.emailField.widthAnchor constraintEqualToConstant:200].active = YES;
  [self.passwordField.widthAnchor constraintEqualToConstant:150].active = YES;
  self.signInButton = [self button:@"Sign In" symbol:@"person.badge.key" action:@selector(signIn)];
  self.spinner = [[NSProgressIndicator alloc] init];
  self.spinner.style = NSProgressIndicatorStyleSpinning;
  self.spinner.controlSize = NSControlSizeSmall;
  self.spinner.displayedWhenStopped = NO;
  [fields addArrangedSubview:self.emailField];
  [fields addArrangedSubview:self.passwordField];
  [fields addArrangedSubview:self.signInButton];
  [fields addArrangedSubview:self.spinner];
  self.resetButton = [NSButton buttonWithTitle:@"Forgot password · Create an account at slippi.gg" target:self action:@selector(forgotPassword)];
  self.resetButton.bezelStyle = NSBezelStyleInline;
  self.resetButton.bordered = NO;
  self.resetButton.font = [NSFont systemFontOfSize:11];
  self.resetButton.contentTintColor = rgb(0.72, 0.66, 1.0);
  [self.signInRows addArrangedSubview:fields];
  [self.signInRows addArrangedSubview:self.resetButton];
  [accountStack addArrangedSubview:self.signInRows];
  self.signOutButton = [self button:@"Sign Out" symbol:@"rectangle.portrait.and.arrow.right" action:@selector(signOut)];
  [accountStack addArrangedSubview:self.signOutButton];
  [stack addArrangedSubview:accountCard];
  [self refreshAccount];

  NSBox* settingsCard = [self card];
  NSStackView* settingsStack = [self stackIn:settingsCard];
  [settingsStack addArrangedSubview:[self caption:@"PLAY" symbol:@"gamecontroller"]];
  self.widescreen = [NSButton checkboxWithTitle:@"Widescreen (16:9)" target:nil action:nil];
  self.widescreen.state = settings->widescreen ? NSControlStateValueOn : NSControlStateValueOff;
  self.online = [NSButton checkboxWithTitle:@"Slippi Online" target:nil action:nil];
  self.online.state = settings->online ? NSControlStateValueOn : NSControlStateValueOff;
  NSStackView* sharpRow = [[NSStackView alloc] init];
  sharpRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  NSTextField* sharpLabel = [NSTextField labelWithString:@"Sharpen"];
  sharpLabel.textColor = NSColor.whiteColor;
  self.sharpness = [NSSlider sliderWithValue:settings->sharpness minValue:0 maxValue:1 target:nil action:nil];
  [self.sharpness.widthAnchor constraintEqualToConstant:200].active = YES;
  [sharpRow addArrangedSubview:sharpLabel];
  [sharpRow addArrangedSubview:self.sharpness];
  [settingsStack addArrangedSubview:self.widescreen];
  [settingsStack addArrangedSubview:self.online];
  [settingsStack addArrangedSubview:sharpRow];
  [stack addArrangedSubview:settingsCard];

  NSStackView* buttons = [[NSStackView alloc] init];
  buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  buttons.alignment = NSLayoutAttributeCenterY;
  NSTextField* keys = [NSTextField wrappingLabelWithString:@"Keyboard: arrows move · Z attack · X special · C/V jump · Q/W shield · E grab · Return start. GameCube adapters and gamepads work too. Drop a disc image anywhere on this window."];
  keys.font = [NSFont systemFontOfSize:11];
  keys.textColor = [NSColor colorWithWhite:1 alpha:0.5];
  [keys.widthAnchor constraintLessThanOrEqualToConstant:360].active = YES;
  self.playButton = [NSButton buttonWithTitle:@"Play" target:self action:@selector(play)];
  self.playButton.image = symbol(@"play.fill", 14, NSFontWeightBold);
  self.playButton.imagePosition = NSImageLeading;
  self.playButton.bezelStyle = NSBezelStyleRounded;
  self.playButton.bezelColor = [NSColor systemIndigoColor];
  self.playButton.keyEquivalent = @"\r";
  self.playButton.controlSize = NSControlSizeLarge;
  self.playButton.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
  [self.playButton.widthAnchor constraintGreaterThanOrEqualToConstant:120].active = YES;
  [buttons addArrangedSubview:keys];
  [buttons addArrangedSubview:self.playButton];
  [stack addArrangedSubview:buttons];
  [stack setCustomSpacing:22 afterView:settingsCard];
  for (NSView* full in @[card, accountCard, settingsCard, buttons]) [full.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
  [self refreshDisc];

  self.entrance = @[hero, card, accountCard, settingsCard, buttons];
  for (NSView* v in self.entrance) { v.wantsLayer = YES; v.alphaValue = 0; }
  return self;
}
- (void)animateIn {
  [self.logo animateIn];
  NSTimeInterval delay = 0.12;
  for (NSView* v in self.entrance) {
    CABasicAnimation* rise = [CABasicAnimation animationWithKeyPath:@"transform.translation.y"];
    rise.fromValue = @22; rise.toValue = @0; rise.duration = 0.65; rise.beginTime = CACurrentMediaTime() + delay;
    rise.fillMode = kCAFillModeBackwards;
    rise.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.2 :0.9 :0.25 :1.0];
    [v.layer addAnimation:rise forKey:@"rise"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) { ctx.duration = 0.5; v.animator.alphaValue = 1; } completionHandler:nil];
    });
    delay += 0.08;
  }
  self.playButton.wantsLayer = YES;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    CABasicAnimation* breathe = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    breathe.fromValue = @1.0; breathe.toValue = @1.03; breathe.duration = 1.6; breathe.autoreverses = YES; breathe.repeatCount = HUGE_VALF;
    breathe.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    CGRect b = self.playButton.layer.bounds;
    self.playButton.layer.anchorPoint = CGPointMake(0.5, 0.5);
    self.playButton.layer.position = CGPointMake(NSMidX(self.playButton.frame), NSMidY(self.playButton.frame));
    (void)b;
    [self.playButton.layer addAnimation:breathe forKey:@"breathe"];
  });
}
- (NSBox*)card {
  NSBox* box = [[NSBox alloc] init];
  box.boxType = NSBoxCustom;
  box.cornerRadius = 16;
  box.borderWidth = 1;
  box.borderColor = [NSColor colorWithWhite:1 alpha:0.10];
  box.fillColor = [NSColor colorWithWhite:1 alpha:0.07];
  box.contentViewMargins = NSMakeSize(0, 0);
  return box;
}
- (NSStackView*)stackIn:(NSBox*)box {
  NSStackView* s = [[NSStackView alloc] init];
  s.orientation = NSUserInterfaceLayoutOrientationVertical;
  s.alignment = NSLayoutAttributeLeading;
  s.spacing = 8;
  s.translatesAutoresizingMaskIntoConstraints = NO;
  [box.contentView addSubview:s];
  [NSLayoutConstraint activateConstraints:@[
    [s.topAnchor constraintEqualToAnchor:box.contentView.topAnchor constant:16], [s.bottomAnchor constraintEqualToAnchor:box.contentView.bottomAnchor constant:-16],
    [s.leadingAnchor constraintEqualToAnchor:box.contentView.leadingAnchor constant:16], [s.trailingAnchor constraintEqualToAnchor:box.contentView.trailingAnchor constant:-16]]];
  return s;
}
- (NSView*)caption:(NSString*)text symbol:(NSString*)name {
  NSStackView* row = [[NSStackView alloc] init];
  row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  row.spacing = 5;
  NSImageView* icon = [NSImageView imageViewWithImage:symbol(name, 11, NSFontWeightSemibold)];
  icon.contentTintColor = rgb(0.72, 0.66, 1.0);
  NSTextField* l = [NSTextField labelWithString:text];
  l.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
  l.textColor = [NSColor colorWithWhite:1 alpha:0.55];
  [row addArrangedSubview:icon];
  [row addArrangedSubview:l];
  return row;
}
- (NSButton*)button:(NSString*)title symbol:(NSString*)name action:(SEL)action {
  NSButton* b = [NSButton buttonWithTitle:title target:self action:action];
  b.image = symbol(name, 12, NSFontWeightSemibold);
  b.imagePosition = NSImageLeading;
  b.bezelStyle = NSBezelStyleRounded;
  b.controlSize = NSControlSizeLarge;
  return b;
}
- (void)setBusy:(BOOL)busy {
  _busy = busy;
  self.signInButton.enabled = !busy;
  if (busy) [self.spinner startAnimation:nil]; else [self.spinner stopAnimation:nil];
}
- (void)refreshAccount {
  if (!self.settings) return;
  slippi::login::Account account;
  const bool own = slippi::login::read_user_file(self.settings->slippi_dir, account);
  const bool launcher = !own && self.settings->account_from_launcher && !self.settings->account_code.empty();
  if (own) {
    self.settings->account_name = account.display_name; self.settings->account_code = account.connect_code;
    NSMutableAttributedString* text = [[NSMutableAttributedString alloc] initWithString:[NSString stringWithUTF8String:account.display_name.c_str()]
        attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold], NSForegroundColorAttributeName: NSColor.whiteColor}];
    [text appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"  %s", account.connect_code.c_str()]
        attributes:@{NSFontAttributeName: [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightMedium], NSForegroundColorAttributeName: [NSColor colorWithWhite:1 alpha:0.6]}]];
    self.accountLabel.attributedStringValue = text;
    self.accountIcon.hidden = NO;
  } else if (launcher) {
    self.accountLabel.stringValue = [NSString stringWithFormat:@"Using your Slippi Launcher login: %s  (%s). Sign in below to use a different account.",
                                     self.settings->account_name.c_str(), self.settings->account_code.c_str()];
    self.accountIcon.hidden = NO;
  } else {
    self.settings->account_name.clear(); self.settings->account_code.clear();
    self.accountLabel.stringValue = @"Sign in with your Slippi account to play online (or sign in with the Slippi Launcher). Offline play needs no account.";
    self.accountIcon.hidden = YES;
  }
  self.signInRows.hidden = own;
  self.signOutButton.hidden = !own;
}
- (void)signIn {
  if (self.busy) return;
  std::string email = self.emailField.stringValue.UTF8String, password = self.passwordField.stringValue.UTF8String;
  if (email.empty() || password.empty()) { self.accountLabel.stringValue = @"Enter your Slippi email and password."; return; }
  self.busy = YES;
  self.accountLabel.stringValue = @"Signing in…";
  std::string dir = self.settings->slippi_dir;
  __weak MULauncherWindow* weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    slippi::login::Account account; std::string error;
    bool ok = slippi::login::sign_in(email, password, account, error) && slippi::login::write_user_file(dir, account, error);
    dispatch_async(dispatch_get_main_queue(), ^{
      MULauncherWindow* strongSelf = weakSelf;
      if (!strongSelf || strongSelf.closed) return;
      strongSelf.busy = NO;
      if (ok) { strongSelf.passwordField.stringValue = @""; [strongSelf refreshAccount]; }
      else strongSelf.accountLabel.stringValue = [NSString stringWithUTF8String:error.c_str()];
    });
  });
}
- (void)forgotPassword {
  std::string email = self.emailField.stringValue.UTF8String;
  if (email.empty()) { [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://slippi.gg"]]; return; }
  self.accountLabel.stringValue = @"Sending a password reset email…";
  __weak MULauncherWindow* weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    std::string error;
    bool ok = slippi::login::send_password_reset(email, error);
    dispatch_async(dispatch_get_main_queue(), ^{
      MULauncherWindow* strongSelf = weakSelf;
      if (!strongSelf || strongSelf.closed) return;
      strongSelf.accountLabel.stringValue = ok ? @"Password reset email sent. Check your inbox." : [NSString stringWithUTF8String:error.c_str()];
    });
  });
}
- (void)signOut {
  if (!self.settings) return;
  slippi::login::remove_user_file(self.settings->slippi_dir);
  [self refreshAccount];
}
- (void)refreshDisc {
  if (self.settings->iso.empty()) {
    self.discName.stringValue = @"No disc chosen";
    self.discHint.stringValue = self.startupError.length ? self.startupError : @"Choose your Super Smash Bros. Melee NTSC 1.02 image (.iso/.gcm), or drop it here. The game is read from it; nothing from it is included with the app.";
    self.playButton.enabled = NO;
  } else {
    NSString* path = [NSString stringWithUTF8String:self.settings->iso.c_str()];
    NSDictionary* attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    self.discName.stringValue = path.lastPathComponent;
    self.discHint.stringValue = [NSString stringWithFormat:@"%.2f GB · %@", [attrs fileSize] / 1e9, [path stringByAbbreviatingWithTildeInPath]];
    self.playButton.enabled = YES;
  }
}
- (void)acceptDroppedDisc:(NSString*)path {
  self.settings->iso = std::string(path.fileSystemRepresentation);
  self.startupError = nil;
  [self refreshDisc];
}
- (void)chooseDisc {
  NSOpenPanel* panel = [NSOpenPanel openPanel];
  panel.title = @"Choose Disc Image";
  panel.prompt = @"Choose";
  panel.canChooseDirectories = NO;
  panel.allowsMultipleSelection = NO;
  if ([panel runModal] != NSModalResponseOK) return;
  [self acceptDroppedDisc:[NSString stringWithUTF8String:panel.URL.fileSystemRepresentation]];
}
- (void)play {
  self.settings->widescreen = self.widescreen.state == NSControlStateValueOn;
  self.settings->online = self.online.state == NSControlStateValueOn;
  self.settings->sharpness = (float)self.sharpness.doubleValue;
  [NSApp stopModalWithCode:NSModalResponseOK];
}
- (void)windowWillClose:(NSNotification*)notification { [NSApp stopModalWithCode:NSModalResponseCancel]; }
@end

namespace host {
void mac_show_error(const std::string& title, const std::string& detail) {
  @autoreleasepool {
    prepare_application();
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithUTF8String:title.c_str()];
    alert.informativeText = [NSString stringWithUTF8String:detail.c_str()];
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
  }
}

bool launcher_run(LauncherSettings& settings, const std::string& error) {
  @autoreleasepool {
    prepare_application();
    MULauncherWindow* launcher = [[MULauncherWindow alloc] initWithSettings:&settings
                                                                       error:error.empty() ? nil : [NSString stringWithUTF8String:error.c_str()]];
    [launcher.window makeKeyAndOrderFront:nil];
    [launcher animateIn];
    NSModalResponse response = [NSApp runModalForWindow:launcher.window];
    launcher.closed = YES;
    launcher.settings = nullptr;   // an in-flight sign-in must not write into main's settings afterwards
    [launcher.window orderOut:nil];
    return response == NSModalResponseOK;
  }
}
}  // namespace host
