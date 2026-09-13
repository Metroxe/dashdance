// iOS / iPadOS / visionOS dashboard and launcher (UIKit + SceneKit). Melee-styled: dark grid
// backdrop, yellow angled section headers, italic display type. Shows the signed-in player's
// ranked profile and recent games, manages controllers and display settings, then starts play.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <UIKit/UIKit.h>
#import <SceneKit/SceneKit.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "dashboard.h"
#include "input_config.h"
#include "mac_launcher.h"
#include "slippi_login.h"
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

namespace {
UIColor* rgb(CGFloat r, CGFloat g, CGFloat b, CGFloat a = 1) { return [UIColor colorWithRed:r green:g blue:b alpha:a]; }
UIColor* kYellow() { return rgb(0.97, 0.79, 0.28); }
UIColor* kRed() { return rgb(0.89, 0.27, 0.17); }
NSString* ns(const std::string& s) { return [NSString stringWithUTF8String:s.c_str()]; }
UIFont* meleeFont(CGFloat size, UIFontWeight weight) {
  UIFont* base = [UIFont systemFontOfSize:size weight:weight];
  UIFontDescriptor* d = [base.fontDescriptor fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitItalic | UIFontDescriptorTraitBold];
  return d ? [UIFont fontWithDescriptor:d size:size] : base;
}
std::vector<std::string> documents_discs(NSURL** documents_out) {
  std::vector<std::string> discs;
  NSArray<NSURL*>* documents = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask];
  if (documents.count == 0) return discs;
  if (documents_out) *documents_out = documents.firstObject;
  NSArray<NSURL*>* entries = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:documents.firstObject includingPropertiesForKeys:nil options:0 error:nil];
  for (NSURL* entry in entries) {
    NSString* extension = entry.pathExtension.lowercaseString;
    if ([extension isEqualToString:@"iso"] || [extension isEqualToString:@"gcm"]) discs.push_back(std::string(entry.fileSystemRepresentation));
  }
  return discs;
}
int display_max_hz() {
#if TARGET_OS_VISION
  return 90;
#else
  return (int)UIScreen.mainScreen.maximumFramesPerSecond;
#endif
}
}  // namespace

// ---- 3D mark: a metallic ring with a core, slowly turning (SceneKit, transparent background)
@interface MUHeroView : SCNView
@end
@implementation MUHeroView
- (instancetype)initWithSize:(CGFloat)size {
  self = [super initWithFrame:CGRectMake(0, 0, size, size) options:nil];
  self.translatesAutoresizingMaskIntoConstraints = NO;
  [self.widthAnchor constraintEqualToConstant:size].active = YES;
  [self.heightAnchor constraintEqualToConstant:size].active = YES;
  self.backgroundColor = UIColor.clearColor;
  self.antialiasingMode = SCNAntialiasingModeMultisampling4X;
  self.autoenablesDefaultLighting = NO;
  SCNScene* scene = [SCNScene scene];
  self.scene = scene;
  SCNNode* root = [SCNNode node];
  SCNTorus* torus = [SCNTorus torusWithRingRadius:1.0 pipeRadius:0.34];
  torus.ringSegmentCount = 96; torus.pipeSegmentCount = 48;
  SCNMaterial* metal = [SCNMaterial material];
  metal.lightingModelName = SCNLightingModelPhysicallyBased;
  metal.diffuse.contents = rgb(0.96, 0.96, 1.0); metal.metalness.contents = @0.9; metal.roughness.contents = @0.22;
  torus.materials = @[metal];
  SCNNode* ring = [SCNNode nodeWithGeometry:torus];
  ring.eulerAngles = SCNVector3Make(M_PI_2 * 0.92, 0, 0);
  SCNSphere* core = [SCNSphere sphereWithRadius:0.42];
  SCNMaterial* gold = [SCNMaterial material];
  gold.lightingModelName = SCNLightingModelPhysicallyBased;
  gold.diffuse.contents = kYellow(); gold.metalness.contents = @0.85; gold.roughness.contents = @0.3; gold.emission.contents = rgb(0.5, 0.35, 0.05);
  core.materials = @[gold];
  SCNNode* coreNode = [SCNNode nodeWithGeometry:core];
  [root addChildNode:ring]; [root addChildNode:coreNode];
  [scene.rootNode addChildNode:root];
  SCNNode* key = [SCNNode node]; key.light = [SCNLight light]; key.light.type = SCNLightTypeOmni; key.light.intensity = 900; key.light.color = UIColor.whiteColor; key.position = SCNVector3Make(3, 4, 5);
  SCNNode* fill = [SCNNode node]; fill.light = [SCNLight light]; fill.light.type = SCNLightTypeOmni; fill.light.intensity = 400; fill.light.color = rgb(0.6, 0.55, 1.0); fill.position = SCNVector3Make(-4, -2, 3);
  SCNNode* ambient = [SCNNode node]; ambient.light = [SCNLight light]; ambient.light.type = SCNLightTypeAmbient; ambient.light.intensity = 250; ambient.light.color = rgb(0.4, 0.4, 0.6);
  [scene.rootNode addChildNode:key]; [scene.rootNode addChildNode:fill]; [scene.rootNode addChildNode:ambient];
  SCNNode* cam = [SCNNode node]; cam.camera = [SCNCamera camera]; cam.camera.fieldOfView = 34; cam.position = SCNVector3Make(0, 0.6, 5.2);
  [cam lookAt:SCNVector3Zero];
  [scene.rootNode addChildNode:cam];
  self.pointOfView = cam;
  [root runAction:[SCNAction repeatActionForever:[SCNAction rotateByX:0 y:M_PI * 2 z:0 duration:14]]];
  [coreNode runAction:[SCNAction repeatActionForever:[SCNAction sequence:@[[SCNAction scaleTo:1.12 duration:1.6], [SCNAction scaleTo:1.0 duration:1.6]]]]];
  [ring runAction:[SCNAction repeatActionForever:[SCNAction sequence:@[[SCNAction rotateByX:0.25 y:0 z:0 duration:3.0], [SCNAction rotateByX:-0.25 y:0 z:0 duration:3.0]]]]];
  self.layer.shadowColor = rgb(0.97, 0.79, 0.28).CGColor; self.layer.shadowOpacity = 0.35; self.layer.shadowRadius = size * 0.3; self.layer.shadowOffset = CGSizeZero;
  return self;
}
@end

// ---- Melee-style backdrop: dark blue gradient with a faint perspective grid and a drifting glow
@interface MUBackdropView : UIView
@end
@implementation MUBackdropView { CAGradientLayer* _gradient; CAShapeLayer* _grid; CAGradientLayer* _glow; }
- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  self.userInteractionEnabled = NO; self.translatesAutoresizingMaskIntoConstraints = NO;
  _gradient = [CAGradientLayer layer];
  _gradient.colors = @[(id)rgb(0.05, 0.07, 0.20).CGColor, (id)rgb(0.02, 0.02, 0.08).CGColor];
  _gradient.startPoint = CGPointMake(0.5, 0); _gradient.endPoint = CGPointMake(0.5, 1);
  [self.layer addSublayer:_gradient];
  _grid = [CAShapeLayer layer];
  _grid.strokeColor = rgb(0.45, 0.55, 1.0, 0.10).CGColor; _grid.lineWidth = 1; _grid.fillColor = nil;
  [self.layer addSublayer:_grid];
  _glow = [CAGradientLayer layer];
  _glow.type = kCAGradientLayerRadial;
  _glow.colors = @[(id)rgb(0.97, 0.79, 0.28, 0.22).CGColor, (id)rgb(0.97, 0.79, 0.28, 0).CGColor];
  _glow.startPoint = CGPointMake(0.5, 0.5); _glow.endPoint = CGPointMake(1, 1);
  [self.layer addSublayer:_glow];
  return self;
}
- (void)layoutSubviews {
  [super layoutSubviews];
  [CATransaction begin]; [CATransaction setDisableActions:YES];
  _gradient.frame = self.bounds;
  const CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
  UIBezierPath* p = [UIBezierPath bezierPath];
  for (CGFloat x = 0; x <= w; x += 56) { [p moveToPoint:CGPointMake(x, 0)]; [p addLineToPoint:CGPointMake(x, h)]; }
  for (CGFloat y = 0; y <= h; y += 56) { [p moveToPoint:CGPointMake(0, y)]; [p addLineToPoint:CGPointMake(w, y)]; }
  _grid.path = p.CGPath; _grid.frame = self.bounds;
  const CGFloat d = MAX(w, h) * 0.9;
  _glow.bounds = CGRectMake(0, 0, d, d); _glow.position = CGPointMake(w * 0.85, h * 0.12);
  [CATransaction commit];
  if (![_glow animationForKey:@"drift"]) {
    CABasicAnimation* drift = [CABasicAnimation animationWithKeyPath:@"position"];
    drift.fromValue = [NSValue valueWithCGPoint:_glow.position];
    drift.toValue = [NSValue valueWithCGPoint:CGPointMake(w * 0.2, h * 0.35)];
    drift.duration = 16; drift.autoreverses = YES; drift.repeatCount = HUGE_VALF;
    drift.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [_glow addAnimation:drift forKey:@"drift"];
  }
}
@end

// ---- Remap sheet: press a button on the controller for each GameCube control
@interface MURemapController : UIViewController
@property(nonatomic) host::ControllerConfig config;
@property(nonatomic, copy) NSString* controllerName;
@property(nonatomic, copy) void (^onChange)(host::ControllerConfig);
@property(nonatomic) NSMutableArray<UIButton*>* rows;
@property(nonatomic) int capturing;
@property(nonatomic) BOOL armed;
@property(nonatomic) NSTimer* timer;
@end
@implementation MURemapController
- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = rgb(0.05, 0.06, 0.16);
  self.capturing = -1;
  UIScrollView* scroll = [[UIScrollView alloc] init];
  scroll.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:scroll];
  UIStackView* stack = [[UIStackView alloc] init];
  stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 10; stack.translatesAutoresizingMaskIntoConstraints = NO;
  [scroll addSubview:stack];
  [NSLayoutConstraint activateConstraints:@[
    [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor], [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:24], [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
    [stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:24], [stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-24]]];
  UILabel* title = [[UILabel alloc] init];
  title.text = [NSString stringWithFormat:@"Remap %@", self.controllerName];
  title.font = meleeFont(28, UIFontWeightBold); title.textColor = UIColor.whiteColor;
  UILabel* hint = [[UILabel alloc] init];
  hint.text = @"Tap a GameCube control, then press the button you want on your controller. Triggers can be bound to analog triggers or any button.";
  hint.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote]; hint.textColor = [UIColor colorWithWhite:1 alpha:0.6]; hint.numberOfLines = 0;
  [stack addArrangedSubview:title]; [stack addArrangedSubview:hint];
  self.rows = [NSMutableArray array];
  for (int i = 0; i < host::GC_CTL_COUNT; ++i) {
    UIButtonConfiguration* c = [UIButtonConfiguration grayButtonConfiguration];
    c.cornerStyle = UIButtonConfigurationCornerStyleLarge; c.baseForegroundColor = UIColor.whiteColor;
    c.contentInsets = NSDirectionalEdgeInsetsMake(12, 16, 12, 16);
    UIButton* b = [UIButton buttonWithConfiguration:c primaryAction:nil];
    b.tag = i; b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    [b addTarget:self action:@selector(startCapture:) forControlEvents:UIControlEventTouchUpInside];
    [self.rows addObject:b]; [stack addArrangedSubview:b];
  }
  UIStackView* actions = [[UIStackView alloc] init];
  actions.axis = UILayoutConstraintAxisHorizontal; actions.spacing = 12; actions.distribution = UIStackViewDistributionFillEqually;
  UIButtonConfiguration* rc = [UIButtonConfiguration grayButtonConfiguration]; rc.title = @"Reset to default"; rc.cornerStyle = UIButtonConfigurationCornerStyleLarge;
  UIButton* reset = [UIButton buttonWithConfiguration:rc primaryAction:nil];
  [reset addTarget:self action:@selector(resetMapping) forControlEvents:UIControlEventTouchUpInside];
  UIButtonConfiguration* sc = [UIButtonConfiguration grayButtonConfiguration]; sc.title = @"Swap sticks"; sc.cornerStyle = UIButtonConfigurationCornerStyleLarge;
  UIButton* swap = [UIButton buttonWithConfiguration:sc primaryAction:nil];
  [swap addTarget:self action:@selector(swapSticks) forControlEvents:UIControlEventTouchUpInside];
  UIButtonConfiguration* dc = [UIButtonConfiguration filledButtonConfiguration]; dc.title = @"Done"; dc.cornerStyle = UIButtonConfigurationCornerStyleLarge; dc.baseBackgroundColor = kYellow(); dc.baseForegroundColor = UIColor.blackColor;
  UIButton* done = [UIButton buttonWithConfiguration:dc primaryAction:nil];
  [done addTarget:self action:@selector(finish) forControlEvents:UIControlEventTouchUpInside];
  [actions addArrangedSubview:reset]; [actions addArrangedSubview:swap]; [actions addArrangedSubview:done];
  [stack addArrangedSubview:actions];
  [self refresh];
  self.timer = [NSTimer scheduledTimerWithTimeInterval:0.03 target:self selector:@selector(poll) userInfo:nil repeats:YES];
}
- (void)viewDidDisappear:(BOOL)animated { [super viewDidDisappear:animated]; [self.timer invalidate]; self.timer = nil; }
- (void)refresh {
  for (int i = 0; i < host::GC_CTL_COUNT; ++i) {
    UIButton* b = self.rows[i];
    UIButtonConfiguration* c = b.configuration;
    NSString* bound = self.capturing == i ? @"Press a button…" : ns(host::physical_input_name(self.config.map.binding[i]));
    NSMutableAttributedString* t = [[NSMutableAttributedString alloc] initWithString:[NSString stringWithFormat:@"%s", host::kGcControlNames[i]] attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold], NSForegroundColorAttributeName: UIColor.whiteColor}];
    [t appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"    %@", bound] attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:15], NSForegroundColorAttributeName: self.capturing == i ? kYellow() : [UIColor colorWithWhite:1 alpha:0.6]}]];
    c.attributedTitle = t;
    c.baseBackgroundColor = self.capturing == i ? rgb(0.97, 0.79, 0.28, 0.25) : [UIColor colorWithWhite:1 alpha:0.08];
    b.configuration = c;
  }
}
- (void)startCapture:(UIButton*)sender { self.capturing = (int)sender.tag; self.armed = NO; [self refresh]; }
- (void)poll {
  if (self.capturing < 0) return;
  const int input = host::window_capture_input(self.config.guid);
  if (!self.armed) { if (input == host::kUnbound) self.armed = YES; return; }   // wait for everything to be released first
  if (input == host::kUnbound) return;
  _config.map.binding[self.capturing] = input;
  self.capturing = -1;
  host::upsert_controller_config(self.config);
  if (self.onChange) self.onChange(self.config);
  [self refresh];
}
- (void)resetMapping { _config.map = host::ControllerMap::defaults(); host::upsert_controller_config(self.config); if (self.onChange) self.onChange(self.config); [self refresh]; }
- (void)swapSticks { _config.map.swap_sticks = !_config.map.swap_sticks; host::upsert_controller_config(self.config); if (self.onChange) self.onChange(self.config); }
- (void)finish { [self dismissViewControllerAnimated:YES completion:nil]; }
@end

// ---- Dashboard
@interface MULauncherController : UIViewController <UIDocumentPickerDelegate, UITextFieldDelegate>
@property(nonatomic) host::LauncherSettings* settings;
@property(nonatomic) host::Dashboard dashboard;
@property(nonatomic) BOOL done, playPressed, busy;
@property(nonatomic) UIScrollView* scroll;
@property(nonatomic) UIStackView* stack;
@property(nonatomic) NSArray<UIView*>* entrance;
@property(nonatomic, copy) NSString* startupError;
// hero
@property(nonatomic) UILabel* playerChip;
// steps
@property(nonatomic) UIView* stepsCard; @property(nonatomic) NSArray<UILabel*>* stepLabels; @property(nonatomic) NSArray<UIImageView*>* stepIcons;
// disc
@property(nonatomic) UILabel* discLabel; @property(nonatomic) UILabel* hintLabel;
// account
@property(nonatomic) UIView* accountCard; @property(nonatomic) UILabel* accountLabel; @property(nonatomic) UIStackView* signInRows; @property(nonatomic) UITextField* emailField; @property(nonatomic) UITextField* passwordField; @property(nonatomic) UIButton* signInButton; @property(nonatomic) UIButton* signOutButton;
// ranked
@property(nonatomic) UIView* rankedCard; @property(nonatomic) UILabel* rankLabel; @property(nonatomic) UILabel* ratingLabel; @property(nonatomic) UILabel* recordLabel; @property(nonatomic) UIView* winBar; @property(nonatomic) NSLayoutConstraint* winBarWidth; @property(nonatomic) UILabel* placementLabel; @property(nonatomic) UILabel* mainsLabel;
// games
@property(nonatomic) UIView* gamesCard; @property(nonatomic) UIStackView* gamesStack;
// controllers
@property(nonatomic) UIStackView* controllersStack; @property(nonatomic) NSTimer* controllerTimer; @property(nonatomic) NSUInteger controllerCount;
// display
@property(nonatomic) UISegmentedControl* scaleControl; @property(nonatomic) UISegmentedControl* anisoControl; @property(nonatomic) UISwitch* vsyncSwitch; @property(nonatomic) UISwitch* widescreenSwitch; @property(nonatomic) UISlider* sharpnessSlider; @property(nonatomic) UISwitch* onlineSwitch;
@property(nonatomic) UISlider* overlaySlider; @property(nonatomic) UISlider* overlayScaleSlider;
@property(nonatomic) UIButton* playButton;
@end

@implementation MULauncherController
- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = rgb(0.03, 0.03, 0.09);
  MUBackdropView* backdrop = [[MUBackdropView alloc] initWithFrame:self.view.bounds];
  [self.view addSubview:backdrop];
  [NSLayoutConstraint activateConstraints:@[[backdrop.topAnchor constraintEqualToAnchor:self.view.topAnchor], [backdrop.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
                                            [backdrop.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [backdrop.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]]];
  self.scroll = [[UIScrollView alloc] init];
  self.scroll.translatesAutoresizingMaskIntoConstraints = NO;
#if !TARGET_OS_VISION
  self.scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
#endif
  [self.view addSubview:self.scroll];
  self.stack = [[UIStackView alloc] init];
  self.stack.axis = UILayoutConstraintAxisVertical; self.stack.spacing = 16; self.stack.translatesAutoresizingMaskIntoConstraints = NO;
  [self.scroll addSubview:self.stack];
  [NSLayoutConstraint activateConstraints:@[
    [self.scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor], [self.scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    [self.scroll.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor], [self.scroll.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
    [self.stack.topAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.topAnchor constant:44], [self.stack.bottomAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.bottomAnchor constant:-48],
    [self.stack.centerXAnchor constraintEqualToAnchor:self.scroll.frameLayoutGuide.centerXAnchor], [self.stack.widthAnchor constraintLessThanOrEqualToConstant:640]]];
  NSLayoutConstraint* width = [self.stack.widthAnchor constraintEqualToAnchor:self.scroll.frameLayoutGuide.widthAnchor constant:-40];
  width.priority = UILayoutPriorityDefaultHigh; width.active = YES;
  UITapGestureRecognizer* tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
  tap.cancelsTouchesInView = NO; [self.view addGestureRecognizer:tap];

  UIView* hero = [self buildHero];
  self.stepsCard = [self buildSteps];
  UIView* disc = [self buildDisc];
  self.accountCard = [self buildAccount];
  self.rankedCard = [self buildRanked];
  self.gamesCard = [self buildGames];
  UIView* controllers = [self buildControllers];
  UIView* display = [self buildDisplay];
  UIView* touch = [self buildTouch];
  self.playButton = [self button:@"PLAY" symbol:@"play.fill" prominent:YES];
  [self.playButton addTarget:self action:@selector(play) forControlEvents:UIControlEventTouchUpInside];
  UILabel* footer = [[UILabel alloc] init];
  footer.text = @"Needs your own Super Smash Bros. Melee NTSC 1.02 disc image. Nothing from the game ships with the app. Unofficial; not affiliated with the Slippi team or Nintendo.";
  footer.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1]; footer.textColor = [UIColor colorWithWhite:1 alpha:0.45]; footer.numberOfLines = 0; footer.textAlignment = NSTextAlignmentCenter;
  for (UIView* v in @[hero, self.stepsCard, self.rankedCard, self.gamesCard, self.accountCard, disc, controllers, display, touch, self.playButton, footer]) [self.stack addArrangedSubview:v];
  [self.stack setCustomSpacing:28 afterView:hero];
  self.entrance = @[hero, self.stepsCard, self.rankedCard, self.gamesCard, self.accountCard, disc, controllers, display, touch, self.playButton];
  for (UIView* v in self.entrance) { v.alpha = 0; v.transform = CGAffineTransformMakeTranslation(0, 24); }
  [self refreshDisc]; [self refreshAccount]; [self refreshControllers]; [self refreshSteps];
  [self loadDashboard];
  self.controllerTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(controllerTick) userInfo:nil repeats:YES];
#if !TARGET_OS_VISION
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(keyboardChanged:) name:UIKeyboardWillChangeFrameNotification object:nil];
#endif
}
- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  NSTimeInterval delay = 0.1;
  for (UIView* v in self.entrance) {
    [UIView animateWithDuration:0.7 delay:delay usingSpringWithDamping:0.82 initialSpringVelocity:0.4 options:UIViewAnimationOptionAllowUserInteraction animations:^{ v.alpha = 1; v.transform = CGAffineTransformIdentity; } completion:nil];
    delay += 0.06;
  }
  if (const char* scroll = std::getenv("MELEE_LAUNCHER_SCROLL"))   // screenshot aid: start scrolled down by N points
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self.scroll setContentOffset:CGPointMake(0, std::atof(scroll)) animated:NO]; });
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    CABasicAnimation* breathe = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    breathe.fromValue = @1.0; breathe.toValue = @1.02; breathe.duration = 1.6; breathe.autoreverses = YES; breathe.repeatCount = HUGE_VALF;
    breathe.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [self.playButton.layer addAnimation:breathe forKey:@"breathe"];
  });
}

// ---- building blocks
- (UIView*)panel {
  UIVisualEffectView* card = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
  card.layer.cornerRadius = 18; card.layer.cornerCurve = kCACornerCurveContinuous; card.clipsToBounds = YES;
  card.layer.borderWidth = 1; card.layer.borderColor = rgb(0.5, 0.6, 1.0, 0.14).CGColor;
  return card;
}
- (UIStackView*)stackIn:(UIView*)card {
  UIView* host = [card isKindOfClass:UIVisualEffectView.class] ? ((UIVisualEffectView*)card).contentView : card;
  UIStackView* s = [[UIStackView alloc] init];
  s.axis = UILayoutConstraintAxisVertical; s.spacing = 12; s.translatesAutoresizingMaskIntoConstraints = NO;
  [host addSubview:s];
  [NSLayoutConstraint activateConstraints:@[[s.topAnchor constraintEqualToAnchor:host.topAnchor constant:16], [s.bottomAnchor constraintEqualToAnchor:host.bottomAnchor constant:-18],
                                            [s.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:18], [s.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-18]]];
  return s;
}
// Melee's angled yellow menu bar as a section header.
- (UIView*)header:(NSString*)text symbol:(NSString*)symbol {
  UIView* bar = [[UIView alloc] init];
  bar.translatesAutoresizingMaskIntoConstraints = NO;
  [bar.heightAnchor constraintEqualToConstant:30].active = YES;
  CAShapeLayer* shape = [CAShapeLayer layer];
  shape.fillColor = kYellow().CGColor;
  bar.layer.mask = nil;
  [bar.layer insertSublayer:shape atIndex:0];
  UILabel* l = [[UILabel alloc] init];
  l.text = text; l.font = meleeFont(15, UIFontWeightBold); l.textColor = rgb(0.10, 0.08, 0.02);
  l.translatesAutoresizingMaskIntoConstraints = NO;
  UIImageView* icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
  icon.tintColor = rgb(0.10, 0.08, 0.02); icon.contentMode = UIViewContentModeScaleAspectFit; icon.translatesAutoresizingMaskIntoConstraints = NO;
  icon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightBold];
  [bar addSubview:icon]; [bar addSubview:l];
  [NSLayoutConstraint activateConstraints:@[[icon.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:16], [icon.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor], [icon.widthAnchor constraintEqualToConstant:18],
                                            [l.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:8], [l.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor], [l.trailingAnchor constraintLessThanOrEqualToAnchor:bar.trailingAnchor constant:-20]]];
  objc_setAssociatedObject(bar, "shape", shape, OBJC_ASSOCIATION_RETAIN);
  return bar;
}
- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  // angled header bars follow their width
  for (UIView* v in [self allSubviewsOf:self.stack]) {
    CAShapeLayer* shape = objc_getAssociatedObject(v, "shape");
    if (!shape) continue;
    const CGFloat w = v.bounds.size.width, h = v.bounds.size.height;
    UIBezierPath* p = [UIBezierPath bezierPath];
    [p moveToPoint:CGPointMake(0, 0)]; [p addLineToPoint:CGPointMake(w * 0.72, 0)]; [p addLineToPoint:CGPointMake(w * 0.72 - 14, h)]; [p addLineToPoint:CGPointMake(0, h)]; [p closePath];
    shape.path = p.CGPath;
  }
}
- (NSArray<UIView*>*)allSubviewsOf:(UIView*)v { NSMutableArray* a = [NSMutableArray array]; for (UIView* s in v.subviews) { [a addObject:s]; [a addObjectsFromArray:[self allSubviewsOf:s]]; } return a; }
- (UILabel*)label:(NSString*)text size:(CGFloat)size weight:(UIFontWeight)weight alpha:(CGFloat)alpha {
  UILabel* l = [[UILabel alloc] init];
  l.text = text; l.font = [UIFont systemFontOfSize:size weight:weight]; l.textColor = [UIColor colorWithWhite:1 alpha:alpha]; l.numberOfLines = 0;
  return l;
}
- (UIView*)row:(NSString*)text symbol:(NSString*)symbol control:(UIView*)control {
  UIStackView* row = [[UIStackView alloc] init];
  row.axis = UILayoutConstraintAxisHorizontal; row.spacing = 12; row.alignment = UIStackViewAlignmentCenter;
  UIImageView* icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
  icon.tintColor = kYellow(); icon.contentMode = UIViewContentModeScaleAspectFit;
  icon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightMedium];
  [icon.widthAnchor constraintEqualToConstant:24].active = YES; [icon setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
  UILabel* l = [self label:text size:16 weight:UIFontWeightRegular alpha:1];
  [l setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
  [row addArrangedSubview:icon]; [row addArrangedSubview:l]; [row addArrangedSubview:control];
  if ([control isKindOfClass:UISlider.class]) [control.widthAnchor constraintEqualToConstant:170].active = YES;
  return row;
}
- (UIButton*)button:(NSString*)title symbol:(NSString*)symbol prominent:(BOOL)prominent {
  UIButtonConfiguration* c = prominent ? [UIButtonConfiguration filledButtonConfiguration] : [UIButtonConfiguration grayButtonConfiguration];
  c.title = title; c.cornerStyle = UIButtonConfigurationCornerStyleLarge; c.image = [UIImage systemImageNamed:symbol]; c.imagePadding = 8;
  c.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightBold];
  c.contentInsets = NSDirectionalEdgeInsetsMake(prominent ? 18 : 12, 20, prominent ? 18 : 12, 20);
  if (prominent) { c.baseBackgroundColor = kYellow(); c.baseForegroundColor = rgb(0.1, 0.08, 0.02); } else c.baseForegroundColor = UIColor.whiteColor;
  UIButton* b = [UIButton buttonWithConfiguration:c primaryAction:nil];
  b.titleLabel.font = prominent ? meleeFont(22, UIFontWeightBold) : [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
  if (prominent) { b.layer.shadowColor = kYellow().CGColor; b.layer.shadowOpacity = 0.45; b.layer.shadowRadius = 18; b.layer.shadowOffset = CGSizeMake(0, 6); }
  return b;
}
- (UITextField*)field:(NSString*)placeholder symbol:(NSString*)symbol secure:(BOOL)secure {
  UITextField* f = [[UITextField alloc] init];
  f.attributedPlaceholder = [[NSAttributedString alloc] initWithString:placeholder attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.35]}];
  f.textColor = UIColor.whiteColor; f.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
  f.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08]; f.layer.cornerRadius = 12; f.layer.cornerCurve = kCACornerCurveContinuous;
  f.secureTextEntry = secure; f.autocapitalizationType = UITextAutocapitalizationTypeNone; f.autocorrectionType = UITextAutocorrectionTypeNo; f.delegate = self;
  UIImageView* icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
  icon.tintColor = [UIColor colorWithWhite:1 alpha:0.5]; icon.contentMode = UIViewContentModeCenter; icon.frame = CGRectMake(0, 0, 40, 46);
  f.leftView = icon; f.leftViewMode = UITextFieldViewModeAlways;
  [f.heightAnchor constraintEqualToConstant:46].active = YES;
  return f;
}
- (UISegmentedControl*)segments:(NSArray<NSString*>*)items selected:(NSInteger)index {
  UISegmentedControl* s = [[UISegmentedControl alloc] initWithItems:items];
  s.selectedSegmentIndex = index; s.selectedSegmentTintColor = kYellow();
  [s setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor} forState:UIControlStateNormal];
  [s setTitleTextAttributes:@{NSForegroundColorAttributeName: rgb(0.1, 0.08, 0.02)} forState:UIControlStateSelected];
  return s;
}

// ---- sections
- (UIView*)buildHero {
  UIStackView* hero = [[UIStackView alloc] init];
  hero.axis = UILayoutConstraintAxisVertical; hero.alignment = UIStackViewAlignmentCenter; hero.spacing = 8;
  [hero addArrangedSubview:[[MUHeroView alloc] initWithSize:120]];
  UILabel* title = [[UILabel alloc] init];
  title.text = @"iSlippi"; title.font = meleeFont(52, UIFontWeightBlack); title.textColor = UIColor.whiteColor;
  title.layer.shadowColor = kYellow().CGColor; title.layer.shadowOpacity = 0.5; title.layer.shadowRadius = 14; title.layer.shadowOffset = CGSizeZero;
  UILabel* sub = [self label:@"SUPER SMASH BROS. MELEE  ·  SLIPPI ONLINE  ·  NATIVE" size:12 weight:UIFontWeightSemibold alpha:0.6];
  self.playerChip = [[UILabel alloc] init];
  self.playerChip.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold]; self.playerChip.textColor = rgb(0.1, 0.08, 0.02); self.playerChip.textAlignment = NSTextAlignmentCenter;
  self.playerChip.backgroundColor = kYellow(); self.playerChip.layer.cornerRadius = 15; self.playerChip.clipsToBounds = YES;
  [self.playerChip.heightAnchor constraintEqualToConstant:30].active = YES;
  self.playerChip.hidden = YES;
  UIView* chipWrap = [[UIView alloc] init];
  self.playerChip.translatesAutoresizingMaskIntoConstraints = NO;
  [chipWrap addSubview:self.playerChip];
  [NSLayoutConstraint activateConstraints:@[[self.playerChip.topAnchor constraintEqualToAnchor:chipWrap.topAnchor], [self.playerChip.bottomAnchor constraintEqualToAnchor:chipWrap.bottomAnchor],
                                            [self.playerChip.leadingAnchor constraintEqualToAnchor:chipWrap.leadingAnchor constant:-14], [self.playerChip.trailingAnchor constraintEqualToAnchor:chipWrap.trailingAnchor constant:14]]];
  [hero addArrangedSubview:title]; [hero addArrangedSubview:sub]; [hero addArrangedSubview:chipWrap];
  [hero setCustomSpacing:14 afterView:sub];
  return hero;
}
- (UIView*)buildSteps {
  UIView* card = [self panel];
  UIStackView* s = [self stackIn:card];
  [s addArrangedSubview:[self header:@"GET STARTED" symbol:@"flag.checkered"]];
  NSArray* names = @[@"Add your Melee disc image", @"Sign in to Slippi Online", @"Connect a controller (touch works too)", @"Press Play"];
  NSMutableArray* labels = [NSMutableArray array]; NSMutableArray* icons = [NSMutableArray array];
  for (NSString* n in names) {
    UIStackView* row = [[UIStackView alloc] init]; row.axis = UILayoutConstraintAxisHorizontal; row.spacing = 12; row.alignment = UIStackViewAlignmentCenter;
    UIImageView* icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"circle"]];
    icon.tintColor = [UIColor colorWithWhite:1 alpha:0.4]; icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightSemibold];
    [icon.widthAnchor constraintEqualToConstant:24].active = YES; [icon setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UILabel* l = [self label:n size:16 weight:UIFontWeightRegular alpha:0.9];
    [row addArrangedSubview:icon]; [row addArrangedSubview:l]; [s addArrangedSubview:row];
    [labels addObject:l]; [icons addObject:icon];
  }
  self.stepLabels = labels; self.stepIcons = icons;
  return card;
}
- (UIView*)buildDisc {
  UIView* card = [self panel];
  UIStackView* s = [self stackIn:card];
  [s addArrangedSubview:[self header:@"GAME DISC" symbol:@"opticaldisc"]];
  self.discLabel = [self label:@"" size:20 weight:UIFontWeightSemibold alpha:1];
  self.hintLabel = [self label:@"" size:13 weight:UIFontWeightRegular alpha:0.6];
  UIButton* import_ = [self button:@"Import Disc Image" symbol:@"square.and.arrow.down" prominent:NO];
  [import_ addTarget:self action:@selector(importDisc) forControlEvents:UIControlEventTouchUpInside];
  [s addArrangedSubview:self.discLabel]; [s addArrangedSubview:self.hintLabel]; [s addArrangedSubview:import_];
  return card;
}
- (UIView*)buildAccount {
  UIView* card = [self panel];
  UIStackView* s = [self stackIn:card];
  [s addArrangedSubview:[self header:@"SLIPPI ONLINE ACCOUNT" symbol:@"person.crop.circle"]];
  self.accountLabel = [self label:@"" size:16 weight:UIFontWeightRegular alpha:1];
  [s addArrangedSubview:self.accountLabel];
  self.signInRows = [[UIStackView alloc] init]; self.signInRows.axis = UILayoutConstraintAxisVertical; self.signInRows.spacing = 10;
  self.emailField = [self field:@"Email" symbol:@"envelope" secure:NO]; self.emailField.keyboardType = UIKeyboardTypeEmailAddress; self.emailField.textContentType = UITextContentTypeUsername; self.emailField.returnKeyType = UIReturnKeyNext;
  self.passwordField = [self field:@"Password" symbol:@"key" secure:YES]; self.passwordField.textContentType = UITextContentTypePassword; self.passwordField.returnKeyType = UIReturnKeyGo;
  self.signInButton = [self button:@"Sign In" symbol:@"person.badge.key" prominent:NO];
  [self.signInButton addTarget:self action:@selector(signIn) forControlEvents:UIControlEventTouchUpInside];
  UIButton* reset = [UIButton buttonWithType:UIButtonTypeSystem];
  [reset setTitle:@"Forgot password · Create an account at slippi.gg" forState:UIControlStateNormal];
  reset.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote]; reset.tintColor = kYellow();
  [reset addTarget:self action:@selector(forgotPassword) forControlEvents:UIControlEventTouchUpInside];
  for (UIView* v in @[self.emailField, self.passwordField, self.signInButton, reset]) [self.signInRows addArrangedSubview:v];
  [s addArrangedSubview:self.signInRows];
  self.signOutButton = [self button:@"Sign Out" symbol:@"rectangle.portrait.and.arrow.right" prominent:NO];
  [self.signOutButton addTarget:self action:@selector(signOut) forControlEvents:UIControlEventTouchUpInside];
  [s addArrangedSubview:self.signOutButton];
  return card;
}
- (UIView*)buildRanked {
  UIView* card = [self panel];
  ((UIView*)card).layer.borderColor = rgb(0.97, 0.79, 0.28, 0.35).CGColor;
  UIStackView* s = [self stackIn:card];
  [s addArrangedSubview:[self header:@"RANKED" symbol:@"trophy"]];
  UIStackView* top = [[UIStackView alloc] init]; top.axis = UILayoutConstraintAxisHorizontal; top.alignment = UIStackViewAlignmentFirstBaseline; top.spacing = 12;
  self.rankLabel = [[UILabel alloc] init]; self.rankLabel.font = meleeFont(34, UIFontWeightBlack); self.rankLabel.textColor = kYellow();
  self.ratingLabel = [[UILabel alloc] init]; self.ratingLabel.font = [UIFont monospacedDigitSystemFontOfSize:22 weight:UIFontWeightSemibold]; self.ratingLabel.textColor = UIColor.whiteColor;
  UIView* spacer = [[UIView alloc] init]; [spacer setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
  [top addArrangedSubview:self.rankLabel]; [top addArrangedSubview:spacer]; [top addArrangedSubview:self.ratingLabel];
  self.recordLabel = [self label:@"" size:15 weight:UIFontWeightMedium alpha:0.9];
  UIView* track = [[UIView alloc] init]; track.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12]; track.layer.cornerRadius = 4; track.clipsToBounds = YES;
  [track.heightAnchor constraintEqualToConstant:8].active = YES;
  self.winBar = [[UIView alloc] init]; self.winBar.backgroundColor = rgb(0.30, 0.85, 0.45); self.winBar.translatesAutoresizingMaskIntoConstraints = NO;
  [track addSubview:self.winBar];
  self.winBarWidth = [self.winBar.widthAnchor constraintEqualToAnchor:track.widthAnchor multiplier:0.0];
  [NSLayoutConstraint activateConstraints:@[[self.winBar.leadingAnchor constraintEqualToAnchor:track.leadingAnchor], [self.winBar.topAnchor constraintEqualToAnchor:track.topAnchor], [self.winBar.bottomAnchor constraintEqualToAnchor:track.bottomAnchor], self.winBarWidth]];
  self.placementLabel = [self label:@"" size:14 weight:UIFontWeightRegular alpha:0.7];
  self.mainsLabel = [self label:@"" size:14 weight:UIFontWeightRegular alpha:0.85];
  for (UIView* v in @[top, self.recordLabel, track, self.placementLabel, self.mainsLabel]) [s addArrangedSubview:v];
  return card;
}
- (UIView*)buildGames {
  UIView* card = [self panel];
  UIStackView* s = [self stackIn:card];
  [s addArrangedSubview:[self header:@"RECENT GAMES" symbol:@"clock.arrow.circlepath"]];
  self.gamesStack = [[UIStackView alloc] init]; self.gamesStack.axis = UILayoutConstraintAxisVertical; self.gamesStack.spacing = 8;
  [s addArrangedSubview:self.gamesStack];
  return card;
}
- (UIView*)buildControllers {
  UIView* card = [self panel];
  UIStackView* s = [self stackIn:card];
  [s addArrangedSubview:[self header:@"CONTROLLERS" symbol:@"gamecontroller"]];
  self.controllersStack = [[UIStackView alloc] init]; self.controllersStack.axis = UILayoutConstraintAxisVertical; self.controllersStack.spacing = 10;
  [s addArrangedSubview:self.controllersStack];
  UILabel* help = [self label:@"Bluetooth and USB-C controllers (PlayStation, Xbox, Switch Pro, MFi) connect through iPadOS Settings › Bluetooth or a cable, then appear here. Assign each one a GameCube port and remap buttons. The on-screen controller hides itself while a controller is connected." size:13 weight:UIFontWeightRegular alpha:0.6];
  [s addArrangedSubview:help];
  return card;
}
- (UIView*)buildDisplay {
  UIView* card = [self panel];
  UIStackView* s = [self stackIn:card];
  [s addArrangedSubview:[self header:@"DISPLAY & PERFORMANCE" symbol:@"speedometer"]];
  id<MTLDevice> gpu = MTLCreateSystemDefaultDevice();
  NSString* info = [NSString stringWithFormat:@"%@  ·  %d Hz display  ·  60 Hz simulation, frames shown on the next refresh", gpu ? gpu.name : @"Metal", display_max_hz()];
  UILabel* infoLabel = [self label:info size:13 weight:UIFontWeightRegular alpha:0.7];
  [s addArrangedSubview:infoLabel];
  const int scales[] = {0, 1, 2, 3, 4, 6, 8}; NSInteger scaleIndex = 0;
  for (int i = 0; i < 7; ++i) if (scales[i] == self.settings->scale) scaleIndex = i;
  self.scaleControl = [self segments:@[@"Auto", @"1×", @"2×", @"3×", @"4×", @"6×", @"8×"] selected:scaleIndex];
  [s addArrangedSubview:[self label:@"Internal resolution" size:14 weight:UIFontWeightMedium alpha:0.8]];
  [s addArrangedSubview:self.scaleControl];
  self.anisoControl = [self segments:@[@"Off", @"4×", @"16×"] selected:self.settings->anisotropy >= 16 ? 2 : self.settings->anisotropy >= 4 ? 1 : 0];
  [s addArrangedSubview:[self row:@"Anisotropic filtering" symbol:@"square.stack.3d.up" control:self.anisoControl]];
  self.vsyncSwitch = [[UISwitch alloc] init]; self.vsyncSwitch.on = self.settings->vsync; self.vsyncSwitch.onTintColor = kYellow();
  [s addArrangedSubview:[self row:@"Display sync (off = lowest latency, may tear)" symbol:@"waveform.path" control:self.vsyncSwitch]];
  self.widescreenSwitch = [[UISwitch alloc] init]; self.widescreenSwitch.on = self.settings->widescreen; self.widescreenSwitch.onTintColor = kYellow();
  [s addArrangedSubview:[self row:@"Widescreen (16:9)" symbol:@"rectangle.ratio.16.to.9" control:self.widescreenSwitch]];
  self.sharpnessSlider = [[UISlider alloc] init]; self.sharpnessSlider.value = self.settings->sharpness; self.sharpnessSlider.tintColor = kYellow();
  [s addArrangedSubview:[self row:@"Sharpen" symbol:@"sparkles" control:self.sharpnessSlider]];
  self.onlineSwitch = [[UISwitch alloc] init]; self.onlineSwitch.on = self.settings->online; self.onlineSwitch.onTintColor = kYellow();
  [s addArrangedSubview:[self row:@"Slippi Online services" symbol:@"network" control:self.onlineSwitch]];
  return card;
}
- (UIView*)buildTouch {
  UIView* card = [self panel];
  UIStackView* s = [self stackIn:card];
  [s addArrangedSubview:[self header:@"ON-SCREEN CONTROLS" symbol:@"hand.tap"]];
  self.overlaySlider = [[UISlider alloc] init]; self.overlaySlider.value = self.settings->overlay_opacity; self.overlaySlider.tintColor = kYellow();
  [s addArrangedSubview:[self row:@"Opacity" symbol:@"circle.lefthalf.filled" control:self.overlaySlider]];
  self.overlayScaleSlider = [[UISlider alloc] init]; self.overlayScaleSlider.minimumValue = 0.7; self.overlayScaleSlider.maximumValue = 1.4; self.overlayScaleSlider.value = self.settings->overlay_scale; self.overlayScaleSlider.tintColor = kYellow();
  [s addArrangedSubview:[self row:@"Size" symbol:@"arrow.up.left.and.arrow.down.right" control:self.overlayScaleSlider]];
  return card;
}

// ---- state
- (void)refreshSteps {
  const BOOL disc = !self.settings->iso.empty(), account = self.dashboard.signed_in, pad = self.controllerCount > 0;
  const BOOL states[4] = {disc, account, pad, NO};
  BOOL allDone = disc && account;
  for (int i = 0; i < 4; ++i) {
    UIImageView* icon = self.stepIcons[i];
    icon.image = [UIImage systemImageNamed:states[i] ? @"checkmark.circle.fill" : (i == 2 ? @"circle.dashed" : @"circle")];
    icon.tintColor = states[i] ? rgb(0.30, 0.85, 0.45) : [UIColor colorWithWhite:1 alpha:0.4];
    self.stepLabels[i].alpha = states[i] ? 0.5 : 0.95;
  }
  self.stepsCard.hidden = allDone;
}
- (void)refreshAccount {
  if (!self.settings) return;
  slippi::login::Account account;
  bool signed_in = slippi::login::read_user_file(self.settings->slippi_dir, account);
  if (!signed_in && _dashboard.profile_loaded && _dashboard.signed_in) { signed_in = true; account.display_name = _dashboard.name; account.connect_code = _dashboard.code; }   // sample data
  _dashboard.signed_in = signed_in;
  if (signed_in) {
    self.settings->account_name = account.display_name; self.settings->account_code = account.connect_code;
    if (_dashboard.name.empty()) { _dashboard.name = account.display_name; _dashboard.code = account.connect_code; }
    self.accountLabel.text = [NSString stringWithFormat:@"Signed in as %s  (%s). Ranked stats and your connect code stay saved on this device.", account.display_name.c_str(), account.connect_code.c_str()];
    self.playerChip.text = [NSString stringWithFormat:@"%s  %s", account.display_name.c_str(), account.connect_code.c_str()];
    self.playerChip.hidden = NO;
  } else {
    self.settings->account_name.clear(); self.settings->account_code.clear();
    self.accountLabel.text = @"Sign in with your Slippi account to play online and see your ranked stats. Offline play works without it.";
    self.playerChip.hidden = YES;
  }
  self.signInRows.hidden = signed_in; self.signOutButton.hidden = !signed_in;
  self.rankedCard.hidden = !signed_in;
  [self refreshRanked]; [self refreshSteps];
}
- (void)refreshRanked {
  const host::Dashboard& d = self.dashboard;
  self.rankLabel.text = ns(d.rank());
  self.ratingLabel.text = ns(d.rating());
  self.recordLabel.text = d.profile_loaded ? ns(d.record()) : (d.profile_error.empty() ? @"Loading ranked profile…" : ns(d.profile_error));
  self.winBarWidth.active = NO;
  self.winBarWidth = [self.winBar.widthAnchor constraintEqualToAnchor:self.winBar.superview.widthAnchor multiplier:MAX(0.0, MIN(1.0, d.win_rate()))];
  self.winBarWidth.active = YES;
  self.placementLabel.text = ns(d.placement());
  std::string mains;
  for (const std::string& m : d.mains()) mains += (mains.empty() ? "Mains: " : "   ") + m;
  self.mainsLabel.text = ns(mains);
  self.placementLabel.hidden = self.placementLabel.text.length == 0; self.mainsLabel.hidden = mains.empty();
  if (d.profile_loaded && d.profile.ranked) self.playerChip.text = [NSString stringWithFormat:@"%s  %s  ·  %s", d.name.c_str(), d.code.c_str(), d.rank().c_str()];
}
- (void)refreshGames {
  for (UIView* v in self.gamesStack.arrangedSubviews) [v removeFromSuperview];
  std::vector<host::GameRow> rows = self.dashboard.rows();
  self.gamesCard.hidden = rows.empty();
  for (const host::GameRow& r : rows) {
    UIStackView* row = [[UIStackView alloc] init]; row.axis = UILayoutConstraintAxisHorizontal; row.spacing = 10; row.alignment = UIStackViewAlignmentCenter;
    UIStackView* text = [[UIStackView alloc] init]; text.axis = UILayoutConstraintAxisVertical; text.spacing = 2;
    [text addArrangedSubview:[self label:ns(r.title) size:15 weight:UIFontWeightSemibold alpha:1]];
    [text addArrangedSubview:[self label:ns(r.subtitle) size:12 weight:UIFontWeightRegular alpha:0.6]];
    UILabel* result = [[UILabel alloc] init];
    result.text = ns(r.result); result.font = meleeFont(14, UIFontWeightBold); result.textAlignment = NSTextAlignmentCenter;
    result.textColor = r.win ? rgb(0.30, 0.85, 0.45) : r.loss ? kRed() : [UIColor colorWithWhite:1 alpha:0.6];
    [result setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [row addArrangedSubview:text]; [row addArrangedSubview:result];
    [self.gamesStack addArrangedSubview:row];
  }
}
- (void)refreshControllers {
  std::vector<host::ControllerInfo> pads = host::window_list_controllers();
  self.controllerCount = pads.size();
  for (UIView* v in self.controllersStack.arrangedSubviews) [v removeFromSuperview];
  if (pads.empty()) {
    [self.controllersStack addArrangedSubview:[self label:@"No controller connected. Touch controls are ready." size:15 weight:UIFontWeightRegular alpha:0.7]];
  }
  for (size_t i = 0; i < pads.size(); ++i) {
    const host::ControllerInfo& pad = pads[i];
    UIStackView* row = [[UIStackView alloc] init]; row.axis = UILayoutConstraintAxisHorizontal; row.spacing = 10; row.alignment = UIStackViewAlignmentCenter;
    UIImageView* icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"gamecontroller.fill"]];
    icon.tintColor = kYellow(); icon.contentMode = UIViewContentModeScaleAspectFit; [icon.widthAnchor constraintEqualToConstant:26].active = YES;
    [icon setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UILabel* name = [self label:ns(pad.name) size:15 weight:UIFontWeightSemibold alpha:1];
    [name setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    NSMutableArray<UIAction*>* ports = [NSMutableArray array];
    NSString* guid = ns(pad.guid);
    for (int p = 0; p <= 4; ++p) {
      NSString* title = p == 0 ? @"Auto port" : [NSString stringWithFormat:@"Port %d", p];
      UIAction* a = [UIAction actionWithTitle:title image:nil identifier:nil handler:^(UIAction*) {
        host::ControllerConfig cfg; if (const host::ControllerConfig* c = host::controller_config_for(guid.UTF8String)) cfg = *c;
        cfg.guid = guid.UTF8String; cfg.port = p; host::upsert_controller_config(cfg); [self refreshControllers]; }];
      if (p == pad.assigned_port) a.state = UIMenuElementStateOn;
      [ports addObject:a];
    }
    UIButtonConfiguration* pc = [UIButtonConfiguration grayButtonConfiguration];
    pc.title = pad.assigned_port ? [NSString stringWithFormat:@"Port %d", pad.assigned_port] : @"Auto"; pc.baseForegroundColor = UIColor.whiteColor; pc.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    UIButton* portButton = [UIButton buttonWithConfiguration:pc primaryAction:nil];
    portButton.menu = [UIMenu menuWithChildren:ports]; portButton.showsMenuAsPrimaryAction = YES;
    UIButtonConfiguration* rc = [UIButtonConfiguration grayButtonConfiguration];
    rc.title = @"Remap"; rc.image = [UIImage systemImageNamed:@"slider.horizontal.3"]; rc.imagePadding = 6; rc.baseForegroundColor = UIColor.whiteColor; rc.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    UIButton* remap = [UIButton buttonWithConfiguration:rc primaryAction:[UIAction actionWithHandler:^(UIAction*) {
      MURemapController* rm = [[MURemapController alloc] init];
      host::ControllerConfig cfg; if (const host::ControllerConfig* c = host::controller_config_for(guid.UTF8String)) cfg = *c; else { cfg.guid = guid.UTF8String; cfg.port = pad.assigned_port; }
      rm.config = cfg; rm.controllerName = name.text;
      rm.modalPresentationStyle = UIModalPresentationFormSheet;
      [self presentViewController:rm animated:YES completion:nil]; }]];
    [row addArrangedSubview:icon]; [row addArrangedSubview:name]; [row addArrangedSubview:portButton]; [row addArrangedSubview:remap];
    [self.controllersStack addArrangedSubview:row];
  }
  [self refreshSteps];
}
- (void)controllerTick { if (host::window_list_controllers().size() != self.controllerCount) [self refreshControllers]; }
- (void)refreshDisc {
  std::vector<std::string> discs = documents_discs(nullptr);
  if (!self.settings->iso.empty()) { bool present = false; for (const std::string& d : discs) if (d == self.settings->iso) present = true; if (!present) self.settings->iso.clear(); }
  if (self.settings->iso.empty() && !discs.empty()) self.settings->iso = discs.front();
  if (self.settings->iso.empty()) {
    self.discLabel.text = @"No disc image yet";
    self.hintLabel.text = self.startupError.length ? self.startupError : @"Import your .iso/.gcm here, or drop it into this app's folder in Files.";
    self.playButton.enabled = NO;
  } else {
    NSString* path = ns(self.settings->iso);
    NSDictionary* attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    self.discLabel.text = path.lastPathComponent;
    self.hintLabel.text = [NSString stringWithFormat:@"%.2f GB · ready to play%@", [attrs fileSize] / 1e9, self.startupError.length ? [@"\n" stringByAppendingString:self.startupError] : @""];
    self.playButton.enabled = YES;
  }
  [self refreshSteps];
}
- (void)loadDashboard {
  std::string slippi_dir = self.settings->slippi_dir, replay_dir = self.settings->replay_dir;
  __weak MULauncherController* weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    host::Dashboard d;
    host::dashboard_load_games(replay_dir, d, 8);
    host::dashboard_load_profile(slippi_dir, d);
    dispatch_async(dispatch_get_main_queue(), ^{
      MULauncherController* s = weakSelf; if (!s || s.done) return;
      host::Dashboard merged = d; merged.signed_in = s.dashboard.signed_in || d.profile_loaded;
      s.dashboard = merged; [s refreshAccount]; [s refreshGames];
    });
  });
}

// ---- actions
- (void)dismissKeyboard { [self.view endEditing:YES]; }
#if !TARGET_OS_VISION
- (void)keyboardChanged:(NSNotification*)note {
  CGRect end = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
  CGRect inView = [self.view convertRect:end fromView:nil];
  CGFloat overlap = MAX(0, CGRectGetMaxY(self.view.bounds) - CGRectGetMinY(inView));
  UIEdgeInsets insets = self.scroll.contentInset; insets.bottom = overlap; self.scroll.contentInset = insets; self.scroll.verticalScrollIndicatorInsets = insets;
  if (overlap > 0 && self.passwordField.isFirstResponder) [self.scroll scrollRectToVisible:[self.scroll convertRect:self.signInRows.bounds fromView:self.signInRows] animated:YES];
}
#endif
- (BOOL)textFieldShouldReturn:(UITextField*)field {
  if (field == self.emailField) { [self.passwordField becomeFirstResponder]; return NO; }
  [field resignFirstResponder]; [self signIn]; return YES;
}
- (void)setBusy:(BOOL)busy {
  _busy = busy;
  UIButtonConfiguration* c = self.signInButton.configuration; c.showsActivityIndicator = busy; c.title = busy ? @"Signing In…" : @"Sign In"; self.signInButton.configuration = c; self.signInButton.enabled = !busy;
}
- (void)signIn {
  if (self.busy) return;
  std::string email = self.emailField.text.UTF8String ?: "", password = self.passwordField.text.UTF8String ?: "";
  if (email.empty() || password.empty()) { self.accountLabel.text = @"Enter your Slippi email and password."; return; }
  [self.view endEditing:YES]; self.busy = YES; self.accountLabel.text = @"Signing in…";
  std::string dir = self.settings->slippi_dir;
  __weak MULauncherController* weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    slippi::login::Account account; slippi::login::Session session; std::string error;
    bool ok = slippi::login::sign_in_session(email, password, account, session, error) && slippi::login::write_user_file(dir, account, error);
    if (ok) slippi::login::write_session(dir, session);
    dispatch_async(dispatch_get_main_queue(), ^{
      MULauncherController* s = weakSelf; if (!s || s.done) return;
      s.busy = NO;
      if (ok) { s.passwordField.text = @""; s->_dashboard.name = account.display_name; s->_dashboard.code = account.connect_code; [s refreshAccount]; [s loadDashboard]; }
      else s.accountLabel.text = ns(error);
    });
  });
}
- (void)forgotPassword {
  std::string email = self.emailField.text.UTF8String ?: "";
  if (email.empty()) { [UIApplication.sharedApplication openURL:[NSURL URLWithString:@"https://slippi.gg"] options:@{} completionHandler:nil]; return; }
  self.accountLabel.text = @"Sending a password reset email…";
  __weak MULauncherController* weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    std::string error; bool ok = slippi::login::send_password_reset(email, error);
    dispatch_async(dispatch_get_main_queue(), ^{ MULauncherController* s = weakSelf; if (!s || s.done) return; s.accountLabel.text = ok ? @"Password reset email sent. Check your inbox." : ns(error); });
  });
}
- (void)signOut {
  if (!self.settings) return;
  slippi::login::remove_user_file(self.settings->slippi_dir); slippi::login::remove_session(self.settings->slippi_dir);
  self.dashboard = host::Dashboard(); [self refreshAccount]; [self refreshGames];
}
- (void)importDisc {
  NSMutableArray<UTType*>* types = [NSMutableArray array];
  for (NSString* ext in @[@"iso", @"gcm"]) { UTType* t = [UTType typeWithFilenameExtension:ext]; if (t) [types addObject:t]; }
  [types addObject:UTTypeData];
  UIDocumentPickerViewController* picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
  picker.delegate = self; [self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController*)controller didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
  NSURL* documents = nil; documents_discs(&documents);
  if (!documents || urls.count == 0) return;
  NSURL* dest = [documents URLByAppendingPathComponent:urls.firstObject.lastPathComponent];
  NSError* error = nil;
  [[NSFileManager defaultManager] removeItemAtURL:dest error:nil];
  if (![[NSFileManager defaultManager] moveItemAtURL:urls.firstObject toURL:dest error:&error]) self.startupError = [NSString stringWithFormat:@"Could not import: %@", error.localizedDescription];
  else { self.startupError = nil; self.settings->iso = std::string(dest.fileSystemRepresentation); }
  [self refreshDisc];
}
- (void)play {
  const int scales[] = {0, 1, 2, 3, 4, 6, 8};
  self.settings->scale = scales[MAX(0, MIN(6, self.scaleControl.selectedSegmentIndex))];
  self.settings->anisotropy = self.anisoControl.selectedSegmentIndex == 2 ? 16 : self.anisoControl.selectedSegmentIndex == 1 ? 4 : 1;
  self.settings->vsync = self.vsyncSwitch.on;
  self.settings->widescreen = self.widescreenSwitch.on;
  self.settings->online = self.onlineSwitch.on;
  self.settings->sharpness = self.sharpnessSlider.value;
  self.settings->overlay_opacity = self.overlaySlider.value;
  self.settings->overlay_scale = self.overlayScaleSlider.value;
  self.playPressed = YES;
  [self.playButton.layer removeAnimationForKey:@"breathe"];
  [UIView animateWithDuration:0.28 animations:^{ self.view.alpha = 0; self.view.transform = CGAffineTransformMakeScale(0.97, 0.97); } completion:nil];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ self.done = YES; });
}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
@end

namespace host {
void mac_show_error(const std::string& title, const std::string& detail) { std::fprintf(stderr, "%s: %s\n", title.c_str(), detail.c_str()); }

bool launcher_run(LauncherSettings& settings, const std::string& error) {
  @autoreleasepool {
    UIWindowScene* scene = nil;
    for (int wait = 0; wait < 200 && !scene; ++wait) {
      for (UIScene* s in UIApplication.sharedApplication.connectedScenes) if ([s isKindOfClass:UIWindowScene.class]) { scene = (UIWindowScene*)s; break; }
      if (!scene) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
    }
    if (!scene) std::fprintf(stderr, "launcher: no window scene connected after 10 s\n");
    UIWindow* window = nil;
    if (scene) window = [[UIWindow alloc] initWithWindowScene:scene];
#if !TARGET_OS_VISION
    if (!window) window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
#endif
    if (!window) return false;
    settings.display_hz = display_max_hz();
    MULauncherController* controller = [[MULauncherController alloc] init];
    controller.settings = &settings;
    controller.startupError = error.empty() ? nil : [NSString stringWithUTF8String:error.c_str()];
    window.rootViewController = controller;
    window.windowLevel = UIWindowLevelNormal + 1;
    [window makeKeyAndVisible];
    while (!controller.done) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
    [controller.controllerTimer invalidate];
    window.hidden = YES; window.rootViewController = nil;
    controller.settings = nullptr;
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
    return controller.playPressed;
  }
}
}  // namespace host
