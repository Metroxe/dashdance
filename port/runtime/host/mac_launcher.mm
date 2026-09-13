// macOS dashboard and launcher (AppKit + SceneKit). Melee-styled: dark grid backdrop, yellow
// angled section headers, italic display type. Shows the signed-in player's ranked profile and
// recent games, manages controllers (ports, remapping) and display settings, then starts play.
// Disc images can be dropped onto the window.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <SceneKit/SceneKit.h>
#import <objc/runtime.h>
#include "dashboard.h"
#include "input_config.h"
#include "mac_launcher.h"
#include "slippi_login.h"
#include <cstdlib>
#include <string>
#include <vector>

namespace {
void prepare_application() {
  [NSApplication sharedApplication];
  [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
  static bool launched = false;
  if (!launched) { [NSApp finishLaunching]; launched = true; }
  [NSApp activateIgnoringOtherApps:YES];
}
NSColor* rgb(CGFloat r, CGFloat g, CGFloat b, CGFloat a = 1) { return [NSColor colorWithSRGBRed:r green:g blue:b alpha:a]; }
NSColor* kYellow() { return rgb(0.97, 0.79, 0.28); }
NSColor* kInk() { return rgb(0.10, 0.08, 0.02); }
NSColor* kGreen() { return rgb(0.30, 0.85, 0.45); }
NSColor* kRed() { return rgb(0.89, 0.27, 0.17); }
NSString* ns(const std::string& s) { return [NSString stringWithUTF8String:s.c_str()]; }
NSImage* symbol(NSString* name, CGFloat size, NSFontWeight weight) {
  NSImage* image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
  return [image imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:size weight:weight]];
}
NSFont* meleeFont(CGFloat size) {
  NSFont* base = [NSFont systemFontOfSize:size weight:NSFontWeightBlack];
  NSFontDescriptor* d = [base.fontDescriptor fontDescriptorWithSymbolicTraits:NSFontDescriptorTraitItalic | NSFontDescriptorTraitBold];
  NSFont* f = d ? [NSFont fontWithDescriptor:d size:size] : nil;
  return f ?: base;
}
NSTextField* label(NSString* text, CGFloat size, NSFontWeight weight, CGFloat alpha) {
  NSTextField* l = [NSTextField wrappingLabelWithString:text];
  l.font = [NSFont systemFontOfSize:size weight:weight]; l.textColor = [NSColor colorWithWhite:1 alpha:alpha]; l.selectable = NO;
  [l setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
  return l;
}
int display_max_hz(NSScreen* screen) {
  if (@available(macOS 12.0, *)) { if (screen.maximumFramesPerSecond > 0) return (int)screen.maximumFramesPerSecond; }
  return 60;
}
}  // namespace

// ---- 3D mark: metallic ring around a gold core, slowly turning
@interface MUHeroView : SCNView
@end
@implementation MUHeroView
- (instancetype)initWithSize:(CGFloat)size {
  self = [super initWithFrame:NSMakeRect(0, 0, size, size) options:nil];
  self.translatesAutoresizingMaskIntoConstraints = NO;
  [self.widthAnchor constraintEqualToConstant:size].active = YES;
  [self.heightAnchor constraintEqualToConstant:size].active = YES;
  self.backgroundColor = NSColor.clearColor;
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
  SCNNode* key = [SCNNode node]; key.light = [SCNLight light]; key.light.type = SCNLightTypeOmni; key.light.intensity = 900; key.light.color = NSColor.whiteColor; key.position = SCNVector3Make(3, 4, 5);
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
  return self;
}
@end

// ---- backdrop: dark blue gradient, faint grid, drifting gold glow (layer-backed)
@interface MUBackdropView : NSView
@end
@implementation MUBackdropView { CAGradientLayer* _gradient; CAShapeLayer* _grid; CAGradientLayer* _glow; }
- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  self.wantsLayer = YES; self.translatesAutoresizingMaskIntoConstraints = NO;
  _gradient = [CAGradientLayer layer];
  _gradient.colors = @[(id)rgb(0.02, 0.02, 0.08).CGColor, (id)rgb(0.05, 0.07, 0.20).CGColor];
  _gradient.startPoint = CGPointMake(0.5, 0); _gradient.endPoint = CGPointMake(0.5, 1);
  [self.layer addSublayer:_gradient];
  _grid = [CAShapeLayer layer];
  _grid.strokeColor = rgb(0.45, 0.55, 1.0, 0.10).CGColor; _grid.lineWidth = 1; _grid.fillColor = nil;
  [self.layer addSublayer:_grid];
  _glow = [CAGradientLayer layer];
  _glow.type = kCAGradientLayerRadial;
  _glow.colors = @[(id)rgb(0.97, 0.79, 0.28, 0.20).CGColor, (id)rgb(0.97, 0.79, 0.28, 0).CGColor];
  _glow.startPoint = CGPointMake(0.5, 0.5); _glow.endPoint = CGPointMake(1, 1);
  [self.layer addSublayer:_glow];
  return self;
}
- (void)layout {
  [super layout];
  [CATransaction begin]; [CATransaction setDisableActions:YES];
  _gradient.frame = self.bounds;
  const CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
  CGMutablePathRef p = CGPathCreateMutable();
  for (CGFloat x = 0; x <= w; x += 56) { CGPathMoveToPoint(p, nil, x, 0); CGPathAddLineToPoint(p, nil, x, h); }
  for (CGFloat y = 0; y <= h; y += 56) { CGPathMoveToPoint(p, nil, 0, y); CGPathAddLineToPoint(p, nil, w, y); }
  _grid.path = p; CGPathRelease(p); _grid.frame = self.bounds;
  const CGFloat d = MAX(w, h) * 0.9;
  _glow.bounds = CGRectMake(0, 0, d, d); _glow.position = CGPointMake(w * 0.85, h * 0.88);
  [CATransaction commit];
  if (![_glow animationForKey:@"drift"]) {
    CABasicAnimation* drift = [CABasicAnimation animationWithKeyPath:@"position"];
    drift.fromValue = [NSValue valueWithPoint:NSPointFromCGPoint(_glow.position)];
    drift.toValue = [NSValue valueWithPoint:NSMakePoint(w * 0.2, h * 0.65)];
    drift.duration = 16; drift.autoreverses = YES; drift.repeatCount = HUGE_VALF;
    drift.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [_glow addAnimation:drift forKey:@"drift"];
  }
}
@end

// ---- a vertical stack whose children always span its full width (AppKit's width alignment only equalises them)
@interface MUColumn : NSStackView
@end
@implementation MUColumn
- (instancetype)init {
  self = [super init];
  self.orientation = NSUserInterfaceLayoutOrientationVertical; self.alignment = NSLayoutAttributeLeading; self.spacing = 10;
  return self;
}
- (void)addArrangedSubview:(NSView*)view {
  [super addArrangedSubview:view];
  [NSLayoutConstraint activateConstraints:@[[view.leadingAnchor constraintEqualToAnchor:self.leadingAnchor], [view.trailingAnchor constraintEqualToAnchor:self.trailingAnchor]]];
}
@end
@interface MUFlippedView : NSView
@end
@implementation MUFlippedView
- (BOOL)isFlipped { return YES; }
@end

// ---- angled yellow section header (Melee menu bar)
@interface MUHeaderView : NSView
@end
@implementation MUHeaderView { CAShapeLayer* _shape; }
- (instancetype)initWithTitle:(NSString*)title symbol:(NSString*)name {
  self = [super initWithFrame:NSZeroRect];
  self.wantsLayer = YES; self.translatesAutoresizingMaskIntoConstraints = NO;
  [self.heightAnchor constraintEqualToConstant:28].active = YES;
  _shape = [CAShapeLayer layer]; _shape.fillColor = kYellow().CGColor;
  [self.layer addSublayer:_shape];
  NSImageView* icon = [NSImageView imageViewWithImage:symbol(name, 12, NSFontWeightBold)];
  icon.contentTintColor = kInk(); icon.translatesAutoresizingMaskIntoConstraints = NO;
  NSTextField* l = [NSTextField labelWithString:title];
  l.font = meleeFont(13); l.textColor = kInk(); l.translatesAutoresizingMaskIntoConstraints = NO;
  [self addSubview:icon]; [self addSubview:l];
  [NSLayoutConstraint activateConstraints:@[[icon.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14], [icon.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
                                            [l.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:7], [l.centerYAnchor constraintEqualToAnchor:self.centerYAnchor]]];
  return self;
}
- (void)layout {
  [super layout];
  const CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
  CGMutablePathRef p = CGPathCreateMutable();
  CGPathMoveToPoint(p, nil, 0, 0); CGPathAddLineToPoint(p, nil, w * 0.7, 0); CGPathAddLineToPoint(p, nil, w * 0.7 - 12, h); CGPathAddLineToPoint(p, nil, 0, h); CGPathCloseSubpath(p);
  [CATransaction begin]; [CATransaction setDisableActions:YES]; _shape.path = p; [CATransaction commit];
  CGPathRelease(p);
}
@end

@class MULauncherWindow;
@interface MUDropView : NSView
@property(nonatomic, weak) MULauncherWindow* owner;
@end

@interface MULauncherWindow : NSObject <NSWindowDelegate, NSTextFieldDelegate>
@property(nonatomic) host::LauncherSettings* settings;
@property(nonatomic) host::Dashboard dashboard;
@property(nonatomic) NSWindow* window;
@property(nonatomic) NSStackView* stack;
@property(nonatomic) NSArray<NSView*>* entrance;
@property(nonatomic, copy) NSString* startupError;
@property(nonatomic) BOOL busy, closed;
@property(nonatomic) NSTimer* timer;
// hero
@property(nonatomic) NSTextField* playerChip; @property(nonatomic) NSBox* chipBox;
// steps
@property(nonatomic) NSBox* stepsCard; @property(nonatomic) NSArray<NSTextField*>* stepLabels; @property(nonatomic) NSArray<NSImageView*>* stepIcons;
// disc
@property(nonatomic) NSTextField* discName; @property(nonatomic) NSTextField* discHint; @property(nonatomic) NSButton* playButton;
// account
@property(nonatomic) NSTextField* accountLabel; @property(nonatomic) NSTextField* emailField; @property(nonatomic) NSSecureTextField* passwordField; @property(nonatomic) NSButton* signInButton; @property(nonatomic) NSProgressIndicator* spinner; @property(nonatomic) NSButton* signOutButton; @property(nonatomic) NSStackView* signInRows;
// ranked / games
@property(nonatomic) NSBox* rankedCard; @property(nonatomic) NSTextField* rankLabel; @property(nonatomic) NSTextField* ratingLabel; @property(nonatomic) NSTextField* recordLabel; @property(nonatomic) NSView* winTrack; @property(nonatomic) NSView* winBar; @property(nonatomic) NSLayoutConstraint* winBarWidth; @property(nonatomic) NSTextField* placementLabel; @property(nonatomic) NSTextField* mainsLabel;
@property(nonatomic) NSBox* gamesCard; @property(nonatomic) NSStackView* gamesStack;
// controllers
@property(nonatomic) NSStackView* controllersStack; @property(nonatomic) NSUInteger controllerCount; @property(nonatomic, copy) NSString* remapGuid; @property(nonatomic) int capturing; @property(nonatomic) BOOL armed; @property(nonatomic) NSArray<NSButton*>* remapButtons;
// display
@property(nonatomic) NSSegmentedControl* scaleControl; @property(nonatomic) NSSegmentedControl* anisoControl; @property(nonatomic) NSSwitch* vsyncSwitch; @property(nonatomic) NSSwitch* fullscreenSwitch; @property(nonatomic) NSSwitch* widescreenSwitch; @property(nonatomic) NSSlider* sharpness; @property(nonatomic) NSSwitch* onlineSwitch;
- (void)acceptDroppedDisc:(NSString*)path;
@end

@implementation MUDropView
- (instancetype)initWithFrame:(NSRect)frame { self = [super initWithFrame:frame]; [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]]; return self; }
- (BOOL)isFlipped { return YES; }
- (NSURL*)discURLIn:(id<NSDraggingInfo>)sender {
  NSArray* urls = [sender.draggingPasteboard readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
  for (NSURL* url in urls) { NSString* ext = url.pathExtension.lowercaseString; if ([ext isEqualToString:@"iso"] || [ext isEqualToString:@"gcm"]) return url; }
  return nil;
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender { return [self discURLIn:sender] ? NSDragOperationCopy : NSDragOperationNone; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
  NSURL* url = [self discURLIn:sender]; if (!url) return NO;
  [self.owner acceptDroppedDisc:[NSString stringWithUTF8String:url.fileSystemRepresentation]]; return YES;
}
@end

@implementation MULauncherWindow
- (instancetype)initWithSettings:(host::LauncherSettings*)settings error:(NSString*)error {
  self = [super init];
  self.settings = settings; self.startupError = error; self.capturing = -1;
  NSRect frame = NSMakeRect(0, 0, 720, 900);
  self.window = [[NSWindow alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView backing:NSBackingStoreBuffered defer:NO];
  self.window.title = @"iSlippi"; self.window.titlebarAppearsTransparent = YES; self.window.titleVisibility = NSWindowTitleHidden;
  self.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
  self.window.backgroundColor = rgb(0.03, 0.03, 0.09); self.window.minSize = NSMakeSize(560, 520);
  self.window.delegate = self; self.window.releasedWhenClosed = NO;
  [self.window center];
  MUDropView* content = [[MUDropView alloc] initWithFrame:frame];
  content.owner = self; content.wantsLayer = YES;
  self.window.contentView = content;
  MUBackdropView* backdrop = [[MUBackdropView alloc] initWithFrame:frame];
  [content addSubview:backdrop];
  NSScrollView* scroll = [[NSScrollView alloc] init];
  scroll.translatesAutoresizingMaskIntoConstraints = NO; scroll.drawsBackground = NO; scroll.hasVerticalScroller = YES; scroll.automaticallyAdjustsContentInsets = NO;
  NSView* doc = [[MUFlippedView alloc] init]; doc.translatesAutoresizingMaskIntoConstraints = NO;
  scroll.documentView = doc;
  [content addSubview:scroll];
  self.stack = [[MUColumn alloc] init];
  self.stack.spacing = 14; self.stack.translatesAutoresizingMaskIntoConstraints = NO;
  [doc addSubview:self.stack];
  [NSLayoutConstraint activateConstraints:@[
    [backdrop.topAnchor constraintEqualToAnchor:content.topAnchor], [backdrop.bottomAnchor constraintEqualToAnchor:content.bottomAnchor], [backdrop.leadingAnchor constraintEqualToAnchor:content.leadingAnchor], [backdrop.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
    [scroll.topAnchor constraintEqualToAnchor:content.topAnchor], [scroll.bottomAnchor constraintEqualToAnchor:content.bottomAnchor], [scroll.leadingAnchor constraintEqualToAnchor:content.leadingAnchor], [scroll.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
    [doc.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
    [self.stack.topAnchor constraintEqualToAnchor:doc.topAnchor constant:40], [self.stack.bottomAnchor constraintEqualToAnchor:doc.bottomAnchor constant:-36],
    [self.stack.centerXAnchor constraintEqualToAnchor:doc.centerXAnchor], [self.stack.widthAnchor constraintLessThanOrEqualToConstant:620]]];
  NSLayoutConstraint* width = [self.stack.widthAnchor constraintEqualToAnchor:doc.widthAnchor constant:-48]; width.priority = NSLayoutPriorityDefaultHigh; width.active = YES;

  NSView* hero = [self buildHero];
  self.stepsCard = [self buildSteps];
  self.rankedCard = [self buildRanked];
  self.gamesCard = [self buildGames];
  NSBox* account = [self buildAccount];
  NSBox* disc = [self buildDisc];
  NSBox* controllers = [self buildControllers];
  NSBox* display = [self buildDisplay];
  self.playButton = [NSButton buttonWithTitle:@"  PLAY  " target:self action:@selector(play)];
  self.playButton.bezelStyle = NSBezelStyleRounded; self.playButton.controlSize = NSControlSizeLarge; self.playButton.keyEquivalent = @"\r";
  self.playButton.bezelColor = kYellow(); self.playButton.font = meleeFont(18); self.playButton.contentTintColor = kInk();
  self.playButton.image = symbol(@"play.fill", 15, NSFontWeightBold); self.playButton.imagePosition = NSImageLeading;
  [self.playButton.heightAnchor constraintEqualToConstant:44].active = YES;
  NSTextField* footer = label(@"Needs your own Super Smash Bros. Melee NTSC 1.02 disc image. Nothing from the game ships with the app. Unofficial; not affiliated with the Slippi team or Nintendo.", 11, NSFontWeightRegular, 0.45);
  footer.alignment = NSTextAlignmentCenter;
  for (NSView* v in @[hero, self.stepsCard, self.rankedCard, self.gamesCard, account, disc, controllers, display, self.playButton, footer]) [self.stack addArrangedSubview:v];
  [self.stack setCustomSpacing:26 afterView:hero];
  self.entrance = @[hero, self.stepsCard, self.rankedCard, self.gamesCard, account, disc, controllers, display, self.playButton];
  for (NSView* v in self.entrance) v.alphaValue = 0;
  [self refreshDisc]; [self refreshAccount]; [self refreshControllers]; [self refreshSteps];
  [self loadDashboard];
  self.timer = [NSTimer timerWithTimeInterval:0.03 target:self selector:@selector(tick) userInfo:nil repeats:YES];
  [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSModalPanelRunLoopMode];   // the launcher runs modally
  [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSDefaultRunLoopMode];
  return self;
}
- (void)animateIn {
  self.window.contentView.wantsLayer = YES;
  NSTimeInterval delay = 0.05;
  for (NSView* v in self.entrance) {
    v.wantsLayer = YES;
    CABasicAnimation* rise = [CABasicAnimation animationWithKeyPath:@"transform.translation.y"];
    rise.fromValue = @(-22); rise.toValue = @0; rise.duration = 0.7; rise.beginTime = CACurrentMediaTime() + delay;
    rise.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.2 :0.9 :0.25 :1.0]; rise.fillMode = kCAFillModeBackwards;
    CABasicAnimation* fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @0; fade.toValue = @1; fade.duration = 0.5; fade.beginTime = rise.beginTime; fade.fillMode = kCAFillModeBackwards;
    v.alphaValue = 1;
    [v.layer addAnimation:rise forKey:@"rise"]; [v.layer addAnimation:fade forKey:@"fade"];
    delay += 0.06;
  }
}

// ---- building blocks
- (NSBox*)card {
  NSBox* box = [[NSBox alloc] init];
  box.boxType = NSBoxCustom; box.cornerRadius = 16; box.borderWidth = 1;
  box.borderColor = rgb(0.5, 0.6, 1.0, 0.16); box.fillColor = rgb(0.06, 0.07, 0.16, 0.82); box.contentViewMargins = NSMakeSize(0, 0);
  return box;
}
- (NSStackView*)stackIn:(NSBox*)box header:(NSString*)title symbol:(NSString*)name {
  NSStackView* s = [[MUColumn alloc] init];
  s.translatesAutoresizingMaskIntoConstraints = NO;
  [box.contentView addSubview:s];
  [NSLayoutConstraint activateConstraints:@[[s.topAnchor constraintEqualToAnchor:box.contentView.topAnchor constant:14], [s.bottomAnchor constraintEqualToAnchor:box.contentView.bottomAnchor constant:-16],
                                            [s.leadingAnchor constraintEqualToAnchor:box.contentView.leadingAnchor constant:16], [s.trailingAnchor constraintEqualToAnchor:box.contentView.trailingAnchor constant:-16]]];
  [s addArrangedSubview:[[MUHeaderView alloc] initWithTitle:title symbol:name]];
  return s;
}
- (NSStackView*)row:(NSString*)text symbol:(NSString*)name control:(NSView*)control {
  NSStackView* row = [[NSStackView alloc] init];
  row.orientation = NSUserInterfaceLayoutOrientationHorizontal; row.spacing = 10; row.alignment = NSLayoutAttributeCenterY;
  NSImageView* icon = [NSImageView imageViewWithImage:symbol(name, 13, NSFontWeightMedium)];
  icon.contentTintColor = kYellow(); [icon.widthAnchor constraintEqualToConstant:20].active = YES;
  NSTextField* l = [NSTextField labelWithString:text]; l.font = [NSFont systemFontOfSize:13]; l.textColor = NSColor.whiteColor;
  NSView* spacer = [[NSView alloc] init]; [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
  [row addArrangedSubview:icon]; [row addArrangedSubview:l]; [row addArrangedSubview:spacer]; [row addArrangedSubview:control];
  if ([control isKindOfClass:NSSlider.class]) [control.widthAnchor constraintEqualToConstant:180].active = YES;
  return row;
}
- (NSButton*)button:(NSString*)title symbol:(NSString*)name action:(SEL)action {
  NSButton* b = [NSButton buttonWithTitle:title target:self action:action];
  b.image = symbol(name, 12, NSFontWeightSemibold); b.imagePosition = NSImageLeading; b.bezelStyle = NSBezelStyleRounded; b.controlSize = NSControlSizeLarge;
  return b;
}
- (NSSwitch*)toggle:(BOOL)on { NSSwitch* s = [[NSSwitch alloc] init]; s.state = on ? NSControlStateValueOn : NSControlStateValueOff; s.controlSize = NSControlSizeSmall; return s; }
- (NSSegmentedControl*)segments:(NSArray<NSString*>*)items selected:(NSInteger)index {
  NSSegmentedControl* s = [NSSegmentedControl segmentedControlWithLabels:items trackingMode:NSSegmentSwitchTrackingSelectOne target:nil action:nil];
  s.selectedSegment = index; s.controlSize = NSControlSizeRegular;
  return s;
}

// ---- sections
- (NSView*)buildHero {
  NSStackView* hero = [[NSStackView alloc] init];
  hero.orientation = NSUserInterfaceLayoutOrientationVertical; hero.alignment = NSLayoutAttributeCenterX; hero.spacing = 6;
  [hero addArrangedSubview:[[MUHeroView alloc] initWithSize:110]];
  NSTextField* title = [NSTextField labelWithString:@"iSlippi"];
  title.font = meleeFont(46); title.textColor = NSColor.whiteColor;
  title.wantsLayer = YES; title.layer.shadowColor = kYellow().CGColor; title.layer.shadowOpacity = 0.5; title.layer.shadowRadius = 14; title.layer.shadowOffset = CGSizeZero;
  NSTextField* sub = [NSTextField labelWithString:@"SUPER SMASH BROS. MELEE  ·  SLIPPI ONLINE  ·  NATIVE"];
  sub.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold]; sub.textColor = [NSColor colorWithWhite:1 alpha:0.6];
  self.chipBox = [[NSBox alloc] init]; self.chipBox.boxType = NSBoxCustom; self.chipBox.cornerRadius = 13; self.chipBox.borderWidth = 0; self.chipBox.fillColor = kYellow(); self.chipBox.contentViewMargins = NSMakeSize(0, 0);
  self.playerChip = [NSTextField labelWithString:@""]; self.playerChip.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]; self.playerChip.textColor = kInk(); self.playerChip.translatesAutoresizingMaskIntoConstraints = NO;
  [self.chipBox.contentView addSubview:self.playerChip];
  [NSLayoutConstraint activateConstraints:@[[self.playerChip.topAnchor constraintEqualToAnchor:self.chipBox.contentView.topAnchor constant:5], [self.playerChip.bottomAnchor constraintEqualToAnchor:self.chipBox.contentView.bottomAnchor constant:-5],
                                            [self.playerChip.leadingAnchor constraintEqualToAnchor:self.chipBox.contentView.leadingAnchor constant:12], [self.playerChip.trailingAnchor constraintEqualToAnchor:self.chipBox.contentView.trailingAnchor constant:-12]]];
  self.chipBox.hidden = YES;
  [hero addArrangedSubview:title]; [hero addArrangedSubview:sub]; [hero addArrangedSubview:self.chipBox];
  [hero setCustomSpacing:12 afterView:sub];
  return hero;
}
- (NSBox*)buildSteps {
  NSBox* card = [self card];
  NSStackView* s = [self stackIn:card header:@"GET STARTED" symbol:@"flag.checkered"];
  NSArray* names = @[@"Choose your Melee disc image", @"Sign in to Slippi Online", @"Connect a controller (GameCube adapter, Bluetooth or USB pad, or keyboard)", @"Press Play"];
  NSMutableArray* labels = [NSMutableArray array]; NSMutableArray* icons = [NSMutableArray array];
  for (NSString* n in names) {
    NSStackView* row = [[NSStackView alloc] init]; row.orientation = NSUserInterfaceLayoutOrientationHorizontal; row.spacing = 10; row.alignment = NSLayoutAttributeCenterY;
    NSImageView* icon = [NSImageView imageViewWithImage:symbol(@"circle", 15, NSFontWeightSemibold)];
    icon.contentTintColor = [NSColor colorWithWhite:1 alpha:0.4]; [icon.widthAnchor constraintEqualToConstant:20].active = YES;
    NSTextField* l = label(n, 13, NSFontWeightRegular, 0.9);
    [row addArrangedSubview:icon]; [row addArrangedSubview:l]; [s addArrangedSubview:row];
    [labels addObject:l]; [icons addObject:icon];
  }
  self.stepLabels = labels; self.stepIcons = icons;
  return card;
}
- (NSBox*)buildRanked {
  NSBox* card = [self card]; card.borderColor = rgb(0.97, 0.79, 0.28, 0.4);
  NSStackView* s = [self stackIn:card header:@"RANKED" symbol:@"trophy"];
  NSStackView* top = [[NSStackView alloc] init]; top.orientation = NSUserInterfaceLayoutOrientationHorizontal; top.alignment = NSLayoutAttributeFirstBaseline;
  self.rankLabel = [NSTextField labelWithString:@""]; self.rankLabel.font = meleeFont(30); self.rankLabel.textColor = kYellow();
  self.ratingLabel = [NSTextField labelWithString:@""]; self.ratingLabel.font = [NSFont monospacedDigitSystemFontOfSize:20 weight:NSFontWeightSemibold]; self.ratingLabel.textColor = NSColor.whiteColor;
  NSView* spacer = [[NSView alloc] init]; [spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
  [top addArrangedSubview:self.rankLabel]; [top addArrangedSubview:spacer]; [top addArrangedSubview:self.ratingLabel];
  self.recordLabel = label(@"", 13, NSFontWeightMedium, 0.9);
  self.winTrack = [[NSView alloc] init]; self.winTrack.wantsLayer = YES; self.winTrack.layer.backgroundColor = [NSColor colorWithWhite:1 alpha:0.12].CGColor; self.winTrack.layer.cornerRadius = 4; self.winTrack.layer.masksToBounds = YES;
  [self.winTrack.heightAnchor constraintEqualToConstant:8].active = YES;
  self.winBar = [[NSView alloc] init]; self.winBar.wantsLayer = YES; self.winBar.layer.backgroundColor = kGreen().CGColor; self.winBar.translatesAutoresizingMaskIntoConstraints = NO;
  [self.winTrack addSubview:self.winBar];
  self.winBarWidth = [self.winBar.widthAnchor constraintEqualToAnchor:self.winTrack.widthAnchor multiplier:0.0];
  [NSLayoutConstraint activateConstraints:@[[self.winBar.leadingAnchor constraintEqualToAnchor:self.winTrack.leadingAnchor], [self.winBar.topAnchor constraintEqualToAnchor:self.winTrack.topAnchor], [self.winBar.bottomAnchor constraintEqualToAnchor:self.winTrack.bottomAnchor], self.winBarWidth]];
  self.placementLabel = label(@"", 12, NSFontWeightRegular, 0.7);
  self.mainsLabel = label(@"", 12, NSFontWeightRegular, 0.85);
  for (NSView* v in @[top, self.recordLabel, self.winTrack, self.placementLabel, self.mainsLabel]) [s addArrangedSubview:v];
  return card;
}
- (NSBox*)buildGames {
  NSBox* card = [self card];
  NSStackView* s = [self stackIn:card header:@"RECENT GAMES" symbol:@"clock.arrow.circlepath"];
  self.gamesStack = [[MUColumn alloc] init]; self.gamesStack.spacing = 7;
  [s addArrangedSubview:self.gamesStack];
  return card;
}
- (NSBox*)buildAccount {
  NSBox* card = [self card];
  NSStackView* s = [self stackIn:card header:@"SLIPPI ONLINE ACCOUNT" symbol:@"person.crop.circle"];
  self.accountLabel = label(@"", 13, NSFontWeightRegular, 1);
  [s addArrangedSubview:self.accountLabel];
  self.signInRows = [[MUColumn alloc] init]; self.signInRows.spacing = 8;
  self.emailField = [[NSTextField alloc] init]; self.emailField.placeholderString = @"Email"; self.emailField.controlSize = NSControlSizeLarge; self.emailField.bezelStyle = NSTextFieldRoundedBezel; self.emailField.delegate = self;
  self.passwordField = [[NSSecureTextField alloc] init]; self.passwordField.placeholderString = @"Password"; self.passwordField.controlSize = NSControlSizeLarge; self.passwordField.bezelStyle = NSTextFieldRoundedBezel; self.passwordField.delegate = self;
  NSStackView* buttons = [[NSStackView alloc] init]; buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal; buttons.spacing = 8;
  self.signInButton = [self button:@"Sign In" symbol:@"person.badge.key" action:@selector(signIn)];
  self.spinner = [[NSProgressIndicator alloc] init]; self.spinner.style = NSProgressIndicatorStyleSpinning; self.spinner.controlSize = NSControlSizeSmall; self.spinner.displayedWhenStopped = NO;
  NSButton* reset = [NSButton buttonWithTitle:@"Forgot password" target:self action:@selector(forgotPassword)]; reset.bezelStyle = NSBezelStyleInline; reset.controlSize = NSControlSizeSmall;
  NSButton* site = [NSButton buttonWithTitle:@"Create an account at slippi.gg" target:self action:@selector(openSlippi)]; site.bezelStyle = NSBezelStyleInline; site.controlSize = NSControlSizeSmall;
  [buttons addArrangedSubview:self.signInButton]; [buttons addArrangedSubview:self.spinner]; [buttons addArrangedSubview:reset]; [buttons addArrangedSubview:site];
  for (NSView* v in @[self.emailField, self.passwordField, buttons]) [self.signInRows addArrangedSubview:v];
  [s addArrangedSubview:self.signInRows];
  self.signOutButton = [self button:@"Sign Out" symbol:@"rectangle.portrait.and.arrow.right" action:@selector(signOut)];
  NSStackView* out = [[NSStackView alloc] init]; out.orientation = NSUserInterfaceLayoutOrientationHorizontal; [out addArrangedSubview:self.signOutButton];
  [s addArrangedSubview:out];
  return card;
}
- (NSBox*)buildDisc {
  NSBox* card = [self card];
  NSStackView* s = [self stackIn:card header:@"GAME DISC" symbol:@"opticaldisc"];
  self.discName = label(@"", 16, NSFontWeightSemibold, 1);
  self.discHint = label(@"", 12, NSFontWeightRegular, 0.6);
  NSStackView* buttons = [[NSStackView alloc] init]; buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  [buttons addArrangedSubview:[self button:@"Choose Disc Image…" symbol:@"folder" action:@selector(chooseDisc)]];
  [s addArrangedSubview:self.discName]; [s addArrangedSubview:self.discHint]; [s addArrangedSubview:buttons];
  return card;
}
- (NSBox*)buildControllers {
  NSBox* card = [self card];
  NSStackView* s = [self stackIn:card header:@"CONTROLLERS" symbol:@"gamecontroller"];
  self.controllersStack = [[MUColumn alloc] init]; self.controllersStack.spacing = 8;
  [s addArrangedSubview:self.controllersStack];
  [s addArrangedSubview:label(@"A Wii U / Switch GameCube adapter (WUP-028) is read directly over USB with the exact polling the real game uses. Bluetooth and USB pads (PlayStation, Xbox, Switch Pro, MFi) pair through System Settings › Bluetooth or a cable. Assign each one a port and remap buttons here; the keyboard always works.", 11, NSFontWeightRegular, 0.6)];
  return card;
}
- (NSBox*)buildDisplay {
  NSBox* card = [self card];
  NSStackView* s = [self stackIn:card header:@"DISPLAY & PERFORMANCE" symbol:@"speedometer"];
  id<MTLDevice> gpu = MTLCreateSystemDefaultDevice();
  NSScreen* screen = NSScreen.mainScreen;
  NSString* info = [NSString stringWithFormat:@"%@  ·  %d Hz display%@  ·  60 Hz simulation, each frame shown on the next refresh", gpu ? gpu.name : @"Metal", display_max_hz(screen), display_max_hz(screen) > 60 ? @" (ProMotion)" : @""];
  [s addArrangedSubview:label(info, 12, NSFontWeightRegular, 0.7)];
  const int scales[] = {0, 1, 2, 3, 4, 6, 8}; NSInteger scaleIndex = 0;
  for (int i = 0; i < 7; ++i) if (scales[i] == self.settings->scale) scaleIndex = i;
  self.scaleControl = [self segments:@[@"Auto", @"1×", @"2×", @"3×", @"4×", @"6×", @"8×"] selected:scaleIndex];
  [s addArrangedSubview:[self row:@"Internal resolution" symbol:@"square.resize" control:self.scaleControl]];
  self.anisoControl = [self segments:@[@"Off", @"4×", @"16×"] selected:self.settings->anisotropy >= 16 ? 2 : self.settings->anisotropy >= 4 ? 1 : 0];
  [s addArrangedSubview:[self row:@"Anisotropic filtering" symbol:@"square.stack.3d.up" control:self.anisoControl]];
  self.vsyncSwitch = [self toggle:self.settings->vsync];
  [s addArrangedSubview:[self row:@"Display sync (off = lowest latency, may tear)" symbol:@"waveform.path" control:self.vsyncSwitch]];
  self.fullscreenSwitch = [self toggle:self.settings->fullscreen];
  [s addArrangedSubview:[self row:@"Start full screen (lowest latency; ⌥⏎ toggles)" symbol:@"arrow.up.left.and.arrow.down.right" control:self.fullscreenSwitch]];
  self.widescreenSwitch = [self toggle:self.settings->widescreen];
  [s addArrangedSubview:[self row:@"Widescreen (16:9)" symbol:@"rectangle.ratio.16.to.9" control:self.widescreenSwitch]];
  self.sharpness = [NSSlider sliderWithValue:self.settings->sharpness minValue:0 maxValue:1 target:nil action:nil];
  [s addArrangedSubview:[self row:@"Sharpen" symbol:@"sparkles" control:self.sharpness]];
  self.onlineSwitch = [self toggle:self.settings->online];
  [s addArrangedSubview:[self row:@"Slippi Online services" symbol:@"network" control:self.onlineSwitch]];
  return card;
}

// ---- state
- (void)refreshSteps {
  const BOOL disc = !self.settings->iso.empty(), account = self.dashboard.signed_in, pad = self.controllerCount > 0;
  const BOOL states[4] = {disc, account, pad, NO};
  for (int i = 0; i < 4; ++i) {
    self.stepIcons[i].image = symbol(states[i] ? @"checkmark.circle.fill" : (i == 2 ? @"circle.dashed" : @"circle"), 15, NSFontWeightSemibold);
    self.stepIcons[i].contentTintColor = states[i] ? kGreen() : [NSColor colorWithWhite:1 alpha:0.4];
    self.stepLabels[i].alphaValue = states[i] ? 0.5 : 1;
  }
  self.stepsCard.hidden = disc && account;
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
    self.accountLabel.stringValue = [NSString stringWithFormat:@"Signed in as %s  (%s). Ranked stats and your connect code stay saved on this Mac.", account.display_name.c_str(), account.connect_code.c_str()];
    self.playerChip.stringValue = [NSString stringWithFormat:@"%s  %s", account.display_name.c_str(), account.connect_code.c_str()];
    self.chipBox.hidden = NO;
  } else {
    self.settings->account_name.clear(); self.settings->account_code.clear();
    self.accountLabel.stringValue = @"Sign in with your Slippi account to play online and see your ranked stats. Offline play works without it.";
    self.chipBox.hidden = YES;
  }
  self.signInRows.hidden = signed_in; self.signOutButton.hidden = !signed_in;
  self.rankedCard.hidden = !signed_in;
  [self refreshRanked]; [self refreshSteps];
}
- (void)refreshRanked {
  const host::Dashboard& d = self.dashboard;
  self.rankLabel.stringValue = ns(d.rank()); self.ratingLabel.stringValue = ns(d.rating());
  self.recordLabel.stringValue = d.profile_loaded ? ns(d.record()) : (d.profile_error.empty() ? @"Loading ranked profile…" : ns(d.profile_error));
  self.winBarWidth.active = NO;
  self.winBarWidth = [self.winBar.widthAnchor constraintEqualToAnchor:self.winTrack.widthAnchor multiplier:MAX(0.0, MIN(1.0, d.win_rate()))];
  self.winBarWidth.active = YES;
  self.placementLabel.stringValue = ns(d.placement());
  std::string mains;
  for (const std::string& m : d.mains()) mains += (mains.empty() ? "Mains: " : "   ") + m;
  self.mainsLabel.stringValue = ns(mains);
  self.placementLabel.hidden = self.placementLabel.stringValue.length == 0; self.mainsLabel.hidden = mains.empty();
  if (d.profile_loaded && d.profile.ranked) self.playerChip.stringValue = [NSString stringWithFormat:@"%s  %s  ·  %s", d.name.c_str(), d.code.c_str(), d.rank().c_str()];
}
- (void)refreshGames {
  for (NSView* v in self.gamesStack.arrangedSubviews) [v removeFromSuperview];
  std::vector<host::GameRow> rows = self.dashboard.rows();
  self.gamesCard.hidden = rows.empty();
  for (const host::GameRow& r : rows) {
    NSStackView* row = [[NSStackView alloc] init]; row.orientation = NSUserInterfaceLayoutOrientationHorizontal; row.spacing = 10; row.alignment = NSLayoutAttributeCenterY;
    NSStackView* text = [[NSStackView alloc] init]; text.orientation = NSUserInterfaceLayoutOrientationVertical; text.alignment = NSLayoutAttributeLeading; text.spacing = 1;
    [text addArrangedSubview:label(ns(r.title), 13, NSFontWeightSemibold, 1)]; [text addArrangedSubview:label(ns(r.subtitle), 11, NSFontWeightRegular, 0.6)];
    NSView* spacer = [[NSView alloc] init]; [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSTextField* result = [NSTextField labelWithString:ns(r.result)];
    result.font = meleeFont(13); result.textColor = r.win ? kGreen() : r.loss ? kRed() : [NSColor colorWithWhite:1 alpha:0.6];
    [row addArrangedSubview:text]; [row addArrangedSubview:spacer]; [row addArrangedSubview:result];
    [self.gamesStack addArrangedSubview:row];
  }
}
- (void)refreshControllers {
  std::vector<host::ControllerInfo> pads = host::window_list_controllers();
  self.controllerCount = pads.size();
  for (NSView* v in self.controllersStack.arrangedSubviews) [v removeFromSuperview];
  self.remapButtons = nil;
  if (pads.empty()) [self.controllersStack addArrangedSubview:label(@"No controller connected. Keyboard: arrows move, Z/X/C/V = A/B/X/Y, Q/E = L/R, Return = Start.", 13, NSFontWeightRegular, 0.7)];
  for (const host::ControllerInfo& pad : pads) {
    NSStackView* row = [[NSStackView alloc] init]; row.orientation = NSUserInterfaceLayoutOrientationHorizontal; row.spacing = 10; row.alignment = NSLayoutAttributeCenterY;
    NSImageView* icon = [NSImageView imageViewWithImage:symbol(pad.is_gamecube_adapter ? @"cable.connector" : @"gamecontroller.fill", 15, NSFontWeightMedium)];
    icon.contentTintColor = kYellow(); [icon.widthAnchor constraintEqualToConstant:22].active = YES;
    NSTextField* name = label(ns(pad.name + (pad.is_gamecube_adapter ? "  ·  GameCube adapter" : "")), 13, NSFontWeightSemibold, 1);
    [name setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSString* guid = ns(pad.guid);
    NSPopUpButton* port = [[NSPopUpButton alloc] init]; port.controlSize = NSControlSizeRegular;
    [port addItemsWithTitles:@[@"Auto port", @"Port 1", @"Port 2", @"Port 3", @"Port 4"]];
    [port selectItemAtIndex:MAX(0, MIN(4, pad.assigned_port))];
    port.target = self; port.action = @selector(portChanged:); objc_setAssociatedObject(port, "guid", guid, OBJC_ASSOCIATION_COPY);
    [row addArrangedSubview:icon]; [row addArrangedSubview:name]; [row addArrangedSubview:port];
    if (!pad.is_gamecube_adapter) {
      NSButton* remap = [NSButton buttonWithTitle:[self.remapGuid isEqualToString:guid] ? @"Done" : @"Remap…" target:self action:@selector(toggleRemap:)];
      remap.bezelStyle = NSBezelStyleRounded; objc_setAssociatedObject(remap, "guid", guid, OBJC_ASSOCIATION_COPY);
      [row addArrangedSubview:remap];
    }
    [self.controllersStack addArrangedSubview:row];
    if ([self.remapGuid isEqualToString:guid]) [self.controllersStack addArrangedSubview:[self remapPanel:pad]];
  }
  [self refreshSteps];
}
- (NSView*)remapPanel:(const host::ControllerInfo&)pad {
  NSBox* box = [[NSBox alloc] init]; box.boxType = NSBoxCustom; box.cornerRadius = 10; box.borderWidth = 0; box.fillColor = [NSColor colorWithWhite:1 alpha:0.06]; box.contentViewMargins = NSMakeSize(12, 10);
  NSStackView* s = [[MUColumn alloc] init]; s.spacing = 6;
  [s addArrangedSubview:label(@"Click a GameCube control, then press the button you want on the controller.", 11, NSFontWeightRegular, 0.6)];
  NSMutableArray* buttons = [NSMutableArray array];
  NSStackView* grid = nil;
  for (int i = 0; i < host::GC_CTL_COUNT; ++i) {
    if (i % 3 == 0) { grid = [[NSStackView alloc] init]; grid.orientation = NSUserInterfaceLayoutOrientationHorizontal; grid.distribution = NSStackViewDistributionFillEqually; grid.spacing = 6; [s addArrangedSubview:grid]; }
    NSButton* b = [NSButton buttonWithTitle:@"" target:self action:@selector(startCapture:)];
    b.bezelStyle = NSBezelStyleRounded; b.tag = i; b.alignment = NSTextAlignmentLeft;
    [grid addArrangedSubview:b]; [buttons addObject:b];
  }
  NSStackView* actions = [[NSStackView alloc] init]; actions.orientation = NSUserInterfaceLayoutOrientationHorizontal; actions.spacing = 8;
  NSButton* reset = [NSButton buttonWithTitle:@"Reset to default" target:self action:@selector(resetMapping)]; reset.bezelStyle = NSBezelStyleRounded;
  NSButton* swap = [NSButton buttonWithTitle:@"Swap sticks" target:self action:@selector(swapSticks)]; swap.bezelStyle = NSBezelStyleRounded;
  [actions addArrangedSubview:reset]; [actions addArrangedSubview:swap];
  [s addArrangedSubview:actions];
  box.contentView = s;
  self.remapButtons = buttons;
  [self refreshRemap];
  return box;
}
- (host::ControllerConfig)remapConfig {
  host::ControllerConfig cfg;
  if (const host::ControllerConfig* c = host::controller_config_for(self.remapGuid.UTF8String ?: "")) cfg = *c;
  cfg.guid = self.remapGuid.UTF8String ?: "";
  return cfg;
}
- (void)refreshRemap {
  host::ControllerConfig cfg = [self remapConfig];
  for (NSButton* b in self.remapButtons) {
    const int i = (int)b.tag;
    b.title = [NSString stringWithFormat:@"%s:  %@", host::kGcControlNames[i], self.capturing == i ? @"press…" : ns(host::physical_input_name(cfg.map.binding[i]))];
    b.contentTintColor = self.capturing == i ? kYellow() : nil;
  }
}
- (void)tick {
  if (self.closed) return;
  if (host::window_list_controllers().size() != self.controllerCount) [self refreshControllers];
  if (self.capturing < 0 || !self.remapGuid) return;
  const int input = host::window_capture_input(self.remapGuid.UTF8String);
  if (!self.armed) { if (input == host::kUnbound) self.armed = YES; return; }
  if (input == host::kUnbound) return;
  host::ControllerConfig cfg = [self remapConfig];
  cfg.map.binding[self.capturing] = input;
  host::upsert_controller_config(cfg);
  self.capturing = -1;
  [self refreshRemap];
}
- (void)portChanged:(NSPopUpButton*)sender {
  NSString* guid = objc_getAssociatedObject(sender, "guid");
  host::ControllerConfig cfg; if (const host::ControllerConfig* c = host::controller_config_for(guid.UTF8String)) cfg = *c;
  cfg.guid = guid.UTF8String; cfg.port = (int)sender.indexOfSelectedItem;
  host::upsert_controller_config(cfg);
  [self refreshControllers];
}
- (void)toggleRemap:(NSButton*)sender {
  NSString* guid = objc_getAssociatedObject(sender, "guid");
  self.remapGuid = [self.remapGuid isEqualToString:guid] ? nil : guid; self.capturing = -1;
  [self refreshControllers];
}
- (void)startCapture:(NSButton*)sender { self.capturing = (int)sender.tag; self.armed = NO; [self refreshRemap]; }
- (void)resetMapping { host::ControllerConfig cfg = [self remapConfig]; cfg.map = host::ControllerMap::defaults(); host::upsert_controller_config(cfg); [self refreshRemap]; }
- (void)swapSticks { host::ControllerConfig cfg = [self remapConfig]; cfg.map.swap_sticks = !cfg.map.swap_sticks; host::upsert_controller_config(cfg); [self refreshRemap]; }
- (void)refreshDisc {
  if (self.settings->iso.empty()) {
    self.discName.stringValue = @"No disc chosen";
    self.discHint.stringValue = self.startupError.length ? self.startupError : @"Choose your Melee NTSC 1.02 image (.iso/.gcm), or drop it onto this window.";
    self.playButton.enabled = NO;
  } else {
    NSString* path = ns(self.settings->iso);
    NSDictionary* attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    self.discName.stringValue = path.lastPathComponent;
    self.discHint.stringValue = [NSString stringWithFormat:@"%.2f GB · %@%@", [attrs fileSize] / 1e9, [path stringByAbbreviatingWithTildeInPath], self.startupError.length ? [@"\n" stringByAppendingString:self.startupError] : @""];
    self.playButton.enabled = YES;
  }
  [self refreshSteps];
}
- (void)loadDashboard {
  std::string slippi_dir = self.settings->slippi_dir, replay_dir = self.settings->replay_dir;
  __weak MULauncherWindow* weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    host::Dashboard d;
    host::dashboard_load_games(replay_dir, d, 8);
    host::dashboard_load_profile(slippi_dir, d);
    dispatch_async(dispatch_get_main_queue(), ^{
      MULauncherWindow* s = weakSelf; if (!s || s.closed || !s.settings) return;
      host::Dashboard merged = d; merged.signed_in = s.dashboard.signed_in || d.profile_loaded;
      s.dashboard = merged; [s refreshAccount]; [s refreshGames];
    });
  });
}

// ---- actions
- (void)controlTextDidEndEditing:(NSNotification*)note {
  NSNumber* movement = note.userInfo[@"NSTextMovement"];
  if (movement.integerValue != NSReturnTextMovement) return;
  if (note.object == self.emailField) [self.window makeFirstResponder:self.passwordField]; else [self signIn];
}
- (void)setBusy:(BOOL)busy {
  _busy = busy; self.signInButton.enabled = !busy;
  if (busy) [self.spinner startAnimation:nil]; else [self.spinner stopAnimation:nil];
}
- (void)signIn {
  if (self.busy) return;
  std::string email = self.emailField.stringValue.UTF8String ?: "", password = self.passwordField.stringValue.UTF8String ?: "";
  if (email.empty() || password.empty()) { self.accountLabel.stringValue = @"Enter your Slippi email and password."; return; }
  self.busy = YES; self.accountLabel.stringValue = @"Signing in…";
  std::string dir = self.settings->slippi_dir;
  __weak MULauncherWindow* weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    slippi::login::Account account; slippi::login::Session session; std::string error;
    bool ok = slippi::login::sign_in_session(email, password, account, session, error) && slippi::login::write_user_file(dir, account, error);
    if (ok) slippi::login::write_session(dir, session);
    dispatch_async(dispatch_get_main_queue(), ^{
      MULauncherWindow* s = weakSelf; if (!s || s.closed || !s.settings) return;
      s.busy = NO;
      if (ok) { s.passwordField.stringValue = @""; s->_dashboard.name = account.display_name; s->_dashboard.code = account.connect_code; [s refreshAccount]; [s loadDashboard]; }
      else s.accountLabel.stringValue = ns(error);
    });
  });
}
- (void)forgotPassword {
  std::string email = self.emailField.stringValue.UTF8String ?: "";
  if (email.empty()) { self.accountLabel.stringValue = @"Enter your email first, then click Forgot password."; return; }
  self.accountLabel.stringValue = @"Sending a password reset email…";
  __weak MULauncherWindow* weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    std::string error; bool ok = slippi::login::send_password_reset(email, error);
    dispatch_async(dispatch_get_main_queue(), ^{ MULauncherWindow* s = weakSelf; if (!s || s.closed) return; s.accountLabel.stringValue = ok ? @"Password reset email sent. Check your inbox." : ns(error); });
  });
}
- (void)openSlippi { [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://slippi.gg"]]; }
- (void)signOut {
  if (!self.settings) return;
  slippi::login::remove_user_file(self.settings->slippi_dir); slippi::login::remove_session(self.settings->slippi_dir);
  self.dashboard = host::Dashboard(); [self refreshAccount]; [self refreshGames];
}
- (void)acceptDroppedDisc:(NSString*)path { self.settings->iso = std::string(path.fileSystemRepresentation); self.startupError = nil; [self refreshDisc]; }
- (void)chooseDisc {
  NSOpenPanel* panel = [NSOpenPanel openPanel];
  panel.title = @"Choose Disc Image"; panel.prompt = @"Choose"; panel.canChooseDirectories = NO; panel.allowsMultipleSelection = NO;
  if ([panel runModal] != NSModalResponseOK) return;
  [self acceptDroppedDisc:[NSString stringWithUTF8String:panel.URL.fileSystemRepresentation]];
}
- (void)play {
  const int scales[] = {0, 1, 2, 3, 4, 6, 8};
  self.settings->scale = scales[MAX(0, MIN(6, self.scaleControl.selectedSegment))];
  self.settings->anisotropy = self.anisoControl.selectedSegment == 2 ? 16 : self.anisoControl.selectedSegment == 1 ? 4 : 1;
  self.settings->vsync = self.vsyncSwitch.state == NSControlStateValueOn;
  self.settings->fullscreen = self.fullscreenSwitch.state == NSControlStateValueOn;
  self.settings->widescreen = self.widescreenSwitch.state == NSControlStateValueOn;
  self.settings->online = self.onlineSwitch.state == NSControlStateValueOn;
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
    [alert runModal];
  }
}
bool launcher_run(LauncherSettings& settings, const std::string& error) {
  @autoreleasepool {
    prepare_application();
    settings.display_hz = display_max_hz(NSScreen.mainScreen);
    if (id<MTLDevice> gpu = MTLCreateSystemDefaultDevice()) settings.gpu_name = gpu.name.UTF8String;
    MULauncherWindow* launcher = [[MULauncherWindow alloc] initWithSettings:&settings error:error.empty() ? nil : [NSString stringWithUTF8String:error.c_str()]];
    [launcher.window makeKeyAndOrderFront:nil];
    [launcher animateIn];
    if (const char* scroll = std::getenv("MELEE_LAUNCHER_SCROLL"))   // screenshot aid: start scrolled down by N points
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSScrollView* sv = (NSScrollView*)launcher.stack.superview.superview.superview;
        if ([sv isKindOfClass:NSScrollView.class]) { [sv.contentView scrollToPoint:NSMakePoint(0, std::atof(scroll))]; [sv reflectScrolledClipView:sv.contentView]; } });
    NSModalResponse response = [NSApp runModalForWindow:launcher.window];
    launcher.closed = YES;
    [launcher.timer invalidate];
    launcher.settings = nullptr;   // an in-flight sign-in must not write into main's settings afterwards
    [launcher.window orderOut:nil];
    return response == NSModalResponseOK;
  }
}
}  // namespace host
