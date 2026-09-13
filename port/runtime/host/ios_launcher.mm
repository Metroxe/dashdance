// iOS / visionOS launcher: a UIKit screen shown before the game window. Disc images
// are imported into the app's Documents folder (also reachable from the Files app).
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
}  // namespace

@interface MULauncherController : UIViewController <UIDocumentPickerDelegate>
@property(nonatomic) host::LauncherSettings* settings;
@property(nonatomic) BOOL done, play;
@property(nonatomic) UILabel* discLabel;
@property(nonatomic) UILabel* hintLabel;
@property(nonatomic) UIButton* playButton;
@property(nonatomic) UISwitch* widescreenSwitch;
@property(nonatomic) UISwitch* onlineSwitch;
@property(nonatomic) UISlider* sharpnessSlider;
@property(nonatomic) UISlider* overlaySlider;
@property(nonatomic, copy) NSString* startupError;
@property(nonatomic) UILabel* accountLabel;
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
  self.view.backgroundColor = [UIColor colorWithRed:0.05 green:0.04 blue:0.10 alpha:1];
  CAGradientLayer* gradient = [CAGradientLayer layer];
  gradient.colors = @[(id)[UIColor colorWithRed:0.16 green:0.10 blue:0.36 alpha:1].CGColor, (id)[UIColor colorWithRed:0.04 green:0.03 blue:0.09 alpha:1].CGColor];
  gradient.startPoint = CGPointMake(0, 0); gradient.endPoint = CGPointMake(1, 1);
  UIView* backdrop = [[UIView alloc] init];
  backdrop.translatesAutoresizingMaskIntoConstraints = NO;
  [backdrop.layer addSublayer:gradient];
  [self.view addSubview:backdrop];
  [NSLayoutConstraint activateConstraints:@[
    [backdrop.topAnchor constraintEqualToAnchor:self.view.topAnchor], [backdrop.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    [backdrop.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [backdrop.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]]];
  gradient.frame = self.view.bounds;

  UIScrollView* scroll = [[UIScrollView alloc] init];
  scroll.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:scroll];
  UIStackView* stack = [[UIStackView alloc] init];
  stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 18; stack.alignment = UIStackViewAlignmentFill;
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  [scroll addSubview:stack];
  [NSLayoutConstraint activateConstraints:@[
    [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor], [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
    [scroll.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor], [scroll.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
    [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:48], [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-40],
    [stack.centerXAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.centerXAnchor],
    [stack.widthAnchor constraintLessThanOrEqualToConstant:560]]];
  NSLayoutConstraint* width = [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-48];
  width.priority = UILayoutPriorityDefaultHigh; width.active = YES;

  UILabel* title = [[UILabel alloc] init];
  title.text = @"Melee Unlocked";
  title.font = [UIFont systemFontOfSize:44 weight:UIFontWeightBold];
  title.textColor = UIColor.whiteColor; title.textAlignment = NSTextAlignmentCenter;
  UILabel* subtitle = [[UILabel alloc] init];
  subtitle.text = @"Super Smash Bros. Melee with Slippi rollback netplay, running natively on this device.";
  subtitle.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
  subtitle.textColor = [UIColor colorWithWhite:1 alpha:0.7]; subtitle.textAlignment = NSTextAlignmentCenter; subtitle.numberOfLines = 0;
  [stack addArrangedSubview:title]; [stack addArrangedSubview:subtitle];
  [stack setCustomSpacing:28 afterView:subtitle];

  // Disc card
  UIView* card = [self card];
  UIStackView* cardStack = [self stackIn:card];
  UILabel* cardTitle = [self caption:@"GAME DISC"];
  self.discLabel = [[UILabel alloc] init];
  self.discLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
  self.discLabel.textColor = UIColor.whiteColor; self.discLabel.numberOfLines = 0;
  self.hintLabel = [[UILabel alloc] init];
  self.hintLabel.font = [UIFont systemFontOfSize:14]; self.hintLabel.numberOfLines = 0;
  self.hintLabel.textColor = [UIColor colorWithWhite:1 alpha:0.6];
  UIButton* import_ = [self button:@"Import Disc Image…" filled:NO];
  [import_ addTarget:self action:@selector(importDisc) forControlEvents:UIControlEventTouchUpInside];
  [cardStack addArrangedSubview:cardTitle]; [cardStack addArrangedSubview:self.discLabel];
  [cardStack addArrangedSubview:self.hintLabel]; [cardStack addArrangedSubview:import_];
  [stack addArrangedSubview:card];

  // Slippi account card
  UIView* account = [self card];
  UIStackView* accountStack = [self stackIn:account];
  [accountStack addArrangedSubview:[self caption:@"SLIPPI ONLINE ACCOUNT"]];
  self.accountLabel = [[UILabel alloc] init];
  self.accountLabel.font = [UIFont systemFontOfSize:17]; self.accountLabel.textColor = UIColor.whiteColor; self.accountLabel.numberOfLines = 0;
  [accountStack addArrangedSubview:self.accountLabel];
  self.signInRows = [[UIStackView alloc] init];
  self.signInRows.axis = UILayoutConstraintAxisVertical; self.signInRows.spacing = 10;
  self.emailField = [self field:@"Email" secure:NO];
  self.emailField.keyboardType = UIKeyboardTypeEmailAddress; self.emailField.textContentType = UITextContentTypeUsername;
  self.passwordField = [self field:@"Password" secure:YES];
  self.passwordField.textContentType = UITextContentTypePassword;
  [self.passwordField addTarget:self action:@selector(signIn) forControlEvents:UIControlEventEditingDidEndOnExit];
  self.signInButton = [self button:@"Sign In" filled:NO];
  [self.signInButton addTarget:self action:@selector(signIn) forControlEvents:UIControlEventTouchUpInside];
  self.resetButton = [UIButton buttonWithType:UIButtonTypeSystem];
  [self.resetButton setTitle:@"Forgot password · Create an account at slippi.gg" forState:UIControlStateNormal];
  self.resetButton.titleLabel.font = [UIFont systemFontOfSize:13];
  [self.resetButton addTarget:self action:@selector(forgotPassword) forControlEvents:UIControlEventTouchUpInside];
  [self.signInRows addArrangedSubview:self.emailField]; [self.signInRows addArrangedSubview:self.passwordField];
  [self.signInRows addArrangedSubview:self.signInButton]; [self.signInRows addArrangedSubview:self.resetButton];
  [accountStack addArrangedSubview:self.signInRows];
  self.signOutButton = [self button:@"Sign Out" filled:NO];
  [self.signOutButton addTarget:self action:@selector(signOut) forControlEvents:UIControlEventTouchUpInside];
  [accountStack addArrangedSubview:self.signOutButton];
  [stack addArrangedSubview:account];
  [self refreshAccount];

  // Settings card
  UIView* settings = [self card];
  UIStackView* settingsStack = [self stackIn:settings];
  [settingsStack addArrangedSubview:[self caption:@"PLAY"]];
  self.widescreenSwitch = [[UISwitch alloc] init]; self.widescreenSwitch.on = self.settings->widescreen;
  [settingsStack addArrangedSubview:[self row:@"Widescreen (16:9)" control:self.widescreenSwitch]];
  self.onlineSwitch = [[UISwitch alloc] init]; self.onlineSwitch.on = self.settings->online;
  [settingsStack addArrangedSubview:[self row:@"Slippi Online" control:self.onlineSwitch]];
  self.sharpnessSlider = [[UISlider alloc] init]; self.sharpnessSlider.value = self.settings->sharpness;
  [settingsStack addArrangedSubview:[self row:@"Sharpen" control:self.sharpnessSlider]];
  self.overlaySlider = [[UISlider alloc] init]; self.overlaySlider.minimumValue = 0.2f; self.overlaySlider.value = self.settings->overlay_opacity;
  [settingsStack addArrangedSubview:[self row:@"On-screen controls" control:self.overlaySlider]];
  [stack addArrangedSubview:settings];

  self.playButton = [self button:@"Play" filled:YES];
  [self.playButton addTarget:self action:@selector(play) forControlEvents:UIControlEventTouchUpInside];
  [stack addArrangedSubview:self.playButton];

  UILabel* footer = [[UILabel alloc] init];
  footer.text = @"Needs your own Super Smash Bros. Melee NTSC 1.02 disc image (.iso/.gcm). Nothing from the game ships with the app. Touch controls, Bluetooth controllers and keyboards all work.";
  footer.font = [UIFont systemFontOfSize:13]; footer.textColor = [UIColor colorWithWhite:1 alpha:0.5];
  footer.numberOfLines = 0; footer.textAlignment = NSTextAlignmentCenter;
  [stack addArrangedSubview:footer];
  [self refreshDisc];
}
- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  for (UIView* v in self.view.subviews) for (CALayer* l in v.layer.sublayers) if ([l isKindOfClass:CAGradientLayer.class]) l.frame = v.bounds;
}
- (UIView*)card {
  UIView* card = [[UIView alloc] init];
  card.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
  card.layer.cornerRadius = 20; card.layer.cornerCurve = kCACornerCurveContinuous;
  return card;
}
- (UIStackView*)stackIn:(UIView*)card {
  UIStackView* s = [[UIStackView alloc] init];
  s.axis = UILayoutConstraintAxisVertical; s.spacing = 12; s.translatesAutoresizingMaskIntoConstraints = NO;
  [card addSubview:s];
  [NSLayoutConstraint activateConstraints:@[
    [s.topAnchor constraintEqualToAnchor:card.topAnchor constant:20], [s.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-20],
    [s.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20], [s.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20]]];
  return s;
}
- (UILabel*)caption:(NSString*)text {
  UILabel* l = [[UILabel alloc] init];
  l.text = text; l.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
  l.textColor = [UIColor colorWithWhite:1 alpha:0.5];
  return l;
}
- (UIView*)row:(NSString*)text control:(UIView*)control {
  UIStackView* row = [[UIStackView alloc] init];
  row.axis = UILayoutConstraintAxisHorizontal; row.spacing = 16; row.alignment = UIStackViewAlignmentCenter;
  UILabel* l = [[UILabel alloc] init];
  l.text = text; l.font = [UIFont systemFontOfSize:17]; l.textColor = UIColor.whiteColor;
  [l setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
  [row addArrangedSubview:l]; [row addArrangedSubview:control];
  if ([control isKindOfClass:UISlider.class]) [control.widthAnchor constraintEqualToConstant:180].active = YES;
  return row;
}
- (UIButton*)button:(NSString*)title filled:(BOOL)filled {
  UIButtonConfiguration* c = filled ? [UIButtonConfiguration filledButtonConfiguration] : [UIButtonConfiguration grayButtonConfiguration];
  c.title = title; c.cornerStyle = UIButtonConfigurationCornerStyleLarge;
  c.contentInsets = NSDirectionalEdgeInsetsMake(14, 20, 14, 20);
  if (filled) c.baseBackgroundColor = [UIColor colorWithRed:0.42 green:0.34 blue:0.95 alpha:1];
  UIButton* b = [UIButton buttonWithConfiguration:c primaryAction:nil];
  b.titleLabel.font = [UIFont systemFontOfSize:19 weight:UIFontWeightSemibold];
  return b;
}
- (UITextField*)field:(NSString*)placeholder secure:(BOOL)secure {
  UITextField* f = [[UITextField alloc] init];
  f.attributedPlaceholder = [[NSAttributedString alloc] initWithString:placeholder attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.35]}];
  f.textColor = UIColor.whiteColor; f.font = [UIFont systemFontOfSize:17];
  f.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08]; f.layer.cornerRadius = 10;
  f.secureTextEntry = secure; f.autocapitalizationType = UITextAutocapitalizationTypeNone; f.autocorrectionType = UITextAutocorrectionTypeNo;
  UIView* pad = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 44)];
  f.leftView = pad; f.leftViewMode = UITextFieldViewModeAlways;
  [f.heightAnchor constraintEqualToConstant:44].active = YES;
  return f;
}
- (void)refreshAccount {
  slippi::login::Account account;
  const bool signed_in = slippi::login::read_user_file(self.settings->slippi_dir, account);
  if (signed_in) {
    self.settings->account_name = account.display_name; self.settings->account_code = account.connect_code;
    self.accountLabel.text = [NSString stringWithFormat:@"Signed in as %s  (%s)", account.display_name.c_str(), account.connect_code.c_str()];
  } else {
    self.settings->account_name.clear(); self.settings->account_code.clear();
    self.accountLabel.text = @"Sign in with your Slippi account to play online. Offline play works without it.";
  }
  self.signInRows.hidden = signed_in;
  self.signOutButton.hidden = !signed_in;
}
- (void)signIn {
  if (self.busy) return;
  std::string email = self.emailField.text.UTF8String ?: "", password = self.passwordField.text.UTF8String ?: "";
  if (email.empty() || password.empty()) { self.accountLabel.text = @"Enter your Slippi email and password."; return; }
  self.busy = YES; self.signInButton.enabled = NO;
  self.accountLabel.text = @"Signing in…";
  std::string dir = self.settings->slippi_dir;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    slippi::login::Account account; std::string error;
    bool ok = slippi::login::sign_in(email, password, account, error) && slippi::login::write_user_file(dir, account, error);
    dispatch_async(dispatch_get_main_queue(), ^{
      self.busy = NO; self.signInButton.enabled = YES;
      if (ok) { self.passwordField.text = @""; [self refreshAccount]; }
      else self.accountLabel.text = [NSString stringWithUTF8String:error.c_str()];
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
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    std::string error;
    bool ok = slippi::login::send_password_reset(email, error);
    dispatch_async(dispatch_get_main_queue(), ^{
      self.accountLabel.text = ok ? @"Password reset email sent. Check your inbox." : [NSString stringWithUTF8String:error.c_str()];
    });
  });
}
- (void)signOut {
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
  self.play = YES; self.done = YES;
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
    for (int wait = 0; wait < 40 && !scene; ++wait) {
      for (UIScene* s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:UIWindowScene.class]) { scene = (UIWindowScene*)s; break; }
      if (!scene) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
    }
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
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
    return controller.play;
  }
}
}  // namespace host
