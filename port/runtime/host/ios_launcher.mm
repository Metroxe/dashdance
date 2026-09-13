// iOS / visionOS launcher: a UIKit screen shown before the game window. Disc images
// are imported into the app's Documents folder (also reachable from the Files app).
// Vector artwork and motion are Core Animation: an animated gradient with drifting
// glows, the ring mark drawn in with a stroke animation, staggered card entrances.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "mac_launcher.h"
#include "slippi_login.h"
#include <cstdio>
#include <string>
#include <vector>

namespace {
std::vector<std::string> documents_discs(NSURL** documents_out) {
  std::vector<std::string> discs;
  NSArray<NSURL*>* documents = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask];
  if (documents.count == 0) return discs;
  if (documents_out) *documents_out = documents.firstObject;
  NSArray<NSURL*>* entries = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:documents.firstObject
                                                          includingPropertiesForKeys:nil options:0 error:nil];
  for (NSURL* entry in entries) {
    NSString* extension = entry.pathExtension.lowercaseString;
    if ([extension isEqualToString:@"iso"] || [extension isEqualToString:@"gcm"]) discs.push_back(std::string(entry.fileSystemRepresentation));
  }
  return discs;
}
UIColor* rgb(CGFloat r, CGFloat g, CGFloat b, CGFloat a = 1) { return [UIColor colorWithRed:r green:g blue:b alpha:a]; }

// The ring mark from the app icon as a vector path (unit box 0..1), so it scales anywhere.
UIBezierPath* ring_mark_path(CGFloat size) {
  UIBezierPath* p = [UIBezierPath bezierPath];
  const CGFloat c = size * 0.5;
  [p appendPath:[UIBezierPath bezierPathWithArcCenter:CGPointMake(c, c) radius:size * 0.42 startAngle:0 endAngle:2 * M_PI clockwise:YES]];
  [p appendPath:[UIBezierPath bezierPathWithArcCenter:CGPointMake(c, c) radius:size * 0.28 startAngle:0 endAngle:2 * M_PI clockwise:NO]];
  p.usesEvenOddFillRule = YES;
  return p;
}
UIBezierPath* core_path(CGFloat size) {
  return [UIBezierPath bezierPathWithArcCenter:CGPointMake(size * 0.5, size * 0.5) radius:size * 0.16 startAngle:0 endAngle:2 * M_PI clockwise:YES];
}
}  // namespace

// Vector logo: ring drawn in with a stroke animation, then filled; core pops in.
@interface MULogoView : UIView
@property(nonatomic) CAShapeLayer* ring;
@property(nonatomic) CAShapeLayer* ringFill;
@property(nonatomic) CAShapeLayer* core;
@property(nonatomic) CAShapeLayer* slash;
@end
@implementation MULogoView
- (instancetype)initWithSize:(CGFloat)size {
  self = [super initWithFrame:CGRectMake(0, 0, size, size)];
  self.translatesAutoresizingMaskIntoConstraints = NO;
  [self.widthAnchor constraintEqualToConstant:size].active = YES;
  [self.heightAnchor constraintEqualToConstant:size].active = YES;
  self.ringFill = [CAShapeLayer layer];
  self.ringFill.path = ring_mark_path(size).CGPath;
  self.ringFill.fillRule = kCAFillRuleEvenOdd;
  self.ringFill.fillColor = UIColor.whiteColor.CGColor;
  self.ringFill.opacity = 0;
  self.ring = [CAShapeLayer layer];
  self.ring.path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(size * 0.5, size * 0.5) radius:size * 0.35 startAngle:-M_PI_2 endAngle:1.5 * M_PI clockwise:YES].CGPath;
  self.ring.strokeColor = UIColor.whiteColor.CGColor;
  self.ring.fillColor = UIColor.clearColor.CGColor;
  self.ring.lineWidth = size * 0.14;
  self.ring.lineCap = kCALineCapRound;
  self.ring.strokeEnd = 0;
  self.core = [CAShapeLayer layer];
  self.core.path = core_path(size).CGPath;
  self.core.fillColor = UIColor.whiteColor.CGColor;
  self.core.opacity = 0;
  // the diagonal cut through the ring (motion line), a masked strip
  self.slash = [CAShapeLayer layer];
  UIBezierPath* cut = [UIBezierPath bezierPath];
  [cut moveToPoint:CGPointMake(size * 0.10, size * 0.56)];
  [cut addLineToPoint:CGPointMake(size * 0.90, size * 0.40)];
  [cut addLineToPoint:CGPointMake(size * 0.90, size * 0.47)];
  [cut addLineToPoint:CGPointMake(size * 0.10, size * 0.63)];
  [cut closePath];
  self.slash.path = cut.CGPath;
  self.slash.fillColor = rgb(0.10, 0.07, 0.24).CGColor;
  self.slash.opacity = 0;
  [self.layer addSublayer:self.ringFill];
  [self.layer addSublayer:self.ring];
  [self.layer addSublayer:self.core];
  [self.layer addSublayer:self.slash];
  self.layer.shadowColor = rgb(0.55, 0.45, 1.0).CGColor;
  self.layer.shadowOpacity = 0.6; self.layer.shadowRadius = size * 0.25; self.layer.shadowOffset = CGSizeZero;
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
  // a slow breathing glow forever
  CABasicAnimation* glow = [CABasicAnimation animationWithKeyPath:@"shadowOpacity"];
  glow.fromValue = @0.35; glow.toValue = @0.8; glow.duration = 2.4; glow.autoreverses = YES; glow.repeatCount = HUGE_VALF;
  glow.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
  [self.layer addAnimation:glow forKey:@"glow"];
}
@end

// Animated backdrop: a gradient that slowly shifts hue plus two drifting radial glows.
@interface MUBackdropView : UIView
@end
@implementation MUBackdropView {
  CAGradientLayer* _gradient;
  NSArray<CAGradientLayer*>* _orbs;
}
- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  self.userInteractionEnabled = NO;
  self.translatesAutoresizingMaskIntoConstraints = NO;
  _gradient = [CAGradientLayer layer];
  _gradient.colors = @[(id)rgb(0.14, 0.09, 0.34).CGColor, (id)rgb(0.05, 0.03, 0.11).CGColor];
  _gradient.startPoint = CGPointMake(0, 0); _gradient.endPoint = CGPointMake(1, 1);
  [self.layer addSublayer:_gradient];
  NSMutableArray* orbs = [NSMutableArray array];
  for (int i = 0; i < 2; ++i) {
    CAGradientLayer* orb = [CAGradientLayer layer];
    orb.type = kCAGradientLayerRadial;
    orb.colors = i == 0 ? @[(id)rgb(0.45, 0.32, 1.0, 0.55).CGColor, (id)rgb(0.45, 0.32, 1.0, 0).CGColor]
                        : @[(id)rgb(0.20, 0.60, 1.0, 0.40).CGColor, (id)rgb(0.20, 0.60, 1.0, 0).CGColor];
    orb.startPoint = CGPointMake(0.5, 0.5); orb.endPoint = CGPointMake(1, 1);
    [self.layer addSublayer:orb];
    [orbs addObject:orb];
  }
  _orbs = orbs;
  return self;
}
- (void)layoutSubviews {
  [super layoutSubviews];
  [CATransaction begin]; [CATransaction setDisableActions:YES];
  _gradient.frame = self.bounds;
  const CGFloat w = self.bounds.size.width, h = self.bounds.size.height, d = MAX(w, h) * 0.9;
  _orbs[0].bounds = CGRectMake(0, 0, d, d); _orbs[0].position = CGPointMake(w * 0.15, h * 0.10);
  _orbs[1].bounds = CGRectMake(0, 0, d * 0.8, d * 0.8); _orbs[1].position = CGPointMake(w * 0.95, h * 0.85);
  [CATransaction commit];
  if (![_gradient animationForKey:@"shift"]) [self startMotion];
}
- (void)startMotion {
  CABasicAnimation* shift = [CABasicAnimation animationWithKeyPath:@"colors"];
  shift.toValue = @[(id)rgb(0.08, 0.14, 0.38).CGColor, (id)rgb(0.10, 0.03, 0.14).CGColor];
  shift.duration = 9; shift.autoreverses = YES; shift.repeatCount = HUGE_VALF;
  shift.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
  [_gradient addAnimation:shift forKey:@"shift"];
  const CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
  for (NSUInteger i = 0; i < _orbs.count; ++i) {
    CABasicAnimation* drift = [CABasicAnimation animationWithKeyPath:@"position"];
    CGPoint from = _orbs[i].position;
    drift.fromValue = [NSValue valueWithCGPoint:from];
    drift.toValue = [NSValue valueWithCGPoint:CGPointMake(from.x + (i == 0 ? w * 0.25 : -w * 0.2), from.y + (i == 0 ? h * 0.18 : -h * 0.22))];
    drift.duration = 11 + 4 * i; drift.autoreverses = YES; drift.repeatCount = HUGE_VALF;
    drift.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [_orbs[i] addAnimation:drift forKey:@"drift"];
  }
}
@end

@interface MULauncherController : UIViewController <UIDocumentPickerDelegate, UITextFieldDelegate>
@property(nonatomic) host::LauncherSettings* settings;
@property(nonatomic) BOOL done, playPressed;
@property(nonatomic) UIScrollView* scroll;
@property(nonatomic) NSArray<UIView*>* entrance;   // views that animate in, in order
@property(nonatomic) MULogoView* logo;
@property(nonatomic) UILabel* discLabel;
@property(nonatomic) UILabel* hintLabel;
@property(nonatomic) UIButton* playButton;
@property(nonatomic) UISwitch* widescreenSwitch;
@property(nonatomic) UISwitch* onlineSwitch;
@property(nonatomic) UISlider* sharpnessSlider;
@property(nonatomic) UISlider* overlaySlider;
@property(nonatomic, copy) NSString* startupError;
@property(nonatomic) UILabel* accountLabel;
@property(nonatomic) UIImageView* accountIcon;
@property(nonatomic) UITextField* emailField;
@property(nonatomic) UITextField* passwordField;
@property(nonatomic) UIButton* signInButton;
@property(nonatomic) UIButton* signOutButton;
@property(nonatomic) UIButton* resetButton;
@property(nonatomic) UIStackView* signInRows;
@property(nonatomic) BOOL busy;
@end

@implementation MULauncherController
- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = rgb(0.05, 0.04, 0.10);
  MUBackdropView* backdrop = [[MUBackdropView alloc] initWithFrame:self.view.bounds];
  [self.view addSubview:backdrop];
  [NSLayoutConstraint activateConstraints:@[
    [backdrop.topAnchor constraintEqualToAnchor:self.view.topAnchor], [backdrop.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    [backdrop.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [backdrop.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]]];

  self.scroll = [[UIScrollView alloc] init];
  self.scroll.translatesAutoresizingMaskIntoConstraints = NO;
#if !TARGET_OS_VISION
  self.scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
#endif
  [self.view addSubview:self.scroll];
  UIStackView* stack = [[UIStackView alloc] init];
  stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 16; stack.alignment = UIStackViewAlignmentFill;
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  [self.scroll addSubview:stack];
  [NSLayoutConstraint activateConstraints:@[
    [self.scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor], [self.scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    [self.scroll.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor], [self.scroll.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
    [stack.topAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.topAnchor constant:56], [stack.bottomAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.bottomAnchor constant:-48],
    [stack.centerXAnchor constraintEqualToAnchor:self.scroll.frameLayoutGuide.centerXAnchor],
    [stack.widthAnchor constraintLessThanOrEqualToConstant:560]]];
  NSLayoutConstraint* width = [stack.widthAnchor constraintEqualToAnchor:self.scroll.frameLayoutGuide.widthAnchor constant:-40];
  width.priority = UILayoutPriorityDefaultHigh; width.active = YES;
  UITapGestureRecognizer* tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
  tap.cancelsTouchesInView = NO;
  [self.view addGestureRecognizer:tap];

  // Hero: vector logo, title, subtitle
  UIStackView* hero = [[UIStackView alloc] init];
  hero.axis = UILayoutConstraintAxisVertical; hero.alignment = UIStackViewAlignmentCenter; hero.spacing = 10;
  self.logo = [[MULogoView alloc] initWithSize:88];
  UILabel* title = [[UILabel alloc] init];
  title.text = @"iSlippi";
  title.font = [UIFont systemFontOfSize:46 weight:UIFontWeightBold];
  title.textColor = UIColor.whiteColor; title.textAlignment = NSTextAlignmentCenter;
  UILabel* subtitle = [[UILabel alloc] init];
  subtitle.text = @"Super Smash Bros. Melee with Slippi rollback netplay, running natively on this device.";
  subtitle.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
  subtitle.adjustsFontForContentSizeCategory = YES;
  subtitle.textColor = [UIColor colorWithWhite:1 alpha:0.72]; subtitle.textAlignment = NSTextAlignmentCenter; subtitle.numberOfLines = 0;
  [hero addArrangedSubview:self.logo]; [hero addArrangedSubview:title]; [hero addArrangedSubview:subtitle];
  [hero setCustomSpacing:18 afterView:self.logo];
  [stack addArrangedSubview:hero];
  [stack setCustomSpacing:30 afterView:hero];

  // Disc card
  UIView* card = [self card];
  UIStackView* cardStack = [self stackIn:card];
  [cardStack addArrangedSubview:[self caption:@"GAME DISC" symbol:@"opticaldisc"]];
  self.discLabel = [[UILabel alloc] init];
  self.discLabel.font = [UIFont systemFontOfSize:21 weight:UIFontWeightSemibold];
  self.discLabel.textColor = UIColor.whiteColor; self.discLabel.numberOfLines = 0;
  self.hintLabel = [[UILabel alloc] init];
  self.hintLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote]; self.hintLabel.numberOfLines = 0;
  self.hintLabel.textColor = [UIColor colorWithWhite:1 alpha:0.6];
  UIButton* import_ = [self button:@"Import Disc Image" symbol:@"square.and.arrow.down" filled:NO];
  [import_ addTarget:self action:@selector(importDisc) forControlEvents:UIControlEventTouchUpInside];
  [cardStack addArrangedSubview:self.discLabel]; [cardStack addArrangedSubview:self.hintLabel]; [cardStack addArrangedSubview:import_];
  [stack addArrangedSubview:card];

  // Slippi account card
  UIView* account = [self card];
  UIStackView* accountStack = [self stackIn:account];
  [accountStack addArrangedSubview:[self caption:@"SLIPPI ONLINE ACCOUNT" symbol:@"person.crop.circle"]];
  UIStackView* accountRow = [[UIStackView alloc] init];
  accountRow.axis = UILayoutConstraintAxisHorizontal; accountRow.spacing = 10; accountRow.alignment = UIStackViewAlignmentCenter;
  self.accountIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark.seal.fill"]];
  self.accountIcon.tintColor = [UIColor systemGreenColor];
  self.accountIcon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightSemibold];
  self.accountIcon.hidden = YES;
  self.accountLabel = [[UILabel alloc] init];
  self.accountLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; self.accountLabel.adjustsFontForContentSizeCategory = YES;
  self.accountLabel.textColor = UIColor.whiteColor; self.accountLabel.numberOfLines = 0;
  [accountRow addArrangedSubview:self.accountIcon]; [accountRow addArrangedSubview:self.accountLabel];
  [accountStack addArrangedSubview:accountRow];
  self.signInRows = [[UIStackView alloc] init];
  self.signInRows.axis = UILayoutConstraintAxisVertical; self.signInRows.spacing = 10;
  self.emailField = [self field:@"Email" symbol:@"envelope" secure:NO];
  self.emailField.keyboardType = UIKeyboardTypeEmailAddress; self.emailField.textContentType = UITextContentTypeUsername;
  self.emailField.returnKeyType = UIReturnKeyNext;
  self.passwordField = [self field:@"Password" symbol:@"key" secure:YES];
  self.passwordField.textContentType = UITextContentTypePassword; self.passwordField.returnKeyType = UIReturnKeyGo;
  self.signInButton = [self button:@"Sign In" symbol:@"person.badge.key" filled:NO];
  [self.signInButton addTarget:self action:@selector(signIn) forControlEvents:UIControlEventTouchUpInside];
  self.resetButton = [UIButton buttonWithType:UIButtonTypeSystem];
  [self.resetButton setTitle:@"Forgot password · Create an account at slippi.gg" forState:UIControlStateNormal];
  self.resetButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
  self.resetButton.tintColor = rgb(0.72, 0.66, 1.0);
  [self.resetButton addTarget:self action:@selector(forgotPassword) forControlEvents:UIControlEventTouchUpInside];
  [self.signInRows addArrangedSubview:self.emailField]; [self.signInRows addArrangedSubview:self.passwordField];
  [self.signInRows addArrangedSubview:self.signInButton]; [self.signInRows addArrangedSubview:self.resetButton];
  [accountStack addArrangedSubview:self.signInRows];
  self.signOutButton = [self button:@"Sign Out" symbol:@"rectangle.portrait.and.arrow.right" filled:NO];
  [self.signOutButton addTarget:self action:@selector(signOut) forControlEvents:UIControlEventTouchUpInside];
  [accountStack addArrangedSubview:self.signOutButton];
  [stack addArrangedSubview:account];
  [self refreshAccount];

  // Settings card
  UIView* settings = [self card];
  UIStackView* settingsStack = [self stackIn:settings];
  [settingsStack addArrangedSubview:[self caption:@"PLAY" symbol:@"gamecontroller"]];
  self.widescreenSwitch = [[UISwitch alloc] init]; self.widescreenSwitch.on = self.settings->widescreen;
  self.widescreenSwitch.onTintColor = [UIColor systemIndigoColor];
  [settingsStack addArrangedSubview:[self row:@"Widescreen (16:9)" symbol:@"rectangle.ratio.16.to.9" control:self.widescreenSwitch]];
  self.onlineSwitch = [[UISwitch alloc] init]; self.onlineSwitch.on = self.settings->online;
  self.onlineSwitch.onTintColor = [UIColor systemIndigoColor];
  [settingsStack addArrangedSubview:[self row:@"Slippi Online" symbol:@"network" control:self.onlineSwitch]];
  self.sharpnessSlider = [[UISlider alloc] init]; self.sharpnessSlider.value = self.settings->sharpness;
  self.sharpnessSlider.tintColor = [UIColor systemIndigoColor];
  [settingsStack addArrangedSubview:[self row:@"Sharpen" symbol:@"sparkles" control:self.sharpnessSlider]];
  self.overlaySlider = [[UISlider alloc] init]; self.overlaySlider.value = self.settings->overlay_opacity;
  self.overlaySlider.tintColor = [UIColor systemIndigoColor];
  [settingsStack addArrangedSubview:[self row:@"On-screen controls" symbol:@"hand.tap" control:self.overlaySlider]];
  [stack addArrangedSubview:settings];

  self.playButton = [self button:@"Play" symbol:@"play.fill" filled:YES];
  [self.playButton addTarget:self action:@selector(play) forControlEvents:UIControlEventTouchUpInside];
  [stack addArrangedSubview:self.playButton];
  [stack setCustomSpacing:24 afterView:settings];

  UILabel* footer = [[UILabel alloc] init];
  footer.text = @"Needs your own Super Smash Bros. Melee NTSC 1.02 disc image (.iso/.gcm). Nothing from the game ships with the app. Unofficial; not affiliated with the Slippi team.";
  footer.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1]; footer.textColor = [UIColor colorWithWhite:1 alpha:0.5];
  footer.numberOfLines = 0; footer.textAlignment = NSTextAlignmentCenter;
  [stack addArrangedSubview:footer];
  [self refreshDisc];

  self.entrance = @[hero, card, account, settings, self.playButton, footer];
  for (UIView* v in self.entrance) { v.alpha = 0; v.transform = CGAffineTransformMakeTranslation(0, 26); }
#if !TARGET_OS_VISION
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(keyboardChanged:) name:UIKeyboardWillChangeFrameNotification object:nil];
#endif
}
- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  [self.logo animateIn];
  NSTimeInterval delay = 0.15;
  for (UIView* v in self.entrance) {
    [UIView animateWithDuration:0.7 delay:delay usingSpringWithDamping:0.82 initialSpringVelocity:0.4 options:UIViewAnimationOptionAllowUserInteraction animations:^{
      v.alpha = 1; v.transform = CGAffineTransformIdentity;
    } completion:nil];
    delay += 0.08;
  }
  // the Play button breathes once the page has settled
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    CABasicAnimation* breathe = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    breathe.fromValue = @1.0; breathe.toValue = @1.025; breathe.duration = 1.6; breathe.autoreverses = YES; breathe.repeatCount = HUGE_VALF;
    breathe.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [self.playButton.layer addAnimation:breathe forKey:@"breathe"];
  });
}
- (void)dismissKeyboard { [self.view endEditing:YES]; }
#if !TARGET_OS_VISION
- (void)keyboardChanged:(NSNotification*)note {
  CGRect end = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
  CGRect inView = [self.view convertRect:end fromView:nil];
  CGFloat overlap = MAX(0, CGRectGetMaxY(self.view.bounds) - CGRectGetMinY(inView));
  UIEdgeInsets insets = self.scroll.contentInset; insets.bottom = overlap;
  self.scroll.contentInset = insets; self.scroll.verticalScrollIndicatorInsets = insets;
  if (overlap > 0 && self.passwordField.isFirstResponder) [self.scroll scrollRectToVisible:[self.scroll convertRect:self.signInRows.bounds fromView:self.signInRows] animated:YES];
}
#endif
- (BOOL)textFieldShouldReturn:(UITextField*)field {
  if (field == self.emailField) { [self.passwordField becomeFirstResponder]; return NO; }
  [field resignFirstResponder]; [self signIn]; return YES;
}
- (UIView*)card {
  UIVisualEffectView* card = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark]];
  card.layer.cornerRadius = 22; card.layer.cornerCurve = kCACornerCurveContinuous; card.clipsToBounds = YES;
  card.layer.borderWidth = 1; card.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.10].CGColor;
  return card;
}
- (UIStackView*)stackIn:(UIView*)card {
  UIView* host = [card isKindOfClass:UIVisualEffectView.class] ? ((UIVisualEffectView*)card).contentView : card;
  UIStackView* s = [[UIStackView alloc] init];
  s.axis = UILayoutConstraintAxisVertical; s.spacing = 12; s.translatesAutoresizingMaskIntoConstraints = NO;
  [host addSubview:s];
  [NSLayoutConstraint activateConstraints:@[
    [s.topAnchor constraintEqualToAnchor:host.topAnchor constant:20], [s.bottomAnchor constraintEqualToAnchor:host.bottomAnchor constant:-20],
    [s.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:20], [s.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-20]]];
  return s;
}
- (UIView*)caption:(NSString*)text symbol:(NSString*)symbol {
  UIStackView* row = [[UIStackView alloc] init];
  row.axis = UILayoutConstraintAxisHorizontal; row.spacing = 6; row.alignment = UIStackViewAlignmentCenter;
  UIImageView* icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
  icon.tintColor = rgb(0.72, 0.66, 1.0);
  icon.contentMode = UIViewContentModeScaleAspectFit;
  icon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold];
  [icon.widthAnchor constraintEqualToConstant:18].active = YES;
  [icon setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
  UILabel* l = [[UILabel alloc] init];
  l.text = text; l.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
  l.textColor = [UIColor colorWithWhite:1 alpha:0.55];
  [l setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
  [row addArrangedSubview:icon]; [row addArrangedSubview:l];
  return row;
}
- (UIView*)row:(NSString*)text symbol:(NSString*)symbol control:(UIView*)control {
  UIStackView* row = [[UIStackView alloc] init];
  row.axis = UILayoutConstraintAxisHorizontal; row.spacing = 12; row.alignment = UIStackViewAlignmentCenter;
  UIImageView* icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
  icon.tintColor = [UIColor colorWithWhite:1 alpha:0.7];
  icon.contentMode = UIViewContentModeScaleAspectFit;
  icon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightMedium];
  [icon.widthAnchor constraintEqualToConstant:24].active = YES;
  [icon setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
  UILabel* l = [[UILabel alloc] init];
  l.text = text; l.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; l.adjustsFontForContentSizeCategory = YES; l.textColor = UIColor.whiteColor;
  [l setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
  [row addArrangedSubview:icon]; [row addArrangedSubview:l]; [row addArrangedSubview:control];
  if ([control isKindOfClass:UISlider.class]) [control.widthAnchor constraintEqualToConstant:170].active = YES;
  return row;
}
- (UIButton*)button:(NSString*)title symbol:(NSString*)symbol filled:(BOOL)filled {
  UIButtonConfiguration* c = filled ? [UIButtonConfiguration filledButtonConfiguration] : [UIButtonConfiguration grayButtonConfiguration];
  c.title = title; c.cornerStyle = UIButtonConfigurationCornerStyleLarge;
  c.image = [UIImage systemImageNamed:symbol]; c.imagePadding = 8;
  c.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightSemibold];
  c.contentInsets = NSDirectionalEdgeInsetsMake(14, 20, 14, 20);
  if (filled) c.baseBackgroundColor = [UIColor systemIndigoColor];
  else c.baseForegroundColor = UIColor.whiteColor;
  UIButton* b = [UIButton buttonWithConfiguration:c primaryAction:nil];
  b.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
  if (filled) { b.layer.shadowColor = [UIColor systemIndigoColor].CGColor; b.layer.shadowOpacity = 0.5; b.layer.shadowRadius = 16; b.layer.shadowOffset = CGSizeMake(0, 6); }
  return b;
}
- (UITextField*)field:(NSString*)placeholder symbol:(NSString*)symbol secure:(BOOL)secure {
  UITextField* f = [[UITextField alloc] init];
  f.attributedPlaceholder = [[NSAttributedString alloc] initWithString:placeholder attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.35]}];
  f.textColor = UIColor.whiteColor; f.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
  f.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08]; f.layer.cornerRadius = 12; f.layer.cornerCurve = kCACornerCurveContinuous;
  f.secureTextEntry = secure; f.autocapitalizationType = UITextAutocapitalizationTypeNone; f.autocorrectionType = UITextAutocorrectionTypeNo;
  f.delegate = self;
  UIImageView* icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
  icon.tintColor = [UIColor colorWithWhite:1 alpha:0.5]; icon.contentMode = UIViewContentModeCenter;
  icon.frame = CGRectMake(0, 0, 40, 46);
  f.leftView = icon; f.leftViewMode = UITextFieldViewModeAlways;
  [f.heightAnchor constraintEqualToConstant:46].active = YES;
  return f;
}
- (void)setBusy:(BOOL)busy {
  _busy = busy;
  UIButtonConfiguration* c = self.signInButton.configuration;
  c.showsActivityIndicator = busy;
  c.title = busy ? @"Signing In…" : @"Sign In";
  self.signInButton.configuration = c;
  self.signInButton.enabled = !busy;
}
- (void)refreshAccount {
  if (!self.settings) return;
  slippi::login::Account account;
  const bool signed_in = slippi::login::read_user_file(self.settings->slippi_dir, account);
  if (signed_in) {
    self.settings->account_name = account.display_name; self.settings->account_code = account.connect_code;
    NSMutableAttributedString* text = [[NSMutableAttributedString alloc] initWithString:[NSString stringWithUTF8String:account.display_name.c_str()]
        attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold], NSForegroundColorAttributeName: UIColor.whiteColor}];
    [text appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"  %s", account.connect_code.c_str()]
        attributes:@{NSFontAttributeName: [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightMedium], NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.6]}]];
    self.accountLabel.attributedText = text;
    self.accountIcon.hidden = NO;
  } else {
    self.settings->account_name.clear(); self.settings->account_code.clear();
    self.accountLabel.attributedText = nil;
    self.accountLabel.text = @"Sign in with your Slippi account to play online. Offline play works without it.";
    self.accountIcon.hidden = YES;
  }
  self.signInRows.hidden = signed_in;
  self.signOutButton.hidden = !signed_in;
}
- (void)celebrate {
  self.accountIcon.transform = CGAffineTransformMakeScale(0.2, 0.2);
  [UIView animateWithDuration:0.6 delay:0 usingSpringWithDamping:0.5 initialSpringVelocity:0.8 options:0 animations:^{ self.accountIcon.transform = CGAffineTransformIdentity; } completion:nil];
}
- (void)signIn {
  if (self.busy) return;
  std::string email = self.emailField.text.UTF8String ?: "", password = self.passwordField.text.UTF8String ?: "";
  if (email.empty() || password.empty()) { self.accountLabel.text = @"Enter your Slippi email and password."; return; }
  [self.view endEditing:YES];
  self.busy = YES;
  self.accountLabel.text = @"Signing in…";
  std::string dir = self.settings->slippi_dir;
  __weak MULauncherController* weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    slippi::login::Account account; std::string error;
    bool ok = slippi::login::sign_in(email, password, account, error) && slippi::login::write_user_file(dir, account, error);
    dispatch_async(dispatch_get_main_queue(), ^{
      MULauncherController* strongSelf = weakSelf;
      if (!strongSelf || strongSelf.done) return;
      strongSelf.busy = NO;
      if (ok) { strongSelf.passwordField.text = @""; [strongSelf refreshAccount]; [strongSelf celebrate]; }
      else strongSelf.accountLabel.text = [NSString stringWithUTF8String:error.c_str()];
    });
  });
}
- (void)forgotPassword {
  std::string email = self.emailField.text.UTF8String ?: "";
  if (email.empty()) {
    [UIApplication.sharedApplication openURL:[NSURL URLWithString:@"https://slippi.gg"] options:@{} completionHandler:nil];
    return;
  }
  self.accountLabel.text = @"Sending a password reset email…";
  __weak MULauncherController* weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    std::string error;
    bool ok = slippi::login::send_password_reset(email, error);
    dispatch_async(dispatch_get_main_queue(), ^{
      MULauncherController* strongSelf = weakSelf;
      if (!strongSelf || strongSelf.done) return;
      strongSelf.accountLabel.text = ok ? @"Password reset email sent. Check your inbox." : [NSString stringWithUTF8String:error.c_str()];
    });
  });
}
- (void)signOut {
  if (!self.settings) return;
  slippi::login::remove_user_file(self.settings->slippi_dir);
  [self refreshAccount];
}
- (void)refreshDisc {
  std::vector<std::string> discs = documents_discs(nullptr);
  if (!self.settings->iso.empty()) {
    bool present = false;
    for (const std::string& d : discs) if (d == self.settings->iso) present = true;
    if (!present) self.settings->iso.clear();
  }
  if (self.settings->iso.empty() && !discs.empty()) self.settings->iso = discs.front();
  if (self.settings->iso.empty()) {
    self.discLabel.text = @"No disc image yet";
    self.hintLabel.text = self.startupError.length ? self.startupError : @"Import your .iso/.gcm here, or drop it into this app's folder in Files.";
    self.playButton.enabled = NO;
  } else {
    NSString* path = [NSString stringWithUTF8String:self.settings->iso.c_str()];
    NSDictionary* attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    double gb = [attrs fileSize] / 1e9;
    self.discLabel.text = path.lastPathComponent;
    self.hintLabel.text = [NSString stringWithFormat:@"%.2f GB · ready to play%@", gb, self.startupError.length ? [@"\n" stringByAppendingString:self.startupError] : @""];
    self.playButton.enabled = YES;
  }
}
- (void)importDisc {
  NSMutableArray<UTType*>* types = [NSMutableArray array];
  for (NSString* ext in @[@"iso", @"gcm"]) { UTType* t = [UTType typeWithFilenameExtension:ext]; if (t) [types addObject:t]; }
  [types addObject:UTTypeData];
  UIDocumentPickerViewController* picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
  picker.delegate = self;
  [self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController*)controller didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
  NSURL* documents = nil;
  documents_discs(&documents);
  if (!documents || urls.count == 0) return;
  NSURL* dest = [documents URLByAppendingPathComponent:urls.firstObject.lastPathComponent];
  NSError* error = nil;
  [[NSFileManager defaultManager] removeItemAtURL:dest error:nil];
  if (![[NSFileManager defaultManager] moveItemAtURL:urls.firstObject toURL:dest error:&error]) {
    self.startupError = [NSString stringWithFormat:@"Could not import: %@", error.localizedDescription];
  } else {
    self.startupError = nil;
    self.settings->iso = std::string(dest.fileSystemRepresentation);
  }
  [self refreshDisc];
}
- (void)play {
  self.settings->widescreen = self.widescreenSwitch.on;
  self.settings->online = self.onlineSwitch.on;
  self.settings->sharpness = self.sharpnessSlider.value;
  self.settings->overlay_opacity = self.overlaySlider.value;
  self.playPressed = YES;
  // fade the page away before the game window takes over; `done` does not depend on the animation finishing
  [self.playButton.layer removeAnimationForKey:@"breathe"];
  [UIView animateWithDuration:0.28 animations:^{ self.view.alpha = 0; self.view.transform = CGAffineTransformMakeScale(0.97, 0.97); } completion:nil];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ self.done = YES; });
}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
@end

namespace host {
void mac_show_error(const std::string& title, const std::string& detail) {
  std::fprintf(stderr, "%s: %s\n", title.c_str(), detail.c_str());
}

bool launcher_run(LauncherSettings& settings, const std::string& error) {
  @autoreleasepool {
    // SDL has not created its window yet; attach ours to the connected scene (or the main screen).
    UIWindowScene* scene = nil;
    for (int wait = 0; wait < 200 && !scene; ++wait) {   // up to 10 s; visionOS connects its scene a little after launch
      for (UIScene* s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:UIWindowScene.class]) { scene = (UIWindowScene*)s; break; }
      if (!scene) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
    }
    if (!scene) std::fprintf(stderr, "launcher: no window scene connected after 10 s\n");
    UIWindow* window = nil;
    if (scene) window = [[UIWindow alloc] initWithWindowScene:scene];
#if !TARGET_OS_VISION
    if (!window) window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
#endif
    if (!window) return false;
    MULauncherController* controller = [[MULauncherController alloc] init];
    controller.settings = &settings;
    controller.startupError = error.empty() ? nil : [NSString stringWithUTF8String:error.c_str()];
    window.rootViewController = controller;
    window.windowLevel = UIWindowLevelNormal + 1;
    [window makeKeyAndVisible];
    while (!controller.done) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
    window.hidden = YES;
    window.rootViewController = nil;
    controller.settings = nullptr;   // an in-flight sign-in must not write into main's settings afterwards
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
    return controller.playPressed;
  }
}
}  // namespace host
